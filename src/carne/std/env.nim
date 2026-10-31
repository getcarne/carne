# Carne std/env: process environment and `.env` file handling.
#
#   const env = require("std/env");
#   env.args()              -> process.argv as a fresh array
#   env.getEnv("HOME")      -> string | undefined
#   env.putEnv("KEY", "v")  -> undefined (writes into process env)
#   env.delEnv("KEY")       -> undefined (removes from process env)
#   env.hasEnv("KEY")       -> bool
#   env.parse(text)         -> object (with variable expansion applied)
#   env.load([path][, override]) -> undefined (writes into process env,
#                                 defaults to ".env")
#   env.cwd()               -> string
#   env.exit(2)             -> terminates the run with exit code 2

import std/os
import std/tables

import javascriptcore

# Narrow import: a full `import powpow/loop` re-exports `init`, which
# would shadow bridge's `init` macro in overload resolution.
from powpow/loop import stop

import pkg/openparser/dotenv

import ../bridge

init proc(module: Module) =
  ## Builds the std/env namespace object.
  exportObject:

    module.registerFn args():
      ## env.args() -> process.argv as a fresh array
      let rt = currentRt()
      var vals: seq[JSValueRef] = @[]
      for arg in rt.argv:
        vals.add(toJS(ctx, arg))
      var ex: JSValueRef = nil
      let arr =
        if vals.len > 0:
          JSObjectMakeArray(ctx, csize_t(vals.len), addr vals[0], addr ex)
        else:
          JSObjectMakeArray(ctx, 0, nil, addr ex)
      if arr == nil:
        if ex != nil and exception != nil:
          exception[] = ex
        return nil
      arr

    module.registerFn getEnv(key: string):
      ## env.getEnv("HOME") -> string | undefined
      if not existsEnv(key):
        return JSValueMakeUndefined(ctx)
      toJS(ctx, getEnv(key))

    module.registerFn putEnv(key: string, value: string):
      ## env.putEnv("KEY", "value") -> undefined
      try:
        putEnv(key, value)
      except CatchableError as e:
        throwError(ctx, "putEnv: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn delEnv(key: string):
      ## env.delEnv("KEY") -> undefined
      try:
        delEnv(key)
      except CatchableError as e:
        throwError(ctx, "delEnv: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn hasEnv(key: string):
      ## env.hasEnv("KEY") -> bool
      toJS(ctx, existsEnv(key))

    module.registerFn parse(text: string):
      ## env.parse(text) -> object (with variable expansion applied)
      try:
        # Same expansion loadDotenv applies, collected into an object
        # instead of the process environment.
        var local = initTable[string, string]()
        var cmdCache = initTable[string, string]()
        let obj = newObject(ctx)
        var ex: JSValueRef = nil
        for e in parseEnv(text):
          let v =
            if e.expand: expandValue(e.value, local, cmdCache)
            else: e.value
          local[e.key] = v
          setProp(ctx, obj, e.key, toJS(ctx, v), addr ex)
          if ex != nil:
            throwError(ctx, "parse: could not convert result to JS",
              exception)
            return nil
        obj
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn load(path: default(string, ".env"),
        override ?: bool):
      ## env.load([path][, override]) -> undefined (writes into process env)
      try:
        loadDotenv(path, override)
      except CatchableError as e:
        throwError(ctx, "load: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn cwd():
      ## env.cwd() -> string
      try:
        toJS(ctx, getCurrentDir())
      except OSError as e:
        throwError(ctx, "cwd: " & e.msg, exception)
        nil

    module.registerFn exit(code ?: float):
      ## env.exit(2) -> terminates the run with exit code 2
      let rt = currentRt()
      rt.exitCode = int(code)
      rt.exitRequested = true
      if rt.loop != nil:
        rt.loop.stop()
      JSValueMakeUndefined(ctx)
