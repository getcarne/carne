# Carne std/watcher: file watching via powpow fswatch.
#
#   const watcher = require("std/watcher");
#   const w = watcher.watch("/tmp/log.txt", (events) => console.log(events));
#   w.close();
#   const events = watcher.watchOnce("/tmp/log.txt", 1000);
#
# watch borrows the run's shared powpow loop and holds it alive until
# close (Node semantics). Events are string arrays from
# powpow FileSystemEvent: modified, created, deleted, renamed, attrib,
# linkCount, revoke. watchOnce blocks, pumping the same loop until the
# first event batch or timeoutMs (default 10000), then returns the
# events array. close() is final and idempotent.

import std/[monotimes, tables, times]

import javascriptcore

from powpow/loop import poll, stop
import powpow/fswatch

import ../bridge
import ../modules

const
  WatchDefaultTimeoutMs = 10_000
  WatchSyncSliceMs = 25

type
  WatchSync = ref object
    done: bool
    events: seq[string]

  WatchEntry = object
    ctx: JSContextRef
    rt: Runtime
    watcher: FileWatcher
    handle: JSObjectRef
    onEvent: JSObjectRef
    sync: WatchSync
    closing: bool
    closed: bool

var watchers {.threadvar.}: Table[pointer, WatchEntry]

proc decPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc unprotectHandlers(ctx: JSContextRef; fns: varargs[JSObjectRef]) =
  for f in fns:
    if f != nil:
      JSValueUnprotect(ctx, f)

proc cleanupWatch(key: pointer) =
  if not watchers.hasKey(key):
    return
  var e = watchers[key]
  let c = e.ctx
  let h = e.handle
  if not e.closed:
    e.closed = true
    watchers[key] = e
    decPending(e.rt)
  watchers.del(key)
  if h != nil:
    JSValueUnprotect(c, h)
  unprotectHandlers(c, e.onEvent)

proc eventNames(events: set[FileSystemEvent]): seq[string] =
  result = @[]
  if fseModified in events: result.add("modified")
  if fseCreated in events: result.add("created")
  if fseDeleted in events: result.add("deleted")
  if fseRenamed in events: result.add("renamed")
  if fseAttrib in events: result.add("attrib")
  if fseLinkCount in events: result.add("linkCount")
  if fseRevoke in events: result.add("revoke")

proc fireCb(c: JSContextRef; rt: Runtime; fn: JSObjectRef;
    args: varargs[JSValueRef]) =
  if fn == nil:
    return
  var ex: JSValueRef = nil
  if args.len == 0:
    discard JSObjectCallAsFunction(c, fn, nil, 0, nil, addr ex)
  else:
    var argv = newSeq[JSValueRef](args.len)
    for i in 0 ..< args.len:
      argv[i] = args[i]
    discard JSObjectCallAsFunction(c, fn, nil, csize_t(args.len),
      addr argv[0], addr ex)
  if ex != nil:
    if rt.uncaught.len == 0:
      rt.uncaught = valueToString(c, ex)
      rt.exitCode = 1

proc watcherDispatched(key: pointer; events: set[FileSystemEvent]) =
  if key == nil or not watchers.hasKey(key):
    return
  var e = watchers[key]
  if e.closing:
    return
  let names = eventNames(events)
  if names.len == 0:
    return
  if e.sync != nil:
    e.sync.done = true
    e.sync.events = names
    watchers[key] = e
    return
  if e.onEvent == nil:
    return
  var vals: seq[JSValueRef] = @[]
  for n in names:
    vals.add(toJS(e.ctx, n))
  let arr = makeJSArray(e.ctx, vals)
  if arr == nil:
    return
  fireCb(e.ctx, e.rt, e.onEvent, arr)

proc findWatchByHandle(handle: JSObjectRef): pointer =
  for k, e in watchers.pairs:
    if e.handle == handle:
      return k
  nil

registerFn(ctx, watcherClose()):
  ## w.close(): final, idempotent; the pending slot is released now.
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "close: called on an invalid watcher", exception)
    return nil
  let key = findWatchByHandle(thisObject)
  if key == nil:
    return toJS(ctx, true)
  var e = watchers[key]
  e.closing = true
  watchers[key] = e
  let w = e.watcher
  cleanupWatch(key)
  try:
    w.close()
  except CatchableError:
    discard
  toJS(ctx, true)

