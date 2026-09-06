#!/usr/bin/env python3
# Report and verify the ABI encoding of every slice in a Mach-O file.
#
# WHY THIS EXISTS
#
# `file` cannot see the bug this catches. Asked about a fat tweak dylib built by
# the Linux toolchain it says:
#
#     [arm64:Mach-O 64-bit arm64 ...] [arm64:Mach-O 64-bit arm64 ...]
#
# -- "arm64" for BOTH slices, with no hint that the second one is arm64e, let
# alone that its arm64e encoding is the pre-2021 one that iOS 16.3.1 mis-loads.
#
# THE BUG IT EXISTS FOR (found from crash logs, 2026-09-06, v0.6.6)
#
# ld64-609, the linker in the Theos Linux toolchain, emits arm64e in the legacy
# unversioned ABI: cpusubtype 0x00000002, with the CPU_SUBTYPE_PTRAUTH_ABI bit
# clear. Every real arm64e binary has that bit set -- ElleKit's own
# libinjector.dylib, read off the test device, is cpusubtype 0x80000002, and so
# is PreferenceLoader, which is installed on practically every jailbroken
# device. That bit, not the fixup format, is the defect.
#
# Some dyld builds tolerate the legacy encoding. iOS 16.3.1's does not: binds
# into the dyld shared cache lose their high 32 bits, so a class pointer that
# should read 0x1dac11a30 arrives as 0xdac11a30. That is an unmapped address,
# and the process dies on the first touch:
#
#   Settings     SIGBUS in objc readClass() during map_images, i.e. while dyld
#                is still mapping the tweak -- before any of our code runs
#   SpringBoard  SIGBUS in objc_msgSend called from HPLog, on the isa of a
#                constant string in our own __DATA_CONST
#
# No amount of defensive code in the tweak can help: it is the image itself that
# is wrong. So the encoding is checked here instead, and a bad build is refused.
#
# The development iPhone 8 Plus is A11 -- arm64 -- so it runs the arm64 slice and
# is permanently immune. This check is the only way to see the fault from here.
#
#   ./macho-abi.py FILE|DIR...            # report, exit 1 if any slice is unfit
#   ./macho-abi.py --report FILE|DIR...   # report only, always exit 0
#
# A directory is walked and every Mach-O in it checked; anything that is not a
# Mach-O is passed over. The walking is done here rather than in the shell so
# the caller stays portable: macOS ships bash 3.2, which has no `mapfile`.

import os
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000

LC_SEGMENT_64 = 0x19
LC_BUILD_VERSION = 0x32
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034

# Pointer formats. ARM64E (1) is NOT a defect: PreferenceLoader 2.2.6-1, built
# with an Apple toolchain and installed on practically every jailbroken device,
# is cpusubtype 0x80000002 with format 1 at minos 14.0. The formats worth
# refusing are the ones that are not userland images at all.
POINTER_FORMATS = {
    1: "ARM64E",
    2: "PTR_64",
    3: "PTR_32",
    6: "PTR_64_OFFSET",
    7: "ARM64E_KERNEL",
    9: "ARM64E_USERLAND",
    10: "ARM64E_FIRMWARE",
    12: "ARM64E_USERLAND24",
}
USERLAND_ARM64E_FORMATS = (1, 9, 12)      # ARM64E, ARM64E_USERLAND, ..._24


