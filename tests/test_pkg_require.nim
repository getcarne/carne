import std/os
import std/strutils
import unittest

import carne
import carne/modules
import carne/pkg/loader
import carne/pkg/pkgman
import carne/std/http

registerStd("std/http", http.install)

proc freshHome(): string =
  result = getTempDir() / "carne_pkgreq_test"
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc gitCommit(dir, msg: string) =
  discard execShellCmd("git -C " & quoteShell(dir) & " add -A")
  discard execShellCmd("git -C " & quoteShell(dir) &
    " commit -qm " & quoteShell(msg))

proc gitInit(dir: string) =
  discard execShellCmd("git -C " & quoteShell(dir) & " init -q")

proc gitTag(dir, tag: string) =
  discard execShellCmd("git -C " & quoteShell(dir) & " tag " & tag)

proc setupFixtures(home: string): DatpkgrConfig =
  result = newCarnePkgConfig(rootPath = home)
  # greet: two tagged versions, main + relative require chain.
  let greet = home / "repo-greet"
  createDir(greet / "src")
  writeFile(greet / "package.json",
    """{"name": "greet", "version": "0.1.0", "main": "src/index.js"}""")
  writeFile(greet / "src" / "index.js",
    "const u = require(\"./util\");\n" &
    "module.exports = { who: () => \"greet-0.1.0+\" + u.suffix() };\n")
  writeFile(greet / "src" / "util.js",
    "module.exports = { suffix: () => \"u1\" };\n")
  gitInit(greet)
  gitCommit(greet, "v1")
  gitTag(greet, "0.1.0")
  writeFile(greet / "src" / "index.js",
    "const u = require(\"./util\");\n" &
    "module.exports = { who: () => \"greet-0.2.0+\" + u.suffix() };\n")
  writeFile(greet / "src" / "util.js",
    "module.exports = { suffix: () => \"u2\" };\n")
  gitCommit(greet, "v2")
  gitTag(greet, "0.2.0")
  check result.pkgInstall("greet", url = greet)
  check result.pkgInstall("greet", url = greet & "#0.1.0")
  # expkg: exports map only (+ subpath file, no main).
  let expkg = home / "repo-expkg"
  createDir(expkg / "src")
  writeFile(expkg / "package.json", """{"name": "expkg", "version": "1.0.0",
    "exports": {".": "./src/entry.js"}}""")
  writeFile(expkg / "src" / "entry.js",
    "module.exports = { tag: () => \"entry\" };\n")
  writeFile(expkg / "extra.js",
    "module.exports = { tag: () => \"extra\" };\n")
  gitInit(expkg)
  gitCommit(expkg, "init")
  check result.pkgInstall("expkg", url = expkg)
  # both: main and exports (exports wins, Node parity).
  let both = home / "repo-both"
  createDir(both)
  writeFile(both / "package.json", """{"name": "both", "version": "1.0.0",
    "main": "main.js", "exports": {".": "./exp.js"}}""")
  writeFile(both / "main.js", "module.exports = { tag: () => \"main\" };\n")
  writeFile(both / "exp.js", "module.exports = { tag: () => \"exp\" };\n")
  gitInit(both)
  gitCommit(both, "init")
  check result.pkgInstall("both", url = both)
  # noentry: manifest only, nothing loadable.
  let noentry = home / "repo-noentry"
  createDir(noentry)
  writeFile(noentry / "package.json",
    """{"name": "noentry", "version": "1.0.0"}""")
  gitInit(noentry)
  gitCommit(noentry, "init")
  check result.pkgInstall("noentry", url = noentry)
  # esmpkg: ESM syntax, out of scope with a clear error.
  let esmpkg = home / "repo-esm"
  createDir(esmpkg)
  writeFile(esmpkg / "package.json",
    """{"name": "esmpkg", "version": "1.0.0", "main": "index.js"}""")
  writeFile(esmpkg / "index.js", "export const x = 1;\n")
  gitInit(esmpkg)
  gitCommit(esmpkg, "init")
  check result.pkgInstall("esmpkg", url = esmpkg)
  initPkgLoader(result)

test "require pkg main with relative chain":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  check runCode("require('pkg/greet').who()") == "greet-0.2.0+u2"

test "require pkg caches instances":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  check runCode("require('pkg/greet') === require('pkg/greet')") == "true"

test "require pkg pins @version":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  check runCode("require('pkg/greet@0.1.0').who()") == "greet-0.1.0+u1"

test "pkg subpath traversal throws":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  for spec in ["pkg/greet/sub/../../../etc/hosts",
      "pkg/greet/../greet",
      "pkg/greet@0.1.0/../../etc/hosts",
      "pkg/expkg/sub/../extra",
      "pkg/greet@",
      "pkg/greet@.."]:
    expect CarneError:
      discard runCode("require('" & spec & "')")

