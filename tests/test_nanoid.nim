import std/sets
import unittest

import carne
import carne/modules
import carne/std/nanoid

registerStd("std/nanoid", nanoid.install)

test "nanoid defaults to 21 url chars":
  let id = runCode("require('std/nanoid').nanoid()")
  check id.len == 21
  var ok = true
  for c in id:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
      ok = false
  check ok

test "destructured nanoid respects size":
  check runCode(
    "const {nanoid} = require('std/nanoid'); nanoid(10).length") == "10"

test "customAlphabet draws from the given alphabet":
  let id = runCode(
    "require('std/nanoid').customAlphabet('abc123', 32)")
  check id.len == 32
  var chars = initHashSet[char]()
  for c in id:
    chars.incl(c)
  check chars <= ['a', 'b', 'c', '1', '2', '3'].toHashSet()

test "nanoidNonSecure yields the requested length":
  check runCode(
    "require('std/nanoid').nanoidNonSecure(12).length") == "12"

test "constants expose the defaults":
  check runCode("require('std/nanoid').defaultSize") == "21"
  check runCode("require('std/nanoid').urlAlphabet.length") == "64"

test "nanoid rejects bad sizes and alphabets":
  expect CarneError:
    discard runCode("require('std/nanoid').nanoid(0)")
  expect CarneError:
    discard runCode("require('std/nanoid').nanoid(2048)")
  expect CarneError:
    discard runCode("require('std/nanoid').customAlphabet('x', 8)")
  expect CarneError:
    discard runCode("require('std/nanoid').customAlphabet('abc', 0)")
