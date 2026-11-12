# Carne std/feed: RSS and Atom feed parsing and serialization via openparser.
#
#   const feed = require("std/feed");
#   feed.parseRss(text)      -> feed object with items[]
#   feed.stringifyRss(feed)  -> string (RSS 2.0 XML)
#   feed.parseAtom(text)     -> feed object with entries[]
#   feed.stringifyAtom(feed) -> string (Atom XML)
#
# Absent options stay absent; unknown input keys are ignored (all
# followed paths are depth-capped).

import std/math
import std/options

import javascriptcore

import pkg/openparser/[feed, rss]

import ../bridge



proc personsToJS[T](ctx: JSContextRef; persons: seq[T]; fname: string;
    exception: ptr JSValueRef;
    conv: proc(ctx: JSContextRef; p: T; fname: string;
      exception: ptr JSValueRef): JSValueRef): JSValueRef =
  var vals: seq[JSValueRef] = @[]
  for p in persons:
    let j = conv(ctx, p, fname, exception)
    if j == nil:
      return nil
    vals.add(j)
  let arr = makeJSArray(ctx, vals)
  if arr == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  arr

# -- RSS ---------------------------------------------------------------

proc rssMediaToJS(ctx: JSContextRef; m: RssMediaContent; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not optSetStr(ctx, obj, "url", m.url, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "mediaType", m.mediaType, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "medium", m.medium, fname, exception):
    return nil
  if not optSetInt(ctx, obj, "height", m.height, fname, exception):
    return nil
  if not optSetInt(ctx, obj, "width", m.width, fname, exception):
    return nil
  obj

proc rssItemToJS(ctx: JSContextRef; item: RssItem; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not optSetStr(ctx, obj, "title", item.title, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "link", item.link, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "description", item.description, fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "pubDate", item.pubDate, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "category", item.category, fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "guid", item.guid, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "source", item.source, fname, exception):
    return nil
  if item.mediaContent.isSome:
    let m = rssMediaToJS(ctx, item.mediaContent.get(), fname, exception)
    if m == nil:
      return nil
    if not setPropChecked(ctx, obj, "mediaContent", m, fname, exception):
      return nil
  obj

proc rssToJS(ctx: JSContextRef; f: RssFeed; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  for (key, val) in [("title", f.title), ("link", f.link),
      ("description", f.description), ("copyright", f.copyright),
      ("pubDate", f.pubDate), ("lastBuildDate", f.lastBuildDate)]:
    if not setPropChecked(ctx, obj, key, toJS(ctx, val), fname,
        exception):
      return nil
  if not setPropChecked(ctx, obj, "ttl", toJS(ctx, f.ttl), fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "atomSelfLink", f.atomSelfLink, fname,
      exception):
    return nil
  let img = newObject(ctx)
  if not setPropChecked(ctx, img, "url", toJS(ctx, f.image.url), fname,
      exception):
    return nil
  if not setPropChecked(ctx, img, "title", toJS(ctx, f.image.title),
      fname, exception):
    return nil
  if not setPropChecked(ctx, img, "link", toJS(ctx, f.image.link),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "image", img, fname, exception):
    return nil
  let items = personsToJS(ctx, f.items, fname, exception, rssItemToJS)
  if items == nil:
    return nil
  if not setPropChecked(ctx, obj, "items", items, fname, exception):
    return nil
  obj

# -- Atom --------------------------------------------------------------

proc atomTextToJS(ctx: JSContextRef; t: AtomText): JSValueRef =
  let obj = newObject(ctx)
  var ex: JSValueRef = nil
  setProp(ctx, obj, "kind", toJS(ctx, t.kind), addr ex)
  setProp(ctx, obj, "value", toJS(ctx, t.value), addr ex)
  if ex != nil:
    return nil
  obj

proc atomPersonToJS(ctx: JSContextRef; p: AtomPerson; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "name", toJS(ctx, p.name), fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "uri", p.uri, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "email", p.email, fname, exception):
    return nil
  obj

proc atomLinkToJS(ctx: JSContextRef; l: AtomLink; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "href", toJS(ctx, l.href), fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "rel", l.rel, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "type", l.mimeType, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "hreflang", l.hreflang, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "title", l.title, fname, exception):
    return nil
  if not optSetInt(ctx, obj, "length", l.length, fname, exception):
    return nil
  obj

proc atomCategoryToJS(ctx: JSContextRef; c: AtomCategory; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "term", toJS(ctx, c.term), fname,
      exception):
    return nil
  if not optSetStr(ctx, obj, "scheme", c.scheme, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "label", c.label, fname, exception):
    return nil
  obj

proc atomEntryToJS(ctx: JSContextRef; e: AtomEntry; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "id", toJS(ctx, e.id), fname,
      exception):
    return nil
  let title = atomTextToJS(ctx, e.title)
  if title == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "title", title, fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "updated", toJS(ctx, e.updated),
      fname, exception):
    return nil
  template setPeople(key: string; items, conv: untyped): untyped =
    let arrVal = personsToJS(ctx, items, fname, exception, conv)
    if arrVal == nil:
      return nil
    if not setPropChecked(ctx, obj, key, arrVal, fname, exception):
      return nil
  setPeople("authors", e.authors, atomPersonToJS)
  setPeople("contributors", e.contributors, atomPersonToJS)
  setPeople("links", e.links, atomLinkToJS)
  setPeople("categories", e.categories, atomCategoryToJS)
  if e.summary.isSome:
    let s = atomTextToJS(ctx, e.summary.get())
    if s == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "summary", s, fname, exception):
      return nil
  if e.content.isSome:
    let c = e.content.get()
    let cobj = newObject(ctx)
    if not optSetStr(ctx, cobj, "kind", c.kind, fname, exception):
      return nil
    if not optSetStr(ctx, cobj, "src", c.src, fname, exception):
      return nil
    if not optSetStr(ctx, cobj, "value", c.value, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "content", cobj, fname, exception):
      return nil
  if e.rights.isSome:
    let r = atomTextToJS(ctx, e.rights.get())
    if r == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "rights", r, fname, exception):
      return nil
  if not optSetStr(ctx, obj, "published", e.published, fname, exception):
    return nil
  obj

