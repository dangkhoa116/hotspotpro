#import "Tracker.h"
#import "Collector.h"
#import "Prefs.h"

NSString *const HPTickAddedKey   = @"added";
NSString *const HPTickTotalKey   = @"total";
NSString *const HPTickEventsKey  = @"events";
NSString *const HPTickIfNamesKey = @"ifNames";
NSString *const HPTickDevicesKey = @"devices";
NSString *const HPTickBlockedKey = @"blocked";

/// Zero the period, archiving what it held. Shared by the scheduled rollover
/// and the manual reset so both leave identical state behind.
static void HPBeginNewPeriod(NSMutableDictionary *state, NSDate *now, NSInteger resetDay,
                             BOOL archive) {
    if (archive) {
        uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];
        NSDate *start = state[HPStPeriodStartKey];
        if (total > 0 && start) {
            NSMutableArray *history = [(state[HPStHistoryKey] ?: @[]) mutableCopy];
            [history addObject:@{
                @"start" : start,
                @"end"   : now,
                @"bytes" : @(total),
            }];
            // Keep a couple of years; the state file stays small and readable.
            while (history.count > 24) [history removeObjectAtIndex:0];
            state[HPStHistoryKey] = history;
        }
    }

    state[HPStTotalBytesKey]  = @0;
    state[HPStUploadBytesKey]   = @0;
    state[HPStDownloadBytesKey] = @0;
    state[HPStPeriodStartKey] = now;
    state[HPStNextResetKey]   = HPNextResetDate(now, resetDay);
    state[HPStWarnFiredKey]   = @NO;
    state[HPStLimitFiredKey]  = @NO;
    state[HPStDevicesSeenKey] = @{};
    // lastRaw is deliberately kept: the interfaces did not go anywhere, so the
    // next tick must still measure a delta rather than re-adding a whole
    // session's counters into the fresh period.
}

/// A content fingerprint of the state, ignoring the sample timestamp.
///
/// The timestamp changes on every tick by definition, so including it would
/// make the answer "changed" every time and nothing would ever be skipped.
/// Serialising rather than comparing dictionaries handles the nested
/// device/history containers without needing a deep copy. If serialisation ever
/// produced different bytes for equal content the result is a redundant write,
/// never a skipped real change -- the safe direction to fail in.
static NSData *HPStateFingerprint(NSDictionary *state) {
    NSMutableDictionary *copy = [state mutableCopy];
    [copy removeObjectForKey:HPStUpdatedKey];
    return [NSPropertyListSerialization dataWithPropertyList:copy
                                                      format:NSPropertyListBinaryFormat_v1_0
                                                     options:0
                                                       error:NULL];
}

