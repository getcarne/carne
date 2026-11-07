# Carne std/udp: async UDP sockets via powpow.
#
#   const udp = require("std/udp");
#   const s = udp.bind(9001, (msg, rinfo) => s.sendTo("pong:" + msg.data, rinfo));
#   const c = udp.connect("127.0.0.1", 9001, (msg) => console.log(msg.data));
#   c.send("hi");
#
# bind creates a server socket, connect a connected client socket. Both
# borrow the run's shared powpow loop and hold it alive until close (Node
# semantics). Messages arrive as {data} (UTF-8 strings in v1, same rule
# as std/http bodies); bind callbacks receive (msg, rinfo) with
# rinfo = {address, port}, connect callbacks just (msg). sendTo accepts
# a rinfo object or (host, port); send targets the connected peer (bind
# sockets must use sendTo). close() is final and idempotent. No TLS on
# UDP in v1 (powpow has no DTLS path).

import std/[tables, json, math]

import javascriptcore

from powpow/loop import stop
from powpow/net/tcp import formatIp
import powpow/net/common
import powpow/net/udp

import ../bridge
import ../modules

when not defined(windows):
  import std/posix

  proc sockaddrPort(sa: Sockaddr_storage): int =
    ## Peer port of an IPv4/IPv6 sockaddr (family + port lead both
    ## layouts, so no full-struct cast is needed). 0 when unreadable.
    var p: uint16
    copyMem(addr p, cast[pointer](cast[int](unsafeAddr sa) + 2), 2)
    int(posix.ntohs(p))

  proc localPort(fd: SocketHandle): int =
    ## Bound local port of fd (for ephemeral binds). 0 on failure.
    var sa: Sockaddr_storage
    var len = SockLen(sizeof(sa))
    if getsockname(fd, cast[ptr SockAddr](addr sa), addr len) != 0:
      return 0
    sockaddrPort(sa)

type
  UdpEntry = object
    ctx: JSContextRef
    rt: Runtime
    sock: UdpSocket
    handle: JSObjectRef
    onMessage: JSObjectRef
    connected: bool
    peerHost: string
    peerPort: int
    closing: bool
    closed: bool

var udpSockets {.threadvar.}: Table[pointer, UdpEntry]

proc decPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc unprotectHandlers(ctx: JSContextRef; fns: varargs[JSObjectRef]) =
  for f in fns:
    if f != nil:
      JSValueUnprotect(ctx, f)

proc cleanupSock(key: pointer) =
  ## Releases one pending slot and drops the entry with its protected JS
  ## refs. Safe to call twice (closed flag) and safe with missing keys.
  if not udpSockets.hasKey(key):
    return
  var e = udpSockets[key]
  let c = e.ctx
  let h = e.handle
  if not e.closed:
    e.closed = true
    udpSockets[key] = e
    decPending(e.rt)
  udpSockets.del(key)
  if h != nil:
    JSValueUnprotect(c, h)
  unprotectHandlers(c, e.onMessage)

proc fireCb(c: JSContextRef; rt: Runtime; fn: JSObjectRef;
    args: varargs[JSValueRef]) =
  ## Calls one user callback; a JS throw becomes the run's uncaught error.
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

proc findSockByHandle(handle: JSObjectRef): pointer =
  for k, e in udpSockets.pairs:
    if e.handle == handle:
      return k
  nil

proc rinfoToJS(ctx: JSContextRef; address: string; port: int;
    name: string; exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "address", toJS(ctx, address), name,
      exception):
    return nil
  if not setPropChecked(ctx, obj, "port", toJS(ctx, port), name,
      exception):
    return nil
  obj

proc udpDispatched(key: pointer; sender: Sockaddr_storage;
    data: openArray[byte]) =
  ## Shared receive path: looks the socket entry up by key, builds
  ## {data} + {address, port} and fires onMessage(msg, rinfo).
  if key == nil or not udpSockets.hasKey(key):
    return
  let e = udpSockets[key]
  if e.closing or e.onMessage == nil:
    return
  var s = newString(data.len)
  if data.len > 0:
    copyMem(addr s[0], unsafeAddr data[0], data.len)
  let msg = jsonToJS(e.ctx, %*{"data": s})
  if msg == nil:
    return
  var address = ""
  var port = 0
  try:
    address = formatIp(sender)
    when not defined(windows):
      port = sockaddrPort(sender)
  except CatchableError:
    discard
  let rinfo = rinfoToJS(e.ctx, address, port, "udp", nil)
  if rinfo == nil:
    return
  fireCb(e.ctx, e.rt, e.onMessage, msg, rinfo)

