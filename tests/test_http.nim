import unittest

import carne
import carne/modules
import carne/std/http
import carne/std/os

registerStd("std/http", http.install)
registerStd("std/os", os.install)

const preamble = "(async () => { const http = require('std/http'); "

test "fetch roundtrip returns status and body":
  check runCode(preamble &
    "const srv = http.serve(18101, req => ({body: 'hi ' + req.path})); " &
    "const res = await http.fetch('http://127.0.0.1:18101/test'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.body; })()") == "200:hi /test"

test "serve returns port and host, close returns true":
  check runCode(preamble &
    "const srv = http.serve(18102, '127.0.0.1', req => ({})); " &
    "const s = srv.port + ':' + srv.host; " &
    "const c = http.close(srv.port); " &
    "return s + ':' + c; })()") == "18102:127.0.0.1:true"

test "get and post with headers and body":
  check runCode(preamble &
    "const srv = http.serve(18103, req => ({status: 201, " &
    "headers: {'X-Echo': req.headers['x-test'] || 'none'}, " &
    "body: req.method + ':' + req.body})); " &
    "const res = await http.post('http://127.0.0.1:18103/e', 'ping', " &
    "{headers: {'X-Test': 'yes'}}); " &
    "const g = await http.get('http://127.0.0.1:18103/e'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.headers['x-echo'] + ':' + res.body + " &
    "'|GET:' + g.body; })()") ==
    "201:yes:POST:ping|GET:GET:"

test "request path query url and status text":
  check runCode(preamble &
    "const srv = http.serve(18104, req => " &
    "({body: [req.path, req.query, req.url].join('|')})); " &
    "const res = await http.get('http://127.0.0.1:18104/a/b?x=1&y=2'); " &
    "http.close(srv.port); " &
    "return res.statusText + ':' + res.body; })()") ==
    "OK:/a/b|x=1&y=2|/a/b?x=1&y=2"

test "handler string return is text plain":
  check runCode(preamble &
    "const srv = http.serve(18105, req => 'plain'); " &
    "const res = await http.get('http://127.0.0.1:18105/'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.headers['content-type'] + ':' + " &
    "res.body; })()") ==
    "200:text/plain; charset=utf-8:plain"

test "handler status codes pass through":
  check runCode(preamble &
    "const srv = http.serve(18106, req => " &
    "req.path === '/old' ? {status: 404, body: 'gone'} : {body: 'here'}); " &
    "const a = await http.get('http://127.0.0.1:18106/old'); " &
    "const b = await http.get('http://127.0.0.1:18106/new'); " &
    "http.close(srv.port); " &
    "return a.status + ':' + a.body + ' ' + b.status + ':' + b.body; " &
    "})()") == "404:gone 200:here"

test "concurrent fetches all resolve":
  check runCode(preamble &
    "const srv = http.serve(18107, req => ({body: 'r' + req.path})); " &
    "const rs = await Promise.all([" &
    "http.get('http://127.0.0.1:18107/1'), " &
    "http.fetch('http://127.0.0.1:18107/2', {method: 'GET'}), " &
    "http.post('http://127.0.0.1:18107/3', 'b')]); " &
    "http.close(srv.port); " &
    "return rs.map(r => r.body).join(','); })()") == "r/1,r/2,r/3"

test "connection refused rejects":
  expect CarneError:
    discard runCode(preamble &
      "await http.get('http://127.0.0.1:18999/nope'); })()")

test "handler throw answers 500 and raises uncaught":
  expect CarneError:
    discard runCode(preamble &
      "const srv = http.serve(18108, req => { throw new Error('kaput'); }); " &
      "const res = await http.get('http://127.0.0.1:18108/'); " &
      "http.close(srv.port); })()")
  check runCode(preamble &
    "const srv = http.serve(18109, req => ({status: 500, body: 'oops'})); " &
    "const res = await http.get('http://127.0.0.1:18109/'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.body; })()") == "500:oops"

test "fetch unknown method throws":
  expect CarneError:
    discard runCode(preamble &
      "await http.fetch('http://127.0.0.1:18109/', " &
      "{method: 'BOGUS'}); })()")

test "serve validates port and handler":
  expect CarneError:
    discard runCode(preamble & "http.serve(99999, () => ({})); })()")
  expect CarneError:
    discard runCode(preamble & "http.serve(18110, 'nope'); })()")
  expect CarneError:
    discard runCode("require('std/http').serve(18111)")

test "close unknown port throws":
  expect CarneError:
    discard runCode("require('std/http').close(18998)")

test "fetch validates arity and options":
  expect CarneError:
    discard runCode("require('std/http').fetch()")
  expect CarneError:
    discard runCode(preamble &
      "await http.fetch('http://127.0.0.1:18112/', 42); })()")
  expect CarneError:
    discard runCode(preamble &
      "await http.get('http://127.0.0.1:18112/', " &
      "{method: 'POST'}); })()")

