// HotspotPro — the SpringBoard half.
//
// Injected ONLY into com.apple.springboard. It folds interface counters into
// the persisted total and posts the soft-limit warnings; it reads sysctls and
// files and nothing else.
//
// Split from the Settings half deliberately. One dylib serving both processes
// meant SpringBoard loaded Preferences.framework — a private UI framework it
// otherwise never loads — during its own launch, before any of the @try/@catch
// below could run. The worst case of a bug in the UI code was therefore a phone
// that would not boot; now it is a Settings pane that misbehaves. Check it with
// tools/check-links.sh: this binary must NOT name Preferences.framework.
//
// Everything here is wrapped in @try/@catch. An uncaught exception on
// SpringBoard's main thread is a Safe Mode boot loop, and no usage counter is
// worth that.

#import <UIKit/UIKit.h>
#include <notify.h>
#include <sys/socket.h>
#import "Collector.h"
#import "Prefs.h"
#import "Tracker.h"
#pragma mark - Collector (SpringBoard)

static NSTimer *gCollectorTimer;
static dispatch_queue_t gCollectorQueue;
static UIWindow *gAlertWindow;
static dispatch_source_t gRouteSource;
static int gRouteFD = -1;

/// A plain UIKit alert on a window of our own. Deliberately not BulletinBoard:
/// this depends on no private class, so there is nothing to break on a
/// firmware where the notification internals differ.
static void HPShowAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gAlertWindow) return; // one at a time

            gAlertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            gAlertWindow.windowLevel = UIWindowLevelAlert + 100;
            gAlertWindow.rootViewController = [UIViewController new];
            gAlertWindow.hidden = NO;

            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:title
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                gAlertWindow.hidden = YES;
                gAlertWindow = nil;
            }]];
            [gAlertWindow.rootViewController presentViewController:alert
                                                          animated:YES
                                                        completion:nil];
        } @catch (NSException *e) {
            HPLog(@"alert failed: %@", e);
            gAlertWindow = nil;
        }
    });
}

static void HPCollectorSample(void) {
    dispatch_async(gCollectorQueue, ^{
        @try {
            NSDictionary *result = HPTick();
            if (!result) return;

            HPTickEvents events = [result[HPTickEventsKey] unsignedIntegerValue];
            if (events == HPTickEventNone) return;

            NSDictionary *cfg = HPConfig();
            uint64_t total = [result[HPTickTotalKey] unsignedLongLongValue];
            double limitGB = [cfg[HPCfgLimitGBKey] doubleValue];

            if (events & HPTickEventLimitFired) {
                HPLog(@"limit reached: %@ of %.2f GB", HPFormatBytes(total), limitGB);
                HPShowAlert(@"Hotspot Limit Reached",
                            [NSString stringWithFormat:
                                @"%@ of your %.2f GB hotspot allowance has been used.\n\n"
                                 "Personal Hotspot is still on — this is a reminder, not a cut-off.",
                                HPFormatBytes(total), limitGB]);
            } else if (events & HPTickEventWarnFired) {
                HPLog(@"warning threshold: %@ of %.2f GB", HPFormatBytes(total), limitGB);
                HPShowAlert(@"Hotspot Data Warning",
                            [NSString stringWithFormat:
                                @"%@ of your %.2f GB hotspot allowance has been used.",
                                HPFormatBytes(total), limitGB]);
            }

            if (events & HPTickEventBlocked) {
                NSArray *names = result[HPTickBlockedKey];
                HPLog(@"blocked: %@", [names componentsJoinedByString:@", "]);
                HPShowAlert(@"Device Blocked",
                            [NSString stringWithFormat:
                                @"%@ reached its data limit and can no longer use the "
                                 "hotspot. It is allowed again when the period resets, "
                                 "or when you clear its limit.",
                                [names componentsJoinedByString:@", "]]);
            }

            if (events & HPTickEventRolledOver) {
                HPLog(@"billing period rolled over");
            }
        } @catch (NSException *e) {
            HPLog(@"sample failed: %@", e);
        }
    });
}

