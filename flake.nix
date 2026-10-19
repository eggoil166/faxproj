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
        ];
        shellHook = ''
          export AST_MODDIR=$(dirname $(dirname $(command -v asterisk)))/lib/asterisk/modules
          echo "asterisk-fax ready $AST_MODDIR"
        '';
      };
    };
}