test "put patch delete head options roundtrip":
  check runCode(preamble &
    "const srv = http.serve(18113, req => ({body: req.method + ':' + " &
    "req.body})); " &
    "const rs = await Promise.all([" &
    "http.put('http://127.0.0.1:18113/e', 'p'), " &
    "http.patch('http://127.0.0.1:18113/e', 'pa'), " &
    "http.delete('http://127.0.0.1:18113/e'), " &
    "http.options('http://127.0.0.1:18113/e')]); " &
    "const h = await http.head('http://127.0.0.1:18113/e'); " &
    "const viaFetch = await http.fetch('http://127.0.0.1:18113/e', " &
    "{method: 'DELETE'}); " &
    "http.close(srv.port); " &
    "return rs.map(r => r.body).join(',') + '|' + h.status + ':' + " &
    "h.body.length + ':' + viaFetch.body; })()") ==
    "PUT:p,PATCH:pa,DELETE:,OPTIONS:|200:0:DELETE:"

test "head and 204 answer empty bodies":
  check runCode(preamble &
    "const srv = http.serve(18114, req => " &
    "req.path === '/gone' ? {status: 204, body: 'x'} : 'body-here'); " &
    "const h = await http.head('http://127.0.0.1:18114/'); " &
    "const g = await http.get('http://127.0.0.1:18114/gone'); " &
    "const ok = await http.get('http://127.0.0.1:18114/'); " &
    "http.close(srv.port); " &
    "return h.status + ':' + h.body.length + ' ' + g.status + ':' + " &
    "g.body.length + ' ' + ok.body; })()") ==
    "200:0 204:0 body-here"

test "request carries clientIp":
  check runCode(preamble &
    "const srv = http.serve(18115, req => ({body: req.clientIp})); " &
    "const res = await http.get('http://127.0.0.1:18115/'); " &
    "http.close(srv.port); " &
    "return res.body; })()") == "127.0.0.1"

test "serve takes tuning opts":
  check runCode(preamble &
    "const a = http.serve(18116, {keepAliveMs: 1000}, " &
    "req => ({body: 'a'})); " &
    "const b = http.serve(18117, '127.0.0.1', " &
    "{readTimeoutMs: 5000, maxBodySize: 1048576}, " &
    "req => ({body: 'b'})); " &
    "const ra = await http.get('http://127.0.0.1:18116/'); " &
    "const rb = await http.get('http://127.0.0.1:18117/'); " &
    "http.close(a.port); http.close(b.port); " &
    "return ra.body + rb.body; })()") == "ab"

test "serve rejects bad opts":
  expect CarneError:
    discard runCode(preamble &
      "http.serve(18118, {keepAliveMs: 'soon'}, () => ({})); })()")
  expect CarneError:
    discard runCode(preamble &
      "http.serve(18118, {maxBodySize: -5}, () => ({})); })()")
  expect CarneError:
    discard runCode(preamble &
      "http.serve(18118, '127.0.0.1', 42, () => ({})); })()")
  expect CarneError:
    discard runCode(preamble &
      "await http.delete('http://127.0.0.1:18118/', " &
      "{method: 'POST'}); })()")

test "object return defaults content-type":
  check runCode(preamble &
    "const srv = http.serve(18119, req => " &
    "req.path === '/t' ? {body: 'hi'} : " &
    "req.path === '/j' ? {body: 42} : " &
    "req.path === '/e' ? {headers: {'Content-Type': 'text/csv'}, " &
    "body: 'a,b'} : {status: 204, body: 'x'}); " &
    "const t = await http.get('http://127.0.0.1:18119/t'); " &
    "const j = await http.get('http://127.0.0.1:18119/j'); " &
    "const e = await http.get('http://127.0.0.1:18119/e'); " &
    "const n = await http.get('http://127.0.0.1:18119/gone'); " &
    "http.close(srv.port); " &
    "return t.headers['content-type'] + '|' + j.headers['content-type'] + " &
    "'|' + e.headers['content-type'] + '|' + " &
    "String(n.headers['content-type']); })()") ==
    "text/plain; charset=utf-8|application/json|text/csv|undefined"

test "handler Uint8Array body roundtrips bytes":
  check runCode(preamble &
    "const srv = http.serve(18120, req => " &
    "({headers: {'Content-Type': 'application/octet-stream'}, " &
    "body: new Uint8Array([72, 105, 195, 169])})); " &
    "const res = await http.get('http://127.0.0.1:18120/'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.headers['content-type'] + ':' + " &
    "res.headers['content-length'] + ':' + res.body; })()") ==
    "200:application/octet-stream:4:Hi\u00e9"

