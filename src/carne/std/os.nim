# Carne std/os: synchronous OS utilities (files, dirs, process).
#
#   const os = require("std/os");
#   os.readFile(path)         -> string (throws on IOError)
#   os.readFileBytes(path)    -> Uint8Array (mmap zero-copy, throws on IOError)
#   os.writeFile(path, data)  -> undefined
#   os.appendFile(path, data) -> undefined
#   os.exists(path)           -> bool (files and dirs)
#   os.isFile(path)           -> bool
#   os.isDir(path)            -> bool
#   os.readDir(path)          -> [{name, kind}] (kind: file|dir|symlink)
#   os.mkdir(path[, recursive]) -> undefined
#   os.remove(path)           -> undefined (files only)
#   os.removeDir(path[, recursive]) -> undefined
#   os.copy(src, dst)         -> undefined (files)
#   os.move(src, dst)         -> undefined (files and dirs)
#   os.stat(path)             -> {size, kind, mtimeMs, atimeMs}
#   os.tmpdir()               -> string
#   os.homedir()              -> string
#   os.configDir()            -> string
#   os.cacheDir()             -> string
#   os.pid()                  -> int
#   os.sleep(ms)              -> undefined (blocks the loop)
#   os.exec(cmd)              -> {code, output} (blocks the loop)
#
# Everything throws a JS Error on failure. sleep and exec block the
# event loop like any sync call: fine in scripts, stalls servers.

import std/[algorithm, json, memfiles, os, osproc, times]

import javascriptcore

import ../bridge

proc kindName(pc: PathComponent): string =
  case pc
  of pcFile: "file"
  of pcDir: "dir"
  of pcLinkToFile, pcLinkToDir: "symlink"

proc toMs(t: Time): int64 =
  int64(t.toUnix()) * 1000 + int64(t.nanosecond div 1_000_000)

proc statToJson(info: FileInfo): JsonNode =
  result = newJObject()
  result["size"] = newJInt(info.size)
  result["kind"] = %kindName(info.kind)
  result["mtimeMs"] = %toMs(info.lastWriteTime)
  result["atimeMs"] = %toMs(info.lastAccessTime)

proc mkdirRecursive(path: string) =
  ## createDir through missing parents (no-op when path exists).
  var missing: seq[string] = @[]
  var cur = path
  while cur.len > 0 and not dirExists(cur) and not fileExists(cur):
    missing.add(cur)
    let parent = parentDir(cur)
    if parent == cur:
      break
    cur = parent
  for i in countdown(missing.high, 0):
    createDir(missing[i])

proc removeDirRecursive(path: string) =
  ## Depth-first delete: files first, then dirs deepest-first, then
  ## the root. Symlinked dirs are removed as links, never descended
  ## into (followFilter stays empty).
  var files: seq[string] = @[]
  for p in walkDirRec(path, yieldFilter = {pcFile, pcLinkToFile,
      pcLinkToDir}, followFilter = {}):
    files.add(p)
  var dirs: seq[string] = @[]
  for p in walkDirRec(path, yieldFilter = {pcDir}, followFilter = {}):
    dirs.add(p)
  for f in files:
    removeFile(f)
  dirs.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for d in dirs:
    removeDir(d)
  removeDir(path)

const mmapThreshold = 64 * 1024
  ## readFile maps instead of reading past this size: below it the
  ## mmap syscall + page-table cost exceeds one streaming read, and
  ## the bridge string snapshot (~1us/KB) dominates either way.

proc readFileFast(path: string): string =
  ## readFile with an mmap fast path for large regular files. Small,
  ## empty and non-mappable inputs (pipes, proc, dirs) fall back to
  ## readFile, so errors stay byte-identical to the plain call. Raises
  ## IOError/OSError like readFile.
  let size =
    try:
      getFileSize(path)
    except OSError:
      return readFile(path)
  if size <= mmapThreshold:
    return readFile(path)
  var mf: MemFile
  try:
    mf = memfiles.open(path)
  except OSError:
    return readFile(path)
  try:
    if mf.size <= 0:
      result = readFile(path)
    else:
      # Immediate copy + close keeps the truncate-SIGBUS window tiny;
      # the mapping never outlives this call.
      result = newString(mf.size)
      copyMem(addr result[0], mf.mem, mf.size)
  finally:
    mf.close()

