# Carne std/terminal: terminal styling, size, raw output, interactive
# reads and CLI arg parsing.
#
#   const terminal = require("std/terminal");
#   terminal.green("ok")        -> "ok" in green (plain when colors off)
#   terminal.red/bold/...       -> same for red/yellow/blue/magenta/cyan,
#                                  gray, bold, dim, underline
#   terminal.colorEnabled()     -> bool (the NO_COLOR/TERM=dumb gate)
#   terminal.stripAnsi(text)    -> string without CSI sequences
#   terminal.write(text)        -> undefined (stdout, no newline)
#   terminal.isTTY()            -> bool
#   terminal.columns()          -> int (80 when unknown)
#   terminal.rows()             -> int (24 when unknown)
#   terminal.readLine([prompt]) -> string | null (blocks the loop)
#   terminal.readPassword([prompt]) -> string | null (no echo, blocks)
#   terminal.parseArgs([argv][, opts]) -> {_: [...], ...}
#
# Styling mirrors the CLI's own rule: colors die under NO_COLOR or
# TERM=dumb. write/readLine/readPassword touch the real terminal and
# block the loop like os.exec: fine in scripts, stalls servers.

import std/os
import std/strutils
import std/tables
import std/terminal

import javascriptcore

import ../bridge
import ../runtime

const ansiReset = "\e[0m"

proc colorsOn(): bool =
  ## The CLI's rule, verbatim: NO_COLOR set to anything non-empty (or
  ## TERM=dumb) kills colors; unset/empty NO_COLOR keeps them.
  getEnv("NO_COLOR") == "" and getEnv("TERM") != "dumb"

proc paint(code, text: string): string =
  ## Wraps text in one SGR code, or returns it untouched when colors
  ## are off. One reset at the end (no nesting support: callers pass
  ## plain text, like every other styler in this ecosystem).
  if colorsOn():
    "\e[" & code & "m" & text & ansiReset
  else:
    text

proc stripAnsiCodes(s: string): string =
  ## Drops CSI sequences (ESC [ params intermediates final). Covers
  ## everything this module emits (SGR) plus cursor/screen codes from
  ## elsewhere. A bare ESC not followed by `[` is kept verbatim.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'@' .. '~'}:
        inc i
      if i < s.len:
        inc i
    else:
      result.add(s[i])
      inc i

type
  ParsedArgs = object
    ## parseArgs working state: values in first-set order, positionals
    ## in arrival order.
    vals: OrderedTable[string, NimValue]
    pos: seq[string]

proc aliasesOf(groups: Table[string, seq[string]];
    name: string): seq[string] =
  ## The full alias set for name (itself when unaliased).
  if groups.hasKey(name):
    groups[name]
  else:
    @[name]

proc setArg(dst: var ParsedArgs; groups: Table[string, seq[string]];
    key: string; val: NimValue) =
  ## Sets key and every alias to val (last write wins everywhere).
  for name in aliasesOf(groups, key):
    dst.vals[name] = val

proc setArgAbsent(dst: var ParsedArgs; groups: Table[string, seq[string]];
    key: string; val: NimValue) =
  ## setArg only for names with no value yet (positionals lose to
  ## explicit flags, defaults lose to everything).
  for name in aliasesOf(groups, key):
    if not dst.vals.hasKey(name):
      dst.vals[name] = val

proc readStrSeq(ctx: JSContextRef; opts: NimValue; key, fname: string;
    exception: ptr JSValueRef; dst: var seq[string]): bool =
  ## Reads opts[key] as an array of strings. Absent (or undefined)
  ## means empty and still succeeds; anything else throws.
  dst = @[]
  if opts.kind != nvkObject or not opts.obj.hasKey(key):
    return true
  let v = opts.obj[key]
  if v.kind == nvkUndefined:
    return true
  if v.kind != nvkArray:
    throwError(ctx, fname & ": \"" & key &
      "\" must be an array of strings", exception)
    return false
  for item in v.arr:
    if item.kind != nvkString:
      throwError(ctx, fname & ": \"" & key &
        "\" must be an array of strings", exception)
      return false
    dst.add(item.s)
  true

