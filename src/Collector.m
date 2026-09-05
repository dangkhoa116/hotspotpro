#import "Collector.h"
#import "Prefs.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

NSString *const HPIfNameKey     = @"name";
NSString *const HPIfIndexKey    = @"index";
NSString *const HPIfFlagsKey    = @"flags";
NSString *const HPIfUpKey       = @"up";
NSString *const HPIfInBytesKey  = @"ibytes";
NSString *const HPIfOutBytesKey = @"obytes";
NSString *const HPIfMacKey      = @"mac";

NSString *const HPLastInBytesKey  = @"i";
NSString *const HPLastOutBytesKey = @"o";

NSString *const HPDevMacKey      = @"mac";
NSString *const HPDevIPKey       = @"ip";
NSString *const HPDevNameKey     = @"deviceName";
NSString *const HPDevIfIndexKey  = @"ifIndex";
NSString *const HPDevIfNameKey   = @"ifName";
NSString *const HPDevLeaseEndKey = @"leaseEnd";
NSString *const HPDevExpiresKey  = @"arpExpires";
NSString *const HPDevBytesKey    = @"bytes";

#pragma mark - Kernel structures

// struct if_msghdr2 / if_data64 are declared in xnu's <net/if_var.h> but are
// not reliably exposed by the iPhoneOS SDK, so they are redeclared here rather
// than depending on SDK variance. The layout is kernel ABI and stable; the
// static asserts below fail the build immediately if that ever stops holding,
// which beats silently parsing garbage counters.
#pragma pack(4)
struct hp_if_data64 {
    u_char    ifi_type;
    u_char    ifi_typelen;
    u_char    ifi_physical;
    u_char    ifi_addrlen;
    u_char    ifi_hdrlen;
    u_char    ifi_recvquota;
    u_char    ifi_xmitquota;
    u_char    ifi_unused1;
    u_int32_t ifi_mtu;
    u_int32_t ifi_metric;
    u_int64_t ifi_baudrate;
    u_int64_t ifi_ipackets;
    u_int64_t ifi_ierrors;
    u_int64_t ifi_opackets;
    u_int64_t ifi_oerrors;
    u_int64_t ifi_collisions;
    u_int64_t ifi_ibytes;
    u_int64_t ifi_obytes;
    u_int64_t ifi_imcasts;
    u_int64_t ifi_omcasts;
    u_int64_t ifi_iqdrops;
    u_int64_t ifi_noproto;
    u_int32_t ifi_recvtiming;
    u_int32_t ifi_xmittiming;
    struct { int32_t tv_sec; int32_t tv_usec; } ifi_lastchange;
};

struct hp_if_msghdr2 {
    u_short   ifm_msglen;
    u_char    ifm_version;
    u_char    ifm_type;
    int       ifm_addrs;
    int       ifm_flags;
    u_short   ifm_index;
    int       ifm_snd_len;
    int       ifm_snd_maxlen;
    int       ifm_snd_drops;
    int       ifm_timer;
    struct hp_if_data64 ifm_data;
};
#pragma pack()

_Static_assert(sizeof(struct hp_if_data64) == 128, "if_data64 layout changed");
_Static_assert(sizeof(struct hp_if_msghdr2) == 160, "if_msghdr2 layout changed");

// The iPhoneOS SDK ships no <net/route.h> at all, so the routing-socket
// constants and message header are declared here too. Same reasoning as above:
// this is stable kernel ABI, and HPValidateRouteMessage() below checks at
// runtime that the offsets really do land on the sockaddrs, so a bad layout
// shows up as a logged warning rather than as plausible-looking nonsense.
#ifndef NET_RT_IFLIST2
#define NET_RT_IFLIST2 6
#endif
#ifndef NET_RT_FLAGS
#define NET_RT_FLAGS 2
#endif
#ifndef RTM_IFINFO2
#define RTM_IFINFO2 0x12
#endif
#ifndef RTF_LLINFO
#define RTF_LLINFO 0x400
#endif

