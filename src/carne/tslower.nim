# TypeScript to JavaScript lowering for carne.
#
# Parses `.ts` with sweetsyntax (compile-time syntax via `prepared/ts`,
# generic parser dispatched at runtime) and applies the recorded
# lowering spans to the source text. Erasures blank in place (newlines
# survive, so line numbers are preserved); only enums, namespaces and
# `export =` splice generated code, tracked in a line map for stack
# traces (`formatTsError`).
#
# Span ends are INCLUSIVE byte offsets (Nim `..<` stores `a ..< b` as
# `a`..`b-1`): slice source with `src[a .. b]`.

import std/[algorithm, strutils]

import pkg/sweetsyntax/engine/parser
import pkg/sweetsyntax/[config, sweetlexer, tokenizer]
import pkg/sweetsyntax/languages/ts as tsHandlersMod
import pkg/sweetsyntax/languages/prepared/ts as tsPrepared

import javascriptcore
import ./bridge

export bridge

type
  TsLowered* = object
    code*: string
    lines*: seq[int]
      ## Output line (0-based) -> original TS line (1-based).

  SpanTree = object
    span*: StripSpan
    kids*: seq[int]

proc lineStarts(src: string): seq[int] =
  result = @[0]
  for i, c in src:
    if c == '\n':
      result.add(i + 1)

proc lineOf(starts: seq[int], off: int): int =
  var lo = 0
  var hi = starts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if starts[mid] <= off:
      lo = mid
    else:
      hi = mid - 1
  lo + 1

proc lockstep(text: string, firstLine: int): seq[int] =
  ## Input lines for a chunk whose newlines are preserved 1:1. A
  ## trailing newline terminates the last mapped line without opening
  ## an entry for the next (still empty) line.
  result = @[]
  if text.len == 0:
    return
  result.add(firstLine)
  for i in 0 ..< text.len - 1:
    if text[i] == '\n':
      result.add(result[^1] + 1)

proc flat(text: string, line: int): seq[int] =
  ## Input lines for generated text: every output line maps to `line`.
  result = @[]
  if text.len == 0:
    return
  result.add(line)
  for i in 0 ..< text.len - 1:
    if text[i] == '\n':
      result.add(line)

type OutBuf = object
  text: string
  lines: seq[int]

proc add(b: var OutBuf, text: string, lines: seq[int]) =
  ## Append a chunk. The chunk's first entry continues the current
  ## output line unless the buffer is empty or ends with a newline.
  if text.len == 0:
    return
  doAssert text.count('\n') + (if text[^1] == '\n': 0 else: 1) ==
    lines.len
  let fresh = b.text.len == 0 or b.text[^1] == '\n'
  b.text.add(text)
  if fresh:
    b.lines.add(lines)
  else:
    b.lines.add(lines[1 .. ^1])

proc blanked(src: string, a, b: int): string =
  ## Source slice with every byte blanked except newlines.
  result = newStringOfCap(b - a + 1)
  for i in a .. b:
    let c = src[i]
    if c == '\n' or c == '\r':
      result.add(c)
    else:
      result.add(' ')

proc buildTree(spans: seq[StripSpan]): tuple[roots: seq[int], nodes: seq[SpanTree]] =
  ## Nest spans by containment (outermost first). Equal spans nest in
  ## push order; disjoint spans stay roots.
  var order = newSeq[int](spans.len)
  for i in 0 ..< spans.len:
    order[i] = i
  order.sort(proc(x, y: int): int =
    if spans[x].span.a != spans[y].span.a:
      cmp(spans[x].span.a, spans[y].span.a)
    elif spans[x].span.b != spans[y].span.b:
      cmp(spans[y].span.b, spans[x].span.b)
    else:
      cmp(x, y))
  var nodes = newSeq[SpanTree](spans.len)
  for i in 0 ..< spans.len:
    nodes[i] = SpanTree(span: spans[i])
  var roots: seq[int] = @[]
  var stack: seq[int] = @[]
  for idx in order:
    while stack.len > 0 and
        not (nodes[stack[^1]].span.span.a <= spans[idx].span.a and
             spans[idx].span.b <= nodes[stack[^1]].span.span.b):
      discard stack.pop()
    if stack.len > 0:
      nodes[stack[^1]].kids.add(idx)
    else:
      roots.add(idx)
    stack.add(idx)
  (roots, nodes)