proc readRinfo(ctx: JSContextRef; v: JSValueRef; name: string;
    address: var string; port: var int;
    exception: ptr JSValueRef): bool =
  ## Reads a {address, port} target. False + JS throw on failure.
  var err = ""
  let a = getField(ctx, v, "address", err)
  if err != "":
    throwError(ctx, name & ": target.address " & err, exception)
    return false
  if a.kind != nvkString or a.s.len == 0:
    throwError(ctx, name & ": target.address must be a non-empty string",
      exception)
    return false
  let p = getField(ctx, v, "port", err)
  if err != "":
    throwError(ctx, name & ": target.port " & err, exception)
    return false
  var n = 0
  case p.kind
  of nvkInt: n = int(p.i)
  of nvkFloat:
    if p.f != trunc(p.f):
      throwError(ctx, name & ": target.port must be an integer 1..65535",
        exception)
      return false
    n = int(p.f)
  else:
    throwError(ctx, name & ": target.port must be an integer 1..65535",
      exception)
    return false
  if n < 1 or n > 65535:
    throwError(ctx, name & ": target.port must be 1..65535", exception)
    return false
  address = a.s
  port = n
  true

registerFn(ctx, udpSendTo(text: string, target: JSValueRef,
    portArg ?: int64)):
  ## sock.sendTo(text, rinfo) or sock.sendTo(text, host, port).
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "sendTo: called on an invalid socket", exception)
    return nil
  let key = findSockByHandle(thisObject)
  if key == nil:
    throwError(ctx, "sendTo: socket is closed", exception)
    return nil
  let e = udpSockets[key]
  if e.closing or e.closed or e.sock == nil:
    throwError(ctx, "sendTo: socket is closed", exception)
    return nil
  var address = ""
  var port = 0
  let n = int(argumentCount)
  if n == 2:
    if JSValueGetType(ctx, target) != kJSTypeObject or
        JSValueIsArray(ctx, target):
      throwError(ctx, "sendTo: target must be a {address, port} object",
        exception)
      return nil
    if not readRinfo(ctx, target, "sendTo", address, port, exception):
      return nil
  else:
    var herr = ""
    let h = fromJS(ctx, target, herr)
    if herr != "" or h.kind != nvkString or h.s.len == 0:
      throwError(ctx, "sendTo: host must be a non-empty string",
        exception)
      return nil
    if portArg < 1 or portArg > 65535:
      throwError(ctx, "sendTo: port must be 1..65535", exception)
      return nil
    address = h.s
    port = int(portArg)
  try:
    discard e.sock.sendTo(text, address, port)
  except CatchableError as err:
    throwError(ctx, "sendTo: " & err.msg, exception)
    return nil
  toJS(ctx, true)

registerFn(ctx, udpSend(text: string)):
  ## sock.send(text): connected sockets (connect) only.
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "send: called on an invalid socket", exception)
    return nil
  let key = findSockByHandle(thisObject)
  if key == nil:
    throwError(ctx, "send: socket is closed", exception)
    return nil
  let e = udpSockets[key]
  if e.closing or e.closed or e.sock == nil:
    throwError(ctx, "send: socket is closed", exception)
    return nil
  if not e.connected:
    throwError(ctx, "send: socket is not connected, use sendTo",
      exception)
    return nil
  try:
    discard e.sock.send(text)
  except CatchableError as err:
    throwError(ctx, "send: " & err.msg, exception)
    return nil
  toJS(ctx, true)

registerFn(ctx, udpClose()):
  ## sock.close(): final, idempotent; the pending slot is released now.
  if thisObject == nil or not JSValueIsObject(ctx, thisObject):
    throwError(ctx, "close: called on an invalid socket", exception)
    return nil
  let key = findSockByHandle(thisObject)
  if key == nil:
    return toJS(ctx, true)
  var e = udpSockets[key]
  e.closing = true
  udpSockets[key] = e
  let s = e.sock
  cleanupSock(key)
  try:
    s.close()
  except CatchableError:
    discard
  toJS(ctx, true)

proc makeSockHandle(ctx: JSContextRef; address: string; port: int;
    connected: bool; exception: ptr JSValueRef): JSObjectRef =
  ## Fresh `{sendTo, send, close, address, port}` handle; caller protects
  ## it via the entry. address/port is the local bind for bind sockets
  ## and the remote peer for connected sockets.
  result = newObject(ctx)
  var ex: JSValueRef = nil
  setProp(ctx, result, "sendTo",
    makeFunction(ctx, "sendTo", udpSendTo), addr ex)
  if ex != nil:
    throwError(ctx, "udp: could not create socket handle", exception)
    return nil
  setProp(ctx, result, "send",
    makeFunction(ctx, "send", udpSend), addr ex)
  if ex != nil:
    throwError(ctx, "udp: could not create socket handle", exception)
    return nil
  setProp(ctx, result, "close",
    makeFunction(ctx, "close", udpClose), addr ex)
  if ex != nil:
    throwError(ctx, "udp: could not create socket handle", exception)
    return nil
  setProp(ctx, result, "address", toJS(ctx, address), addr ex)
  if ex != nil:
    throwError(ctx, "udp: could not create socket handle", exception)
    return nil
  setProp(ctx, result, "port", toJS(ctx, port), addr ex)
  if ex != nil:
    throwError(ctx, "udp: could not create socket handle", exception)
    return nil

