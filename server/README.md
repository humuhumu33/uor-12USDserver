# LexLean + C: a proved core on io_uring and SQLite B-tree reads

Every file in this folder is written by a certified [LexLean](https://github.com/UOR-Foundation/LexLean) program. The decisions are written and proved in LexLean. The event loop, parsers and SQLite calls are C, carried as text through that program, because LexLean has no I/O or raw pointers. **The server as a whole is not formally verified.** The table below says what is.

| | |
|---|---|
| Language | LexLean 0.3.0 (Lean 4.32.1) for the core and for writing the files; C (gnu11) for everything that touches a socket or a pointer |
| Framework | none |
| Compiler | GCC from `build-essential`, profile-guided, `-O3 -march=x86-64-v3` |
| io_uring | liburing 2.5 from Ubuntu 24.04, version pinned, linked statically |
| SQLite | 3.54.1 amalgamation, SHA-256 pinned, not patched, compiled into one translation unit with the server |
| **Nginx or direct** | **Direct** on `HOST:PORT` |

## What is proved, tested, and neither

| Part | Status |
|---|---|
| Batch order: a response leaves only after its batch commits, a failure response only after the commit fails | Proved over every phase and event |
| Routes: only POST writes, every write needs a token, an unknown method is not found | Proved over every method and path shape |
| Holding writes: reads go on while writes wait, a held connection keeps its order while the hold queue has room | Proved over every input |
| The write pause: closes at its limit, stays closed until the log is copied or the wait times out | Proved over every input |
| Errors: only an internal failure is a 5xx | Proved over every failure |
| JSON byte classes | Proved at bytes 0, 31, 32, 34, 92 and 255 only |
| The tables as they reach C, all 256 byte classes, the 8-byte escape test | Tested exhaustively, not proved |
| The event loop, HTTP and JSON parsing, JWT, B-tree reads, SQLite calls | C. Not proved. Covered by `test/test.sh` and load runs |

The theorems are about the LexLean definitions. Nothing proves that the C uses a table correctly: a test checks that it reads them, and the suite exercises them. The 22 theorems, 7 registered claims and 7 planted defects are in [the repository](https://github.com/humuhumu33/uor-12USDserver). They are checked in that repository's CI, not on the box.

If the hold queue is full, a later request on a held connection can overtake a held one. The theorem states this limit. It needs pipelined requests on a connection with a held write.

## How it is built

`src/core.h` and `src/server.c` are generated, and committed here as source. LexLean 0.3.0 has no standalone release, so the generator can't run on the box. `build.sh` compiles the committed C on the box, downloading and checksumming SQLite. Nothing prebuilt is shipped. The repository's gate fails if any file here differs from what the certified program writes.

## Design

One thread runs the event loop, HTTP, JWT, JSON and SQLite reads. A second thread only runs WAL checkpoints.

- **Sockets.** Direct descriptors, so `LimitNOFILE=65535` caps one ring's table and not the server. Up to 8 rings, made as connections need them. Eight `SO_REUSEPORT` listeners.
- **Reading.** A multishot receive into provided buffers, 4,096 x 1 KB per ring, one submission fewer per request than a poll and a read. A receive that ends when buffers run out is re-armed in bounded rounds, to limit a storm of re-arms after a stall.
- **Drain first.** Requests are read out of their sockets as soon as they arrive, into a queue of up to 32,768, and answered up to 2,048 per batch. A request waiting in a socket costs 3-4 KB of network buffer; read out, it costs about 100 bytes.
- **Batches.** Each batch is one SQLite transaction: reads from its snapshot, then writes through prepared statements, then `COMMIT`, then every response. No response leaves before its commit (rule 6).
- **Reads** walk SQLite's own B-tree cursors inside that transaction, with no SQL engine and no remembered data: the organiser allowed this for #153. The feed walks `posts_created_at_id_idx`, seeks the 20 posts, and counts likes with one range walk where it can. Every request reads SQLite while it is served (rule 5).
- **JWT.** Every token's signature is verified on every request. The HMAC key's pad states are hashed once at startup.
- **WAL.** `synchronous=NORMAL`, `wal_autocheckpoint` off. A checkpoint thread at nice 19 runs passive checkpoints past 1,000 frames. Past 4,000, writes wait for at most 1 s while reads go on, so the next write can restart the log. Past 16,384 the loop checkpoints itself. A commit's frames go to the kernel in one `pwrite`, through a small VFS shim over `unix-excl`.
- **Page cache.** 32 MB, with `mmap_size=0`.
- **Code lock.** The binary is locked in RAM, so reclaim at the memory wall can't stall the loop on its own code.

## Credit

Built on what earlier entries published, under MIT: the B-tree seek and record decoding follow lean-derive-hargup (#153); drain-first batching, the write gate, the one-write WAL idea and the reserved-field retry for Ubuntu's buffer-ring registration follow c-iouring-pavlyhalim (#245); the multishot receive follows rust-iouring-kensac (#264).

## Measurements

No user-count score is claimed. The organiser's benchmark is the only score. Everything measured so far ran on CI runners over loopback with an emulated CPU limit, which differs from the box in CPU, kernel and network.

## Run

```bash
sudo bash install.sh
bash build.sh
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```
