# Carne std/tcp: async TCP client + server via powpow.
#
#   const tcp = require("std/tcp");
#   const srv = tcp.serve(9000, {onData: (conn, chunk) => conn.write("echo:" + chunk)});
#   const c = await tcp.connect("127.0.0.1", 9000, {onData: (chunk) => console.log(chunk)});
#   c.write("hello"); c.close(); tcp.close(9000);
#
# connect returns a Promise for the connection handle: `await
# tcp.connect(host, port[, opts])`. serve borrows the run's shared powpow
# loop and holds it alive until close (Node semantics). Handlers are
# {onOpen?, onData?, onClose?, onError?}: server-side callbacks receive
# (conn, payload), client-side callbacks receive just (payload) (onOpen
# takes no arguments).
#
# Handles are `{write(text), close(), remoteAddress, remotePort}`.
# Messages arrive as UTF-8 strings in v1 (same rule as std/http bodies);
# onClose receives no payload; onError fires for connect-phase failures
# (the connect promise rejects too, like std/ws). close() is final and
# idempotent.
#
# TLS: serve opts {certFile?, keyFile?} (both required together, PEM;
# the handshake starts on accept, writes before it completes buffer).
# connect opts {tls?, serverName?, rejectUnauthorized?} (default
# serverName is the host, rejectUnauthorized defaults to true; wss-style
# per-run shared client context, system CAs).

import std/[tables, json]
import std/[monotimes, times]

import javascriptcore

from powpow/loop import addTimer, stop, TimerId
import powpow/net/common
import powpow/net/tcp
import powpow/net/tls

import ../bridge
import ../modules

when not defined(windows):
  import std/posix

type
  TcpConnEntry = object
    ctx: JSContextRef
    rt: Runtime
    conn: Connection
    handle: JSObjectRef
    remoteAddress: string
    remotePort: int
    onOpen, onData, onClose, onError: JSObjectRef
    resolveFn, rejectFn: JSObjectRef
    serverKey: pointer
    closing: bool
    closed: bool
    openOk: bool
    tlsWait: bool
    timerId: TimerId
    since: MonoTime

  TcpServerEntry = object
    ctx: JSContextRef
    rt: Runtime
    server: TcpServer
    onOpen, onData, onClose, onError: JSObjectRef
    tlsCtx: SslContext
    port: int
    host: string

  TcpDial = ref object
    ctx: JSContextRef
    rt: Runtime
    onOpen, onData, onClose, onError: JSObjectRef
    resolveFn, rejectFn: JSObjectRef
    host: string
    port: int
    tls: bool
    serverName: string
    verify: bool
    settled: bool

var tcpConns {.threadvar.}: Table[pointer, TcpConnEntry]
var tcpServers {.threadvar.}: Table[pointer, TcpServerEntry]
var tcpTlsClient {.threadvar.}: Table[pointer, SslContext]
var tcpTlsClientNoVerify {.threadvar.}: Table[pointer, SslContext]

var tcpFireDepth {.threadvar.}: int
var tcpClosing {.threadvar.}: seq[TcpServer]

proc decPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc tlsClientCtx(rt: Runtime; verify: bool): SslContext =
  ## The run's shared client TLS context, created lazily. nil when OpenSSL
  ## init fails (callers throw for tls connects). Verified and unverified
  ## contexts are cached separately.
  let key = cast[pointer](rt)
  if verify:
    if tcpTlsClient.hasKey(key):
      return tcpTlsClient[key]
    try:
      result = newClientTlsContext(true)
    except CatchableError:
      result = nil
    tcpTlsClient[key] = result
  else:
    if tcpTlsClientNoVerify.hasKey(key):
      return tcpTlsClientNoVerify[key]
    try:
      result = newClientTlsContext(false)
    except CatchableError:
      result = nil
    tcpTlsClientNoVerify[key] = result

when not defined(windows):
  proc sockaddrPort(sa: Sockaddr_storage): int =
    ## Peer port of an IPv4/IPv6 sockaddr (family + port lead both
    ## layouts, so no full-struct cast is needed). 0 when unreadable.
    var p: uint16
    copyMem(addr p, cast[pointer](cast[int](unsafeAddr sa) + 2), 2)
    int(posix.ntohs(p))

