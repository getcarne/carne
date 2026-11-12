# Carne CLI styling (mirrors dfkup's usage/cmd comment style).

import std/[os, strutils, algorithm, atomics, options, terminal]

import ./bridge

func nimbleVersionStr*(spec: string): string =
  ## First `version = "..."` assignment in a .nimble file (comments
  ## skipped, `version` matched as a whole word). "" when absent.
  for raw in spec.splitLines():
    var s = raw.strip()
    if s.len == 0 or s[0] == '#':
      continue
    if not s.startsWith("version"):
      continue
    s = s["version".len .. ^1].strip()
    if not s.startsWith("="):
      continue
    s = s[1 .. ^1].strip()
    if s.len >= 2 and s[0] == '"':
      let q = s.find('"', 1)
      if q > 1:
        return s[1 ..< q]
  ""

const versionStr* = nimbleVersionStr(staticRead("../../carne.nimble"))
  ## Binary version, always from carne.nimble (compile-time, so the
  ## CLI, help text and std tag resolution can never drift).

static:
  assert versionStr.len > 0, "carne.nimble has no parseable `version`"

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
  ## TTY-gated, unless the CLI --isatty flag says otherwise. No env
  ## vars: color control lives at the CLI level.
  if colorTtyOverride.isSome:
    return colorTtyOverride.get
  isatty(stdout)

proc paint*(s, code: string): string =
  if useColor():
    code & s & ansiReset
  else:
    s

proc label*(s: string): string =
  paint(s, ansiBoldWhite)

proc grey*(s: string): string =
  paint(s, ansiGrey)

proc cmdHelp*(cmd, comment: string) =
  ## One command row for the usage screens: two-space indent, comment
  ## column at 28. Adding a command is one line; flags hang off it via
  ## flagHelp below.
  let pad = max(0, 24 - cmd.len)
  echo "  " & cmd & " ".repeat(pad) & "  " & grey(comment)

proc flagHelp*(flag, comment: string) =
  ## One flag row nested under a command: four-space indent, same
  ## comment column as command rows, so flags read as part of the
  ## command above them.
  let pad = max(0, 22 - flag.len)
  echo "    " & flag & " ".repeat(pad) & "  " & grey(comment)

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

var spinAlive: Atomic[bool]
  ## Set while a spinner thread animates. Display procs clear the
  ## spinner row before printing so progress lines never interleave
  ## with the animation.

proc spinnerActive*(): bool =
  ## True while a spinner animates on this process.
  spinAlive.load(moRelaxed)

proc isTty*(): bool =
  ## True when stdout is a terminal (banners and animation gate on
  ## this; pipes get plain output).
  stdout.isatty()

const bannerArt = """
[0;91;41m█▓[0;90m▀[0;31m▀██[0;37m [0;91;41m█▓[0;90m▀[0;31m▀[0;91;41m  [0;37m [0;91;41m█▓[0;90m▀[0;31m▀[0;91;41m  [0;37m [0;91;41m█▓[0;90m▀[0;31m▀[0;91;41m  [0;37m [0;91;41m█▓[0;90m▀[0;31m▀██[0m
[0;91;41m▓▒[0;37m     [0;91;41m▓▒[0;97m  [0;91;41m ░[0;37m [0;91;41m▓▒[0;90m▄[0;31m▄[0;91;41m ░[0;37m [0;91;41m▓▒[0;97m  [0;91;41m ░[0;37m [0;91;41m▓▒[0;37m    [0m
[0;91;41m▒░[0;37m     [0;91;41m▒░[0;90m▀[0;31m▀[0;91;41m░▒[0;37m [0;91;41m▒░[0;90m▀[0;31m▄[0;37m   [0;91;41m▒░[0;97m  [0;91;41m░▒[0;37m [0;91;41m▒░[0;90m▀[0;37m   [0m
[0;91;41m░ [0;37m     [0;91;41m░ [0;97m  [0;91;41m▒▓[0;37m [0;91;41m░ [0;97m  [0;91;41m▒▓[0;37m [0;91;41m░ [0;97m  [0;91;41m▒▓[0;37m [0;91;41m░ [0;37m    [0m
[0;91;41m  [0;90m▄[0;31m▄[0;91;41m▓[0;91m█[0;37m [0;91;41m  [0;97m  [0;91;41m▓█[0;37m [0;91;41m  [0;97m  [0;91;41m▓█[0;37m [0;91;41m  [0;97m  [0;91;41m▓█[0;37m [0;91;41m  [0;90m▄[0;31m▄[0;91;41m▓█[0m
    """

proc printBanner*() =
  ## Carne ASCII banner. TTY only: raw ANSI art stays off pipes.
  if isTty():
    echo bannerArt

proc clearSpinLine() =
  ## Erases the in-progress spinner row. No-op without a spinner.
  if spinnerActive():
    stdout.write("\r\e[K")
    stdout.flushFile()

proc display*(xs: varargs[Span]) =
  ## Prints one plain row of fragments.
  clearSpinLine()
  echo spansToStr(xs)

proc displayError*(x: string) =
  ## Prints an error message.
  clearSpinLine()
  echo paint("Error:", ansiRed) & " " & x

proc displayError*(xs: varargs[Span]) =
  ## Prints an error message from fragments.
  clearSpinLine()
  echo paint("Error:", ansiRed) & " " & spansToStr(xs)

proc displayWarning*(x: string) =
  ## Prints a warning message.
  clearSpinLine()
  echo paint("Warning:", ansiYellow) & " " & x

