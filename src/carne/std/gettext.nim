# Carne std/gettext: .po parsing and translation via openparser.
#
# One-shot fns take the catalog inline (text or path) and re-parse on
# every call; fine for occasional use. Hot paths open a catalog once
# and reuse the compiled handle (no temp file, no re-parse):
#
#   const id = gettext.openCatalog(poText);
#   gettext.translateCatalog(id, "hi");
#   gettext.closeCatalog(id);
#
#   gettext.parse(text)
#     -> {headers: {...}, entries: [{msgid, msgstr: [...], ...}]}
#   gettext.translate(text, msgid[, msgctxt]) -> translated string
#   gettext.ntranslate(text, singular, plural, n[, msgctxt]) -> plural form
#   gettext.parseMoFile(path) -> {headers, entries}
#   gettext.translateMo(path, msgid[, msgctxt]) -> translated string
#   gettext.ntranslateMo(path, singular, plural, n[, msgctxt]) -> plural form
#   gettext.writeMo(text, path) -> compiles .po text to a .mo file
#   gettext.openCatalog(text) -> catalog id (.po text, parsed once)
#   gettext.openCatalogMo(path) -> catalog id (.mo file, parsed once)
#   gettext.translateCatalog(id, msgid[, msgctxt]) -> translated string
#   gettext.ntranslateCatalog(id, singular, plural, n[, msgctxt])
#     -> plural form
#   gettext.hasCatalog(id, key[, msgctxt]) -> bool (true when a lookup
#     would translate instead of falling back to the key)
#   gettext.pluralIndexCatalog(id, n) -> form index for the catalog's
#     own plural rule (drives handle-based ntranslate from JS)
#   gettext.closeCatalog(id) -> undefined (idempotent)
#
# Entries carry msgid, msgstr[], and msgidPlural/msgctxt/fuzzy only when
# present. Obsolete entries are skipped; untranslated ids fall back to
# the msgid. openparser's reader is MemFile-based, so one-shot input
# goes through a temp file (same bridge as std/csv); compiled handles
# decode to plain strings once, then the mapping is closed.

import std/[os, strutils, tables]

import javascriptcore

import pkg/openparser/gettext/po
import pkg/openparser/gettext/mo

import ../bridge
import ../modules

proc openTemp(text, name: string; ctx: JSContextRef;
    exception: ptr JSValueRef; tmp: var string;
    cat: var PoCatalog; docBlock = ""): bool =
  ## Writes text to a temp file and opens it. False + JS throw on failure.
  ## Callers must close(cat) and removeFile(tmp) when done: close unmaps
  ## the file, so all decoding happens before it.
  template oerr(msg: string): untyped =
    throwError(ctx,
      (if docBlock.len > 0: docBlock & "\n" else: "") & msg, exception)
  tmp = getTempDir() / "carne_gettext_parse.tmp"
  try:
    writeFile(tmp, text)
  except IOError as e:
    oerr(name & ": " & e.msg)
    return false
  except OSError as e:
    oerr(name & ": " & e.msg)
    return false
  try:
    cat = openPoCatalog(tmp)
  except CatchableError as e:
    try: removeFile(tmp)
    except OSError: discard
    oerr(name & ": " & e.msg)
    return false
  true

proc closeTemp(tmp: string; cat: PoCatalog) =
  close(cat)
  try: removeFile(tmp)
  except OSError: discard

proc entryToJS(ctx: JSContextRef; cat: PoCatalog; e: PoEntry;
    fname: string; exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "msgid",
      toJS(ctx, decodeField(cat, e.msgid)), fname, exception):
    return nil
  let plural = decodeField(cat, e.msgidPlural)
  if plural.len > 0:
    if not setPropChecked(ctx, obj, "msgidPlural", toJS(ctx, plural),
        fname, exception):
      return nil
  let context = decodeField(cat, e.msgctxt)
  if context.len > 0:
    if not setPropChecked(ctx, obj, "msgctxt", toJS(ctx, context),
        fname, exception):
      return nil
  var fvals: seq[JSValueRef] = @[]
  for m in e.msgstr:
    fvals.add(toJS(ctx, decodeMsgStr(cat, e, m.idx)))
  let forms = makeJSArray(ctx, fvals)
  if forms == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "msgstr", forms, fname, exception):
    return nil
  var fuzzy = false
  for c in e.comments:
    if c.kind == pckFlag and "fuzzy" in toString(cat, c.text):
      fuzzy = true
      break
  if fuzzy:
    if not setPropChecked(ctx, obj, "fuzzy", toJS(ctx, true), fname,
        exception):
      return nil
  obj

