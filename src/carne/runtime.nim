# Carne runtime: owns the JS context and the powpow event loop.
#
# Installs console.log (+ print alias), process.argv, global require and
# the timer globals, evaluates the script, then drains the loop while
# async work remains. macOS and Linux (system JavaScriptCore /
# JavaScriptCoreGTK 4.1).

import std/strutils
import std/tables
import std/monotimes
import std/times
import std/os
import std/atomics
import std/locks

import javascriptcore

import powpow/loop

import ./bridge
import ./modules
import ./std/timers

export bridge

var logLock: Lock
var logLockState: Atomic[int]
  ## Process-wide print lock (worker threads share stdout). Once-init
  ## below: 0 uninit, 1 initing, 2 ready.

proc lockLog*() =
  if logLockState.load(moAcquire) != 2:
    if logLockState.exchange(1, moAcquireRelease) == 0:
      initLock(logLock)
      logLockState.store(2, moRelease)
    else:
      while logLockState.load(moAcquire) != 2:
        cpuRelax()
  acquire(logLock)

proc unlockLog*() =
  release(logLock)

registerFn(ctx, consoleLog(rest: RestArgs)):
  ## console.log(...): joins args with spaces on stdout.
  var parts: seq[string] = @[]
  for v in rest:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      if ex != nil and exception != nil:
        exception[] = ex
      return nil
    let text = $s
    JSStringRelease(s)
    parts.add(text)
  lockLog()
  try:
    stdout.writeLine(parts.join(" "))
  finally:
    unlockLog()
  JSValueMakeUndefined(ctx)

proc topResolveImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  ## Settle-capture for a top-level completion promise (fulfilled).
  let rt = currentRt()
  if rt != nil:
    if int(argumentCount) > 0 and arguments != nil:
      let args = cast[ptr UncheckedArray[JSValueRef]](arguments)
      rt.promiseText = valueToString(ctx, args[0])
    else:
      rt.promiseText = ""
    rt.promiseSettled = true
    rt.promiseRejected = false
  JSValueMakeUndefined(ctx)

proc topRejectImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  ## Settle-capture for a top-level completion promise (rejected).
  let rt = currentRt()
  if rt != nil:
    if int(argumentCount) > 0 and arguments != nil:
      let args = cast[ptr UncheckedArray[JSValueRef]](arguments)
      rt.promiseText = valueToString(ctx, args[0])
    else:
      rt.promiseText = ""
    rt.promiseSettled = true
    rt.promiseRejected = true
  JSValueMakeUndefined(ctx)

proc thenFnOf(ctx: JSContextRef; v: JSValueRef): JSObjectRef =
  ## Returns v's `then` when v is an object with a callable `then`
  ## (Promise or thenable), else nil. Never throws.
  if v == nil or not JSValueIsObject(ctx, v):
    return nil
  var ex: JSValueRef = nil
  let key = newJSString("then")
  defer: JSStringRelease(key)
  let prop = JSObjectGetProperty(ctx, v, key, addr ex)
  if ex != nil or prop == nil or not JSValueIsObject(ctx, prop):
    return nil
  if not JSObjectIsFunction(ctx, prop):
    return nil
  prop

proc installConsole(ctx: JSContextRef; setupEx: ptr JSValueRef) =
  ## Installs global `console.log` and a `print` alias.
  let global = JSContextGetGlobalObject(ctx)
  let logFn = makeFunction(ctx, "log", consoleLog)
  let consoleObj = newObject(ctx)
  setProp(ctx, consoleObj, "log", logFn, setupEx)
  setProp(ctx, global, "console", consoleObj, setupEx)
  setProp(ctx, global, "print", logFn, setupEx)

proc installProcess(ctx: JSContextRef; argv: seq[string];
    setupEx: ptr JSValueRef) =
  ## Installs global `process.argv` from the given Nim strings.
  let global = JSContextGetGlobalObject(ctx)
  var vals: seq[JSValueRef] = @[]
  for arg in argv:
    vals.add(toJS(ctx, arg))
  var ex: JSValueRef = nil
  let arr =
    if vals.len > 0:
      JSObjectMakeArray(ctx, csize_t(vals.len), addr vals[0], addr ex)
    else:
      JSObjectMakeArray(ctx, 0, nil, addr ex)
  let processObj = newObject(ctx)
  setProp(ctx, processObj, "argv", arr, setupEx)
  # Frozen per context at boot: workers (threads spawned by http.serve
  # workers) install true, main installs false. Driver code gates on it
  # (workers re-run the whole script, so fetch/close/test scaffolding
  # must be main-only).
  setProp(ctx, processObj, "isWorker", toJS(ctx, inHttpWorker()), setupEx)
  setProp(ctx, global, "process", processObj, setupEx)

