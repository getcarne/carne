import std/os
import std/strutils
import unittest

import carne
import carne/cli
import carne/modules
import carne/std/test as stdtest

registerStd("std/test", stdtest.install)

test "expect matchers pass":
  check runCode(
    "const {expect} = require('std/test');" &
    "expect(1 + 1).toBe(2)") == ""
  check runCode(
    "const {expect} = require('std/test');" &
    "expect({a: [1, 2]}).toEqual({a: [1, 2]});" &
    "expect(1).not.toBe(2);" &
    "expect(0).toBeFalsy();" &
    "expect('hi').toBeTruthy();" &
    "expect(null).toBeNull();" &
    "expect(undefined).toBeUndefined();" &
    "expect(1).toBeDefined();" &
    "expect(0 / 0).toBeNaN();" &
    "expect([1, 2]).toContain(2);" &
    "expect('hi there').toContain('there');" &
    "expect('abc123').toMatch(/123/);" &
    "expect(3).toBeGreaterThan(2);" &
    "expect(2).toBeLessThan(3);" &
    "expect(3).toBeGreaterThanOrEqual(3);" &
    "expect(2).toBeLessThanOrEqual(2);" &
    "expect(0.1 + 0.2).toBeCloseTo(0.3);" &
    "expect(() => { throw new Error('boom x'); }).toThrow('boom');") == ""

test "expect matchers fail":
  expect CarneError:
    discard runCode(
      "require('std/test').expect(1).toBe(2)")
  expect CarneError:
    discard runCode(
      "require('std/test').expect({a: 1}).toEqual({a: 2})")
  expect CarneError:
    discard runCode(
      "require('std/test').expect(1).not.toBe(1)")
  expect CarneError:
    discard runCode(
      "require('std/test').expect([1]).toContain(2)")
  expect CarneError:
    discard runCode(
      "require('std/test').expect(() => {}).toThrow()")
  expect CarneError:
    discard runCode(
      "require('std/test').expect(1).toBeGreaterThan(2)")

test "assert style passes":
  check runCode(
    "const {assert} = require('std/test');" &
    "assert(true);" &
    "assert.ok(1);" &
    "assert.equal(1, '1');" &
    "assert.strictEqual(1, 1);" &
    "assert.deepEqual({a: [1]}, {a: [1]});" &
    "assert.throws(() => { throw new Error('boom'); }, 'boom');" &
    "assert.doesNotThrow(() => {});") == ""

test "assert style fails":
  expect CarneError:
    discard runCode("require('std/test').assert(false)")
  expect CarneError:
    discard runCode("require('std/test').assert.strictEqual(1, '1')")
  expect CarneError:
    discard runCode("require('std/test').assert.deepEqual([1], [2])")
  expect CarneError:
    discard runCode("require('std/test').assert.fail('nope')")
  expect CarneError:
    discard runCode(
      "require('std/test').assert.throws(() => {}, 'boom')")

test "registration errors":
  expect CarneError:
    discard runCode("require('std/test').test('only-name')")
  expect CarneError:
    discard runCode("require('std/test').test(42, () => {})")
  expect CarneError:
    discard runCode("require('std/test').test('x', 'not-fn')")
  expect CarneError:
    discard runCode("require('std/test').describe('x')")
  expect CarneError:
    discard runCode("require('std/test').expect()")

test "passing run exits clean":
  check runCode(
    "const t = require('std/test');" &
    "t.test('one', () => { t.expect(1).toBe(1); });" &
    "t.describe('g', () => {" &
    "  t.it('two', () => { t.expect(2).toBe(2); });" &
    "});") == ""

test "failing run raises with names":
  var raised = false
  try:
    discard runCode(
      "const t = require('std/test');" &
      "t.test('fine', () => {});" &
      "t.describe('suite', () => {" &
      "  t.test('bad', () => { t.expect(1).toBe(2); });" &
      "});")
  except CarneError as e:
    raised = true
    check "test run failed" in e.msg
    check "suite > bad" in e.msg
  check raised

test "async cases are awaited":
  check runCode(
    "const t = require('std/test');" &
    "t.test('late', async () => {" &
    "  const v = await new Promise((r) => setTimeout(() => r(41), 5));" &
    "  t.expect(v + 1).toBe(42);" &
    "});") == ""
  var raised = false
  try:
    discard runCode(
      "const t = require('std/test');" &
      "t.test('late-bad', async () => {" &
      "  await new Promise((r) => setTimeout(r, 5));" &
      "  t.expect(1).toBe(2);" &
      "});")
  except CarneError as e:
    raised = true
    check "late-bad" in e.msg
  check raised

test "stats reflect the run":
  check runCode("(async () => {" &
    "const t = require('std/test');" &
    "t.test('one', () => { t.expect(1).toBe(1); });" &
    "t.test('two', () => { t.expect(2).toBe(2); });" &
    "await new Promise((r) => setTimeout(r, 50));" &
    "return JSON.stringify(t.stats());" &
    "})()") ==
    "{\"total\":2,\"passed\":2,\"failed\":0,\"done\":true}"

test "throwing describe becomes a failing setup case":
  var raised = false
  try:
    discard runCode(
      "const t = require('std/test');" &
      "t.describe('broken', () => { throw new Error('setup blew up'); });")
  except CarneError as e:
    raised = true
    check "broken > (setup)" in e.msg
  check raised

test "findTestFiles discovers nested *.test.js only":
  let base = getTempDir() / "carne_test_discovery"
  removeDir(base)
  createDir(base / "tests" / "sub" / "deep")
  writeFile(base / "tests" / "a.test.js", "x")
  writeFile(base / "tests" / "sub" / "b.test.js", "x")
  writeFile(base / "tests" / "sub" / "deep" / "c.test.js", "x")
  writeFile(base / "tests" / "helper.js", "x")
  writeFile(base / "tests" / "old.nim", "x")
  check findTestFiles(base / "tests") == @[
    base / "tests" / "a.test.js",
    base / "tests" / "sub" / "b.test.js",
    base / "tests" / "sub" / "deep" / "c.test.js"]
  check findTestFiles(base / "missing") == newSeq[string]()
  removeDir(base)

test "resolveTestArg is file-only":
  let base = getTempDir() / "carne_test_resolve"
  removeDir(base)
  createDir(base / "tests" / "sub")
  writeFile(base / "tests" / "a.test.js", "x")
  writeFile(base / "tests" / "sub" / "b.test.js", "x")
  writeFile(base / "tests" / "helper.js", "x")
  let r = base / "tests"
  check resolveTestArg("a", r) == r / "a.test.js"
  check resolveTestArg("sub/b", r) == r / "sub" / "b.test.js"
  check resolveTestArg(r / "a.test.js", r) == r / "a.test.js"
  check resolveTestArg("helper", r) == r / "helper.js"
  check resolveTestArg("missing", r) == ""
  check resolveTestArg("sub", r) == ""
  removeDir(base)

test "examples/test.js runs green":
  let demo = currentSourcePath.parentDir() / ".." / "examples" / "test.js"
  let res = runFileEx(demo)
  check res.code == 0
