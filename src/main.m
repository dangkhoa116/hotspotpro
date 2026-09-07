// hotspotpro — the CLI half of HotspotPro.
//
// It exists because iOS 16.7 ships no ifconfig, netstat, arp or ndp, so the
// interface accounting cannot be measured from a shell: the measuring
// instrument has to be built. It shares every line of its collection code with
// the tweak, so what it measures is exactly what the tweak will count.

#import <Foundation/Foundation.h>
#import "Collector.h"
#import "Prefs.h"
#import "Tracker.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <unistd.h>

static void HPPrint(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void HPPrint(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("%s\n", [s UTF8String]);
}

#pragma mark - dump

static void HPPrintInterfaces(NSArray<NSDictionary *> *ifaces,
                              NSArray<NSString *> *counted) {
    HPPrint(@"%-12s %5s %4s %18s %18s  %s", "INTERFACE", "INDEX", "UP",
            "IN BYTES", "OUT BYTES", "");
    for (NSDictionary *i in ifaces) {
        NSString *name = i[HPIfNameKey];
        BOOL isCounted = [counted containsObject:name];
        uint64_t in = [i[HPIfInBytesKey] unsignedLongLongValue];
        uint64_t out = [i[HPIfOutBytesKey] unsignedLongLongValue];
        HPPrint(@"%-12s %5u %4s %18llu %18llu  %@%@",
                [name UTF8String],
                [i[HPIfIndexKey] unsignedIntValue],
                [i[HPIfUpKey] boolValue] ? "yes" : "no",
                in, out,
                isCounted ? @"<-- COUNTED  " : @"",
                (in || out) ? [NSString stringWithFormat:@"(%@ / %@)",
                                                        HPFormatBytes(in), HPFormatBytes(out)]
                            : @"");
    }
}

static void HPCommandDump(void) {
    NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
    NSArray<NSString *> *counted = HPHotspotInterfaceNames(ifaces);

    HPPrint(@"=== interfaces (%lu) ===", (unsigned long)ifaces.count);
    HPPrintInterfaces(ifaces, counted);

    HPPrint(@"\n=== hotspot accounting ===");
    if (counted.count == 0) {
        HPPrint(@"No hotspot interface is up. Turn Personal Hotspot on and attach a");
        HPPrint(@"client, then run this again — bridge100 should appear.");
    } else {
        HPPrint(@"Counting  : %@", [counted componentsJoinedByString:@", "]);
        HPPrint(@"Total     : %@ (in + out)",
                HPFormatBytes(HPTotalBytes(ifaces, counted)));
    }

    NSArray<NSDictionary *> *arp = HPCopyArpEntries();
    HPPrint(@"\n=== arp neighbours (%lu) ===", (unsigned long)arp.count);
    for (NSDictionary *e in arp) {
        HPPrint(@"  %-16s %-20s on %@",
                [e[HPDevIPKey] UTF8String], [e[HPDevMacKey] UTF8String],
                e[HPDevIfNameKey]);
    }

    NSArray<NSDictionary *> *leases = HPCopyDhcpLeases();
    HPPrint(@"\n=== dhcp leases (%lu) ===", (unsigned long)leases.count);
    for (NSDictionary *l in leases) {
        HPPrint(@"  %-24s %-16s %-20s expires %@",
                [(l[HPDevNameKey] ?: @"(no name)") UTF8String],
                [(l[HPDevIPKey] ?: @"?") UTF8String],
                [(l[HPDevMacKey] ?: @"?") UTF8String],
                l[HPDevLeaseEndKey] ?: @"?");
    }

    NSArray<NSDictionary *> *devices = HPCopyConnectedDevices(counted);
    HPPrint(@"\n=== connected devices (%lu) ===", (unsigned long)devices.count);
    for (NSDictionary *d in devices) {
        HPPrint(@"  %-24s %-16s %@",
                [(d[HPDevNameKey] ?: @"(unnamed)") UTF8String],
                [(d[HPDevIPKey] ?: @"?") UTF8String],
                d[HPDevMacKey]);
    }

    // The evidence behind "who is here now", printed raw. The list above is the
    // ARP table, which keeps a departed client's entry for the rest of its
    // lifetime; whether a device is shown as connected or as offline turns on
    // the numbers below, so this is the section to read when a device that is
    // plainly connected is being reported as offline.
    NSDate *now = [NSDate date];
    NSDate *tapSince = HPDaemonTapSince();
    NSDate *flush = HPDaemonLastFlush();
    NSDictionary<NSString *, NSDate *> *lastSeen = HPCopyDaemonLastSeen();
    HPPrint(@"\n=== daemon presence evidence ===");
    HPPrint(@"Tap open for : %@",
            tapSince ? [NSString stringWithFormat:@"%.0fs",
                                 [now timeIntervalSinceDate:tapSince]]
                     : @"no tap open");
    HPPrint(@"Last flush   : %@",
            flush ? [NSString stringWithFormat:@"%.0fs ago",
                              [now timeIntervalSinceDate:flush]]
                  : @"never (daemon not running?)");
    // Which of the two windows is in force, and why.
    BOOL probing = HPDaemonIsProbing();
    HPPrint(@"Probing      : %@ (window %.0fs)",
            probing ? @"yes, ARP request per client every 10s"
                    : @"no — passive, nothing is being asked",
            probing ? HPSilentCutoffProbed : HPSilentCutoff);
    if (lastSeen.count == 0) {
        HPPrint(@"No per-client timestamps — nothing can be ruled offline.");
    }
    for (NSString *mac in lastSeen) {
        HPPrint(@"  %-20s last frame %.0fs ago",
                [mac UTF8String], [now timeIntervalSinceDate:lastSeen[mac]]);
    }

    // Deliberately no verdict here. HPCopyPresentDevices() reaches one across
    // successive polls, so a one-shot process cannot ask it a fair question;
    // `hotspotpro status` reads the collector's answer, which was.
}

#pragma mark - watch

/// The measurement: record per-interval deltas for every plausible interface so
/// a download of known size can be matched against whichever counter moved.
///
/// `toLog` exists because of a hardware constraint: an iPhone 8 Plus has one
/// Wi-Fi radio, so switching Personal Hotspot on drops the phone off the home
/// network — and ios-mcp with it — for exactly the period being measured.
/// Detached and logging to a file, this survives the blackout and can be read
/// back once the phone rejoins.
static void HPCommandWatch(NSInteger seconds, BOOL toLog) {
    if (toLog) HPLog(@"watch started, interval %lds", (long)seconds);
    HPPrint(@"Watching every %lds. Ctrl-C to stop.", (long)seconds);
    HPPrint(@"Transfer a file of known size from a client and see which");
    HPPrint(@"interface's delta matches it.\n");

    NSMutableDictionary *prev = [NSMutableDictionary dictionary];
    NSMutableDictionary *cumulative = [NSMutableDictionary dictionary];

    while (1) {
        NSArray<NSDictionary *> *ifaces = HPCopyInterfaces();
        NSArray<NSDictionary *> *candidates = HPCopyInterfaceCandidates(ifaces);

        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *i in candidates) {
            NSString *name = i[HPIfNameKey];
            uint64_t cur = [i[HPIfInBytesKey] unsignedLongLongValue] +
                           [i[HPIfOutBytesKey] unsignedLongLongValue];
            NSNumber *before = prev[name];
            if (before) {
                uint64_t was = [before unsignedLongLongValue];
                uint64_t delta = (cur >= was) ? (cur - was) : cur;
                if (delta > 0) {
                    uint64_t run = [cumulative[name] unsignedLongLongValue] + delta;
                    cumulative[name] = @(run);
                    [line appendFormat:@"  %@ +%@ (run %@)", name,
                                       HPFormatBytes(delta), HPFormatBytes(run)];
                }
            }
            prev[name] = @(cur);
        }

        // Interfaces appearing or vanishing is itself the signal for when the
        // hotspot came up, so it is recorded even on an otherwise idle tick.
        NSArray<NSString *> *hotspot = HPHotspotInterfaceNames(ifaces);
        NSString *shape = [hotspot componentsJoinedByString:@","];
        static NSString *lastShape = nil;
        if (![shape isEqualToString:lastShape ?: @""]) {
            NSString *msg = [NSString stringWithFormat:@"hotspot interfaces now [%@]", shape];
            HPPrint(@"%@", msg);
            if (toLog) HPLog(@"%@", msg);
            lastShape = shape;
        }

        if (line.length) {
            HPPrint(@"%@%@", [[NSDate date] description], line);
            if (toLog) HPLog(@"%@", line);
        }
        sleep((unsigned int)seconds);
    }
}

