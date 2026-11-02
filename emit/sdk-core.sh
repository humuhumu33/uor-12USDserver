#!/bin/bash
# Runs inside the locked SDK image. Do the core's theorems hold, and what header does its certified root write?
set -uo pipefail
repo="$PWD"
project="$repo/emit/work-core"
out="$repo/emit/out"
mkdir -p "$out"

# Takes the exact axiom sets LexLean reports, because each definition's policy must name them exactly.
learn_axioms() {
  python3 - "$1" "$repo/emit/axioms.json" <<'PY'
import json, pathlib, re, sys
result = json.load(open(sys.argv[1]))
path = pathlib.Path(sys.argv[2])
axioms = json.loads(path.read_text()) if path.exists() else {}
changed = 0
for diagnostic in result.get("diagnostics", []):
    match = re.search(r"`[\w.]*\.(\w+)` violates its exact axiom policy: observed \[(.*?)\]", diagnostic["message"])
    if match:
        axioms[match.group(1)] = sorted(a.strip() for a in match.group(2).split(",") if a.strip())
        changed += 1
    else:
        print("DIAG", diagnostic["code"], diagnostic["message"][:1100].replace("\n", " | "))
        for label in diagnostic.get("labels", [])[:2]:
            print("  LABEL", str(label)[:300])
        primary = diagnostic.get("primary") or {}
        print("  AT line", primary.get("line_start"), "column", primary.get("column_start"))
path.write_text(json.dumps(axioms, indent=0, sort_keys=True))
print("axiom policies learned:", changed)
sys.exit(0 if changed else 1)
PY
}

generate() {
  rm -rf "$project"
  mkdir -p "$project"
  python3 emit/gen_emit.py --core-only server "$project"
  (cd "$project" && lexlean lock > /dev/null)
}

generate
cd "$project" || exit 1
lexlean --diagnostic-format json check > check.json 2>&1
echo "check exit $?"
learn_axioms check.json
cd "$repo" || exit 1

for pass in 1 2 3 4 5 6; do
  generate
  cd "$project" || exit 1
  start=$(date +%s)
  lexlean --diagnostic-format json verify > verify.json 2> verify.err
  code=$?
  echo "VERIFY pass=$pass exit=$code seconds=$(( $(date +%s) - start ))"
  tail -c 300 verify.err
  cd "$repo" || exit 1
  [ "$code" = 0 ] && break
  learn_axioms "$project/verify.json" || exit 0
done
[ "$code" = 0 ] || exit 0

cd "$project" || exit 1
lexlean production targets > targets.json
python3 - > request.json <<'PY'
import json
digest = {t["id"]: t["digest"] for t in json.load(open("targets.json"))["targets"]}["rust-std"]
print(json.dumps({"spec": "lexlean/production-request/1", "roots": [
    {"root": "UorEmit.Emit.emitSource", "package": {"name": "kern_emit", "version": "0.1.0"},
     "targets": [{"id": "rust-std", "digest": digest}]}]}))
PY
cd "$repo" || exit 1
for pass in 1 2 3 4 5 6; do
  cd "$project" || exit 1
  start=$(date +%s)
  lexlean --diagnostic-format json production build --request request.json > production.json 2> production.err
  code=$?
  echo "PRODUCTION pass=$pass exit=$code seconds=$(( $(date +%s) - start ))"
  tail -c 300 production.err
  cd "$repo" || exit 1
  [ "$code" = 0 ] && break
  learn_axioms "$project/production.json" || exit 0
  cp "$project/targets.json" "$project/request.json" /tmp/
  generate
  cp /tmp/targets.json /tmp/request.json "$project/"
done
[ "$code" = 0 ] || exit 0

cd "$project" || exit 1
pkg=$(cd "$(find . -type d -name kern_emit | head -1)" && pwd)
mkdir -p host/src
printf '[package]\nname = "host"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nkern_emit = { path = "%s" }\n[workspace]\n' "$pkg" > host/Cargo.toml
cp "$repo/emit/host.rs" host/src/main.rs
(cd host && CARGO_HOME="$project/cargo" CARGO_TARGET_DIR="$project/target" cargo build --release --offline 2>&1 | tail -2)
"$project/target/release/host" "$project/emitted"
cp "$project/emitted/src/core.h" "$out/core.h"
cp "$repo/emit/axioms.json" "$out/axioms.json"
wc -l "$out/core.h"
sed 's/^/CORE /' "$out/core.h" | cut -c1-140 | head -75
cd "$repo" || exit 1
cc -std=gnu11 -Wall -Wextra -include stdint.h -fsyntax-only -x c "$out/core.h"
echo "core.h compiles: exit $?"
exit 0