proc displayWarning*(xs: varargs[Span]) =
  ## Prints a warning message from fragments.
  clearSpinLine()
  echo paint("Warning:", ansiYellow) & " " & spansToStr(xs)

proc displayInfo*(x: string) =
  ## Prints an informational message.
  clearSpinLine()
  echo paint("Info:", ansiCyan) & " " & x

proc displayInfo*(xs: varargs[Span]) =
  ## Prints an informational message from fragments.
  clearSpinLine()
  echo paint("Info:", ansiCyan) & " " & spansToStr(xs)

proc displaySuccess*(x: string) =
  ## Prints a success message.
  clearSpinLine()
  echo paint("Success:", ansiGreen) & " " & x

proc displaySuccess*(xs: varargs[Span]) =
  ## Prints a success message from fragments.
  clearSpinLine()
  echo paint("Success:", ansiGreen) & " " & spansToStr(xs)

const spinFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  ## Braille spinner frames (kapsis preloader style, dependency-free).

type SpinArgs = object
  msg: string
  colored: bool

proc spinLoop(a: SpinArgs) {.thread.} =
  ## Spinner thread: redraws one row until `spinAlive` drops.
  var i = 0
  while spinAlive.load(moRelaxed):
    let frame =
      if a.colored: ansiCyan & spinFrames[i] & ansiReset
      else: spinFrames[i]
    stdout.write("\r" & frame & " " & a.msg)
    stdout.flushFile()
    sleep(80)
    i = (i + 1) mod spinFrames.len

type Spinner* = object
  thread: Thread[SpinArgs]
  running*: bool

proc startSpinner*(msg: string): Spinner =
  ## Animates `msg` on a TTY. Idle otherwise (callers fall back to
  ## plain log lines, which the datpkgr callback already emits).
  if not isTty():
    return Spinner(running: false)
  spinAlive.store(true, moRelaxed)
  try:
    createThread(result.thread, spinLoop,
      SpinArgs(msg: msg, colored: useColor()))
    result.running = true
  except CatchableError:
    spinAlive.store(false, moRelaxed)

proc stopSpinner*(s: var Spinner) =
  ## Stops the animation and erases the spinner row.
  if not s.running:
    return
  s.running = false
  spinAlive.store(false, moRelaxed)
  joinThread(s.thread)
  stdout.write("\r\e[K")
  stdout.flushFile()

template withSpinner*(msg: string; body: untyped): untyped =
  ## Runs body while `msg` animates on a TTY (plain log lines
  ## otherwise). Exceptions propagate after the spinner stops.
  block:
    var spinState = startSpinner(msg)
    try:
      body
    finally:
      stopSpinner(spinState)

proc confirm*(question: string): bool =
  ## y/N prompt, default no. False when stdin is not a TTY or on
  ## EOF, so scripts and pipes never confirm destructively.
  if not stdin.isatty():
    return false
  stdout.write(question & " [y/N]: ")
  stdout.flushFile()
  try:
    result = stdin.readLine().strip().toLowerAscii() in ["y", "yes"]
  except EOFError, IOError:
    result = false

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
  printBanner()
  echo grey("A JavaScript runtime in Nim")
  echo grey("  (c) OpenPeeps | MIT License")
  echo grey("  Build Version: " & versionStr)
  echo ""
  echo "usage: carne <command> [args] [options]"
  echo ""
  echo label("Scripting:")
  cmdHelp("run <script.js> [args]", "run a .js file")
  cmdHelp("test [file] [...]", "run tests/**/*.test.js (or the given file)")
  echo ""
  echo label("Standard library:")
  cmdHelp("std init", "download JS stdlib (std/*) into ~/.carne/std")
  cmdHelp("std update", "refresh all JS stdlib files")
  cmdHelp("std list", "show installed JS stdlib version and files")
  echo ""
  echo label("Packages:")
  cmdHelp("pkg install <spec>",
    "install a package by name, git URL, gh:user/repo alias, name#ref, or name + source URL")
  flagHelp("--url:<url>", "pin a source URL")
  cmdHelp("pkg remove <name> [ver]", "uninstall one version, or all")
  flagHelp("--yes", "skip confirmation prompts")
  cmdHelp("pkg update [name]", "update one package, or all")
  cmdHelp("pkg list", "list installed packages")
  cmdHelp("pkg develop [path]", "editable install from a local directory")
  cmdHelp("pkg prune", "remove orphaned packages")
  flagHelp("--yes", "skip confirmation prompts")
  cmdHelp("pkg refresh", "re-download registry data")
  cmdHelp("pkg publish", "open a PR adding this package to the registry")
  flagHelp("--tags:<list>", "comma-separated tags")
  flagHelp("--web:<url>", "package website URL")
  flagHelp("--url:<url>", "pin a source URL")
  flagHelp("--dry-run", "no network, git, or secret changes")
  flagHelp("--yes", "skip confirmation prompts")
  echo ""
  echo label("Versioning:")
  cmdHelp("bump [semver]", "bump version in package.json (or a direct dep)")
  flagHelp("--level:<level>", "major, minor, or patch")
  flagHelp("--dep:<name>", "bump a direct dependency spec (prefix kept)")
  cmdHelp("upgrade [version]", "self-update carne from GitHub releases (into ~/.carne/bin)")
  flagHelp("--dry-run", "print resolved URLs only, no changes")
  echo ""
  echo label("Inspect:")
  cmdHelp("dump [pkg[@ref]]", "print package.json (cwd or an installed package)")
  echo ""
  echo label("options:")
  flagHelp("--isatty:<true|false>", "override TTY detection (default: auto-detect)")
  cmdHelp("-h, --help", "show this help")
  cmdHelp("--version", "show version")
