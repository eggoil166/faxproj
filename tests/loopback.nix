# One station faxes itself through the [self] endpoint on 127.0.0.1: exercises
# the generated Asterisk config, spool permissions, CLI and hooks without any
# transport underneath.
{ pkgs, module }:
let
  test = import ./network.nix { inherit pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "torfax-loopback";

  nodes.machine = {
    imports = [ module ];
    services.torfax = {
      enable = true;
      role = "hub";
      station = "0001";
      inherit (test.network) phonebook hub subnet;
      wireguard.privateKeyFile = "/etc/torfax-test/wg.key";
      users = [ "alice" ];
    };
    environment.etc."torfax-test/wg.key" = {
      source = test.keyFile "hub";
      mode = "0400";
    };
    environment.etc."torfax-test/test.pdf".source = ../lab/test.pdf;
    users.users.alice.isNormalUser = true;
    virtualisation.memorySize = 1536;
  };

  testScript = ''
    ast = "asterisk -C /etc/asterisk/asterisk.conf -rx"

    machine.wait_for_unit("asterisk.service")
    machine.wait_until_succeeds(f"{ast} 'core waitfullybooted'", timeout=600)
    machine.wait_until_succeeds(f"{ast} 'pjsip show transports' | grep -q transport-udp", timeout=300)
    machine.succeed(f"{ast} 'module show like res_fax_spandsp' | grep -q res_fax_spandsp")
    print(machine.succeed(f"{ast} 'fax show settings'"))
    print(machine.succeed(f"{ast} 'pjsip show endpoints'"))

    with subtest("a new hub generates its onion address for the admin to publish"):
        machine.wait_for_unit("tor.service")
        machine.wait_until_succeeds("test -s /var/lib/tor/onion/torfax/hostname", timeout=300)
        machine.succeed("grep -qxE '[a-z2-7]{56}\\.onion' /var/lib/tor/onion/torfax/hostname")

    with subtest("users outside the torfax group are refused"):
        machine.succeed("useradd -m mallory")
        machine.fail("su - mallory -c 'torfax send /etc/torfax-test/test.pdf 0001'")
        machine.fail("su - mallory -c 'torfax inbox'")

    with subtest("bad numbers are refused before anything is queued"):
        machine.fail("su - alice -c 'torfax send /etc/torfax-test/test.pdf 0009'")
        machine.fail("su - alice -c 'torfax send /etc/torfax-test/test.pdf 12'")
        machine.succeed("test -z \"$(ls /var/lib/torfax/outbox)\"")

    with subtest("fax to self over the [self] endpoint"):
        print(machine.succeed("su - alice -c 'torfax send /etc/torfax-test/test.pdf 0001'"))
        machine.wait_until_succeeds("grep -qx status=SUCCESS /var/lib/torfax/outbox/*.meta", timeout=600)
        print(machine.succeed("cat /var/lib/torfax/outbox/*.meta"))
        machine.succeed("grep -qx mode=T38 /var/lib/torfax/outbox/*.meta")
        machine.wait_until_succeeds("ls /var/lib/torfax/inbox/*.meta", timeout=60)
        print(machine.succeed("cat /var/lib/torfax/inbox/*.meta"))
        machine.succeed("grep -qx status=SUCCESS /var/lib/torfax/inbox/*.meta")
        machine.succeed("grep -qx mode=T38 /var/lib/torfax/inbox/*.meta")
        machine.succeed("grep -qx from=0001 /var/lib/torfax/inbox/*.meta")
        machine.succeed("grep -qx rate=4800 /var/lib/torfax/inbox/*.meta")
        machine.succeed("head -c5 /var/lib/torfax/inbox/*.pdf | grep -q %PDF")
        # the received TIFF is removed from the spool once converted
        machine.succeed("test -z \"$(ls /var/spool/asterisk/fax/incoming)\"")
        print(machine.succeed("su - alice -c 'torfax inbox; torfax outbox; torfax phonebook'"))
  '';
}
