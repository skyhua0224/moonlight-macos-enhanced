#!/usr/bin/env python3
"""Stand-in for a Moonlight video stream on the wire (netem experiment): frames at a fixed rate, each frame
data+parity packets, a large key frame now and then. Sender and receiver in one file.

  udp_frames.py recv --port P --seconds S --out result.json
  udp_frames.py send --host H --port P --seconds S --fps 100 --data-pkts 9 --parity 0.25 --idr-pkts 90 --idr-every 3 --pace burst|spread:<ms>

Packet: 8 bytes header (frame u32, index u16, total u16) + payload, 940 bytes in all (896 payload as the client asks over a tunnel).
A frame is "decodable" when the receiver got at least `data` of its packets (Reed-Solomon: any `data` of data+parity)."""
import argparse, socket, struct, time, json, sys

ap = argparse.ArgumentParser()
ap.add_argument('mode', choices=('send', 'recv'))
ap.add_argument('--host', default='127.0.0.1'); ap.add_argument('--port', type=int, required=True)
ap.add_argument('--seconds', type=float, default=30); ap.add_argument('--fps', type=int, default=100)
ap.add_argument('--data-pkts', type=int, default=9); ap.add_argument('--parity', type=float, default=0.25)
ap.add_argument('--idr-pkts', type=int, default=90); ap.add_argument('--idr-every', type=float, default=3.0)
ap.add_argument('--idr-spread-ms', type=float, default=0); ap.add_argument('--pace', default='burst'); ap.add_argument('--out', default='')
args = ap.parse_args()
SIZE = 940; HDR = struct.Struct('>IHHH')   # frame, index, total, data

if args.mode == 'send':
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    dst = (args.host, args.port)
    pad = b'\0' * (SIZE - HDR.size)
    spread = float(args.pace.split(':')[1]) / 1000.0 if args.pace.startswith('spread') else 0.0
    interval = 1.0 / args.fps
    start = time.perf_counter(); frame = 0; sent = 0
    next_idr = start + args.idr_every
    while True:
        t0 = start + frame * interval
        now = time.perf_counter()
        if now - start > args.seconds: break
        while time.perf_counter() < t0: pass
        data = args.data_pkts; big = False
        if t0 >= next_idr: data = args.idr_pkts; next_idr += args.idr_every; big = True
        total = data + max(1, int(data * args.parity + 0.5))
        span = (args.idr_spread_ms / 1000.0) if (big and args.idr_spread_ms) else spread
        for i in range(total):
            if span:
                due = time.perf_counter() if i == 0 else t0 + span * i / total
                while time.perf_counter() < due: pass
            s.sendto(HDR.pack(frame, i, total, data) + pad, dst); sent += 1
        frame += 1
    print(json.dumps({'frames': frame, 'packets': sent}))
else:
    r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    r.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    r.bind(('0.0.0.0', args.port)); r.settimeout(2.0)
    frames = {}; end = time.time() + args.seconds + 4; got = 0
    while time.time() < end:
        try: d = r.recv(2048)
        except socket.timeout: continue
        f, i, total, data = HDR.unpack_from(d); got += 1
        e = frames.setdefault(f, [data, total, 0]); e[2] += 1
    ok = sum(1 for v in frames.values() if v[2] >= v[0])
    big = [v for v in frames.values() if v[0] > 20]; big_ok = sum(1 for v in big if v[2] >= v[0])
    res = {'packets_received': got, 'frames_seen': len(frames), 'frames_decodable': ok, 'big_frames_seen': len(big), 'big_decodable': big_ok}
    print(json.dumps(res))
    if args.out: open(args.out, 'w').write(json.dumps(res))
