# Carne std/vcard: vCard contact parsing and serialization via openparser.
#
#   const vcard = require("std/vcard");
#   vcard.parse(text) -> contact[] (one object per VCARD)
#   vcard.stringify(contacts) -> string (VCARD documents, CRLF)
#
# Contact objects are plain data (absent options stay absent).
# stringify accepts one contact or an array of contacts; unknown input
# keys are ignored, so a stray reference cycle hiding behind an unknown
# key cannot hang it (all followed paths are depth-capped).

import std/math
import std/options

import javascriptcore

import pkg/openparser/vcard

import ../bridge



proc strsToJS(ctx: JSContextRef; strs: seq[string]): JSValueRef =
  var vals: seq[JSValueRef] = @[]
  for s in strs:
    vals.add(toJS(ctx, s))
  makeJSArray(ctx, vals)

proc paramsToJS(ctx: JSContextRef; params: seq[VCardParam];
    fname: string; exception: ptr JSValueRef): JSValueRef =
  var vals: seq[JSValueRef] = @[]
  for p in params:
    var vvals: seq[JSValueRef] = @[]
    for v in p.values:
      vvals.add(toJS(ctx, v))
    let values = makeJSArray(ctx, vvals)
    if values == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "name", toJS(ctx, p.name), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "values", values, fname, exception):
      return nil
    vals.add(obj)
  makeJSArray(ctx, vals)

proc commonToJS(ctx: JSContextRef; obj: JSObjectRef; types: seq[string];
    pref: Option[int]; altId: Option[string]; params: seq[VCardParam];
    fname: string; exception: ptr JSValueRef): bool =
  let t = strsToJS(ctx, types)
  if t == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return false
  if not setPropChecked(ctx, obj, "types", t, fname, exception):
    return false
  if not optSetInt(ctx, obj, "pref", pref, fname, exception):
    return false
  if not optSetStr(ctx, obj, "altId", altId, fname, exception):
    return false
  if params.len > 0:
    let p = paramsToJS(ctx, params, fname, exception)
    if p == nil:
      return false
    if not setPropChecked(ctx, obj, "params", p, fname, exception):
      return false
  true

proc valueToJS(ctx: JSContextRef; value: string; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "value", toJS(ctx, value), fname,
      exception):
    return nil
  obj

