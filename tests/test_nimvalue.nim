import std/os
import std/strutils
import std/tables
import unittest

import javascriptcore

import pkg/openparser/json

import carne
import carne/modules
import carne/pkg/stdsync
import carne/std/diff
import carne/std/env
import carne/std/http
import carne/std/qr
import carne/std/sql

let stdHome = getTempDir() / "carne_std_nimvalue"
removeDir(stdHome)
createDir(stdJsStore(stdHome))
copyFile(currentSourcePath.parentDir() / ".." / "src" / "carne" /
  "std" / "js" / "colors.js", stdJsStore(stdHome) / "colors.js")
initStdDispatcher(stdHome)

registerStd("std/diff", diff.install)
registerStd("std/env", env.install)
registerStd("std/http", http.install)
registerStd("std/qr", qr.install)
registerStd("std/sql", sql.install)

test "jsTypeName maps kinds to JS names":
  check jsTypeName(nvkUndefined) == "undefined"
  check jsTypeName(nvkNull) == "null"
  check jsTypeName(nvkBool) == "boolean"
  check jsTypeName(nvkInt) == "number"
  check jsTypeName(nvkFloat) == "number"
  check jsTypeName(nvkString) == "string"
  check jsTypeName(nvkArray) == "object"
  check jsTypeName(nvkObject) == "object"
  check jsTypeName(nvkFunction) == "function"
  check jsTypeName(nvkSymbol) == "symbol"
  check jsTypeName(nvkBigInt) == "bigint"

test "fromJsonNode and toJsonNode roundtrip":
  let node = fromJsonNode(%*{"a": 1, "b": [true, "x"], "c": nil})
  check node.kind == nvkObject
  check node.get("a", "t").asInt("t") == 1
  check toJsonNode(node) == %*{"a": 1, "b": [true, "x"], "c": nil}

test "toJsonNode rejects non-JSON kinds":
  expect CatchableError:
    discard toJsonNode(NimValue(kind: nvkUndefined))
  expect CatchableError:
    discard toJsonNode(NimValue(kind: nvkFunction, raw: nil))
  expect CatchableError:
    discard toJsonNode(NimValue(kind: nvkFloat, f: 0.0 / 0.0))

test "accessors are strict":
  let s = NimValue(kind: nvkString, s: "hi")
  check s.asString("t") == "hi"
  expect CatchableError:
    discard s.asInt("t")
  let f = NimValue(kind: nvkFloat, f: 2.5)
  check f.asFloat("t") == 2.5
  expect CatchableError:
    discard f.asInt("t")
  let whole = NimValue(kind: nvkFloat, f: 3.0)
  check whole.asInt("t") == 3
  let o = NimValue(kind: nvkObject,
    obj: {"k": NimValue(kind: nvkBool, b: true)}.toOrderedTable)
  check o.hasKey("k")
  check not o.hasKey("missing")
  check o.get("k", "t").asBool("t")
  expect CatchableError:
    discard o.get("missing", "t")
  check o.getOpt("missing",
    NimValue(kind: nvkInt, i: 7)).asInt("t") == 7

proc snap(code: string): NimValue =
  ## Evaluates code in a scratch context and snapshots the result.
  withGlobalContext(ctx):
    var ex: JSValueRef = nil
    let v = evalScript(ctx, code, exception = ex)
    check ex == nil
    var err = ""
    let nv = fromJS(ctx, v, err)
    check err == ""
    return nv

test "fromJS snapshots primitives with int/float split":
  check snap("42").kind == nvkInt
  check snap("42").i == 42
  check snap("4.5").kind == nvkFloat
  check snap("'hi'").s == "hi"
  check snap("true").b == true
  check snap("null").kind == nvkNull
  check snap("undefined").kind == nvkUndefined
  check snap("1e21").kind == nvkFloat

test "fromJS snapshots arrays and objects deeply":
  let v = snap("({a: 1, b: [1, 'x', null]})")
  check v.kind == nvkObject
  check v.get("a", "t").i == 1
  check v.get("b", "t").asArray("t").len == 3
  check v.get("b", "t").asArray("t")[2].kind == nvkNull

test "fromJS keeps functions as raw refs":
  let v = snap("((x) => x)")
  check v.kind == nvkFunction
  check v.raw != nil

test "toJS roundtrips a snapshot":
  withGlobalContext(ctx):
    var t = initOrderedTable[string, NimValue]()
    t["n"] = NimValue(kind: nvkInt, i: 3)
    t["s"] = NimValue(kind: nvkString, s: "x")
    let v = NimValue(kind: nvkObject, obj: t)
    let j = toJS(ctx, v)
    check j != nil
    check valueToString(ctx, j) == "[object Object]"
    var err = ""
    let back = fromJS(ctx, j, err)
    check err == ""
    check toJsonNode(back) == toJsonNode(v)

