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
  "https://raw.githubusercontent.com/getcarne/carnepkgs/main/packages.json"
  ## The default packages registry (getcarne/carnepkgs).

const pkgDefaultSourceName* = "carne"
  ## The default registry source name in sources.json.

proc carneHome*(): string =
  ## Package-manager home: `CARNE_HOME` or `~/.carne`.
  getEnv("CARNE_HOME", getHomeDir() / ".carne")

proc carneBinDir*(home = carneHome()): string =
  ## Self-install directory: `<home>/bin` holds the carne binary
  ## (`carne upgrade` installs here, like `~/.clue/bin` for clue).
  home / "bin"

proc carneLogCb(level: LogLevel, msg: string) {.gcsafe.} =
  ## datpkgr log levels through the CLI display procs, so pkg output
  ## carries the same colors as the rest of the CLI (Info: cyan,
  ## Success: green, Warning: yellow, Error: red). Continuation lines
  ## (datpkgr's 2-space indent: tree entries, resolved packages,
  ## fetch events) print bare at 8 spaces with no label.
  case level
  of lvlDebug:
    stderr.writeLine("[pkg] " & msg)
  of lvlInfo:
    if msg.startsWith("  "):
      display(span("      " & msg))
    else:
      displayInfo(msg)
  of lvlSuccess:
    displaySuccess(msg)
  of lvlWarn:
    displayWarning(msg)
  of lvlError:
    displayError(msg)

proc ensurePkgSource*(cfg: DatpkgrConfig) =
  ## Make sure the carne registry source is registered at the current
  ## default URL. Fresh homes get it from datpkgr's own defaults; homes
  ## created before the registry existed carry a sourceless sources.json
  ## that `ensureSourcesFile` never upgrades (it only writes when
  ## missing), so add it here. Homes created between registry moves
  ## carry a stale URL (openpeeps/carnepkgs, carne/pkgs, ...) that 404s
  ## on refresh, so heal those to the default too - the `carne`-named
  ## source is owned by the binary, custom mirrors live under their own
  ## names and pass through untouched.
  ##
  ## NB: consult the raw file, not `loadSources` - its fallback fabricates
  ## a usable-looking entry named `defaultSourceName` when the file yields
  ## nothing, which is indistinguishable from a registered source.
  var storedUrl = ""
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
          storedUrl = item["url"].getStr
          break
  except CatchableError:
    discard
  if storedUrl == cfg.defaultRegistryUrl:
    return
  # Rebuild through loadSources: drop sourceless entries (the
  # pre-registry default has an empty URL and can never seed anything)
  # and collapse the default source to one entry at the current URL.
  var sources: seq[Source] = @[]
  var healed = false
  for src in cfg.loadSources():
    if src.name == cfg.defaultSourceName:
      if healed or src.url != cfg.defaultRegistryUrl:
        continue
      healed = true
      sources.add(src)
    elif src.url.len > 0:
      sources.add(src)
  if not healed:
    sources.add(Source(name: cfg.defaultSourceName,
      url: cfg.defaultRegistryUrl))
  cfg.saveSources(sources)
  if storedUrl.len > 0:
    displayInfo("registry source `" & cfg.defaultSourceName &
      "`: updated URL to " & cfg.defaultRegistryUrl)

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

proc insidePkgRoot*(root, candidate: string): bool =
  ## True when `candidate` resolves inside `root`. Both sides go through
  ## `realpath`, so symlinks at any level (a `link.js -> /etc/passwd`
  ## file, a `lib -> /tmp/evil` dir on the path, an entry point
  ## pointing out) fail closed. Non-existent paths fail closed too.
  try:
    let r = expandFilename(root)
    let p = expandFilename(candidate)
    p == r or p.startsWith(r & DirSep)
  except OSError:
    false

proc entryTargetOk(target: string): string =
  ## A manifest `main`/`exports` value reduced to an in-package
  ## relative path, "" when it escapes. Strips the `./` prefix Node
  ## allows, then rejects absolute paths and anything normalizing up
  ## past the package root (`../x`, `a/../../x`).
  var p = target
  while p.startsWith("./"):
    p = p[2 .. ^1]
  if p.len == 0 or p.isAbsolute:
    return ""
  let n = normalizedPath(p)
  if n == ".." or n.startsWith(".." & DirSep):
    return ""
  n

proc containedHit(root, path: string): string =
  ## `path` when it is a real file inside `root`, "" otherwise.
  if path.len > 0 and fileExists(path) and insidePkgRoot(root, path):
    return path
  ""

proc packageEntryPoint*(cfg: DatpkgrConfig, root, name: string): string =
  ## Absolute path of a package's entry file: the `exports` map root
  ## (Node parity: it wins over `main`), then manifest `main`, then
  ## `index.js`, `src/index.js`, `<name>.js` - first hit wins,
  ## "" when nothing exists. Manifest targets that escape the package
  ## (`../`, absolute) and hits resolving outside the root via
  ## symlinks are skipped, never returned.
  let mf = cfg.findManifestInDir(root)
  if mf.len > 0:
    try:
      let m = cfg.parseManifest(readFile(mf), mf)
      let exp = entryTargetOk(m.manifestExportsEntry())
      if exp.len > 0:
        let hit = containedHit(root, root / exp)
        if hit.len > 0:
          return hit
      let main = entryTargetOk(m.manifestMain())
      if main.len > 0:
        let hit = containedHit(root, root / main)
        if hit.len > 0:
          return hit
    except CatchableError:
      discard
  for cand in [root / "index.js", root / "src" / "index.js",
      root / name & ".js"]:
    let hit = containedHit(root, cand)
    if hit.len > 0:
      return hit
  ""

proc resolvePkgImport*(cfg: DatpkgrConfig,
    spec: string; preferRef = ""): Option[string] =
  ## Map `pkg/<name>` (or `pkg/<name>/sub/path`) to an absolute script
  ## path, none when unresolvable. Develop checkouts win automatically
  ## via `resolveInstalledPath`. Any `..` segment in the subpath is
  ## rejected outright (fail closed, even when it would stay inside),
  ## and every hit is verified to resolve inside the package root, so
  ## symlinks pointing out can never be returned. `preferRef`
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
  for seg in rest.split('/'):
    if seg == "..":
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
    let hit = containedHit(root, joined)
    if hit.len > 0:
      return some(hit)
    return none(string)
  let hit = containedHit(root, joined & ".js")
  if hit.len > 0:
    return some(hit)
  none(string)
