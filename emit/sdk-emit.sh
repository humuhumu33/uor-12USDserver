#!/bin/bash
# Runs inside the locked SDK image. Can a LexLean root carry the real server, byte for byte, and what does it cost?
set -uo pipefail
repo="$PWD"
project="$repo/emit/work"
rm -rf "$project"
mkdir -p "$project"

# Can source stay readable beside the literals? Each probe is a tiny module, and only its diagnostics matter.
probe() {
  local name="$1" middle="$2" dir="$project/probe-$1"
  mkdir -p "$dir/src"
  cp -r "$repo/feasibility/kernels/lexlean.toml" "$repo/feasibility/kernels/lean-toolchain" "$dir/"
  printf 'name = "uor_emit_host"\nversion = "0.1.0"\n' > "$dir/lakefile.toml"
  printf '{"version": "1.2.0",\n "packagesDir": ".lake/packages",\n "packages": [],\n "name": "uor_emit_host",\n "lakeDir": ".lake",\n "fixedToolchain": false}\n' > "$dir/lake-manifest.json"
  sed -i 's/src\/Kernels.lex.tex/src\/Probe.lex.tex/; s/UorKernels/UorProbe/; s/uor-kernels/uor-probe/' "$dir/lexlean.toml"
  printf '\\begin{lexlean}{Probe}\n\\useglossary{lexlean.std.nat@1.2.0}\n\\title{Natural number addition}\n%b\n\\end{lexlean}\n' "$middle" > "$dir/src/Probe.lex.tex"
  (cd "$dir" && lexlean lock > /dev/null 2>&1; lexlean --diagnostic-format json check > out.txt 2>&1; echo "PROBE $name exit=$?"; head -c 700 out.txt; echo)
}
one='definition{\n  name: one,\n  parameters: [seed : Bytes],\n  result: Bytes,\n  body: (prim append seed 0x41 : Bytes),\n  executable: true\n}'
two='definition{\n  name: two,\n  parameters: [seed : Bytes],\n  result: Bytes,\n  body: (one seed),\n  executable: true\n}'
probe control "\\\\begin{semanticmodule}\n$one\n\\\\end{semanticmodule}"
probe two_modules "\\\\begin{semanticmodule}\n$one\n\\\\end{semanticmodule}\n\\\\begin{semanticmodule}\n$two\n\\\\end{semanticmodule}"
probe prose_between "\\\\begin{semanticmodule}\n$one\n\\\\end{semanticmodule}\nSome prose.\n\\\\begin{verbatim}\nint main(void) { return 42; }\n\\\\end{verbatim}\n\\\\begin{semanticmodule}\n$two\n\\\\end{semanticmodule}"
probe verbatim_before "Some prose.\n\\\\begin{verbatim}\nint main(void) { return 42; }\n\\\\end{verbatim}\n\\\\begin{semanticmodule}\n$one\n\\\\end{semanticmodule}"
probe comment_inside "\\\\begin{semanticmodule}\n%% int main(void) { return 42; }\n$one\n\\\\end{semanticmodule}"
probe text_literal "\\\\begin{semanticmodule}\ndefinition{\n  name: one,\n  parameters: [seed : Bytes],\n  result: Bytes,\n  body: (prim append seed \"abc\" : Bytes),\n  executable: true\n}\n\\\\end{semanticmodule}"

# The real server through the whole chain.
python3 emit/gen_emit.py server "$project/emit"
cd "$project/emit" || exit 1
wc -c src/Emit.lex.tex
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
echo "RESULT exit=$code seconds=$(( $(date +%s) - start )) memory_peak_mb=$(( $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0) / 1048576 ))"
python3 - <<'PY'
import json
d = json.load(open("production.json"))
for x in d.get("diagnostics", []):
    print("DIAG", x["code"], x["message"][:900])
print("artifacts", json.dumps(d.get("artifacts"))[:500])
PY
tail -c 600 production.err
[ "$code" = 0 ] || exit 0
pkg=$(cd "$(find . -type d -name kern_emit | head -1)" && pwd)
wc -c "$pkg/src/lib.rs"
mkdir -p host/src
printf '[package]\nname = "host"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nkern_emit = { path = "%s" }\n[workspace]\n' "$pkg" > host/Cargo.toml
cat > host/src/main.rs <<'RS'
// Writes each file of the archive the certified root returns. This and the shell around it are not LexLean: it has no I/O.
fn main() {
    let archive = kern_emit::run(kern_emit::Bytes::lit(b""));
    let out = std::path::PathBuf::from(std::env::args().nth(1).unwrap());
    let mut rest: &[u8] = archive.octets();
    while !rest.is_empty() {
        let at = rest.iter().position(|b| *b == b'\n').unwrap();
        let name = std::str::from_utf8(&rest[..at]).unwrap().to_string();
        rest = &rest[at + 1..];
        let at = rest.iter().position(|b| *b == b'\n').unwrap();
        let length: usize = std::str::from_utf8(&rest[..at]).unwrap().parse().unwrap();
        rest = &rest[at + 1..];
        let path = out.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, &rest[..length]).unwrap();
        rest = &rest[length..];
    }
}
RS
start=$(date +%s)
(cd host && CARGO_HOME="$project/cargo" CARGO_TARGET_DIR="$project/target" cargo build --release --offline 2>&1 | tail -2)
echo "generator compile seconds=$(( $(date +%s) - start ))"
start_ns=$(date +%s%N)
"$project/target/release/host" "$project/emitted"
echo "generator run ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))"
cd "$repo" || exit 1
for name in src/server.c build.sh install.sh start.sh .gitignore README.md; do
  if cmp "server/$name" "$project/emitted/$name"; then echo "IDENTICAL $name $(sha256sum < "$project/emitted/$name" | cut -c1-16)"; else echo "DIFFERENT $name"; fi
done
exit 0
