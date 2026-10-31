# Carne std/yaml: YAML parsing and serialization (pure JS).
#
#   const yaml = require("std/yaml");
#   yaml.parse(text)      -> value (objects, arrays, scalars, Date)
#   yaml.stringify(value) -> string (single YAML document)
#
# Single-document in v1: trailing documents after `---` are ignored.
# Core Schema resolution with no legacy 1.1 bools; timestamps resolve
# to Date objects; unknown tags throw.
#
# The implementation lives in js/yaml.js (CommonJS). It is embedded
# at build time via slurp and evaluated on first require, so the
# binary has no runtime file dependency and no openparser dependency
# for yaml.

import javascriptcore

import ../bridge

const yamlJsSource = slurp("js/yaml.js")

proc install*(ctx: JSContextRef; rt: Runtime): JSObjectRef =
  ## Loads the bundled JS implementation as a CommonJS module and
  ## returns its `module.exports`. nil on failure (require reports
  ## "failed to initialize").
  let moduleObj = newObject(ctx)
  let exportsObj = newObject(ctx)
  var setupEx: JSValueRef = nil
  setProp(ctx, moduleObj, "exports", exportsObj, addr setupEx)
  if setupEx != nil:
    return nil
  let wrapped = "(function(module, exports) {\n" & yamlJsSource & "\n})"
  var ex: JSValueRef = nil
  let fn = evalScript(ctx, wrapped, sourceURL = "std/yaml.js",
    exception = ex)
  if ex != nil or fn == nil or not JSValueIsObject(ctx, fn):
    return nil
  let fnObj = cast[JSObjectRef](fn)
  if not JSObjectIsFunction(ctx, fnObj):
    return nil
  var callEx: JSValueRef = nil
  var args: array[2, JSValueRef]
  args[0] = moduleObj
  args[1] = exportsObj
  discard JSObjectCallAsFunction(ctx, fnObj, nil, 2, addr args[0],
    addr callEx)
  if callEx != nil:
    return nil
  var getEx: JSValueRef = nil
  let key = newJSString("exports")
  defer: JSStringRelease(key)
  let finalExp = JSObjectGetProperty(ctx, moduleObj, key, addr getEx)
  if getEx != nil or finalExp == nil or
      not JSValueIsObject(ctx, finalExp):
    return nil
  cast[JSObjectRef](finalExp)
