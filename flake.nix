{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      asterisk-fax = pkgs.asterisk.overrideAttrs (old: {
        pname = "asterisk-fax";
        buildInputs = old.buildInputs ++ [
          pkgs.spandsp
          pkgs.libtiff
        ];
        postInstall = (old.postInstall or "") + ''
          test -f $out/lib/asterisk/modules/res_fax_spandsp.so || {
              echo "res_fax_spandsp.so was not built" >&2
              exit 1
            }
        '';
      });
    in
    {
      packages.x86_64-linux.asterisk-fax = asterisk-fax;
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
      nixosConfigurations.labvm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
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
              asterisk-fax
              pkgs.wireguard-tools
              pkgs.ghostscript
              pkgs.libtiff
              pkgs.wstunnel
              pkgs.tor
            ];
            networking.wg-quick.interfaces.wg0.configFile = "/mnt/faxproj/lab/wg/vm/wg0.conf";
            systemd.services.wg-quick-wg0.unitConfig.RequiresMountsFor = "/mnt/faxproj";
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
