# Carne std/qr: QR code generation, decoding and payload builders.
#
#   const qr = require("std/qr");
#   qr.encode("hello")
#     -> {family, version, width, height, size, ecLevel, mask, svg, terminal, modules}
#   qr.encode("hello", {family: "micro", ecLevel: "L"}) -> Micro QR symbol
#   qr.decode(matrix) -> {text, family, version, ecLevel, mask, eci}
#   qr.wifi("cafe", {password: "secret"}) -> "WIFI:..."
#   qr.sqrc("public", "private", key) -> encrypted-payload symbol
#
# Families: model2 (default), model1, micro, rmqr, aqr (via encodeAqr)
# and sqrc (Model 2 carrying an encrypted area). Contact cards come from
# std/vcard (feed its output to encode); image decode stays out of
# scope: decode reads a clean module grid, e.g. from .modules.

import std/strutils

import javascriptcore

import pkg/openparser/qr/common
import pkg/openparser/qr/model2
import pkg/openparser/qr/model1
import pkg/openparser/qr/micro
import pkg/openparser/qr/rmqr
import pkg/openparser/qr/aqr
import pkg/openparser/qr/sqrc
import pkg/openparser/qr/payload
import pkg/openparser/qr/render

import ../bridge

type QrFam = enum
  qfModel2
  qfModel1
  qfMicro
  qfRmqr

proc ecName(level: QrEcLevel): string =
  ## "L" | "M" | "Q" | "H" for result objects.
  case level
  of ecLow: "L"
  of ecMedium: "M"
  of ecQuartile: "Q"
  of ecHigh: "H"

proc ecLevelArg(ctx: JSContextRef; obj: JSValueRef): QrEcLevel =
  ## Reads {ecLevel?}; absent and undefined both mean M. Raises with a
  ## bare options message (callers add their "fn: " prefix once).
  result = ecMedium
  if obj == nil:
    return
  var err = ""
  let f = getField(ctx, obj, "ecLevel", err)
  if err != "":
    raise newException(CatchableError, "options.ecLevel " & err)
  if f.kind == nvkUndefined:
    return
  if f.kind != nvkString:
    raise newException(CatchableError,
      "options.ecLevel must be one of L, M, Q, H")
  case f.s.toUpperAscii()
  of "L":
    result = ecLow
  of "M":
    result = ecMedium
  of "Q":
    result = ecQuartile
  of "H":
    result = ecHigh
  else:
    raise newException(CatchableError,
      "options.ecLevel must be one of L, M, Q, H")

proc getOptStr(ctx: JSContextRef; obj: JSValueRef; key: string;
    val: var string): bool =
  ## Optional string option. Returns true when present (val set),
  ## false when absent/undefined. Raises with a bare options message.
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(CatchableError, "options." & key & " " & err)
  if f.kind == nvkUndefined:
    return false
  if f.kind != nvkString:
    raise newException(CatchableError, "options." & key &
      " must be a string, got " & jsTypeName(f.kind))
  val = f.s
  true

proc getOptInt(ctx: JSContextRef; obj: JSValueRef; key: string;
    val: var int64): bool =
  ## Optional integer option (integral floats accepted). Same contract
  ## as getOptStr.
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(CatchableError, "options." & key & " " & err)
  if f.kind == nvkUndefined:
    return false
  try:
    val = f.asInt(key)
  except CatchableError:
    raise newException(CatchableError, "options." & key &
      " must be an integer, got " & jsTypeName(f.kind))
  true

proc getOptBool(ctx: JSContextRef; obj: JSValueRef; key: string;
    val: var bool): bool =
  ## Optional boolean option. Same contract as getOptStr.
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(CatchableError, "options." & key & " " & err)
  if f.kind == nvkUndefined:
    return false
  if f.kind != nvkBool:
    raise newException(CatchableError, "options." & key &
      " must be a boolean, got " & jsTypeName(f.kind))
  val = f.b
  true

proc getVersionField(ctx: JSContextRef;
    obj: JSValueRef): NimValue =
  ## Raw options.version (possibly undefined) for per-family parsing.
  ## Raises with a bare options message.
  result = NimValue(kind: nvkUndefined)
  if obj == nil:
    return
  var err = ""
  result = getField(ctx, obj, "version", err)
  if err != "":
    raise newException(CatchableError, "options.version " & err)

