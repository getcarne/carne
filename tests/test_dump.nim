import std/[os, unittest]

import carne/pkg/dump
import carne/pkg/pkgman

test "splitDumpRef handles names, @refs and #refs":
  check splitDumpRef("concarne") == ("concarne", "")
  check splitDumpRef("concarne@0.2.0") == ("concarne", "0.2.0")
  check splitDumpRef("concarne#main") == ("concarne", "main")
  check splitDumpRef("  concarne  ") == ("concarne", "")
  check splitDumpRef("@") == ("@", "")

test "dumpManifest reads the cwd package upward":
  let dir = getTempDir() / "carne_dump_cwd"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir / "sub")
  defer: removeDir(dir)
  let content = "{\n  \"name\": \"greet\",\n  \"version\": \"0.1.0\"\n}\n"
  writeFile(dir / "package.json", content)
  check dumpManifest(dir / "sub", "") == content

test "dumpManifest errors without a package.json":
  let dir = getTempDir() / "carne_dump_missing"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  expect DumpError:
    discard dumpManifest(dir, "")
  expect DumpError:
    discard dumpManifest(dir, "  ")

test "dumpManifest reads an installed develop package":
  let home = getTempDir() / "carne_dump_home"
  if dirExists(home):
    removeDir(home)
  createDir(home)
  defer: removeDir(home)
  let src = getTempDir() / "carne_dump_src"
  if dirExists(src):
    removeDir(src)
  createDir(src)
  defer: removeDir(src)
  let content = "{\n  \"name\": \"greet\",\n  \"version\": \"0.1.0\",\n" &
    "  \"description\": \"Say hi\",\n  \"license\": \"MIT\"\n}\n"
  writeFile(src / "package.json", content)
  writeFile(src / "index.js", "module.exports = {};\n")
  let cfg = newCarnePkgConfig(home, ensureSource = false)
  check cfg.pkgDevelop(src)
  check dumpManifest(home, "greet", home, false) == content
  check dumpManifest(home, "greet@0.1.0", home, false) == content
  expect DumpError:
    discard dumpManifest(home, "nope", home, false)
  expect DumpError:
    discard dumpManifest(home, "greet@9.9.9", home, false)

test "dumpCommand returns exit codes":
  let dir = getTempDir() / "carne_dump_cmd"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "package.json",
    "{\"name\": \"greet\", \"version\": \"0.1.0\"}")
  check dumpCommand(dir, "") == 0
  check dumpCommand(dir, "not-installed-xyz") == 1
