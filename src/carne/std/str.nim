# Carne std/str: string utilities with SIMD-accelerated batch ops.
#
#   const str = require("std/str");
#   str.indexOf(hay, needle)  -> int (UTF-16 units, -1 when absent)
#   str.toUpperCase(s)        -> string
#   str.lines(s)              -> array of strings
#   str.camelCase(s)          -> string
#
# Free-function style: the subject string is always the first argument.
# Index-returning ops (indexOf/lastIndexOf) use UTF-16 code-unit offsets
# like JS; slice and friends are rune-based (never split a codepoint).
# Byte-oriented scanning is encoding-transparent wherever only
# equality/delimiters matter; ASCII case mapping runs through SIMD with
# a `unicode` redo when non-ASCII bytes are seen. `toUpperCase` /
# `toLowerCase` therefore match JS except for locale-sensitive edges
# (Turkish dotted/dotless I), where `unicode` rules apply.
#
# Errors are per-op prefixed (`repeat: ...`, `levenshtein: ...`).

import std/unicode

import javascriptcore

import ../bridge
import ./strsimd

# ---------------------------------------------------------------------------
# Shared helpers (not exported)
# ---------------------------------------------------------------------------

proc runeCount(s: string): int =
  ## Number of runes in `s` (tolerant: each odd byte advances by one).
  var n = 0
  var i = 0
  while i < s.len:
    inc n
    i += max(runeLenAt(s, i), 1)
  n

proc advLen(s: string; i: int): int {.inline.} =
  ## Safe advance over the rune at `i` (clamped, always >= 1 for
  ## `i < s.len`).
  min(max(runeLenAt(s, i), 1), s.len - i)

proc isJsWs(o: int): bool {.inline.} =
  ## JS WhiteSpace + LineTerminator code points (the `trim` set).
  o == 0x20 or (o >= 0x09 and o <= 0x0D) or o == 0xA0 or
    o == 0x1680 or (o >= 0x2000 and o <= 0x200A) or
    o == 0x2028 or o == 0x2029 or o == 0x202F or o == 0x205F or
    o == 0x3000 or o == 0xFEFF

proc trimStartIdx(s: string): int =
  ## Byte index of the first keeper (ASCII fast path + unicode tail).
  var i = wsPrefixLen(s, 0)
  while i < s.len:
    if not isJsWs(int(runeAt(s, i))):
      break
    i += advLen(s, i)
  i

proc trimEndIdx(s: string): int =
  ## One-past index of the last keeper.
  var p = wsSuffixLen(s, s.len)
  while p > 0:
    var q = p - 1
    while q > 0 and (ord(s[q]) and 0xC0) == 0x80:
      dec q
    if not isJsWs(int(runeAt(s, q))):
      break
    p = q
  p

proc runeTable(s: string): tuple[bytes: seq[int], units: seq[int],
    total: int] =
  ## Per-rune byte offset + UTF-16 offset, plus the total unit count.
  ## Surrogate-range runes (WTF-8 from lone surrogates) count 1 unit,
  ## matching JS.
  var bytes: seq[int] = @[]
  var units: seq[int] = @[]
  var u = 0
  var i = 0
  while i < s.len:
    let L = advLen(s, i)
    bytes.add(i)
    units.add(u)
    u += (if int(runeAt(s, i)) > 0xFFFF: 2 else: 1)
    i += L
  (bytes, units, u)

proc utf16IndexOf(hay, needle: string; fromUnits: int): int =
  ## Scalar UTF-16-unit indexOf for non-ASCII input (JS semantics).
  let (hb, hu, htotal) = runeTable(hay)
  let (nb, _, ntotal) = runeTable(needle)
  var f = max(fromUnits, 0)
  if ntotal == 0:
    return min(f, htotal)
  if f > htotal:
    return -1
  let nn = nb.len
  var r = 0
  while r < hu.len and hu[r] < f:
    inc r
  while r + nn <= hu.len:
    var ok = true
    for k in 0 ..< nn:
      if runeAt(hay, hb[r + k]) != runeAt(needle, nb[k]):
        ok = false
        break
    if ok:
      return hu[r]
    inc r
  -1

