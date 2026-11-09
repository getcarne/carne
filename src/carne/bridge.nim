# Carne bridge: shared Nim <> JS marshalling and registration helpers.
#
# Every std module builds on these, so authoring a module stays small.
# Rule: no Nim exception may escape a {.cdecl.} JS callback; Nim errors
# become JS Error throws via throwError.

import std/macros
import std/math
import std/options
import std/strutils
import std/tables

import pkg/openparser/json

import javascriptcore

when not defined(windows):
  import std/posix

when defined(linux):
  # WebKitGTK declares JSValueRef as `const struct OpaqueJSValue*` while the
  # bindings use a non-const pointer, so every `exception: ptr JSValueRef`
  # out-param mismatches the header's `const JSValueRef*` and GCC 14 turns
  # -Wincompatible-pointer-types into a hard error. Upstream silences only
  # the clang spelling of this diagnostic, so add the GCC spelling here in
  # bridge (imported by the runtime and every std module): it covers the
  # binary and all test binaries in one place.
  {.passC: "-Wno-incompatible-pointer-types".}

import powpow/types
import powpow/loop

type
  TimerEntry* = object
    ## One live JS timer: the powpow id, the protected JS callback,
    ## protected passthrough args, and whether it repeats.
    id*: TimerId
    fn*: JSObjectRef
    rest*: seq[JSValueRef]
    isInterval*: bool

  Runtime* = ref object
    ## Per-run shared state: JS context, argv, powpow loop, pending-work
    ## refcount, exit signalling, require cache, live timers.
    ctx*: JSContextRef
    argv*: seq[string]
    loop*: Loop
    pending*: int
    exitRequested*: bool
    exitCode*: int
    uncaught*: string
    instances*: Table[string, JSObjectRef]
    moduleStack*: seq[string]
    timerSeq*: int
    timers*: Table[int, TimerEntry]
    promiseSettled*: bool
    promiseRejected*: bool
    promiseText*: string
    source*: string
    sourceURL*: string
    baseDir*: string
      ## Retained boot source so http workers can re-run the script.

var rtThread {.threadvar.}: Runtime

proc currentRt*(): Runtime =
  ## The run currently executing on this thread. Set by runCode.
  rtThread

proc setCurrentRt*(rt: Runtime) =
  rtThread = rt

var isHttpWorker {.threadvar.}: bool
  ## True on threads spawned by http.serve workers (never on main).
  ## Gates spawn recursion, teardown joins and ws.serve.

proc inHttpWorker*(): bool =
  isHttpWorker

proc markHttpWorker*() =
  isHttpWorker = true

proc ensureLoop*(rt: Runtime): Loop =
  ## Creates the run's powpow loop on first async need (timers, fetch,
  ## serve) and returns it. Pure-sync scripts never pay for the event
  ## backend (kqueue on macOS, epoll on Linux) + table preallocation. Every `inc rt.pending` site must go through
  ## here first, so pending > 0 implies a live loop.
  if rt.loop == nil:
    rt.loop = newLoop()
  rt.loop

type
  CarneError* = object of CatchableError

  Module* = ref object
    ## A std module under construction: the JS context plus the
    ## namespace object that `init` returns for `require("std/...")`.
    ctx*: JSContextRef
    ns*: JSObjectRef

proc valueToString*(ctx: JSContextRef; value: JSValueRef): string =
  ## Converts a JS value via String(value). Empty string on failure.
  var ex: JSValueRef = nil
  let s = JSValueToStringCopy(ctx, value, addr ex)
  if s == nil:
    return ""
  defer: JSStringRelease(s)
  $s

proc setProp*(ctx: JSContextRef; obj: JSObjectRef; name: string;
    value: JSValueRef; setupEx: ptr JSValueRef) =
  let key = newJSString(name)
  defer: JSStringRelease(key)
  JSObjectSetProperty(ctx, obj, key, value, kJSPropertyAttributeNone, setupEx)

proc newObject*(ctx: JSContextRef): JSObjectRef =
  JSObjectMake(ctx, nil, nil)

proc makeFunction*(ctx: JSContextRef; name: string;
    cb: JSObjectCallAsFunctionCallback): JSObjectRef =
  ## Wraps a Nim callback as a JS function.
  let jsName = newJSString(name)
  defer: JSStringRelease(jsName)
  JSObjectMakeFunctionWithCallback(ctx, jsName, cb)

proc toJS*(ctx: JSContextRef; s: string): JSValueRef =
  let jsStr = newJSString(s)
  defer: JSStringRelease(jsStr)
  JSValueMakeString(ctx, jsStr)

proc toJS*(ctx: JSContextRef; n: int64): JSValueRef =
  JSValueMakeNumber(ctx, cdouble(n))

proc toJS*(ctx: JSContextRef; n: int): JSValueRef =
  JSValueMakeNumber(ctx, cdouble(n))

proc toJS*(ctx: JSContextRef; f: float): JSValueRef =
  JSValueMakeNumber(ctx, cdouble(f))

proc toJS*(ctx: JSContextRef; b: bool): JSValueRef =
  JSValueMakeBoolean(ctx, b)

proc throwError*(ctx: JSContextRef; msg: string;
    exception: ptr JSValueRef) =
  ## Throws a JS Error with msg. Returns nil for convenience.
  if exception == nil:
    return
  var ex: JSValueRef = nil
  let text = toJS(ctx, msg)
  let err = JSObjectMakeError(ctx, 1, unsafeAddr text, addr ex)
  if err != nil:
    exception[] = err

proc setPropChecked*(ctx: JSContextRef; obj: JSObjectRef; name: string;
    value: JSValueRef; fname: string; exception: ptr JSValueRef): bool =
  ## setProp with the std modules' throw contract: direct-result
  ## builders (no JsonNode middle layer) funnel every install through
  ## here so a failed property write throws instead of half-building.
  ## True on success, false + JS throw on failure.
  var ex: JSValueRef = nil
  setProp(ctx, obj, name, value, addr ex)
  if ex != nil:
    throwError(ctx, fname & ": could not convert result to JS", exception)
    return false
  true

when not defined(windows):
  type MmapBytesCtx = object
    ## Owned mapping behind a mmap-backed Uint8Array: freed by the
    ## JSC deallocator below, never touched after hand-off.
    mem: pointer
    size: int

  proc mmapBytesDealloc(bytes: pointer; ctx: pointer) {.cdecl.} =
    ## JSC bytes deallocator: unmaps and frees the context. Runs on GC
    ## (and even on failed construction), so it never raises and
    ## ignores errors.
    if ctx != nil:
      let c = cast[ptr MmapBytesCtx](ctx)
      if c.mem != nil and c.size > 0:
        discard posix.munmap(c.mem, c.size)
      dealloc(c)

proc copyBytesDealloc(bytes: pointer; ctx: pointer) {.cdecl.} =
  ## JSC bytes deallocator for heap copies (see toJSUint8Copy).
  if bytes != nil:
    dealloc(bytes)

proc toJSUint8Copy*(ctx: JSContextRef; s: string; name: string;
    exception: ptr JSValueRef): JSValueRef =
  ## Copies s into a heap buffer owned by the Uint8Array (freed on
  ## GC). Fallback for files mmap cannot cover (empty, pipes, proc).
  ## nil + JS throw on failure.
  var ex: JSValueRef = nil
  if s.len == 0:
    let arr = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array,
      0, addr ex)
    if ex != nil or arr == nil:
      throwError(ctx, name & ": could not convert result to JS",
        exception)
      return nil
    return arr
  let buf = alloc(s.len)
  copyMem(buf, unsafeAddr s[0], s.len)
  result = JSObjectMakeTypedArrayWithBytesNoCopy(ctx,
    kJSTypedArrayTypeUint8Array, buf, csize_t(s.len),
    copyBytesDealloc, nil, addr ex)
  if ex != nil or result == nil:
    throwError(ctx, name & ": could not convert result to JS",
      exception)
    return nil

when not defined(windows):
  proc toJSUint8Mmap*(ctx: JSContextRef; mem: pointer; byteLen: int;
      name: string; exception: ptr JSValueRef): JSValueRef =
    ## Wraps an mmap'd region as a Uint8Array, transferring ownership
    ## to JSC (munmap runs on GC). The caller must never touch mem or
    ## close the mapping afterwards, on success or failure (JSC runs
    ## the deallocator even when construction fails). nil + JS throw
    ## on failure.
    var ex: JSValueRef = nil
    if byteLen <= 0:
      let arr = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array,
        0, addr ex)
      if ex != nil or arr == nil:
        throwError(ctx, name & ": could not convert result to JS",
          exception)
        return nil
      return arr
    let c = cast[ptr MmapBytesCtx](create(MmapBytesCtx))
    c.mem = mem
    c.size = byteLen
    result = JSObjectMakeTypedArrayWithBytesNoCopy(ctx,
      kJSTypedArrayTypeUint8Array, mem, csize_t(byteLen),
      mmapBytesDealloc, c, addr ex)
    if ex != nil or result == nil:
      throwError(ctx, name & ": could not convert result to JS",
        exception)
      return nil

