// Collector — every piece of hotspot data collection, shared by the CLI probe
// (hotspotpro) and, later, the SpringBoard tweak. Nothing here needs root or
// any private framework: it is sysctl calls plus one world-readable file.

#import <Foundation/Foundation.h>
#include <sys/types.h>

#pragma mark - Kernel routing structures

// The iPhoneOS SDK ships no <net/route.h>, so the routing-socket message header
// is declared here. Shared because the collector reads the ARP table with it and
// the daemon writes blackhole routes with it — one definition, no divergence.
// The sizes are asserted in Collector.m, so a layout change fails the build
// rather than silently corrupting the routing table.
struct hp_rt_metrics {
    u_int32_t rmx_locks;
    u_int32_t rmx_mtu;
    u_int32_t rmx_hopcount;
    int32_t   rmx_expire;
    u_int32_t rmx_recvpipe;
    u_int32_t rmx_sendpipe;
    u_int32_t rmx_ssthresh;
    u_int32_t rmx_rtt;
    u_int32_t rmx_rttvar;
    u_int32_t rmx_pksent;
    u_int32_t rmx_state;
    u_int32_t rmx_filler[3];
};

struct hp_rt_msghdr {
    u_short   rtm_msglen;
    u_char    rtm_version;
    u_char    rtm_type;
    u_short   rtm_index;
    int       rtm_flags;
    int       rtm_addrs;
    pid_t     rtm_pid;
    int       rtm_seq;
    int       rtm_errno;
    int       rtm_use;
    u_int32_t rtm_inits;
    struct hp_rt_metrics rtm_rmx;
};

#ifndef RTM_VERSION
#define RTM_VERSION 5
#endif
#ifndef RTM_ADD
#define RTM_ADD 0x1
#endif
#ifndef RTM_DELETE
#define RTM_DELETE 0x2
#endif
#ifndef RTA_DST
#define RTA_DST 0x1
#endif
#ifndef RTA_GATEWAY
#define RTA_GATEWAY 0x2
#endif
#ifndef RTF_UP
#define RTF_UP 0x1
#endif
#ifndef RTF_HOST
#define RTF_HOST 0x4
#endif
#ifndef RTF_REJECT
#define RTF_REJECT 0x8
#endif
#ifndef RTF_STATIC
#define RTF_STATIC 0x800
#endif

#pragma mark - Interface counters

// Keys in each dictionary returned by HPCopyInterfaces().
extern NSString *const HPIfNameKey;    // NSString, e.g. "bridge100"
extern NSString *const HPIfIndexKey;   // NSNumber (unsigned)
extern NSString *const HPIfFlagsKey;   // NSNumber (unsigned), IFF_* bits
extern NSString *const HPIfUpKey;      // NSNumber (BOOL), IFF_UP && IFF_RUNNING
extern NSString *const HPIfInBytesKey; // NSNumber (unsigned long long)
extern NSString *const HPIfOutBytesKey;// NSNumber (unsigned long long)
extern NSString *const HPIfMacKey;     // NSString, link-layer address, or absent

/// Every interface with its 64-bit byte counters, via sysctl NET_RT_IFLIST2.
///
/// Deliberately not getifaddrs(): that returns `struct if_data`, whose
/// ifi_ibytes/ifi_obytes are 32-bit and wrap at 4 GB — precisely the range this
/// tweak measures. NET_RT_IFLIST2 yields if_data64. This is what netstat -ib
/// uses, and netstat does not exist on iOS 16.
NSArray<NSDictionary *> *HPCopyInterfaces(void);

/// Look one interface up by name in a HPCopyInterfaces() result.
NSDictionary *HPInterfaceNamed(NSArray<NSDictionary *> *ifaces, NSString *name);

#pragma mark - Which interfaces carry hotspot traffic

/// The interfaces whose counters represent shared hotspot traffic.
///
/// The rule is `ap1` (plus `en2` for USB, only while a tethering bridge is up),
/// NOT the bridge: measurement showed bridge100 counting every forwarded packet
/// twice. See the comment on the implementation for the numbers.
NSArray<NSString *> *HPHotspotInterfaceNames(NSArray<NSDictionary *> *ifaces);

