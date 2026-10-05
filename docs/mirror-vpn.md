# mirror daily VPN

The daily launchd job at 04:00 runs discovery, fetch and recheck through a
loopback HTTP proxy backed by Proton WireGuard in sing-box. The UI server,
standalone jobs and manual mirror commands retain their existing networking.
The VPN does not change macOS routes or system proxy settings.

## Setup / replace credentials

Download a WireGuard `.conf` from Proton's account page (Free is supported), then:

```sh
mirror-vpn-import /path/to/proton.conf
```

This validates the converted sing-box configuration, writes
`~/.config/mirror/vpn.json` atomically with mode 600, and restarts the VPN agent
if registered. Keep the downloaded `.conf` outside this Git checkout with
mode 600. Neither file belongs in Nix sources or the Nix store.

Build and activate changes using the repository runbook and `./apply`.

## Failure behavior

The daily job checks VPN connectivity before running mirror. Failure exits 75
without starting acquisition. All three steps and their children run under a
Seatbelt profile that permits only the VPN proxy and local PostgreSQL UNIX
socket. Direct IP connections and the system DNS service are blocked; hostname
resolution in sing-box goes to the configured Proton DNS server over WireGuard.
There is no direct outbound in the generated sing-box configuration.

The WireGuard MTU is 1280. With the default MTU, real Python HTTPS requests
timed out in this environment; at 1280, repeated HTTPS checks succeeded.

VPN logs are in `~/Library/Logs/mirror-vpn.log`; daily output remains in
`~/Library/Logs/mirror-daily.log`. Log messages can contain source hostnames.
Do not publish logs or private VPN configuration contents.

## Verification performed

- Full darwin system build and sing-box config validation.
- Direct IPv4/IPv6, other local TCP ports, child-process networking and system
  DNS denied; allowed proxy and a synthetic PostgreSQL-style UNIX socket work.
- Embedded yt-dlp, yt-dlp CLI and ffmpeg use an isolated test HTTP proxy under
  the same network restrictions, with a synthetic audio file.
- Repeated public HTTPS requests through the real Proton tunnel succeed.

Actual source URLs and the mirror database are not used in these tests.