test "handler Uint8Array body defaults status and content type":
  check runCode(preamble &
    "const srv = http.serve(18121, req => " &
    "({status: 201, body: new Uint8Array([65, 66, 67])})); " &
    "const res = await http.get('http://127.0.0.1:18121/'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.headers['content-type'] + ':' + " &
    "res.body; })()") ==
    "201:application/octet-stream:ABC"

test "handler Uint8Array body with NUL keeps content length":
  check runCode(preamble &
    "const srv = http.serve(18122, req => " &
    "({body: new Uint8Array([65, 0, 66])})); " &
    "const res = await http.get('http://127.0.0.1:18122/'); " &
    "http.close(srv.port); " &
    "return res.headers['content-length'] + ':' + res.body.length + " &
    "':' + res.body.charCodeAt(1); })()") == "3:3:0"

test "handler Uint8Array body rejects bad status and headers":
  check runCode(preamble &
    "const srv = http.serve(18123, req => " &
    "req.path === '/s' ? {status: 99, body: new Uint8Array([1])} : " &
    "{headers: {x: 42}, body: new Uint8Array([1])}); " &
    "const a = await http.get('http://127.0.0.1:18123/s'); " &
    "const b = await http.get('http://127.0.0.1:18123/h'); " &
    "http.close(srv.port); " &
    "return a.status + ':' + b.status; })()") == "500:500"

test "handler array header values send repeated headers":
  check runCode(preamble &
    "const srv = http.serve(18125, req => " &
    "({headers: {'X-Multi': ['a', 'b'], 'X-Single': 's'}, body: 'x'})); " &
    "const res = await http.fetch('http://127.0.0.1:18125/'); " &
    "http.close(srv.port); " &
    "return res.status + ':' + res.headers['x-multi'] + ':' + " &
    "res.headers['x-single']; })()") == "200:b:s"

test "multipart field parses uploads and cleans tmpfiles":
  check runCode(preamble &
    "const os = require('std/os'); " &
    "var saved = ''; " &
    "const srv = http.serve(18126, req => { " &
    "if (req.path === '/u') { " &
    "const f = req.multipart.files[0]; saved = f.path; " &
    "return {body: JSON.stringify({fields: req.multipart.fields, " &
    "file: f.filename + ':' + f.size})}; } " &
    "return {body: String(os.isFile(saved))}; }); " &
    "const u = await http.post('http://127.0.0.1:18126/u', " &
    "'--b26\\r\\nContent-Disposition: form-data; name=\"t\"\\r\\n\\r\\nhi\\r\\n' + " &
    "'--b26\\r\\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\\r\\n' + " &
    "'Content-Type: text/plain\\r\\n\\r\\n0123456789\\r\\n--b26--\\r\\n', " &
    "{headers: {'Content-Type': 'multipart/form-data; boundary=b26'}}); " &
    "const c = await http.get('http://127.0.0.1:18126/check'); " &
    "http.close(srv.port); " &
    "return u.status + ':' + u.body + ':' + c.body; })()") ==
    "200:{\"fields\":{\"t\":\"hi\"},\"file\":\"a.txt:10\"}:false"

test "file return serves zero-copy with ranges and conditionals":
  check runCode(preamble &
    "const srv = http.serve(18127, req => { " &
    "if (req.path === '/bad') return {file: 42}; " &
    "return {file: 'tests/fixtures/hello.txt', " &
    "headers: {'X-Test': 'yes', 'Content-Type': 'ignored'}}; }); " &
    "const a = await http.get('http://127.0.0.1:18127/'); " &
    "const b = await http.fetch('http://127.0.0.1:18127/', " &
    "{headers: {Range: 'bytes=0-3'}}); " &
    "const c = await http.fetch('http://127.0.0.1:18127/', " &
    "{headers: {'If-None-Match': a.headers['etag']}}); " &
    "const d = await http.fetch('http://127.0.0.1:18127/bad'); " &
    "http.close(srv.port); " &
    "return a.status + ':' + a.body + ':' + a.headers['x-test'] + ':' + " &
    "b.status + ':' + b.body + ':' + b.headers['content-range'] + ':' + " &
    "c.status + ':' + d.status; })()") ==
    "200:hello\n:yes:206:hell:bytes 0-3/6:304:500"

test "client decodes invalid UTF-8 with replacement":
  check runCode(preamble &
    "const srv = http.serve(18124, req => " &
    "({body: new Uint8Array([65, 255, 66])})); " &
    "const res = await http.get('http://127.0.0.1:18124/'); " &
    "http.close(srv.port); " &
    "return res.headers['content-length'] + ':' + res.body.length + " &
    "':' + res.body.charCodeAt(1); })()") == "3:3:65533"
