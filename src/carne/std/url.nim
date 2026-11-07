# Carne std/url: URL parsing and formatting via Nim std/uri.
#
#   const url = require("std/url");
#   url.parse("https://user:pw@host:8080/p?q=1#frag")
#     -> {scheme, username, password, hostname, port, path,
#         query: [{key, value}], fragment, isAbsolute}
#   url.format(obj) -> string (inverse of parse)
#   url.parseQuery("a=1&b=") -> [{key, value}]
#   url.stringifyQuery([{key: "a", value: "1"}]) -> "a=1"
#   url.encode("a b") -> "a%20b", url.decode("a%20b") -> "a b"
#
# RFC 3986 encoding (Nim std/uri): unreserved chars pass through,
# space encodes as %20. Query parsing decodes + as space.
# Absent components stay absent (empty username/password/path/fragment
# are omitted). Port is an int when present.

import std/[strutils, tables, uri]

import javascriptcore

import ../bridge

proc parseQueryPairs(q: string): seq[(string, string)] =
  ## Raw query string -> decoded pairs. Empty -> @[].
  result = @[]
  var s = q
  if s.len > 0 and (s[0] == '?' or s[0] == '#'):
    s = s[1 .. ^1]
  if s.len == 0:
    return
  for part in s.split('&'):
    if part.len == 0:
      continue
    let eq = part.find('=')
    if eq < 0:
      result.add((decodeUrl(part, true), ""))
    else:
      result.add((decodeUrl(part[0 ..< eq], true),
        decodeUrl(part[eq + 1 .. ^1], true)))

proc queryToJS(ctx: JSContextRef; pairs: seq[(string, string)];
    fname: string; exception: ptr JSValueRef): JSValueRef =
  var vals: seq[JSValueRef] = @[]
  for (k, v) in pairs:
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "key", toJS(ctx, k), fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "value", toJS(ctx, v), fname,
        exception):
      return nil
    vals.add(obj)
  makeJSArray(ctx, vals)

proc uriToJS(ctx: JSContextRef; u: Uri; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "scheme", toJS(ctx, u.scheme), fname,
      exception):
    return nil
  if u.username.len > 0:
    if not setPropChecked(ctx, obj, "username", toJS(ctx, u.username),
        fname, exception):
      return nil
  if u.password.len > 0:
    if not setPropChecked(ctx, obj, "password", toJS(ctx, u.password),
        fname, exception):
      return nil
  if not setPropChecked(ctx, obj, "hostname", toJS(ctx, u.hostname),
      fname, exception):
    return nil
  if u.port.len > 0:
    var n = 0
    try:
      n = parseInt(u.port)
    except ValueError:
      throwError(ctx, fname & ": port is not numeric", exception)
      return nil
    if not setPropChecked(ctx, obj, "port", toJS(ctx, n), fname,
        exception):
      return nil
  if not setPropChecked(ctx, obj, "path", toJS(ctx, u.path), fname,
      exception):
    return nil
  let q = queryToJS(ctx, parseQueryPairs(u.query), fname, exception)
  if q == nil:
    return nil
  if not setPropChecked(ctx, obj, "query", q, fname, exception):
    return nil
  if u.anchor.len > 0:
    if not setPropChecked(ctx, obj, "fragment", toJS(ctx, u.anchor),
        fname, exception):
      return nil
  if not setPropChecked(ctx, obj, "isAbsolute",
      toJS(ctx, isAbsolute(u)), fname, exception):
    return nil
  obj

proc optStr(ctx: JSContextRef; obj: JSValueRef; key: string;
    dst: var string; fname: string;
    exception: ptr JSValueRef): bool =
  ## Optional string field. True on success (absent -> dst unchanged).
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    throwError(ctx, fname & ": ." & key & " " & err, exception)
    return false
  if f.kind == nvkUndefined:
    return true
  if f.kind != nvkString:
    throwError(ctx, fname & ": ." & key & " must be a string, got " &
      jsTypeName(f.kind), exception)
    return false
  dst = f.s
  true

proc readQueryField(ctx: JSContextRef; obj: JSValueRef;
    pairs: var seq[(string, string)]; fname: string;
    exception: ptr JSValueRef): bool =
  ## Reads .query as string | [{key,value}] | [[k,v]] | {k:v}.
  ## Absent -> empty. True on success.
  var err = ""
  let f = getField(ctx, obj, "query", err)
  if err != "":
    throwError(ctx, fname & ": .query " & err, exception)
    return false
  pairs = @[]
  if f.kind == nvkUndefined:
    return true
  if f.kind == nvkString:
    pairs = parseQueryPairs(f.s)
    return true
  if f.kind == nvkArray:
    for i, item in f.arr:
      case item.kind
      of nvkArray:
        if item.arr.len != 2 or item.arr[0].kind != nvkString or
            item.arr[1].kind != nvkString:
          throwError(ctx,
            fname & ": .query[" & $i & "] must be [key, value] strings",
            exception)
          return false
        pairs.add((item.arr[0].s, item.arr[1].s))
      of nvkObject:
        if not item.obj.hasKey("key") or not item.obj.hasKey("value"):
          throwError(ctx,
            fname & ": .query[" & $i & "] needs string key/value",
            exception)
          return false
        let k = item.obj["key"]
        let v = item.obj["value"]
        if k.kind != nvkString or v.kind != nvkString:
          throwError(ctx,
            fname & ": .query[" & $i & "] needs string key/value",
            exception)
          return false
        pairs.add((k.s, v.s))
      else:
        throwError(ctx,
          fname & ": .query[" & $i & "] must be {key, value} or [k, v]",
          exception)
        return false
    return true
  if f.kind == nvkObject:
    for key, aval in f.obj.pairs:
      if aval.kind != nvkString:
        throwError(ctx, fname & ": .query." & key & " must be a string",
          exception)
        return false
      pairs.add((key, aval.s))
    return true
  throwError(ctx, fname & ": .query must be an array, object or string",
    exception)
  false

