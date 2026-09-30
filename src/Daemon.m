// hotspotprod — the per-device byte counter.
//
// Runs as root from a LaunchDaemon, because per-client accounting is the one
// thing in HotspotPro the kernel will not tell an unprivileged process. It taps
// the tethering bridge with BPF and counts frames per client MAC, then writes a
// world-readable plist the tweak folds into its state.
//
// Cost: the BPF filter returns 14, so the kernel copies only the Ethernet
// header of each frame — the full length still arrives in bh_datalen, so the
// numbers are exact. Reads are batched out of a 32 KB buffer, so this wakes a
// few times a second under load, not once per packet. With no hotspot up it
// polls the interface list every 5s and does nothing else.

#import <Foundation/Foundation.h>
#import "Collector.h"
#import "Prefs.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <notify.h>

#pragma mark - BPF, declared here because the SDK ships no <net/bpf.h>

#define HP_BIOCSBLEN     _IOWR('B', 102, u_int)
#define HP_BIOCSETF      _IOW ('B', 103, struct hp_bpf_program)
#define HP_BIOCFLUSH     _IO  ('B', 104)
#define HP_BIOCGDLT      _IOR ('B', 106, u_int)
#define HP_BIOCSETIF     _IOW ('B', 108, struct ifreq)
#define HP_BIOCSRTIMEOUT _IOW ('B', 109, struct timeval)
#define HP_BIOCIMMEDIATE _IOW ('B', 112, u_int)
#define HP_BIOCSSEESENT  _IOW ('B', 118, u_int)

#define HP_DLT_EN10MB 1

struct hp_bpf_insn {
    u_short code;
    u_char  jt;
    u_char  jf;
    uint32_t k;
};

struct hp_bpf_program {
    u_int bf_len;
    struct hp_bpf_insn *bf_insns;
};

// Only the field offsets matter here, and those are stable: a 32-bit timeval,
// then caplen, datalen, hdrlen. The kernel's own bh_hdrlen is what we use to
// step over the header, so this struct's size never has to be exactly right.
struct hp_bpf_hdr {
    int32_t  bh_tv_sec;
    int32_t  bh_tv_usec;
    uint32_t bh_caplen;
    uint32_t bh_datalen;
    u_short  bh_hdrlen;
};

#define HP_BPF_WORDALIGN(x) (((x) + (sizeof(int32_t) - 1)) & ~(sizeof(int32_t) - 1))

static const size_t kBufferSize = 32768;
static const NSTimeInterval kFlushInterval = 10.0;

// How long the tap may hear nothing from any client before the daemon goes
// idle. Longer than the collector's presence window (4 minutes), so every
// device has been judged gone before the heartbeat stops.
static const NSTimeInterval kIdleAfter = 300.0;

// How often, at most, the loop re-reads config, re-applies the blocklist and
// looks for the bridge when nothing has told it to. Under load the loop comes
// round several times a second, once per filled buffer.
static const NSTimeInterval kChoresInterval = 5.0;

#pragma mark - State

static NSMutableDictionary<NSString *, NSNumber *> *gBytesByMac;
// The same totals split by direction. Upload is what the client SENT (a frame
// whose source is the client); download is what it RECEIVED. They sum to
// gBytesByMac, which is kept as-is so the per-device limit logic and older
// readers are untouched.
static NSMutableDictionary<NSString *, NSNumber *> *gUploadByMac;
static NSMutableDictionary<NSString *, NSNumber *> *gDownloadByMac;
static NSMutableDictionary<NSString *, NSDate *> *gLastSeenByMac;
static NSMutableSet<NSString *> *gTouchedMacs;
// When the tap now open was opened, or nil while there is none. Published so
// readers can tell "this client has been silent" from "nobody was listening":
// after a bridge flap every per-client timestamp is stale at once, and a reader
// that could not see the difference declared connected devices departed.
static NSDate *gTapSince;

// Whether the open tap was given a read timeout, so a partly filled buffer is
// delivered within seconds instead of only once 32 KB of headers have piled
// up. Only a tap that does this can be left to wake the daemon on its own.
static BOOL gTapTimesOut;
// When a client last sent a frame, and whether the daemon has gone idle for
// want of one. Idle means no timer at all: the daemon sleeps until a frame, a
// routing message or a notification arrives.
static CFAbsoluteTime gLastClientFrame;
static BOOL gIdle;
// A client spoke after a minute or more of silence — back from sleep, back in
// range, or new. The collector stops sampling while nobody is connected, so it
// is told at once rather than finding out on a heartbeat it is not reading.
static BOOL gClientReturned;
static const NSTimeInterval kReturnAfter = 60.0;

// MAC -> IP for every block this daemon has installed. Declared here, up with
// the other state, because the flush publishes its keys — it is read well
// before the blocking section that maintains it is reached in the file.
static NSMutableDictionary<NSString *, NSString *> *gInstalledBlocks;

