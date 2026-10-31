<p align="center">
  <img src="https://github.com/openpeeps/carne/blob/main/.github/carne_logo.png" alt="Carne Logo" width="140px" height="140px"><br>
  Carne /kär-nē/ &bullet; a JavaScript runtime 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install carne</code> / <code>clue install carne --build</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/carne">API reference</a><br>
  <img src="https://github.com/openpeeps/carne/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/carne/workflows/docs/badge.svg" alt="Github Actions">
</p>

> [!NOTE]
> Carne is still experimental: it runs on macOS and Linux
> (Linux needs `libjavascriptcoregtk-4.1-dev` installed), the `std/*` API
> may change between 0.x releases, and a few modules are parse-only
> in v1 (see the Standard Library notes below). Scripts needing
> top-level `await` must wrap in an async IIFE for now. Not recommended
> for production yet, but the full test suite passes on both platforms
> and every example below is covered by it.

## About
A JavaScript runtime based on JavaScriptCore and Nim! No drama, no overhype. With a rich
standard library, so you don't need npm anymore! Still, it ships with an efficient package manager that
abolishes `node_modules` and keeps dependencies in one shared global store instead.

Carne is not a drop-in replacement for Node.js, Bun or Deno, instead it is a runtime with an opinion: most scripts
should not need a dependency at all. It trades the npm ocean for a standard library that covers
everyday work out of the box, starts in ~8 ms on the back of JavaScriptCore, and stays ~6k lines of Nim,
small enough to read in an afternoon. If you want the Node ecosystem, keep Node. If you want a
script that just runs, take Carne.