#pragma mark - selftest

/// Exercises the reset/respring logic without needing a hotspot, because that
/// is the part most likely to silently corrupt a running total.
static int HPCommandSelftest(void) {
    __block int failures = 0;
    NSArray<NSString *> *names = @[ @"bridge100" ];

    NSDictionary *(^iface)(uint64_t, uint64_t) = ^(uint64_t in, uint64_t out) {
        return @{ HPIfNameKey     : @"bridge100",
                  HPIfIndexKey    : @1,
                  HPIfFlagsKey    : @0,
                  HPIfUpKey       : @YES,
                  HPIfInBytesKey  : @(in),
                  HPIfOutBytesKey : @(out) };
    };
    void (^check)(NSString *, uint64_t, uint64_t) =
        ^(NSString *what, uint64_t got, uint64_t want) {
            if (got == want) {
                HPPrint(@"  ok    %@ (%llu)", what, got);
            } else {
                HPPrint(@"  FAIL  %@: got %llu, want %llu", what, got, want);
                failures++;
            }
        };

    HPPrint(@"=== accumulation ===");
    NSMutableDictionary *last = [NSMutableDictionary dictionary];
    uint64_t total = 0;

    // First run baselines rather than importing a session already in progress.
    total += HPAccumulateDelta(last, @[ iface(1000, 2000) ], names, YES);
    check(@"first run baselines to zero", total, 0);

    total += HPAccumulateDelta(last, @[ iface(1500, 2500) ], names, NO);
    check(@"normal delta", total, 1000);

    // Hotspot toggled off and on: the bridge is recreated, counters restart.
    total += HPAccumulateDelta(last, @[ iface(100, 50) ], names, NO);
    check(@"counter reset counts the new value", total, 1150);

    total += HPAccumulateDelta(last, @[ iface(200, 100) ], names, NO);
    check(@"delta resumes after reset", total, 1300);

    // A respring loses memory but not the persisted lastRaw.
    NSMutableDictionary *afterRespring = [last mutableCopy];
    uint64_t t2 = total;
    t2 += HPAccumulateDelta(afterRespring, @[ iface(200, 100) ], names, NO);
    check(@"respring with no traffic adds nothing", t2, 1300);

    // Regression: ap1 survives hotspot toggles carrying a lifetime counter, so
    // an interface seen for the first time must be baselined, never imported.
    // Adding it put 761.5 MB of history into the period on first run.
    NSMutableDictionary *fresh = [NSMutableDictionary dictionary];
    uint64_t t3 = HPAccumulateDelta(fresh, @[ iface(400000000, 361500000) ], names, NO);
    check(@"first sight imports no history", t3, 0);
    t3 += HPAccumulateDelta(fresh, @[ iface(400001000, 361500500) ], names, NO);
    check(@"and counts only what follows", t3, 1500);

    HPPrint(@"\n=== period maths ===");
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [NSDateComponents new];
    c.year = 2026; c.month = 1; c.day = 15; c.hour = 12;
    NSDate *jan15 = [cal dateFromComponents:c];

    NSDate *next = HPNextResetDate(jan15, 1);
    NSDateComponents *nc = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                            NSCalendarUnitDay)
                                  fromDate:next];
    HPPrint(@"  next reset after 2026-01-15 with day=1 -> %04ld-%02ld-%02ld",
            (long)nc.year, (long)nc.month, (long)nc.day);
    if (!(nc.year == 2026 && nc.month == 2 && nc.day == 1)) failures++;

    // The clamp: day 31 must still fire in February.
    NSDate *feb = HPNextResetDate(jan15, 31);
    NSDateComponents *fc = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                            NSCalendarUnitDay)
                                  fromDate:feb];
    HPPrint(@"  next reset after 2026-01-15 with day=31 -> %04ld-%02ld-%02ld",
            (long)fc.year, (long)fc.month, (long)fc.day);
    if (!(fc.month == 1 && fc.day == 31)) failures++;

    NSDate *start = HPPeriodStartDate(jan15, 1);
    NSDateComponents *sc = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                            NSCalendarUnitDay)
                                  fromDate:start];
    HPPrint(@"  period containing 2026-01-15 with day=1 started %04ld-%02ld-%02ld",
            (long)sc.year, (long)sc.month, (long)sc.day);
    if (!(sc.year == 2026 && sc.month == 1 && sc.day == 1)) failures++;

    HPPrint(@"\n=== mac normalisation ===");
    NSString *mac = HPNormaliseMac(@"1,1e:7:67:bb:5b:3f");
    HPPrint(@"  '1,1e:7:67:bb:5b:3f' -> '%@'", mac);
    if (![mac isEqualToString:@"1e:07:67:bb:5b:3f"]) failures++;

    // --- presence ----------------------------------------------------------
    // Whether a connected device is shown as connected. The bug this pins is a
    // device that never left being reported offline and then online again: the
    // rule used to be "no captured frame in 30s means gone", and an idle client
    // is silent for far longer than that.
    HPPrint(@"\n=== presence ===");
    NSString *quiet = @"aa:bb:cc:dd:ee:01";
    NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *(^at)(NSTimeInterval) = ^(NSTimeInterval dt) {
        return [t0 dateByAddingTimeInterval:dt];
    };
    NSArray *(^arpWithExpire)(NSNumber *) = ^(NSNumber *expire) {
        return @[ @{ HPDevMacKey     : quiet,
                     HPDevIPKey      : @"172.20.10.5",
                     HPDevIfNameKey  : @"bridge100",
                     HPDevExpiresKey : expire } ];
    };
    NSArray *arp = arpWithExpire(@1000);
    // A tap that has been open far longer than either window, so silence counts.
    NSDate *tapSince = at(-10 * HPSilentCutoff);
    // Nothing heard from this client since long before the window began.
    NSDictionary *longAgo = @{ quiet : at(-10 * HPSilentCutoff) };

    void (^expect)(NSString *, NSUInteger, NSUInteger) =
        ^(NSString *what, NSUInteger got, NSUInteger want) {
            if (got == want) {
                HPPrint(@"  ok    %@ (%lu)", what, (unsigned long)got);
            } else {
                HPPrint(@"  FAIL  %@: got %lu, want %lu", what,
                        (unsigned long)got, (unsigned long)want);
                failures++;
            }
        };

    // Heard recently: present, however long ago anything else happened.
    NSMutableDictionary *books = [NSMutableDictionary dictionary];
    expect(@"a client heard 10s ago is present",
           HPFilterPresentDevices(arp, @{ quiet : at(-10) }, tapSince, at(0),
                                  NO, books, at(0)).count, 1);

    // Regression, the bug itself: an idle client, silent past the passive
    // window, whose ARP entry the kernel is still refreshing. Under the old
    // rule this device vanished from the list and came back on its next packet;
    // the refreshed expiry is independent evidence that it is still reachable.
    books = [NSMutableDictionary dictionary];
    HPFilterPresentDevices(arpWithExpire(@1000), longAgo, tapSince, at(0),
                           NO, books, at(0));
    for (int i = 1; i <= HPMissesNeeded + 1; i++) {
        NSArray *out = HPFilterPresentDevices(arpWithExpire(@(1000 + i * 30)), longAgo,
                                              tapSince, at(i), NO, books, at(i));
        if (out.count != 1) {
            HPPrint(@"  FAIL  idle client with a refreshed ARP entry dropped on poll %d", i);
            failures++;
            break;
        }
        if (i == HPMissesNeeded + 1) {
            HPPrint(@"  ok    an idle client the kernel still reaches stays present");
        }
    }

    // One silent poll is not a departure, and neither are two.
    books = [NSMutableDictionary dictionary];
    for (int i = 1; i < HPMissesNeeded; i++) {
        expect([NSString stringWithFormat:@"silent poll %d does not drop it", i],
               HPFilterPresentDevices(arp, longAgo, tapSince, at(i),
                                      NO, books, at(i)).count, 1);
    }
    // ...but a client with nothing to show for itself, poll after poll, is gone.
    expect(@"a client silent past the window is dropped",
           HPFilterPresentDevices(arp, longAgo, tapSince, at(HPMissesNeeded),
                                  NO, books, at(HPMissesNeeded)).count, 0);

    // Probing shortens the window without changing the rule: silence in the
    // face of unanswered ARP requests means more than silence alone.
    NSDictionary *quietAWhile = @{ quiet : at(-2 * HPSilentCutoffProbed) };
    books = [NSMutableDictionary dictionary];
    for (int i = 0; i <= HPMissesNeeded; i++) {
        HPFilterPresentDevices(arp, quietAWhile, tapSince, at(0), NO, books, at(i));
    }
    expect(@"90s of silence is not a departure when nobody is asking",
           HPFilterPresentDevices(arp, quietAWhile, tapSince, at(0),
                                  NO, books, at(HPMissesNeeded + 1)).count, 1);
    books = [NSMutableDictionary dictionary];
    for (int i = 0; i < HPMissesNeeded; i++) {
        HPFilterPresentDevices(arp, quietAWhile, tapSince, at(0), YES, books, at(i));
    }
    expect(@"...but it is when the client has been asked and did not answer",
           HPFilterPresentDevices(arp, quietAWhile, tapSince, at(0),
                                  YES, books, at(HPMissesNeeded)).count, 0);

    // The gates that must switch the rule off entirely: silence proves nothing
    // when nothing was listening.
    books = [NSMutableDictionary dictionary];
    for (int i = 0; i <= HPMissesNeeded; i++) {
        HPFilterPresentDevices(arp, longAgo, at(-1), at(0), NO, books, at(i));
    }
    expect(@"a tap open for less than the window rules nobody out",
           HPFilterPresentDevices(arp, longAgo, at(-1), at(0),
                                  NO, books, at(HPMissesNeeded + 1)).count, 1);

    books = [NSMutableDictionary dictionary];
    for (int i = 0; i <= HPMissesNeeded; i++) {
        HPFilterPresentDevices(arp, longAgo, tapSince, at(-2 * HPDaemonStaleAfter),
                               NO, books, at(i));
    }
    expect(@"a stale daemon heartbeat rules nobody out",
           HPFilterPresentDevices(arp, longAgo, tapSince, at(-2 * HPDaemonStaleAfter),
                                  NO, books, at(HPMissesNeeded + 1)).count, 1);

    books = [NSMutableDictionary dictionary];
    for (int i = 0; i <= HPMissesNeeded; i++) {
        HPFilterPresentDevices(arp, @{}, tapSince, at(0), NO, books, at(i));
    }
    expect(@"no daemon data at all rules nobody out",
           HPFilterPresentDevices(arp, @{}, tapSince, at(0),
                                  NO, books, at(HPMissesNeeded + 1)).count, 1);

    // Bookkeeping must not accumulate a row per randomised MAC forever.
    books = [NSMutableDictionary dictionary];
    HPFilterPresentDevices(arp, longAgo, tapSince, at(0), NO, books, at(0));
    HPFilterPresentDevices(@[], longAgo, tapSince, at(1), NO, books, at(1));
    NSUInteger left = 0;
    for (NSString *k in books) left += [books[k] count];
    expect(@"bookkeeping is forgotten with the ARP entry", left, 0);

    return failures;
}

