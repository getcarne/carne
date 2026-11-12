# Carne `carne pkg init` — scaffold a new CommonJS package.
#
#   carne pkg init              wizard in the current directory (must be empty)
#   carne pkg init <dir>        wizard into ./<dir>/ (created when missing)
#   carne pkg init -Y [dir]     skip the wizard, scaffold with defaults
#
# Mirrors `clue init`: the package name defaults to the target directory
# name and is validated against the manifest rules before anything is
# written, so bad names never leave a stray directory behind. `init <dir>`
# refuses non-empty targets; bare `init` refuses non-empty cwd. An
# existing `package.json` is never overwritten. The wizard prompts for
# version (re-asked until valid semver), description, author (defaults to
# the git user name), license and keywords (publish mandates all three of
# description/license/keywords, so the scaffold ships them). `-Y`/`--yes`
# takes git author, v0.1.0, MIT and `["carne"]` keywords with no prompts;
# without it, stdin must be a TTY.
#
# Scaffold: `package.json`, `index.js` (a `hello` starter with JSDoc) and
# `tests/<name>.test.js` (a `std/test` starter, found by `carne test`).
#
# This module stays threads-free and importable from unit tests.

import std/[os, osproc, strutils, terminal]
import pkg/openparser/json
import pkg/semver

import ../cli
import ./pkgmanifest
import ./publish

type
  InitError* = object of CatchableError
    ## A `carne pkg init` usage or scaffold error (message is user-facing).

const
  initDefaultVersion* = "0.1.0"
    ## Fresh-package version, wizard default and `-Y` value.
  initDefaultDescription* = "A new awesome carne package"
    ## Fresh-package description, wizard default and `-Y` value.
  initDefaultLicense* = "MIT"
    ## Fresh-package license, wizard default and `-Y` value.
  initDefaultKeywords* = ["carne"]
    ## Fresh-package keywords, wizard default and `-Y` value.
  initMain* = "index.js"
    ## Fixed entry point for scaffolded packages.

const indexTemplate = """/**
 * Say hello.
 * @param {string} [name] - who to greet
 * @returns {string} the greeting
 */
function hello(name = "world") {
  return "Hello, " + name + "!";
}

module.exports = { hello };
"""

const testTemplate = """const { test, expect } = require("std/test");
const { hello } = require("../index.js");

test("greets by name", () => {
  expect(hello("ada")).toBe("Hello, ada!");
});
"""

proc gitAuthor*(): string =
  ## The git-configured user name ("" when unavailable).
  let (outp, code) = execCmdEx("git config --get user.name")
  if code != 0:
    return ""
  outp.strip()

proc validPkgName*(name: string): bool =
  ## True when `name` passes the manifest name rules (single source of
  ## truth lives in pkgmanifest).
  try:
    validateName("package.json", name)
    true
  except PackageManifestError:
    false

proc dirHasItems*(d: string): bool =
  ## True when any non-hidden entry exists directly below `d`.
  for f in walkDir(d):
    if not f.path.isHidden:
      return true
  false

proc buildPackageJson*(name, version, description, author, license: string;
    keywords: seq[string]; main = initMain): string =
  ## The scaffold `package.json` source (`author` omitted when empty).
  var root = %*{
    "name": name,
    "version": version,
    "description": description,
    "license": license,
    "main": main,
  }
  if author.len > 0:
    root["author"] = %author
  var arr = newJArray()
  for k in keywords:
    arr.add(%k)
  root["keywords"] = arr
  pretty(root) & "\n"

proc promptLine(label, default: string): string =
  ## One `label [default]:` prompt; empty input takes the default, EOF
  ## keeps it too (callers gate on a TTY first).
  if default.len > 0:
    stdout.write(label & " [" & default & "]: ")
  else:
    stdout.write(label & ": ")
  stdout.flushFile()
  try:
    let line = stdin.readLine().strip()
    if line.len == 0: default else: line
  except EOFError, IOError:
    default

