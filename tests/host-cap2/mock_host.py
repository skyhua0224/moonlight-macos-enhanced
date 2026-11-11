#!/usr/bin/env python3
"""A stand-in Foundation Sunshine host for the client's discovery, over plain HTTP, built from tests/fixtures/host-cap*.xml.

  mock_host.py --cap 2 --port 47989 --log requests.log [--bump-every 6] [--ignore-wait] [--no-events-feature]
  mock_host.py --cap 1 --port 47989 --log requests.log

cap 2: /serverinfo answers FsEventSeq; `/serverinfo?fsWait=<seq>&timeout=<s>` holds the request until the counter is past <seq>
(or <s> seconds, or 25), the long-poll of the Foundation Sunshine events feature. --bump-every N raises the counter (and
FsSessionStarted) every N seconds. --ignore-wait answers a fsWait request at once, like a host that lists events but does not
wait. cap 1: fsWait is not a parameter the host knows; it answers a plain /serverinfo. /applist answers the cap 2 app list.
Every request is logged as one line: <epoch> <path-with-query> -> <status> <seconds waited>.
Stops after --max-seconds (default 600) or on SIGTERM.
"""
import argparse, re, threading, time, sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ap = argparse.ArgumentParser()
ap.add_argument('--cap', type=int, choices=(1, 2), required=True)
ap.add_argument('--port', type=int, required=True)
ap.add_argument('--log', required=True)
ap.add_argument('--fixtures', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fixtures'))
ap.add_argument('--bump-every', type=float, default=0)
ap.add_argument('--ignore-wait', action='store_true')
ap.add_argument('--no-events-feature', action='store_true')
ap.add_argument('--max-seconds', type=float, default=600)
ap.add_argument('--uniqueid', default='', help='answer with this uniqueid (a host the client already knows by id)')
args = ap.parse_args()

fx = args.fixtures
serverinfo = open(os.path.join(fx, f'host-cap{args.cap}-serverinfo.xml'), encoding='utf-8').read()
applist = open(os.path.join(fx, 'host-cap2-applist.xml'), encoding='utf-8').read()
if args.uniqueid:
    serverinfo = re.sub(r'<uniqueid>[^<]*</uniqueid>', f'<uniqueid>{args.uniqueid}</uniqueid>', serverinfo)
if args.no_events_feature:
    serverinfo = serverinfo.replace(',events', '')

cond = threading.Condition()
state = {'seq': int(re.search(r'<FsEventSeq>(\d+)</FsEventSeq>', serverinfo).group(1)) if args.cap == 2 else 0,
         'started': 1794400000}
logfile = open(args.log, 'a', buffering=1)

def log(path, status, waited):
    logfile.write(f'{time.time():.3f} {path} -> {status} {waited:.2f}\n')

def render():
    xml = serverinfo
    if args.cap == 2:
        xml = re.sub(r'<FsEventSeq>\d+</FsEventSeq>', f'<FsEventSeq>{state["seq"]}</FsEventSeq>', xml)
        xml = re.sub(r'<FsSessionStarted>\d+</FsSessionStarted>', f'<FsSessionStarted>{state["started"]}</FsSessionStarted>', xml)
    return xml.encode('utf-8')

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def send(self, body, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/xml; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        began = time.time()
        if url.path == '/serverinfo':
            if args.cap == 2 and 'fsWait' in q and not args.ignore_wait:
                after = int(q['fsWait'][0] or 0)
                limit = min(float(q.get('timeout', ['25'])[0] or 25), 25)
                with cond:
                    cond.wait_for(lambda: state['seq'] > after, timeout=limit)
            self.send(render())
            log(self.path, 200, time.time() - began)
        elif url.path == '/applist':
            self.send(applist.encode('utf-8'))
            log(self.path, 200, time.time() - began)
        else:
            self.send(b'<?xml version="1.0"?><root status_code="404"/>', 404)
            log(self.path, 404, 0)

def bumper():
    while args.bump_every > 0:
        time.sleep(args.bump_every)
        with cond:
            state['seq'] += 1
            state['started'] += 1
            cond.notify_all()

threading.Thread(target=bumper, daemon=True).start()
server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
server.daemon_threads = True
threading.Timer(args.max_seconds, server.shutdown).start()
try:
    server.serve_forever()
finally:
    logfile.close()