// A client with a randomised MAC mints a new entry every time it reconnects, so
// without a bound this file would grow for the life of the install.
static const NSTimeInterval kMaxDeviceAge = 60 * 60 * 24 * 45;   // 45 days
static const NSUInteger kMaxDevices = 200;

static void HPDaemonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void HPDaemonLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    HPLog(@"[daemon] %@", msg);
}

/// Record what the daemon is doing right now. No-op when the state has not
/// changed since the last call, so it is safe to call from inside the loop.
///
/// A one-line breadcrumb saying what this process is doing, so the UI and CLI
/// can explain why per-device figures or blocking are absent instead of only
/// showing "helper not running". Written on startup and at each state change —
/// never in a tight loop — so it cannot become the 8,600-writes-a-day problem
/// the state file once was. Its absence means the binary never ran at all, which
/// is itself the answer (a LaunchDaemon that never bootstrapped, or a signature
/// the device refused to exec).
static void HPWriteDaemonStatus(NSString *state) {
    static NSString *last;
    if ([state isEqualToString:last]) return;
    last = state;
    @try {
        NSDictionary *payload = @{
            @"state"    : state,
            @"pid"      : @(getpid()),
            @"firmware" : [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"?",
            @"updated"  : [NSDate date],
        };
        NSString *statusPath = HPDaemonStatusPath();
        [payload writeToFile:statusPath atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions : @0644 }
                                         ofItemAtPath:statusPath error:NULL];
    } @catch (NSException *e) {
        HPDaemonLog(@"status write failed: %@", e);
    }
}

/// Forget devices that stopped appearing long ago, and cap the total.
static void HPPruneDevices(void) {
    NSDate *now = [NSDate date];

    NSMutableArray *expired = [NSMutableArray array];
    for (NSString *mac in gLastSeenByMac) {
        if ([now timeIntervalSinceDate:gLastSeenByMac[mac]] > kMaxDeviceAge) {
            [expired addObject:mac];
        }
    }
    for (NSString *mac in expired) {
        [gBytesByMac removeObjectForKey:mac];
        [gUploadByMac removeObjectForKey:mac];
        [gDownloadByMac removeObjectForKey:mac];
        [gLastSeenByMac removeObjectForKey:mac];
    }

    if (gBytesByMac.count <= kMaxDevices) {
        if (expired.count) HPDaemonLog(@"pruned %lu stale device(s)",
                                       (unsigned long)expired.count);
        return;
    }

    // Still too many: drop the least recently seen first.
    NSArray *byAge = [gLastSeenByMac.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            return [gLastSeenByMac[a] compare:gLastSeenByMac[b]];
        }];
    NSUInteger excess = gBytesByMac.count - kMaxDevices;
    for (NSUInteger i = 0; i < excess && i < byAge.count; i++) {
        [gBytesByMac removeObjectForKey:byAge[i]];
        [gUploadByMac removeObjectForKey:byAge[i]];
        [gDownloadByMac removeObjectForKey:byAge[i]];
        [gLastSeenByMac removeObjectForKey:byAge[i]];
    }
    HPDaemonLog(@"capped device table to %lu entries", (unsigned long)gBytesByMac.count);
}

/// Counters are written where the tweak (running as mobile) can read them.
static void HPFlushCounters(void) {
    @try {
        // Stamp only the devices that actually moved data since the last flush,
        // so timestamps cost nothing per packet.
        NSDate *now = [NSDate date];
        for (NSString *mac in gTouchedMacs) gLastSeenByMac[mac] = now;
        [gTouchedMacs removeAllObjects];
        HPPruneDevices();

        NSString *devicesPath = HPDevicesPath();
        NSString *tmp = [devicesPath stringByAppendingPathExtension:@"tmp"];
        NSMutableDictionary *payload = [@{
            @"bytesByMac"   : gBytesByMac,
            @"uploadByMac"  : gUploadByMac,
            @"downloadByMac": gDownloadByMac,
            @"lastSeenByMac": gLastSeenByMac,
            @"updated"      : [NSDate date],
        } mutableCopy];
        // Absent rather than null while there is no tap, so a reader that finds
        // it knows a tap was open at the moment this was written.
        if (gTapSince) payload[@"tapSince"] = gTapSince;
        // Idle: still listening, but nothing has been heard from any client
        // for minutes, so the heartbeat has stopped. Readers treat the silence
        // as current rather than as a daemon that died.
        if (gIdle) payload[@"idle"] = @YES;
        // The MACs a reject route is actually installed for right now, so the
        // UI can tell "the tracker wants this blocked" from "the block is
        // really in place". They diverge when this daemon is not running or
        // cannot write routes on this firmware, which is exactly the case that
        // showed "Blocked" over a device that still had working internet.
        payload[@"installedBlocks"] = [gInstalledBlocks allKeys];
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:NULL];
        if (!data || ![data writeToFile:tmp atomically:NO]) return;
        // Written by root, read by the tweak inside SpringBoard and Preferences.
        // Set on the temp file, so the file readers find is never briefly 0600.
        [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions : @0644 }
                                         ofItemAtPath:tmp
                                                error:NULL];
        // rename(2) replaces the old file in one step. This used to delete the
        // old file and then move the new one in, and a reader landing between
        // the two found no file at all — every 10 seconds. The tracker took
        // that as "no devices", forgot every baseline, and re-imported each
        // device's whole running figure on the next read.
        if (rename([tmp fileSystemRepresentation], [devicesPath fileSystemRepresentation]) != 0) {
            HPDaemonLog(@"flush rename: %s", strerror(errno));
        }
    } @catch (NSException *e) {
        HPDaemonLog(@"flush failed: %@", e);
    }
}