proc promptVersion(label, default: string): string =
  ## Prompt until the input parses as semver (empty takes the default).
  while true:
    let value = promptLine(label, default)
    try:
      discard parseVersion(value)
      return value
    except CatchableError:
      displayError("Invalid version: " & value)

proc writeExampleIfNonExistent(file, content: string) =
  ## Writes starter code, warning instead when the file already exists.
  if not fileExists(file):
    writeFile(file, content)
  else:
    displayWarning("File " & file & " already exists, did not write example code")

proc scaffoldPackage*(projectRoot, pkgName, version, description, author,
    license: string; keywords: seq[string]) =
  ## Writes the scaffold files. Raises `InitError` when a `package.json`
  ## is already there (never overwritten); starter sources only warn.
  let mf = projectRoot / pkgManifestFileName
  if fileExists(mf):
    raise newException(InitError,
      mf & " already exists — nothing to do.")
  writeFile(mf, buildPackageJson(pkgName, version, description, author,
    license, keywords))
  writeExampleIfNonExistent(projectRoot / initMain, indexTemplate)
  createDir(projectRoot / "tests")
  writeExampleIfNonExistent(projectRoot / "tests" / pkgName & ".test.js",
    testTemplate)

proc initCommand*(dir, name: string; yesMode: bool): int =
  ## `carne pkg init [dir]` entry point. `dir` is the working directory,
  ## `name` the optional target subdirectory. Returns the exit code.
  if not yesMode and not stdin.isatty():
    displayError("`carne pkg init` requires an interactive terminal " &
      "(stdin is not a TTY). Re-run with -Y/--yes to scaffold with defaults.")
    return 1
  let target = name.strip()
  var pkgName = if target.len > 0: target.lastPathPart() else: dir.lastPathPart()
  if not validPkgName(pkgName):
    if yesMode:
      displayError("'" & pkgName & "' is not a valid package name " &
        "(lowercase, no spaces; no `@scope/` prefixes).")
      return 1
    while not validPkgName(pkgName):
      displayWarning("'" & pkgName & "' is not a valid package name.")
      pkgName = promptLine("Package name", pkgName).lastPathPart()
  var projectRoot = if target.len > 0: dir / target else: dir
  if fileExists(projectRoot / pkgManifestFileName):
    displayError(projectRoot / pkgManifestFileName &
      " already exists — nothing to do.")
    return 1
  if target.len > 0:
    if dirExists(projectRoot) and dirHasItems(projectRoot):
      displayError("'" & target & "' already exists and is not empty.")
      return 1
    try:
      createDir(projectRoot)
    except OSError, IOError:
      displayError("cannot create " & projectRoot & ": " &
        getCurrentExceptionMsg())
      return 1
  elif dirHasItems(dir):
    displayError("Current directory is not empty. Provide a package name " &
      "to scaffold into a subdirectory, e.g. `carne pkg init " &
      pkgName & "`")
    return 1
  let version =
    if yesMode: initDefaultVersion
    else: promptVersion("Initial version", initDefaultVersion)
  let description =
    if yesMode: initDefaultDescription
    else: promptLine("Package description", initDefaultDescription)
  let author =
    if yesMode: gitAuthor()
    else: promptLine("Author", gitAuthor())
  let license =
    if yesMode: initDefaultLicense
    else: promptLine("License", initDefaultLicense)
  let keywords =
    if yesMode: @initDefaultKeywords
    else: splitPublishTags(promptLine("Keywords (comma-separated)", "carne"))
  if keywords.len == 0:
    displayError("At least one keyword is required " &
      "(`carne pkg publish` mandates keywords).")
    return 1
  try:
    scaffoldPackage(projectRoot, pkgName, version, description, author,
      license, keywords)
  except InitError as e:
    displayError(e.msg)
    return 1
  except OSError, IOError:
    displayError("cannot write scaffold: " & getCurrentExceptionMsg())
    return 1
  displaySuccess("Initialized package '" & pkgName & "' in " & projectRoot)
  0
