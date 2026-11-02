#!/bin/bash
# Runs inside the locked SDK image. A gate is evidence only once a planted defect shows it can fail, so each defect
# here goes into a fresh copy of the repository, and the gate named for it must reject that copy.
set -uo pipefail
repo="$PWD"
work=/tmp/plant
export CARGO_TARGET_DIR=/tmp/plant-target
escaped=0

fresh() {
  rm -rf "$work"
  mkdir -p "$work"
  tar -C "$repo" --exclude=.git --exclude=target --exclude='emit/work*' --exclude=emit/out -cf - . | tar -C "$work" -xf -
  cd "$work" || exit 1
}

# plant NAME EDIT_PYTHON GATE_COMMAND LINES_TO_SHOW
plant() {
  local name="$1" edit="$2" gate="$3" show="$4"
  fresh
  python3 -c "$edit" || { echo "PLANT $name could not be planted"; escaped=1; return; }
  git -C "$repo" diff --no-index --stat "$repo/emit/core.lex" emit/core.lex > /dev/null 2>&1
  bash -c "$gate" > /tmp/plant.log 2>&1
  local code=$?
  echo "PLANT $name gate='$gate' exit=$code"
  grep -E "$show" /tmp/plant.log | cut -c1-400 | head -6 | sed 's/^/  SAW /'
  [ "$code" != 0 ] || { echo "PLANT $name ESCAPED"; escaped=1; }
}

EMIT='bash emit/sdk-emit.sh'
TESTS='cargo test -q --locked -p repo-conformance --test core'

plant send_before_commit "
import pathlib
p = pathlib.Path('emit/core.lex'); s = p.read_text()
a = s.index('name: actionOf,'); b = s.index('| Phase.committing =>', a)
block = s[a:b]
fixed = block.replace('| Event.commitOk => (ctor Action.nothing)\n      | Event.commitFail => (ctor Action.nothing))\n    ', '| Event.commitOk => (ctor Action.sendAll)\n      | Event.commitFail => (ctor Action.nothing))\n    ')
assert fixed != block
p.write_text(s[:a] + fixed + s[b:], newline='\n')
" "$EMIT" 'DIAG|VERIFY|FRESH'

plant server_edited_alone "
import pathlib
p = pathlib.Path('server/src/server.c'); s = p.read_text()
assert 'define HOLD_CAP 8192' in s
p.write_text(s.replace('define HOLD_CAP 8192', 'define HOLD_CAP 8193'), newline='\n')
" "$EMIT" 'FRESH|GATE'

plant table_edited_by_hand "
import pathlib
p = pathlib.Path('server/src/core.h'); s = p.read_text()
wrong = s.replace('{1, 2, 1, 1, },', '{1, 2, 1, 3, },')
assert wrong != s
p.write_text(wrong, newline='\n')
" "$EMIT" 'FRESH|DIFFERENT|GATE'

plant byte_no_theorem_checks "
import pathlib
p = pathlib.Path('emit/core.lex'); s = p.read_text()
head = '(if (prim equal octet (34 : UInt8) : Bool) then (ctor EscapeClass.backslash) else'
assert head in s
p.write_text(s.replace(head, '(if (prim equal octet (127 : UInt8) : Bool) then (ctor EscapeClass.unicode) else ' + head, 1).replace('(ctor EscapeClass.plain)))),', '(ctor EscapeClass.plain))))),', 1), newline='\n')
" "$EMIT" 'VERIFY|DIAG|class of byte|core_test|CORETEST|DIFFERENT|GATE'

plant weakened_theorem "
import pathlib
p = pathlib.Path('emit/core.lex'); s = p.read_text()
old = 'statement: ((sendAllowed phase event) = true),'
assert old in s
p.write_text(s.replace(old, 'statement: ((sendAllowed phase event) = (sendAllowed phase event)),'), newline='\n')
" "$TESTS" 'statement changed|test result|core_sv_'

plant server_stops_reading_the_table "
import pathlib
p = pathlib.Path('server/src/server.c'); s = p.read_text()
old = 'int route = ROUTE_OF[method][path_shape(path, path_len)];'
assert old in s
p.write_text(s.replace(old, 'int route = method == METHOD_GET ? ROUTE_FEED : ROUTE_NOT_FOUND;'), newline='\n')
" "$TESTS" 'must take this decision|test result|core_sv_'

plant file_the_root_does_not_write "
import pathlib
pathlib.Path('server/extra.c').write_text('int unproved;\n')
" "$TESTS" 'every file in server|test result|core_sv_'

cd "$repo" || exit 1
echo "PLANTED escaped=$escaped"
exit "$escaped"
