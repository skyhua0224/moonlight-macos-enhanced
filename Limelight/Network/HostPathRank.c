#include "HostPathRank.h"

#include <ctype.h>
#include <string.h>
#include <strings.h>

/* Same-class switch needs a smoothed improvement at least this large, so a
   probe that alternates between a name and its address cannot flap. */
static const int kSwitchImprovementMs = 20;

static int is_digits(const char *s) {
    if (s == NULL || *s == '\0') {
        return 0;
    }
    for (; *s; s++) {
        if (!isdigit((unsigned char)*s)) {
            return 0;
        }
    }
    return 1;
}

/* Writes the host part into host_out. Returns 6, 4, or 0 (a name). */
static int split_host(const char *address, char *host_out, size_t host_len) {
    const char *start = address != NULL ? address : "";
    const char *end = start + strlen(start);
    while (start < end && isspace((unsigned char)*start)) {
        start++;
    }
    while (end > start && isspace((unsigned char)end[-1])) {
        end--;
    }
    if (start < end && *start == '[') {
        const char *close = memchr(start, ']', (size_t)(end - start));
        if (close != NULL) {
            start++;
            end = close;
        }
    } else {
        const char *colon = NULL;
        const char *p;
        int colons = 0;
        for (p = start; p < end; p++) {
            if (*p == ':') {
                colons++;
                colon = p;
            }
        }
        /* host:port, including an mDNS name with a trailing dot. */
        if (colons == 1 && colon != NULL && is_digits(colon + 1)) {
            end = colon;
        }
    }
    while (end > start && end[-1] == '.') {
        end--;
    }
    if ((size_t)(end - start) >= host_len) {
        end = start + host_len - 1;
    }
    memcpy(host_out, start, (size_t)(end - start));
    host_out[end - start] = '\0';
    if (strchr(host_out, ':') != NULL) {
        return 6;
    }
    {
        int dots = 0;
        int octets = 0;
        const char *p = host_out;
        int value = 0;
        int digits = 0;
        for (; *p; p++) {
            if (*p == '.') {
                if (digits == 0 || value > 255) {
                    return 0;
                }
                octets++;
                dots++;
                value = 0;
                digits = 0;
            } else if (isdigit((unsigned char)*p)) {
                value = value * 10 + (*p - '0');
                digits++;
            } else {
                return 0;
            }
        }
        if (dots == 3 && digits > 0 && value <= 255 && octets == 3) {
            return 4;
        }
    }
    return 0;
}

static int ipv4_octet(const char *host, int index) {
    int value = 0;
    int seen = 0;
    for (; *host && index >= 0; host++) {
        if (*host == '.') {
            if (index == 0) {
                return seen ? value : -1;
            }
            index--;
            value = 0;
            seen = 0;
        } else {
            value = value * 10 + (*host - '0');
            seen = 1;
        }
    }
    return (index == 0 && seen) ? value : -1;
}

static int prefix_eq(const char *host, const char *prefix) {
    size_t n = strlen(prefix);
    return strncasecmp(host, prefix, n) == 0;
}

