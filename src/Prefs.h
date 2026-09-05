// Prefs — on-disk config and persisted state, shared by the CLI and the tweak.
//
// Two files, deliberately separate:
//   config  (user-owned)  /var/mobile/Library/Preferences/com.dangkhoa.hotspotpro.plist
//   state   (tweak-owned) /var/mobile/Library/Caches/hotspotpro-state.plist
//
// Only the collector ever writes state; the Settings UI only reads it. One
// writer means no races and no lost bytes.

#import <Foundation/Foundation.h>

#pragma mark - Paths

NSString *HPConfigPath(void);
NSString *HPStatePath(void);
NSString *HPLogPath(void);

#pragma mark - Config

// Config keys, all optional — HPConfig() applies defaults.
extern NSString *const HPCfgEnabledKey;     // BOOL,   default YES
extern NSString *const HPCfgLimitGBKey;     // double, default 0 (= no limit)
extern NSString *const HPCfgResetDayKey;    // int 1-31, default 1
extern NSString *const HPCfgWarnPercentKey; // int,    default 80
extern NSString *const HPCfgNicknamesKey;   // dict mac -> user-set name
extern NSString *const HPCfgDeviceLimitsKey;// dict mac -> GB (double), per device

/// Devices the collector has decided are over their own limit, written for the
/// root daemon to enforce. The daemon is the only thing that can install a
/// route, and the collector is the only thing that knows the period totals.
NSString *HPBlocklistPath(void);

/// Current config with defaults filled in. Re-read from disk each call: cheap,
/// and it means an edit from Settings is picked up without any invalidation.
NSDictionary *HPConfig(void);

/// Darwin notification posted when the config changes, so the collector can
/// re-read without polling the file.
extern NSString *const HPPrefsChangedNotification;

/// Name of the "take a sample right now" notification. The UI writes a request
/// into the state file and posts this; the collector — still the only writer of
/// the totals — acts on it immediately instead of at its next 10s tick.
extern const char *const HPTickRequestNotification;

/// Ask the collector to sample immediately.
void HPPostTickRequest(void);

#pragma mark - State

extern NSString *const HPStTotalBytesKey;   // unsigned long long, this period
extern NSString *const HPStPeriodStartKey;  // NSDate
extern NSString *const HPStNextResetKey;    // NSDate
extern NSString *const HPStLastRawKey;      // dict ifname -> {i, o}
extern NSString *const HPStBaselinedKey;    // BOOL, first run has happened
extern NSString *const HPStLastDevRawKey;   // dict mac -> cumulative daemon bytes
extern NSString *const HPStDevBaselinedKey; // BOOL, daemon counters baselined
extern NSString *const HPStWarnFiredKey;    // BOOL, warning shown this period
extern NSString *const HPStLimitFiredKey;   // BOOL, limit alert shown this period
extern NSString *const HPStHistoryKey;      // array of past periods
extern NSString *const HPStDevicesSeenKey;  // dict mac -> {name, first, last}
extern NSString *const HPStDevicesNowKey;   // array of connected devices
extern NSString *const HPStUpdatedKey;      // NSDate of last sample
extern NSString *const HPStIfNamesKey;      // array, interfaces being counted
extern NSString *const HPStBlockedMacsKey;  // array of MACs over their own limit
extern NSString *const HPStResetRequestKey; // BOOL, set by the UI, consumed by
                                            // the collector — the UI never
                                            // mutates the totals itself

NSMutableDictionary *HPStateLoad(void);

/// Atomic write (temp file + rename), so a respring mid-write cannot leave a
/// truncated state file behind.
BOOL HPStateSave(NSDictionary *state);

#pragma mark - Period maths

/// The next reset boundary strictly after `date`, for a monthly cycle that
/// rolls over on `day`. Days past the end of a short month clamp to its last
/// day, so resetDay=31 still fires in February.
NSDate *HPNextResetDate(NSDate *date, NSInteger day);

/// The reset boundary at or before `date` — i.e. when the current period began.
NSDate *HPPeriodStartDate(NSDate *date, NSInteger day);

#pragma mark - Logging

/// Appends to HPLogPath(). The file is the reliable channel: get_syslog is a
/// forward-looking capture that misses anything logged before it attaches.
void HPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
