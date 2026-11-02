# Carne std/db driver: async + sync database executor (sqlite, postgres).
#
#   const driver = require("std/db/driver");
#   const sqlite = await driver.connect("sqlite::memory:");
#   const pg = await driver.connect({dialect: "postgres", host: "127.0.0.1",
#     user: "app", password: "secret", database: "app"});
#   const s = driver.connectSync("sqlite:/tmp/app.db");  // blocks the loop
#   await sqlite.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
#   await sqlite.query("SELECT * FROM users WHERE age > ?", [18]);
#     -> {rows: [{...}], rowCount: n, changes: m, lastInsertRowId?}
#   sqlite.querySync("SELECT 1"); pg.execSync("DELETE FROM t"); sqlite.close();
#
# require("std/db") (the JS ORM: fluent builder, models, migrations) is
# store-loaded db.js built on this driver; power users can require the
# driver directly. Every statement is validated with std/sql's dialect
# grammars before it executes. Placeholders only (? sqlite, $1..$n
# postgres); values bind separately and are never interpolated.
#
# Threading: everything runs on the JS thread. Async fns execute on the
# calling tick and settle on the next loop turn (zero-delay timer), so
# `await` composes with fetch/ws/timers; the loop is blocked during the
# call itself (fast local IO for sqlite, network RTTs for postgres).
# Sync fns block and return directly (ws.connectSync precedent).
# Needs a libpq client library for postgres (ships with postgres;
# Linux: libpq5); sqlite links the system sqlite3.

import std/[math, strutils, tables]

import javascriptcore

import pkg/db_connector/sqlite3
import pkg/db_connector/postgres
import pkg/openparser/sql

import powpow/loop

import ../bridge
import ../modules

type
  DbDialect = enum
    ddSqlite, ddPostgres

  DbEntry = object
    ctx: JSContextRef
    rt: Runtime
    dialect: DbDialect
    dialectName: string
    sqliteDb: PSqlite3
    pgConn: PPGconn
    handle: JSObjectRef
    closed: bool

  DbParamKind = enum
    dpkNull, dpkInt, dpkFloat, dpkText, dpkBool

  DbParam = object
    case kind: DbParamKind
    of dpkNull: discard
    of dpkInt: i: int64
    of dpkFloat: f: float
    of dpkText: s: string
    of dpkBool: b: bool

  DbCellKind = enum
    dckNull, dckInt, dckFloat, dckText, dckBlob, dckBool

  DbCell = object
    case kind: DbCellKind
    of dckNull: discard
    of dckInt: i: int64
    of dckFloat: f: float
    of dckText: s: string
    of dckBlob: b: string
    of dckBool: bl: bool

  DbResult = object
    cols: seq[string]
    rows: seq[seq[DbCell]]
    changes: int64
    lastId: int64
    hasLastId: bool

var dbConns {.threadvar.}: Table[pointer, DbEntry]
  ## Live connections by handle pointer. Handles are JSValueProtect'd
  ## while open, so keys never dangle.

proc decDbPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

proc toParams(v: NimValue; fname: string): seq[DbParam] =
  ## Snapshot array -> bind params. Raises on non-arrays or exotic
  ## items (objects, functions, undefined): pass null explicitly.
  if v.kind != nvkArray:
    raise newException(CatchableError,
      fname & ": params must be an array, got " & jsTypeName(v.kind))
  for item in v.arr:
    case item.kind
    of nvkNull:
      result.add(DbParam(kind: dpkNull))
    of nvkInt:
      result.add(DbParam(kind: dpkInt, i: item.i))
    of nvkFloat:
      result.add(DbParam(kind: dpkFloat, f: item.f))
    of nvkString:
      result.add(DbParam(kind: dpkText, s: item.s))
    of nvkBool:
      result.add(DbParam(kind: dpkBool, b: item.b))
    else:
      raise newException(CatchableError,
        fname & ": params must be strings, numbers, booleans or null" &
        " (got " & jsTypeName(item.kind) & ")")

