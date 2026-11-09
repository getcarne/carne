# Carne package publishing on top of the carnepkgs registry.
#
# `carne pkg publish` submits the package in the current directory by
# opening a pull request against https://github.com/getcarne/carnepkgs
# (fork, insert entry into packages.json, PR) — the same flow as
# `clue publish` against nim-lang/packages.
#
# Auth is a `.tokens` file in the carne home (`~/.carne/.tokens`,
# `CARNE_HOME` overrides it) holding the GitHub token: one token per
# line, first non-empty line wins (`#` comments and blank lines skipped).
# No env vars, no nimble fallback.
# The token stays in memory (and inside push URLs) only.
#
# Package metadata comes from `package.json`: `name`, `description`
# and `license` are mandatory, and `keywords` supplies the registry
# tags (also mandatory — pass `--tags=` to override). The repo URL is
# read from `.git/config` (`remote.origin.url`); `--url=` overrides it.
# `web` defaults to `--web=`, then `homepage`, then the repo URL.
#
# This module stays threads-free and importable from unit tests.
# Only the pure helpers are tested; network/git flows are covered
# by `--dry-run` only, never by live fixtures.

import std/[os, osproc, strutils, tempfiles, terminal, times]
import pkg/openparser/json
import pkg/datpkgr/[store, types]
import ./pkgmanifest

const
  publishUpstream* = "getcarne/carnepkgs"
  publishUpstreamUrl* = "https://github.com/" & publishUpstream
  publishApiBase* = "https://api.github.com/repos/"
  publishApiRoot* = "https://api.github.com"
  publishDefaultBranch* = "main"
  publishTokensFile* = ".tokens"
type
  PublishOpts* = tuple[tags, web, urlOverride: string; dryRun, yesMode: bool]
    ## `--tags`/`--web`/`--url` overrides plus `--dry-run`/`--yes` modes.

proc tokensFilePath*(home = ""): string =
  ## Path of the publish token file: `<home>/.tokens` (`CARNE_HOME`
  ## or `~/.carne` when `home` is empty).
  let h = if home.len > 0: home
    else: getEnv("CARNE_HOME", getHomeDir() / ".carne")
  h / publishTokensFile

proc readPublishToken*(path = ""): string =
  ## The GitHub token for publishing: first non-empty line of the
  ## `.tokens` file (`#` comments and blank lines skipped). ""
  ## when the file holds no token. The value itself is never logged.
  let p = if path.len > 0: path else: tokensFilePath()
  try:
    for line in readFile(p).splitLines():
      let s = line.strip()
      if s.len == 0 or s.startsWith('#'):
        continue
      return s
  except IOError, OSError:
    discard
  ""

proc tokensFileExposed*(path: string): bool =
  ## True when `path` is group/world-readable (a nudge to `chmod 600`).
  try:
    let perms = getFilePermissions(path)
    fpGroupRead in perms or fpOthersRead in perms or
      fpGroupWrite in perms or fpOthersWrite in perms
  except CatchableError:
    false

proc splitPublishTags*(s: string): seq[string] =
  ## Split a tag line on commas and any whitespace, dropping empties and
  ## dupes while keeping first-seen order. `"web, library  wrapper"` →
  ## `@["web", "library", "wrapper"]`.
  for part in s.split({',', ' ', '\t', '\n', '\r', '\f', '\v'}):
    let tag = part.strip()
    if tag.len > 0 and tag notin result:
      result.add(tag)

proc normalizeRepoUrl*(url: string): string =
  ## Normalize a git remote URL to its canonical `https://` form for the
  ## registry index: strips a trailing `.git`, maps scp-like
  ## `git@host:owner/repo` and `ssh://[user@]host[:port]/path` to https, and
  ## rejects URLs embedding a username or password.
  var u = url.strip()
  if u.endsWith(".git"):
    u = u[0 ..< ^4]
  u = u.strip(chars = {'/'})
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if "://" notin u and '@' in u and ':' in u:
    # scp-like syntax: [user@]host:path
    let atPos = u.find('@')
    let colonPos = u.find(':', atPos)
    let host = u[atPos + 1 ..< colonPos]
    let path = u[colonPos + 1 .. ^1].strip(chars = {'/'})
    if host.len == 0 or path.len == 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    return "https://" & host & "/" & path
  if u.startsWith("ssh://"):
    var rest = u["ssh://".len .. ^1]
    if '@' in rest:
      rest = rest[rest.find('@') + 1 .. ^1]
    let slashPos = rest.find('/')
    if slashPos < 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    var hostPort = rest[0 ..< slashPos]
    let path = rest[slashPos + 1 .. ^1].strip(chars = {'/'})
    if ':' in hostPort:
      hostPort = hostPort[0 ..< hostPort.find(':')]
    if hostPort.len == 0 or path.len == 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    return "https://" & hostPort & "/" & path
  if u.startsWith("http://") or u.startsWith("https://"):
    let schemeEnd = u.find("://") + 3
    let rest = u[schemeEnd .. ^1]
    let slashPos = rest.find('/')
    let authority = if slashPos < 0: rest else: rest[0 ..< slashPos]
    if '@' in authority:
      raise newException(ValueError,
        "Cannot publish the repository URL because it contains username " &
        "and/or password. Fix the remote URL. Hint: \"git remote -v\"")
    return u
  raise newException(ValueError, "Cannot parse repository URL: " & url)

