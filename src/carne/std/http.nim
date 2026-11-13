# Carne std/http: async HTTP client + server via powpow.
#
#   const http = require("std/http");
#   await http.fetch("https://example.com/")
#     -> {status: 200, statusText: "OK", headers: {...}, body: "..."}
#   await http.get(url[, {headers, timeoutMs}])
#   await http.post(url, body[, {headers, timeoutMs}])
#   await http.put(url, body[, opts]) // patch, delete, head, options too
#   const srv = http.serve(3000, req => ({body: "hi " + req.path}));
#   http.close(srv.port)
#
# fetch/get/post return Promises multiplexed on the run's shared powpow
# loop together with timers and serve sockets: truly async, no threads.
# serve borrows the loop and holds it alive until close (Node semantics).
# Handler return: string -> 200 text/plain; {status?, headers?, body?};
# body is a string, a Uint8Array (binary, Content-Type defaults to
# application/octet-stream), or anything else (JSON-serialized);
# undefined/null -> 200 empty; anything else -> JSON body. Header
# values are strings, or arrays of strings for repeated headers
# (e.g. multiple Set-Cookie); anything else in headers answers 500.
# A JS throw in a handler answers 500 and is recorded as uncaught.
# The object form defaults Content-Type to text/plain for string bodies and
# application/json for serialized ones unless headers sets one. Bodies
# are UTF-8 strings in v1; https uses a default client context with
# system CAs. Header names are lowercased in req.headers and
# res.headers (read them lowercase); handler-set response headers keep
# their case on the wire.
# HEAD requests and 101/204/205/304 statuses answer with an empty body
# (fetch null-body-status semantics). The request object carries
# {method, path, query, url, headers, body, clientIp} plus a lazy
# `multipart` field: powpow auto-streams multipart/form-data uploads to
# tmpfiles from the first body byte (per-file/per-field/total caps from
# the serve `maxBodySize` opt enforced at the protocol level, 413/400
# before dispatch), and `multipart` exposes them as
# {fields: {name: value|[values]}, files: [{field, filename,
# contentType, size, path}]}. File parts need a filename and a
# Content-Type header (what curl and browsers send; a filename-only
# part reads as a text field). File paths are tmpfiles deleted right
# after the handler returns: read or copy them during handling
# (os.readFileBytes gives binary-safe Uint8Arrays). Non-multipart
# requests and truncated uploads read {fields: {}, files: []}.
# serve takes tuning opts: serve(port[, host][, opts], handler) with
# opts = {keepAliveMs?, readTimeoutMs?, maxBodySize?, workers?}.
# workers (1..64, default 1) scales serving across worker threads: each
# extra worker is a full runtime (own JS context in its own group, own
# loop, own server) re-running the script source, so no JS value ever
# crosses a thread (Node cluster model). Linux balances a SO_REUSEPORT
# group (each worker listens); macOS adopts one shared listen socket
# (it does not balance REUSEPORT groups). JS heaps stay isolated: no
# shared state, module-level side effects run per worker. Driver code
# gates on process.isWorker (false on main, true on workers).
# close(port) stops every worker; process exit joins them. ws.serve
# refuses inside workers (its listen would collide).
# The request
# object is lazy: fields convert on first access, so handlers that
# ignore it pay ~nothing. Fields read during the handler stay valid;
# fields first read after the handler returns answer "" ({} for
# headers). Assignments to req fields stick.
#
# Note: scripts need an async IIFE for await (top-level await is out of
# scope in v1): `(async () => { ... })()`. The runtime unwraps a
# top-level completion promise, so tests assert on it directly.

import std/[json, strutils, tables]
import std/httpcore except HttpMethod

import javascriptcore

import powpow/types
import powpow/proto/http
import powpow/proto/httpclient
import powpow/proto/httpserver
from pkg/multipart import MultipartFile, MultipartStreamer, isComplete,
  boundaries, cleanup
from powpow/loop import stop, register
from powpow/net/tls import SslContext, newClientTlsContext
from powpow/net/common import setNonBlocking
when not defined(windows):
  import std/posix

import ../bridge
import ../modules
when not defined(windows):
  import ./httpworkers

type
  FetchOpts = object
    meth: HttpMethod
    headers: seq[(string, string)]
    body: string
    timeoutMs: int

  ServerEntry = object
    ctx: JSContextRef
    rt: Runtime
    server: HttpServer
    handlerFn: JSObjectRef
    port: int
    host: string

var httpServers {.threadvar.}: Table[pointer, ServerEntry]
var httpClients {.threadvar.}: Table[pointer, HttpClientBase]
  ## Per-worker tables: every worker thread runs its own runtime, loop
  ## and server, so no request/connection state is ever shared.

proc decPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc methodFromString(s: string; name: string): HttpMethod =
  case s.toUpperAscii()
  of "GET": HttpGet
  of "POST": HttpPost
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  of "HEAD": HttpHead
  of "OPTIONS": HttpOptions
  of "PATCH": HttpPatch
  else:
    raise newException(CatchableError, name & ": unknown method \"" & s & "\"")

proc methodToString(m: HttpMethod): string =
  case m
  of HttpGet: "GET"
  of HttpPost: "POST"
  of HttpPut: "PUT"
  of HttpDelete: "DELETE"
  of HttpHead: "HEAD"
  of HttpOptions: "OPTIONS"
  of HttpPatch: "PATCH"
  else: ($m)[4 .. ^1].toUpperAscii()