test "toJS preserves NaN through JSC":
  withGlobalContext(ctx):
    let j = toJS(ctx, NimValue(kind: nvkFloat, f: 0.0 / 0.0))
    check j != nil
    var err = ""
    let back = fromJS(ctx, j, err)
    check err == ""
    check back.kind == nvkFloat

test "colors still parses via NimValue arg reader":
  check runCode(
    "JSON.stringify(require('std/colors').parse('red'))") ==
    """{"r":255,"g":0,"b":0,"a":1}"""
  check runCode(
    "const c = require('std/colors');" &
    "c.toHex(c.parse('#333'))") == "#333333"

test "colors rejects mistyped args with type errors":
  try:
    discard runCode("require('std/colors').parse(42)")
    fail()
  except CarneError as e:
    check "expected `string`" in e.msg
  try:
    discard runCode("require('std/colors').toHex(42)")
    fail()
  except CarneError as e:
    check "must be an {r, g, b, a?} object" in e.msg

test "sql rejects non-strings with a type error":
  try:
    discard runCode("require('std/sql').sqlite.parse(42)")
    fail()
  except CarneError as e:
    check "expected `string`" in e.msg

test "setTimeout with a non-function throws instead of crashing":
  try:
    discard runCode("setTimeout(42, 10)")
    fail()
  except CarneError as e:
    check "expected `function`" in e.msg

test "serve with a non-function handler throws instead of crashing":
  try:
    discard runCode("require('std/http').serve(18301, 42)")
    fail()
  except CarneError as e:
    check "expected `function`" in e.msg

test "strict scalars reject mistyped args":
  try:
    discard runCode("require('std/env').getEnv(42)")
    fail()
  except CarneError as e:
    check "expected `string`" in e.msg
  try:
    discard runCode("require('std/env').putEnv('K', 42)")
    fail()
  except CarneError as e:
    check "expected `string`" in e.msg
  try:
    discard runCode("require('std/env').exit('x')")
    fail()
  except CarneError as e:
    check "expected `number`" in e.msg

test "options readers ignore extra keys and undefined":
  check runCode(
    "JSON.stringify(require('std/diff').diff('a', 'b', " &
    "{context: undefined, junk: 'x'}).stats)") ==
    runCode(
    "JSON.stringify(require('std/diff').diff('a', 'b').stats)")
  check runCode(
    "require('std/qr').encode('hi', {ecLevel: 'H', junk: 1}).size") ==
    runCode("require('std/qr').encode('hi', {ecLevel: 'H'}).size")

test "options bags reject arrays":
  try:
    discard runCode("require('std/diff').diff('a', 'b', [3])")
    fail()
  except CarneError as e:
    check "expected `object`" in e.msg

test "type mismatch carries the JSDoc block first":
  try:
    discard runCode("require('std/env').getEnv(42)")
    fail()
  except CarneError as e:
    check "/*\n * env.getEnv(\"HOME\") -> string | undefined\n */" in e.msg
    check "type mismatch parameter: `key`. Got `number`," &
      " expected `string`" in e.msg
    check e.msg.find("/*") < e.msg.find("type mismatch")

test "arity errors carry the JSDoc block after the message":
  try:
    discard runCode("require('std/env').getEnv()")
    fail()
  except CarneError as e:
    check "getEnv: expected 1 argument(s), got 0" in e.msg
    check "/*\n * env.getEnv(\"HOME\") -> string | undefined\n */" in e.msg
    check e.msg.find("got 0") < e.msg.find("/*")

test "optional params keep their defaults":
  check runCode(
    "const c = require('std/colors');" &
    "const a = c.parse('red'); const b = c.parse('blue');" &
    "JSON.stringify(c.mix(a, b))") ==
    runCode(
    "const c = require('std/colors');" &
    "const a = c.parse('red'); const b = c.parse('blue');" &
    "JSON.stringify(c.mix(a, b, 50))")

test "fromJS rejects oversized arrays":
  block:
    withGlobalContext(ctx):
      var ex: JSValueRef = nil
      let v = evalScript(ctx, "new Array(100001)", exception = ex)
      check ex == nil
      var err = ""
      discard fromJS(ctx, v, err)
      check err == "array is too large (100001 elements, cap 100000)"
  block:
    withGlobalContext(ctx):
      var ex: JSValueRef = nil
      let v = evalScript(ctx, "[1, 2, 3]", exception = ex)
      check ex == nil
      var err = ""
      check fromJS(ctx, v, err).asArray("t").len == 3
      check err == ""

test "lazy field access reads single props":
  withGlobalContext(ctx):
    var ex: JSValueRef = nil
    let obj = evalScript(ctx, "({a: 1, b: {c: 'x'}})", exception = ex)
    check ex == nil
    var err = ""
    check getField(ctx, obj, "a", err).i == 1
    check err == ""
    check getField(ctx, obj, "missing", err).kind == nvkUndefined
    check err == ""
    check getField(ctx, obj, "b", err).get("c", "t").s == "x"
    check err == ""