_Static_assert(sizeof(struct hp_rt_metrics) == 56, "rt_metrics layout changed");
_Static_assert(sizeof(struct hp_rt_msghdr) == 92, "rt_msghdr layout changed");

// Routing-socket messages pad each sockaddr to a 4-byte boundary (xnu builds
// them with ROUNDUP32). Not sizeof(long) — that would be 8 here and would walk
// the ARP table off into nonsense.
#define HP_SA_SIZE(sa)                                                        \
    (((struct sockaddr *)(sa))->sa_len                                        \
         ? (1 + ((((struct sockaddr *)(sa))->sa_len - 1) | (sizeof(uint32_t) - 1))) \
         : sizeof(uint32_t))

/// Read a whole sysctl into a malloc'd buffer. Caller frees. Returns NULL on
/// failure. The size is re-queried in a small retry loop because the table can
/// grow between the sizing call and the read.
static char *HPReadSysctl(int *mib, u_int mibLen, size_t *outLen) {
    for (int attempt = 0; attempt < 5; attempt++) {
        size_t len = 0;
        if (sysctl(mib, mibLen, NULL, &len, NULL, 0) < 0 || len == 0) return NULL;
        len += len / 8 + 1024; // slack for growth between the two calls
        char *buf = malloc(len);
        if (!buf) return NULL;
        if (sysctl(mib, mibLen, buf, &len, NULL, 0) == 0) {
            *outLen = len;
            return buf;
        }
        free(buf);
        if (errno != ENOMEM) return NULL;
    }
    return NULL;
}

#pragma mark - Interface counters

NSArray<NSDictionary *> *HPCopyInterfaces(void) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    char *buf = HPReadSysctl(mib, 6, &len);
    if (!buf) return @[];

    NSMutableArray *out = [NSMutableArray array];
    char *lim = buf + len;
    char *next = buf;

    while (next + sizeof(struct hp_if_msghdr2) <= lim) {
        struct hp_if_msghdr2 *hdr = (struct hp_if_msghdr2 *)next;
        if (hdr->ifm_msglen == 0 || next + hdr->ifm_msglen > lim) break;

        if (hdr->ifm_type == RTM_IFINFO2) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)(hdr + 1);
            if (sdl->sdl_nlen > 0 && sdl->sdl_nlen < IFNAMSIZ) {
                NSString *name = [[NSString alloc] initWithBytes:sdl->sdl_data
                                                          length:sdl->sdl_nlen
                                                        encoding:NSUTF8StringEncoding];
                if (name.length) {
                    BOOL up = (hdr->ifm_flags & IFF_UP) && (hdr->ifm_flags & IFF_RUNNING);
                    NSMutableDictionary *entry = [@{
                        HPIfNameKey     : name,
                        HPIfIndexKey    : @(hdr->ifm_index),
                        HPIfFlagsKey    : @((unsigned)hdr->ifm_flags),
                        HPIfUpKey       : @(up),
                        HPIfInBytesKey  : @(hdr->ifm_data.ifi_ibytes),
                        HPIfOutBytesKey : @(hdr->ifm_data.ifi_obytes),
                    } mutableCopy];

                    // The interface's own MAC, needed to tell which end of a
                    // captured frame is the client.
                    if (sdl->sdl_alen == 6) {
                        unsigned char *m = (unsigned char *)LLADDR(sdl);
                        entry[HPIfMacKey] =
                            [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                                                       m[0], m[1], m[2], m[3], m[4], m[5]];
                    }
                    [out addObject:entry];
                }
            }
        }
        next += hdr->ifm_msglen;
    }

    free(buf);
    return out;
}

NSDictionary *HPInterfaceNamed(NSArray<NSDictionary *> *ifaces, NSString *name) {
    for (NSDictionary *i in ifaces) {
        if ([i[HPIfNameKey] isEqualToString:name]) return i;
    }
    return nil;
}

