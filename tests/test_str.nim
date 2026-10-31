import std/os
import std/strutils
import unittest

import carne
import carne/modules
import carne/std/str

registerStd("std/str", str.install)

test "indexOf basics and JS parity":
  check runCode("require('std/str').indexOf('hello world', 'world')") == "6"
  check runCode("require('std/str').indexOf('hello', 'z')") == "-1"
  check runCode("require('std/str').indexOf('aaa', 'a', 1)") == "1"
  check runCode("require('std/str').indexOf('aaa', 'a', 9)") == "-1"
  check runCode("require('std/str').indexOf('abc', '')") == "0"
  check runCode("require('std/str').indexOf('abc', '', 2)") == "2"
  check runCode("require('std/str').indexOf('abc', '', 9)") == "3"
  check runCode(
    "const s = 'one two one two';" &
    "require('std/str').indexOf(s, 'two') === s.indexOf('two')") == "true"
  check runCode(
    "const s = 'aaaa';" &
    "require('std/str').indexOf(s, 'aa', 1) === s.indexOf('aa', 1)") ==
    "true"

test "indexOf unicode uses UTF-16 units":
  check runCode("require('std/str').indexOf('h\\u00E9llo', 'llo')") == "2"
  check runCode("require('std/str').indexOf('a\\uD83D\\uDE00b', 'b')") ==
    "3"
  check runCode("require('std/str').indexOf('a\\uD83D\\uDE00b', '\\uD83D\\uDE00')") ==
    "1"
  check runCode(
    "const s = 'h\\u00E9llo w\\u00F6rld';" &
    "require('std/str').indexOf(s, 'w\\u00F6') === s.indexOf('w\\u00F6')") ==
    "true"

test "lastIndexOf basics and JS parity":
  check runCode("require('std/str').lastIndexOf('aaa', 'a')") == "2"
  check runCode("require('std/str').lastIndexOf('hello', 'z')") == "-1"
  check runCode("require('std/str').lastIndexOf('aaa', 'a', 9)") == "2"
  check runCode("require('std/str').lastIndexOf('aaa', 'a', -1)") == "0"
  check runCode("require('std/str').lastIndexOf('abc', '')") == "3"
  check runCode(
    "const s = 'one two one two';" &
    "require('std/str').lastIndexOf(s, 'one') === s.lastIndexOf('one')") ==
    "true"
  check runCode(
    "const s = 'one two one two';" &
    "require('std/str').lastIndexOf(s, 'one', 2) === s.lastIndexOf('one', 2)") ==
    "true"
  check runCode(
    "require('std/str').lastIndexOf('a\\uD83D\\uDE00b\\uD83D\\uDE00', '\\uD83D\\uDE00')") ==
    "4"

test "includes count startsWith endsWith equals":
  check runCode("require('std/str').includes('abc', 'b')") == "true"
  check runCode("require('std/str').includes('abc', 'd')") == "false"
  check runCode("require('std/str').count('aaa', 'a')") == "3"
  check runCode("require('std/str').count('aaa', 'aa')") == "1"
  check runCode("require('std/str').count('abc', 'z')") == "0"
  check runCode("require('std/str').count('abc', '')") == "4"
  check runCode("require('std/str').startsWith('hello', 'he')") == "true"
  check runCode("require('std/str').startsWith('hello', '')") == "true"
  check runCode("require('std/str').endsWith('hello', 'lo')") == "true"
  check runCode("require('std/str').endsWith('hello', 'he')") == "false"
  check runCode("require('std/str').equals('a', 'a')") == "true"
  check runCode("require('std/str').equals('a', 'b')") == "false"

test "trim family with JS whitespace":
  check runCode("require('std/str').trim('  hi  ')") == "hi"
  check runCode("require('std/str').trim('\\t\\n hi \\r\\n')") == "hi"
  check runCode("require('std/str').trim('\\u00A0hi\\u00A0')") == "hi"
  check runCode("require('std/str').trim('\\u2003hi\\u2003')") == "hi"
  check runCode("require('std/str').trim('')") == ""
  check runCode("require('std/str').trim('   ')") == ""
  check runCode("require('std/str').trimStart('  hi  ')") == "hi  "
  check runCode("require('std/str').trimEnd('  hi  ')") == "  hi"
  check runCode(
    "const s = '  padded string here  ';" &
    "require('std/str').trim(s) === s.trim()") == "true"

