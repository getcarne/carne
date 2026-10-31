# Carne JS-std store: `require("std/<name>")` for JS-based modules.
#
# JS stdlib ships as source, not embedded in the binary. `carne std init`
# downloads manifest.json + *.js from the carne repo into ~/.carne/std
# (`CARNE_HOME` overrides), one file per module, each verified against
# the manifest sha256 (nimcypher). `carne std update` refreshes every
# file. The manifest carries the JS-stdlib's own version, independent
# of the binary: downloads try tag `v<binaryVersion>` first, `main`
# otherwise, so manifest and files are always mutually consistent.
#
# At runtime a require fallback (wired via modules.stdRequireHook)
# loads store files as CommonJS through pkg/loader. A missing
# well-known module throws with a `carne std init` hint; anything else
# keeps the classic unknown-module error. Nothing is ever auto-fetched
# inside `require`.

import std/[json, os, osproc, strutils, tables]

import javascriptcore

import pkg/nimcypher/hash

import ../bridge
import ../cli
import ../modules
import ./loader
import ./pkgman

const stdJsRepoBase* = "https://raw.githubusercontent.com/openpeeps/carne"
  ## Registry root: manifest and files live under <base>/<ref>/js-path.

const stdJsPath* = "src/carne/std/js"
  ## Repo-relative directory holding manifest.json + *.js.

const stdManifestFile* = "manifest.json"

const stdKnownJs*: array[3, string] = ["colors", "str", "test"]
  ## Well-known JS modules. Hint quality on fresh installs only; the
  ## fetched manifest is authoritative once present.

type
  StdFile* = tuple[file, sha256: string]
    ## One manifest entry: repo filename + expected hex digest.

  StdManifest* = object
    ## Parsed manifest.json plus the ref it was fetched from.
    version*: string
    refUsed*: string
    files*: Table[string, StdFile]

proc stdRoot*(home = carneHome()): string =
  ## Store root: <home>/std.
  home / "std"

proc stdJsStore*(home = carneHome()): string =
  ## JS module directory: <home>/std/js.
  stdRoot(home) / "js"

proc stdManifestPath*(home = carneHome()): string =
  ## Local manifest copy: <home>/std/manifest.json.
  stdRoot(home) / stdManifestFile

proc parseStdManifest*(src: string): StdManifest =
  ## Parses manifest.json. Raises ValueError on malformed input.
  var j: JsonNode
  try:
    j = parseJson(src)
  except CatchableError as e:
    raise newException(ValueError, "manifest: invalid JSON (" & e.msg & ")")
  if j.kind != JObject:
    raise newException(ValueError, "manifest: expected an object")
  if not j.hasKey("version") or j["version"].kind != JString:
    raise newException(ValueError, "manifest: missing \"version\"")
  if not j.hasKey("files") or j["files"].kind != JObject:
    raise newException(ValueError, "manifest: missing \"files\"")
  result.version = j["version"].getStr()
  result.refUsed =
    if j.hasKey("ref") and j["ref"].kind == JString: j["ref"].getStr()
    else: ""
  result.files = initTable[string, StdFile]()
  for name, entry in j["files"].pairs:
    if entry.kind != JObject or not entry.hasKey("file") or
        entry["file"].kind != JString or not entry.hasKey("sha256") or
        entry["sha256"].kind != JString:
      raise newException(ValueError,
        "manifest: bad entry for \"" & name & "\"")
    result.files[name] = (entry["file"].getStr(),
      entry["sha256"].getStr())

proc readLocalManifest*(home = carneHome()):
    tuple[found: bool, m: StdManifest] =
  ## Reads the local manifest copy. found=false when missing or broken.
  try:
    let m = parseStdManifest(readFile(stdManifestPath(home)))
    return (true, m)
  except CatchableError:
    return (false, StdManifest(files: initTable[string, StdFile]()))

proc isKnownJs*(name: string; home = carneHome()): bool =
  ## True when name is a JS module: local manifest first, the
  ## compile-time list on fresh installs.
  if name in stdKnownJs:
    return true
  let (found, m) = readLocalManifest(home)
  found and m.files.hasKey(name)

proc curlGet(url: string): string =
  ## HTTPS GET over curl (publish.nim precedent, no new deps).
  ## Raises IOError on any failure (curl missing, offline, HTTP error).
  let (output, code) = execCmdEx("curl -fsSL --connect-timeout 15 " &
    quoteShell(url))
  if code != 0:
    raise newException(IOError,
      "download failed: " & url & " (curl exit " & $code & ")")
  output

