#!/usr/bin/env python3
"""Userspace bottleneck for the stream smoothness experiment: a UDP relay with a leaky-bucket rate, a tail-drop queue of
`--queue-bytes` and a fixed delay, optionally with random jitter. Stands where a Hysteria2 overlay stands.
  bottleneck.py --listen 0.0.0.0:P --to HOST:P2 --rate-mbps 12 --queue-bytes 30000 --delay-ms 25 [--jitter-ms 5] [--loss 0.0] --seconds S
Prints JSON: packets in/out/dropped (queue), dropped (random)."""
import argparse, socket, time, heapq, random, json, select
ap = argparse.ArgumentParser()
ap.add_argument('--listen', required=True); ap.add_argument('--to', required=True)
ap.add_argument('--rate-mbps', type=float, default=12); ap.add_argument('--queue-bytes', type=int, default=30000)
ap.add_argument('--delay-ms', type=float, default=25); ap.add_argument('--jitter-ms', type=float, default=0)
ap.add_argument('--loss', type=float, default=0.0); ap.add_argument('--seconds', type=float, default=40)
a = ap.parse_args()
lh, lp = a.listen.split(':'); th, tp = a.to.split(':')
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
rx.bind((lh, int(lp))); rx.setblocking(False)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); dst = (th, int(tp))
rate = a.rate_mbps * 1e6 / 8.0   # bytes/s
rnd = random.Random(3)
queue = []            # (release_time, seq, packet)  already serialised through the bucket
free_at = time.perf_counter()   # when the bucket finishes the packet before it
backlog = 0           # bytes accepted but not yet "sent" through the bucket
inq = []              # (finish_time, size) of packets in the bucket
n_in = n_out = n_qdrop = n_rdrop = 0; seq = 0
end = time.perf_counter() + a.seconds + 6
last_in = time.perf_counter()
while time.perf_counter() < end:
    now = time.perf_counter()
    # bytes still queued = those whose bucket finish time is in the future
    while inq and inq[0][0] <= now:
        backlog -= inq.pop(0)[1]
    r, _, _ = select.select([rx], [], [], 0.0005)
    if r:
        for _ in range(200):
            try: p = rx.recv(2048)
            except BlockingIOError: break
            n_in += 1; last_in = time.perf_counter(); now = last_in
            while inq and inq[0][0] <= now: backlog -= inq.pop(0)[1]
            if a.loss and rnd.random() < a.loss: n_rdrop += 1; continue
            if backlog + len(p) > a.queue_bytes: n_qdrop += 1; continue
            start = max(now, free_at); free_at = start + len(p) / rate
            backlog += len(p); inq.append((free_at, len(p)))
            rel = free_at + a.delay_ms / 1000.0 + (rnd.random() * a.jitter_ms / 1000.0 if a.jitter_ms else 0)
            heapq.heappush(queue, (rel, seq, p)); seq += 1
    now = time.perf_counter()
    while queue and queue[0][0] <= now:
        tx.sendto(heapq.heappop(queue)[2], dst); n_out += 1
    if now - last_in > 3 and not queue and n_in: break
print(json.dumps({'in': n_in, 'out': n_out, 'queue_drops': n_qdrop, 'random_drops': n_rdrop}))