test "case conversion":
  check runCode("require('std/str').toUpperCase('hello')") == "HELLO"
  check runCode("require('std/str').toLowerCase('HeLLo')") == "hello"
  check runCode("require('std/str').toUpperCase('h\\u00E9llo')") ==
    "H\u00C9LLO"
  check runCode(
    "const s = 'mixed CASE 123';" &
    "require('std/str').toUpperCase(s) === s.toUpperCase()") == "true"
  check runCode("require('std/str').isAscii('abc')") == "true"
  check runCode("require('std/str').isAscii('\\u00E9')") == "false"
  check runCode("require('std/str').isBlank('')") == "true"
  check runCode("require('std/str').isBlank('  \\t\\n ')") == "true"
  check runCode("require('std/str').isBlank(' x ')") == "false"

test "stripAnsi and lines":
  check runCode(
    "require('std/str').stripAnsi('\\x1B[31mred\\x1B[0m')") == "red"
  check runCode("require('std/str').stripAnsi('plain')") == "plain"
  check runCode(
    "JSON.stringify(require('std/str').lines('a\\r\\nb\\nc'))") ==
    """["a","b","c"]"""
  check runCode(
    "JSON.stringify(require('std/str').lines('a\\n'))") == """["a",""]"""
  check runCode(
    "JSON.stringify(require('std/str').lines(''))") == """[""]"""

test "split and join":
  check runCode(
    "JSON.stringify(require('std/str').split('a,b,c', ','))") ==
    """["a","b","c"]"""
  check runCode(
    "JSON.stringify(require('std/str').split('abc', ','))") ==
    """["abc"]"""
  check runCode(
    "JSON.stringify(require('std/str').split('a--b--c', '--'))") ==
    """["a","b","c"]"""
  check runCode(
    "JSON.stringify(require('std/str').split('a,b,', ','))") ==
    """["a","b",""]"""
  check runCode(
    "JSON.stringify(require('std/str').split('h\\u00E9llo', ''))") ==
    "[\"h\",\"é\",\"l\",\"l\",\"o\"]"
  check runCode("require('std/str').join(['a','b','c'], '-')") == "a-b-c"
  check runCode("require('std/str').join(['a','b'])") == "a,b"
  check runCode("require('std/str').join([])") == ""

test "replace and replaceAll":
  check runCode(
    "require('std/str').replace('aaa', 'a', 'b')") == "baa"
  check runCode(
    "require('std/str').replace('abc', '', 'X')") == "Xabc"
  check runCode(
    "require('std/str').replace('abc', 'z', 'X')") == "abc"
  check runCode(
    "require('std/str').replaceAll('aaa', 'a', 'b')") == "bbb"
  check runCode(
    "require('std/str').replaceAll('abc', 'z', 'X')") == "abc"
  check runCode(
    "require('std/str').replaceAll('abc', '', 'X')") == "XaXbXcX"
  check runCode(
    "require('std/str').replace('h\\u00E9llo', '\\u00E9', 'e')") ==
    "hello"

test "slice pad repeat reverse truncate":
  check runCode("require('std/str').slice('hello', 1, 3)") == "el"
  check runCode("require('std/str').slice('hello', -2)") == "lo"
  check runCode("require('std/str').slice('h\\u00E9llo', 1, 4)") ==
    "éll"
  check runCode("require('std/str').padStart('5', 3, '0')") == "005"
  check runCode("require('std/str').padEnd('5', 3, '0')") == "500"
  check runCode("require('std/str').padCenter('ab', 5)") == " ab  "
  check runCode("require('std/str').repeat('ab', 3)") == "ababab"
  check runCode("require('std/str').repeat('ab', 0)") == ""
  check runCode("require('std/str').reverse('abc')") == "cba"
  check runCode("require('std/str').reverse('h\\u00E9llo')") ==
    "olléh"
  check runCode("require('std/str').truncate('hello world', 5)") ==
    "hello…"
  check runCode("require('std/str').truncate('hi', 5)") == "hi"
  check runCode("require('std/str').truncate('hello', 2, '...')") ==
    "he..."

test "words and case converters":
  check runCode(
    "JSON.stringify(require('std/str').words('  hello   world\\n'))") ==
    """["hello","world"]"""
  check runCode("require('std/str').camelCase('hello-world_foo')") ==
    "helloWorldFoo"
  check runCode("require('std/str').camelCase('helloWorld')") ==
    "helloWorld"
  check runCode("require('std/str').snakeCase('helloWorld')") ==
    "hello_world"
  check runCode("require('std/str').snakeCase('HTTPRequest')") ==
    "http_request"
  check runCode("require('std/str').kebabCase('helloWorld')") ==
    "hello-world"
  check runCode("require('std/str').titleCase('hello world')") ==
    "Hello World"
  check runCode("require('std/str').slugify('Hello, World!')") ==
    "hello-world"