proc setupLinkFixtures(home: string): DatpkgrConfig =
  # Develop checkouts keep symlinks live (registry installs copy file
  # contents instead), so symlink escapes are modelled with
  # `developPackage` - the editable path `resolveInstalledPath`
  # prefers.
  result = newCarnePkgConfig(rootPath = home)
  let outside = home / "outside-marker.js"
  writeFile(outside, "module.exports = { tag: () => \"pwned\" };\n")
  let checkout = home / "checkout-linkpkg"
  createDir(checkout / "lib")
  writeFile(checkout / "package.json",
    """{"name": "linkpkg", "version": "1.0.0", "main": "index.js"}""")
  writeFile(checkout / "index.js",
    "module.exports = { tag: () => \"ok\" };\n")
  writeFile(checkout / "real.js",
    "module.exports = { tag: () => \"real\" };\n")
  createSymlink(checkout / "real.js", checkout / "alias.js")
  createSymlink(outside, checkout / "evil.js")
  createSymlink(home, checkout / "lib" / "out")
  check result.developPackage(checkout)
  let root = result.resolveInstalledPath("linkpkg", "")
  check root.len > 0
  # The checkout must carry live symlinks for this test to mean anything.
  check symlinkExists(checkout / "evil.js")
  check symlinkExists(checkout / "alias.js")
  check symlinkExists(checkout / "lib" / "out")
  initPkgLoader(result)

test "pkg symlinks resolve inside, escapes throw":
  let home = freshHome()
  defer: removeDir(home)
  discard setupLinkFixtures(home)
  check runCode("require('pkg/linkpkg').tag()") == "ok"
  check runCode("require('pkg/linkpkg/alias').tag()") == "real"
  expect CarneError:
    discard runCode("require('pkg/linkpkg/evil')")
  expect CarneError:
    discard runCode("require('pkg/linkpkg/lib/out/outside-marker')")

test "pkg entry point escapes throw":
  let home = freshHome()
  defer: removeDir(home)
  var cfg = newCarnePkgConfig(rootPath = home)
  let outside = home / "outside.js"
  writeFile(outside, "module.exports = { tag: () => \"pwned\" };\n")
  let checkoutEscape = home / "checkout-escape"
  createDir(checkoutEscape)
  writeFile(checkoutEscape / "package.json",
    """{"name": "escape", "version": "1.0.0", "main": "../outside.js"}""")
  check cfg.developPackage(checkoutEscape)
  let checkoutEntry = home / "checkout-entrylink"
  createDir(checkoutEntry)
  writeFile(checkoutEntry / "package.json",
    """{"name": "entrylink", "version": "1.0.0", "main": "index.js"}""")
  createSymlink(outside, checkoutEntry / "index.js")
  check cfg.developPackage(checkoutEntry)
  check symlinkExists(checkoutEntry / "index.js")
  initPkgLoader(cfg)
  expect CarneError:
    discard runCode("require('pkg/escape')")
  expect CarneError:
    discard runCode("require('pkg/entrylink')")

test "require pkg honors exports map and subpaths":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  check runCode("require('pkg/expkg').tag()") == "entry"
  check runCode("require('pkg/expkg/extra').tag()") == "extra"

test "exports wins over main":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  check runCode("require('pkg/both').tag()") == "exp"

test "require unknown package throws":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  expect CarneError:
    discard runCode("require('pkg/nope')")

test "require package without entry throws":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  expect CarneError:
    discard runCode("require('pkg/noentry')")

test "require ESM package throws":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  expect CarneError:
    discard runCode("require('pkg/esmpkg')")

test "relative require outside a package throws":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  expect CarneError:
    discard runCode("require('./x')")

test "runFile supports sibling relative requires":
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  let dir = home / "scripts"
  createDir(dir)
  writeFile(dir / "lib.js", "module.exports = { name: \"lib\" };\n")
  writeFile(dir / "main.js", "require(\"./lib\").name + \"!\";\n")
  check runFile(dir / "main.js") == "lib!"

test "pkg require under http workers serves on every worker":
  # Workers re-run the script on separate threads and resolve pkg/
  # concurrently against a store that is not thread-safe. Without
  # serialization in the loader this flakes with store file errors.
  let home = freshHome()
  defer: removeDir(home)
  discard setupFixtures(home)
  var expected: seq[string] = @[]
  for _ in 0 ..< 8:
    expected.add("200:greet-0.2.0+u2")
  check runCode(
    "const greet = require('pkg/greet'); " &
    "const http = require('std/http'); " &
    "http.serve(18250, {workers: 8}, req => greet.who()); " &
    "(async () => { " &
    "if (process.isWorker) return 'worker'; " &
    "const rs = await Promise.all([0, 1, 2, 3, 4, 5, 6, 7].map(() => " &
    "http.fetch('http://127.0.0.1:18250/').then(r => r.status + ':' + r.body))); " &
    "http.close(18250); " &
    "return rs.join(','); })()") == expected.join(",")
