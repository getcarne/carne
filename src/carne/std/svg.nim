# Carne std/svg: SVG parsing and serialization via openparser.
#
#   const svg = require("std/svg");
#   svg.parse('<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>')
#     -> {kind: "element", tag: "svg", attrs: {...}, children: [...]}
#   svg.stringify(node) -> string (HTML-embeddable svg)
#
# Elements map to {kind, tag, attrs, children} (text, comments and CDATA
# become {kind, text} leaves; bare strings also stringify as text).
# stringify accepts exactly what parse emits.

import std/[tables, strutils]

import javascriptcore

import pkg/openparser/svg/parser
import pkg/openparser/svg/ast
import pkg/openparser/svg/serializer

import ../bridge

proc svgToJS(ctx: JSContextRef; n: SvgNode; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## SvgNode -> live JS value, no JsonNode middle layer.
  case n.kind
  of svgElement:
    let attrs = newObject(ctx)
    for k, v in n.attrsRaw:
      if not setPropChecked(ctx, attrs, k, toJS(ctx, v), fname,
          exception):
        return nil
    var vals: seq[JSValueRef] = @[]
    for c in n.children:
      let j = svgToJS(ctx, c, fname, exception)
      if j == nil:
        return nil
      vals.add(j)
    var ex: JSValueRef = nil
    let children =
      if vals.len > 0:
        JSObjectMakeArray(ctx, csize_t(vals.len), addr vals[0], addr ex)
      else:
        JSObjectMakeArray(ctx, 0, nil, addr ex)
    if ex != nil:
      throwError(ctx, fname & ": could not convert result to JS",
        exception)
      return nil
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "kind", toJS(ctx, "element"), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "tag", toJS(ctx, tagName(n)), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "attrs", attrs, fname, exception):
      return nil
    if not setPropChecked(ctx, obj, "children", children, fname,
        exception):
      return nil
    result = obj
  of svgTextNode:
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "kind", toJS(ctx, "text"), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "text", toJS(ctx, n.text), fname,
        exception):
      return nil
    result = obj
  of svgCommentNode:
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "kind", toJS(ctx, "comment"), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "text", toJS(ctx, n.comment), fname,
        exception):
      return nil
    result = obj
  of svgCdataNode:
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "kind", toJS(ctx, "cdata"), fname,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "text", toJS(ctx, n.cdata), fname,
        exception):
      return nil
    result = obj

proc svgErr(msg: string): ref CatchableError =
  newException(CatchableError, msg)

proc jsSvgProp(ctx: JSContextRef; obj: JSValueRef; key: string): JSValueRef =
  ## Raw required property. Raises like the xml validators.
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  if ex != nil or prop == nil:
    raise svgErr("node object needs \"" & key & "\"")
  if JSValueGetType(ctx, prop) == kJSTypeUndefined:
    raise svgErr("node object needs \"" & key & "\"")
  prop

proc jsSvgStr(ctx: JSContextRef; v: JSValueRef; what: string): string =
  ## Strict string conversion. Raises on failure.
  if JSValueGetType(ctx, v) != kJSTypeString:
    raise svgErr(what & " must be a string")
  var ex: JSValueRef = nil
  let s = JSValueToStringCopy(ctx, v, addr ex)
  if s == nil:
    raise svgErr(what & " must be a string")
  defer: JSStringRelease(s)
  $s

