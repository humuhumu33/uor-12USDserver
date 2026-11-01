#!/bin/bash
# Runs inside the locked SDK image: export one production root, so each root's certificate cost and verdict are its own.
set -uo pipefail
cd feasibility/kernels
out=../out
lexlean --version | head -1
lexlean production targets > "$out/targets.json"
ROOT="$1" PKG="$2" TARGET="$3" python3 - "$out/targets.json" > request.json <<'PY'
import json, os, sys
digests = {t["id"]: t["digest"] for t in json.load(open(sys.argv[1]))["targets"]}
print(json.dumps({"spec": "lexlean/production-request/1", "roots": [
    {"root": "UorKernels.Kernels." + os.environ["ROOT"], "package": {"name": os.environ["PKG"], "version": "0.1.0"},
     "targets": [{"id": os.environ["TARGET"], "digest": digests[os.environ["TARGET"]]}]}]}))
PY
# LexLean certifies every production root the project declares, so keep only the root under test.
ROOT="$1" python3 - <<'PY2'
import os, re
path = "src/Kernels.lex.tex"
source = open(path).read()
blocks = re.split(r"(?=\ndefinition\{)", source)
kept = []
for block in blocks:
    name = re.search(r"name: (\w+),", block)
    if name and name.group(1) != os.environ["ROOT"]:
        block = re.sub(r",\n\s*production: \{[^}]*\}", "", block)
    kept.append(block)
open(path, "w", newline="\n").write("".join(kept))
PY2
grep -c "production:" src/Kernels.lex.tex
lexlean lock > /dev/null
lexlean check || exit 0
start=$(date +%s)
lexlean --diagnostic-format json production build --request request.json > "$out/production.json" 2> "$out/production.err"
code=$?
echo "RESULT root=$1 target=$3 exit=$code seconds=$(( $(date +%s) - start )) memory_peak_mb=$(( $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0) / 1048576 ))"
python3 - "$out/production.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d.get("diagnostics", []):
    print("DIAG", x["code"], x["message"][:900])
print("keys", sorted(d.keys()), "artifacts", json.dumps(d.get("artifacts"))[:600])
PY
tail -c 800 "$out/production.err"
[ "$code" = 0 ] || exit 0
find . -name lib.rs -newer request.json | head -5
pkg_dir=$(find . -type d -name "$2" | head -1)
echo "package dir: $pkg_dir"
mkdir -p "$out/pkg"
cp -r "$pkg_dir" "$out/pkg/$2"
f="$out/pkg/$2/src/lib.rs"
echo "=== $f ($(wc -l < "$f") lines)"
grep -n "pub fn run" -A3 "$f"
tail -45 "$f"
exit 0
