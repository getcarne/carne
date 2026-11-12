# Carne std/sql: SQL parsing, validation and serialization via openparser.
#
#   const sql = require("std/sql");
#   sql.sqlite.parse("SELECT a FROM t")   -> AST object
#   sql.sqlite.stringify(ast)             -> string
#   sql.sqlite.format("select a from t")  -> string (normalized)
#   sql.sqlite.validate("SELECT $1")      -> {valid: false, error: "..."}
#   sql.postgres.validate("SELECT $1")    -> {valid: true}
#   sql.mysql.validate("SELECT `a` FROM t") -> {valid: true}
#
# One sub-namespace per dialect: sqlite, postgres (= pgsql), mysql.
# Each has parse(sql) -> AST, stringify(ast) -> SQL, format(sql) -> SQL
# and validate(sql) -> {valid, error?}.
# parse throws a JS Error on syntax errors; validate never throws,
# it reports {valid: false, error: "..."} instead.
#
# AST shape: {kind, value?, quote?, children?}. kind is the openparser
# SqlNodeKind without the "nk" prefix ("Select", "StmtList", ...).
# Literal nodes carry value (and quote for quoted idents/strings:
# "Single", "Double", "Backtick", "Bracket"); every other node
# carries children.
#
# The three namespaces are built as setup (the DSL attaches members
# to the top namespace only), with define-only `ctx.registerFn`
# callbacks sharing one helper per operation.

import std/strutils

import javascriptcore

import pkg/openparser/sql

import ../bridge

const literalKinds = {nkIdent, nkQuotedIdent, nkStringLit, nkBitStringLit,
  nkHexStringLit, nkIntegerLit, nkNumericLit, nkPlaceholder, nkRaw}

proc sqlToJS(ctx: JSContextRef; n: SqlNode; name: string;
    exception: ptr JSValueRef): JSValueRef =
  ## SqlNode -> live JS value, no JsonNode middle layer.
  let obj = newObject(ctx)
  if not setPropChecked(ctx, obj, "kind", toJS(ctx, ($n.kind)[2 .. ^1]),
      name, exception):
    return nil
  if n.kind in literalKinds:
    if not setPropChecked(ctx, obj, "value", toJS(ctx, n.strVal),
        name, exception):
      return nil
    if n.quote != qkNone:
      if not setPropChecked(ctx, obj, "quote",
          toJS(ctx, ($n.quote)[2 .. ^1]), name, exception):
        return nil
  else:
    var vals: seq[JSValueRef] = @[]
    for child in n.sons:
      let j = sqlToJS(ctx, child, name, exception)
      if j == nil:
        return nil
      vals.add(j)
    let kids = makeJSArray(ctx, vals)
    if kids == nil:
      throwError(ctx, name & ": could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "children", kids, name, exception):
      return nil
  result = obj

proc sqlErr(ctx: JSContextRef; docBlock, name, detail: string;
    exception: ptr JSValueRef) =
  ## Domain-error throw with the JSDoc block first (CLI info).
  var msg = ""
  if docBlock.len > 0:
    msg = docBlock & "\n"
  throwError(ctx, msg & name & ": " & detail, exception)

proc doParse(ctx: JSContextRef; text: string; driver: SqlDriver;
    name, docBlock: string; exception: ptr JSValueRef): JSValueRef =
  try:
    let j = sqlToJS(ctx, parseSql(text, driver), name, exception)
    if j == nil:
      sqlErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    j
  except CatchableError as e:
    # SqlParseError text starts with a newline + code snippet.
    sqlErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doValidate(ctx: JSContextRef; text: string; driver: SqlDriver;
    name, docBlock: string; exception: ptr JSValueRef): JSValueRef =
  try:
    discard parseSql(text, driver)
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "valid", toJS(ctx, true), name,
        exception):
      sqlErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "valid", toJS(ctx, false), name,
        exception):
      sqlErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "error", toJS(ctx, e.msg), name,
        exception):
      sqlErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj

proc sRawHas(ctx: JSContextRef; obj: JSValueRef; key: string): bool =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  ex == nil and prop != nil and
    JSValueGetType(ctx, prop) != kJSTypeUndefined

proc sRawGet(ctx: JSContextRef; obj: JSValueRef; key: string): JSValueRef =
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  let prop = JSObjectGetProperty(ctx, obj, k, addr ex)
  if ex != nil or prop == nil:
    raise newException(CatchableError,
      "has an unreadable property \"" & key & "\"")
  prop

proc sRequireObj(ctx: JSContextRef; v: JSValueRef): JSValueRef =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeObject or
      JSValueIsArray(ctx, v) or JSObjectIsFunction(ctx, v):
    raise newException(CatchableError, "AST nodes must be objects")
  v