proc escConnVal(v: string): string =
  ## libpq keyword/value escaping for built conninfo strings.
  if v.len == 0:
    return "''"
  var needsQuote = false
  for c in v:
    if c in {' ', '\'', '\\', '='}:
      needsQuote = true
      break
  if not needsQuote:
    return v
  result = "'"
  for c in v:
    if c in {'\'', '\\'}:
      result.add('\\')
    result.add(c)
  result.add('\'')

proc parseSpec(v: NimValue): tuple[dialect: DbDialect, path,
    conninfo: string] =
  ## Connection spec -> dialect + sqlite path or pg conninfo. Raises
  ## with usage examples on anything else.
  if v.kind == nvkString:
    let s = v.s
    if s.startsWith("sqlite:"):
      let p = s["sqlite:".len .. ^1]
      if p.len == 0:
        raise newException(CatchableError,
          "connect: sqlite path is empty (try \"sqlite::memory:\")")
      return (ddSqlite, p, "")
    if s.startsWith("postgres://") or s.startsWith("postgresql://"):
      return (ddPostgres, "", s)
    raise newException(CatchableError,
      "connect: expected \"sqlite:<path>\" or \"postgres://...\", got \"" &
      s & "\"")
  if v.kind != nvkObject:
    raise newException(CatchableError,
      "connect: expected a connection string or object, got " &
      jsTypeName(v.kind))
  let d = v.getOpt("dialect", NimValue(kind: nvkUndefined))
  if d.kind != nvkString or (d.s != "sqlite" and d.s != "postgres"):
    raise newException(CatchableError,
      "connect: object spec needs {dialect: \"sqlite\" | \"postgres\"}")
  if d.s == "sqlite":
    let p = v.getOpt("path", NimValue(kind: nvkUndefined))
    if p.kind != nvkString or p.s.len == 0:
      raise newException(CatchableError,
        "connect: sqlite object spec needs {dialect: \"sqlite\", path}")
    return (ddSqlite, p.s, "")
  let host = v.getOpt("host", NimValue(kind: nvkString, s: "127.0.0.1"))
  let user = v.getOpt("user", NimValue(kind: nvkString, s: ""))
  let password = v.getOpt("password", NimValue(kind: nvkString, s: ""))
  let database = v.getOpt("database", NimValue(kind: nvkUndefined))
  if host.kind != nvkString or user.kind != nvkString or
      password.kind != nvkString:
    raise newException(CatchableError,
      "connect: postgres host/user/password must be strings")
  if database.kind != nvkString or database.s.len == 0:
    raise newException(CatchableError,
      "connect: postgres object spec needs {database}")
  let port = v.getOpt("port", NimValue(kind: nvkInt, i: 5432))
  let timeout = v.getOpt("connectTimeout",
    NimValue(kind: nvkInt, i: 10))
  var portNum = 5432
  var timeoutNum = 10
  try:
    portNum = int(port.asInt("connect"))
    timeoutNum = int(timeout.asInt("connect"))
  except CatchableError:
    raise newException(CatchableError,
      "connect: postgres port/connectTimeout must be integers")
  if portNum < 1 or portNum > 65535:
    raise newException(CatchableError,
      "connect: postgres port must be 1..65535")
  if timeoutNum < 1:
    raise newException(CatchableError,
      "connect: postgres connectTimeout must be >= 1 (seconds)")
  let info = "host=" & escConnVal(host.s) & " port=" & $portNum &
    " dbname=" & escConnVal(database.s) &
    " connect_timeout=" & $timeoutNum &
    (if user.s.len > 0: " user=" & escConnVal(user.s) else: "") &
    (if password.s.len > 0:
      " password=" & escConnVal(password.s) else: "")
  (ddPostgres, "", info)

proc openEntry(spec: NimValue; fname: string): DbEntry =
  ## Opens the native connection. Raises on bad specs or failures.
  let (dialect, path, conninfo) = parseSpec(spec)
  case dialect
  of ddSqlite:
    var db: PSqlite3 = nil
    let rc = sqlite3.open(path.cstring, db)
    if rc != SQLITE_OK or db == nil:
      raise newException(CatchableError,
        fname & ": could not open sqlite database \"" & path & "\"")
    DbEntry(dialect: ddSqlite, dialectName: "sqlite", sqliteDb: db)
  of ddPostgres:
    let conn = pqconnectdb(conninfo.cstring)
    if conn == nil:
      raise newException(CatchableError,
        fname & ": postgres connect failed (out of memory?)")
    if pqstatus(conn) != CONNECTION_OK:
      var msg = ""
      try:
        msg = ($pqerrorMessage(conn)).strip()
      except CatchableError:
        discard
      pqfinish(conn)
      if msg.len == 0:
        msg = "connection refused"
      raise newException(CatchableError,
        fname & ": postgres connect failed: " & msg)
    DbEntry(dialect: ddPostgres, dialectName: "postgres", pgConn: conn)

