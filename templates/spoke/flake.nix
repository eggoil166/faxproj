{
  description = "Your station on a torfax network";

  # Your network's flake, from its admin. This one is eggoil's network.
  inputs.faxnet.url = "github:eggoil166/faxproj";

  outputs =
    { faxnet, ... }:
    {
      # Add this flake as an input of your NixOS flake and put
      # inputs.<name>.nixosModules.default in your system's modules.
      nixosModules.default = faxnet.lib.mkSpoke {
        # Your fax number, from the network's admin.
        station = "0003";
        # Your WireGuard private key (see README.md). Read at runtime; never
        # commit it or write it as a ./path, which would copy it to the store.
        privateKeyFile = "/var/lib/torfax-secrets/wg.key";
        # Existing users who may send and read faxes.
        users = [ "alice" ];
      };
    };
}
