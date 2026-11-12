import unittest

import carne
import carne/modules
import carne/std/css

registerStd("std/css", css.install)

test "css parse ruleset":
  check runCode(
    "JSON.stringify(require('std/css').parse('a { color: red; }')" &
    ".rules[0].declarations[0])") ==
    """{"kind":"Declaration","property":"color","value":"red",""" &
    """"important":false}"""
  check runCode(
    "JSON.stringify(require('std/css').parse('.x#f { margin: 0; }')" &
    ".rules[0].selectors[0])") ==
    """{"kind":"Selector","selectorKind":"Class","parts":[".x","#f"]}"""
  check runCode(
    "require('std/css').parse('.x, #f { margin: 0; }')" &
    ".rules[0].selectors.length") == "2"

test "css parse important and atrule":
  check runCode(
    "require('std/css').parse('a { margin: 0 !important; }')" &
    ".rules[0].declarations[0].important") == "true"
  check runCode(
    "require('std/css').parse('@media screen { a { color: blue; } }')" &
    ".rules[0].name") == "media"

test "css validate clean sheet is empty":
  check runCode(
    "JSON.stringify(require('std/css').validate('a { color: red; }'))") ==
    "[]"

test "css validate flags unknown property":
  check runCode(
    "JSON.stringify(require('std/css').validate('a { bogus: 1; }'))") ==
    """[{"property":"bogus","value":"1","valid":false,""" &
    """"errors":[{"message":"Unknown property","property":"bogus",""" &
    """"value":"1"}]}]"""

test "css validate flags bad value but allows custom props":
  check runCode(
    "JSON.stringify(require('std/css').validate('a { color: 12345; }'))") ==
    """[{"property":"color","value":"12345","valid":false,""" &
    """"errors":[{"message":"Value does not match property syntax",""" &
    """"property":"color","value":"12345"}]}]"""
  check runCode(
    "JSON.stringify(require('std/css').validate('a { --brand: #fff; }'))") ==
    "[]"

test "css stringify roundtrip":
  check runCode(
    "require('std/css').stringify(require('std/css').parse(" &
    "'a { color: red; }')).includes('color: red')") == "true"
  check runCode(
    "JSON.stringify(require('std/css').parse(require('std/css')" &
    ".stringify(require('std/css').parse('a { color: red; }')))" &
    ".rules[0].declarations[0])") ==
    """{"kind":"Declaration","property":"color","value":"red",""" &
    """"important":false}"""

test "css stringify rejects bad input":
  expect CarneError:
    discard runCode("require('std/css').stringify({rules: [{kind: 'Nope'}]})")
