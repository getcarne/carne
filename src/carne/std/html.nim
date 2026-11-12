# Carne std/html: HTML parsing and serialization via openparser.
#
#   const html = require("std/html");
#   const doc = html.parse("<p>hi <b>ada</b></p>");
#   html.innerText(doc) // "hi ada"
#   html.stringify(doc) // "<p>hi <b>ada</b></p>"
#
# Elements map to {tag, attrs, children} (same shape as std/xml, so the
# two stay interchangeable); text nodes are bare strings. Comments are
# dropped on parse, like std/xml. parse returns the array of top-level
# nodes (HTML documents may have several); innerText accepts a node, a
# text string or such an array. Unknown tags keep the parser's
# tagUnknown name. stringify accepts a node, a text string, or an array
# of those; void elements (br, img, ...) emit without a close tag.

import std/[strutils, tables]

import javascriptcore

import pkg/openparser/html

import ../bridge

proc htmlAttrsToJS(ctx: JSContextRef; attrs: auto; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## Attributes table -> plain object (nil-safe).
  result = newObject(ctx)
  if attrs.isNil:
    return
  for k, v in attrs.pairs:
    if not setPropChecked(ctx, result, k, toJS(ctx, v), fname,
        exception):
      return nil

proc htmlNodeToJS(ctx: JSContextRef; n: HtmlNode; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## HtmlNode -> live JS value (elements and text only; comments are
  ## dropped by the caller, never passed here).
  case n.kind
  of htmlTag:
    let attrs = htmlAttrsToJS(ctx, n.attributes, fname, exception)
    if attrs == nil:
      return nil
    var vals: seq[JSValueRef] = @[]
    for c in n.children:
      case c.kind
      of htmlTag, htmlInnerText:
        let j = htmlNodeToJS(ctx, c, fname, exception)
        if j == nil:
          return nil
        vals.add(j)
      else:
        discard
    let children = makeJSArray(ctx, vals)
    if children == nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "tag", toJS(ctx, $n.tag), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "attrs", attrs, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "children", children, fname,
        exception):
      return nil
    obj
  of htmlInnerText:
    toJS(ctx, n.value.text)
  else:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    nil

proc appendPiece(res: var string; piece: string) =
  ## Concatenates with a single space at the boundary when neither
  ## side already has one (mirrors openparser's innerText).
  if piece.len == 0:
    return
  if res.len > 0 and res[^1] != ' ' and piece[0] != ' ':
    res.add(' ')
  res.add(piece)

proc innerTextOf(ctx: JSContextRef; v: JSValueRef; depth: int;
    err: var string): string =
  ## innerText over JS values: strings pass through, arrays and
  ## {children} objects concatenate recursively.
  if v == nil:
    err = "needs a node, text or array of nodes"
    return ""
  if depth > maxDumpDepth:
    err = "is too deeply nested or circular"
    return ""
  case JSValueGetType(ctx, v)
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      err = "is not convertible to string"
      return ""
    defer: JSStringRelease(s)
    $s
  of kJSTypeObject:
    if JSObjectIsFunction(ctx, v):
      err = "needs a node, text or array of nodes"
      return ""
    if JSValueIsArray(ctx, v):
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
      if ex != nil or lenV == nil:
        err = "has an unreadable length"
        return ""
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        err = "has an unreadable length"
        return ""
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx),
          addr eEx)
        if eEx != nil or item == nil:
          err = "has an unreadable index " & $idx
          return ""
        appendPiece(result, innerTextOf(ctx, item, depth + 1, err))
        if err != "":
          return ""
      result
    else:
      let key = newJSString("children")
      defer: JSStringRelease(key)
      var pEx: JSValueRef = nil
      let children = JSObjectGetProperty(ctx, v, key, addr pEx)
      if pEx != nil or children == nil:
        err = "needs a node with a children array"
        return ""
      if not JSValueIsArray(ctx, children):
        err = "needs a node with a children array"
        return ""
      innerTextOf(ctx, children, depth + 1, err)
  else:
    err = "needs a node, text or array of nodes"
    ""

