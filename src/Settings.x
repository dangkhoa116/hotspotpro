// HotspotPro — the Settings half.
//
// Injected ONLY into com.apple.Preferences: the extra groups appended to the
// stock Personal Hotspot pane, plus our own usage and per-device panes. Every
// getter reads the state the SpringBoard collector wrote and every setter
// writes config — the UI never computes a total and never mutates one, so a
// reset can never race a sample.
//
// This is the half that links Preferences.framework, and keeping it out of
// SpringBoard is the whole point of the split. See SpringBoard.x.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <notify.h>
#import "Collector.h"
#import "Prefs.h"
#import "Tracker.h"
#import "PSHeaders.h"
#pragma mark - Settings helper (Preferences)

/// How many disconnected devices the pane will list. iOS caps concurrent
/// hotspot clients at a handful, but the historical list is unbounded.
static const NSUInteger kHPMaxOfflineRows = 6;

/// Tip jar. The link comes from `donate-url.txt`, which the build scripts turn
/// into DonateURL.h, so changing it never means editing code. While it is empty
/// the row is not shown at all — an unconfigured build never presents a button
/// that goes nowhere.
#if __has_include("DonateURL.h")
#import "DonateURL.h"
#endif
#ifndef HP_DONATE_URL
#define HP_DONATE_URL ""
#endif
static NSString *const kHPDonateURL = @HP_DONATE_URL;

static NSArray *HPBuildDeviceRows(void);
static void HPReloadValues(PSListController *pane);

/// The usage pane while it is on screen, so an action can refresh its rows.
static __weak PSListController *gUsagePaneRef;

/// Target object for our specifiers: every getter reads the state file the
/// collector wrote, every setter writes config. The UI never computes a total
/// and never mutates one — one writer, no races.
@interface HPSettingsHelper : NSObject
@property (nonatomic, copy) NSString *lastStructure;
@property (nonatomic, copy) NSString *lastValues;
+ (instancetype)shared;
- (void)setResetDayValue:(id)value specifier:(PSSpecifier *)spec;
- (void)performReset;
- (void)openDonateLink:(PSSpecifier *)spec;
@end

@implementation HPSettingsHelper

static HPSettingsHelper *gHelper;

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gHelper = [HPSettingsHelper new]; });
    return gHelper;
}

#pragma mark Config setters

- (void)writeConfigValue:(id)value forKey:(NSString *)key {
    NSMutableDictionary *cfg =
        [([NSDictionary dictionaryWithContentsOfFile:HPConfigPath()] ?: @{}) mutableCopy];
    cfg[key] = value;
    [cfg writeToFile:HPConfigPath() atomically:YES];
}

- (id)enabledValue:(PSSpecifier *)spec { return HPConfig()[HPCfgEnabledKey]; }
- (void)setEnabledValue:(id)value specifier:(PSSpecifier *)spec {
    [self writeConfigValue:@([value boolValue]) forKey:HPCfgEnabledKey];
}

// These three back PSLinkListCells, so they trade in the NSNumbers listed as
// that row's valid values, not in typed strings.
- (id)limitValue:(PSSpecifier *)spec {
    return @([HPConfig()[HPCfgLimitGBKey] doubleValue]);
}
- (void)setLimitValue:(id)value specifier:(PSSpecifier *)spec {
    [self writeConfigValue:@([value doubleValue]) forKey:HPCfgLimitGBKey];
}

- (id)warnValue:(PSSpecifier *)spec {
    return @([HPConfig()[HPCfgWarnPercentKey] integerValue]);
}
- (void)setWarnValue:(id)value specifier:(PSSpecifier *)spec {
    NSInteger v = MAX(1, MIN(100, [value integerValue]));
    [self writeConfigValue:@(v) forKey:HPCfgWarnPercentKey];
}

- (id)resetDayValue:(PSSpecifier *)spec {
    return @([HPConfig()[HPCfgResetDayKey] integerValue]);
}
- (void)setResetDayValue:(id)value specifier:(PSSpecifier *)spec {
    NSInteger v = MAX(1, MIN(31, [value integerValue]));
    [self writeConfigValue:@(v) forKey:HPCfgResetDayKey];
}

#pragma mark Stat getters

- (id)usedValue:(PSSpecifier *)spec {
    NSDictionary *state = HPStateLoad();
    return HPFormatBytes([state[HPStTotalBytesKey] unsignedLongLongValue]);
}

- (id)remainingValue:(PSSpecifier *)spec {
    NSDictionary *state = HPStateLoad();
    double limitGB = [HPConfig()[HPCfgLimitGBKey] doubleValue];
    if (limitGB <= 0) return @"No limit";

    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];
    uint64_t limit = (uint64_t)(limitGB * 1024.0 * 1024.0 * 1024.0);
    if (total >= limit) return @"Over limit";
    return [NSString stringWithFormat:@"%@ (%.0f%% used)",
                                      HPFormatBytes(limit - total),
                                      100.0 * total / (double)limit];
}

- (id)resetsValue:(PSSpecifier *)spec {
    NSDictionary *state = HPStateLoad();
    NSDate *next = state[HPStNextResetKey];
    if (!next) return @"—";

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateStyle = NSDateFormatterMediumStyle;
    fmt.timeStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:next];
}

/// Who is connected, read live rather than from the state file.
///
/// The state file is written by the collector, which samples lazily while the
/// hotspot is off, so a list read from it could sit up to a minute behind —
/// devices stayed on screen long after the hotspot was switched off. Two sysctl
/// walks while a pane is actually on screen cost almost nothing, and this is the
/// same reasoning that already applies to the status row below.
///
/// Byte totals still come from the state file: those are the collector's to
/// compute, and only presence needs to be current.
static NSArray *HPLiveConnectedDevices(void) {
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    return HPCopyConnectedDevices(HPHotspotInterfaceNames(ifaces)) ?: @[];
}