proc fireCb(c: JSContextRef; rt: Runtime; fn: JSObjectRef;
    args: varargs[JSValueRef]) =
  ## Calls one user callback; a JS throw becomes the run's uncaught error.
  if fn == nil:
    return
  var ex: JSValueRef = nil
  inc tcpFireDepth
  try:
    if args.len == 0:
      discard JSObjectCallAsFunction(c, fn, nil, 0, nil, addr ex)
    else:
      var argv = newSeq[JSValueRef](args.len)
      for i in 0 ..< args.len:
        argv[i] = args[i]
      discard JSObjectCallAsFunction(c, fn, nil, csize_t(args.len),
        addr argv[0], addr ex)
  finally:
    dec tcpFireDepth
  if ex != nil:
    if rt.uncaught.len == 0:
      rt.uncaught = valueToString(c, ex)
      rt.exitCode = 1

proc unprotectHandlers(ctx: JSContextRef; fns: varargs[JSObjectRef]) =
  for f in fns:
    if f != nil:
      JSValueUnprotect(ctx, f)

proc cleanupConn(key: pointer) =
  ## Releases one pending slot and drops the entry with all its protected
  ## JS refs. Safe to call twice (closed flag) and safe with missing keys
  ## (late powpow events after teardown).
  if not tcpConns.hasKey(key):
    return
  var e = tcpConns[key]
  let c = e.ctx
  let h = e.handle
  let fns = [e.onOpen, e.onData, e.onClose, e.onError,
    e.resolveFn, e.rejectFn]
  if not e.closed:
    e.closed = true
    tcpConns[key] = e
    decPending(e.rt)
  tcpConns.del(key)
  if h != nil:
    JSValueUnprotect(c, h)
  unprotectHandlers(c, fns[0], fns[1], fns[2], fns[3], fns[4], fns[5])

proc settleResolve(c: JSContextRef; res, rej: JSObjectRef; val: JSValueRef) =
  ## Resolves a connect() promise with the handle; settle fns are consumed.
  if res == nil:
    return
  var ex: JSValueRef = nil
  var a = val
  discard JSObjectCallAsFunction(c, res, nil, 1, addr a, addr ex)
  JSValueUnprotect(c, res)
  if rej != nil:
    JSValueUnprotect(c, rej)

proc settleReject(c: JSContextRef; res, rej: JSObjectRef; msg: string) =
  ## Rejects a connect() promise with an Error; settle fns are consumed.
  if rej == nil:
    if res != nil:
      JSValueUnprotect(c, res)
    return
  var ex: JSValueRef = nil
  let msgV = toJS(c, msg)
  let errObj = JSObjectMakeError(c, 1, unsafeAddr msgV, addr ex)
  var arg = if errObj != nil: errObj else: msgV
  discard JSObjectCallAsFunction(c, rej, nil, 1, addr arg, addr ex)
  if res != nil:
    JSValueUnprotect(c, res)
  JSValueUnprotect(c, rej)

proc tcpOnData(conn: Connection; data: openArray[byte]) {.gcsafe.} =
  ## powpow dispatch: loop thread is the JS thread (borrowed loop).
  {.cast(gcsafe).}:
    let key = cast[pointer](conn)
    if not tcpConns.hasKey(key):
      return
    let e = tcpConns[key]
    if e.closing or e.onData == nil:
      return
    var s = newString(data.len)
    if data.len > 0:
      copyMem(addr s[0], unsafeAddr data[0], data.len)
    let msg = toJS(e.ctx, s)
    if msg == nil:
      return
    if e.serverKey == nil:
      fireCb(e.ctx, e.rt, e.onData, msg)
    else:
      fireCb(e.ctx, e.rt, e.onData, e.handle, msg)

proc tcpOnClose(conn: Connection) {.gcsafe.} =
  {.cast(gcsafe).}:
    let key = cast[pointer](conn)
    if not tcpConns.hasKey(key):
      return
    var ne = tcpConns[key]
    let wasClosing = ne.closing
    let c = ne.ctx
    let res = ne.resolveFn
    let rej = ne.rejectFn
    ne.resolveFn = nil
    ne.rejectFn = nil
    tcpConns[key] = ne
    cleanupConn(key)
    if res != nil or rej != nil:
      settleReject(c, res, rej, "connect: connection closed before open")
      return
    if wasClosing:
      return
    if ne.serverKey == nil:
      fireCb(ne.ctx, ne.rt, ne.onClose)
    else:
      fireCb(ne.ctx, ne.rt, ne.onClose, ne.handle)

