#include "HostPathRoute.h"

#include <ctype.h>
#include <stdint.h>
#include <string.h>

#if defined(__APPLE__)
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

static void copy_name(char *name, size_t name_len, const char *src) {
    size_t n;
    if (name == NULL || name_len == 0) {
        return;
    }
    if (src == NULL) {
        name[0] = 0;
        return;
    }
    n = strlen(src);
    if (n >= name_len) {
        n = name_len - 1;
    }
    memcpy(name, src, n);
    name[n] = 0;
}

static int kind_for_ifname(const char *name) {
    if (name == NULL || name[0] == 0) {
        return HOST_PATH_IFACE_UNKNOWN;
    }
    if (strncmp(name, "en", 2) == 0 || strncmp(name, "bridge", 6) == 0) {
        return HOST_PATH_IFACE_PHYSICAL;
    }
    if (strcmp(name, "lo0") == 0 || strncmp(name, "lo", 2) == 0) {
        return HOST_PATH_IFACE_LOOPBACK;
    }
    if (strncmp(name, "utun", 4) == 0 || strncmp(name, "tun", 3) == 0 ||
        strncmp(name, "ipsec", 5) == 0 || strncmp(name, "ppp", 3) == 0 ||
        strncmp(name, "tap", 3) == 0 || strncmp(name, "awdl", 4) == 0 ||
        strncmp(name, "llw", 3) == 0) {
        return HOST_PATH_IFACE_TUNNEL;
    }
    return HOST_PATH_IFACE_UNKNOWN;
}

#if defined(__APPLE__)

static int parse_numeric(const char *address, struct sockaddr_storage *out) {
    char host[256];
    const char *start = address != NULL ? address : "";
    const char *end;
    const char *zone;
    size_t n;
    memset(out, 0, sizeof(*out));
    while (*start && isspace((unsigned char)*start)) {
        start++;
    }
    end = start + strlen(start);
    while (end > start && isspace((unsigned char)end[-1])) {
        end--;
    }
    if (*start == '[') {
        const char *close = memchr(start, ']', (size_t)(end - start));
        if (close == NULL) {
            return 0;
        }
        start++;
        end = close;
    } else {
        const char *colon = strrchr(start, ':');
        int only = colon != NULL && memchr(start, ':', (size_t)(colon - start)) == NULL;
        if (only && colon < end) {
            const char *p = colon + 1;
            int digits = p < end;
            for (; p < end; p++) {
                if (!isdigit((unsigned char)*p)) {
                    digits = 0;
                    break;
                }
            }
            if (digits) {
                end = colon;
            }
        }
    }
    n = (size_t)(end - start);
    if (n == 0 || n >= sizeof(host)) {
        return 0;
    }
    memcpy(host, start, n);
    host[n] = 0;
    zone = strchr(host, '%');
    if (zone != NULL) {
        host[zone - host] = 0;
    }
    {
        struct sockaddr_in *sin = (struct sockaddr_in *)out;
        if (inet_pton(AF_INET, host, &sin->sin_addr) == 1) {
            sin->sin_len = sizeof(*sin);
            sin->sin_family = AF_INET;
            return 4;
        }
    }
    {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)out;
        if (inet_pton(AF_INET6, host, &sin6->sin6_addr) == 1) {
            sin6->sin6_len = sizeof(*sin6);
            sin6->sin6_family = AF_INET6;
            return 6;
        }
    }
    return 0;
}

static int same_subnet(struct ifaddrs *ifa, const struct sockaddr_storage *dst) {
    if (ifa->ifa_addr == NULL || ifa->ifa_netmask == NULL) {
        return 0;
    }
    if (ifa->ifa_addr->sa_family != dst->ss_family) {
        return 0;
    }
    if (dst->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)ifa->ifa_addr;
        const struct sockaddr_in *m = (const struct sockaddr_in *)ifa->ifa_netmask;
        const struct sockaddr_in *d = (const struct sockaddr_in *)dst;
        return (a->sin_addr.s_addr & m->sin_addr.s_addr) == (d->sin_addr.s_addr & m->sin_addr.s_addr);
    }
    if (dst->ss_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)ifa->ifa_addr;
        const struct sockaddr_in6 *m = (const struct sockaddr_in6 *)ifa->ifa_netmask;
        const struct sockaddr_in6 *d = (const struct sockaddr_in6 *)dst;
        int i;
        for (i = 0; i < 16; i++) {
            if ((a->sin6_addr.s6_addr[i] & m->sin6_addr.s6_addr[i]) !=
                (d->sin6_addr.s6_addr[i] & m->sin6_addr.s6_addr[i])) {
                return 0;
            }
        }
        return 1;
    }
    return 0;
}