## Builds the std/url namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## url.parse(text) -> {scheme, hostname, port?, path, query, ...}
      try:
        let u = parseUri(text)
        let j = uriToJS(ctx, u, "parse", exception)
        if j == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn format(value: JSValueRef):
      ## url.format(obj) -> string
      if value == nil or JSValueGetType(ctx, value) != kJSTypeObject or
          JSValueIsArray(ctx, value):
        throwError(ctx, "format: needs a URL object", exception)
        return nil
      var scheme, username, password, hostname, path, fragment = ""
      if not optStr(ctx, value, "scheme", scheme, "format", exception):
        return nil
      if not optStr(ctx, value, "username", username, "format", exception):
        return nil
      if not optStr(ctx, value, "password", password, "format", exception):
        return nil
      if not optStr(ctx, value, "hostname", hostname, "format", exception):
        return nil
      if hostname.len == 0:
        if not optStr(ctx, value, "host", hostname, "format", exception):
          return nil
      if not optStr(ctx, value, "path", path, "format", exception):
        return nil
      if not optStr(ctx, value, "fragment", fragment, "format", exception):
        return nil
      if fragment.len == 0:
        if not optStr(ctx, value, "anchor", fragment, "format", exception):
          return nil
        if fragment.len > 0 and fragment[0] == '#':
          fragment = fragment[1 .. ^1]
      var portStr = ""
      var perr = ""
      let p = getField(ctx, value, "port", perr)
      if perr != "":
        throwError(ctx, "format: .port " & perr, exception)
        return nil
      if p.kind != nvkUndefined:
        case p.kind
        of nvkInt:
          if p.i < 1 or p.i > 65535:
            throwError(ctx, "format: .port must be 1..65535", exception)
            return nil
          portStr = $p.i
        of nvkString:
          if p.s.len > 0:
            var n = 0
            try:
              n = parseInt(p.s)
            except ValueError:
              throwError(ctx, "format: .port is not numeric", exception)
              return nil
            if n < 1 or n > 65535:
              throwError(ctx, "format: .port must be 1..65535", exception)
              return nil
            portStr = $n
        else:
          throwError(ctx, "format: .port must be an integer 1..65535",
            exception)
          return nil
      var pairs: seq[(string, string)] = @[]
      if not readQueryField(ctx, value, pairs, "format", exception):
        return nil
      var u = initUri()
      u.scheme = scheme
      u.username = username
      u.password = password
      u.hostname = hostname
      u.port = portStr
      u.path = path
      if pairs.len > 0:
        u.query = encodeQuery(pairs)
      u.anchor = fragment
      toJS(ctx, $u)

    module.registerFn parseQuery(text: string):
      ## url.parseQuery("a=1&b=") -> [{key, value}]
      let j = queryToJS(ctx, parseQueryPairs(text), "parseQuery",
        exception)
      if j == nil:
        throwError(ctx, "parseQuery: could not convert result to JS",
          exception)
        return nil
      j

    module.registerFn stringifyQuery(value: JSValueRef):
      ## url.stringifyQuery([{key, value}] | {k: v} | [[k, v]]) -> string
      var pairs: seq[(string, string)] = @[]
      if value == nil:
        throwError(ctx, "stringifyQuery: needs query pairs", exception)
        return nil
      if JSValueGetType(ctx, value) == kJSTypeString:
        var herr = ""
        let f = fromJS(ctx, value, herr)
        if herr == "" and f.kind == nvkString:
          pairs = parseQueryPairs(f.s)
          return toJS(ctx, encodeQuery(pairs))
        throwError(ctx, "stringifyQuery: needs query pairs", exception)
        return nil
      # Reuse the .query reader by wrapping value as {query: value}.
      let wrap = newObject(ctx)
      var ex: JSValueRef = nil
      setProp(ctx, wrap, "query", value, addr ex)
      if ex != nil:
        throwError(ctx, "stringifyQuery: needs query pairs", exception)
        return nil
      if not readQueryField(ctx, wrap, pairs, "stringifyQuery",
          exception):
        return nil
      toJS(ctx, encodeQuery(pairs))

    module.registerFn encode(text: string):
      ## url.encode(text) -> percent-encoded string (%20 for space)
      toJS(ctx, encodeUrl(text, false))

    module.registerFn decode(text: string):
      ## url.decode(text) -> decoded string
      toJS(ctx, decodeUrl(text, false))

    module.registerFn encodeComponent(text: string):
      ## url.encodeComponent(text) -> percent-encoded string
      toJS(ctx, encodeUrl(text, false))

    module.registerFn decodeComponent(text: string):
      ## url.decodeComponent(text) -> decoded string
      toJS(ctx, decodeUrl(text, false))