#pragma mark - Which interfaces carry hotspot traffic

/// The tethering bridge: bridge100, bridge101, ... iOS numbers them from 100.
static BOOL HPIsTetherBridge(NSString *name) {
    if (![name hasPrefix:@"bridge"]) return NO;
    NSString *digits = [name substringFromIndex:6];
    return digits.length >= 3 && [digits integerValue] >= 100;
}

/// The raw Wi-Fi AP interface clients associate with, normally a bridge member.
static BOOL HPIsApInterface(NSString *name) {
    return [name hasPrefix:@"ap"];
}

NSArray<NSDictionary *> *HPCopyInterfaceCandidates(NSArray<NSDictionary *> *ifaces) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *i in ifaces) {
        NSString *n = i[HPIfNameKey];
        if (HPIsTetherBridge(n) || HPIsApInterface(n) || [n hasPrefix:@"bridge"] ||
            [n hasPrefix:@"en"] || [n hasPrefix:@"pdp_ip"]) {
            [out addObject:i];
        }
    }
    return out;
}

NSArray<NSString *> *HPHotspotInterfaceNames(NSArray<NSDictionary *> *ifaces) {
    // MEASURED on device 2026-09-05, hotspot up with a real client pulling a
    // file: bridge100 accumulated 32.9 MB while ap1 accumulated 16.9 MB and the
    // cellular uplink pdp_ip0 17.5 MB — and every single 3s sample showed
    // bridge100 at exactly twice ap1 (+2.7/+2.7/+5.4, +2.2/+2.2/+4.3, ...).
    //
    // The bridge counts each forwarded packet on both the way in and the way
    // out, so counting the bridge reports double the real usage. ap1 — the
    // Wi-Fi AP interface the clients associate with — tracks the uplink, so
    // that is what gets counted. This is the whole reason the CLI probe was
    // built before the tweak.
    BOOL bridgeUp = NO;
    for (NSDictionary *i in ifaces) {
        if ([i[HPIfUpKey] boolValue] && HPIsTetherBridge(i[HPIfNameKey])) bridgeUp = YES;
    }

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *i in ifaces) {
        if (![i[HPIfUpKey] boolValue]) continue;
        NSString *n = i[HPIfNameKey];
        if (HPIsApInterface(n)) {
            [out addObject:n];          // Wi-Fi clients
        } else if (bridgeUp && [n isEqualToString:@"en2"]) {
            // USB tethering, but only while a tethering bridge exists — en2 is
            // up permanently and must not be counted outside a session.
            [out addObject:n];
        }
    }
    return out;
}

/// The kernel turns IP forwarding on while Internet Sharing is enabled and off
/// again afterwards. Measured: 1 with the hotspot on, 0 with it off.
BOOL HPIPForwardingEnabled(void) {
    int value = 0;
    size_t len = sizeof(value);
    if (sysctlbyname("net.inet.ip.forwarding", &value, &len, NULL, 0) != 0) return NO;
    return value != 0;
}

BOOL HPHotspotIsActive(NSArray<NSDictionary *> *ifaces) {
    for (NSDictionary *i in ifaces) {
        if (![i[HPIfUpKey] boolValue]) continue;
        NSString *n = i[HPIfNameKey];
        if (HPIsTetherBridge(n) || HPIsApInterface(n)) return YES;
    }
    // The interfaces are not a steady signal on their own: bridge100 and ap1
    // come and go while sharing stays on (an earlier capture caught them
    // flip-flopping within seconds), which made the status row alternate
    // between on and off. IP forwarding stays put for the whole session.
    return HPIPForwardingEnabled();
}

uint64_t HPTotalBytes(NSArray<NSDictionary *> *ifaces, NSArray<NSString *> *names) {
    uint64_t total = 0;
    for (NSString *n in names) {
        NSDictionary *i = HPInterfaceNamed(ifaces, n);
        if (!i) continue;
        total += [i[HPIfInBytesKey] unsignedLongLongValue];
        total += [i[HPIfOutBytesKey] unsignedLongLongValue];
    }
    return total;
}

