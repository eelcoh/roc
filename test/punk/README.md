# punkroc's platform

A small platform for punkroc programs such as Advent of Code solutions:

| Module | Functions |
|--------|-----------|
| `Stdout` | `line! : Str => {}`, `write! : Str => {}` |
| `Stderr` | `line! : Str => {}` |
| `Stdin` | `line! : () => Str` (one line, empty at the end), `readAll! : () => Str` |
| `File` | `read! : Str => Result Str [FileErr Str]`, `write! path text` |
| `Arg` | `list! : () => List Str` (the arguments after the program's name) |

```
app [main!] { pf: platform "../../../test/punk/platform/main.roc" }

import pf.Stdout
import pf.File
import pf.Arg

main! = fn () ->
    case Arg.list! () of
        [path] ->
            case File.read! path of
                Ok text -> Stdout.line! "${String.fromInt (String.length text)} bytes"
                Err (FileErr msg) -> Stdout.line! msg
        _ ->
            Stdout.line! "give me a file"
```

Build its host once (and after changing `host.zig`), from the repository root:

```
zig build roc
sh test/punk/setup.sh
zig-out/bin/roc examples/punk/aoc2024/Day01.punk input.txt
zig-out/bin/roc examples/punk/platform/io.punk < input.txt
```

`setup.sh` builds the host with `zig build build-test-hosts -Dplatform=punk`
and copies it, with the C runtime of the `fx` test platform, into
`platform/targets/` (which git ignores). It lives under `test/` because the
build makes hosts for the platforms there. Writing files does not work on
Windows yet.
