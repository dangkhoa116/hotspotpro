#import "Prefs.h"
#include <notify.h>

NSString *const HPCfgEnabledKey     = @"enabled";
NSString *const HPCfgLimitGBKey     = @"limitGB";
NSString *const HPCfgResetDayKey    = @"resetDay";
NSString *const HPCfgWarnPercentKey = @"warnPercent";
NSString *const HPCfgNicknamesKey    = @"nicknames";
NSString *const HPCfgDeviceLimitsKey = @"deviceLimits";

NSString *const HPPrefsChangedNotification = @"com.dangkhoa.hotspotpro/prefschanged";
const char *const HPTickRequestNotification = "com.dangkhoa.hotspotpro/tick";

void HPPostTickRequest(void) {
    notify_post(HPTickRequestNotification);
}

NSString *const HPStTotalBytesKey   = @"totalBytes";
NSString *const HPStPeriodStartKey  = @"periodStart";
NSString *const HPStNextResetKey    = @"nextReset";
NSString *const HPStLastRawKey      = @"lastRaw";
NSString *const HPStBaselinedKey    = @"baselined";
NSString *const HPStLastDevRawKey   = @"lastDevRaw";
NSString *const HPStDevBaselinedKey = @"devBaselined";
NSString *const HPStWarnFiredKey    = @"warnFired";
NSString *const HPStLimitFiredKey   = @"limitFired";
NSString *const HPStHistoryKey      = @"history";
NSString *const HPStDevicesSeenKey  = @"devicesSeen";
NSString *const HPStDevicesNowKey   = @"devicesNow";
NSString *const HPStUpdatedKey      = @"updated";
NSString *const HPStIfNamesKey      = @"ifNames";
NSString *const HPStBlockedMacsKey  = @"blockedMacs";
NSString *const HPStResetRequestKey = @"resetRequested";

#pragma mark - Paths

NSString *HPConfigPath(void) {
    return @"/var/mobile/Library/Preferences/com.dangkhoa.hotspotpro.plist";
}

NSString *HPStatePath(void) {
    return @"/var/mobile/Library/Caches/hotspotpro-state.plist";
}

NSString *HPLogPath(void) {
    return @"/var/mobile/Library/Caches/hotspotpro.log";
}

NSString *HPBlocklistPath(void) {
    return @"/var/mobile/Library/Caches/hotspotpro-blocklist.plist";
}

#pragma mark - Config

NSDictionary *HPConfig(void) {
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:HPConfigPath()];
    NSMutableDictionary *cfg = [@{
        HPCfgEnabledKey     : @YES,
        HPCfgLimitGBKey     : @0.0,
        HPCfgResetDayKey    : @1,
        HPCfgWarnPercentKey : @80,
        HPCfgNicknamesKey    : @{},
        HPCfgDeviceLimitsKey : @{},
    } mutableCopy];
    if ([onDisk isKindOfClass:[NSDictionary class]]) [cfg addEntriesFromDictionary:onDisk];

    // Clamp the values a hand-edited plist could get wrong.
    NSInteger day = [cfg[HPCfgResetDayKey] integerValue];
    cfg[HPCfgResetDayKey] = @(MAX(1, MIN(31, day)));
    NSInteger warn = [cfg[HPCfgWarnPercentKey] integerValue];
    cfg[HPCfgWarnPercentKey] = @(MAX(1, MIN(100, warn)));
    if ([cfg[HPCfgLimitGBKey] doubleValue] < 0) cfg[HPCfgLimitGBKey] = @0.0;

    return cfg;
}

#pragma mark - State

NSMutableDictionary *HPStateLoad(void) {
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:HPStatePath()];
    if ([onDisk isKindOfClass:[NSDictionary class]]) return [onDisk mutableCopy];
    return [NSMutableDictionary dictionary];
}

BOOL HPStateSave(NSDictionary *state) {
    NSString *path = HPStatePath();
    NSString *tmp = [path stringByAppendingPathExtension:@"tmp"];

    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&err];
    if (!data) {
        HPLog(@"state serialise failed: %@", err);
        return NO;
    }
    if (![data writeToFile:tmp atomically:NO]) return NO;

    // rename(2) is atomic within a filesystem: readers see either the old file
    // or the new one, never a half-written one.
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:NULL];
    return [fm moveItemAtPath:tmp toPath:path error:NULL];
}

#pragma mark - Period maths

static NSDate *HPBoundaryInMonthOf(NSDate *date, NSInteger day, NSCalendar *cal) {
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth)
                                 fromDate:date];
    NSDate *monthStart = [cal dateFromComponents:c];
    NSRange days = [cal rangeOfUnit:NSCalendarUnitDay
                             inUnit:NSCalendarUnitMonth
                            forDate:monthStart];
    // resetDay=31 in a 30-day month lands on the 30th rather than skipping.
    c.day = MIN(day, (NSInteger)days.length);
    c.hour = 0; c.minute = 0; c.second = 0;
    return [cal dateFromComponents:c];
}

NSDate *HPNextResetDate(NSDate *date, NSInteger day) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *thisMonth = HPBoundaryInMonthOf(date, day, cal);
    if ([thisMonth compare:date] == NSOrderedDescending) return thisMonth;

    NSDateComponents *plus = [NSDateComponents new];
    plus.month = 1;
    NSDate *nextMonth = [cal dateByAddingComponents:plus toDate:thisMonth options:0];
    return HPBoundaryInMonthOf(nextMonth, day, cal);
}

NSDate *HPPeriodStartDate(NSDate *date, NSInteger day) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *thisMonth = HPBoundaryInMonthOf(date, day, cal);
    if ([thisMonth compare:date] != NSOrderedDescending) return thisMonth;

    NSDateComponents *minus = [NSDateComponents new];
    minus.month = -1;
    NSDate *prevMonth = [cal dateByAddingComponents:minus toDate:thisMonth options:0];
    return HPBoundaryInMonthOf(prevMonth, day, cal);
}

#pragma mark - Logging

void HPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                                                [fmt stringFromDate:[NSDate date]], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    NSString *path = HPLogPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [data writeToFile:path atomically:NO];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (NSException *e) {
        // A full disk or a yanked file is not worth taking the host process
        // down for — this runs inside SpringBoard later.
    }
    [fh closeFile];
}