/// "Is the hotspot on", smoothed.
///
/// Even with IP forwarding as the primary signal, a status row that samples
/// every 3s will eventually catch a transient and flip. Once seen active, the
/// hotspot is reported active for a few more seconds, so a blip cannot flip the
/// row — at the cost of the row lagging a few seconds behind switching off.
static BOOL HPHotspotIsActiveSmoothed(NSArray<NSDictionary *> *ifaces) {
    static NSDate *lastActive;
    static int offRuns = 0;
    static const int kOffRunsNeeded = 2;      // ignore a single blip, not fifteen seconds of them
    static const NSTimeInterval kMaxHold = 8.0;

    if (HPHotspotIsActive(ifaces)) {
        lastActive = [NSDate date];
        offRuns = 0;
        return YES;
    }

    // Never seen active, or last seen active a while ago: answer immediately.
    // Without this the row would claim "on" for its first couple of refreshes
    // every time the pane is opened with the hotspot already off.
    if (!lastActive) return NO;
    if ([[NSDate date] timeIntervalSinceDate:lastActive] >= kMaxHold) return NO;

    // Suppressing a transient needs one contradicting sample, not a fixed
    // wall-clock hold. At the pane's 3s refresh this reports "off" a few
    // seconds after the switch is flipped rather than fifteen.
    if (offRuns < kOffRunsNeeded) {
        offRuns++;
        return YES;
    }
    return NO;
}

/// Read live rather than from the state file. The collector samples every 10s,
/// so a state-file answer could claim the hotspot was off for ten seconds after
/// it was switched on — which is exactly when someone is looking at this row.
- (id)statusValue:(PSSpecifier *)spec {
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    if (!HPHotspotIsActiveSmoothed(ifaces)) return @"Hotspot off";

    NSUInteger count = HPCopyConnectedDevices(HPHotspotInterfaceNames(ifaces)).count;
    if (count == 0) return @"On · no devices";
    return count == 1 ? @"1 device connected"
                      : [NSString stringWithFormat:@"%lu devices connected",
                                                   (unsigned long)count];
}

/// One device row's value: how much it used this period, and its address.
///
/// The byte figure is looked up live by MAC rather than captured when the row
/// was built, so a plain value refresh keeps it current without the row having
/// to be rebuilt.
- (id)deviceValue:(PSSpecifier *)spec {
    NSString *ip = [spec propertyForKey:@"hpIP"] ?: @"?";
    NSString *mac = [spec propertyForKey:@"hpMac"];
    if (!mac.length) return ip;

    NSDictionary *seen = HPStateLoad()[HPStDevicesSeenKey] ?: @{};
    uint64_t bytes = [seen[mac][@"bytes"] unsignedLongLongValue];
    if (bytes == 0) return ip;
    return [NSString stringWithFormat:@"%@ · %@", HPFormatBytes(bytes), ip];
}

- (id)seenValue:(PSSpecifier *)spec {
    NSDictionary *seen = HPStateLoad()[HPStDevicesSeenKey] ?: @{};
    NSUInteger withUsage = 0;
    for (NSString *mac in seen) {
        if ([seen[mac][@"bytes"] unsignedLongLongValue] > 0) withUsage++;
    }
    // Says so explicitly when the list above is only part of the story.
    if (withUsage > kHPMaxOfflineRows) {
        return [NSString stringWithFormat:@"%lu (top %lu shown)",
                                          (unsigned long)seen.count,
                                          (unsigned long)kHPMaxOfflineRows];
    }
    return [NSString stringWithFormat:@"%lu", (unsigned long)seen.count];
}

/// The one line the stock Personal Hotspot pane shows: usage at a glance, with
/// everything else behind the disclosure.
- (id)summaryValue:(PSSpecifier *)spec {
    NSDictionary *state = HPStateLoad();
    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    NSUInteger devices = HPCopyConnectedDevices(HPHotspotInterfaceNames(ifaces)).count;

    NSString *summary;
    if (devices > 0) {
        summary = [NSString stringWithFormat:@"%@ · %lu %@", HPFormatBytes(total),
                                             (unsigned long)devices,
                                             devices == 1 ? @"device" : @"devices"];
    } else {
        summary = HPFormatBytes(total);
    }

    // A PSLinkCell does not reliably show a getter's return value, so the same
    // string is also written to the specifier's own value property. Whichever
    // mechanism the cell honours, the row shows the figure.
    [spec setProperty:summary forKey:@"value"];
    return summary;
}

/// Resetting throws away the period's totals, so it asks first.
- (void)resetNow:(PSSpecifier *)spec {
    PSListController *pane = gUsagePaneRef;
    if (!pane) {           // no pane to present from; do as asked
        [self performReset];
        return;
    }

    NSDictionary *state = HPStateLoad();
    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Usage?"
                         message:[NSString stringWithFormat:
                                     @"This clears the %@ recorded this period and "
                                      "every device's figure, and starts a new period "
                                      "today. It cannot be undone.",
                                     HPFormatBytes(total)]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self performReset];
    }]];

    [pane presentViewController:alert animated:YES completion:nil];
}

- (void)openDonateLink:(PSSpecifier *)spec {
    @try {
        NSURL *url = [NSURL URLWithString:kHPDonateURL];
        if (!url) return;
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } @catch (NSException *e) {
        HPLog(@"donate link failed: %@", e);
    }
}

- (void)performReset {
    NSMutableDictionary *state = HPStateLoad();
    state[HPStResetRequestKey] = @YES;
    HPStateSave(state);
    HPLog(@"reset requested from Settings");

    // Wake the collector instead of waiting out its 10s tick, then pull the
    // rows once it has written, so the zero appears while the finger is still
    // on the screen. The collector stays the only writer of the totals.
    HPPostTickRequest();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HPReloadValues(gUsagePaneRef);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HPReloadValues(gUsagePaneRef);
    });
}

