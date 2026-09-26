#import "Tracker.h"
#import "Collector.h"
#import "Prefs.h"
#import "Apportion.h"

const NSTimeInterval HPAttributeWindow = 60.0;

// Bumped when a one-time repair of stored figures is added; see HPRepairTotals.
static const NSInteger kHPSchema = 2;

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
    // Bytes still waiting for an owner were measured in the period just closed.
    [state removeObjectForKey:HPStPendingUpKey];
    [state removeObjectForKey:HPStPendingDownKey];
    [state removeObjectForKey:HPStPendingSinceKey];
    // lastRaw is deliberately kept: the interfaces did not go anywhere, so the
    // next tick must still measure a delta rather than re-adding a whole
    // session's counters into the fresh period.
}

#pragma mark - Per-device attribution

/// Split bytes whose direction was never recorded along the up:down ratio that
/// was. With no ratio to go on it all goes to download, which is what a
/// hotspot's traffic overwhelmingly is.
static void HPSplitAlongRatio(uint64_t amount, uint64_t ratioUp, uint64_t ratioDown,
                              uint64_t *outUp, uint64_t *outDown) {
    uint64_t weights[2] = { ratioUp, ratioDown };
    uint64_t parts[2] = { 0, 0 };
    if (HPApportion(amount, weights, 2, parts) == 0) {
        parts[0] = 0;
        parts[1] = amount;
    }
    *outUp = parts[0];
    *outDown = parts[1];
}

void HPAttributeToDevices(NSMutableDictionary *seen,
                          NSDictionary<NSString *, NSNumber *> *rawUp,
                          NSDictionary<NSString *, NSNumber *> *rawDown,
                          uint64_t *poolUp,
                          uint64_t *poolDown,
                          NSDate *now) {
    NSMutableSet<NSString *> *active = [NSMutableSet set];
    for (NSString *mac in rawUp) {
        if ([rawUp[mac] unsignedLongLongValue]) [active addObject:mac];
    }
    for (NSString *mac in rawDown) {
        if ([rawDown[mac] unsignedLongLongValue]) [active addObject:mac];
    }
    if (!active.count) return;

    // Sorted, so the stray byte a split leaves over lands the same way for the
    // same input rather than following hash order.
    NSArray<NSString *> *macs = [active.allObjects sortedArrayUsingSelector:@selector(compare:)];
    size_t n = macs.count;
    NSMutableData *buf = [NSMutableData dataWithLength:4 * n * sizeof(uint64_t)];
    uint64_t *wUp = buf.mutableBytes, *wDown = wUp + n, *gotUp = wDown + n, *gotDown = gotUp + n;
    for (size_t i = 0; i < n; i++) {
        wUp[i]   = [rawUp[macs[i]] unsignedLongLongValue];
        wDown[i] = [rawDown[macs[i]] unsignedLongLongValue];
    }

    if (HPApportion(*poolUp, wUp, n, gotUp))       *poolUp = 0;
    if (HPApportion(*poolDown, wDown, n, gotDown)) *poolDown = 0;

    for (size_t i = 0; i < n; i++) {
        NSMutableDictionary *record = [(seen[macs[i]] ?: @{}) mutableCopy];
        if (!record[@"first"]) record[@"first"] = now;
        record[@"last"] = now;
        uint64_t up   = [record[@"up"] unsignedLongLongValue] + gotUp[i];
        uint64_t down = [record[@"down"] unsignedLongLongValue] + gotDown[i];
        record[@"up"]    = @(up);
        record[@"down"]  = @(down);
        record[@"bytes"] = @(up + down);
        seen[macs[i]] = record;
    }
}

