{
  lib,
  symlinkJoin,
  writeShellApplication,
  coreutils,
  gawk,
  ghostscript,
  gnugrep,
  libtiff,
  util-linux,
}:
let
  common = builtins.readFile ./common.sh;
  runtimeInputs = [
    coreutils
    gawk
    ghostscript
    gnugrep
    libtiff
    util-linux
  ];
in
symlinkJoin {
  name = "torfax";
  paths = [
    (writeShellApplication {
      name = "torfax";
      inherit runtimeInputs;
      text = common + builtins.readFile ./torfax.sh;
    })
    (writeShellApplication {
      name = "torfax-hook";
      inherit runtimeInputs;
      text = common + builtins.readFile ./torfax-hook.sh;
    })
  ];
  meta = {
    description = "Send and list faxes on a torfax station";
    mainProgram = "torfax";
    platforms = lib.platforms.linux;
  };
}
