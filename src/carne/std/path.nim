# Carne std/path: file-path and URL parsing via openparser.
#
#   const path = require("std/path");
#   path.parse("/a/b/c.txt")
#     -> {kind: "local", absolute: true, segments: ["a","b","c.txt"], ext: "txt"}
#   path.parse("https://user@host:8080/p?q=1#frag")
#     -> {kind: "web", scheme: "https", user: "user", host: "host",
#         port: 8080, path: "/p", segments: ["p"],
#         query: [{key: "q", value: "1"}], fragment: "frag"}
#   path.format(path.parse("/a/b")) -> "/a/b"
#   path.join(["a", "b", "c.txt"]) -> "a/b/c.txt"
#   path.normalize("a/./b/../c") -> "a/c"
#
# Absent options stay absent; format ignores derived `ext`/`segments`
# when `path` is present and re-derives them.

import std/[math, options, strutils, tables]

import javascriptcore

import pkg/openparser/path

import ../bridge


proc pathToJS(ctx: JSContextRef; p: Path; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "kind",
      toJS(ctx, ($p.kind)[2 .. ^1].toLowerAscii()), fname, exception):
    return nil
  if p.isLocal:
    if not optSetStr(ctx, obj, "drive", p.drive, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "absolute", toJS(ctx, p.isAbsolute),
        fname, exception):
      return nil
    var svals: seq[JSValueRef] = @[]
    for s in p.segments:
      svals.add(toJS(ctx, s))
    let segs = makeJSArray(ctx, svals)
    if segs == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "segments", segs, fname, exception):
      return nil
    if not optSetStr(ctx, obj, "ext", p.localExt, fname, exception):
      return nil
  else:
    if not setPropChecked(ctx, obj, "scheme", toJS(ctx, p.scheme),
        fname, exception):
      return nil
    if p.auth.isSome:
      let a = p.auth.get()
      if not setPropChecked(ctx, obj, "user", toJS(ctx, a.user), fname,
          exception):
        return nil
      if not optSetStr(ctx, obj, "password", a.password, fname,
          exception):
        return nil
    if not setPropChecked(ctx, obj, "host", toJS(ctx, p.host), fname,
        exception):
      return nil
    if p.port.isSome:
      if not setPropChecked(ctx, obj, "port", toJS(ctx, p.port.get()),
          fname, exception):
        return nil
    if not setPropChecked(ctx, obj, "path", toJS(ctx, p.path), fname,
        exception):
      return nil
    var svals: seq[JSValueRef] = @[]
    for s in p.pathSegments:
      svals.add(toJS(ctx, s))
    let segs = makeJSArray(ctx, svals)
    if segs == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "segments", segs, fname, exception):
      return nil
    var qvals: seq[JSValueRef] = @[]
    for param in p.query:
      let qobj = newObject(ctx)
      if not setPropChecked(ctx, qobj, "key", toJS(ctx, param.key),
          fname, exception):
        return nil
      if not setPropChecked(ctx, qobj, "value", toJS(ctx, param.value),
          fname, exception):
        return nil
      qvals.add(qobj)
    let q = makeJSArray(ctx, qvals)
    if q == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "query", q, fname, exception):
      return nil
    if not optSetStr(ctx, obj, "fragment", p.fragment, fname, exception):
      return nil
    if not optSetStr(ctx, obj, "ext", p.ext, fname, exception):
      return nil
  obj

proc splitLocalSegments(p: string): seq[string] =
  result = @[]
  for seg in p.split('/'):
    if seg.len > 0:
      result.add(seg)

proc resolveDotSegments(segs: seq[string]; absolute: bool): seq[string] =
  result = @[]
  for s in segs:
    if s == "" or s == ".":
      continue
    if s == "..":
      if result.len > 0 and result[^1] != "..":
        discard result.pop()
      elif not absolute:
        result.add("..")
      continue
    result.add(s)