proc makeJSArray*(ctx: JSContextRef;
    vals: openArray[JSValueRef]): JSValueRef =
  ## Builds a JS array from refs. nil on creation failure; callers own
  ## fname/exception and report the throw (same contract as the
  ## inlined versions in yaml/toml/xml/diff/svg).
  var ex: JSValueRef = nil
  let arr =
    if vals.len > 0:
      JSObjectMakeArray(ctx, csize_t(vals.len), unsafeAddr vals[0],
        addr ex)
    else:
      JSObjectMakeArray(ctx, 0, nil, addr ex)
  if ex != nil:
    return nil
  arr

proc optSetStr*(ctx: JSContextRef; obj: JSObjectRef; key: string;
    v: Option[string]; fname: string;
    exception: ptr JSValueRef): bool =
  ## Optional string install for direct-result builders: absent
  ## options stay absent. True on success (or absence), false + JS
  ## throw on failure.
  if v.isNone:
    return true
  setPropChecked(ctx, obj, key, toJS(ctx, v.get()), fname, exception)

proc optSetInt*(ctx: JSContextRef; obj: JSObjectRef; key: string;
    v: Option[int]; fname: string; exception: ptr JSValueRef): bool =
  ## Optional integer install, same contract as optSetStr.
  if v.isNone:
    return true
  setPropChecked(ctx, obj, key, toJS(ctx, v.get()), fname, exception)

proc checkArity*(argumentCount: csize_t; wantMin, wantMax: int;
    name: string; ctx: JSContextRef;
    exception: ptr JSValueRef; usage: string = ""): bool =
  ## Validates arg count, throwing a JS Error on mismatch. `usage` is
  ## appended to the message when provided (the `init` macro fills it
  ## from the member's `##` doc comment).
  let n = int(argumentCount)
  if n < wantMin or n > wantMax:
    var msg = name & ": expected "
    if wantMin == wantMax:
      msg &= $wantMin & " argument(s), got " & $n
    else:
      msg &= $wantMin & "-" & $wantMax & " argument(s), got " & $n
    if usage.len > 0:
      msg &= "\n" & usage
    throwError(ctx, msg, exception)
    return false
  true

proc checkArityMin*(argumentCount: csize_t; wantMin: int;
    name: string; ctx: JSContextRef;
    exception: ptr JSValueRef; usage: string = ""): bool =
  ## Lower-bound-only arity check for variadic tails (see RestArgs).
  ## Same message shape as checkArity ("expected at least N").
  let n = int(argumentCount)
  if n < wantMin:
    var msg = name & ": expected at least " & $wantMin &
      " argument(s), got " & $n
    if usage.len > 0:
      msg &= "\n" & usage
    throwError(ctx, msg, exception)
    return false
  true

type
  JsArgKind* = enum
    ## Declared `registerFn` parameter kinds. The macro maps the written
    ## type name to one of these at compile time; anything else is a
    ## build error. Valid type names: string, int, int64, float, bool,
    ## NimValue, JSObjectRef, JSValueRef, RestArgs.
    jakString    ## string: strict JS string
    jakInt       ## int/int64: integral number (integral floats accepted)
    jakFloat     ## float: any number, ints widen
    jakBool      ## bool: strict boolean
    jakNimValue  ## NimValue: eager snapshot of anything
    jakObject    ## JSObjectRef: live object ref, arrays rejected
    jakRaw       ## JSValueRef: live ref, unchecked (overload dispatch,
                 ## JS coercion passthrough)
    jakRest      ## RestArgs: remaining raw refs (variadic tail, last only)

  RestArgs* = seq[JSValueRef]
    ## Declared type of a variadic tail parameter.

proc jsDocBlock*(doc: string): string =
  ## Renders leading `##` doc lines as a JSDoc block for error output,
  ## "" when there is no doc. Thrown type errors carry this first so
  ## the CLI prints full context.
  if doc.strip().len == 0:
    return ""
  result = "/*"
  for line in doc.splitLines():
    let t = line.strip()
    if t.len == 0:
      result &= "\n *"
    else:
      result &= "\n * " & t
  result &= "\n */"

proc throwTypeMismatch*(ctx: JSContextRef; fname, pname, actual, want,
    docBlock: string; exception: ptr JSValueRef) =
  ## Throws `type mismatch parameter: ...` with the JSDoc block first
  ## (user format). Without docs the function name prefixes instead so
  ## the error still names its owner.
  var msg = ""
  if docBlock.len > 0:
    msg = docBlock & "\n"
  else:
    msg = fname & ": "
  msg &= "type mismatch parameter: `" & pname & "`. Got `" & actual &
    "`, expected `" & want & "`"
  throwError(ctx, msg, exception)

const maxNimValueDepth = 64
const maxNimValueArrayLen = 100_000

const maxDumpDepth* = 64
  ## Nesting cap for direct JS -> native-tree walkers (yaml, toml,
  ## xml, ...). Same contract as the snapshot cap: anything deeper
  ## throws instead of recursing forever on circular input.

proc jsSkipped*(ctx: JSContextRef; v: JSValueRef): bool =
  ## JSON holes for serializers: undefined, symbols, and functions are
  ## dropped from objects and read back as null in arrays.
  let t = JSValueGetType(ctx, v)
  t == kJSTypeUndefined or t == kJSTypeSymbol or
    (t == kJSTypeObject and JSObjectIsFunction(ctx, v))


proc jsonToJS*(ctx: JSContextRef; node: JsonNode): JSValueRef =
  ## Parses $node as JSON into a fresh JS value. nil on failure
  ## (only when $node is not valid JSON, e.g. NaN payloads).
  let s = $node
  let jsStr = newJSString(s)
  defer: JSStringRelease(jsStr)
  JSValueMakeFromJSONString(ctx, jsStr)

proc jsonNodeToJS*(ctx: JSContextRef; node: JsonNode): JSValueRef =
  ## JsonNode -> live JS value in one walk, no string round trip
  ## (the $stringify + JSC re-parse that jsonToJS does). nil only when
  ## an array/object fails to install. Note: JFloat NaN/Inf becomes a
  ## JS NaN/Infinity number; jsonToJS threw on those instead. Parsers
  ## never produce non-finite floats, so this only matters for
  ## hand-built trees.
  case node.kind
  of JNull:
    JSValueMakeNull(ctx)
  of JBool:
    JSValueMakeBoolean(ctx, node.getBool())
  of JInt:
    JSValueMakeNumber(ctx, cdouble(node.getBiggestInt()))
  of JFloat:
    JSValueMakeNumber(ctx, cdouble(node.getFloat()))
  of JString:
    toJS(ctx, node.getStr())
  of JArray:
    var vals: seq[JSValueRef] = @[]
    for item in node:
      let j = jsonNodeToJS(ctx, item)
      if j == nil:
        return nil
      vals.add(j)
    makeJSArray(ctx, vals)
  of JObject:
    let obj = newObject(ctx)
    var ex: JSValueRef = nil
    for k, v in node.pairs:
      let j = jsonNodeToJS(ctx, v)
      if j == nil:
        return nil
      setProp(ctx, obj, k, j, addr ex)
      if ex != nil:
        return nil
    obj

proc jsToJson*(ctx: JSContextRef; value: JSValueRef;
    err: var string): JsonNode =
  ## JSON.stringify(value), parsed with openparser. nil + err message
  ## on failure (circular structures, BigInt, undefined).
  var ex: JSValueRef = nil
  let jsStr = JSValueCreateJSONString(ctx, value, 0, addr ex)
  if jsStr == nil:
    err = "value is not JSON-serializable"
    return nil
  defer: JSStringRelease(jsStr)
  try:
    fromJson($jsStr)
  except CatchableError as e:
    err = e.msg
    nil