proc parseFamily(s: string): QrFam =
  ## "model2" | "model1" | "micro" | "rmqr", forgiving on separators.
  case s.toLowerAscii()
  of "model2", "model-2", "m2", "qr":
    qfModel2
  of "model1", "model-1", "m1":
    qfModel1
  of "micro", "microqr", "micro-qr", "micro-qr-code":
    qfMicro
  of "rmqr", "r-mqr", "rectangular", "rectangular-micro":
    qfRmqr
  else:
    raise newException(CatchableError,
      "options.family must be one of model2, model1, micro, rmqr")

proc versionInt(f: NimValue; lo, hi: int; label: string): int =
  ## Integer version pin for Model 2 / Model 1. Raises with a bare,
  ## family-specific range message.
  var v: int64 = 0
  case f.kind
  of nvkInt:
    v = f.i
  of nvkFloat:
    try:
      v = f.asInt("options.version")
    except CatchableError:
      raise newException(CatchableError,
        "options.version for " & label & " must be " &
        $lo & " .. " & $hi)
  else:
    raise newException(CatchableError, "options.version for " &
      label & " must be " & $lo & " .. " & $hi)
  if v < lo or v > hi:
    raise newException(CatchableError, "options.version for " &
      label & " must be " & $lo & " .. " & $hi)
  int(v)

proc parseMicroVersion(f: NimValue): MicroVersion =
  ## "M1" .. "M4" (case-insensitive) or 1 .. 4.
  if f.kind == nvkString:
    case f.s.toUpperAscii()
    of "M1": return mvM1
    of "M2": return mvM2
    of "M3": return mvM3
    of "M4": return mvM4
    else: discard
    raise newException(CatchableError,
      "options.version for Micro QR must be \"M1\" .. \"M4\" (or 1 .. 4)")
  MicroVersion(versionInt(f, 1, 4, "Micro QR"))

proc microVersionName(width: int): string =
  ## Size class from symbol width (11/13/15/17).
  case width
  of 11: "M1"
  of 13: "M2"
  of 15: "M3"
  of 17: "M4"
  else: $width

proc rmqrVersionName(m: QrMatrix): string =
  ## Canonical "R{height}x{width}" designation by table lookup.
  for idx in 0 .. 31:
    if rmqrHeight[idx] == m.height and rmqrWidth[idx] == m.width:
      return rmqrSizeName(idx)
  $m.height & "x" & $m.width

proc aqrCoreVersion(outer: int): int =
  ## Inverts aqrOuterSize: Model 2 core version behind an AQR symbol.
  var n = 21
  while n <= 177:
    if aqrOuterSize(n) == outer:
      return (n - 17) div 4
    inc n, 4
  0

proc matrixModules(ctx: JSContextRef; m: QrMatrix): JSValueRef =
  ## Nested 0/1 rows for the modules field (feeds qr.decode).
  var rows: seq[JSValueRef] = @[]
  for y in 0 ..< m.height:
    var cols: seq[JSValueRef] = @[]
    for x in 0 ..< m.width:
      cols.add(toJS(ctx, if m[x, y]: 1 else: 0))
    let row = makeJSArray(ctx, cols)
    if row == nil:
      return nil
    rows.add(row)
  makeJSArray(ctx, rows)

proc matrixResult(ctx: JSContextRef; m: QrMatrix; family, version,
    ec: string; mask: int; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## Shared encode-shape object: {family, version, width, height, size,
  ## ecLevel, mask, svg, terminal, modules}. nil + JS throw on failure.
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "family", toJS(ctx, family),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "version", toJS(ctx, version),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "width", toJS(ctx, m.width),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "height", toJS(ctx, m.height),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "size", toJS(ctx, m.width),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "ecLevel", toJS(ctx, ec),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "mask", toJS(ctx, mask),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "svg", toJS(ctx, toSvg(m)),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "terminal", toJS(ctx, toTerminal(m)),
      fname, exception):
    return nil
  let mods = matrixModules(ctx, m)
  if mods == nil:
    throwError(ctx, fname & ": could not convert result to JS", exception)
    return nil
  if not setPropChecked(ctx, obj, "modules", mods, fname, exception):
    return nil
  obj

