{
  subnet = "10.73.0.0/24";

  hub = {
    number = "0001";
    # After the hub's first start: sudo cat /var/lib/tor/onion/torfax/hostname
    onion = null;
  };

  phonebook = {
    "0001" = {
      name = "hub";
      address = "10.73.0.1";
      publicKey = "PASTE-THE-HUB-PUBLIC-KEY-HERE";
    };
    # "0002" = {
    #   name = "alice";
    #   address = "10.73.0.2";
    #   publicKey = "...";
    # };
  };
}