proc jsToJsonNodeImpl(ctx: JSContextRef; v: JSValueRef; depth: int;
    err: var string): JsonNode =
  ## One-walk JS -> JsonNode with jsToJson's observable semantics:
  ## JSON holes (undefined/symbol/function dropped from objects, null
  ## in arrays), bigints and circular input throw, integrals become
  ## JInt. No string conversions anywhere.
  if v == nil:
    err = "is null"
    return nil
  if depth > maxNimValueDepth:
    err = "is too deeply nested or circular"
    return nil
  if jsSkipped(ctx, v):
    err = "value is not JSON-serializable"
    return nil
  case JSValueGetType(ctx, v)
  of kJSTypeNull:
    result = newJNull()
  of kJSTypeBoolean:
    result = %JSValueToBoolean(ctx, v)
  of kJSTypeNumber:
    var ex: JSValueRef = nil
    let f = JSValueToNumber(ctx, v, addr ex)
    if ex != nil:
      err = "is not a number"
      return nil
    if f == trunc(f) and abs(f) < 9223372036854775808.0:
      result = %int64(f)
    else:
      result = %f
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      err = "is not convertible to string"
      return nil
    defer: JSStringRelease(s)
    result = %($s)
  of kJSTypeBigInt:
    err = "value is not JSON-serializable"
    return nil
  of kJSTypeUndefined, kJSTypeSymbol:
    err = "value is not JSON-serializable"
    return nil
  of kJSTypeObject:
    if JSValueIsArray(ctx, v):
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
      if ex != nil or lenV == nil:
        err = "has an unreadable length"
        return nil
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        err = "has an unreadable length"
        return nil
      result = newJArray()
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx),
          addr eEx)
        if eEx != nil or item == nil:
          err = "has an unreadable index " & $idx
          return nil
        if jsSkipped(ctx, item):
          result.add(newJNull())
        else:
          let nv = jsToJsonNodeImpl(ctx, item, depth + 1, err)
          if err != "":
            return nil
          result.add(nv)
    elif JSObjectIsFunction(ctx, v):
      err = "value is not JSON-serializable"
      return nil
    else:
      let names = JSObjectCopyPropertyNames(ctx, v)
      if names == nil:
        err = "has unreadable properties"
        return nil
      defer: JSPropertyNameArrayRelease(names)
      result = newJObject()
      let count = int(JSPropertyNameArrayGetCount(names))
      for idx in 0 ..< count:
        let jsName =
          JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
        let key = $jsName
        var pEx: JSValueRef = nil
        let prop = JSObjectGetProperty(ctx, v, jsName, addr pEx)
        if pEx != nil or prop == nil:
          err = "has an unreadable property \"" & key & "\""
          return nil
        if jsSkipped(ctx, prop):
          continue
        let nv = jsToJsonNodeImpl(ctx, prop, depth + 1, err)
        if err != "":
          return nil
        result[key] = nv

proc jsToJsonNode*(ctx: JSContextRef; value: JSValueRef;
    err: var string): JsonNode =
  ## Direct JS -> JsonNode without the stringify + re-parse round
  ## trip. Same contract as jsToJson: JsonNode + "" on success, nil +
  ## err message on failure.
  err = ""
  jsToJsonNodeImpl(ctx, value, 0, err)

proc returnJson*(ctx: JSContextRef; node: JsonNode; name: string;
    exception: ptr JSValueRef): JSValueRef =
  ## jsonToJS with a JS throw on failure. nil on failure.
  let v = jsonToJS(ctx, node)
  if v == nil:
    throwError(ctx, name & ": could not convert result to JS", exception)
    return nil
  v

proc stripNulls*(node: JsonNode): JsonNode =
  ## Drops object fields whose value is JNull (options that were none).
  ## Array elements are kept as-is. Returns a fresh tree.
  case node.kind
  of JObject:
    result = newJObject()
    for k, v in node.pairs:
      if v.kind != JNull:
        result[k] = stripNulls(v)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(stripNulls(item))
  else:
    result = node

proc propToJS*(ctx: JSContextRef; v: string): JSValueRef =
  ## `module.property` value conversion. Anything outside these
  ## overloads fails to compile at the `property` line.
  toJS(ctx, v)

proc propToJS*(ctx: JSContextRef; v: int): JSValueRef =
  toJS(ctx, v)

proc propToJS*(ctx: JSContextRef; v: int64): JSValueRef =
  toJS(ctx, v)

proc propToJS*(ctx: JSContextRef; v: float): JSValueRef =
  toJS(ctx, v)

proc propToJS*(ctx: JSContextRef; v: bool): JSValueRef =
  toJS(ctx, v)

proc propToJS*(ctx: JSContextRef; v: JsonNode): JSValueRef =
  let r = jsonToJS(ctx, v)
  if r == nil:
    jsonToJS(ctx, newJNull())
  else:
    r

type
  NimValueKind* = enum
    ## JS-facing value kinds. Numbers split: integral doubles become
    ## nvkInt (within ±2^53), the rest nvkFloat (incl. NaN/Infinity,
    ## which JSON cannot represent but JSC can).
    nvkUndefined, nvkNull, nvkBool, nvkInt, nvkFloat, nvkString,
    nvkArray, nvkObject, nvkFunction, nvkSymbol, nvkBigInt

  NimValue* = object
    ## An eager snapshot of a JS value. Primitives, arrays and plain
    ## objects are deep-copied into Nim data; functions, symbols and
    ## bigints keep the borrowed `raw` ref, valid only for the duration
    ## of the callback that produced it (callers that retain must
    ## JSValueProtect separately, as std/http does for handlers).
    case kind*: NimValueKind
    of nvkUndefined, nvkNull: discard
    of nvkBool: b*: bool
    of nvkInt: i*: int64
    of nvkFloat: f*: float
    of nvkString: s*: string
    of nvkArray: arr*: seq[NimValue]
    of nvkObject: obj*: OrderedTable[string, NimValue]
    of nvkFunction, nvkSymbol, nvkBigInt: raw*: JSValueRef

proc jsTypeName*(kind: NimValueKind): string =
  ## JS-style type name for error messages.
  case kind
  of nvkUndefined: "undefined"
  of nvkNull: "null"
  of nvkBool: "boolean"
  of nvkInt, nvkFloat: "number"
  of nvkString: "string"
  of nvkArray, nvkObject: "object"
  of nvkFunction: "function"
  of nvkSymbol: "symbol"
  of nvkBigInt: "bigint"

proc fromJSImpl(ctx: JSContextRef; v: JSValueRef; depth: int;
    err: var string): NimValue =
  if v == nil:
    err = "is null"
    return NimValue(kind: nvkUndefined)
  if depth > maxNimValueDepth:
    err = "is too deeply nested or circular"
    return NimValue(kind: nvkUndefined)
  case JSValueGetType(ctx, v)
  of kJSTypeUndefined:
    result = NimValue(kind: nvkUndefined)
  of kJSTypeNull:
    result = NimValue(kind: nvkNull)
  of kJSTypeBoolean:
    result = NimValue(kind: nvkBool, b: JSValueToBoolean(ctx, v))
  of kJSTypeNumber:
    var ex: JSValueRef = nil
    let f = JSValueToNumber(ctx, v, addr ex)
    if ex != nil:
      err = "is not a number"
      return NimValue(kind: nvkUndefined)
    if f == trunc(f) and f >= -9007199254740991.0 and
        f <= 9007199254740991.0:
      result = NimValue(kind: nvkInt, i: int64(f))
    else:
      result = NimValue(kind: nvkFloat, f: f)
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      err = "is not convertible to string"
      return NimValue(kind: nvkUndefined)
    defer: JSStringRelease(s)
    result = NimValue(kind: nvkString, s: $s)
  of kJSTypeSymbol:
    result = NimValue(kind: nvkSymbol, raw: v)
  of kJSTypeBigInt:
    result = NimValue(kind: nvkBigInt, raw: v)
  of kJSTypeObject:
    if JSValueIsArray(ctx, v):
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
      if ex != nil or lenV == nil:
        err = "has an unreadable length"
        return NimValue(kind: nvkUndefined)
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        err = "has an unreadable length"
        return NimValue(kind: nvkUndefined)
      if n > maxNimValueArrayLen:
        err = "array is too large (" & $n & " elements, cap " &
          $maxNimValueArrayLen & ")"
        return NimValue(kind: nvkUndefined)
      result = NimValue(kind: nvkArray, arr: @[])
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx), addr eEx)
        if eEx != nil or item == nil:
          err = "has an unreadable index " & $idx
          return NimValue(kind: nvkUndefined)
        let nv = fromJSImpl(ctx, item, depth + 1, err)
        if err != "":
          return NimValue(kind: nvkUndefined)
        result.arr.add(nv)
    elif JSObjectIsFunction(ctx, v):
      result = NimValue(kind: nvkFunction, raw: v)
    else:
      let names = JSObjectCopyPropertyNames(ctx, v)
      if names == nil:
        err = "has unreadable properties"
        return NimValue(kind: nvkUndefined)
      defer: JSPropertyNameArrayRelease(names)
      result = NimValue(kind: nvkObject,
        obj: initOrderedTable[string, NimValue]())
      let count = int(JSPropertyNameArrayGetCount(names))
      for idx in 0 ..< count:
        let jsName = JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
        let key = $jsName
        var pEx: JSValueRef = nil
        let prop = JSObjectGetProperty(ctx, v, jsName, addr pEx)
        if pEx != nil or prop == nil:
          err = "has an unreadable property \"" & key & "\""
          return NimValue(kind: nvkUndefined)
        let nv = fromJSImpl(ctx, prop, depth + 1, err)
        if err != "":
          return NimValue(kind: nvkUndefined)
        result.obj[key] = nv

proc fromJS*(ctx: JSContextRef; v: JSValueRef;
    err: var string): NimValue =
  ## Eager snapshot of a JS value. NimValue + "" on success, err message
  ## set on failure (return value is undefined then).
  err = ""
  fromJSImpl(ctx, v, 0, err)