proc findBodyBrace(src: string, a: int): int =
  ## Offset of the `{` opening a namespace body: skip the keyword, the
  ## dotted path or string name, and any whitespace/comments between.
  var pos = a
  while pos < src.len and src[pos] notin {' ', '\t', '\r', '\n'}:
    inc pos
  while pos < src.len:
    case src[pos]
    of ' ', '\t', '\r', '\n':
      inc pos
    of '/':
      if pos + 1 < src.len and src[pos + 1] == '/':
        while pos < src.len and src[pos] != '\n':
          inc pos
      elif pos + 1 < src.len and src[pos + 1] == '*':
        pos += 2
        while pos + 1 < src.len and not (src[pos] == '*' and src[pos + 1] == '/'):
          inc pos
        pos += 2
      else:
        inc pos
    of '"', '\'':
      let q = src[pos]
      inc pos
      while pos < src.len and src[pos] != q:
        if src[pos] == '\\':
          inc pos
        inc pos
      inc pos
    of '{':
      return pos
    else:
      inc pos
  -1

proc qualifyEnumInit(slice, enumName: string,
    priors: seq[string]): string =
  ## Qualify bare references to earlier enum members (`B = A * 2` ->
  ## `B = C.A * 2`). Strings, comments and property accesses are left
  ## alone; `${}` interpolations are scanned as code.
  if priors.len == 0:
    return slice
  result = newStringOfCap(slice.len + 16)
  var prevCode = ' '
  var word = ""
  template flushWord() =
    if word.len > 0:
      if word in priors and prevCode != '.':
        result.add(enumName)
        result.add('.')
      result.add(word)
      prevCode = word[^1]
      word = ""
  var k = 0
  while k < slice.len:
    let c = slice[k]
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'}:
      word.add(c)
      inc k
    else:
      flushWord()
      if c == '"' or c == '\'':
        let q = c
        result.add(c)
        inc k
        while k < slice.len and slice[k] != q:
          if slice[k] == '\\' and k + 1 < slice.len:
            result.add(slice[k])
            result.add(slice[k + 1])
            k += 2
          else:
            result.add(slice[k])
            inc k
        if k < slice.len:
          result.add(slice[k])
          inc k
        prevCode = q
      elif c == '`':
        result.add(c)
        inc k
        while k < slice.len:
          if slice[k] == '\\' and k + 1 < slice.len:
            result.add(slice[k])
            result.add(slice[k + 1])
            k += 2
          elif slice[k] == '$' and k + 1 < slice.len and
              slice[k + 1] == '{':
            result.add("${")
            k += 2
            let innerStart = k
            var braceDepth = 1
            while k < slice.len and braceDepth > 0:
              if slice[k] == '{':
                inc braceDepth
              elif slice[k] == '}':
                dec braceDepth
              inc k
            result.add(qualifyEnumInit(slice[innerStart ..< k - 1],
              enumName, priors))
            result.add('}')
            prevCode = '}'
          elif slice[k] == '`':
            result.add(slice[k])
            inc k
            break
          else:
            result.add(slice[k])
            inc k
        prevCode = '`'
      elif c == '/' and k + 1 < slice.len and slice[k + 1] == '/':
        while k < slice.len and slice[k] != '\n':
          result.add(slice[k])
          inc k
      elif c == '/' and k + 1 < slice.len and slice[k + 1] == '*':
        result.add("/*")
        k += 2
        while k + 1 < slice.len and
            not (slice[k] == '*' and slice[k + 1] == '/'):
          result.add(slice[k])
          inc k
        if k + 1 < slice.len:
          result.add("*/")
          k += 2
      else:
        result.add(c)
        if c notin {' ', '\t', '\r', '\n'}:
          prevCode = c
        inc k
  flushWord()

proc renderNode(src: string, idx: int, nodes: seq[SpanTree],
    starts: seq[int], nsPath, path: string,
    assigns: var seq[tuple[text: string, line: int]]): OutBuf

