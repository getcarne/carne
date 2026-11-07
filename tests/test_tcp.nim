import unittest

import carne
import carne/modules
import carne/std/tcp

registerStd("std/tcp", tcp.install)

test "tcp echo roundtrip":
  check runCode(
    "const tcp = require('std/tcp'); " &
    "const log = []; " &
    "const srv = tcp.serve(18301, {onData: (c, m) => " &
    "{ log.push('srv:' + m); c.write('echo:' + m); }}); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "(async () => { " &
    "const c = await tcp.connect('127.0.0.1', 18301, { " &
    "onOpen: () => log.push('open'), " &
    "onData: (m) => { log.push('cli:' + m); " &
    "c.close(); tcp.close(srv.port); " &
    "done(log.join(',') + '|' + c.remoteAddress + ':' + c.remotePort); }}); " &
    "c.write('hello'); })(); " &
    "gate") ==
    "open,srv:hello,cli:echo:hello|127.0.0.1:18301"

test "tcp serve returns port and host, close returns true":
  check runCode(
    "const tcp = require('std/tcp'); " &
    "const s = tcp.serve(18302, '127.0.0.1', {}); " &
    "s.port + ':' + s.host + ':' + tcp.close(s.port)") ==
    "18302:127.0.0.1:true"

test "tcp handle carries remote address and port":
  check runCode(
    "const tcp = require('std/tcp'); " &
    "const srv = tcp.serve(18303, {onData: (c, m) => " &
    "{ c.write(c.remoteAddress + ':' + (c.remotePort > 0)); }}); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "(async () => { " &
    "const c = await tcp.connect('127.0.0.1', 18303, " &
    "{onData: (m) => { c.close(); tcp.close(srv.port); done(m); }}); " &
    "c.write('hi'); })(); " &
    "gate") == "127.0.0.1:true"

test "tcp connect to closed port rejects":
  expect CarneError:
    discard runCode(
      "require('std/tcp').connect('127.0.0.1', 18304)")

test "tcp serve validates options":
  expect CarneError:
    discard runCode("require('std/tcp').serve(0, {})")
  expect CarneError:
    discard runCode(
      "require('std/tcp').serve(18305, {certFile: 'x.pem'})")

const tlsCert = "tests/fixtures/tcp-cert.pem"
const tlsKey = "tests/fixtures/tcp-key.pem"

test "tcp tls echo roundtrip":
  check runCode(
    "const tcp = require('std/tcp'); " &
    "const srv = tcp.serve(18306, {certFile: '" & tlsCert & "', " &
    "keyFile: '" & tlsKey & "', " &
    "onData: (c, m) => { c.write('tls:' + m); }}); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "(async () => { " &
    "const c = await tcp.connect('127.0.0.1', 18306, {tls: true, " &
    "rejectUnauthorized: false, " &
    "onData: (m) => { c.close(); tcp.close(srv.port); done(m); }}); " &
    "c.write('hello'); })(); " &
    "gate") == "tls:hello"

test "tcp tls rejects self-signed by default":
  check runCode(
    "const tcp = require('std/tcp'); " &
    "const srv = tcp.serve(18307, {certFile: '" & tlsCert & "', " &
    "keyFile: '" & tlsKey & "', onData: (c, m) => {}}); " &
    "let done; " &
    "const gate = new Promise((r) => { done = r; }); " &
    "tcp.connect('127.0.0.1', 18307, {tls: true}).then(" &
    "() => { tcp.close(srv.port); done('resolved?!'); }, " &
    "() => { tcp.close(srv.port); done('rejected'); }); " &
    "gate") == "rejected"