proc failDial(d: TcpDial; msg: string) =
  ## Terminal pre-open failure on the async path. The dial took one
  ## pending slot up front; it is released here and the protected
  ## handlers settle (promise rejection + optional onError, like std/ws).
  if d.settled:
    return
  d.settled = true
  decPending(d.rt)
  let c = d.ctx
  let res = d.resolveFn
  let rej = d.rejectFn
  let errFn = d.onError
  d.resolveFn = nil
  d.rejectFn = nil
  d.onError = nil
  unprotectHandlers(c, d.onOpen, d.onData, d.onClose, res, rej)
  if res != nil or rej != nil:
    settleReject(c, res, rej, "connect: " & msg)
  if errFn != nil:
    let ev = jsonToJS(c, %*{"message": msg})
    if ev != nil:
      fireCb(c, d.rt, errFn, ev)
    else:
      unprotectHandlers(c, errFn)
  elif d.rt.uncaught.len == 0 and res == nil and rej == nil:
    d.rt.uncaught = "tcp: " & msg
    d.rt.exitCode = 1

const
  TlsPollMs = 25
  TlsHandshakeTimeoutMs = 10_000

proc tlsPollFired(key: pointer) =
  ## One poll turn for a TLS handshake (client dial or accepted server
  ## conn). Success opens the connection (resolves the dial promise and
  ## fires onOpen); terminal failure settles it the same way a refused
  ## dial does. powpow never reports handshake failure through onClose,
  ## so without this the slot would leak and the run would hang.
  if not tcpConns.hasKey(key):
    return
  var e = tcpConns[key]
  if not e.tlsWait:
    return
  e.timerId = TimerId(0)
  tcpConns[key] = e
  if isTlsActive(e.conn):
    let res = e.resolveFn
    let rej = e.rejectFn
    var ne = tcpConns[key]
    ne.resolveFn = nil
    ne.rejectFn = nil
    ne.tlsWait = false
    ne.openOk = true
    tcpConns[key] = ne
    if res != nil or rej != nil:
      settleResolve(e.ctx, res, rej, e.handle)
    if e.serverKey == nil:
      fireCb(e.ctx, e.rt, e.onOpen)
    else:
      fireCb(e.ctx, e.rt, e.onOpen, e.handle)
    return
  let ms = int(inMilliseconds(getMonoTime() - e.since))
  if e.conn.state == Closed or ms >= TlsHandshakeTimeoutMs:
    let msg =
      if e.conn.state == Closed: "tls handshake failed"
      else: "tls handshake timed out after " & $TlsHandshakeTimeoutMs & "ms"
    let c = e.ctx
    let r = e.rt
    let res = e.resolveFn
    let rej = e.rejectFn
    let oe = e.onError
    let sk = e.serverKey
    let h = e.handle
    var ne = tcpConns[key]
    ne.resolveFn = nil
    ne.rejectFn = nil
    tcpConns[key] = ne
    if res != nil or rej != nil:
      settleReject(c, res, rej, "connect: " & msg)
    if oe != nil:
      let ev = jsonToJS(c, %*{"message": msg})
      if ev != nil:
        if sk == nil:
          fireCb(c, r, oe, ev)
        else:
          fireCb(c, r, oe, h, ev)
    cleanupConn(key)
    return
  let loop = e.rt.ensureLoop()
  var ne = tcpConns[key]
  ne.timerId = loop.addTimer(TlsPollMs) do (id: int):
    tlsPollFired(key)
  tcpConns[key] = ne

proc armTlsPoll(key: pointer) =
  ## Starts handshake polling for a freshly wrapped TLS connection.
  if not tcpConns.hasKey(key):
    return
  var e = tcpConns[key]
  e.tlsWait = true
  e.since = getMonoTime()
  e.timerId = e.rt.ensureLoop().addTimer(TlsPollMs) do (id: int):
    tlsPollFired(key)
  tcpConns[key] = e

