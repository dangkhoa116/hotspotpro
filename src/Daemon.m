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
#include <string.h>
#include <errno.h>

#pragma mark - BPF, declared here because the SDK ships no <net/bpf.h>

#define HP_BIOCSBLEN     _IOWR('B', 102, u_int)
#define HP_BIOCSETF      _IOW ('B', 103, struct hp_bpf_program)
#define HP_BIOCFLUSH     _IO  ('B', 104)
#define HP_BIOCGDLT      _IOR ('B', 106, u_int)
#define HP_BIOCSETIF     _IOW ('B', 108, struct ifreq)
#define HP_BIOCIMMEDIATE _IOW ('B', 112, u_int)
#define HP_BIOCSHDRCMPLT _IOW ('B', 117, u_int)
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

#pragma mark - State

static NSMutableDictionary<NSString *, NSNumber *> *gBytesByMac;
static NSMutableDictionary<NSString *, NSDate *> *gLastSeenByMac;
static NSMutableSet<NSString *> *gTouchedMacs;
static NSString *gDevicesPath = @"/var/mobile/Library/Caches/hotspotpro-devices.plist";

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
        [gLastSeenByMac removeObjectForKey:byAge[i]];
    }
    HPDaemonLog(@"capped device table to %lu entries", (unsigned long)gBytesByMac.count);
}

/// Counters are written where the tweak (running as mobile) can read them.
static void HPFlushCounters(void) {
    if (!gBytesByMac.count) return;
    @try {
        // Stamp only the devices that actually moved data since the last flush,
        // so timestamps cost nothing per packet.
        NSDate *now = [NSDate date];
        for (NSString *mac in gTouchedMacs) gLastSeenByMac[mac] = now;
        [gTouchedMacs removeAllObjects];
        HPPruneDevices();

        NSString *tmp = [gDevicesPath stringByAppendingPathExtension:@"tmp"];
        NSDictionary *payload = @{
            @"bytesByMac"   : gBytesByMac,
            @"lastSeenByMac": gLastSeenByMac,
            @"updated"      : [NSDate date],
        };
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:NULL];
        if (!data) return;
        [data writeToFile:tmp atomically:NO];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:gDevicesPath error:NULL];
        [fm moveItemAtPath:tmp toPath:gDevicesPath error:NULL];
        // Written by root, read by the tweak inside SpringBoard and Preferences.
        [fm setAttributes:@{ NSFilePosixPermissions : @0644 }
             ofItemAtPath:gDevicesPath
                    error:NULL];
    } @catch (NSException *e) {
        HPDaemonLog(@"flush failed: %@", e);
    }
}

#pragma mark - Blocking

// MAC -> IP for every block this daemon has installed.
static NSMutableDictionary<NSString *, NSString *> *gInstalledBlocks;
static NSString *gInstalledPath = @"/var/mobile/Library/Caches/hotspotpro-installed.plist";

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
    HPDaemonLog(@"%@ %@", blocked ? @"blocked" : @"unblocked", ip);
    return YES;
}

static void HPSaveInstalledBlocks(void) {
    [gInstalledBlocks writeToFile:gInstalledPath atomically:YES];
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

        HPSaveInstalledBlocks();
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
    NSDictionary *stale = [NSDictionary dictionaryWithContentsOfFile:gInstalledPath];
    if (![stale isKindOfClass:[NSDictionary class]] || stale.count == 0) return;

    HPDaemonLog(@"clearing %lu route block(s) left from a previous run",
                (unsigned long)stale.count);
    for (NSString *mac in stale) HPSetRouteBlock(stale[mac], NO);
    [[NSFileManager defaultManager] removeItemAtPath:gInstalledPath error:NULL];
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

    // Batched, not immediate: the read returns when the buffer fills or the
    // select() timeout fires, rather than once per packet.
    u_int immediate = 0;
    ioctl(fd, HP_BIOCIMMEDIATE, &immediate);
    ioctl(fd, HP_BIOCFLUSH);

    HPDaemonLog(@"tapping %@ (fd %d, buffer %u bytes)", ifname, fd, blen);
    return fd;
}

static void HPConsume(const char *buf, ssize_t len, NSString *bridgeMac) {
    const char *p = buf;
    const char *end = buf + len;

    while (p + sizeof(struct hp_bpf_hdr) <= end) {
        const struct hp_bpf_hdr *bh = (const struct hp_bpf_hdr *)p;
        if (bh->bh_hdrlen == 0) break;

        const unsigned char *frame = (const unsigned char *)p + bh->bh_hdrlen;
        if ((const char *)frame + 12 <= end && bh->bh_caplen >= 12) {
            NSString *dst = HPMacString(frame);
            NSString *src = HPMacString(frame + 6);

            // Whichever end is not the bridge itself is the client. Broadcast
            // and multicast are not devices.
            NSString *client = [src isEqualToString:bridgeMac] ? dst : src;
            unsigned int firstOctet = 0;
            sscanf([[client substringToIndex:2] UTF8String], "%x", &firstOctet);
            BOOL isGroupAddress = (firstOctet & 0x01) != 0;

            if (!isGroupAddress && ![client isEqualToString:bridgeMac]) {
                uint64_t prev = [gBytesByMac[client] unsignedLongLongValue];
                gBytesByMac[client] = @(prev + bh->bh_datalen);
                [gTouchedMacs addObject:client];
            }
        }

        size_t advance = HP_BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
        if (advance == 0) break;
        p += advance;
    }
}

