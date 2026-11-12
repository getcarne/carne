import std/[os, strutils, unittest]
import pkg/openparser/json

import carne/pkg/init
import carne/pkg/pkgmanifest

test "validPkgName follows the manifest rules":
  check validPkgName("my-pkg")
  check validPkgName("foo")
  check validPkgName("a1")
  check not validPkgName("")
  check not validPkgName(".foo")
  check not validPkgName("_foo")
  check not validPkgName("Foo")
  check not validPkgName("a b")
  check not validPkgName("@scope/x")
  check not validPkgName("a".repeat(215))

test "buildPackageJson round-trips through the manifest parser":
  let src = buildPackageJson("greet", "0.1.0", "Say hi", "Ada",
    "MIT", @["carne", "demo"])
  let m = parsePackageManifest(src, "package.json")
  check m.name == "greet"
  check m.version == "0.1.0"
  check m.description == "Say hi"
  check m.license == "MIT"
  let doc = fromJson(src)
  check doc["main"].getStr() == "index.js"
  check doc["author"].getStr() == "Ada"
  var tags: seq[string] = @[]
  for k in doc["keywords"]:
    tags.add(k.getStr())
  check tags == @["carne", "demo"]

test "buildPackageJson omits an empty author":
  let doc = fromJson(buildPackageJson("greet", "0.1.0", "Say hi", "",
    "MIT", @["carne"]))
  check not doc.hasKey("author")

test "initCommand scaffolds with -Y in an empty dir":
  let dir = getTempDir() / "carne_init_empty"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  check initCommand(dir, "", true) == 0
  let mf = dir / "package.json"
  check fileExists(mf)
  let m = parsePackageManifest(readFile(mf), mf)
  check m.name == "carne_init_empty"
  check m.version == "0.1.0"
  check m.description.len > 0
  check m.license == "MIT"
  check fileExists(dir / "index.js")
  check fileExists(dir / "tests" / "carne_init_empty.test.js")

test "initCommand scaffolds into a fresh subdir, creating it":
  let dir = getTempDir() / "carne_init_sub"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  check initCommand(dir, "my-pkg", true) == 0
  check fileExists(dir / "my-pkg" / "package.json")
  check fileExists(dir / "my-pkg" / "index.js")
  check fileExists(dir / "my-pkg" / "tests" / "my-pkg.test.js")
  let m = parsePackageManifest(
    readFile(dir / "my-pkg" / "package.json"), "package.json")
  check m.name == "my-pkg"

test "initCommand never overwrites an existing package.json":
  let dir = getTempDir() / "carne_init_exists"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "package.json",
    "{\"name\": \"mine\", \"version\": \"9.9.9\"}")
  check initCommand(dir, "", true) == 1
  check readFile(dir / "package.json") ==
    "{\"name\": \"mine\", \"version\": \"9.9.9\"}"

test "initCommand refuses a non-empty cwd without a target":
  let dir = getTempDir() / "carne_init_full"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "notes.txt", "hi")
  check initCommand(dir, "", true) == 1
  check not fileExists(dir / "package.json")

test "initCommand refuses a non-empty target subdir":
  let dir = getTempDir() / "carne_init_fullsub"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir / "taken")
  defer: removeDir(dir)
  writeFile(dir / "taken" / "notes.txt", "hi")
  check initCommand(dir, "taken", true) == 1
  check not fileExists(dir / "taken" / "package.json")

test "initCommand validates the name before touching the filesystem":
  let dir = getTempDir() / "carne_init_badname"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  check initCommand(dir, "Not A Name", true) == 1
  check not dirExists(dir / "Not A Name")
