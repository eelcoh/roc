# punkroc's cli platform

The platform for punk command-line programs, such as Advent of Code
solutions. Its host is written in Rust, on [ambit](https://github.com/eelcoh/ambit)'s
`cli` platform and capabilities.

| Module | Functions |
|--------|-----------|
| `Stdout` | `line! : Str => {}`, `write! : Str => {}` |
| `Stderr` | `line! : Str => {}` |
| `Stdin` | `line! : () => Str` (one line, empty at the end), `readAll! : () => Str` |
| `File` | `read! : Str => Result Str [FileErr Str]`, `write! path text`, only for files named on the command line |
| `Arg` | `list! : () => List Str` (the arguments after the program's name) |
| `Clock` | `now! : () => I64` (milliseconds since 1970), `elapsed! : () => I64` (milliseconds since the start) |
| `Random` | `u64! : () => U64` (64 random bits from the OS) |

```
app [main!] { pf: platform "../../platforms/cli/main.roc" }

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

## Only the files you name

A punk program can read and write only the files named on its command line,
as with ambit's `Named` capability: `punk app.punk input.txt` lets the program
use `input.txt`, and a path it makes up itself gives `Err (FileErr ...)`. So
the person who types the command decides what the program touches, not the
program. A file is read whole and must be UTF-8 text; a write replaces the
file all at once (after a crash it has its old or its new text).

## Building

Needs Zig 0.17.1 (for the compiler) and Rust (for the host, the version in
`host/rust-toolchain.toml`; with rustup it is installed by itself). From the
repository root:

```
zig build roc
sh test/punk/setup.sh
zig-out/bin/punk examples/punk/aoc2024/Day01.punk input.txt
zig-out/bin/punk examples/punk/platform/io.punk < input.txt
```

`setup.sh` builds `host/` with cargo for this computer and copies it into
`targets/<target>/libhost.a` (which git ignores). On Linux the program is
static (musl): `setup.sh` also copies the C runtime and unwinder that Rust
ships for musl. macOS should work (`libhost.a` and the app are all it needs)
but has not been tried yet; Windows has no host yet.

## How the host fits together

```
 app.punk ─ punk → Roc → roc ─▶ app.o       (the app: no I/O of its own)
                                  │  calls roc_alloc, roc_stdout_line, ...
                                  ▼  is called as roc_main
 host/ (Rust, staticlib) ─────▶ libhost.a   main(): ambit_cli_native::run(PunkApp)
                                  │
            ambit: ambit-cli, ambit-cli-native, ambit-caps, ambit-caps-dir(-native)
```

- `main.roc` and the other `.roc` files: the platform's API, what a punk app
  sees. `hosted { ... }` maps each effect to the C symbol the host exports.
- `host/src/lib.rs`: the exported symbols (`main`, the six runtime functions
  `roc_alloc` ... `roc_crashed`, and one per effect), and the wiring: the
  punk app is an `ambit_cli::App`, run by ambit's native backend.
- `host/src/platform.rs`: what each effect does, in safe Rust on ambit's
  capabilities (`Clock`, `Random`, `Dir` through `Named<OneFile>`, `DirModify`).
- `host/src/roc.rs`: Roc's `Str`, `List` and `Try` as the app lays them out,
  the allocator and the refcounts. The only code that reads raw memory. It
  mirrors the compiler's `src/builtins/str.zig`, `list.zig` and `utils.zig`
  (`allocateWithRefcount`, `decref`) and `host_abi.zig`. If an upstream merge
  changes those, the golden tests fail; change this file to match.

At the end of a run the host checks that every byte the app allocated was
freed, and says so on stderr when not.

### ambit and punkroc

Neither repository depends on the other's build. `host/Cargo.toml` uses
ambit's crates as a Rust library, pinned to one commit of `eelcoh/ambit`
(and `Cargo.lock`); the compiler never sees Rust, and ambit does not know punk
exists. To move to a newer ambit, change `rev` in `host/Cargo.toml` and run
`cargo update` in `host/`. To try a local checkout of ambit, add to
`host/Cargo.toml`:

```
[patch."https://github.com/eelcoh/ambit"]
ambit-caps = { path = "../../../../ambit/caps/api" }
ambit-caps-dir = { path = "../../../../ambit/caps/dir" }
ambit-caps-dir-native = { path = "../../../../ambit/caps/dir-native" }
ambit-cli = { path = "../../../../ambit/platforms/cli/api" }
ambit-cli-native = { path = "../../../../ambit/platforms/cli/native" }
```

The next platforms (`server`, `tui`) are made the same way: a folder under
`platforms/` with the `.roc` API and a Rust `host/` on the matching ambit
platform.