proc expandPublishForgeAlias*(s: string): string =
  ## Expand `alias:user/repo` shorthand to a canonical https URL.
  ## Single source of truth lives in datpkgr/store.
  store.expandForgeAlias(s)

proc isPublishForgeAliasShape*(s: string): bool =
  ## True when `s` looks like `alias:path` shorthand (not a real URL).
  ## Single source of truth lives in datpkgr/store.
  store.isForgeAliasShape(s)

proc resolveRepoUrl*(input: string): string =
  ## Resolve human-typed repo input: forge-alias shorthand expands first,
  ## anything else goes through normal URL normalization. Auto-detected
  ## git remote output must bypass this (it is already canonical) and call
  ## `normalizeRepoUrl` directly.
  let s = input.strip()
  if isPublishForgeAliasShape(s):
    return expandPublishForgeAlias(s)
  normalizeRepoUrl(s)

proc publishEntry*(name, url, description, license, web: string,
    tags: seq[string]): JsonNode =
  ## Build the packages.json entry for a package, matching the registry schema.
  var tagsArr = newJArray()
  for t in tags:
    tagsArr.add(%t)
  result = %*{
    "name": name,
    "url": url,
    "method": "git",
    "tags": tagsArr,
    "description": description,
    "license": license,
    "web": web
  }

proc entryExists*(packagesJson: JsonNode, name: string): bool =
  ## True when `packages.json` (a top-level array) already holds `name`.
  if packagesJson.kind != JArray:
    return false
  for entry in packagesJson:
    if entry.kind == JObject and entry.hasKey("name") and
        entry["name"].getStr == name:
      return true
  false

proc insertEntrySorted*(packagesJson: JsonNode, entry: JsonNode) =
  ## Insert `entry` keeping ascending `name` order. No-op when `name`
  ## is already listed (callers report the duplicate separately).
  let name = entry["name"].getStr()
  for i in 0 ..< packagesJson.len:
    let cur = packagesJson[i]
    if cur.kind == JObject and cur.hasKey("name"):
      if cur["name"].getStr() == name:
        return
      if cur["name"].getStr() > name:
        packagesJson.elems.insert(entry, i)
        return
  packagesJson.add(entry)

proc manifestKeywords*(extra: JsonNode): seq[string] =
  ## The `keywords` array from a `package.json` document, cleaned
  ## (empties dropped, dupes removed, order kept). @[] when absent.
  ## Anything present but not an array of strings is a manifest error.
  if extra == nil or extra.kind != JObject or not extra.hasKey("keywords"):
    return @[]
  let k = extra["keywords"]
  if k.kind != JArray:
    raise newException(ValueError, "\"keywords\" must be an array of strings")
  for item in k:
    if item.kind != JString:
      raise newException(ValueError, "\"keywords\" must be an array of strings")
    let tag = item.getStr().strip()
    if tag.len > 0 and tag notin result:
      result.add(tag)

proc manifestHomepage*(extra: JsonNode): string =
  ## The `homepage` string from a `package.json` document, "" when absent.
  if extra == nil or extra.kind != JObject or not extra.hasKey("homepage"):
    return ""
  let v = extra["homepage"]
  if v.kind != JString:
    return ""
  v.getStr().strip()

proc detectRepoUrl*(dir: string): string =
  ## The checkout's origin URL from `.git/config` ("" when none).
  ## `git config` first, `ls-remote` as fallback — same source, two readers.
  var (output, code) = execCmdEx("git config --get remote.origin.url",
    workingDir = dir)
  if code == 0 and output.strip().len > 0:
    return output.strip()
  (output, code) = execCmdEx("git ls-remote --get-url", workingDir = dir)
  if code == 0:
    return output.strip()
  ""

