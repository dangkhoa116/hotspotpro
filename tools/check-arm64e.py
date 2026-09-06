#!/usr/bin/env python3
"""Reject legacy arm64e ABI binaries before packaging iOS 14+ tweaks."""
import struct
import sys
from pathlib import Path


def check(path):
    data = Path(path).read_bytes()
    if data[:4] == b'\xca\xfe\xba\xbe':
        count = struct.unpack_from('>I', data, 4)[0]
        slices = [struct.unpack_from('>IIIII', data, 8 + 20 * i)
                  for i in range(count)]
    else:
        raise ValueError('expected a universal Mach-O with arm64 and arm64e')
    found = set()
    for cpu, subtype, offset, size, _ in slices:
        if offset + size > len(data) or size < 32:
            raise ValueError('invalid Mach-O slice bounds')
        magic, actual_cpu, actual_subtype = struct.unpack_from('<III', data, offset)
        if (magic, actual_cpu, actual_subtype) != (0xFEEDFACF, cpu, subtype):
            raise ValueError('fat header and Mach-O slice disagree')
        if cpu == 0x0100000C:
            found.add(subtype & 0x00FFFFFF)
            if subtype & 0x00FFFFFF == 2 and not subtype & 0x80000000:
                raise ValueError('legacy arm64e ABI: rebuild with a modern Apple toolchain; '
                                 'this binary crashes during loading on iOS 14+')
    if not {0, 2}.issubset(found):
        raise ValueError('both arm64 and arm64e slices are required')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('usage: check-arm64e.py binary [...]')
    failed = False
    for name in sys.argv[1:]:
        try:
            check(name)
            print(f'PASS {name}')
        except (OSError, ValueError, struct.error) as error:
            print(f'FAIL {name}: {error}', file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)
