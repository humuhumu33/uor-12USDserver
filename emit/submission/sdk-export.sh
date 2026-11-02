#!/bin/bash
# Runs inside the locked SDK image. Writes the folder a pull request would add: the readable C and the core's LexLean to
# review, the plain Lean of the module and of the one runtime file it imports, and the scripts. The box checks that Lean,
# runs it, and stops if what it writes differs from the C here.
set -euo pipefail
repo="$PWD"
project="$repo/emit/work-export"
out="$repo/emit/out/submission"
vendor=/opt/prismpm/share/conformance-root/vendor/lexlean
rm -rf "$project" "$out"
mkdir -p "$project/module/src" "$out/lean/UorEmit" "$out/lean/LexLeanRuntime"

cp emit/project/lexlean.toml emit/project/lean-toolchain emit/project/lakefile.toml emit/project/lake-manifest.json emit/project/lexlean.lock "$project/module/"
cp emit/project/src/Emit.lex.tex "$project/module/src/"
(cd "$project/module" && lexlean build > /dev/null)
cp "$(find "$project/module" -name Emit.lean -not -path '*/.lake/*' | head -1)" "$out/lean/UorEmit/Emit.lean"

cp -r "$vendor/language/runtime-1.2/library" "$project/runtime"
chmod -R u+w "$project/runtime"
(cd "$project/runtime" && lexlean lock > /dev/null && lexlean build > /dev/null)
cp "$(find "$project/runtime" -name Portable.lean -not -path '*/.lake/*' | head -1)" "$out/lean/LexLeanRuntime/Portable.lean"
cp "$vendor/LICENSE-MIT" "$out/lean/LexLeanRuntime/LICENSE-MIT"
cp "$vendor/LICENSE-APACHE" "$out/lean/LexLeanRuntime/LICENSE-APACHE"
chmod -R u+w "$out"

cp emit/submission/lakefile.toml emit/submission/Write.lean emit/submission/Claims.lean "$out/lean/"
cp emit/core.lex "$out/core.lex"
cp -r server/src "$out/src"
cp emit/project/lean-toolchain "$out/lean/lean-toolchain"
cp server/build.sh server/install.sh server/start.sh server/.gitignore server/README.md "$out/"
find "$out" -type f | sed "s#$out/##" | xargs -I{} wc -c "$out/{}" | sed "s#$out/##"