proc openMo(path, name: string; ctx: JSContextRef;
    exception: ptr JSValueRef; cat: var MoCatalog;
    docBlock = ""): bool =
  ## Opens a .mo catalog from a file path. False + JS throw on failure.
  ## Callers must close(cat) when done.
  try:
    cat = openMoCatalog(path)
    true
  except CatchableError as e:
    throwError(ctx,
      (if docBlock.len > 0: docBlock & "\n" else: "") & name & ": " &
      e.msg, exception)
    false

proc moEntryToJS(ctx: JSContextRef; cat: MoCatalog; m: MoMessage;
    fname: string; exception: ptr JSValueRef): JSValueRef =
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "msgid",
      toJS(ctx, toString(cat, m.msgid)), fname, exception):
    return nil
  let plural = toString(cat, m.msgidPlural)
  if plural.len > 0:
    if not setPropChecked(ctx, obj, "msgidPlural", toJS(ctx, plural),
        fname, exception):
      return nil
  let context = toString(cat, m.msgctxt)
  if context.len > 0:
    if not setPropChecked(ctx, obj, "msgctxt", toJS(ctx, context),
        fname, exception):
      return nil
  var fvals: seq[JSValueRef] = @[]
  for s in m.forms:
    fvals.add(toJS(ctx, toString(cat, s)))
  let forms = makeJSArray(ctx, fvals)
  if forms == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  if not setPropChecked(ctx, obj, "msgstr", forms, fname, exception):
    return nil
  obj

type
  CatalogKind = enum ckPo, ckMo
  CatalogEntry = object
    case kind: CatalogKind
    of ckPo: po: PoCompiledCatalog
    of ckMo: mo: MoCompiledCatalog

var catalogHandles {.threadvar.}: Table[int64, CatalogEntry]
var nextCatalogId {.threadvar.}: int64

proc closeAllCatalogs() =
  ## Drops every live catalog handle. Runs at runtime teardown; each
  ## worker clears its own threadvar table. Compiled catalogs hold
  ## plain strings (no mappings), so this is just table removal.
  catalogHandles.clear()

proc lookupCatalog(id: int64): tuple[ok: bool, e: CatalogEntry] =
  ## Fetches a live handle. Fails closed: unknown or closed ids never
  ## resolve.
  if catalogHandles.hasKey(id):
    (true, catalogHandles[id])
  else:
    (false, CatalogEntry(kind: ckPo))

proc hasForm(e: CatalogEntry; key: string): bool =
  ## True when a plain lookup for key would translate instead of
  ## falling back (mirrors translate's empty-form fallback).
  case e.kind
  of ckPo:
    if not e.po.index.hasKey(key):
      return false
    let m = e.po.messages[e.po.index[key]]
    m.forms.len > 0 and m.forms[0] != ""
  of ckMo:
    if not e.mo.index.hasKey(key):
      return false
    let m = e.mo.messages[e.mo.index[key]]
    m.forms.len > 0 and m.forms[0] != ""

