#include "HostPathRank.h"

#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

static int failures = 0;

static void expect(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", what);
        failures++;
    }
}

static HostPathSample sample(const char *address, int reachable, int rtt, int hint, int iface) {
    HostPathSample s;
    memset(&s, 0, sizeof(s));
    s.address = address;
    s.reachable = reachable;
    s.rtt_ms = rtt;
    s.jitter_ms = 0;
    s.relay_hint = hint;
    s.iface = iface;
    return s;
}

static int klass_of(const char *address, int rtt, int hint, int iface) {
    HostPathSample s = sample(address, 1, rtt, hint, iface);
    HostPathScore score;
    host_path_score(&s, &score);
    return score.klass;
}


/* ---- application-layer RTT: a host whose network round trip is 5 ms. The probe asks /serverinfo (the one path Foundation Sunshine keeps a
   connection open for); any other path answers 404 and closes. ---- */
static int srv_port = 0;
static int srv_keepalive = 1;
static int srv_serverinfo_ms = 5;
static int srv_big_body = 0;   /* answer /serverinfo with a body larger than the 4 KB read buffer */
static int srv_silent_close = 0;   /* Foundation Sunshine: closes after any answer except /serverinfo, and does not say so */
static void sleep_ms(int ms) { struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }
static void *serve_conn(void *arg) {
    int fd = (int)(long)arg;
    char buf[2048];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) break;
        buf[n] = 0;
        if (strstr(buf, "GET /serverinfo") != NULL) {
            sleep_ms(srv_serverinfo_ms);   /* the host builds the answer: display, GPU ... */
            if (srv_big_body) {
                static char big[9000];
                char head[96];
                int hl = snprintf(head, sizeof(head), "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", (int)sizeof(big));
                memset(big, 'x', sizeof(big));
                send(fd, head, (size_t)hl, 0);
                send(fd, big, sizeof(big), 0);
            } else {
                const char *body = "<root status_code=\"200\"/>";
                char resp[256];
                int len = snprintf(resp, sizeof(resp), "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n%s\r\n%s", (int)strlen(body), srv_keepalive ? "" : "Connection: close\r\n", body);
                send(fd, resp, (size_t)len, 0);
                if (!srv_keepalive) break;
            }
        } else {
            sleep_ms(5);     /* the path's round trip */
            const char *resp = srv_keepalive ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                                             : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(fd, resp, strlen(resp), 0);
            if (!srv_keepalive || srv_silent_close) break;
        }
    }
    close(fd);
    return NULL;
}
static void *accept_loop(void *arg) {
    int lfd = (int)(long)arg;
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        pthread_t t;
        if (fd < 0) break;
        pthread_create(&t, NULL, serve_conn, (void *)(long)fd);
        pthread_detach(t);
    }
    return NULL;
}
static void start_server(void) {
    struct sockaddr_in a;
    socklen_t len = sizeof(a);
    pthread_t t;
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(lfd, (struct sockaddr *)&a, sizeof(a));
    listen(lfd, 16);
    getsockname(lfd, (struct sockaddr *)&a, &len);
    srv_port = ntohs(a.sin_port);
    pthread_create(&t, NULL, accept_loop, (void *)(long)lfd);
    pthread_detach(t);
}

