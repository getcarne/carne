import std/[os, strutils, unittest]
import pkg/openparser/json
import pkg/semver

import carne/pkg/bump

test "parseBumpLevel reads levels case-insensitively":
  check parseBumpLevel("major") == blMajor
  check parseBumpLevel("Minor") == blMinor
  check parseBumpLevel("PATCH") == blPatch
  expect BumpError:
    discard parseBumpLevel("mini")
  expect BumpError:
    discard parseBumpLevel("")

test "bumpVersion resets lower levels and drops metadata":
  check $bumpVersion(parseVersion("1.2.3"), blPatch) == "1.2.4"
  check $bumpVersion(parseVersion("1.2.3"), blMinor) == "1.3.0"
  check $bumpVersion(parseVersion("1.2.3"), blMajor) == "2.0.0"
  check $bumpVersion(parseVersion("0.0.0"), blPatch) == "0.0.1"
  check $bumpVersion(parseVersion("1.2.3-alpha"), blPatch) == "1.2.4"
  check $bumpVersion(parseVersion("1.2.3-alpha+001"), blMinor) == "1.3.0"

test "splitSpecPrefix separates operators":
  check splitSpecPrefix("^1.2.3") == ("^", "1.2.3")
  check splitSpecPrefix("~ 1.2.3") == ("~", "1.2.3")
  check splitSpecPrefix(">=1.2.3") == (">=", "1.2.3")
  check splitSpecPrefix("1.2.3") == ("", "1.2.3")
  check splitSpecPrefix("v1.2.3") == ("v", "1.2.3")

test "bumpSpec keeps prefixes, rejects versionless specs":
  check bumpSpec("^0.1.0", blPatch) == "^0.1.1"
  check bumpSpec("~1.2.3", blMinor) == "~1.3.0"
  check bumpSpec(">=1.2.3", blMajor) == ">=2.0.0"
  check bumpSpec("1.2.3", blPatch) == "1.2.4"
  check bumpSpec("npm:real@^2.0.0", blPatch) == "npm:real@^2.0.1"
  expect BumpError:
    discard bumpSpec("*", blPatch)
  expect BumpError:
    discard bumpSpec("latest", blPatch)
  expect BumpError:
    discard bumpSpec("", blPatch)
  expect BumpError:
    discard bumpSpec("git+https://example.com/x.git", blPatch)
  expect BumpError:
    discard bumpSpec("github:user/repo", blPatch)
  expect BumpError:
    discard bumpSpec("npm:real@", blPatch)
  expect BumpError:
    discard bumpSpec("^1.2", blPatch)

test "setSpecVersion preserves prefixes, exact for stars":
  check setSpecVersion("^0.1.0", parseVersion("0.2.0")) == "^0.2.0"
  check setSpecVersion("~1.2.3", parseVersion("2.0.0")) == "~2.0.0"
  check setSpecVersion("*", parseVersion("1.0.0")) == "1.0.0"
  check setSpecVersion("latest", parseVersion("1.0.0")) == "1.0.0"
  check setSpecVersion("npm:real@^2.0.0", parseVersion("3.0.0")) ==
    "npm:real@3.0.0"
  expect BumpError:
    discard setSpecVersion("git+https://example.com/x.git",
      parseVersion("1.0.0"))
  expect BumpError:
    discard setSpecVersion("github:user/repo", parseVersion("1.0.0"))

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

test "bumpCommand patch-bumps and keeps formatting":
  let dir = freshDir("carne_bump_own")
  defer: removeDir(dir)
  let before = "{\n  \"name\": \"greet\",\n  \"version\": \"0.1.0\",\n" &
    "  \"description\": \"Say hi\",\n  \"license\": \"MIT\"\n}\n"
  writeFile(dir / "package.json", before)
  check bumpCommand(dir, "", "", "") == 0
  check readFile(dir / "package.json") == before.replace(
    "\"version\": \"0.1.0\"", "\"version\": \"0.1.1\"")

