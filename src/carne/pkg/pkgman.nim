# Carne package management on top of datpkgr.
#
# Owns the `~/.carne` home (`CARNE_HOME` overrides it): datpkgr keeps its
# databases, `packages/`, `develop/` and caches there. The home is created
# on the first package operation - there is no setup step.
#
# Packages are JS source trees declared by `package.json` (see
# `pkgmanifest`). This phase supports registry installs (once the carne
# packages source exists), installs by git URL and editable `develop`
# checkouts.
#
# NOTE: importing `datpkgr/operations` pulls the install thread pool, so
# any binary linking this module must build with `--threads:on` (the
# carne host does; see `src/carne.nims`). The CLI imports this module
# under `when isMainModule` only, keeping library imports threads-free.

import std/[algorithm, json, options, os, sequtils, strutils, tables]
import pkg/datpkgr/[config, install, operations, store, types]
import ../cli
import ./pkgmanifest

export config, install, operations, store, types
export pkgmanifest

const pkgRegistryUrl* =
  "https://raw.githubusercontent.com/openpeeps/carnepkgs/main/packages.json"
  ## The default packages registry (openpeeps/carnepkgs).

const pkgDefaultSourceName* = "carne"
  ## The default registry source name in sources.json.

proc carneHome*(): string =
  ## Package-manager home: `CARNE_HOME` or `~/.carne`.
  getEnv("CARNE_HOME", getHomeDir() / ".carne")

proc carneLogCb(level: LogLevel, msg: string) {.gcsafe.} =
  ## datpkgr log levels through the CLI display procs, so pkg output
  ## carries the same colors as the rest of the CLI (Info: cyan,
  ## Success: green, Warning: yellow, Error: red).
  case level
  of lvlDebug:
    stderr.writeLine("[pkg] " & msg)
  of lvlInfo:
    displayInfo(msg)
  of lvlSuccess:
    displaySuccess(msg)
  of lvlWarn:
    displayWarning(msg)
  of lvlError:
    displayError(msg)

proc ensurePkgSource*(cfg: DatpkgrConfig) =
  ## Make sure the carne registry source is registered. Fresh homes get
  ## it from datpkgr's own defaults; homes created before the registry
  ## existed carry a sourceless sources.json that `ensureSourcesFile`
  ## never upgrades (it only writes when missing), so add it here.
  ##
  ## NB: consult the raw file, not `loadSources` - its fallback fabricates
  ## a usable-looking entry named `defaultSourceName` when the file yields
  ## nothing, which is indistinguishable from a registered source.
  var present = false
  try:
    let content = readFile(cfg.rootPath / cfg.sourcesPath())
    let j = parseJson(content)
    let arr = if j.kind == JArray: j
      elif j.kind == JObject and j.hasKey("sources"): j["sources"]
      else: newJArray()
    if arr.kind == JArray:
      for item in arr:
        if item.kind == JObject and item.hasKey("name") and
            item["name"].getStr == cfg.defaultSourceName and
            item.hasKey("url") and item["url"].getStr.len > 0:
          present = true
          break
  except CatchableError:
    discard
  if present:
    return
  # Drop sourceless entries on the way through (the pre-registry
  # default has an empty URL and can never seed anything).
  var sources: seq[Source] = @[]
  for src in cfg.loadSources():
    if src.url.len > 0 and src.name != cfg.defaultSourceName:
      sources.add(src)
  sources.add(Source(name: cfg.defaultSourceName,
    url: cfg.defaultRegistryUrl))
  cfg.saveSources(sources)

proc newCarnePkgConfig*(rootPath = "", debug = false,
    ensureSource = true): DatpkgrConfig =
  ## datpkgr config rooted at the carne home, wired to `package.json`
  ## manifests, the carne packages registry and plain CLI logging.
  ## `rootPath` overrides the home (tests point it at a temp dir for
  ## hermetic runs). `ensureSource = false` skips the home-dir IO.
  let root = if rootPath.len > 0: rootPath else: carneHome()
  var cbs: Callbacks
  cbs.log = carneLogCb
  result = newDatpkgrConfig("carne", root, debugEnabled = debug,
    callbacks = cbs)
  result.manifestParser = parsePackageManifest
  result.manifestFinder = findPackageJson
  result.manifestFileName = proc(pkg: string): string = pkgManifestFileName
  result.requiredManifestFile = some(pkgManifestFileName)
  result.defaultRegistryUrl = pkgRegistryUrl
  result.defaultSourceName = pkgDefaultSourceName
  if ensureSource:
    result.ensurePkgSource()

proc splitRef(spec: string): tuple[clean, refStr: string] =
  ## Split a `#ref` (branch/tag) suffix off an install spec.
  let pos = spec.find('#')
  if pos < 0:
    (spec, "")
  else:
    (spec[0 ..< pos].strip(), spec[pos + 1 .. ^1].strip())

