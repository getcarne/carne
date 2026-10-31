# Carne std/str: string utilities (pure JS).
#
#   const str = require("std/str");
#   str.indexOf(hay, needle)  -> int (-1 when absent)
#   str.toUpperCase(s)        -> string
#   str.lines(s)              -> array of strings
#   str.isEmail(s)            -> bool
#
# Free-function style: the subject string is always the first argument.
# Semantics are exactly the JS builtins' wherever one exists; the rest
# is documented on each function. Includes eight validators (isEmail,
# isDomain, isIPv4, isIPv6, isIP, isWebUrl, isUUID, isPort).
#
# The implementation lives in js/str.js (CommonJS). It is embedded
# at build time via slurp and evaluated on first require, so the
# binary has no runtime file dependency.

import javascriptcore

import ../bridge

const strJsSource = slurp("js/str.js")

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
  let wrapped = "(function(module, exports) {\n" & strJsSource & "\n})"
  var ex: JSValueRef = nil
  let fn = evalScript(ctx, wrapped, sourceURL = "std/str.js",
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
