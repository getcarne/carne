# Carne std/archive: archive creation/extraction and compression.
#
#   const archive = require("std/archive");
#   archive.compress("gz", data[, level])          -> Uint8Array
#   archive.decompress("gz", data)                 -> Uint8Array
#   archive.compressFile("gz", src, dst[, level])  -> undefined
#   archive.decompressFile("gz", src, dst)         -> undefined
#   archive.create("tar", entries[, {compression}]) -> Uint8Array
#   archive.createFile("tar", entries, out[, {compression}]) -> undefined
#   archive.archiveDir("tar", srcDir, dst[, {compression, root}]) -> undefined
#   archive.extract(path, outDir)                  -> undefined
#   archive.list(path)                             -> [name]
#   archive.read(path)                             -> [{name, data}]
#   archive.identify(path)                         -> {archive, compression}
#
# Formats: archives "tar", "zip", "rar"; compression "gz", "zz"
# (zlib), "lz4", "bz2", "br" (brotli, store-encode). Names are
# case-insensitive with an optional leading dot ("GZ", ".gz"); common
# aliases ("gzip", "zlib", "bzip2", "brotli") work too. A "tar.gz"
# style pair is an archive plus {compression: "gz"}, never one name.
#
# `data` is a string (UTF-8 bytes) or Uint8Array; results are always
# Uint8Array so NUL bytes survive (plain strings truncate at the first
# NUL on the way out, like os.readFile). Pair with
# os.writeFileBytes/os.readFileBytes to persist blobs.
#
# `entries` for create/createFile mixes in-memory and on-disk files:
# [{name, data}] (data string|Uint8Array), [{name, path}] (path read
# from disk, name defaulting to its basename) and [{name}] or
# [{name, dir: true}] for directories. A path pointing at a directory
# is stored recursively. Entry names must be relative without "..".
#
# Everything is synchronous and blocks the loop like std/os.
# Encrypted archives and the virtual filesystem stay in pkg/archive
# (out of scope in v1).
#
# Backed by pkg/archive (pure Nim, no C bindings): own
# DEFLATE/gzip/zip/tar codecs, rar 5.0/7.0 read + write, bzip2/lz4
# and brotli decode.

import std/[options, strutils]

import javascriptcore

import pkg/archive
import pkg/archive/files

import ../bridge

const maxArchiveEntries = 100_000
  ## Cap on create/createFile entries, mirroring the bridge snapshot
  ## cap: fail fast instead of walking hostile arrays.

proc archiveErr(ctx: JSContextRef; docBlock, name, detail: string;
    exception: ptr JSValueRef) =
  ## Domain-error throw with the JSDoc block first (CLI info).
  var msg = ""
  if docBlock.len > 0:
    msg = docBlock & "\n"
  throwError(ctx, msg & name & ": " & detail, exception)

proc normFmt(s: string): string =
  s.strip().toLowerAscii().strip(chars = {'.'})

proc parseCompression(s: string): CompressionFormat =
  ## Friendly name -> lib enum. Raises ValueError.
  case normFmt(s)
  of "gz", "gzip": cfGz
  of "zz", "zlib": cfZlib
  of "lz4": cfLz4
  of "bz2", "bzip2": cfBz2
  of "br", "brotli": cfBrotli
  else:
    raise newException(ValueError, "unknown compression format \"" & s &
      "\" (want gz, zz, lz4, bz2 or br)")

proc parseArchive(s: string): ArchiveFormat =
  ## Friendly name -> lib enum. Raises ValueError.
  case normFmt(s)
  of "tar": afTar
  of "zip": afZip
  of "rar": afRar
  else:
    raise newException(ValueError, "unknown archive format \"" & s &
      "\" (want tar, zip or rar)")

proc compressionName(f: CompressionFormat): string =
  case f
  of cfGz: "gz"
  of cfZlib: "zz"
  of cfLz4: "lz4"
  of cfBz2: "bz2"
  of cfBrotli: "br"

proc archiveName(f: ArchiveFormat): string =
  case f
  of afTar: "tar"
  of afZip: "zip"
  of afRar: "rar"

