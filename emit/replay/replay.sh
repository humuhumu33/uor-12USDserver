#!/bin/bash
# Runs on a plain runner with official Lean only, under the box's memory. Can the box itself check the theorems and
# write the server's files, byte for byte?
set -uo pipefail
input="$(cd "$1" && pwd)"
repo="$PWD"
work="$RUNNER_TEMP/replay"
rm -rf "$work"
mkdir -p "$work/LexLeanRuntime" "$work/UorEmit"
# The module imports only Portable, so the other runtime files don't go on the box.
cp "$input/lean/LexLeanRuntime/Portable.lean" "$work/LexLeanRuntime/"
cp "$input/lean/UorEmit/Emit.lean" "$work/UorEmit/"
cd "$work" || exit 1
find . -name '*.lean' | xargs wc -c
curl -fsSL --retry 3 -o /tmp/lean.tar.zst https://github.com/leanprover/lean4/releases/download/v4.32.1/lean-4.32.1-linux.tar.zst || exit 1
sha256sum /tmp/lean.tar.zst
sudo apt-get install -y -qq zstd > /dev/null
mkdir -p /tmp/lean && tar --use-compress-program=unzstd -xf /tmp/lean.tar.zst -C /tmp/lean --strip-components=1
export PATH="/tmp/lean/bin:$PATH"
lean --version
du -sh /tmp/lean
printf 'leanprover/lean4:v4.32.1\n' > lean-toolchain
cat > lakefile.toml <<'TOML'
name = "replay"
defaultTargets = ["UorEmit"]

[[lean_lib]]
name = "LexLeanRuntime"
roots = ["LexLeanRuntime.Portable"]

[[lean_lib]]
name = "UorEmit"
roots = ["UorEmit.Emit"]
TOML
cat > Write.lean <<'LEAN'
import UorEmit.Emit

def main : IO Unit :=
  IO.FS.writeBinFile "archive.bin" (UorEmit.Emit.emitSource ByteArray.empty)
LEAN
limit() { sudo systemd-run --scope --quiet -p AllowedCPUs=0 -p MemoryMax=1750M -p MemorySwapMax=0 --uid="$(id -u)" --gid="$(id -g)" env PATH="$PATH" HOME="$HOME" "$@"; }

start=$(date +%s)
limit /usr/bin/time -v lake build > build.txt 2>&1
code=$?
echo "BUILD exit=$code seconds=$(( $(date +%s) - start )) $(grep 'Maximum resident' build.txt | sed 's/.*: //') kB resident"
grep -vE 'Maximum|Average|Page size|Swaps|File system|Socket|Signals|Voluntary|Involuntary|Exit status|Percent|Major|Minor|Command|Elapsed|System time|User time' build.txt | cut -c1-300 | tail -25
du -sh .lake 2> /dev/null
grep -c 'theorem ' UorEmit/Emit.lean
[ "$code" = 0 ] || exit 0

start=$(date +%s)
limit /usr/bin/time -v lake env lean --run Write.lean > run.txt 2>&1
code=$?
echo "WRITE exit=$code seconds=$(( $(date +%s) - start )) $(grep 'Maximum resident' run.txt | sed 's/.*: //') kB resident"
[ "$code" = 0 ] || { head -c 1500 run.txt; exit 0; }
wc -c archive.bin
python3 - "$repo/server" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
data = pathlib.Path("archive.bin").read_bytes()
bad = 0
for entry in data.split(b"\0"):
    if not entry:
        continue
    name, _, content = entry.partition(b"\n")
    same = (root / name.decode()).read_bytes() == content
    print("IDENTICAL" if same else "DIFFERENT", name.decode())
    bad |= not same
print("REPLAY bad=%d" % bad)
PY
exit 0
