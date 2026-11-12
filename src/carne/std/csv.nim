# Carne std/csv: CSV parsing and serialization.
#
#   const csv = require("std/csv");
#   csv.parse(text[, {headers, delimiter, quote}]) -> array
#   csv.stringify(value[, {delimiter, quote, headers}]) -> string
#
# Without headers: array of string arrays. With `headers: true` the first
# row becomes keys and the result is an array of objects. openparser's CSV
# reader is MemFile-based, so input goes through a temp file.
# stringify is a Carne writer (openparser has no CSV dump): array of
# arrays writes rows directly; array of objects writes the first object's
# keys as the header row plus one row per object (missing keys read as
# ""). Cells coerce (numbers/bools to text, null to ""); fields holding
# the delimiter, quote, or a newline are quoted with doubled quotes.

import std/math
import std/os
import std/strutils
import std/tables

import javascriptcore

import pkg/openparser/csv

import ../bridge

## Builds the std/csv namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn parse(text: string, optsObj ?: JSObjectRef):
      ## csv.parse(text[, {headers, delimiter, quote}]) -> array
      var headers = false
      var opts = defaultCsvOptions()
      if optsObj != nil:
        var err = ""
        let h = getField(ctx, optsObj, "headers", err)
        if err != "":
          throwError(ctx, "parse: options.headers " & err, exception)
          return nil
        if h.kind == nvkBool:
          headers = h.b
        let d = getField(ctx, optsObj, "delimiter", err)
        if err != "":
          throwError(ctx, "parse: options.delimiter " & err, exception)
          return nil
        if d.kind == nvkString and d.s.len > 0:
          opts.delimiter = d.s[0]
        let q = getField(ctx, optsObj, "quote", err)
        if err != "":
          throwError(ctx, "parse: options.quote " & err, exception)
          return nil
        if q.kind == nvkString and q.s.len > 0:
          opts.quote = q.s[0]
      let tmp = getTempDir() / "carne_csv_parse.tmp"
      try:
        writeFile(tmp, text)
      except IOError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        return nil
      var rows: seq[seq[string]] = @[]
      try:
        proc onRow(fields: openArray[CsvFieldSlice], row: int): bool =
          var r: seq[string] = @[]
          for f in fields:
            r.add($f)
          rows.add(r)
          true
        parseFile(tmp, onRow, opts)
      except CatchableError as e:
        try: removeFile(tmp)
        except OSError: discard
        throwError(ctx, "parse: " & e.msg, exception)
        return nil
      try: removeFile(tmp)
      except OSError: discard
      try:
        var vals: seq[JSValueRef] = @[]
        if headers and rows.len > 0:
          let heads = rows[0]
          for r in rows[1 .. ^1]:
            let obj = newObject(ctx)
            var ex: JSValueRef = nil
            for i, h in heads:
              setProp(ctx, obj, h, toJS(ctx, if i < r.len: r[i] else: ""),
                addr ex)
              if ex != nil:
                throwError(ctx, "parse: could not convert result to JS",
                  exception)
                return nil
            vals.add(obj)
        elif not headers:
          for r in rows:
            var fvals: seq[JSValueRef] = @[]
            for f in r:
              fvals.add(toJS(ctx, f))
            let a = makeJSArray(ctx, fvals)
            if a == nil:
              throwError(ctx, "parse: could not convert result to JS",
                exception)
              return nil
            vals.add(a)
        let arr = makeJSArray(ctx, vals)
        if arr == nil:
          throwError(ctx, "parse: could not convert result to JS",
            exception)
          return nil
        arr
      except CatchableError as e:
        throwError(ctx, "parse: " & e.msg, exception)
        nil

    module.registerFn stringify(value: NimValue, optsObj ?: JSObjectRef):
      ## csv.stringify(value[, {delimiter, quote, headers}]) -> string
      var delim = ','
      var quote = '"'
      var headers = true
      if optsObj != nil:
        var err = ""
        let d = getField(ctx, optsObj, "delimiter", err)
        if err != "":
          throwError(ctx, "stringify: options.delimiter " & err, exception)
          return nil
        if d.kind == nvkString and d.s.len > 0:
          delim = d.s[0]
        let q = getField(ctx, optsObj, "quote", err)
        if err != "":
          throwError(ctx, "stringify: options.quote " & err, exception)
          return nil
        if q.kind == nvkString and q.s.len > 0:
          quote = q.s[0]
        let h = getField(ctx, optsObj, "headers", err)
        if err != "":
          throwError(ctx, "stringify: options.headers " & err, exception)
          return nil
        if h.kind == nvkBool:
          headers = h.b
      if value.kind != nvkArray:
        throwError(ctx, "stringify: expected array, got " &
          jsTypeName(value.kind), exception)
        return nil
      if value.arr.len == 0:
        return toJS(ctx, "")
      proc cellText(v: NimValue): string =
        case v.kind
        of nvkString: v.s
        of nvkInt: $v.i
        of nvkFloat:
          if v.f == trunc(v.f) and abs(v.f) < 9007199254740991.0:
            $(int64(v.f))
          else:
            $v.f
        of nvkBool:
          if v.b: "true" else: "false"
        of nvkNull, nvkUndefined: ""
        else: ""
      proc needsQuote(s: string): bool =
        for c in s:
          if c == delim or c == quote or c == '\n' or c == '\r':
            return true
        false
      proc escField(s: string): string =
        if not needsQuote(s):
          return s
        result = newStringOfCap(s.len + 2)
        result.add(quote)
        for c in s:
          if c == quote:
            result.add(quote)
            result.add(quote)
          else:
            result.add(c)
        result.add(quote)
      try:
        var rows: seq[seq[string]] = @[]
        if value.arr[0].kind == nvkArray:
          for item in value.arr:
            if item.kind != nvkArray:
              throwError(ctx, "stringify: expected array of arrays " &
                "or array of objects, got mixed kinds", exception)
              return nil
            var r: seq[string] = @[]
            for cell in item.arr:
              if cell.kind in {nvkObject, nvkArray, nvkFunction,
                  nvkSymbol, nvkBigInt}:
                throwError(ctx, "stringify: cells must be scalars, got " &
                  jsTypeName(cell.kind), exception)
                return nil
              r.add(escField(cellText(cell)))
            rows.add(r)
        elif value.arr[0].kind == nvkObject:
          var colKeys: seq[string] = @[]
          for k in keys(value.arr[0].obj):
            colKeys.add(k)
          if headers:
            var hr: seq[string] = @[]
            for k in colKeys:
              hr.add(escField(k))
            rows.add(hr)
          for item in value.arr:
            if item.kind != nvkObject:
              throwError(ctx, "stringify: expected array of arrays " &
                "or array of objects, got mixed kinds", exception)
              return nil
            var r: seq[string] = @[]
            for k in colKeys:
              if item.obj.hasKey(k):
                let cell = item.obj[k]
                if cell.kind in {nvkObject, nvkArray, nvkFunction,
                    nvkSymbol, nvkBigInt}:
                  throwError(ctx, "stringify: cells must be scalars, got " &
                    jsTypeName(cell.kind), exception)
                  return nil
                r.add(escField(cellText(cell)))
              else:
                r.add("")
            rows.add(r)
        else:
          throwError(ctx, "stringify: expected array of arrays or " &
            "array of objects", exception)
          return nil
        var outLines: seq[string] = @[]
        for r in rows:
          outLines.add(r.join($delim))
        toJS(ctx, outLines.join("\n"))
      except CatchableError as e:
        throwError(ctx, "stringify: " & e.msg, exception)
        nil
