#!/bin/bash
# One load step: fresh database, server in a 1 CPU / 1750 MB cgroup, load on the other CPUs, the server's cost over the hold.
set -uo pipefail
name="$1"       # floor or control
users="$2"
ramp="$3"
hold="$4"
challenge="$5"
rig="$6"
unit="srv-$name-$users"
cgroup="/sys/fs/cgroup/system.slice/$unit.service"
port=3000
db=/tmp/rig-feed.db
rm -f "$db" "$db"-wal "$db"-shm
cp "$challenge/seed/feed.db" "$db"
base_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
base_sockstat=$(awk '/^TCP:/ {print $11}' /proc/net/sockstat)
if [ "$name" = floor ]; then
  command=("$rig/floor" "$port")
  limit=1048576
elif [ "$name" = ours ]; then
  command=(/bin/bash "$rig/../server/start.sh")
  limit=65535
else
  command=(/bin/bash "$challenge/submissions/c-iouring-pavlyhalim/start.sh")
  limit=65535
fi
# A server from an earlier step can still be shutting down.
for _ in $(seq 1 30); do
  [ -z "$(ss -Hltn "sport = :$port")" ] && break
  sleep 1
done
sudo ss -Hltnp "sport = :$port" | cut -c1-200
# CPU_QUOTA emulates a slower CPU, so a server can reach its limit here before it reaches the memory limit.
quota=()
[ -n "${CPU_QUOTA:-}" ] && quota=(-p "CPUQuota=$CPU_QUOTA" -p CPUQuotaPeriodSec=5ms)
# A transient service, as the organiser's systemd unit runs entries.
sudo systemd-run --unit="$unit" --collect -p AllowedCPUs=0 "${quota[@]}" -p MemoryMax=1750M -p MemorySwapMax=0 -p LimitNOFILE="$limit" -p LimitCORE=infinity \
  -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p StandardOutput="file:/tmp/$unit.log" -p StandardError="file:/tmp/$unit.log" \
  --setenv=SQLITE_PATH="$db" --setenv=JWT_SECRET=twelve-dollar-challenge --setenv=HOST=127.0.0.1 --setenv=PORT="$port" --setenv=SERVER_STATS=1 \
  --uid="$(id -u)" --gid="$(id -g)" "${command[@]}"
for _ in $(seq 1 60); do
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/health" && break
  sleep 1
done
if ! curl -s --max-time 2 "http://127.0.0.1:$port/health" | head -c 200; then
  echo "SERVER did not come up"
fi
echo
if [ ! -f "$cgroup/cpu.stat" ] || ! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/health"; then
  echo "SERVERLOG $unit"
  cat "/tmp/$unit.log"
  sudo systemctl status "$unit.service" --no-pager 2>&1 | head -20
  ls /sys/fs/cgroup/system.slice | grep srv
  find /sys/fs/cgroup -name "$unit*" | head
  sudo journalctl -n 20 --no-pager 2>&1 | cut -c1-200
  sysctl kernel.io_uring_disabled 2>&1
  exit 1
fi
died() {
  echo "SERVER DIED $unit at users=$users ($1)"
  grep -v STATS "/tmp/$unit.log" | tail -12
  grep STATS "/tmp/$unit.log" | tail -4
  awk '$1 ~ /^(anon|file)$/' "$cgroup/memory.stat" 2> /dev/null
  sudo journalctl -u "$unit.service" -n 15 --no-pager 2>&1 | cut -c1-200
  sudo dmesg | grep -iE 'segfault|general protection|out of memory|oom-kill|killed process|tcp: out of' | tail -8 | cut -c1-240
  for core in /tmp/core.*; do
    [ -f "$core" ] || continue
    gdb -q -batch -ex 'bt 12' -ex 'info locals' "$rig/../server/bin/server" "$core" 2>&1 | tail -40 | cut -c1-200
    rm -f "$core"
  done
  grep -E 'WINDOW' "/tmp/load-$unit.log" | tail -4
  pkill -f "$rig/loadgen" 2> /dev/null
  wait "$load" 2> /dev/null
  sudo systemctl stop "$unit.service" 2> /dev/null
  exit 0
}
memory_breakdown() {
  awk '$1 ~ /^(anon|file|kernel|kernel_stack|pagetables|percpu|sock|slab)$/ {printf "%s=%.0fMB ", $1, $2 / 1048576}' "$cgroup/memory.stat"
  echo
}
taskset -c 1-3 "$rig/loadgen" "$port" "$users" "$ramp" "$hold" "$challenge/tokens.txt" > "/tmp/load-$unit.log" 2>&1 &
load=$!
for _ in $(seq 1 "$ramp"); do
  sleep 1
  [ -f "$cgroup/cpu.stat" ] || died "during the ramp"
