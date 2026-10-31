import std/os
import std/strutils
import std/tables
import unittest

import pkg/nimcypher/hash

import carne
import carne/modules
import carne/pkg/stdsync

proc fakeRepo(): tuple[base, home: string] =
  ## Builds a file:// registry: <tmp>/repo/main/src/carne/std/js/
  ## with manifest.json + a.js, plus an empty home dir.
  let base = getTempDir() / "carne_stdsync_repo"
  let home = getTempDir() / "carne_stdsync_home"
  removeDir(base)
  removeDir(home)
  let jsDir = base / "main" / "src" / "carne" / "std" / "js"
  createDir(jsDir)
  let body = "module.exports = {hello: function () { return \"hi\"; }};\n"
  writeFile(jsDir / "a.js", body)
  let manifest = "{\"version\": \"9.9.9\", \"files\": {\"a\": " &
    "{\"file\": \"a.js\", \"sha256\": \"" & sha256Hex(body) & "\"}}}"
  writeFile(jsDir / "manifest.json", manifest)
  result = (base: "file://" & base, home: home)

test "parseStdManifest reads versions and entries":
  let m = parseStdManifest("{\"version\": \"1.2.3\", \"files\": " &
    "{\"a\": {\"file\": \"a.js\", \"sha256\": \"abc\"}}}")
  check m.version == "1.2.3"
  check m.files["a"].file == "a.js"
  check m.files["a"].sha256 == "abc"

test "parseStdManifest rejects malformed input":
  expect ValueError:
    discard parseStdManifest("{nope")
  expect ValueError:
    discard parseStdManifest("{\"files\": {}}")
  expect ValueError:
    discard parseStdManifest("{\"version\": \"1\", \"files\": []}")
  expect ValueError:
    discard parseStdManifest(
      "{\"version\": \"1\", \"files\": {\"a\": {\"file\": \"a.js\"}}}")

test "local manifest is absent on fresh homes":
  let (found, _) = readLocalManifest(getTempDir() / "carne_stdsync_nobody")
  check not found

test "isKnownJs covers the fallback list":
  check isKnownJs("colors")
  check isKnownJs("str")
  check isKnownJs("test")
  check not isKnownJs("nope", getTempDir() / "carne_stdsync_nobody")

test "stdSync downloads and verifies from a registry":
  let (base, home) = fakeRepo()
  let r = stdSync(home, base)
  check r.version == "9.9.9"
  check r.refUsed == "main"
  check r.count == 1
  check readFile(stdJsStore(home) / "a.js").contains("hello")
  let s = stdStatus(home)
  check s.found
  check s.version == "9.9.9"
  check s.refUsed == "main"
  check s.entries == @[(name: "a", file: "a.js", present: true)]

test "stdSync rejects checksum mismatches":
  let (base, home) = fakeRepo()
  let jsDir = base.substr("file://".len) / "main" / "src" / "carne" /
    "std" / "js"
  writeFile(jsDir / "manifest.json",
    "{\"version\": \"9.9.9\", \"files\": {\"a\": " &
    "{\"file\": \"a.js\", \"sha256\": \"" & repeat('0', 64) & "\"}}}")
  var raised = false
  try:
    discard stdSync(home, base)
  except IOError as e:
    raised = true
    check "checksum mismatch" in e.msg
  check raised
  check not fileExists(stdJsStore(home) / "a.js")

test "stdSync fails clearly when unreachable":
  var raised = false
  try:
    discard stdSync(getTempDir() / "carne_stdsync_off",
      "file:///nonexistent-carne-repo")
  except IOError as e:
    raised = true
    check "download failed" in e.msg
  check raised

test "dispatcher loads store files and hints on misses":
  let home = getTempDir() / "carne_stdsync_dispatch"
  removeDir(home)
  createDir(stdJsStore(home))
  writeFile(stdJsStore(home) / "a.js",
    "module.exports = {hello: function () { return \"hi\"; }};\n")
  initStdDispatcher(home)
  check runCode("require('std/a').hello()") == "hi"
  var hinted = false
  try:
    discard runCode("require('std/str')")
  except CarneError as e:
    hinted = true
    check "carne std init" in e.msg
  check hinted
  var unknown = false
  try:
    discard runCode("require('std/nope')")
  except CarneError as e:
    unknown = true
    check "unknown module" in e.msg
  check unknown
