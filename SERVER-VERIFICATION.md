# Server verification

What the `core` suite establishes about the server in `server/`, what it doesn't, and the evidence that its gates can fail.

## What is proved, tested and neither

| Part | Status | Evidence |
| --- | --- | --- |
| The decision functions in `emit/core.lex`: batch order, routes, holds, the write pause, failures | Proved over every input, in LexLean, by the Lean kernel | 16 theorems, `SV-01` to `SV-05` |
| Byte classes in `emit/core.lex` | Proved at bytes 0, 31, 32, 34, 92 and 255 only | 6 theorems, `SV-06` |
| The Rust generator that writes the files | Certified by LexLean's production build against its definitions | `just emit`, `SV-07` |
| The tables as they reach C, all 256 byte classes, the 8-byte escape test | Tested exhaustively, not proved | `emit/core_test.c`, `SV-06` |
| That the server reads those tables | Checked by reading the source, then exercised by the 42 tests | `crates/conformance/tests/core.rs` |
| The event loop, HTTP and JSON parsing, JWT, B-tree reads and SQLite calls | C text carried through the module. Not proved | The challenge's 42 tests; load runs |
| Capacity, in users held | Measured on CI loopback with an emulated CPU limit. Not a score | `rig/` |

No theorem says anything about the C that calls a table. The server as a whole is not formally verified.

A full hold queue is the stated limit of `SV-03`: when it is full, nothing new is held, so a later request on a held connection can overtake a held one. That needs pipelined requests on a connection with a held write.

## Recipe

`just emit` runs `emit/sdk-emit.sh` as part of `just vv`. The committed module `emit/project/src/Emit.lex.tex` is the source of record. The recipe fails if regenerating it gives different bytes, if a theorem fails, if the root doesn't certify, if any file it writes differs from `server/`, or if `core_test` fails.

## Planted defects

Each defect goes into a fresh copy of the repository through `emit/plant.sh`, which fails if any defect escapes. The repository itself is never changed, so the restored result is the `just vv` run on the same commit.

| Defect | Failing command | Diagnostic |
| --- | --- | --- |
| `actionOf` sends before the commit | `bash emit/sdk-emit.sh` | `LLV7002` unsolved goals, `false = true` in `send_only_after_commit` |
| `server.c` edited without the module | `bash emit/sdk-emit.sh` | `FRESH 0`, `GATE bad=1` |
| A table in `core.h` edited by hand | `bash emit/sdk-emit.sh` | `DIFFERENT src/core.h`, `GATE bad=1` |
| `escapeClass` wrong at byte 127, which no theorem checks | `bash emit/sdk-emit.sh` | Theorems pass; `class of byte 127`, `core_test failures=1` |
| A theorem's statement weakened to a tautology | `cargo test -p repo-conformance --test core` | `core_sv_01`: `send_only_after_commit's statement changed` |
| The server stops reading the route table | `cargo test -p repo-conformance --test core` | `core_sv_02`: `the server must take this decision from the emitted table` |
| A file in `server/` the root doesn't write | `cargo test -p repo-conformance --test core` | `core_sv_07`: `every file in server must be compared` |

Recorded from `plant` run 41442171462, commit `c4340a9`: `PLANTED escaped=0`. Restored: `bootstrap` run 41439383771, commit `61da6e9`, `vv: the acceptance gate passed` on both native runners.

The byte 127 defect shows what each gate is for: the proofs passed, and only the exhaustive test caught it.
