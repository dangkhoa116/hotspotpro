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

// No private API here on purpose. SpringBoard does hold the exact tethering
// connection count -- the number behind the green status bar, in
// _UIStatusBarDataTetheringEntry.connectionCount, with
// SBStatusBarStateAggregator._updateTetheringState as its change event -- and
// reading it would beat every heuristic in this file. It is deliberately not
// used: private names move between firmwares, and this tweak already runs on
// 15.4.1 through 17.0.2. Presence is derived from the ARP table and the
// daemon's own tap instead.

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
static NSMutableArray<UIAlertController *> *gAlertQueue;
static dispatch_source_t gRouteSource;
static int gRouteFD = -1;

static void HPCollectorSample(void);

// Whether the 10s timer is running. Written on the main thread, read by the
// routing-socket handler on the collector queue; a stale read only costs or
// saves one sample.
static volatile BOOL gTicking;

/// Present the next queued alert, if none is on screen. Main thread only.
static void HPPresentNextAlert(void) {
    @try {
        // An alert that went away without one of its buttons being tapped
        // must not hold up every alert after it — a held device nobody is
        // told about just sits there with no internet.
        if (gAlertWindow && !gAlertWindow.rootViewController.presentedViewController) {
            gAlertWindow.hidden = YES;
            gAlertWindow = nil;
        }
        if (gAlertWindow || !gAlertQueue.count) return;
        UIAlertController *alert = gAlertQueue.firstObject;
        [gAlertQueue removeObjectAtIndex:0];

        gAlertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gAlertWindow.windowLevel = UIWindowLevelAlert + 100;
        gAlertWindow.rootViewController = [UIViewController new];
        gAlertWindow.hidden = NO;
        [gAlertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    } @catch (NSException *e) {
        HPLog(@"alert failed: %@", e);
        gAlertWindow = nil;
    }
}

/// One button of an alert: its title, style, and what it does (may be nil).
static UIAlertAction *HPAlertAction(NSString *title, UIAlertActionStyle style,
                                    void (^handler)(void)) {
    return [UIAlertAction actionWithTitle:title style:style handler:^(UIAlertAction *a) {
        @try {
            if (handler) handler();
        } @catch (NSException *e) {
            HPLog(@"alert action failed: %@", e);
        }
        gAlertWindow.hidden = YES;
        gAlertWindow = nil;
        HPPresentNextAlert();
    }];
}

/// A plain UIKit alert on a window of our own. Deliberately not BulletinBoard:
/// this depends on no private class, so there is nothing to break on a
/// firmware where the notification internals differ.
///
/// Alerts queue rather than drop: a device held for approval that nobody is
/// told about would simply sit there with no internet.
static void HPShowAlertWithActions(NSString *title, NSString *message,
                                   NSArray *(^makeActions)(void),
                                   NSInteger preferred) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gAlertQueue) gAlertQueue = [NSMutableArray array];
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:title
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
            NSArray<UIAlertAction *> *actions = makeActions();
            for (UIAlertAction *action in actions) [alert addAction:action];
            if (preferred >= 0 && preferred < (NSInteger)actions.count) {
                alert.preferredAction = actions[preferred];
            }
            [gAlertQueue addObject:alert];
            HPPresentNextAlert();
        } @catch (NSException *e) {
            HPLog(@"alert failed: %@", e);
        }
    });
}

static void HPShowAlert(NSString *title, NSString *message) {
    HPShowAlertWithActions(title, message, ^{
        return @[ HPAlertAction(@"OK", UIAlertActionStyleDefault, nil) ];
    }, 0);
}

/// Write a decision about one device to the config, then sample at once so it
/// takes effect while the alert is still fading.
static void HPDecide(NSString *mac, BOOL allow) {
    HPConfigUpdate(^(NSMutableDictionary *cfg) {
        NSMutableDictionary *approved = [(cfg[HPCfgApprovedKey] ?: @{}) mutableCopy];
        approved[mac] = @YES;
        cfg[HPCfgApprovedKey] = approved;
        if (!allow) {
            NSMutableDictionary *blocks = [(cfg[HPCfgManualBlocksKey] ?: @{}) mutableCopy];
            blocks[mac] = @YES;
            cfg[HPCfgManualBlocksKey] = blocks;
        }
    });
    HPLog(@"%@ %@ from its alert", allow ? @"allowed" : @"blocked", mac);
    HPCollectorSample();
}