/// Every interface that could conceivably carry hotspot traffic, for recon.
NSArray<NSDictionary *> *HPCopyInterfaceCandidates(NSArray<NSDictionary *> *ifaces);

/// Whether Personal Hotspot is currently sharing, whether or not anyone has
/// connected yet.
///
/// Deliberately broader than HPHotspotInterfaceNames(): iOS brings the
/// tethering bridge up when sharing is switched on, seconds before the AP
/// interface that traffic is counted on. Asking only about counted interfaces
/// reported "Hotspot off" for the first moments after the switch was flipped.
BOOL HPHotspotIsActive(NSArray<NSDictionary *> *ifaces);

/// `net.inet.ip.forwarding` on its own: one sysctl, no table walk and no
/// allocation. Use it to decide whether a full sample is worth taking at all;
/// use HPHotspotIsActive() when you already have the interface list.
BOOL HPIPForwardingEnabled(void);

/// Sum of in+out over the named interfaces. Each forwarded packet is counted
/// once: client->internet arrives as ibytes, internet->client leaves as obytes.
uint64_t HPTotalBytes(NSArray<NSDictionary *> *ifaces, NSArray<NSString *> *names);

#pragma mark - Accumulation

// Keys in the mutable "last raw sample" dictionary, per interface name.
extern NSString *const HPLastInBytesKey;
extern NSString *const HPLastOutBytesKey;

/// Fold one raw sample into a running total, returning the bytes to add.
///
/// Per interface:
///   never seen   -> add nothing, just record where the counter stands
///   cur >= last  -> add (cur - last)
///   cur <  last  -> interface was recreated; add cur
/// First sight adds nothing because ap1 survives hotspot toggles carrying a
/// lifetime counter, and adding it would import months of history.
/// `last` is updated in place and is meant to be *persisted*, not merely held
/// in memory: if it lived only in memory, the first sample after a respring
/// would re-add every byte of the current session.
///
/// When `baselineOnly` is YES nothing is added and the counters are merely
/// recorded — used on the very first run so installing the tweak mid-session
/// does not import a session that predates the current period.
uint64_t HPAccumulateDelta(NSMutableDictionary *last,
                           NSArray<NSDictionary *> *ifaces,
                           NSArray<NSString *> *names,
                           BOOL baselineOnly);

#pragma mark - Connected devices

// Keys for ARP entries / leases / joined devices.
extern NSString *const HPDevMacKey;       // NSString, normalised "1e:07:67:bb:5b:3f"
extern NSString *const HPDevIPKey;        // NSString
extern NSString *const HPDevNameKey;      // NSString, from the DHCP lease
extern NSString *const HPDevIfIndexKey;   // NSNumber
extern NSString *const HPDevIfNameKey;    // NSString
extern NSString *const HPDevLeaseEndKey;  // NSDate
extern NSString *const HPDevBytesKey;     // NSNumber, bytes this period

/// Live ARP neighbours, via sysctl NET_RT_FLAGS with RTF_LLINFO.
NSArray<NSDictionary *> *HPCopyArpEntries(void);

/// Parsed /var/db/dhcpd_leases — the hotspot's own DHCP server's records.
/// Gives client *names*, which ARP cannot. Records are historical: a lease
/// here does not mean the device is connected now.
NSArray<NSDictionary *> *HPCopyDhcpLeases(void);

/// Devices connected right now: ARP neighbours on the hotspot interfaces,
/// joined to lease records by MAC so they carry a name where one is known.
NSArray<NSDictionary *> *HPCopyConnectedDevices(NSArray<NSString *> *hotspotIfNames);

#pragma mark - Helpers

/// Cumulative bytes per client MAC, as written by the hotspotprod daemon.
/// Empty when the daemon is not running. The values count from whenever the
/// daemon last started, so callers must take deltas rather than read them as
/// per-period figures.
NSDictionary<NSString *, NSNumber *> *HPCopyDaemonDeviceBytes(void);

/// "4.72 GB", "812 MB" — for display.
NSString *HPFormatBytes(uint64_t bytes);

/// Normalise a MAC to lowercase, zero-padded, colon-separated. The lease file
/// writes them unpadded and prefixed with the hardware type ("1,1e:7:67:bb:5b:3f").
NSString *HPNormaliseMac(NSString *raw);
