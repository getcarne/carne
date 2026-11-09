# Carne `carne bump` — semver bumps for `package.json`.
#
#   carne bump                        patch bump of ./package.json
#   carne bump 1.2.3                  set the version to 1.2.3
#   carne bump --level=minor           minor bump (major|minor|patch)
#   carne bump --dep=concarne          patch bump of the concarne spec
#   carne bump 0.2.0 --dep=concarne    set the concarne spec (prefix kept)
#
# Own version: exact semver in `"version"`. Dep specs keep their range
# prefix (`^`, `~`, `>=`, ...) across bumps and sets; `*`/`latest`/`""`
# can only be set, never bumped. Git/URL/file specs refuse both (edit
# by hand). Level bumps drop prerelease/build metadata.
#
# Rewrites are surgical string splices, so the file keeps its
# indentation, key order and trailing newline — only the bumped value
# changes. This module stays threads-free and importable from unit
# tests under default flags.

import std/strutils
import pkg/openparser/json
import pkg/semver

import ../cli
import ./pkgmanifest

type
  BumpError* = object of CatchableError
    ## A `carne bump` usage or spec error (message is user-facing).

  BumpLevel* = enum
    blMajor, blMinor, blPatch

const depGroups* = ["dependencies", "devDependencies",
  "optionalDependencies", "peerDependencies"]
  ## Dependency groups searched for `--dep` (in this order).

proc parseBumpLevel*(s: string): BumpLevel =
  ## `major|minor|patch` (any case), else a `BumpError`.
  case s.strip().toLowerAscii()
  of "major": blMajor
  of "minor": blMinor
  of "patch": blPatch
  else:
    raise newException(BumpError,
      "bad --level \"" & s & "\" (want major|minor|patch)")

proc bumpVersion*(v: Version; level: BumpLevel): Version =
  ## The next version at `level` (higher levels reset, metadata drops).
  case level
  of blMajor: newVersion(v.major + 1, 0, 0)
  of blMinor: newVersion(v.major, v.minor + 1, 0)
  of blPatch: newVersion(v.major, v.minor, v.patch + 1)

proc splitSpecPrefix*(spec: string): tuple[prefix, core: string] =
  ## Leading range operator (`^ ~ >= <= > < = v`, blanks) off a dep
  ## spec: `"^ 1.2.3"` → `("^", "1.2.3")`, `"1.2.3"` → `("", "1.2.3")`.
  var i = 0
  while i < spec.len and
      spec[i] in {'^', '~', '<', '>', '=', 'v', 'V', ' ', '\t'}:
    inc i
  (spec[0 ..< i].strip(), spec[i .. ^1].strip())

proc isBumpableSpec*(spec: string): bool =
  ## False for `*`/`latest`/"" (no version inside) and for git, URL,
  ## `npm:`-alias-bare and local specs (no semver to move).
  let s = spec.strip()
  if s.len == 0 or s == "*" or s == "latest":
    return false
  if s.startsWith("npm:"):
    let inner = s["npm:".len .. ^1]
    let at = inner.rfind('@')
    return at > 0 and inner[at + 1 .. ^1].strip().len > 0
  if s.startsWith("git+") or s.startsWith("git://") or
      s.startsWith("github:") or s.startsWith("gitlab:") or
      s.startsWith("bitbucket:") or s.startsWith("git@") or
      s.endsWith(".git"):
    return false
  if s.startsWith("file:") or s.startsWith("portal:") or
      s.startsWith("workspace:") or s.startsWith("./") or
      s.startsWith("../") or s.startsWith("/") or s in [".", ".."]:
    return false
  if "://" in s:
    return false
  true

proc splitAlias(spec: string): tuple[name, range: string] =
  ## `npm:real@^2.0.0` → `("real", "^2.0.0")`. Raises `BumpError` on a
  ## malformed alias (no `@` separator).
  let inner = spec.strip()["npm:".len .. ^1]
  let at = inner.rfind('@')
  if at <= 0:
    raise newException(BumpError,
      "bad alias \"" & spec.strip() & "\" (want npm:name@range)")
  (inner[0 ..< at], inner[at + 1 .. ^1].strip())