proc normalizeLocalParts(drive: Option[string]; absolute: bool;
    segs: seq[string]): string =
  let norm = resolveDotSegments(segs, absolute)
  result = ""
  if drive.isSome:
    result &= drive.get() & ":"
  if absolute:
    result &= "/"
  result &= norm.join("/")

proc normalizeLocalText(text: string): string =
  var p = text.replace('\\', '/')
  var drive = none(string)
  if p.len >= 2 and p[1] == ':' and p[0].isAlphaAscii():
    drive = some($p[0])
    p = p[2 .. ^1]
  let absolute = p.startsWith('/')
  normalizeLocalParts(drive, absolute, splitLocalSegments(p))

proc pathKindFromString(s: string): PathKind =
  case s
  of "local": pkLocal
  of "web": pkWeb
  of "ssh": pkSSH
  of "git": pkGit
  of "ftp": pkFTP
  of "sftp": pkSFTP
  of "mail": pkMail
  of "unknown": pkUnknown
  else:
    raise newException(CatchableError, "unknown kind \"" & s & "\"")

proc reqStr(v: NimValue; key: string): string =
  if not v.hasKey(key):
    raise newException(CatchableError, "missing \"" & key & "\"")
  let f = v.obj[key]
  if f.kind != nvkString:
    raise newException(CatchableError, "\"" & key & "\" must be a string, got " &
      jsTypeName(f.kind))
  f.s

proc optStr(v: NimValue; key: string): Option[string] =
  if not v.hasKey(key):
    return none(string)
  let f = v.obj[key]
  case f.kind
  of nvkString: some(f.s)
  of nvkUndefined, nvkNull: none(string)
  else:
    raise newException(CatchableError, "\"" & key & "\" must be a string, got " &
      jsTypeName(f.kind))

proc optBool(v: NimValue; key: string; dflt = false): bool =
  if not v.hasKey(key):
    return dflt
  let f = v.obj[key]
  case f.kind
  of nvkBool: f.b
  of nvkUndefined, nvkNull: dflt
  else:
    raise newException(CatchableError, "\"" & key & "\" must be a boolean, got " &
      jsTypeName(f.kind))

proc optInt(v: NimValue; key: string): Option[int] =
  if not v.hasKey(key):
    return none(int)
  let f = v.obj[key]
  case f.kind
  of nvkInt: some(int(f.i))
  of nvkFloat:
    if f.f == trunc(f.f) and f.f >= -9007199254740991.0 and
        f.f <= 9007199254740991.0:
      some(int(f.f))
    else:
      raise newException(CatchableError, "\"" & key &
        "\" must be an integer, got non-integral number")
  of nvkUndefined, nvkNull: none(int)
  else:
    raise newException(CatchableError, "\"" & key &
      "\" must be a number, got " & jsTypeName(f.kind))

proc reqStrArray(v: NimValue; key: string): seq[string] =
  if not v.hasKey(key):
    raise newException(CatchableError, "missing \"" & key & "\"")
  let f = v.obj[key]
  if f.kind != nvkArray:
    raise newException(CatchableError, "\"" & key & "\" must be an array, got " &
      jsTypeName(f.kind))
  for item in f.arr:
    if item.kind != nvkString:
      raise newException(CatchableError, "\"" & key &
        "\" entries must be strings, got " & jsTypeName(item.kind))
    result.add(item.s)

proc readQuery(v: NimValue): seq[QueryParam] =
  if not v.hasKey("query"):
    return @[]
  let f = v.obj["query"]
  case f.kind
  of nvkUndefined, nvkNull:
    return @[]
  of nvkArray:
    for item in f.arr:
      if item.kind != nvkObject:
        raise newException(CatchableError,
          "\"query\" entries must be {key, value} objects")
      if not item.hasKey("key") or not item.hasKey("value"):
        raise newException(CatchableError,
          "\"query\" entries must be {key, value} objects")
      let k = item.obj["key"]
      let val = item.obj["value"]
      if k.kind != nvkString or val.kind != nvkString:
        raise newException(CatchableError,
          "\"query\" entries must be {key, value} strings")
      result.add((key: k.s, value: val.s))
  else:
    raise newException(CatchableError,
      "\"query\" must be an array, got " & jsTypeName(f.kind))

