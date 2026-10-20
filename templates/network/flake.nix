{
  description = "A torfax network: the phonebook its hub and users share";

  inputs.torfax.url = "github:eggoil166/faxproj";

  outputs =
    { torfax, ... }:
    {
      # On the hub:
      #   (inputs.<this>.lib.mkHub { privateKeyFile = "..."; users = [ "..." ]; })
      # On each user's machine:
      #   (inputs.<this>.lib.mkSpoke { station = "0002"; privateKeyFile = "..."; users = [ "..." ]; })
      lib = torfax.lib.mkNetwork (import ./network.nix);
    };
}
