# Carne pkg imports: `require("pkg/<name>[/sub][@ver]")` and relative requires.
#
# Loads package JS as CommonJS: the file is wrapped in
# `(function(module, exports) { ... })` and called; `module.exports` is
# returned and cached per spec. The exports object is cached *before*
# the call, so circular requires see partial exports like Node. Like
# std instances, cached values are referenced from `rt.instances` only
# (no extra GC protection).
#
# Wired via `pkgRequireHook` in ../modules so that module stays free of
# the package-manager dependency: tests link only what they import.
# v1 out of scope with explicit errors: ESM (import/export syntax),
# bare `require("name")`, non-JS entries.

import std/[atomics, locks, options, os, strutils, tables]

import javascriptcore

import ../bridge
import ../modules
import ./pkgman

var loaderCfg: DatpkgrConfig = nil

var pkgResolveLock: Lock
var pkgResolveLockState: Atomic[int]
  ## Process-wide pkg resolution lock (once-init below). Http workers
  ## re-run the script on separate threads, and the package store is
  ## not thread-safe, so concurrent `pkg/` resolves race on the store
  ## files. Resolution is startup-only (instances cache per runtime),
  ## so serializing here costs nothing at steady state.

proc ensurePkgResolveLock() =
  if pkgResolveLockState.load(moAcquire) != 2:
    if pkgResolveLockState.exchange(1, moAcquireRelease) == 0:
      initLock(pkgResolveLock)
      pkgResolveLockState.store(2, moRelease)
    else:
      while pkgResolveLockState.load(moAcquire) != 2:
        cpuRelax()

proc looksEsm(code: string): bool =
  ## Line-anchored import/export keyword heuristic (`//` comments
  ## skipped). Block comments and strings can fool it; v1 accepts that.
  for line in code.splitLines():
    let t = line.strip()
    if t.startsWith("//"):
      continue
    for kw in ["import", "export"]:
      if t.startsWith(kw):
        if t.len == kw.len:
          return true
        if t[kw.len] in {' ', '\t', '{', '*', '"', '\''}:
          return true
  false

proc loadJsFile*(ctx: JSContextRef; rt: Runtime; spec, path: string;
    exception: ptr JSValueRef): JSValueRef =
  ## CommonJS-loads one file, returns `module.exports`.
  var code: string
  try:
    code = readFile(path)
  except IOError as e:
    throwError(ctx, "require: cannot read \"" & spec & "\": " & e.msg,
      exception)
    return nil
  if looksEsm(code):
    throwError(ctx, "require: pkg \"" & spec &
      "\" uses ESM (import/export) - only CommonJS is supported",
      exception)
    return nil
  let moduleObj = newObject(ctx)
  let exportsObj = newObject(ctx)
  var setupEx: JSValueRef = nil
  setProp(ctx, moduleObj, "exports", exportsObj, addr setupEx)
  if setupEx != nil:
    throwError(ctx, "require: failed to initialize \"" & spec & "\"",
      exception)
    return nil
  rt.instances[spec] = exportsObj
  let wrapped = "(function(module, exports) {\n" & code & "\n})"
  var ex: JSValueRef = nil
  let fn = evalScript(ctx, wrapped, sourceURL = path, exception = ex)
  if ex != nil or fn == nil or not JSValueIsObject(ctx, fn) or
      not JSObjectIsFunction(ctx, cast[JSObjectRef](fn)):
    rt.instances.del(spec)
    let msg = if ex != nil: valueToString(ctx, ex) else: "not a function"
    throwError(ctx, "require: failed to load \"" & spec & "\": " & msg,
      exception)
    return nil
  rt.moduleStack.add(path.parentDir())
  try:
    var callEx: JSValueRef = nil
    var args: array[2, JSValueRef]
    args[0] = moduleObj
    args[1] = exportsObj
    discard JSObjectCallAsFunction(ctx, cast[JSObjectRef](fn), nil, 2,
      addr args[0], addr callEx)
    if callEx != nil:
      rt.instances.del(spec)
      throwError(ctx, "require: error in \"" & spec & "\": " &
        valueToString(ctx, callEx), exception)
      return nil
  finally:
    discard rt.moduleStack.pop()
  # `module.exports` may have been reassigned; that is the result.
  var getEx: JSValueRef = nil
  let key = newJSString("exports")
  defer: JSStringRelease(key)
  let finalExp = JSObjectGetProperty(ctx, moduleObj, key, addr getEx)
  if getEx != nil or finalExp == nil:
    rt.instances.del(spec)
    throwError(ctx, "require: failed to read exports of \"" & spec & "\"",
      exception)
    return nil
  rt.instances[spec] = finalExp
  finalExp

