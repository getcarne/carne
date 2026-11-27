import std/os
import std/strutils
import unittest

import carne
import carne/modules
import carne/std/watcher
import carne/std/os as carneos
import carne/std/http as carnehttp

registerStd("std/watcher", watcher.install)
registerStd("std/os", carneos.install)
registerStd("std/http", carnehttp.install)

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

test "watchOnce times out with a clear error":
  let path = tmpPath("timeout")
  writeFile(path, "start\n")
  try:
    var msg = ""
    try:
      discard runCode(
        "require('std/watcher').watchOnce('" & path & "', 150)")
    except CarneError as e:
      msg = e.msg
    check "timed out after 150ms" in msg
  finally:
    removeFile(path)

test "watch is rejected in http workers":
  check runCode(
    "const http = require('std/http'); " &
    "http.serve(18130, {workers: 1}, (req) => { " &
    "try { " &
    "require('std/watcher').watch('/tmp/carne_test_w.txt', () => {}); " &
    "} catch (e) { return 'threw'; } return 'no-throw'; }); " &
    "(async () => { " &
    "if (process.isWorker) return 'worker'; " &
    "const res = await http.fetch('http://127.0.0.1:18130/'); " &
    "http.close(18130); " &
    "return res.body; })()") == "threw"

test "watchOnce is rejected in http workers":
  check runCode(
    "const http = require('std/http'); " &
    "http.serve(18131, {workers: 1}, (req) => { " &
    "try { " &
    "require('std/watcher').watchOnce('/tmp/carne_test_w.txt', 100); " &
    "} catch (e) { return 'threw'; } return 'no-throw'; }); " &
    "(async () => { " &
    "if (process.isWorker) return 'worker'; " &
    "const res = await http.fetch('http://127.0.0.1:18131/'); " &
    "http.close(18131); " &
    "return res.body; })()") == "threw"

test "watchOnce rejects non-positive timeouts":
  expect CarneError:
    discard runCode("require('std/watcher').watchOnce('/tmp', 0)")

test "close is final and idempotent, no callback after close":
  let path = tmpPath("final")
  writeFile(path, "start\n")
  try:
    check runCode(
      "const watcher = require('std/watcher'); " &
      "const os = require('std/os'); " &
      "let fired = 0; " &
      "const w = watcher.watch('" & path & "', () => { fired++; }); " &
      "const a = w.close(); const b = w.close(); " &
      "os.appendFile('" & path & "', 'x'); " &
      "new Promise(r => setTimeout(() => r(a + ',' + b + ',' + fired), 150))"
    ) == "true,true,0"
  finally:
    removeFile(path)
