# Carne std/yaml: YAML parsing and serialization via openparser.
#
#   const yaml = require("std/yaml");
#   yaml.parse(text)      -> value (objects, arrays, scalars)
#   yaml.stringify(value) -> string (single YAML document)
#
# Single-document in v1: trailing documents after `---` are ignored.

import std/[math, tables]

import javascriptcore

import pkg/openparser/yaml

import ../bridge

proc yamlNodeToJS(ctx: JSContextRef; n: YamlNode): JSValueRef =
  ## YamlNode -> live JS value, no JsonNode middle layer (which cost a
  ## build walk, a stringify, and a JSC re-parse per call).
  case n.kind
  of yamlNull:
    result = JSValueMakeNull(ctx)
  of yamlBoolean:
    result = toJS(ctx, n.boolValue)
  of yamlInteger:
    result = toJS(ctx, n.intValue)
  of yamlFloat:
    result = toJS(ctx, n.floatValue)
  of yamlString:
    result = toJS(ctx, n.strValue)
  of yamlObject:
    let obj = newObject(ctx)
    var ex: JSValueRef = nil
    for k, v in n.objValue.pairs:
      let j = yamlNodeToJS(ctx, v)
      if j == nil:
        return nil
      setProp(ctx, obj, k, j, addr ex)
      if ex != nil:
        return nil
    result = obj
  of yamlArray:
    var vals: seq[JSValueRef] = @[]
    for item in n.arrValue:
      let j = yamlNodeToJS(ctx, item)
      if j == nil:
        return nil
      vals.add(j)
    var ex: JSValueRef = nil
    let arr =
      if vals.len > 0:
        JSObjectMakeArray(ctx, csize_t(vals.len), addr vals[0], addr ex)
      else:
        JSObjectMakeArray(ctx, 0, nil, addr ex)
    if ex != nil:
      result = nil
    else:
      result = arr

proc jsToYamlNode(ctx: JSContextRef; v: JSValueRef; depth: int;
    err: var string): YamlNode =
  ## Live JS value -> YamlNode in one walk, feeding dump directly.
  ## Replaces jsToJson (JSC stringify + re-parse) with zero string
  ## conversions. Scalar mapping mirrors JSON semantics: non-finite
  ## numbers read as null, functions/symbols/undefined are dropped
  ## from objects and null in arrays, bigints throw.
  if v == nil:
    err = "is null"
    return nil
  if depth > maxDumpDepth:
    err = "is too deeply nested or circular"
    return nil
  if jsSkipped(ctx, v):
    err = "value is not YAML-serializable"
    return nil
  case JSValueGetType(ctx, v)
  of kJSTypeUndefined, kJSTypeSymbol:
    err = "value is not YAML-serializable"
    result = nil
  of kJSTypeNull:
    result = YamlNode(kind: yamlNull)
  of kJSTypeBoolean:
    result = YamlNode(kind: yamlBoolean, boolValue: JSValueToBoolean(ctx, v))
  of kJSTypeNumber:
    var ex: JSValueRef = nil
    let f = JSValueToNumber(ctx, v, addr ex)
    if ex != nil:
      err = "is not a number"
      return nil
    if f != f or f == Inf or f == -Inf:
      result = YamlNode(kind: yamlNull)
    elif f == trunc(f) and abs(f) < 9223372036854775808.0:
      result = YamlNode(kind: yamlInteger, intValue: int64(f))
    else:
      result = YamlNode(kind: yamlFloat, floatValue: f)
  of kJSTypeString:
    var ex: JSValueRef = nil
    let s = JSValueToStringCopy(ctx, v, addr ex)
    if s == nil:
      err = "is not convertible to string"
      return nil
    defer: JSStringRelease(s)
    result = YamlNode(kind: yamlString, strValue: $s)
  of kJSTypeBigInt:
    err = "value is not YAML-serializable"
    result = nil
  of kJSTypeObject:
    if JSValueIsArray(ctx, v):
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, v, lenKey, addr ex)
      if ex != nil or lenV == nil:
        err = "has an unreadable length"
        return nil
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        err = "has an unreadable length"
        return nil
      result = YamlNode(kind: yamlArray, arrValue: @[])
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, v, cuint(idx), addr eEx)
        if eEx != nil or item == nil:
          err = "has an unreadable index " & $idx
          return nil
        # JSON holes: dropped values read back as null.
        if jsSkipped(ctx, item):
          result.arrValue.add(YamlNode(kind: yamlNull))
        else:
          let nv = jsToYamlNode(ctx, item, depth + 1, err)
          if err != "":
            return nil
          result.arrValue.add(nv)
    else:
      let names = JSObjectCopyPropertyNames(ctx, v)
      if names == nil:
        err = "has unreadable properties"
        return nil
      defer: JSPropertyNameArrayRelease(names)
      result = YamlNode(kind: yamlObject,
        objValue: newOrderedTable[string, YamlNode]())
      let count = int(JSPropertyNameArrayGetCount(names))
      for idx in 0 ..< count:
        let jsName =
          JSPropertyNameArrayGetNameAtIndex(names, csize_t(idx))
        let key = $jsName
        var pEx: JSValueRef = nil
        let prop = JSObjectGetProperty(ctx, v, jsName, addr pEx)
        if pEx != nil or prop == nil:
          err = "has an unreadable property \"" & key & "\""
          return nil
        # JSON holes: dropped values are skipped.
        if jsSkipped(ctx, prop):
          continue
        let nv = jsToYamlNode(ctx, prop, depth + 1, err)
        if err != "":
          return nil
        result.objValue[key] = nv

## Builds the std/yaml namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string):
      ## yaml.parse(text) -> value (objects, arrays, scalars)
      try:
        let j = yamlNodeToJS(ctx, parseYAMLNode(text))
        if j == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        j
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn stringify(value: JSValueRef):
      ## yaml.stringify(value) -> string (single YAML document)
      var err = ""
      let node = jsToYamlNode(ctx, value, 0, err)
      if node == nil:
        throwError(ctx, "stringify: " & err, exception)
        return nil
      try:
        toJS(ctx, dump(node))
      except CatchableError as e:
        throwError(ctx, "stringify: " & e.msg, exception)
        nil