proc toJS*(ctx: JSContextRef; v: NimValue): JSValueRef =
  ## Builds a fresh JS value from a snapshot. nil on failure (only when
  ## a nested object property fails to install). Function/symbol/bigint
  ## return the borrowed ref they were snapshotted from.
  case v.kind
  of nvkUndefined:
    JSValueMakeUndefined(ctx)
  of nvkNull:
    JSValueMakeNull(ctx)
  of nvkBool:
    JSValueMakeBoolean(ctx, v.b)
  of nvkInt:
    JSValueMakeNumber(ctx, cdouble(v.i))
  of nvkFloat:
    JSValueMakeNumber(ctx, cdouble(v.f))
  of nvkString:
    let jsStr = newJSString(v.s)
    defer: JSStringRelease(jsStr)
    JSValueMakeString(ctx, jsStr)
  of nvkArray:
    var vals: seq[JSValueRef] = @[]
    for item in v.arr:
      let j = toJS(ctx, item)
      if j == nil:
        return nil
      vals.add(j)
    var ex: JSValueRef = nil
    let arr =
      if vals.len > 0:
        JSObjectMakeArray(ctx, csize_t(vals.len), addr vals[0], addr ex)
      else:
        JSObjectMakeArray(ctx, 0, nil, addr ex)
    if ex != nil:
      nil
    else:
      arr
  of nvkObject:
    let obj = newObject(ctx)
    var ex: JSValueRef = nil
    for k, item in v.obj.pairs:
      let j = toJS(ctx, item)
      if j == nil:
        return nil
      setProp(ctx, obj, k, j, addr ex)
      if ex != nil:
        return nil
    obj
  of nvkFunction, nvkSymbol, nvkBigInt:
    v.raw

proc nimArg*(ctx: JSContextRef; args: ptr UncheckedArray[JSValueRef];
    i: int; name: string; exception: ptr JSValueRef;
    val: var NimValue; prefix = ""): bool =
  ## Reads arg i as a NimValue snapshot. False + JS throw on failure.
  ## `prefix` (the JSDoc block + newline, emitted by the macro) goes
  ## first so the CLI prints full context.
  var err = ""
  if args[i] == nil:
    err = "is missing"
  else:
    val = fromJS(ctx, args[i], err)
  if err != "":
    throwError(ctx, prefix & name & ": argument " & $i & " " & err,
      exception)
    return false
  true

proc jsKindName*(ctx: JSContextRef; v: JSValueRef): string =
  ## jsTypeName for live refs (used in objArg type errors).
  if v == nil:
    return "null"
  case JSValueGetType(ctx, v)
  of kJSTypeUndefined: "undefined"
  of kJSTypeNull: "null"
  of kJSTypeBoolean: "boolean"
  of kJSTypeNumber: "number"
  of kJSTypeString: "string"
  of kJSTypeSymbol: "symbol"
  of kJSTypeBigInt: "bigint"
  of kJSTypeObject:
    if JSValueIsArray(ctx, v): "array"
    elif JSObjectIsFunction(ctx, v): "function"
    else: "object"

proc objRefCheck*(ctx: JSContextRef; v: JSValueRef; fname, pname,
    docBlock: string; exception: ptr JSValueRef): bool =
  ## Object check on a live ref for macro-generated `JSObjectRef`
  ## params (arrays rejected, like objArg). False + JS throw with the
  ## JSDoc-first mismatch on failure.
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      JSValueIsArray(ctx, v):
    throwTypeMismatch(ctx, fname, pname, jsKindName(ctx, v), "object",
      docBlock, exception)
    return false
  true

proc objArg*(ctx: JSContextRef; args: ptr UncheckedArray[JSValueRef];
    i: int; name: string; exception: ptr JSValueRef;
    obj: var JSValueRef): bool =
  ## Borrows arg i as an object ref for lazy field access. No snapshot:
  ## fields are converted on demand via getField. Arrays are rejected
  ## (options bags are plain objects). False + JS throw on failure.
  if args[i] == nil:
    throwError(ctx, name & ": argument " & $i & " is missing", exception)
    return false
  if JSValueGetType(ctx, args[i]) != kJSTypeObject or
      JSValueIsArray(ctx, args[i]):
    throwError(ctx, name & ": argument " & $i & " expected object, got " &
      jsKindName(ctx, args[i]), exception)
    return false
  obj = args[i]
  true

proc getField*(ctx: JSContextRef; obj: JSValueRef; key: string;
    err: var string): NimValue =
  ## Converts a single property. Missing (or explicit `undefined`)
  ## yields nvkUndefined with empty err, so readers treat absent and
  ## undefined alike. err is set only on real failures (throwing getter,
  ## unreadable nested value).
  err = ""
  if obj == nil or JSValueGetType(ctx, obj) != kJSTypeObject:
    err = "not an object"
    return NimValue(kind: nvkUndefined)
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  if ex != nil or prop == nil:
    return NimValue(kind: nvkUndefined)
  fromJS(ctx, prop, err)

proc asString*(v: NimValue; what: string): string =
  ## Strict string getter. Raises (callers turn it into a JS throw).
  if v.kind != nvkString:
    raise newException(CatchableError,
      what & ": expected string, got " & jsTypeName(v.kind))
  v.s

proc asBool*(v: NimValue; what: string): bool =
  if v.kind != nvkBool:
    raise newException(CatchableError,
      what & ": expected boolean, got " & jsTypeName(v.kind))
  v.b

proc asInt*(v: NimValue; what: string): int64 =
  ## Integral numbers only; floats must be integral and in int64 range.
  case v.kind
  of nvkInt:
    v.i
  of nvkFloat:
    if v.f == trunc(v.f) and v.f >= -9007199254740991.0 and
        v.f <= 9007199254740991.0:
      int64(v.f)
    else:
      raise newException(CatchableError,
        what & ": expected integer, got non-integral number")
  else:
    raise newException(CatchableError,
      what & ": expected integer, got " & jsTypeName(v.kind))

proc asFloat*(v: NimValue; what: string): float =
  ## Ints widen; anything else raises.
  case v.kind
  of nvkFloat:
    v.f
  of nvkInt:
    float(v.i)
  else:
    raise newException(CatchableError,
      what & ": expected number, got " & jsTypeName(v.kind))

proc asArray*(v: NimValue; what: string): seq[NimValue] =
  if v.kind != nvkArray:
    raise newException(CatchableError,
      what & ": expected array, got " & jsTypeName(v.kind))
  v.arr

proc asObject*(v: NimValue; what: string): OrderedTable[string, NimValue] =
  if v.kind != nvkObject:
    raise newException(CatchableError,
      what & ": expected object, got " & jsTypeName(v.kind))
  v.obj

proc hasKey*(v: NimValue; key: string): bool =
  ## True when v is an object holding key.
  v.kind == nvkObject and v.obj.hasKey(key)

proc get*(v: NimValue; key: string; what: string): NimValue =
  ## Object field access. Raises on wrong kind or missing key.
  if v.kind != nvkObject:
    raise newException(CatchableError,
      what & ": expected object, got " & jsTypeName(v.kind))
  if not v.obj.hasKey(key):
    raise newException(CatchableError,
      what & ": missing \"" & key & "\"")
  v.obj[key]

proc getOpt*(v: NimValue; key: string; default: NimValue): NimValue =
  ## Missing keys (or non-objects) yield default instead of raising.
  if v.kind == nvkObject and v.obj.hasKey(key):
    v.obj[key]
  else:
    default

proc strField*(ctx: JSContextRef; v: NimValue; key, name: string;
    exception: ptr JSValueRef; val: var string): bool =
  ## Required string field. False + JS throw on failure.
  if v.kind != nvkObject:
    throwError(ctx, name & ": expected object, got " & jsTypeName(v.kind),
      exception)
    return false
  if not v.obj.hasKey(key):
    throwError(ctx, name & ": missing \"" & key & "\"", exception)
    return false
  let f = v.obj[key]
  if f.kind != nvkString:
    throwError(ctx, name & ": \"" & key & "\" must be a string, got " &
      jsTypeName(f.kind), exception)
    return false
  val = f.s
  true

proc numField*(ctx: JSContextRef; v: NimValue; key, name: string;
    exception: ptr JSValueRef; val: var float): bool =
  ## Required numeric field (ints widen). False + JS throw on failure.
  if v.kind != nvkObject:
    throwError(ctx, name & ": expected object, got " & jsTypeName(v.kind),
      exception)
    return false
  if not v.obj.hasKey(key):
    throwError(ctx, name & ": missing \"" & key & "\"", exception)
    return false
  let f = v.obj[key]
  case f.kind
  of nvkInt:
    val = float(f.i)
  of nvkFloat:
    val = f.f
  else:
    throwError(ctx, name & ": \"" & key & "\" must be a number, got " &
      jsTypeName(f.kind), exception)
    return false
  true

proc boolField*(ctx: JSContextRef; v: NimValue; key, name: string;
    exception: ptr JSValueRef; val: var bool): bool =
  ## Required boolean field. False + JS throw on failure.
  if v.kind != nvkObject:
    throwError(ctx, name & ": expected object, got " & jsTypeName(v.kind),
      exception)
    return false
  if not v.obj.hasKey(key):
    throwError(ctx, name & ": missing \"" & key & "\"", exception)
    return false
  let f = v.obj[key]
  if f.kind != nvkBool:
    throwError(ctx, name & ": \"" & key & "\" must be a boolean, got " &
      jsTypeName(f.kind), exception)
    return false
  val = f.b
  true

