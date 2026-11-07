import unittest

import carne
import carne/modules
import carne/std/svg

registerStd("std/svg", svg.install)

test "svg parse element tree":
  check runCode(
    "JSON.stringify(require('std/svg').parse(" &
    "'<svg viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\"/></svg>'))") ==
    """{"kind":"element","tag":"svg","attrs":{"viewBox":"0 0 10 10"},""" &
    """"children":[{"kind":"element","tag":"circle",""" &
    """"attrs":{"cx":"5","cy":"5","r":"4"},"children":[]}]}"""

test "svg parse text leaves":
  check runCode(
    "JSON.stringify(require('std/svg').parse('<svg>hi</svg>')" &
    ".children[0])") ==
    """{"kind":"text","text":"hi"}"""

test "svg parse error throws":
  expect CarneError:
    discard runCode("require('std/svg').parse('<svg><unclosed>')")

test "svg stringify roundtrip":
  check runCode(
    "const s = require('std/svg');" &
    "s.stringify(s.parse(" &
    "'<svg viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\"/></svg>'))") ==
    """<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>"""
  check runCode(
    "const s = require('std/svg');" &
    "s.stringify(s.parse('<svg>hi</svg>'))") == "<svg>hi</svg>"

test "svg stringify validates shapes":
  expect CarneError:
    discard runCode("require('std/svg').stringify({tag: 42})")
  expect CarneError:
    discard runCode("require('std/svg').stringify('just a string root')")