#pragma mark - classes

/// Which notification API actually exists on this firmware. Answers it by
/// loading the framework and asking the runtime, rather than guessing from
/// what worked on some other iOS version.
static void HPCommandClasses(void) {
    NSArray *frameworks = @[
        @"/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard",
        @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        @"/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
        @"/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
    ];
    for (NSString *path in frameworks) {
        void *h = dlopen([path UTF8String], RTLD_LAZY);
        HPPrint(@"%-32s %@", [[path lastPathComponent] UTF8String],
                h ? @"loaded" : [NSString stringWithFormat:@"FAILED (%s)", dlerror()]);
    }

    HPPrint(@"");
    NSArray *classes = @[
        @"BBBulletinRequest", @"BBServer", @"SBUserNotificationCenter",
        @"SBSLocalNotificationClient", @"PSListController", @"PSSpecifier",
        @"WirelessModemBundleController",
    ];
    for (NSString *name in classes) {
        Class c = objc_getClass([name UTF8String]);
        HPPrint(@"  %-32s %@", [name UTF8String], c ? @"present" : @"absent");
    }
    HPPrint(@"\nNote: SpringBoard-only classes read 'absent' here because this is a");
    HPPrint(@"plain process. Presence is only meaningful for the frameworks above.");
}

#pragma mark - main

