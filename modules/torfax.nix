{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStrings
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.torfax;
  isHub = cfg.role == "hub";
  me = cfg.phonebook.${cfg.station};
  others = lib.filterAttrs (n: _: n != cfg.station) cfg.phonebook;
  iface = cfg.wireguard.interface;
  prefixLength = lib.last (lib.splitString "/" cfg.subnet);

  stateDir = "/var/lib/torfax";
  spoolDir = "/var/spool/asterisk";

  sipPort = 5060;
  udptlPorts = {
    from = 4000;
    to = 4999;
  };
  rtpPorts = {
    from = 10000;
    to = 20000;
  };

  hook = "${cfg.cliPackage}/bin/torfax-hook";
  arg = v: "'\${FILTER(-/0-9A-Za-z ._+:,${v})}'";

  pjsipEndpoint = number: entry: ''

    [${number}](fax-endpoint)
    aors=${number}
    [${number}]
    type=aor
    contact=sip:${entry.address}:${toString sipPort}
    [${number}]
    type=identify
    endpoint=${number}
    match=${entry.address}
  '';

  confFiles = {
    "pjsip.conf" = ''
      [system]
      type=system
      timer_t1=1000
      timer_b=64000

      [transport-udp]
      type=transport
      protocol=udp
      bind=0.0.0.0:${toString sipPort}

      [fax-endpoint](!)
      type=endpoint
      context=torfax-inbound
      disallow=all
      allow=ulaw
      t38_udptl=yes
      t38_udptl_ec=redundancy
      t38_udptl_maxdatagram=400
      t38_udptl_nat=no
      fax_detect=no
      direct_media=no

      [self](fax-endpoint)
      aors=self
      [self]
      type=aor
      contact=sip:127.0.0.1:${toString sipPort}
      [self]
      type=identify
      endpoint=self
      match=127.0.0.1
    ''
    + concatStrings (mapAttrsToList pjsipEndpoint others);

    "res_fax.conf" = ''
      [general]
      modems=v27
      minrate=4800
      maxrate=4800
      ecm=yes
      statusevents=yes
      t38timeout=30000
    '';

    "udptl.conf" = ''
      [general]
      udptlstart=${toString udptlPorts.from}
      udptlend=${toString udptlPorts.to}
      udptlfecentries=3
      udptlfecspan=3
      use_even_ports=no
    '';

    "rtp.conf" = ''
      [general]
      rtpstart=${toString rtpPorts.from}
      rtpend=${toString rtpPorts.to}
    '';

    "modules.conf" = ''
      [modules]
      autoload=yes
      noload = res_hep.so
      noload = res_hep_pjsip.so
      noload = res_hep_rtcp.so
      noload = app_voicemail_imap.so
      noload = app_voicemail_odbc.so
    '';

    "logger.conf" = ''
      [general]

      [logfiles]
      console => notice,warning,error,verbose
      full => notice,warning,error,verbose,fax
    '';

    "extensions.conf" = ''
      [general]
      static=yes
      writeprotect=no

      [torfax-inbound]
      exten => _X.,1,NoOp(inbound fax from ''${CHANNEL(endpoint)} to ''${EXTEN})
       same => n,Set(FAXOPT(ecm)=yes)
       same => n,Set(FAXOPT(maxrate)=4800)
       same => n,Set(FAXOPT(localstationid)=''${ENV(TORFAX_STATION)})
       same => n,Set(FAXFILE=''${ASTSPOOLDIR}/fax/incoming/''${STRFTIME(''${EPOCH},,%Y%m%d-%H%M%S)}-''${UNIQUEID}.tif)
       same => n,Set(TORFAX_FROM=''${CHANNEL(endpoint)})
       same => n,Set(TORFAX_TO=''${EXTEN})
       same => n,Answer()
       same => n,ReceiveFAX(''${FAXFILE},d)
       same => n,Hangup()
      exten => h,1,NoOp(RX RESULT status=''${FAXSTATUS} mode=''${FAXMODE} pages=''${FAXPAGES} rate=''${FAXBITRATE} err="''${FAXERROR}" file=''${FAXFILE})
       same => n,System(${hook} rx ${arg "\${TORFAX_FROM}"} ${arg "\${TORFAX_TO}"} ${arg "\${FAXSTATUS}"} ${arg "\${FAXMODE}"} ${arg "\${FAXPAGES}"} ${arg "\${FAXBITRATE}"} ${arg "\${FAXOPT(remotestationid)}"} ${arg "\${FAXERROR}"} ${arg "\${FAXFILE}"})

      [torfax-outbound]
      exten => _XXXX,1,NoOp(outbound fax to ''${EXTEN} file=''${FAXFILE})
       same => n,Set(FAXOPT(ecm)=yes)
       same => n,Set(FAXOPT(maxrate)=4800)
       same => n,Set(FAXOPT(localstationid)=''${ENV(TORFAX_STATION)})
       same => n,SendFAX(''${FAXFILE},d)
       same => n,Hangup()
      exten => h,1,NoOp(RX RESULT status=''${FAXSTATUS} mode=''${FAXMODE} pages=''${FAXPAGES} rate=''${FAXBITRATE} remote=''${FAXOPT(remotestationid)} err="''${FAXERROR}" file=''${FAXFILE})
       same => n,GotoIf($["''${TORFAX_FAILED}" = "1"]?done)
       same => n,System(${hook} tx ${arg "\${TORFAX_JOB}"} ${arg "\${FAXSTATUS}"} ${arg "\${FAXMODE}"} ${arg "\${FAXPAGES}"} ${arg "\${FAXBITRATE}"} ${arg "\${FAXOPT(remotestationid)}"} ${arg "\${FAXERROR}"})
       same => n(done),NoOp()
      ; the call file's call never connected; runs once per attempt
      exten => failed,1,NoOp(TX FAILED job=''${TORFAX_JOB} reason=''${REASON})
       same => n,Set(TORFAX_FAILED=1)
       same => n,System(${hook} txfail ${arg "\${TORFAX_JOB}"} ${arg "\${REASON}"})
    '';
  };

  torfaxConf = ''
    station=${cfg.station}
    hub=${cfg.hub.number}
    role=${cfg.role}
    phonebook=/etc/torfax/phonebook.tsv
    state=${stateDir}
    spool=${spoolDir}
    max_retries=${toString cfg.retries}
    retry_time=120
    wait_time=90
  '';

  phonebookTsv = concatStrings (
    mapAttrsToList (n: e: "${n}\t${e.name}\t${e.address}\t${e.publicKey}\n") cfg.phonebook
  );

  secretPath = types.addCheck types.str (
    p: lib.hasPrefix "/" p && !lib.hasPrefix builtins.storeDir p
  );
in
{
  options.services.torfax = {
    enable = mkEnableOption "torfax, fax over T.38/WireGuard/wstunnel/Tor";

    role = mkOption {
      type = types.enum [
        "hub"
        "spoke"
      ];
      description = "The hub publishes the onion service; spokes connect to it.";
    };

    station = mkOption {
      type = types.strMatching "[0-9]{4}";
      example = "0002";
      description = "This station's fax number; must be in the phonebook.";
    };

    phonebook = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.strMatching "[^\t\n]+";
              description = "Human-readable station name.";
            };
            address = mkOption {
              type = types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+";
              example = "10.73.0.2";
              description = "The station's WireGuard address inside `subnet`.";
            };
            publicKey = mkOption {
              type = types.strMatching "[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=";
              description = "The station's WireGuard public key.";
            };
          };
        }
      );
      description = ''
        Every station on the network, keyed by 4-digit fax number. Shared
        verbatim by the hub and all spokes: the hub turns it into WireGuard
        peers, every station into PJSIP endpoints and /etc/torfax/phonebook.tsv.
      '';
    };

    subnet = mkOption {
      type = types.str;
      default = "10.73.0.0/24";
      description = "The WireGuard network all phonebook addresses live in.";
    };

    hub = {
      number = mkOption {
        type = types.strMatching "[0-9]{4}";
        example = "0001";
        description = "Phonebook number of the hub.";
      };
      onion = mkOption {
        type = types.nullOr (types.strMatching "[a-z2-7]{56}\\.onion");
        default = null;
        description = "The hub's onion address. Required on spokes.";
      };
      onionPort = mkOption {
        type = types.port;
        default = 8080;
        description = ''
          Onion service port, and the 127.0.0.1 port the hub's wstunnel server
          listens on behind it.
        '';
      };
      wireguardPort = mkOption {
        type = types.port;
        default = 51820;
        description = "The hub's WireGuard listen port (reached via wstunnel only).";
      };
      onionSecretKeyFile = mkOption {
        type = types.nullOr secretPath;
        default = null;
        example = "/var/lib/torfax-secrets/hs_ed25519_secret_key";
        description = ''
          Hub only: an existing `hs_ed25519_secret_key` to publish the onion
          with. If null, Tor generates one on first start and keeps it in
          /var/lib/tor/onion/torfax/.
        '';
      };
      routeBetweenSpokes = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Hub only: forward IPv4 between WireGuard peers so spokes can fax
          each other. Enabled for the WireGuard interface only.
        '';
      };
    };

    spoke = {
      httpTunnelPort = mkOption {
        type = types.port;
        default = 9080;
        description = "Spoke only: local Tor HTTPTunnelPort that wstunnel connects through.";
      };
      wstunnelPort = mkOption {
        type = types.port;
        default = 51821;
        description = "Spoke only: local UDP port wstunnel listens on as WireGuard's endpoint.";
      };
    };

    wireguard = {
      interface = mkOption {
        type = types.str;
        default = "torfax";
        description = "Name of the WireGuard interface.";
      };
      privateKeyFile = mkOption {
        type = secretPath;
        example = "/var/lib/torfax-secrets/wg.key";
        description = "This station's WireGuard private key, read at runtime.";
      };
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Users allowed to send and read faxes (added to the torfax group).
        Members can drop arbitrary Asterisk call files, so only list people
        you would trust with the asterisk user.
      '';
    };

    retries = mkOption {
      type = types.ints.unsigned;
      default = 3;
      description = "How often to redial a station that did not answer.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/asterisk-fax.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/asterisk-fax.nix { }";
      description = "Asterisk built with spandsp.";
    };

    cliPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/torfax { };
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/torfax { }";
      description = "The torfax CLI and dialplan hook.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.phonebook ? ${cfg.station};
        message = "services.torfax.station ${cfg.station} is not in services.torfax.phonebook.";
      }
      {
        assertion = cfg.phonebook ? ${cfg.hub.number};
        message = "services.torfax.hub.number ${cfg.hub.number} is not in services.torfax.phonebook.";
      }
      {
        assertion = lib.all (n: builtins.match "[0-9]{4}" n != null) (lib.attrNames cfg.phonebook);
        message = "services.torfax.phonebook numbers must be 4 digits.";
      }
      {
        assertion = isHub == (cfg.station == cfg.hub.number);
        message = "services.torfax: role is ${cfg.role}, but station ${cfg.station} ${
          if isHub then "is not" else "is"
        } hub.number.";
      }
      {
        assertion = isHub || cfg.hub.onion != null;
        message = "services.torfax.hub.onion must be set on spokes.";
      }
      {
        assertion = lib.allUnique (mapAttrsToList (_: e: e.address) cfg.phonebook);
        message = "services.torfax.phonebook addresses must be unique.";
      }
    ];

    users.groups.torfax = { };
    users.users =
      lib.genAttrs cfg.users (_: {
        extraGroups = [ "torfax" ];
      })
      // {
        asterisk.extraGroups = [ "torfax" ];
      };

    environment.systemPackages = [ cfg.cliPackage ];
    environment.etc."torfax/torfax.conf".text = torfaxConf;
    environment.etc."torfax/phonebook.tsv".text = phonebookTsv;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 2770 asterisk torfax -"
      "d ${stateDir}/inbox 2770 asterisk torfax -"
      "d ${stateDir}/outbox 2770 asterisk torfax -"
    ];

    services.asterisk = {
      enable = true;
      inherit (cfg) package;
      inherit confFiles;
      extraConfig = ''
        [options]
        verbose = 3
        debug = 0
      '';
    };

    networking.wireguard.interfaces.${iface} = {
      ips = [ "${me.address}/${prefixLength}" ];
      inherit (cfg.wireguard) privateKeyFile;
      mtu = 1280;
      listenPort = if isHub then cfg.hub.wireguardPort else null;
      peers =
        if isHub then
          mapAttrsToList (n: e: {
            name = "station-${n}";
            inherit (e) publicKey;
            allowedIPs = [ "${e.address}/32" ];
          }) others
        else
          [
            {
              name = "hub";
              inherit (cfg.phonebook.${cfg.hub.number}) publicKey;
              allowedIPs = [ cfg.subnet ];
              endpoint = "127.0.0.1:${toString cfg.spoke.wstunnelPort}";
              persistentKeepalive = 25;
            }
          ];
      postSetup = lib.optionalString (
        isHub && cfg.hub.routeBetweenSpokes
      ) "echo 1 > /proc/sys/net/ipv4/conf/${iface}/forwarding";
    };

    networking.firewall.interfaces.${iface} = {
      allowedUDPPorts = [ sipPort ];
      allowedUDPPortRanges = [
        udptlPorts
        rtpPorts
      ];
    };

    services.tor = {
      enable = true;
      relay.onionServices = mkIf isHub {
        torfax = {
          map = [
            {
              port = cfg.hub.onionPort;
              target = {
                addr = "127.0.0.1";
                port = cfg.hub.onionPort;
              };
            }
          ];
          secretKey = cfg.hub.onionSecretKeyFile;
        };
      };
      settings.HTTPTunnelPort = mkIf (!isHub) [
        {
          addr = "127.0.0.1";
          port = cfg.spoke.httpTunnelPort;
        }
      ];
    };

    services.wstunnel = {
      enable = true;
      servers.torfax = mkIf isHub {
        listen = {
          host = "127.0.0.1";
          port = cfg.hub.onionPort;
          enableHTTPS = false;
        };
        settings.restrict-to = [
          {
            host = "127.0.0.1";
            port = cfg.hub.wireguardPort;
          }
        ];
      };
      clients.torfax = mkIf (!isHub) {
        connectTo = "ws://${cfg.hub.onion}:${toString cfg.hub.onionPort}";
        settings = {
          local-to-remote = [
            "udp://${toString cfg.spoke.wstunnelPort}:127.0.0.1:${toString cfg.hub.wireguardPort}?timeout_sec=0"
          ];
          http-proxy = "127.0.0.1:${toString cfg.spoke.httpTunnelPort}";
        };
      };
    };
    systemd.services.wstunnel-client-torfax = mkIf (!isHub) {
      wants = [ "tor.service" ];
      after = [ "tor.service" ];
    };

    systemd.services.asterisk = {
      after = [ "wireguard-${iface}.service" ];
      environment.TORFAX_STATION = cfg.station;
      restartIfChanged = lib.mkForce true;
      restartTriggers = lib.attrValues confFiles;
      preStart = lib.mkAfter ''
        install -d -m 0750 -o asterisk -g asterisk ${spoolDir}/fax ${spoolDir}/fax/incoming
        # torfax-staging holds call files until they are renamed into outgoing/
        install -d -m 2770 -o asterisk -g torfax ${spoolDir}/outgoing ${spoolDir}/torfax-staging
        # Stasis won't initialise without the package's xmldoc; upstream copies
        # it only once, so refresh it in case the package changed.
        cp -rT --no-preserve=mode ${cfg.package}/var/lib/asterisk/documentation /var/lib/asterisk/documentation
        chown -R asterisk:asterisk /var/lib/asterisk/documentation
      '';
    };
  };
}
