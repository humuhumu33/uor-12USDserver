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
# A transient service, as the organiser's systemd unit runs entries.
sudo systemd-run --unit="$unit" --collect -p AllowedCPUs=0 -p MemoryMax=1750M -p MemorySwapMax=0 -p LimitNOFILE="$limit" \
  -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p StandardOutput="file:/tmp/$unit.log" -p StandardError="file:/tmp/$unit.log" \
  --setenv=SQLITE_PATH="$db" --setenv=JWT_SECRET=twelve-dollar-challenge --setenv=HOST=127.0.0.1 --setenv=PORT="$port" \
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
taskset -c 1-3 "$rig/loadgen" "$port" "$users" "$ramp" "$hold" "$challenge/tokens.txt" > "/tmp/load-$unit.log" 2>&1 &
load=$!
sleep "$ramp"
usage_start=$(awk '/usage_usec/ {print $2}' "$cgroup/cpu.stat")
sleep "$hold"
usage_end=$(awk '/usage_usec/ {print $2}' "$cgroup/cpu.stat")
peak=$(cat "$cgroup/memory.peak")
current=$(cat "$cgroup/memory.current")
available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
sockstat=$(awk '/^TCP:/ {print $11}' /proc/net/sockstat)
wait "$load"
grep -E 'HOLD|WINDOW' "/tmp/load-$unit.log" | tail -6
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