proc bumpRange(range: string; level: BumpLevel): string =
  ## Bump one `prefix + exact version` range, keeping the prefix.
  let (prefix, core) = splitSpecPrefix(range)
  var v: Version
  try:
    v = parseVersion(core)
  except CatchableError:
    raise newException(BumpError, "\"" & range.strip() &
      "\" has no exact X.Y.Z version to bump " &
      "(pass an explicit version instead)")
  prefix & $bumpVersion(v, level)

proc noVersionToBump(spec: string): ref BumpError =
  ## Bump refusal for specs without a movable version. Stars can be
  ## replaced by an explicit version; anything else (git, URLs, local
  ## paths) needs a hand edit.
  let s = spec.strip()
  if s.len == 0 or s == "*" or s == "latest":
    newException(BumpError, "\"" & s &
      "\" has no version to bump (pass an explicit version instead)")
  else:
    newException(BumpError, "\"" & s &
      "\" is not a versioned spec (edit package.json by hand)")

proc bumpSpec*(spec: string; level: BumpLevel): string =
  ## The spec at the next `level`, prefix preserved. `*`/`latest`/git
  ## specs raise `BumpError` (nothing to move).
  let s = spec.strip()
  if s.startsWith("npm:"):
    let (name, range) = splitAlias(s)
    if range.len == 0:
      raise newException(BumpError, "\"" & s &
        "\" has no version to bump (pass an explicit version instead)")
    return "npm:" & name & "@" & bumpRange(range, level)
  if not isBumpableSpec(s):
    raise noVersionToBump(s)
  bumpRange(s, level)

proc setSpecVersion*(spec: string; v: Version): string =
  ## The spec pointing at `v`, prefix preserved. `*` becomes exact;
  ## git/URL/local specs raise `BumpError`.
  let s = spec.strip()
  if s.startsWith("npm:"):
    let (name, _) = splitAlias(s)
    return "npm:" & name & "@" & $v
  if s.len == 0 or s == "*" or s == "latest":
    return $v
  if not isBumpableSpec(s):
    raise newException(BumpError, "\"" & s &
      "\" is not a versioned spec (edit package.json by hand)")
  splitSpecPrefix(s).prefix & $v

proc skipWs(content: string; j: var int; hi: int) =
  while j < hi and content[j] in {' ', '\t', '\n', '\r'}:
    inc j

proc readJsonString(content: string; pos, hi: int; val: var string;
    next: var int): bool =
  ## Parses the JSON string at `pos` (opening quote), unescaped into
  ## `val`, `next` past the closing quote. False on any malformed
  ## input (never raises, never runs past `hi`).
  if pos >= hi or content[pos] != '"':
    return false
  var i = pos + 1
  val = ""
  while i < hi:
    let c = content[i]
    if c == '"':
      next = i + 1
      return true
    if c == '\\':
      inc i
      if i >= hi:
        return false
      case content[i]
      of '"': val.add('"')
      of '\\': val.add('\\')
      of '/': val.add('/')
      of 'b': val.add('\b')
      of 'f': val.add('\f')
      of 'n': val.add('\n')
      of 'r': val.add('\r')
      of 't': val.add('\t')
      of 'u':
        if i + 4 >= hi:
          return false
        var code = 0
        for k in 1 .. 4:
          code = code shl 4
          case content[i + k]
          of '0' .. '9': code += ord(content[i + k]) - ord('0')
          of 'a' .. 'f': code += ord(content[i + k]) - ord('a') + 10
          of 'A' .. 'F': code += ord(content[i + k]) - ord('A') + 10
          else: return false
        i += 4
        if code <= 0x7F:
          val.add(chr(code))
        elif code <= 0x7FF:
          val.add(chr(0xC0 or (code shr 6)))
          val.add(chr(0x80 or (code and 0x3F)))
        elif code < 0xD800 or (code > 0xDFFF and code <= 0xFFFF):
          val.add(chr(0xE0 or (code shr 12)))
          val.add(chr(0x80 or ((code shr 6) and 0x3F)))
          val.add(chr(0x80 or (code and 0x3F)))
        else:
          return false
      else:
        return false
      inc i
    elif c == '\n' or c == '\r' or ord(c) < 0x20:
      return false
    else:
      val.add(c)
      inc i
  false