proc atomToJS(ctx: JSContextRef; f: AtomFeed; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "id", toJS(ctx, f.id), fname,
      exception):
    return nil
  let title = atomTextToJS(ctx, f.title)
  if title == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "title", title, fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "updated", toJS(ctx, f.updated),
      fname, exception):
    return nil
  template setPeople(key: string; items, conv: untyped): untyped =
    let arrVal = personsToJS(ctx, items, fname, exception, conv)
    if arrVal == nil:
      return nil
    if not setPropChecked(ctx, obj, key, arrVal, fname, exception):
      return nil
  setPeople("authors", f.authors, atomPersonToJS)
  setPeople("contributors", f.contributors, atomPersonToJS)
  setPeople("links", f.links, atomLinkToJS)
  setPeople("categories", f.categories, atomCategoryToJS)
  if f.subtitle.isSome:
    let s = atomTextToJS(ctx, f.subtitle.get())
    if s == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "subtitle", s, fname, exception):
      return nil
  if f.rights.isSome:
    let r = atomTextToJS(ctx, f.rights.get())
    if r == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "rights", r, fname, exception):
      return nil
  if f.generator.isSome:
    let g = f.generator.get()
    let gobj = newObject(ctx)
    if not setPropChecked(ctx, gobj, "value", toJS(ctx, g.value), fname,
        exception):
      return nil
    if not optSetStr(ctx, gobj, "uri", g.uri, fname, exception):
      return nil
    if not optSetStr(ctx, gobj, "version", g.version, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "generator", gobj, fname,
        exception):
      return nil
  if not optSetStr(ctx, obj, "icon", f.icon, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "logo", f.logo, fname, exception):
    return nil
  let entries = personsToJS(ctx, f.entries, fname, exception,
    atomEntryToJS)
  if entries == nil:
    return nil
  if not setPropChecked(ctx, obj, "entries", entries, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "lang", f.lang, fname, exception):
    return nil
  if not optSetStr(ctx, obj, "base", f.base, fname, exception):
    return nil
  obj

# -- JS -> native (stringify) ---------------------------------------

proc feedErr(msg: string): ref CatchableError =
  newException(CatchableError, msg)

proc fRawHas(ctx: JSContextRef; obj: JSValueRef; key: string): bool =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  ex == nil and prop != nil and
    JSValueGetType(ctx, prop) != kJSTypeUndefined

proc fRawGet(ctx: JSContextRef; obj: JSValueRef; key: string): JSValueRef =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  if ex != nil or prop == nil:
    raise feedErr("has an unreadable property \"" & key & "\"")
  prop

proc fRequireObj(ctx: JSContextRef; v: JSValueRef; what: string): JSValueRef =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      JSValueIsArray(ctx, v) or JSObjectIsFunction(ctx, v):
    raise feedErr(what)
  v

