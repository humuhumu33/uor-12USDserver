#!/bin/bash
# Runs on a plain runner with official Lean only, under the box's memory. Can the theorems be checked on the box?
set -uo pipefail
input="$(cd "$1" && pwd)"
work="$RUNNER_TEMP/replay"
mkdir -p "$work"
cd "$work" || exit 1
ls -la "$input"
tar -xf "$input/lean.tar"
find . -name '*.lean' | head -20
curl -fsSL --retry 3 -o lean.tar.zst https://github.com/leanprover/lean4/releases/download/v4.32.1/lean-4.32.1-linux.tar.zst || exit 0
sudo apt-get install -y -qq zstd > /dev/null
mkdir -p /tmp/lean && tar --use-compress-program=unzstd -xf lean.tar.zst -C /tmp/lean --strip-components=1
export PATH="/tmp/lean/bin:$PATH"
lean --version
du -sh /tmp/lean
for f in "$input"/*.lean; do
  [ -e "$f" ] && cp "$f" . && echo "SUPPORT $(basename "$f")"
done
[ -f "$input/support.tar" ] && tar -xf "$input/support.tar"
ls "$work"; for lean_file in $(find . -name '*.lean' | grep -v '.lake' | grep -E 'Emit' | head -3); do
  start=$(date +%s)
  sudo systemd-run --scope --quiet -p MemoryMax=1750M -p MemorySwapMax=0 --uid="$(id -u)" --gid="$(id -g)" \
    env PATH="$PATH" LEAN_PATH="$work" lean -o "$work/LexLeanCheck.olean" "$lean_file" > "$work/out.txt" 2>&1
  code=$?
  echo "REPLAY file=$lean_file exit=$code seconds=$(( $(date +%s) - start ))"
  head -c 1500 "$work/out.txt"
  echo
done
exit 0