proc sReadStr(ctx: JSContextRef; v: JSValueRef; what: string): string =
  if v == nil or JSValueGetType(ctx, v) != kJSTypeString:
    raise newException(CatchableError, what)
  var ex: JSValueRef = nil
  let s = JSValueToStringCopy(ctx, v, addr ex)
  if s == nil:
    raise newException(CatchableError, what)
  defer: JSStringRelease(s)
  $s

proc jsToSql(ctx: JSContextRef; v: JSValueRef; depth: int): SqlNode =
  if depth > maxDumpDepth:
    raise newException(CatchableError,
      "AST is too deeply nested or circular")
  let o = sRequireObj(ctx, v)
  if not sRawHas(ctx, o, "kind"):
    raise newException(CatchableError, "AST nodes need {kind, ...}")
  let kindStr = sReadStr(ctx, sRawGet(ctx, o, "kind"),
    "AST \"kind\" must be a string")
  var kind: SqlNodeKind
  try:
    kind = parseEnum[SqlNodeKind]("nk" & kindStr)
  except ValueError:
    raise newException(CatchableError,
      "unknown AST kind \"" & kindStr & "\"")
  if kind in literalKinds:
    let val = if sRawHas(ctx, o, "value"):
      sReadStr(ctx, sRawGet(ctx, o, "value"),
        "AST \"value\" must be a string")
    else: ""
    var q = qkNone
    if sRawHas(ctx, o, "quote"):
      let qs = sReadStr(ctx, sRawGet(ctx, o, "quote"),
        "AST \"quote\" must be a string")
      try:
        q = parseEnum[QuoteKind]("qk" & qs)
      except ValueError:
        raise newException(CatchableError,
          "unknown AST quote \"" & qs & "\"")
    result = newNode(kind, val, q)
  else:
    var sons: seq[SqlNode] = @[]
    if sRawHas(ctx, o, "children"):
      let cv = sRawGet(ctx, o, "children")
      if cv == nil or JSValueGetType(ctx, cv) != kJSTypeObject or
          not JSValueIsArray(ctx, cv):
        raise newException(CatchableError,
          "AST \"children\" must be an array")
      var ex: JSValueRef = nil
      let lenKey = newJSString("length")
      defer: JSStringRelease(lenKey)
      let lenV = JSObjectGetProperty(ctx, cv, lenKey, addr ex)
      if ex != nil or lenV == nil:
        raise newException(CatchableError,
          "AST \"children\" must be an array")
      var ex2: JSValueRef = nil
      let n = int(JSValueToNumber(ctx, lenV, addr ex2))
      if ex2 != nil or n < 0:
        raise newException(CatchableError,
          "AST \"children\" must be an array")
      for idx in 0 ..< n:
        var eEx: JSValueRef = nil
        let item = JSObjectGetPropertyAtIndex(ctx, cv, cuint(idx),
          addr eEx)
        if eEx != nil or item == nil:
          raise newException(CatchableError,
            "AST \"children\" must be an array")
        sons.add(jsToSql(ctx, item, depth + 1))
    result = newNode(kind, sons)

