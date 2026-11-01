#!/bin/bash
# Runs inside the locked SDK image: can a LexLean root carry server source text, and what does it cost?
set -uo pipefail
size="$1"
chunk="$2"
out="$PWD/feasibility/out"
project=/tmp/emit
python3 feasibility/gen_generator.py "$size" "$chunk" "$project"
cd "$project"
lexlean production targets > targets.json
python3 - > request.json <<'PY'
import json
digest = {t["id"]: t["digest"] for t in json.load(open("targets.json"))["targets"]}["rust-std"]
print(json.dumps({"spec": "lexlean/production-request/1", "roots": [
    {"root": "UorEmit.Emit.emitSource", "package": {"name": "kern_emit", "version": "0.1.0"},
     "targets": [{"id": "rust-std", "digest": digest}]}]}))
PY
lexlean lock > /dev/null
start=$(date +%s)
lexlean check
echo "check exit $? seconds=$(( $(date +%s) - start ))"
start=$(date +%s)
lexlean --diagnostic-format json production build --request request.json > production.json 2> production.err
code=$?
echo "RESULT size=$size chunk=$chunk exit=$code seconds=$(( $(date +%s) - start )) memory_peak_mb=$(( $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0) / 1048576 ))"
python3 - <<'PY'
import json
d = json.load(open("production.json"))
for x in d.get("diagnostics", []):
    print("DIAG", x["code"], x["message"][:900])
print("artifacts", json.dumps(d.get("artifacts"))[:500])
PY
tail -c 600 production.err
[ "$code" = 0 ] || exit 0
pkg=$(find . -type d -name kern_emit | head -1)
echo "package: $pkg"
mkdir -p "$out/pkg"
cp -r "$pkg" "$out/pkg/kern_emit"
lib="$pkg/src/lib.rs"
wc -c "$lib"
grep -n "pub fn run" -A3 "$lib"
grep -n "pub struct Bytes" -A3 "$lib" | head -8
grep -n "pub fn lit\|pub fn as_slice\|impl Bytes" "$lib" | head -8
cat "$pkg/Cargo.toml" | head -20
exit 0
