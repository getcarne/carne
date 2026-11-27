import std/strutils
import unittest

import carne
import carne/modules
import carne/std/sql

registerStd("std/sql", sql.install)

test "sql parse returns AST with kind/value navigation":
  check runCode(
    "require('std/sql').sqlite.parse('SELECT a FROM t').kind") == "StmtList"
  check runCode(
    "require('std/sql').sqlite.parse('SELECT a FROM t')" &
    ".children[0].kind") == "Select"
  check runCode(
    "require('std/sql').sqlite.parse('SELECT a FROM t')" &
    ".children[0].children[1].children[0].children[0].value") == "t"

test "sql parse literal kinds carry value and quote":
  check runCode(
    "JSON.stringify(require('std/sql').mysql.parse('SELECT `a` FROM t')" &
    ".children[0].children[0].children[0].children[0])") ==
    """{"kind":"QuotedIdent","value":"a","quote":"Backtick"}"""
  check runCode(
    "JSON.stringify(require('std/sql').sqlite.parse('SELECT 1').children[0]" &
    ".children[0].children[0].children[0])") ==
    """{"kind":"IntegerLit","value":"1"}"""

test "sql validate ok returns valid true":
  check runCode(
    "require('std/sql').postgres.validate('SELECT $1').valid") == "true"
  check runCode(
    "require('std/sql').sqlite.validate('PRAGMA journal_mode').valid") ==
    "true"

test "sql validate rejects wrong-dialect syntax without throwing":
  check runCode(
    "require('std/sql').sqlite.validate('SELECT $1').valid") == "false"
  check runCode(
    "require('std/sql').postgres.validate('SELECT `a` FROM t').valid") ==
    "false"
  check runCode(
    "require('std/sql').postgres.validate('SELECT a FROM t LIMIT 1, 2')" &
    ".valid") == "false"
  check runCode(
    "JSON.stringify(require('std/sql').postgres.validate('SELECT `a` FROM t')" &
    ".error).includes('backtick')") == "true"

test "sql parse throws with dialect error and usage":
  expect CarneError:
    discard runCode("require('std/sql').postgres.parse('SELECT `a` FROM t')")
  expect CarneError:
    discard runCode("require('std/sql').sqlite.parse('SELECT FROM WHERE')")

test "sql exposes exactly the three dialect namespaces":
  check runCode(
    "Object.keys(require('std/sql')).sort().join(',')") ==
    "mysql,postgres,sqlite"

test "sql stringify roundtrip":
  check runCode(
    "require('std/sql').sqlite.stringify(require('std/sql').sqlite.parse(" &
    "'SELECT a FROM t')).toUpperCase().includes('SELECT')") == "true"
  check runCode(
    "require('std/sql').sqlite.parse(require('std/sql').sqlite.stringify(" &
    "require('std/sql').sqlite.parse('SELECT a FROM t'))).kind") ==
    "StmtList"

test "sql format normalizes":
  check runCode(
    "require('std/sql').sqlite.format('select a from t')") ==
    runCode("require('std/sql').sqlite.stringify(require('std/sql')" &
    ".sqlite.parse('select a from t'))")

test "sql format upperCase option":
  check runCode(
    "require('std/sql').sqlite.format('select a from t', " &
    "{upperCase: true})") == "SELECT a FROM t;"
  check runCode(
    "require('std/sql').postgres.format('select $1', " &
    "{upperCase: true})") == "SELECT $1;"
  check runCode(
    "require('std/sql').sqlite.format('select a from t', " &
    "{upperCase: false})") ==
    runCode("require('std/sql').sqlite.format('select a from t')")

test "sql format rejects non-boolean upperCase":
  expect CarneError:
    discard runCode(
      "require('std/sql').sqlite.format('select a from t', " &
      "{upperCase: 42})")
  expect CarneError:
    discard runCode(
      "require('std/sql').postgres.format('select 1', " &
      "{upperCase: 'yes'})")
  expect CarneError:
    discard runCode(
      "require('std/sql').mysql.format('select 1', {upperCase: 1})")

test "dialect parity: every dialect exposes the same API":
  for d in ["sqlite", "postgres", "mysql"]:
    check runCode(
      "Object.keys(require('std/sql')." & d & ").sort().join()") ==
      "format,parse,stringify,validate"

test "dialect parity: simple select parses and round-trips":
  for d in ["sqlite", "postgres", "mysql"]:
    check runCode(
      "const s = require('std/sql')." & d & ";" &
      "s.parse(s.stringify(s.parse('SELECT a FROM t'))).kind") == "StmtList"
    check runCode(
      "require('std/sql')." & d & ".validate('SELECT a FROM t').valid") ==
      "true"
    check runCode(
      "require('std/sql')." & d & ".validate('SELEC a FROM').valid") ==
      "false"

test "format upperCase must be a boolean (TypeError, fn: prefix)":
  for d in ["sqlite", "postgres", "mysql"]:
    let r = runCode("""
      (() => { try {
        require('std/sql').""" & d & """.format('select 1', {upperCase: 'x'});
        return 'none'; } catch (e) { return e.constructor.name + '|' +
        String(e.message).split('\n').filter(l => !/^\s*(\*|\/\*)/.test(l))
        .join('|'); } })()""")
    check r.startsWith("TypeError|" & d &
      ".format: options.upperCase must be a boolean")
    check runCode("require('std/sql')." & d &
      ".format('select 1', {upperCase: true})").len > 0
