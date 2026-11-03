# Carne lazy libpq bindings: postgres without a load-time dependency.
#
# db_connector/postgres binds libpq with `dynlib`, so any binary that
# imports it fails at startup with `could not load: libpq.dylib` on
# machines without a postgres client (CI runners). This module
# re-declares only the symbols std/db uses and resolves them via
# std/dynlib on first postgres use: sqlite-only machines never touch
# libpq, and postgres connects throw a clear CatchableError when the
# library is missing instead of killing the process at load.
#
# Proc/type names mirror db_connector/postgres so std/db swaps one
# import. Opaque structs stay `pointer`: std/db only passes handles
# through, never dereferences them.

import std/dynlib

type
  PPGconn* = pointer
  PPGresult* = pointer

const
  CONNECTION_OK*: cint = 0
  PGRES_COMMAND_OK*: cint = 1
  PGRES_TUPLES_OK*: cint = 2

var pgLib: LibHandle = nil

proc pgEnsureLib() =
  ## Loads libpq on first use. Raises CatchableError with install
  ## hints when no candidate resolves.
  if pgLib != nil:
    return
  when defined(macosx):
    const candidates = [
      "libpq.5.dylib",
      "libpq.dylib",
      "/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
      "/usr/local/opt/libpq/lib/libpq.5.dylib",
      "/opt/homebrew/lib/libpq.5.dylib",
      "/usr/local/lib/libpq.5.dylib"
    ]
  elif defined(linux):
    const candidates = [
      "libpq.so.5",
      "libpq.so",
      "/usr/lib/x86_64-linux-gnu/libpq.so.5",
      "/usr/lib/aarch64-linux-gnu/libpq.so.5"
    ]
  else:
    const candidates = ["libpq"]
  for c in candidates:
    pgLib = loadLib(c)
    if pgLib != nil:
      return
  raise newException(CatchableError,
    "postgres: libpq client library not found (macOS: brew install libpq; " &
    "Linux: install libpq5)")

proc pgSym(name: string): pointer =
  pgEnsureLib()
  result = symAddr(pgLib, name)
  if result == nil:
    raise newException(CatchableError,
      "postgres: libpq is missing symbol " & name)

proc pqconnectdb*(conninfo: cstring): PPGconn =
  let p = cast[proc(c: cstring): PPGconn {.cdecl.}](pgSym("PQconnectdb"))
  p(conninfo)

proc pqfinish*(conn: PPGconn) =
  let p = cast[proc(c: PPGconn) {.cdecl.}](pgSym("PQfinish"))
  p(conn)

proc pqstatus*(conn: PPGconn): cint =
  let p = cast[proc(c: PPGconn): cint {.cdecl.}](pgSym("PQstatus"))
  p(conn)

proc pqerrorMessage*(conn: PPGconn): cstring =
  let p = cast[proc(c: PPGconn): cstring {.cdecl.}](pgSym("PQerrorMessage"))
  p(conn)

proc pqexecParams*(conn: PPGconn; command: cstring; nParams: int32;
    paramTypes: pointer; paramValues: cstringArray;
    paramLengths, paramFormats: ptr int32;
    resultFormat: int32): PPGresult =
  let p = cast[proc(c: PPGconn; cmd: cstring; n: int32; types: pointer;
    vals: cstringArray; lens, fmts: ptr int32; rf: int32): PPGresult
    {.cdecl.}](pgSym("PQexecParams"))
  p(conn, command, nParams, paramTypes, paramValues, paramLengths,
    paramFormats, resultFormat)

proc pqresultStatus*(res: PPGresult): cint =
  let p = cast[proc(r: PPGresult): cint {.cdecl.}](pgSym("PQresultStatus"))
  p(res)

proc pqresultErrorMessage*(res: PPGresult): cstring =
  let p = cast[proc(r: PPGresult): cstring {.cdecl.}](pgSym(
    "PQresultErrorMessage"))
  p(res)

proc pqntuples*(res: PPGresult): int32 =
  let p = cast[proc(r: PPGresult): int32 {.cdecl.}](pgSym("PQntuples"))
  p(res)

proc pqnfields*(res: PPGresult): int32 =
  let p = cast[proc(r: PPGresult): int32 {.cdecl.}](pgSym("PQnfields"))
  p(res)

proc pqfname*(res: PPGresult; fieldNum: int32): cstring =
  let p = cast[proc(r: PPGresult; f: int32): cstring {.cdecl.}](pgSym(
    "PQfname"))
  p(res, fieldNum)

proc pqftype*(res: PPGresult; fieldNum: int32): int32 =
  let p = cast[proc(r: PPGresult; f: int32): int32 {.cdecl.}](pgSym("PQftype"))
  p(res, fieldNum)

proc pqgetvalue*(res: PPGresult; tupNum, fieldNum: int32): cstring =
  let p = cast[proc(r: PPGresult; t, f: int32): cstring {.cdecl.}](pgSym(
    "PQgetvalue"))
  p(res, tupNum, fieldNum)

proc pqgetlength*(res: PPGresult; tupNum, fieldNum: int32): int32 =
  let p = cast[proc(r: PPGresult; t, f: int32): int32 {.cdecl.}](pgSym(
    "PQgetlength"))
  p(res, tupNum, fieldNum)

proc pqgetisnull*(res: PPGresult; tupNum, fieldNum: int32): int32 =
  let p = cast[proc(r: PPGresult; t, f: int32): int32 {.cdecl.}](pgSym(
    "PQgetisnull"))
  p(res, tupNum, fieldNum)

proc pqclear*(res: PPGresult) =
  let p = cast[proc(r: PPGresult) {.cdecl.}](pgSym("PQclear"))
  p(res)

proc pqcmdTuples*(res: PPGresult): cstring =
  let p = cast[proc(r: PPGresult): cstring {.cdecl.}](pgSym("PQcmdTuples"))
  p(res)