proc curlApi(url, token: string, payload = ""): tuple[output: string, exitCode: int] =
  ## Minimal GitHub API client over curl: GET by default, POST with a
  ## JSON body when `payload` is set.
  var cmd = "curl -fsSL --connect-timeout 15 -H " &
    quoteShell("Authorization: token " & token) & " -H " &
    quoteShell("Accept: application/vnd.github+json")
  if payload.len > 0:
    cmd.add(" -X POST -H " & quoteShell("Content-Type: application/json") &
      " --data " & quoteShell(payload))
  cmd.add(" " & quoteShell(url))
  execCmdEx(cmd)

proc gitHubUser*(token: string): string =
  ## Resolve the token owner (`login`) — also verifies the token works.
  let (output, code) = curlApi(publishApiRoot & "/user", token)
  if code != 0:
    return ""
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("login"):
      return j["login"].getStr
  except CatchableError:
    discard
  ""

proc isCorrectFork(output: string): bool =
  ## True when a `GET /repos/{user}/carnepkgs` body is a fork of the registry.
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("fork") and j["fork"].getBool:
      let parent = j["parent"]
      if parent.kind == JObject and parent.hasKey("full_name"):
        return parent["full_name"].getStr == publishUpstream
  except CatchableError:
    discard
  false

proc ensureFork*(user, token: string): bool =
  ## Make sure `{user}/carnepkgs` is a fork of the registry, forking
  ## first when needed. Returns false with the caller logging the reason.
  let (output, code) = curlApi(publishApiBase & user & "/carnepkgs", token)
  if code == 0 and isCorrectFork(output):
    return true
  echo "Forking " & publishUpstream & " ..."
  let (_, forkCode) = curlApi(publishApiBase & publishUpstream & "/forks",
    token, "{}")
  if forkCode != 0:
    stderr.writeLine("error: Unable to create fork. The token might not " &
      "have enough permissions (needs `public_repo`).")
    return false
  echo "Waiting 10s to let GitHub create the fork ..."
  sleep(10_000)
  true

proc runGit(workdir, args: string): bool =
  ## Run a git command in `workdir`, echoing its output on failure.
  let (output, code) = execCmdEx("git " & args, workingDir = workdir)
  if code != 0:
    stderr.writeLine("error: git " & args & " failed: " & output.strip())
    return false
  true

proc createPullRequest*(token, user, branch, title, body: string): string =
  ## Open the PR against the registry; returns its `html_url` or "".
  let payload = %*{
    "title": title,
    "head": user & ":" & branch,
    "base": publishDefaultBranch,
    "body": body
  }
  let (output, code) = curlApi(publishApiBase & publishUpstream & "/pulls",
    token, $payload)
  if code != 0:
    return ""
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("html_url"):
      return j["html_url"].getStr
  except CatchableError:
    discard
  ""

proc fail(msg: string): int =
  stderr.writeLine("error: " & msg)
  1