proc isTxControl(text: string): bool =
  ## Transaction verbs the std/sql grammars don't cover (BEGIN, COMMIT,
  ## ROLLBACK, SAVEPOINT ...): fixed shapes emitted by
  ## Database.transaction only, with identifier-only names. Anything
  ## else still goes through the grammar below.
  let u = text.strip().toUpperAscii()
  if u == "BEGIN" or u == "COMMIT" or u == "ROLLBACK":
    return true
  for verb in ["SAVEPOINT ", "RELEASE SAVEPOINT ",
      "ROLLBACK TO SAVEPOINT "]:
    if u.startsWith(verb):
      let name = text.strip()[verb.len .. ^1].strip()
      if name.len == 0 or name[0] in {'0' .. '9'}:
        return false
      for c in name:
        if c notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
          return false
      return true
  false

proc validateSql(text: string; dialect: DbDialect; fname: string) =
  ## std/sql dialect grammar over the raw statement (placeholders are
  ## grammar-native: ? for sqlite, $N for postgres). Raises with the
  ## dialect error on invalid SQL.
  if isTxControl(text):
    return
  let driver = if dialect == ddSqlite: sqlite else: pgsql
  try:
    discard parseSql(text, driver)
  except CatchableError as e:
    raise newException(CatchableError, fname & ": invalid SQL (" &
      (if dialect == ddSqlite: "sqlite" else: "postgres") & "): " & e.msg)

proc sqliteErr(db: PSqlite3): string =
  try:
    ($sqlite3.errmsg(db)).strip()
  except CatchableError:
    "unknown error"

proc runSqlite(db: PSqlite3; text: string; params: seq[DbParam];
    fname: string): DbResult =
  var stmt: PStmt = nil
  if prepare_v2(db, text.cstring, text.len.cint, stmt, nil) != SQLITE_OK:
    raise newException(CatchableError,
      fname & ": " & sqliteErr(db))
  try:
    if int(bind_parameter_count(stmt)) != params.len:
      raise newException(CatchableError,
        fname & ": expected " & $int(bind_parameter_count(stmt)) &
        " parameter(s), got " & $params.len)
    for i, p in params:
      let idx = int32(i + 1)
      let brc =
        case p.kind
        of dpkNull: bind_null(stmt, idx)
        of dpkInt: bind_int64(stmt, idx, p.i)
        of dpkFloat: bind_double(stmt, idx, p.f)
        of dpkText:
          if p.s.len == 0:
            bind_text(stmt, idx, "".cstring, 0, SQLITE_TRANSIENT)
          else:
            bind_text(stmt, idx, p.s.cstring, p.s.len.int32,
              SQLITE_TRANSIENT)
        of dpkBool: bind_int(stmt, idx, if p.b: 1 else: 0)
      if brc != SQLITE_OK:
        raise newException(CatchableError,
          fname & ": could not bind parameter " & $(i + 1) & ": " &
          sqliteErr(db))
    let ncol = int(column_count(stmt))
    for c in 0 ..< ncol:
      let n = column_name(stmt, int32(c))
      result.cols.add(if n == nil: "col" & $c else: $n)
    var rc = step(stmt)
    while rc == SQLITE_ROW:
      var row: seq[DbCell] = @[]
      for c in 0 ..< ncol:
        let ci = int32(c)
        case column_type(stmt, ci)
        of SQLITE_INTEGER:
          row.add(DbCell(kind: dckInt, i: column_int64(stmt, ci)))
        of SQLITE_FLOAT:
          row.add(DbCell(kind: dckFloat, f: column_double(stmt, ci)))
        of SQLITE_TEXT:
          let n = int(column_bytes(stmt, ci))
          var s = newString(n)
          if n > 0:
            copyMem(addr s[0], column_text(stmt, ci), n)
          row.add(DbCell(kind: dckText, s: s))
        of SQLITE_BLOB:
          let n = int(column_bytes(stmt, ci))
          var s = newString(n)
          if n > 0:
            copyMem(addr s[0], column_blob(stmt, ci), n)
          row.add(DbCell(kind: dckBlob, b: s))
        else:
          row.add(DbCell(kind: dckNull))
      result.rows.add(row)
      rc = step(stmt)
    if rc != SQLITE_DONE:
      raise newException(CatchableError, fname & ": " & sqliteErr(db))
    result.changes = int64(changes(db))
    result.lastId = last_insert_rowid(db)
    result.hasLastId = true
  finally:
    discard finalize(stmt)