int main(void) {
    HostPathSample paths[4];
    HostPathScore scores[4];
    int order[4];
    int i;

    expect(klass_of("10.100.0.133:57989", 2, -1, HOST_PATH_IFACE_PHYSICAL) == HOST_PATH_CLASS_LAN,
           "on-link private address is LAN");
    expect(klass_of("10.100.0.133:57989", 30, -1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "private address via a tunnel is not LAN");
    expect(klass_of("10.100.0.133", 90, -1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "a slow tunnel is still an overlay: relay needs a hint, not an RTT guess");
    expect(klass_of("10.100.0.133", 56, -1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "a utun route to a private LAN address at 56 ms is an overlay");
    expect(klass_of("10.100.0.133", 400, -1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "a very slow tunnel is an overlay");
    expect(klass_of("100.100.0.84", 8, 0, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "overlay direct when the controller says so");
    expect(klass_of("100.100.0.84", 8, 1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_RELAY,
           "controller relay hint wins");
    expect(klass_of("100.100.0.84", 80, -1, HOST_PATH_IFACE_UNKNOWN) == HOST_PATH_CLASS_OVERLAY,
           "100.64/10 with a high RTT and no controller is an overlay, not a guessed relay");
    expect(klass_of("198.51.100.26", 40, -1, HOST_PATH_IFACE_PHYSICAL) == HOST_PATH_CLASS_PUBLIC,
           "public address on a physical route stays public");
    expect(klass_of("198.51.100.26", 40, -1, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "public address captured by a tunnel is an overlay");
    expect(klass_of("[fe80::1%en0]", 1, -1, HOST_PATH_IFACE_PHYSICAL) == HOST_PATH_CLASS_LAN,
           "link-local IPv6");
    expect(klass_of("Gaming-PC.local.:57989", 5, -1, HOST_PATH_IFACE_PHYSICAL) == HOST_PATH_CLASS_LAN,
           "mDNS name");
    expect(klass_of("[fd7a:115c:a1e0::1234]", 10, 0, HOST_PATH_IFACE_TUNNEL) == HOST_PATH_CLASS_OVERLAY,
           "Tailscale IPv6");

    paths[0] = sample("198.51.100.26", 1, 12, -1, HOST_PATH_IFACE_PHYSICAL);
    paths[1] = sample("10.100.0.133", 1, 40, -1, HOST_PATH_IFACE_PHYSICAL);
    paths[2] = sample("100.100.0.84", 1, 8, 1, HOST_PATH_IFACE_TUNNEL);
    for (i = 0; i < 3; i++) {
        host_path_score(&paths[i], &scores[i]);
    }
    expect(host_path_select(paths, scores, 3, -1) == 1, "LAN beats a faster public address and a relay");

    paths[0] = sample("10.100.0.133:57989", 1, 30, -1, HOST_PATH_IFACE_TUNNEL);
    paths[1] = sample("10.200.0.235", 1, 4, -1, HOST_PATH_IFACE_PHYSICAL);
    host_path_score(&paths[0], &scores[0]);
    host_path_score(&paths[1], &scores[1]);
    expect(host_path_select(paths, scores, 2, 0) == 1, "leave a tunneled private address for on-link LAN");

    paths[0] = sample("DESKTOP.local", 1, 6, -1, HOST_PATH_IFACE_PHYSICAL);
    paths[1] = sample("10.200.0.235", 1, 4, -1, HOST_PATH_IFACE_PHYSICAL);
    host_path_score(&paths[0], &scores[0]);
    host_path_score(&paths[1], &scores[1]);
    expect(host_path_select(paths, scores, 2, 0) == 0, "a 2 ms name/address swing does not flap");
    paths[1].rtt_ms = 80;
    paths[0].rtt_ms = 5;
    expect(host_path_select(paths, scores, 2, 1) == 0, "a large same-class improvement does switch");

    paths[0] = sample("[fd00:db8::1]", 1, 3, -1, HOST_PATH_IFACE_PHYSICAL);
    paths[1] = sample("10.200.0.235", 1, 3, -1, HOST_PATH_IFACE_PHYSICAL);
    host_path_score(&paths[0], &scores[0]);
    host_path_score(&paths[1], &scores[1]);
    host_path_probe_order(paths, scores, 2, order);
    expect(scores[order[0]].family == 6, "IPv6 is probed before IPv4 in the same class");

    expect(host_path_smooth_rtt(-1, 10) == 10, "first sample");
    expect(host_path_smooth_rtt(10, 30) == 20, "half the step");

    expect(host_path_presence_start_ms(0) == 0, "first path starts immediately");
    expect(host_path_presence_start_ms(1) == 50, "second path waits 50 ms");
    expect(host_path_presence_start_ms(5) == 250, "start offset caps at 250 ms");
    expect(host_path_presence_start_ms(18) == 250, "a long tail does not burst and does not walk out");
    expect(host_path_presence_timeout_ms(HOST_PATH_CLASS_LAN) == 1000, "LAN probe budget is 1 s");
    expect(host_path_presence_timeout_ms(HOST_PATH_CLASS_PUBLIC) == 2500, "other probes get 2.5 s");
    expect(host_path_presence_timeout_ms(HOST_PATH_CLASS_RELAY) == 2500, "a relay probe gets 2.5 s");

    {
        int done[1];
        int limit[1];
        int online;
        done[0] = 40;
        limit[0] = host_path_presence_timeout_ms(HOST_PATH_CLASS_LAN);
        online = host_path_presence_online_ms(done, limit, 1);
        expect(online == 40, "a LAN answer at 40 ms is online at 40 ms");
        expect(online >= 0 && online < 300, "an online LAN host is inside 300 ms");
        printf("presence_lan_online_ms=%d\n", online);
        done[0] = 1500;
        expect(host_path_presence_online_ms(done, limit, 1) < 0, "a LAN answer after 1 s does not count");
    }

    paths[0] = sample("100.100.0.84", 1, 40, 1, HOST_PATH_IFACE_TUNNEL);
    paths[1] = sample("10.100.0.133", 1, 2, -1, HOST_PATH_IFACE_PHYSICAL);
    paths[2] = sample("[fe80::1]", 1, 2, -1, HOST_PATH_IFACE_PHYSICAL);
    for (i = 0; i < 3; i++) {
        host_path_score(&paths[i], &scores[i]);
    }
    host_path_presence_order(paths, scores, 3, -1, order);
    expect(order[0] != 0, "with no history a relay is not first");
    expect(scores[order[0]].klass == HOST_PATH_CLASS_LAN, "with no history LAN starts at t=0");
    host_path_presence_order(paths, scores, 3, 0, order);
    expect(order[0] == 0, "the last-good path starts first even when it is a relay");
    expect(order[1] != 0 && order[2] != 0, "the other paths stay in the race");
    {
        int done[2];
        int limit[2];
        int online;
        /* The saved relay is dead. LAN is next, starts at 50 ms, and answers in 20 ms. */
        done[0] = -1;
        done[1] = host_path_presence_start_ms(1) + 20;
        limit[0] = host_path_presence_timeout_ms(scores[0].klass);
        limit[1] = host_path_presence_timeout_ms(HOST_PATH_CLASS_LAN);
        online = host_path_presence_online_ms(done, limit, 2);
        expect(done[1] == 70, "LAN completion is 50 ms plus its own 20 ms");
        expect(online == 70, "a dead last-good relay does not hide the LAN answer");
        expect(online >= 0 && online < 300, "failover is still inside 300 ms");
        printf("presence_failover_online_ms=%d\n", online);
    }


    {
        HostAppRtt r;
        int rc;
        long long t0;
        start_server();
        rc = host_app_rtt_measure("127.0.0.1", srv_port, 5, 1500, &r);
        expect(rc == 0, "app rtt: measured");
        printf("app_rtt: median=%d us samples=%d reused=%d connect=%d us\n", r.median_us, r.samples, r.reused, r.connect_us);
        expect(host_app_rtt_display_ms(r.median_us) >= 4 && host_app_rtt_display_ms(r.median_us) <= 15, "app rtt: about 5 ms over an open connection");
        expect(r.reused >= 3, "app rtt: samples went over a connection that was already open");
        srv_keepalive = 0;   /* a host that closes after every answer: still the application round trip, not connect time */
        rc = host_app_rtt_measure("127.0.0.1", srv_port, 5, 1500, &r);
        expect(rc == 0 && host_app_rtt_display_ms(r.median_us) >= 4 && host_app_rtt_display_ms(r.median_us) <= 15, "app rtt: close-after-answer host still reads about 5 ms");
        srv_keepalive = 1;
        /* Foundation Sunshine (2026.1111): /serverinfo is cheap and keeps the connection; any other path answers and closes without
           saying so. The probe asks /serverinfo, so the samples go over one open connection. */
        srv_serverinfo_ms = 5;
        srv_silent_close = 1;
        rc = host_app_rtt_measure("127.0.0.1", srv_port, 5, 1500, &r);
        expect(rc == 0 && host_app_rtt_display_ms(r.median_us) >= 4 && host_app_rtt_display_ms(r.median_us) <= 15, "app rtt: a host like Foundation Sunshine reads about 5 ms (was unavailable: -2)");
        expect(rc == 0 && r.reused >= 3, "app rtt: Foundation-style host: the samples went over an open connection");
        /* a host that answers /serverinfo with a body longer than the read buffer still keeps the connection */
        srv_big_body = 1;
        rc = host_app_rtt_measure("127.0.0.1", srv_port, 5, 1500, &r);
        expect(rc == 0 && r.reused >= 3, "app rtt: a /serverinfo body larger than the buffer does not end the connection");
        srv_big_body = 0;
        srv_silent_close = 0;
        t0 = 0; (void)t0;
        expect(host_app_rtt_measure("127.0.0.1", 1, 5, 300, &r) < 0, "app rtt: a closed port is a failure, not a number");
        expect(host_app_rtt_display_ms(0) == 1 && host_app_rtt_display_ms(1499) == 1 && host_app_rtt_display_ms(1500) == 2, "app rtt: display rounds and is never below 1 ms");
    }

    {
        long long now = 100000;
        expect(host_path_health_avoid(now - 600, 0, now) == 1, "health: a path that failed 10 minutes ago is avoided");
        expect(host_path_health_avoid(now - 600, now - 60, now) == 0, "health: a good stream after the failure clears it");
        expect(host_path_health_avoid(now - 1900, 0, now) == 0, "health: the failure is forgotten after 30 minutes");
        expect(host_path_health_avoid(0, 0, now) == 0, "health: a path never used is not avoided");
        expect(host_path_health_should_stop(2) == 0 && host_path_health_should_stop(3) == 1, "health: stop after 3 failures in a row");
        expect(host_path_health_classify(72.9, 0, 10) == HOST_STREAM_VERDICT_HIGH_LOSS, "health: 72.9 % loss over a tunnel is high loss (a user log)");
        expect(host_path_health_classify(0, 1, 12) == HOST_STREAM_VERDICT_CONTROL_FAILED_EARLY, "health: control stream failed 12 s after start (a user log: 13:08)");
        expect(host_path_health_classify(0, 1, 3600) == HOST_STREAM_VERDICT_OK, "health: a stream that ran an hour and then ended is not a failed path");
        expect(host_path_health_classify(5, 0, 10) == HOST_STREAM_VERDICT_OK, "health: some loss is not a verdict");
    }

    if (failures) {
        fprintf(stderr, "%d failed\n", failures);
        return 1;
    }
    printf("host_path_rank_ok\n");
    return 0;
}
