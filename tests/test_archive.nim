from std/os import getTempDir, `/`, createDir, dirExists, fileExists,
  removeDir, removeFile
from std/strutils import repeat
import unittest

import carne
import carne/modules
import carne/std/archive as stdarchive
import carne/std/os as stdos
## Both std/os (above) and carne/std/os bind the name `os`: never
## qualify with bare `os` in this file, use the aliases unqualified.

registerStd("std/archive", stdarchive.install)
registerStd("std/os", stdos.install)

proc tmpPath(name: string): string =
  getTempDir() / ("carne_archive_" & name)

proc rmTree(d: string) =
  if dirExists(d):
    removeDir(d)

test "compress roundtrips every format":
  check runCode(
    "const a = require('std/archive'); " &
    "const s = 'hello world, '.repeat(20); " &
    "const bad = []; " &
    "for (const f of ['gz','zz','lz4','bz2','br']) { " &
    "  const c = a.compress(f, s); " &
    "  if (!(c instanceof Uint8Array) || c.length === 0) { bad.push(f + ':compress'); continue; } " &
    "  const b = a.decompress(f, c); " &
    "  if (b.length !== s.length) { bad.push(f + ':len'); continue; } " &
    "  for (let i = 0; i < s.length; i++) " &
    "    if (b[i] !== s.charCodeAt(i)) { bad.push(f + ':byte'); break; } " &
    "} " &
    "JSON.stringify(bad)") == "[]"

test "compress preserves NUL and high bytes":
  check runCode(
    "const a = require('std/archive'); " &
    "const src = new Uint8Array(256); " &
    "for (let i = 0; i < 256; i++) src[i] = i; " &
    "const back = a.decompress('gz', a.compress('gz', src)); " &
    "let ok = back.length === 256; " &
    "for (let i = 0; i < 256 && ok; i++) ok = back[i] === i; " &
    "ok") == "true"

test "compress aliases, level and magic bytes":
  check runCode(
    "const a = require('std/archive'); " &
    "const c = a.compress('gzip', 'hello', 1); " &
    "c[0] + ',' + c[1]") == "31,139"
  check runCode(
    "const a = require('std/archive'); " &
    "const c = a.compress('.GZ', 'hello'); " &
    "c[0] + ',' + c[1]") == "31,139"
  check runCode(
    "const a = require('std/archive'); " &
    "const c = a.compress('bz2', 'hello', 9); " &
    "c[0] + ',' + c[1] + ',' + c[2] + ',' + c[3]") == "66,90,104,57"
  expect CarneError:
    discard runCode("require('std/archive').compress('nope', 'x')")
  expect CarneError:
    discard runCode("require('std/archive').decompress('tar', 'x')")

test "compressFile roundtrip":
  let src = tmpPath("src.txt")
  let enc = tmpPath("src.txt.gz")
  let back = tmpPath("back.txt")
  defer: removeFile(src)
  defer: removeFile(enc)
  defer: removeFile(back)
  writeFile(src, "file payload ".repeat(50))
  discard runCode("require('std/archive').compressFile('gz', '" &
    src & "', '" & enc & "')")
  check fileExists(enc)
  discard runCode("require('std/archive').decompressFile('gz', '" &
    enc & "', '" & back & "')")
  check readFile(back) == "file payload ".repeat(50)

test "create, writeFileBytes, list and read roundtrip":
  let p = tmpPath("mem.tar")
  defer: removeFile(p)
  check runCode(
    "const a = require('std/archive'); " &
    "const os = require('std/os'); " &
    "const blob = a.create('tar', [" &
    "  {name: 'a.txt', data: 'alpha'}, " &
    "  {name: 'bin.dat', data: new Uint8Array([0, 1, 255, 128])}, " &
    "  {name: 'sub/'}, " &
    "  {name: 'sub/b.txt', data: 'beta'}]); " &
    "blob instanceof Uint8Array && blob.length > 0") == "true"
  discard runCode(
    "const a = require('std/archive'); " &
    "const os = require('std/os'); " &
    "os.writeFileBytes('" & p & "', a.create('tar', [" &
    "  {name: 'a.txt', data: 'alpha'}, " &
    "  {name: 'bin.dat', data: new Uint8Array([0, 1, 255, 128])}, " &
    "  {name: 'sub/'}, " &
    "  {name: 'sub/b.txt', data: 'beta'}]))")
  check runCode(
    "JSON.stringify(require('std/archive').list('" & p &
    "').sort())") == """["a.txt","bin.dat","sub","sub/b.txt"]"""
  check runCode(
    "const items = require('std/archive').read('" & p & "'); " &
    "const m = {}; " &
    "for (const e of items) m[e.name] = Array.from(e.data); " &
    "JSON.stringify(m)") ==
    """{"a.txt":[97,108,112,104,97],"bin.dat":[0,1,255,128],""" &
    """"sub/b.txt":[98,101,116,97]}"""