proc toJsonNode*(v: NimValue): JsonNode =
  ## Converts a snapshot to the format funnel. Raises on kinds JSON
  ## cannot represent (undefined, functions, symbols, bigints,
  ## NaN/Infinity) — the same inputs jsToJson rejects today.
  case v.kind
  of nvkNull:
    result = newJNull()
  of nvkBool:
    result = %v.b
  of nvkInt:
    result = %v.i
  of nvkFloat:
    if v.f.classify in {fcNaN, fcInf, fcNegInf}:
      raise newException(CatchableError,
        "value is not JSON-serializable (NaN/Infinity)")
    result = %v.f
  of nvkString:
    result = %v.s
  of nvkArray:
    result = newJArray()
    for item in v.arr:
      result.add(toJsonNode(item))
  of nvkObject:
    result = newJObject()
    for k, item in v.obj.pairs:
      result[k] = toJsonNode(item)
  of nvkUndefined, nvkFunction, nvkSymbol, nvkBigInt:
    raise newException(CatchableError,
      "value is not JSON-serializable (" & jsTypeName(v.kind) & ")")

proc fromJsonNode*(n: JsonNode): NimValue =
  ## Converts the format funnel back to a snapshot.
  case n.kind
  of JNull:
    result = NimValue(kind: nvkNull)
  of JBool:
    result = NimValue(kind: nvkBool, b: n.getBool())
  of JInt:
    result = NimValue(kind: nvkInt, i: int64(n.getInt()))
  of JFloat:
    result = NimValue(kind: nvkFloat, f: n.getFloat())
  of JString:
    result = NimValue(kind: nvkString, s: n.getStr())
  of JArray:
    result = NimValue(kind: nvkArray, arr: @[])
    for item in n:
      result.arr.add(fromJsonNode(item))
  of JObject:
    result = NimValue(kind: nvkObject,
      obj: initOrderedTable[string, NimValue]())
    for k, item in n.pairs:
      result.obj[k] = fromJsonNode(item)

proc readBytesParam*(ctx: JSContextRef; v: JSValueRef; fname, pname,
    docBlock: string; exception: ptr JSValueRef;
    dst: var string): bool =
  ## Reads a live value as bytes: JS strings contribute their UTF-8
  ## bytes, Uint8Array/Uint8ClampedArray views and ArrayBuffers are
  ## copied out immediately (the JSC pointer is temporary and may not
  ## survive further JS calls). Anything else throws the JSDoc-first
  ## type mismatch, like the macro's checked params. Snapshots
  ## (NimValue) are deliberately avoided here: a Uint8Array would walk
  ## per byte. False + JS throw on failure.
  if v == nil:
    throwTypeMismatch(ctx, fname, pname, "null", "string or Uint8Array",
      docBlock, exception)
    return false
  case JSValueGetType(ctx, v)
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if ex != nil or s == nil:
      throwError(ctx, fname & ": `" & pname &
        "` is not convertible to string", exception)
      return false
    defer: JSStringRelease(s)
    dst = $s
    true
  of kJSTypeObject:
    if JSObjectIsFunction(ctx, v):
      throwTypeMismatch(ctx, fname, pname, "function",
        "string or Uint8Array", docBlock, exception)
      return false
    let o = cast[JSObjectRef](v)
    var tex: JSValueRef = nil
    let t = JSValueGetTypedArrayType(ctx, v, addr tex)
    if tex != nil:
      throwError(ctx, fname & ": `" & pname & "` is unreadable",
        exception)
      return false
    var n = 0
    var p: pointer = nil
    case t
    of kJSTypedArrayTypeUint8Array, kJSTypedArrayTypeUint8ClampedArray:
      var lex: JSValueRef = nil
      n = int(JSObjectGetTypedArrayByteLength(ctx, o, addr lex))
      if lex != nil or n < 0:
        throwError(ctx, fname & ": `" & pname & "` is unreadable",
          exception)
        return false
      if n > 0:
        var pex: JSValueRef = nil
        p = JSObjectGetTypedArrayBytesPtr(ctx, o, addr pex)
        if pex != nil or p == nil:
          throwError(ctx, fname & ": `" & pname & "` is detached",
            exception)
          return false
    of kJSTypedArrayTypeArrayBuffer:
      var lex: JSValueRef = nil
      n = int(JSObjectGetArrayBufferByteLength(ctx, o, addr lex))
      if lex != nil or n < 0:
        throwError(ctx, fname & ": `" & pname & "` is unreadable",
          exception)
        return false
      if n > 0:
        var pex: JSValueRef = nil
        p = JSObjectGetArrayBufferBytesPtr(ctx, o, addr pex)
        if pex != nil or p == nil:
          throwError(ctx, fname & ": `" & pname & "` is detached",
            exception)
          return false
    else:
      throwTypeMismatch(ctx, fname, pname, jsKindName(ctx, v),
        "string or Uint8Array", docBlock, exception)
      return false
    dst = newString(n)
    if n > 0:
      copyMem(addr dst[0], p, n)
    true
  else:
    throwTypeMismatch(ctx, fname, pname, jsKindName(ctx, v),
      "string or Uint8Array", docBlock, exception)
    false

proc sanitizeUTF8*(s: string): string =
  ## Copies s, replacing malformed UTF-8 with U+FFFD (WHATWG-style).
  ## JSC string creation fails on invalid input (nil JSString), which
  ## turns into dropped values or rejected fetches downstream — never
  ## pass wire bytes to newJSString unsanitized. Overlongs, surrogates
  ## and codepoints past U+10FFFF count as malformed, like WebKit.
  result = newStringOfCap(s.len)
  var i = 0
  template bad() =
    result.add("\xEF\xBF\xBD")
    inc i
  while i < s.len:
    let b = s[i].uint8
    if b < 0x80'u8:
      result.add(s[i])
      inc i
    else:
      var need = 0
      var lo, hi: uint8
      if b in 0xC2'u8 .. 0xDF'u8:
        need = 1
        lo = 0x80'u8; hi = 0xBF'u8
      elif b in 0xE0'u8 .. 0xEF'u8:
        need = 2
        lo = 0x80'u8; hi = 0xBF'u8
        if b == 0xE0'u8: lo = 0xA0'u8
        elif b == 0xED'u8: hi = 0x9F'u8
      elif b in 0xF0'u8 .. 0xF4'u8:
        need = 3
        lo = 0x80'u8; hi = 0xBF'u8
        if b == 0xF0'u8: lo = 0x90'u8
        elif b == 0xF4'u8: hi = 0x8F'u8
      else:
        bad()
        continue
      if i + need >= s.len:
        bad()
        continue
      var ok = true
      for k in 1 .. need:
        let c = s[i + k].uint8
        if k == 1:
          if c < lo or c > hi:
            ok = false
            break
        elif c < 0x80'u8 or c > 0xBF'u8:
          ok = false
          break
      if not ok:
        bad()
        continue
      for k in 0 .. need:
        result.add(s[i + k])
      i += need + 1

proc strArg*(ctx: JSContextRef; args: ptr UncheckedArray[JSValueRef];
    i: int; name: string; exception: ptr JSValueRef;
    val: var string): bool =
  ## Reads arg i as a string (strict: non-strings throw a type error).
  ## False + JS throw on failure.
  var v: NimValue
  if not nimArg(ctx, args, i, name, exception, v):
    return false
  try:
    val = v.asString(name)
    true
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    false

proc numArg*(ctx: JSContextRef; args: ptr UncheckedArray[JSValueRef];
    i: int; name: string; exception: ptr JSValueRef;
    val: var float): bool =
  ## Reads arg i as a number (strict: ints widen, non-numbers throw).
  ## False + JS throw on failure.
  var v: NimValue
  if not nimArg(ctx, args, i, name, exception, v):
    return false
  try:
    val = v.asFloat(name)
    true
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    false

proc boolArg*(ctx: JSContextRef; args: ptr UncheckedArray[JSValueRef];
    i: int; name: string; exception: ptr JSValueRef;
    val: var bool): bool =
  ## Reads arg i as a boolean (strict). False + JS throw on failure.
  var v: NimValue
  if not nimArg(ctx, args, i, name, exception, v):
    return false
  try:
    val = v.asBool(name)
    true
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    false

proc stringParam*(ctx: JSContextRef; v: NimValue; fname, pname,
    docBlock: string; exception: ptr JSValueRef;
    val: var string): bool =
  ## Strict string check on a snapshot, throwing the JSDoc-first type
  ## mismatch on failure. Emitted by the macro for `name: string`.
  try:
    val = v.asString(fname)
    true
  except CatchableError:
    throwTypeMismatch(ctx, fname, pname, jsTypeName(v.kind), "string",
      docBlock, exception)
    false

proc intParam*(ctx: JSContextRef; v: NimValue; fname, pname,
    docBlock: string; exception: ptr JSValueRef;
    val: var int64): bool =
  ## Integral-number check on a snapshot (integral floats accepted,
  ## mirroring asInt). Emitted by the macro for `name: int`.
  try:
    val = v.asInt(fname)
    true
  except CatchableError:
    throwTypeMismatch(ctx, fname, pname, jsTypeName(v.kind), "integer",
      docBlock, exception)
    false