NSDictionary *HPTick(void) {
    NSDictionary *cfg = HPConfig();
    if (![cfg[HPCfgEnabledKey] boolValue]) return nil;

    NSMutableDictionary *state = HPStateLoad();
    NSData *fingerprintBefore = HPStateFingerprint(state);
    NSDate *now = [NSDate date];
    NSInteger resetDay = [cfg[HPCfgResetDayKey] integerValue];
    HPTickEvents events = HPTickEventNone;

    // --- period bookkeeping ------------------------------------------------
    if (!state[HPStPeriodStartKey] || !state[HPStNextResetKey]) {
        state[HPStPeriodStartKey] = HPPeriodStartDate(now, resetDay);
        state[HPStNextResetKey]   = HPNextResetDate(now, resetDay);
    }

    if ([state[HPStResetRequestKey] boolValue]) {
        // The UI only ever sets a flag; the collector is the single writer of
        // the totals, so a reset can never race a sample.
        HPBeginNewPeriod(state, now, resetDay, YES);
        state[HPStResetRequestKey] = @NO;
        events |= HPTickEventReset;
    }

    NSDate *nextReset = state[HPStNextResetKey];
    if ([now compare:nextReset] != NSOrderedAscending) {
        HPBeginNewPeriod(state, now, resetDay, YES);
        events |= HPTickEventRolledOver;
    }

    // A changed resetDay moves the boundary without waiting for the old one.
    NSDate *expected = HPNextResetDate(state[HPStPeriodStartKey], resetDay);
    if (![expected isEqualToDate:state[HPStNextResetKey]]) {
        state[HPStNextResetKey] = expected;
    }

    // --- counters ----------------------------------------------------------
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    NSArray<NSString *> *names = HPHotspotInterfaceNames(ifaces);

    NSMutableDictionary *lastRaw = [(state[HPStLastRawKey] ?: @{}) mutableCopy];
    BOOL baselined = [state[HPStBaselinedKey] boolValue];

    uint64_t addedUp = 0, addedDown = 0;
    uint64_t added = HPAccumulateDeltaSplit(lastRaw, ifaces, names, !baselined,
                                            &addedUp, &addedDown);
    if (!baselined) {
        // First run ever: record where the counters stand without importing a
        // session that may predate this billing period.
        state[HPStBaselinedKey] = @YES;
        HPLog(@"baselined on interfaces %@", [names componentsJoinedByString:@", "]);
    }

    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue] + added;
    state[HPStTotalBytesKey] = @(total);
    state[HPStUploadBytesKey]   =
        @([state[HPStUploadBytesKey] unsignedLongLongValue] + addedUp);
    state[HPStDownloadBytesKey] =
        @([state[HPStDownloadBytesKey] unsignedLongLongValue] + addedDown);
    state[HPStLastRawKey]    = lastRaw;
    state[HPStIfNamesKey]    = names;

    // --- devices -----------------------------------------------------------
    // Two lists, deliberately: the ARP table is what a device has *been* seen
    // at, and that is what the "seen this period" record wants — a name and an
    // address are worth keeping the moment they are known. "Connected now" is a
    // narrower question, and only HPCopyPresentDevices() answers it, so the CLI
    // and the Settings pane cannot end up disagreeing about who is here.
    NSArray<NSDictionary *> *devices = HPCopyConnectedDevices(names);
    NSMutableSet<NSString *> *presentMacs = [NSMutableSet set];
    for (NSDictionary *dev in HPCopyPresentDevices(names)) {
        if (dev[HPDevMacKey]) [presentMacs addObject:dev[HPDevMacKey]];
    }
    NSDictionary *nicknames = cfg[HPCfgNicknamesKey];

    NSMutableArray *devicesNow = [NSMutableArray array];
    NSMutableDictionary *seen = [(state[HPStDevicesSeenKey] ?: @{}) mutableCopy];

    for (NSDictionary *dev in devices) {
        NSString *mac = dev[HPDevMacKey];
        NSMutableDictionary *entry = [dev mutableCopy];

        // A nickname the user set wins over the DHCP name; a randomised MAC with
        // no name of its own is labelled "Private Address" rather than shown as
        // the raw MAC, which read as no name at all.
        NSString *nick = [nicknames isKindOfClass:[NSDictionary class]] ? nicknames[mac] : nil;
        entry[HPDevNameKey] = HPDeviceDisplayName(mac, dev[HPDevNameKey], nick);
        if ([presentMacs containsObject:mac]) [devicesNow addObject:entry];

        NSMutableDictionary *record = [(seen[mac] ?: @{}) mutableCopy];
        if (!record[@"first"]) record[@"first"] = now;
        record[@"last"] = now;
        record[@"name"] = entry[HPDevNameKey];
        if (dev[HPDevIPKey]) record[@"ip"] = dev[HPDevIPKey];
        seen[mac] = record;
    }

    // --- per-device bytes ---------------------------------------------------
    // The daemon's counters run from whenever it last started, so they are
    // folded in as deltas, exactly like the interface counters: a value that
    // dropped means the daemon restarted and the current figure is the delta.
    NSDictionary<NSString *, NSNumber *> *daemonBytes = HPCopyDaemonDeviceBytes();
    NSDictionary<NSString *, NSNumber *> *daemonUp    = HPCopyDaemonDeviceUpload();
    NSDictionary<NSString *, NSNumber *> *daemonDown  = HPCopyDaemonDeviceDownload();
    NSMutableDictionary *lastDevRaw     = [(state[HPStLastDevRawKey] ?: @{}) mutableCopy];
    NSMutableDictionary *lastDevRawUp   = [(state[HPStLastDevRawUpKey] ?: @{}) mutableCopy];
    NSMutableDictionary *lastDevRawDown = [(state[HPStLastDevRawDownKey] ?: @{}) mutableCopy];
    BOOL devBaselined = [state[HPStDevBaselinedKey] boolValue];

    // Delta of one cumulative daemon counter against its own stored baseline.
    // `newOK` says whether a first sight with no baseline counts in full — true
    // for a device the daemon began counting after our last sample, false for
    // the first tick after the directional counters were added, where importing
    // the whole running figure would double-count a period already tracked by
    // the total.
    uint64_t (^devDelta)(NSDictionary *, NSMutableDictionary *, NSString *, BOOL) =
        ^uint64_t(NSDictionary *cumulative, NSMutableDictionary *baseline,
                  NSString *mac, BOOL newOK) {
        uint64_t cur = [cumulative[mac] unsignedLongLongValue];
        uint64_t out = 0;
        if (baseline[mac] && devBaselined) {
            uint64_t prev = [baseline[mac] unsignedLongLongValue];
            // A value that dropped means the daemon restarted; the figure is the
            // delta.
            out = (cur >= prev) ? (cur - prev) : cur;
        } else if (!baseline[mac] && devBaselined && newOK) {
            out = cur;
        }
        baseline[mac] = @(cur);
        return out;
    };

    for (NSString *mac in daemonBytes) {
        // Captured before devDelta records this tick's baseline: a device with
        // no total baseline yet is genuinely new, so its directional figures are
        // all new too.
        BOOL isNewDevice = (lastDevRaw[mac] == nil);

        uint64_t delta     = devDelta(daemonBytes, lastDevRaw,     mac, isNewDevice);
        uint64_t deltaUp   = devDelta(daemonUp,    lastDevRawUp,   mac, isNewDevice);
        uint64_t deltaDown = devDelta(daemonDown,  lastDevRawDown, mac, isNewDevice);

        if (delta == 0 && deltaUp == 0 && deltaDown == 0) continue;
        NSMutableDictionary *record = [(seen[mac] ?: @{}) mutableCopy];
        if (!record[@"first"]) record[@"first"] = now;
        record[@"last"] = now;
        record[@"bytes"] = @([record[@"bytes"] unsignedLongLongValue] + delta);
        record[@"up"]    = @([record[@"up"]    unsignedLongLongValue] + deltaUp);
        record[@"down"]  = @([record[@"down"]  unsignedLongLongValue] + deltaDown);
        if (!record[@"name"]) {
            NSString *nick = [nicknames isKindOfClass:[NSDictionary class]] ? nicknames[mac] : nil;
            record[@"name"] = HPDeviceDisplayName(mac, nil, nick);
        }
        seen[mac] = record;
    }

    // Drop our mirror of any device the daemon has forgotten, so this table
    // cannot outgrow the daemon's own (capped) one. Only entries the daemon no
    // longer reports are removed — pruning one it still counts would make its
    // whole running total look like new traffic on the next sample.
    for (NSString *mac in [lastDevRaw.allKeys copy]) {
        if (!daemonBytes[mac]) {
            [lastDevRaw removeObjectForKey:mac];
            [lastDevRawUp removeObjectForKey:mac];
            [lastDevRawDown removeObjectForKey:mac];
        }
    }

    state[HPStLastDevRawKey]     = lastDevRaw;
    state[HPStLastDevRawUpKey]   = lastDevRawUp;
    state[HPStLastDevRawDownKey] = lastDevRawDown;
    state[HPStDevBaselinedKey] = @YES;

    // Carry each connected device's period total onto its row.
    for (NSMutableDictionary *dev in devicesNow) {
        NSDictionary *record = seen[dev[HPDevMacKey]];
        dev[HPDevBytesKey] = record[@"bytes"] ?: @0;
    }

    state[HPStDevicesNowKey]  = devicesNow;
    state[HPStDevicesSeenKey] = seen;
    state[HPStUpdatedKey]     = now;

    // --- per-device limits --------------------------------------------------
    // Decided here because this is where period totals live, and published as a
    // file for the daemon, which is the only thing that can install a route.
    // A device drops off the list the moment it is under its cap again — which
    // is what unblocks it after a reset or a raised limit, with no extra state.
    NSDictionary *deviceLimits = cfg[HPCfgDeviceLimitsKey];
    NSDictionary *manualBlocks = cfg[HPCfgManualBlocksKey];
    NSMutableArray *blocked = [NSMutableArray array];
    NSMutableArray *newlyBlocked = [NSMutableArray array];
    NSArray *previouslyBlocked = state[HPStBlockedMacsKey] ?: @[];

    // Two independent reasons a device is cut off: it went over its own data
    // limit, or the user blocked it by hand from its page. They feed the same
    // reject-route mechanism, but only a limit block raises a popup — a manual
    // block was the user's own doing and needs no announcing.
    NSMutableSet<NSString *> *macsToBlock = [NSMutableSet set];
    NSMutableSet<NSString *> *limitBlocked = [NSMutableSet set];

    if ([deviceLimits isKindOfClass:[NSDictionary class]]) {
        for (NSString *mac in deviceLimits) {
            double limitGB = [deviceLimits[mac] doubleValue];
            if (limitGB <= 0) continue;
            uint64_t used = [seen[mac][@"bytes"] unsignedLongLongValue];
            if (used < (uint64_t)(limitGB * 1024.0 * 1024.0 * 1024.0)) continue;
            [macsToBlock addObject:mac];
            [limitBlocked addObject:mac];
        }
    }
    if ([manualBlocks isKindOfClass:[NSDictionary class]]) {
        for (NSString *mac in manualBlocks) {
            if ([manualBlocks[mac] boolValue]) [macsToBlock addObject:mac];
        }
    }

    for (NSString *mac in macsToBlock) {
        NSString *ip = seen[mac][@"ip"];
        if (!ip) continue;   // no address on record yet — nothing to route-block
        [blocked addObject:@{ @"mac" : mac, @"ip" : ip }];

        // Announce only a device the limit newly cut off, never a manual block.
        if ([limitBlocked containsObject:mac] && ![previouslyBlocked containsObject:mac]) {
            [newlyBlocked addObject:seen[mac][@"name"] ?: mac];
        }
    }

    NSArray *blockedMacs = [blocked valueForKey:@"mac"];
    state[HPStBlockedMacsKey] = blockedMacs;
    if (newlyBlocked.count) events |= HPTickEventBlocked;

    // Only rewrite the file when the set actually changes; the daemon reads it
    // on every pass.
    if (![blockedMacs isEqualToArray:previouslyBlocked]) {
        [@{ @"blocked" : blocked, @"updated" : now } writeToFile:HPBlocklistPath()
                                                      atomically:YES];
        HPLog(@"blocklist now %@", blockedMacs.count ? [blockedMacs componentsJoinedByString:@", "]
                                                     : @"(empty)");
    }

    // --- thresholds --------------------------------------------------------
    double limitGB = [cfg[HPCfgLimitGBKey] doubleValue];
    if (limitGB > 0) {
        double limitBytes = limitGB * 1024.0 * 1024.0 * 1024.0;
        double warnBytes = limitBytes * [cfg[HPCfgWarnPercentKey] doubleValue] / 100.0;

        if (total >= (uint64_t)limitBytes && ![state[HPStLimitFiredKey] boolValue]) {
            state[HPStLimitFiredKey] = @YES;
            state[HPStWarnFiredKey]  = @YES; // never warn after the limit itself
            events |= HPTickEventLimitFired;
        } else if (total >= (uint64_t)warnBytes && ![state[HPStWarnFiredKey] boolValue]) {
            state[HPStWarnFiredKey] = @YES;
            events |= HPTickEventWarnFired;
        }
    }

    // An idle phone was doing an atomic rewrite of this file every 10 seconds --
    // around 8,600 a day -- with identical contents. Write when something
    // actually changed, and otherwise no more than once a minute so the "last
    // updated" stamp cannot drift arbitrarily far behind.
    static NSDate *lastWrite;
    BOOL changed = ![HPStateFingerprint(state) isEqualToData:fingerprintBefore];
    if (changed || !lastWrite || [now timeIntervalSinceDate:lastWrite] >= 60.0) {
        HPStateSave(state);
        lastWrite = now;
    }

    return @{
        HPTickAddedKey   : @(added),
        HPTickTotalKey   : @(total),
        HPTickEventsKey  : @(events),
        HPTickIfNamesKey : names,
        HPTickDevicesKey : devicesNow,
        HPTickBlockedKey : newlyBlocked,
    };
}