proc fetchStdManifest*(base = stdJsRepoBase):
    tuple[refUsed, src: string] =
  ## Fetches manifest.json from tag `v<binaryVersion>`, falling back
  ## to `main`. Raises IOError when both are unreachable.
  let tag = "v" & versionStr
  for r in [tag, "main"]:
    let url = base & "/" & r & "/" & stdJsPath & "/" & stdManifestFile
    try:
      return (r, curlGet(url))
    except IOError:
      discard
  raise newException(IOError,
    "download failed: manifest unreachable at tag \"" & tag &
    "\" and main (offline?)")

proc verifySha*(content, wantHex: string): bool =
  ## True when the sha256 of content matches wantHex (case-insensitive).
  sha256Hex(content).toLowerAscii() == wantHex.strip().toLowerAscii()

proc stdSync*(home = carneHome(); base = stdJsRepoBase):
    tuple[version, refUsed: string, count: int, upToDate: bool] =
  ## `carne std init` / `update`: resolves the ref, fetches the remote
  ## manifest, then downloads only missing or changed files (verified
  ## before each write). Writes the local manifest copy last. upToDate
  ## is true when the local version already matched and nothing was
  ## downloaded. Raises IOError on failure.
  let (refUsed, src) = fetchStdManifest(base)
  var m: StdManifest
  try:
    m = parseStdManifest(src)
  except ValueError as e:
    raise newException(IOError, e.msg)
  m.refUsed = refUsed
  let (localFound, local) = readLocalManifest(home)
  let dir = stdJsStore(home)
  createDir(dir)
  var names: seq[string] = @[]
  for name in m.files.keys:
    names.add(name)
  var downloaded = 0
  for name in names:
    let entry = m.files[name]
    let dest = dir / name & ".js"
    if fileExists(dest):
      try:
        if verifySha(readFile(dest), entry.sha256):
          continue
      except IOError:
        discard
    let url = base & "/" & refUsed & "/" & stdJsPath & "/" & entry.file
    let code = curlGet(url)
    if not verifySha(code, entry.sha256):
      raise newException(IOError, "checksum mismatch: \"" & entry.file &
        "\" (ref " & refUsed & ")")
    writeFile(dest, code)
    inc downloaded
  var stored: JsonNode
  try:
    stored = parseJson(src)
  except CatchableError as e:
    raise newException(IOError, "manifest: invalid JSON (" & e.msg & ")")
  stored["ref"] = %refUsed
  writeFile(stdManifestPath(home), $stored)
  (m.version, refUsed, downloaded,
    localFound and local.version == m.version and downloaded == 0)

proc stdStatus*(home = carneHome()):
    tuple[found: bool, version, refUsed: string,
      entries: seq[tuple[name, file: string, present: bool]]] =
  ## Store inventory for `carne std list`.
  let (found, m) = readLocalManifest(home)
  if not found:
    return (false, "", "", @[])
  var entries: seq[tuple[name, file: string, present: bool]] = @[]
  var names: seq[string] = @[]
  for name in m.files.keys:
    names.add(name)
  for name in names:
    entries.add((name, m.files[name].file,
      fileExists(stdJsStore(home) / name & ".js")))
  (true, m.version, m.refUsed, entries)

proc stdRequireImpl(ctx: JSContextRef; spec, name: string;
    home: string; exception: ptr JSValueRef): JSValueRef =
  ## modules.stdRequireHook body: loads store files, hints on
  ## well-known misses, keeps the unknown-module error otherwise.
  let path = stdJsStore(home) / name & ".js"
  if not fileExists(path):
    if isKnownJs(name, home):
      throwError(ctx, "require: \"" & spec & "\" is not installed" &
        " (run `carne std init`)", exception)
    else:
      throwError(ctx, "require: unknown module \"" & spec & "\"",
        exception)
    return nil
  loadJsFile(ctx, currentRt(), spec, path, exception)

proc initStdDispatcher*(home = carneHome()) =
  ## Wires the std/ fallback into modules (binary top level, or tests
  ## with a temp home seeded with fixture .js files).
  let h = home
  modules.stdRequireHook =
    proc(ctx: JSContextRef; spec, name: string;
        exception: ptr JSValueRef): JSValueRef {.closure.} =
      stdRequireImpl(ctx, spec, name, h, exception)
