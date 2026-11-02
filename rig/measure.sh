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
elif [[ "$name" == v-* ]]; then
  command=(/bin/bash "/tmp/variants/$name/start.sh")
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
# A snapshot at the end misses what a spike was made of, so the cgroup's memory is kept second by second.
samples="/tmp/memory-$unit.log"
rm -f "$samples"
sample_memory() {
  awk -v current="$(cat "$cgroup/memory.current" 2> /dev/null)" '$1 ~ /^(anon|file|sock|slab)$/ {printf "%s=%.0f ", $1, $2 / 1048576} END {printf "total=%.0f\n", current / 1048576}' "$cgroup/memory.stat" >> "$samples" 2> /dev/null
}
# When socket memory jumps, says whose bytes they are: requests the server hasn't read, responses the client hasn't
# acknowledged, or responses the load generator hasn't read. Also how much CPU the load generator is getting.
last_load_ticks=0
split_sockets() {
  local sock ticks
  sock=$(awk '$1 == "sock" {printf "%d", $2 / 1048576}' "$cgroup/memory.stat" 2> /dev/null)
  ticks=$(awk '{print $14 + $15}' "/proc/$load/stat" 2> /dev/null)
  if [ "${sock:-0}" -gt 40 ]; then
    ss -Htn 2> /dev/null | awk -v port=":$port" -v sock="$sock" -v load_cpu="$((${ticks:-0} - last_load_ticks))" '
      { states[$1]++; if ($4 ~ port "$") { server_recv += $2; server_send += $3 } else if ($5 ~ port "$") { client_recv += $2; client_send += $3 } }
      END { printf "SOCKETS sock=%d server_unread_mb=%.0f server_unacked_mb=%.0f client_unread_mb=%.0f client_unacked_mb=%.0f load_ticks=%d", sock, server_recv / 1048576, server_send / 1048576, client_recv / 1048576, client_send / 1048576, load_cpu; for (k in states) printf " %s=%d", k, states[k]; printf "\n" }'
    awk '/^TCP:/ {printf "SOCKSTAT %s\n", $0}' /proc/net/sockstat
    # What the server's threads are doing in the kernel while the bytes pile up, for the first few jumps of a run.
    if [ "${thread_dumps:-0}" -lt 4 ]; then
      thread_dumps=$((${thread_dumps:-0} + 1))
      echo "PRESSURE memory=$(sed -n 1p /proc/pressure/memory) io=$(sed -n 1p /proc/pressure/io) cpu=$(sed -n 1p /proc/pressure/cpu)"
      for task in /proc/"$(head -1 "$cgroup/cgroup.procs" 2> /dev/null)"/task/*; do
        echo "THREAD $(basename "$task") state=$(awk '{print $3}' "$task/stat" 2> /dev/null) wchan=$(sudo cat "$task/wchan" 2> /dev/null) stack=$(sudo cat "$task/stack" 2> /dev/null | head -8 | awk '{print $2}' | tr '\n' ' ')"
      done
    fi
  fi
  last_load_ticks=${ticks:-0}
}
memory_peaks() {
  awk '{for (i = 1; i <= NF; i++) {split($i, kv, "="); if (kv[2] + 0 > most[kv[1]]) most[kv[1]] = kv[2] + 0}} END {printf "PEAKS"; for (k in most) printf " %s=%d", k, most[k]; printf "\n"}' "$samples" 2> /dev/null
}
died() {
  echo "SERVER DIED $unit at users=$users ($1)"
  memory_peaks
  tail -6 "$samples" 2> /dev/null | sed 's/^/LAST /'
  grep -v STATS "/tmp/$unit.log" | tail -12
  grep STATS "/tmp/$unit.log" | tail -12
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
  sample_memory
  split_sockets
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
  sample_memory
  split_sockets
done
echo "MEMORY $(memory_breakdown)"
memory_peaks
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