proc floatParam*(ctx: JSContextRef; v: NimValue; fname, pname,
    docBlock: string; exception: ptr JSValueRef;
    val: var float): bool =
  ## Number check on a snapshot (ints widen). Emitted by the macro
  ## for `name: float`.
  try:
    val = v.asFloat(fname)
    true
  except CatchableError:
    throwTypeMismatch(ctx, fname, pname, jsTypeName(v.kind), "number",
      docBlock, exception)
    false

proc boolParam*(ctx: JSContextRef; v: NimValue; fname, pname,
    docBlock: string; exception: ptr JSValueRef;
    val: var bool): bool =
  ## Strict boolean check on a snapshot. Emitted by the macro for
  ## `name: bool`.
  try:
    val = v.asBool(fname)
    true
  except CatchableError:
    throwTypeMismatch(ctx, fname, pname, jsTypeName(v.kind), "boolean",
      docBlock, exception)
    false

template exportObject*(body: untyped): untyped =
  ## Marker for member declarations inside `init`. Only `init`
  ## understands it; direct expansion is a compile error.
  {.error: "exportObject is only valid directly inside an init block" &
    " (if you are inside one, `init` is shadowed by another import:" &
    " qualify it or narrow the import)".}

type
  FnBindings = object
    ctxName: string
    ctxSym, functionSym, thisObjectSym: NimNode
    argcSym, argvSym, exSym, argsSym: NimNode

proc newBindings(ctxName: string): FnBindings =
  FnBindings(ctxName: ctxName, ctxSym: genSym(nskParam, ctxName),
    functionSym: genSym(nskParam, "function"),
    thisObjectSym: genSym(nskParam, "thisObject"),
    argcSym: genSym(nskParam, "argumentCount"),
    argvSym: genSym(nskParam, "arguments"),
    exSym: genSym(nskParam, "exception"),
    argsSym: genSym(nskLet, "args"))

const routineKinds = {nnkProcDef, nnkFuncDef, nnkMethodDef, nnkMacroDef,
  nnkTemplateDef, nnkIteratorDef, nnkConverterDef, nnkLambda}

proc substBody(n: NimNode; b: FnBindings): NimNode =
  ## Rewrites callback-body identifiers to the generated proc's gensyms.
  ## Nested routine definitions are left untouched (they cannot see the
  ## bindings). Dot selectors and named-arg keys are never rewritten.
  if n.kind == nnkIdent:
    if n.strVal == b.ctxName:
      return b.ctxSym
    case n.strVal
    of "function": return b.functionSym
    of "thisObject": return b.thisObjectSym
    of "argumentCount": return b.argcSym
    of "arguments": return b.argvSym
    of "exception": return b.exSym
    of "args": return b.argsSym
    else: return copy(n)
  if n.kind in routineKinds:
    return copy(n)
  result = copyNimNode(n)
  for i, child in n.pairs:
    if (n.kind == nnkDotExpr and i == 1) or
        (n.kind in {nnkExprColonExpr, nnkExprEqExpr} and i == 0):
      result.add(copy(child))
    else:
      result.add(substBody(child, b))

proc substModule(n: NimNode; mname: string; moduleSym: NimNode): NimNode =
  ## Rewrites the `init` module name to the generated module symbol in
  ## setup statements and property values (which run in install scope).
  if n.kind == nnkIdent:
    if n.strVal == mname:
      return moduleSym
    return copy(n)
  result = copyNimNode(n)
  for i, child in n.pairs:
    if (n.kind == nnkDotExpr and i == 1) or
        (n.kind in {nnkExprColonExpr, nnkExprEqExpr} and i == 0):
      result.add(copy(child))
    else:
      result.add(substModule(child, mname, moduleSym))

proc addErrorContext(n: NimNode; doc: string): NimNode =
  ## Appends the member doc (rendered as a JSDoc block) to every
  ## `throwError` message and passes it as `usage` to `checkArity`
  ## calls. Same traversal rules as substBody.
  let blockStr = jsDocBlock(doc)
  if blockStr.len == 0:
    return copy(n)
  if n.kind == nnkCall and n.len >= 4 and n[0].kind == nnkIdent and
      n[0].strVal == "throwError":
    result = copyNimNode(n)
    result.add(copy(n[0]))
    result.add(copy(n[1]))
    result.add(nnkInfix.newTree(newIdentNode("&"), copy(n[2]),
      newStrLitNode("\n" & blockStr)))
    for i in 3 ..< n.len:
      result.add(copy(n[i]))
    return
  if n.kind == nnkCall and n.len == 7 and n[0].kind == nnkIdent and
      n[0].strVal == "checkArity":
    result = copyNimNode(n)
    for child in n:
      result.add(copy(child))
    result.add(newStrLitNode(blockStr))
    return
  if n.kind in routineKinds:
    return copy(n)
  result = copyNimNode(n)
  for i, child in n.pairs:
    if (n.kind == nnkDotExpr and i == 1) or
        (n.kind in {nnkExprColonExpr, nnkExprEqExpr} and i == 0):
      result.add(copy(child))
    else:
      result.add(addErrorContext(child, doc))

type
  ParamSpec = tuple[name: string, kind: JsArgKind, hasDefault: bool,
    default: NimNode]
    ## One declared `registerFn` parameter, parsed at compile time.

const reservedParamNames = ["ctx", "function", "thisObject",
  "argumentCount", "arguments", "exception", "args", "docBlock"]

proc jsArgKindFromIdent(t: NimNode; fname, pname: string): JsArgKind =
  ## Maps a written type name to its kind. Anything else is a build
  ## error listing what is valid.
  if t.kind != nnkIdent:
    error("registerFn " & fname & ": parameter `" & pname &
      "` needs a plain type name", t)
  case t.strVal
  of "string": result = jakString
  of "int", "int64": result = jakInt
  of "float": result = jakFloat
  of "bool": result = jakBool
  of "NimValue": result = jakNimValue
  of "JSObjectRef": result = jakObject
  of "JSValueRef": result = jakRaw
  of "RestArgs": result = jakRest
  else:
    error("registerFn " & fname & ": unknown arg type '" & t.strVal &
      "' for `" & pname & "` (use string, int, float, bool, NimValue," &
      " JSObjectRef, JSValueRef or RestArgs)", t)

proc defaultExprFor(kind: JsArgKind): NimNode =
  ## Zero default for an optional parameter.
  case kind
  of jakString: result = newStrLitNode("")
  of jakInt:
    result = newNimNode(nnkInt64Lit)
    result.intVal = 0
  of jakFloat: result = newFloatLitNode(0.0)
  of jakBool: result = newIdentNode("false")
  of jakNimValue:
    result = nnkObjConstr.newTree(newIdentNode("NimValue"),
      nnkExprColonExpr.newTree(newIdentNode("kind"),
        newIdentNode("nvkUndefined")))
  of jakObject, jakRaw: result = newNilLit()
  of jakRest:
    result = nnkPrefix.newTree(newIdentNode("@"),
      newNimNode(nnkBracket))

proc paramVarType(kind: JsArgKind): NimNode =
  ## Declared Nim type of a generated parameter binding.
  case kind
  of jakString: newIdentNode("string")
  of jakInt: newIdentNode("int64")
  of jakFloat: newIdentNode("float")
  of jakBool: newIdentNode("bool")
  of jakNimValue: newIdentNode("NimValue")
  of jakObject, jakRaw: newIdentNode("JSValueRef")
  of jakRest: newIdentNode("RestArgs")

proc paramName(n: NimNode; fname: string): string =
  if n.kind != nnkIdent:
    error("registerFn " & fname & ": parameter name must be an " &
      "identifier", n)
  if n.strVal in reservedParamNames:
    error("registerFn " & fname & ": `" & n.strVal & "` is reserved" &
      " (callback binding)", n)
  n.strVal

proc parseOneParam(p: NimNode; fname: string): ParamSpec =
  ## One header entry: `name: Type` (required), `name?: Type`
  ## (optional, zero default) or `name: default(Type, value)`
  ## (optional, explicit default).
  if p.kind == nnkExprColonExpr and p.len >= 2:
    let nm = paramName(p[0], fname)
    if p[1].kind == nnkCall and p[1].len == 3 and
        p[1][0].kind == nnkIdent and p[1][0].strVal == "default":
      let k = jsArgKindFromIdent(p[1][1], fname, nm)
      if k == jakRest:
        error("registerFn " & fname & ": RestArgs takes no default", p)
      return (nm, k, true, copy(p[1][2]))
    return (nm, jsArgKindFromIdent(p[1], fname, nm), false, newNilLit())
  if p.kind == nnkInfix and p.len >= 3 and p[0].kind == nnkIdent and
      p[0].strVal == "?:" and p[1].kind == nnkIdent:
    let nm = paramName(p[1], fname)
    let k = jsArgKindFromIdent(p[2], fname, nm)
    if k == jakRest:
      error("registerFn " & fname & ": RestArgs is bare and last" &
        " (no `?` needed)", p)
    return (nm, k, true, defaultExprFor(k))
  error("registerFn " & fname & ": write each parameter as `name: Type`," &
    " `name?: Type` or `name: default(Type, value)`", p)