/// Turn the daemon's cumulative per-client counters into what each client moved
/// since the last sample, advancing the stored baselines. The results only
/// weight HPAttributeToDevices; they are never added to a total directly.
static void HPFoldDaemonCounters(NSDictionary *counters, NSMutableDictionary *state,
                                 NSMutableDictionary *rawUp, NSMutableDictionary *rawDown) {
    NSDictionary<NSString *, NSNumber *> *daemonBytes = counters[@"bytes"];
    NSDictionary<NSString *, NSNumber *> *daemonUp    = counters[@"up"];
    NSDictionary<NSString *, NSNumber *> *daemonDown  = counters[@"down"];
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

        // A daemon from before the split reports only the total; weigh that as
        // download, which is what nearly all of it is.
        if (deltaUp == 0 && deltaDown == 0) deltaDown = delta;
        if (deltaUp)   rawUp[mac]   = @(deltaUp);
        if (deltaDown) rawDown[mac] = @(deltaDown);
    }

    // Drop our mirror of any device the daemon has forgotten, so this table
    // cannot outgrow the daemon's own (capped) one. Only entries the daemon no
    // longer reports are removed — pruning one it still counts would make its
    // whole running total look like new traffic on the next sample. Safe only
    // because the caller never passes an unreadable file in as an empty one.
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
}

