import unittest

import carne
import carne/modules
import carne/std/udp

registerStd("std/udp", udp.install)

test "udp bind echo roundtrip":
  check runCode(
    "const udp = require('std/udp'); " &
    "const s = udp.bind(18411, (msg, rinfo) => " &
    "{ s.sendTo('pong:' + msg.data, rinfo); }); " &
    "const c = udp.connect('127.0.0.1', 18411, (msg) => { " &
    "c.close(); s.close(); done(msg.data); }); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "c.send('ping'); " &
    "gate") == "pong:ping"

test "udp sendTo rinfo echo and ephemeral bind":
  check runCode(
    "const udp = require('std/udp'); " &
    "const s = udp.bind(18412, (msg, rinfo) => " &
    "{ s.sendTo('from:' + rinfo.port, rinfo); }); " &
    "const c = udp.bind(0, (msg) => { " &
    "const ok = msg.data === 'from:' + c.port; " &
    "c.close(); s.close(); done(ok); }); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "c.sendTo('hello', '127.0.0.1', 18412); " &
    "gate") == "true"

test "udp socket validates shapes":
  expect CarneError:
    discard runCode("require('std/udp').bind(-1, (m) => {})")
  expect CarneError:
    discard runCode("require('std/udp').bind(18413)")
  expect CarneError:
    discard runCode(
      "const udp = require('std/udp'); " &
      "const s = udp.bind(18414, (m) => {}); " &
      "s.send('x')")