proc parseOpts(ctx: JSContextRef; obj: JSValueRef; name: string;
    allowMethod, allowBody: bool): FetchOpts =
  ## Reads {method?, headers?, body?, timeoutMs?} lazily; absent and
  ## undefined fields both mean default. Raises on anything else
  ## (callers turn it into a sync JS throw). nil obj means absent.
  result = FetchOpts(meth: HttpGet, headers: @[], body: "", timeoutMs: -1)
  if obj == nil:
    return
  var err = ""
  template field(key: string): NimValue =
    let f = getField(ctx, obj, key, err)
    if err != "":
      raise newException(CatchableError, name & ": options." & key & " " & err)
    f
  let m = field("method")
  if m.kind != nvkUndefined:
    if not allowMethod:
      raise newException(CatchableError,
        name & ": method is fixed here, use fetch for full control")
    if m.kind != nvkString:
      raise newException(CatchableError,
        name & ": options.method must be a string")
    result.meth = methodFromString(m.s, name)
  let b = field("body")
  if b.kind != nvkUndefined:
    if not allowBody:
      raise newException(CatchableError,
        name & ": body is fixed here, use fetch for full control")
    if b.kind != nvkString:
      raise newException(CatchableError,
        name & ": options.body must be a string")
    result.body = b.s
  let h = field("headers")
  if h.kind != nvkUndefined:
    if h.kind != nvkObject:
      raise newException(CatchableError,
        name & ": options.headers must be an object")
    for k, hv in h.obj.pairs:
      if hv.kind != nvkString:
        raise newException(CatchableError,
          name & ": header \"" & k & "\" must be a string")
      result.headers.add((k, hv.s))
  let t = field("timeoutMs")
  if t.kind != nvkUndefined:
    case t.kind
    of nvkInt: result.timeoutMs = int(t.i)
    of nvkFloat: result.timeoutMs = int(t.f)
    else:
      raise newException(CatchableError,
        name & ": options.timeoutMs must be a number")

proc clientFor(rt: Runtime; needTls: bool): HttpClientBase =
  ## One shared client (pool + TLS context) per run. Freed by
  ## closeAllServers in the runtime teardown. The TLS context is only
  ## created for https URLs: plain-http runs never pay OpenSSL init.
  let key = cast[pointer](rt)
  if httpClients.hasKey(key):
    result = httpClients[key]
    if needTls and result.tlsCtx == nil:
      try:
        result.tlsCtx = newClientTlsContext()
      except CatchableError:
        discard
    return result
  var tlsCtx: SslContext = nil
  if needTls:
    try:
      tlsCtx = newClientTlsContext()
    except CatchableError:
      tlsCtx = nil
  result = HttpClientBase(tlsCtx: tlsCtx, keepAlive: true, timeoutMs: 0,
    maxBodySize: DefaultMaxResponseBody, defaultHeaders: @[],
    pool: newHttpConnPool())
  httpClients[key] = result

proc responseToJson(res: HttpClientResponse): JsonNode =
  # Everything is copied out here: with keepAlive the parser is reused
  # by the next request on a pooled connection.
  result = newJObject()
  result["status"] = %int(res.getStatusCode())
  let st: string = res.getStatusText()
  result["statusText"] = %st
  var hdrs = newJObject()
  for k, v in res.getHeaders().pairs:
    hdrs[k] = %v
  result["headers"] = hdrs
  # Bodies arrive as raw wire bytes; decode lossy (U+FFFD) so any
  # payload converts to JS instead of rejecting the fetch. NUL
  # survives; for exact binary, serve with Content-Length and read
  # length + codes, or fetch outside the runtime.
  result["body"] = %sanitizeUTF8(res.getBodyString())

# Lazy request objects: the handler gets a JSClass instance whose fields
# convert on first access instead of an eagerly snapshotted object, so a
# handler that ignores the request pays ~nothing for it. First access
# during the handler snapshots the value (later reads stay valid
# forever); fields never accessed read as "" ({} for headers) once the
# handler has returned and the pooled powpow request is recycled.
# Assignments stick via a JsonNode override snapshot. Enumeration
# (Object.keys, spread, JSON.stringify) sees the same eight fields.

type
  ReqField = enum
    rfMethod, rfPath, rfQuery, rfUrl, rfHeaders, rfBody, rfClientIp,
    rfMultipart

const reqFieldNames: array[ReqField, string] = ["method", "path", "query",
  "url", "headers", "body", "clientIp", "multipart"]

type
  ReqState = ref object
    req: HttpRequest
    res: HttpResponse
    alive: bool
    ctx: JSContextRef
    strs: array[ReqField, string]
    headers: seq[(string, string)]
    multi: JsonNode
    have: set[ReqField]
    over: array[ReqField, JsonNode]
    haveOver: set[ReqField]

var reqClass {.threadvar.}: JSClassRef
var reqStates {.threadvar.}: Table[pointer, ReqState]
  ## Roots ReqState while its JS object lives (removed in finalize).
  ## Same-thread assumption as the rest of the runtime: all JS and
  ## loop work happens on the run's single thread.
