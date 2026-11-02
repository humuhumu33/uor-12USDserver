#!/bin/bash
# Runs where install.sh has run. The box's build is evidence only if it can fail: each defect goes into a copy of the
# submitted folder, and build.sh must stop on it, using official Lean alone. An untouched copy must build, or a failure
# below could be for some other reason.
set -uo pipefail
folder="$(cd "$1" && pwd)"
work="$RUNNER_TEMP/plant"
escaped=0

fresh() {
  rm -rf "$work"
  cp -r "$folder" "$work"
}

plant() {
  local name="$1" edit="$2"
  fresh
  (cd "$work" && python3 -c "$edit") || { echo "PLANT $name could not be planted"; escaped=1; return; }
  (cd "$work" && PGO=0 bash build.sh) > "$RUNNER_TEMP/plant.log" 2>&1
  local code=$?
  echo "PLANT $name exit=$code"
  grep -E 'error|sorry|differ|warning|rests on' "$RUNNER_TEMP/plant.log" | cut -c1-260 | head -4 | sed 's/^/  SAW /'
  [ "$code" != 0 ] || { echo "PLANT $name ESCAPED"; escaped=1; }
}

fresh
start=$(date +%s)
(cd "$work" && PGO=0 bash build.sh) > "$RUNNER_TEMP/plant.log" 2>&1
code=$?
echo "UNTOUCHED exit=$code seconds=$(( $(date +%s) - start ))"
tail -3 "$RUNNER_TEMP/plant.log" | cut -c1-200
[ "$code" = 0 ] || escaped=1

plant false_theorem "
import pathlib
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
old = 'match copied with | Flag.yes => Flag.no'
assert s.count(old) == 1
p.write_text(s.replace(old, 'match copied with | Flag.yes => Flag.yes'), newline='\n')
"

plant theorem_left_as_sorry "
import pathlib, re
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
wrong = re.sub(r'(public theorem send_only_after_commit [^\n]*:= by\n).*?\n\n', lambda m: m.group(1) + '  sorry\n\n', s, count=1, flags=re.S)
assert wrong != s
p.write_text(wrong, newline='\n')
"

plant readme_edited_alone "
import pathlib
p = pathlib.Path('README.md')
p.write_text(p.read_text() + 'one more line\n', newline='\n')
"

plant theorem_weakened "
import pathlib
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
old = 'def sendAllowed (phase : Phase) (event : Event) : Bool :='
assert old in s
start = s.index(old)
stop = s.index('public theorem send_only_after_commit')
s = s[:start] + 'def sendAllowed (phase : Phase) (event : Event) : Bool := true\n\n' + s[stop:]
lines = s.split('\n')
p.write_text(s, newline='\n')
"

plant theorem_deleted "
import pathlib, re
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
wrong = re.sub(r'public theorem the_top_byte_is_plain [^\n]*:= by\n.*?\n\n', '', s, count=1, flags=re.S)
assert wrong != s
p.write_text(wrong, newline='\n')
"

plant axiom_added "
import pathlib, re
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
wrong = re.sub(r'(public theorem a_quote_is_escaped [^\n]*:= )by\n.*?\n\n', lambda m: m.group(1) + 'cheat.elim\n\n', s, count=1, flags=re.S)
assert wrong != s
wrong = wrong.replace('namespace UorEmit.Emit\n', 'namespace UorEmit.Emit\n\npublic axiom cheat : False\n', 1)
p.write_text(wrong, newline='\n')
"

plant c_edited_in_the_lean "
import pathlib
p = pathlib.Path('lean/UorEmit/Emit.lean')
s = p.read_text()
old = 'define HOLD_CAP 8192'
assert old in s
p.write_text(s.replace(old, 'define HOLD_CAP 8193'), newline='\n')
"

plant c_edited_alone "
import pathlib
p = pathlib.Path('src/server.c')
s = p.read_text()
old = 'define HOLD_CAP 8192'
assert old in s
p.write_text(s.replace(old, 'define HOLD_CAP 8193'), newline='\n')
"

plant table_edited_alone "
import pathlib
p = pathlib.Path('src/core.h')
s = p.read_text()
wrong = s.replace('{1, 2, 1, 1, },', '{1, 2, 1, 3, },')
assert wrong != s
p.write_text(wrong, newline='\n')
"

echo "PLANTED escaped=$escaped"
exit "$escaped"
