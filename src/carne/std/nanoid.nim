# Carne std/nanoid: URL-friendly id generation via openparser.
#
#   const {nanoid} = require("std/nanoid");
#   nanoid()                -> "V1StGXR8_Z5jdHi6B-myT" (21 chars)
#   nanoid(10)              -> 10 chars from the URL alphabet
#   const id = require("std/nanoid");
#   id.customAlphabet("abc123", 8) -> 8 chars from "abc123"
#   id.nanoidNonSecure()    -> same shape, non-secure PRNG (DOM keys etc)
#
# Sync only, no event loop. Validation errors throw a JS Error.

import javascriptcore

import pkg/openparser/nanoid

import ../bridge

## Builds the std/nanoid namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn nanoid(size: default(int, defaultSize)):
      ## nanoid.nanoid([size]) -> URL-safe id string
      if size <= 0 or size > 1024:
        throwError(ctx, "nanoid: size must be 1..1024, got " & $size,
          exception)
        return nil
      try:
        toJS(ctx, nanoid(size))
      except CatchableError as e:
        throwError(ctx, "nanoid: " & e.msg, exception)
        nil

    module.registerFn customAlphabet(alphabet: string,
        size: default(int, defaultSize)):
      ## nanoid.customAlphabet(alphabet[, size]) -> id string
      if size <= 0 or size > 1024:
        throwError(ctx,
          "customAlphabet: size must be 1..1024, got " & $size, exception)
        return nil
      try:
        toJS(ctx, customAlphabet(alphabet, size))
      except CatchableError as e:
        throwError(ctx, "customAlphabet: " & e.msg, exception)
        nil

    module.registerFn nanoidNonSecure(size: default(int, defaultSize)):
      ## nanoid.nanoidNonSecure([size]) -> id string (non-secure PRNG)
      if size <= 0 or size > 1024:
        throwError(ctx,
          "nanoidNonSecure: size must be 1..1024, got " & $size, exception)
        return nil
      try:
        toJS(ctx, nanoidNonSecure(size))
      except CatchableError as e:
        throwError(ctx, "nanoidNonSecure: " & e.msg, exception)
        nil

  setProp(module.ctx, module.ns, "urlAlphabet",
    toJS(module.ctx, urlAlphabet), nil)
  setProp(module.ctx, module.ns, "defaultSize",
    toJS(module.ctx, defaultSize), nil)
