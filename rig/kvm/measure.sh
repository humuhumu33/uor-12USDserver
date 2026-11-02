#!/bin/bash
# One load step against an entry in the guest: fresh database, the service as the organiser's unit runs it, on port 80.
#   measure.sh WORK_DIR ENTRY USERS RAMP HOLD LOADGEN TOKENS
set -uo pipefail
work="$1"; entry="$2"; users="$3"; ramp="$4"; hold="$5"; loadgen="$6"; tokens="$7"
GUEST=10.77.0.2
SSH=(ssh -i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "deploy@$GUEST")
unit="srv-$entry-$users"
cgroup="/sys/fs/cgroup/system.slice/$unit.service"

"${SSH[@]}" "rm -f feed-run.db*; cp feed.db feed-run.db; sudo sysctl -q -w vm.drop_caches=3; sudo systemd-run --quiet --unit=$unit --collect \
  -p LimitNOFILE=65535 -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p StandardOutput=file:/tmp/$unit.log -p StandardError=file:/tmp/$unit.log \
  --uid=deploy --gid=deploy --setenv=SQLITE_PATH=\$HOME/feed-run.db --setenv=JWT_SECRET=twelve-dollar-challenge --setenv=HOST=0.0.0.0 --setenv=PORT=80 \
  /bin/bash \$HOME/entries/$entry/start.sh"
for _ in $(seq 1 60); do
  curl -s -o /dev/null --max-time 2 "http://$GUEST/health" && break
  sleep 1
done
curl -s --max-time 2 "http://$GUEST/health" | head -c 120
echo

# The guest keeps its own memory record, since it has to be read back after any failure.
"${SSH[@]}" "nohup sh -c 'while sleep 2; do
  echo \"\$(date +%s) avail_mb=\$(awk \"/MemAvailable/ {print int(\\\$2/1024)}\" /proc/meminfo) tcp_mem_pages=\$(awk \"/^TCP:/ {print \\\$NF}\" /proc/net/sockstat) service_mb=\$(( \$(cat $cgroup/memory.current 2>/dev/null || echo 0) / 1048576 )) active=\$(systemctl is-active $unit)\"
done' > /tmp/samples-$unit.log 2>&1 < /dev/null &"

LOAD_TARGET="$GUEST" LOAD_SOURCE=10.77.1.0 taskset -c 2,3 "$loadgen" 80 "$users" "$ramp" "$hold" "$tokens" > "$work/load-$unit.log" 2>&1 &
load=$!
sleep "$ramp"
start=$("${SSH[@]}" "awk '/usage_usec/ {print \$2}' $cgroup/cpu.stat" 2> /dev/null)
load_start=$(awk '{print $14 + $15}' "/proc/$load/stat" 2> /dev/null)
sleep "$hold"
stop=$("${SSH[@]}" "awk '/usage_usec/ {print \$2}' $cgroup/cpu.stat" 2> /dev/null)
load_stop=$(awk '{print $14 + $15}' "/proc/$load/stat" 2> /dev/null)
peak=$("${SSH[@]}" "cat $cgroup/memory.peak" 2> /dev/null)
wait "$load"

line=$(grep LOAD "$work/load-$unit.log" | tail -1)
echo "$line"
grep -E 'WINDOW' "$work/load-$unit.log" | tail -4 | cut -c1-140
requests=$(echo "$line" | sed -E 's/.* requests=([0-9]+).*/\1/')
"${SSH[@]}" "grep STATS /tmp/$unit.log | tail -2 | cut -c1-300; sudo dmesg | grep -iE 'out of memory|oom-kill|tcp: out of|tcp: too many' | tail -4 | cut -c1-160; systemctl is-active $unit || true; awk 'BEGIN {low=99999; t=0} {split(\$2,a,\"=\"); if (a[2]+0<low) low=a[2]+0; split(\$3,b,\"=\"); if (b[2]+0>t) t=b[2]+0} END {print \"GUEST lowest_avail_mb=\" low \" most_tcp_mem_pages=\" t}' /tmp/samples-$unit.log; pkill -f 'while sleep 2' || true"
python3 - "$entry" "$users" "$hold" "${start:-0}" "${stop:-0}" "${requests:-0}" "${peak:-0}" "${load_start:-0}" "${load_stop:-0}" <<'PY'
import sys
entry, users, hold, start, stop, requests, peak, load_start, load_stop = sys.argv[1:]
hold, start, stop, requests, peak, load_start, load_stop = map(int, (hold, start, stop, requests, peak, load_start, load_stop))
cpu = stop - start
print(f"RESULT server={entry} users={users} cpu_pct={100 * cpu / (hold * 1e6):.1f} us_per_request={(cpu / requests) if requests else 0:.2f} service_peak_mb={peak / 1048576:.0f} load_generator_cpu_pct={(load_stop - load_start) / hold:.0f}")
PY
"${SSH[@]}" "sudo systemctl stop $unit 2> /dev/null; sudo sysctl -q -w vm.drop_caches=3; sleep 2"
sleep 3