NSString *HPStatusReport(void) {
    NSDictionary *cfg = HPConfig();
    NSDictionary *state = HPStateLoad();

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";

    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];
    double limitGB = [cfg[HPCfgLimitGBKey] doubleValue];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Used this period : %@\n", HPFormatBytes(total)];

    if (limitGB > 0) {
        uint64_t limitBytes = (uint64_t)(limitGB * 1024.0 * 1024.0 * 1024.0);
        double pct = limitBytes ? (100.0 * total / limitBytes) : 0.0;
        [s appendFormat:@"Limit            : %.2f GB (%.1f%% used, %@ left)\n",
                        limitGB, pct,
                        HPFormatBytes(total >= limitBytes ? 0 : limitBytes - total)];
    } else {
        [s appendString:@"Limit            : none set\n"];
    }

    [s appendFormat:@"Period started   : %@\n",
                    state[HPStPeriodStartKey]
                        ? [fmt stringFromDate:state[HPStPeriodStartKey]] : @"-"];
    [s appendFormat:@"Resets           : %@ (day %@ of the month)\n",
                    state[HPStNextResetKey]
                        ? [fmt stringFromDate:state[HPStNextResetKey]] : @"-",
                    cfg[HPCfgResetDayKey]];
    [s appendFormat:@"Counting         : %@\n",
                    [(state[HPStIfNamesKey] ?: @[]) componentsJoinedByString:@", "] ?: @"-"];
    [s appendFormat:@"Last sample      : %@\n",
                    state[HPStUpdatedKey] ? [fmt stringFromDate:state[HPStUpdatedKey]] : @"never"];

    NSArray *now = state[HPStDevicesNowKey] ?: @[];
    [s appendFormat:@"\nConnected now (%lu):\n", (unsigned long)now.count];
    for (NSDictionary *d in now) {
        [s appendFormat:@"  %-24s %-15s %@\n",
                        [(d[HPDevNameKey] ?: @"?") UTF8String],
                        [(d[HPDevIPKey] ?: @"?") UTF8String],
                        d[HPDevMacKey] ?: @"?"];
    }

    NSDictionary *seen = state[HPStDevicesSeenKey] ?: @{};
    [s appendFormat:@"\nSeen this period (%lu):\n", (unsigned long)seen.count];
    for (NSString *mac in seen) {
        NSDictionary *d = seen[mac];
        [s appendFormat:@"  %-24s %-15s %-10s (down %@ / up %@) last %@\n",
                        [(d[@"name"] ?: mac) UTF8String],
                        [(d[@"ip"] ?: @"?") UTF8String],
                        [HPFormatBytes([d[@"bytes"] unsignedLongLongValue]) UTF8String],
                        HPFormatBytes([d[@"down"] unsignedLongLongValue]),
                        HPFormatBytes([d[@"up"] unsignedLongLongValue]),
                        d[@"last"] ? [fmt stringFromDate:d[@"last"]] : @"?"];
    }

    return s;
}
