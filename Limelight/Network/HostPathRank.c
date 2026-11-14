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

static int rtt_connect(const char *host, int port, int timeout_ms, int *connect_us) {
    char service[16];
    struct addrinfo hints, *list = NULL, *ai;
    int fd = -1;
    snprintf(service, sizeof(service), "%d", port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, service, &hints, &list) != 0) {
        return -1;
    }
    for (ai = list; ai != NULL && fd < 0; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        long long t0;
        struct pollfd pfd;
        int err = 0;
        socklen_t len = sizeof(err);
        int one = 1;
        if (s < 0) {
            continue;
        }
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
        setsockopt(s, IPPROTO_TCP, 1 /* TCP_NODELAY */, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        t0 = rtt_now_us();
        if (connect(s, ai->ai_addr, ai->ai_addrlen) != 0 && errno != EINPROGRESS) {
            close(s);
            continue;
        }
        pfd.fd = s;
        pfd.events = POLLOUT;
        if (poll(&pfd, 1, timeout_ms) == 1 && getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
            fd = s;
            if (connect_us != NULL) {
                *connect_us = (int)(rtt_now_us() - t0);
            }
        } else {
            close(s);
        }
    }
    freeaddrinfo(list);
    return fd;
}

/* Reads one HTTP answer. *first_us is the time of its first byte (relative to t_send). Returns 1 when the connection can carry
   another request (a Content-Length was given and read, no "Connection: close"), 0 when the answer arrived but the connection
   cannot be reused, -1 on failure. */
static int rtt_read_answer(int fd, long long t_send, int timeout_ms, long long *first_us) {
    char buf[4096];
    size_t have = 0;        /* bytes of the head kept in buf */
    size_t header_end = 0;
    size_t body_have = 0;   /* bytes of the body read so far (a body longer than buf is read and dropped) */
    long content_length = -1;
    int keep = 1;
    int got_first = 0;
    for (;;) {
        struct pollfd pfd;
        ssize_t n;
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, timeout_ms) != 1) {
            return -1;
        }
        if (header_end == 0) {
            n = recv(fd, buf + have, sizeof(buf) - 1 - have, 0);
        } else {
            n = recv(fd, buf, sizeof(buf) - 1, 0);
        }
        if (n <= 0) {
            return got_first && header_end > 0 && content_length == 0 ? 0 : -1;
        }
        if (!got_first) {
            *first_us = rtt_now_us() - t_send;
            got_first = 1;
        }
        if (header_end > 0) {
            body_have += (size_t)n;
        } else {
            char *end;
            have += (size_t)n;
            buf[have] = 0;
            end = strstr(buf, "\r\n\r\n");
            if (end != NULL) {
                char *p;
                header_end = (size_t)(end - buf) + 4;
                body_have = have - header_end;
                for (p = buf; p < end; p++) {
                    if (strncasecmp(p, "content-length:", 15) == 0) {
                        content_length = strtol(p + 15, NULL, 10);
                    } else if (strncasecmp(p, "connection:", 11) == 0) {
                        char *q = p + 11;
                        while (*q == ' ') {
                            q++;
                        }
                        if (strncasecmp(q, "close", 5) == 0) {
                            keep = 0;
                        }
                    } else if (strncasecmp(p, "transfer-encoding:", 18) == 0) {
                        keep = 0;
                    }
                }
            } else if (have >= sizeof(buf) - 1) {
                return -1;   /* a head that does not end inside the buffer is not an HTTP answer we understand */
            }
        }
        if (header_end > 0) {
            if (content_length < 0) {
                return 0;
            }
            if ((long)body_have >= content_length) {
                return keep ? 1 : 0;
            }
        }
    }
}