proc utf16LastIndexOf(hay, needle: string; fromUnits: int): int =
  ## Scalar UTF-16-unit lastIndexOf for non-ASCII input. `fromUnits`
  ## < 0 selects the end of the string.
  let (hb, hu, htotal) = runeTable(hay)
  let (nb, _, ntotal) = runeTable(needle)
  let f = if fromUnits < 0: htotal else: min(fromUnits, htotal)
  if ntotal == 0:
    return f
  let nn = nb.len
  var r = hb.len - nn
  while r >= 0:
    if hu[r] > f:
      dec r
      continue
    var ok = true
    for k in 0 ..< nn:
      if runeAt(hay, hb[r + k]) != runeAt(needle, nb[k]):
        ok = false
        break
    if ok:
      return hu[r]
    dec r
  -1

proc unitsTotal(s: string): int =
  ## UTF-16 unit count (== byte length for ASCII).
  if isAscii(s):
    return s.len
  runeTable(s).total

proc strIndexOf(s, needle: string; f: int): int =
  ## Shared indexOf core (byte/SIMD path + UTF-16 fallback).
  if needle.len == 0:
    return min(f, unitsTotal(s))
  if isAscii(s) and isAscii(needle):
    if f >= s.len:
      return -1
    if needle.len == 1:
      return findNeedle(s, f, needle[0], needle[0])
    let n0 = needle[0]
    let nl = needle.len
    var pos = f
    while true:
      pos = findNeedle(s, pos, n0, n0)
      if pos < 0 or pos + nl > s.len:
        return -1
      if equalMem(unsafeAddr s[pos], unsafeAddr needle[0], nl):
        return pos
      inc pos
  else:
    return utf16IndexOf(s, needle, f)

proc strLastIndexOf(s, needle: string; f: int): int =
  ## Shared lastIndexOf core. `f` < 0 selects the end of the string.
  if needle.len == 0:
    let total = unitsTotal(s)
    return if f < 0: total else: min(f, total)
  if isAscii(s) and isAscii(needle):
    let limit =
      if f < 0: s.len - needle.len
      else: min(f, s.len - needle.len)
    if limit < 0:
      return -1
    if needle.len == 1:
      return findNeedleLast(s, limit + 1, needle[0], needle[0])
    let n0 = needle[0]
    let nl = needle.len
    var top = limit
    while top >= 0:
      let p = findNeedleLast(s, top + 1, n0, n0)
      if p < 0:
        return -1
      if p + nl <= s.len and
          equalMem(unsafeAddr s[p], unsafeAddr needle[0], nl):
        return p
      top = p - 1
    return -1
  else:
    utf16LastIndexOf(s, needle, f)