## 😍 Key Features
- JavaScript runtime powered by JavaScriptCore
- Powerful Standard Library fully written in Nim lang
- Cryptographic library via [pkg/nimcypher](https://github.com/nimbase/nimcypher)
- HTTP/1.1, H/2, UDP, TCP and WebSockets library via [pkg/powpow](https://github.com/openpeeps/powpow)
- Built-in formatters: `yaml`, `toml`, `csv`, `xml`, `markdown`, `vcard`, `feed`, `sql`, `css`, `diff`, `qr`, `svg` via [pkg/openparser](https://github.com/openpeeps/openparser) (`colors` is pure JS)
- JIT compiled Regex Engine
- i18n via GNU Gettext PO/MO
- CSS and JavaScript bundler via [pkg/squeezy](https://github.com/openpeeps/squeezy)
- Built-in package manager (`carne pkg`)
  - one shared global store in your home dir, no `node_modules`,
    no duplicated installs across projects
  - `install` (by name or `--url`), `remove`, `update`, `list`,
    `prune` orphans, `refresh` registry data
  - `develop <path>` for editable installs from a local directory
  - `package.json` manifests, npm-spec compliant; public registry
    at [openpeeps/carnepkgs](https://github.com/openpeeps/carnepkgs)
- Written in Nim language
- Open Source | `MIT` License

### Usage

```
A JavaScript runtime in Nim
  (c) OpenPeeps | MIT License
  Build Version: 0.1.0

usage: carne <command> [args] [options]

Scripting
  run <script.js> [args]  run a .js file

Packages
  pkg install <spec>      install a package by name, git URL (--url=... pins a source URL)
  pkg remove <name> [ver] uninstall a package (one version, or all)
  pkg update [name]       update one package, or all when omitted
  pkg list                list installed packages
  pkg develop <path>      editable install from a local directory
  pkg prune               remove orphaned packages
  pkg refresh             re-download registry data
  pkg publish [opts]      open a PR adding this package to the registry

  -h, --help              show this help
  --version               show version
```

## Package manager
A DFS (depth-first search) package manager with one shared global store
(`~/.carne`, no `node_modules`), built on
[pkg/datpkgr](https://github.com/openpeeps/datpkgr), the same engine used
at [tim](https://github.com/openpeeps/tim),
[clue](https://github.com/openpeeps/clue),
[bowdy](https://github.com/openpeeps/bowdy). It installs from both git
and npm-style sources:

- `carne pkg install <git-url>` (or `--url=...` to pin a source URL):
  `https://` URLs, `git+`/`git://` transports, `git@` and `.git` URLs,
  plus forge aliases (`gh:user/repo`, long form `github:`; also `gl:`,
  `cb:`, `srht:`). A `#ref`
  suffix pins a branch or tag: `carne pkg install gh:user/repo#v1`.
  Works today.
- The cloned repo must contain a valid `package.json` at its root;
  anything else is rejected, not installed.
- `carne pkg install <name>[@range]`, `npm:name@range` aliases:
  resolved through the package registry at
  [openpeeps/carnepkgs](https://github.com/openpeeps/carnepkgs)
  (source `carne`, cached at `~/.carne/registries/carne.json`;
  `carne pkg refresh` re-downloads it).
- `carne pkg develop [path]`: editable installs from a local directory
  (default: current dir).
- `remove`, `update`, `list`, `prune`, `refresh` manage the store.
- `carne pkg publish [--tags=..] [--web=..] [--url=..] [--dry-run] [--yes]`:
  opens a pull request adding the current package to
  [openpeeps/carnepkgs](https://github.com/openpeeps/carnepkgs)
  (fork, insert into `packages.json` in name order, PR against `main`).
  `description`, `license` and `keywords` (registry tags) are required in
  `package.json`; the repo URL comes from `.git/config` (`remote.origin.url`).
  Auth is the GitHub token on its own line in `~/.carne/.tokens` (`chmod 600`).
  `--dry-run` prints the entry without touching the network.

### Package imports
Installed packages load through `require("pkg/<name>")` as CommonJS:
entry resolution reads the `exports` map root first, then `main`
(`index.js`, `src/index.js`, `<name>.js` fallbacks). A `@version`
suffix pins an installed version, `pkg/<name>/sub/path` reaches
inside, and `./...` requires work between package files (and from
`carne run` scripts, relative to the script).

```js
const demo = require("pkg/carne_demo_pkg");
console.log(demo.hello("ada")); // hi ada
```

A `@version` suffix pins an installed version
(`require("pkg/greet@0.1.0")`), and `pkg/<name>/sub/path` reaches
inside a package.

Only CommonJS v1: ESM (`import`/`export`) packages fail with a clear
error, as do packages with no loadable entry.

## Standard Library

All modules load lazily via the global `require("std/<name>")`,
requiring one costs nothing until first use. Timers are globals
(No require needed), Node-style.

The library covers OS and process access, data formats, text
processing, crypto, networking, and developer tools:

- `std/env` - process info and environment (args, getenv, cwd, exit)
- `std/os` - synchronous OS utilities (files, dirs, sleep, exec)
- Timers - `setTimeout`/`setInterval` globals, no require needed
- `std/yaml` - YAML parsing and serialization
- `std/toml` - TOML parsing and serialization
- `std/ical` - iCalendar parsing and serialization
- `std/dotenv` - `.env` file parsing with variable expansion
- `std/plist` - Apple property lists
- `std/bson` - BSON parsing and serialization
- `std/csv` - CSV parsing
- `std/xml` - XML parsing and serialization
- `std/vcard` - vCard contact parsing (parse-only in v1)
- `std/feed` - RSS and Atom feed parsing (parse-only in v1)
- `std/sql` - SQL parsing and validation (sqlite, postgres, mysql)
- `std/crypto` - hashing, AEAD sealing, signatures, passwords
- `std/path` - file-path and URL parsing (parse-only in v1)
- `std/colors` - color parsing, formatting and math (pure JS)
- `std/css` - CSS parsing and declaration validation
- `std/diff` - unified diffs
- `std/gettext` - `.po` parsing and translation
- `std/mimetype` - MIME type lookup
- `std/benchmark` - in-process microbenchmarking
- `std/qr` - QR code generation (decoding out of scope in v1)
- `std/svg` - SVG parsing (serialization out of scope in v1)
- `std/http` - async HTTP client + server (optional worker threads)
- `std/ws` - async + sync WebSocket client and server
- `std/uuid` - UUID generation (v1-v8) and inspection

Full API reference with examples: https://openpeeps.github.io/carne/

## Roadmap
- [x] JSC runtime: console/process/require/timers CLI
- [x] Package management (`carne pkg`, manifests)
- [x] Format std libs (yaml, toml, ical, dotenv, plist, bson, csv, xml, vcard, feed)
- [x] `std/sql`, `std/crypto`, `std/path`, `std/colors`
- [x] `std/css`, `std/diff`, `std/gettext`, `std/mimetype`, `std/benchmark`, `std/qr`, `std/svg`
- [x] `std/http` (async client + server, tuning opts, method helpers) + top-level promise unwrap in `runCode`
- [x] `std/ws` (async + sync client, server, binary/ping/protocol, `wss://` client)
- [x] `std/http` workers (cluster-style threads, `process.isWorker`)
- [x] `std/uuid` (v1-v8 generation, parse/inspect, RFC namespace constants)
- [x] Lazy startup (deferred event loop, per-run TLS, cached spec data)
- [x] Benchmark suite + results
- [ ] Top-level await in scripts (currently needs an async IIFE)
- [ ] `std/crypto`: X25519 exchange, RSA/ECDSA, AES-GCM
- [ ] `std/gettext`: `.mo` support; `std/qr`: decode; `std/svg`: stringify
- [ ] `exportClass` in the module DSL
- [x] Public package registry ([openpeeps/carnepkgs](https://github.com/openpeeps/carnepkgs))
- [x] `carne pkg publish` (fork + PR flow, `.tokens` auth)
- [x] Beyond macOS (Linux via JavaScriptCoreGTK 4.1)


## Benchmarks

Kinda useless JS bench suite (`bench/js`, via `hyperfine --warmup 2 --min-runs 3`,
macOS, `bench/run.sh` reproduces; node v22.22.1, bun 1.4.3):

| Benchmark | carne | node | bun |
|-----------|-------|------|-----|
| fib_recursive | 42.4 ms ± 0.5 ms | 85.1 ms ± 1.1 ms | 45.5 ms ± 1.0 ms |
| nested_loops | 9.3 ms ± 0.4 ms | 36.3 ms ± 0.7 ms | 11.9 ms ± 0.4 ms |
| prime_sieve | 9.2 ms ± 0.3 ms | 35.0 ms ± 0.5 ms | 11.7 ms ± 0.3 ms |
| string_concat | 9.4 ms ± 0.3 ms | 34.5 ms ± 0.5 ms | 11.7 ms ± 0.7 ms |
| tail_recursive | 9.7 ms ± 0.3 ms | CRASHED | 11.8 ms ± 0.3 ms |
| range_sum | 38.4 ms ± 0.4 ms | 43.8 ms ± 0.4 ms | 19.6 ms ± 0.3 ms |
| collatz | 51.1 ms ± 0.4 ms | 69.5 ms ± 0.7 ms | 53.4 ms ± 2.3 ms |
| array_sum | 14.6 ms ± 0.5 ms | 40.7 ms ± 0.9 ms | 16.8 ms ± 0.3 ms |
| bubble_sort | 11.8 ms ± 0.3 ms | 36.7 ms ± 0.4 ms | 14.5 ms ± 0.3 ms |
| object_access | 11.3 ms ± 0.3 ms | 36.9 ms ± 0.4 ms | 14.0 ms ± 0.3 ms |
| float_math | 12.9 ms ± 0.3 ms | 39.1 ms ± 1.0 ms | 16.5 ms ± 0.4 ms |
| call_overhead | 10.4 ms ± 0.2 ms | 35.5 ms ± 0.4 ms | 12.5 ms ± 0.3 ms |
| fizzbuzz_count | 43.8 ms ± 0.4 ms | 64.8 ms ± 0.6 ms | 38.3 ms ± 0.4 ms |

A cold `hello.js` run costs carne ~8.5 ms, so everything near that floor is
startup-dominated (JSC context + stdlib install), not compute. Node crashes
`tail_recursive` (no proper tail calls: stack overflow at 10k frames);
carne inherits JSC's tail-call support, like bun.

### HTTP hello-world (`wrk`)

Throughput bench (`bench/http-hello`, `bench/http-hello/run.sh` reproduces;
wrk 4.2.0, `wrk -t4 -c100 -d10s` after a 2s warmup, port 3000, macOS,
node v22.22.1, bun 1.4.4). Each server answers `200 text/plain
"hello world"` to every request; `carne-workers` is the same server
with `{workers: 4}` (`bench/http-hello/server.carne.workers.js`):

| Runtime | Requests/sec | Avg latency | Max RSS |
|---------|--------------|-------------|---------|
| carne | 91330.44 | 1.15ms | 10.9 MB |
| carne-workers | 144029.68 | 739.70us | 28.3 MB |
| node | 38576.69 | 2.71ms | 61.5 MB |
| bun | 86878.46 | 1.15ms | 31.1 MB |

Bodies are byte-identical (11 bytes); headers differ per runtime, so
`Transfer/sec` is not directly comparable. Max RSS is sampled via
`ps` during the measured run (includes shared libraries).

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/carne/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/carne/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