#pragma mark - Accumulation

uint64_t HPAccumulateDelta(NSMutableDictionary *last,
                           NSArray<NSDictionary *> *ifaces,
                           NSArray<NSString *> *names,
                           BOOL baselineOnly) {
    uint64_t added = 0;

    for (NSString *name in names) {
        NSDictionary *cur = HPInterfaceNamed(ifaces, name);
        if (!cur) continue;

        uint64_t ci = [cur[HPIfInBytesKey] unsignedLongLongValue];
        uint64_t co = [cur[HPIfOutBytesKey] unsignedLongLongValue];

        NSDictionary *prev = last[name];
        if (prev && !baselineOnly) {
            uint64_t pi = [prev[HPLastInBytesKey] unsignedLongLongValue];
            uint64_t po = [prev[HPLastOutBytesKey] unsignedLongLongValue];
            // A counter that went backwards means the interface was torn down
            // and recreated (hotspot toggled), so the new value is the delta.
            added += (ci >= pi) ? (ci - pi) : ci;
            added += (co >= po) ? (co - po) : co;
        }
        // First sight of an interface adds NOTHING; it is only baselined.
        //
        // ap1 is not destroyed when the hotspot goes off — it keeps a lifetime
        // counter. Treating first sight as "this is all new traffic" imported
        // 761.5 MB of history the moment the tweak first ran. Since a
        // never-before-seen interface cannot be told apart from a
        // freshly-created one, baselining is the only safe choice: at worst it
        // misses the few seconds before the first sample, instead of inventing
        // hundreds of megabytes. Genuine restarts are still caught by the
        // counter-went-backwards branch above.

        last[name] = @{ HPLastInBytesKey : @(ci), HPLastOutBytesKey : @(co) };
    }

    return added;
}

#pragma mark - ARP

NSArray<NSDictionary *> *HPCopyArpEntries(void) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO };
    size_t len = 0;
    char *buf = HPReadSysctl(mib, 6, &len);
    if (!buf) return @[];

    NSMutableArray *out = [NSMutableArray array];
    char *lim = buf + len;
    char *next = buf;
    BOOL warned = NO;

    while (next + sizeof(struct hp_rt_msghdr) <= lim) {
        struct hp_rt_msghdr *rtm = (struct hp_rt_msghdr *)next;
        if (rtm->rtm_msglen == 0 || next + rtm->rtm_msglen > lim) break;

        struct sockaddr_in *sin = (struct sockaddr_in *)(rtm + 1);
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)((char *)sin + HP_SA_SIZE(sin));

        // If the declared header size were wrong, these two would not be an
        // AF_INET address followed by an AF_LINK one — better to say so than
        // to hand back invented MAC addresses.
        if (sin->sin_family != AF_INET || sdl->sdl_family != AF_LINK) {
            if (!warned) {
                HPLog(@"ARP: unexpected sockaddr families (%d, %d) — rt_msghdr "
                       "layout may be wrong on this firmware",
                      sin->sin_family, sdl->sdl_family);
                warned = YES;
            }
            next += rtm->rtm_msglen;
            continue;
        }

        if ((char *)sdl + sizeof(struct sockaddr_dl) <= next + rtm->rtm_msglen &&
            sdl->sdl_alen == 6) {
            unsigned char *m = (unsigned char *)LLADDR(sdl);
            NSString *mac = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                                                       m[0], m[1], m[2], m[3], m[4], m[5]];
            char ipbuf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &sin->sin_addr, ipbuf, sizeof(ipbuf));

            char ifname[IFNAMSIZ] = {0};
            if_indextoname(sdl->sdl_index, ifname);

            // rmx_expire is the absolute time this entry dies. It is the only
            // clue the ARP table gives about freshness: a client that has left
            // is not removed, it simply stops being refreshed, so the entry sits
            // there counting down for the rest of its lifetime. Zero means a
            // permanent entry, which never ages.
            [out addObject:@{
                HPDevMacKey     : mac,
                HPDevIPKey      : @(ipbuf),
                HPDevIfIndexKey : @(sdl->sdl_index),
                HPDevIfNameKey  : @(ifname),
                HPDevExpiresKey : @(rtm->rtm_rmx.rmx_expire),
            }];
        }
        next += rtm->rtm_msglen;
    }

    free(buf);
    return out;
}