static int route_ifname(const struct sockaddr *dst, char *name, size_t name_len) {
    int sock;
    int attempt;
    struct {
        struct rt_msghdr hdr;
        unsigned char data[512];
    } msg;
    size_t dst_len = dst->sa_len;
    /* The kernel answers with rtm_index. RTA_IFP is not always present. */
    if (dst_len == 0 || dst_len > sizeof(msg.data)) {
        return -1;
    }
    sock = socket(PF_ROUTE, SOCK_RAW, 0);
    if (sock < 0) {
        return -1;
    }
    memset(&msg, 0, sizeof(msg));
    msg.hdr.rtm_msglen = (u_short)(sizeof(struct rt_msghdr) + dst_len);
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_type = RTM_GET;
    msg.hdr.rtm_addrs = RTA_DST;
    msg.hdr.rtm_pid = getpid();
    msg.hdr.rtm_seq = 1;
    memcpy(msg.data, dst, dst_len);
    if (write(sock, &msg, msg.hdr.rtm_msglen) < 0) {
        close(sock);
        return -1;
    }
    for (attempt = 0; attempt < 4; attempt++) {
        char resolved[IFNAMSIZ];
        ssize_t got = read(sock, &msg, sizeof(msg));
        if (got < (ssize_t)sizeof(struct rt_msghdr)) {
            close(sock);
            return -1;
        }
        if (msg.hdr.rtm_pid != getpid() || msg.hdr.rtm_seq != 1) {
            continue;
        }
        if (msg.hdr.rtm_errno != 0 || msg.hdr.rtm_index == 0) {
            close(sock);
            return -1;
        }
        resolved[0] = 0;
        if (if_indextoname(msg.hdr.rtm_index, resolved) == NULL) {
            close(sock);
            return -1;
        }
        copy_name(name, name_len, resolved);
        close(sock);
        return 0;
    }
    close(sock);
    return -1;
}

int host_path_route_kind(const char *address, char *name, size_t name_len) {
    struct sockaddr_storage dst;
    struct ifaddrs *list = NULL;
    struct ifaddrs *ifa;
    char ifname[IFNAMSIZ];
    int family;
    int on_link_kind = HOST_PATH_IFACE_UNKNOWN;
    ifname[0] = 0;
    family = parse_numeric(address, &dst);
    if (family == 0) {
        copy_name(name, name_len, NULL);
        return HOST_PATH_IFACE_UNKNOWN;
    }
    if (getifaddrs(&list) == 0) {
        for (ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
            int kind;
            if ((ifa->ifa_flags & IFF_UP) == 0) {
                continue;
            }
            if (!same_subnet(ifa, &dst)) {
                continue;
            }
            kind = kind_for_ifname(ifa->ifa_name);
            if (kind == HOST_PATH_IFACE_PHYSICAL) {
                copy_name(name, name_len, ifa->ifa_name);
                freeifaddrs(list);
                return HOST_PATH_IFACE_PHYSICAL;
            }
            if (on_link_kind == HOST_PATH_IFACE_UNKNOWN) {
                on_link_kind = kind;
                copy_name(ifname, sizeof(ifname), ifa->ifa_name);
            }
        }
        freeifaddrs(list);
    }
    if (route_ifname((struct sockaddr *)&dst, ifname, sizeof(ifname)) == 0) {
        int kind = kind_for_ifname(ifname);
        copy_name(name, name_len, ifname);
        if (kind != HOST_PATH_IFACE_UNKNOWN) {
            return kind;
        }
    }
    copy_name(name, name_len, ifname);
    return on_link_kind;
}

#else

int host_path_route_kind(const char *address, char *name, size_t name_len) {
    (void)address;
    copy_name(name, name_len, NULL);
    return HOST_PATH_IFACE_UNKNOWN;
}

#endif
