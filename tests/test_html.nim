import unittest

import carne
import carne/modules
import carne/std/html

registerStd("std/html", html.install)

test "html parse element shape":
  let res = runCode(
    "JSON.stringify(require('std/html').parse(" &
    "'<p>hi <b>ada</b></p>'))")
  check res == """[{"tag":"p","attrs":{},"children":["hi ",{"tag":"b","attrs":{},"children":["ada"]}]}]"""

test "html innerText doc and node":
  check runCode(
    "const h = require('std/html');" &
    "h.innerText(h.parse('<p>hi <b>ada</b></p>'))") == "hi ada"
  check runCode(
    "const h = require('std/html');" &
    "h.innerText(h.parse('<p>hi <b>ada</b></p>')[0].children[1])") ==
    "ada"

test "html inline and block helpers":
  check runCode(
    "const h = require('std/html');" &
    "[h.isInline('br'), h.isBlock('br'), " &
    "h.isInline('div'), h.isBlock('div')].join(',')") ==
    "true,false,false,true"

test "html innerText validates input":
  expect CarneError:
    discard runCode("require('std/html').innerText(42)")

test "html stringify roundtrip":
  check runCode(
    "require('std/html').stringify(require('std/html').parse(" &
    "'<p>hi <b>ada</b></p>'))") == "<p>hi <b>ada</b></p>"
  check runCode(
    "require('std/html').stringify(require('std/html').parse(" &
    "'<br>'))") == "<br>"
  check runCode(
    "JSON.stringify(require('std/html').parse(require('std/html')" &
    ".stringify(require('std/html').parse('<p>hi</p>'))))") ==
    """[{"tag":"p","attrs":{},"children":["hi"]}]"""
