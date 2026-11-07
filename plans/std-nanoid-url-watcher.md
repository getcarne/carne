# P3 batch: std/nanoid, std/url, std/watcher

## Goal
Expand JS stdlib with three small modules. `std/env` already covers
dotenv, so it is out of scope.

## Scope
- `std/nanoid`: id generation via `pkg/openparser/nanoid.nim`.
  - `nanoid([size])`, `customAlphabet(alphabet[, size])`,
    `nanoidNonSecure([size])`, constants `urlAlphabet`, `defaultSize`.
  - Sync only, no loop. Validation errors throw JS Error.
- `std/url`: WHATWG-style URL helpers via Nim `std/uri` (not `std/path`,
  which stays file-path oriented).
  - `parse(text)` -> `{scheme, username, password, hostname, port,
    path, query:[{key,value}], fragment, isAbsolute}`.
  - `format(obj)` -> string (inverse of parse).
  - `encode(text)`, `decode(text)`, `encodeComponent`, `decodeComponent`,
    `parseQuery(text)`, `stringifyQuery(pairs)`.
  - Pure, no loop. Throws on invalid input.
- `std/watcher`: file watching via `pkg/powpow/fswatch.nim`.
  - Async: `watch(path, onEvent)` -> `{close(), path}` handle.
    Holds one pending slot until `close()` (Node semantics).
    `onEvent(events)` receives string array from
    `FileSystemEvent` (`modified`, `created`, `deleted`, `renamed`,
    `attrib`, `linkCount`, `revoke`).
  - Sync: `watchOnce(path[, timeoutMs])` -> events array. Blocks by
    pumping the shared loop (`loop.poll(25)` slices, like
    `std/ws connectSync`), default 10s timeout, throws on timeout.
  - `close()` is final and idempotent. Teardown hook closes live
    watchers. `watch` in http worker threads is rejected.

## Files
- `src/carne/std/nanoid.nim`, `tests/test_nanoid.nim`, `examples/nanoid.js`
- `src/carne/std/url.nim`, `tests/test_url.nim`, `examples/url.js`
- `src/carne/std/watcher.nim`, `tests/test_watcher.nim`, `examples/watcher.js`
- Register in `src/carne/std/all.nim`, README std list + roadmap.

## Tests
- nanoid: length/alphabet defaults, custom alphabet, non-secure path,
  validation throws.
- url: parse/format roundtrip, query parse/stringify, encode/decode,
  invalid throws.
- watcher: async event on file write + close idempotent; sync
  `watchOnce` resolves on write; missing path throws; close unknown
  handle is true.
- Full `clue test` must stay green (currently 42/42 before batch).