#pragma mark - Blocking

/// Install or remove a reject route for one hotspot client.
///
/// A host route to nowhere is used rather than pf: pf would mean driving
/// `pf_rule` through raw ioctls with no pfctl on the device to check against,
/// while the routing socket needs only the message header already proven by the
/// ARP reader. The phone simply stops being able to route to that client.
static BOOL HPSetRouteBlock(NSString *ip, BOOL blocked) {
    // Refuse to touch anything outside the hotspot's own subnet. A stray route
    // elsewhere in the table could take the phone's own networking down.
    if (![ip hasPrefix:@"172.20.10."]) {
        HPDaemonLog(@"refusing to route-block %@ (outside hotspot subnet)", ip);
        return NO;
    }

    int sock = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (sock < 0) {
        HPDaemonLog(@"route socket: %s", strerror(errno));
        return NO;
    }

    static int sequence = 0;
    struct {
        struct hp_rt_msghdr hdr;
        struct sockaddr_in dst;
        struct sockaddr_in gateway;
    } msg;
    memset(&msg, 0, sizeof(msg));

    msg.hdr.rtm_msglen  = sizeof(msg);
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_type    = blocked ? RTM_ADD : RTM_DELETE;
    msg.hdr.rtm_flags   = RTF_UP | RTF_HOST | RTF_STATIC | RTF_REJECT;
    msg.hdr.rtm_addrs   = RTA_DST | RTA_GATEWAY;
    msg.hdr.rtm_seq     = ++sequence;
    msg.hdr.rtm_pid     = getpid();

    msg.dst.sin_len    = sizeof(struct sockaddr_in);
    msg.dst.sin_family = AF_INET;
    inet_pton(AF_INET, [ip UTF8String], &msg.dst.sin_addr);

    msg.gateway.sin_len         = sizeof(struct sockaddr_in);
    msg.gateway.sin_family      = AF_INET;
    msg.gateway.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    ssize_t written = write(sock, &msg, msg.hdr.rtm_msglen);
    int failure = (written < 0) ? errno : 0;
    close(sock);

    // EEXIST on add and ESRCH on delete both mean the table already says what
    // we want it to say.
    if (failure && failure != EEXIST && failure != ESRCH) {
        HPDaemonLog(@"route %@ %@: %s", blocked ? @"block" : @"unblock", ip,
                    strerror(failure));
        return NO;
    }
    // Announce only a real change (failure 0). EEXIST/ESRCH mean nothing moved,
    // so the whole-subnet sweep below can call this for every client address
    // without filling the log with "unblocked" lines for routes that were never
    // there.
    if (failure == 0) HPDaemonLog(@"%@ %@", blocked ? @"blocked" : @"unblocked", ip);
    return YES;
}

/// Delete any reject route sitting on a hotspot client address, tracked or not.
///
/// iOS hands clients 172.20.10.2 .. .14 (a /28, .1 is the phone, .15 broadcast),
/// so sweeping that whole range clears a block no matter how it got there.
/// This is the backstop that makes a block impossible to strand: a daemon
/// killed between installing a route and recording it leaves an orphan that
/// gInstalledBlocks and the installed-plist never knew about, which used to
/// survive until a reboot. Deleting a route that is not there is a harmless
/// ESRCH, so this is safe to run unconditionally.
static void HPSweepHotspotRejectRoutes(void) {
    for (int host = 2; host <= 14; host++) {
        HPSetRouteBlock([NSString stringWithFormat:@"172.20.10.%d", host], NO);
    }
}

static void HPSaveInstalledBlocks(void) {
    [gInstalledBlocks writeToFile:HPInstalledBlocksPath() atomically:YES];
}

static NSDictionary *gSavedBlocks;

