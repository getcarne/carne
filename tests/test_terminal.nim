import std/os
import unittest

import carne
import carne/modules
import carne/std/terminal

registerStd("std/terminal", terminal.install)

proc withEnv(key, val: string; body: proc()) =
  ## Runs body with an env override, restoring afterwards even on
  ## failure (a leaked NO_COLOR would poison every later color test).
  let had = existsEnv(key)
  let old = getEnv(key)
  putEnv(key, val)
  try:
    body()
  finally:
    if had:
      putEnv(key, old)
    else:
      delEnv(key)

test "colors wrap when enabled":
  withEnv("TERM", "xterm"):
    doAssert not existsEnv("NO_COLOR")
    check runCode("require('std/terminal').green('ok')") ==
      "\u001b[32mok\u001b[0m"
    check runCode("require('std/terminal').red('x')") ==
      "\u001b[31mx\u001b[0m"
    check runCode("require('std/terminal').bold('x')") ==
      "\u001b[1mx\u001b[0m"
    check runCode("require('std/terminal').colorEnabled()") == "true"

test "colors die under NO_COLOR":
  withEnv("NO_COLOR", "1"):
    check runCode("require('std/terminal').green('ok')") == "ok"
    check runCode("require('std/terminal').colorEnabled()") == "false"

test "colors die under TERM=dumb":
  withEnv("TERM", "dumb"):
    check runCode("require('std/terminal').red('x')") == "x"
    check runCode("require('std/terminal').colorEnabled()") == "false"

test "stripAnsi removes codes":
  withEnv("TERM", "xterm"):
    check runCode(
      "require('std/terminal').stripAnsi(require('std/terminal').red('x'))") ==
      "x"
    check runCode("require('std/terminal').stripAnsi('plain')") == "plain"
    check runCode(
      "require('std/terminal').stripAnsi('\u001b[1mA\u001b[0m \u001b[32mB\u001b[0m')") ==
      "A B"

test "write and size read sane":
  check runCode("require('std/terminal').write('')") == ""
  check runCode("Number(require('std/terminal').columns()) > 0") == "true"
  check runCode("Number(require('std/terminal').rows()) > 0") == "true"
  check runCode(
    "['true','false'].indexOf(String(require('std/terminal').isTTY())) >= 0") ==
    "true"

test "parseArgs defaults to script argv":
  check runCode("JSON.stringify(require('std/terminal').parseArgs())",
    argv = @["carne", "s.js", "--port", "3000", "pos"]) ==
    "{\"port\":\"3000\",\"_\":[\"pos\"]}"

test "parseArgs longs, shorts, no-, separator":
  check runCode(
    "const p = require('std/terminal').parseArgs(" &
    "['--port','3000','-v','--no-cache','--','--notflag']," &
    "{boolean: ['v','cache'], string: ['port']}); " &
    "JSON.stringify([p.port, p.v, p.cache, p._])") ==
    "[\"3000\",true,false,[\"--notflag\"]]"

test "parseArgs short attach and equals":
  check runCode(
    "const p = require('std/terminal').parseArgs(['-n5'], " &
    "{string: ['n']}); p.n") == "5"
  check runCode(
    "const p = require('std/terminal').parseArgs(['--k='], " &
    "{string: ['k']}); p.k === ''") == "true"
  check runCode(
    "const p = require('std/terminal').parseArgs(['-abc']); " &
    "JSON.stringify([p.a, p.b, p.c])") == "[true,true,true]"

test "parseArgs aliases, defaults, positionals":
  check runCode(
    "const t = require('std/terminal'); const p = t.parseArgs(['run','x.js'], " &
    "{alias: {p: 'port'}, default: {port: '8080'}, positional: ['cmd']}); " &
    "JSON.stringify([p.cmd, p.port, p.p, p._])") ==
    "[\"run\",\"8080\",\"8080\",[\"run\",\"x.js\"]]"
  check runCode(
    "const p = require('std/terminal').parseArgs(['-p','80'], " &
    "{alias: {p: 'port'}}); JSON.stringify([p.port, p.p])") ==
    "[\"80\",\"80\"]"

test "parseArgs never coerces numbers":
  check runCode(
    "const p = require('std/terminal').parseArgs(['--n','42']); " &
    "typeof p.n") == "string"
  check runCode(
    "const p = require('std/terminal').parseArgs(['--n','42']); p.n") == "42"

test "parseArgs validates shapes":
  expect CarneError:
    discard runCode("require('std/terminal').parseArgs('nope')")
  expect CarneError:
    discard runCode("require('std/terminal').parseArgs([], 'nope')")
  expect CarneError:
    discard runCode(
      "require('std/terminal').parseArgs([], {boolean: 'v'})")
  expect CarneError:
    discard runCode(
      "require('std/terminal').parseArgs([42])")
  expect CarneError:
    discard runCode(
      "require('std/terminal').parseArgs([], {default: {n: [1]}})")