test "createFile zip with compression extracts to disk":
  let z = tmpPath("out.zip")
  let dst = tmpPath("zip_out")
  defer: removeFile(z)
  defer: rmTree(dst)
  discard runCode(
    "require('std/archive').createFile('zip', [" &
    "  {name: 'a.txt', data: 'alpha'}, " &
    "  {name: 'sub/b.txt', data: 'beta'}], '" & z & "')")
  check fileExists(z)
  check runCode(
    "JSON.stringify(require('std/archive').list('" & z &
    "').sort())") == """["a.txt","sub","sub/b.txt"]"""
  discard runCode(
    "require('std/archive').extract('" & z & "', '" & dst & "')")
  check readFile(dst / "a.txt") == "alpha"
  check readFile(dst / "sub" / "b.txt") == "beta"

test "create entries from disk paths":
  let f1 = tmpPath("disk1.txt")
  let f2 = tmpPath("disk2.txt")
  let z = tmpPath("disk.tar")
  defer: removeFile(f1)
  defer: removeFile(f2)
  defer: removeFile(z)
  writeFile(f1, "one")
  writeFile(f2, "two")
  discard runCode(
    "require('std/archive').createFile('tar', [" &
    "  {name: 'renamed.txt', path: '" & f1 & "'}, " &
    "  {path: '" & f2 & "'}], '" & z & "')")
  check runCode(
    "JSON.stringify(require('std/archive').list('" & z &
    "').sort())") == """["carne_archive_disk2.txt","renamed.txt"]"""
  check runCode(
    "const items = require('std/archive').read('" & z & "'); " &
    "const m = {}; " &
    "for (const e of items) m[e.name] = e.data.length; " &
    "JSON.stringify(m)") ==
    """{"renamed.txt":3,"carne_archive_disk2.txt":3}"""

test "archiveDir, identify and extract roundtrip":
  let tree = tmpPath("tree")
  let blob = tmpPath("tree.tar.gz")
  let dst = tmpPath("tree_out")
  let gzOnly = tmpPath("only.gz")
  defer: rmTree(tree)
  defer: removeFile(blob)
  defer: rmTree(dst)
  defer: removeFile(gzOnly)
  createDir(tree / "sub")
  writeFile(tree / "a.txt", "alpha")
  writeFile(tree / "sub" / "b.txt", "beta")
  discard runCode("require('std/archive').archiveDir('tar', '" & tree &
    "', '" & blob & "', {compression: 'gz', root: 'site'})")
  check runCode("JSON.stringify(require('std/archive').identify('" &
    blob & "'))") == """{"archive":"tar","compression":"gz"}"""
  discard runCode("require('std/archive').extract('" & blob & "', '" &
    dst & "')")
  check readFile(dst / "site" / "a.txt") == "alpha"
  check readFile(dst / "site" / "sub" / "b.txt") == "beta"
  discard runCode("require('std/archive').compressFile('gz', '" &
    tree / "a.txt" & "', '" & gzOnly & "')")
  check runCode("JSON.stringify(require('std/archive').identify('" &
    gzOnly & "'))") == """{"archive":null,"compression":"gz"}"""

test "archiveDir root option renames the top dir":
  let tree = tmpPath("roottree")
  let blob = tmpPath("roottree.tar")
  defer: rmTree(tree)
  defer: removeFile(blob)
  createDir(tree)
  writeFile(tree / "a.txt", "alpha")
  discard runCode("require('std/archive').archiveDir('tar', '" & tree &
    "', '" & blob & "', {root: 'docs'})")
  check runCode(
    "JSON.stringify(require('std/archive').list('" & blob &
    "').sort())") == """["docs","docs/a.txt"]"""

test "os writeFileBytes roundtrips binary":
  let p = tmpPath("bytes.bin")
  defer: removeFile(p)
  check runCode(
    "const os = require('std/os'); " &
    "const src = new Uint8Array(256); " &
    "for (let i = 0; i < 256; i++) src[i] = i; " &
    "os.writeFileBytes('" & p & "', src); " &
    "const back = os.readFileBytes('" & p & "'); " &
    "let ok = back.length === 256; " &
    "for (let i = 0; i < 256 && ok; i++) ok = back[i] === i; " &
    "ok") == "true"
  check runCode(
    "const os = require('std/os'); " &
    "os.writeFileBytes('" & p & "', 'hi'); " &
    "os.readFile('" & p & "')") == "hi"

test "archive rejects bad input":
  expect CarneError:
    discard runCode("require('std/archive').compress('gz')")
  expect CarneError:
    discard runCode("require('std/archive').compress('gz', 42)")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', 'nope')")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', [42])")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', [{}])")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', " &
      "[{name: 'x', data: 'a', path: 'b'}])")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', [{name: '../evil'}])")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', [{name: '/abs'}])")
  expect CarneError:
    discard runCode(
      "require('std/archive').create('tar', [], 'gz')")
  expect CarneError:
    discard runCode(
      "require('std/archive').decompress('gz', new Uint8Array([1,2,3]))")
  expect CarneError:
    discard runCode(
      "require('std/archive').list('/no/such/carne_archive_xyz')")
  expect CarneError:
    discard runCode(
      "require('std/archive').extract('/no/such/carne_archive_xyz', '/tmp/x')")
  expect CarneError:
    discard runCode(
      "require('std/archive').compressFile('gz', '/no/such/src', '/tmp/x')")
