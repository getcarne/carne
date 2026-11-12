# Carne timers: Node-style globals backed by the powpow event loop.
#
#   setTimeout(fn, ms, ...args)   -> numeric id
#   setInterval(fn, ms, ...args)  -> numeric id
#   clearTimeout(id) / clearInterval(id)
#   sleep(ms)                     -> Promise<undefined> (non-blocking)
#
# Callbacks are protected from GC until they fire or are cleared.
# Each live timer holds one pending-work slot; the run drains until
# none remain. Timer throws are recorded as uncaught (exit 1 after
# drain) without killing the remaining timers. sleep resolves on the
# loop like any other timer, so awaiting it never blocks.

import std/tables

import javascriptcore

import powpow/loop

import ../bridge

proc decPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc releaseTimer(rt: Runtime; entry: TimerEntry) =
  JSValueUnprotect(rt.ctx, entry.fn)
  for v in entry.rest:
    JSValueUnprotect(rt.ctx, v)

proc fireTimer(rt: Runtime; jsId: int) =
  ## Runs one timer callback inside JS. Runs on the loop thread,
  ## which is the same thread that owns the JS context.
  if not rt.timers.hasKey(jsId):
    return # cleared before firing
  let entry = rt.timers[jsId]
  var ex: JSValueRef = nil
  let res =
    if entry.rest.len > 0:
      var vals = entry.rest
      JSObjectCallAsFunction(rt.ctx, entry.fn, nil, csize_t(vals.len),
        addr vals[0], addr ex)
    else:
      JSObjectCallAsFunction(rt.ctx, entry.fn, nil, 0, nil, addr ex)
  discard res
  if ex != nil:
    if rt.uncaught.len == 0:
      rt.uncaught = valueToString(rt.ctx, ex)
    rt.exitCode = 1
  if not entry.isInterval:
    rt.timers.del(jsId)
    releaseTimer(rt, entry)
    decPending(rt)

proc scheduleTimerFn(ctx: JSContextRef; fnVal: NimValue; delay: float;
    rest: RestArgs; name: string; isInterval: bool;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  if fnVal.kind != nvkFunction:
    throwTypeMismatch(ctx, name, "fn", jsTypeName(fnVal.kind), "function",
      docBlock, exception)
    return nil
  var delayMs = int(delay)
  if delay != delay or delayMs < 0:
    delayMs = 0
  let rt = currentRt()
  let fn = fnVal.raw
  JSValueProtect(ctx, fn)
  for v in rest:
    JSValueProtect(ctx, v)
  inc rt.timerSeq
  let jsId = rt.timerSeq
  let loop = rt.ensureLoop()
  inc rt.pending
  let timerId =
    if isInterval:
      loop.addInterval(delayMs, proc(id: int) = fireTimer(rt, jsId))
    else:
      loop.addTimer(delayMs, proc(id: int) = fireTimer(rt, jsId))
  rt.timers[jsId] = TimerEntry(id: timerId, fn: fn, rest: rest,
    isInterval: isInterval)
  toJS(ctx, jsId)

registerFn(ctx, setTimeoutCb(fn: NimValue, delay: float, rest: RestArgs)):
  ## setTimeout(fn, ms, ...args) -> numeric id
  scheduleTimerFn(ctx, fn, delay, rest, "setTimeout", false, docBlock,
    exception)

registerFn(ctx, setIntervalCb(fn: NimValue, delay: float, rest: RestArgs)):
  ## setInterval(fn, ms, ...args) -> numeric id
  scheduleTimerFn(ctx, fn, delay, rest, "setInterval", true, docBlock,
    exception)

registerFn(ctx, clearTimerCb(id ?: JSValueRef)):
  ## clearTimeout(id) / clearInterval(id): unknown ids are no-ops.
  if id != nil:
    var ex: JSValueRef = nil
    let idNum = JSValueToNumber(ctx, id, addr ex)
    if ex == nil:
      let rt = currentRt()
      let jsId = int(idNum)
      if rt.timers.hasKey(jsId):
        let entry = rt.timers[jsId]
        rt.ensureLoop().cancelTimer(entry.id)
        rt.timers.del(jsId)
        releaseTimer(rt, entry)
        decPending(rt)
  JSValueMakeUndefined(ctx)

registerFn(ctx, sleepCb(delay: float)):
  ## sleep(ms) -> Promise<undefined> (non-blocking, loop-friendly)
  var delayMs = int(delay)
  if delay != delay or delayMs < 0:
    delayMs = 0
  let rt = currentRt()
  var resolveFn, rejectFn: JSObjectRef
  var mkEx: JSValueRef = nil
  let promise =
    JSObjectMakeDeferredPromise(ctx, addr resolveFn, addr rejectFn, addr mkEx)
  if promise == nil or mkEx != nil:
    throwError(ctx, "sleep: could not create promise", exception)
    return nil
  JSValueProtect(ctx, promise)
  JSValueProtect(ctx, resolveFn)
  JSValueProtect(ctx, rejectFn)
  inc rt.pending
  let c = ctx
  discard rt.ensureLoop().addTimer(delayMs, proc(id: int) =
    var e2: JSValueRef = nil
    var arg = JSValueMakeUndefined(c)
    discard JSObjectCallAsFunction(c, resolveFn, nil, 1, addr arg, addr e2)
    JSValueUnprotect(c, promise)
    JSValueUnprotect(c, resolveFn)
    JSValueUnprotect(c, rejectFn)
    decPending(rt))
  promise

proc installTimers*(rt: Runtime; setupEx: ptr JSValueRef) =
  ## Installs the timer globals.
  let global = JSContextGetGlobalObject(rt.ctx)
  setProp(rt.ctx, global, "setTimeout",
    makeFunction(rt.ctx, "setTimeout", setTimeoutCb), setupEx)
  setProp(rt.ctx, global, "setInterval",
    makeFunction(rt.ctx, "setInterval", setIntervalCb), setupEx)
  setProp(rt.ctx, global, "clearTimeout",
    makeFunction(rt.ctx, "clearTimeout", clearTimerCb), setupEx)
  setProp(rt.ctx, global, "clearInterval",
    makeFunction(rt.ctx, "clearInterval", clearTimerCb), setupEx)
  setProp(rt.ctx, global, "sleep",
    makeFunction(rt.ctx, "sleep", sleepCb), setupEx)