done
usage_start=$(awk '/usage_usec/ {print $2}' "$cgroup/cpu.stat")
if [ "${PROFILE:-0}" = 1 ] && command -v perf > /dev/null; then
  # All of the server's threads over the middle of the hold.
  pid=$(head -1 "$cgroup/cgroup.procs")
  (sleep 20; sudo perf record -q -F 1999 -g -p "$pid" -o "/tmp/perf-$unit.data" -- sleep 30 > /dev/null 2>&1) &
fi
for _ in $(seq 1 "$hold"); do
  sleep 1
  [ -f "$cgroup/cpu.stat" ] || died "during the hold"
done
echo "MEMORY $(memory_breakdown)"
echo "CPUSTAT $(awk '$1 ~ /^(user_usec|system_usec|nr_periods|nr_throttled|throttled_usec)$/ {printf "%s=%s ", $1, $2}' "$cgroup/cpu.stat")"
usage_end=$(awk '/usage_usec/ {print $2}' "$cgroup/cpu.stat")
peak=$(cat "$cgroup/memory.peak")
current=$(cat "$cgroup/memory.current")
available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
sockstat=$(awk '/^TCP:/ {print $11}' /proc/net/sockstat)
wait "$load"
grep -E 'HOLD|WINDOW' "/tmp/load-$unit.log" | tail -10
grep STATS "/tmp/$unit.log" | tail -4
if [ -f "/tmp/perf-$unit.data" ]; then
  echo "PROFILE $unit"
  sudo perf report -i "/tmp/perf-$unit.data" --stdio --no-children --sort sym -g none --percent-limit 0.7 2> /dev/null | grep -E '^ +[0-9]' | head -45
  sudo perf report -i "/tmp/perf-$unit.data" --stdio --no-children --sort dso -g none 2> /dev/null | grep -E '^ +[0-9]' | head -5
  # What the largest kernel entry is really doing: it is where interrupts come back on.
  sudo perf report -i "/tmp/perf-$unit.data" --stdio --no-children --symbols=_raw_spin_unlock_irqrestore --sort sym -g graph,2,callee --max-stack 12 2> /dev/null | grep -v '^#' | head -70
  echo "PROFILE end"
fi
line=$(grep LOAD "/tmp/load-$unit.log")
echo "$line"
requests=$(echo "$line" | sed -E 's/.* requests=([0-9]+).*/\1/')
cpu_us=$((usage_end - usage_start))
python3 - "$name" "$users" "$hold" "$cpu_us" "${requests:-0}" "$peak" "$current" "$base_available" "$available" "$base_sockstat" "$sockstat" <<'PY'
import sys
name, users, hold, cpu, requests, peak, current, base, now, sock0, sock1 = sys.argv[1:]
users, hold, cpu, requests, peak, current, base, now, sock0, sock1 = map(int, (users, hold, cpu, requests, peak, current, base, now, sock0, sock1))
per = cpu / requests if requests else 0
# Client and server sockets share this kernel, so each connection costs two sockets here.
kb = (base - now) / max(users, 1)
print(f"RESULT server={name} users={users} cpu_pct={100 * cpu / (hold * 1e6):.1f} us_per_request={per:.2f} cgroup_peak_mb={peak / 1048576:.0f} cgroup_now_mb={current / 1048576:.0f} machine_kb_per_connection={kb:.2f} sockstat_mem_pages={sock1 - sock0}")
PY
sudo systemctl stop "$unit.service" 2> /dev/null
sleep 3