proc nimValueToPath(v: NimValue): Path =
  if v.kind != nvkObject:
    raise newException(CatchableError,
      "expected object, got " & jsTypeName(v.kind))
  let kind = reqStr(v, "kind")
  let k = pathKindFromString(kind)
  if k == pkLocal:
    let absolute = optBool(v, "absolute")
    let segs = if v.hasKey("segments"): reqStrArray(v, "segments")
      else: @[]
    let drive = optStr(v, "drive")
    result = Path(raw: "", kind: pkLocal, isLocal: true, drive: drive,
      isAbsolute: absolute, segments: segs, localExt: none(string))
  else:
    let scheme = reqStr(v, "scheme")
    let user = optStr(v, "user")
    var auth = none(AuthInfo)
    if user.isSome:
      auth = some(AuthInfo(user: user.get(), password: optStr(v, "password")))
    elif v.hasKey("password"):
      let pw = v.obj["password"]
      if pw.kind notin {nvkUndefined, nvkNull}:
        raise newException(CatchableError,
          "\"password\" needs \"user\"")
    let host = reqStr(v, "host")
    let port = optInt(v, "port")
    var pathStr = ""
    if v.hasKey("path"):
      let pf = v.obj["path"]
      case pf.kind
      of nvkString: pathStr = pf.s
      of nvkUndefined, nvkNull: pathStr = ""
      else:
        raise newException(CatchableError,
          "\"path\" must be a string, got " & jsTypeName(pf.kind))
    result = Path(raw: "", kind: k, isLocal: false, scheme: scheme,
      auth: auth, host: host, port: port, path: pathStr,
      pathSegments: splitLocalSegments(pathStr), query: readQuery(v),
      fragment: optStr(v, "fragment"), ext: none(string))

proc normalizeParsedPath(p: Path): string =
  if p.isLocal:
    normalizeLocalParts(p.drive, p.isAbsolute,
      resolveDotSegments(p.segments, p.isAbsolute))
  else:
    var q = p
    q.pathSegments = resolveDotSegments(p.pathSegments, true)
    q.path = "/" & q.pathSegments.join("/")
    if p.path.len == 0:
      q.path = ""
    elif p.path == "/":
      q.path = "/"
    elif not p.path.startsWith('/') and q.path.startsWith('/'):
      q.path = q.path[1 .. ^1]
    $q

## Builds the std/path namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## path.parse(text) -> local or network path object
      try:
        let j = pathToJS(ctx, parsePath(text), "parse", exception)
        if j == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn format(value: NimValue):
      ## path.format(obj) -> canonical string for a parse-shaped object
      try:
        toJS(ctx, $nimValueToPath(value))
      except CatchableError as e:
        throwTypeError(ctx, "format: " & e.msg, exception)
        nil

    module.registerFn join(parts: NimValue):
      ## path.join(["a", "b"]) -> normalized local path string
      try:
        if parts.kind != nvkArray:
          throwTypeError(ctx, "join: expected array, got " &
            jsTypeName(parts.kind), exception)
          return nil
        var raw: seq[string] = @[]
        for item in parts.arr:
          if item.kind != nvkString:
            throwTypeError(ctx, "join: entries must be strings, got " &
              jsTypeName(item.kind), exception)
            return nil
          raw.add(item.s)
        toJS(ctx, normalizeLocalText(raw.join("/")))
      except CatchableError as e:
        throwTypeError(ctx, "join: " & e.msg, exception)
        nil

    module.registerFn normalize(text: string):
      ## path.normalize(text) -> local path with ./.. resolved; URLs keep
      ## scheme/authority/query/fragment with a resolved path part
      try:
        let p = parsePath(text)
        toJS(ctx, normalizeParsedPath(p))
      except CatchableError as e:
        throwError(ctx, "normalize: " & e.msg, exception)
        nil
