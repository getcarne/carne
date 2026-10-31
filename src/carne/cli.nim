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
  ansiGreen = "\e[32m"
  ansiYellow = "\e[33m"
  ansiCyan = "\e[36m"

type Span* = tuple[text: string, code: string]
  ## One colored fragment for the display procs (kapsis-style, without
  ## the termstyle dependency). code "" renders plain.

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

proc span*(text: string, code = ""): Span =
  ## Builds one display fragment (code "" for plain text).
  (text, code)

proc spansToStr*(xs: openArray[Span]): string =
  ## Renders fragments back to back (callers embed their own spaces).
  ## Empty codes pass through untouched (no stray reset sequences).
  for x in xs:
    if x.code.len == 0:
      result.add(x.text)
    else:
      result.add(paint(x.text, x.code))

proc display*(xs: varargs[Span]) =
  ## Prints one plain row of fragments.
  echo spansToStr(xs)

proc displayError*(x: string) =
  ## Prints an error message.
  echo paint("Error:", ansiRed) & " " & x

proc displayError*(xs: varargs[Span]) =
  ## Prints an error message from fragments.
  echo paint("Error:", ansiRed) & " " & spansToStr(xs)

proc displayWarning*(x: string) =
  ## Prints a warning message.
  echo paint("Warning:", ansiYellow) & " " & x

proc displayWarning*(xs: varargs[Span]) =
  ## Prints a warning message from fragments.
  echo paint("Warning:", ansiYellow) & " " & spansToStr(xs)

proc displayInfo*(x: string) =
  ## Prints an informational message.
  echo paint("Info:", ansiCyan) & " " & x

proc displayInfo*(xs: varargs[Span]) =
  ## Prints an informational message from fragments.
  echo paint("Info:", ansiCyan) & " " & spansToStr(xs)

proc displaySuccess*(x: string) =
  ## Prints a success message.
  echo paint("Success:", ansiGreen) & " " & x

proc displaySuccess*(xs: varargs[Span]) =
  ## Prints a success message from fragments.
  echo paint("Success:", ansiGreen) & " " & spansToStr(xs)

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
  echo label("Standard library")
  echo "  std init                " & grey("download JS stdlib (std/*) into ~/.carne/std")
  echo "  std update              " & grey("refresh all JS stdlib files")
  echo "  std list                " & grey("show installed JS stdlib version and files")
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
