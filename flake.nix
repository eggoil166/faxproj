{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      inherit (self.packages.x86_64-linux) asterisk-fax;

      testNetwork = (import ./tests/network.nix { inherit pkgs; }).network;
      # A bare system around some modules, for checks that build but never boot.
      mkTestSystem =
        modules:
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = modules ++ [
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/".device = "/dev/null";
            }
          ];
        }).config.system.build.toplevel;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          asterisk-fax = pkgs.callPackage ./pkgs/asterisk-fax.nix { };
          torfax = pkgs.callPackage ./pkgs/torfax { };
          default = torfax;
        }
      );

      nixosModules.torfax =
        { pkgs, ... }:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
        in
        {
          imports = [ ./modules/torfax.nix ];
          # Every station runs the Asterisk/spandsp build tested here, whatever
          # nixpkgs its own system follows.
          services.torfax = lib.mkIf (self.packages ? ${system}) {
            package = lib.mkDefault self.packages.${system}.asterisk-fax;
            cliPackage = lib.mkDefault self.packages.${system}.torfax;
          };
        };
      nixosModules.default = self.nixosModules.torfax;

      lib =
        let
          # mkHub and mkSpoke for one network (its subnet, hub and phonebook).
          # Each admin keeps their network in their own flake, see
          # templates/network.
          mkNetwork = network: {
            inherit network;

            # The hub: station network.hub.number, publishing the onion service.
            mkHub =
              {
                privateKeyFile,
                onionSecretKeyFile ? null,
                users ? [ ],
              }:
              {
                imports = [ self.nixosModules.torfax ];
                services.torfax = {
                  enable = true;
                  role = "hub";
                  station = network.hub.number;
                  inherit users;
                  inherit (network) subnet phonebook;
                  hub = network.hub // {
                    inherit onionSecretKeyFile;
                  };
                  wireguard.privateKeyFile = privateKeyFile;
                };
              };

            # A user's station: differs from other spokes only by number, key
            # file and local users.
            mkSpoke =
              {
                station,
                privateKeyFile,
                users ? [ ],
              }:
              {
                imports = [ self.nixosModules.torfax ];
                services.torfax = {
                  enable = true;
                  role = "spoke";
                  inherit station users;
                  inherit (network) subnet hub phonebook;
                  wireguard.privateKeyFile = privateKeyFile;
                };
              };
          };
        in
        # This repository also carries eggoil's network.
        mkNetwork (import ./network.nix) // { inherit mkNetwork; };

      templates = {
        network = {
          path = ./templates/network;
          description = "Run your own torfax network: the phonebook your hub and users share";
        };
        spoke = {
          path = ./templates/spoke;
          description = "Join a torfax network as a user, with your own number and key";
        };
      };

      checks.x86_64-linux = {
        loopback = import ./tests/loopback.nix {
          inherit pkgs;
          module = self.nixosModules.torfax;
        };
        torfax = import ./tests/torfax.nix {
          inherit pkgs;
          module = self.nixosModules.torfax;
        };

        # The templates' flake.nix files, evaluated against this checkout and
        # the test phonebook into full systems.
        template-spoke =
          let
            template = (import ./templates/spoke/flake.nix).outputs {
              faxnet = self // {
                lib = self.lib.mkNetwork testNetwork;
              };
            };
          in
          mkTestSystem [
            template.nixosModules.default
            { users.users.alice.isNormalUser = true; }
          ];

        # A brand-new network at the hub's first deploy: just the hub in the
        # phonebook, and no onion address yet.
        template-network =
          let
            fresh = testNetwork // {
              hub = {
                number = "0001";
                onion = null;
              };
              phonebook."0001" = testNetwork.phonebook."0001";
            };
            template = (import ./templates/network/flake.nix).outputs {
              torfax = self // {
                lib = self.lib // {
                  mkNetwork = _: self.lib.mkNetwork fresh;
                };
              };
            };
          in
          mkTestSystem [
            (template.lib.mkHub {
              privateKeyFile = "/var/lib/torfax-secrets/wg.key";
              users = [ "admin" ];
            })
            { users.users.admin.isNormalUser = true; }
          ];

        # lab/conf is where settings get proven; fail if the module drifts.
        lab-parity =
          let
            conf = lib.mapAttrs pkgs.writeText self.checks.x86_64-linux.loopback.nodes.machine.services.asterisk.confFiles;
          in
          pkgs.runCommand "torfax-lab-parity" { } ''
            # copied verbatim
            for f in res_fax.conf udptl.conf logger.conf; do
              diff -u ${./lab/conf}/$f ${pkgs.linkFarm "conf" conf}/$f
            done
            # the same [system], transport, template and [self]; only the
            # per-station endpoints differ
            n=$(($(grep -n '^\[hub\](fax-endpoint)' ${./lab/conf/pjsip.conf} | cut -d: -f1) - 1))
            diff -u <(head -n $n ${./lab/conf/pjsip.conf}) <(head -n $n ${conf."pjsip.conf"})
            # every lab dialplan line, in order; the module only adds hooks
            awk 'BEGIN { i = 0 } NR == FNR { want[n++] = $0; next } i < n && $0 == want[i] { i++ }
                 END { if (i < n) { print "missing from module dialplan: " want[i]; exit 1 } }' \
              ${./lab/conf/extensions.conf} ${conf."extensions.conf"}
            touch $out
          '';
      };

      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          asterisk-fax
          pkgs.ghostscript
          pkgs.libtiff
          pkgs.wireguard-tools
          pkgs.wstunnel
          pkgs.tor
        ];
        shellHook = ''
          export AST_MODDIR=$(dirname $(dirname $(command -v asterisk)))/lib/asterisk/modules
          echo "asterisk-fax ready $AST_MODDIR"
        '';
      };
      # The spoke test rig: station 0002 on the real network, over real Tor.
      nixosConfigurations.labvm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (self.lib.mkSpoke {
            station = "0002";
            # gitignored, read over the 9p share at runtime
            privateKeyFile = "/mnt/faxproj/lab/wg/vm.key";
            users = [ "lab" ];
          })
          ({ pkgs, ... }: {
            system.stateVersion = "25.11";
            networking.hostName = "labvm";
            networking.firewall.enable = false;
            users.users.lab = {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
              password = "lab";
            };
            security.sudo.wheelNeedsPassword = false;
            services.getty.autologinUser = "lab";
            environment.systemPackages = [
              pkgs.wireguard-tools
              pkgs.ghostscript
              pkgs.libtiff
              pkgs.wstunnel
              pkgs.tor
            ];
            systemd.services.wireguard-torfax.unitConfig.RequiresMountsFor = "/mnt/faxproj";
            virtualisation.vmVariant.virtualisation = {
              graphics = false;
              memorySize = 2048;
              sharedDirectories.faxProj = {
                source = "$HOME/src/faxproj";
                target = "/mnt/faxproj";
              };
            };
          })
        ];
      };
    };
}