void host_path_score(const HostPathSample *sample, HostPathScore *out) {
    char host[256];
    int family;
    int klass = HOST_PATH_CLASS_UNKNOWN;
    int a = 0;
    int b = 0;
    memset(out, 0, sizeof(*out));
    family = split_host(sample != NULL ? sample->address : NULL, host, sizeof(host));
    out->family = family;
    out->literal = family == 4 || family == 6;
    if (host[0] == '\0') {
        out->klass = HOST_PATH_CLASS_UNKNOWN;
        return;
    }
    if (family == 4) {
        a = ipv4_octet(host, 0);
        b = ipv4_octet(host, 1);
        if (a == 127 || (a == 0)) {
            klass = HOST_PATH_CLASS_UNKNOWN;
        } else if (a == 169 && b == 254) {
            klass = HOST_PATH_CLASS_LAN;
        } else if (a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)) {
            klass = HOST_PATH_CLASS_LAN; /* RFC 1918 */
        } else if (a == 100 && b >= 64 && b <= 127) {
            klass = HOST_PATH_CLASS_OVERLAY; /* RFC 6598, used by overlay networks */
        } else if (a == 198 && (b == 18 || b == 19)) {
            klass = HOST_PATH_CLASS_OVERLAY; /* 198.18.0.0/15, the usual capture-all TUN range */
        } else {
            klass = HOST_PATH_CLASS_PUBLIC;
        }
    } else if (family == 6) {
        if (prefix_eq(host, "fe80:")) {
            klass = HOST_PATH_CLASS_LAN;
        } else if (prefix_eq(host, "fd7a:115c:a1e0:")) {
            klass = HOST_PATH_CLASS_OVERLAY; /* Tailscale IPv6 ULA */
        } else if (prefix_eq(host, "fc") || prefix_eq(host, "fd")) {
            klass = HOST_PATH_CLASS_LAN; /* other unique-local, on-link unless a tunnel says otherwise */
        } else if (prefix_eq(host, "::1")) {
            klass = HOST_PATH_CLASS_UNKNOWN;
        } else {
            klass = HOST_PATH_CLASS_PUBLIC;
        }
    } else if (strlen(host) >= 6 && strcasecmp(host + strlen(host) - 6, ".local") == 0) {
        klass = HOST_PATH_CLASS_LAN;
    } else {
        klass = HOST_PATH_CLASS_PUBLIC; /* a DNS name is a remote name until a probe says otherwise */
    }

    if (sample != NULL && sample->iface == HOST_PATH_IFACE_TUNNEL) {
        /* The route, not the address text, decides. A private address reached
           through utun is an overlay path, not the LAN. */
        if (klass == HOST_PATH_CLASS_LAN || klass == HOST_PATH_CLASS_PUBLIC) {
            klass = HOST_PATH_CLASS_OVERLAY;
        }
    } else if (sample != NULL && sample->iface == HOST_PATH_IFACE_LOOPBACK) {
        klass = HOST_PATH_CLASS_UNKNOWN;
    }

    out->relayed = 0;
    if (sample != NULL && sample->relay_hint == 1) {
        klass = HOST_PATH_CLASS_RELAY;
        out->relayed = 1;
    }
    /* No RTT guess: a slow overlay path is still an overlay path. Relayed only when something says so (relay_hint == 1: the
       overlay's own controller status, a TURN allocation); a utun route slower than 50-80 ms is not a relay by itself. */
    out->klass = klass;
}

int host_path_rank_key(const HostPathSample *sample, const HostPathScore *score) {
    int rtt;
    int jitter;
    if (sample == NULL || score == NULL || !sample->reachable) {
        return 2000000000;
    }
    rtt = sample->rtt_ms < 0 ? 500000 : sample->rtt_ms;
    if (rtt > 500000) {
        rtt = 500000;
    }
    jitter = sample->jitter_ms > 0 ? sample->jitter_ms : 0;
    if (jitter > 1000) {
        jitter = 1000;
    }
    /* Class dominates. Inside a class, lower smoothed RTT wins, then lower jitter,
       then a numeric address over a name that measured about the same. */
    return score->klass * 1000000 + rtt * 10 + jitter / 10 + (score->literal ? 0 : 5);
}

int host_path_select(const HostPathSample *samples, const HostPathScore *scores,
                     int count, int current_index) {
    int best = -1;
    int best_key = 0;
    int i;
    for (i = 0; i < count; i++) {
        int key = host_path_rank_key(&samples[i], &scores[i]);
        if (key >= 2000000000) {
            continue;
        }
        if (best < 0 || key < best_key) {
            best = i;
            best_key = key;
        }
    }
    if (best < 0) {
        return current_index >= 0 && current_index < count ? current_index : -1;
    }
    if (current_index < 0 || current_index >= count || !samples[current_index].reachable) {
        return best;
    }
    if (scores[best].klass < scores[current_index].klass) {
        return best; /* LAN over a public address, either of those over a relay */
    }
    if (scores[best].klass > scores[current_index].klass) {
        return current_index; /* do not leave a working direct path for a relay */
    }
    if (samples[current_index].rtt_ms >= 0 && samples[best].rtt_ms >= 0 &&
        samples[current_index].rtt_ms - samples[best].rtt_ms >= kSwitchImprovementMs) {
        return best;
    }
    return current_index;
}