proc findValueSpan*(content: string; key, expected: string; depth, lo,
    hi: int; valStart, valEnd: var int): bool =
  ## Raw inner span of `"key": "expected"` with `key` at object depth
  ## `depth` inside `[lo, hi)`. Depth counts from the slice start, so
  ## top-level keys scan with `depth = 1` over the whole file and dep
  ## keys with `depth = 1` over their group span.
  let want = "\"" & key & "\""
  var i = lo
  var d = 0
  while i < hi:
    let c = content[i]
    if c == '"':
      if d == depth and i + want.len <= hi and
          content[i ..< i + want.len] == want:
        var j = i + want.len
        skipWs(content, j, hi)
        if j < hi and content[j] == ':':
          inc j
          skipWs(content, j, hi)
          if j < hi and content[j] == '"':
            var v: string
            var nxt: int
            if readJsonString(content, j, hi, v, nxt) and v == expected:
              valStart = j + 1
              valEnd = nxt - 1
              return true
      var dummy: string
      var nxt: int
      if readJsonString(content, i, hi, dummy, nxt):
        i = nxt
      else:
        inc i
    elif c == '{' or c == '[':
      inc d
      inc i
    elif c == '}' or c == ']':
      dec d
      inc i
    else:
      inc i
  false

proc findGroupSpan*(content: string; group: string; glo,
    ghi: var int): bool =
  ## Span of the `"group": {...}` object value (`glo` at `{`, `ghi`
  ## past `}`). False when the group is absent or not an object.
  let want = "\"" & group & "\""
  var i = 0
  var d = 0
  let hi = content.len
  while i < hi:
    let c = content[i]
    if c == '"':
      if d == 1 and i + want.len <= hi and
          content[i ..< i + want.len] == want:
        var j = i + want.len
        skipWs(content, j, hi)
        if j < hi and content[j] == ':':
          inc j
          skipWs(content, j, hi)
          if j < hi and content[j] == '{':
            var k = j + 1
            var depth = 1
            while k < hi and depth > 0:
              if content[k] == '"':
                var dummy: string
                var nxt: int
                if readJsonString(content, k, hi, dummy, nxt):
                  k = nxt
                else:
                  inc k
              elif content[k] == '{':
                inc depth
                inc k
              elif content[k] == '}':
                dec depth
                inc k
              else:
                inc k
            if depth == 0:
              glo = j
              ghi = k
              return true
            return false
      var dummy: string
      var nxt: int
      if readJsonString(content, i, hi, dummy, nxt):
        i = nxt
      else:
        inc i
    elif c == '{' or c == '[':
      inc d
      inc i
    elif c == '}' or c == ']':
      dec d
      inc i
    else:
      inc i
  false

proc spliceValue(content: string; valStart, valEnd: int;
    newVal: string): string =
  content[0 ..< valStart] & newVal & content[valEnd .. ^1]

proc writeChecked(mf, updated: string): bool =
  ## Validates the rewrite parses, then writes it. False (with the
  ## reason already displayed) on any failure.
  try:
    discard fromJson(updated)
  except CatchableError as e:
    displayError(mf & ": rewrite failed validation: " & e.msg)
    return false
  try:
    writeFile(mf, updated)
  except IOError, OSError:
    displayError("cannot write " & mf & ": " &
      getCurrentExceptionMsg())
    return false
  true

proc bumpOwn(mf, content: string; root: JsonNode; newV: string;
    haveNew: bool; level: BumpLevel): int =
  if not root.hasKey("version") or root["version"].kind != JString:
    displayError(mf & ": no string \"version\" to bump")
    return 1
  let old = root["version"].getStr()
  var oldV: Version
  try:
    oldV = parseVersion(old.strip())
  except CatchableError:
    displayError(mf & ": \"version\" must be exact semver, got \"" &
      old & "\"")
    return 1
  let target = if haveNew: newV else: $bumpVersion(oldV, level)
  if target == old:
    displayInfo("already at " & old & ", nothing to do")
    return 0
  var vs, ve: int
  if not findValueSpan(content, "version", old, 1, 0, content.len,
      vs, ve):
    displayError(mf &
      ": could not locate the version value (unexpected formatting)")
    return 1
  if not writeChecked(mf, spliceValue(content, vs, ve, target)):
    return 1
  let name =
    if root.hasKey("name") and root["name"].kind == JString:
      root["name"].getStr()
    else: "package"
  displaySuccess("bumped " & name & " " & old & " -> " & target)
  0