/// Which ROWS the pane needs — device list membership, nothing else.
///
/// Only a change here justifies rebuilding the block of specifiers. The first
/// version folded the byte total into this signature, so while data was flowing
/// the total changed every 10s and the pane tore itself down and rebuilt every
/// few seconds: visibly reloading, losing scroll position, and interrupting
/// anything being typed.
- (NSString *)structureSignature {
    NSDictionary *state = HPStateLoad();
    NSMutableString *sig = [NSMutableString string];

    // Toggling tracking adds or removes every row below the switch.
    [sig appendFormat:@"%d|", [HPConfig()[HPCfgEnabledKey] boolValue]];

    // Live, matching what the rows are built from. Read from the state file
    // instead, this signature would not change when a device left, so the rows
    // would never be rebuilt and the departed device would stay on screen.
    for (NSDictionary *d in HPLiveConnectedDevices()) {
        [sig appendFormat:@"%@,", d[HPDevMacKey]];
    }
    [sig appendString:@"|"];

    // Offline devices with usage get a row too, so they belong here.
    NSDictionary *seen = state[HPStDevicesSeenKey] ?: @{};
    for (NSString *mac in [seen.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([seen[mac][@"bytes"] unsignedLongLongValue] > 0) [sig appendFormat:@"%@,", mac];
    }
    return sig;
}

/// What the existing rows DISPLAY. A change here only needs the value cells
/// re-read through their getters, which is invisible next to a rebuild.
- (NSString *)valueSignature {
    NSDictionary *state = HPStateLoad();
    NSMutableString *sig = [NSMutableString string];
    [sig appendFormat:@"%@|%@|", state[HPStTotalBytesKey], state[HPStIfNamesKey]];

    // The status row is computed live, so its inputs belong in the signature —
    // otherwise switching the hotspot on would not refresh the row until some
    // byte total happened to change.
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    [sig appendFormat:@"%d|%lu|", (int)HPHotspotIsActiveSmoothed(ifaces),
                      (unsigned long)HPCopyConnectedDevices(
                          HPHotspotInterfaceNames(ifaces)).count];

    NSDictionary *seen = state[HPStDevicesSeenKey] ?: @{};
    for (NSString *mac in [seen.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [sig appendFormat:@"%@:%@,", mac, seen[mac][@"bytes"]];
    }
    return sig;
}

@end

#pragma mark - Specifier construction

static PSSpecifier *HPGroup(NSString *title, NSString *footer) {
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:title
                                                        target:nil
                                                           set:NULL
                                                           get:NULL
                                                        detail:nil
                                                          cell:PSGroupCell
                                                          edit:nil];
    if (footer) [group setProperty:footer forKey:@"footerText"];
    [group setProperty:@YES forKey:@"hpOurs"];
    return group;
}

static PSSpecifier *HPValueRow(NSString *title, SEL getter) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                       target:[HPSettingsHelper shared]
                                                          set:NULL
                                                          get:getter
                                                       detail:nil
                                                         cell:PSTitleValueCell
                                                         edit:nil];
    [spec setProperty:@YES forKey:@"hpOurs"];
    [spec setProperty:@YES forKey:@"hpValueRow"]; // refreshed in place, not rebuilt
    [spec setProperty:@NO forKey:@"enabled"];     // display only, not tappable
    return spec;
}

/// A native picker row: right-aligned value plus chevron, tapping opens a
/// checklist. Replaces the numeric text fields, which looked like a form.
static PSSpecifier *HPChoiceRow(NSString *title, SEL getter, SEL setter,
                                NSArray *values, NSArray *titles) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                       target:[HPSettingsHelper shared]
                                                          set:setter
                                                          get:getter
                                                       detail:[PSListItemsController class]
                                                         cell:PSLinkListCell
                                                         edit:nil];
    [spec setProperty:@YES forKey:@"hpOurs"];
    [spec setProperty:@YES forKey:@"hpValueRow"];
    [spec setValues:values titles:titles];
    return spec;
}

static PSSpecifier *HPLimitRow(void) {
    NSMutableArray *values =
        [@[ @0, @1, @2, @3, @5, @10, @15, @20, @30, @50, @100 ] mutableCopy];

    // A limit set before this row became a picker (or edited in the plist by
    // hand) must still appear, or its row would show no selection at all.
    double current = [HPConfig()[HPCfgLimitGBKey] doubleValue];
    BOOL listed = NO;
    for (NSNumber *v in values) {
        if (fabs(v.doubleValue - current) < 0.0001) { listed = YES; break; }
    }
    if (!listed && current > 0) {
        [values addObject:@(current)];
        [values sortUsingSelector:@selector(compare:)];
    }

    NSMutableArray *titles = [NSMutableArray array];
    for (NSNumber *v in values) {
        [titles addObject:v.doubleValue == 0
                              ? @"No Limit"
                              : [NSString stringWithFormat:@"%g GB", v.doubleValue]];
    }
    return HPChoiceRow(@"Data Limit", @selector(limitValue:),
                       @selector(setLimitValue:specifier:), values, titles);
}

static PSSpecifier *HPWarnRow(void) {
    NSArray *values = @[ @50, @60, @70, @75, @80, @85, @90, @95 ];
    NSMutableArray *titles = [NSMutableArray array];
    for (NSNumber *v in values) {
        [titles addObject:[NSString stringWithFormat:@"%@%% of limit", v]];
    }
    return HPChoiceRow(@"Warn Me At", @selector(warnValue:),
                       @selector(setWarnValue:specifier:), values, titles);
}

static NSString *HPOrdinalDay(NSInteger day) {
    NSString *suffix = @"th";
    if (day % 100 < 11 || day % 100 > 13) {
        if (day % 10 == 1) suffix = @"st";
        else if (day % 10 == 2) suffix = @"nd";
        else if (day % 10 == 3) suffix = @"rd";
    }
    return [NSString stringWithFormat:@"%ld%@", (long)day, suffix];
}