/// Write the installed-blocks file only when it would say something new. It
/// was rewritten on every pass of the loop — several times a second under load.
static void HPSaveInstalledBlocksIfChanged(void) {
    if (gSavedBlocks && [gSavedBlocks isEqualToDictionary:gInstalledBlocks]) return;
    HPSaveInstalledBlocks();
    gSavedBlocks = [gInstalledBlocks copy];
}

/// Bring the routing table in line with the collector's blocklist.
static void HPApplyBlocklist(void) {
    @try {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:HPBlocklistPath()];
        NSArray *wanted = file[@"blocked"];
        if (![wanted isKindOfClass:[NSArray class]]) wanted = @[];

        NSMutableDictionary *desired = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in wanted) {
            NSString *mac = entry[@"mac"], *ip = entry[@"ip"];
            if (mac.length && ip.length) desired[mac] = ip;
        }

        for (NSString *mac in [gInstalledBlocks.allKeys copy]) {
            if (desired[mac] && [desired[mac] isEqualToString:gInstalledBlocks[mac]]) continue;
            // Gone from the list, or the device moved to a different address.
            if (HPSetRouteBlock(gInstalledBlocks[mac], NO)) {
                [gInstalledBlocks removeObjectForKey:mac];
            }
        }

        for (NSString *mac in desired) {
            if (gInstalledBlocks[mac]) continue;
            if (HPSetRouteBlock(desired[mac], YES)) gInstalledBlocks[mac] = desired[mac];
        }

        HPSaveInstalledBlocksIfChanged();

        // Self-heal, at most once a minute: delete any reject route on a client
        // address that is NOT currently meant to be blocked. The loop above
        // only touches routes this process tracks; this also clears an orphan
        // left by a killed daemon, so no route can strand a device for more
        // than about a minute even while the daemon runs on without restarting.
        // It never deletes a wanted block (those IPs are skipped), and if the
        // list read ever came back short it errs toward giving a device its
        // connection back rather than cutting one off — the safe direction.
        static NSDate *lastHeal;
        NSDate *now = [NSDate date];
        if (!lastHeal || [now timeIntervalSinceDate:lastHeal] >= 60.0) {
            lastHeal = now;
            NSSet *keep = [NSSet setWithArray:[desired allValues]];
            for (int host = 2; host <= 14; host++) {
                NSString *ip = [NSString stringWithFormat:@"172.20.10.%d", host];
                if (![keep containsObject:ip]) HPSetRouteBlock(ip, NO);
            }
        }
    } @catch (NSException *e) {
        HPDaemonLog(@"blocklist apply failed: %@", e);
    }
}

/// Empty the routing socket's queue.
///
/// The message contents do not matter: any of them means the network
/// configuration moved, which is the cue to re-check the interfaces. What does
/// matter is draining them — a socket left full stops delivering, and with it
/// the wake-ups this daemon now depends on. Our own block/unblock writes come
/// back here too, which is harmless.
static void HPDrainRouteSocket(int rs) {
    char scratch[2048];
    while (recv(rs, scratch, sizeof(scratch), MSG_DONTWAIT) > 0) { }
}

/// Routes outlive the process, so anything left behind by a crash or an upgrade
/// is torn down before we start — otherwise a device could stay cut off with
/// nothing left that knows why.
static void HPClearStaleBlocks(void) {
    NSString *installedPath = HPInstalledBlocksPath();
    NSDictionary *stale = [NSDictionary dictionaryWithContentsOfFile:installedPath];
    if (![stale isKindOfClass:[NSDictionary class]] || stale.count == 0) return;

    HPDaemonLog(@"clearing %lu route block(s) left from a previous run",
                (unsigned long)stale.count);
    for (NSString *mac in stale) HPSetRouteBlock(stale[mac], NO);
    [[NSFileManager defaultManager] removeItemAtPath:installedPath error:NULL];
}

#pragma mark - Capture

static NSString *HPMacString(const unsigned char *m) {
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                                      m[0], m[1], m[2], m[3], m[4], m[5]];
}

/// The tethering bridge, or nil when the hotspot is off.
static NSDictionary *HPFindBridge(void) {
    for (NSDictionary *i in HPCopyInterfaces()) {
        if (![i[HPIfUpKey] boolValue]) continue;
        NSString *n = i[HPIfNameKey];
        if ([n hasPrefix:@"bridge"] && [[n substringFromIndex:6] integerValue] >= 100) {
            return i;
        }
    }
    return nil;
}

