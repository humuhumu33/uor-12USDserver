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
start=$(date +%s)
lexlean build
echo "BUILD exit $? seconds=$(( $(date +%s) - start ))"
find . -name '*.lean' | grep -v '.lake' | xargs wc -c | tail -12
echo "IMPORTS"
find . -name '*.lean' | grep -v '.lake' | xargs grep -h '^import ' | sort | uniq -c | sort -rn | head -20
echo "LEANPATH candidates"
lexlean --version | head -3
for name in LexLeanRuntime LexLeanText LexLeanModels; do
  find / -name "$name.lean" -not -path '/proc/*' -not -path '/sys/*' 2> /dev/null | head -3
  find / -name "$name.olean" -not -path '/proc/*' -not -path '/sys/*' 2> /dev/null | head -3
done
find . -type f \( -name '*.lean' -o -name 'lakefile*' -o -name 'lake-manifest.json' -o -name 'lean-toolchain' \) -not -path '*/.lake/*' | tar -cf "$out/lean.tar" -T -
# Everything the generated Lean imports that isn't Lean's own, as source if it can be found.
for name in LexLeanRuntime LexLeanText LexLeanModels; do
  file=$(find / -name "$name.lean" -not -path '/proc/*' -not -path '/sys/*' 2> /dev/null | head -1)
  if [ -n "$file" ]; then
    echo "SOURCE $name $file"
    cp "$file" "$out/"
    dir=$(dirname "$file")
    ls "$dir" | head -20
    sed -n 1,12p "$file" | cut -c1-120
    [ -d "$dir/$name" ] && tar -C "$dir" -rf "$out/support.tar" "$name"
  fi
done
ls -la "$out"
exit 0
