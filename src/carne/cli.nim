# Carne CLI styling (mirrors dfkup's usage/cmd comment style).
#
# Colors are disabled under NO_COLOR or TERM=dumb.

import std/[os, strutils, algorithm]

const versionStr* = "0.1.0"

const
  ansiReset = "\e[0m"
  ansiBoldWhite = "\e[1;37m"
  ansiGrey = "\e[90m"
  ansiRed = "\e[31m"

proc useColor*(): bool =
  getEnv("NO_COLOR") == "" and getEnv("TERM") != "dumb"

proc paint*(s, code: string): string =
  if useColor():
    code & s & ansiReset
  else:
    s

proc label*(s: string): string =
  paint(s, ansiBoldWhite)

proc grey*(s: string): string =
  paint(s, ansiGrey)

proc errPrefix*(): string =
  paint("error:", ansiRed)

proc findTestFiles*(root = "tests"): seq[string] =
  ## Recursive `*.test.js` discovery under root, sorted. Empty when
  ## the directory is missing (callers report that themselves).
  result = @[]
  if not dirExists(root):
    return
  for path in walkDirRec(root, yieldFilter = {pcFile}):
    if path.endsWith(".test.js"):
      result.add(path)
  result.sort()

proc resolveTestArg*(arg: string; root = "tests"): string =
  ## File-only resolution for `carne test <arg>`. Tries the arg as
  ## given, then under root, then `.test.js` variants. Returns ""
  ## when nothing exists.
  var cands: seq[string] = @[arg]
  cands.add(root / arg)
  if not arg.endsWith(".js"):
    cands.add(root / arg & ".test.js")
    cands.add(arg & ".test.js")
    cands.add(root / arg & ".js")
    cands.add(arg & ".js")
  var seen: seq[string] = @[]
  for c in cands:
    if c in seen:
      continue
    seen.add(c)
    if fileExists(c) and not dirExists(c):
      return c
  ""

proc printHelp*() =
  echo grey("A JavaScript runtime in Nim")
  echo grey("  (c) OpenPeeps | MIT License")
  echo grey("  Build Version: " & versionStr)
  echo ""
  echo "usage: carne <command> [args] [options]"
  echo ""
  echo label("Scripting")
  echo "  run <script.js> [args]  " & grey("run a .js file")
  echo "  test [file] [...]       " & grey("run tests/**/*.test.js (or the given file)")
  echo ""
  echo label("Packages")
  echo "  pkg install <spec>      " & grey("install a package by name, git URL (--url=... pins a source URL)")
  echo "  pkg remove <name> [ver] " & grey("uninstall a package (one version, or all)")
  echo "  pkg update [name]       " & grey("update one package, or all when omitted")
  echo "  pkg list                " & grey("list installed packages")
  echo "  pkg develop <path>      " & grey("editable install from a local directory")
  echo "  pkg prune               " & grey("remove orphaned packages")
  echo "  pkg refresh             " & grey("re-download registry data")
  echo "  pkg publish [opts]      " & grey("open a PR adding this package to the registry")
  echo ""
  echo "  -h, --help              " & grey("show this help")
  echo "  --version               " & grey("show version")
