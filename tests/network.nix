# The phonebook the VM tests use. Their WireGuard keys are generated at build
# time, so no private key is ever written into the repository; the public
# halves are read back from the build output.
{ pkgs }:
let
  keys = pkgs.runCommand "torfax-test-keys" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    mkdir $out
    for name in hub alice bob; do
      wg genkey > $out/$name.key
      wg pubkey < $out/$name.key > $out/$name.pub
    done
  '';
  publicKey = name: pkgs.lib.removeSuffix "\n" (builtins.readFile "${keys}/${name}.pub");
in
{
  keyFile = name: "${keys}/${name}.key";

  network = {
    subnet = "10.73.0.0/24";
    hub.number = "0001";
    # Not a real onion service: the sandboxed test resolves this name to the
    # hub through /etc/hosts and a stand-in HTTP CONNECT proxy.
    hub.onion = "torfaxtestxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.onion";
    phonebook = {
      "0001" = {
        name = "hub";
        address = "10.73.0.1";
        publicKey = publicKey "hub";
      };
      "0002" = {
        name = "alice";
        address = "10.73.0.2";
        publicKey = publicKey "alice";
      };
      "0003" = {
        name = "bob";
        address = "10.73.0.3";
        publicKey = publicKey "bob";
      };
    };
  };
}