proc readAliases(ctx: JSContextRef; opts: NimValue; fname: string;
    exception: ptr JSValueRef;
    groups: var Table[string, seq[string]]): bool =
  ## Reads opts.alias as {name: string | string[]} into connected
  ## alias groups (transitive: {a: "b"} plus {b: "c"} links a, b and c).
  groups = initTable[string, seq[string]]()
  if opts.kind != nvkObject or not opts.obj.hasKey("alias"):
    return true
  let v = opts.obj["alias"]
  if v.kind == nvkUndefined:
    return true
  if v.kind != nvkObject:
    throwError(ctx, fname & ": \"alias\" must be an object", exception)
    return false
  var pairs: seq[(string, string)] = @[]
  for name, av in v.obj.pairs:
    case av.kind
    of nvkString:
      pairs.add((name, av.s))
    of nvkArray:
      for item in av.arr:
        if item.kind != nvkString:
          throwError(ctx, fname & ": \"alias\" values must be strings",
            exception)
          return false
        pairs.add((name, item.s))
    of nvkUndefined:
      discard
    else:
      throwError(ctx, fname & ": \"alias\" values must be strings",
        exception)
      return false
  var compOf = initTable[string, int]()
  var comps: seq[seq[string]] = @[]
  proc find(m: var Table[string, int]; x: string): int =
    if not m.hasKey(x):
      m[x] = m.len
    m[x]
  for (a, b) in pairs:
    let ca = find(compOf, a)
    let cb = find(compOf, b)
    if ca != cb:
      for k, c in compOf.mpairs:
        if c == cb:
          c = ca
  for k, c in compOf.pairs:
    while comps.len <= c:
      comps.add(@[])
    comps[c].add(k)
  for members in comps:
    for m in members:
      groups[m] = members
  true

proc isFlagToken(s: string): bool =
  ## True when s must not be swallowed as an option value: starts with
  ## `-`, except the lone `-` (stdin convention, a value like any).
  s.len > 1 and s[0] == '-' and s != "-"

proc parseArgv(args: seq[string]; boolOpts, strOpts: seq[string];
    groups: Table[string, seq[string]]): ParsedArgs =
  ## The actual scan. Values are never coerced: everything stays a
  ## string or a boolean (a deliberate split from minimist, whose
  ## numeric guessing surprises; callers convert explicitly). `--key`
  ## and single `-k` consume the next token as their value unless it
  ## looks like a flag (declared strings take "" then, anything else
  ## reads true); combined shorts (`-abc`) never reach past their own
  ## token. Known booleans never consume: `--flag value` reads the
  ## flag true and parks value as positional.
  result = ParsedArgs(vals: initOrderedTable[string, NimValue](), pos: @[])
  var i = 0
  var onlyPos = false
  while i < args.len:
    let a = args[i]
    if onlyPos:
      result.pos.add(a)
    elif a == "--":
      onlyPos = true
    elif a.len > 2 and a[0] == '-' and a[1] == '-':
      let rest = a[2 .. ^1]
      let eq = rest.find('=')
      if eq >= 0:
        let key = rest[0 ..< eq]
        if key == "":
          result.pos.add(a)
        else:
          setArg(result, groups, key,
            NimValue(kind: nvkString, s: rest[eq + 1 .. ^1]))
      elif rest.len > 3 and rest[0 .. 2] == "no-" and
          rest[3 .. ^1] notin strOpts:
        # `--no-cache` reads false, unless the key is a declared
        # string (then it is just an oddly named option).
        setArg(result, groups, rest[3 .. ^1],
          NimValue(kind: nvkBool, b: false))
      elif rest in boolOpts:
        setArg(result, groups, rest, NimValue(kind: nvkBool, b: true))
      elif i + 1 < args.len and not isFlagToken(args[i + 1]):
        setArg(result, groups, rest,
          NimValue(kind: nvkString, s: args[i + 1]))
        inc i
      elif rest in strOpts:
        setArg(result, groups, rest, NimValue(kind: nvkString, s: ""))
      else:
        setArg(result, groups, rest, NimValue(kind: nvkBool, b: true))
    elif a.len > 1 and a[0] == '-' and a != "-" and
        not (a[1] in {'0' .. '9'}):
      # A lone `-5` is a positional, not flag "5".
      if a.len == 2:
        let ch = $a[1]
        if ch in boolOpts:
          setArg(result, groups, ch, NimValue(kind: nvkBool, b: true))
        elif i + 1 < args.len and not isFlagToken(args[i + 1]):
          setArg(result, groups, ch,
            NimValue(kind: nvkString, s: args[i + 1]))
          inc i
        elif ch in strOpts:
          setArg(result, groups, ch, NimValue(kind: nvkString, s: ""))
        else:
          setArg(result, groups, ch, NimValue(kind: nvkBool, b: true))
      else:
        let rest = a[1 .. ^1]
        let eq = rest.find('=')
        if eq >= 0:
          setArg(result, groups, rest[0 ..< eq],
            NimValue(kind: nvkString, s: rest[eq + 1 .. ^1]))
        else:
          var j = 0
          while j < rest.len:
            let ch = $rest[j]
            if ch in strOpts:
              if j < rest.len - 1:
                setArg(result, groups, ch,
                  NimValue(kind: nvkString, s: rest[j + 1 .. ^1]))
              else:
                var val = ""
                if i + 1 < args.len and not isFlagToken(args[i + 1]):
                  val = args[i + 1]
                  inc i
                setArg(result, groups, ch, NimValue(kind: nvkString, s: val))
              break
            else:
              setArg(result, groups, ch, NimValue(kind: nvkBool, b: true))
              inc j
    else:
      result.pos.add(a)
    inc i

