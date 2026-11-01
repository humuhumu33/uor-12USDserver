#!/bin/bash
# Runs inside the locked SDK image on one CPU: build the benchmark, then the emitted-source chain end to end.
set -uo pipefail
cd feasibility/bench
export CARGO_HOME=/tmp/cargo CARGO_TARGET_DIR=/tmp/target RUSTFLAGS="-C target-cpu=native"
rustc --version
grep -m1 "model name" /proc/cpuinfo
cargo build --release --offline --bins 2>&1 | tail -5
ls -la /tmp/target/release/bench /tmp/target/release/emit
/tmp/target/release/bench 2>&1
echo "bench exit $?"
/tmp/target/release/emit /tmp/emitted.c && cc -O2 /tmp/emitted.c -o /tmp/emitted
echo "emitted $(wc -c < /tmp/emitted.c) bytes, compile exit $?"
/tmp/emitted
echo "EMITTED program exit $? (expected 42)"
