# HotspotPro

Personal Hotspot on iOS tells you almost nothing: no data total, no list of who
is connected, no cap. HotspotPro adds all three to the stock Personal Hotspot
pane in Settings.

- **Data used this period**, with a monthly reset day you choose
- **Who is connected** — name, address, and how much each device has used
- **A limit** that warns you, and **per-device limits** that cut a device off

## Install

Add the repo in Sileo, Zebra or Cydia:

```
https://dangkhoa116.github.io/hotspotpro/
```

Free, and the source is here. Reboot or respring after installing.

## How it works

Three pieces, deliberately kept apart:

| Piece | Runs as | Job |
|---|---|---|
| `HotspotPro.dylib` in SpringBoard | mobile | Samples counters every 10s, keeps the running total, posts warnings |
| `HotspotPro.dylib` in Preferences | mobile | The UI, appended to the stock Personal Hotspot pane |
| `hotspotprod` (LaunchDaemon) | root | Per-device byte counting, and enforcing per-device limits |
| `hotspotpro` (CLI) | mobile | `dump`, `status`, `watch`, `selftest` — the same collector code, runnable by hand |

**Only the SpringBoard collector ever writes the usage totals.** The UI writes
requests and the daemon writes per-device counters; one writer for the totals
means a reset can never race a sample.

### Where the numbers come from

- **Totals** — `sysctl NET_RT_IFLIST2`, which reports 64-bit byte counters.
  Not `getifaddrs()`, whose counters are 32-bit and wrap at 4 GB.
- **Which interface** — `ap1`, the Wi-Fi AP interface, plus `en2` for USB
  tethering. Measured on-device: `bridge100` counts every forwarded packet
  *twice*, so counting the bridge would double your usage.
- **Device names** — `/var/db/dhcpd_leases`, the hotspot's own DHCP records.
- **Who is connected** — the ARP table, filtered to the hotspot subnet.
- **Per-device bytes** — a BPF tap on the tethering bridge with a 14-byte snap
  length, so the kernel copies only each frame's Ethernet header while the
  frame's true length is still counted. Reads are batched; with the hotspot off
  the daemon polls the interface list every 5s and does nothing else.
- **Per-device blocking** — a host reject route for that client. Not pf: there
  is no `pfctl` on iOS to verify hand-built `pf_rule` ioctls against, whereas
  the routing socket needs only the message header the ARP reader already
  proves correct. The daemon refuses any address outside the hotspot's subnet.

## Privacy

Everything stays on the device. Nothing is uploaded anywhere.

The daemon reads packet **headers** on the tethering bridge to attribute bytes
to devices — it captures 14 bytes per frame, which is the Ethernet header, and
never packet contents. It stores client MAC addresses, the names those devices
announce over DHCP, and byte counts, in
`/var/mobile/Library/Caches/hotspotpro-*.plist`. Device records are forgotten
after 45 days. Switching **Track Hotspot Usage** off closes the tap entirely.

## Compatibility

- **Tested on** iOS 16.7.15, iPhone 8 Plus, Dopamine (rootless), ElleKit.
- **Built for** iOS 14+, rootless and rootful, `arm64` and `arm64e`.
- Untested outside the configuration above. Reports welcome.

## Building

Requires [Theos](https://theos.dev). To build both release packages:

```sh
tools/build-release.sh      # rootless + rootful, both architectures, into release/
```

For a single development build, `tools/build.sh`. `tools/repo-publish.sh`
regenerates a local APT repo for testing over the LAN, and `tools/check-fat.sh`
confirms the built binaries really carry both architectures — a tweak that
ships arm64 only links fine and then fails silently on every A12+ device.

### Layout

```
src/       the tweak, the CLI, the daemon, and the collector they share
tools/     build, verification, repo and git scripts
assets/    package icons
layout/    files installed onto the device (DEBIAN scripts, LaunchDaemon)
web/       templates for the repo landing page and depictions
docs/      the generated APT repo, served by GitHub Pages
```

The `Makefile` names sources bare even though they live in `src/`: the build
scripts copy them flat into a Linux-native directory, because Theos on a WSL1
`/mnt/c` path hits permission and symlink problems. Adding `src/` prefixes to
the Makefile would break the build.

## License

MIT — see [LICENSE](LICENSE).
