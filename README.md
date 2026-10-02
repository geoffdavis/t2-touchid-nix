# t2-touchid-nix

Nix flake for [KaiT2en](https://kait2en.org)'s
[`t2-touchid`](https://github.com/kaiT2en/KaiT2en-Fedora/tree/main/t2-services/t2-touchid),
which bridges the Touch ID sensor of Apple T2 Macs to stock `fprintd`, so
login, `sudo` and screen lockers accept a finger enrolled under macOS.

This repo only packages it. The daemon, its protocol work and its design are
KaiT2en's; read [upstream's README](https://github.com/kaiT2en/KaiT2en-Fedora/blob/main/t2-services/t2-touchid/README.md)
for how it works and its limits.

## Requirements

- An x86_64 T2 Mac running NixOS with a T2 kernel that exposes the T2's
  CDC-NCM interface (USB `05ac:8233`, MAC `ac:de:48:00:11:22`), e.g.
  [nixos-hardware's `apple-t2`](https://github.com/NixOS/nixos-hardware/tree/master/apple/t2).
  No KaiT2en kernel modules are needed: the daemon talks to the sensor over
  IPv6 link-local on that interface.
- Fingers enrolled under **macOS**. The daemon never enrolls.
- After the T2 itself loses power, log into macOS once before Touch ID works
  on Linux again (the SEP's before-first-unlock gate). Linux reboots don't
  count.

## Usage

```nix
{
  inputs.t2-touchid.url = "github:geoffdavis/t2-touchid-nix";

  outputs = {nixpkgs, t2-touchid, ...}: {
    nixosConfigurations.my-mac = nixpkgs.lib.nixosSystem {
      modules = [
        t2-touchid.nixosModules.default
        {
          services.t2-touchid = {
            enable = true;
            bindUser = "alice"; # bind the macOS-enrolled fingers to this account
          };
        }
      ];
    };
  };
}
```

Enabling the module:

- runs the bridge as `t2-touchid.service`;
- enables `services.fprintd`, points it at libfprint's virtual device socket,
  and makes it `Requires=` the bridge, so a stopped bridge means "no reader"
  and PAM falls straight through to the password. Note that NixOS turns on
  `fprintAuth` for **every** PAM service when fprintd is enabled; opt services
  out with `security.pam.services.<name>.fprintAuth = false`;
- brings the T2 CDC-NCM link up (link-local only) at boot and whenever it
  reappears, and marks it unmanaged in NetworkManager
  (`manageLink = false` to handle that yourself).

| Option | Default | |
|---|---|---|
| `enable` | `false` | |
| `package` | this flake's | |
| `bindUser` | `null` | Linux account to bind enrolled fingers to on start. `null` = bind by hand: `fprintd-enroll -f <finger>` and one touch. |
| `macosUid` | `"auto"` | macOS uid whose fingers to use; set only if several macOS users have Touch ID. |
| `manageLink` | `true` | Bring the NCM link up and keep NM off it. |

The package (`packages.x86_64-linux.t2-touchid`, or `overlays.default`) also
ships upstream's systemd unit, fprintd drop-in and D-Bus policy for use
outside NixOS.

## Updating

`package.nix` pins an upstream commit. To bump: change `rev`, set `hash` and
`cargoHash` to `lib.fakeHash`, build, and paste the hashes Nix reports.

## License

GPL-3.0-or-later, same as upstream.