proc makeWatchHandle(ctx: JSContextRef; path: string;
    exception: ptr JSValueRef): JSObjectRef =
  result = newObject(ctx)
  var ex: JSValueRef = nil
  setProp(ctx, result, "close",
    makeFunction(ctx, "close", watcherClose), addr ex)
  if ex != nil:
    throwError(ctx, "watch: could not create watcher handle", exception)
    return nil
  setProp(ctx, result, "path", toJS(ctx, path), addr ex)
  if ex != nil:
    throwError(ctx, "watch: could not create watcher handle", exception)
    return nil

proc closeAllWatcher*() =
  var keys: seq[pointer] = @[]
  for k in watchers.keys:
    keys.add(k)
  for k in keys:
    if not watchers.hasKey(k):
      continue
    let e = watchers[k]
    watchers.del(k)
    if not e.closed:
      decPending(e.rt)
    if e.handle != nil:
      JSValueUnprotect(e.ctx, e.handle)
    unprotectHandlers(e.ctx, e.onEvent)
    if e.watcher != nil:
      try:
        e.watcher.close()
      except CatchableError:
        discard

onTeardown.add(closeAllWatcher)

## Builds the std/watcher namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn watch(path: string, onEvent: JSObjectRef):
      ## watcher.watch(path, onEvent) -> {close(), path}
      if inHttpWorker():
        throwError(ctx,
          "watch: watcher.watch is not supported in http worker threads",
          exception)
        return nil
      if not JSObjectIsFunction(ctx, onEvent):
        throwError(ctx, "watch: onEvent must be a function", exception)
        return nil
      if path.len == 0:
        throwError(ctx, "watch: path must not be empty", exception)
        return nil
      let rt = currentRt()
      var wkey: pointer = nil
      proc cb(w: FileWatcher;
          events: set[FileSystemEvent]) {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          watcherDispatched(wkey, events)
      var w: FileWatcher
      try:
        w = newFileWatcher(rt.ensureLoop(), path, cb)
      except CatchableError as e:
        throwError(ctx, "watch: " & e.msg, exception)
        return nil
      if w == nil:
        throwError(ctx, "watch: could not watch " & path, exception)
        return nil
      wkey = cast[pointer](w)
      let handle = makeWatchHandle(ctx, path, exception)
      if handle == nil:
        try:
          w.close()
        except CatchableError:
          discard
        return nil
      JSValueProtect(ctx, handle)
      JSValueProtect(ctx, onEvent)
      watchers[wkey] = WatchEntry(ctx: ctx, rt: rt, watcher: w,
        handle: handle, onEvent: onEvent, sync: nil,
        closing: false, closed: false)
      inc rt.pending
      handle

    module.registerFn watchOnce(path: string,
        timeoutMs: default(int, WatchDefaultTimeoutMs)):
      ## watcher.watchOnce(path[, timeoutMs]) -> string[] (blocks)
      if inHttpWorker():
        throwError(ctx,
          "watchOnce: watcher.watchOnce is not supported in http worker threads",
          exception)
        return nil
      if path.len == 0:
        throwError(ctx, "watchOnce: path must not be empty", exception)
        return nil
      if timeoutMs <= 0:
        throwError(ctx, "watchOnce: timeoutMs must be positive",
          exception)
        return nil
      let rt = currentRt()
      let st = WatchSync(done: false, events: @[])
      var wkey: pointer = nil
      proc cb(w: FileWatcher;
          events: set[FileSystemEvent]) {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          watcherDispatched(wkey, events)
      var w: FileWatcher
      try:
        w = newFileWatcher(rt.ensureLoop(), path, cb)
      except CatchableError as e:
        throwError(ctx, "watchOnce: " & e.msg, exception)
        return nil
      if w == nil:
        throwError(ctx, "watchOnce: could not watch " & path, exception)
        return nil
      wkey = cast[pointer](w)
      watchers[wkey] = WatchEntry(ctx: ctx, rt: rt, watcher: w,
        handle: nil, onEvent: nil, sync: st,
        closing: false, closed: false)
      inc rt.pending
      let loop = rt.ensureLoop()
      let t0 = getMonoTime()
      while not st.done:
        if rt.exitRequested:
          break
        let elapsed = int(inMilliseconds(getMonoTime() - t0))
        if elapsed >= timeoutMs:
          break
        loop.poll(min(WatchSyncSliceMs, timeoutMs - elapsed))
      let got = st.events
      var e = watchers[wkey]
      e.closing = true
      watchers[wkey] = e
      cleanupWatch(wkey)
      try:
        w.close()
      except CatchableError:
        discard
      if got.len == 0:
        throwError(ctx,
          "watchOnce: timed out after " & $timeoutMs & "ms", exception)
        return nil
      var vals: seq[JSValueRef] = @[]
      for n in got:
        vals.add(toJS(ctx, n))
      makeJSArray(ctx, vals)
