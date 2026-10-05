# Wi-Fi: rolling 30-day diagnostics

`services.wifi-monitor.enable = true` in this machine's Home Manager configuration
enables `org.nix-community.home.wifi-monitor`. The module is imported through
`modules/shared-scripts.nix`; the collector source is `scripts/wifi-monitor.py`.

## Operation

- launchd runs one bounded sample every 60 seconds and at login.
- Samples append to compressed hourly files in
  `~/Library/Logs/wifi-monitor/samples-<hour-unix-time>.jsonl.gz`.
  Existing uncompressed samples are preserved until their 30-day expiry.
- Each sample records Wi-Fi interface/IP/DHCP, the default route, DNS settings,
  interface counters, three pings to the Wi-Fi DHCP router, three pings to
  `1.1.1.1` and `8.8.8.8`, a system DNS lookup, and an HTTPS request to Apple's connectivity
  test page. Internet probes follow system routing, including an active VPN;
  router pings are bound to the Wi-Fi interface. Router ARP and the actual
  routes to the router and public probe are recorded. TCP probes to router ports
  80/443 and public port 443 distinguish ICMP silence from broader reachability
  trouble. A refused TCP connection is recorded as a response, not a timeout.
  Separate DNS queries to the router and a public resolver help distinguish
  router DNS problems from system/VPN DNS configuration.
- Relevant macOS `airportd`/`configd` events include signal/noise, rate/retries,
  link changes, private MAC evaluation, and DHCP transitions. Collection windows
  overlap slightly. After a gap, the next query looks back to the previous sample,
  up to 24 hours. Duplicate events can be identified by their original timestamp.
- Every five minutes, `system_profiler` also supplies Wi-Fi details, so missing
  LQM events do not prevent all radio diagnostics. SSID/BSSID may be redacted by
  macOS; a redacted or unavailable name does not mean the Wi-Fi is disconnected.
- Buckets whose samples are all older than 30 days are removed on each run
  (the hourly bucket means at most one extra hour is retained). Sleeping, shutdown, or
  logout creates a measurement gap; expired files are removed at the next run.
  This does not wake the Mac. It cannot reconstruct historical ping results.
- Probe errors/timeouts and truncated event output are recorded explicitly.
  Commands have timeouts; records are atomically replaced; a lock prevents
  concurrent manual/launchd collectors. Files are private to the user.

Normal deployment is the repository's `./apply`. The initial setup on 2026-10-05
instead built and installed **only the Home Manager-generated monitor plist**,
then bootstrapped it into `gui/501`. This avoided activating unrelated work in
progress and needed no administrator password. A GC root at
`~/.local/state/nix/gcroots/wifi-monitor` keeps that initial Nix closure alive.
The next normal Home Manager activation will manage the same agent. The temporary
GC root can then be removed after confirming the agent belongs to that generation.

Inspect status:

```sh
launchctl print "gui/$(id -u)/org.nix-community.home.wifi-monitor"
ls -lt ~/Library/Logs/wifi-monitor/samples-*.jsonl.gz | head
```

After normal activation, `wifi-monitor` takes an immediate extra sample.
`wifi-monitor --summary --hours 720` summarizes 30 days without network requests.
Before the next full system activation, invoke the built executable listed in
the live plist, or use `python3 scripts/wifi-monitor.py --summary --hours 720`. For
development, `python3 scripts/wifi-monitor.py --directory /tmp/wifi-monitor-check`
uses a separate directory.

## Findings on 2026-10-05

Observed on the physical Mac, without changing its Wi-Fi settings:

- `en0`, IPv4 `192.168.10.3`, DHCP router/DNS `192.168.10.1`; 5 GHz channel 40,
  80 MHz, 802.11ac. The current transmit PHY rate was 130 Mbps (not a measured
  application throughput).
- Current signal/noise: approximately -70/-94 dBm. Available LQM records over
  the preceding 24 hours ranged from -76 to -66 dBm and included recurring
  transmit retries. These support investigating radio/link quality; they do not
  prove interference or a defective router.