proc checkEntryName(name: string): string =
  ## Validates a normalized (no trailing slash) entry name. Raises
  ## ValueError; extraction re-guards with safeDestPath on the way
  ## out, so a malicious archive still cannot escape on extract.
  if name.len == 0 or name == ".":
    raise newException(ValueError, "entry name must not be empty")
  if name.startsWith("/"):
    raise newException(ValueError,
      "entry name must not be absolute: \"" & name & "\"")
  for part in name.split('/'):
    if part == "..":
      raise newException(ValueError,
        "entry name must not contain \"..\": \"" & name & "\"")
  name

proc stripTrailingSlashes(s: string): string =
  result = s
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc diskBase(p: string): string =
  ## Basename over both separators (disk paths, either platform).
  var i = p.len - 1
  while i >= 0 and (p[i] == '/' or p[i] == '\\'):
    dec i
  if i < 0:
    return ""
  var j = i
  while j >= 0 and p[j] != '/' and p[j] != '\\':
    dec j
  p[j + 1 .. i]

proc propRaw(ctx: JSContextRef; obj: JSValueRef; key: string;
    val: var JSValueRef): bool =
  ## One live property read (binary-safe: no snapshot). False when the
  ## getter throws or the ref is missing.
  let k = newJSString(key)
  defer: JSStringRelease(k)
  var ex: JSValueRef = nil
  val = JSObjectGetProperty(ctx, cast[JSObjectRef](obj), k, addr ex)
  ex == nil and val != nil

proc readEntries(ctx: JSContextRef; arrVal: JSValueRef; fname,
    docBlock: string; exception: ptr JSValueRef;
    mems: var seq[tuple[name, data: string; isDir: bool]];
    disks: var seq[tuple[disk, name: string]]): bool =
  ## Entries array -> memory blobs plus (disk path, archive name)
  ## pairs. Data fields stay live until readBytesParam copies them:
  ## snapshotting a Uint8Array would walk it per byte.
  mems = @[]
  disks = @[]
  if arrVal == nil or JSValueGetType(ctx, arrVal) != kJSTypeObject or
      not JSValueIsArray(ctx, arrVal):
    throwTypeMismatch(ctx, fname, "entries", jsKindName(ctx, arrVal),
      "array", docBlock, exception)
    return false
  let lk = newJSString("length")
  defer: JSStringRelease(lk)
  var lex: JSValueRef = nil
  let lenVal = JSObjectGetProperty(ctx, cast[JSObjectRef](arrVal), lk,
    addr lex)
  if lex != nil or lenVal == nil:
    throwError(ctx, fname & ": entries has an unreadable length",
      exception)
    return false
  var nex: JSValueRef = nil
  let n = int(JSValueToNumber(ctx, lenVal, addr nex))
  if nex != nil or n < 0:
    throwError(ctx, fname & ": entries has an unreadable length",
      exception)
    return false
  if n > maxArchiveEntries:
    throwError(ctx, fname & ": too many entries (" & $n & ", cap " &
      $maxArchiveEntries & ")", exception)
    return false
  for i in 0 ..< n:
    var eex: JSValueRef = nil
    let item = JSObjectGetPropertyAtIndex(ctx,
      cast[JSObjectRef](arrVal), cuint(i), addr eex)
    if eex != nil or item == nil:
      throwError(ctx, fname & ": entries[" & $i & "] is unreadable",
        exception)
      return false
    let what = "entries[" & $i & "]"
    if JSValueGetType(ctx, item) != kJSTypeObject or
        JSValueIsArray(ctx, item) or JSObjectIsFunction(ctx, item):
      throwError(ctx, fname & ": " & what & " must be an object",
        exception)
      return false
    var err = ""
    let nName = getField(ctx, item, "name", err)
    if err != "":
      throwError(ctx, fname & ": " & what & ".name " & err, exception)
      return false
    var name = ""
    var hasName = false
    case nName.kind
    of nvkUndefined:
      discard
    of nvkString:
      name = nName.s
      hasName = true
    else:
      throwError(ctx, fname & ": " & what & ".name must be a string, got " &
        jsTypeName(nName.kind), exception)
      return false
    let nPath = getField(ctx, item, "path", err)
    if err != "":
      throwError(ctx, fname & ": " & what & ".path " & err, exception)
      return false
    var path = ""
    var hasPath = false
    case nPath.kind
    of nvkUndefined:
      discard
    of nvkString:
      path = nPath.s
      hasPath = true
    else:
      throwError(ctx, fname & ": " & what & ".path must be a string, got " &
        jsTypeName(nPath.kind), exception)
      return false
    let nDir = getField(ctx, item, "dir", err)
    if err != "":
      throwError(ctx, fname & ": " & what & ".dir " & err, exception)
      return false
    var isDir = false
    case nDir.kind
    of nvkUndefined:
      discard
    of nvkBool:
      isDir = nDir.b
    else:
      throwError(ctx, fname & ": " & what & ".dir must be a boolean, got " &
        jsTypeName(nDir.kind), exception)
      return false
    var dataProp: JSValueRef = nil
    if not propRaw(ctx, item, "data", dataProp):
      throwError(ctx, fname & ": " & what & ".data is unreadable",
        exception)
      return false
    var data = ""
    var hasData = false
    if dataProp != nil and
        JSValueGetType(ctx, dataProp) != kJSTypeUndefined:
      if not readBytesParam(ctx, dataProp, fname, what & ".data",
          docBlock, exception, data):
        return false
      hasData = true
    if hasData and hasPath:
      throwError(ctx, fname & ": " & what &
        " takes data or path, not both", exception)
      return false
    if isDir and (hasData or hasPath):
      throwError(ctx, fname & ": " & what &
        " is a directory and takes no data or path", exception)
      return false
    var entryName = name
    if not hasName:
      if not hasPath:
        throwError(ctx, fname & ": " & what & " needs a name",
          exception)
        return false
      entryName = diskBase(path)
      if entryName.len == 0:
        throwError(ctx, fname & ": " & what &
          ".path has no file name: \"" & path & "\"", exception)
        return false
    entryName = stripTrailingSlashes(entryName)
    try:
      entryName = checkEntryName(entryName)
    except ValueError as e:
      throwError(ctx, fname & ": " & what & ": " & e.msg, exception)
      return false
    if isDir or (not hasData and not hasPath):
      mems.add((entryName, "", true))
    elif hasData:
      mems.add((entryName, data, false))
    else:
      disks.add((path, entryName))
  true