proc fReadStr(ctx: JSContextRef; v: JSValueRef; what: string): string =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeString:
    raise feedErr(what)
  var ex: JSValueRef = nil
  let s = JSValueToStringCopy(ctx, v, addr ex)
  if s == nil:
    raise feedErr(what)
  defer: JSStringRelease(s)
  $s

proc fReadOptStr(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[string] =
  if not fRawHas(ctx, obj, key):
    return none(string)
  some(fReadStr(ctx, fRawGet(ctx, obj, key),
    "\"" & key & "\" must be a string"))

proc fReadReqStr(ctx: JSContextRef; obj: JSValueRef; key: string;
    what: string): string =
  if not fRawHas(ctx, obj, key):
    return ""
  fReadStr(ctx, fRawGet(ctx, obj, key), "\"" & key & "\" must be a string")

proc fReadOptInt(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[int] =
  if not fRawHas(ctx, obj, key):
    return none(int)
  let v = fRawGet(ctx, obj, key)
  if JSValueGetType(ctx, v) != kJSTypeNumber:
    raise feedErr("\"" & key & "\" must be an integer")
  var ex: JSValueRef = nil
  let f = JSValueToNumber(ctx, v, addr ex)
  if ex != nil or f != trunc(f) or abs(f) >= 9223372036854775808.0:
    raise feedErr("\"" & key & "\" must be an integer")
  some(int(f))

proc fRawLen(ctx: JSContextRef; v: JSValueRef; what: string): int =
  var ex: JSValueRef = nil
  let lenKey = newJSString("length")
  defer: JSStringRelease(lenKey)
  let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
  if ex != nil or lenV == nil:
    raise feedErr(what)
  var ex2: JSValueRef = nil
  let n = int(JSValueToNumber(ctx, lenV, addr ex2))
  if ex2 != nil or n < 0:
    raise feedErr(what)
  n

proc fRawIndex(ctx: JSContextRef; v: JSValueRef; idx: int;
    what: string): JSValueRef =
  var eEx: JSValueRef = nil
  let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx), addr eEx)
  if eEx != nil or item == nil:
    raise feedErr(what)
  item

proc fRequireArr(ctx: JSContextRef; v: JSValueRef; what: string): JSValueRef =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      not JSValueIsArray(ctx, v):
    raise feedErr(what)
  v

proc fReadSeq[T](ctx: JSContextRef; obj: JSValueRef; key: string;
    what: string; conv: proc(ctx: JSContextRef;
    v: JSValueRef): T): seq[T] =
  if not fRawHas(ctx, obj, key):
    return @[]
  let v = fRequireArr(ctx, fRawGet(ctx, obj, key), what)
  let n = fRawLen(ctx, v, what)
  if n > maxDumpDepth * 1000:
    raise feedErr("array is too large")
  for idx in 0 ..< n:
    result.add(conv(ctx, fRawIndex(ctx, v, idx, what)))

proc fReadMedia(ctx: JSContextRef; v: JSValueRef): RssMediaContent =
  let o = fRequireObj(ctx, v, "mediaContent must be an object")
  result = RssMediaContent()
  result.url = fReadOptStr(ctx, o, "url")
  result.mediaType = fReadOptStr(ctx, o, "mediaType")
  result.medium = fReadOptStr(ctx, o, "medium")
  result.height = fReadOptInt(ctx, o, "height")
  result.width = fReadOptInt(ctx, o, "width")

proc fReadRssItem(ctx: JSContextRef; v: JSValueRef): RssItem =
  let o = fRequireObj(ctx, v, "items entries must be objects")
  result = RssItem()
  result.title = fReadOptStr(ctx, o, "title")
  result.link = fReadOptStr(ctx, o, "link")
  result.description = fReadOptStr(ctx, o, "description")
  result.pubDate = fReadOptStr(ctx, o, "pubDate")
  result.category = fReadOptStr(ctx, o, "category")
  result.guid = fReadOptStr(ctx, o, "guid")
  result.source = fReadOptStr(ctx, o, "source")
  if fRawHas(ctx, o, "mediaContent"):
    result.mediaContent = some(fReadMedia(ctx, fRawGet(ctx, o,
      "mediaContent")))