## Builds the std/gettext namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## gettext.parse(text) -> {headers, entries}
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "parse", ctx, exception, tmp, cat, docBlock):
        return nil
      try:
        let headers = newObject(ctx)
        var hex: JSValueRef = nil
        for k, v in parsePoHeaders(cat):
          setProp(ctx, headers, k, toJS(ctx, v), addr hex)
          if hex != nil:
            closeTemp(tmp, cat)
            throwError(ctx, "parse: could not convert result to JS",
              exception)
            return nil
        var evals: seq[JSValueRef] = @[]
        for e in cat.entries:
          if e.obsolete:
            continue
          if decodeField(cat, e.msgid).len == 0:
            continue
          let j = entryToJS(ctx, cat, e, "parse", exception)
          if j == nil:
            closeTemp(tmp, cat)
            return nil
          evals.add(j)
        let entries = makeJSArray(ctx, evals)
        if entries == nil:
          closeTemp(tmp, cat)
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        let obj = newObject(ctx)
        if not setPropChecked(ctx, obj, "headers", headers, "parse",
            exception):
          closeTemp(tmp, cat)
          return nil
        if not setPropChecked(ctx, obj, "entries", entries, "parse",
            exception):
          closeTemp(tmp, cat)
          return nil
        closeTemp(tmp, cat)
        obj
      except CatchableError as e:
        closeTemp(tmp, cat)
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn translate(text: string, msgid: string,
        msgctxt ?: string):
      ## gettext.translate(text, msgid[, msgctxt]) -> string
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "translate", ctx, exception, tmp, cat, docBlock):
        return nil
      try:
        let s = translate(compilePo(cat), msgid, msgctxt)
        closeTemp(tmp, cat)
        toJS(ctx, s)
      except CatchableError as e:
        closeTemp(tmp, cat)
        throwError(ctx, "translate: " & e.msg, exception)
        nil

    module.registerFn ntranslate(text: string, singular: string,
        plural: string, n: int64, msgctxt ?: string):
      ## gettext.ntranslate(text, singular, plural, n[, msgctxt]) -> string
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "ntranslate", ctx, exception, tmp, cat, docBlock):
        return nil
      try:
        let s = ntranslate(compilePo(cat), singular, plural, int(n), msgctxt)
        closeTemp(tmp, cat)
        toJS(ctx, s)
      except CatchableError as e:
        closeTemp(tmp, cat)
        throwError(ctx, "ntranslate: " & e.msg, exception)
        nil

    module.registerFn parseMoFile(path: string):
      ## gettext.parseMoFile(path) -> {headers, entries}
      var cat: MoCatalog
      if not openMo(path, "parseMoFile", ctx, exception, cat, docBlock):
        return nil
      try:
        let headers = newObject(ctx)
        var hex: JSValueRef = nil
        for k, v in cat.headers.pairs:
          setProp(ctx, headers, k, toJS(ctx, v), addr hex)
          if hex != nil:
            close(cat)
            throwError(ctx, "parseMoFile: could not convert result to JS",
              exception)
            return nil
        var evals: seq[JSValueRef] = @[]
        for m in cat.messages:
          if toString(cat, m.msgid).len == 0:
            continue
          let j = moEntryToJS(ctx, cat, m, "parseMoFile", exception)
          if j == nil:
            close(cat)
            return nil
          evals.add(j)
        let entries = makeJSArray(ctx, evals)
        if entries == nil:
          close(cat)
          throwError(ctx, "parseMoFile: could not convert result to JS",
            exception)
          return nil
        let obj = newObject(ctx)
        if not setPropChecked(ctx, obj, "headers", headers, "parseMoFile",
            exception):
          close(cat)
          return nil
        if not setPropChecked(ctx, obj, "entries", entries, "parseMoFile",
            exception):
          close(cat)
          return nil
        close(cat)
        obj
      except CatchableError as e:
        close(cat)
        throwError(ctx, "parseMoFile: " & e.msg, exception)
        nil

    module.registerFn translateMo(path: string, msgid: string,
        msgctxt ?: string):
      ## gettext.translateMo(path, msgid[, msgctxt]) -> string
      var cat: MoCatalog
      if not openMo(path, "translateMo", ctx, exception, cat, docBlock):
        return nil
      try:
        let s = translate(compileMo(cat), msgid, msgctxt)
        close(cat)
        toJS(ctx, s)
      except CatchableError as e:
        close(cat)
        throwError(ctx, "translateMo: " & e.msg, exception)
        nil

    module.registerFn ntranslateMo(path: string, singular: string,
        plural: string, n: int64, msgctxt ?: string):
      ## gettext.ntranslateMo(path, singular, plural, n[, msgctxt]) -> string
      var cat: MoCatalog
      if not openMo(path, "ntranslateMo", ctx, exception, cat, docBlock):
        return nil
      try:
        let s = ntranslate(compileMo(cat), singular, plural, int(n), msgctxt)
        close(cat)
        toJS(ctx, s)
      except CatchableError as e:
        close(cat)
        throwError(ctx, "ntranslateMo: " & e.msg, exception)
        nil

    module.registerFn writeMo(text: string, path: string):
      ## gettext.writeMo(text, path) -> undefined
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "writeMo", ctx, exception, tmp, cat, docBlock):
        return nil
      try:
        writeMoFile(compilePo(cat), path)
        closeTemp(tmp, cat)
      except CatchableError as e:
        closeTemp(tmp, cat)
        throwError(ctx, "writeMo: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn openCatalog(text: string):
      ## gettext.openCatalog(text) -> catalog id
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "openCatalog", ctx, exception, tmp, cat,
          docBlock):
        return nil
      try:
        let compiled = compilePo(cat)
        closeTemp(tmp, cat)
        inc nextCatalogId
        let id = nextCatalogId
        catalogHandles[id] = CatalogEntry(kind: ckPo, po: compiled)
        toJS(ctx, id)
      except CatchableError as e:
        closeTemp(tmp, cat)
        throwError(ctx, "openCatalog: " & e.msg, exception)
        nil

    module.registerFn openCatalogMo(path: string):
      ## gettext.openCatalogMo(path) -> catalog id
      var cat: MoCatalog
      if not openMo(path, "openCatalogMo", ctx, exception, cat, docBlock):
        return nil
      try:
        let compiled = compileMo(cat)
        close(cat)
        inc nextCatalogId
        let id = nextCatalogId
        catalogHandles[id] = CatalogEntry(kind: ckMo, mo: compiled)
        toJS(ctx, id)
      except CatchableError as e:
        close(cat)
        throwError(ctx, "openCatalogMo: " & e.msg, exception)
        nil

    module.registerFn translateCatalog(id: int64, msgid: string,
        msgctxt ?: string):
      ## gettext.translateCatalog(id, msgid[, msgctxt]) -> string
      let (ok, e) = lookupCatalog(id)
      if not ok:
        throwError(ctx, "translateCatalog: unknown or closed catalog",
          exception)
        return nil
      try:
        case e.kind
        of ckPo: toJS(ctx, translate(e.po, msgid, msgctxt))
        of ckMo: toJS(ctx, translate(e.mo, msgid, msgctxt))
      except CatchableError as ex:
        throwError(ctx, "translateCatalog: " & ex.msg, exception)
        nil

    module.registerFn ntranslateCatalog(id: int64, singular: string,
        plural: string, n: int64, msgctxt ?: string):
      ## gettext.ntranslateCatalog(id, singular, plural, n[, msgctxt])
      ##   -> string
      let (ok, e) = lookupCatalog(id)
      if not ok:
        throwError(ctx, "ntranslateCatalog: unknown or closed catalog",
          exception)
        return nil
      try:
        case e.kind
        of ckPo: toJS(ctx, ntranslate(e.po, singular, plural, int(n), msgctxt))
        of ckMo: toJS(ctx, ntranslate(e.mo, singular, plural, int(n), msgctxt))
      except CatchableError as ex:
        throwError(ctx, "ntranslateCatalog: " & ex.msg, exception)
        nil

    module.registerFn hasCatalog(id: int64, key: string,
        msgctxt ?: string):
      ## gettext.hasCatalog(id, key[, msgctxt]) -> bool
      let (ok, e) = lookupCatalog(id)
      if not ok:
        throwError(ctx, "hasCatalog: unknown or closed catalog",
          exception)
        return nil
      let ctxKey = if msgctxt == "": key else: msgctxt & "\x04" & key
      toJS(ctx, hasForm(e, ctxKey))

    module.registerFn pluralIndexCatalog(id: int64, n: int64):
      ## gettext.pluralIndexCatalog(id, n) -> form index
      let (ok, e) = lookupCatalog(id)
      if not ok:
        throwError(ctx, "pluralIndexCatalog: unknown or closed catalog",
          exception)
        return nil
      case e.kind
      of ckPo: toJS(ctx, pluralIndex(e.po, int(n)))
      of ckMo: toJS(ctx, pluralIndex(e.mo, int(n)))

    module.registerFn closeCatalog(id: int64):
      ## gettext.closeCatalog(id) -> undefined (idempotent)
      if catalogHandles.hasKey(id):
        catalogHandles.del(id)
      JSValueMakeUndefined(ctx)

onTeardown.add(closeAllCatalogs)