void host_path_probe_order(const HostPathSample *samples, const HostPathScore *scores,
                           int count, int *order) {
    int i;
    for (i = 0; i < count; i++) {
        order[i] = i;
    }
    /* Insertion sort. Better class first, and inside a class IPv6 before IPv4,
       which is the family order Happy Eyeballs starts from. */
    for (i = 1; i < count; i++) {
        int item = order[i];
        int j = i;
        while (j > 0) {
            int prev = order[j - 1];
            int prev_key = scores[prev].klass * 10 + (scores[prev].family == 6 ? 0 : 1);
            int item_key = scores[item].klass * 10 + (scores[item].family == 6 ? 0 : 1);
            if (prev_key <= item_key) {
                break;
            }
            order[j] = prev;
            j--;
        }
        order[j] = item;
    }
    (void)samples;
}

double host_path_smooth_rtt(double previous, int sample_ms) {
    if (sample_ms < 0) {
        return previous;
    }
    if (previous < 0) {
        return (double)sample_ms;
    }
    return previous * 0.5 + (double)sample_ms * 0.5;
}

/* RFC 8305 section 4: prefer a previously used address, then historical RTT.
   Section 5 recommends a 250 ms Connection Attempt Delay, recommends a 100 ms
   minimum, and says a later attempt MUST NOT start within 10 ms of the
   previous one. Section 8 repeats those values and allows different ones.
   These are a few already-resolved paths, and the host has to show online
   within 300 ms, so the delay is 50 ms: above the 10 ms floor, below the
   100 ms recommendation. A 250 ms delay would spend the whole budget on the
   first dead path. Section 5 also says to cancel the other attempts once one
   succeeds. Presence does not: the rest of the answers only rank the
   automatic choice. The wait for the first answer is what ends. */
static const int kPresenceStaggerMs = 50;
static const int kPresenceStartCapMs = 250;
static const int kPresenceBudgetMs = 2500;
static const int kPresenceLanTimeoutMs = 1000;

void host_path_presence_order(const HostPathSample *samples, const HostPathScore *scores,
                              int count, int last_good, int *order) {
    int i;
    if (order == NULL || count <= 0) {
        return;
    }
    host_path_probe_order(samples, scores, count, order);
    if (last_good < 0 || last_good >= count) {
        return;
    }
    for (i = 0; i < count; i++) {
        if (order[i] == last_good) {
            break;
        }
    }
    if (i == count) {
        return;
    }
    while (i > 0 && i < count) {
        order[i] = order[i - 1];
        i--;
    }
    order[0] = last_good;
}

int host_path_presence_start_ms(int position) {
    int start;
    if (position <= 0) {
        return 0;
    }
    start = position * kPresenceStaggerMs;
    if (start > kPresenceStartCapMs) {
        return kPresenceStartCapMs;
    }
    return start;
}

int host_path_presence_timeout_ms(int klass) {
    if (klass == HOST_PATH_CLASS_LAN) {
        return kPresenceLanTimeoutMs;
    }
    return kPresenceBudgetMs;
}

int host_path_presence_online_ms(const int *completion_ms, const int *timeout_ms, int count) {
    int best = -1;
    int i;
    if (completion_ms == NULL || count <= 0) {
        return -1;
    }
    for (i = 0; i < count; i++) {
        int done = completion_ms[i];
        int limit = timeout_ms != NULL ? timeout_ms[i] : kPresenceBudgetMs;
        if (limit > kPresenceBudgetMs) {
            limit = kPresenceBudgetMs;
        }
        if (done < 0 || done > limit) {
            continue;
        }
        if (best < 0 || done < best) {
            best = done;
        }
    }
    return best;
}


/* ---- application-layer RTT (see HostPathRank.h) ---- */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

static long long rtt_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

