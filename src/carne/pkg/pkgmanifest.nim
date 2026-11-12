# Carne `package.json` manifest parser (datpkgr `ManifestParser` compatible).
#
# npm-spec compliant, parsed with openparser/json:
#
#   ```json
#   {
#     "name": "myutils",
#     "version": "0.1.0",
#     "description": "handy string helpers",
#     "license": "MIT",
#     "main": "src/myutils.js",
#     "dependencies": { "otherlib": "^0.2.0" }
#   }
#   ```
#
# `name` and `version` are required. `name` follows npm's new-package rules
# (1-214 chars, no leading `.`/`_`, lowercase, no spaces or URL-unsafe
# characters; scoped `@scope/name` packages are rejected in v1).
# `version` must be exact semver. `license` accepts the string form and the
# legacy `{type: "..."}` object. `dependencies`, `devDependencies` and
# `optionalDependencies` map name->spec pairs: semver ranges go through
# datpkgr's `parseConstraint`, `*`/`""`/`latest` means any, `npm:name@range`
# aliases resolve to name + constraint, git specs land in `url`.
# `file:`/`portal:`/`workspace:` specs, tarballs and dist-tags other than
# `latest` are manifest errors. `peerDependencies` is syntax-checked and
# carried in `extra` with no solver behavior. Everything else
# (`keywords`, `scripts`, `engines`, `main`, `exports`, `bin`, ...) is
# carried verbatim in `extra`, so `main`/`exports` resolution later sees
# the full document.
#
# The manifest is parsed, never evaluated: this module stays threads-free
# and importable from unit tests under default flags.

import std/[os, strutils, tables]
import pkg/openparser/json
import pkg/datpkgr/[resolver, types]
import pkg/semver

type
  PackageManifestError* = object of CatchableError

const pkgManifestFileName* = "package.json"
  ## The JS package manifest filename.

proc manifestErr(path, msg: string): ref PackageManifestError =
  newException(PackageManifestError, path & ": " & msg)

proc strField(obj: JsonNode; path, field: string): string =
  ## Value of a string-valued field, "" when absent. Anything present
  ## but not a string is a manifest error.
  if not obj.hasKey(field):
    return ""
  let v = obj[field]
  if v.kind != JString:
    raise manifestErr(path, "\"" & field & "\" must be a string")
  v.getStr()

proc validateName*(path, name: string) =
  ## npm new-package name rules (minus registry-availability checks).
  if name.len == 0:
    raise manifestErr(path, "\"name\" is required")
  if name.len > 214:
    raise manifestErr(path, "\"name\" exceeds 214 characters")
  if name[0] == '.' or name[0] == '_':
    raise manifestErr(path, "\"name\" cannot start with '.' or '_'")
  if name.startsWith("@"):
    raise manifestErr(path,
      "scoped packages (\"@scope/name\") are not supported")
  if name != name.toLowerAscii():
    raise manifestErr(path, "\"name\" must be lowercase")
  for c in name:
    if c in {'A'..'Z'} or c in {' ', '~', '\'', '!', '(', ')', '*', '/'}:
      raise manifestErr(path,
        "\"name\" contains an invalid character: '" & $c & "'")
    if c.ord < 0x20 or c.ord == 0x7F:
      raise manifestErr(path, "\"name\" contains a control character")

proc validateVersion(path, version: string) =
  ## Own version must be present and exact semver (ranges rejected).
  if version.strip().len == 0:
    raise manifestErr(path, "\"version\" is required")
  try:
    discard parseVersion(version.strip())
  except CatchableError:
    raise manifestErr(path,
      "\"version\" must be exact semver, got \"" & version & "\"")

proc isGitSpec(spec: string): bool =
  ## True for specs datpkgr can clone: git transports, shorthands, .git URLs.
  spec.startsWith("git+") or spec.startsWith("git://") or
    spec.startsWith("github:") or spec.startsWith("gitlab:") or
    spec.startsWith("bitbucket:") or spec.startsWith("git@") or
    spec.endsWith(".git")

proc parseDepSpec(path, depName, spec: string): PkgDependency =
  ## Maps one npm dependency spec onto a datpkgr PkgDependency.
  let s = spec.strip()
  if s == "" or s == "*" or s == "latest":
    return PkgDependency(name: depName, url: "",
      constraint: parseConstraint("*"), branch: "", tag: "",
      features: @[], isToolchain: false)
  if s.startsWith("npm:"):
    # npm:name@range alias: install `name` at `range`.
    let inner = s["npm:".len .. ^1]
    let at = inner.rfind('@')
    if at <= 0:
      raise manifestErr(path, "bad alias for \"" & depName & "\": \"" &
        spec & "\"")
    let realName = inner[0 ..< at]
    let range = inner[at + 1 .. ^1]
    try:
      let constraint =
        if range.len == 0: parseConstraint("*")
        else: parseConstraint(range)
      return PkgDependency(name: realName, url: "", constraint: constraint,
        branch: "", tag: "", features: @[], isToolchain: false)
    except CatchableError as e:
      raise manifestErr(path, "bad alias range for \"" & depName &
        "\": " & e.msg)
  if isGitSpec(s):
    return PkgDependency(name: depName, url: s,
      constraint: parseConstraint("*"), branch: "", tag: "",
      features: @[], isToolchain: false)
  if s.startsWith("file:") or s.startsWith("portal:") or
      s.startsWith("workspace:") or s.startsWith("./") or
      s.startsWith("../") or s.startsWith("/") or s in [".", ".."]:
    raise manifestErr(path, "local spec for \"" & depName &
      "\" is not supported: \"" & spec & "\"")
  if "://" in s:
    raise manifestErr(path, "URL spec for \"" & depName &
      "\" is not supported: \"" & spec & "\"")
  if ' ' in s or "||" in s or " - " in s:
    raise manifestErr(path, "compound range for \"" & depName &
      "\" is not supported: \"" & spec & "\"")
  try:
    let constraint = parseConstraint(s)
    PkgDependency(name: depName, url: "", constraint: constraint,
      branch: "", tag: "", features: @[], isToolchain: false)
  except CatchableError:
    raise manifestErr(path, "bad spec for \"" & depName & "\": \"" &
      spec & "\"")