proc closeAllUdp*() =
  ## Closes every live socket. Runs at runtime teardown with entries
  ## removed first, so late powpow events no-op. Safe with none live.
  var keys: seq[pointer] = @[]
  for k in udpSockets.keys:
    keys.add(k)
  for k in keys:
    if not udpSockets.hasKey(k):
      continue
    let e = udpSockets[k]
    udpSockets.del(k)
    if not e.closed:
      decPending(e.rt)
    if e.handle != nil:
      JSValueUnprotect(e.ctx, e.handle)
    unprotectHandlers(e.ctx, e.onMessage)
    if e.sock != nil:
      try:
        e.sock.close()
      except CatchableError:
        discard

# Teardown hook: runs at runtime teardown when this module is linked in
# (binary, or tests that register std/udp). Safe with none live.
onTeardown.add(closeAllUdp)

registerFn(ctx, udpBindFn(port: int64, hostOrFn: JSValueRef, onMessageFn ?: JSObjectRef)):
  ## udp.bind(port[, host], onMessage) -> socket (port 0 binds an ephemeral port)
  if port < 0 or port > 65535:
    throwError(ctx, "bind: port must be 0..65535", exception)
    return nil
  let portNum = int(port)
  let n = int(argumentCount)
  var host = "127.0.0.1"
  var fn: JSObjectRef = nil
  if n == 2:
    if JSValueGetType(ctx, hostOrFn) != kJSTypeObject or
        not JSObjectIsFunction(ctx, hostOrFn):
      throwError(ctx,
        "bind: onMessage must be a function", exception)
      return nil
    fn = hostOrFn
  else:
    var herr = ""
    let h = fromJS(ctx, hostOrFn, herr)
    if herr != "" or h.kind != nvkString:
      throwTypeMismatch(ctx, "bind", "host",
        (if herr != "": "unreadable" else: jsTypeName(h.kind)),
        "string", docBlock, exception)
      return nil
    host = h.s
    if onMessageFn == nil:
      throwError(ctx, "bind: onMessage is required", exception)
      return nil
    if not JSObjectIsFunction(ctx, onMessageFn):
      throwError(ctx, "bind: onMessage must be a function",
        exception)
      return nil
    fn = onMessageFn
  let rt = currentRt()
  var skey: pointer = nil
  proc onRecv(sender: Sockaddr_storage;
      data: openArray[byte]) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      udpDispatched(skey, sender, data)
  var sock: UdpSocket
  try:
    sock = bindUdp(rt.ensureLoop(), host, portNum, onRecv)
  except CatchableError as e:
    throwError(ctx, "bind: " & e.msg, exception)
    return nil
  skey = cast[pointer](sock)
  var actual = portNum
  when not defined(windows):
    if actual == 0:
      actual = localPort(sock.fd)
  let handle = makeSockHandle(ctx, host, actual, false, exception)
  if handle == nil:
    try:
      sock.close()
    except CatchableError:
      discard
    return nil
  JSValueProtect(ctx, handle)
  JSValueProtect(ctx, fn)
  let key = skey
  udpSockets[key] = UdpEntry(ctx: ctx, rt: rt, sock: sock,
    handle: handle, onMessage: fn, connected: false,
    peerHost: "", peerPort: 0, closing: false, closed: false)
  inc rt.pending
  handle

## Builds the std/udp namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn connect(host: string, port: int64,
        onMessageFn ?: JSObjectRef):
      ## udp.connect(host, port[, onMessage]) -> socket
      if port < 1 or port > 65535:
        throwError(ctx, "connect: port must be 1..65535", exception)
        return nil
      let portNum = int(port)
      var fn: JSObjectRef = nil
      if onMessageFn != nil:
        if not JSObjectIsFunction(ctx, onMessageFn):
          throwError(ctx, "connect: onMessage must be a function",
            exception)
          return nil
        fn = onMessageFn
      let rt = currentRt()
      var skey: pointer = nil
      proc onRecv(sender: Sockaddr_storage;
          data: openArray[byte]) {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          udpDispatched(skey, sender, data)
      var sock: UdpSocket
      try:
        sock = connectUdp(rt.ensureLoop(), host, portNum, onRecv)
      except CatchableError as e:
        throwError(ctx, "connect: " & e.msg, exception)
        return nil
      skey = cast[pointer](sock)
      let handle = makeSockHandle(ctx, host, portNum, true, exception)
      if handle == nil:
        try:
          sock.close()
        except CatchableError:
          discard
        return nil
      JSValueProtect(ctx, handle)
      if fn != nil:
        JSValueProtect(ctx, fn)
      let key = skey
      udpSockets[key] = UdpEntry(ctx: ctx, rt: rt, sock: sock,
        handle: handle, onMessage: fn, connected: true,
        peerHost: host, peerPort: portNum, closing: false, closed: false)
      inc rt.pending
      handle

  # `bind` cannot be a registerFn name (Nim `bind` statement), so the
  # definition-only callback above is attached manually here.
  setProp(module.ctx, module.ns, "bind",
    makeFunction(module.ctx, "bind", udpBindFn), nil)
