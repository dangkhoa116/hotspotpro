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

Four pieces, deliberately kept apart:

| Piece | Runs as | Job |
|---|---|---|
| `HotspotPro.dylib` in SpringBoard | mobile | Samples counters, keeps the running total, posts warnings |
| `HotspotPro.dylib` in Preferences | mobile | The UI, appended to the stock Personal Hotspot pane |
| `hotspotprod` (LaunchDaemon) | root | Per-device byte counting and per-device blocking |
| `hotspotpro` (CLI) | mobile | `dump`, `status`, `watch`, `selftest` — the shared collector, by hand |

Only the SpringBoard collector writes the usage totals, so a reset can never
race a sample. Totals come from `sysctl NET_RT_IFLIST2` (64-bit byte counters);
device names from the hotspot's own DHCP leases; the connected list from the ARP
table, with a departure judged over a steady four-minute window so a quiet
device doesn't flicker offline. Per-device bytes come from a BPF tap that copies
only each frame's 14-byte Ethernet header, and blocking is a host reject route
for that client — never outside the hotspot's own subnet.

## Privacy

Everything stays on the device; nothing is uploaded. The tap reads packet
**headers** only — 14 bytes per frame, never contents — and stores client MAC
addresses, the names devices announce over DHCP, and byte counts, all forgotten
after 45 days. Switching **Track Hotspot Usage** off closes the tap entirely.

## Compatibility

- **Tested on** iOS 16.7.15, iPhone 8 Plus, Dopamine (rootless), ElleKit.
- **Built for** iOS 14+, rootless and rootful, `arm64` and `arm64e`.
- Untested outside the above. Reports welcome.

## Building

Requires [Theos](https://theos.dev).

```sh
tools/build-release.sh   # both packages, both architectures, into release/
tools/build.sh           # a single development build
```

`tools/check-fat.sh` confirms the binaries carry both architectures — an arm64-only
tweak links fine and then fails silently on every A12+ device.

### Layout

```
src/       the tweak, the CLI, the daemon, and the collector they share
tools/     build, verification, repo and git scripts
assets/    package icons
layout/    files installed onto the device (DEBIAN scripts, LaunchDaemon)
web/       templates for the repo landing page and depictions
docs/      the generated APT repo, served by GitHub Pages
```

## Changelog

**0.6.9**
- Now installs and runs on iOS 18. The crash that made earlier builds unsafe
  there was the arm64e linker marker fixed in 0.6.7, so the install block is
  lifted. Still only tested through iOS 17 — reports from iOS 18 welcome.
- The **Buy Me a Beer 🍺** tip row is back and always shown, linking to Ko-fi.

**0.6.8**
- Connected devices no longer flip between online and offline, or show
  "no devices" while a device is actually connected — presence is judged over a
  steady four-minute window instead of a few seconds.
- Rename a device from its own page; the new name shows in the list right away.
- Per-device limits: a block can no longer get stuck. A device is never left
  without internet after you lift its limit or turn tracking off — the daemon
  clears reject routes on start, on toggle-off, and continuously.
- A device that is over its limit but not actually cut off now says so plainly,
  instead of claiming "Blocked".

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