proc doStringify(ctx: JSContextRef; v: JSValueRef; driver: SqlDriver;
    name, docBlock: string; exception: ptr JSValueRef): JSValueRef =
  try:
    toJS(ctx, renderSql(jsToSql(ctx, v, 0), false, driver))
  except CatchableError as e:
    sqlErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doFormat(ctx: JSContextRef; text: string; upper: bool;
    driver: SqlDriver; name, docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  try:
    toJS(ctx, renderSql(parseSql(text, driver), upper, driver))
  except CatchableError as e:
    sqlErr(ctx, docBlock, name, e.msg, exception)
    nil

## Builds the std/sql namespace object.
init proc(module: Module) =
  let sqliteNs = newObject(module.ctx)
  let postgresNs = newObject(module.ctx)
  let mysqlNs = newObject(module.ctx)

  ctx.registerFn sqliteParse(sql: string):
    ## sqlite.parse(sql) -> AST object
    return doParse(ctx, sql, sqlite, "sqlite.parse", docBlock, exception)

  ctx.registerFn sqliteStringify(value: JSValueRef):
    ## sqlite.stringify(ast) -> string
    return doStringify(ctx, value, sqlite, "sqlite.stringify", docBlock,
      exception)

  ctx.registerFn sqliteFormat(sql: string, optsObj ?: JSObjectRef):
    ## sqlite.format(sql[, {upperCase}]) -> string (normalized)
    var upper = false
    if optsObj != nil:
      var err = ""
      let u = getField(ctx, optsObj, "upperCase", err)
      if err != "":
        sqlErr(ctx, docBlock, "sqlite.format",
          "options.upperCase " & err, exception)
        return nil
      if u.kind == nvkBool:
        upper = u.b
    return doFormat(ctx, sql, upper, sqlite, "sqlite.format", docBlock,
      exception)

  ctx.registerFn sqliteValidate(sql: string):
    ## sqlite.validate(sql) -> {valid, error?}
    return doValidate(ctx, sql, sqlite, "sqlite.validate", docBlock, exception)

  ctx.registerFn postgresParse(sql: string):
    ## postgres.parse(sql) -> AST object
    return doParse(ctx, sql, pgsql, "postgres.parse", docBlock, exception)

  ctx.registerFn postgresStringify(value: JSValueRef):
    ## postgres.stringify(ast) -> string
    return doStringify(ctx, value, pgsql, "postgres.stringify", docBlock,
      exception)

  ctx.registerFn postgresFormat(sql: string, optsObj ?: JSObjectRef):
    ## postgres.format(sql[, {upperCase}]) -> string (normalized)
    var upper = false
    if optsObj != nil:
      var err = ""
      let u = getField(ctx, optsObj, "upperCase", err)
      if err != "":
        sqlErr(ctx, docBlock, "postgres.format",
          "options.upperCase " & err, exception)
        return nil
      if u.kind == nvkBool:
        upper = u.b
    return doFormat(ctx, sql, upper, pgsql, "postgres.format", docBlock,
      exception)

  ctx.registerFn postgresValidate(sql: string):
    ## postgres.validate(sql) -> {valid, error?}
    return doValidate(ctx, sql, pgsql, "postgres.validate", docBlock, exception)

  ctx.registerFn mysqlParse(sql: string):
    ## mysql.parse(sql) -> AST object
    return doParse(ctx, sql, mysql, "mysql.parse", docBlock, exception)

  ctx.registerFn mysqlStringify(value: JSValueRef):
    ## mysql.stringify(ast) -> string
    return doStringify(ctx, value, mysql, "mysql.stringify", docBlock,
      exception)

  ctx.registerFn mysqlFormat(sql: string, optsObj ?: JSObjectRef):
    ## mysql.format(sql[, {upperCase}]) -> string (normalized)
    var upper = false
    if optsObj != nil:
      var err = ""
      let u = getField(ctx, optsObj, "upperCase", err)
      if err != "":
        sqlErr(ctx, docBlock, "mysql.format",
          "options.upperCase " & err, exception)
        return nil
      if u.kind == nvkBool:
        upper = u.b
    return doFormat(ctx, sql, upper, mysql, "mysql.format", docBlock,
      exception)

  ctx.registerFn mysqlValidate(sql: string):
    ## mysql.validate(sql) -> {valid, error?}
    return doValidate(ctx, sql, mysql, "mysql.validate", docBlock, exception)

  # Plain-object property sets cannot throw; no setupEx in scope here.
  setProp(module.ctx, sqliteNs, "parse",
    makeFunction(module.ctx, "parse", sqliteParse), nil)
  setProp(module.ctx, sqliteNs, "stringify",
    makeFunction(module.ctx, "stringify", sqliteStringify), nil)
  setProp(module.ctx, sqliteNs, "format",
    makeFunction(module.ctx, "format", sqliteFormat), nil)
  setProp(module.ctx, sqliteNs, "validate",
    makeFunction(module.ctx, "validate", sqliteValidate), nil)
  setProp(module.ctx, postgresNs, "parse",
    makeFunction(module.ctx, "parse", postgresParse), nil)
  setProp(module.ctx, postgresNs, "stringify",
    makeFunction(module.ctx, "stringify", postgresStringify), nil)
  setProp(module.ctx, postgresNs, "format",
    makeFunction(module.ctx, "format", postgresFormat), nil)
  setProp(module.ctx, postgresNs, "validate",
    makeFunction(module.ctx, "validate", postgresValidate), nil)
  setProp(module.ctx, mysqlNs, "parse",
    makeFunction(module.ctx, "parse", mysqlParse), nil)
  setProp(module.ctx, mysqlNs, "stringify",
    makeFunction(module.ctx, "stringify", mysqlStringify), nil)
  setProp(module.ctx, mysqlNs, "format",
    makeFunction(module.ctx, "format", mysqlFormat), nil)
  setProp(module.ctx, mysqlNs, "validate",
    makeFunction(module.ctx, "validate", mysqlValidate), nil)

  setProp(module.ctx, module.ns, "sqlite", sqliteNs, nil)
  setProp(module.ctx, module.ns, "postgres", postgresNs, nil)
  setProp(module.ctx, module.ns, "mysql", mysqlNs, nil)
