# Hub + two spokes, faxing over the real module transport: WireGuard ->
# wstunnel (--http-proxy) -> "Tor" -> wstunnel server -> WireGuard.
#
# The sandbox has no Tor network, so onion routing itself is the one leg that
# is stood in for, after checking each Tor daemon starts with the module's
# config:
#   spoke: tinyproxy (an HTTP CONNECT proxy, like Tor's HTTPTunnelPort) takes
#          over 127.0.0.1:9080 and resolves the onion name to the hub;
#   hub:   socat forwards the hub's LAN port 8080 to 127.0.0.1:8080, as the
#          onion service does.
# Every hop gets 300ms of netem delay so T.38 sees Tor-like round trips.
{ pkgs, module }:
let
  test = import ./network.nix { inherit pkgs; };
  net = test.network;

  station =
    {
      role,
      number,
      key,
    }:
    { lib, ... }:
    {
      imports = [ module ];
      services.torfax = {
        enable = true;
        inherit role;
        station = number;
        inherit (net) phonebook hub subnet;
        wireguard.privateKeyFile = "/etc/torfax-test/wg.key";
        users = [ "user" ];
      };
      environment.etc."torfax-test/wg.key" = {
        source = test.keyFile key;
        mode = "0400";
      };
      environment.etc."torfax-test/test.pdf".source = ../lab/test.pdf;
      environment.systemPackages = [ pkgs.wireguard-tools ];
      users.users.user.isNormalUser = true;
      virtualisation.memorySize = 1536;
    };

  spoke =
    args:
    { nodes, ... }:
    {
      imports = [ (station (args // { role = "spoke"; })) ];
      networking.hosts.${nodes.hub.networking.primaryIPAddress} = [ net.hub.onion ];
      systemd.services.tor-standin = {
        conflicts = [ "tor.service" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.tinyproxy}/bin/tinyproxy -d -c ${pkgs.writeText "tinyproxy.conf" ''
            Port 9080
            Listen 127.0.0.1
            Allow 127.0.0.1
            ConnectPort 8080
            Timeout 3600
          ''}";
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "torfax";

  nodes.hub =
    { config, ... }:
    {
      imports = [
        (station {
          role = "hub";
          number = "0001";
          key = "hub";
        })
      ];
      # Publish with a key we made, to check the hostname Tor derives from it.
      services.torfax.hub.onionSecretKeyFile = "/var/lib/torfax-test/hs_ed25519_secret_key";
      systemd.services.torfax-test-onion-key = {
        requiredBy = [ "tor.service" ];
        before = [ "tor.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          rm -rf /var/lib/torfax-test && mkdir -p /var/lib/torfax-test/keys
          ${pkgs.mkp224o}/bin/mkp224o-donna -q -n 1 -d /var/lib/torfax-test/keys t
          cp /var/lib/torfax-test/keys/*/hs_ed25519_secret_key /var/lib/torfax-test/keys/*/hostname /var/lib/torfax-test/
        '';
      };
      systemd.services.onion-standin = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:8080,bind=${config.networking.primaryIPAddress},fork,reuseaddr TCP:127.0.0.1:8080";
      };
      networking.firewall.interfaces.eth1.allowedTCPPorts = [ 8080 ];
    };
  nodes.alice = spoke {
    number = "0002";
    key = "alice";
  };
  nodes.bob = spoke {
    number = "0003";
    key = "bob";
  };

  testScript = ''
    ast = "asterisk -C /etc/asterisk/asterisk.conf -rx"
    spokes = [alice, bob]
    stations = [hub, alice, bob]
    number = {hub: "0001", alice: "0002", bob: "0003"}

    def torrc(m):
        return m.succeed("systemctl cat tor.service | grep -o '/nix/store/[^ ]*torrc' | head -1").strip()

    def wait_asterisk(m):
        m.wait_for_unit("asterisk.service")
        m.wait_until_succeeds(f"{ast} 'core waitfullybooted'", timeout=900)
        m.wait_until_succeeds(f"{ast} 'pjsip show transports' | grep -q transport-udp", timeout=300)

    def fax(src, dst):
        """src faxes dst; both sides must report SUCCESS over T.38."""
        out = src.succeed(f"su - user -c 'torfax send /etc/torfax-test/test.pdf {number[dst]}'")
        job = out.split()[1].rstrip(":")
        meta = f"/var/lib/torfax/outbox/{job}.meta"
        src.wait_until_succeeds(f"grep -qxE 'status=(SUCCESS|FAILED)' {meta}", timeout=1200)
        print(src.succeed(f"cat {meta}"))
        src.succeed(f"grep -qx status=SUCCESS {meta}", f"grep -qx mode=T38 {meta}")
        rx = dst.wait_until_succeeds(f"grep -lx from={number[src]} /var/lib/torfax/inbox/*.meta", timeout=120).split()[-1]
        print(dst.succeed(f"cat {rx}"))
        dst.succeed(
            f"grep -qx status=SUCCESS {rx}",
            f"grep -qx mode=T38 {rx}",
            f"grep -qx rate=4800 {rx}",
            f"head -c5 /var/lib/torfax/inbox/$(sed -n 's/^pdf=//p' {rx}) | grep -q %PDF",
        )

    start_all()

    with subtest("hub: onion service from the provided key, wstunnel on loopback only"):
        hub.wait_for_unit("tor.service")
        hub.wait_until_succeeds("test -s /run/tor/onion/torfax/hostname", timeout=600)
        hub.succeed("diff /run/tor/onion/torfax/hostname /var/lib/torfax-test/hostname")
        rc = torrc(hub)
        hub.succeed(f"grep -qx 'HiddenServicePort 8080 127.0.0.1:8080' {rc}", f"grep -qx 'SOCKSPort 0' {rc}")
        hub.wait_for_unit("wstunnel-server-torfax.service")
        hub.wait_for_open_port(8080, "127.0.0.1")
        hub.succeed("ss -Hltn 'sport = :8080' | grep -q '127.0.0.1:8080'")
        hub.succeed("test $(cat /proc/sys/net/ipv4/conf/torfax/forwarding) = 1")
        hub.succeed("test $(cat /proc/sys/net/ipv4/conf/eth1/forwarding) = 0")

    with subtest("spokes: Tor is an HTTP CONNECT tunnel with no SOCKS port"):
        for s in spokes:
            s.wait_for_unit("tor.service")
            s.wait_for_open_port(9080, "127.0.0.1")
            rc = torrc(s)
            s.succeed(f"grep -qE '^HTTPTunnelPort 127.0.0.1:9080 *$' {rc}", f"grep -qx 'SOCKSPort 0' {rc}")
            s.fail("ss -Hltn | grep -q ':9050 '")

    with subtest("firewall opens the fax ports on the WireGuard interface only"):
        for m in stations:
            rules = m.succeed("iptables -S nixos-fw")
            for want in ["-i torfax -p udp -m udp --dport 5060", "-i torfax -p udp -m udp --dport 4000:4999", "-i torfax -p udp -m udp --dport 10000:20000"]:
                assert want in rules, f"{m.name}: missing '{want}'"
            assert "--dport 5060 -j nixos-fw-accept" not in rules.replace("-i torfax -p udp -m udp --dport 5060 -j nixos-fw-accept", ""), "5060 open beyond torfax"

    with subtest("stand in for onion routing, add Tor-like latency"):
        for s in spokes:
            s.succeed("systemctl start tor-standin.service")
            s.wait_for_open_port(9080, "127.0.0.1")
        for m in stations:
            m.succeed("tc qdisc add dev eth1 root netem delay 300ms")

    with subtest("WireGuard over wstunnel, spoke to spoke through the hub"):
        for s in spokes:
            s.wait_until_succeeds("ping -c1 -W5 10.73.0.1", timeout=600)
        alice.wait_until_succeeds("ping -c1 -W5 10.73.0.3", timeout=300)
        print(hub.succeed("wg show torfax"))

    for m in stations:
        wait_asterisk(m)

    with subtest("spoke -> hub"):
        fax(alice, hub)

    with subtest("restarting Asterisk leaves the transport up"):
        hub.succeed("systemctl restart asterisk.service")
        wait_asterisk(hub)
        alice.succeed("ping -c1 -W5 10.73.0.1")

    with subtest("hub -> spoke"):
        fax(hub, alice)

    with subtest("spoke -> spoke through the hub"):
        fax(alice, bob)

    for m in stations:
        print(m.succeed("su - user -c 'torfax inbox; torfax outbox'"))
  '';
}