proc renderSlice(src: string, lo, hi: int, kids: seq[int],
    nodes: seq[SpanTree], starts: seq[int], nsPath, path: string,
    assigns: var seq[tuple[text: string, line: int]]): OutBuf =
  ## Render source [lo..hi] with child spans applied. Export keywords
  ## and lists blank/rewrite only when `nsPath` is non-empty (inside a
  ## namespace lowering); otherwise they pass through for the ESM gate.
  var b = OutBuf()
  var pos = lo
  for k in kids:
    let s = nodes[k].span
    if s.span.a > pos:
      let chunk = src[pos ..< s.span.a]
      b.add(chunk, lockstep(chunk, lineOf(starts, pos)))
    let nb = renderNode(src, k, nodes, starts, nsPath, path, assigns)
    b.add(nb.text, nb.lines)
    pos = s.span.b + 1
  if pos <= hi:
    let chunk = src[pos .. hi]
    b.add(chunk, lockstep(chunk, lineOf(starts, pos)))
  b

proc renderNode(src: string, idx: int, nodes: seq[SpanTree],
    starts: seq[int], nsPath, path: string,
    assigns: var seq[tuple[text: string, line: int]]): OutBuf =
  let s = nodes[idx].span
  let kwLine = lineOf(starts, s.span.a)
  var b = OutBuf()
  case s.kind
  of skErase:
    # Nested spans merge: the whole range blanks at once.
    let t = blanked(src, s.span.a, s.span.b)
    b.add(t, lockstep(t, kwLine))
  of skReplace:
    b.add(s.text, flat(s.text, kwLine))
  of skEnum:
    var cleanInits = newSeq[string](s.members.len)
    for i, m in s.members:
      if m.initKind in {ikStr, ikExpr}:
        var slice = src[m.initSpan.a .. m.initSpan.b]
        for k in nodes[idx].kids:
          let c = nodes[k].span
          if c.kind == skErase and c.span.a >= m.initSpan.a and
              c.span.b <= m.initSpan.b:
            for j in c.span.a - m.initSpan.a .. c.span.b - m.initSpan.a:
              if slice[j] != '\n' and slice[j] != '\r':
                slice[j] = ' '
          elif c.kind == skError:
            raise newException(CarneError, path & ":" &
              $lineOf(starts, c.span.a) & ": " & c.text)
        cleanInits[i] = slice
    var lastVal: int64 = 0
    var haveLast = false
    var started = false
    var priors: seq[string] = @[]
    b.add("var " & s.text & ";(function(" & s.text & "){\n",
      flat("var " & s.text & ";(function(" & s.text & "){\n", kwLine))
    for i, m in s.members:
      var initText: string
      var numeric = true
      case m.initKind
      of ikAuto:
        if not started:
          lastVal = 0
        elif not haveLast:
          raise newException(CarneError, path & ":" & $m.line &
            ": Enum member '" & m.name & "' must have an initializer " &
            "(auto-increment cannot follow a string or computed member)")
        else:
          lastVal += 1
        haveLast = true
        initText = $lastVal
      of ikInt:
        lastVal = m.intVal
        haveLast = true
        initText = $m.intVal
      of ikStr, ikExpr:
        haveLast = false
        if m.initKind == ikStr:
          numeric = false
        initText = cleanInits[i]
        if m.initKind == ikExpr:
          initText = qualifyEnumInit(initText, s.text, priors)
      started = true
      if not m.strName:
        priors.add(m.name)
      let key = if m.strName: src[m.nameSpan.a .. m.nameSpan.b]
                else: "\"" & m.name & "\""
      if numeric:
        b.add(s.text & "[" & s.text & "[" & key & "]=" & initText &
          "]=" & key & ";\n", @[m.line])
      else:
        b.add(s.text & "[" & key & "]=" & initText & ";\n", @[m.line])
    b.add("})(" & s.text & "||(" & s.text & "={}));\n",
      flat("})(" & s.text & "||(" & s.text & "={}));\n", kwLine))
  of skExportKw, skExportList:
    if nsPath.len == 0:
      let t = src[s.span.a .. s.span.b]
      b.add(t, lockstep(t, kwLine))
    elif s.kind == skExportKw:
      if s.defaultExport:
        raise newException(CarneError, path & ":" & $kwLine &
          ": Default exports are not allowed in namespaces")
      for n in s.names:
        assigns.add((nsPath & "." & n & "=" & n & ";\n", kwLine))
      let t = blanked(src, s.span.a, s.span.b)
      b.add(t, lockstep(t, kwLine))
    else:
      if s.text.len > 0:
        raise newException(CarneError, path & ":" & $kwLine &
          ": Re-exports are not supported in namespaces")
      var i = 0
      while i + 1 < s.names.len:
        assigns.add((nsPath & "." & s.names[i + 1] & "=" & s.names[i] &
          ";\n", kwLine))
        i += 2
      let t = blanked(src, s.span.a, s.span.b)
      b.add(t, lockstep(t, kwLine))
  of skExportEq:
    if nsPath.len > 0:
      raise newException(CarneError, path & ":" & $kwLine &
        ": `export =` is not allowed in namespaces")
    let inner = renderSlice(src, s.span.a, s.span.b,
      nodes[idx].kids, nodes, starts, nsPath, path, assigns)
    # The slice starts with `export`: find the `=` at depth 0.
    var p = 6
    while p < inner.text.len and inner.text[p] in {' ', '\t', '\r', '\n'}:
      inc p
    if p >= inner.text.len or inner.text[p] != '=':
      raise newException(CarneError, path & ":" & $kwLine &
        ": malformed `export =` (internal error)")
    let tail = if p + 1 <= inner.text.high: inner.text[p + 1 .. ^1] else: ""
    var restFirst = kwLine
    for i in 0 .. p:
      if inner.text[i] == '\n':
        inc restFirst
    b.add("module.exports =", flat("module.exports =", kwLine))
    b.add(tail, lockstep(tail, restFirst))
  of skNamespace:
    if s.path.len == 0:
      raise newException(CarneError, path & ":" & $kwLine &
        ": Ambient module declarations cannot be lowered (use `declare module` for types)")
    let brace = findBodyBrace(src, s.span.a)
    if brace <= 0:
      raise newException(CarneError, path & ":" & $kwLine &
        ": malformed namespace (internal error)")
    var innerAssigns: seq[tuple[text: string, line: int]] = @[]
    let inner = renderSlice(src, brace + 1, s.span.b - 1,
      nodes[idx].kids, nodes, starts, s.path[^1], path, innerAssigns)
    var bodyOut = OutBuf()
    bodyOut.add(inner.text, inner.lines)
    if bodyOut.text.len == 0 or bodyOut.text[^1] != '\n':
      bodyOut.add("\n", @[lineOf(starts, s.span.b)])
    for a in innerAssigns:
      bodyOut.add(a.text, flat(a.text, a.line))
    # Wrap nested paths inside out: `namespace A.B` -> IIFE(A) > IIFE(B).
    for depth in countdown(s.path.len - 1, 0):
      let nm = s.path[depth]
      let arg = if depth == 0: nm & "=" & nm & "||({})"
                else: nm & "=" & s.path[0 ..< depth].join(".") & "." &
                  nm & "||(" & s.path[0 ..< depth].join(".") & "." & nm &
                  "={})"
      let pre = "var " & nm & ";(function(" & nm & "){\n"
      let post = "})(" & arg & ");\n"
      var wrapped = OutBuf()
      wrapped.add(pre, flat(pre, kwLine))
      wrapped.add(bodyOut.text, bodyOut.lines)
      wrapped.add(post, flat(post, kwLine))
      bodyOut = wrapped
    b = bodyOut
  of skError:
    raise newException(CarneError,
      path & ":" & $kwLine & ": " & s.text)
  b


