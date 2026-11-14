#ifndef HOST_PATH_RANK_H
#define HOST_PATH_RANK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Classes, best first. A tunnel route is never "LAN", even when the
   address is a private one (RFC 1918). 100.64.0.0/10 is Shared Address
   Space (RFC 6598), which overlay networks use. */
typedef enum HostPathClass {
    HOST_PATH_CLASS_LAN = 0,
    HOST_PATH_CLASS_PUBLIC = 1,
    HOST_PATH_CLASS_OVERLAY = 2,
    HOST_PATH_CLASS_RELAY = 3,
    HOST_PATH_CLASS_UNKNOWN = 4
} HostPathClass;

typedef enum HostPathIface {
    HOST_PATH_IFACE_UNKNOWN = 0,
    HOST_PATH_IFACE_PHYSICAL = 1,
    HOST_PATH_IFACE_TUNNEL = 2,
    HOST_PATH_IFACE_LOOPBACK = 3
} HostPathIface;

typedef struct HostPathSample {
    const char *address;
    int reachable;  /* 1 or 0 */
    int rtt_ms;     /* smoothed; negative if unknown */
    int jitter_ms;  /* negative if unknown */
    int relay_hint; /* 1 relayed, 0 not, -1 unknown */
    int iface;      /* HostPathIface */
    int manual;
} HostPathSample;

typedef struct HostPathScore {
    int index;
    int klass;
    int family; /* 6, 4, or 0 for a name */
    int literal;
    int relayed;
} HostPathScore;

void host_path_score(const HostPathSample *sample, HostPathScore *out);
int host_path_rank_key(const HostPathSample *sample, const HostPathScore *score);
int host_path_select(const HostPathSample *samples, const HostPathScore *scores,
                     int count, int current_index);
void host_path_probe_order(const HostPathSample *samples, const HostPathScore *scores,
                           int count, int *order);
double host_path_smooth_rtt(double previous, int sample_ms);

/* Application-layer round trip time of a host, in the sense the user means by "latency": a few tiny HTTP requests (a path
   the host answers with a 404) sent on one connection that is already open, the time from writing the request to the first
   byte of the answer, median of the samples. It deliberately does NOT include the TCP handshake (a TUN proxy such as
   Hysteria2 or Clash completes it locally, near 0 ms), the TLS handshake, or the time a host needs to build /serverinfo
   (Foundation Sunshine asks the display and the GPU). The first request on a connection is a warm-up and not counted: a
   tunnel opens its outbound leg on the first data. */
typedef struct HostAppRtt {
    int median_us;      /* median of the counted samples, microseconds */
    int min_us;
    int max_us;
    int samples;        /* counted samples */
    int reused;         /* how many of them went over an already used connection */
    int connect_us;     /* the handshake, for the log only: never part of the result */
} HostAppRtt;

/* 0 and *out filled when at least 3 samples were counted, negative otherwise (-1 unreachable, -2 too few answers). */
int host_app_rtt_measure(const char *host, int port, int wanted_samples, int op_timeout_ms, HostAppRtt *out);
/* microseconds -> the millisecond figure shown: rounded, never below 1 */
int host_app_rtt_display_ms(int us);

/* ---- health of the path a stream used ----
   A stream that dies in its first minute, or loses most of its frames, says something about the PATH it ran over (a TUN proxy
   that drops UDP, a relay): the next automatic choice avoids that path for 30 minutes unless a later stream on it went well.
   A path the user pinned is never switched silently; after 3 failures in a row automatic reconnecting stops and says why. */
#define HOST_PATH_HEALTH_WINDOW_SEC 1800
#define HOST_PATH_HEALTH_STOP_AFTER 3
#define HOST_PATH_HEALTH_LOSS_PERCENT 30.0
#define HOST_PATH_HEALTH_EARLY_SEC 60
typedef enum HostStreamVerdict {
    HOST_STREAM_VERDICT_OK = 0,
    HOST_STREAM_VERDICT_HIGH_LOSS = 1,
    HOST_STREAM_VERDICT_CONTROL_FAILED_EARLY = 2
} HostStreamVerdict;
/* 1 when the newest word on a path is a failure and is younger than the window. Times are seconds since any epoch; 0 = never. */
int host_path_health_avoid(long long last_failure, long long last_success, long long now);
int host_path_health_should_stop(int consecutive_failures);
/* loss_percent: share of frames lost; control_failed: the control stream ended with an error; seconds_since_start: age of the stream. */
int host_path_health_classify(double loss_percent, int control_failed, int seconds_since_start);



/* Presence race. last_good is an index into samples, or -1 when there is no
   saved reachable address. Position 0 starts immediately; later positions are
   staggered. See HostPathRank.c for the RFC 8305 departure. */
void host_path_presence_order(const HostPathSample *samples, const HostPathScore *scores,
                              int count, int last_good, int *order);
int host_path_presence_start_ms(int position);
int host_path_presence_timeout_ms(int klass);
/* completion_ms[i] is the race-relative time the attempt finished, or negative
   if it failed. A finish counts only inside that attempt's timeout and the
   2500 ms budget. Returns -1 when none did. */
int host_path_presence_online_ms(const int *completion_ms, const int *timeout_ms, int count);

#ifdef __cplusplus
}
#endif

#endif
