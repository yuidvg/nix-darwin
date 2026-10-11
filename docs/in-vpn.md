# InVPN

The CLI is provided by the MIT-licensed [yuidvg/in-vpn](https://github.com/yuidvg/in-vpn) product flake, pinned to `v0.1.0` by `flake.lock`. This repository imports `invpn.darwinModules.default` and enables `programs.invpn`.

Build and apply through the usual nix-darwin path:

```sh
nix build .#darwinConfigurations.Yuis-MacBook-Pro.system --no-link --print-out-paths
./apply
/run/current-system/sw/bin/in-vpn --version
/run/current-system/sw/bin/in-vpn capabilities --json
```

The module installs the CLI, Python and sing-box dependencies. It does not activate a VPN or Network Extension. Proxy mode works without the native app. Full isolation is unavailable; default `in-vpn vpn1 command` refuses before executing the command. See the product [capability table](https://github.com/yuidvg/in-vpn#in-vpn).

WireGuard configuration remains outside Git and the Nix store. Existing profiles in `~/Library/Application Support/InVPN/profiles/` remain usable. To add a dedicated profile at runtime:

```sh
in-vpn profiles import vpn1 /path/to/dedicated-WireGuard.conf
in-vpn --mode proxy vpn1 curl --disable https://example.com
in-vpn --mode proxy vpn1 shell
```

On this Mac, an earlier manual installation created `~/.local/bin/in-vpn` and `invpn`. Home Manager now places the managed InVPN package's `bin` directory before that directory on PATH, preserving the manual installation and profiles. After applying and opening a new shell, inspect `whence -a in-vpn invpn` and verify that the Nix store package is selected. Existing shells may retain the old PATH until restarted. No manual links or runtime data are removed by this configuration.

Updating the product is a separate operation: change the product version in `flake.nix`, update only the `invpn` lock input, build and verify before activation. Keep the product's nixpkgs pin rather than following this repository's unrelated dependency updates.