proc looksEsm*(code: string): bool =
  ## Line-anchored import/export keyword heuristic (`//` comments
  ## skipped). Block comments and strings can fool it; v1 accepts that.
  for line in code.splitLines():
    let t = line.strip()
    if t.startsWith("//"):
      continue
    for kw in ["import", "export"]:
      if t.startsWith(kw):
        if t.len == kw.len:
          return true
        if t[kw.len] in {' ', '\t', '{', '*', '"', '\''}:
          return true
  false

proc transpileTS*(code, path: string): TsLowered =
  ## Lower TypeScript `code` to JavaScript. Raises CarneError with a
  ## `path:line: message` diagnostic on parse or lowering failures.
  var p: GenericParser
  p.applyPrecompiled(tsPrepared.tsInitData)
  tsHandlersMod.tsHandlers(p)
  p.features = p.features + {featAsync, featArrowFn, featGenerators,
    featLabeledStmt, featTemplateLit}
  p.lexer = initLexer(tsPrepared.tsInitData, code, enableAttrs = false)
  p.curr = p.getToken()
  p.next = p.getToken()
  try:
    while p.curr.kind != tkEOF:
      discard parseStatement(p)
  except OpenAstParsingError as e:
    raise newException(CarneError, path & ": " & e.msg.strip())
  let starts = lineStarts(code)
  let (roots, nodes) = buildTree(p.stripSpans)
  var assigns: seq[tuple[text: string, line: int]] = @[]
  let outBuf = renderSlice(code, 0, code.len - 1, roots, nodes,
    starts, "", path, assigns)
  doAssert assigns.len == 0
  TsLowered(code: outBuf.text, lines: outBuf.lines)