proc buildFiles(mems: seq[tuple[name, data: string; isDir: bool]];
    disks: seq[tuple[disk, name: string]]): seq[FileInfo] =
  ## Memory + disk entries -> lib FileInfo list (file contents are
  ## shared, disk files mmap lazily; nothing is read here).
  var ctxA: ArchiveContext
  var fsEntries: seq[FsEntry] = @[]
  for m in mems:
    if m.isDir:
      fsEntries.add(FsEntry(path: m.name,
        meta: FileMeta(name: baseNameV(m.name), isDir: true), data: ""))
    else:
      fsEntries.add(FsEntry(path: m.name,
        meta: FileMeta(name: baseNameV(m.name), size: m.data.len.int64,
          isRegular: true), data: m.data))
  result = filesFromEntries(ctxA, FromFSOptions(), fsEntries, ".", "")
  for d in disks:
    for f in filesFromDisk(ctxA, FromDiskOptions(), [(d.disk, d.name)]):
      result.add(f)

proc checkOptsBag(opts: NimValue; fname: string) =
  ## create/archive opts must be an object when present (absent and
  ## null both mean defaults).
  if opts.kind notin {nvkUndefined, nvkNull, nvkObject}:
    raise newException(ValueError,
      fname & ": opts must be an object, got " & jsTypeName(opts.kind))

proc optsCompression(opts: NimValue; fname: string): Option[CompressionFormat] =
  let c = opts.getOpt("compression", NimValue(kind: nvkUndefined))
  if c.kind in {nvkUndefined, nvkNull}:
    return none(CompressionFormat)
  if c.kind != nvkString:
    raise newException(ValueError,
      fname & ": opts.compression must be a string")
  some(parseCompression(c.s))