proc publishCommand*(dir: string; opts: PublishOpts; home = ""): int =
  ## Publish the package at `dir` by opening a PR against the registry.
  ## Returns the process exit code (0 on success).
  let mf = findPackageJson(dir)
  if mf.len == 0:
    return fail("No package.json found in " & dir &
      ". `carne pkg publish` must run inside a package directory.")
  var m: Manifest
  try:
    m = parsePackageManifest(readFile(mf), mf)
  except CatchableError as e:
    return fail(e.msg)
  if m.description.strip().len == 0:
    return fail("package.json has no `description` — refusing to publish " &
      "an undescribed package.")
  if m.license.strip().len == 0:
    return fail("package.json has no `license` — refusing to publish " &
      "an unlicensed package.")

  var url = ""
  if opts.urlOverride.strip().len > 0:
    try:
      url = resolveRepoUrl(opts.urlOverride)
    except ValueError as e:
      return fail(e.msg)
  else:
    let detected = detectRepoUrl(dir)
    if detected.len > 0:
      try:
        url = normalizeRepoUrl(detected)
      except ValueError as e:
        return fail(e.msg)
  if url.len == 0:
    return fail("Could not detect a git remote. Run inside a git checkout " &
      "with an origin remote, or pass `--url=<repo>`.")
  if not url.startsWith("https://github.com/"):
    return fail("The registry only accepts GitHub repos (fork + PR flow); " &
      "got " & url)

  var tags: seq[string]
  if opts.tags.strip().len > 0:
    tags = splitPublishTags(opts.tags)
  else:
    try:
      tags = manifestKeywords(m.extra)
    except ValueError as e:
      return fail("package.json: " & e.msg)
  if tags.len == 0:
    return fail("No tags: add a \"keywords\" array to package.json " &
      "or pass `--tags=\"web, library\"`.")

  var web = opts.web.strip()
  if web.len == 0:
    web = manifestHomepage(m.extra)
  if web.len == 0:
    web = url

  let entry = publishEntry(m.name, url, m.description.strip(),
    m.license.strip(), web, tags)
  let branchName = "add-" & m.name & "-" & getTime().utc.format("HHmm")

  if opts.dryRun:
    echo "Dry run — no network or git changes made."
    echo "Package entry:"
    echo pretty(entry)
    echo "Would fork " & publishUpstreamUrl & ", insert the entry into " &
      "packages.json on branch " & branchName & ", push, and open a PR against " &
      publishDefaultBranch & "."
    echo "Dry run complete"
    return 0

  # Auth only past this point: dry runs stay fully offline.
  let tokPath = tokensFilePath(home)
  let token = readPublishToken(tokPath)
  if token.len == 0:
    return fail("No GitHub token found. Put the token on its own line in " &
      tokPath & " (chmod 600).")
  if tokensFileExposed(tokPath):
    stderr.writeLine("warning: " & tokPath &
      " is group/world-readable; consider `chmod 600 " & tokPath & "`.")
  let user = gitHubUser(token)
  if user.len == 0:
    return fail("Could not verify the GitHub token (GET /user failed). " &
      "Check the token and network.")
  echo "Verified as " & user

  if not opts.yesMode:
    if not isatty(stdin):
      return fail("`carne pkg publish` needs confirmation; re-run with " &
        "--yes in non-interactive environments.")
    stdout.write("Open a pull request adding " & m.name & " to " &
      publishUpstream & "? [y/N] ")
    let answer =
      try: readLine(stdin).strip().toLowerAscii()
      except EOFError, IOError: ""
    if answer != "y" and answer != "yes":
      echo "Cancelled."
      return 0

  if not ensureFork(user, token):
    return 1
  let workdir = createTempDir("carne-publish-", "")
  try:
    if not runGit(workdir, "init -q"): return 1
    if not runGit(workdir, "checkout -q -b " & publishDefaultBranch): return 1
    echo "Fetching your fork ..."
    if not runGit(workdir, "pull -q https://github.com/" & user & "/carnepkgs"):
      return 1
    echo "Syncing with upstream ..."
    if not runGit(workdir, "pull -q " & publishUpstreamUrl & ".git " &
        publishDefaultBranch):
      return 1
    # NB: the token travels inside the push URL (never stored in the repo);
    # git redacts credentials from any echoed errors, and runGit only
    # echoes output on failure.
    if not runGit(workdir, "push -q https://" & token & "@github.com/" &
        user & "/carnepkgs " & publishDefaultBranch):
      return 1
    let pkgsFile = workdir / "packages.json"
    if not fileExists(pkgsFile):
      return fail("No packages.json found in the fork.")
    var packagesJson: JsonNode
    try:
      packagesJson = parseJson(readFile(pkgsFile))
    except CatchableError as e:
      return fail("Could not parse packages.json: " & e.msg)
    if packagesJson.kind != JArray:
      return fail("packages.json is not a top-level array.")
    if entryExists(packagesJson, m.name):
      return fail("Package '" & m.name & "' is already listed in packages.json.")
    insertEntrySorted(packagesJson, entry)
    writeFile(pkgsFile, pretty(packagesJson))
    if not runGit(workdir, "checkout -q -B " & branchName): return 1
    if not runGit(workdir, "commit -q packages.json -m " &
        quoteShell("Added package " & m.name)):
      return 1
    echo "Pushing branch " & branchName & " ..."
    if not runGit(workdir, "push -q https://" & token & "@github.com/" &
        user & "/carnepkgs " & branchName):
      return 1
    echo "Creating pull request ..."
    let prUrl = createPullRequest(token, user, branchName,
      "Add package " & m.name, m.description.strip() & "\n\n" & url)
    if prUrl.len == 0:
      return fail("Pull request creation failed.")
    echo "Pull request opened: " & prUrl
    0
  finally:
    try: removeDir(workdir)
    except OSError, IOError: discard