test "bumpCommand sets explicit versions and levels":
  let dir = freshDir("carne_bump_levels")
  defer: removeDir(dir)
  writeFile(dir / "package.json",
    "{\"name\": \"greet\", \"version\": \"0.1.0\"}")
  check bumpCommand(dir, "2.0.0", "", "") == 0
  check fromJson(readFile(dir / "package.json"))["version"].getStr() ==
    "2.0.0"
  check bumpCommand(dir, "", "minor", "") == 0
  check fromJson(readFile(dir / "package.json"))["version"].getStr() ==
    "2.1.0"
  check bumpCommand(dir, "", "major", "") == 0
  check fromJson(readFile(dir / "package.json"))["version"].getStr() ==
    "3.0.0"

test "bumpCommand rejects bad input":
  let dir = freshDir("carne_bump_bad")
  defer: removeDir(dir)
  writeFile(dir / "package.json",
    "{\"name\": \"greet\", \"version\": \"0.1.0\"}")
  check bumpCommand(dir, "nope", "", "") == 1
  check bumpCommand(dir, "1.2.3", "minor", "") == 1
  check bumpCommand(dir, "", "mini", "") == 1
  check bumpCommand(dir, "", "", "missing-dep") == 1
  # Failed bumps leave the file untouched.
  check fromJson(readFile(dir / "package.json"))["version"].getStr() ==
    "0.1.0"

test "bumpCommand needs a package.json":
  let dir = freshDir("carne_bump_missing")
  defer: removeDir(dir)
  check bumpCommand(dir, "", "", "") == 1

test "bumpCommand bumps one dep across groups":
  let dir = freshDir("carne_bump_dep")
  defer: removeDir(dir)
  writeFile(dir / "package.json", "{\n" &
    "  \"name\": \"app\",\n  \"version\": \"1.0.0\",\n" &
    "  \"dependencies\": {\n    \"concarne\": \"^0.1.0\",\n" &
    "    \"other\": \"1.0.0\"\n  },\n" &
    "  \"devDependencies\": {\n    \"testlib\": \"~1.0.0\"\n  }\n}\n")
  check bumpCommand(dir, "", "", "concarne") == 0
  var root = fromJson(readFile(dir / "package.json"))
  check root["dependencies"]["concarne"].getStr() == "^0.1.1"
  check root["dependencies"]["other"].getStr() == "1.0.0"
  check root["devDependencies"]["testlib"].getStr() == "~1.0.0"
  check root["version"].getStr() == "1.0.0"
  check bumpCommand(dir, "2.0.0", "", "testlib") == 0
  root = fromJson(readFile(dir / "package.json"))
  check root["devDependencies"]["testlib"].getStr() == "~2.0.0"
  check bumpCommand(dir, "", "major", "concarne") == 0
  root = fromJson(readFile(dir / "package.json"))
  check root["dependencies"]["concarne"].getStr() == "^1.0.0"

test "bumpCommand refuses unbumpable dep specs":
  let dir = freshDir("carne_bump_depbad")
  defer: removeDir(dir)
  writeFile(dir / "package.json", "{\"name\": \"app\", " &
    "\"version\": \"1.0.0\", \"dependencies\": {" &
    "\"any\": \"*\", \"git\": \"github:user/repo\"}}")
  check bumpCommand(dir, "", "", "any") == 1
  check bumpCommand(dir, "", "", "git") == 1
  check bumpCommand(dir, "1.0.0", "", "any") == 0
  check fromJson(readFile(dir / "package.json"))["dependencies"][
    "any"].getStr() == "1.0.0"

test "dep lookup stays inside dependency groups":
  let dir = freshDir("carne_bump_scope")
  defer: removeDir(dir)
  # "concarne" also appears in description text and keywords; only
  # the dependencies entry may move.
  let before = "{\n  \"name\": \"app\",\n  \"version\": \"1.0.0\",\n" &
    "  \"description\": \"uses concarne ^0.1.0 daily\",\n" &
    "  \"keywords\": [\"concarne\"],\n" &
    "  \"dependencies\": {\"concarne\": \"^0.1.0\"}\n}\n"
  writeFile(dir / "package.json", before)
  check bumpCommand(dir, "", "", "concarne") == 0
  let after = readFile(dir / "package.json")
  check "\"description\": \"uses concarne ^0.1.0 daily\"" in after
  check "\"dependencies\": {\"concarne\": \"^0.1.1\"}" in after
