// Apportion — split a measured byte count across devices, exactly.
//
// Plain C and header-only on purpose: it is the arithmetic the per-device
// figures now stand on, so it has to be testable off the device, and nothing
// about it needs Foundation.

#ifndef HP_APPORTION_H
#define HP_APPORTION_H

#include <stddef.h>
#include <stdint.h>

/// Split `amount` into `n` parts in proportion to `weights`, writing them to
/// `out`. The parts always sum to exactly `amount` — the remainder left by
/// rounding down goes to the largest fractional shares — so a per-device split
/// can never drift away from the total it was cut from.
///
/// When every weight is zero, every part is zero and it returns 0: there is
/// nobody to give the bytes to, and the caller decides what to do with them.
/// Otherwise it returns `amount`.
static inline uint64_t HPApportion(uint64_t amount, const uint64_t *weights,
                                   size_t n, uint64_t *out) {
    unsigned __int128 sum = 0;
    for (size_t i = 0; i < n; i++) {
        out[i] = 0;
        sum += weights[i];
    }
    if (sum == 0 || amount == 0) return 0;

    // 128-bit, because amount * weight overflows 64 bits once both are in the
    // tens of gigabytes.
    uint64_t placed = 0;
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint64_t)(((unsigned __int128)amount * weights[i]) / sum);
        placed += out[i];
    }

    // Fewer than n bytes are left over. Each goes to the largest remaining
    // fraction; a share that already received one is skipped by comparing
    // against the fraction it had, which only ever shrinks once bumped.
    uint64_t left = amount - placed;
    while (left > 0) {
        size_t best = n;
        unsigned __int128 bestFrac = 0;
        for (size_t i = 0; i < n; i++) {
            if (weights[i] == 0) continue;
            unsigned __int128 exact = (unsigned __int128)amount * weights[i];
            unsigned __int128 given = (unsigned __int128)out[i] * sum;
            // Already rounded up: its share is at or past the exact value.
            if (given >= exact) continue;
            unsigned __int128 frac = exact - given;
            if (best == n || frac > bestFrac) {
                best = i;
                bestFrac = frac;
            }
        }
        if (best == n) break;   // cannot happen, but never spin
        out[best]++;
        left--;
    }
    return amount;
}

#endif