proc installEntryModule(ctx: JSContextRef; setupEx: ptr JSValueRef) =
  ## Exposes `module` / `exports` to file-backed entry scripts, so a
  ## package wrapper (`index.js`) also runs directly via `carne
  ## index.js`. Set as plain global-object properties (not lexical
  ## bindings), so a script's own top-level `const module` still
  ## shadows cleanly. `module.exports` reassignments are not read
  ## back — the entry's completion value keeps the eval semantics.
  let global = JSContextGetGlobalObject(ctx)
  let moduleObj = newObject(ctx)
  let exportsObj = newObject(ctx)
  setProp(ctx, moduleObj, "exports", exportsObj, setupEx)
  setProp(ctx, global, "module", moduleObj, setupEx)
  setProp(ctx, global, "exports", exportsObj, setupEx)

proc mark(prof: bool; pt: var MonoTime; phase: string) =
  ## CARNE_PROFILE phase timer (dev aid, zero cost when off).
  if prof:
    let now = getMonoTime()
    stderr.writeLine("carne-prof " & phase & "=" &
      $(inNanoseconds(now - pt) div 1000) & "us")
    pt = now

proc hasAwaitToken(code: string): bool =
  ## Finds an await identifier without matching comments or quoted text.
  var i = 0
  var templateStates: seq[bool] = @[]
  var expressionBraces: seq[int] = @[]
  while i < code.len:
    if templateStates.len > 0 and not templateStates[^1]:
      if code[i] == '\\':
        i = min(i + 2, code.len)
      elif code[i] == '`':
        discard templateStates.pop()
        inc i
      elif code[i] == '$' and i + 1 < code.len and code[i + 1] == '{':
        templateStates[^1] = true
        expressionBraces.add(1)
        i += 2
      else:
        inc i
    elif code[i] in {' ', '\t', '\r', '\n'}:
      inc i
    elif code[i] == '/' and i + 1 < code.len and code[i + 1] == '/':
      i += 2
      while i < code.len and code[i] != '\n':
        inc i
    elif code[i] == '/' and i + 1 < code.len and code[i + 1] == '*':
      i += 2
      while i + 1 < code.len and
          not (code[i] == '*' and code[i + 1] == '/'):
        inc i
      i = min(i + 2, code.len)
    elif code[i] in {'"', '\''}:
      let quote = code[i]
      inc i
      while i < code.len:
        if code[i] == '\\':
          i = min(i + 2, code.len)
        elif code[i] == quote:
          inc i
          break
        else:
          inc i
    elif code[i] in {'a'..'z', 'A'..'Z', '_', '$'}:
      let start = i
      inc i
      while i < code.len and code[i] in
          {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'}:
        inc i
      if code[start ..< i] == "await":
        return true
    elif code[i] == '`':
      templateStates.add(false)
      inc i
    elif templateStates.len > 0 and templateStates[^1] and
        code[i] == '{':
      inc expressionBraces[^1]
      inc i
    elif templateStates.len > 0 and templateStates[^1] and
        code[i] == '}':
      if expressionBraces[^1] == 1:
        discard expressionBraces.pop()
        templateStates[^1] = false
      else:
        dec expressionBraces[^1]
      inc i
    else:
      inc i

var loopCreatedLastRun* = false
  ## True when the most recent runCodeEx on this thread created a powpow
  ## loop. Pure-sync scripts must leave it false (lazy loop contract).

proc runCodeEx*(code: string; sourceURL = "script.js";
    argv: seq[string] = @[]; baseDir = ""): tuple[output: string, code: int] =
  ## Evaluates `code`, drains async work, returns the completion value
  ## ("" for undefined) and the process exit code. Raises CarneError on
  ## JS exceptions (eval-time or uncaught async). The event loop is
  ## created lazily: pure-sync scripts never pay for it. `baseDir` seeds
  ## relative `require("./...")` for file-backed runs (see runFileEx).
  let rt = Runtime(ctx: nil, argv: argv, loop: nil, pending: 0,
    exitRequested: false, exitCode: 0, uncaught: "",
    instances: initTable[string, JSObjectRef](), moduleStack: @[],
    timerSeq: 0, timers: initTable[int, TimerEntry](),
    source: code, sourceURL: sourceURL, baseDir: baseDir)
  if baseDir.len > 0:
    rt.moduleStack.add(baseDir)
  withGlobalContext(ctx):
    rt.ctx = ctx
    setCurrentRt(rt)
    let prof = getEnv("CARNE_PROFILE") != ""
    var pt = getMonoTime()
    try:
      var setupEx: JSValueRef = nil
      mark(prof, pt, "ctx")
      installConsole(ctx, addr setupEx)
      installProcess(ctx, argv, addr setupEx)
      installRequire(rt, addr setupEx)
      installTimers(rt, addr setupEx)
      if baseDir.len > 0:
        installEntryModule(ctx, addr setupEx)
      mark(prof, pt, "install")
      if setupEx != nil:
        raise newException(CarneError,
          "failed to initialize runtime: " & valueToString(ctx, setupEx))
      var ex: JSValueRef = nil
      var res = evalScript(ctx, code, sourceURL = sourceURL, exception = ex)
      var sourceHasSyntaxError = false
      if ex != nil and hasAwaitToken(code):
        let jsSource = newJSString(code)
        var syntaxEx: JSValueRef = nil
        sourceHasSyntaxError = not JSCheckScriptSyntax(ctx, jsSource, nil,
          1, addr syntaxEx)
        JSStringRelease(jsSource)
      if sourceHasSyntaxError:
        let originalError = valueToString(ctx, ex)
        ex = nil
        let wrapped = "(async () => {\n" & code & "\n})()"
        res = evalScript(ctx, wrapped, sourceURL = sourceURL, line = 0,
          exception = ex)
        if ex != nil:
          raise newException(CarneError, originalError)
      mark(prof, pt, "eval")
      if ex != nil:
        raise newException(CarneError, valueToString(ctx, ex))
      var completion = ""
      var awaited: JSValueRef = nil
      if res != nil and not JSValueIsUndefined(ctx, res):
        let thenFn = thenFnOf(ctx, res)
        if thenFn != nil:
          # Completion is a Promise/thenable (e.g. an async IIFE or
          # top-level await): capture its settlement after the drain
          # below. The async work it awaits holds pending slots itself.
          rt.promiseSettled = false
          rt.promiseRejected = false
          rt.promiseText = ""
          JSValueProtect(ctx, res)
          awaited = res
          var attachEx: JSValueRef = nil
          var fns: array[2, JSValueRef]
          fns[0] = makeFunction(ctx, "resolve", topResolveImpl)
          fns[1] = makeFunction(ctx, "reject", topRejectImpl)
          discard JSObjectCallAsFunction(ctx, thenFn, res, 2,
            addr fns[0], addr attachEx)
          if attachEx != nil:
            JSValueUnprotect(ctx, res)
            awaited = nil
            completion = valueToString(ctx, res)
        else:
          completion = valueToString(ctx, res)
      if not rt.exitRequested and rt.pending > 0 and rt.loop != nil:
        rt.loop.run()
      mark(prof, pt, "drain")
      if awaited != nil:
        JSValueUnprotect(ctx, awaited)
        if rt.promiseSettled and rt.promiseRejected:
          raise newException(CarneError, rt.promiseText)
        elif rt.promiseSettled:
          completion = rt.promiseText
        else:
          completion = valueToString(ctx, awaited)
      if rt.uncaught.len > 0:
        raise newException(CarneError, rt.uncaught)
      mark(prof, pt, "settle")
      return (completion, rt.exitCode)
    finally:
      setCurrentRt(nil)
      for hook in onTeardown:
        hook()
      loopCreatedLastRun = rt.loop != nil
      if rt.loop != nil:
        rt.loop.close()
      mark(prof, pt, "teardown")

proc runCode*(code: string; sourceURL = "script.js";
    argv: seq[string] = @[]): string =
  ## Evaluates `code`, returns the completion value as a string.
  ## Empty string for undefined results. Raises CarneError on JS exceptions.
  runCodeEx(code, sourceURL, argv).output

proc runFileEx*(path: string;
    extraArgs: seq[string] = @[]): tuple[output: string, code: int] =
  ## Reads `path` and evaluates it. process.argv is
  ## ["carne", path, extraArgs...]. Raises CarneError / IOError.
  let code = readFile(path)
  let argv = @["carne", path] & extraArgs
  runCodeEx(code, sourceURL = path, argv = argv,
    baseDir = path.absolutePath.parentDir())

proc runFile*(path: string; extraArgs: seq[string] = @[]): string =
  ## Reads `path` and evaluates it. Raises CarneError / IOError.
  runFileEx(path, extraArgs).output