BOOL HPRepairTotals(NSMutableDictionary *state) {
    if ([state[HPStSchemaKey] integerValue] >= kHPSchema) return NO;
    state[HPStSchemaKey] = @(kHPSchema);
    BOOL changed = NO;

    // The period. The upload/download split arrived in 0.7.0, so a period that
    // began earlier carried bytes in Used that neither half ever saw — Used
    // 8.65 GB over a split adding to 7.12 GB.
    uint64_t total = [state[HPStTotalBytesKey] unsignedLongLongValue];
    uint64_t up    = [state[HPStUploadBytesKey] unsignedLongLongValue];
    uint64_t down  = [state[HPStDownloadBytesKey] unsignedLongLongValue];
    if (up + down < total) {
        uint64_t addUp = 0, addDown = 0;
        HPSplitAlongRatio(total - up - down, up, down, &addUp, &addDown);
        up += addUp;
        down += addDown;
        changed = YES;
    }
    if (up + down != total) changed = YES;
    total = up + down;
    state[HPStTotalBytesKey]    = @(total);
    state[HPStUploadBytesKey]   = @(up);
    state[HPStDownloadBytesKey] = @(down);

    // Each device: the same gap between its Total and its own split, and on
    // top of that the re-imports of whole running figures, which put device
    // sums at several times the hotspot total. The proportions between devices
    // are the part worth keeping, so a sum over the hotspot total is cut back
    // to each device's share of that total.
    NSDictionary *oldSeen = state[HPStDevicesSeenKey];
    if (![oldSeen isKindOfClass:[NSDictionary class]]) return changed;
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    uint64_t sum = 0;
    for (NSString *mac in oldSeen) {
        if (![oldSeen[mac] isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *record = [oldSeen[mac] mutableCopy];
        uint64_t b = [record[@"bytes"] unsignedLongLongValue];
        uint64_t u = [record[@"up"] unsignedLongLongValue];
        uint64_t d = [record[@"down"] unsignedLongLongValue];
        if (u + d < b) {
            uint64_t addUp = 0, addDown = 0;
            HPSplitAlongRatio(b - u - d, u, d, &addUp, &addDown);
            u += addUp;
            d += addDown;
        }
        if (u + d != b) changed = YES;
        record[@"up"]    = @(u);
        record[@"down"]  = @(d);
        record[@"bytes"] = @(u + d);
        sum += u + d;
        seen[mac] = record;
    }

    if (sum > total) {
        NSArray<NSString *> *macs = [seen.allKeys sortedArrayUsingSelector:@selector(compare:)];
        size_t n = macs.count;
        NSMutableData *buf = [NSMutableData dataWithLength:2 * n * sizeof(uint64_t)];
        uint64_t *weights = buf.mutableBytes, *share = weights + n;
        for (size_t i = 0; i < n; i++) weights[i] = [seen[macs[i]][@"bytes"] unsignedLongLongValue];
        HPApportion(total, weights, n, share);
        for (size_t i = 0; i < n; i++) {
            NSMutableDictionary *record = seen[macs[i]];
            uint64_t u = 0, d = 0;
            HPSplitAlongRatio(share[i], [record[@"up"] unsignedLongLongValue],
                              [record[@"down"] unsignedLongLongValue], &u, &d);
            record[@"up"]    = @(u);
            record[@"down"]  = @(d);
            record[@"bytes"] = @(u + d);
        }
        HPLog(@"repair: devices summed to %@ against a hotspot total of %@; "
               "scaled each back to its share", HPFormatBytes(sum), HPFormatBytes(total));
        changed = YES;
    }
    state[HPStDevicesSeenKey] = seen;
    return changed;
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

    if (HPRepairTotals(state)) HPLog(@"repaired this period's figures from an earlier version");

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

    // Used is the sum of its two halves by definition, not a third counter kept
    // alongside them that could drift away.
    uint64_t periodUp   = [state[HPStUploadBytesKey] unsignedLongLongValue] + addedUp;
    uint64_t periodDown = [state[HPStDownloadBytesKey] unsignedLongLongValue] + addedDown;
    uint64_t total = periodUp + periodDown;
    state[HPStTotalBytesKey]    = @(total);
    state[HPStUploadBytesKey]   = @(periodUp);
    state[HPStDownloadBytesKey] = @(periodDown);
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
    // Two instruments, each used for what it is good at. This tick's hotspot
    // bytes (ap1, measured to track the cellular uplink) go into a pool; the
    // daemon's tap, which sits on the double-counting bridge, says who moved
    // what since the last sample, and the pool is shared out in those
    // proportions. So devices add up to Used, and a figure can never be more
    // than the hotspot actually carried.
    uint64_t poolUp   = [state[HPStPendingUpKey] unsignedLongLongValue] + addedUp;
    uint64_t poolDown = [state[HPStPendingDownKey] unsignedLongLongValue] + addedDown;
    NSMutableDictionary<NSString *, NSNumber *> *rawUp   = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *rawDown = [NSMutableDictionary dictionary];

    // One read, so the three tables are the same moment. nil is an unreadable
    // file, which says nothing about anybody: skip this round and keep every
    // baseline, rather than forgetting them and re-importing each device's
    // whole running figure on the next read.
    NSDictionary *counters = HPCopyDaemonCounters();
    if (counters) HPFoldDaemonCounters(counters, state, rawUp, rawDown);

    HPAttributeToDevices(seen, rawUp, rawDown, &poolUp, &poolDown, now);
    for (NSString *mac in seen.allKeys) {   // a copy: the loop writes to seen
        if (seen[mac][@"name"]) continue;
        NSMutableDictionary *record = [seen[mac] mutableCopy];
        NSString *nick = [nicknames isKindOfClass:[NSDictionary class]] ? nicknames[mac] : nil;
        record[@"name"] = HPDeviceDisplayName(mac, nil, nick);
        seen[mac] = record;
    }

    // Bytes nobody has claimed wait a little, since the daemon flushes on its
    // own 10s clock and a sample often lands before it has. Past the window —
    // the daemon is not running, or not tapping — they are let go: they are
    // still in Used, they are just not any one device's.
    NSDate *pendingSince = state[HPStPendingSinceKey];
    if (poolUp + poolDown == 0) {
        pendingSince = nil;
    } else if (!pendingSince) {
        pendingSince = now;
    } else if ([now timeIntervalSinceDate:pendingSince] > HPAttributeWindow) {
        poolUp = poolDown = 0;
        pendingSince = nil;
    }
    state[HPStPendingUpKey]   = @(poolUp);
    state[HPStPendingDownKey] = @(poolDown);
    if (pendingSince) {
        state[HPStPendingSinceKey] = pendingSince;
    } else {
        [state removeObjectForKey:HPStPendingSinceKey];
    }

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
