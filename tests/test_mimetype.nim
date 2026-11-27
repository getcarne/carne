import unittest

import carne
import carne/modules
import carne/std/mimetype

registerStd("std/mimetype", mimetype.install)

test "lookup resolves with or without dot, any case":
  check runCode("require('std/mimetype').lookup('html')") == "text/html"
  check runCode("require('std/mimetype').lookup('.html')") == "text/html"
  check runCode("require('std/mimetype').lookup('PNG')") == "image/png"
  check runCode("require('std/mimetype').lookup('.Png')") == "image/png"

test "lookup returns null for unknown extensions":
  check runCode("require('std/mimetype').lookup('nope')") == "null"
  check runCode("require('std/mimetype').lookup('')") == "null"

test "info returns source, extensions and compressibility":
  check runCode(
    "JSON.stringify(require('std/mimetype').info('text/html'))") ==
    """{"source":"iana","compressible":true,"extensions":["html","htm","shtml"]}"""

test "info returns null for unknown types":
  check runCode("require('std/mimetype').info('nope/x')") == "null"

test "isExtension and has answer existence":
  check runCode("require('std/mimetype').isExtension('html')") == "true"
  check runCode("require('std/mimetype').isExtension('.zip')") == "true"
  check runCode("require('std/mimetype').isExtension('nope')") == "false"
  check runCode("require('std/mimetype').has('text/html')") == "true"
  check runCode("require('std/mimetype').has('nope/x')") == "false"

test "lookup rejects non-string input":
  expect CarneError:
    discard runCode("require('std/mimetype').lookup(42)")

test "charset reflects bundled defaults":
  check runCode("require('std/mimetype').charset('application/json')") ==
    "UTF-8"
  check runCode("require('std/mimetype').charset('text/css')") == "UTF-8"
  check runCode("require('std/mimetype').charset('image/png')") == "null"
  check runCode("require('std/mimetype').charset('text/html')") == "null"
  check runCode("require('std/mimetype').charset('nope/x')") == "null"

test "charset rejects non-string input":
  expect CarneError:
    discard runCode("require('std/mimetype').charset(42)")

test "charset uses exact lowercase MIME matches":
  check runCode("require('std/mimetype').charset('application/json')") == "UTF-8"
  check runCode("require('std/mimetype').charset('application/news-groupinfo')") == "US-ASCII"
  check runCode("require('std/mimetype').charset('text/html')") == "null"
  check runCode("require('std/mimetype').charset('Application/JSON')") == "null"
