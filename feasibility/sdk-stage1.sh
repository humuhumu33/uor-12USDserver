#!/bin/bash
# Runs inside the locked SDK image: build the kernel model and export its production roots.
set -uo pipefail
cd feasibility/kernels
out=../out
lexlean --version | head -1
lexlean production targets > "$out/targets.json"
echo "### lock, fmt, check"
lexlean lock
lexlean fmt
echo "fmt exit $?"
lexlean check || { echo "check failed"; exit 0; }
echo "### export"
python3 - "$out/targets.json" > request.json <<'PY'
import json, sys
digests = {t["id"]: t["digest"] for t in json.load(open(sys.argv[1]))["targets"]}
roots = [("needsEscape", "kern_escape", "rust-core"), ("postJson", "kern_post_json", "rust-std"),
         ("routeBytes", "kern_route_bytes", "rust-std"), ("routeWords", "kern_route_words", "rust-core"),
         ("shaRound", "kern_sha_round", "rust-core"), ("stepCode", "kern_step", "rust-core")]
print(json.dumps({"spec": "lexlean/production-request/1", "roots": [
    {"root": "UorKernels.Kernels." + r, "package": {"name": p, "version": "0.1.0"},
     "targets": [{"id": t, "digest": digests[t]}]} for r, p, t in roots]}))
PY
start=$(date +%s)
lexlean --diagnostic-format json production build --request request.json > "$out/production.json" 2> "$out/production.err"
code=$?
echo "production build exit $code in $(( $(date +%s) - start )) s"
head -c 1800 "$out/production.json"
echo
tail -c 2500 "$out/production.err"
[ "$code" = 0 ] || exit 0
bundle=$(python3 -c "
import json,sys
d=json.load(open('$out/production.json'))
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if 'bundle' in k and isinstance(v,str): print(v); sys.exit()
            walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d)
")
echo "bundle: $bundle"
cp -r "$bundle" "$out/bundle" || find . -name lib.rs | head
find "$out/bundle" -maxdepth 4 | head -40
for f in $(find "$out/bundle" -name lib.rs); do
  echo "=== $f ($(wc -l < "$f") lines)"
  grep -n "pub fn run" -A3 "$f"
done
f=$(find "$out/bundle" -path '*kern_step*' -name lib.rs | head -1)
[ -n "$f" ] && { echo "=== tail of step"; tail -70 "$f"; }
