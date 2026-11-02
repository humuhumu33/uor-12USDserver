# Server verification

What the `core` suite establishes about the server in `server/`, what it doesn't, and the evidence that its gates can fail.

## What is proved, tested and neither

| Part | Status | Evidence |
| --- | --- | --- |
| The decision functions in `emit/core.lex`: batch order, routes, holds, the write pause, failures | Proved over every input, in LexLean, by the Lean kernel | 16 theorems, `SV-01` to `SV-05` |
| Byte classes in `emit/core.lex` | Proved at bytes 0, 31, 32, 34, 92 and 255 only | 6 theorems, `SV-06` |
| The Rust generator that writes the files | Certified by LexLean's production build against its definitions. For `server.c` this is a round trip: the generator carries the text it was given. Only `core.h` is computed | `just emit`, `SV-07` |
| The box's own build | Official Lean alone checks the theorems, restates them in `Claims.lean`, checks their axioms and compares every file, or the build stops | `build.sh`, `SV-08` |
| The tables as they reach C, all 256 byte classes, the 8-byte escape test | Tested exhaustively, not proved | `server/src/core_test.c`, `SV-06` |
| That the server reads those tables, and in the right order | String and order checks on the source, then exercised by the 42 tests. Not proved, and a defect that keeps the strings could pass | `crates/conformance/tests/core.rs` |
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

## The box's build

The folder a pull request adds holds the readable C and the plain Lean. `build.sh` checks the theorems with official Lean, runs the program, compares every file, and tests the tables. `emit/submission/plant.sh` puts defects into a copy of that folder, and the build must stop on each, after an untouched copy has built.

| Defect | Failing command | Diagnostic |
| --- | --- | --- |
| `gateNext` changed so a copied log no longer opens the gate | `PGO=0 bash build.sh` | `unsolved goals` in `the_gate_opens_when_the_log_is_copied` |
| A theorem's proof replaced by `sorry` | `PGO=0 bash build.sh` | `Claims.lean: send_only_after_commit rests on sorryAx` |
| `README.md` edited without the program | `PGO=0 bash build.sh` | `cmp`: differs, exit 1 |
| `sendAllowed` redefined as `true` | `PGO=0 bash build.sh` | Stops on warnings as failures: unused variables and an unused simp argument. `Claims.lean` wasn't reached |
| A theorem deleted | `PGO=0 bash build.sh` | `Claims.lean: Unknown constant the_top_byte_is_plain` |
| An axiom added and used | `PGO=0 bash build.sh` | `Claims.lean: a_quote_is_escaped rests on UorEmit.Emit.cheat` |
| C edited inside `Emit.lean` | `PGO=0 bash build.sh` | `src/server.c generated/src/server.c differ` |
| `src/server.c` edited alone | `PGO=0 bash build.sh` | `src/server.c generated/src/server.c differ` |
| `src/core.h` edited alone | `PGO=0 bash build.sh` | `src/core.h generated/src/core.h differ` |

Recorded from `submission` run 41514549488, commit `473c892`: `UNTOUCHED exit=0`, `PLANTED escaped=0`, and `passed=42 failed=0` from the challenge's `test/run.sh` on the same folder.

## Known gaps

Found by an independent audit and not closed:

- Capacity and other measurements aren't in the ledger, because no measured claim is made.
- The 503 from `/health`, the close when a request outgrows its buffer, and `die()` aren't modelled failures (R5). The challenge's negative tests run outside `just vv`.
- The order in `AGENTS.md` wasn't followed for this suite: `server.c` predates the model and tests (R3).
- `build.sh` skips the Lean steps where there is no `lean/`, the path `rig.yml` uses. The submitted folder always has it.
- Nothing has run on Ubuntu's 6.8. On 6.8 a request can pin later socket closes until it ends, which is untested under connection churn.