proc parseHeader(header: NimNode; what: string): tuple[fname: string,
    params: seq[ParamSpec]] =
  ## Normalizes a `registerFn` header. The command-position header
  ## parses as ObjConstr (colon-first params) or Call (`?`-first or
  ## `()` params); both carry the same entries. A bare name is a
  ## build error pointing at the typed form.
  if header.kind == nnkIdent:
    error(what & " expects declared arg types, e.g. `" & header.strVal &
      "(text: string)` (`" & header.strVal & "()` for zero args)", header)
  if header.kind in {nnkObjConstr, nnkCall} and header.len >= 1 and
      header[0].kind == nnkIdent:
    let fname = header[0].strVal
    var ps: seq[ParamSpec] = @[]
    for i in 1 ..< header.len:
      if header[i].kind == nnkEmpty:
        continue
      ps.add(parseOneParam(header[i], fname))
    var seenOptional = false
    var seenRest = false
    for p in ps:
      if p.kind == jakRest:
        if seenRest:
          error(what & " " & fname & ": only one RestArgs tail", header)
        seenRest = true
      elif p.hasDefault:
        seenOptional = true
      elif seenOptional:
        error(what & " " & fname & ": required `" & p.name &
          "` follows an optional parameter", header)
    if seenRest and ps[^1].kind != jakRest:
      error(what & " " & fname & ": RestArgs must be last", header)
    return (fname, ps)
  error(what & " expects `name(param: Type, ...)`", header)

proc guardNot(call: NimNode): NimNode =
  ## `if not <call>: return nil`.
  let retNil = newNimNode(nnkReturnStmt)
  retNil.add(newNilLit())
  nnkIfStmt.newTree(nnkElifBranch.newTree(
    nnkPrefix.newTree(newIdentNode("not"), call),
    newStmtList(retNil)))

proc emitSnapshot(body: NimNode; b: FnBindings; fname: string;
    idx: int; prefix: string; tmp: NimNode) =
  ## `var tmp: NimValue` + guarded `nimArg` snapshot.
  var sec = newNimNode(nnkVarSection)
  sec.add(newIdentDefs(tmp, newIdentNode("NimValue"), newEmptyNode()))
  body.add(sec)
  body.add(guardNot(newCall("nimArg", b.ctxSym, b.argsSym,
    newLit(idx), newStrLitNode(fname), b.exSym, tmp,
    newStrLitNode(prefix))))

proc checkedHelperFor(kind: JsArgKind): string =
  case kind
  of jakString: "stringParam"
  of jakInt: "intParam"
  of jakFloat: "floatParam"
  of jakBool: "boolParam"
  else: "stringParam"

proc emitCheckedAssign(body: NimNode; b: FnBindings; spec: ParamSpec;
    fname: string; idx: int; docBlock, prefix: string) =
  ## Snapshot + kind check assigning the visible binding. Used for
  ## required params directly and for optional params inside the
  ## presence guard.
  let snap = genSym(nskVar, "snap")
  emitSnapshot(body, b, fname, idx, prefix, snap)
  body.add(guardNot(newCall(checkedHelperFor(spec.kind), b.ctxSym, snap,
    newStrLitNode(fname), newStrLitNode(spec.name),
    newStrLitNode(docBlock), b.exSym, newIdentNode(spec.name))))

proc emitGuard(body: NimNode; b: FnBindings; idx: int;
    inner: NimNode) =
  ## `if int(argumentCount) >= idx+1: <inner>` for optional params.
  body.add(nnkIfStmt.newTree(nnkElifBranch.newTree(
    nnkInfix.newTree(newIdentNode(">="),
      newCall("int", b.argcSym), newLit(idx + 1)),
    inner)))

proc buildCallbackFn*(fname: string; ctxName: string;
    fnBody: NimNode; params: seq[ParamSpec]): NimNode =
  ## Builds the nested `cdecl` callback proc named `fname`. The header
  ## params generate the arity check plus one reader each (see
  ## parseHeader); the user body follows with the bindings in scope
  ## plus `args`, `argumentCount` and `docBlock` (the rendered JSDoc).
  ## Leading `##` doc comments in the body are collected for error
  ## output: the JSDoc block prefixes type mismatches and is appended
  ## to arity and `throwError` messages:
  ##
  ##   module.registerFn readFile(path: string):
  ##     ## fs.readFile(path) -> string
  ##     ...
  let b = newBindings(ctxName)
  var doc = ""
  if fnBody.kind == nnkStmtList:
    for stmt in fnBody:
      if stmt.kind == nnkCommentStmt:
        doc =
          if doc.len > 0: doc & "\n" & stmt.strVal
          else: stmt.strVal
      else:
        break
  let docBlock = jsDocBlock(doc)
  let prefix = if docBlock.len > 0: docBlock & "\n" else: ""
  var minArity = 0
  var fixed = 0
  var hasRest = false
  for p in params:
    if p.kind == jakRest:
      hasRest = true
    else:
      inc fixed
      if not p.hasDefault:
        inc minArity
  let body = newStmtList()
  body.add(newLetStmt(b.argsSym,
    nnkCast.newTree(
      nnkPtrTy.newTree(
        nnkBracketExpr.newTree(
          newIdentNode("UncheckedArray"), newIdentNode("JSValueRef"))),
      b.argvSym)))
  body.add(newLetStmt(newIdentNode("docBlock"), newStrLitNode(docBlock)))
  if hasRest:
    body.add(guardNot(newCall("checkArityMin", b.argcSym, newLit(minArity),
      newStrLitNode(fname), b.ctxSym, b.exSym,
      newStrLitNode(docBlock))))
  else:
    body.add(guardNot(newCall("checkArity", b.argcSym, newLit(minArity),
      newLit(fixed), newStrLitNode(fname), b.ctxSym, b.exSym,
      newStrLitNode(docBlock))))
  var idx = 0
  for spec in params:
    if spec.kind == jakRest:
      let pname = newIdentNode(spec.name)
      var sec = newNimNode(nnkVarSection)
      sec.add(newIdentDefs(pname, newIdentNode("RestArgs"),
        nnkPrefix.newTree(newIdentNode("@"),
          newNimNode(nnkBracket))))
      body.add(sec)
      let loopVar = genSym(nskForVar, "k")
      body.add(nnkForStmt.newTree(loopVar,
        nnkInfix.newTree(newIdentNode("..<"), newLit(idx),
          newCall("int", b.argcSym)),
        newStmtList(newCall("add", pname,
          nnkBracketExpr.newTree(b.argsSym, loopVar)))))
    elif spec.kind == jakRaw:
      var sec = newNimNode(nnkVarSection)
      if spec.hasDefault:
        sec.add(newIdentDefs(newIdentNode(spec.name),
          newIdentNode("JSValueRef"), copy(spec.default)))
      else:
        sec.add(newIdentDefs(newIdentNode(spec.name),
          newEmptyNode(),
          nnkBracketExpr.newTree(b.argsSym, newLit(idx))))
      body.add(sec)
      if spec.hasDefault:
        let assign = newStmtList(nnkAsgn.newTree(newIdentNode(spec.name),
          nnkBracketExpr.newTree(b.argsSym, newLit(idx))))
        body.add(nnkIfStmt.newTree(nnkElifBranch.newTree(
          nnkInfix.newTree(newIdentNode(">="),
            newCall("int", b.argcSym), newLit(idx + 1)),
          assign)))
    elif spec.kind == jakNimValue:
      if spec.hasDefault:
        var sec = newNimNode(nnkVarSection)
        sec.add(newIdentDefs(newIdentNode(spec.name),
          newIdentNode("NimValue"), copy(spec.default)))
        body.add(sec)
        let inner = newStmtList()
        let snap = genSym(nskVar, "snap")
        emitSnapshot(inner, b, fname, idx, prefix, snap)
        inner.add(nnkAsgn.newTree(newIdentNode(spec.name), snap))
        emitGuard(body, b, idx, inner)
      else:
        let snap = genSym(nskVar, "snap")
        emitSnapshot(body, b, fname, idx, prefix, snap)
        body.add(newLetStmt(newIdentNode(spec.name), snap))
    elif spec.kind == jakObject:
      var sec = newNimNode(nnkVarSection)
      sec.add(newIdentDefs(newIdentNode(spec.name),
        newIdentNode("JSValueRef"), newNilLit()))
      body.add(sec)
      let check = newStmtList()
      check.add(guardNot(newCall("objRefCheck", b.ctxSym,
        nnkBracketExpr.newTree(b.argsSym, newLit(idx)),
        newStrLitNode(fname), newStrLitNode(spec.name),
        newStrLitNode(docBlock), b.exSym)))
      check.add(nnkAsgn.newTree(newIdentNode(spec.name),
        nnkBracketExpr.newTree(b.argsSym, newLit(idx))))
      if spec.hasDefault:
        emitGuard(body, b, idx, check)
      else:
        for s in check:
          body.add(s)
    else:
      # jakString/jakInt/jakFloat/jakBool via *Param helpers.
      if spec.hasDefault:
        var sec = newNimNode(nnkVarSection)
        sec.add(newIdentDefs(newIdentNode(spec.name),
          paramVarType(spec.kind), copy(spec.default)))
        body.add(sec)
        let inner = newStmtList()
        emitCheckedAssign(inner, b, spec, fname, idx, docBlock, prefix)
        emitGuard(body, b, idx, inner)
      else:
        var sec = newNimNode(nnkVarSection)
        sec.add(newIdentDefs(newIdentNode(spec.name),
          paramVarType(spec.kind), newEmptyNode()))
        body.add(sec)
        emitCheckedAssign(body, b, spec, fname, idx, docBlock, prefix)
    if spec.kind != jakRest:
      inc idx
  let subbed = substBody(fnBody, b)
  body.add(if doc.len > 0: addErrorContext(subbed, doc) else: subbed)

  let ptrJsVal = nnkPtrTy.newTree(newIdentNode("JSValueRef"))
  let formal = newNimNode(nnkFormalParams)
  formal.add(newIdentNode("JSValueRef"))
  formal.add(nnkIdentDefs.newTree(b.ctxSym, newIdentNode("JSContextRef"),
    newEmptyNode()))
  formal.add(nnkIdentDefs.newTree(b.functionSym, b.thisObjectSym,
    newIdentNode("JSObjectRef"), newEmptyNode()))
  formal.add(nnkIdentDefs.newTree(b.argcSym, newIdentNode("csize_t"),
    newEmptyNode()))
  formal.add(nnkIdentDefs.newTree(b.argvSym, ptrJsVal, newEmptyNode()))
  formal.add(nnkIdentDefs.newTree(b.exSym, ptrJsVal, newEmptyNode()))

  result = newNimNode(nnkProcDef)
  result.add(newIdentNode(fname))
  result.add(newEmptyNode())
  result.add(newEmptyNode())
  result.add(formal)
  result.add(newNimNode(nnkPragma).add(newIdentNode("cdecl")))
  result.add(newEmptyNode())
  result.add(body)

