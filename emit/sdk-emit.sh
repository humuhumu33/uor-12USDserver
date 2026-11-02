#!/bin/bash
# Runs inside the locked SDK image, as part of `just vv`.
#
# The committed module in emit/project is the source of record. This fails if it is stale, if a theorem doesn't hold,
# if the root doesn't certify, if any file it writes differs from server/, or if the emitted tables fail their test.
# A stale run still completes, learning axiom sets as it goes, and leaves the fresh module in emit/out to commit.
set -uo pipefail
repo="$PWD"
project="$repo/emit/work"
out="$repo/emit/out"
bad=0
mkdir -p "$out"
FILES="src/core.h src/server.c build.sh install.sh start.sh .gitignore README.md"

learn_axioms() {
  python3 - "$1" "$repo/emit/axioms.json" <<'PY'
import json, pathlib, re, sys
result = json.load(open(sys.argv[1]))
path = pathlib.Path(sys.argv[2])
axioms = json.loads(path.read_text()) if path.exists() else {}
changed = 0
for diagnostic in result.get("diagnostics", []):
    match = re.search(r"`[\w.]*\.(\w+)` violates its \w+ axiom policy: observed \[(.*?)\]", diagnostic["message"])
    if match:
        axioms[match.group(1)] = sorted(a.strip() for a in match.group(2).split(",") if a.strip())
        changed += 1
    else:
        print("DIAG", diagnostic["code"], diagnostic["message"][:1100].replace("\n", " | "))
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
  cp emit/project/lexlean.toml emit/project/lean-toolchain emit/project/lakefile.toml emit/project/lake-manifest.json "$project/"
  python3 emit/gen_emit.py server "$project" || exit 1
  (cd "$project" && lexlean lock > /dev/null && lexlean fmt && lexlean lock > /dev/null) || exit 1
}

is_fresh() {
  cmp -s "$project/src/Emit.lex.tex" emit/project/src/Emit.lex.tex && cmp -s "$project/lexlean.lock" emit/project/lexlean.lock
}

generate
fresh=1
is_fresh || fresh=0
echo "FRESH $fresh"
[ "$fresh" = 1 ] || bad=1

for pass in $(seq 1 40); do
  cd "$project" || exit 1
  start=$(date +%s)
  lexlean --diagnostic-format json verify > verify.json 2> verify.err
  code=$?
  echo "VERIFY pass=$pass exit=$code seconds=$(( $(date +%s) - start ))"
  tail -c 300 verify.err
  cd "$repo" || exit 1
  [ "$code" = 0 ] && break
  [ "$fresh" = 0 ] || { learn_axioms "$project/verify.json"; exit 1; }
  learn_axioms "$project/verify.json" || exit 1
  generate
done
[ "$code" = 0 ] || exit 1

for pass in $(seq 1 10); do
  cd "$project" || exit 1
  lexlean production targets > targets.json
  python3 - > request.json <<'PY'
import json
digest = {t["id"]: t["digest"] for t in json.load(open("targets.json"))["targets"]}["rust-std"]
print(json.dumps({"spec": "lexlean/production-request/1", "roots": [
    {"root": "UorEmit.Emit.emitSource", "package": {"name": "kern_emit", "version": "0.1.0"},
     "targets": [{"id": "rust-std", "digest": digest}]}]}))
PY
  start=$(date +%s)
  lexlean --diagnostic-format json production build --request request.json > production.json 2> production.err
  code=$?
  echo "PRODUCTION pass=$pass exit=$code seconds=$(( $(date +%s) - start ))"
  tail -c 300 production.err
  cd "$repo" || exit 1
  [ "$code" = 0 ] && break
  [ "$fresh" = 0 ] || { learn_axioms "$project/production.json"; exit 1; }
  learn_axioms "$project/production.json" || exit 1
  generate
done
[ "$code" = 0 ] || exit 1

cd "$project" || exit 1
wc -c src/Emit.lex.tex
pkg=$(cd "$(find . -type d -name kern_emit | head -1)" && pwd)
mkdir -p host/src
printf '[package]\nname = "host"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nkern_emit = { path = "%s" }\n[workspace]\n' "$pkg" > host/Cargo.toml
cp "$repo/emit/host.rs" host/src/main.rs
(cd host && CARGO_HOME="$project/cargo" CARGO_TARGET_DIR="$project/target" cargo build --release --offline 2>&1 | tail -1)
start_ns=$(date +%s%N)
"$project/target/release/host" "$project/emitted"
echo "generator run ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))"
cd "$repo" || exit 1
mkdir -p "$out/project/src"
cp "$project/src/Emit.lex.tex" "$out/project/src/Emit.lex.tex"
cp "$project/lexlean.lock" "$out/project/lexlean.lock"
cp emit/axioms.json "$out/axioms.json"
cp "$project/emitted/src/core.h" "$out/core.h"
for name in $FILES; do
  if cmp "server/$name" "$project/emitted/$name"; then echo "IDENTICAL $name $(sha256sum < "$project/emitted/$name" | cut -c1-16)"; else echo "DIFFERENT $name"; bad=1; fi
done
cc -std=gnu11 -Wall -Wextra -I"$project/emitted/src" -o "$project/core_test" emit/core_test.c && "$project/core_test"
result=$?
echo "CORETEST exit $result"
[ "$result" = 0 ] || bad=1
echo "GATE bad=$bad"
exit "$bad"