proc parseDepGroup(obj: JsonNode; path, field: string): seq[PkgDependency] =
  ## `field: {name: "spec"}` pairs. Absent field gives @[].
  if not obj.hasKey(field):
    return @[]
  let group = obj[field]
  if group.kind != JObject:
    raise manifestErr(path, "\"" & field & "\" must be an object")
  for name, spec in group.pairs:
    if spec.kind != JString:
      raise manifestErr(path, "spec for \"" & name & "\" in \"" & field &
        "\" must be a string")
    result.add(parseDepSpec(path, name, spec.getStr()))

proc checkDepGroupShape(obj: JsonNode; path, field: string) =
  ## Syntax-check only (used for peerDependencies): object of strings.
  if not obj.hasKey(field):
    return
  let group = obj[field]
  if group.kind != JObject:
    raise manifestErr(path, "\"" & field & "\" must be an object")
  for name, spec in group.pairs:
    if spec.kind != JString:
      raise manifestErr(path, "spec for \"" & name & "\" in \"" & field &
        "\" must be a string")

proc checkStringArray(obj: JsonNode; path, field: string) =
  ## Syntax-check only (bundledDependencies): array of strings.
  if not obj.hasKey(field):
    return
  let arr = obj[field]
  if arr.kind != JArray:
    raise manifestErr(path, "\"" & field & "\" must be an array")
  for item in arr:
    if item.kind != JString:
      raise manifestErr(path, "\"" & field & "\" must list strings")

proc parseLicense(obj: JsonNode; path: string): string =
  ## String form, plus the legacy `{type: "..."}` object.
  if not obj.hasKey("license"):
    return ""
  let v = obj["license"]
  case v.kind
  of JString:
    v.getStr()
  of JObject:
    if v.hasKey("type") and v["type"].kind == JString:
      v["type"].getStr()
    else:
      raise manifestErr(path,
        "\"license\" object must carry a string \"type\"")
  else:
    raise manifestErr(path, "\"license\" must be a string")

proc parsePackageManifest*(content: string, path: string): Manifest =
  ## Parse `package.json` source into a datpkgr `Manifest`. Raises
  ## `PackageManifestError` (a `CatchableError`, safe through datpkgr)
  ## on syntax errors and on spec violations. The full document is kept
  ## in `extra` for entry-point and registry use.
  var root: JsonNode
  try:
    root = fromJson(content)
  except CatchableError as e:
    raise manifestErr(path, "invalid JSON: " & e.msg)
  if root.kind != JObject:
    raise manifestErr(path, "top level must be an object")
  let name = root.strField(path, "name")
  validateName(path, name)
  let version = root.strField(path, "version")
  validateVersion(path, version)
  checkDepGroupShape(root, path, "peerDependencies")
  checkStringArray(root, path, "bundledDependencies")
  checkStringArray(root, path, "bundleDependencies")
  Manifest(path: path, name: name, version: version,
    description: root.strField(path, "description"),
    license: root.parseLicense(path),
    dependencies: root.parseDepGroup(path, "dependencies"),
    features: initTable[string, seq[PkgDependency]](),
    devDependencies: root.parseDepGroup(path, "devDependencies") &
      root.parseDepGroup(path, "optionalDependencies"),
    extra: root)

proc findPackageJson*(dir: string): string =
  ## `ManifestFinder` for JS packages: walk up from `dir` looking for
  ## `package.json`, "" when none is found.
  var cur = dir
  var depth = 0
  while depth < 15:
    let cand = cur / pkgManifestFileName
    if fileExists(cand):
      return cand
    let parent = cur.parentDir()
    if parent == cur:
      break
    cur = parent
    inc depth
  ""

proc manifestMain*(m: Manifest): string =
  ## The manifest `main` entry value, "" when absent or not a string.
  if m.extra == nil or m.extra.kind != JObject:
    return ""
  if not m.extra.hasKey("main"):
    return ""
  let v = m.extra["main"]
  if v.kind != JString:
    return ""
  v.getStr()

proc manifestExportsEntry*(m: Manifest): string =
  ## The root `"."` entry of the manifest `exports` map, "" when absent.
  ## A string maps directly; an object resolves the `default` condition,
  ## then `node`. Anything fancier (nested conditions, patterns) is v1
  ## out of scope.
  if m.extra == nil or m.extra.kind != JObject:
    return ""
  if not m.extra.hasKey("exports"):
    return ""
  let ex = m.extra["exports"]
  if ex.kind == JString:
    return ex.getStr()
  if ex.kind != JObject or not ex.hasKey("."):
    return ""
  let dot = ex["."]
  if dot.kind == JString:
    return dot.getStr()
  if dot.kind != JObject:
    return ""
  for cond in ["default", "node"]:
    if dot.hasKey(cond) and dot[cond].kind == JString:
      return dot[cond].getStr()
  ""
