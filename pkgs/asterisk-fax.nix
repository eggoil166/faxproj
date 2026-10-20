{
  asterisk,
  spandsp,
  libtiff,
}:
asterisk.overrideAttrs (old: {
  pname = "asterisk-fax";
  buildInputs = old.buildInputs ++ [
    spandsp
    libtiff
  ];
  postInstall = (old.postInstall or "") + ''
    test -f $out/lib/asterisk/modules/res_fax_spandsp.so || {
        echo "res_fax_spandsp.so was not built" >&2
        exit 1
      }
  '';
})
