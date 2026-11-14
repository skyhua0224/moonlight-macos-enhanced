#!/usr/bin/env python3
"""A stand-in Foundation Sunshine host that is paired by pinned certificate (MLC_SEED=tls) and whose Desktop cover is a
10 MB PNG sent at a limited rate, like a host over a 10 Mbit/s overlay.

  art_host.py --cert c.pem --key k.pem --log req.log [--rate 1250000] [--png-bytes 10700000] [--serverinfo-delay S]
              [--delay-from T0 --delay-until T1] [--max-seconds 120]
              [--variants [--preview-bytes 150000] [--drop-full-at N]]
--variants: the poster_variants contract of Foundation Sunshine (docs: host-poster-keyframe-pacing.md, "Contract"):
serverinfo carries <poster_variants>1</poster_variants>; /appasset?...&fsVariant=preview is a small picture with
X-FS-Poster-Variant, ETag, X-FS-Poster-Full-ETag, X-FS-Poster-Full-Length; /appasset without it is the lossless picture
(ETag = SHA-256 of its bytes, Accept-Ranges, 304 to If-None-Match, 206 to Range, If-Range honoured). The same rate limit
carries both. --drop-full-at N closes the connection of the first full-picture response once N bytes of the file have
been sent (a link that drops mid-download); the log line of a full request carries RANGE=<header>.

HTTPS 127.0.0.1:50000 (the client's https port for a host at 127.0.0.1:50005) and plain HTTP on 50005. Endpoints:
/serverinfo (Foundation, paired, SUNSHINE_SERVER_FREE), /applist (one app, the Desktop, 25818427, art "poster"),
/appasset (the PNG, ETag "<version>-poster", honours If-None-Match), /launch /resume (answer 200 with a session url).
--serverinfo-delay S holds every /serverinfo answer for S seconds between T0 and T1 seconds after start: the congested link
of 17:14, where the client's own questions queue behind the cover. One log line per request:
  <seconds since start> <path> -> <status> <seconds taken> <bytes sent> <ok|aborted>
"""
import argparse, re, ssl, socket, threading, time, zlib, struct, os, random, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ap = argparse.ArgumentParser()
ap.add_argument('--cert', required=True); ap.add_argument('--key', required=True); ap.add_argument('--log', required=True)
ap.add_argument('--rate', type=float, default=1250000.0, help='bytes per second of the cover (default 10 Mbit/s)')
ap.add_argument('--png-bytes', type=int, default=10700000)
ap.add_argument('--serverinfo-delay', type=float, default=0.0)
ap.add_argument('--delay-from', type=float, default=0.0); ap.add_argument('--delay-until', type=float, default=1e9)
ap.add_argument('--max-seconds', type=float, default=150)
ap.add_argument('--variants', action='store_true'); ap.add_argument('--preview-bytes', type=int, default=150000)
ap.add_argument('--drop-full-at', type=int, default=0)
ap.add_argument('--https-port', type=int, default=50000); ap.add_argument('--http-port', type=int, default=50005)
ap.add_argument('--fixtures', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fixtures'))
args = ap.parse_args()
T0 = time.time()
logf = open(args.log, 'a', buffering=1)
lock = threading.Lock()
def log(path, status, took, sent, outcome):
    with lock:
        logf.write(f'{time.time() - T0:8.2f} {path} -> {status} {took:.2f} {sent} {outcome}\n')

def make_png(total):
    """A valid PNG of about `total` bytes: incompressible noise in stored deflate blocks."""
    side = int((total / 3) ** 0.5)
    rnd = random.Random(7)
    raw = b''.join(b'\x00' + rnd.randbytes(side * 3) for _ in range(side))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', side, side, 8, 2, 0, 0, 0)) + \
           chunk(b'IDAT', zlib.compress(raw, 0)) + chunk(b'IEND', b'')
PNG = make_png(args.png_bytes)
ETAG = '"3344304115-poster"'
if args.variants:
    PREVIEW = make_png(args.preview_bytes)
    FULL_ETAG = '"%s"' % hashlib.sha256(PNG).hexdigest()
    PREVIEW_ETAG = '"pv-%s"' % hashlib.sha256(PREVIEW).hexdigest()[:32]
    dropped = [False]

serverinfo = open(os.path.join(args.fixtures, 'host-cap2-serverinfo.xml'), encoding='utf-8').read()
serverinfo = re.sub(r'<uniqueid>[^<]*</uniqueid>', '<uniqueid>TLS-0</uniqueid>', serverinfo)
serverinfo = serverinfo.replace('<PairStatus>0</PairStatus>', '<PairStatus>1</PairStatus>')
serverinfo = serverinfo.replace('<LocalIP>10.100.0.133</LocalIP>', '<LocalIP>127.0.0.1</LocalIP>')
if args.variants:
    serverinfo = serverinfo.replace('</root>', '<poster_variants>1</poster_variants></root>')
APPLIST = ('<?xml version="1.0" encoding="utf-8"?><root status_code="200"><App><IsHdrSupported>1</IsHdrSupported>'
           '<AppTitle>Desktop</AppTitle><ID>25818427</ID><FsKind>desktop</FsKind><FsLaunchMode>direct</FsLaunchMode>'
           '<FsArt>poster</FsArt><FsArtVersion>3344304115</FsArtVersion></App></root>').encode()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def reply(self, body, status=200, ctype='application/xml; charset=utf-8', extra=None):
        self.send_response(status); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def send_range(self, body, start, end, status, headers, began, label):
        """Sends body[start:end+1] at the limited rate. Returns the log outcome."""
        sent = 0
        try:
            self.send_response(status); self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(end - start + 1))
            for k, v in headers.items(): self.send_header(k, v)
            self.end_headers()
            chunk = 32768
            off = start
            while off <= end:
                n = min(chunk, end - off + 1)
                self.wfile.write(body[off:off + n]); off += n; sent += n
                time.sleep(n / args.rate)
                if body is PNG and args.drop_full_at and not dropped[0] and off >= args.drop_full_at and off <= end:
                    dropped[0] = True
                    self.wfile.flush()
                    try: self.connection.shutdown(socket.SHUT_RDWR)
                    except Exception: pass
                    self.close_connection = True
                    log(label, status, time.time() - began, sent, 'dropped')
                    return
            log(label, status, time.time() - began, sent, 'ok')
        except Exception:
            self.close_connection = True
            log(label, status, time.time() - began, sent, 'aborted')

    def asset_variants(self, began, q):
        variant = q.get('fsVariant', [''])[0]
        inm = self.headers.get('If-None-Match')
        rng = self.headers.get('Range')
        label = self.path + (f' RANGE={rng}' if rng else '')
        if variant == 'preview':
            if inm == PREVIEW_ETAG:
                self.send_response(304); self.send_header('ETag', PREVIEW_ETAG); self.send_header('Content-Length', '0'); self.end_headers()
                log(label, 304, time.time() - began, 0, 'ok'); return
            hdr = {'ETag': PREVIEW_ETAG, 'X-FS-Poster-Variant': 'preview', 'X-FS-Poster-Full-ETag': FULL_ETAG,
                   'X-FS-Poster-Full-Length': str(len(PNG))}
            self.send_range(PREVIEW, 0, len(PREVIEW) - 1, 200, hdr, began, label); return
        if inm == FULL_ETAG:
            self.send_response(304); self.send_header('ETag', FULL_ETAG); self.send_header('Content-Length', '0'); self.end_headers()
            log(label, 304, time.time() - began, 0, 'ok'); return
        total = len(PNG)
        hdr = {'ETag': FULL_ETAG, 'Accept-Ranges': 'bytes'}
        m = re.match(r'bytes=(\d*)-(\d*)$', rng or '')
        if m and self.headers.get('If-Range', FULL_ETAG) == FULL_ETAG:
            a = int(m.group(1)) if m.group(1) else None
            b = int(m.group(2)) if m.group(2) else total - 1
            if a is None or a >= total or b < a:
                self.send_response(416); self.send_header('Content-Range', f'bytes */{total}'); self.send_header('Content-Length', '0'); self.end_headers()
                log(label, 416, time.time() - began, 0, 'ok'); return
            b = min(b, total - 1)
            hdr['Content-Range'] = f'bytes {a}-{b}/{total}'
            self.send_range(PNG, a, b, 206, hdr, began, label); return
        self.send_range(PNG, 0, total - 1, 200, hdr, began, label)

    def do_GET(self):
        began = time.time(); url = urlparse(self.path); q = parse_qs(url.query)
        if url.path == '/serverinfo':
            if args.serverinfo_delay > 0 and args.delay_from <= began - T0 <= args.delay_until:
                time.sleep(args.serverinfo_delay)
            try: self.reply(serverinfo.encode()); log(self.path, 200, time.time() - began, 0, 'ok')
            except Exception: log(self.path, 200, time.time() - began, 0, 'aborted')
        elif url.path == '/applist':
            self.reply(APPLIST); log(self.path, 200, time.time() - began, 0, 'ok')
        elif url.path == '/appasset' and args.variants:
            self.asset_variants(began, q)
        elif url.path == '/appasset':
            if self.headers.get('If-None-Match') == ETAG:
                self.send_response(304); self.send_header('ETag', ETAG); self.send_header('Content-Length', '0'); self.end_headers()
                log(self.path, 304, time.time() - began, 0, 'ok'); return
            sent = 0
            try:
                self.send_response(200); self.send_header('Content-Type', 'image/png'); self.send_header('Content-Length', str(len(PNG)))
                self.send_header('ETag', ETAG); self.end_headers()
                chunk = 32768
                for off in range(0, len(PNG), chunk):
                    self.wfile.write(PNG[off:off + chunk]); sent += min(chunk, len(PNG) - off)
                    time.sleep(chunk / args.rate)
                log(self.path, 200, time.time() - began, sent, 'ok')
            except Exception:
                log(self.path, 200, time.time() - began, sent, 'aborted'); self.close_connection = True
        elif url.path in ('/launch', '/resume'):
            self.reply(b'<?xml version="1.0"?><root status_code="200"><sessionUrl0>rtsp://127.0.0.1:58010</sessionUrl0><gamesession>1</gamesession></root>')
            log(self.path, 200, time.time() - began, 0, 'ok')
        else:
            self.reply(b'<?xml version="1.0"?><root status_code="404"/>', 404); log(self.path, 404, 0, 0, 'ok')

class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

https = Server(('127.0.0.1', args.https_port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(args.cert, args.key)
ctx.verify_mode = ssl.CERT_NONE
https.socket = ctx.wrap_socket(https.socket, server_side=True)
http = Server(('127.0.0.1', args.http_port), Handler)
threading.Thread(target=https.serve_forever, daemon=True).start()
threading.Thread(target=http.serve_forever, daemon=True).start()
print('art host up', flush=True)
time.sleep(args.max_seconds)