#pragma mark - DHCP leases

NSString *HPNormaliseMac(NSString *raw) {
    if (!raw.length) return nil;
    // The lease file writes "1,1e:7:67:bb:5b:3f": a hardware-type prefix, and
    // octets that are *not* zero-padded. Both have to go before it can be
    // joined against an ARP entry.
    NSRange comma = [raw rangeOfString:@","];
    NSString *body = comma.location == NSNotFound ? raw
                                                  : [raw substringFromIndex:comma.location + 1];
    NSArray<NSString *> *parts = [body componentsSeparatedByString:@":"];
    if (parts.count != 6) return [body lowercaseString];

    NSMutableArray *padded = [NSMutableArray arrayWithCapacity:6];
    for (NSString *p in parts) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:p] scanHexInt:&v];
        [padded addObject:[NSString stringWithFormat:@"%02x", v & 0xff]];
    }
    return [padded componentsJoinedByString:@":"];
}

NSArray<NSDictionary *> *HPCopyDhcpLeases(void) {
    NSString *path = @"/var/db/dhcpd_leases";
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text.length) return @[];

    NSMutableArray *out = [NSMutableArray array];
    NSMutableDictionary *rec = nil;

    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
        if ([line isEqualToString:@"{"]) {
            rec = [NSMutableDictionary dictionary];
            continue;
        }
        if ([line isEqualToString:@"}"]) {
            if (rec[HPDevMacKey]) [out addObject:[rec copy]];
            rec = nil;
            continue;
        }
        if (!rec) continue;

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:eq.location];
        NSString *val = [line substringFromIndex:eq.location + 1];

        if ([key isEqualToString:@"name"]) {
            rec[HPDevNameKey] = val;
        } else if ([key isEqualToString:@"ip_address"]) {
            rec[HPDevIPKey] = val;
        } else if ([key isEqualToString:@"hw_address"]) {
            NSString *mac = HPNormaliseMac(val);
            if (mac) rec[HPDevMacKey] = mac;
        } else if ([key isEqualToString:@"lease"]) {
            unsigned long long secs = 0;
            NSScanner *s = [NSScanner scannerWithString:val];
            if ([val hasPrefix:@"0x"]) [s setScanLocation:2];
            if ([s scanHexLongLong:&secs] && secs > 0) {
                rec[HPDevLeaseEndKey] = [NSDate dateWithTimeIntervalSince1970:secs];
            }
        }
    }

    return out;
}

#pragma mark - Connected devices

/// Multicast and broadcast link addresses (the low bit of the first octet)
/// are not devices — they are 224.0.0.251, 239.255.255.250 and friends.
static BOOL HPIsMulticastMac(NSString *mac) {
    if (mac.length < 2) return NO;
    unsigned int first = 0;
    [[NSScanner scannerWithString:[mac substringToIndex:2]] scanHexInt:&first];
    return (first & 0x01) != 0;
}

