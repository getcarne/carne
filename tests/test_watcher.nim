import std/os
import std/strutils
import unittest

import carne
import carne/modules
import carne/std/watcher
import carne/std/os as carneos

registerStd("std/watcher", watcher.install)
registerStd("std/os", carneos.install)

proc tmpPath(name: string): string =
  getTempDir() / ("carne-watcher-" & name & ".txt")

test "watcher fires on file write and closes":
  let path = tmpPath("async")
  writeFile(path, "start\n")
  try:
    let got = runCode(
      "const watcher = require('std/watcher'); " &
      "const os = require('std/os'); " &
      "let done; " &
      "const gate = new Promise((r) => { done = r; }); " &
      "const w = watcher.watch('" & path & "', (events) => { " &
      "w.close(); w.close(); done(events.join(',')); }); " &
      "setTimeout(() => { os.appendFile('" & path & "', 'more\\n'); }, 50); " &
      "gate")
    check got.contains("modified")
  finally:
    removeFile(path)

test "watchOnce blocks until a write lands":
  let path = tmpPath("once")
  writeFile(path, "start\n")
  try:
    check runCode(
      "const watcher = require('std/watcher'); " &
      "const os = require('std/os'); " &
      "setTimeout(() => { os.appendFile('" & path & "', 'more\\n'); }, 50); " &
      "watcher.watchOnce('" & path & "', 4000).length > 0") == "true"
  finally:
    removeFile(path)

test "watcher validates input":
  expect CarneError:
    discard runCode("require('std/watcher').watch('', () => {})")
  expect CarneError:
    discard runCode("require('std/watcher').watch('/nope-missing-xyz', () => {})")
  expect CarneError:
    discard runCode(
      "require('std/watcher').watchOnce('/nope-missing-xyz', 100)")
