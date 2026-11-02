#!/bin/bash
# Runs inside the locked SDK image. What does the module's generated Lean need in order to build without the SDK?
set -uo pipefail
repo="$PWD"
project="$repo/emit/work-replay"
out="$repo/emit/out/replay"
rm -rf "$project" "$out"
mkdir -p "$project/src" "$out"
cp emit/project/lexlean.toml emit/project/lean-toolchain emit/project/lakefile.toml emit/project/lake-manifest.json emit/project/lexlean.lock "$project/"
cp emit/project/src/Emit.lex.tex "$project/src/"
cd "$project" || exit 1
lexlean build
echo "BUILD exit $?"
find . -name '*.lean' -not -path '*/.lake/*' | tar -cf "$out/lean.tar" -T -
echo "RUNTIME anything named for it, on disk"
find / \( -path '*LexLeanRuntime*' -o -path '*lexlean*runtime*' \) -not -path '/proc/*' -not -path '/sys/*' -not -path "$repo/*" 2> /dev/null | head -30
echo "RUNTIME in this project"
find . -path '*LexLean*' | head -20
echo "RUNTIME what a verify passes to Lean"
strace -f -e trace=execve -s 300 -o "$project/trace.txt" lexlean verify > /dev/null 2>&1
grep -E 'lean|lake' "$project/trace.txt" | head -6 | cut -c1-500
grep -oE 'LEAN_PATH=[^"]*' "$project/trace.txt" | sort -u | head -3
env | grep -iE 'lean|elan' | head
which lean lake elan 2> /dev/null
lean --print-libdir 2> /dev/null
lean_path=$(grep -oE 'LEAN_PATH=[^"]*' "$project/trace.txt" | head -1 | cut -d= -f2-)
for dir in $(echo "$lean_path" | tr ':' ' '); do
  echo "PATHDIR $dir"
  ls "$dir" 2> /dev/null | head -8
done
# Whatever holds it, as source if there is source.
file=$(find / -path '*LexLeanRuntime/Portable.lean' -not -path '/proc/*' -not -path '/sys/*' 2> /dev/null | head -1)
if [ -n "$file" ]; then
  root=$(dirname "$(dirname "$file")")
  echo "SOURCE $file root=$root"
  wc -c "$file"
  ls "$root/LexLeanRuntime" | head -20
  sed -n 1,14p "$file" | cut -c1-120
  grep -E '^(public )?import ' "$root"/LexLeanRuntime/*.lean | head -12
  tar -C "$root" -cf "$out/support.tar" LexLeanRuntime LexLeanRuntime.lean 2> /dev/null || tar -C "$root" -cf "$out/support.tar" LexLeanRuntime
  ls "$root" | grep -iE 'licen|copying|readme' | head
else
  echo "SOURCE none"
fi
ls -la "$out"
exit 0
