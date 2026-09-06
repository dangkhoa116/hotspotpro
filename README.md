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

## Changelog

**0.6.7**
- Fixes a crash where Settings would not open and the phone resprang, on some
  devices and iOS versions. The arm64e build carried an ABI marker that newer
  versions of iOS reject; releases are now built with Apple's own linker and
  the binaries are checked before publishing.
- Thanks to @DrAhmedHesham, who independently diagnosed the same cause.

**0.6.6**
- Split into two dylibs, so SpringBoard no longer loads `Preferences.framework`
  or the UI code. A fault in the interface can no longer stop the phone booting.
- Event-driven on a `PF_ROUTE` socket instead of polling on a timer.
- Faster presence: status settles in ~6s, departed devices clear in ~40s.

**0.5.5**
- Per-device limit options are round numbers (100 MB, 250 MB, 500 MB). They
  were decimal fractions of a GB, so they displayed as 102 MB and 256 MB.

**0.5.4**
- Far less background work with the hotspot off: the state file is written only
  when its contents changed (it was rewritten every 10 seconds regardless),
  sampling backs off to once a minute, and the daemon's idle poll went from 5s
  to 15s.

**0.5.3**
- Refuses to install on iOS 18, where it is known to break the Settings app,
  with a runtime gate behind the dependency for anyone who force-installs.

**0.5.2**
- Per-device data limits, device pages, and usage in the stock Personal Hotspot
  pane.

## License

MIT — see [LICENSE](LICENSE).
