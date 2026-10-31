# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "JavaScript runtime on JavaScriptCore"
license       = "MIT"
srcDir        = "src"
bin           = @["carne"]
binDir        = "bin"


# Dependencies

requires "nim >= 2.2.10"
requires "datpkgr >= 0.1.12"
requires "javascriptcore >= 0.1.0"

requires "nimcypher >= 0.2.5"
requires "openparser >= 0.4.1"
requires "mimedb >= 0.1.4"
requires "powpow >= 0.2.4"
requires "semver >= 1.2.3"
