import std/os
import unittest

import carne
import carne/modules
import carne/std/env

registerStd("std/env", env.install)

test "env.args mirrors argv":
  check runCode("require('std/env').args().join(',')",
    argv = @["carne", "a.js", "x"]) == "carne,a.js,x"

test "env.getEnv returns values":
  putEnv("CARNE_TEST_VAR", "hello123")
  check runCode("require('std/env').getEnv('CARNE_TEST_VAR')") == "hello123"

test "env.getEnv missing is undefined":
  delEnv("CARNE_TEST_MISSING")
  check runCode("require('std/env').getEnv('CARNE_TEST_MISSING')") == ""

test "env.putEnv writes values visible to getEnv":
  discard runCode("require('std/env').putEnv('CARNE_TEST_PUT', 'v42')")
  check getEnv("CARNE_TEST_PUT") == "v42"
  check runCode("require('std/env').getEnv('CARNE_TEST_PUT')") == "v42"
  delEnv("CARNE_TEST_PUT")

test "env.delEnv removes values":
  putEnv("CARNE_TEST_DEL", "gone")
  discard runCode("require('std/env').delEnv('CARNE_TEST_DEL')")
  check not existsEnv("CARNE_TEST_DEL")
  check runCode("require('std/env').getEnv('CARNE_TEST_DEL')") == ""

test "env.hasEnv reflects presence":
  putEnv("CARNE_TEST_HAS", "1")
  check runCode("require('std/env').hasEnv('CARNE_TEST_HAS')") == "true"
  delEnv("CARNE_TEST_HAS_MISSING")
  check runCode("require('std/env').hasEnv('CARNE_TEST_HAS_MISSING')") ==
    "false"

test "env.cwd matches process":
  check runCode("require('std/env').cwd()") == getCurrentDir()

test "env.exit sets exit code":
  let res = runCodeEx("require('std/env').exit(3)")
  check res.code == 3
  check res.output == ""

test "env.parse with expansion":
  let res = runCode(
    "JSON.stringify(require('std/env').parse(" &
    "'A=1\\nB=\"x $A\"\\n# comment\\nexport C=plain'))")
  check res == """{"A":"1","B":"x 1","C":"plain"}"""

test "env.parse single quotes stay raw":
  check runCode(
    "require('std/env').parse(\"A='no $expand'\").A") == "no $expand"

test "env.load writes process env":
  let p = getTempDir() / "carne_dotenv_test"
  defer: removeFile(p)
  writeFile(p, "CARNE_DOTENV_TESTKEY=ok456\n")
  discard runCode("require('std/env').load('" & p & "')")
  check runCode("require('std/env').getEnv('CARNE_DOTENV_TESTKEY')") ==
    "ok456"

test "env.load missing file is a no-op":
  discard runCode(
    "require('std/env').load('/no/such/carne_dotenv_xyz')")

test "env.parse error shape":
  expect CarneError:
    discard runCode("require('std/env').parse('x', 'y')")