/// A device seen for the first time. Held ones need an answer; the rest are
/// news, shown only if the user wants to be told.
static void HPAnnounceJoined(NSDictionary *device) {
    NSString *mac = device[@"mac"];
    NSString *name = device[@"name"] ?: mac;
    NSString *ip = [device[@"ip"] length] ? device[@"ip"] : nil;
    NSString *who = ip ? [NSString stringWithFormat:@"“%@” (%@)", name, ip]
                       : [NSString stringWithFormat:@"“%@”", name];

    if ([device[@"pending"] boolValue]) {
        HPShowAlertWithActions(@"Allow New Device?",
            [NSString stringWithFormat:@"%@ joined your hotspot. It has no internet "
                                        "until you allow it.\n\nYou can also decide later "
                                        "in Settings › Personal Hotspot › Hotspot Usage.", who],
            ^{
                return @[
                    HPAlertAction(@"Block", UIAlertActionStyleDestructive, ^{ HPDecide(mac, NO); }),
                    HPAlertAction(@"Later", UIAlertActionStyleCancel, nil),
                    HPAlertAction(@"Allow", UIAlertActionStyleDefault, ^{ HPDecide(mac, YES); }),
                ];
            }, 2);
        return;
    }

    if (![HPConfig()[HPCfgAlertJoinsKey] boolValue]) return;
    HPShowAlertWithActions(@"New Device on Your Hotspot",
        [NSString stringWithFormat:@"%@ joined your hotspot for the first time.", who],
        ^{
            return @[
                HPAlertAction(@"Block", UIAlertActionStyleDestructive, ^{ HPDecide(mac, NO); }),
                HPAlertAction(@"OK", UIAlertActionStyleDefault, nil),
            ];
        }, 1);
}

/// Run the 10s timer only while there is something to count: the hotspot on
/// and somebody connected. Otherwise nothing runs on a clock at all — a sample
/// happens when the hotspot comes up or a device joins (routing messages),
/// when the daemon hears a client after going quiet, or when Settings asks.
/// Main thread only.
static void HPSetTicking(BOOL wanted) {
    if (wanted == (gCollectorTimer != nil)) return;
    if (wanted) {
        gCollectorTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                          repeats:YES
                                                            block:^(NSTimer *t) {
            HPCollectorSample();
        }];
        // Let the system fold this wake-up into others nearby.
        gCollectorTimer.tolerance = 2.0;
        HPLog(@"sampling every 10s: devices connected");
    } else {
        [gCollectorTimer invalidate];
        gCollectorTimer = nil;
        HPLog(@"sampling stopped: nobody connected");
    }
    gTicking = wanted;
}

static void HPCollectorSample(void) {
    dispatch_async(gCollectorQueue, ^{
        @try {
            NSDictionary *result = HPTick();
            BOOL busy = result && HPIPForwardingEnabled() && [result[HPTickDevicesKey] count] > 0;
            dispatch_async(dispatch_get_main_queue(), ^{ HPSetTicking(busy); });
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

            if (events & HPTickEventJoined) {
                for (NSDictionary *device in result[HPTickJoinedKey]) HPAnnounceJoined(device);
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

            if (events & HPTickEventDailyLimit) {
                NSArray *names = result[HPTickDailyKey];
                HPLog(@"daily limit: %@", [names componentsJoinedByString:@", "]);
                HPShowAlert(@"Daily Limit Reached",
                            [NSString stringWithFormat:
                                @"%@ used its data for today and can no longer use the "
                                 "hotspot. It is allowed again at midnight, or when you "
                                 "raise its daily limit.",
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
            // Settings asks for a sample the moment it needs one — a reset
            // otherwise sat waiting for the next 10s tick, which reads as the
            // button having done nothing.
            static int token;
            notify_register_dispatch(HPTickRequestNotification, &token,
                                     dispatch_get_main_queue(), ^(int t) {
                HPCollectorSample();
            });

            // A Settings pane is showing the figures: write them promptly.
            static int watchingToken;
            notify_register_dispatch(HPUIWatchingNotification, &watchingToken,
                                     gCollectorQueue, ^(int t) {
                HPTickNoteWatched();
            });

            // The daemon heard a client after a quiet spell. With nobody
            // connected this process runs no timer, so this is what brings it
            // back when a device that never left starts talking again.
            static int activityToken;
            notify_register_dispatch(HPDaemonActivityNotification, &activityToken,
                                     dispatch_get_main_queue(), ^(int t) {
                HPCollectorSample();
            });

            // Turning the hotspot on creates an interface and gives it an
            // address, and a device joining adds a neighbour; the kernel
            // announces each on a routing socket. That is what wakes this
            // process while no timer runs, so the first sample of a session
            // happens the moment there is something to count.
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

                    // With the hotspot off these are the phone's own networks
                    // moving — Wi-Fi neighbours, cellular — and there is nothing
                    // to count. One sysctl says so. A running timer still gets
                    // its sample, so switching the hotspot off is noticed.
                    if (!HPIPForwardingEnabled() && !gTicking) return;

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
                // Nothing to wake on, so fall back to looking once a minute.
                HPLog(@"route socket failed, polling once a minute: %s", strerror(errno));
                static NSTimer *fallback;
                fallback = [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES
                                                             block:^(NSTimer *t) {
                    if (HPIPForwardingEnabled() && !gTicking) HPCollectorSample();
                }];
                fallback.tolerance = 10.0;
            }

            HPLog(@"collector started in SpringBoard");
            HPCollectorSample();
        } @catch (NSException *e) {
            HPLog(@"collector start failed: %@", e);
        }
    });
}

#pragma mark - Entry

%ctor {
    @autoreleasepool {
        @try {
            // The filter plist already limits this dylib to SpringBoard, so the
            // bundle check is belt and braces rather than dispatch.
            HPStartCollector();
        } @catch (NSException *e) {
            HPLog(@"ctor failed: %@", e);
        }
    }
}
