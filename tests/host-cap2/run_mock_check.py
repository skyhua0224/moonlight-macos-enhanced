#!/usr/bin/env python3
"""Proves the stand-in host itself behaves like the capability it claims, with a plain HTTP client (no app).
usage: run_mock_check.py   (picks free ports, starts the mock twice, stops it)"""
import os, subprocess, sys, tempfile, time, urllib.request, socket, re

here = os.path.dirname(os.path.abspath(__file__))
fails = 0
def check(name, ok, detail=''):
    global fails
    if not ok: fails += 1
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else ' — ' + str(detail)))

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def get(port, path, timeout=40):
    t = time.time()
    body = urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=timeout).read().decode('utf-8')
    return body, time.time() - t

def start(*extra):
    port = free_port(); log = tempfile.mktemp(suffix='.log')
    p = subprocess.Popen([sys.executable, '-I', os.path.join(here, 'mock_host.py'), '--port', str(port), '--log', log, '--max-seconds', '60', *extra])
    for _ in range(50):
        try: socket.create_connection(('127.0.0.1', port), 0.2).close(); break
        except OSError: time.sleep(0.1)
    return p, port, log

p, port, log = start('--cap', '2', '--bump-every', '3')
try:
    body, dt = get(port, '/serverinfo?uniqueid=x')
    seq = int(re.search(r'<FsEventSeq>(\d+)', body).group(1))
    check('cap2: plain serverinfo answers at once with FsCapabilityVersion 2 and the events feature', dt < 1 and '<FsCapabilityVersion>2<' in body and 'events' in body)
    body, dt = get(port, f'/serverinfo?uniqueid=x&fsWait={seq}&timeout=25')
    seq2 = int(re.search(r'<FsEventSeq>(\d+)', body).group(1))
    check('cap2: fsWait holds the request until the counter moves', 1 < dt < 6 and seq2 > seq, (dt, seq, seq2))
    body, dt = get(port, f'/serverinfo?uniqueid=x&fsWait={seq2 - 1}&timeout=25')
    check('cap2: fsWait behind the counter answers at once', dt < 1)
    body, _ = get(port, '/applist?uniqueid=x')
    check('cap2: applist carries FsSession and FsLaunchMode', '<FsSession>' in body and '<FsLaunchMode>' in body)
finally:
    p.terminate(); p.wait()

p, port, log = start('--cap', '2', '--ignore-wait')
try:
    body, dt = get(port, '/serverinfo?uniqueid=x&fsWait=99&timeout=25')
    check('cap2 --ignore-wait: answers a fsWait request at once', dt < 1)
finally:
    p.terminate(); p.wait()

p, port, log = start('--cap', '1')
try:
    body, dt = get(port, '/serverinfo?uniqueid=x&fsWait=0&timeout=25')
    check('cap1: answers at once, FsCapabilityVersion 1, no event counter', dt < 1 and '<FsCapabilityVersion>1<' in body and 'FsEventSeq' not in body)
finally:
    p.terminate(); p.wait()
print('ALL PASS' if fails == 0 else f'{fails} FAILED')
sys.exit(1 if fails else 0)
