import std/options
import unittest

import carne
import carne/modules
import carne/bridge
import carne/std/terminal

registerStd("std/terminal", terminal.install)

template withOverride(v: bool; body: untyped) =
  ## Runs body with the CLI --isatty override forced, restoring
  ## afterwards even on failure.
  block:
    let oldOverride = colorTtyOverride
    colorTtyOverride = some(v)
    try:
      body
    finally:
      colorTtyOverride = oldOverride

const esc = "\u001b"

test "colors wrap when enabled":
  withOverride(true):
    check runCode("require('std/terminal').green('ok')") ==
      esc & "[32mok" & esc & "[0m"
    check runCode("require('std/terminal').red('x')") ==
      esc & "[31mx" & esc & "[0m"
    check runCode("require('std/terminal').bold('x')") ==
      esc & "[1mx" & esc & "[0m"
    check runCode("require('std/terminal').colorEnabled()") == "true"

test "colors die when disabled":
  withOverride(false):
    check runCode("require('std/terminal').green('ok')") == "ok"
    check runCode("require('std/terminal').red('x')") == "x"
    check runCode("require('std/terminal').colorEnabled()") == "false"

test "auto mode reports a bool":
  colorTtyOverride = none(bool)
  check runCode(
    "['true','false'].indexOf(String(require('std/terminal').colorEnabled())) >= 0") ==
    "true"

test "stripAnsi removes codes":
  withOverride(true):
    check runCode(
      "require('std/terminal').stripAnsi(require('std/terminal').red('x'))") ==
      "x"
    check runCode("require('std/terminal').stripAnsi('plain')") == "plain"
    check runCode("require('std/terminal').stripAnsi('" & esc &
      "[1mA" & esc & "[0m " & esc & "[32mB" & esc & "[0m')") == "A B"

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
