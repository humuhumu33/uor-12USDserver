#!/usr/bin/env bash
# Builds bin/server: the pinned SQLite amalgamation and the server as one translation unit.
set -euo pipefail
cd "$(dirname "$0")"
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p vendor bin
if [ ! -f "vendor/$SQLITE/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o "vendor/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  vendor/$SQLITE.zip" | sha256sum -c -
  unzip -q -o "vendor/$SQLITE.zip" -d vendor
fi
gcc -std=gnu11 -O3 -march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256 -fno-plt -fomit-frame-pointer -pthread \
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_TEMP_STORE=3 \
  -DNDEBUG -I"vendor/$SQLITE" -o bin/server src/server.c -l:liburing.a -lm
echo "built bin/server"
