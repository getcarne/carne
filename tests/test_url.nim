import unittest

import carne
import carne/modules
import carne/std/url

registerStd("std/url", url.install)

test "url parse exposes parts":
  check runCode(
    "JSON.stringify(require('std/url').parse(" &
    "'https://user:pw@host:8080/p?q=1&r=#frag'))") ==
    """{"scheme":"https","username":"user","password":"pw",""" &
    """"hostname":"host","port":8080,"path":"/p",""" &
    """"query":[{"key":"q","value":"1"},{"key":"r","value":""}],""" &
    """"fragment":"frag","isAbsolute":true}"""

test "url parse relative stays relative":
  check runCode(
    "JSON.stringify(require('std/url').parse('/a/b?x=1'))") ==
    """{"scheme":"","hostname":"","path":"/a/b",""" &
    """"query":[{"key":"x","value":"1"}],"isAbsolute":false}"""

test "url format roundtrips parse":
  check runCode(
    "const u = require('std/url'); " &
    "u.format(u.parse('https://user@host:8080/p?q=1#frag'))") ==
    "https://user@host:8080/p?q=1#frag"

test "url query helpers":
  check runCode(
    "JSON.stringify(require('std/url').parseQuery('a=1&b='))") ==
    """[{"key":"a","value":"1"},{"key":"b","value":""}]"""
  check runCode(
    "require('std/url').stringifyQuery([{key:'a',value:'1'}," &
    "{key:'b',value:''}])") == "a=1&b"
  check runCode(
    "require('std/url').stringifyQuery({a:'1',b:'x y'})") ==
    "a=1&b=x+y"

test "url encode and decode":
  check runCode("require('std/url').encode('a b/c')") == "a%20b%2Fc"
  check runCode("require('std/url').decode('a%20b%2Fc')") == "a b/c"

test "url format validates port":
  expect CarneError:
    discard runCode("require('std/url').format({hostname:'h',port:0})")
  expect CarneError:
    discard runCode("require('std/url').format('nope')")
