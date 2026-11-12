# Carne self-upgrade: `carne upgrade [version]`.
#
# Downloads the release binary from
# https://github.com/getcarne/carne/releases and installs it into
# `~/.carne/bin` (`CARNE_HOME` overrides), creating the directory on
# first use. Bare `upgrade` takes the latest release; an explicit
# version (`0.1.3` or `v0.1.3`) pins one release. Release assets are
# `<app>_<os>-<arch>.tar.gz` (see .github/workflows/release.yml).
#
# The current version is the compile-time `versionStr` (carne.nimble),
# and the up-to-date check compares it against the latest tag (or the
# requested version). The running binary is never touched: only
# `~/.carne/bin/carne` is replaced (backed up to `carne.prev.<old>`).
#
# Network flows stay in `upgradeCommand` (untested, like publish);
# everything else is pure and covered by tests/test_upgrade.nim.
# This module pulls datpkgr/operations via pkgman, so linkers need
# `--threads:on` (the carne host does).

import std/[json, os, osproc, strutils]

import ../cli
import ./pkgman

const
  upgradeRepo* = "getcarne/carne"
    ## Releases live here: github.com/getcarne/carne/releases.
  upgradeApiBase* = "https://api.github.com/repos/" & upgradeRepo &
    "/releases"
    ## GitHub releases API for version discovery.

type
  UpgradeError* = object of CatchableError
    ## A `carne upgrade` usage or platform error (message is user-facing).

proc normalizeTag*(v: string): string =
  ## `0.1.3` → `v0.1.3` (leading `v` kept, surrounding blanks cut).
  let s = v.strip()
  if s.startsWith("v") or s.startsWith("V"):
    "v" & s[1 .. ^1].strip()
  else:
    "v" & s

proc stripTagV*(tag: string): string =
  ## `v0.1.3` → `0.1.3` (for comparing against `versionStr`).
  let s = tag.strip()
  if s.len > 1 and (s[0] == 'v' or s[0] == 'V'):
    s[1 .. ^1]
  else:
    s

proc upgradeAsset*(): tuple[name, ext: string] =
  ## Release asset for this platform (`name` without extension).
  ## Raises `UpgradeError` where carne ships no release binary.
  when defined(linux):
    when defined(arm64):
      ("carne_linux-arm64", "tar.gz")
    else:
      ("carne_linux-x86_64", "tar.gz")
  elif defined(macosx):
    when defined(arm64):
      ("carne_macos-arm64", "tar.gz")
    else:
      ("carne_macos-x86_64", "tar.gz")
  else:
    raise newException(UpgradeError,
      "carne upgrade has no release binary for this platform")

proc latestDownloadUrl*(asset: string): string =
  ## `/releases/latest/download/` URL for `asset` (with extension).
  "https://github.com/" & upgradeRepo & "/releases/latest/download/" &
    asset

proc taggedDownloadUrl*(tag, asset: string): string =
  ## `/releases/download/<tag>/` URL for one pinned release.
  "https://github.com/" & upgradeRepo & "/releases/download/" & tag &
    "/" & asset

proc parseTagName*(apiBody: string): string =
  ## The `"tag_name"` value of a GitHub release API body, "" when
  ## absent or unparsable (callers treat "" as unknown, never fatal).
  try:
    let j = parseJson(apiBody)
    if j.kind == JObject and j.hasKey("tag_name") and
        j["tag_name"].kind == JString:
      return j["tag_name"].getStr().strip()
  except CatchableError:
    discard
  ""

proc latestTag*(): string =
  ## Latest release tag via the GitHub API, "" when unreachable.
  try:
    let (output, code) = execCmdEx("curl -fsSL --connect-timeout 10 " &
      quoteShell(upgradeApiBase & "/latest"))
    if code != 0:
      return ""
    return parseTagName(output)
  except CatchableError:
    return ""