proc doEncodeQr(text: string; fam: QrFam; ec: QrEcLevel; ver: NimValue;
    mask: int; eci: int64): tuple[m: QrMatrix, version: string] =
  ## Family dispatch for encode. Raises bare messages; the registerFn
  ## adds its prefix once.
  case fam
  of qfModel2:
    var pinned = 0
    if ver.kind != nvkUndefined:
      pinned = versionInt(ver, 1, 40, "Model 2")
    var opts = defaultQrEncodeOptions()
    opts.ecLevel = ec
    if pinned > 0:
      opts.minVersion = pinned
      opts.maxVersion = pinned
    opts.mask = mask
    opts.eci = int(eci)
    let m = encodeQr(text, opts)
    (m, $((m.width - 17) div 4))
  of qfModel1:
    var v = 0
    if ver.kind != nvkUndefined:
      v = versionInt(ver, 0, 12, "Model 1")
    let m = encodeModel1(text, ec, v, mask)
    (m, $((m.width - 17) div 4))
  of qfMicro:
    var mv = mvAuto
    if ver.kind != nvkUndefined:
      mv = parseMicroVersion(ver)
    let m = encodeMicro(text, ec, mv, mask)
    (m, microVersionName(m.width))
  of qfRmqr:
    var name = ""
    if ver.kind != nvkUndefined:
      if ver.kind != nvkString:
        raise newException(CatchableError,
          "options.version for rMQR must be a size designation like \"R11x139\"")
      name = ver.s
    let m = encodeRmqr(text, ec, name)
    (m, rmqrVersionName(m))

