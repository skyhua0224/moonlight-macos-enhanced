#!/bin/bash
set -u
MAC_HOST=${MAC_HOST:?set MAC_HOST to the ssh name of the Mac}; MAC_ADDR=${MAC_ADDR:?set MAC_ADDR to its address}
D=${EXP_DIR:-${TMPDIR:-/tmp}/net-quiet-exp}; mkdir -p $D; cp "$(dirname "$0")"/udp_frames.py "$(dirname "$0")"/bottleneck.py $D/; scp -q $D/udp_frames.py "$MAC_HOST":/tmp/net-quiet-udp_frames.py
SEC=${SEC:-25}
run() {  # label queue idrspread
  local label=$1 queue=$2 idr=$3
  local RP=$((46000 + RANDOM % 1000)) BP=$((47000 + RANDOM % 1000))
  ssh "$MAC_HOST" "python3 -I /tmp/net-quiet-udp_frames.py recv --port $RP --seconds $SEC" > $D/$label.recv 2>&1 &
  local R=$!; sleep 1.5
  python3 $D/bottleneck.py --listen 127.0.0.1:$BP --to $MAC_ADDR:$RP --rate-mbps 12 --queue-bytes $queue --delay-ms 25 --seconds $SEC > $D/$label.relay 2>&1 &
  local B=$!; sleep 0.5
  python3 $D/udp_frames.py send --host 127.0.0.1 --port $BP --seconds $SEC --fps 100 --data-pkts 9 --parity 0.25 --idr-pkts 90 --idr-every 3 --idr-spread-ms $idr --pace burst > $D/$label.send 2>&1
  wait $B; wait $R
  echo "$label queue=${queue}B idr-spread=${idr}ms | relay $(cat $D/$label.relay) | receiver $(tail -1 $D/$label.recv)"
}
for q in 15000 30000; do
  for idr in 0 40 80 120; do run "q$q-idr$idr" $q $idr; done
done