class Slice(object):
    def __init__(self, cputype, cpusubtype, offset, size):
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.offset = offset
        self.size = size
        self.pointer_formats = []
        self.has_chained_fixups = False
        self.has_dyld_info = False
        self.minos = None
        self.sdk = None

    @property
    def is_arm64e(self):
        return (self.cputype == CPU_TYPE_ARM64
                and (self.cpusubtype & CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E)

    @property
    def is_arm64(self):
        return (self.cputype == CPU_TYPE_ARM64
                and (self.cpusubtype & CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64_ALL)

    @property
    def versioned_ptrauth(self):
        return bool(self.cpusubtype & CPU_SUBTYPE_PTRAUTH_ABI)

    @property
    def arch(self):
        if self.is_arm64e:
            return "arm64e"
        if self.is_arm64:
            return "arm64"
        return "cputype 0x%08x/0x%08x" % (self.cputype, self.cpusubtype)


def read_fat(data):
    """Every slice in the file. A thin Mach-O counts as one slice."""
    if len(data) < 8:
        return []
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        wide = magic == 0xCAFEBABF
        count = struct.unpack(">I", data[4:8])[0]
        entry = 32 if wide else 20
        out = []
        for i in range(count):
            base = 8 + entry * i
            if wide:
                ct, cs, off, size = struct.unpack(">IIQQ", data[base:base + 24])
            else:
                ct, cs, off, size = struct.unpack(">IIII", data[base:base + 16])
            out.append(Slice(ct, cs, off, size))
        return out
    if struct.unpack("<I", data[:4])[0] == 0xFEEDFACF:
        _, ct, cs = struct.unpack("<III", data[:12])
        return [Slice(ct, cs, 0, len(data))]
    return []


def parse_slice(data, sl):
    """Fill in the load-command-derived fields of one slice."""
    m = data[sl.offset:sl.offset + sl.size]
    if len(m) < 32 or struct.unpack("<I", m[:4])[0] != 0xFEEDFACF:
        return
    ncmds = struct.unpack("<I", m[16:20])[0]
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(m):
            return
        cmd, cmdsize = struct.unpack("<II", m[off:off + 8])
        if cmdsize < 8:
            return
        if cmd == LC_DYLD_INFO_ONLY:
            sl.has_dyld_info = True
        elif cmd == LC_BUILD_VERSION:
            _, minos, sdk, _ = struct.unpack("<IIII", m[off + 8:off + 24])
            fmt = lambda v: "%d.%d.%d" % (v >> 16, (v >> 8) & 0xFF, v & 0xFF)
            sl.minos, sl.sdk = fmt(minos), fmt(sdk)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            sl.has_chained_fixups = True
            sl.pointer_formats = chained_pointer_formats(m, off)
        off += cmdsize


def chained_pointer_formats(m, cmd_off):
    """The pointer_format of every segment in LC_DYLD_CHAINED_FIXUPS.

    dyld reads this to decide how to walk the fixup chains, so it is what
    actually decides whether binds land correctly at runtime.
    """
    dataoff, datasize = struct.unpack("<II", m[cmd_off + 8:cmd_off + 16])
    if dataoff + 28 > len(m):
        return []
    starts_offset = struct.unpack("<I", m[dataoff + 4:dataoff + 8])[0]
    base = dataoff + starts_offset
    if base + 4 > len(m):
        return []
    seg_count = struct.unpack("<I", m[base:base + 4])[0]
    if base + 4 + 4 * seg_count > len(m):
        return []
    offsets = struct.unpack("<%dI" % seg_count, m[base + 4:base + 4 + 4 * seg_count])
    formats = []
    for seg_off in offsets:
        if seg_off == 0:                       # segment has no fixups
            continue
        s = base + seg_off
        if s + 22 > len(m):
            continue
        # dyld_chained_starts_in_segment: size, page_size, pointer_format,
        # segment_offset, max_valid_pointer, page_count
        _, _, pointer_format, _, _, _ = struct.unpack("<IHHQIH", m[s:s + 22])
        formats.append(pointer_format)
    return formats


def is_macho(path):
    """Cheap sniff, so walking a package payload skips plists and scripts."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
    except (IOError, OSError):
        return False
    if len(head) < 4:
        return False
    return (struct.unpack(">I", head)[0] in (0xCAFEBABE, 0xCAFEBABF)
            or struct.unpack("<I", head)[0] == 0xFEEDFACF)


def collect(paths):
    """(path, display name) for everything to check, plus any empty dirs."""
    found = []
    empty_dirs = []
    for p in paths:
        if os.path.isdir(p):
            here = []
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    full = os.path.join(root, f)
                    if is_macho(full):
                        here.append((full, os.path.relpath(full, p)))
            if here:
                found += sorted(here, key=lambda t: t[1])
            else:
                empty_dirs.append(p)
        else:
            found.append((p, os.path.basename(p)))
    return found, empty_dirs


def check(path, name):
    """Report one file. Returns a list of failure strings (empty means fit)."""
    with open(path, "rb") as fh:
        data = fh.read()

    slices = read_fat(data)
    if not slices:
        print("  %-26s not a Mach-O, skipped" % name)
        return []

    for sl in slices:
        parse_slice(data, sl)

    fails = []
    print("  %s" % name)

    for sl in slices:
        bits = []
        if sl.is_arm64e:
            bits.append("cpusubtype 0x%08x" % sl.cpusubtype)
            bits.append("ptrauth ABI %s" % ("versioned" if sl.versioned_ptrauth else "LEGACY"))
        if sl.pointer_formats:
            seen = sorted(set(sl.pointer_formats))
            bits.append("fixups " + ", ".join(
                "%d (%s)" % (f, POINTER_FORMATS.get(f, "?")) for f in seen))
        elif sl.has_dyld_info:
            bits.append("classic rebase/bind")
        if sl.minos:
            bits.append("minos %s sdk %s" % (sl.minos, sl.sdk))
        print("    %-8s %s" % (sl.arch, "  ".join(bits)))

    # 1. Both architectures present. arm64 covers A7-A11, arm64e A12 and newer,
    #    whose system processes an arm64-only dylib cannot be injected into.
    if not any(s.is_arm64 for s in slices):
        fails.append("%s: no arm64 slice" % name)
    if not any(s.is_arm64e for s in slices):
        fails.append("%s: no arm64e slice" % name)

    for sl in slices:
        if not sl.is_arm64e:
            continue
        # 2. The versioned ptrauth ABI. Apple's own arm64e binaries and
        #    ElleKit's libinjector.dylib are 0x80000002; ld64-609 emits
        #    0x00000002, which iOS 16.3.1 loads with truncated binds.
        if not sl.versioned_ptrauth:
            fails.append(
                "%s: arm64e slice is the legacy unversioned ptrauth ABI "
                "(cpusubtype 0x%08x, want 0x80000002)" % (name, sl.cpusubtype))
        # 3. A userland chained-fixup encoding. All three userland formats are
        #    fine -- see the note by POINTER_FORMATS -- but a kernel or
        #    firmware format in a tweak means something went badly wrong.
        bad = [f for f in sl.pointer_formats if f not in USERLAND_ARM64E_FORMATS]
        for f in sorted(set(bad)):
            fails.append(
                "%s: arm64e slice uses chained-fixup pointer format %d (%s), "
                "which is not a userland format"
                % (name, f, POINTER_FORMATS.get(f, "?")))

    return fails


def main(argv):
    report_only = "--report" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print("usage: macho-abi.py [--report] FILE|DIR...", file=sys.stderr)
        return 2

    targets, empty_dirs = collect(paths)
    fails = ["%s: no Mach-O binaries found" % d for d in empty_dirs]
    for d in empty_dirs:
        print("  %s: no Mach-O binaries found" % d)

    for path, name in targets:
        try:
            fails += check(path, name)
        except Exception as exc:                # a malformed file is a failure
            print("  %s: could not parse (%s)" % (name, exc))
            fails.append("%s: could not parse (%s)" % (name, exc))

    if fails and not report_only:
        print()
        for f in fails:
            print("FAIL: %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