#pragma mark - Main loop

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gBytesByMac = [NSMutableDictionary dictionary];
        gLastSeenByMac = [NSMutableDictionary dictionary];
        gTouchedMacs = [NSMutableSet set];
        gInstalledBlocks = [NSMutableDictionary dictionary];
        HPDaemonLog(@"started, uid %d", getuid());

        // Same gate as the tweak: iOS 18 is untested and reported unstable, and
        // this process is root, taps packets and writes routes. Exit rather than
        // run any of that against kernel structures nobody here has checked.
        NSOperatingSystemVersion ios18 = { 18, 0, 0 };
        if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:ios18]) {
            HPDaemonLog(@"iOS 18+ — untested firmware, exiting without tapping");
            return 0;
        }

        HPClearStaleBlocks();

        // Counters survive a hotspot session; they are cumulative since the
        // daemon started, and the tweak turns them into per-period figures by
        // taking deltas (and treating a drop as a daemon restart).
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:gDevicesPath];
        if ([existing[@"bytesByMac"] isKindOfClass:[NSDictionary class]]) {
            [gBytesByMac addEntriesFromDictionary:existing[@"bytesByMac"]];
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

        int fd = -1;
        NSString *bridgeName = nil;
        NSString *bridgeMac = nil;
        NSDate *lastFlush = [NSDate date];

        while (1) {
            @autoreleasepool {
                // "Track Hotspot Usage" off means off: close the tap so nothing
                // is captured and nothing is counted, and idle cheaply until it
                // is switched back on.
                if (![HPConfig()[HPCfgEnabledKey] boolValue]) {
                    if (fd >= 0) {
                        HPDaemonLog(@"tracking disabled, closing tap");
                        close(fd);
                        fd = -1;
                        bridgeName = nil;
                        HPFlushCounters();
                    }
                    // Tracking off must not leave anyone cut off.
                    if (gInstalledBlocks.count) {
                        for (NSString *mac in [gInstalledBlocks.allKeys copy]) {
                            if (HPSetRouteBlock(gInstalledBlocks[mac], NO)) {
                                [gInstalledBlocks removeObjectForKey:mac];
                            }
                        }
                        HPSaveInstalledBlocks();
                    }
                    sleep(15);
                    continue;
                }

                HPApplyBlocklist();

                NSDictionary *bridge = HPFindBridge();

                if (!bridge && fd >= 0) {
                    HPDaemonLog(@"%@ went away, closing tap", bridgeName);
                    close(fd);
                    fd = -1;
                    bridgeName = nil;
                    HPFlushCounters();
                }

                if (bridge && fd < 0) {
                    bridgeName = bridge[HPIfNameKey];
                    bridgeMac = bridge[HPIfMacKey] ?: @"";
                    fd = HPOpenBPF(bridgeName);
                    if (fd < 0) {
                        // Do not spin retrying a tap that cannot be opened.
                        sleep(30);
                        continue;
                    }
                }

                if (fd < 0) {
                    // Hotspot off. Rather than waking on a timer to ask whether
                    // anything changed, block until the kernel says so: the
                    // routing socket becomes readable the moment an interface
                    // or address appears, which is exactly what starting a
                    // hotspot does. Waiting here costs nothing. The timeout is
                    // a backstop for a missed message, not the mechanism.
                    if (rs >= 0) {
                        fd_set rfds;
                        FD_ZERO(&rfds);
                        FD_SET(rs, &rfds);
                        struct timeval tv = { .tv_sec = 60, .tv_usec = 0 };
                        if (select(rs + 1, &rfds, NULL, NULL, &tv) > 0) {
                            HPDrainRouteSocket(rs);
                        }
                    } else {
                        sleep(15);   // no routing socket; fall back to polling
                    }
                    continue;
                }

                fd_set readfds;
                FD_ZERO(&readfds);
                FD_SET(fd, &readfds);
                int maxfd = fd;
                if (rs >= 0) {
                    FD_SET(rs, &readfds);
                    if (rs > maxfd) maxfd = rs;
                }
                // 5s rather than 1s: with immediate mode off this only governs
                // how often a partly-filled buffer is drained, and waking five
                // times less often while tethering costs nothing but latency.
                struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };

                int ready = select(maxfd + 1, &readfds, NULL, NULL, &timeout);

                // The hotspot going down arrives here as a routing message, so
                // the next loop notices the bridge is gone immediately instead
                // of up to five seconds later.
                if (ready > 0 && rs >= 0 && FD_ISSET(rs, &readfds)) {
                    HPDrainRouteSocket(rs);
                }

                if (ready > 0 && FD_ISSET(fd, &readfds)) {
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
                        HPFlushCounters();
                    }
                }

                if ([[NSDate date] timeIntervalSinceDate:lastFlush] >= kFlushInterval) {
                    HPFlushCounters();
                    lastFlush = [NSDate date];
                }
            }
        }
    }
    return 0;
}