/// Open a free /dev/bpfN bound to `ifname`. Returns -1 on failure.
static int HPOpenBPF(NSString *ifname) {
    // Read-only: this tap only ever reads frames to count them. It does not
    // write anything to the interface.
    int fd = -1;
    for (int i = 0; i < 32; i++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/bpf%d", i);
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        if (errno != EBUSY && errno != EPERM && errno != EACCES) {
            // ENOENT means we ran past the last node; anything else is worth a look.
            if (errno != ENOENT) HPDaemonLog(@"open %s: %s", path, strerror(errno));
        }
    }
    if (fd < 0) {
        HPDaemonLog(@"no usable /dev/bpf device (running as uid %d)", getuid());
        return -1;
    }

    u_int blen = (u_int)kBufferSize;
    if (ioctl(fd, HP_BIOCSBLEN, &blen) < 0) {
        HPDaemonLog(@"BIOCSBLEN: %s", strerror(errno));
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, [ifname UTF8String], sizeof(ifr.ifr_name));
    if (ioctl(fd, HP_BIOCSETIF, &ifr) < 0) {
        HPDaemonLog(@"BIOCSETIF %@: %s", ifname, strerror(errno));
        close(fd);
        return -1;
    }

    u_int dlt = 0;
    if (ioctl(fd, HP_BIOCGDLT, &dlt) == 0 && dlt != HP_DLT_EN10MB) {
        HPDaemonLog(@"unexpected datalink %u on %@, expected Ethernet", dlt, ifname);
        close(fd);
        return -1;
    }

    // Count traffic the phone sends to clients too, not just what it receives.
    u_int on = 1;
    ioctl(fd, HP_BIOCSSEESENT, &on);

    // Capture just the Ethernet header: this is what keeps the tap cheap, while
    // bh_datalen still reports each frame's true length.
    static struct hp_bpf_insn insns[] = {
        { 0x06, 0, 0, 14 },  // BPF_RET | BPF_K : accept, snap to 14 bytes
    };
    struct hp_bpf_program prog = { .bf_len = 1, .bf_insns = insns };
    if (ioctl(fd, HP_BIOCSETF, &prog) < 0) {
        HPDaemonLog(@"BIOCSETF: %s", strerror(errno));
    }

    // Batched, not immediate: frames are delivered a buffer at a time, not
    // one wake-up per packet. The read timeout bounds how long a partly filled
    // buffer waits: without it, light traffic sat in the kernel until 32 KB of
    // headers had built up — minutes, for a device only browsing — and both
    // its bytes and its presence arrived that late.
    u_int immediate = 0;
    ioctl(fd, HP_BIOCIMMEDIATE, &immediate);
    struct timeval rtimeout = { .tv_sec = 2, .tv_usec = 0 };
    gTapTimesOut = (ioctl(fd, HP_BIOCSRTIMEOUT, &rtimeout) == 0);
    if (!gTapTimesOut) HPDaemonLog(@"BIOCSRTIMEOUT: %s — staying on a timer", strerror(errno));
    ioctl(fd, HP_BIOCFLUSH);

    HPDaemonLog(@"tapping %@ (fd %d, buffer %u bytes)", ifname, fd, blen);
    return fd;
}

/// A MAC as a 48-bit number, so frames can be sorted by client without
/// building an object per frame.
static uint64_t HPMacBits(const unsigned char *m) {
    return ((uint64_t)m[0] << 40) | ((uint64_t)m[1] << 32) | ((uint64_t)m[2] << 24) |
           ((uint64_t)m[3] << 16) | ((uint64_t)m[4] << 8) | (uint64_t)m[5];
}