## Builds the std/terminal namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn green(text: string):
      ## terminal.green(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("32", text))

    module.registerFn red(text: string):
      ## terminal.red(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("31", text))

    module.registerFn yellow(text: string):
      ## terminal.yellow(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("33", text))

    module.registerFn blue(text: string):
      ## terminal.blue(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("34", text))

    module.registerFn magenta(text: string):
      ## terminal.magenta(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("35", text))

    module.registerFn cyan(text: string):
      ## terminal.cyan(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("36", text))

    module.registerFn gray(text: string):
      ## terminal.gray(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("90", text))

    module.registerFn bold(text: string):
      ## terminal.bold(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("1", text))

    module.registerFn dim(text: string):
      ## terminal.dim(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("2", text))

    module.registerFn underline(text: string):
      ## terminal.underline(text) -> styled string (plain when colors are off)
      toJS(ctx, paint("4", text))

    module.registerFn colorEnabled():
      ## terminal.colorEnabled() -> whether styling emits ANSI codes
      ## (false under NO_COLOR or TERM=dumb, like the CLI itself)
      toJS(ctx, colorsOn())

    module.registerFn stripAnsi(text: string):
      ## terminal.stripAnsi(text) -> text without CSI escape sequences
      toJS(ctx, stripAnsiCodes(text))

    module.registerFn write(text: string):
      ## terminal.write(text) -> undefined (stdout, no trailing newline)
      lockLog()
      try:
        stdout.write(text)
        flushFile(stdout)
      finally:
        unlockLog()
      JSValueMakeUndefined(ctx)

    module.registerFn isTTY():
      ## terminal.isTTY() -> whether stdout is a terminal
      toJS(ctx, isatty(stdout))

    module.registerFn columns():
      ## terminal.columns() -> terminal width (80 when unknown)
      let w = terminalWidth()
      toJS(ctx, if w > 0: w else: 80)

    module.registerFn rows():
      ## terminal.rows() -> terminal height (24 when unknown)
      let h = terminalHeight()
      toJS(ctx, if h > 0: h else: 24)

    module.registerFn readLine(prompt?: string):
      ## terminal.readLine([prompt]) -> line | null (null on EOF,
      ## blocks the loop like os.exec)
      if prompt.len > 0:
        lockLog()
        try:
          stdout.write(prompt)
          flushFile(stdout)
        finally:
          unlockLog()
      var line = ""
      try:
        line = stdin.readLine()
      except EOFError:
        return JSValueMakeNull(ctx)
      except IOError as e:
        throwError(ctx, "readLine: " & e.msg, exception)
        return nil
      toJS(ctx, line)

    module.registerFn readPassword(prompt?: string):
      ## terminal.readPassword([prompt]) -> password | null (no echo,
      ## null on EOF, blocks the loop like os.exec)
      var pw = ""
      try:
        pw = readPasswordFromStdin(prompt)
      except EOFError:
        return JSValueMakeNull(ctx)
      except IOError as e:
        throwError(ctx, "readPassword: " & e.msg, exception)
        return nil
      toJS(ctx, pw)

    module.registerFn parseArgs(argv?: NimValue, opts?: NimValue):
      ## terminal.parseArgs([argv][, opts]) -> {_: [...], ...}
      ## argv defaults to the script's own args (past `carne script.js`).
      ## opts takes {boolean?, string?, alias?, default?, positional?}.
      ## Values never coerce: strings stay strings (no minimist-style
      ## numeric guessing), flags are booleans, repeats last-win.
      var argList: seq[string] = @[]
      if argv.kind == nvkUndefined:
        let a = currentRt().argv
        if a.len > 2:
          argList = a[2 .. ^1]
      elif argv.kind == nvkArray:
        for item in argv.arr:
          if item.kind != nvkString:
            throwTypeMismatch(ctx, "parseArgs", "argv",
              jsTypeName(item.kind), "array", "", exception)
            return nil
          argList.add(item.s)
      else:
        throwTypeMismatch(ctx, "parseArgs", "argv",
          jsTypeName(argv.kind), "array", "", exception)
        return nil
      var optObj = NimValue(kind: nvkUndefined)
      if opts.kind != nvkUndefined:
        if opts.kind != nvkObject:
          throwTypeMismatch(ctx, "parseArgs", "opts",
            jsTypeName(opts.kind), "object", "", exception)
          return nil
        optObj = opts
      var boolOpts: seq[string] = @[]
      var strOpts: seq[string] = @[]
      var posNames: seq[string] = @[]
      var groups = initTable[string, seq[string]]()
      if not readStrSeq(ctx, optObj, "boolean", "parseArgs", exception,
          boolOpts):
        return nil
      if not readStrSeq(ctx, optObj, "string", "parseArgs", exception,
          strOpts):
        return nil
      if not readStrSeq(ctx, optObj, "positional", "parseArgs", exception,
          posNames):
        return nil
      if not readAliases(ctx, optObj, "parseArgs", exception, groups):
        return nil
      var parsed = parseArgv(argList, boolOpts, strOpts, groups)
      # Defaults lose to everything arrived so far.
      if optObj.kind == nvkObject and optObj.obj.hasKey("default"):
        let d = optObj.obj["default"]
        if d.kind == nvkUndefined:
          discard
        elif d.kind != nvkObject:
          throwError(ctx,
            "parseArgs: \"default\" must be an object", exception)
          return nil
        else:
          for k, v in d.obj.pairs:
            if v.kind notin {nvkString, nvkBool, nvkInt, nvkFloat}:
              throwError(ctx, "parseArgs: default \"" & k &
                "\" must be a string, boolean or number", exception)
              return nil
            setArgAbsent(parsed, groups, k, v)
      # Positional names lose to explicit flags, beat defaults.
      for idx, name in posNames:
        if idx < parsed.pos.len:
          setArgAbsent(parsed, groups, name,
            NimValue(kind: nvkString, s: parsed.pos[idx]))
      # Unused boolean declarations still read false (minimist parity:
      # a known flag that never appears is false, not absent).
      for name in boolOpts:
        setArgAbsent(parsed, groups, name,
          NimValue(kind: nvkBool, b: false))
      let obj = newObject(ctx)
      for k, v in parsed.vals.pairs:
        let j = toJS(ctx, v)
        if j == nil or not setPropChecked(ctx, obj, k, j, "parseArgs",
            exception):
          return nil
      var posVals: seq[JSValueRef] = @[]
      for p in parsed.pos:
        posVals.add(toJS(ctx, p))
      let arr = makeJSArray(ctx, posVals)
      if arr == nil or not setPropChecked(ctx, obj, "_", arr, "parseArgs",
          exception):
        return nil
      obj
