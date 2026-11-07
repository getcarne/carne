# Carne std/gettext: .po parsing and translation via openparser.
#
#   const gettext = require("std/gettext");
#   gettext.parse(text)
#     -> {headers: {...}, entries: [{msgid, msgstr: [...], ...}]}
#   gettext.translate(text, msgid[, msgctxt]) -> translated string
#   gettext.ntranslate(text, singular, plural, n) -> plural form
#
# Entries carry msgid, msgstr[], and msgidPlural/msgctxt/fuzzy only when
# present. Obsolete entries are skipped; untranslated ids fall back to
# the msgid. openparser's reader is MemFile-based, so input goes through
# a temp file (same bridge as std/csv). .mo is out of scope in v1
# (binary input).

import std/[os, strutils, tables]

import javascriptcore

import pkg/openparser/gettext/po
import pkg/openparser/gettext/mo

import ../bridge

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
        plural: string, n: int64):
      ## gettext.ntranslate(text, singular, plural, n) -> string
      var tmp = ""
      var cat: PoCatalog
      if not openTemp(text, "ntranslate", ctx, exception, tmp, cat, docBlock):
        return nil
      try:
        let s = ntranslate(compilePo(cat), singular, plural, int(n))
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
        plural: string, n: int64):
      ## gettext.ntranslateMo(path, singular, plural, n) -> string
      var cat: MoCatalog
      if not openMo(path, "ntranslateMo", ctx, exception, cat, docBlock):
        return nil
      try:
        let s = ntranslate(compileMo(cat), singular, plural, int(n))
        close(cat)
        toJS(ctx, s)
      except CatchableError as e:
        close(cat)
        throwError(ctx, "ntranslateMo: " & e.msg, exception)
        nil
