#!/usr/bin/env bash
# Builds bin/server: the pinned SQLite amalgamation and the server as one translation unit, profile-guided.
#   PGO=0 ./build.sh   plain build
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
FLAGS=(-std=gnu11 -O3 -g -march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256 -fno-plt -fomit-frame-pointer
  -fno-stack-protector -fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE -pthread
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0
  -DSQLITE_TEMP_STORE=3 -DNDEBUG "-Ivendor/$SQLITE")
LINK=(-l:liburing.a -lm)
if [ "${PGO:-1}" = 0 ]; then
  gcc "${FLAGS[@]}" -o bin/server src/server.c "${LINK[@]}"
else
  rm -f bin/*.gcda
  gcc "${FLAGS[@]}" -fprofile-generate -fprofile-update=single -o bin/server src/server.c "${LINK[@]}"
  training=$(mktemp -d)
  SERVER_PROFILE_TRAINING=400000 SQLITE_PATH="$training/train.db" JWT_SECRET=profile-training HOST=127.0.0.1 PORT=39871 bin/server
  rm -rf "$training"
  gcc "${FLAGS[@]}" -fprofile-use -fprofile-correction -Wno-missing-profile -o bin/server src/server.c "${LINK[@]}"
fi
echo "built bin/server ($(wc -c < bin/server) bytes)"
