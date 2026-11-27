# Carne roadmap: core + std

Scope: `src/carne/runtime.nim`, `src/carne/bridge.nim`, `src/carne/modules.nim`, `src/carne/cli.nim`, and `src/carne/std/*`. Current version: `0.1.5` (`carne.nimble:3`).

Out of scope for this file: package manager behavior, `gen docs`, `gen ast`, `gen addon`, registry work.

How to verify each item: `clue build`, `clue test <name>`, `./bin/carne run <file>`, docs snippets run against the built binary.

## 0. Core runtime

Base: `src/carne/runtime.nim:162` (`runCodeEx`), `src/carne/modules.nim:48` (lazy registry), `src/carne/bridge.nim:1` (`registerFn` DSL).

- [x] Top-level `await` in entry scripts without manual async IIFE wrapper. Keep sync path byte-identical, preserve line numbers on syntax errors, keep `pkg/*` requires sync.
- [x] `exportClass` in the module DSL alongside `registerFn`. Same arity checks and error prefix, teardown-safe.
- [x] Error contract: one `fn:` prefix, JSDoc-first type mismatches, `TypeError` for arg validation. Audit all std modules for bare `options.*` messages.
- [x] Lazy event loop stays lazy: pure-sync scripts never create a powpow loop (`src/carne/runtime.nim:224`). Keep per-run TLS and cached spec data.
- [x] Require cache and teardown: per-run `instances`, ordered `onTeardown`, worker thread isolation (`src/carne/modules.nim:40`).
- [x] CLI help stays in sync: top-level usage and `gen` sub-help list the same commands and flags.

## 1. Std format parity

Status notes (verified in tree):
- `std/html`, `std/vcard`, `std/feed` already implement `stringify` in code (`src/carne/std/html.nim:1`, `src/carne/std/vcard.nim:1`, `src/carne/std/feed.nim:1`), but `README.md:252-254` still labels them parse-only. Fix docs, add round-trip tests.
- `std/path` is truly parse-only (`src/carne/std/path.nim:11`).
- `std/csv` already has `parse` + `stringify`.
- `std/sql` already has parse, stringify, format, validate for sqlite, postgres, mysql.
- `std/mimetype` defers `charset` (`src/carne/std/mimetype.nim:15`), exposes lookup, info, isExtension, has.

Tasks:
- [x] `std/path`: add format, join, normalize to complement `parse`. Keep absent options absent.
- [x] `std/mimetype`: add `charset` handling, keep exact lowercase match behavior.
- [x] Docs correction: update README std list for html, vcard, feed now that serialize exists. Add verified round-trip examples.
- [x] `std/sql`: harden dialect parity and error messages, keep validate behavior stable.
- [x] `std/db`: sqlite + postgres driver gaps, sync vs async parity, placeholder rules (`?` vs `$N`), lazy libpq load, JS ORM builder and migration coverage (`src/carne/std/db.nim:1`).
- [x] JS shims (`std/js/*`): keep manifest versioning and `stdsync` refresh path tested.

Verify: `clue test test_html test_vcard test_feed test_path test_csv test_sql test_mimetype test_db`, round-trip tests for every parse and stringify pair.

## 3. OS, process, terminal, watcher

Base: `src/carne/std/os.nim:29` (`exec` blocks loop), `src/carne/std/terminal.nim:14-15` (blocking reads), `src/carne/std/watcher.nim:8-13` (watch vs watchOnce).

- [x] `std/os`: file and dir ops stay sync. Add streaming spawn with stdout and stderr chunks and exit code. Keep `exec` capture-only behavior unchanged.
- [x] `std/terminal`: keep blocking `readLine` and `readPassword` contract explicit, document server stall risk. Keep `write` newline-free, TTY detection, `--isatty` override, `parseArgs` parity.
- [x] `std/watcher`: define async `watch` close semantics (final, idempotent), `watchOnce` timeout behavior, and behavior in http workers.
- [x] `std/env`: args, env parse and load, cwd, exit codes. No behavior change, coverage only.
- [x] `std/benchmark`: keep as regression harness for core and std perf checks.

Verify: `clue test test_os test_terminal test_watcher test_env test_benchmark`, manual TTY and pipe runs.

## 4. Networking and workers

Base: `src/carne/std/http.nim:1`, `src/carne/std/tcp.nim:1`, plus `ws`, `udp`, `httpworkers`.

- [x] `std/http`: async client and server, worker mode, zero-copy file responses, ETag and Range, method helpers. Handler return contract stable (string, JSON, Uint8Array, file).
- [x] `std/ws`: async + sync client, server, binary, ping, protocol, `wss` client path.
- [x] `std/tcp`: client + server, optional TLS, `conn.close` releases pending slot, no hang on timer-close. Server `onClose` still fires on remote close.
- [x] `std/udp`: bind and connect, message boundaries, echo behavior.
- [x] Workers: per-thread context, `process.isWorker` gating, teardown joins. Document shared-state limits and backpressure behavior.
- [x] TLS: serve and connect opts, PEM handling, system CA path, per-run shared client context.

Verify: `clue test test_http test_http_workers test_ws test_tcp test_udp`, `bench/http-hello` for regressions.

## Non-goals

- No ESM or TS package loading changes in this roadmap.
- No native addon loader changes.
- No Windows support.
- No full Node compat emulation.
