import std/[options, os, strutils, tables]
import unittest

import carne/pkg/pkgman

proc freshHome(): string =
  result = getTempDir() / "carne_pkgman_test"
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc gitInitCommit(dir: string) =
  ## `git init` + commit everything in `dir` (test fixtures only).
  discard execShellCmd("git -C " & quoteShell(dir) & " init -q")
  discard execShellCmd("git -C " & quoteShell(dir) & " add -A")
  discard execShellCmd("git -C " & quoteShell(dir) &
    " commit -qm init")

proc makeJsRepo(dir, name, version: string) =
  ## Minimal JS package fixture: package.json + main entry.
  createDir(dir / "src")
  writeFile(dir / "package.json", "{\"name\": \"" & name &
    "\", \"version\": \"" & version & "\", \"main\": \"src/index.js\"}")
  writeFile(dir / "src" / "index.js", "console.log('hi');\n")

test "config roots at override and registers source":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  check cfg.defaultSourceName == "carne"
  check cfg.defaultRegistryUrl == pkgRegistryUrl
  check cfg.requiredManifestFile == some(pkgManifestFileName)
  var found = false
  for src in cfg.loadSources():
    if src.name == "carne" and src.url == pkgRegistryUrl:
      found = true
  check found

test "ensurePkgSource heals a stale registry URL":
  let home = freshHome()
  defer: removeDir(home)
  let seed = newCarnePkgConfig(rootPath = home, ensureSource = false)
  seed.saveSources(@[Source(name: "carne",
    url: "https://raw.githubusercontent.com/carne/pkgs/main/packages.json")])
  discard newCarnePkgConfig(rootPath = home)
  let cfg = newCarnePkgConfig(rootPath = home)
  var urls: seq[string] = @[]
  for src in cfg.loadSources():
    if src.name == "carne":
      urls.add(src.url)
  check urls == @[pkgRegistryUrl]

test "ensurePkgSource keeps custom sources while healing":
  let home = freshHome()
  defer: removeDir(home)
  let seed = newCarnePkgConfig(rootPath = home, ensureSource = false)
  seed.saveSources(@[
    Source(name: "carne",
      url: "https://raw.githubusercontent.com/openpeeps/carnepkgs/main/packages.json"),
    Source(name: "mirror", url: "https://example.com/mirror.json"),
  ])
  discard newCarnePkgConfig(rootPath = home)
  let cfg = newCarnePkgConfig(rootPath = home)
  var carneUrls: seq[string] = @[]
  var mirrorKept = false
  for src in cfg.loadSources():
    if src.name == "carne":
      carneUrls.add(src.url)
    if src.name == "mirror" and src.url == "https://example.com/mirror.json":
      mirrorKept = true
  check carneUrls == @[pkgRegistryUrl]
  check mirrorKept

test "pkg list on empty home does not raise":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  cfg.pkgList()

test "develop + resolve roundtrip":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let pkgDir = home / "fixture-greet"
  createDir(pkgDir / "src")
  writeFile(pkgDir / "package.json", """{
    "name": "greet", "version": "0.1.0", "main": "src/greet.js"
  }""")
  writeFile(pkgDir / "src" / "greet.js", "console.log('hi');\n")
  check cfg.pkgDevelop(pkgDir)
  let resolved = cfg.resolvePkgImport("pkg/greet")
  check resolved.isSome
  check resolved.get == pkgDir / "src" / "greet.js"

test "resolve rejects unknown and escapes":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  check cfg.resolvePkgImport("pkg/nonexistent").isNone
  check cfg.resolvePkgImport("std/env").isNone
  check cfg.resolvePkgImport("pkg/../escape").isNone
  check cfg.resolvePkgImport("pkg/").isNone

test "entry point fallbacks":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let noMain = home / "fixture-nomain"
  createDir(noMain)
  writeFile(noMain / "package.json",
    """{"name": "nomain", "version": "1.0.0"}""")
  writeFile(noMain / "index.js", "var a = 1;\n")
  check cfg.packageEntryPoint(noMain, "nomain") == noMain / "index.js"
  let empty = home / "fixture-empty"
  createDir(empty)
  check cfg.packageEntryPoint(empty, "empty") == ""

test "forge alias expansion":
  check expandForgeAlias("gh:openpeeps/tim") ==
    "https://github.com/openpeeps/tim"
  check expandForgeAlias("github:openpeeps/tim") ==
    "https://github.com/openpeeps/tim"
  check expandForgeAlias("gl:group/proj") == "https://gitlab.com/group/proj"
  check isForgeAliasShape("gh:openpeeps/tim")
  check not isForgeAliasShape("https://github.com/openpeeps/tim")
  check not isForgeAliasShape("greet")
  expect ValueError:
    discard expandForgeAlias("npm:foo@1.2")

test "url install of js repo (basename differs from package name)":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let repo = home / "some-checkout-dir"
  makeJsRepo(repo, "greet-url", "0.2.0")
  gitInitCommit(repo)
  check cfg.pkgInstall("greet-url", url = repo)
  let resolved = cfg.resolvePkgImport("pkg/greet-url")
  check resolved.isSome
  check resolved.get.fileExists

test "url install rejects repo without package.json":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let repo = home / "not-a-package"
  createDir(repo)
  writeFile(repo / "README.md", "# hello\n")
  gitInitCommit(repo)
  check not cfg.pkgInstall("nogood", url = repo)
  check not cfg.installedRecordsAll().hasKey("nogood")
  check not dirExists(cfg.pkgsCachePath() / "nogood")

test "url install rejects invalid package.json":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let repo = home / "bad-manifest"
  createDir(repo)
  writeFile(repo / "package.json", """{"version": "1.0.0"}""")
  gitInitCommit(repo)
  check not cfg.pkgInstall("bad", url = repo)
  check not cfg.installedRecordsAll().hasKey("bad")

test "url install with #ref checks out the branch":
  let home = freshHome()
  defer: removeDir(home)
  let cfg = newCarnePkgConfig(rootPath = home)
  let repo = home / "ref-repo"
  makeJsRepo(repo, "greet-ref", "0.1.0")
  gitInitCommit(repo)
  discard execShellCmd("git -C " & quoteShell(repo) & " checkout -qb feature")
  writeFile(repo / "src" / "index.js", "console.log('feature');\n")
  discard execShellCmd("git -C " & quoteShell(repo) & " add -A")
  discard execShellCmd("git -C " & quoteShell(repo) &
    " commit -qm feature")
  check cfg.pkgInstall("greet-ref", url = repo & "#feature")
  let resolved = cfg.resolvePkgImport("pkg/greet-ref")
  check resolved.isSome
  check readFile(resolved.get).contains("feature")
