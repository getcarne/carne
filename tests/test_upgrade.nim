import std/[os, unittest]

import carne/pkg/upgrade

test "normalizeTag pins the v prefix":
  check normalizeTag("0.1.3") == "v0.1.3"
  check normalizeTag("v0.1.3") == "v0.1.3"
  check normalizeTag("  0.1.3  ") == "v0.1.3"

test "stripTagV drops one leading v":
  check stripTagV("v0.1.3") == "0.1.3"
  check stripTagV("0.1.3") == "0.1.3"
  check stripTagV("v") == "v"

test "release URLs point at getcarne/carne":
  check latestDownloadUrl("carne_macos-arm64.tar.gz") ==
    "https://github.com/getcarne/carne/releases/latest/download/" &
    "carne_macos-arm64.tar.gz"
  check taggedDownloadUrl("v0.1.3", "carne_linux-x86_64.tar.gz") ==
    "https://github.com/getcarne/carne/releases/download/v0.1.3/" &
    "carne_linux-x86_64.tar.gz"

test "parseTagName reads tag_name, ignores garbage":
  check parseTagName("{\"tag_name\": \"v0.1.3\", \"draft\": false}") ==
    "v0.1.3"
  check parseTagName("{}") == ""
  check parseTagName("not json") == ""
  check parseTagName("[]") == ""

test "upgradeAsset matches this platform":
  let (name, ext) = upgradeAsset()
  check ext == "tar.gz"
  when defined(macosx):
    when defined(arm64):
      check name == "carne_macos-arm64"
    else:
      check name == "carne_macos-x86_64"
  elif defined(linux):
    when defined(arm64):
      check name == "carne_linux-arm64"
    else:
      check name == "carne_linux-x86_64"

test "findReleaseBinary locates nested binaries":
  let dir = getTempDir() / "carne_upgrade_find"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir / "carne_macos-arm64")
  defer: removeDir(dir)
  writeFile(dir / "carne_macos-arm64" / "carne", "bin")
  writeFile(dir / "carne_macos-arm64" / "README.md", "docs")
  check findReleaseBinary(dir) ==
    dir / "carne_macos-arm64" / "carne"

test "installBinary backs up and replaces":
  let dir = getTempDir() / "carne_upgrade_install"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let target = dir / "carne"
  let fresh = dir / "fresh"
  writeFile(target, "old")
  writeFile(fresh, "new")
  check installBinary(fresh, target, "0.1.2")
  check readFile(target) == "new"
  check readFile(target & ".prev.0.1.2") == "old"
  # Missing target installs without a backup.
  removeFile(target)
  removeFile(target & ".prev.0.1.2")
  check installBinary(fresh, target, "0.1.2")
  check readFile(target) == "new"
  check not fileExists(target & ".prev.0.1.2")

test "upgradeCommand dry-run prints URLs offline":
  check upgradeCommand("", dryRun = true) == 0
  check upgradeCommand("0.1.3", dryRun = true) == 0