proc matrixFromJS(v: NimValue; fname: string): QrMatrix =
  ## 2D grid of 0/1 (booleans accepted) into a QrMatrix. Raises on
  ## ragged, empty, oversized or non-binary input.
  if v.kind != nvkArray or v.arr.len == 0:
    raise newException(CatchableError,
      fname & ": matrix must be a non-empty array of rows")
  let h = v.arr.len
  if h > 512:
    raise newException(CatchableError,
      fname & ": matrix has too many rows (" & $h & ", cap 512)")
  var w = -1
  for row in v.arr:
    if row.kind != nvkArray or row.arr.len == 0:
      raise newException(CatchableError,
        fname & ": matrix rows must be non-empty arrays")
    if w < 0:
      w = row.arr.len
      if w > 512:
        raise newException(CatchableError,
          fname & ": matrix has too many columns (" & $w & ", cap 512)")
    elif row.arr.len != w:
      raise newException(CatchableError, fname &
        ": matrix rows have uneven lengths (" & $row.arr.len & " vs " & $w & ")")
    for cell in row.arr:
      case cell.kind
      of nvkBool, nvkInt:
        if cell.kind == nvkInt and cell.i != 0 and cell.i != 1:
          raise newException(CatchableError, fname &
            ": matrix cells must be 0, 1 or boolean")
      else:
        raise newException(CatchableError, fname &
          ": matrix cells must be 0, 1 or boolean, got " &
          jsTypeName(cell.kind))
  result = initQrMatrix(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let cell = v.arr[y].arr[x]
      result[x, y] = cell.kind == nvkBool and cell.b or
        cell.kind == nvkInt and cell.i == 1

proc decodeFamilyName(f: QrFamily): string =
  case f
  of famModel2: "model2"
  of famModel1: "model1"
  of famMicro: "micro"
  of famRmqr: "rmqr"

proc decodeVersionName(r: QrDecodeResult): string =
  ## Human version: ints for Model 1/2, "M1" for Micro, "R11x139" for rMQR.
  case r.family
  of famMicro:
    if r.version >= 1 and r.version <= 4:
      "M" & $r.version
    else:
      $r.version
  of famRmqr:
    if r.version >= 1 and r.version <= 32:
      rmqrSizeName(r.version - 1)
    else:
      $r.version
  else:
    $r.version

## Builds the std/qr namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn encode(text: string, optsObj ?: JSObjectRef):
      ## qr.encode(text[, {ecLevel, family, version, mask, eci}]) ->
      ## {family, version, width, height, size, ecLevel, mask, svg,
      ## terminal, modules}. family is model2 (default), model1, micro
      ## or rmqr; version pins the symbol (Model 2: 1-40, Model 1:
      ## 0-12 with 0 = auto, Micro: "M1"-"M4", rMQR: "R11x139"; omit
      ## for smallest fit); mask is 0-7 (-1 = auto, not for rMQR);
      ## eci is Model 2 only.
      var level = ecMedium
      var fam = qfModel2
      var mask = -1
      var eci: int64 = 0
      var ver = NimValue(kind: nvkUndefined)
      if optsObj != nil:
        try:
          level = ecLevelArg(ctx, optsObj)
          var famStr = ""
          if getOptStr(ctx, optsObj, "family", famStr):
            fam = parseFamily(famStr)
          ver = getVersionField(ctx, optsObj)
          var maskV: int64 = -1
          if getOptInt(ctx, optsObj, "mask", maskV):
            if maskV < -1 or maskV > 7:
              raise newException(CatchableError,
                "options.mask must be 0 .. 7 (-1 = auto)")
            mask = int(maskV)
          var eciV: int64 = 0
          if getOptInt(ctx, optsObj, "eci", eciV):
            if eciV < 0:
              raise newException(CatchableError,
                "options.eci must be a non-negative integer")
            eci = eciV
        except CatchableError as e:
          throwTypeError(ctx, "encode: " & e.msg, exception)
          return nil
      if fam == qfRmqr and mask != -1:
        throwTypeError(ctx, "encode: options.mask is not supported for rMQR",
          exception)
        return nil
      if eci != 0 and fam != qfModel2:
        throwTypeError(ctx, "encode: options.eci is only supported for Model 2",
          exception)
        return nil
      try:
        let (m, version) = doEncodeQr(text, fam, level, ver, mask, eci)
        let famName = case fam
          of qfModel2: "model2"
          of qfModel1: "model1"
          of qfMicro: "micro"
          of qfRmqr: "rmqr"
        matrixResult(ctx, m, famName, version, ecName(level), mask,
          "encode", exception)
      except CatchableError as e:
        throwTypeError(ctx, "encode: " & e.msg, exception)
        nil

    module.registerFn encodeAqr(mainPayload: string, ringPayload: string,
        optsObj ?: JSObjectRef):
      ## qr.encodeAqr(mainPayload, ringPayload[, {ecLevel, version}]) ->
      ## encode-shape object with family "aqr": a Model 2 core plus a
      ## data ring around it. version pins the core Model 2 version.
      var level = ecMedium
      var pinned = 0
      if optsObj != nil:
        try:
          level = ecLevelArg(ctx, optsObj)
          let ver = getVersionField(ctx, optsObj)
          if ver.kind != nvkUndefined:
            pinned = versionInt(ver, 0, 40, "AQR core")
        except CatchableError as e:
          throwTypeError(ctx, "encodeAqr: " & e.msg, exception)
          return nil
      try:
        let m = encodeAqr(mainPayload, ringPayload, level, pinned)
        let core = aqrCoreVersion(m.width)
        let version = if core > 0: $core else: $m.width
        matrixResult(ctx, m, "aqr", version, ecName(level), -1,
          "encodeAqr", exception)
      except CatchableError as e:
        throwTypeError(ctx, "encodeAqr: " & e.msg, exception)
        nil

    module.registerFn decode(matrix: NimValue, optsObj ?: JSObjectRef):
      ## qr.decode(matrix[, {family}]) -> {text, family, version,
      ## ecLevel, mask, eci} (plus ring for AQR). matrix is an array of
      ## equal-length rows of 0/1 (booleans work too), e.g. from
      ## .modules. Without family the symbol type is auto-detected;
      ## pass family ("model2", "model1", "micro", "rmqr", "aqr") to
      ## pin it.
      var famName = ""
      if optsObj != nil:
        try:
          discard getOptStr(ctx, optsObj, "family", famName)
        except CatchableError as e:
          throwTypeError(ctx, "decode: " & e.msg, exception)
          return nil
      if famName.len > 0 and famName.toLowerAscii() notin
          ["model2", "model-2", "m2", "qr", "model1", "model-1", "m1",
           "micro", "microqr", "micro-qr", "micro-qr-code", "rmqr",
           "r-mqr", "rectangular", "rectangular-micro", "aqr"]:
        throwTypeError(ctx, "decode: options.family must be one of model2, " &
          "model1, micro, rmqr, aqr", exception)
        return nil
      let famKey = famName.toLowerAscii()
      var m: QrMatrix
      try:
        m = matrixFromJS(matrix, "decode")
      except CatchableError as e:
        throwTypeError(ctx, e.msg, exception)
        return nil
      let square = m.width == m.height
      var res: QrDecodeResult
      var ring = ""
      var viaAqr = false
      var found = false
      try:
        if famKey.len == 0 or famKey in ["model2", "model-2", "m2", "qr"]:
          if square:
            try:
              res = decodeQrMatrix(m)
              found = res.ok
            except CatchableError:
              discard
        if not found and (famKey.len == 0 or
            famKey in ["model1", "model-1", "m1"]) and square:
          try:
            res = decodeModel1Matrix(m)
            found = res.ok
          except CatchableError:
            discard
        if not found and (famKey.len == 0 or famKey in ["micro",
            "microqr", "micro-qr", "micro-qr-code"]) and square:
          try:
            res = decodeMicroMatrix(m)
            found = res.ok
          except CatchableError:
            discard
        if not found and (famKey.len == 0 or famKey in ["rmqr", "r-mqr",
            "rectangular", "rectangular-micro"]):
          try:
            res = decodeRmqrMatrix(m)
            found = res.ok
          except CatchableError:
            discard
        if not found and (famKey.len == 0 or famKey == "aqr"):
          try:
            let core = decodeAqrCore(m)
            if core.ok:
              res = core
              found = true
              viaAqr = true
              try:
                ring = readAqrRing(m)
              except QrError:
                ring = ""
          except CatchableError:
            discard
      except CatchableError as e:
        throwTypeError(ctx, "decode: " & e.msg, exception)
        return nil
      if not found:
        if famKey.len > 0:
          throwError(ctx, "decode: matrix is not a readable " & famName &
            " symbol", exception)
        else:
          throwError(ctx, "decode: no readable QR symbol in matrix",
            exception)
        return nil
      let obj = newObject(ctx)
      if not setPropChecked(ctx, obj, "text", toJS(ctx, res.text),
          "decode", exception):
        return nil
      let famStr = if viaAqr: "aqr" else: decodeFamilyName(res.family)
      if not setPropChecked(ctx, obj, "family", toJS(ctx, famStr),
          "decode", exception):
        return nil
      if not setPropChecked(ctx, obj, "version",
          toJS(ctx, decodeVersionName(res)), "decode", exception):
        return nil
      if not setPropChecked(ctx, obj, "ecLevel",
          toJS(ctx, ecName(res.ecLevel)), "decode", exception):
        return nil
      if not setPropChecked(ctx, obj, "mask", toJS(ctx, res.mask),
          "decode", exception):
        return nil
      if not setPropChecked(ctx, obj, "eci", toJS(ctx, res.eci),
          "decode", exception):
        return nil
      if famStr == "aqr":
        if not setPropChecked(ctx, obj, "ring", toJS(ctx, ring),
            "decode", exception):
          return nil
      obj

    module.registerFn wifi(ssid: string, optsObj ?: JSObjectRef):
      ## qr.wifi(ssid[, {password, encryption, hidden}]) -> string
      ## ("WIFI:..."). encryption is WPA, WEP or nopass; an empty
      ## password implies nopass. hidden marks the network hidden.
      var password = ""
      var encryption = "WPA"
      var hidden = false
      if optsObj != nil:
        try:
          discard getOptStr(ctx, optsObj, "password", password)
          discard getOptStr(ctx, optsObj, "encryption", encryption)
          discard getOptBool(ctx, optsObj, "hidden", hidden)
        except CatchableError as e:
          throwTypeError(ctx, "wifi: " & e.msg, exception)
          return nil
      try:
        toJS(ctx, makeWifi(ssid, password, encryption, hidden))
      except CatchableError as e:
        throwTypeError(ctx, "wifi: " & e.msg, exception)
        nil

    module.registerFn mecard(name: string, optsObj ?: JSObjectRef):
      ## qr.mecard(name[, {phone, email, url}]) -> string
      ## ("MECARD:...").
      var phone = ""
      var email = ""
      var url = ""
      if optsObj != nil:
        try:
          discard getOptStr(ctx, optsObj, "phone", phone)
          discard getOptStr(ctx, optsObj, "email", email)
          discard getOptStr(ctx, optsObj, "url", url)
        except CatchableError as e:
          throwTypeError(ctx, "mecard: " & e.msg, exception)
          return nil
      try:
        toJS(ctx, makeMecard(name, phone, email, url))
      except CatchableError as e:
        throwTypeError(ctx, "mecard: " & e.msg, exception)
        nil

    module.registerFn url(url: string):
      ## qr.url(url) -> string. A bare domain gains an https:// scheme;
      ## absolute URLs pass through unchanged.
      try:
        toJS(ctx, makeUrl(url))
      except CatchableError as e:
        throwTypeError(ctx, "url: " & e.msg, exception)
        nil

    module.registerFn sms(phone: string, message ?: string):
      ## qr.sms(phone[, message]) -> string ("SMSTO:...").
      try:
        toJS(ctx, makeSms(phone, message))
      except CatchableError as e:
        throwTypeError(ctx, "sms: " & e.msg, exception)
        nil

    module.registerFn email(to: string, optsObj ?: JSObjectRef):
      ## qr.email(to[, {subject, body}]) -> string ("mailto:...").
      var subject = ""
      var body = ""
      if optsObj != nil:
        try:
          discard getOptStr(ctx, optsObj, "subject", subject)
          discard getOptStr(ctx, optsObj, "body", body)
        except CatchableError as e:
          throwTypeError(ctx, "email: " & e.msg, exception)
          return nil
      try:
        toJS(ctx, makeEmail(to, subject, body))
      except CatchableError as e:
        throwTypeError(ctx, "email: " & e.msg, exception)
        nil

    module.registerFn sqrc(publicData: string, privateData: string,
        key: JSValueRef, optsObj ?: JSObjectRef):
      ## qr.sqrc(publicData, privateData, key[, {ecLevel, extended}]) ->
      ## encode-shape object with family "sqrc": a Model 2 symbol whose
      ## private area opens only with the key (string or Uint8Array).
      var keyBytes: string
      if not readBytesParam(ctx, key, "sqrc", "key", docBlock, exception,
          keyBytes):
        return nil
      var level = ecMedium
      var extended = false
      if optsObj != nil:
        try:
          level = ecLevelArg(ctx, optsObj)
          discard getOptBool(ctx, optsObj, "extended", extended)
        except CatchableError as e:
          throwTypeError(ctx, "sqrc: " & e.msg, exception)
          return nil
      try:
        var opts = defaultQrEncodeOptions()
        opts.ecLevel = level
        let m =
          if keyBytes.len > 0:
            encodeSqrc(publicData, privateData,
              keyBytes.toOpenArrayByte(0, keyBytes.high), opts, extended)
          else:
            encodeSqrc(publicData, privateData, newSeq[byte](), opts,
              extended)
        matrixResult(ctx, m, "sqrc", $((m.width - 17) div 4),
          ecName(level), -1, "sqrc", exception)
      except CatchableError as e:
        throwTypeError(ctx, "sqrc: " & e.msg, exception)
        nil

    module.registerFn unsqrc(text: string, key: JSValueRef):
      ## qr.unsqrc(text, key) -> {ok, publicText, privateText}. Opens a
      ## scanned SQRC payload; privateText is empty when the key is
      ## wrong (ok stays true, the public area still reads).
      var keyBytes: string
      if not readBytesParam(ctx, key, "unsqrc", "key", docBlock, exception,
          keyBytes):
        return nil
      let r =
        if keyBytes.len > 0:
          decodeSqrcText(text,
            keyBytes.toOpenArrayByte(0, keyBytes.high))
        else:
          decodeSqrcText(text, newSeq[byte]())
      let obj = newObject(ctx)
      if not setPropChecked(ctx, obj, "ok", toJS(ctx, r.ok),
          "unsqrc", exception):
        return nil
      if not setPropChecked(ctx, obj, "publicText",
          toJS(ctx, r.publicText), "unsqrc", exception):
        return nil
      if not setPropChecked(ctx, obj, "privateText",
          toJS(ctx, r.privateText), "unsqrc", exception):
        return nil
      obj
