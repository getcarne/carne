import std/[os, osproc, strutils, sequtils, sets]
import unittest

import carne
import carne/modules
import carne/runtime
import carne/std/path

registerStd("std/path", path.install)

test "pure-sync scripts never create an event loop":
  discard runCode("1 + 1")
  check loopCreatedLastRun == false
  discard runCode("require('std/path').join(['a','b'])")
  check loopCreatedLastRun == false

test "timers create the loop lazily":
  discard runCode("setTimeout(() => {}, 1)")
  check loopCreatedLastRun == true
  discard runCode("2 + 2")
  check loopCreatedLastRun == false

test "require cache returns one instance per run, fresh per run":
  check runCode("require('std/path') === require('std/path')") == "true"
  check runCode(
    "globalThis.__m = require('std/path'); String(__m === require('std/path'))"
  ) == "true"
  # a new run does not see the previous run's globals
  check runCode("typeof globalThis.__m") == "undefined"

proc stripAnsi(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e':
      while i < s.len and s[i] != 'm': inc i
    else: result.add s[i]
    inc i

proc normLines(lines: seq[string]): HashSet[string] =
  for l in lines:
    let t = l.strip().splitWhitespace().join(" ")
    if t.len > 0: result.incl t

test "top-level gen help and `gen` sub-help list the same commands and flags":
  ## Needs a built binary (`scripts/build.sh` or `clue build`). CI runs
  ## tests without one, and unittest's skip() does not stop the test
  ## body, so the exec lives behind an explicit guard.
  let bin = absolutePath("bin" / "carne")
  var top, sub: seq[string]
  var ran = false
  if fileExists(bin):
    try:
      top = stripAnsi(execProcess(bin, args = ["--help"],
        options = {poStdErrToStdOut})).splitLines
      sub = stripAnsi(execProcess(bin, args = ["gen"],
        options = {poStdErrToStdOut})).splitLines
      ran = true
    except OSError:
      discard
  if not ran:
    skip()
  else:
    var inGen = false
    var topGen: seq[string]
    for l in top:
      if l.strip().endsWith("Generating:"): inGen = true; continue
      if inGen:
        if l.strip().len == 0: break
        topGen.add l.replace("gen ", "")
    let subGen = sub.filterIt(not it.startsWith("usage"))
    check normLines(topGen).len > 0
    check normLines(topGen) == normLines(subGen)
