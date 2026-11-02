#!/bin/bash
# Runs inside the locked SDK image. Writes the plain Lean of the module and of the runtime it imports, for a machine
# that has official Lean and nothing else.
set -uo pipefail
repo="$PWD"
project="$repo/emit/work-replay"
out="$repo/emit/out/replay"
vendor=/opt/prismpm/share/conformance-root/vendor/lexlean
rm -rf "$project" "$out"
mkdir -p "$project/emit/src" "$out/lean/UorEmit"
cp emit/project/lexlean.toml emit/project/lean-toolchain emit/project/lakefile.toml emit/project/lake-manifest.json emit/project/lexlean.lock "$project/emit/"
cp emit/project/src/Emit.lex.tex "$project/emit/src/"
(cd "$project/emit" && lexlean build)
echo "MODULE build exit $?"
cp "$(find "$project/emit" -name Emit.lean -not -path '*/.lake/*' | head -1)" "$out/lean/UorEmit/Emit.lean"

cp -r "$vendor/language/runtime-1.2/library" "$project/runtime"
cat "$project/runtime/lexlean.toml" | head -14 | cut -c1-110
(cd "$project/runtime" && lexlean lock > /dev/null 2>&1; lexlean build 2>&1 | tail -3 | cut -c1-300)
echo "RUNTIME build exit $?"
find "$project/runtime" -name '*.lean' -not -path '*/.lake/*' | head -12
(cd "$project/runtime" && find . -name '*.lean' -not -path '*/.lake/*' | while read -r file; do
  relative=$(echo "$file" | sed -E 's#.*/modules/##')
  mkdir -p "$out/lean/$(dirname "$relative")"
  cp "$file" "$out/lean/$relative"
done)
find "$out/lean" -name '*.lean' | xargs wc -c
echo "IMPORTS"
find "$out/lean" -name '*.lean' | xargs grep -hE '^(public )?import ' | sort | uniq -c
echo "LICENCE"
ls "$vendor" | head -30
for name in LICENSE LICENSE-MIT LICENSE-APACHE COPYING; do
  [ -f "$vendor/$name" ] && { echo "FOUND $name"; head -4 "$vendor/$name" | cut -c1-90; cp "$vendor/$name" "$out/"; }
done
grep -m3 -iE 'license|repository' "$vendor/Cargo.toml" 2> /dev/null
ls -la "$out"
exit 0