- Ten router pings: 0% loss, min/average/max 2.858/42.207/102.620 ms. Five external
  pings: 0% loss, min/average/max 16.848/41.491/101.816 ms. HTTPS to Apple succeeded.
  At measurement time, connectivity worked, although latency varied.
- 14:52:30: Wi-Fi link change and DHCP INIT/REBOOT. Router ARP detection received
  no response at 14:52:31.535 and 14:52:33.007. DHCP reached BOUND at 14:52:34.204
  and published success at 14:52:34.869. This documents temporary local router
  reachability/lease re-establishment trouble during reconnection; it does not
  identify the reason for the original slowdown. Transient probing failures
  during reconnection alone are insufficient to establish the root cause.
- The Mac subsequently rebooted around 15:14. Its new connection reached DHCP
  BOUND at 15:14:46 and the connectivity probe succeeded at 15:14:47. Private MAC
  mode/evaluation transitions were also recorded, but their causal role is unknown.
- Tailscale supplemental DNS and tunnel interfaces were present; the IPv4
  default route was Wi-Fi. The evidence does not establish a VPN or DNS fault.

Working hypothesis: unstable quality or state on the Mac-to-access-point path.
Weak signal, airtime contention, access point handling, and Mac radio/driver state
remain candidates. Reconnecting refreshes association, link state and DHCP, so
recovery after reconnecting alone cannot distinguish those causes.

At recurrence, compare the saved timeline **before and after reconnecting**:
router loss plus retries suggests the local Wi-Fi/AP path; healthy router pings
with failing external pings suggests upstream routing/WAN; healthy IP pings with
failing DNS/HTTPS suggests resolver, tunnel or application connectivity. ICMP
may be deprioritized, so ping latency alone is not a conclusive diagnosis.

Apple's guidance on interference and non-disruptive Wireless Diagnostics:

- https://support.apple.com/en-us/102319
- https://support.apple.com/en-gb/guide/mac-help/mchlf4de377f/mac

Validation: Nix formatter on touched Nix files; monitor/agent closure build;
plist syntax validation; real probe sample; retention/offline/timeout checks;
live launchd execution and timed repeat verified during setup.


## Choosing coverage improvements versus replacing the router

- Weak signal/low SNR plus growing retransmissions and loss to the router,
  with improvement when the Mac is near the router: coverage/obstructions or
  radio interference are candidates. Better placement or an additional access
  point can help. A wireless repeater itself needs a healthy upstream signal;
  placing it in the same weak spot can preserve the original bottleneck.
- Healthy radio metrics but router ICMP **and** TCP failures plus ARP/DHCP
  trouble: the local AP/router path or Mac radio/driver state is suspect.
  Another device or a wired test at the same time is needed to distinguish them.
- Router responds but both public targets and public TCP fail: investigate
  router WAN/ISP/VPN routing; buying a repeater would not address that path.
- IP/TCP succeeds but router DNS fails while public DNS succeeds: investigate
  the router DNS service. If both direct resolvers work but the system lookup
  fails, investigate system/VPN resolver configuration.

These are diagnostic comparisons, not automatic hardware-failure verdicts.
A single Mac's log cannot conclusively prove the router is faulty. The practical
comparison is the usual desk versus a location near the router during the same
symptom, and, if possible, another device or a wired connection. RSSI by itself
is insufficient: Cisco lists -70 dBm as around the minimum for reliable packet
transfer in its traditional-network guidance, while stronger requirements apply
for some uses. Current SNR is about 24 dB.

https://www.cisco.com/c/en/us/support/docs/smb/wireless/CB-Wireless-Mesh/1902-tz-Troubleshooting-Traditional-Cisco-Wireless-Network.html

Compression removes repetitive unified-log metadata (stack traces, UUIDs, etc.)
while retaining event timestamps/processes/messages and structured radio metrics.
Thirty-day size estimates are extrapolations from measured compressed samples,
not a fixed storage cap; event volume varies. No packet payloads or browsing
history are captured. Existing older-format logs remain readable by the summary.