proc jsPropStr(ctx: JSContextRef, obj: JSObjectRef,
    name: string): tuple[ok: bool, val: string] =
  var ex: JSValueRef = nil
  let key = newJSString(name)
  defer: JSStringRelease(key)
  let v = JSObjectGetProperty(ctx, obj, key, addr ex)
  if ex != nil or v == nil or JSValueIsUndefined(ctx, v):
    return (false, "")
  (true, valueToString(ctx, v))

proc jsPropInt(ctx: JSContextRef, obj: JSObjectRef,
    name: string): tuple[ok: bool, val: int] =
  var ex: JSValueRef = nil
  let key = newJSString(name)
  defer: JSStringRelease(key)
  let v = JSObjectGetProperty(ctx, obj, key, addr ex)
  if ex != nil or v == nil or JSValueIsUndefined(ctx, v):
    return (false, 0)
  let n = JSValueToNumber(ctx, v, addr ex)
  if ex != nil or n != n:
    return (false, 0)
  (true, int(n))

proc formatTsError*(ctx: JSContextRef, ex: JSValueRef, path: string,
    lines: seq[int], base = 0): string

proc jsErrorMessage*(ctx: JSContextRef, ex: JSValueRef): string =
  ## Best-effort `message` of a JS error value, "" when unreadable.
  if not JSValueIsObject(ctx, ex):
    return ""
  let (ok, val) = jsPropStr(ctx, cast[JSObjectRef](ex), "message")
  if ok:
    val
  else:
    ""

proc formatRtError*(ctx: JSContextRef, ex: JSValueRef,
    rt: Runtime): string =
  ## Best-effort TS-aware error string for async paths (timers,
  ## top-level rejections): remaps only when the run has a single TS
  ## map (unambiguous); otherwise today's plain stringification.
  if rt.tsMaps.len == 1 and rt.tsMaps.hasKey(rt.sourceURL):
    let m = rt.tsMaps[rt.sourceURL]
    return formatTsError(ctx, ex, rt.sourceURL, m.lines, m.base)
  valueToString(ctx, ex)

proc formatTsError*(ctx: JSContextRef, ex: JSValueRef, path: string,
    lines: seq[int], base = 0): string =
  ## Format a JS exception from transpiled TypeScript: `path:line:col:
  ## message` plus the function chain. `lines` maps transpiled lines to
  ## original TS lines; `base` skips wrapper lines (1 for require()).
  var msg = valueToString(ctx, ex)
  var line = 0
  var col = 0
  var chain: seq[string] = @[]
  if not JSValueIsObject(ctx, ex):
    return path & ": " & msg
  let obj = cast[JSObjectRef](ex)
  let (mok, mval) = jsPropStr(ctx, obj, "message")
  if mok and mval.len > 0 and not msg.contains(mval):
    msg = mval
  let (lok, lval) = jsPropInt(ctx, obj, "line")
  if lok:
    line = lval
  let (cok, cval) = jsPropInt(ctx, obj, "column")
  if cok:
    col = cval
  let (sok, sval) = jsPropStr(ctx, obj, "stack")
  if sok:
    for frame in sval.splitLines():
      let at = frame.find('@')
      let fn = if at > 0: frame[0 ..< at] else: frame
      if fn.len > 0:
        chain.add(fn)
  var tsLine = line - base
  let idx = line - 1 - base
  if idx >= 0 and idx < lines.len:
    tsLine = lines[idx]
  result = path & ":" & $tsLine & ":" & $col & ": " & msg
  for fn in chain:
    result.add("\n    at " & fn)