proc pgCellText(res: PPGresult; r, c: int32): string =
  let n = int(pqgetlength(res, r, c))
  result = newString(n)
  if n > 0:
    copyMem(addr result[0], pqgetvalue(res, r, c), n)

proc pgHexByte(p: char): int =
  case p
  of '0' .. '9': ord(p) - ord('0')
  of 'a' .. 'f': ord(p) - ord('a') + 10
  of 'A' .. 'F': ord(p) - ord('A') + 10
  else: -1

proc runPg(conn: PPGconn; text: string; params: seq[DbParam];
    fname: string): DbResult =
  var held: seq[string] = @[]
  var isNull: seq[bool] = @[]
  for p in params:
    case p.kind
    of dpkNull:
      held.add("")
      isNull.add(true)
    of dpkInt:
      held.add($p.i)
      isNull.add(false)
    of dpkFloat:
      held.add($p.f)
      isNull.add(false)
    of dpkText:
      held.add(p.s)
      isNull.add(false)
    of dpkBool:
      held.add(if p.b: "TRUE" else: "FALSE")
      isNull.add(false)
  var arr: cstringArray = nil
  if params.len > 0:
    arr = cast[cstringArray](alloc(params.len * sizeof(cstring)))
    let p = cast[ptr UncheckedArray[cstring]](arr)
    for i in 0 ..< params.len:
      p[i] = if isNull[i]: nil else: held[i].cstring
  let res =
    try:
      pqexecParams(conn, text.cstring, params.len.int32, nil, arr,
        nil, nil, 0)
    finally:
      if arr != nil:
        dealloc(arr)
  if res == nil:
    var msg = ""
    try:
      msg = ($pqerrorMessage(conn)).strip()
    except CatchableError:
      discard
    if msg.len == 0:
      msg = "connection lost"
    raise newException(CatchableError, fname & ": " & msg)
  try:
    case pqresultStatus(res)
    of PGRES_TUPLES_OK:
      let nfields = pqnfields(res)
      let ntuples = pqntuples(res)
      for c in 0 ..< nfields:
        let n = pqfname(res, c)
        result.cols.add(if n == nil: "col" & $c else: $n)
      for r in 0 ..< ntuples:
        var row: seq[DbCell] = @[]
        for c in 0 ..< nfields:
          if pqgetisnull(res, r, c) != 0:
            row.add(DbCell(kind: dckNull))
            continue
          let ft = int(pqftype(res, c))
          let s = pgCellText(res, r, c)
          case ft
          of 16:
            row.add(DbCell(kind: dckBool, bl: s == "t"))
          of 20, 21, 23:
            try:
              row.add(DbCell(kind: dckInt, i: parseBiggestInt(s)))
            except ValueError:
              raise newException(CatchableError,
                fname & ": unparseable integer \"" & s & "\"")
          of 700, 701:
            try:
              row.add(DbCell(kind: dckFloat, f: parseFloat(s)))
            except ValueError:
              raise newException(CatchableError,
                fname & ": unparseable float \"" & s & "\"")
          of 1700:
            try:
              let f = parseFloat(s)
              if f == trunc(f) and abs(f) < 9007199254740991.0:
                row.add(DbCell(kind: dckInt, i: int64(f)))
              else:
                row.add(DbCell(kind: dckFloat, f: f))
            except ValueError:
              row.add(DbCell(kind: dckText, s: s))
          of 17:
            if not s.startsWith("\\x"):
              raise newException(CatchableError,
                fname & ": unparseable bytea value")
            let hx = s[2 .. ^1]
            if hx.len mod 2 != 0:
              raise newException(CatchableError,
                fname & ": unparseable bytea value")
            var raw = newString(hx.len div 2)
            for i in 0 ..< raw.len:
              let hi = pgHexByte(hx[2 * i])
              let lo = pgHexByte(hx[2 * i + 1])
              if hi < 0 or lo < 0:
                raise newException(CatchableError,
                  fname & ": unparseable bytea value")
              raw[i] = char(hi * 16 + lo)
            row.add(DbCell(kind: dckBlob, b: raw))
          else:
            row.add(DbCell(kind: dckText, s: s))
        result.rows.add(row)
    of PGRES_COMMAND_OK:
      var n = ""
      try:
        n = ($pqcmdTuples(res)).strip()
      except CatchableError:
        discard
      if n.len > 0:
        try:
          result.changes = parseBiggestInt(n)
        except ValueError:
          discard
    else:
      var msg = ""
      try:
        msg = ($pqresultErrorMessage(res)).strip()
      except CatchableError:
        discard
      if msg.len == 0:
        msg = "query failed"
      raise newException(CatchableError, fname & ": " & msg)
  finally:
    pqclear(res)