proc jsToRss(ctx: JSContextRef; v: JSValueRef): RssFeed =
  let o = fRequireObj(ctx, v, "feed must be an object")
  result = RssFeed()
  result.title = fReadReqStr(ctx, o, "title", "feed must be an object")
  result.link = fReadReqStr(ctx, o, "link", "feed must be an object")
  result.description = fReadReqStr(ctx, o, "description",
    "feed must be an object")
  result.copyright = fReadReqStr(ctx, o, "copyright", "feed must be an object")
  result.pubDate = fReadReqStr(ctx, o, "pubDate", "feed must be an object")
  result.lastBuildDate = fReadReqStr(ctx, o, "lastBuildDate",
    "feed must be an object")
  if fRawHas(ctx, o, "ttl"):
    let tv = fRawGet(ctx, o, "ttl")
    if JSValueGetType(ctx, tv) == kJSTypeNumber:
      var ex: JSValueRef = nil
      let f = JSValueToNumber(ctx, tv, addr ex)
      if ex == nil:
        result.ttl = int(f)
  result.atomSelfLink = fReadOptStr(ctx, o, "atomSelfLink")
  if fRawHas(ctx, o, "image"):
    let io = fRequireObj(ctx, fRawGet(ctx, o, "image"),
      "\"image\" must be an object")
    result.image.url = fReadReqStr(ctx, io, "url", "\"image\" must be an object")
    result.image.title = fReadReqStr(ctx, io, "title",
      "\"image\" must be an object")
    result.image.link = fReadReqStr(ctx, io, "link",
      "\"image\" must be an object")
  result.items = fReadSeq(ctx, o, "items", "items must be an array",
    fReadRssItem)

proc fReadText(ctx: JSContextRef; v: JSValueRef; what: string): AtomText =
  let o = fRequireObj(ctx, v, what)
  result = AtomText(kind: "text", value: "")
  if fRawHas(ctx, o, "kind"):
    result.kind = fReadStr(ctx, fRawGet(ctx, o, "kind"), what)
  if fRawHas(ctx, o, "value"):
    result.value = fReadStr(ctx, fRawGet(ctx, o, "value"), what)

proc fReadPerson(ctx: JSContextRef; v: JSValueRef): AtomPerson =
  let o = fRequireObj(ctx, v, "authors entries must be {name, ...}")
  if not fRawHas(ctx, o, "name"):
    raise feedErr("authors entries must be {name, ...}")
  result = AtomPerson(name: fReadStr(ctx, fRawGet(ctx, o, "name"),
    "authors entries must be {name, ...}"))
  result.uri = fReadOptStr(ctx, o, "uri")
  result.email = fReadOptStr(ctx, o, "email")

proc fReadLink(ctx: JSContextRef; v: JSValueRef): AtomLink =
  let o = fRequireObj(ctx, v, "links entries must be {href, ...}")
  if not fRawHas(ctx, o, "href"):
    raise feedErr("links entries must be {href, ...}")
  result = AtomLink(href: fReadStr(ctx, fRawGet(ctx, o, "href"),
    "links entries must be {href, ...}"))
  result.rel = fReadOptStr(ctx, o, "rel")
  if fRawHas(ctx, o, "type"):
    result.mimeType = some(fReadStr(ctx, fRawGet(ctx, o, "type"),
      "links entries must be {href, ...}"))
  result.hreflang = fReadOptStr(ctx, o, "hreflang")
  result.title = fReadOptStr(ctx, o, "title")
  result.length = fReadOptInt(ctx, o, "length")

proc fReadCategory(ctx: JSContextRef; v: JSValueRef): AtomCategory =
  let o = fRequireObj(ctx, v, "categories entries must be {term, ...}")
  if not fRawHas(ctx, o, "term"):
    raise feedErr("categories entries must be {term, ...}")
  result = AtomCategory(term: fReadStr(ctx, fRawGet(ctx, o, "term"),
    "categories entries must be {term, ...}"))
  result.scheme = fReadOptStr(ctx, o, "scheme")
  result.label = fReadOptStr(ctx, o, "label")