proc downloadFile*(url, dest: string): bool =
  ## curl `url` to `dest`. True on success.
  try:
    let (_, code) = execCmdEx("curl -fsSL --connect-timeout 15 " &
      quoteShell(url) & " -o " & quoteShell(dest))
    return code == 0
  except CatchableError:
    return false

proc extractTarball*(workDir, archive: string): bool =
  ## `tar xzf` into `workDir`. True on success.
  try:
    let (_, code) = execCmdEx("tar xzf " & quoteShell(archive) &
      " -C " & quoteShell(workDir))
    return code == 0
  except CatchableError:
    return false

proc findReleaseBinary*(dir: string): string =
  ## First `carne` binary under `dir` (archives wrap it in a folder).
  for f in walkDirRec(dir):
    if f.extractFilename() == "carne":
      return f
  ""

proc installBinary*(extracted, target, currentVersion: string): bool =
  ## Back up `target` (`carne.prev.<old>`) and install `extracted`
  ## over it, executable. False with the reason displayed on failure.
  if fileExists(target):
    try:
      let backup = target & ".prev." & currentVersion
      if fileExists(backup):
        removeFile(backup)
      moveFile(target, backup)
    except OSError as e:
      displayError("cannot back up " & target & ": " & e.msg)
      return false
  try:
    copyFile(extracted, target)
  except OSError as e:
    displayError("cannot install " & target & ": " & e.msg)
    return false
  when defined(posix):
    discard execCmdEx("chmod +x " & quoteShell(target))
  true

proc upgradeCommand*(versionArg: string; home = "";
    dryRun = false): int =
  ## `carne upgrade [version]`: fetch the release binary into
  ## `<home>/bin`. `--dry-run` prints the resolved URLs only.
  var asset, ext: string
  try:
    (asset, ext) = upgradeAsset()
  except UpgradeError as e:
    displayError(e.msg)
    return 1
  let file = asset & "." & ext
  var tag, url: string
  if versionArg.strip().len == 0:
    if dryRun:
      tag = "latest"
      url = latestDownloadUrl(file)
    else:
      tag = latestTag()
      if tag.len > 0 and stripTagV(tag) == versionStr:
        displaySuccess("Already up to date (" & versionStr & ")")
        return 0
      url = latestDownloadUrl(file)
      if tag.len > 0:
        displayInfo("Upgrading carne " & versionStr & " -> " & tag)
      else:
        displayInfo("Upgrading carne to the latest release")
  else:
    tag = normalizeTag(versionArg)
    if stripTagV(tag) == versionStr:
      displaySuccess("Already up to date (" & versionStr & ")")
      return 0
    url = taggedDownloadUrl(tag, file)
    displayInfo("Upgrading carne " & versionStr & " -> " & tag)
  if dryRun:
    displayInfo("would download " & url)
    return 0
  let binDir = carneBinDir(if home.len > 0: home else: carneHome())
  try:
    createDir(binDir)
  except OSError as e:
    displayError("cannot create " & binDir & ": " & e.msg)
    return 1
  let target = binDir / "carne"
  let workDir = getTempDir() / ("carne_upgrade_" & $getCurrentProcessId())
  try:
    createDir(workDir)
  except OSError as e:
    displayError("cannot create " & workDir & ": " & e.msg)
    return 1
  try:
    displayInfo("Downloading " & url)
    let archive = workDir / file
    if not downloadFile(url, archive):
      displayError("Failed to download the release: " & url)
      return 1
    if not extractTarball(workDir, archive):
      displayError("Failed to extract the release archive")
      return 1
    let extracted = findReleaseBinary(workDir)
    if extracted.len == 0:
      displayError("No carne binary found in the release archive")
      return 1
    if not installBinary(extracted, target, versionStr):
      return 1
    let label = if tag.len > 0: tag else: "latest"
    displaySuccess("Upgraded carne to " & label & " at " & target)
    return 0
  finally:
    try: removeDir(workDir)
    except OSError: discard
