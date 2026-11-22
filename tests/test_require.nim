import std/strutils
import unittest

import javascriptcore
import carne
import carne/modules
import carne/bridge
import carne/std/env

registerStd("std/env", env.install)

init proc(module: Module) =
  exportObject:
    module.exportClass Point(value: int):
      let point = newObject(ctx)
      setProp(ctx, point, "value", toJS(ctx, value), exception)
      point

registerStd("std/point", install)

test "require unknown module raises":
  expect CarneError:
    discard runCode("require('std/nope')")

test "require unknown module message":
  try:
    discard runCode("require('std/nope')")
    fail()
  except CarneError as e:
    check "unknown module" in e.msg

test "require caches instances":
  check runCode("require('std/env') === require('std/env')") == "true"

test "require needs exactly one arg":
  expect CarneError:
    discard runCode("require()")

test "object completion does not crash thenable check":
  check runCode("JSON.stringify(({a: 1}))") ==
    """{"a":1}"""
  check runCode("JSON.stringify([1, 2])") == "[1,2]"
  check runCode("typeof ({})") == "object"

test "non-callable then is not unwrapped":
  check runCode("JSON.stringify(({then: 42}))") == """{"then":42}"""

test "top-level promise completion unwraps":
  check runCode("Promise.resolve(5)") == "5"
  check runCode("(async () => 7)()") == "7"
  expect CarneError:
    discard runCode("Promise.reject(new Error('nope'))")

test "top-level await works in scripts":
  check runCode(
    "const value = await Promise.resolve(7); " &
    "if (value !== 7) throw new Error('bad value')") == "undefined"
  check runCode(
    "const value = `value:${await Promise.resolve(7)}`; " &
    "if (value !== 'value:7') throw new Error('bad template')") ==
    "undefined"
  check runCode(
    "await new Promise(resolve => setTimeout(resolve, 1)); " &
    "if (false) throw new Error('unreachable')") == "undefined"
  expect CarneError:
    discard runCode("await Promise.reject(new Error('nope'))")

test "module exportClass creates checked constructors":
  check runCode(
    "const {Point} = require('std/point'); " &
    "const p = new Point(42); (p instanceof Point) + ':' + p.value") ==
    "true:42"
  check runCode(
    "try { new (require('std/point').Point)(); 'no' } " &
    "catch (e) { e.constructor.name + ':' + e.message.split('\\n')[0] }") ==
    "TypeError:Point: expected 1 argument(s), got 0"