test "html escapes":
  check runCode("require('std/str').escapeHtml('<a>&\"\\'')") ==
    "&lt;a&gt;&amp;&quot;&#39;"
  check runCode(
    "require('std/str').unescapeHtml('&lt;a&gt;&amp;&quot;&#39;')") ==
    "<a>&\"'"
  check runCode("require('std/str').unescapeHtml('&#65;&#x42;')") == "AB"
  check runCode("require('std/str').unescapeHtml('&bogus;')") == "&bogus;"
  check runCode(
    "require('std/str').unescapeHtml(require('std/str').escapeHtml('<x>'))") ==
    "<x>"

test "levenshtein":
  check runCode("require('std/str').levenshtein('kitten', 'sitting')") ==
    "3"
  check runCode("require('std/str').levenshtein('', 'abc')") == "3"
  check runCode("require('std/str').levenshtein('same', 'same')") == "0"
  expect CarneError:
    discard runCode("require('std/str').levenshtein('" &
      repeat('x', 2001) & "', '" & repeat('y', 2001) & "')")

test "wrap indent dedent collapse chomp":
  check runCode(
    "require('std/str').wordWrap('aa bb cc dd', 5)") == "aa bb\ncc dd"
  check runCode(
    "require('std/str').wordWrap('a\\n\\nb', 10)") == "a\n\nb"
  check runCode("require('std/str').indent('a\\nb', '>>')") == ">>a\n>>b"
  check runCode("require('std/str').dedent('  a\\n  b\\n')") == "a\nb\n"
  check runCode(
    "require('std/str').collapseWhitespace('  a   b \\n c  ')") == "a b c"
  check runCode("require('std/str').chomp('a\\n')") == "a"
  check runCode("require('std/str').chomp('a\\r\\n')") == "a"
  check runCode("require('std/str').chomp('a')") == "a"
  check runCode("require('std/str').chomp('a\\n\\n')") == "a\n"

test "error shapes":
  expect CarneError:
    discard runCode("require('std/str').indexOf('x')")
  expect CarneError:
    discard runCode("require('std/str').count(42, 'x')")
  expect CarneError:
    discard runCode("require('std/str').join([1, 2])")
  expect CarneError:
    discard runCode("require('std/str').repeat('ab', -1)")
  expect CarneError:
    discard runCode("require('std/str').wordWrap('ab', 0)")

test "validators":
  check runCode("require('std/str').isEmail('a@b.com')") == "true"
  check runCode("require('std/str').isEmail('bad@')") == "false"
  check runCode("require('std/str').isEmail('x@y')") == "false"
  check runCode("require('std/str').isEmail(42)") == "false"
  check runCode("require('std/str').isDomain('example.com')") == "true"
  check runCode("require('std/str').isDomain('-bad.com')") == "false"
  check runCode("require('std/str').isDomain('a.b')") == "false"
  check runCode("require('std/str').isIPv4('1.2.3.4')") == "true"
  check runCode("require('std/str').isIPv4('01.2.3.4')") == "false"
  check runCode("require('std/str').isIPv4('1.2.3.256')") == "false"
  check runCode("require('std/str').isIPv6('::1')") == "true"
  check runCode("require('std/str').isIPv6('fe80::1')") == "true"
  check runCode("require('std/str').isIPv6('1::2::3')") == "false"
  check runCode("require('std/str').isIPv6('::ffff:1.2.3.4')") == "true"
  check runCode("require('std/str').isIP('1.2.3.4')") == "true"
  check runCode("require('std/str').isIP('::1')") == "true"
  check runCode("require('std/str').isIP('nope')") == "false"
  check runCode(
    "require('std/str').isWebUrl('https://example.com/x')") == "true"
  check runCode("require('std/str').isWebUrl('ftp://x.com')") == "false"
  check runCode(
    "require('std/str').isWebUrl('http://localhost:3000/')") == "true"
  check runCode(
    "require('std/str').isUUID('550e8400-e29b-41d4-a716-446655440000')") ==
    "true"
  check runCode("require('std/str').isUUID('xyz')") == "false"
  check runCode("require('std/str').isPort(8080)") == "true"
  check runCode("require('std/str').isPort('443')") == "true"
  check runCode("require('std/str').isPort(80.5)") == "false"
  check runCode("require('std/str').isPort('')") == "false"
  check runCode("require('std/str').isPort(null)") == "false"
  check runCode("require('std/str').isPort(70000)") == "false"

test "astral plane follows JS units":
  check runCode(
    "require('std/str').slice('a'+String.fromCodePoint(0x1F600)+'b', 0, 2).length") ==
    "2"
  check runCode(
    "JSON.stringify(require('std/str').split('a'+String.fromCodePoint(0x1F600)+'b', ''))") ==
    "[\"a\",\"\\ud83d\",\"\\ude00\",\"b\"]"
  check runCode(
    "require('std/str').reverse('a'+String.fromCodePoint(0x1F600)+'b')") ==
    "b😀a"
  check runCode(
    "require('std/str').replaceAll('aaa', 'a', '$&')") == "$&$&$&"
