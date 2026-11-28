# Carne std/markdown: Markdown rendering via marvdown.
#
#   const md = require("std/markdown");
#   md.toHtml("# hi")                         -> "<h1 ...>...</h1>\n"
#   md.toAst("# hi")                          -> AST as JS arrays/objects
#   md.frontMatter("---\ntitle: t\n---\n# hi") -> {title: "t"} ({} when absent)
#   md.toc("# a\n## b")                       -> [{level, anchor, title}]
#   md.title("# hello")                       -> "hello"
#
# Options (plain object, camelCase; unknown keys throw) mirror the
# JSON-safe subset of marvdown's MarkdownOptions; omitted keys keep
# marvdown's defaults (anchors on, default allowed-tag list, front
# matter parsed, components off). The proc hooks (customTransform,
# codeBlockTransform) stay out: they cannot cross the JS boundary.
#
#   md.toHtml(src, {enableAnchors: false, allowed: [],
#     allowTagsByType: "all", showFootnotes: false,
#     htmlTableClasses: ["table"], enableEmailAutolinks: true,
#     enableComponents: true, componentBaseDir: "docs",
#     lazyloadImages: true, parseYaml: false})

import std/[options, strutils]

import javascriptcore

import pkg/marvdown
from pkg/openparser/html import getHtmlTag, tagUnknown

import ../bridge

const mdOptionKeys = ["allowed", "allowTagsByType", "allowInlineStyle",
  "allowHtmlAttributes", "enableAnchors", "anchorIcon", "showFootnotes",
  "htmlTableClasses", "enableEmailAutolinks", "enableComponents",
  "componentBaseDir", "lazyloadIframes", "lazyloadVideos", "lazyloadImages",
  "parseYaml"]

proc readMarkdownOptions(ctx: JSContextRef; optsObj: JSObjectRef;
    fname: string; exception: ptr JSValueRef;
    opts: var MarkdownOptions): bool =
  ## Overlay a JS options object onto marvdown's defaults. True on
  ## success; false + JS TypeError on unknown keys or type mismatches.
  opts = defaultOptions
  let names = JSObjectCopyPropertyNames(ctx, optsObj)
  if names == nil:
    throwTypeError(ctx, fname & ": options must be an object", exception)
    return false
  defer: JSPropertyNameArrayRelease(names)
  let count = int(JSPropertyNameArrayGetCount(names))
  for idx in 0 ..< count:
    let key = $JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
    var known = false
    for k in mdOptionKeys:
      if k == key:
        known = true
        break
    if not known:
      throwTypeError(ctx, fname & ": unknown option \"" & key & "\"",
        exception)
      return false
  template optBool(key: string; field: untyped) =
    block:
      var ferr = ""
      let fv = getField(ctx, optsObj, key, ferr)
      if ferr != "":
        throwTypeError(ctx, fname & ": options." & key & " " & ferr,
          exception)
        return false
      case fv.kind
      of nvkUndefined, nvkNull:
        discard
      of nvkBool:
        opts.field = fv.b
      else:
        throwTypeError(ctx, fname & ": options." & key &
          " must be a boolean, got " & jsTypeName(fv.kind), exception)
        return false
  template optString(key: string; field: untyped) =
    block:
      var ferr = ""
      let fv = getField(ctx, optsObj, key, ferr)
      if ferr != "":
        throwTypeError(ctx, fname & ": options." & key & " " & ferr,
          exception)
        return false
      case fv.kind
      of nvkUndefined, nvkNull:
        discard
      of nvkString:
        opts.field = fv.s
      else:
        throwTypeError(ctx, fname & ": options." & key &
          " must be a string, got " & jsTypeName(fv.kind), exception)
        return false
  optBool("allowInlineStyle", allowInlineStyle)
  optBool("allowHtmlAttributes", allowHtmlAttributes)
  optBool("enableAnchors", enableAnchors)
  optBool("showFootnotes", showFootnotes)
  optBool("enableEmailAutolinks", enableEmailAutolinks)
  optBool("enableComponents", enableComponents)
  optBool("lazyloadIframes", lazyloadIframes)
  optBool("lazyloadVideos", lazyloadVideos)
  optBool("lazyloadImages", lazyloadImages)
  optBool("parseYaml", parseYaml)
  optString("anchorIcon", anchorIcon)
  optString("componentBaseDir", componentBaseDir)
  var terr = ""
  let tv = getField(ctx, optsObj, "allowTagsByType", terr)
  if terr != "":
    throwTypeError(ctx, fname & ": options.allowTagsByType " & terr,
      exception)
    return false
  case tv.kind
  of nvkUndefined, nvkNull:
    discard
  of nvkString:
    let v = tv.s.strip().toLowerAscii()
    let norm = if v.startsWith("tag"): v[3 .. ^1] else: v
    case norm
    of "none":
      opts.allowTagsByType = none(TagType)
    of "inline":
      opts.allowTagsByType = some(tagInline)
    of "block":
      opts.allowTagsByType = some(tagBlock)
    of "all":
      opts.allowTagsByType = some(tagAll)
    else:
      throwTypeError(ctx, fname &
        ": options.allowTagsByType must be one of none|inline|block|all, got \"" &
        tv.s & "\"", exception)
      return false
  else:
    throwTypeError(ctx, fname &
      ": options.allowTagsByType must be a string, got " &
      jsTypeName(tv.kind), exception)
    return false
  var aerr = ""
  let av = getField(ctx, optsObj, "allowed", aerr)
  if aerr != "":
    throwTypeError(ctx, fname & ": options.allowed " & aerr, exception)
    return false
  case av.kind
  of nvkUndefined, nvkNull:
    discard
  of nvkArray:
    var tags: seq[HtmlTag] = @[]
    for item in av.arr:
      if item.kind != nvkString:
        throwTypeError(ctx, fname &
          ": options.allowed must be an array of tag names, got " &
          jsTypeName(item.kind), exception)
        return false
      let tag = getHtmlTag(item.s.strip().toLowerAscii())
      if tag == tagUnknown:
        throwTypeError(ctx, fname &
          ": unknown html tag in options.allowed: \"" & item.s & "\"",
          exception)
        return false
      tags.add(tag)
    opts.allowed = tags
  else:
    throwTypeError(ctx, fname &
      ": options.allowed must be an array of tag names, got " &
      jsTypeName(av.kind), exception)
    return false
  var cerr = ""
  let cv = getField(ctx, optsObj, "htmlTableClasses", cerr)
  if cerr != "":
    throwTypeError(ctx, fname & ": options.htmlTableClasses " & cerr,
      exception)
    return false
  case cv.kind
  of nvkUndefined, nvkNull:
    discard
  of nvkArray:
    var classes: seq[string] = @[]
    for item in cv.arr:
      if item.kind != nvkString:
        throwTypeError(ctx, fname &
          ": options.htmlTableClasses must be an array of strings, got " &
          jsTypeName(item.kind), exception)
        return false
      classes.add(item.s)
    opts.htmlTableClasses = some(classes)
  else:
    throwTypeError(ctx, fname &
      ": options.htmlTableClasses must be an array of strings, got " &
      jsTypeName(cv.kind), exception)
    return false
  true