/// Reset day as a checklist, the same shape as the other two settings.
///
/// An inline UIPickerView wheel was tried and reverted: the framework ignored
/// both documented ways of setting a row's height, and the row swallowed its
/// own tap, so it took custom table-delegate overrides to do what a plain list
/// does correctly for free.
static PSSpecifier *HPResetDayRow(void) {
    NSMutableArray *values = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    for (NSInteger day = 1; day <= 31; day++) {
        [values addObject:@(day)];
        [titles addObject:HPOrdinalDay(day)];
    }
    return HPChoiceRow(@"Reset Day", @selector(resetDayValue:),
                       @selector(setResetDayValue:specifier:), values, titles);
}

static NSArray *HPBuildBodySpecifiers(void);

/// The whole usage pane. The tracking switch comes first and governs the rest:
/// with it off there is nothing below it, because "off" should mean off rather
/// than a screenful of frozen numbers.
static NSArray *HPBuildSpecifiers(void) {
    HPSettingsHelper *helper = [HPSettingsHelper shared];
    NSMutableArray *specs = [NSMutableArray array];

    [specs addObject:HPGroup(nil,
                             @"Counts the data your hotspot shares, lists who is "
                              "connected, and warns you at a limit you choose. "
                              "Switching this off stops the counting and closes the "
                              "background tap; totals already recorded are kept.")];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"Track Hotspot Usage"
                                                          target:helper
                                                             set:@selector(setEnabledValue:specifier:)
                                                             get:@selector(enabledValue:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
    [enabled setProperty:@YES forKey:@"hpOurs"];
    [specs addObject:enabled];

    if ([HPConfig()[HPCfgEnabledKey] boolValue]) {
        [specs addObjectsFromArray:HPBuildBodySpecifiers()];
    }
    return specs;
}

/// Everything the tracking switch governs.
static NSArray *HPBuildBodySpecifiers(void) {
    HPSettingsHelper *helper = [HPSettingsHelper shared];
    NSMutableArray *specs = [NSMutableArray array];
    // No state read here any more: every value row fetches its own through a
    // getter, and the device list is now read live.

    // --- usage ------------------------------------------------------------
    [specs addObject:HPGroup(@"THIS PERIOD", nil)];
    [specs addObject:HPValueRow(@"Used", @selector(usedValue:))];
    [specs addObject:HPValueRow(@"Remaining", @selector(remainingValue:))];
    [specs addObject:HPValueRow(@"Resets On", @selector(resetsValue:))];
    [specs addObject:HPValueRow(@"Hotspot", @selector(statusValue:))];

    // --- devices ----------------------------------------------------------
    NSArray *devices = HPLiveConnectedDevices();
    PSSpecifier *devicesGroup =
        HPGroup(@"CONNECTED DEVICES",
                devices.count ? nil : @"No devices are connected right now.");
    [devicesGroup setProperty:@YES forKey:@"hpDevicesGroup"];
    [specs addObject:devicesGroup];
    [specs addObjectsFromArray:HPBuildDeviceRows()];
    [specs addObject:HPValueRow(@"Seen this period", @selector(seenValue:))];

    // --- limit ------------------------------------------------------------
    [specs addObject:HPGroup(@"DATA LIMIT",
                             @"A soft limit. HotspotPro warns you when you reach it "
                              "and never switches Personal Hotspot off.")];

    [specs addObject:HPLimitRow()];
    [specs addObject:HPWarnRow()];

    // --- billing period ---------------------------------------------------
    // The chosen day goes in the footer, which always renders, so the setting
    // is readable whether or not the wheel is open.
    [specs addObject:HPGroup(@"BILLING PERIOD",
                             @"Usage clears automatically on this day each month. "
                              "Months without that day reset on their last day.")];
    [specs addObject:HPResetDayRow()];

    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"Reset Usage Now"
                                                        target:helper
                                                           set:NULL
                                                           get:NULL
                                                        detail:nil
                                                          cell:PSButtonCell
                                                          edit:nil];
    [reset setProperty:@YES forKey:@"hpOurs"];
    [reset setTarget:helper];
    [reset setButtonAction:@selector(resetNow:)];
    [specs addObject:reset];

    // --- tip jar ----------------------------------------------------------
    // Free tweak, no paywall, no nag: one row at the very bottom, and none at
    // all in a build with no link configured.
    if (kHPDonateURL.length) {
        [specs addObject:HPGroup(nil,
                                 @"HotspotPro is free and open source. If it saved "
                                  "you an argument about who used all the data, a "
                                  "beer is always welcome.")];

        PSSpecifier *donate = [PSSpecifier preferenceSpecifierNamed:@"Buy Me a Beer 🍺"
                                                             target:helper
                                                                set:NULL
                                                                get:NULL
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
        [donate setProperty:@YES forKey:@"hpOurs"];
        [donate setTarget:helper];
        [donate setButtonAction:@selector(openDonateLink:)];
        [specs addObject:donate];
    }

    // Tag everything the switch governs, so it can be pulled out and put back
    // in one move when tracking is toggled.
    for (PSSpecifier *spec in specs) [spec setProperty:@YES forKey:@"hpBody"];
    return specs;
}

#pragma mark - Per-device pane

/// One device's own page: what it has used, and a cap that cuts it off.
@interface HPDeviceListController : PSListController
@end

@implementation HPDeviceListController {
    NSArray *_hpSpecs;
    NSString *_mac;
}

- (NSString *)hpMac {
    if (!_mac) _mac = [[self specifier] propertyForKey:@"hpMac"] ?: @"";
    return _mac;
}

- (id)hpDeviceLimit:(PSSpecifier *)spec {
    NSDictionary *limits = HPConfig()[HPCfgDeviceLimitsKey];
    return @([limits[[self hpMac]] doubleValue]);
}

- (void)setHpDeviceLimit:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg =
        [([NSDictionary dictionaryWithContentsOfFile:HPConfigPath()] ?: @{}) mutableCopy];
    NSMutableDictionary *limits = [(cfg[HPCfgDeviceLimitsKey] ?: @{}) mutableCopy];

    double gb = [value doubleValue];
    if (gb > 0) {
        limits[[self hpMac]] = @(gb);
    } else {
        // "No limit" also lifts a block, because the device is no longer over
        // anything — that is the way back for a device you cut off.
        [limits removeObjectForKey:[self hpMac]];
    }
    cfg[HPCfgDeviceLimitsKey] = limits;
    [cfg writeToFile:HPConfigPath() atomically:YES];

    // Apply now rather than at the next tick, so a device is released the
    // moment its limit is lifted.
    HPPostTickRequest();
}