proc readOneFn(ctx: JSContextRef; obj: JSValueRef; key, name: string;
    exception: ptr JSValueRef; ok: var bool;
    docBlock = ""): JSObjectRef =
  ## Reads one optional handler fn; nil for absent/undefined. Protects the
  ## result. ok=false with a JS throw on anything else.
  template oerr(msg: string): untyped =
    throwError(ctx,
      (if docBlock.len > 0: docBlock & "\n" else: "") & msg, exception)
  result = nil
  ok = true
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    oerr(name & ": handlers." & key & " " & err)
    ok = false
    return
  if f.kind == nvkUndefined:
    return
  if f.kind != nvkFunction:
    oerr(name & ": handlers." & key & " is not a function, got " &
      jsTypeName(f.kind))
    ok = false
    return
  result = f.raw
  JSValueProtect(ctx, result)

proc readHandlers(ctx: JSContextRef; obj: JSValueRef; name: string;
    exception: ptr JSValueRef; onOpen, onData, onClose,
    onError: var JSObjectRef; docBlock = ""): bool =
  ## Reads optional {onOpen?, onData?, onClose?, onError?} handler fns.
  ## nil obj means absent. True on success.
  onOpen = nil
  onData = nil
  onClose = nil
  onError = nil
  if obj == nil:
    return true
  var ok = false
  onOpen = readOneFn(ctx, obj, "onOpen", name, exception, ok, docBlock)
  if not ok:
    return false
  onData = readOneFn(ctx, obj, "onData", name, exception, ok, docBlock)
  if not ok:
    unprotectHandlers(ctx, onOpen)
    return false
  onClose = readOneFn(ctx, obj, "onClose", name, exception, ok, docBlock)
  if not ok:
    unprotectHandlers(ctx, onOpen, onData)
    return false
  onError = readOneFn(ctx, obj, "onError", name, exception, ok, docBlock)
  if not ok:
    unprotectHandlers(ctx, onOpen, onData, onClose)
    return false
  true

proc findConnByHandle(handle: JSObjectRef): pointer =
  for k, e in tcpConns.pairs:
    if e.handle == handle:
      return k
  nil

registerFn(ctx, tcpWrite(text: string)):
  ## conn.write(text): thisObject is the handle created by connect/serve.
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "write: called on an invalid connection", exception)
    return nil
  let key = findConnByHandle(thisObject)
  if key == nil:
    throwError(ctx, "write: connection is closed", exception)
    return nil
  let e = tcpConns[key]
  if e.closing or e.closed or e.conn == nil or not e.openOk:
    throwError(ctx, "write: connection is closed", exception)
    return nil
  try:
    discard e.conn.send(text)
  except CatchableError as err:
    throwError(ctx, "write: " & err.msg, exception)
    return nil
  toJS(ctx, true)

registerFn(ctx, tcpClose()):
  ## conn.close(): final, idempotent; the pending slot is released when
  ## the close lands (or at teardown).
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "close: called on an invalid connection", exception)
    return nil
  let key = findConnByHandle(thisObject)
  if key == nil:
    return toJS(ctx, true)
  var e = tcpConns[key]
  e.closing = true
  tcpConns[key] = e
  try:
    e.conn.close()
  except CatchableError:
    discard
  toJS(ctx, true)

proc makeConnHandle(ctx: JSContextRef; address: string; port: int;
    exception: ptr JSValueRef): JSObjectRef =
  ## Fresh `{write, close, remoteAddress, remotePort}` handle; caller
  ## protects it via the entry.
  result = newObject(ctx)
  var ex: JSValueRef = nil
  setProp(ctx, result, "write", makeFunction(ctx, "write", tcpWrite),
    addr ex)
  if ex != nil:
    throwError(ctx, "tcp: could not create connection handle", exception)
    return nil
  setProp(ctx, result, "close", makeFunction(ctx, "close", tcpClose),
    addr ex)
  if ex != nil:
    throwError(ctx, "tcp: could not create connection handle", exception)
    return nil
  setProp(ctx, result, "remoteAddress", toJS(ctx, address), addr ex)
  if ex != nil:
    throwError(ctx, "tcp: could not create connection handle", exception)
    return nil
  setProp(ctx, result, "remotePort", toJS(ctx, port), addr ex)
  if ex != nil:
    throwError(ctx, "tcp: could not create connection handle", exception)
    return nil

