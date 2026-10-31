import std/os
import unittest

import carne
import carne/modules
import carne/pkg/stdsync

let stdHome = getTempDir() / "carne_std_colors"
removeDir(stdHome)
createDir(stdJsStore(stdHome))
copyFile(currentSourcePath.parentDir() / ".." / "src" / "carne" /
  "std" / "js" / "colors.js", stdJsStore(stdHome) / "colors.js")
initStdDispatcher(stdHome)

test "colors parse named and hex":
  check runCode(
    "JSON.stringify(require('std/colors').parse('red'))") ==
    """{"r":255,"g":0,"b":0,"a":1}"""
  check runCode(
    "JSON.stringify(require('std/colors').parse('rgba(0, 255, 0, 0.5)'))") ==
    """{"r":0,"g":255,"b":0,"a":0.5}"""

test "colors parse rejects garbage":
  expect CarneError:
    discard runCode("require('std/colors').parse('notacolor')")

test "colors format converters":
  check runCode(
    "const c = require('std/colors');" &
    "c.toHex(c.parse('red'))") == "#ff0000"
  check runCode(
    "const c = require('std/colors');" &
    "c.toRgb(c.parse('red'))") == "rgb(255, 0, 0)"
  check runCode(
    "const c = require('std/colors');" &
    "c.toHsl(c.parse('red'))") == "hsl(0, 100%, 50%)"
  check runCode(
    "const c = require('std/colors');" &
    "c.toName(c.parse('#ff0000'))") == "red"

test "colors manipulate":
  check runCode(
    "const c = require('std/colors');" &
    "c.toHex(c.lighten(c.parse('#333333'), 20))") == "#666666"
  check runCode(
    "const c = require('std/colors');" &
    "c.toHex(c.mix(c.parse('red'), c.parse('blue')))") == "#800080"
  check runCode(
    "const c = require('std/colors');" &
    "c.triad(c.parse('red')).length") == "3"
  check runCode(
    "const c = require('std/colors');" &
    "c.toHex(c.complement(c.parse('#ff0000')))") == "#00ffff"

test "colors contrast":
  check runCode(
    "const c = require('std/colors');" &
    "c.contrastRatio(c.parse('black'), c.parse('white'))") == "21"
  check runCode(
    "const c = require('std/colors');" &
    "c.isReadable(c.parse('black'), c.parse('white'))") == "true"
  check runCode(
    "const c = require('std/colors');" &
    "c.isReadable(c.parse('#777777'), c.parse('#ffffff'))") == "false"
  check runCode(
    "const c = require('std/colors');" &
    "c.isLight(c.parse('white'))") == "true"

test "colors rejects bad color objects":
  expect CarneError:
    discard runCode("require('std/colors').toHex({r: 1})")
  expect CarneError:
    discard runCode("require('std/colors').toHex({r: 999, g: 0, b: 0})")