- (id)hpUsedValue:(PSSpecifier *)spec {
    NSDictionary *seen = HPStateLoad()[HPStDevicesSeenKey] ?: @{};
    return HPFormatBytes([seen[[self hpMac]][@"bytes"] unsignedLongLongValue]);
}

- (id)hpStatusValue:(PSSpecifier *)spec {
    NSArray *blocked = HPStateLoad()[HPStBlockedMacsKey] ?: @[];
    if ([blocked containsObject:[self hpMac]]) return @"Blocked — over its limit";

    double limit = [HPConfig()[HPCfgDeviceLimitsKey][[self hpMac]] doubleValue];
    return limit > 0 ? @"Allowed" : @"No limit set";
}

- (id)hpAddressValue:(PSSpecifier *)spec {
    NSDictionary *seen = HPStateLoad()[HPStDevicesSeenKey] ?: @{};
    return seen[[self hpMac]][@"ip"] ?: @"—";
}

- (NSArray *)specifiers {
    @try {
        NSArray *existing = [self valueForKey:@"_specifiers"];
        if (existing.count) return existing;
    } @catch (NSException *e) {
        if (_hpSpecs) return _hpSpecs;
    }

    NSMutableArray *specs = [NSMutableArray array];

    [specs addObject:HPGroup(@"THIS PERIOD", nil)];
    PSSpecifier *used = [PSSpecifier preferenceSpecifierNamed:@"Used"
                                                       target:self
                                                          set:NULL
                                                          get:@selector(hpUsedValue:)
                                                       detail:nil
                                                         cell:PSTitleValueCell
                                                         edit:nil];
    [used setProperty:@NO forKey:@"enabled"];
    [specs addObject:used];

    PSSpecifier *address = [PSSpecifier preferenceSpecifierNamed:@"Address"
                                                          target:self
                                                             set:NULL
                                                             get:@selector(hpAddressValue:)
                                                          detail:nil
                                                            cell:PSTitleValueCell
                                                            edit:nil];
    [address setProperty:@NO forKey:@"enabled"];
    [specs addObject:address];

    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"Status"
                                                         target:self
                                                            set:NULL
                                                            get:@selector(hpStatusValue:)
                                                         detail:nil
                                                           cell:PSTitleValueCell
                                                           edit:nil];
    [status setProperty:@NO forKey:@"enabled"];
    [specs addObject:status];

    [specs addObject:HPGroup(@"DEVICE LIMIT",
                             @"When this device passes its limit, the hotspot stops "
                              "routing to it until the period resets or you set the "
                              "limit back to No Limit. Other devices are unaffected.")];

    // Values are GB, but the sub-1 GB steps are exact binary fractions rather
    // than decimal ones so their labels land on round numbers: 0.1 GB rendered
    // as "102 MB" read like a bug, whereas 100/1024 GB is exactly 100 MB. All
    // three divide by a power of two, so the multiplication below is exact.
    NSMutableArray *values = [@[ @0, @(100 / 1024.0), @(250 / 1024.0), @(500 / 1024.0),
                                 @1, @2, @3, @5, @10, @20 ] mutableCopy];

    // A limit stored under the old values (0.1 GB and friends) must still be
    // listed, or an already-limited device would open to a row with nothing
    // selected and silently lose its limit on the next tap.
    double current = [HPConfig()[HPCfgDeviceLimitsKey][[self hpMac]] doubleValue];
    BOOL listed = NO;
    for (NSNumber *v in values) {
        if (fabs(v.doubleValue - current) < 1e-9) { listed = YES; break; }
    }
    if (!listed && current > 0) {
        [values addObject:@(current)];
        [values sortUsingSelector:@selector(compare:)];
    }

    NSMutableArray *titles = [NSMutableArray array];
    for (NSNumber *v in values) {
        double gb = v.doubleValue;
        if (gb == 0) [titles addObject:@"No Limit"];
        else if (gb < 1) [titles addObject:[NSString stringWithFormat:@"%.0f MB", gb * 1024]];
        else [titles addObject:[NSString stringWithFormat:@"%g GB", gb]];
    }

    PSSpecifier *limit = [PSSpecifier preferenceSpecifierNamed:@"Data Limit"
                                                        target:self
                                                           set:@selector(setHpDeviceLimit:specifier:)
                                                           get:@selector(hpDeviceLimit:)
                                                        detail:[PSListItemsController class]
                                                          cell:PSLinkListCell
                                                          edit:nil];
    [limit setValues:values titles:titles];
    [specs addObject:limit];

    _hpSpecs = specs;
    @try {
        [self setValue:specs forKey:@"_specifiers"];
    } @catch (NSException *e) {}
    return specs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        NSDictionary *seen = HPStateLoad()[HPStDevicesSeenKey] ?: @{};
        self.title = seen[[self hpMac]][@"name"] ?: [self hpMac];
    } @catch (NSException *e) {}
}

@end

