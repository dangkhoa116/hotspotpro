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