var lastSrvKey {.threadvar.}: pointer
var lastSrv {.threadvar.}: ServerEntry
var lastSrvValid {.threadvar.}: bool
  ## One-entry fast path: benchmarks serve on a single server.

proc snap(s: string): string =
  ## Unconditional byte copy: powpow yields borrowed (`lent`) strings over
  ## pooled parser buffers, so aliasing them past the request is unsafe.
  result = newString(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc fieldOf(name: JSStringRef): int =
  for i in ReqField:
    if JSStringIsEqualToUTF8CString(name, cstring(reqFieldNames[i])):
      return ord(i)
  -1

proc stateOf(obj: JSObjectRef): ReqState =
  let p = JSObjectGetPrivate(obj)
  if p == nil:
    return nil
  cast[ReqState](p)

proc buildHeadersObj(ctx: JSContextRef; pairs: seq[(string, string)]): JSValueRef =
  result = newObject(ctx)
  if result == nil:
    return nil
  var ex: JSValueRef = nil
  for (k, v) in pairs:
    setProp(ctx, result, k, toJS(ctx, v), addr ex)
    if ex != nil:
      return nil

proc multipartSnapshot(req: HttpRequest): JsonNode =
  ## powpow-backed multipart parse for the lazy `multipart` req field:
  ## text fields inline (repeated names become arrays), files as tmp
  ## paths (auto-streamed from the first body byte, so nothing is
  ## copied twice and binary stays binary). Empty shape when the
  ## content type is not multipart or the upload did not complete;
  ## config garbage answers the same (never a throw into the handler).
  result = newJObject()
  result["fields"] = newJObject()
  result["files"] = newJArray()
  let mp =
    try: req.getMultipart()
    except CatchableError: nil
  if mp == nil or not mp.isComplete():
    return
  for b in mp.boundaries():
    if b.fieldName.len == 0:
      continue
    if b.dataType == MultipartFile:
      var f = newJObject()
      f["field"] = %b.fieldName
      f["filename"] = %b.fileName
      f["contentType"] = %b.fileType
      f["size"] = newJInt(b.fileSize)
      f["path"] = %b.filePath
      result["files"].add(f)
    else:
      let v = %b.value
      if result["fields"].hasKey(b.fieldName):
        let cur = result["fields"][b.fieldName]
        if cur.kind == JArray:
          cur.add(v)
        else:
          var arr = newJArray()
          arr.add(cur)
          arr.add(v)
          result["fields"][b.fieldName] = arr
      else:
        result["fields"][b.fieldName] = v

proc reqConvert(st: ReqState; f: ReqField): JSValueRef =
  ## Fresh JS value for field f, snapshotting live data on first access.
  ## nil when the value is unavailable (caller yields undefined).
  if f in st.haveOver:
    return jsonToJS(st.ctx, st.over[f])
  case f
  of rfMethod, rfPath, rfQuery, rfUrl, rfBody, rfClientIp:
    if f in st.have:
      return toJS(st.ctx, st.strs[f])
    if not st.alive:
      return toJS(st.ctx, "")
    case f
    of rfMethod: st.strs[f] = methodToString(st.req.getMethod())
    of rfPath: st.strs[f] = snap(st.req.getPath())
    of rfQuery: st.strs[f] = snap(st.req.getQuery())
    of rfUrl: st.strs[f] = snap(st.req.getUrl())
    of rfBody: st.strs[f] = snap(st.req.getBodyString())
    of rfClientIp:
      try:
        st.strs[f] = snap(st.res.getClientIp())
      except CatchableError:
        st.strs[f] = ""
    else: discard
    st.have.incl(f)
    return toJS(st.ctx, st.strs[f])
  of rfHeaders:
    if f in st.have:
      return buildHeadersObj(st.ctx, st.headers)
    if not st.alive:
      return newObject(st.ctx)
    st.headers.setLen(0)
    for k, v in st.req.getHeaders().pairs:
      st.headers.add((snap(k), snap(v)))
    st.have.incl(f)
    return buildHeadersObj(st.ctx, st.headers)
  of rfMultipart:
    if f in st.have:
      return jsonToJS(st.ctx, st.multi)
    if not st.alive:
      st.multi = newJObject()
      st.multi["fields"] = newJObject()
      st.multi["files"] = newJArray()
    else:
      st.multi = multipartSnapshot(st.req)
    st.have.incl(f)
    return jsonToJS(st.ctx, st.multi)

proc reqHasProperty(ctx: JSContextRef; obj: JSObjectRef;
    name: JSStringRef): bool {.cdecl.} =
  fieldOf(name) >= 0

proc reqGetProperty(ctx: JSContextRef; obj: JSObjectRef; name: JSStringRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  let idx = fieldOf(name)
  if idx < 0:
    return nil
  let st = stateOf(obj)
  if st == nil:
    return nil
  reqConvert(st, ReqField(idx))

proc reqSetProperty(ctx: JSContextRef; obj: JSObjectRef; name: JSStringRef;
    value: JSValueRef; exception: ptr JSValueRef): bool {.cdecl.} =
  let idx = fieldOf(name)
  if idx < 0:
    return false
  let st = stateOf(obj)
  if st == nil:
    return false
  var jerr = ""
  let node = jsToJson(ctx, value, jerr)
  if node == nil:
    return false
  st.over[ReqField(idx)] = node
  st.haveOver.incl(ReqField(idx))
  true

proc reqGetPropertyNames(ctx: JSContextRef; obj: JSObjectRef;
    acc: JSPropertyNameAccumulatorRef) {.cdecl.} =
  for n in reqFieldNames:
    let js = newJSString(n)
    JSPropertyNameAccumulatorAddName(acc, js)
    JSStringRelease(js)

proc reqFinalize(obj: JSObjectRef) {.cdecl.} =
  reqStates.del(cast[pointer](obj))

proc ensureReqClass() =
  if reqClass != nil:
    return
  var def = kJSClassDefinitionEmpty
  def.className = "CarneHttpReq"
  def.hasProperty = reqHasProperty
  def.getProperty = reqGetProperty
  def.setProperty = reqSetProperty
  def.getPropertyNames = reqGetPropertyNames
  def.finalize = reqFinalize
  reqClass = JSClassCreate(addr def)

proc makeLazyReq(ctx: JSContextRef; req: HttpRequest;
    res: HttpResponse): JSValueRef =
  ## One class instance borrowing req/res; fields snapshot on first
  ## access. nil on allocation failure.
  ensureReqClass()
  if reqClass == nil:
    return nil
  let st = ReqState(req: req, res: res, alive: true, ctx: ctx)
  result = JSObjectMake(ctx, reqClass, nil)
  if result == nil:
    return nil
  if not JSObjectSetPrivate(result, cast[pointer](st)):
    return nil
  reqStates[cast[pointer](result)] = st

proc startFetch(ctx: JSContextRef; rt: Runtime; url: string; opts: FetchOpts;
    name: string; exception: ptr JSValueRef): JSValueRef =
  ## Issues one async request on the run's loop and returns its Promise.
  ## Sync setup failures throw; network failures reject. Top-level helper
  ## (not a member body): the settle closures below capture only locals,
  ## never callback bindings.
  var resolveFn, rejectFn: JSObjectRef
  var mkEx: JSValueRef = nil
  let promise =
    JSObjectMakeDeferredPromise(ctx, addr resolveFn, addr rejectFn, addr mkEx)
  if promise == nil or mkEx != nil:
    throwError(ctx, name & ": could not create promise", exception)
    return nil
  JSValueProtect(ctx, promise)
  JSValueProtect(ctx, resolveFn)
  JSValueProtect(ctx, rejectFn)
  inc rt.pending
  let c = ctx
  var done = false
  proc finish() =
    JSValueUnprotect(c, promise)
    JSValueUnprotect(c, resolveFn)
    JSValueUnprotect(c, rejectFn)
    decPending(rt)
  proc rejectWith(msg: string) =
    try:
      let msgV = toJS(c, name & ": " & msg)
      var e2: JSValueRef = nil
      let errObj = JSObjectMakeError(c, 1, unsafeAddr msgV, addr e2)
      var arg = if errObj != nil: errObj else: msgV
      discard JSObjectCallAsFunction(c, rejectFn, nil, 1, addr arg, addr e2)
    except CatchableError:
      discard
    finish()
  proc settleOk(res: HttpClientResponse) {.closure.} =
    if done:
      return
    done = true
    try:
      let v = jsonToJS(c, responseToJson(res))
      if v == nil:
        rejectWith("could not convert response to JS")
        return
      var e2: JSValueRef = nil
      var vv = v
      discard JSObjectCallAsFunction(c, resolveFn, nil, 1, addr vv, addr e2)
    except CatchableError as e:
      rejectWith(e.msg)
      return
    finish()
  proc settleErr(msg: string) {.closure.} =
    if done:
      return
    done = true
    rejectWith(msg)
  let cMeth = opts.meth
  let cHeaders = opts.headers
  let cTimeout = opts.timeoutMs
  let cBody = opts.body
  try:
    let needTls = url.strip().toLowerAscii().startsWith("https:")
    let client = clientFor(rt, needTls)
    let loop = rt.ensureLoop()
    if cBody.len > 0:
      discard requestImpl(client, loop, cMeth, url,
        cBody.toOpenArrayByte(0, cBody.high), cHeaders, "", cTimeout,
        onResponse = settleOk, onBodyData = nil, onError = settleErr)
    else:
      discard requestImpl(client, loop, cMeth, url,
        [], cHeaders, "", cTimeout,
        onResponse = settleOk, onBodyData = nil, onError = settleErr)
  except CatchableError as e:
    finish()
    throwError(ctx, name & ": " & e.msg, exception)
    return nil
  promise

proc liveProp(ctx: JSContextRef; obj: JSValueRef; key: string): JSValueRef =
  ## One live property read; nil when the getter throws. Used where a
  ## snapshot is wrong: typed-array bodies must never be walked.
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  result = JSObjectGetProperty(ctx, cast[JSObjectRef](obj), k, addr ex)
  if ex != nil:
    result = nil

proc isByteView(ctx: JSContextRef; v: JSValueRef): bool =
  ## True for Uint8Array/Uint8ClampedArray views and ArrayBuffers.
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject:
    return false
  var tex: JSValueRef = nil
  let t = JSValueGetTypedArrayType(ctx, v, addr tex)
  tex == nil and t in {kJSTypedArrayTypeUint8Array,
    kJSTypedArrayTypeUint8ClampedArray, kJSTypedArrayTypeArrayBuffer}

proc serveBinary(ctx: JSContextRef; res: HttpResponse; ret, bodyProp: JSValueRef;
    headOnly: bool) =
  ## Serves a {status?, headers?, body: Uint8Array} handler return.
  ## Unreadable parts answer 500; HEAD and null-body statuses send no
  ## bytes (fetch semantics, like the text path). Unset Content-Type
  ## defaults to application/octet-stream for non-empty bodies.
  var code = Http200
  var err = ""
  let s = getField(ctx, ret, "status", err)
  if err != "":
    res.sendError(Http500, "handler status is unreadable")
    return
  case s.kind
  of nvkUndefined: discard
  of nvkInt:
    if s.i < 100 or s.i > 599:
      res.sendError(Http500, "handler status must be 100..599")
      return
    code = HttpCode(int(s.i))
  else:
    res.sendError(Http500, "handler status must be 100..599")
    return
  var hdrs: seq[(string, string)] = @[]
  let h = getField(ctx, ret, "headers", err)
  if err != "":
    res.sendError(Http500, "handler headers are unreadable")
    return
  case h.kind
  of nvkUndefined: discard
  of nvkObject:
    for k, v in h.obj.pairs:
      case v.kind
      of nvkString:
        hdrs.add((k, v.s))
      of nvkArray:
        for item in v.arr:
          if item.kind != nvkString:
            res.sendError(Http500, "handler header values must be strings")
            return
          hdrs.add((k, item.s))
      else:
        res.sendError(Http500, "handler header values must be strings")
        return
  else:
    res.sendError(Http500, "handler headers must be an object")
    return
  var raw = ""
  var exc: JSValueRef = nil
  if not readBytesParam(ctx, bodyProp, "serve", "body", "", addr exc, raw):
    res.sendError(Http500, "handler body is unreadable")
    return
  if headOnly or code in {Http101, Http204, Http205, Http304}:
    raw = ""
  var hasContentType = false
  for (k, v) in hdrs:
    if k.toLowerAscii() == "content-type":
      hasContentType = true
      break
  if not hasContentType and raw.len > 0:
    hdrs.add(("Content-Type", "application/octet-stream"))
  res.status(code)
  for (k, v) in hdrs:
    res.header(k, v)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  res.send(bytes)

proc httpOnRequest(req: HttpRequest; res: HttpResponse) {.gcsafe.} =
  ## powpow dispatch: runs on the loop thread, which is the JS thread
  ## (borrowed loop), so JS calls are sound; the cast covers the global
  ## table, which no other thread touches.
  {.cast(gcsafe).}:
    let srvKey = cast[pointer](res.server)
    var e: ServerEntry
    if lastSrvValid and srvKey == lastSrvKey:
      e = lastSrv
    else:
      if not httpServers.hasKey(srvKey):
        res.sendError(Http500, "server closed")
        return
      e = httpServers[srvKey]
      lastSrvKey = srvKey
      lastSrv = e
      lastSrvValid = true
    let c = e.ctx
    let headOnly = req.getMethod() == HttpHead
    let reqVal = makeLazyReq(c, req, res)
    if reqVal == nil:
      res.sendError(Http500, "out of memory")
      return
    let st = stateOf(reqVal)
    var ex: JSValueRef = nil
    var argv: array[1, JSValueRef]
    argv[0] = reqVal
    let ret = JSObjectCallAsFunction(c, e.handlerFn, nil, 1, addr argv[0],
      addr ex)
    # The handler ran: the pooled req/res recycle from here, so fields
    # never read above now answer as defaults (documented). Multipart
    # uploads streamed to tmpfiles during parsing; drop them now that
    # the handler is done (handed-out paths stay valid only while it
    # runs). Untouched uploads leave files too; non-multipart requests
    # carry no streamer, so this is a no-op for them.
    if st != nil:
      st.alive = false
      try:
        if st.req.streamer != nil:
          st.req.streamer[].cleanup()
      except CatchableError:
        discard
    if ex != nil or ret == nil:
      if e.rt.uncaught.len == 0:
        e.rt.uncaught =
          if ex != nil: valueToString(c, ex) else: "handler failed"
        e.rt.exitCode = 1
      res.sendError(Http500, "handler threw")
      return
    if JSValueIsUndefined(c, ret) or JSValueIsNull(c, ret):
      res.status(Http200).send("")
      return
    if JSValueIsString(c, ret):
      res.status(Http200)
        .header("Content-Type", "text/plain; charset=utf-8")
        .send(if headOnly: "" else: valueToString(c, ret))
      return
    # Binary fast path: {status?, headers?, body: Uint8Array}. jsToJson
    # would walk a typed array per byte (tripping the snapshot cap on
    # large files), so probe the live body ref first; anything else
    # falls through to the snapshot path with identical behavior.
    if JSValueGetType(c, ret) == kJSTypeObject and
        not JSValueIsArray(c, ret) and not JSObjectIsFunction(c, ret):
      let bodyProp = liveProp(c, ret, "body")
      if isByteView(c, bodyProp):
        serveBinary(c, res, ret, bodyProp, headOnly)
        return
    var jerr = ""
    let node = jsToJson(c, ret, jerr)
    if node == nil:
      res.sendError(Http500, "handler returned non-serializable value")
      return
    if node.kind != JObject:
      res.status(Http200).header("Content-Type", "application/json")
        .send(if headOnly: "" else: $node)
      return
    var code = Http200
    if node.hasKey("status"):
      let s = node["status"]
      if s.kind != JInt or s.getInt() < 100 or s.getInt() > 599:
        res.sendError(Http500, "handler status must be 100..599")
        return
      code = HttpCode(int(s.getInt()))
    var hdrs: seq[(string, string)] = @[]
    if node.hasKey("headers"):
      let h = node["headers"]
      if h.kind != JObject:
        res.sendError(Http500, "handler headers must be an object")
        return
      for k, v in h.pairs:
        case v.kind
        of JString:
          hdrs.add((k, v.getStr()))
        of JArray:
          for item in v.items:
            if item.kind != JString:
              res.sendError(Http500, "handler header values must be strings")
              return
            hdrs.add((k, item.getStr()))
        else:
          res.sendError(Http500, "handler header values must be strings")
          return
    var body = ""
    var bodyIsJson = false
    if node.hasKey("body"):
      let b = node["body"]
      if b.kind == JString:
        body = b.getStr()
      elif b.kind == JNull:
        body = ""
      else:
        body = $b
        bodyIsJson = true
    # Null-body statuses (fetch semantics) and HEAD never carry a body.
    if headOnly or code in {Http101, Http204, Http205, Http304}:
      body = ""
      bodyIsJson = false
    # The object form defaults Content-Type like the other return paths
    # (string -> text/plain, JSON -> application/json) unless the
    # handler set one explicitly (matched case-insensitively).
    var hasContentType = false
    for (k, v) in hdrs:
      if k.toLowerAscii() == "content-type":
        hasContentType = true
        break
    if not hasContentType and body.len > 0:
      hdrs.add(("Content-Type",
        if bodyIsJson: "application/json" else: "text/plain; charset=utf-8"))
    res.status(code)
    for (k, v) in hdrs:
      res.header(k, v)
    res.send(body)

proc serveOptNum(ctx: JSContextRef; obj: JSValueRef; name, key: string;
    allowZero: bool): int =
  ## One numeric serve opt, -1 when absent/undefined. Raises on anything
  ## malformed (callers turn it into a sync JS throw).
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(CatchableError, name & ": opts." & key & " " & err)
  if f.kind == nvkUndefined:
    return -1
  var v = -1
  case f.kind
  of nvkInt: v = int(f.i)
  of nvkFloat: v = int(f.f)
  else:
    raise newException(CatchableError,
      name & ": opts." & key & " must be a number")
  if v < 0 or (v == 0 and not allowZero):
    raise newException(CatchableError, name & ": opts." & key &
      (if allowZero: " must be >= 0" else: " must be positive"))
  v

proc parseServeOpts(ctx: JSContextRef; obj: JSValueRef; name: string):
    HttpServerOptions =
  ## Reads {keepAliveMs?, readTimeoutMs?, maxBodySize?} from the serve
  ## opts object, starting from powpow's defaults. Raises on anything
  ## malformed (callers turn it into a sync JS throw).
  result = defaultHttpServerOptions()
  let ka = serveOptNum(ctx, obj, name, "keepAliveMs", true)
  if ka >= 0:
    result.keepAliveMs = ka
  let rt = serveOptNum(ctx, obj, name, "readTimeoutMs", true)
  if rt >= 0:
    result.readTimeoutMs = rt
  let mb = serveOptNum(ctx, obj, name, "maxBodySize", false)
  if mb >= 0:
    result.maxBodySize = mb

proc closeServerEntry(srv: HttpServer; e: ServerEntry) =
  srv.close()
  JSValueUnprotect(e.ctx, e.handlerFn)
  httpServers.del(cast[pointer](srv))
  lastSrvValid = false
  decPending(e.rt)

proc serveOptWorkers(ctx: JSContextRef; obj: JSValueRef;
    name: string): int =
  ## Reads opts.workers (1..64, default 1). Raises on anything
  ## malformed (callers turn it into a sync JS throw). Spawning itself
  ## is POSIX-only (see serve); Windows callers reject workers != 1.
  result = 1
  var err = ""
  let f = getField(ctx, obj, "workers", err)
  if err != "":
    raise newException(CatchableError, name & ": opts.workers " & err)
  if f.kind == nvkUndefined:
    return 1
  var v = -1
  case f.kind
  of nvkInt: v = int(f.i)
  of nvkFloat: v = int(f.f)
  else:
    raise newException(CatchableError,
      name & ": opts.workers must be a number")
  if v < 1 or v > 64:
    raise newException(CatchableError,
      name & ": opts.workers must be 1..64")
  result = v

when not defined(windows):

  proc workerPipeCb(fd: int, events: set[EventType])
  proc registerWorkerPipe(port: int)
  proc broadcastWorkerPort(port, msg: int)

proc closeAllServers*() =
  ## Closes every live server and frees per-run client pools. Called
  ## from the runtime teardown; safe with none live. On the main
  ## thread with workers live, workers stop and join first so the
  ## shared listen socket outlives their adopted references.
  when not defined(windows):
    stopAllWorkers()
  var keys: seq[pointer] = @[]
  for k in httpServers.keys:
    keys.add(k)
  for k in keys:
    let e = httpServers[k]
    try:
      closeServerEntry(e.server, e)
    except CatchableError:
      discard
  var rts: seq[pointer] = @[]
  for k in httpClients.keys:
    rts.add(k)
  for k in rts:
    try:
      httpClients[k].pool.closeAll()
    except CatchableError:
      discard
    httpClients.del(k)

# Teardown hook: runs at runtime teardown when this module is linked in
# (binary, or tests that register std/http). Safe with none live.
onTeardown.add(closeAllServers)

when not defined(windows):
  proc workerPipeCb(fd: int, events: set[EventType]) =
    ## Control-pipe dispatcher, runs on the owning worker's loop thread.
    ## 4-byte port messages (0 = stop everything).
    var msg: array[4, byte]
    while true:
      let n = posix.read(fd.cint, addr msg[0], 4)
      if n != 4:
        break
      let port = int(msg[0]) or (int(msg[1]) shl 8) or
        (int(msg[2]) shl 16) or (int(msg[3]) shl 24)
      if port == 0:
        closeAllServers()
        let rt = currentRt()
        if rt != nil:
          rt.exitRequested = true
          rt.pending = 0
          if rt.loop != nil:
            rt.loop.stop()
      else:
        for k, e in httpServers.pairs:
          if e.port == port:
            try:
              closeServerEntry(e.server, e)
            except CatchableError:
              discard
            break

  proc registerWorkerPipe(port: int) =
    ## Arms this worker's control pipe in its own loop and records the
    ## write end. A worker that registers after a close/stop broadcast
    ## shuts its server at once (recordPipe reports it).
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      raise newException(OSError, "serve: pipe() failed")
    setNonBlocking(SocketHandle(fds[0]))
    let rt = currentRt()
    rt.ensureLoop().register(fds[0].int, {Read}, workerPipeCb)
    if recordPipe(port, fds[1]):
      for k, e in httpServers.pairs:
        if e.port == port:
          try:
            closeServerEntry(e.server, e)
          except CatchableError:
            discard
          break

  proc broadcastWorkerPort(port, msg: int) =
    var b: array[4, byte]
    b[0] = byte(msg and 0xFF)
    b[1] = byte((msg shr 8) and 0xFF)
    b[2] = byte((msg shr 16) and 0xFF)
    b[3] = byte((msg shr 24) and 0xFF)
    for w in markClosed(port):
      discard posix.write(w, addr b[0], 4)

## Builds the std/http namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn fetch(url: string, optsObj ?: JSObjectRef):
      ## http.fetch(url[, {method, headers, body, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "fetch", true, true)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      startFetch(ctx, currentRt(), url, opts, "fetch", exception)

    module.registerFn get(url: string, optsObj ?: JSObjectRef):
      ## http.get(url[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "get", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      startFetch(ctx, currentRt(), url, opts, "get", exception)

    module.registerFn post(url: string, body: string,
        optsObj ?: JSObjectRef):
      ## http.post(url, body[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "post", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpPost
      opts.body = body
      startFetch(ctx, currentRt(), url, opts, "post", exception)

    module.registerFn put(url: string, body: string,
        optsObj ?: JSObjectRef):
      ## http.put(url, body[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "put", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpPut
      opts.body = body
      startFetch(ctx, currentRt(), url, opts, "put", exception)

    module.registerFn patch(url: string, body: string,
        optsObj ?: JSObjectRef):
      ## http.patch(url, body[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "patch", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpPatch
      opts.body = body
      startFetch(ctx, currentRt(), url, opts, "patch", exception)

    module.registerFn delete(url: string, optsObj ?: JSObjectRef):
      ## http.delete(url[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "delete", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpDelete
      startFetch(ctx, currentRt(), url, opts, "delete", exception)

    module.registerFn head(url: string, optsObj ?: JSObjectRef):
      ## http.head(url[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}> (body is always "")
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "head", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpHead
      startFetch(ctx, currentRt(), url, opts, "head", exception)

    module.registerFn options(url: string, optsObj ?: JSObjectRef):
      ## http.options(url[, {headers, timeoutMs}]) -> Promise<{status, statusText, headers, body}>
      var opts: FetchOpts
      try:
        opts = parseOpts(ctx, optsObj, "options", false, false)
      except CatchableError as e:
        throwError(ctx, e.msg, exception)
        return nil
      opts.meth = HttpOptions
      startFetch(ctx, currentRt(), url, opts, "options", exception)

    module.registerFn serve(port: int64, second: JSValueRef,
        third ?: JSValueRef, handler ?: JSObjectRef):
      ## http.serve(port[, host][, opts], handler) -> {port, host}
      ## opts.workers (1..64, default 1) scales across worker threads,
      ## each a full runtime re-running the script (see the module
      ## header). Workers share the port: Linux balances a REUSEPORT
      ## group, macOS adopts one shared listen socket.
      if port < 1 or port > 65535:
        throwError(ctx, "serve: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      let n = int(argumentCount)
      var host = "127.0.0.1"
      var haveOpts = false
      var workers = 1
      var sopts = defaultHttpServerOptions()
      var handlerV: JSValueRef = nil
      if n == 2:
        var ferr2 = ""
        let hv2 = fromJS(ctx, second, ferr2)
        if ferr2 != "" or hv2.kind != nvkFunction:
          throwTypeMismatch(ctx, "serve", "handler",
            (if ferr2 != "": "unreadable" else: jsTypeName(hv2.kind)),
            "function", docBlock, exception)
          return nil
        handlerV = second
      elif n == 3:
        var serr = ""
        let sk = fromJS(ctx, second, serr)
        if serr == "" and sk.kind == nvkString:
          host = sk.s
        elif serr == "" and sk.kind == nvkObject:
          try:
            sopts = parseServeOpts(ctx, second, "serve")
            workers = serveOptWorkers(ctx, second, "serve")
          except CatchableError as e:
            throwError(ctx, e.msg, exception)
            return nil
          haveOpts = true
        else:
          throwTypeMismatch(ctx, "serve", "hostOrOpts",
            (if serr != "": "unreadable" else: jsTypeName(sk.kind)),
            "string|object", docBlock, exception)
          return nil
        var ferr3 = ""
        let hv3 = fromJS(ctx, third, ferr3)
        if ferr3 != "" or hv3.kind != nvkFunction:
          throwTypeMismatch(ctx, "serve", "handler",
            (if ferr3 != "": "unreadable" else: jsTypeName(hv3.kind)),
            "function", docBlock, exception)
          return nil
        handlerV = third
      else:
        var herr = ""
        let h = fromJS(ctx, second, herr)
        if herr != "" or h.kind != nvkString:
          throwTypeMismatch(ctx, "serve", "host",
            (if herr != "": "unreadable" else: jsTypeName(h.kind)),
            "string", docBlock, exception)
          return nil
        host = h.s
        var oerr = ""
        let oo = fromJS(ctx, third, oerr)
        if oerr != "" or oo.kind != nvkObject:
          throwTypeMismatch(ctx, "serve", "opts",
            (if oerr != "": "unreadable" else: jsTypeName(oo.kind)),
            "object", docBlock, exception)
          return nil
        try:
          sopts = parseServeOpts(ctx, third, "serve")
          workers = serveOptWorkers(ctx, third, "serve")
        except CatchableError as e:
          throwError(ctx, e.msg, exception)
          return nil
        haveOpts = true
        var ferr4 = ""
        let hv4 = fromJS(ctx, handler, ferr4)
        if ferr4 != "" or hv4.kind != nvkFunction:
          throwTypeMismatch(ctx, "serve", "handler",
            (if ferr4 != "": "unreadable" else: jsTypeName(hv4.kind)),
            "function", docBlock, exception)
          return nil
        handlerV = handler
      let rt = currentRt()
      var server = newHttpServer(rt.ensureLoop(), populate = false)
      if haveOpts:
        server.applyOptions(sopts)
      server.handler = httpOnRequest
      when defined(windows):
        if workers != 1:
          throwError(ctx, "serve: opts.workers is not supported on Windows",
            exception)
          return nil
      when not defined(windows):
        let spawning = workers > 1 and not inHttpWorker()
        let (adoptFd, hasAdoptFd) = readWorkerAdoptFd()
        let adopting = inHttpWorker() and hasAdoptFd
      try:
        when not defined(windows):
          if adopting:
            server.adoptListenFd(SocketHandle(adoptFd))
          else:
            server.listen(host, portNum)
        else:
          server.listen(host, portNum)
      except CatchableError as e:
        try:
          server.close()
        except CatchableError:
          discard
        throwError(ctx, "serve: " & e.msg, exception)
        return nil
      JSValueProtect(ctx, handlerV)
      inc rt.pending
      httpServers[cast[pointer](server)] =
        ServerEntry(ctx: ctx, rt: rt, server: server, handlerFn: handlerV,
          port: portNum, host: host)
      when not defined(windows):
        if spawning:
          var boundFd = 0.cint
          var hasBoundFd = false
          when defined(macosx):
            # macOS does not balance REUSEPORT groups: share this
            # socket, every worker adopts it in its own loop.
            hasBoundFd = true
            boundFd = cint(int(server.tcpServers[^1].fd))
          try:
            for i in 1 ..< workers:
              spawnWorker(makeBoot(rt.source, rt.sourceURL, rt.baseDir,
                host, rt.argv, portNum, boundFd, hasBoundFd), portNum)
          except CatchableError as e:
            try:
              closeServerEntry(server, httpServers[cast[pointer](server)])
            except CatchableError:
              discard
            throwError(ctx, "serve: " & e.msg, exception)
            return nil
        try:
          registerWorkerPipe(portNum)
        except CatchableError as e:
          try:
            closeServerEntry(server, httpServers[cast[pointer](server)])
          except CatchableError:
            discard
          throwError(ctx, "serve: " & e.msg, exception)
          return nil
      returnJson(ctx, %*{"port": portNum, "host": host}, "serve", exception)

    module.registerFn close(port: int64):
      ## http.close(port) -> bool
      if port < 1 or port > 65535:
        throwError(ctx, "close: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      var target: ServerEntry
      var found = false
      for k, e in httpServers.pairs:
        if e.port == portNum:
          target = e
          found = true
          break
      if not found:
        throwError(ctx, "close: no server on port " & $port, exception)
        return nil
      try:
        when not defined(windows):
          # Workers mode: every participant closes its own server;
          # the pipe broadcast reaches the other workers.
          broadcastWorkerPort(portNum, portNum)
        closeServerEntry(target.server, target)
      except CatchableError as err:
        throwError(ctx, "close: " & err.msg, exception)
        return nil
      toJS(ctx, true)