proc jsToSvgNode(ctx: JSContextRef; v: JSValueRef; depth: int): SvgNode =
  ## {kind, ...} (or a bare text string) -> SvgNode in one walk.
  ## Accepts exactly what parse emits; anything else throws.
  if v == nil:
    raise svgErr("node must be an svg object or text string")
  if depth > maxDumpDepth:
    raise svgErr("node is too deeply nested or circular")
  if JSValueGetType(ctx, v) == kJSTypeString:
    return newSvgText(jsSvgStr(ctx, v, "text node"))
  if JSValueGetType(ctx, v) != kJSTypeObject or
      JSValueIsArray(ctx, v) or JSObjectIsFunction(ctx, v):
    raise svgErr("node must be an svg object or text string")
  var kind = ""
  try:
    kind = jsSvgStr(ctx, jsSvgProp(ctx, v, "kind"), "\"kind\"")
  except CatchableError:
    kind = ""
  if kind == "text":
    return newSvgText(jsSvgStr(ctx, jsSvgProp(ctx, v, "text"),
      "text node"))
  if kind == "comment":
    return newSvgComment(jsSvgStr(ctx, jsSvgProp(ctx, v, "text"),
      "comment node"))
  if kind == "cdata":
    return newSvgCdata(jsSvgStr(ctx, jsSvgProp(ctx, v, "text"),
      "cdata node"))
  if kind.len > 0 and kind != "element":
    raise svgErr("unknown node kind \"" & kind & "\"")
  let tagName = jsSvgStr(ctx, jsSvgProp(ctx, v, "tag"), "\"tag\"")
  let attrsProp = jsSvgProp(ctx, v, "attrs")
  if JSValueGetType(ctx, attrsProp) != kJSTypeObject or
      JSValueIsArray(ctx, attrsProp):
    raise svgErr("node object needs an object \"attrs\"")
  let childrenProp = jsSvgProp(ctx, v, "children")
  if not JSValueIsArray(ctx, childrenProp):
    raise svgErr("node object needs an array \"children\"")
  let node = newSvgElement(getSvgTag(tagName), tagName)
  let names = JSObjectCopyPropertyNames(ctx, attrsProp)
  if names == nil:
    raise svgErr("node object needs an object \"attrs\"")
  defer: JSPropertyNameArrayRelease(names)
  for idx in 0 ..< int(JSPropertyNameArrayGetCount(names)):
    let jsName = JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
    let key = $jsName
    var pEx: JSValueRef = nil
    let aval = JSObjectGetProperty(ctx, attrsProp, jsName, addr pEx)
    if pEx != nil or aval == nil:
      raise svgErr("attribute \"" & key & "\" must be a string")
    node.attrsRaw[key] = jsSvgStr(ctx, aval,
      "attribute \"" & key & "\"")
  var lenEx: JSValueRef = nil
  let lenKey = newJSString("length")
  defer: JSStringRelease(lenKey)
  let lenV = JSObjectGetProperty(ctx, childrenProp, lenKey, addr lenEx)
  if lenEx != nil or lenV == nil:
    raise svgErr("node object needs an array \"children\"")
  var lenEx2: JSValueRef = nil
  let n = int(JSValueToNumber(ctx, lenV, addr lenEx2))
  if lenEx2 != nil or n < 0:
    raise svgErr("node object needs an array \"children\"")
  for idx in 0 ..< n:
    var eEx: JSValueRef = nil
    let item = JSObjectGetPropertyAtIndex(ctx, childrenProp, cuint(idx),
      addr eEx)
    if eEx != nil or item == nil:
      raise svgErr("node must be an svg object or text string")
    node.children.add(jsToSvgNode(ctx, item, depth + 1))
  node

## Builds the std/svg namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## svg.parse(text) -> {kind, tag, attrs, children}
      try:
        let doc = parseSvg(text)
        if doc.root == nil:
          throwError(ctx, "parse: no root element", exception)
          return nil
        let j = svgToJS(ctx, doc.root, "parse", exception)
        if j == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        # Parser errors start with a newline + code snippet.
        throwError(ctx, "parse:" & e.msg, exception)
        nil

    module.registerFn stringify(value: JSValueRef, optsObj ?: JSObjectRef):
      ## svg.stringify(node[, {pretty, minify}]) -> string (HTML-embeddable svg)
      var opts = defaultSvgSerializeOptions()
      if optsObj != nil:
        for (key, dst) in [("pretty", addr opts.pretty),
            ("minify", addr opts.minify)]:
          var err = ""
          let f = getField(ctx, optsObj, key, err)
          if err != "":
            throwError(ctx, "stringify: options." & key & " " & err,
              exception)
            return nil
          if f.kind == nvkUndefined:
            continue
          if f.kind != nvkBool:
            throwError(ctx, "stringify: options." & key &
              " must be a boolean", exception)
            return nil
          dst[] = f.b
      try:
        let node = jsToSvgNode(ctx, value, 0)
        if node.kind != svgElement:
          throwError(ctx, "stringify: root must be an element node",
            exception)
          return nil
        toJS(ctx, toSvg(node, opts))
      except CatchableError as e:
        throwError(ctx, "stringify: " & e.msg, exception)
        nil