/// Just the device rows — the only part of the pane whose SHAPE changes as
/// clients come and go, so it is the only part ever rebuilt.
static NSArray *HPBuildDeviceRows(void) {
    HPSettingsHelper *helper = [HPSettingsHelper shared];
    NSDictionary *state = HPStateLoad();
    NSMutableArray *specs = [NSMutableArray array];
    NSArray *devices = HPLiveConnectedDevices();

    for (NSDictionary *dev in devices) {
        // Built with a getter like every other value row, rather than a static
        // "value" property, which a PSTitleValueCell does not reliably display.
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:dev[HPDevNameKey] ?: @"Device"
                                                          target:helper
                                                             set:NULL
                                                             get:@selector(deviceValue:)
                                                          detail:nil
                                                            cell:PSTitleValueCell
                                                            edit:nil];
        [row setProperty:@YES forKey:@"hpOurs"];
        [row setProperty:@YES forKey:@"hpValueRow"];
        [row setProperty:@YES forKey:@"hpDeviceRow"];
        [row setProperty:dev[HPDevIPKey] ?: @"?" forKey:@"hpIP"];
        [row setProperty:dev[HPDevMacKey] ?: @"" forKey:@"hpMac"];
        [specs addObject:row];
    }

    // Devices that used data this period but are not connected right now.
    //
    // Capped and ranked by usage: over a month of randomised client MACs this
    // list would otherwise grow into dozens of rows, burying the connected
    // devices. The full count stays visible in "Seen this period".
    NSDictionary *seen = state[HPStDevicesSeenKey] ?: @{};
    NSMutableSet *connectedMacs = [NSMutableSet set];
    for (NSDictionary *dev in devices) [connectedMacs addObject:dev[HPDevMacKey]];

    NSMutableArray *offline = [NSMutableArray array];
    for (NSString *mac in seen) {
        if ([connectedMacs containsObject:mac]) continue;
        if ([seen[mac][@"bytes"] unsignedLongLongValue] == 0) continue;
        [offline addObject:mac];
    }
    [offline sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [seen[b][@"bytes"] compare:seen[a][@"bytes"]];   // heaviest first
    }];
    if (offline.count > kHPMaxOfflineRows) {
        [offline removeObjectsInRange:NSMakeRange(kHPMaxOfflineRows,
                                                  offline.count - kHPMaxOfflineRows)];
    }

    for (NSString *mac in offline) {
        NSDictionary *record = seen[mac];

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:record[@"name"] ?: mac
                                                          target:helper
                                                             set:NULL
                                                             get:@selector(deviceValue:)
                                                          detail:nil
                                                            cell:PSTitleValueCell
                                                            edit:nil];
        [row setProperty:@YES forKey:@"hpOurs"];
        [row setProperty:@YES forKey:@"hpValueRow"];
        [row setProperty:@YES forKey:@"hpDeviceRow"];
        [row setProperty:@"offline" forKey:@"hpIP"];
        [row setProperty:mac forKey:@"hpMac"];
        [specs addObject:row];
    }

    return specs;
}

#pragma mark - Our own pane

static BOOL HPViewHoldsFirstResponderFwd(UIView *view);

/// Everything HotspotPro adds lives here, behind a single row in the stock
/// pane. Owning the whole controller means refreshing it disturbs nothing of
/// Apple's, and the stock pane is left with one row that never rebuilds.
@interface HPUsageListController : PSListController
@end

@implementation HPUsageListController {
    NSArray *_hpSpecs;
    NSTimer *_hpTimer;
    NSString *_hpStructure;
    NSString *_hpValues;
    BOOL _hpEnabled;
}

- (NSArray *)specifiers {
    // Write through to PSListController's own _specifiers ivar, which is what
    // every stock preference bundle does. Returning an array from an override
    // while the framework's ivar stayed nil crashed -prepareSpecifiersMetadata
    // with an unrecognized selector the moment this pane was pushed.
    @try {
        NSArray *existing = [self valueForKey:@"_specifiers"];
        if (existing.count) return existing;
    } @catch (NSException *e) {
        // No such ivar on this firmware; fall back to our own storage.
        if (_hpSpecs) return _hpSpecs;
    }

    _hpSpecs = HPBuildSpecifiers();
    @try {
        [self setValue:_hpSpecs forKey:@"_specifiers"];
    } @catch (NSException *e) {}
    return _hpSpecs;
}

- (void)hpInvalidateSpecifiers {
    _hpSpecs = nil;
    @try {
        [self setValue:nil forKey:@"_specifiers"];
    } @catch (NSException *e) {}
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hotspot Usage";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try {
        HPSettingsHelper *helper = [HPSettingsHelper shared];
        _hpStructure = [helper structureSignature];
        _hpValues = [helper valueSignature];
        _hpEnabled = [HPConfig()[HPCfgEnabledKey] boolValue];
        gUsagePaneRef = self;

        [_hpTimer invalidate];
        __weak typeof(self) weakSelf = self;
        _hpTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                   repeats:YES
                                                     block:^(NSTimer *t) {
            [weakSelf hpTick];
        }];
    } @catch (NSException *e) {
        HPLog(@"usage pane appear failed: %@", e);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_hpTimer invalidate];
    _hpTimer = nil;
}

/// Swap the device rows in place when a client joins or leaves.
///
/// Deliberately NOT -reloadSpecifiers: calling that on a pushed controller
/// popped this pane back to Personal Hotspot the instant a device connected.
/// Removing and inserting the affected rows leaves the navigation stack and
/// everything else on the pane untouched.
- (void)hpUpdateDeviceRows {
    @try {
        NSArray *specs = [self specifiers];
        NSMutableArray *stale = [NSMutableArray array];
        NSUInteger insertAt = NSNotFound;

        for (NSUInteger i = 0; i < specs.count; i++) {
            PSSpecifier *spec = specs[i];
            if ([[spec propertyForKey:@"hpDeviceRow"] boolValue]) {
                if (insertAt == NSNotFound) insertAt = i;
                [stale addObject:spec];
            } else if (insertAt == NSNotFound &&
                       [[spec propertyForKey:@"hpDevicesGroup"] boolValue]) {
                insertAt = i + 1;   // no rows yet: land right after the header
            }
        }
        if (insertAt == NSNotFound) return;

        UITableView *table = [self table];
        CGPoint offset = table ? table.contentOffset : CGPointZero;

        if (stale.count) [self removeContiguousSpecifiers:stale animated:NO];
        NSArray *fresh = HPBuildDeviceRows();
        if (fresh.count) {
            [self insertContiguousSpecifiers:fresh atIndex:insertAt animated:NO];
        }

        if (table) table.contentOffset = offset;
    } @catch (NSException *e) {
        HPLog(@"device row update failed: %@", e);
    }
}

