# Carne - a JavaScript runtime on JavaScriptCore (macOS + Linux).
#
# Library API: runCode / runFile from ./carne/runtime.
# CLI: `carne run <script.js> [args]`, --help, --version.

import ./carne/runtime
export runtime

when isMainModule:
  import std/[algorithm, options, os, parseopt, strutils]

  import ./carne/cli
  import ./carne/modules
  import ./carne/std/all
  import ./carne/pkg/pkgman
  import ./carne/pkg/init
  import ./carne/pkg/publish
  import ./carne/pkg/bump
  import ./carne/pkg/dump
  import ./carne/pkg/upgrade
  import ./carne/pkg/loader
  import ./carne/pkg/stdsync

  proc runScriptFile(filePath: string; extraArgs: seq[string]): int =
    ## Execute JS from a file
    initPkgLoaderLazy()
    initStdDispatcher()
    try:
      let res = runFileEx(filePath, extraArgs)
      return res.code
    except CarneError as e:
      displayError(e.msg)
      return 1
    except IOError as e:
      displayError(e.msg)
      return 1

  proc printPkgHelp() =
    echo "usage: carne pkg <command> [args] [options]"
    echo ""
    cmdHelp("init [dir]",
      "scaffold a new package (wizard, -Y skips it)")
    flagHelp("--yes, -Y", "skip the wizard, use defaults")
    cmdHelp("install <spec>",
      "registry name, git URL, gh:user/repo alias, name#ref, or name + source URL")
    flagHelp("--url:<url>", "pin a source URL")
    cmdHelp("remove <name> [ver]", "uninstall one version, or all")
    flagHelp("--yes", "skip confirmation prompts")
    cmdHelp("update [name]", "update one package, or all")
    cmdHelp("list", "list installed packages")
    cmdHelp("develop [path]",
      "editable install from a local directory (default: current dir)")
    cmdHelp("prune", "remove orphaned packages")
    flagHelp("--yes", "skip confirmation prompts")
    cmdHelp("refresh", "re-download registry data")
    cmdHelp("publish", "open a PR adding this package to the registry")
    flagHelp("--tags:<list>", "comma-separated tags")
    flagHelp("--web:<url>", "package website URL")
    flagHelp("--url:<url>", "pin a source URL")
    flagHelp("--dry-run", "no network, git, or secret changes")
    flagHelp("--yes", "skip confirmation prompts")

  proc runPkg(args: seq[string], pkgUrl, pkgTags, pkgWeb: string,
      pkgDryRun, pkgYes: bool): int =
    ## Package management on the ~/.carne home (CARNE_HOME overrides).
    if args.len == 0:
      printPkgHelp()
      return 1
    let cfg = newCarnePkgConfig()
    case args[0]
    of "init":
      if args.len > 2:
        displayError("usage: carne pkg init [dir] [--yes]")
        return 1
      let target = if args.len == 2: args[1] else: ""
      return initCommand(getCurrentDir(), target, pkgYes)
    of "install":
      if args.len < 2:
        displayError("package name or URL is required")
        printPkgHelp()
        return 1
      if args.len > 2:
        displayError("only one package allowed")
        return 1
      try:
        withSpinner("Installing packages..."):
          if cfg.pkgInstall(args[1], url = pkgUrl):
            return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "remove", "uninstall":
      if args.len < 2:
        displayError("package name is required")
        printPkgHelp()
        return 1
      if args.len > 3:
        displayError("usage: carne pkg remove <name> [version] [--yes]")
        return 1
      let version = if args.len > 2: args[2] else: ""
      let what = args[1] & (if version.len > 0: "@" & version
        else: " (all versions)")
      if not pkgYes and not confirm("Remove " & what & "?"):
        displayInfo("aborted")
        return 1
      try:
        if cfg.pkgRemove(args[1], version):
          return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "update":
      if args.len > 2:
        displayError("usage: carne pkg update [name]")
        return 1
      let name = if args.len > 1: args[1] else: ""
      try:
        withSpinner("Updating packages..."):
          if cfg.pkgUpdate(name):
            return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "list":
      try:
        cfg.pkgList()
        return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "develop":
      if args.len > 2:
        displayError("usage: carne pkg develop [path]")
        return 1
      let dir = if args.len == 2: args[1] else: getCurrentDir()
      try:
        if cfg.pkgDevelop(dir):
          return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "prune":
      if not pkgYes and not confirm("Prune orphaned packages?"):
        displayInfo("aborted")
        return 1
      try:
        withSpinner("Pruning orphaned packages..."):
          cfg.pkgPrune()
        return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "refresh":
      try:
        withSpinner("Refreshing registry..."):
          if cfg.refreshAllSources():
            return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "publish":
      if args.len > 1:
        displayError("usage: carne pkg publish [--tags=..] [--web=..] [--url=..] [--dry-run] [--yes]")
        return 1
      return publishCommand(getCurrentDir(), (tags: pkgTags, web: pkgWeb,
        urlOverride: pkgUrl, dryRun: pkgDryRun, yesMode: pkgYes))
    else:
      displayError("unknown pkg command `" & args[0] & "`")
      printPkgHelp()
      return 1

  proc runTestFiles(files: seq[string]): int =
    ## Runs each test file in a fresh runtime (std/test owns
    ## semantics; the driver only isolates and summarizes).
    var failedFiles: seq[string] = @[]
    for f in files:
      display(span(grey("# " & f)))
      if runScriptFile(f, @[]) == 0:
        discard
      else:
        failedFiles.add(f)
    if files.len > 1:
      if failedFiles.len == 0:
        displaySuccess("pass " & $files.len & "/" & $files.len & " files")
      else:
        displayError("fail " &
          $(files.len - failedFiles.len) & "/" & $files.len &
          " files: " & failedFiles.join(", "))
    if failedFiles.len == 0: 0 else: 1

  proc runTestCommand(args: seq[string]): int =
    ## `carne test` runs tests/**/*.test.js; `carne test <file>`
    ## runs the given test module (file-only).
    if args.len == 0:
      let files = findTestFiles("tests")
      if files.len == 0:
        if not dirExists("tests"):
          displayError("no tests/ directory found")
        else:
          displayError("no test files found (tests/**/*.test.js)")
        return 1
      return runTestFiles(files)
    var files: seq[string] = @[]
    for a in args:
      let f = resolveTestArg(a)
      if f == "":
        displayError("test file not found: `" & a & "`")
        return 1
      files.add(f)
    return runTestFiles(files)

  proc runBump(args: seq[string]; level, dep, missing: string): int =
    ## `carne bump [semver] [--level=..] [--dep=..]`: semver bumps for
    ## the local package.json (or one direct dependency with --dep).
    if missing.len > 0:
      displayError("option --" & missing & " needs a value")
      return 1
    if args.len > 1:
      displayError("usage: carne bump [semver] " &
        "[--level=major|minor|patch] [--dep=name]")
      return 1
    let v = if args.len == 1: args[0] else: ""
    bumpCommand(getCurrentDir(), v, level, dep)

  proc runDump(args: seq[string]): int =
    ## `carne dump [pkg[@ref]]`: print a package.json (cwd or store).
    if args.len > 1:
      displayError("usage: carne dump [pkg[@ref]]")
      return 1
    let spec = if args.len == 1: args[0] else: ""
    dumpCommand(getCurrentDir(), spec)

  proc runUpgrade(args: seq[string]; dryRun: bool): int =
    ## `carne upgrade [version]`: self-update from GitHub releases
    ## into ~/.carne/bin.
    if args.len > 1:
      displayError("usage: carne upgrade [version] [--dry-run]")
      return 1
    let v = if args.len == 1: args[0] else: ""
    upgradeCommand(v, dryRun = dryRun)

  proc printStdHelp() =
    echo "usage: carne std <init|update|list>"
    echo ""
    echo "  init                        " & grey("download JS stdlib (std/*) into ~/.carne/std")
    echo "  update                      " & grey("refresh all JS stdlib files")
    echo "  list                        " & grey("show all std modules (built-in and JS)")

  proc runStd(args: seq[string]): int =
    ## Standard library inventory: Nim modules are embedded in the
    ## binary (built-in), JS modules live in the ~/.carne home
    ## (`carne std init` downloads them; CARNE_HOME overrides).
    if args.len == 0:
      printStdHelp()
      return 1
    case args[0]
    of "init", "update":
      if args.len > 1:
        displayError("usage: carne std <init|update>")
        return 1
      try:
        let r = stdSync()
        if r.upToDate:
          displayInfo("std " & r.version & " (" & r.refUsed &
            "): already up to date")
        elif r.count == 0:
          displaySuccess("std " & r.version & " (" & r.refUsed &
            "): manifest updated, files unchanged")
        else:
          displaySuccess("std " & r.version & " (" & r.refUsed & "): " &
            $r.count & " files in " & stdJsStore())
        return 0
      except CatchableError as e:
        displayError(e.msg)
      return 1
    of "list":
      if args.len > 1:
        displayError("usage: carne std list")
        return 1
      let s = stdStatus()
      if s.found:
        let at = if s.refUsed.len > 0: " (" & s.refUsed & ")" else: ""
        displayInfo("std " & s.version & at & ":")
      else:
        displayInfo("std (no JS stdlib installed, run `carne std init`):")
      for name in registeredStdNames():
        display(span("  " & name & "  " & grey("(built-in)")))
      if s.found:
        var names: seq[string] = @[]
        for e in s.entries:
          names.add(e.name)
        for name in sorted(names):
          for e in s.entries:
            if e.name == name:
              let mark = if e.present: "installed" else: "missing"
              display(span("  std/" & e.name & "  " &
                grey(e.file & " (" & mark & ")")))
      return 0
    else:
      displayError("unknown std command `" & args[0] & "`")
      printStdHelp()
      return 1

  proc main(): int =
    var command = ""
    var positionals: seq[string] = @[]
    var showHelp = false
    var showVersion = false
    var pkgUrl = ""
    var pkgTags = ""
    var pkgWeb = ""
    var pkgDryRun = false
    var pkgYes = false
    var bumpLevel = ""
    var bumpDep = ""
    var bumpPending = ""
    var bumpMissing = ""
    var isattyFlag = ""
    var hasIsatty = false
    var p = initOptParser(commandLineParams())
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        if bumpPending.len > 0:
          case bumpPending
          of "level": bumpLevel = key
          of "dep": bumpDep = key
          else: discard
          bumpPending = ""
        elif command == "":
          command = key
        else:
          positionals.add(key)
      of cmdLongOption, cmdShortOption:
        if bumpPending.len > 0:
          # `--level`/`--dep` with no value before the next option.
          bumpMissing = bumpPending
          bumpPending = ""
        case key
        of "help", "h":
          showHelp = true
        of "version":
          showVersion = true
        of "url":
          pkgUrl = val
        of "tags":
          pkgTags = val
        of "web":
          pkgWeb = val
        of "dry-run":
          pkgDryRun = true
        of "yes", "Y":
          pkgYes = true
        of "level":
          if val.len > 0:
            bumpLevel = val
          else:
            bumpPending = "level"
        of "dep":
          if val.len > 0:
            bumpDep = val
          else:
            bumpPending = "dep"
        of "isatty":
          # --isatty=true|false (bare --isatty means true): overrides
          # TTY detection for this run's output, CLI and std/terminal.
          hasIsatty = true
          isattyFlag = val
        else:
          displayError("unknown option --" & key)
          printHelp()
          return 1
      of cmdEnd:
        discard
    if bumpPending.len > 0:
      bumpMissing = bumpPending
      bumpPending = ""
    if hasIsatty:
      case isattyFlag
      of "", "true":
        colorTtyOverride = some(true)
      of "false":
        colorTtyOverride = some(false)
      else:
        displayError("option --isatty needs true or false")
        printHelp()
        return 1
    if showVersion:
      echo versionStr
      return 0
    if showHelp:
      printHelp()
      return 0
    if command == "":
      printHelp()
      return 0
    case command
    of "run":
      # run a .js script file
      if positionals.len == 0:
        displayError("script is required")
        printHelp()
        return 1
      let script = positionals[0]
      let extra = if positionals.len > 1: positionals[1 .. ^1] else: @[]
      return runScriptFile(script, extra)
    of "pkg":
      # package management on the ~/.carne home
      return runPkg(positionals, pkgUrl, pkgTags, pkgWeb, pkgDryRun, pkgYes)
    of "bump":
      # local semver bumps for package.json (or one direct dep)
      return runBump(positionals, bumpLevel, bumpDep, bumpMissing)
    of "dump":
      # print a package.json (cwd upward, or an installed package)
      return runDump(positionals)
    of "upgrade":
      # self-update from GitHub releases into ~/.carne/bin
      return runUpgrade(positionals, pkgDryRun)
    of "test":
      # test runner over tests/**/*.test.js
      return runTestCommand(positionals)
    of "std":
      # JS-based standard library management
      return runStd(positionals)
    else:
      # default command: a bare script path runs like `run <script>`
      if positionals.len >= 0 and fileExists(command):
        return runScriptFile(command, positionals)
      displayError("unknown command `" & command & "`")
      printHelp()
      return 1

  quit(main())