proc bumpDep(mf, content: string; root: JsonNode; dep, newV: string;
    haveNew: bool; level: BumpLevel): int =
  var hits: seq[string] = @[]
  for g in depGroups:
    if not root.hasKey(g):
      continue
    let grp = root[g]
    if grp.kind != JObject:
      displayError(mf & ": \"" & g & "\" must be an object")
      return 1
    for k, v in grp.pairs:
      if v.kind != JString:
        displayError(mf & ": spec for \"" & k & "\" in \"" & g &
          "\" must be a string")
        return 1
    if grp.hasKey(dep):
      hits.add(g)
  if hits.len == 0:
    displayError("no direct dependency on \"" & dep &
      "\" in package.json (dependencies, devDependencies, " &
      "optionalDependencies, peerDependencies)")
    return 1
  var updated = content
  var reports: seq[string] = @[]
  for g in hits:
    let oldSpec = root[g][dep].getStr()
    var target: string
    try:
      if haveNew:
        target = setSpecVersion(oldSpec, parseVersion(newV))
      else:
        target = bumpSpec(oldSpec, level)
    except BumpError as e:
      displayError(dep & ": " & e.msg)
      return 1
    if target == oldSpec:
      reports.add(g & " already at " & oldSpec)
      continue
    var glo, ghi: int
    if not findGroupSpan(updated, g, glo, ghi):
      displayError(mf & ": could not locate \"" & g &
        "\" (unexpected formatting)")
      return 1
    var vs, ve: int
    if not findValueSpan(updated, dep, oldSpec, 1, glo, ghi, vs, ve):
      displayError(mf & ": could not locate \"" & dep & "\" in \"" &
        g & "\"")
      return 1
    updated = spliceValue(updated, vs, ve, target)
    reports.add(g & " " & oldSpec & " -> " & target)
  if not writeChecked(mf, updated):
    return 1
  displaySuccess("bumped " & dep & " (" & reports.join("; ") & ")")
  0

proc bumpCommand*(dir, versionArg, levelStr, depName: string): int =
  ## Bump the `package.json` found from `dir` upwards. `versionArg`
  ## sets an exact version, `levelStr` picks major|minor|patch
  ## (default patch), `depName` retargets a direct dependency instead
  ## of the own version. Returns the process exit code.
  if versionArg.len > 0 and levelStr.len > 0:
    displayError("pass either a version or --level, not both")
    return 1
  var level = blPatch
  if levelStr.len > 0:
    try:
      level = parseBumpLevel(levelStr)
    except BumpError as e:
      displayError(e.msg)
      return 1
  var newV = ""
  if versionArg.len > 0:
    try:
      newV = $parseVersion(versionArg.strip())
    except CatchableError:
      displayError("bad version \"" & versionArg &
        "\" (want exact semver like 1.2.3; to bump a dependency, " &
        "use --dep=<name>)")
      return 1
  let mf = findPackageJson(dir)
  if mf.len == 0:
    displayError("no package.json found " &
      "(run `carne bump` inside a package directory)")
    return 1
  var content: string
  try:
    content = readFile(mf)
  except IOError, OSError:
    displayError("cannot read " & mf & ": " & getCurrentExceptionMsg())
    return 1
  var root: JsonNode
  try:
    root = fromJson(content)
  except CatchableError as e:
    displayError(mf & ": invalid JSON: " & e.msg)
    return 1
  if root.kind != JObject:
    displayError(mf & ": top level must be an object")
    return 1
  if depName.len == 0:
    bumpOwn(mf, content, root, newV, versionArg.len > 0, level)
  else:
    bumpDep(mf, content, root, depName.strip(), newV,
      versionArg.len > 0, level)