proc fReadOptText(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[AtomText] =
  if not fRawHas(ctx, obj, key):
    return none(AtomText)
  some(fReadText(ctx, fRawGet(ctx, obj, key),
    "\"" & key & "\" must be {kind, value}"))

proc fReadContent(ctx: JSContextRef; obj: JSValueRef;
    key: string): Option[AtomContent] =
  if not fRawHas(ctx, obj, key):
    return none(AtomContent)
  let o = fRequireObj(ctx, fRawGet(ctx, obj, key),
    "\"" & key & "\" must be an object")
  var c = AtomContent()
  c.kind = fReadOptStr(ctx, o, "kind")
  c.src = fReadOptStr(ctx, o, "src")
  c.value = fReadOptStr(ctx, o, "value")
  some(c)

proc fReadEntry(ctx: JSContextRef; v: JSValueRef): AtomEntry =
  let o = fRequireObj(ctx, v, "entries must be objects")
  if not fRawHas(ctx, o, "id"):
    raise feedErr("entries must be objects")
  result = AtomEntry(id: fReadStr(ctx, fRawGet(ctx, o, "id"),
    "entries must be objects"))
  if not fRawHas(ctx, o, "title"):
    raise feedErr("entries must be objects")
  result.title = fReadText(ctx, fRawGet(ctx, o, "title"),
    "\"title\" must be {kind, value}")
  result.updated = fReadReqStr(ctx, o, "updated", "entries must be objects")
  result.authors = fReadSeq(ctx, o, "authors", "authors must be an array",
    fReadPerson)
  result.contributors = fReadSeq(ctx, o, "contributors",
    "contributors must be an array", fReadPerson)
  result.links = fReadSeq(ctx, o, "links", "links must be an array",
    fReadLink)
  result.categories = fReadSeq(ctx, o, "categories",
    "categories must be an array", fReadCategory)
  result.summary = fReadOptText(ctx, o, "summary")
  result.content = fReadContent(ctx, o, "content")
  result.rights = fReadOptText(ctx, o, "rights")
  result.published = fReadOptStr(ctx, o, "published")

proc jsToAtom(ctx: JSContextRef; v: JSValueRef): AtomFeed =
  let o = fRequireObj(ctx, v, "feed must be an object")
  if not fRawHas(ctx, o, "id"):
    raise feedErr("feed must be an object")
  result = AtomFeed(id: fReadStr(ctx, fRawGet(ctx, o, "id"),
    "feed must be an object"))
  if not fRawHas(ctx, o, "title"):
    raise feedErr("feed must be an object")
  result.title = fReadText(ctx, fRawGet(ctx, o, "title"),
    "\"title\" must be {kind, value}")
  result.updated = fReadReqStr(ctx, o, "updated", "feed must be an object")
  result.authors = fReadSeq(ctx, o, "authors", "authors must be an array",
    fReadPerson)
  result.contributors = fReadSeq(ctx, o, "contributors",
    "contributors must be an array", fReadPerson)
  result.links = fReadSeq(ctx, o, "links", "links must be an array",
    fReadLink)
  result.categories = fReadSeq(ctx, o, "categories",
    "categories must be an array", fReadCategory)
  result.subtitle = fReadOptText(ctx, o, "subtitle")
  result.rights = fReadOptText(ctx, o, "rights")
  if fRawHas(ctx, o, "generator"):
    let go = fRequireObj(ctx, fRawGet(ctx, o, "generator"),
      "\"generator\" must be an object")
    if not fRawHas(ctx, go, "value"):
      raise feedErr("\"generator\" must be an object")
    var g = AtomGenerator(value: fReadStr(ctx, fRawGet(ctx, go, "value"),
      "\"generator\" must be an object"))
    g.uri = fReadOptStr(ctx, go, "uri")
    g.version = fReadOptStr(ctx, go, "version")
    result.generator = some(g)
  result.icon = fReadOptStr(ctx, o, "icon")
  result.logo = fReadOptStr(ctx, o, "logo")
  result.entries = fReadSeq(ctx, o, "entries", "entries must be an array",
    fReadEntry)
  result.lang = fReadOptStr(ctx, o, "lang")
  result.base = fReadOptStr(ctx, o, "base")

# -- JS entry points ---------------------------------------------------

## Builds the std/feed namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parseRss(text: string):
      ## feed.parseRss(text) -> feed object with items[]
      try:
        let j = rssToJS(ctx, parseRss(text), "parseRss", exception)
        if j == nil:
          throwError(ctx, "parseRss: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "parseRss: " & e.msg, exception)
        nil

    module.registerFn stringifyRss(value: JSValueRef):
      ## feed.stringifyRss(feed) -> string (RSS 2.0 XML)
      try:
        toJS(ctx, toRssXml(jsToRss(ctx, value)))
      except CatchableError as e:
        throwError(ctx, "stringifyRss: " & e.msg, exception)
        nil

    module.registerFn parseAtom(text: string):
      ## feed.parseAtom(text) -> feed object with entries[]
      try:
        let j = atomToJS(ctx, parseAtom(text), "parseAtom", exception)
        if j == nil:
          throwError(ctx, "parseAtom: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "parseAtom: " & e.msg, exception)
        nil

    module.registerFn stringifyAtom(value: JSValueRef):
      ## feed.stringifyAtom(feed) -> string (Atom XML)
      try:
        toJS(ctx, toAtomXml(jsToAtom(ctx, value)))
      except CatchableError as e:
        throwError(ctx, "stringifyAtom: " & e.msg, exception)
        nil