NSArray<NSDictionary *> *HPCopyConnectedDevices(NSArray<NSString *> *hotspotIfNames) {
    // No hotspot interface means no hotspot clients. Without this the ARP table
    // is returned unfiltered, and every neighbour on the home Wi-Fi gets
    // reported as a tethering client.
    if (hotspotIfNames.count == 0) return @[];

    // The interfaces that CARRY clients are not the ones we COUNT. Bytes are
    // counted on ap1, but the gateway address (172.20.10.1) lives on bridge100,
    // so that is the interface ARP neighbours are reached over. Filtering
    // devices by the counting interfaces reported "0 devices connected" with
    // clients plainly attached.
    NSMutableSet<NSString *> *clientIfs = [NSMutableSet set];
    for (NSDictionary *i in HPCopyInterfaces()) {
        if (![i[HPIfUpKey] boolValue]) continue;
        NSString *n = i[HPIfNameKey];
        if (HPIsTetherBridge(n) || HPIsApInterface(n) || [n isEqualToString:@"en2"]) {
            [clientIfs addObject:n];
        }
    }

    NSArray<NSDictionary *> *arp = HPCopyArpEntries();
    NSArray<NSDictionary *> *leases = HPCopyDhcpLeases();

    // Newest lease per MAC wins: the file keeps historical records, and a
    // client that reconnected has more than one.
    NSMutableDictionary<NSString *, NSDictionary *> *byMac = [NSMutableDictionary dictionary];
    for (NSDictionary *l in leases) {
        NSString *mac = l[HPDevMacKey];
        NSDictionary *existing = byMac[mac];
        if (!existing) {
            byMac[mac] = l;
            continue;
        }
        NSDate *a = existing[HPDevLeaseEndKey], *b = l[HPDevLeaseEndKey];
        if (b && (!a || [b compare:a] == NSOrderedDescending)) byMac[mac] = l;
    }

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *entry in arp) {
        // Only neighbours reached over a hotspot interface are clients; the
        // rest are the phone's own upstream neighbours (home router, etc.).
        // The address check is a second, independent signal: iOS always hands
        // hotspot clients 172.20.10.x, so a client still counts even if the
        // interface it arrived on is not one we recognised.
        BOOL onClientIf = [clientIfs containsObject:entry[HPDevIfNameKey]];
        BOOL onHotspotSubnet = [entry[HPDevIPKey] hasPrefix:@"172.20.10."];
        if (!onClientIf && !onHotspotSubnet) continue;
        if (HPIsMulticastMac(entry[HPDevMacKey])) continue;
        // The phone itself is the gateway, not a client.
        if ([entry[HPDevIPKey] isEqualToString:@"172.20.10.1"]) continue;
        NSMutableDictionary *dev = [entry mutableCopy];
        NSDictionary *lease = byMac[entry[HPDevMacKey]];
        if (lease[HPDevNameKey]) dev[HPDevNameKey] = lease[HPDevNameKey];
        if (lease[HPDevLeaseEndKey]) dev[HPDevLeaseEndKey] = lease[HPDevLeaseEndKey];
        [out addObject:dev];
    }
    return out;
}

#pragma mark - Per-device bytes (from the daemon)

NSDictionary<NSString *, NSNumber *> *HPCopyDaemonDeviceBytes(void) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:
                              @"/var/mobile/Library/Caches/hotspotpro-devices.plist"];
    NSDictionary *bytes = file[@"bytesByMac"];
    return [bytes isKindOfClass:[NSDictionary class]] ? bytes : @{};
}

NSDictionary<NSString *, NSDate *> *HPCopyDaemonLastSeen(void) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:
                              @"/var/mobile/Library/Caches/hotspotpro-devices.plist"];
    NSDictionary *seen = file[@"lastSeenByMac"];
    return [seen isKindOfClass:[NSDictionary class]] ? seen : @{};
}

#pragma mark - Helpers

NSString *HPFormatBytes(uint64_t bytes) {
    double b = (double)bytes;
    if (b < 1024.0) return [NSString stringWithFormat:@"%llu B", bytes];
    if (b < 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    if (b < 1024.0 * 1024.0 * 1024.0)
        return [NSString stringWithFormat:@"%.1f MB", b / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.2f GB", b / (1024.0 * 1024.0 * 1024.0)];
}