static int rtt_cmp(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

int host_app_rtt_measure(const char *host, int port, int wanted_samples, int op_timeout_ms, HostAppRtt *out) {
    int values[32];
    int counted = 0, reused = 0, connect_us = 0, reconnects = 0;
    int fd = -1;
    int fresh = 1;       /* the connection has carried no request yet */
    int warmed = 0;      /* a request already went over this connection: the next one is a counted sample */
    int no_warmup = 0;
    char request[512];
    int request_len;
    if (host == NULL || out == NULL || port <= 0) {
        return -1;
    }
    if (wanted_samples < 3) {
        wanted_samples = 3;
    }
    if (wanted_samples > 32) {
        wanted_samples = 32;
    }
    memset(out, 0, sizeof(*out));
    request_len = snprintf(request, sizeof(request),
                           "GET /serverinfo HTTP/1.1\r\nHost: %s:%d\r\nConnection: keep-alive\r\nUser-Agent: Moonlight-rtt\r\n\r\n", host, port);
    if (request_len <= 0 || request_len >= (int)sizeof(request)) {
        return -1;   /* a host name too long for the request line: nothing is sent */
    }
    while (counted < wanted_samples && reconnects < 4 + wanted_samples) {
        long long t_send, first = 0;
        int answer;
        if (fd < 0) {
            int took = 0;
            fd = rtt_connect(host, port, op_timeout_ms, &took);
            if (fd < 0) {
                if (counted >= 3) {
                    break;   /* enough samples were counted before the connection was lost */
                }
                return counted > 0 ? -2 : -1;
            }
            if (connect_us == 0) {
                connect_us = took;
            }
            fresh = 1;
            warmed = 0;
            reconnects++;
        }
        t_send = rtt_now_us();
        if (send(fd, request, (size_t)request_len, 0) != request_len) {
            close(fd);
            fd = -1;
            if (warmed) {
                no_warmup = 1;   /* the connection had answered once and is gone: this host closes after an answer without saying so */
            }
            continue;
        }
        answer = rtt_read_answer(fd, t_send, op_timeout_ms, &first);
        if (answer < 0) {
            close(fd);
            fd = -1;
            if (warmed) {
                no_warmup = 1;   /* same: Foundation Sunshine answers a path it does not know (404) and closes, with no Connection: close */
            }
            if (counted == 0 && reconnects >= 2) {
                return -2;
            }
            continue;
        }
        if (!warmed && !no_warmup) {
            warmed = 1;            /* the first request of a connection opens the tunnel's outbound leg: not counted */
            if (answer == 0) {
                no_warmup = 1;     /* this host closes after every answer: no connection ever carries a second request, so the
                                      first request of a fresh connection is the sample (the handshake is still not in it) */
            }
        } else {
            values[counted++] = (int)first;
            if (!fresh) {
                reused++;
            }
        }
        fresh = 0;
        if (answer == 0) {
            close(fd);
            fd = -1;
        }
    }
    if (fd >= 0) {
        close(fd);
    }
    if (counted < 3) {
        return -2;
    }
    qsort(values, (size_t)counted, sizeof(int), rtt_cmp);
    out->median_us = values[counted / 2];
    out->min_us = values[0];
    out->max_us = values[counted - 1];
    out->samples = counted;
    out->reused = reused;
    out->connect_us = connect_us;
    return 0;
}

int host_app_rtt_display_ms(int us) {
    int ms = (us + 500) / 1000;
    return ms < 1 ? 1 : ms;
}


int host_path_health_avoid(long long last_failure, long long last_success, long long now) {
    if (last_failure <= 0 || last_failure <= last_success) {
        return 0;
    }
    return (now - last_failure) < HOST_PATH_HEALTH_WINDOW_SEC ? 1 : 0;
}

int host_path_health_should_stop(int consecutive_failures) {
    return consecutive_failures >= HOST_PATH_HEALTH_STOP_AFTER ? 1 : 0;
}

int host_path_health_classify(double loss_percent, int control_failed, int seconds_since_start) {
    if (loss_percent >= HOST_PATH_HEALTH_LOSS_PERCENT) {
        return HOST_STREAM_VERDICT_HIGH_LOSS;
    }
    if (control_failed && seconds_since_start < HOST_PATH_HEALTH_EARLY_SEC) {
        return HOST_STREAM_VERDICT_CONTROL_FAILED_EARLY;
    }
    return HOST_STREAM_VERDICT_OK;
}