proc insertConnHandle(ctx: JSContextRef; rt: Runtime; conn: Connection;
    address: string; port: int; serverKey: pointer;
    onOpen, onData, onClose, onError: JSObjectRef): JSObjectRef =
  ## Builds the handle, protects everything and registers the entry. The
  ## pending slot is owned by the caller (dial slot for clients, an extra
  ## inc for accepted server conns — see call sites). nil on failure (the
  ## connection is closed and uncaught is set).
  let handle = makeConnHandle(ctx, address, port, nil)
  if handle == nil:
    unprotectHandlers(ctx, onOpen, onData, onClose, onError)
    if rt.uncaught.len == 0:
      rt.uncaught = "tcp: could not create connection handle"
      rt.exitCode = 1
    try:
      conn.close()
    except CatchableError:
      discard
    return nil
  JSValueProtect(ctx, handle)
  let key = cast[pointer](conn)
  tcpConns[key] = TcpConnEntry(ctx: ctx, rt: rt, conn: conn,
    handle: handle, remoteAddress: address, remotePort: port,
    onOpen: onOpen, onData: onData, onClose: onClose, onError: onError,
    serverKey: serverKey, closing: false, closed: false, openOk: true)
  handle

proc queueServerClose(rt: Runtime; server: TcpServer) =
  ## Finishes a tcp.close(port) whose caller sits inside a user callback:
  ## the server close runs on the next loop turn, after powpow's dispatch
  ## stack has unwound. Exactly-once via tcpClosing (teardown drains it).
  tcpClosing.add(server)
  let srv = server
  let loop = rt.ensureLoop()
  discard loop.addTimer(1) do (id: int):
    var idx = -1
    for i in 0 ..< tcpClosing.len:
      if tcpClosing[i] == srv:
        idx = i
        break
    if idx >= 0:
      tcpClosing.del(idx)
      try:
        srv.close()
      except CatchableError:
        discard

proc closeAllTcp*() =
  ## Closes every live server and connection. Runs at runtime teardown with
  ## entries removed first, so late powpow close events no-op instead of
  ## calling JS on a dying context. Safe with none live.
  var skeys: seq[pointer] = @[]
  for k in tcpServers.keys:
    skeys.add(k)
  for k in skeys:
    if not tcpServers.hasKey(k):
      continue
    let se = tcpServers[k]
    unprotectHandlers(se.ctx, se.onOpen, se.onData, se.onClose,
      se.onError)
    tcpServers.del(k)
    try:
      se.server.close()
    except CatchableError:
      discard
    decPending(se.rt)
  for srv in tcpClosing:
    try:
      srv.close()
    except CatchableError:
      discard
  tcpClosing.setLen(0)
  var tkeys: seq[pointer] = @[]
  for k in tcpTlsClient.keys:
    tkeys.add(k)
  for k in tkeys:
    tcpTlsClient.del(k)
  var nkeys: seq[pointer] = @[]
  for k in tcpTlsClientNoVerify.keys:
    nkeys.add(k)
  for k in nkeys:
    tcpTlsClientNoVerify.del(k)
  var ckeys: seq[pointer] = @[]
  for k in tcpConns.keys:
    ckeys.add(k)
  for k in ckeys:
    if not tcpConns.hasKey(k):
      continue
    let e = tcpConns[k]
    tcpConns.del(k)
    if not e.closed:
      decPending(e.rt)
    if e.handle != nil:
      JSValueUnprotect(e.ctx, e.handle)
    unprotectHandlers(e.ctx, e.onOpen, e.onData, e.onClose, e.onError,
      e.resolveFn, e.rejectFn)
    if e.conn != nil:
      try:
        e.conn.close()
      except CatchableError:
        discard

# Teardown hook: runs at runtime teardown when this module is linked in
# (binary, or tests that register std/tcp). Safe with none live.
onTeardown.add(closeAllTcp)

