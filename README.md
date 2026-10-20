# torfax

Send and receive real faxes between NixOS machines over Tor. A network is one
**hub** (run by an admin) and any number of **users**. Everyone joins a private
network through the hub's onion service, so no machine, not even the hub, is
exposed to the internet or its LAN, and there are no ports to open.

You need NixOS with flakes enabled. Every station makes its own WireGuard key,
which stays on that machine:

```sh
sudo install -d -m 0700 /var/lib/torfax-secrets
nix shell nixpkgs#wireguard-tools -c sh -c \
  'umask 077; wg genkey | sudo tee /var/lib/torfax-secrets/wg.key | wg pubkey'
```

That prints the key's **public** half, which is the only part you ever share.

## Join a network

**1.** Make your key (above) and send the public key to the network's admin.
You get back a 4-digit fax number and the network's flake URL.

**2.** Add the network to your system flake. For eggoil's network the URL is
`github:eggoil166/faxproj`:

```nix
{
  inputs.faxnet.url = "github:eggoil166/faxproj";

  outputs = { nixpkgs, faxnet, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        (faxnet.lib.mkSpoke {
          station = "0003";                                  # your fax number
          privateKeyFile = "/var/lib/torfax-secrets/wg.key"; # a string, never ./wg.key
          users = [ "alice" ];                               # who may send and read faxes
        })
      ];
    };
  };
}
```

Don't make it follow your nixpkgs: every station should run the same tested
fax build.

**3.** Rebuild, then log out and back in to join the `torfax` group:

```sh
sudo nixos-rebuild switch --flake .#yourhost
```

The first build compiles Asterisk with fax support, which takes a while.

**4.** Check you're connected (Tor needs a minute to start):

```sh
ping 10.73.0.1      # the hub, through Tor
torfax phonebook
```

When new people join, `nix flake update faxnet` and rebuild to get their entries.

## Run your own network

The hub must stay online: it carries every call.

**1.** Start a repo for your network:

```sh
mkdir mynet && cd mynet && git init
nix flake init -t github:eggoil166/faxproj#network
```

**2.** On the hub machine, make its key (above) and paste the public key into
the `"0001"` entry in `network.nix`.

**3.** Commit, then add your network repo to the hub's system flake and rebuild:

```nix
inputs.mynet.url = "git+file:///home/you/mynet";   # or wherever you push it
# ...
modules = [
  (mynet.lib.mkHub {
    privateKeyFile = "/var/lib/torfax-secrets/wg.key";
    users = [ "you" ];
  })
];
```

**4.** Tor creates your onion address on the first start. Put it in
`network.nix` as `hub.onion`:

```sh
sudo cat /var/lib/tor/onion/torfax/hostname
```

Back up `/var/lib/tor/onion/torfax/hs_ed25519_secret_key`: losing it changes
your address and every user has to update. To keep using a backed-up key, pass
`onionSecretKeyFile = "/var/lib/torfax-secrets/hs_ed25519_secret_key";` to
`mkHub`.

**5.** Commit and push the network repo, and give its URL to your users.
`network.nix` holds public information only, but it does reveal your onion
address, so use a private repo if that matters to you.

**To add a user:** take their public key, give them the next free number and
an address in the subnet:

```nix
"0002" = { name = "alice"; address = "10.73.0.2"; publicKey = "..."; };
```

Push, then on the hub run `nix flake update mynet` and rebuild.

## Faxing

```sh
torfax send letter.pdf 0001   # fax a PDF to station 0001
torfax outbox                 # QUEUED, then SUCCESS
torfax inbox                  # faxes you received, as PDFs
```

A station has to be on to receive faxes; otherwise the sender retries a few
times and then gives up.

## If it doesn't connect

- `journalctl -u tor | grep Bootstrapped` should reach 100%.
- `sudo wg show torfax` should show a recent "latest handshake".
- `journalctl -u wstunnel-client-torfax` (users) or
  `journalctl -u wstunnel-server-torfax` (hub) shows the tunnel.
