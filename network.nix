# The torfax network, shared verbatim by the hub and every spoke. Public
# information only: numbers, names, WireGuard *public* keys and the hub's onion
# address. Private keys never go here; stations point at them with
# services.torfax.wireguard.privateKeyFile.
#
# To add a friend: they send you their public key (see templates/spoke), you
# give them the next free number and address below, then redeploy the hub.
{
  subnet = "10.73.0.0/24";
  hub = {
    number = "0001";
    onion = "r36v7ohrey6m3miradr2wpb47seib54qxwhol7fefr6agqwgmyls4oqd.onion";
  };
  phonebook = {
    "0001" = {
      name = "eggoil";
      address = "10.73.0.1";
      publicKey = "a2iwWwWn+uHQ4CxYMi2LyDRdqYA/MoW/LunRoI1rOHo=";
    };
    "0002" = {
      name = "labvm";
      address = "10.73.0.2";
      publicKey = "n3gXiUuzt3DmLJFtB1lzgjEsiipV3PbCpucvGhiGUAo=";
    };
  };
}
