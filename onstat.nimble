# Package

version       = "0.1.0"
author        = "osmarks"
description   = "Monitor the existence/status of your networked things."
license       = "MIT"
srcDir        = "src"
bin           = @["onstat"]

# Dependencies

requires "nim >= 1.4.2"
requires "https://github.com/GULPF/tiny_sqlite#8fe760d9"
requires "karax >= 1.2.1"