proc runDb(e: DbEntry; text: string; params: seq[DbParam];
    fname: string): DbResult =
  validateSql(text, e.dialect, fname)
  case e.dialect
  of ddSqlite:
    runSqlite(e.sqliteDb, text, params, fname)
  of ddPostgres:
    runPg(e.pgConn, text, params, fname)

proc resultToJS(ctx: JSContextRef; r: DbResult; fname: string;
    exception: ptr JSValueRef): JSValueRef =
  ## DbResult -> {rows, rowCount, changes, lastInsertRowId?}. Blobs
  ## become Uint8Arrays (GC-owned copies). nil + JS throw on failure.
  let obj = newObject(ctx)
  var rowVals: seq[JSValueRef] = @[]
  for row in r.rows:
    let o = newObject(ctx)
    for i, c in row:
      let v =
        case c.kind
        of dckNull: JSValueMakeNull(ctx)
        of dckInt: toJS(ctx, c.i)
        of dckFloat: toJS(ctx, c.f)
        of dckText: toJS(ctx, c.s)
        of dckBool: toJS(ctx, c.bl)
        of dckBlob: toJSUint8Copy(ctx, c.b, fname, exception)
      if v == nil:
        return nil
      if not setPropChecked(ctx, o, r.cols[i], v, fname, exception):
        return nil
    rowVals.add(o)
  let arr = makeJSArray(ctx, rowVals)
  if arr == nil:
    throwError(ctx, fname & ": could not convert result to JS", exception)
    return nil
  if not setPropChecked(ctx, obj, "rows", arr, fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "rowCount", toJS(ctx, r.rows.len),
      fname, exception):
    return nil
  if not setPropChecked(ctx, obj, "changes", toJS(ctx, r.changes),
      fname, exception):
    return nil
  if r.hasLastId:
    if not setPropChecked(ctx, obj, "lastInsertRowId", toJS(ctx,
        r.lastId), fname, exception):
      return nil
  obj

proc entryOf(ctx: JSContextRef; h: JSObjectRef; fname: string;
    exception: ptr JSValueRef): tuple[ok: bool, key: pointer] =
  let key = cast[pointer](h)
  if h == nil or not dbConns.hasKey(key) or dbConns[key].closed:
    throwError(ctx, fname & ": connection is closed", exception)
    return (false, nil)
  (true, key)

proc readQueryArgs(ctx: JSContextRef; argc: csize_t;
    argv: ptr JSValueRef; fname: string; exception: ptr JSValueRef;
    text: var string; params: var seq[DbParam]): bool =
  if not checkArity(argc, 1, 2, fname, ctx, exception):
    return false
  let args = cast[ptr UncheckedArray[JSValueRef]](argv)
  if not strArg(ctx, args, 0, fname, exception, text):
    return false
  params = @[]
  if int(argc) >= 2 and args[1] != nil and
      JSValueGetType(ctx, args[1]) != kJSTypeUndefined:
    var v: NimValue
    if not nimArg(ctx, args, 1, fname, exception, v):
      return false
    try:
      params = toParams(v, fname)
    except CatchableError as e:
      throwError(ctx, e.msg, exception)
      return false
  true