static void HPUsage(void) {
    HPPrint(@"hotspotpro — Personal Hotspot usage, devices and limits\n");
    HPPrint(@"  dump              interfaces, counters, arp, leases, devices,");
    HPPrint(@"                    and the evidence behind who counts as present");
    HPPrint(@"  watch [secs] [--log]  per-interval deltas (default 5) — the measurement");
    HPPrint(@"  tick              take one sample and fold it into state");
    HPPrint(@"  status            current period, limit and devices");
    HPPrint(@"  state             dump the raw state file");
    HPPrint(@"  reset             request a period reset (applied on the next tick)");
    HPPrint(@"  selftest          check the reset/rollover logic");
    HPPrint(@"  classes           which private frameworks and classes exist here");
    HPPrint(@"  paths             where config, state and the log live");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"dump";

        if ([cmd isEqualToString:@"dump"]) {
            HPCommandDump();
        } else if ([cmd isEqualToString:@"watch"]) {
            BOOL toLog = NO;
            for (int i = 2; i < argc; i++) {
                if (strcmp(argv[i], "--log") == 0) toLog = YES;
            }
            HPCommandWatch(argc > 2 ? MAX(1, atoi(argv[2])) : 5, toLog);
        } else if ([cmd isEqualToString:@"tick"]) {
            NSDictionary *r = HPTick();
            if (!r) {
                HPPrint(@"disabled in config");
            } else {
                HPPrint(@"added %@, period total %@, interfaces [%@], %lu device(s), events 0x%lx",
                        HPFormatBytes([r[HPTickAddedKey] unsignedLongLongValue]),
                        HPFormatBytes([r[HPTickTotalKey] unsignedLongLongValue]),
                        [r[HPTickIfNamesKey] componentsJoinedByString:@", "],
                        (unsigned long)[r[HPTickDevicesKey] count],
                        (unsigned long)[r[HPTickEventsKey] unsignedLongValue]);
            }
        } else if ([cmd isEqualToString:@"status"]) {
            printf("%s", [HPStatusReport() UTF8String]);
        } else if ([cmd isEqualToString:@"state"]) {
            HPPrint(@"%@", HPStateLoad());
        } else if ([cmd isEqualToString:@"reset"]) {
            NSMutableDictionary *state = HPStateLoad();
            state[HPStResetRequestKey] = @YES;
            HPPrint(@"%@", HPStateSave(state) ? @"reset requested" : @"could not write state");
        } else if ([cmd isEqualToString:@"selftest"]) {
            int failures = HPCommandSelftest();
            HPPrint(@"\n%@", failures ? [NSString stringWithFormat:@"%d FAILURE(S)", failures]
                                      : @"all checks passed");
            return failures ? 1 : 0;
        } else if ([cmd isEqualToString:@"classes"]) {
            HPCommandClasses();
        } else if ([cmd isEqualToString:@"paths"]) {
            HPPrint(@"config %@", HPConfigPath());
            HPPrint(@"state  %@", HPStatePath());
            HPPrint(@"log    %@", HPLogPath());
        } else {
            HPUsage();
            return 1;
        }
    }
    return 0;
}