proc asciiWords(s: string): seq[string] =
  ## Splits on non-alphanumeric runs plus camel boundaries. Non-ASCII
  ## bytes ride along with the current word (never split mid-rune).
  var words: seq[string] = @[]
  var cur = ""
  var prevLower, prevUpper = false
  var i = 0
  template flush() =
    if cur.len > 0:
      words.add(cur)
      cur = ""
  while i < s.len:
    let c = s[i]
    if (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9'):
      let isU = c >= 'A' and c <= 'Z'
      let isL = c >= 'a' and c <= 'z'
      if cur.len > 0 and isU and (prevLower or
          (prevUpper and i + 1 < s.len and
            s[i + 1] >= 'a' and s[i + 1] <= 'z')):
        flush()
      cur.add(c)
      prevLower = isL
      prevUpper = isU
      inc i
    elif c >= '\x80':
      let e = min(i + advLen(s, i), s.len)
      cur.add(s[i ..< e])
      prevLower = false
      prevUpper = false
      i = e
    else:
      flush()
      prevLower = false
      prevUpper = false
      inc i
  flush()
  words

proc capitalizeWord(w: string): string =
  ## Upper-cases the first rune, lower-cases the rest.
  if w.len == 0:
    return w
  let L = advLen(w, 0)
  $toUpper(runeAt(w, 0)) & toLower(w[L .. ^1])

proc parseDec(s: string): int =
  ## Strict decimal parse, -1 on any invalid input (no exceptions).
  if s.len == 0:
    return -1
  var v = 0
  for c in s:
    if c < '0' or c > '9':
      return -1
    v = v * 10 + (ord(c) - ord('0'))
    if v > 0x10FFFF:
      return -1
  v

proc parseHex(s: string): int =
  ## Strict hex parse, -1 on any invalid input (no exceptions).
  if s.len == 0:
    return -1
  var v = 0
  for c in s:
    v = v shl 4
    if c >= '0' and c <= '9':
      v += ord(c) - ord('0')
    elif c >= 'a' and c <= 'f':
      v += ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F':
      v += ord(c) - ord('A') + 10
    else:
      return -1
    if v > 0x10FFFF:
      return -1
  v

proc validScalar(code: int): bool {.inline.} =
  code >= 0 and code <= 0x10FFFF and
    not (code >= 0xD800 and code <= 0xDFFF)

proc strArrayToJS(ctx: JSContextRef; parts: openArray[string];
    fname: string; exception: ptr JSValueRef): JSValueRef =
  ## Builds a JS string array; nil + throw on creation failure.
  var vals = newSeq[JSValueRef](parts.len)
  for i, p in parts:
    vals[i] = toJS(ctx, p)
  let arr = makeJSArray(ctx, vals)
  if arr == nil:
    throwError(ctx, fname & ": could not convert result to JS",
      exception)
    return nil
  arr

## Builds the std/str namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn indexOf(s: string, needle: string,
        frm: default(int, 0)):
      ## str.indexOf(s, needle[, from]) -> int (UTF-16 units, -1 absent)
      var f = int(frm)
      if f < 0:
        f = 0
      toJS(ctx, strIndexOf(s, needle, f))

    module.registerFn lastIndexOf(s: string, needle: string,
        frm: default(int, 0)):
      ## str.lastIndexOf(s, needle[, from]) -> int (absent -1)
      ## Omitted `from` searches from the end; an explicit value is
      ## clamped like JS (negatives search at 0 only).
      let f =
        if int(argumentCount) < 3: -1
        else: max(int(frm), 0)
      toJS(ctx, strLastIndexOf(s, needle, f))

    module.registerFn includes(s: string, needle: string,
        frm: default(int, 0)):
      ## str.includes(s, needle[, from]) -> bool
      var f = int(frm)
      if f < 0:
        f = 0
      toJS(ctx, strIndexOf(s, needle, f) >= 0)

    module.registerFn count(s: string, needle: string):
      ## str.count(s, needle) -> int (non-overlapping occurrences)
      if needle.len == 0:
        return toJS(ctx, (if isAscii(s): s.len
          else: runeCount(s)) + 1)
      if isAscii(s) and isAscii(needle):
        if needle.len == 1:
          return toJS(ctx, countByte(s, 0, needle[0]))
        let n0 = needle[0]
        let nl = needle.len
        var n = 0
        var pos = 0
        while true:
          pos = findNeedle(s, pos, n0, n0)
          if pos < 0 or pos + nl > s.len:
            break
          if equalMem(unsafeAddr s[pos], unsafeAddr needle[0], nl):
            inc n
            pos += nl
          else:
            inc pos
        return toJS(ctx, n)
      let hay = toRunes(s)
      let ndl = toRunes(needle)
      var n = 0
      var r = 0
      while r + ndl.len <= hay.len:
        var ok = true
        for k in 0 ..< ndl.len:
          if hay[r + k] != ndl[k]:
            ok = false
            break
        if ok:
          inc n
          r += ndl.len
        else:
          inc r
      toJS(ctx, n)

    module.registerFn startsWith(s: string, prefix: string):
      ## str.startsWith(s, prefix) -> bool
      if prefix.len == 0:
        return toJS(ctx, true)
      if s.len < prefix.len:
        return toJS(ctx, false)
      toJS(ctx, equalMem(unsafeAddr s[0], unsafeAddr prefix[0],
        prefix.len))

    module.registerFn endsWith(s: string, suffix: string):
      ## str.endsWith(s, suffix) -> bool
      if suffix.len == 0:
        return toJS(ctx, true)
      if s.len < suffix.len:
        return toJS(ctx, false)
      toJS(ctx, equalMem(unsafeAddr s[s.len - suffix.len],
        unsafeAddr suffix[0], suffix.len))

    module.registerFn equals(a: string, b: string):
      ## str.equals(a, b) -> bool (exact byte equality)
      toJS(ctx, a == b)

    module.registerFn trim(s: string):
      ## str.trim(s) -> string (JS whitespace set)
      let a = trimStartIdx(s)
      let b = trimEndIdx(s)
      toJS(ctx, if b <= a: "" else: s[a ..< b])

    module.registerFn trimStart(s: string):
      ## str.trimStart(s) -> string (leading JS whitespace off)
      let a = trimStartIdx(s)
      toJS(ctx, if a >= s.len: "" else: s[a .. ^1])

    module.registerFn trimEnd(s: string):
      ## str.trimEnd(s) -> string (trailing JS whitespace off)
      let b = trimEndIdx(s)
      toJS(ctx, if b <= 0: "" else: s[0 ..< b])

    module.registerFn toUpperCase(s: string):
      ## str.toUpperCase(s) -> string (SIMD ASCII, unicode redo past)
      var outp = newString(s.len)
      if asciiUpperTo(outp, s):
        toJS(ctx, toUpper(s))
      else:
        toJS(ctx, outp)

    module.registerFn toLowerCase(s: string):
      ## str.toLowerCase(s) -> string (SIMD ASCII, unicode redo past)
      var outp = newString(s.len)
      if asciiLowerTo(outp, s):
        toJS(ctx, toLower(s))
      else:
        toJS(ctx, outp)

    module.registerFn isAscii(s: string):
      ## str.isAscii(s) -> bool (every byte below 0x80)
      toJS(ctx, isAscii(s))

    module.registerFn isBlank(s: string):
      ## str.isBlank(s) -> bool (empty or all JS whitespace)
      toJS(ctx, trimStartIdx(s) >= s.len)

    module.registerFn stripAnsi(s: string):
      ## str.stripAnsi(s) -> string (drops CSI/OSC/ESC sequences)
      var outp = ""
      var pos = 0
      while true:
        let e = findNeedle(s, pos, '\x1B', '\x1B')
        if e < 0:
          outp.add(s[pos .. ^1])
          break
        outp.add(s[pos ..< e])
        if e + 1 >= s.len:
          break
        let c = s[e + 1]
        if c == '[':
          var j = e + 2
          while j < s.len and
              (ord(s[j]) < 0x40 or ord(s[j]) > 0x7E):
            inc j
          pos = min(j + 1, s.len)
        elif c == ']':
          var j = e + 2
          var done = s.len
          while j < s.len:
            if s[j] == '\x07':
              done = j + 1
              break
            if s[j] == '\x1B' and j + 1 < s.len and s[j + 1] == '\\':
              done = j + 2
              break
            inc j
          pos = done
        else:
          pos = e + 2
      toJS(ctx, outp)

    module.registerFn lines(s: string):
      ## str.lines(s) -> array (split on \n, one \r stripped per line)
      var parts: seq[string] = @[]
      var pos = 0
      while true:
        let e = findNeedle(s, pos, '\n', '\n')
        if e < 0:
          var last = s[pos .. ^1]
          if last.len > 0 and last[^1] == '\r':
            last.setLen(last.len - 1)
          parts.add(last)
          break
        var line = s[pos ..< e]
        if line.len > 0 and line[^1] == '\r':
          line.setLen(line.len - 1)
        parts.add(line)
        pos = e + 1
      strArrayToJS(ctx, parts, "lines", exception)

    module.registerFn split(s: string, sep: string):
      ## str.split(s, sep) -> array ("" splits into runes)
      var parts: seq[string] = @[]
      if sep.len == 0:
        for r in runes(s):
          parts.add($r)
        return strArrayToJS(ctx, parts, "split", exception)
      var pos = 0
      let n0 = sep[0]
      let nl = sep.len
      while true:
        let e = findNeedle(s, pos, n0, n0)
        if e < 0 or e + nl > s.len:
          parts.add(s[pos .. ^1])
          break
        if equalMem(unsafeAddr s[e], unsafeAddr sep[0], nl):
          parts.add(s[pos ..< e])
          pos = e + nl
        else:
          pos = e + 1
      strArrayToJS(ctx, parts, "split", exception)

    module.registerFn join(parts: NimValue, sep: default(string, ",")):
      ## str.join(parts, sep=",") -> string (parts: string array)
      try:
        let items = parts.asArray("join")
        var strs = newSeq[string](items.len)
        var total = 0
        for i, it in items:
          strs[i] = it.asString("join")
          total += strs[i].len
        total += max(items.len - 1, 0) * sep.len
        var outp = newStringOfCap(total)
        for i, st in strs:
          if i > 0:
            outp.add(sep)
          outp.add(st)
        toJS(ctx, outp)
      except CatchableError as e:
        throwError(ctx, "join: " & e.msg, exception)
        nil

    module.registerFn replace(s: string, search: string,
        replacement: string):
      ## str.replace(s, search, replacement) -> string (first hit)
      if search.len == 0:
        return toJS(ctx, replacement & s)
      if isAscii(s) and isAscii(search):
        let p = strIndexOf(s, search, 0)
        if p < 0:
          return toJS(ctx, s)
        return toJS(ctx, s[0 ..< p] & replacement &
          s[p + search.len .. ^1])
      # Non-ASCII: locate the rune at the UTF-16 hit, then splice the
      # exact source bytes (same runes -> same UTF-8).
      let p = utf16IndexOf(s, search, 0)
      if p < 0:
        return toJS(ctx, s)
      let (hb, hu, _) = runeTable(s)
      var r = 0
      while r < hu.len and hu[r] != p:
        inc r
      let bp = if r < hb.len: hb[r] else: s.len
      toJS(ctx, s[0 ..< bp] & replacement & s[bp + search.len .. ^1])

    module.registerFn replaceAll(s: string, search: string,
        replacement: string):
      ## str.replaceAll(s, search, replacement) -> string (every hit)
      if search.len == 0:
        var outp = replacement
        for r in runes(s):
          outp.add($r)
          outp.add(replacement)
        return toJS(ctx, outp)
      if isAscii(s) and isAscii(search):
        var outp = ""
        var pos = 0
        let n0 = search[0]
        let nl = search.len
        while true:
          let e = findNeedle(s, pos, n0, n0)
          if e < 0 or e + nl > s.len:
            outp.add(s[pos .. ^1])
            break
          if equalMem(unsafeAddr s[e], unsafeAddr search[0], nl):
            outp.add(s[pos ..< e])
            outp.add(replacement)
            pos = e + nl
          else:
            outp.add(s[pos .. e])
            pos = e + 1
        return toJS(ctx, outp)
      let hay = toRunes(s)
      let ndl = toRunes(search)
      let sb = runeTable(s).bytes
      var outp = ""
      var bytePos = 0
      var r = 0
      while r + ndl.len <= hay.len:
        var ok = true
        for k in 0 ..< ndl.len:
          if hay[r + k] != ndl[k]:
            ok = false
            break
        if ok:
          let bs = sb[r]
          var be = bs
          for k in 0 ..< ndl.len:
            be += advLen(s, be)
          outp.add(s[bytePos ..< bs])
          outp.add(replacement)
          bytePos = be
          r += ndl.len
        else:
          inc r
      outp.add(s[bytePos .. ^1])
      toJS(ctx, outp)

    module.registerFn slice(s: string, start: default(int, 0),
        stop: default(int, 0)):
      ## str.slice(s[, start][, end]) -> string (rune-based, negatives ok)
      let rs = toRunes(s)
      let n = rs.len
      var a = int(start)
      var b =
        if int(argumentCount) < 3: n
        else: int(stop)
      if a < 0:
        a = max(n + a, 0)
      else:
        a = min(a, n)
      if b < 0:
        b = max(n + b, 0)
      else:
        b = min(b, n)
      if b <= a:
        return toJS(ctx, "")
      var outp = ""
      for i in a ..< b:
        outp.add($rs[i])
      toJS(ctx, outp)

    module.registerFn padStart(s: string, width: int,
        pad: default(string, " ")):
      ## str.padStart(s, width[, pad]) -> string (rune width)
      let base = runeCount(s)
      let w = int(width)
      if base >= w or pad.len == 0:
        return toJS(ctx, s)
      let pr = toRunes(pad)
      var outp = ""
      var added = 0
      var i = 0
      while base + added < w:
        outp.add($pr[i mod pr.len])
        inc added
        inc i
      outp.add(s)
      toJS(ctx, outp)

    module.registerFn padEnd(s: string, width: int,
        pad: default(string, " ")):
      ## str.padEnd(s, width[, pad]) -> string (rune width)
      let base = runeCount(s)
      let w = int(width)
      if base >= w or pad.len == 0:
        return toJS(ctx, s)
      let pr = toRunes(pad)
      var outp = s
      var added = 0
      var i = 0
      while base + added < w:
        outp.add($pr[i mod pr.len])
        inc added
        inc i
      toJS(ctx, outp)

    module.registerFn padCenter(s: string, width: int,
        pad: default(string, " ")):
      ## str.padCenter(s, width[, pad]) -> string (extra goes right)
      let base = runeCount(s)
      let w = int(width)
      if base >= w or pad.len == 0:
        return toJS(ctx, s)
      let pr = toRunes(pad)
      let total = w - base
      let left = total div 2
      let right = total - left
      var outp = ""
      for i in 0 ..< left:
        outp.add($pr[i mod pr.len])
      outp.add(s)
      for i in 0 ..< right:
        outp.add($pr[(left + i) mod pr.len])
      toJS(ctx, outp)

    module.registerFn repeat(s: string, n: int):
      ## str.repeat(s, n) -> string (cap 16M result bytes)
      let k = int(n)
      if k < 0:
        throwError(ctx, "repeat: invalid count", exception)
        return nil
      if k == 0 or s.len == 0:
        return toJS(ctx, "")
      if k > 16_777_216 or s.len * k > 16_777_216:
        throwError(ctx, "repeat: result too large", exception)
        return nil
      var outp = newStringOfCap(s.len * k)
      for _ in 0 ..< k:
        outp.add(s)
      toJS(ctx, outp)

    module.registerFn reverse(s: string):
      ## str.reverse(s) -> string (rune-wise)
      let rs = toRunes(s)
      var outp = newStringOfCap(s.len)
      for i in countdown(rs.len - 1, 0):
        outp.add($rs[i])
      toJS(ctx, outp)

    module.registerFn truncate(s: string, maxLen: int,
        ellipsis: default(string, "\xE2\x80\xA6")):
      ## str.truncate(s, maxLen[, ellipsis]) -> string (rune-based)
      let m = int(maxLen)
      if m < 0:
        throwError(ctx, "truncate: maxLen must be >= 0", exception)
        return nil
      let rs = toRunes(s)
      if rs.len <= m:
        return toJS(ctx, s)
      var outp = ""
      for i in 0 ..< m:
        outp.add($rs[i])
      outp.add(ellipsis)
      toJS(ctx, outp)

    module.registerFn words(s: string):
      ## str.words(s) -> array (split on JS-whitespace runs)
      var parts: seq[string] = @[]
      var i = 0
      while i < s.len:
        if isJsWs(int(runeAt(s, i))):
          i += advLen(s, i)
          continue
        let a = i
        while i < s.len and not isJsWs(int(runeAt(s, i))):
          i += advLen(s, i)
        parts.add(s[a ..< i])
      strArrayToJS(ctx, parts, "words", exception)

    module.registerFn camelCase(s: string):
      ## str.camelCase(s) -> string ("hello-world" -> "helloWorld")
      let ws = asciiWords(s)
      if ws.len == 0:
        return toJS(ctx, "")
      var outp = toLower(ws[0])
      for i in 1 ..< ws.len:
        outp.add(capitalizeWord(toLower(ws[i])))
      toJS(ctx, outp)

    module.registerFn snakeCase(s: string):
      ## str.snakeCase(s) -> string ("helloWorld" -> "hello_world")
      let ws = asciiWords(s)
      var outp = ""
      for i, w in ws:
        if i > 0:
          outp.add('_')
        outp.add(toLower(w))
      toJS(ctx, outp)

    module.registerFn kebabCase(s: string):
      ## str.kebabCase(s) -> string ("helloWorld" -> "hello-world")
      let ws = asciiWords(s)
      var outp = ""
      for i, w in ws:
        if i > 0:
          outp.add('-')
        outp.add(toLower(w))
      toJS(ctx, outp)

    module.registerFn titleCase(s: string):
      ## str.titleCase(s) -> string ("hello world" -> "Hello World")
      let ws = asciiWords(s)
      var outp = ""
      for i, w in ws:
        if i > 0:
          outp.add(' ')
        outp.add(capitalizeWord(toLower(w)))
      toJS(ctx, outp)

    module.registerFn slugify(s: string):
      ## str.slugify(s) -> string (lowercase, "-" boundaries)
      var outp = ""
      var dash = false
      var started = false
      for r in runes(toLower(s)):
        let o = int(r)
        if isAlpha(r) or (o >= 48 and o <= 57):
          outp.add($r)
          dash = false
          started = true
        elif started and not dash:
          outp.add('-')
          dash = true
      if dash and outp.len > 0:
        outp.setLen(outp.len - 1)
      toJS(ctx, outp)

    module.registerFn escapeHtml(s: string):
      ## str.escapeHtml(s) -> string (&<>"' to entities)
      var outp = newStringOfCap(s.len)
      for c in s:
        case c
        of '&': outp.add("&amp;")
        of '<': outp.add("&lt;")
        of '>': outp.add("&gt;")
        of '"': outp.add("&quot;")
        of '\'': outp.add("&#39;")
        else: outp.add(c)
      toJS(ctx, outp)

    module.registerFn unescapeHtml(s: string):
      ## str.unescapeHtml(s) -> string (named + numeric entities)
      var outp = newStringOfCap(s.len)
      var i = 0
      while i < s.len:
        if s[i] != '&':
          outp.add(s[i])
          inc i
          continue
        let e = findNeedle(s, i + 1, ';', ';')
        if e < 0 or e - i > 10:
          outp.add('&')
          inc i
          continue
        let ent = s[i + 1 ..< e]
        var done = false
        if ent == "amp":
          outp.add('&')
          done = true
        elif ent == "lt":
          outp.add('<')
          done = true
        elif ent == "gt":
          outp.add('>')
          done = true
        elif ent == "quot":
          outp.add('"')
          done = true
        elif ent == "#39" or ent == "#x27" or ent == "#X27":
          outp.add('\'')
          done = true
        elif ent.len > 1 and ent[0] == '#':
          let code =
            if ent[1] == 'x' or ent[1] == 'X': parseHex(ent[2 .. ^1])
            else: parseDec(ent[1 .. ^1])
          if validScalar(code):
            outp.add($Rune(code))
            done = true
        if done:
          i = e + 1
        else:
          outp.add('&')
          inc i
      toJS(ctx, outp)

    module.registerFn levenshtein(a: string, b: string):
      ## str.levenshtein(a, b) -> int (rune edit distance, 4M cap)
      let ra = toRunes(a)
      let rb = toRunes(b)
      if (ra.len + 1) * (rb.len + 1) > 4_000_000:
        throwError(ctx, "levenshtein: inputs too large (cap 4M cells)",
          exception)
        return nil
      var prev = newSeq[int](rb.len + 1)
      var cur = newSeq[int](rb.len + 1)
      for j in 0 .. rb.len:
        prev[j] = j
      for i in 1 .. ra.len:
        cur[0] = i
        for j in 1 .. rb.len:
          let cost = if ra[i - 1] == rb[j - 1]: 0 else: 1
          cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1),
            prev[j - 1] + cost)
        swap(prev, cur)
      toJS(ctx, prev[rb.len])

    module.registerFn wordWrap(s: string, width: int):
      ## str.wordWrap(s, width) -> string (greedy, keeps paragraphs)
      let w = int(width)
      if w < 1:
        throwError(ctx, "wordWrap: width must be >= 1", exception)
        return nil
      var linesOut: seq[string] = @[]
      var pos = 0
      while true:
        let e = findNeedle(s, pos, '\n', '\n')
        var para = if e < 0: s[pos .. ^1] else: s[pos ..< e]
        if para.len > 0 and para[^1] == '\r':
          para.setLen(para.len - 1)
        var line = ""
        var lineRunes = 0
        var i = 0
        while i < para.len:
          if isJsWs(int(runeAt(para, i))):
            i += advLen(para, i)
            continue
          let a = i
          while i < para.len and not isJsWs(int(runeAt(para, i))):
            i += advLen(para, i)
          let word = para[a ..< i]
          let wr = runeCount(word)
          if lineRunes == 0:
            line = word
            lineRunes = wr
          elif lineRunes + 1 + wr <= w:
            line.add(' ')
            line.add(word)
            lineRunes += 1 + wr
          else:
            linesOut.add(line)
            line = word
            lineRunes = wr
        linesOut.add(line)
        if e < 0:
          break
        pos = e + 1
      var outp = ""
      for i, ln in linesOut:
        if i > 0:
          outp.add('\n')
        outp.add(ln)
      toJS(ctx, outp)

    module.registerFn indent(s: string, prefix: string):
      ## str.indent(s, prefix) -> string (prefixes every line)
      if s.len == 0:
        return toJS(ctx, "")
      var outp = prefix
      var i = 0
      while i < s.len:
        let e = findNeedle(s, i, '\n', '\n')
        if e < 0:
          outp.add(s[i .. ^1])
          break
        outp.add(s[i .. e])
        if e + 1 < s.len:
          outp.add(prefix)
        i = e + 1
      toJS(ctx, outp)

    module.registerFn dedent(s: string):
      ## str.dedent(s) -> string (drops common space/tab margin)
      var parts: seq[string] = @[]
      var pos = 0
      while true:
        let e = findNeedle(s, pos, '\n', '\n')
        if e < 0:
          parts.add(s[pos .. ^1])
          break
        parts.add(s[pos ..< e])
        pos = e + 1
      var margin = high(int)
      for line in parts:
        var j = 0
        while j < line.len and (line[j] == ' ' or line[j] == '\t'):
          inc j
        if j < line.len:
          margin = min(margin, j)
      if margin == high(int):
        margin = 0
      var outp = ""
      for i, line in parts:
        var j = 0
        while j < margin and j < line.len and
            (line[j] == ' ' or line[j] == '\t'):
          inc j
        if j < line.len:
          outp.add(line[j .. ^1])
        if i + 1 < parts.len:
          outp.add('\n')
      toJS(ctx, outp)

    module.registerFn collapseWhitespace(s: string):
      ## str.collapseWhitespace(s) -> string (runs to one space, trim)
      var outp = ""
      var i = 0
      var pending = false
      var started = false
      while i < s.len:
        if isJsWs(int(runeAt(s, i))):
          pending = started
          i += advLen(s, i)
          continue
        if pending:
          outp.add(' ')
          pending = false
        let a = i
        while i < s.len and not isJsWs(int(runeAt(s, i))):
          i += advLen(s, i)
        outp.add(s[a ..< i])
        started = true
      toJS(ctx, outp)

    module.registerFn chomp(s: string):
      ## str.chomp(s) -> string (drops one trailing newline)
      var e = s.len
      if e > 0 and s[e - 1] == '\n':
        dec e
        if e > 0 and s[e - 1] == '\r':
          dec e
      toJS(ctx, s[0 ..< e])
