// Tracker — one sample of the world, folded into persisted state.
//
// This is the brain, kept out of both the CLI and the tweak so the two can
// never drift apart: `hotspotpro tick` and the SpringBoard timer call exactly
// the same function.

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, HPTickEvents) {
    HPTickEventNone       = 0,
    HPTickEventWarnFired  = 1 << 0, // crossed the warning threshold, first time
    HPTickEventLimitFired = 1 << 1, // crossed 100% of the limit, first time
    HPTickEventRolledOver = 1 << 2, // the billing period rolled over
    HPTickEventReset      = 1 << 3, // the UI asked for a manual reset
    HPTickEventBlocked    = 1 << 4, // a device crossed its own limit
};

// Keys in the dictionary HPTick() returns.
extern NSString *const HPTickAddedKey;    // NSNumber, bytes added this tick
extern NSString *const HPTickTotalKey;    // NSNumber, period total after the tick
extern NSString *const HPTickEventsKey;   // NSNumber, HPTickEvents bitmask
extern NSString *const HPTickIfNamesKey;  // NSArray, interfaces counted
extern NSString *const HPTickDevicesKey;  // NSArray, devices connected right now
extern NSString *const HPTickBlockedKey;  // NSArray of names newly blocked

/// Take one sample: read counters, fold in the delta, roll the period over if
/// due, refresh the device roster, decide which notifications are owed, and
/// persist. Safe to call from any thread, but only from one at a time.
///
/// Returns nil when the tweak is disabled in config.
NSDictionary *HPTick(void);

/// A human-readable summary of current state, for `hotspotpro status`.
NSString *HPStatusReport(void);

#pragma mark - Per-device attribution (exposed for selftest)

/// How long measured hotspot bytes may wait for the daemon to say whose they
/// were. The daemon flushes every 10s, so a minute is several flushes; bytes
/// still unclaimed after that (no daemon running, say) stay in the hotspot
/// total and are simply not given to any device.
extern const NSTimeInterval HPAttributeWindow;

/// Hand the pooled hotspot bytes to devices in proportion to what the daemon
/// saw each of them move since the last sample (`rawUp`/`rawDown`, MAC ->
/// bytes). Uploads and downloads are split separately.
///
/// The hotspot's own counter (ap1) decides HOW MUCH — it is the one measured to
/// track the cellular uplink. The daemon's tap only decides WHO: it sits on the
/// bridge, which counts forwarded traffic twice, so its raw figures are good
/// for shares and nothing else. The result is that device figures add up to
/// the hotspot total instead of running at a multiple of it.
///
/// A pool is emptied only when there is somebody to give it to; otherwise it is
/// left for the next sample. Each record's bytes stays equal to up + down.
void HPAttributeToDevices(NSMutableDictionary *seen,
                          NSDictionary<NSString *, NSNumber *> *rawUp,
                          NSDictionary<NSString *, NSNumber *> *rawDown,
                          uint64_t *poolUp,
                          uint64_t *poolDown,
                          NSDate *now);

/// One-time repair of figures recorded before 0.7.1, run on the first sample
/// after upgrading. Makes the period's Used equal Downloaded + Uploaded, each
/// device's Total equal its own Downloaded + Uploaded, and scales devices
/// whose sum ran past the hotspot total back to their share of it. Returns YES
/// if it changed anything; a no-op once it has run.
BOOL HPRepairTotals(NSMutableDictionary *state);