proc closeNative(e: DbEntry) =
  ## Closes the native connection without touching the handle table.
  case e.dialect
  of ddSqlite:
    if e.sqliteDb != nil:
      discard sqlite3.close(e.sqliteDb)
  of ddPostgres:
    if e.pgConn != nil:
      pqfinish(e.pgConn)

proc closeEntry(key: pointer) =
  ## Removes the handle and closes the native connection. Safe with
  ## missing keys (idempotent close).
  if not dbConns.hasKey(key):
    return
  let e = dbConns[key]
  dbConns.del(key)
  if e.handle != nil:
    JSValueUnprotect(e.ctx, e.handle)
  if e.closed:
    return
  closeNative(e)

proc closeAllDb*() =
  ## Closes every live connection. Runs at runtime teardown with
  ## entries removed first, so late timer settles reject instead of
  ## touching freed handles.
  var keys: seq[pointer] = @[]
  for k in dbConns.keys:
    keys.add(k)
  for k in keys:
    if dbConns.hasKey(k):
      var e = dbConns[k]
      e.closed = true
      dbConns[k] = e
  for k in keys:
    closeEntry(k)

proc queryImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  var text: string
  var params: seq[DbParam] = @[]
  if not readQueryArgs(ctx, argumentCount, arguments, "query", exception,
      text, params):
    return nil
  let (ok, key) = entryOf(ctx, thisObject, "query", exception)
  if not ok:
    return nil
  let rt = currentRt()
  var resolveFn, rejectFn: JSObjectRef
  var mkEx: JSValueRef = nil
  let promise = JSObjectMakeDeferredPromise(ctx, addr resolveFn,
    addr rejectFn, addr mkEx)
  if promise == nil or mkEx != nil:
    throwError(ctx, "query: could not create promise", exception)
    return nil
  JSValueProtect(ctx, promise)
  JSValueProtect(ctx, resolveFn)
  JSValueProtect(ctx, rejectFn)
  let loop = rt.ensureLoop()
  inc rt.pending
  let c = ctx
  var settledOk = false
  var resultVal: JSValueRef = nil
  var errMsg = ""
  if not dbConns.hasKey(key) or dbConns[key].closed:
    errMsg = "query: connection is closed"
  else:
    let e = dbConns[key]
    try:
      let r = runDb(e, text, params, "query")
      resultVal = resultToJS(c, r, "query", nil)
      if resultVal == nil:
        errMsg = "query: could not convert result to JS"
      else:
        settledOk = true
    except CatchableError as ex:
      errMsg = ex.msg
  if resultVal != nil:
    JSValueProtect(c, resultVal)
  proc settle() {.closure.} =
    var e2: JSValueRef = nil
    if settledOk:
      var vv = resultVal
      discard JSObjectCallAsFunction(c, resolveFn, nil, 1, addr vv,
        addr e2)
    else:
      let m = toJS(c, errMsg)
      let errObj = JSObjectMakeError(c, 1, unsafeAddr m, addr e2)
      var arg = if errObj != nil: errObj else: m
      discard JSObjectCallAsFunction(c, rejectFn, nil, 1, addr arg,
        addr e2)
    if resultVal != nil:
      JSValueUnprotect(c, resultVal)
    JSValueUnprotect(c, promise)
    JSValueUnprotect(c, resolveFn)
    JSValueUnprotect(c, rejectFn)
    decDbPending(rt)
  try:
    discard loop.addTimer(0) do (id: int):
      settle()
  except CatchableError:
    settle()
  promise

proc querySyncImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  var text: string
  var params: seq[DbParam] = @[]
  if not readQueryArgs(ctx, argumentCount, arguments, "querySync",
      exception, text, params):
    return nil
  let (ok, key) = entryOf(ctx, thisObject, "querySync", exception)
  if not ok:
    return nil
  try:
    resultToJS(ctx, runDb(dbConns[key], text, params, "querySync"),
      "querySync", exception)
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    nil