/// Open a device's own page.
///
/// Pushed by hand rather than through the specifier's detail class, because a
/// device row has to be a PSTitleValueCell: that is the only cell that shows
/// the row's value, and the value is the whole point — "28.8 MB · 172.20.10.2".
/// Making the row a PSLinkCell to get automatic pushing silently dropped that
/// text, leaving a device row with a name and nothing else.
- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if ([[spec propertyForKey:@"hpDeviceRow"] boolValue]) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            HPDeviceListController *device = [[HPDeviceListController alloc] init];
            [device setSpecifier:spec];
            [self pushController:device];
            return;
        }
    } @catch (NSException *e) {
        HPLog(@"device row tap failed: %@", e);
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

/// Add or remove everything the tracking switch governs.
- (void)hpUpdateBody {
    @try {
        NSMutableArray *body = [NSMutableArray array];
        for (PSSpecifier *spec in [self specifiers]) {
            if ([[spec propertyForKey:@"hpBody"] boolValue]) [body addObject:spec];
        }
        if (body.count) [self removeContiguousSpecifiers:body animated:NO];

        if ([HPConfig()[HPCfgEnabledKey] boolValue]) {
            [self insertContiguousSpecifiers:HPBuildBodySpecifiers()
                                     atIndex:[[self specifiers] count]
                                    animated:NO];
        }
    } @catch (NSException *e) {
        HPLog(@"body update failed: %@", e);
    }
}

- (void)hpTick {
    @try {
        UITableView *table = [self table];

        // Never move anything under the user's finger, and never while a limit
        // field is being typed into.
        if (table.isDragging || table.isDecelerating || table.isTracking) return;
        for (UITableViewCell *cell in table.visibleCells) {
            if (HPViewHoldsFirstResponderFwd(cell)) return;
        }

        HPSettingsHelper *helper = [HPSettingsHelper shared];

        // Row changes — a device joining or leaving — touch only the device
        // rows. Byte totals move constantly and must never restructure a table.
        // Tracking being switched on or off changes the whole pane; anything
        // else that changes shape is just a device joining or leaving.
        BOOL enabledNow = [HPConfig()[HPCfgEnabledKey] boolValue];
        if (enabledNow != _hpEnabled) {
            _hpEnabled = enabledNow;
            _hpStructure = [helper structureSignature];
            _hpValues = [helper valueSignature];
            [self hpUpdateBody];
            return;
        }

        NSString *structure = [helper structureSignature];
        if (![structure isEqualToString:_hpStructure]) {
            _hpStructure = structure;
            _hpValues = [helper valueSignature];
            [self hpUpdateDeviceRows];
            return;
        }

        NSString *values = [helper valueSignature];
        if ([values isEqualToString:_hpValues]) return;
        _hpValues = values;

        for (PSSpecifier *spec in [self specifiers]) {
            if ([[spec propertyForKey:@"hpValueRow"] boolValue]) {
                [self reloadSpecifier:spec animated:NO];
            }
        }
    } @catch (NSException *e) {
        HPLog(@"usage pane tick failed: %@", e);
    }
}

@end

/// The single row added to the stock Personal Hotspot pane.
static NSArray *HPStockPaneRows(void) {
    PSSpecifier *group = HPGroup(nil, nil);
    PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:@"Hotspot Usage"
                                                       target:[HPSettingsHelper shared]
                                                          set:NULL
                                                          get:@selector(summaryValue:)
                                                       detail:[HPUsageListController class]
                                                         cell:PSLinkCell
                                                         edit:nil];
    [link setProperty:@YES forKey:@"hpOurs"];
    [link setProperty:@YES forKey:@"hpSummary"];
    return @[ group, link ];
}

#pragma mark - Settings hook (Preferences)

static NSTimer *gPaneTimer;
static __weak PSListController *gPane;

/// Identify the Personal Hotspot pane.
///
/// Two earlier attempts were both too narrow:
///  - v0.2.0 hooked `WirelessModemBundleController`, the NSPrincipalClass of
///    WirelessModemSettings.bundle. Its `specifiers` is never called; the class
///    that actually backs the pane is `WirelessModemController`.
///  - v0.2.2 matched only the `TetheringSwitchFooterView` / `TetheringSetupView`
///    cell classes. Those exist only while the hotspot is ON — the pane carries
///    10 specifiers on, 9 off — so with it off nothing was detected and no rows
///    appeared.
///
/// So match on several independent signals, any one of which is enough: the
/// class name, and two pieces of pane content, one of which (the Wi-Fi password
/// row's detail controller) is present in both states.
static BOOL HPIsHotspotPane(NSArray *specs, NSString *className) {
    if ([className containsString:@"WirelessModem"] ||
        [className containsString:@"Tethering"]) {
        return YES;
    }

    for (PSSpecifier *spec in specs) {
        if ([[spec propertyForKey:@"footerCellClass"] isEqualToString:@"TetheringSwitchFooterView"])
            return YES;
        if ([[spec propertyForKey:@"headerCellClass"] isEqualToString:@"TetheringSetupView"])
            return YES;

        // "detail" is the pushed controller, stored either as a Class or its
        // name depending on how the specifier was built.
        id detail = [spec propertyForKey:@"detail"];
        NSString *detailName = nil;
        if ([detail isKindOfClass:[NSString class]]) {
            detailName = detail;
        } else if (detail && class_isMetaClass(object_getClass(detail))) {
            detailName = NSStringFromClass((Class)detail);
        }
        if ([detailName isEqualToString:@"WiFiPasswordController"]) return YES;
    }
    return NO;
}

static NSArray *HPOurSpecifiersIn(NSArray *specs) {
    NSMutableArray *ours = [NSMutableArray array];
    for (PSSpecifier *spec in specs) {
        if ([[spec propertyForKey:@"hpOurs"] boolValue]) [ours addObject:spec];
    }
    return ours;
}