## Builds the std/markdown namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn toHtml(src: string, optsObj ?: JSObjectRef):
      ## md.toHtml(src[, options]) -> string (anchors on, front matter
      ## parsed by default; components off unless enabled in options)
      var opts = defaultOptions
      if optsObj != nil:
        if not readMarkdownOptions(ctx, optsObj, "toHtml", exception,
            opts):
          return nil
      try:
        var md = newMarkdown(src, opts)
        toJS(ctx, md.toHtml())
      except CatchableError as e:
        throwError(ctx, "toHtml: " & e.msg, exception)
        nil

    module.registerFn toAst(src: string, optsObj ?: JSObjectRef):
      ## md.toAst(src[, options]) -> AST as JS arrays/objects/strings
      var opts = defaultOptions
      if optsObj != nil:
        if not readMarkdownOptions(ctx, optsObj, "toAst", exception,
            opts):
          return nil
      try:
        var md = newMarkdown(src, opts)
        let j = jsonNodeToJS(ctx, parseJson(md.toJson()))
        if j == nil:
          throwError(ctx, "toAst: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "toAst: " & e.msg, exception)
        nil

    module.registerFn frontMatter(src: string, optsObj ?: JSObjectRef):
      ## md.frontMatter(src[, options]) -> object ({} when the document
      ## has no front matter)
      var opts = defaultOptions
      if optsObj != nil:
        if not readMarkdownOptions(ctx, optsObj, "frontMatter", exception,
            opts):
          return nil
      try:
        var md = newMarkdown(src, opts)
        returnJson(ctx, md.headerJson(), "frontMatter", exception)
      except CatchableError as e:
        throwError(ctx, "frontMatter: " & e.msg, exception)
        nil

    module.registerFn toc(src: string, optsObj ?: JSObjectRef):
      ## md.toc(src[, options]) -> [{level, anchor, title}] in document order
      var opts = defaultOptions
      if optsObj != nil:
        if not readMarkdownOptions(ctx, optsObj, "toc", exception, opts):
          return nil
      try:
        var md = newMarkdown(src, opts)
        # Selectors populate at render time, so render once (discarded)
        # before reading the table of contents.
        discard md.toHtml()
        var vals: seq[JSValueRef] = @[]
        for item in md.getSelectorItems():
          let obj = newObject(ctx)
          if not setPropChecked(ctx, obj, "level", toJS(ctx, item.level),
              "toc", exception):
            return nil
          if not setPropChecked(ctx, obj, "anchor", toJS(ctx, item.anchor),
              "toc", exception):
            return nil
          if not setPropChecked(ctx, obj, "title", toJS(ctx, item.title),
              "toc", exception):
            return nil
          vals.add(obj)
        let arr = makeJSArray(ctx, vals)
        if arr == nil:
          throwError(ctx, "toc: could not convert result to JS", exception)
          return nil
        arr
      except CatchableError as e:
        throwError(ctx, "toc: " & e.msg, exception)
        nil

    module.registerFn title(src: string, optsObj ?: JSObjectRef):
      ## md.title(src[, options]) -> first heading text ("Untitled
      ## document" when the document has no headings)
      var opts = defaultOptions
      if optsObj != nil:
        if not readMarkdownOptions(ctx, optsObj, "title", exception,
            opts):
          return nil
      try:
        var md = newMarkdown(src, opts)
        # The title is the first heading anchor, which is generated at
        # render time, so render once (discarded) before reading it.
        discard md.toHtml()
        toJS(ctx, md.getTitle())
      except CatchableError as e:
        throwError(ctx, "title: " & e.msg, exception)
        nil