proc execImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  var text: string
  var params: seq[DbParam] = @[]
  if not readQueryArgs(ctx, argumentCount, arguments, "exec", exception,
      text, params):
    return nil
  let (ok, key) = entryOf(ctx, thisObject, "exec", exception)
  if not ok:
    return nil
  let rt = currentRt()
  var resolveFn, rejectFn: JSObjectRef
  var mkEx: JSValueRef = nil
  let promise = JSObjectMakeDeferredPromise(ctx, addr resolveFn,
    addr rejectFn, addr mkEx)
  if promise == nil or mkEx != nil:
    throwError(ctx, "exec: could not create promise", exception)
    return nil
  JSValueProtect(ctx, promise)
  JSValueProtect(ctx, resolveFn)
  JSValueProtect(ctx, rejectFn)
  let loop = rt.ensureLoop()
  inc rt.pending
  let c = ctx
  var settledOk = false
  var resultVal: JSValueRef = nil
  var errMsg = ""
  if not dbConns.hasKey(key) or dbConns[key].closed:
    errMsg = "exec: connection is closed"
  else:
    let e = dbConns[key]
    try:
      let r = runDb(e, text, params, "exec")
      resultVal = resultToJS(c, r, "exec", nil)
      if resultVal == nil:
        errMsg = "exec: could not convert result to JS"
      else:
        settledOk = true
    except CatchableError as ex:
      errMsg = ex.msg
  if resultVal != nil:
    JSValueProtect(c, resultVal)
  proc settle() {.closure.} =
    var e2: JSValueRef = nil
    if settledOk:
      var vv = resultVal
      discard JSObjectCallAsFunction(c, resolveFn, nil, 1, addr vv,
        addr e2)
    else:
      let m = toJS(c, errMsg)
      let errObj = JSObjectMakeError(c, 1, unsafeAddr m, addr e2)
      var arg = if errObj != nil: errObj else: m
      discard JSObjectCallAsFunction(c, rejectFn, nil, 1, addr arg,
        addr e2)
    if resultVal != nil:
      JSValueUnprotect(c, resultVal)
    JSValueUnprotect(c, promise)
    JSValueUnprotect(c, resolveFn)
    JSValueUnprotect(c, rejectFn)
    decDbPending(rt)
  try:
    discard loop.addTimer(0) do (id: int):
      settle()
  except CatchableError:
    settle()
  promise

proc execSyncImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  var text: string
  var params: seq[DbParam] = @[]
  if not readQueryArgs(ctx, argumentCount, arguments, "execSync",
      exception, text, params):
    return nil
  let (ok, key) = entryOf(ctx, thisObject, "execSync", exception)
  if not ok:
    return nil
  try:
    resultToJS(ctx, runDb(dbConns[key], text, params, "execSync"),
      "execSync", exception)
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    nil

proc closeImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  if not checkArity(argumentCount, 0, 0, "close", ctx, exception):
    return nil
  if thisObject != nil:
    closeEntry(cast[pointer](thisObject))
  toJS(ctx, true)

proc makeHandle(ctx: JSContextRef; rt: Runtime; e: DbEntry;
    fname: string; exception: ptr JSValueRef): JSObjectRef =
  ## Handle object {dialect, query, querySync, exec, execSync, close}.
  ## Protected while open; methods dispatch via the handle table.
  let h = newObject(ctx)
  if h == nil:
    throwError(ctx, fname & ": could not create connection", exception)
    return nil
  var ex: JSValueRef = nil
  setProp(ctx, h, "query", makeFunction(ctx, "query", queryImpl),
    addr ex)
  if ex == nil:
    setProp(ctx, h, "querySync",
      makeFunction(ctx, "querySync", querySyncImpl), addr ex)
  if ex == nil:
    setProp(ctx, h, "exec", makeFunction(ctx, "exec", execImpl),
      addr ex)
  if ex == nil:
    setProp(ctx, h, "execSync",
      makeFunction(ctx, "execSync", execSyncImpl), addr ex)
  if ex == nil:
    setProp(ctx, h, "close", makeFunction(ctx, "close", closeImpl),
      addr ex)
  var e2: JSValueRef = nil
  let d = toJS(ctx, e.dialectName)
  if ex == nil:
    setProp(ctx, h, "dialect", d, addr e2)
    if e2 != nil:
      ex = e2
  if ex != nil:
    throwError(ctx, fname & ": could not create connection", exception)
    return nil
  JSValueProtect(ctx, h)
  var ne = e
  ne.ctx = ctx
  ne.rt = rt
  ne.handle = h
  dbConns[cast[pointer](h)] = ne
  h

