#!/bin/bash
# Runs on a Linux host: sender -> userspace bottleneck (this host) -> receiver on the Mac (MAC_HOST, reached at MAC_ADDR).
set -u
MAC_HOST=${MAC_HOST:?set MAC_HOST to the ssh name of the Mac}; MAC_ADDR=${MAC_ADDR:?set MAC_ADDR to its address}
D=${EXP_DIR:-${TMPDIR:-/tmp}/net-quiet-exp}; mkdir -p $D
cp "$(dirname "$0")"/udp_frames.py "$(dirname "$0")"/bottleneck.py $D/
scp -q $D/udp_frames.py "$MAC_HOST":/tmp/net-quiet-udp_frames.py
SEC=${SEC:-30}
run() {  # label rate queue pace jitter loss
  local label=$1 rate=$2 queue=$3 pace=$4 jit=$5 loss=$6
  local RP=$((46000 + RANDOM % 1000)) BP=$((47000 + RANDOM % 1000))
  ssh "$MAC_HOST" "python3 -I /tmp/net-quiet-udp_frames.py recv --port $RP --seconds $SEC --out /tmp/net-quiet-$label.json" > $D/$label.recv 2>&1 &
  local R=$!
  sleep 1.5
  python3 $D/bottleneck.py --listen 127.0.0.1:$BP --to $MAC_ADDR:$RP --rate-mbps $rate --queue-bytes $queue --delay-ms 25 --jitter-ms $jit --loss $loss --seconds $SEC > $D/$label.relay 2>&1 &
  local B=$!
  sleep 0.5
  python3 $D/udp_frames.py send --host 127.0.0.1 --port $BP --seconds $SEC --fps 100 --data-pkts 9 --parity 0.25 --idr-pkts 90 --idr-every 3 --pace "$pace" > $D/$label.send 2>&1
  wait $B; wait $R
  echo "$label rate=${rate}Mbit queue=${queue}B pace=$pace jitter=${jit}ms loss=$loss | sender $(cat $D/$label.send) | relay $(cat $D/$label.relay) | receiver $(tail -1 $D/$label.recv)"
}
for q in 15000 30000 60000; do
  run "q$q-burst"   12 $q burst 0 0
  run "q$q-spread4" 12 $q spread:4 0 0
  run "q$q-spread8" 12 $q spread:8 0 0
done
run "jitter-burst"   12 30000 burst 8 0
run "jitter-spread8" 12 30000 spread:8 8 0