macro registerFn*(ctx: untyped; header: untyped;
    fnBody: untyped): untyped =
  ## Defines a JSC callback with the standard
  ## `JSObjectCallAsFunctionCallback` shape. The header declares the
  ## parameter types (see parseHeader); arity and type checks are
  ## generated, so the body starts with the bindings in scope. The body
  ## also sees `ctx` (named after the passed context), `function`,
  ## `thisObject`, `argumentCount`, `arguments`, a pre-cast `args` and
  ## `docBlock` (the rendered JSDoc):
  ##
  ##   ctx.registerFn readFile(path: string):
  ##     ## fs.readFile(path) -> string
  ##     ...
  ##
  ## Definition only; registration stays explicit, as before:
  ##
  ##   setProp(ctx, ns, "readFile",
  ##     makeFunction(ctx, "readFile", readFile), addr ex)
  ##
  ## Note: `quote` cannot express this (it is hygienic: injected bodies
  ## cannot see quote-introduced bindings), so the proc is built manually
  ## and body identifiers are substituted with gensyms. Nested routine
  ## definitions inside the body are left untouched.
  let ctxName = if ctx.kind == nnkIdent: ctx.strVal else: "ctx"
  let parsed = parseHeader(header, "registerFn")
  result = buildCallbackFn(parsed.fname, ctxName, fnBody, parsed.params)

proc dotCallTarget(n: NimNode; mname, field: string): bool =
  ## True when `n` is `mname.field(...)` / `mname.field ...`.
  (n.kind in {nnkCommand, nnkCall}) and n.len > 0 and
    n[0].kind == nnkDotExpr and n[0][0].kind == nnkIdent and
    n[0][0].strVal == mname and n[0][1].kind == nnkIdent and
    n[0][1].strVal == field

macro init*(def: untyped): untyped =
  ## Module initializer. Takes `proc(<name>: Module) = ...` and
  ## generates the `install*` entry point behind `require("std/...")`:
  ##
  ##   init proc(module: Module) =
  ##     exportObject:
  ##       module.property greeting = "hi"
  ##       module.registerFn readFile(path: string):
  ##         ...
  ##
  ## `module.registerFn` defines the callback and attaches it to the
  ## namespace; `module.property` attaches a data value (string, int,
  ## float, bool, JsonNode). A `##` doc comment on a member is collected
  ## for error output (see buildCallbackFn). Bare statements run
  ## as init-time setup code. Member declarations outside `exportObject:`
  ## are an error, as is anything but members inside it.
  if def.kind != nnkLambda:
    error("init expects `proc(<name>: Module) = ...`", def)
  var formal: NimNode = nil
  for child in def:
    if child.kind == nnkFormalParams:
      formal = child
      break
  if formal == nil or formal.len != 2 or formal[1].kind != nnkIdentDefs or
      formal[1].len != 3 or formal[1][0].kind != nnkIdent or
      formal[1][1].kind != nnkIdent or formal[1][1].strVal != "Module":
    error("init expects exactly one parameter of type Module", def)
  let mname = formal[1][0].strVal
  let body = def[^1]
  if body.kind != nnkStmtList:
    error("init expects a block body", def)

  let moduleSym = genSym(nskLet, "module")
  let exSym = genSym(nskVar, "ex")
  let ctxId = newIdentNode("ctx")
  let nsOf = nnkDotExpr.newTree(moduleSym, newIdentNode("ns"))

  let outStmts = newStmtList()
  for stmt in body:
    if stmt.kind in {nnkCommand, nnkCall} and stmt.len > 0 and
        stmt[0].kind == nnkIdent and stmt[0].strVal == "exportObject":
      if stmt.len != 2 or stmt[1].kind != nnkStmtList:
        error("exportObject takes a single block", stmt)
      for member in stmt[1]:
        if member.kind == nnkCommentStmt:
          continue
        elif dotCallTarget(member, mname, "registerFn"):
          if member.len != 3 or member[2].kind != nnkStmtList:
            error("registerFn expects a header with params and a body",
              member)
          let parsed = parseHeader(member[1], "registerFn")
          let fname = parsed.fname
          outStmts.add(buildCallbackFn(fname, "ctx", member[2],
            parsed.params))
          outStmts.add(newCall("setProp", ctxId, copy(nsOf),
            newStrLitNode(fname),
            newCall("makeFunction", ctxId, newStrLitNode(fname),
              newIdentNode(fname)),
            nnkCommand.newTree(newIdentNode("addr"), exSym)))
        elif dotCallTarget(member, mname, "property"):
          if member.len != 2 or member[1].kind != nnkExprEqExpr:
            error("property expects `name = value`", member)
          let key = member[1][0]
          if key.kind notin {nnkIdent, nnkStrLit}:
            error("property name must be an identifier or string", member)
          let pname = key.strVal
          outStmts.add(newCall("setProp", ctxId, copy(nsOf),
            newStrLitNode(pname),
            newCall("propToJS", ctxId,
              substModule(member[1][1], mname, moduleSym)),
            nnkCommand.newTree(newIdentNode("addr"), exSym)))
        else:
          error("only module.property and module.registerFn allowed " &
            "in exportObject", member)
    elif dotCallTarget(stmt, mname, "registerFn") or
        dotCallTarget(stmt, mname, "property"):
      error("member declarations must live in exportObject:", stmt)
    else:
      outStmts.add(substModule(stmt, mname, moduleSym))

  result = newNimNode(nnkProcDef)
  result.add(newIdentNode("install").postfix("*"))
  result.add(newEmptyNode())
  result.add(newEmptyNode())
  let formalOut = newNimNode(nnkFormalParams)
  formalOut.add(newIdentNode("JSObjectRef"))
  formalOut.add(nnkIdentDefs.newTree(ctxId, newIdentNode("JSContextRef"),
    newEmptyNode()))
  formalOut.add(nnkIdentDefs.newTree(newIdentNode("rt"),
    newIdentNode("Runtime"), newEmptyNode()))
  result.add(formalOut)
  result.add(newEmptyNode())
  result.add(newEmptyNode())
  let wrapper = newStmtList()
  wrapper.add(newLetStmt(moduleSym,
    nnkObjConstr.newTree(newIdentNode("Module"),
      nnkExprColonExpr.newTree(newIdentNode("ctx"), ctxId),
      nnkExprColonExpr.newTree(newIdentNode("ns"),
        newCall("newObject", ctxId)))))
  let varSec = newNimNode(nnkVarSection)
  varSec.add(newIdentDefs(exSym, newIdentNode("JSValueRef"),
    newNilLit()))
  wrapper.add(varSec)
  for s in outStmts:
    wrapper.add(s)
  let cond = newNimNode(nnkInfix)
  cond.add(newIdentNode("!="))
  cond.add(exSym)
  cond.add(newNilLit())
  let retNil = newNimNode(nnkReturnStmt)
  retNil.add(newNilLit())
  let elifBranch = nnkElifBranch.newTree(cond, newStmtList(retNil))
  wrapper.add(nnkIfStmt.newTree(elifBranch))
  wrapper.add(nsOf)
  result.add(wrapper)
