# Carne std/test: minimal test runner (pure JS).
#
#   const { test, describe, it, expect, assert } =
#     require("std/test");
#   test("adds", () => { expect(1 + 1).toBe(2); });
#   describe("math", () => {
#     it("throws", () => { assert.throws(() => bad()); });
#   });
#
# Two styles, user decides: `expect` matchers or Node-style `assert`.
# Registration is synchronous; execution is deferred through a
# zero-delay timer so tests run after the file finishes evaluating
# (works under both `carne run` and `carne test`). Async test
# functions (promise-returning) are awaited serially. Results print
# as `ok - <name>` / `fail - <name>` lines plus a summary; any
# failure throws at the end (exit 1).
#
# The implementation lives in js/test.js (CommonJS). It is embedded
# at build time via slurp and evaluated on first require, so the
# binary has no runtime file dependency.

import javascriptcore

import ../bridge

const testJsSource = slurp("js/test.js")

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
  let wrapped = "(function(module, exports) {\n" & testJsSource & "\n})"
  var ex: JSValueRef = nil
  let fn = evalScript(ctx, wrapped, sourceURL = "std/test.js",
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