proc photoToJS(ctx: JSContextRef; p: VCardPhoto; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = valueToJS(ctx, p.value, fname, exception)
  if obj == nil:
    return nil
  if not optSetStr(ctx, obj, "mediaType", p.mediaType, fname, exception):
    return nil
  if not commonToJS(ctx, obj, p.types, p.pref, p.altId, p.params,
      fname, exception):
    return nil
  obj

proc adrToJS(ctx: JSContextRef; a: VCardAdr; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  for (key, val) in [("poBox", a.poBox), ("ext", a.ext),
      ("street", a.street), ("locality", a.locality),
      ("region", a.region), ("postal", a.postal),
      ("country", a.country)]:
    if not setPropChecked(ctx, obj, key, toJS(ctx, val), fname,
        exception):
      return nil
  if not optSetStr(ctx, obj, "label", a.label, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "geo", a.geo, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "tz", a.tz, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "altId", a.altId, fname, exception):
    return nil
  if not optSetInt(ctx, obj, "pref", a.pref, fname, exception):
    return nil
  let t = strsToJS(ctx, a.types)
  if t == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "types", t, fname, exception):
    return nil
  if a.params.len > 0:
    let p = paramsToJS(ctx, a.params, fname, exception)
    if p == nil:
      return nil
    if not setPropChecked(ctx, obj, "params", p, fname, exception):
      return nil
  obj

proc labeledToJS(ctx: JSContextRef; value: string; label: Option[string];
    types: seq[string]; pref: Option[int]; altId: Option[string];
    params: seq[VCardParam]; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## value + label + common tail (tel, url shapes).
  let obj = valueToJS(ctx, value, fname, exception)
  if obj == nil:
    return nil
  if not optSetStr(ctx, obj, "label", label, fname, exception):
    return nil
  if not commonToJS(ctx, obj, types, pref, altId, params, fname,
      exception):
    return nil
  obj

proc plainToJS(ctx: JSContextRef; value: string; types: seq[string];
    pref: Option[int]; altId: Option[string]; params: seq[VCardParam];
    fname: string; exception: ptr JSValueRef): JSValueRef =
  ## value + common tail, no label (email, impp, lang shapes).
  let obj = valueToJS(ctx, value, fname, exception)
  if obj == nil:
    return nil
  if not commonToJS(ctx, obj, types, pref, altId, params, fname,
      exception):
    return nil
  obj

proc telToJS(ctx: JSContextRef; t: VCardTel; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  labeledToJS(ctx, t.value, t.label, t.types, t.pref, t.altId, t.params,
    fname, exception)

proc emailToJS(ctx: JSContextRef; e: VCardEmail; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  plainToJS(ctx, e.value, e.types, e.pref, e.altId, e.params, fname,
    exception)

proc imppToJS(ctx: JSContextRef; i: VCardImpp; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  plainToJS(ctx, i.value, i.types, i.pref, i.altId, i.params, fname,
    exception)

proc langToJS(ctx: JSContextRef; l: VCardLang; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  plainToJS(ctx, l.value, l.types, l.pref, l.altId, l.params, fname,
    exception)

proc urlToJS(ctx: JSContextRef; u: VCardUrl; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  labeledToJS(ctx, u.value, u.label, u.types, u.pref, u.altId, u.params,
    fname, exception)

proc memberToJS(ctx: JSContextRef; m: VCardMember; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = valueToJS(ctx, m.value, fname, exception)
  if obj == nil:
    return nil
  if not optSetInt(ctx, obj, "pref", m.pref, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "altId", m.altId, fname, exception):
    return nil
  if m.params.len > 0:
    let p = paramsToJS(ctx, m.params, fname, exception)
    if p == nil:
      return nil
    if not setPropChecked(ctx, obj, "params", p, fname, exception):
      return nil
  obj

proc relatedToJS(ctx: JSContextRef; r: VCardRelated; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = valueToJS(ctx, r.value, fname, exception)
  if obj == nil:
    return nil
  if not optSetStr(ctx, obj, "relType", r.relType, fname, exception):
    return nil
  if not commonToJS(ctx, obj, r.types, r.pref, r.altId, r.params,
      fname, exception):
    return nil
  obj

proc datePropToJS(ctx: JSContextRef; d: VCardDateProp; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "value", toJS(ctx, d.value), fname,
      exception):
    return nil
  if not setPropChecked(ctx, obj, "valueType", toJS(ctx, d.valueType),
      fname, exception):
    return nil
  if not optSetStr(ctx, obj, "altId", d.altId, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "calscale", d.calscale, fname, exception):
    return nil
  if d.params.len > 0:
    let p = paramsToJS(ctx, d.params, fname, exception)
    if p == nil:
      return nil
    if not setPropChecked(ctx, obj, "params", p, fname, exception):
      return nil
  obj

proc kindToJS(ctx: JSContextRef; k: VCardKindValue): JSValueRef =
  case k.kind
  of vkIndividual: toJS(ctx, "individual")
  of vkGroup: toJS(ctx, "group")
  of vkOrg: toJS(ctx, "org")
  of vkLocation: toJS(ctx, "location")
  of vkApplication: toJS(ctx, "application")
  of vkCustom: toJS(ctx, k.custom)

proc seqToJS[T](ctx: JSContextRef; items: seq[T]; fname: string;
    exception: ptr JSValueRef;
    conv: proc(ctx: JSContextRef; x: T; fname: string;
      exception: ptr JSValueRef): JSValueRef): JSValueRef =
  var vals: seq[JSValueRef] = @[]
  for item in items:
    let j = conv(ctx, item, fname, exception)
    if j == nil:
      return nil
    vals.add(j)
  let arr = makeJSArray(ctx, vals)
  if arr == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  arr

proc cardToJS(ctx: JSContextRef; c: VCard; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "version", toJS(ctx, $c.version),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "fn", toJS(ctx, c.fn), fname,
      exception):
    return nil
  if c.n.isSome:
    let n = c.n.get()
    let nobj = newObject(ctx)
    for (key, val) in [("family", n.family), ("given", n.given),
        ("additional", n.additional), ("prefix", n.prefix),
        ("suffix", n.suffix)]:
      if not setPropChecked(ctx, nobj, key, toJS(ctx, val), fname,
          exception):
        return nil
    if not setPropChecked(ctx, obj, "n", nobj, fname, exception):
      return nil
  template setSeq(key: string; items, conv: untyped): untyped =
    let arrVal = seqToJS(ctx, items, fname, exception, conv)
    if arrVal == nil:
      return nil
    if not setPropChecked(ctx, obj, key, arrVal, fname, exception):
      return nil
  template setStrs(key: string; items: seq[string]): untyped =
    let arrVal = strsToJS(ctx, items)
    if arrVal == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, key, arrVal, fname, exception):
      return nil
  setStrs("nicknames", c.nicknames)
  setSeq("photos", c.photos, photoToJS)
  if c.bday.isSome:
    let b = datePropToJS(ctx, c.bday.get(), fname, exception)
    if b == nil:
      return nil
    if not setPropChecked(ctx, obj, "bday", b, fname, exception):
      return nil
  if c.anniversary.isSome:
    let a = datePropToJS(ctx, c.anniversary.get(), fname, exception)
    if a == nil:
      return nil
    if not setPropChecked(ctx, obj, "anniversary", a, fname,
        exception):
      return nil
  if c.gender.isSome:
    let g = c.gender.get()
    let gobj = newObject(ctx)
    if not setPropChecked(ctx, gobj, "sex", toJS(ctx, g.sex), fname,
        exception):
      return nil
    if not setPropChecked(ctx, gobj, "identity", toJS(ctx, g.identity),
        fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "gender", gobj, fname, exception):
      return nil
  setSeq("adrs", c.adrs, adrToJS)
  setSeq("tels", c.tels, telToJS)
  setSeq("emails", c.emails, emailToJS)
  setSeq("impps", c.impps, imppToJS)
  setSeq("langs", c.langs, langToJS)
  if not optSetStr(ctx, obj, "tz", c.tz, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "geo", c.geo, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "title", c.title, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "role", c.role, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "logo", c.logo, fname, exception):
    return nil
  if c.org.isSome:
    let o = c.org.get()
    let oobj = newObject(ctx)
    if not setPropChecked(ctx, oobj, "name", toJS(ctx, o.name), fname,
        exception):
      return nil
    let units = strsToJS(ctx, o.units)
    if units == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, oobj, "units", units, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "org", oobj, fname, exception):
      return nil
  setSeq("members", c.members, memberToJS)
  setSeq("related", c.related, relatedToJS)
  setStrs("categories", c.categories)
  if not optSetStr(ctx, obj, "note", c.note, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "prodId", c.prodId, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "rev", c.rev, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "sortString", c.sortString, fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "sound", c.sound, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "uid", c.uid, fname, exception):
    return nil
  if c.kind.isSome:
    if not setPropChecked(ctx, obj, "kind",
        kindToJS(ctx, c.kind.get()), fname, exception):
      return nil
  var pidVals: seq[JSValueRef] = @[]
  for pid in c.clientPidMaps:
    let pobj = newObject(ctx)
    if not setPropChecked(ctx, pobj, "pid", toJS(ctx, pid.pid), fname,
        exception):
      return nil
    if not setPropChecked(ctx, pobj, "uri", toJS(ctx, pid.uri), fname,
        exception):
      return nil
    pidVals.add(pobj)
  let pids = makeJSArray(ctx, pidVals)
  if pids == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "clientPidMaps", pids, fname,
      exception):
    return nil
  setSeq("urls", c.urls, urlToJS)
  if not optSetStr(ctx, obj, "key", c.key, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "fbUrl", c.fbUrl, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "calAdrUri", c.calAdrUri, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "calUri", c.calUri, fname, exception):
    return nil
  setStrs("xml", c.xml)
  if c.extraProps.len > 0:
    var evals: seq[JSValueRef] = @[]
    for p in c.extraProps:
      let pobj = newObject(ctx)
      if not setPropChecked(ctx, pobj, "group", toJS(ctx, p.group),
          fname, exception):
        return nil
      if not setPropChecked(ctx, pobj, "name", toJS(ctx, p.name),
          fname, exception):
        return nil
      let prm = paramsToJS(ctx, p.params, fname, exception)
      if prm == nil:
        return nil
      if not setPropChecked(ctx, pobj, "params", prm, fname, exception):
        return nil
      if not setPropChecked(ctx, pobj, "value", toJS(ctx, p.value),
          fname, exception):
        return nil
      evals.add(pobj)
    let extra = makeJSArray(ctx, evals)
    if extra == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "extraProps", extra, fname,
        exception):
      return nil
  obj

proc vcardErr(msg: string): ref CatchableError =
  newException(CatchableError, msg)

proc vRawHas(ctx: JSContextRef; obj: JSValueRef; key: string): bool =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  ex == nil and prop != nil and
    JSValueGetType(ctx, prop) != kJSTypeUndefined

proc vRawGet(ctx: JSContextRef; obj: JSValueRef; key: string): JSValueRef =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  if ex != nil or prop == nil:
    raise vcardErr("has an unreadable property \"" & key & "\"")
  prop

proc vRequireObj(ctx: JSContextRef; v: JSValueRef; what: string): JSValueRef =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      JSValueIsArray(ctx, v) or JSObjectIsFunction(ctx, v):
    raise vcardErr(what)
  v

proc vReadStr(ctx: JSContextRef; v: JSValueRef; what: string): string =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeString:
    raise vcardErr(what)
  var ex: JSValueRef = nil
  let s = JSValueToStringCopy(ctx, v, addr ex)
  if s == nil:
    raise vcardErr(what)
  defer: JSStringRelease(s)
  $s

proc vReadOptStr(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[string] =
  if not vRawHas(ctx, obj, key):
    return none(string)
  some(vReadStr(ctx, vRawGet(ctx, obj, key),
    "\"" & key & "\" must be a string"))

proc vReadOptInt(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[int] =
  if not vRawHas(ctx, obj, key):
    return none(int)
  let v = vRawGet(ctx, obj, key)
  if JSValueGetType(ctx, v) != kJSTypeNumber:
    raise vcardErr("\"" & key & "\" must be an integer")
  var ex: JSValueRef = nil
  let f = JSValueToNumber(ctx, v, addr ex)
  if ex != nil or f != trunc(f) or abs(f) >= 9223372036854775808.0:
    raise vcardErr("\"" & key & "\" must be an integer")
  some(int(f))

proc vRawLen(ctx: JSContextRef; v: JSValueRef; what: string): int =
  var ex: JSValueRef = nil
  let lenKey = newJSString("length")
  defer: JSStringRelease(lenKey)
  let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
  if ex != nil or lenV == nil:
    raise vcardErr(what)
  var ex2: JSValueRef = nil
  let n = int(JSValueToNumber(ctx, lenV, addr ex2))
  if ex2 != nil or n < 0:
    raise vcardErr(what)
  n

proc vRawIndex(ctx: JSContextRef; v: JSValueRef; idx: int;
    what: string): JSValueRef =
  var eEx: JSValueRef = nil
  let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx), addr eEx)
  if eEx != nil or item == nil:
    raise vcardErr(what)
  item

proc vRequireArr(ctx: JSContextRef; v: JSValueRef; what: string): JSValueRef =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      not JSValueIsArray(ctx, v):
    raise vcardErr(what)
  v

proc vReadStrs(ctx: JSContextRef; obj: JSValueRef;
    key: string): seq[string] =
  if not vRawHas(ctx, obj, key):
    return @[]
  let v = vRequireArr(ctx, vRawGet(ctx, obj, key),
    "\"" & key & "\" must be an array")
  let n = vRawLen(ctx, v, "\"" & key & "\" must be an array")
  for idx in 0 ..< n:
    result.add(vReadStr(ctx, vRawIndex(ctx, v, idx,
      "\"" & key & "\" must list strings"),
      "\"" & key & "\" must list strings"))

proc vReadParams(ctx: JSContextRef; v: JSValueRef): seq[VCardParam] =
  let arr = vRequireArr(ctx, v, "\"params\" must be an array")
  let n = vRawLen(ctx, arr, "\"params\" must be an array")
  for idx in 0 ..< n:
    let item = vRequireObj(ctx, vRawIndex(ctx, arr, idx,
      "params entries need {name, values}"),
      "params entries need {name, values}")
    if not vRawHas(ctx, item, "name") or not vRawHas(ctx, item, "values"):
      raise vcardErr("params entries need {name, values}")
    let name = vReadStr(ctx, vRawGet(ctx, item, "name"),
      "params entries need {name, values}")
    let vv = vRequireArr(ctx, vRawGet(ctx, item, "values"),
      "\"values\" must be an array")
    let vn = vRawLen(ctx, vv, "\"values\" must be an array")
    var values: seq[string] = @[]
    for j in 0 ..< vn:
      values.add(vReadStr(ctx, vRawIndex(ctx, vv, j,
        "\"values\" must list strings"),
        "\"values\" must list strings"))
    result.add(VCardParam(name: name, values: values))

proc vReadOptParams(ctx: JSContextRef; obj: JSValueRef;
    key: string): seq[VCardParam] =
  if not vRawHas(ctx, obj, key):
    return @[]
  vReadParams(ctx, vRawGet(ctx, obj, key))

proc vReadCommon(ctx: JSContextRef; obj: JSValueRef;
    types: var seq[string]; pref: var Option[int];
    altId: var Option[string]; params: var seq[VCardParam]) =
  types = vReadStrs(ctx, obj, "types")
  pref = vReadOptInt(ctx, obj, "pref")
  altId = vReadOptStr(ctx, obj, "altId")
  params = vReadOptParams(ctx, obj, "params")

proc vReadPhoto(ctx: JSContextRef; v: JSValueRef): VCardPhoto =
  let o = vRequireObj(ctx, v, "photos entries must be {value, ...}")
  if not vRawHas(ctx, o, "value"):
    raise vcardErr("photos entries must be {value, ...}")
  result = VCardPhoto(value: vReadStr(ctx, vRawGet(ctx, o, "value"),
    "photos entries must be {value, ...}"))
  result.mediaType = vReadOptStr(ctx, o, "mediaType")
  vReadCommon(ctx, o, result.types, result.pref, result.altId,
    result.params)

proc vReadAdr(ctx: JSContextRef; v: JSValueRef): VCardAdr =
  let o = vRequireObj(ctx, v, "adrs entries must be objects")
  proc f(key: string): string =
    if not vRawHas(ctx, o, key):
      return ""
    vReadStr(ctx, vRawGet(ctx, o, key), "\"" & key & "\" must be a string")
  result = VCardAdr(poBox: f("poBox"), ext: f("ext"), street: f("street"),
    locality: f("locality"), region: f("region"), postal: f("postal"),
    country: f("country"))
  result.label = vReadOptStr(ctx, o, "label")
  result.geo = vReadOptStr(ctx, o, "geo")
  result.tz = vReadOptStr(ctx, o, "tz")
  result.altId = vReadOptStr(ctx, o, "altId")
  result.pref = vReadOptInt(ctx, o, "pref")
  result.types = vReadStrs(ctx, o, "types")
  result.params = vReadOptParams(ctx, o, "params")

proc vReadLabeled(ctx: JSContextRef; v: JSValueRef; what: string;
    withLabel: bool): tuple[value: string; label: Option[string];
    types: seq[string]; pref: Option[int]; altId: Option[string];
    params: seq[VCardParam]] =
  let o = vRequireObj(ctx, v, what)
  if not vRawHas(ctx, o, "value"):
    raise vcardErr(what)
  result.value = vReadStr(ctx, vRawGet(ctx, o, "value"), what)
  if withLabel:
    result.label = vReadOptStr(ctx, o, "label")
  vReadCommon(ctx, o, result.types, result.pref, result.altId,
    result.params)

proc vReadTel(ctx: JSContextRef; v: JSValueRef): VCardTel =
  let t = vReadLabeled(ctx, v, "tels entries must be {value, ...}", true)
  VCardTel(value: t.value, types: t.types, pref: t.pref, altId: t.altId,
    label: t.label, params: t.params)

proc vReadEmail(ctx: JSContextRef; v: JSValueRef): VCardEmail =
  let t = vReadLabeled(ctx, v, "emails entries must be {value, ...}", false)
  VCardEmail(value: t.value, types: t.types, pref: t.pref,
    altId: t.altId, params: t.params)

proc vReadImpp(ctx: JSContextRef; v: JSValueRef): VCardImpp =
  let t = vReadLabeled(ctx, v, "impps entries must be {value, ...}", false)
  VCardImpp(value: t.value, types: t.types, pref: t.pref,
    altId: t.altId, params: t.params)

proc vReadLang(ctx: JSContextRef; v: JSValueRef): VCardLang =
  let t = vReadLabeled(ctx, v, "langs entries must be {value, ...}", false)
  VCardLang(value: t.value, types: t.types, pref: t.pref,
    altId: t.altId, params: t.params)

proc vReadUrl(ctx: JSContextRef; v: JSValueRef): VCardUrl =
  let t = vReadLabeled(ctx, v, "urls entries must be {value, ...}", true)
  VCardUrl(value: t.value, types: t.types, pref: t.pref, altId: t.altId,
    params: t.params, label: t.label)

proc vReadMember(ctx: JSContextRef; v: JSValueRef): VCardMember =
  let o = vRequireObj(ctx, v, "members entries must be {value, ...}")
  if not vRawHas(ctx, o, "value"):
    raise vcardErr("members entries must be {value, ...}")
  result = VCardMember(value: vReadStr(ctx, vRawGet(ctx, o, "value"),
    "members entries must be {value, ...}"))
  result.pref = vReadOptInt(ctx, o, "pref")
  result.altId = vReadOptStr(ctx, o, "altId")
  result.params = vReadOptParams(ctx, o, "params")

proc vReadRelated(ctx: JSContextRef; v: JSValueRef): VCardRelated =
  let o = vRequireObj(ctx, v, "related entries must be {value, ...}")
  if not vRawHas(ctx, o, "value"):
    raise vcardErr("related entries must be {value, ...}")
  result = VCardRelated(value: vReadStr(ctx, vRawGet(ctx, o, "value"),
    "related entries must be {value, ...}"))
  result.relType = vReadOptStr(ctx, o, "relType")
  vReadCommon(ctx, o, result.types, result.pref, result.altId,
    result.params)

proc vReadDateProp(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[VCardDateProp] =
  if not vRawHas(ctx, obj, key):
    return none(VCardDateProp)
  let o = vRequireObj(ctx, vRawGet(ctx, obj, key),
    "\"" & key & "\" must be {value, ...}")
  if not vRawHas(ctx, o, "value"):
    raise vcardErr("\"" & key & "\" must be {value, ...}")
  var d = VCardDateProp(value: vReadStr(ctx, vRawGet(ctx, o, "value"),
    "\"" & key & "\" must be {value, ...}"),
    valueType: if vRawHas(ctx, o, "valueType"):
      vReadStr(ctx, vRawGet(ctx, o, "valueType"),
        "\"valueType\" must be a string") else: "")
  d.altId = vReadOptStr(ctx, o, "altId")
  d.calscale = vReadOptStr(ctx, o, "calscale")
  d.params = vReadOptParams(ctx, o, "params")
  some(d)

proc vReadSeq[T](ctx: JSContextRef; obj: JSValueRef; key: string;
    what: string; conv: proc(ctx: JSContextRef;
    v: JSValueRef): T): seq[T] =
  if not vRawHas(ctx, obj, key):
    return @[]
  let v = vRequireArr(ctx, vRawGet(ctx, obj, key), what)
  let n = vRawLen(ctx, v, what)
  for idx in 0 ..< n:
    result.add(conv(ctx, vRawIndex(ctx, v, idx, what)))

proc vReadProp(ctx: JSContextRef; v: JSValueRef): VCardProp =
  let o = vRequireObj(ctx, v, "extraProps entries need {name, value}")
  if not vRawHas(ctx, o, "name") or not vRawHas(ctx, o, "value"):
    raise vcardErr("extraProps entries need {name, value}")
  var group = ""
  if vRawHas(ctx, o, "group"):
    group = vReadStr(ctx, vRawGet(ctx, o, "group"),
      "extraProps entries need {name, value}")
  result = VCardProp(group: group,
    name: vReadStr(ctx, vRawGet(ctx, o, "name"),
      "extraProps entries need {name, value}"),
    value: vReadStr(ctx, vRawGet(ctx, o, "value"),
      "extraProps entries need {name, value}"))
  if vRawHas(ctx, o, "params"):
    result.params = vReadParams(ctx, vRawGet(ctx, o, "params"))

proc jsToCard(ctx: JSContextRef; v: JSValueRef; depth: int): VCard =
  if depth > maxDumpDepth:
    raise vcardErr("contact is too deeply nested or circular")
  let o = vRequireObj(ctx, v, "contacts must be objects")
  result = VCard()
  if vRawHas(ctx, o, "version"):
    let vs = vReadStr(ctx, vRawGet(ctx, o, "version"),
      "\"version\" must be a string")
    result.version = if vs == "3.0": vv30 else: vv40
  else:
    result.version = vv40
  result.fn = if vRawHas(ctx, o, "fn"):
    vReadStr(ctx, vRawGet(ctx, o, "fn"), "\"fn\" must be a string")
  else: ""
  if vRawHas(ctx, o, "n"):
    let n = vRequireObj(ctx, vRawGet(ctx, o, "n"),
      "\"n\" must be {family, ...}")
    proc nf(key: string): string =
      if not vRawHas(ctx, n, key):
        return ""
      vReadStr(ctx, vRawGet(ctx, n, key), "\"" & key & "\" must be a string")
    result.n = some(VCardName(family: nf("family"), given: nf("given"),
      additional: nf("additional"), prefix: nf("prefix"),
      suffix: nf("suffix")))
  result.nicknames = vReadStrs(ctx, o, "nicknames")
  result.photos = vReadSeq(ctx, o, "photos",
    "photos must be an array", vReadPhoto)
  result.bday = vReadDateProp(ctx, o, "bday")
  result.anniversary = vReadDateProp(ctx, o, "anniversary")
  if vRawHas(ctx, o, "gender"):
    let g = vRequireObj(ctx, vRawGet(ctx, o, "gender"),
      "\"gender\" must be {sex, identity}")
    var sex = ""
    var ident = ""
    if vRawHas(ctx, g, "sex"):
      sex = vReadStr(ctx, vRawGet(ctx, g, "sex"),
        "\"sex\" must be a string")
    if vRawHas(ctx, g, "identity"):
      ident = vReadStr(ctx, vRawGet(ctx, g, "identity"),
        "\"identity\" must be a string")
    result.gender = some(VCardGender(sex: sex, identity: ident))
  result.adrs = vReadSeq(ctx, o, "adrs", "adrs must be an array", vReadAdr)
  result.tels = vReadSeq(ctx, o, "tels", "tels must be an array", vReadTel)
  result.emails = vReadSeq(ctx, o, "emails", "emails must be an array",
    vReadEmail)
  result.impps = vReadSeq(ctx, o, "impps", "impps must be an array",
    vReadImpp)
  result.langs = vReadSeq(ctx, o, "langs", "langs must be an array",
    vReadLang)
  result.tz = vReadOptStr(ctx, o, "tz")
  result.geo = vReadOptStr(ctx, o, "geo")
  result.title = vReadOptStr(ctx, o, "title")
  result.role = vReadOptStr(ctx, o, "role")
  result.logo = vReadOptStr(ctx, o, "logo")
  if vRawHas(ctx, o, "org"):
    let oo = vRequireObj(ctx, vRawGet(ctx, o, "org"),
      "\"org\" must be {name, units}")
    if not vRawHas(ctx, oo, "name"):
      raise vcardErr("\"org\" must be {name, units}")
    result.org = some(VCardOrg(name: vReadStr(ctx, vRawGet(ctx, oo, "name"),
      "\"org\" must be {name, units}"), units: vReadStrs(ctx, oo, "units")))
  result.members = vReadSeq(ctx, o, "members", "members must be an array",
    vReadMember)
  result.related = vReadSeq(ctx, o, "related", "related must be an array",
    vReadRelated)
  result.categories = vReadStrs(ctx, o, "categories")
  result.note = vReadOptStr(ctx, o, "note")
  result.prodId = vReadOptStr(ctx, o, "prodId")
  result.rev = vReadOptStr(ctx, o, "rev")
  result.sortString = vReadOptStr(ctx, o, "sortString")
  result.sound = vReadOptStr(ctx, o, "sound")
  result.uid = vReadOptStr(ctx, o, "uid")
  if vRawHas(ctx, o, "kind"):
    let ks = vReadStr(ctx, vRawGet(ctx, o, "kind"),
      "\"kind\" must be a string")
    case ks
    of "individual": result.kind = some(VCardKindValue(kind: vkIndividual))
    of "group": result.kind = some(VCardKindValue(kind: vkGroup))
    of "org": result.kind = some(VCardKindValue(kind: vkOrg))
    of "location": result.kind = some(VCardKindValue(kind: vkLocation))
    of "application":
      result.kind = some(VCardKindValue(kind: vkApplication))
    else:
      result.kind = some(VCardKindValue(kind: vkCustom, custom: ks))
  if vRawHas(ctx, o, "clientPidMaps"):
    let v = vRequireArr(ctx, vRawGet(ctx, o, "clientPidMaps"),
      "clientPidMaps must be an array")
    let n = vRawLen(ctx, v, "clientPidMaps must be an array")
    for idx in 0 ..< n:
      let item = vRequireObj(ctx, vRawIndex(ctx, v, idx,
        "clientPidMaps entries need {pid, uri}"),
        "clientPidMaps entries need {pid, uri}")
      if not vRawHas(ctx, item, "pid") or not vRawHas(ctx, item, "uri"):
        raise vcardErr("clientPidMaps entries need {pid, uri}")
      let pv = vRawGet(ctx, item, "pid")
      if JSValueGetType(ctx, pv) != kJSTypeNumber:
        raise vcardErr("\"pid\" must be an integer")
      var ex: JSValueRef = nil
      let f = JSValueToNumber(ctx, pv, addr ex)
      if ex != nil or f != trunc(f):
        raise vcardErr("\"pid\" must be an integer")
      result.clientPidMaps.add(VCardClientPid(pid: int(f),
        uri: vReadStr(ctx, vRawGet(ctx, item, "uri"),
          "clientPidMaps entries need {pid, uri}")))
  result.urls = vReadSeq(ctx, o, "urls", "urls must be an array", vReadUrl)
  result.key = vReadOptStr(ctx, o, "key")
  result.fbUrl = vReadOptStr(ctx, o, "fbUrl")
  result.calAdrUri = vReadOptStr(ctx, o, "calAdrUri")
  result.calUri = vReadOptStr(ctx, o, "calUri")
  result.xml = vReadStrs(ctx, o, "xml")
  if vRawHas(ctx, o, "extraProps"):
    let v = vRequireArr(ctx, vRawGet(ctx, o, "extraProps"),
      "extraProps must be an array")
    let n = vRawLen(ctx, v, "extraProps must be an array")
    for idx in 0 ..< n:
      result.extraProps.add(vReadProp(ctx, vRawIndex(ctx, v, idx,
        "extraProps entries need {name, value}")))

## Builds the std/vcard namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## vcard.parse(text) -> contact[] (one object per VCARD)
      try:
        var vals: seq[JSValueRef] = @[]
        for c in parseVCards(text):
          let j = cardToJS(ctx, c, "parse", exception)
          if j == nil:
            return nil
          vals.add(j)
        let arr = makeJSArray(ctx, vals)
        if arr == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        arr
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn stringify(value: JSValueRef):
      ## vcard.stringify(contacts) -> string (VCARD documents)
      try:
        var cards: seq[VCard] = @[]
        if JSValueIsArray(ctx, value):
          var ex: JSValueRef = nil
          let lenKey = newJSString("length")
          defer: JSStringRelease(lenKey)
          let lenV = JSObjectGetProperty(ctx, value, lenKey, addr ex)
          if ex != nil or lenV == nil:
            throwError(ctx, "stringify: contacts must be an object or array",
              exception)
            return nil
          var ex2: JSValueRef = nil
          let n = int(JSValueToNumber(ctx, lenV, addr ex2))
          if ex2 != nil or n < 0:
            throwError(ctx, "stringify: contacts must be an object or array",
              exception)
            return nil
          for idx in 0 ..< n:
            var eEx: JSValueRef = nil
            let item = JSObjectGetPropertyAtIndex(ctx, value, cuint(idx),
              addr eEx)
            if eEx != nil or item == nil:
              throwError(ctx, "stringify: contacts must be an object or array",
                exception)
              return nil
            cards.add(jsToCard(ctx, item, 0))
        else:
          cards.add(jsToCard(ctx, value, 0))
        toJS(ctx, toVCards(cards))
      except CatchableError as e:
        throwError(ctx, "stringify: " & e.msg, exception)
        nil
