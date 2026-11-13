import unittest

import std/os

import carne
import carne/modules
import carne/std/gettext

registerStd("std/gettext", gettext.install)

const jsPo = """'msgid ""\nmsgstr ""\n"Project-Id-Version: demo\\n"\n""" &
  """"Language: fr\\n"\n\n#, fuzzy\nmsgid "Hello"\nmsgstr "Bonjour"\n\n""" &
  """msgid "Bye"\nmsgstr "Au revoir"\n\n""" &
  """msgid "apple"\nmsgid_plural "apples"\nmsgstr[0] "pomme"\n""" &
  """msgstr[1] "pommes"\n'"""

test "gettext parse headers and entries":
  check runCode(
    "JSON.stringify(require('std/gettext').parse(" & jsPo & ").headers)") ==
    """{"Project-Id-Version":"demo","Language":"fr"}"""
  check runCode(
    "JSON.stringify(require('std/gettext').parse(" & jsPo & ").entries)") ==
    """[{"msgid":"Hello","msgstr":["Bonjour"],"fuzzy":true},""" &
    """{"msgid":"Bye","msgstr":["Au revoir"]},""" &
    """{"msgid":"apple","msgidPlural":"apples",""" &
    """"msgstr":["pomme","pommes"]}]"""

test "gettext translate falls back to msgid":
  check runCode(
    "require('std/gettext').translate(" & jsPo & ", 'Bye')") == "Au revoir"
  check runCode(
    "require('std/gettext').translate(" & jsPo & ", 'Missing')") == "Missing"

test "gettext translate skips fuzzy entries":
  check runCode(
    "require('std/gettext').translate(" & jsPo & ", 'Hello')") == "Hello"

test "gettext ntranslate picks plural form":
  check runCode(
    "require('std/gettext').ntranslate(" & jsPo &
    ", 'apple', 'apples', 1)") == "pomme"
  check runCode(
    "require('std/gettext').ntranslate(" & jsPo &
    ", 'apple', 'apples', 5)") == "pommes"

test "gettext parse error throws":
  expect CarneError:
    discard runCode("require('std/gettext').parse('msgid \"unterminated')")

const moPath = "tests/fixtures/gettext.mo"

test "gettext mo file parse headers and entries":
  check runCode(
    "JSON.stringify(require('std/gettext').parseMoFile('" & moPath &
    "').headers)") ==
    """{"Project-Id-Version":"demo","Language":"fr","Plural-Forms":"nplurals=2; plural=(n > 1);"}"""
  check runCode(
    "JSON.stringify(require('std/gettext').parseMoFile('" & moPath &
    "').entries)") ==
    """[{"msgid":"Hello","msgstr":["Bonjour"]},""" &
    """{"msgid":"apple","msgidPlural":"apples",""" &
    """"msgstr":["pomme","pommes"]},""" &
    """{"msgid":"Open","msgctxt":"menu","msgstr":["Ouvrir"]}]"""

test "gettext mo translate and ntranslate":
  check runCode(
    "require('std/gettext').translateMo('" & moPath & "', 'Hello')") ==
    "Bonjour"
  check runCode(
    "require('std/gettext').translateMo('" & moPath &
    "', 'Open', 'menu')") == "Ouvrir"
  check runCode(
    "require('std/gettext').translateMo('" & moPath &
    "', 'Missing')") == "Missing"
  check runCode(
    "require('std/gettext').ntranslateMo('" & moPath &
    "', 'apple', 'apples', 1)") == "pomme"
  check runCode(
    "require('std/gettext').ntranslateMo('" & moPath &
    "', 'apple', 'apples', 5)") == "pommes"

test "gettext mo missing file throws":
  expect CarneError:
    discard runCode(
      "require('std/gettext').parseMoFile('tests/fixtures/nope.mo')")

const jsPoCtx = """'msgid ""\nmsgstr ""\n"Project-Id-Version: t\\n"\n""" &
  """"Language: fr\\n"\n"Plural-Forms: nplurals=2; plural=(n > 1);\\n"\n\n""" &
  """msgctxt "menu"\nmsgid "file"\nmsgid_plural "files"\n""" &
  """msgstr[0] "fichier"\nmsgstr[1] "fichiers"\n\n""" &
  """msgctxt "menu"\nmsgid "Open"\nmsgstr "Ouvrir"\n'"""

test "gettext ntranslate takes msgctxt":
  check runCode("require('std/gettext').ntranslate(" & jsPoCtx &
    ", 'file', 'files', 1, 'menu')") == "fichier"
  check runCode("require('std/gettext').ntranslate(" & jsPoCtx &
    ", 'file', 'files', 5, 'menu')") == "fichiers"
  check runCode("require('std/gettext').ntranslate(" & jsPoCtx &
    ", 'file', 'files', 5)") == "files"

test "gettext writeMo roundtrips and ntranslateMo takes msgctxt":
  let moPath = getTempDir() / "carne_gettext_ctx.mo"
  discard runCode("require('std/gettext').writeMo(" & jsPoCtx &
    ", '" & moPath & "')")
  check runCode("require('std/gettext').ntranslateMo('" & moPath &
    "', 'file', 'files', 1, 'menu')") == "fichier"
  check runCode("require('std/gettext').ntranslateMo('" & moPath &
    "', 'file', 'files', 5, 'menu')") == "fichiers"
  check runCode("require('std/gettext').translateMo('" & moPath &
    "', 'Open', 'menu')") == "Ouvrir"
  removeFile(moPath)

test "gettext writeMo error throws":
  expect CarneError:
    discard runCode(
      "require('std/gettext').writeMo('msgid \"unterminated', 'x.mo')")