/// Append our rows, preserving the user's scroll position.
///
/// Inserting rows while the pane is appearing shifts the table's content
/// offset, which made the pane open scrolled down into our section instead of
/// at the top.
static NSArray *HPStockPaneRows(void);

static void HPAppendToPane(PSListController *pane) {
    @try {
        CGPoint offset = CGPointZero;
        UITableView *table = nil;
        @try { table = [pane table]; } @catch (NSException *e) {}
        if (table) offset = table.contentOffset;

        [pane insertContiguousSpecifiers:HPStockPaneRows()
                                 atIndex:[[pane specifiers] count]
                                animated:NO];

        if (table) table.contentOffset = offset;
    } @catch (NSException *e) {
        HPLog(@"append failed: %@", e);
    }
}

static BOOL HPViewHoldsFirstResponder(UIView *view) {
    if (view.isFirstResponder) return YES;
    for (UIView *sub in view.subviews) {
        if (HPViewHoldsFirstResponder(sub)) return YES;
    }
    return NO;
}

static BOOL HPViewHoldsFirstResponderFwd(UIView *view) {
    return HPViewHoldsFirstResponder(view);
}

/// Never touch the table while it is being scrolled or a field is being edited.
/// Re-inserting rows under a moving finger is what made the stock pane jump to
/// the bottom of the settings list.
static BOOL HPPaneIsBusy(PSListController *pane) {
    @try {
        UITableView *table = [pane table];
        if (table.isDragging || table.isDecelerating || table.isTracking) return YES;
        for (UITableViewCell *cell in table.visibleCells) {
            if (HPViewHoldsFirstResponder(cell)) return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

/// Re-read the value cells through their getters. No rows added or removed, so
/// scroll position and cell identity are untouched.
static void HPReloadValues(PSListController *pane) {
    @try {
        for (PSSpecifier *spec in [pane specifiers]) {
            if ([[spec propertyForKey:@"hpValueRow"] boolValue] ||
                [[spec propertyForKey:@"hpSummary"] boolValue]) {
                [pane reloadSpecifier:spec animated:NO];
            }
        }
    } @catch (NSException *e) {
        HPLog(@"value reload failed: %@", e);
    }
}


%group SettingsHooks

// Hooked on the base class so it fires for whichever subclass backs the pane,
// since a UIViewController subclass calls super on appearance.
%hook PSListController

// Diagnostic and safety net. Settings aborted here with an unrecognized
// selector when our pane was pushed; if anything similar happens again the log
// names the selector and Settings stays up instead of dying on a usage screen.
- (void)prepareSpecifiersMetadata {
    @try {
        %orig;
    } @catch (NSException *e) {
        HPLog(@"prepareSpecifiersMetadata threw in %@: %@ — %@",
              NSStringFromClass([self class]), e.name, e.reason);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        PSListController *pane = (PSListController *)self;
        NSArray *specs = [pane specifiers];
        if (!specs.count) return;

        // One line per distinct pane class, so if detection ever fails again the
        // log names every candidate actually opened.
        static NSMutableSet *seen;
        if (!seen) seen = [NSMutableSet set];
        NSString *cls = NSStringFromClass([self class]);
        BOOL isHotspot = HPIsHotspotPane(specs, cls);
        if (![seen containsObject:cls]) {
            [seen addObject:cls];
            HPLog(@"pane %@ (%lu specifiers)%@", cls, (unsigned long)specs.count,
                  isHotspot ? @"  <-- HOTSPOT" : @"");
        }
        if (!isHotspot) return;

        gPane = pane;
        if (HPOurSpecifiersIn(specs).count == 0) {
            HPAppendToPane(pane);
            HPLog(@"appended rows to %@", cls);
        }

        [gPaneTimer invalidate];
        gPaneTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
            @try {
                PSListController *live = gPane;
                if (!live) { [t invalidate]; return; }

                // Self-healing. Toggling "Allow Others to Join" makes the pane
                // rebuild its own specifiers, which drops ours on the floor —
                // and the hotspot switch is exactly the control people touch
                // here. Rather than chase every method that can rebuild them,
                // notice they are gone and put them back.
                if (HPPaneIsBusy(live)) return;

                // Only two jobs here now that the stock pane holds a single
                // row: put it back if a pane rebuild dropped it, and keep its
                // summary current. Nothing rebuilds, so nothing visibly
                // reloads while you are looking at Apple's own settings.
                if (HPOurSpecifiersIn([live specifiers]).count == 0) {
                    HPAppendToPane(live);
                    return;
                }

                HPSettingsHelper *helper = [HPSettingsHelper shared];
                NSString *values = [helper valueSignature];
                if ([values isEqualToString:helper.lastValues]) return;
                helper.lastValues = values;
                HPReloadValues(live);
            } @catch (NSException *e) {
                HPLog(@"pane timer failed: %@", e);
            }
        }];
    } @catch (NSException *e) {
        HPLog(@"viewWillAppear hook failed: %@", e);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    @try {
        if (gPane == (PSListController *)self) {
            [gPaneTimer invalidate];
            gPaneTimer = nil;
            gPane = nil;
        }
    } @catch (NSException *e) {}
}

%end

%end

#pragma mark - Entry

// See SpringBoard.x for why iOS 18 is gated. Duplicated rather than shared
// because the two dylibs no longer have a translation unit in common, and a
// four-line check is cheaper than a header to hold it.
static BOOL HPFirmwareUntested(void) {
    NSOperatingSystemVersion ios18 = { 18, 0, 0 };
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:ios18];
}

%ctor {
    @autoreleasepool {
        @try {
            if (HPFirmwareUntested()) {
                HPLog(@"iOS 18+ — settings hooks disabled, firmware untested");
                return;
            }
            %init(SettingsHooks);
            HPLog(@"settings hooks installed");
        } @catch (NSException *e) {
            HPLog(@"ctor failed: %@", e);
        }
    }
}