proc connectImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  if not checkArity(argumentCount, 1, 1, "connect", ctx, exception):
    return nil
  let args = cast[ptr UncheckedArray[JSValueRef]](arguments)
  var spec: NimValue
  if not nimArg(ctx, args, 0, "connect", exception, spec):
    return nil
  var opened: DbEntry
  var errMsg = ""
  try:
    opened = openEntry(spec, "connect")
  except CatchableError as e:
    errMsg = e.msg
  let rt = currentRt()
  var resolveFn, rejectFn: JSObjectRef
  var mkEx: JSValueRef = nil
  let promise = JSObjectMakeDeferredPromise(ctx, addr resolveFn,
    addr rejectFn, addr mkEx)
  if promise == nil or mkEx != nil:
    if errMsg == "":
      closeNative(opened)
    throwError(ctx, "connect: could not create promise", exception)
    return nil
  JSValueProtect(ctx, promise)
  JSValueProtect(ctx, resolveFn)
  JSValueProtect(ctx, rejectFn)
  let loop = rt.ensureLoop()
  inc rt.pending
  let c = ctx
  var handle: JSObjectRef = nil
  if errMsg == "":
    handle = makeHandle(ctx, rt, opened, "connect", nil)
    if handle == nil:
      errMsg = "connect: could not create connection"
      closeNative(opened)
  if handle != nil:
    JSValueProtect(c, handle)
  proc settle() {.closure.} =
    var e2: JSValueRef = nil
    if errMsg == "":
      var vv: JSValueRef = handle
      discard JSObjectCallAsFunction(c, resolveFn, nil, 1, addr vv,
        addr e2)
    else:
      let m = toJS(c, errMsg)
      let errObj = JSObjectMakeError(c, 1, unsafeAddr m, addr e2)
      var arg = if errObj != nil: errObj else: m
      discard JSObjectCallAsFunction(c, rejectFn, nil, 1, addr arg,
        addr e2)
    if handle != nil:
      JSValueUnprotect(c, handle)
    JSValueUnprotect(c, promise)
    JSValueUnprotect(c, resolveFn)
    JSValueUnprotect(c, rejectFn)
    decDbPending(rt)
  try:
    discard loop.addTimer(0) do (id: int):
      settle()
  except CatchableError:
    settle()
  promise

proc connectSyncImpl(ctx: JSContextRef; function, thisObject: JSObjectRef;
    argumentCount: csize_t; arguments: ptr JSValueRef;
    exception: ptr JSValueRef): JSValueRef {.cdecl.} =
  if not checkArity(argumentCount, 1, 1, "connectSync", ctx, exception):
    return nil
  let args = cast[ptr UncheckedArray[JSValueRef]](arguments)
  var spec: NimValue
  if not nimArg(ctx, args, 0, "connectSync", exception, spec):
    return nil
  var opened: DbEntry
  try:
    opened = openEntry(spec, "connectSync")
  except CatchableError as e:
    throwError(ctx, e.msg, exception)
    return nil
  let h = makeHandle(ctx, currentRt(), opened, "connectSync", exception)
  if h == nil:
    closeNative(opened)
  h

proc installDriver*(ctx: JSContextRef; rt: Runtime): JSObjectRef =
  ## Raw executor behind require("std/db/driver"): connect/connectSync.
  let ns = newObject(ctx)
  var ex: JSValueRef = nil
  setProp(ctx, ns, "connect", makeFunction(ctx, "connect", connectImpl),
    addr ex)
  if ex == nil:
    setProp(ctx, ns, "connectSync",
      makeFunction(ctx, "connectSync", connectSyncImpl), addr ex)
  if ex != nil:
    return nil
  ns

onTeardown.add(closeAllDb)