/// "aa:bb:cc:dd:ee:ff" as HPMacBits, or UINT64_MAX (never a real MAC) if it
/// does not parse.
static uint64_t HPMacBitsFromString(NSString *mac) {
    unsigned int b[6];
    if (mac.length == 0 ||
        sscanf([mac UTF8String], "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return UINT64_MAX;
    }
    unsigned char bytes[6];
    for (int i = 0; i < 6; i++) bytes[i] = (unsigned char)b[i];
    return HPMacBits(bytes);
}

/// One client's frames in the buffer being read.
typedef struct {
    uint64_t mac;
    uint64_t up, down;
    BOOL sent;      // it sent at least one frame: evidence it is here
} HPTally;

enum { kHPMaxTallies = 32 };

/// Add a buffer's tallies to the running counters. This is the only place
/// objects are made, once per client per buffer rather than per frame: at
/// full speed a buffer holds about a thousand frames.
static void HPFoldTallies(HPTally *tally, size_t count) {
    for (size_t i = 0; i < count; i++) {
        unsigned char m[6];
        for (int b = 0; b < 6; b++) m[b] = (unsigned char)(tally[i].mac >> (8 * (5 - b)));
        NSString *client = HPMacString(m);
        uint64_t both = tally[i].up + tally[i].down;
        if (both) {
            gBytesByMac[client] = @([gBytesByMac[client] unsignedLongLongValue] + both);
            // A frame the client sent is its upload; one sent toward it is its
            // download. The two sum back to gBytesByMac.
            if (tally[i].up) {
                gUploadByMac[client] = @([gUploadByMac[client] unsignedLongLongValue] + tally[i].up);
            }
            if (tally[i].down) {
                gDownloadByMac[client] = @([gDownloadByMac[client] unsignedLongLongValue] + tally[i].down);
            }
        }
        if (tally[i].sent) {
            NSDate *last = gLastSeenByMac[client];
            if (![gTouchedMacs containsObject:client] &&
                (!last || -[last timeIntervalSinceNow] >= kReturnAfter)) {
                gClientReturned = YES;
            }
            [gTouchedMacs addObject:client];
            gLastClientFrame = CFAbsoluteTimeGetCurrent();
        }
    }
}

static void HPConsume(const char *buf, ssize_t len, uint64_t bridgeMac) {
    const char *p = buf;
    const char *end = buf + len;
    HPTally tally[kHPMaxTallies];
    size_t used = 0;

    while (p + sizeof(struct hp_bpf_hdr) <= end) {
        const struct hp_bpf_hdr *bh = (const struct hp_bpf_hdr *)p;
        if (bh->bh_hdrlen == 0) break;

        const unsigned char *frame = (const unsigned char *)p + bh->bh_hdrlen;
        if ((const char *)frame + 12 <= end && bh->bh_caplen >= 12) {
            uint64_t dst = HPMacBits(frame);
            uint64_t src = HPMacBits(frame + 6);

            // Whichever end is not the bridge itself is the client. Broadcast
            // and multicast (the group bit, the low bit of the first octet)
            // are not devices.
            BOOL fromClient = (src != bridgeMac);
            uint64_t client = fromClient ? src : dst;
            BOOL isGroupAddress = ((client >> 40) & 0x01) != 0;
            // The snap length is 14, so the ethertype is always in hand.
            BOOL isArp = bh->bh_caplen >= 14 && (const char *)frame + 14 <= end &&
                         frame[12] == 0x08 && frame[13] == 0x06;

            if (!isGroupAddress && client != bridgeMac) {
                size_t i = 0;
                while (i < used && tally[i].mac != client) i++;
                if (i == used) {
                    if (used == kHPMaxTallies) {   // more clients than iOS allows; fold and go on
                        HPFoldTallies(tally, used);
                        used = 0;
                        i = 0;
                    }
                    tally[used++] = (HPTally){ .mac = client };
                }
                // An ARP frame the phone sent is a presence probe: this
                // daemon's own overhead, not the client's traffic. Counting
                // those would trickle our bytes onto every device's total for
                // as long as the hotspot was up.
                if (fromClient) tally[i].up += bh->bh_datalen;
                else if (!isArp) tally[i].down += bh->bh_datalen;
                // Bytes are counted in both directions; presence is not. Only a
                // frame the client SENT is evidence that it is here — a frame
                // the phone sent toward it proves nothing, least of all a
                // probe, which would otherwise answer its own question.
                if (fromClient) tally[i].sent = YES;
            }
        }

        size_t advance = HP_BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
        if (advance == 0) break;
        p += advance;
    }
    HPFoldTallies(tally, used);
}

#pragma mark - Main loop

/// Empty the blocklist notification's descriptor. Each post arrives as a 4-byte
/// token; what matters is only that one came, and that the queue is drained.
static void HPDrainNotify(int nfd) {
    int token;
    while (read(nfd, &token, sizeof(token)) == sizeof(token)) { }
}

/// Sleep until the tap (if `tap` >= 0), the routing socket or the blocklist
/// notification has something, or `timeout` passes — NULL waits with no
/// timeout at all. Drains the socket and the notification, and marks the
/// chores due when either fired. Returns whether the tap is readable.
///
/// Without a routing socket there is no event to wait for, so it falls back to
/// a 15s poll rather than sleeping forever.
static BOOL HPWaitForEvents(int tap, int rs, int nfd, struct timeval *timeout, BOOL *choresDue) {
    fd_set rfds;
    FD_ZERO(&rfds);
    int top = -1;
    if (tap >= 0) { FD_SET(tap, &rfds); if (tap > top) top = tap; }
    if (rs >= 0)  { FD_SET(rs, &rfds);  if (rs > top) top = rs; }
    if (nfd >= 0) { FD_SET(nfd, &rfds); if (nfd > top) top = nfd; }

    struct timeval fallback = { .tv_sec = 15, .tv_usec = 0 };
    if (!timeout && rs < 0) timeout = &fallback;
    if (top < 0) {
        sleep((unsigned int)(timeout ? timeout->tv_sec : 15));
        *choresDue = YES;
        return NO;
    }

    int ready = select(top + 1, &rfds, NULL, NULL, timeout);
    if (ready <= 0) return NO;
    if (rs >= 0 && FD_ISSET(rs, &rfds)) {
        HPDrainRouteSocket(rs);
        *choresDue = YES;
    }
    if (nfd >= 0 && FD_ISSET(nfd, &rfds)) {
        HPDrainNotify(nfd);
        *choresDue = YES;
    }
    return tap >= 0 && FD_ISSET(tap, &rfds);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gBytesByMac = [NSMutableDictionary dictionary];
        gUploadByMac = [NSMutableDictionary dictionary];
        gDownloadByMac = [NSMutableDictionary dictionary];
        gLastSeenByMac = [NSMutableDictionary dictionary];
        gTouchedMacs = [NSMutableSet set];
        gInstalledBlocks = [NSMutableDictionary dictionary];
        HPDaemonLog(@"started, uid %d", getuid());

        HPWriteDaemonStatus(@"starting");

        HPClearStaleBlocks();
        // And sweep the whole client range, so an orphan route no tracking file
        // remembers — left by a daemon that was killed mid-block — is gone by
        // the next start rather than surviving until a reboot.
        HPSweepHotspotRejectRoutes();

        // Counters survive a hotspot session; they are cumulative since the
        // daemon started, and the tweak turns them into per-period figures by
        // taking deltas (and treating a drop as a daemon restart).
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:HPDevicesPath()];
        if ([existing[@"bytesByMac"] isKindOfClass:[NSDictionary class]]) {
            [gBytesByMac addEntriesFromDictionary:existing[@"bytesByMac"]];
            // Directional counters were added in 0.7.0; an older file has none,
            // in which case they simply start fresh and re-accumulate.
            if ([existing[@"uploadByMac"] isKindOfClass:[NSDictionary class]]) {
                [gUploadByMac addEntriesFromDictionary:existing[@"uploadByMac"]];
            }
            if ([existing[@"downloadByMac"] isKindOfClass:[NSDictionary class]]) {
                [gDownloadByMac addEntriesFromDictionary:existing[@"downloadByMac"]];
            }
            if ([existing[@"lastSeenByMac"] isKindOfClass:[NSDictionary class]]) {
                [gLastSeenByMac addEntriesFromDictionary:existing[@"lastSeenByMac"]];
            }
            // Devices carried over from before this file had timestamps get one
            // now, so they age out normally instead of living forever.
            for (NSString *mac in gBytesByMac) {
                if (!gLastSeenByMac[mac]) gLastSeenByMac[mac] = [NSDate date];
            }
            HPPruneDevices();
            HPDaemonLog(@"resumed %lu device counters",
                        (unsigned long)gBytesByMac.count);
        }

        char *buf = malloc(kBufferSize);
        if (!buf) return 1;

        // The kernel broadcasts a message on this socket whenever an interface,
        // address or route changes. Selecting on it turns "has the hotspot come
        // up yet?" from a question asked on a timer into one the kernel answers
        // when the answer changes -- no wake-ups in between. Reading a routing
        // socket needs no privilege; only writing to one does, which this
        // process already does for the per-device blocks.
        int rs = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
        if (rs < 0) {
            HPDaemonLog(@"route socket: %s — falling back to polling",
                        strerror(errno));
        }

        // The collector posts this each time it rewrites the blocklist, and
        // Settings when tracking is switched on or off. Waiting on it alongside
        // everything else means a change takes effect at once, and lets the
        // loop sleep with no timer while the hotspot is off or idle.
        int nfd = -1, ntoken = 0;
        if (notify_register_file_descriptor(HPBlocklistChangedNotification, &nfd, 0,
                                            &ntoken) == NOTIFY_STATUS_OK) {
            fcntl(nfd, F_SETFL, fcntl(nfd, F_GETFL) | O_NONBLOCK);
        } else {
            nfd = -1;
            HPDaemonLog(@"blocklist notification unavailable; applying on each pass");
        }

        int fd = -1;
        NSString *bridgeName = nil;
        uint64_t bridgeMac = UINT64_MAX;
        NSDate *lastFlush = [NSDate date];
        CFAbsoluteTime lastChores = 0;
        BOOL choresDue = YES;   // something said config, blocklist or network moved
        BOOL trackingOff = NO;

        while (1) {
            @autoreleasepool {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

                // --- chores ---------------------------------------------------
                // Config, the blocklist and which bridge is up. Done when an
                // event says one of them changed, and otherwise at most every
                // 5s: under load this loop comes round several times a second,
                // and doing these each time was several file reads and a file
                // write per second for as long as data flowed. While idle,
                // only an event brings them round.
                if (choresDue || fd < 0 || (!gIdle && now - lastChores >= kChoresInterval)) {
                    choresDue = NO;
                    lastChores = now;

                    // "Track Hotspot Usage" off means off: close the tap so
                    // nothing is captured and nothing is counted.
                    if (![HPConfig()[HPCfgEnabledKey] boolValue]) {
                        HPWriteDaemonStatus(@"tracking-off");
                        if (trackingOff) {
                            // Already cleared; nothing adds a route while off.
                            HPWaitForEvents(-1, rs, nfd, NULL, &choresDue);
                            continue;
                        }
                        trackingOff = YES;
                        if (fd >= 0) {
                            HPDaemonLog(@"tracking disabled, closing tap");
                            close(fd);
                            fd = -1;
                            bridgeName = nil;
                            gTapSince = nil;
                            gIdle = NO;
                            HPFlushCounters();
                        }
                        // Tracking off must not leave anyone cut off. Clear what
                        // we tracked, then sweep the whole client range so an
                        // orphan route we no longer remember cannot strand a
                        // device.
                        if (gInstalledBlocks.count) [gInstalledBlocks removeAllObjects];
                        HPSaveInstalledBlocksIfChanged();
                        HPSweepHotspotRejectRoutes();
                        // Then sleep until something changes: Settings posts the
                        // notification when the switch is turned back on.
                        HPWaitForEvents(-1, rs, nfd, NULL, &choresDue);
                        continue;
                    }
                    trackingOff = NO;

                    NSDictionary *bridge = HPFindBridge();
                    if (!bridge && fd >= 0) {
                        HPDaemonLog(@"%@ went away, closing tap", bridgeName);
                        close(fd);
                        fd = -1;
                        bridgeName = nil;
                        gTapSince = nil;
                        gIdle = NO;
                        HPFlushCounters();
                    }
                    if (bridge && fd < 0) {
                        bridgeName = bridge[HPIfNameKey];
                        bridgeMac = HPMacBitsFromString(bridge[HPIfMacKey]);
                        fd = HPOpenBPF(bridgeName);
                        if (fd < 0) {
                            // Do not spin retrying a tap that cannot be opened.
                            HPWriteDaemonStatus(@"no-bpf");
                            sleep(30);
                            continue;
                        }
                        gTapSince = [NSDate date];
                        // A fresh tap has heard nothing yet; give clients the
                        // whole idle window to speak before concluding nobody
                        // is there.
                        gLastClientFrame = now;
                        gIdle = NO;
                        HPWriteDaemonStatus(@"running");
                    }
                    // Routes only matter while there is a hotspot to route
                    // for; with it off, a Wi-Fi network moving is no reason to
                    // read the blocklist.
                    if (fd >= 0) HPApplyBlocklist();
                }

                // --- hotspot off ----------------------------------------------
                if (fd < 0) {
                    HPWriteDaemonStatus(@"hotspot-off");
                    // No timer: the routing socket becomes readable the moment
                    // an interface or address appears, which is exactly what
                    // starting a hotspot does, and a notification arrives for
                    // anything Settings changes. Waiting here costs nothing.
                    HPWaitForEvents(-1, rs, nfd, NULL, &choresDue);
                    continue;
                }

                // --- idle -----------------------------------------------------
                // Nobody has sent a frame for minutes: stop the heartbeat and
                // sleep until a frame arrives. Only a tap with a read timeout
                // can be trusted to deliver that first frame promptly.
                if (!gIdle && gTapTimesOut && now - gLastClientFrame >= kIdleAfter) {
                    gIdle = YES;
                    HPFlushCounters();
                    lastFlush = [NSDate date];
                    HPDaemonLog(@"no clients for %.0fs, idle until one appears", kIdleAfter);
                }

                // 5s while clients are about: with immediate mode off this only
                // paces the heartbeat and the chores. None at all while idle.
                struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
                BOOL readable = HPWaitForEvents(fd, rs, nfd, gIdle ? NULL : &timeout, &choresDue);

                if (readable) {
                    ssize_t n = read(fd, buf, kBufferSize);
                    if (n > 0) {
                        HPConsume(buf, n, bridgeMac);
                    } else if (n < 0 && errno != EINTR && errno != EAGAIN) {
                        // ENXIO is just the hotspot being switched off: the
                        // interface the tap was bound to no longer exists.
                        // That is routine, not a failure worth logging.
                        if (errno != ENXIO) HPDaemonLog(@"read: %s", strerror(errno));
                        close(fd);
                        fd = -1;
                        gTapSince = nil;
                        gIdle = NO;
                        HPFlushCounters();
                        continue;
                    }
                }

                // A client spoke after a quiet spell (which is always the
                // case when leaving idle): publish its stamp now rather than
                // on the next heartbeat, and wake the collector, which may be
                // sleeping for want of anyone to count.
                if (gClientReturned) {
                    gClientReturned = NO;
                    if (gIdle) HPDaemonLog(@"client traffic, leaving idle");
                    gIdle = NO;
                    HPFlushCounters();
                    lastFlush = [NSDate date];
                    notify_post(HPDaemonActivityNotification);
                    choresDue = YES;
                }

                if (!gIdle && [[NSDate date] timeIntervalSinceDate:lastFlush] >= kFlushInterval) {
                    HPFlushCounters();
                    lastFlush = [NSDate date];
                }
            }
        }
    }
    return 0;
}