## Builds the std/os namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn readFile(path: string):
      ## os.readFile(path) -> string (throws on IOError)
      try:
        toJS(ctx, readFileFast(path))
      except IOError as e:
        throwError(ctx, "readFile: " & e.msg, exception)
        nil
      except OSError as e:
        throwError(ctx, "readFile: " & e.msg, exception)
        nil

    module.registerFn readFileBytes(path: string):
      ## os.readFileBytes(path) -> Uint8Array (mmap zero-copy, throws on IOError)
      try:
        when not defined(windows):
          let size =
            try:
              getFileSize(path)
            except OSError:
              return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
                exception)
          if size <= 0:
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          var mf: MemFile
          try:
            mf = memfiles.open(path)
          except OSError:
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          if mf.size <= 0:
            mf.close()
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          # Ownership moves to JSC (munmap on GC): never close mf
          # past this point, on success or failure.
          let m = mf.mem
          let s = mf.size
          return toJSUint8Mmap(ctx, m, s, "readFileBytes", exception)
        else:
          return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
            exception)
      except IOError as e:
        throwError(ctx, "readFileBytes: " & e.msg, exception)
        nil
      except OSError as e:
        throwError(ctx, "readFileBytes: " & e.msg, exception)
        nil

    module.registerFn writeFile(path: string, data: string):
      ## os.writeFile(path, data) -> undefined
      try:
        writeFile(path, data)
      except IOError as e:
        throwError(ctx, "writeFile: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "writeFile: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn appendFile(path: string, data: string):
      ## os.appendFile(path, data) -> undefined
      try:
        var f = system.open(path, fmAppend)
        try:
          f.write(data)
        finally:
          f.close()
      except IOError as e:
        throwError(ctx, "appendFile: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "appendFile: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn exists(path: string):
      ## os.exists(path) -> bool (files and dirs)
      toJS(ctx, fileExists(path) or dirExists(path))

    module.registerFn isFile(path: string):
      ## os.isFile(path) -> bool
      toJS(ctx, fileExists(path))

    module.registerFn isDir(path: string):
      ## os.isDir(path) -> bool
      toJS(ctx, dirExists(path))

    module.registerFn readDir(path: string):
      ## os.readDir(path) -> [{name, kind}]
      var entries = newJArray()
      try:
        for pc, entry in walkDir(path, checkDir = true):
          var obj = newJObject()
          obj["name"] = %entry.extractFilename()
          obj["kind"] = %kindName(pc)
          entries.add(obj)
      except OSError as e:
        throwError(ctx, "readDir: " & e.msg, exception)
        return nil
      returnJson(ctx, entries, "readDir", exception)

    module.registerFn mkdir(path: string, recursive ?: bool):
      ## os.mkdir(path[, recursive]) -> undefined
      try:
        if recursive:
          mkdirRecursive(path)
        else:
          createDir(path)
      except OSError as e:
        throwError(ctx, "mkdir: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn remove(path: string):
      ## os.remove(path) -> undefined (files only)
      try:
        removeFile(path)
      except OSError as e:
        throwError(ctx, "remove: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn removeDir(path: string, recursive ?: bool):
      ## os.removeDir(path[, recursive]) -> undefined
      try:
        if recursive:
          removeDirRecursive(path)
        else:
          removeDir(path)
      except OSError as e:
        throwError(ctx, "removeDir: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn copy(src: string, dst: string):
      ## os.copy(src, dst) -> undefined (files)
      try:
        copyFile(src, dst)
      except OSError as e:
        throwError(ctx, "copy: " & e.msg, exception)
        return nil
      except IOError as e:
        throwError(ctx, "copy: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn move(src: string, dst: string):
      ## os.move(src, dst) -> undefined (files and dirs)
      try:
        moveFile(src, dst)
      except OSError as e:
        throwError(ctx, "move: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn stat(path: string):
      ## os.stat(path) -> {size, kind, mtimeMs, atimeMs}
      try:
        returnJson(ctx, statToJson(getFileInfo(path)), "stat", exception)
      except OSError as e:
        throwError(ctx, "stat: " & e.msg, exception)
        nil

    module.registerFn tmpdir():
      ## os.tmpdir() -> temp directory path
      try:
        toJS(ctx, getTempDir())
      except OSError as e:
        throwError(ctx, "tmpdir: " & e.msg, exception)
        nil

    module.registerFn homedir():
      ## os.homedir() -> home directory path
      try:
        toJS(ctx, getHomeDir())
      except OSError as e:
        throwError(ctx, "homedir: " & e.msg, exception)
        nil

    module.registerFn configDir():
      ## os.configDir() -> config directory path
      try:
        toJS(ctx, getConfigDir())
      except OSError as e:
        throwError(ctx, "configDir: " & e.msg, exception)
        nil

    module.registerFn cacheDir():
      ## os.cacheDir() -> cache directory path
      try:
        toJS(ctx, getCacheDir())
      except OSError as e:
        throwError(ctx, "cacheDir: " & e.msg, exception)
        nil

    module.registerFn pid():
      ## os.pid() -> current process id
      toJS(ctx, int(getCurrentProcessId()))

    module.registerFn sleep(ms: int):
      ## os.sleep(ms) -> undefined (blocks the loop)
      if ms < 0:
        throwError(ctx, "sleep: ms out of range (must be >= 0)", exception)
        return nil
      os.sleep(ms)
      JSValueMakeUndefined(ctx)

    module.registerFn exec(cmd: string):
      ## os.exec(cmd) -> {code, output} (blocks the loop)
      try:
        let res = execCmdEx(cmd)
        var obj = newJObject()
        obj["code"] = %res.exitCode
        obj["output"] = %res.output
        returnJson(ctx, obj, "exec", exception)
      except OSError as e:
        throwError(ctx, "exec: " & e.msg, exception)
        nil
      except IOError as e:
        throwError(ctx, "exec: " & e.msg, exception)
        nil