proc optsRoot(opts: NimValue; fname: string): string =
  let r = opts.getOpt("root", NimValue(kind: nvkUndefined))
  if r.kind in {nvkUndefined, nvkNull}:
    return ""
  if r.kind != nvkString:
    raise newException(ValueError,
      fname & ": opts.root must be a string")
  r.s

proc doCompress(ctx: JSContextRef; format: string; dataVal: JSValueRef;
    level: int64; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "compress"
  var data = ""
  if not readBytesParam(ctx, dataVal, fname, "data", docBlock, exception,
      data):
    return nil
  try:
    let cf = parseCompression(format)
    toJSUint8Copy(ctx, compress(cf, data, int(level)), fname, exception)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

proc doDecompress(ctx: JSContextRef; format: string; dataVal: JSValueRef;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const fname = "decompress"
  var data = ""
  if not readBytesParam(ctx, dataVal, fname, "data", docBlock, exception,
      data):
    return nil
  try:
    let cf = parseCompression(format)
    toJSUint8Copy(ctx, decompress(cf, data), fname, exception)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

proc doCompressFile(ctx: JSContextRef; format, src, dst: string;
    level: int64; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "compressFile"
  try:
    let cf = parseCompression(format)
    compressFile(cf, src, dst, int(level))
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    return nil
  JSValueMakeUndefined(ctx)

proc doDecompressFile(ctx: JSContextRef; format, src, dst: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const fname = "decompressFile"
  try:
    let cf = parseCompression(format)
    decompressFile(cf, src, dst)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    return nil
  JSValueMakeUndefined(ctx)

proc doCreate(ctx: JSContextRef; format: string; entriesVal: JSValueRef;
    opts: NimValue; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "create"
  var mems: seq[tuple[name, data: string; isDir: bool]] = @[]
  var disks: seq[tuple[disk, name: string]] = @[]
  if not readEntries(ctx, entriesVal, fname, docBlock, exception, mems,
      disks):
    return nil
  try:
    let af = parseArchive(format)
    checkOptsBag(opts, fname)
    let cfOpt = optsCompression(opts, fname)
    let files = buildFiles(mems, disks)
    var ctxA: ArchiveContext
    let dst = newOutput()
    if cfOpt.isSome:
      CompressedArchive(archival: af,
        compression: cfOpt.get).archiveTo(ctxA, dst, files)
    else:
      archiveFormat(af, ctxA, dst, files)
    toJSUint8Copy(ctx, take(dst), fname, exception)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

proc doCreateFile(ctx: JSContextRef; format: string;
    entriesVal: JSValueRef; outPath: string; opts: NimValue;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const fname = "createFile"
  var mems: seq[tuple[name, data: string; isDir: bool]] = @[]
  var disks: seq[tuple[disk, name: string]] = @[]
  if not readEntries(ctx, entriesVal, fname, docBlock, exception, mems,
      disks):
    return nil
  try:
    let af = parseArchive(format)
    checkOptsBag(opts, fname)
    let cfOpt = optsCompression(opts, fname)
    let files = buildFiles(mems, disks)
    var ctxA: ArchiveContext
    let dst = newOutput()
    if cfOpt.isSome:
      CompressedArchive(archival: af,
        compression: cfOpt.get).archiveTo(ctxA, dst, files)
    else:
      archiveFormat(af, ctxA, dst, files)
    writeFile(outPath, take(dst))
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    return nil
  JSValueMakeUndefined(ctx)

proc doArchiveDir(ctx: JSContextRef; format, srcDir, dstPath: string;
    opts: NimValue; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "archiveDir"
  try:
    let af = parseArchive(format)
    checkOptsBag(opts, fname)
    let cfOpt = optsCompression(opts, fname)
    let root = optsRoot(opts, fname)
    var ctxA: ArchiveContext
    archiveDir(af, srcDir, dstPath, root, ctxA, cfOpt)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    return nil
  JSValueMakeUndefined(ctx)

proc doExtract(ctx: JSContextRef; path, outDir: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "extract"
  try:
    extractFile(path, outDir)
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    return nil
  JSValueMakeUndefined(ctx)

proc doList(ctx: JSContextRef; path: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "list"
  try:
    var vals: seq[JSValueRef] = @[]
    for name in listEntries(path):
      vals.add(toJS(ctx, name))
    let arr = makeJSArray(ctx, vals)
    if arr == nil:
      archiveErr(ctx, docBlock, fname, "could not convert result to JS",
        exception)
      return nil
    arr
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

proc doRead(ctx: JSContextRef; path: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "read"
  try:
    var ctxA: ArchiveContext
    var items: seq[JSValueRef] = @[]
    for e in extractAll(path, ctxA):
      let obj = newObject(ctx)
      if not setPropChecked(ctx, obj, "name", toJS(ctx, e.name), fname,
          exception):
        return nil
      let d = toJSUint8Copy(ctx, e.data, fname, exception)
      if d == nil:
        return nil
      if not setPropChecked(ctx, obj, "data", d, fname, exception):
        return nil
      items.add(obj)
    let arr = makeJSArray(ctx, items)
    if arr == nil:
      archiveErr(ctx, docBlock, fname, "could not convert result to JS",
        exception)
      return nil
    arr
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

proc doIdentify(ctx: JSContextRef; path: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const fname = "identify"
  try:
    let res = identifyPath(path)
    let obj = newObject(ctx)
    if res.archival.isSome:
      if not setPropChecked(ctx, obj, "archive",
          toJS(ctx, archiveName(res.archival.get)), fname, exception):
        return nil
    else:
      if not setPropChecked(ctx, obj, "archive", JSValueMakeNull(ctx),
          fname, exception):
        return nil
    if res.compression.isSome:
      if not setPropChecked(ctx, obj, "compression",
          toJS(ctx, compressionName(res.compression.get)), fname,
          exception):
        return nil
    else:
      if not setPropChecked(ctx, obj, "compression",
          JSValueMakeNull(ctx), fname, exception):
        return nil
    obj
  except CatchableError as e:
    archiveErr(ctx, docBlock, fname, e.msg, exception)
    nil

## Builds the std/archive namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn compress(format: string, data: JSValueRef, level: default(int, 0)):
      ## archive.compress(format, data[, level]) -> Uint8Array
      return doCompress(ctx, format, data, level, docBlock, exception)

    module.registerFn decompress(format: string, data: JSValueRef):
      ## archive.decompress(format, data) -> Uint8Array
      return doDecompress(ctx, format, data, docBlock, exception)

    module.registerFn compressFile(format: string, src: string, dst: string, level: default(int, 0)):
      ## archive.compressFile(format, src, dst[, level]) -> undefined
      return doCompressFile(ctx, format, src, dst, level, docBlock,
        exception)

    module.registerFn decompressFile(format: string, src: string, dst: string):
      ## archive.decompressFile(format, src, dst) -> undefined
      return doDecompressFile(ctx, format, src, dst, docBlock, exception)

    module.registerFn create(format: string, entries: JSValueRef, opts ?: NimValue):
      ## archive.create(format, entries[, {compression}]) -> Uint8Array
      return doCreate(ctx, format, entries, opts, docBlock, exception)

    module.registerFn createFile(format: string, entries: JSValueRef, outPath: string, opts ?: NimValue):
      ## archive.createFile(format, entries, out[, {compression}]) -> undefined
      return doCreateFile(ctx, format, entries, outPath, opts, docBlock,
        exception)

    module.registerFn archiveDir(format: string, srcDir: string, dstPath: string, opts ?: NimValue):
      ## archive.archiveDir(format, srcDir, dst[, {compression, root}]) -> undefined
      return doArchiveDir(ctx, format, srcDir, dstPath, opts, docBlock,
        exception)

    module.registerFn extract(path: string, outDir: string):
      ## archive.extract(path, outDir) -> undefined
      return doExtract(ctx, path, outDir, docBlock, exception)

    module.registerFn list(path: string):
      ## archive.list(path) -> [entry names]
      return doList(ctx, path, docBlock, exception)

    module.registerFn read(path: string):
      ## archive.read(path) -> [{name, data}]
      return doRead(ctx, path, docBlock, exception)

    module.registerFn identify(path: string):
      ## archive.identify(path) -> {archive, compression}
      return doIdentify(ctx, path, docBlock, exception)
