import unittest

import carne
import carne/modules
import carne/std/feed

registerStd("std/feed", feed.install)

const sampleRss =
  "\"<?xml version=\\\"1.0\\\"?><rss version=\\\"2.0\\\"><channel>" &
  "<title>T</title><link>http://x</link><description>D</description>" &
  "<item><title>I1</title><link>http://x/1</link></item>" &
  "</channel></rss>\""

const sampleAtom =
  "\"<?xml version=\\\"1.0\\\"?><feed xmlns=\\\"http://www.w3.org/2005/Atom\\\">" &
  "<id>u:1</id><title>AT</title><updated>2026-01-01T00:00:00Z</updated>" &
  "<author><name>Ann</name></author>" &
  "<entry><id>u:2</id><title>E1</title>" &
  "<updated>2026-01-02T00:00:00Z</updated></entry></feed>\""

test "feed parseRss":
  check runCode(
    "require('std/feed').parseRss(" & sampleRss & ").title") == "T"
  check runCode(
    "require('std/feed').parseRss(" & sampleRss & ").items[0].title") == "I1"
  check runCode(
    "require('std/feed').parseRss(" & sampleRss & ").items.length") == "1"

test "feed parseAtom":
  check runCode(
    "require('std/feed').parseAtom(" & sampleAtom & ").title.value") == "AT"
  check runCode(
    "require('std/feed').parseAtom(" & sampleAtom & ").authors[0].name") ==
    "Ann"
  check runCode(
    "require('std/feed').parseAtom(" & sampleAtom & ").entries[0].id") ==
    "u:2"

test "feed parse errors throw":
  expect CarneError:
    discard runCode("require('std/feed').parseRss('<nope>')")
  expect CarneError:
    discard runCode("require('std/feed').parseAtom('not xml')")

test "feed stringifyRss roundtrip":
  check runCode(
    "require('std/feed').parseRss(require('std/feed').stringifyRss(" &
    "require('std/feed').parseRss(" & sampleRss & "))).title") == "T"
  check runCode(
    "require('std/feed').stringifyRss(require('std/feed').parseRss(" &
    sampleRss & ")).includes('<title>T</title>')") == "true"

test "feed stringifyAtom roundtrip":
  check runCode(
    "require('std/feed').parseAtom(require('std/feed').stringifyAtom(" &
    "require('std/feed').parseAtom(" & sampleAtom & "))).id") == "u:1"
