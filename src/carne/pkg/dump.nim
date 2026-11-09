# Carne `carne dump` — print a `package.json`.
#
#   carne dump                the package.json found from the cwd upwards
#   carne dump <name>         the installed package's manifest
#   carne dump <name>@<ref>   one installed version/ref of the package
#
# Installed lookups go through the store (develop checkouts win
# unpinned lookups, like `require("pkg/...")`). Output is the raw
# file, byte for byte. This module pulls datpkgr/operations via
# pkgman, so linkers need `--threads:on` (the carne host does).
#
# This module stays importable from unit tests under default flags.

import std/[os, strutils]

import ../cli
import ./pkgman

type
  DumpError* = object of CatchableError
    ## A `carne dump` lookup or read error (message is user-facing).

proc splitDumpRef*(spec: string): tuple[name, refStr: string] =
  ## `name@ref` / `name#ref` off an installed-package spec (`#` wins
  ## when both are present). Plain names return an empty ref.
  var s = spec.strip()
  let hash = s.find('#')
  if hash >= 0:
    return (s[0 ..< hash].strip(), s[hash + 1 .. ^1].strip())
  let at = s.rfind('@')
  if at > 0:
    return (s[0 ..< at].strip(), s[at + 1 .. ^1].strip())
  (s, "")

proc dumpManifest*(dir, pkgSpec: string; home = "";
    ensureSource = true): string =
  ## The `package.json` source for `pkgSpec` ("" = cwd upwards).
  ## Raises `DumpError` when nothing resolves or the file is unreadable.
  if pkgSpec.strip().len == 0:
    let mf = findPackageJson(dir)
    if mf.len == 0:
      raise newException(DumpError, "no package.json found " &
        "(run `carne dump` inside a package directory)")
    try:
      return readFile(mf)
    except IOError, OSError:
      raise newException(DumpError,
        "cannot read " & mf & ": " & getCurrentExceptionMsg())
  let (name, refStr) = splitDumpRef(pkgSpec)
  if name.len == 0:
    raise newException(DumpError,
      "bad package spec \"" & pkgSpec.strip() & "\"")
  let cfg = newCarnePkgConfig(
    if home.len > 0: home else: carneHome(),
    ensureSource = ensureSource)
  let root = cfg.resolveInstalledPath(name, refStr)
  if root.len == 0 or not dirExists(root):
    raise newException(DumpError, "package \"" & pkgSpec.strip() &
      "\" is not installed")
  let mf = cfg.findManifestInDir(root)
  if mf.len == 0:
    raise newException(DumpError, "package \"" & name &
      "\" has no package.json at " & root)
  try:
    return readFile(mf)
  except IOError, OSError:
    raise newException(DumpError,
      "cannot read " & mf & ": " & getCurrentExceptionMsg())

proc dumpCommand*(dir, pkgSpec: string; home = "";
    ensureSource = true): int =
  ## `carne dump` entry point. Prints the manifest, returns the
  ## process exit code.
  try:
    stdout.write(dumpManifest(dir, pkgSpec, home, ensureSource))
    return 0
  except DumpError as e:
    displayError(e.msg)
    return 1