## Builds the std/tcp namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn serve(port: int64, hostOrHandlers: JSValueRef,
        handlers ?: JSObjectRef):
      ## tcp.serve(port[, host], {onData?, ...handlers, certFile?, keyFile?}) -> {port, host}
      if inHttpWorker():
        throwError(ctx,
          "serve: tcp.serve is not supported in http worker threads",
          exception)
        return nil
      if port < 1 or port > 65535:
        throwError(ctx, "serve: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      let n = int(argumentCount)
      var host = "127.0.0.1"
      var handlersObj: JSObjectRef = nil
      if n == 2:
        if not objRefCheck(ctx, hostOrHandlers, "serve", "handlers",
            docBlock, exception):
          return nil
        handlersObj = hostOrHandlers
      else:
        var herr = ""
        let h = fromJS(ctx, hostOrHandlers, herr)
        if herr != "" or h.kind != nvkString:
          throwTypeMismatch(ctx, "serve", "host",
            (if herr != "": "unreadable" else: jsTypeName(h.kind)),
            "string", docBlock, exception)
          return nil
        host = h.s
        handlersObj = handlers
      var onOpen, onData, onClose, onError: JSObjectRef
      if not readHandlers(ctx, handlersObj, "serve", exception, onOpen,
          onData, onClose, onError, docBlock):
        return nil
      var certFile, keyFile = ""
      if handlersObj != nil:
        for (key, dst) in [("certFile", addr certFile),
            ("keyFile", addr keyFile)]:
          var oerr = ""
          let f = getField(ctx, handlersObj, key, oerr)
          if oerr != "":
            unprotectHandlers(ctx, onOpen, onData, onClose, onError)
            throwError(ctx, "serve: options." & key & " " & oerr,
              exception)
            return nil
          if f.kind != nvkUndefined:
            if f.kind != nvkString:
              unprotectHandlers(ctx, onOpen, onData, onClose, onError)
              throwError(ctx, "serve: options." & key &
                " must be a string", exception)
              return nil
            dst[] = f.s
      if (certFile.len == 0) != (keyFile.len == 0):
        unprotectHandlers(ctx, onOpen, onData, onClose, onError)
        throwError(ctx,
          "serve: options.certFile and options.keyFile are required together",
          exception)
        return nil
      var serverTls: SslContext = nil
      if certFile.len > 0:
        try:
          serverTls = newServerTlsContext(certFile, keyFile)
        except CatchableError as e:
          unprotectHandlers(ctx, onOpen, onData, onClose, onError)
          throwError(ctx, "serve: " & e.msg, exception)
          return nil
      # tcell is pre-declared: the onAccept closure runs after listen,
      # but it must read the server key through an already-declared capture
      # (a var under construction cannot see itself).
      let rt = currentRt()
      var tcell: TcpServer = nil
      tcell = newTcpServer(rt.ensureLoop(), tcpOnData,
        onAccept = proc(conn: Connection) {.closure, gcsafe.} =
          {.cast(gcsafe).}:
            let sk = cast[pointer](tcell)
            if not tcpServers.hasKey(sk):
              try:
                conn.close()
              except CatchableError:
                discard
              return
            let se = tcpServers[sk]
            if se.tlsCtx != nil:
              try:
                wrapTls(conn, se.tlsCtx)
              except CatchableError as e:
                try:
                  conn.close()
                except CatchableError:
                  discard
                if se.onError != nil:
                  let ev = jsonToJS(se.ctx,
                    %*{"message": "tls handshake failed: " & e.msg})
                  if ev != nil:
                    fireCb(se.ctx, se.rt, se.onError, ev)
                return
            var address = ""
            var peerPort = 0
            try:
              address = conn.getClientIp()
              when not defined(windows):
                peerPort = sockaddrPort(conn.getClientSockAddr())
            except CatchableError:
              discard
            # Borrowed fns: each accepted conn protects what it references
            # (balanced by its cleanupConn); the server entry keeps its own
            # set for closeAllTcp/tcp.close.
            if se.onOpen != nil:
              JSValueProtect(se.ctx, se.onOpen)
            if se.onData != nil:
              JSValueProtect(se.ctx, se.onData)
            if se.onClose != nil:
              JSValueProtect(se.ctx, se.onClose)
            if se.onError != nil:
              JSValueProtect(se.ctx, se.onError)
            let handle = insertConnHandle(se.ctx, se.rt, conn, address,
              peerPort, sk, se.onOpen, se.onData, se.onClose, se.onError)
            if handle == nil:
              return
            inc se.rt.pending
            if se.tlsCtx != nil:
              # Handshake completes asynchronously; the poll opens the
              # connection (fires onOpen) or drops it on failure.
              armTlsPoll(cast[pointer](conn))
            else:
              fireCb(se.ctx, se.rt, se.onOpen, handle),
        onClose = tcpOnClose)
      let tserver = tcell
      let skey = cast[pointer](tserver)
      tcpServers[skey] = TcpServerEntry(ctx: ctx, rt: rt, server: tserver,
        onOpen: onOpen, onData: onData, onClose: onClose, onError: onError,
        tlsCtx: serverTls, port: portNum, host: host)
      try:
        tserver.listen(host, portNum)
      except CatchableError as e:
        tcpServers.del(skey)
        unprotectHandlers(ctx, onOpen, onData, onClose, onError)
        try:
          tserver.close()
        except CatchableError:
          discard
        throwError(ctx, "serve: " & e.msg, exception)
        return nil
      inc rt.pending
      # The server entry holds one slot; each accepted conn holds its own.
      returnJson(ctx, %*{"port": portNum, "host": host}, "serve", exception)

    module.registerFn connect(host: string, port: int64,
        optsObj ?: JSObjectRef):
      ## tcp.connect(host, port[, {tls?, serverName?, rejectUnauthorized?, ...handlers}]) -> Promise<conn>
      if port < 1 or port > 65535:
        throwError(ctx, "connect: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      var onOpen, onData, onClose, onError: JSObjectRef
      if not readHandlers(ctx, optsObj, "connect", exception, onOpen,
          onData, onClose, onError, docBlock):
        return nil
      var useTls = false
      var serverName = host
      var verify = true
      if optsObj != nil:
        var oerr = ""
        let t = getField(ctx, optsObj, "tls", oerr)
        if oerr != "":
          unprotectHandlers(ctx, onOpen, onData, onClose, onError)
          throwError(ctx, "connect: options.tls " & oerr, exception)
          return nil
        if t.kind != nvkUndefined:
          if t.kind != nvkBool:
            unprotectHandlers(ctx, onOpen, onData, onClose, onError)
            throwError(ctx, "connect: options.tls must be a boolean",
              exception)
            return nil
          useTls = t.b
        let sn = getField(ctx, optsObj, "serverName", oerr)
        if oerr != "":
          unprotectHandlers(ctx, onOpen, onData, onClose, onError)
          throwError(ctx, "connect: options.serverName " & oerr, exception)
          return nil
        if sn.kind != nvkUndefined:
          if sn.kind != nvkString:
            unprotectHandlers(ctx, onOpen, onData, onClose, onError)
            throwError(ctx,
              "connect: options.serverName must be a string", exception)
            return nil
          serverName = sn.s
        let ru = getField(ctx, optsObj, "rejectUnauthorized", oerr)
        if oerr != "":
          unprotectHandlers(ctx, onOpen, onData, onClose, onError)
          throwError(ctx, "connect: options.rejectUnauthorized " & oerr,
            exception)
          return nil
        if ru.kind != nvkUndefined:
          if ru.kind != nvkBool:
            unprotectHandlers(ctx, onOpen, onData, onClose, onError)
            throwError(ctx,
              "connect: options.rejectUnauthorized must be a boolean",
              exception)
            return nil
          verify = ru.b
      if useTls and serverName.len == 0:
        unprotectHandlers(ctx, onOpen, onData, onClose, onError)
        throwError(ctx, "connect: options.serverName must not be empty",
          exception)
        return nil
      var resolveFn, rejectFn: JSObjectRef
      var mkEx: JSValueRef = nil
      let promise = JSObjectMakeDeferredPromise(ctx, addr resolveFn,
        addr rejectFn, addr mkEx)
      if promise == nil or mkEx != nil:
        unprotectHandlers(ctx, onOpen, onData, onClose, onError)
        throwError(ctx, "connect: could not create promise", exception)
        return nil
      JSValueProtect(ctx, resolveFn)
      JSValueProtect(ctx, rejectFn)
      let rt = currentRt()
      let dial = TcpDial(ctx: ctx, rt: rt, onOpen: onOpen,
        onData: onData, onClose: onClose, onError: onError,
        resolveFn: resolveFn, rejectFn: rejectFn, host: host,
        port: portNum, tls: useTls, serverName: serverName,
        verify: verify, settled: false)
      inc rt.pending
      let loop = rt.ensureLoop()
      try:
        loop.connect(host, portNum,
          onConnect = proc(conn: Connection) {.closure, gcsafe.} =
            {.cast(gcsafe).}:
              if dial.settled:
                try:
                  conn.close()
                except CatchableError:
                  discard
                return
              dial.settled = true
              if dial.tls:
                let tlsCtx = tlsClientCtx(dial.rt, dial.verify)
                if tlsCtx == nil:
                  failDial(dial, "tls needs a TLS context" &
                    " (OpenSSL init failed)")
                  try:
                    conn.close()
                  except CatchableError:
                    discard
                  return
                try:
                  wrapTls(conn, tlsCtx, dial.serverName)
                except CatchableError as e:
                  failDial(dial, e.msg)
                  try:
                    conn.close()
                  except CatchableError:
                    discard
                  return
              # The remote is definitionally the dial target (powpow only
              # fills in the peer address on accepted server conns).
              let address = dial.host
              let peerPort = dial.port
              let c = dial.ctx
              let r = dial.rt
              let oo = dial.onOpen
              let od = dial.onData
              let oc = dial.onClose
              let oe = dial.onError
              let res = dial.resolveFn
              let rej = dial.rejectFn
              if oo != nil:
                JSValueProtect(c, oo)
              if od != nil:
                JSValueProtect(c, od)
              if oc != nil:
                JSValueProtect(c, oc)
              if oe != nil:
                JSValueProtect(c, oe)
              let handle = insertConnHandle(c, r, conn, address, peerPort,
                nil, oo, od, oc, oe)
              if handle == nil:
                decPending(r)
                settleReject(c, res, rej,
                  "connect: could not create connection handle")
                return
              if dial.tls:
                # Handshake completes asynchronously; the poll resolves the
                # promise (fires onOpen) or rejects it on failure.
                var ne = tcpConns[cast[pointer](conn)]
                ne.resolveFn = res
                ne.rejectFn = rej
                tcpConns[cast[pointer](conn)] = ne
                armTlsPoll(cast[pointer](conn))
              else:
                settleResolve(c, res, rej, handle)
                fireCb(c, r, oo),
          onData = tcpOnData,
          onClose = tcpOnClose,
          onError = proc(err: string) {.closure, gcsafe.} =
            {.cast(gcsafe).}:
              failDial(dial, err))
      except CatchableError as e:
        decPending(rt)
        unprotectHandlers(ctx, onOpen, onData, onClose, onError,
          resolveFn, rejectFn)
        throwError(ctx, "connect: " & e.msg, exception)
        return nil
      promise

    module.registerFn close(port: int64):
      ## tcp.close(port) -> bool
      if port < 1 or port > 65535:
        throwError(ctx, "close: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      var skey: pointer = nil
      var found = false
      for k, se in tcpServers.pairs:
        if se.port == portNum:
          skey = k
          found = true
          break
      if not found:
        throwError(ctx, "close: no server on port " & $portNum, exception)
        return nil
      let se = tcpServers[skey]
      # Server-side conns die with the listener: drop their entries first
      # so their close events no-op, then close the listener.
      var dead: seq[pointer] = @[]
      for k, e in tcpConns.pairs:
        if e.serverKey == skey:
          dead.add(k)
      for k in dead:
        cleanupConn(k)
      unprotectHandlers(se.ctx, se.onOpen, se.onData, se.onClose,
        se.onError)
      tcpServers.del(skey)
      # The slot is released now; the transport close follows. From inside
      # a user callback it must wait a turn (see queueServerClose).
      decPending(se.rt)
      if tcpFireDepth > 0:
        queueServerClose(se.rt, se.server)
        return toJS(ctx, true)
      try:
        se.server.close()
      except CatchableError as err:
        throwError(ctx, "close: " & err.msg, exception)
        return nil
      toJS(ctx, true)