proc pkgInstall*(cfg: DatpkgrConfig, spec: string, url = "",
    verbose = true): bool =
  ## Install one package: `spec` is a registry name (needs the carne
  ## packages source), a git URL, a forge alias (`gh:user/repo`, ...),
  ## any of those with a `#ref` (branch/tag) suffix, or a name with
  ## explicit `--url`.
  var name = spec.strip()
  var srcUrl = url.strip()
  if srcUrl.len == 0 and isForgeAliasShape(name):
    # `gh:user/repo` installs straight from git, like a written-out
    # https URL. Unknown `x:y` shapes keep the legacy behavior (looked
    # up as a registry name) instead of raising here.
    try: name = expandForgeAlias(name)
    except ValueError: discard
  var refStr = ""
  if srcUrl.len > 0:
    if isForgeAliasShape(srcUrl):
      try: srcUrl = expandForgeAlias(srcUrl)
      except ValueError: discard
    let parts = splitRef(srcUrl)
    srcUrl = parts.clean
    refStr = parts.refStr
  if srcUrl.len > 0:
    cfg.installPackage(name, refStr, url = srcUrl, verbose = verbose)
  elif isGitUrl(name) or name.startsWith("file://"):
    let parts = splitRef(name)
    cfg.installPackage(pkgNameFromUrl(parts.clean), parts.refStr,
      url = parts.clean, verbose = verbose)
  else:
    let parts = splitRef(name)
    if parts.refStr.len > 0:
      cfg.installPackage(parts.clean, parts.refStr, verbose = verbose)
    else:
      cfg.installPackage(name, verbose = verbose)

proc pkgRemove*(cfg: DatpkgrConfig, name: string,
    version = ""): bool =
  ## Uninstall `name` (one version, or all when `version` is empty).
  ## No confirm callback: the CLI confirms nothing, removal is immediate.
  cfg.uninstallPackage(name, version)

proc pkgUpdate*(cfg: DatpkgrConfig, name = "",
    verbose = true): bool =
  ## Update one package, or every installed package when `name` is empty.
  if name.len == 0:
    cfg.updateAllPackages(verbose = verbose)
  else:
    cfg.updatePackage(name, verbose = verbose)

proc pkgDevelop*(cfg: DatpkgrConfig, dir: string): bool =
  ## Editable install: link `~/.carne/develop/<name>` at `dir`.
  ## The directory must carry a `package.json` manifest.
  cfg.developPackage(dir)

proc pkgPrune*(cfg: DatpkgrConfig) =
  ## Drop orphaned packages (installed but no longer reachable).
  cfg.prunePackages()

proc pkgList*(cfg: DatpkgrConfig) =
  ## Print installed packages as `name@version  path`, roots first.
  let all = cfg.installedRecordsAll()
  if all.len == 0:
    echo "no packages installed"
    return
  var roots: seq[string] = @[]
  var rest: seq[string] = @[]
  for name in sorted(all.keys.toSeq):
    var isRoot = false
    for rec in all[name]:
      if rec.root:
        isRoot = true
        break
    if isRoot:
      roots.add(name)
    else:
      rest.add(name)
  for name in roots & rest:
    for rec in all[name]:
      var line = name & "@" & rec.version
      if rec.path.len > 0:
        line.add("  " & rec.path)
      echo line

proc firstExisting(paths: varargs[string]): string =
  for p in paths:
    if p.len > 0 and fileExists(p):
      return p
  ""

proc packageEntryPoint*(cfg: DatpkgrConfig, root, name: string): string =
  ## Absolute path of a package's entry file: the `exports` map root
  ## (Node parity: it wins over `main`), then manifest `main`, then
  ## `index.js`, `src/index.js`, `<name>.js` - first hit wins,
  ## "" when nothing exists.
  let mf = cfg.findManifestInDir(root)
  if mf.len > 0:
    try:
      let m = cfg.parseManifest(readFile(mf), mf)
      let exp = m.manifestExportsEntry()
      if exp.len > 0:
        var p = exp
        while p.startsWith("./"):
          p = p[2 .. ^1]
        if not p.startsWith("..") and not p.isAbsolute:
          let hit = firstExisting(root / p)
          if hit.len > 0:
            return hit
      let main = m.manifestMain()
      if main.len > 0:
        let hit = firstExisting(root / main)
        if hit.len > 0:
          return hit
    except CatchableError:
      discard
  firstExisting(root / "index.js", root / "src" / "index.js",
    root / name & ".js")

proc resolvePkgImport*(cfg: DatpkgrConfig,
    spec: string; preferRef = ""): Option[string] =
  ## Map `pkg/<name>` (or `pkg/<name>/sub/path`) to an absolute script
  ## path, none when unresolvable. Develop checkouts win automatically
  ## via `resolveInstalledPath`. `..` escapes are rejected. `preferRef`
  ## pins an exact installed version/ref instead of the default pick.
  const prefix = "pkg/"
  if not spec.startsWith(prefix):
    return none(string)
  let tail = spec[prefix.len .. ^1]
  if tail.len == 0:
    return none(string)
  let slash = tail.find('/')
  let name = if slash < 0: tail else: tail[0 ..< slash]
  let rest = if slash < 0: "" else: tail[slash + 1 .. ^1]
  if name.len == 0 or name == "." or name == "..":
    return none(string)
  let root = cfg.resolveInstalledPath(name, preferRef)
  if root.len == 0 or not dirExists(root):
    return none(string)
  if rest.len == 0:
    let entry = cfg.packageEntryPoint(root, name)
    if entry.len == 0:
      return none(string)
    return some(entry)
  let joined = normalizedPath(root / rest)
  if joined != root and not joined.startsWith(root & DirSep):
    return none(string)
  if splitFile(joined).ext.len > 0:
    if fileExists(joined):
      return some(joined)
    return none(string)
  let hit = firstExisting(joined & ".js")
  if hit.len > 0:
    return some(hit)
  none(string)
