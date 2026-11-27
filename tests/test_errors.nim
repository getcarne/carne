import unittest, strutils

import carne
import carne/modules
import carne/std/qr
import carne/std/path
import carne/std/sql
import carne/std/uuid
import carne/std/mimetype

registerStd("std/qr", qr.install)
registerStd("std/path", path.install)
registerStd("std/sql", sql.install)
registerStd("std/uuid", uuid.install)
registerStd("std/mimetype", mimetype.install)

proc probe(modName, call: string): string =
  ## "<ctor>|<message without JSDoc lines>" or "none" when nothing threw.
  runCode("""
    (() => { try { const m = require('""" & modName & """'); """ & call & """;
      return 'none'; } catch (e) {
      return e.constructor.name + '|' + String(e.message).split('\n')
        .filter(l => !/^\s*(\*|\/\*)/.test(l)).join('|'); } })()""")

suite "error contract: TypeError for argument validation, one fn: prefix":
  test "qr option validation is a TypeError with encode: prefix":
    check probe("std/qr", "m.encode('hi',{family:'qr9'})").startsWith(
      "TypeError|encode: options.family")
    check probe("std/qr", "m.encode('hi',{ecLevel:'Z'})").startsWith(
      "TypeError|encode: options.ecLevel")
  test "type mismatches name the parameter":
    for (modName, call) in [("std/sql", "m.sqlite.parse(5)"),
        ("std/mimetype", "m.charset(5)")]:
      let r = probe(modName, call)
      check r.startsWith("TypeError|type mismatch parameter:")
  test "arity errors are TypeErrors with fn prefix":
    check probe("std/uuid", "m.v4(1, 2)").startsWith("TypeError|v4: expected")
  test "path.join and path.format validate arguments with TypeError":
    check probe("std/path", "m.join('not-array')").startsWith(
      "TypeError|join: expected array")
    check probe("std/path", "m.join(['a', 5])").startsWith(
      "TypeError|join: entries must be strings")
    check probe("std/path", "m.format({kind: 'bogus'})").startsWith(
      "TypeError|format:")
  test "sql format upperCase must be boolean (TypeError, fn: prefix)":
    for d in ["sqlite", "postgres", "mysql"]:
      check probe("std/sql", "m." & d & ".format('select 1', {upperCase: 'x'})")
        .startsWith("TypeError|" & d & ".format: options.upperCase")
  test "valid calls do not throw":
    check probe("std/path", "m.join(['a','b'])") == "none"
    check probe("std/sql", "m.sqlite.format('select 1', {upperCase: true})") ==
      "none"
