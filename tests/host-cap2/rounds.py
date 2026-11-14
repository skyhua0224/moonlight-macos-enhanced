#!/usr/bin/env python3
"""usage: rounds.py <mock log> — the times (seconds after the first request) at which a new round of requests begins
(a gap of more than 5 s ends a round), and how many plain serverinfo requests each had."""
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
t = [float(r[0]) for r in rows]
plain = ['fsWait=' not in r[1] and r[1].startswith('/serverinfo') for r in rows]
out, n = [], 0
for i, x in enumerate(t):
    if i and x - t[i - 1] > 5:
        out.append((round(start - t[0]), n)); n = 0
    if i == 0 or x - t[i - 1] > 5: start = x
    n += 1 if plain[i] else 0
out.append((round(start - t[0]), n))
print(' '.join(f'+{s}s:{c}' for s, c in out))