static void HPStartCollector(void) {
    gCollectorQueue = dispatch_queue_create("com.dangkhoa.hotspotpro.collector",
                                            DISPATCH_QUEUE_SERIAL);
    // SpringBoard is busy during launch; there is nothing to measure in the
    // first few seconds anyway.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            gCollectorTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                              repeats:YES
                                                                block:^(NSTimer *t) {
                // With the hotspot off there is nothing to measure, yet the full
                // sample -- two kernel table walks, a lease-file parse and a
                // state write -- was running six times a minute forever. Check
                // the cheap signal every 10s so switching the hotspot on is
                // still noticed quickly, but only sample once a minute while it
                // is off.
                static int idleTicks = 0;
                if (!HPIPForwardingEnabled() && ++idleTicks < 6) return;
                idleTicks = 0;
                HPCollectorSample();
            }];

            // Settings asks for a sample the moment it needs one — a reset
            // otherwise sat waiting for the next 10s tick, which reads as the
            // button having done nothing.
            static int token;
            notify_register_dispatch(HPTickRequestNotification, &token,
                                     dispatch_get_main_queue(), ^(int t) {
                HPCollectorSample();
            });

            // Turning the hotspot on creates an interface and gives it an
            // address, and the kernel announces both on a routing socket. A
            // read source on that socket means the first sample of a session
            // happens at once, instead of up to a minute later when the idle
            // backoff above next comes round — so the timer can stay lazy
            // without the pane looking stale when someone starts sharing.
            gRouteFD = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
            if (gRouteFD >= 0) {
                gRouteSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                      (uintptr_t)gRouteFD, 0,
                                                      gCollectorQueue);
                dispatch_source_set_event_handler(gRouteSource, ^{
                    // Drain first: an undrained socket stops delivering, which
                    // would silently turn this back into timer-only polling.
                    char scratch[2048];
                    while (recv(gRouteFD, scratch, sizeof(scratch), MSG_DONTWAIT) > 0) { }

                    // Ordinary neighbour churn on whatever Wi-Fi network the
                    // phone is on also lands here, so this is rate-limited
                    // rather than sampling once per message. Safe as a plain
                    // static: the handler runs on the serial collector queue.
                    static NSDate *lastEventSample;
                    NSDate *now = [NSDate date];
                    if (lastEventSample &&
                        [now timeIntervalSinceDate:lastEventSample] < 5.0) return;
                    lastEventSample = now;
                    HPCollectorSample();
                });
                dispatch_resume(gRouteSource);
            } else {
                HPLog(@"route socket failed, timer only: %s", strerror(errno));
            }

            HPLog(@"collector started in SpringBoard");
            HPCollectorSample();
        } @catch (NSException *e) {
            HPLog(@"collector start failed: %@", e);
        }
    });
}

#pragma mark - Entry

// iOS 18 is untested and reported broken: users on 18.3.1 and 18.4.1 got
// resprings, safe mode, and a Settings app that refused to open. Working
// reports exist for 15.4.1, 16.5, 16.7 and 17.0.2.
//
// The package also refuses to install on 18 (see the firmware dependency in
// control); this gate is the second line, for anyone who force-installs or
// upgrades across the boundary.
static BOOL HPFirmwareUntested(void) {
    NSOperatingSystemVersion ios18 = { 18, 0, 0 };
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:ios18];
}

%ctor {
    @autoreleasepool {
        @try {
            // The filter plist already limits this dylib to SpringBoard, so the
            // bundle check is belt and braces rather than dispatch.
            if (HPFirmwareUntested()) {
                HPLog(@"iOS 18+ — collector disabled, firmware untested");
                return;
            }
            HPStartCollector();
        } @catch (NSException *e) {
            HPLog(@"ctor failed: %@", e);
        }
    }
}