proc hEscText(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc hEscAttr(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

const htmlVoids = ["area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "param", "source", "track", "wbr"]

proc hIsVoid(tag: string): bool =
  for v in htmlVoids:
    if tag == v:
      return true
  false

proc hWriteNode(ctx: JSContextRef; v: JSValueRef; depth: int;
    res: var string) =
  if depth > maxDumpDepth:
    raise newException(CatchableError,
      "node is too deeply nested or circular")
  case JSValueGetType(ctx, v)
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      raise newException(CatchableError,
        "text nodes must be strings")
    defer: JSStringRelease(s)
    res.add(hEscText($s))
  of kJSTypeObject:
    if JSValueIsArray(ctx, v):
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
      if ex != nil or lenV == nil:
        raise newException(CatchableError, "nodes must be an array")
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        raise newException(CatchableError, "nodes must be an array")
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx), addr eEx)
        if eEx != nil or item == nil:
          raise newException(CatchableError, "nodes must be an array")
        hWriteNode(ctx, item, depth + 1, res)
    elif JSObjectIsFunction(ctx, v):
      raise newException(CatchableError,
        "nodes must be {tag, attrs, children}, text, or arrays")
    else:
      let tagKey = newJSString("tag")
      defer: JSStringRelease(tagKey)
      var tEx: JSValueRef = nil
      let tagV = JSObjectGetProperty(ctx, v, tagKey, addr tEx)
      if tEx != nil or tagV == nil or
          JSValueGetType(ctx, tagV) != kJSTypeString:
        raise newException(CatchableError,
          "element nodes need {tag, attrs, children}")
      var sEx: JSValueRef = nil
      let tagS = JSValueToStringCopy(ctx, tagV, addr sEx)
      if tagS == nil:
        raise newException(CatchableError,
          "element nodes need {tag, attrs, children}")
      defer: JSStringRelease(tagS)
      let tag = $tagS
      res.add("<")
      res.add(tag)
      let attrsKey = newJSString("attrs")
      defer: JSStringRelease(attrsKey)
      var aEx: JSValueRef = nil
      let attrsV = JSObjectGetProperty(ctx, v, attrsKey, addr aEx)
      if aEx == nil and attrsV != nil and
          JSValueGetType(ctx, attrsV) == kJSTypeObject and
          not JSValueIsArray(ctx, attrsV):
        let names = JSObjectCopyPropertyNames(ctx, attrsV)
        if names == nil:
          raise newException(CatchableError,
            "element attrs must be an object")
        defer: JSPropertyNameArrayRelease(names)
        let count = int(JSPropertyNameArrayGetCount(names))
        for idx in 0 ..< count:
          let jsName =
            JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
          let key = $jsName
          var pEx: JSValueRef = nil
          let prop = JSObjectGetProperty(ctx, attrsV, jsName, addr pEx)
          if pEx != nil or prop == nil:
            raise newException(CatchableError,
              "element attrs must be an object")
          if JSValueGetType(ctx, prop) != kJSTypeString:
            raise newException(CatchableError,
              "attribute values must be strings")
          var vEx: JSValueRef = nil
          let vs = JSValueToStringCopy(ctx, prop, addr vEx)
          if vs == nil:
            raise newException(CatchableError,
              "attribute values must be strings")
          defer: JSStringRelease(vs)
          res.add(" " & key & "=\"" & hEscAttr($vs) & "\"")
      let chKey = newJSString("children")
      defer: JSStringRelease(chKey)
      var cEx: JSValueRef = nil
      let chV = JSObjectGetProperty(ctx, v, chKey, addr cEx)
      if hIsVoid(tag):
        res.add(">")
      else:
        res.add(">")
        if cEx == nil and chV != nil:
          hWriteNode(ctx, chV, depth + 1, res)
        res.add("</" & tag & ">")
  else:
    raise newException(CatchableError,
      "nodes must be {tag, attrs, children}, text, or arrays")

## Builds the std/html namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## html.parse(text) -> array of nodes ({tag, attrs, children}, text as strings)
      try:
        let doc = parseHtml(text)
        var vals: seq[JSValueRef] = @[]
        for n in doc.nodes:
          case n.kind
          of htmlTag, htmlInnerText:
            let j = htmlNodeToJS(ctx, n, "parse", exception)
            if j == nil:
              throwError(ctx, "parse: could not convert result to JS",
                exception)
              return nil
            vals.add(j)
          else:
            discard
        let arr = makeJSArray(ctx, vals)
        if arr == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        arr
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn innerText(value: JSValueRef):
      ## html.innerText(node) -> string
      var err = ""
      let s = innerTextOf(ctx, value, 0, err)
      if err != "":
        throwError(ctx, "innerText: value " & err, exception)
        return nil
      toJS(ctx, s)

    module.registerFn isInline(tagName: string):
      ## html.isInline(tagName) -> bool
      toJS(ctx, isInline(getHtmlTag(tagName.toLowerAscii())))

    module.registerFn isBlock(tagName: string):
      ## html.isBlock(tagName) -> bool
      toJS(ctx, isBlock(getHtmlTag(tagName.toLowerAscii())))

    module.registerFn stringify(value: JSValueRef):
      ## html.stringify(nodes) -> string
      try:
        var res = ""
        hWriteNode(ctx, value, 0, res)
        toJS(ctx, res)
      except CatchableError as e:
        throwError(ctx, "stringify: " & e.msg, exception)
        nil