proc requirePkg(ctx: JSContextRef; rt: Runtime; spec: string;
    exception: ptr JSValueRef): JSValueRef =
  ## Resolves `pkg/<name>[@ver][/sub]` against the store and loads it.
  let tail = spec["pkg/".len .. ^1]
  let slash = tail.find('/')
  let head = if slash < 0: tail else: tail[0 ..< slash]
  let rest = if slash < 0: "" else: tail[slash + 1 .. ^1]
  let at = head.find('@')
  var name = head
  var ver = ""
  if at >= 0:
    name = head[0 ..< at]
    ver = head[at + 1 .. ^1]
  if name.len == 0 or name == "." or name == ".." or '\0' in name or
      '\\' in name:
    throwError(ctx, "require: unknown module \"" & spec & "\"", exception)
    return nil
  # Fail closed on malformed pins: an empty or dot-only version would
  # otherwise silently fall back to the latest installed version, and
  # a second `@` makes the pin ambiguous.
  if at >= 0 and (ver.len == 0 or ver == "." or ver == ".." or
      '@' in ver or '\\' in ver or '\0' in ver):
    throwError(ctx, "require: invalid package version in \"" & spec & "\"",
      exception)
    return nil
  # Any `..` segment in the subpath is rejected outright, even one
  # that would stay inside the package: `pkg/<name>/sub/...` never
  # leaves the package root. The resolver re-checks this plus
  # symlink containment (defense in depth).
  for seg in rest.split('/'):
    if seg == ".." or '\0' in seg:
      throwError(ctx, "require: invalid package path \"" & spec & "\"",
        exception)
      return nil
  # Resolve under the process-wide lock: the store underneath is not
  # thread-safe and http workers resolve concurrently. Only the lookup
  # is serialized — loading and running the module stays per-runtime.
  # (Nested `pkg/` requires inside module code re-enter cleanly since
  # the lock is released before loadJsFile runs.)
  var path = ""
  ensurePkgResolveLock()
  withLock pkgResolveLock:
    if loaderCfg == nil:
      loaderCfg = newCarnePkgConfig(ensureSource = false)
    let root = loaderCfg.resolveInstalledPath(name, ver)
    if root.len == 0 or not dirExists(root):
      throwError(ctx, "require: unknown package \"" & spec &
        "\" (is it installed? see `carne pkg list`)", exception)
      return nil
    let sub = if rest.len > 0: "/" & rest else: ""
    let resolved = loaderCfg.resolvePkgImport("pkg/" & name & sub, ver)
    if resolved.isNone:
      throwError(ctx, "require: package \"" & spec &
        "\" has no loadable entry (no main/exports/index.js)", exception)
      return nil
    path = resolved.get
  loadJsFile(ctx, rt, spec, path, exception)

proc requireRelative(ctx: JSContextRef; rt: Runtime; spec: string;
    exception: ptr JSValueRef): JSValueRef =
  ## Resolves `./x` against the requiring file's directory. Cache key is
  ## the absolute path so different spellings share one instance.
  if rt.moduleStack.len == 0:
    throwError(ctx, "require: relative import \"" & spec &
      "\" outside a package (only pkg files can use ./...)", exception)
    return nil
  let joined = normalizedPath(rt.moduleStack[^1] / spec)
  for cand in [joined, joined & ".js", joined / "index.js"]:
    if fileExists(cand):
      if rt.instances.hasKey(cand):
        return rt.instances[cand]
      return loadJsFile(ctx, rt, cand, cand, exception)
  throwError(ctx, "require: cannot find \"" & spec & "\"", exception)
  nil

proc pkgRequireImpl(ctx: JSContextRef; spec: string;
    exception: ptr JSValueRef): JSValueRef =
  let rt = currentRt()
  if rt == nil:
    throwError(ctx, "require: no runtime", exception)
    return nil
  if rt.instances.hasKey(spec):
    return rt.instances[spec]
  if spec.startsWith("pkg/"):
    return requirePkg(ctx, rt, spec, exception)
  requireRelative(ctx, rt, spec, exception)

proc initPkgLoader*(cfg: DatpkgrConfig) =
  ## Binds `require("pkg/...")` to `cfg` (tests pass a fixture home).
  loaderCfg = cfg
  pkgRequireHook = pkgRequireImpl

proc initPkgLoaderLazy*() =
  ## Binary wiring: the CARNE_HOME config is built on the first pkg
  ## require, so plain `carne run` never touches the home dir for
  ## std-only scripts.
  pkgRequireHook = pkgRequireImpl
