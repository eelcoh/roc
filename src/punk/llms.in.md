# punkroc (punk)

> punkroc ("punk") is an Elm-like language on top of the Roc compiler: Elm's
> syntax, names and argument order, Roc's types, platforms and speed. Files end
> in `.punk`. This file is everything you need to write punk programs.

If you know Elm, write Elm and read the section "Differences from Elm".
Everything not listed there works as in Elm.

## Tools

The `punk` command is the Roc compiler (`zig-out/bin/punk`, also `roc`).

| Command | What it does |
|---------|--------------|
| `punk check --json app.punk` | Type-check without building. Problems as JSON on stdout (see "Errors"). Exit code 1 when there are errors. Fast (under a second). |
| `punk fmt app.punk ...` | Lay files out in the one canonical form. `--check` only lists files that are not formatted. |
| `punk app.punk [args]` | Build and run the app. |
| `punk test app.punk` | Run the `expect` tests in the file. |

Work in this loop: write the file, `punk fmt` it, `punk check --json` it, fix
the first problem, repeat; then run it. Fix problems from the top: a later one
is often caused by an earlier one.

## A program

```
app [main!] { pf: platform "../../test/punk/platform/main.roc" }

import pf.Stdout

main! = fn () ->
    Stdout.line! "Hello"
```

The path after `platform` is relative to the `.punk` file; it points to
`test/punk/platform/main.roc` in the punkroc repository. A file is an `app`
(it has `main!`) or a `module` (see "Modules").

## Syntax

```
-- a line comment
{- a block comment -}
{-| a doc comment, before a definition -}

answer : Int                      -- type annotation, then the definition
answer = 42

add : Int -> Int -> Int           -- functions are curried, as in Elm
add = fn a, b ->                  -- a lambda: `fn` params `->` body
    a + b

inc = add 1                       -- partial application
twice = fn f, x -> f (f x)        -- application by spaces: `f a b`, never `f(a, b)`

area = fn shape ->
    case shape of                 -- `case ... of`, as in Elm
        Circle r -> 3.14 * r * r
        Rect w h -> w * h

sign = fn n ->
    if n < 0 then -1 else if n == 0 then 0 else 1
```

Indentation is significant (4 spaces per level; tabs are an error). A body
on the next line is a block: any number of `name = value` lines and then the
result. There is no `let ... in`:

```
distance = fn a, b ->
    dx = a.x - b.x
    dy = a.y - b.y
    F64.sqrt (dx * dx + dy * dy)
```

Pipelines go line by line. `x |> f a` is `f a x`: the value goes last.

```
total =
    input
        |> String.lines
        |> List.map String.trim
        |> List.filter (fn line -> not (String.isEmpty line))
        |> List.length
```

### Values

| Kind | Syntax |
|------|--------|
| numbers | `42`, `-3`, `3.14`, `0xff`, `1_000_000` |
| strings | `"text"`, interpolation `"n = ${String.fromInt n}"` (only a `Str` goes inside `${}`), `"""` multi-line `"""` |
| characters | `'a'` |
| lists | `[1, 2, 3]`, `xs ++ ys` |
| tuples | `(1, "a")`; fields `.0`, `.1`: `pair.0`, `List.map .0 pairs` |
| records | `{ name = "Ann", age = 7 }`, `person.name`, `.name` (accessor function), update `{ person | age = 8 }`, field punning `{ name, age }` |
| tags | `Red`, `Circle 2.0`, `Ok 1`, `Err (BadLine line)`, `Just x`, `Nothing` |
| unit | `()` (argument of `main!` and other effects with no input), `{}` (empty record, the result of an effect such as `Stdout.line!`) |

### Operators

`+ - * /` (`/` on floats), `//` (integer division), `%` (remainder),
`== /= < <= > >=`, `&& ||`, `not x`, `++` (lists and strings), `|>`, `<|`.
A range of numbers is `List.range 1 5` (`[1, 2, 3, 4, 5]`). Dividing an
integer by zero gives 0, as in Elm.

### Types

```
type Shape = Circle Float | Rect Float Float     -- a union (custom type)

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)

type alias Point = { x : Int, y : Int }         -- a record type

parse : Str -> Result (List Int) _              -- `_`: let the compiler infer it
```

Builtin types: `Int` (64-bit, `I64`), `Float` (`F64`), `Bool` (`True`,
`False`), `Str`, `List a`, `Dict k v`, `Set a`, `Maybe a` (`Just a |
Nothing`), `Result ok err` (`Ok ok | Err err`), `Order` (`LT | EQ | GT`), and
Roc's sized numbers `U8 U16 U32 U64 I8 I16 I32 I64 F32 F64 Dec`.

Your own types, tuples, records, lists and strings support `==` and can be
`Dict` keys and `Set` members: `Dict (Int, Int) Int` is the usual grid.

### Numbers and characters

A number literal gets its type from where it is used; give a top-level
value an annotation (`total : U64`) when it matters. `Int` and `I64` are the
same type, as are `Float` and `F64`. Convert between sized numbers with the
functions of the source type:

| From to | Function |
|---------|----------|
| `U64` to `Int`, `Int` to `U64` | `toInt n`, `fromInt n` |
| always fits (`U8` to `I64`, `I32` to `I64`, ...) | `U8.toI64 b`, `I32.toI64 n` |
| may not fit | `I64.toU8Try n` (a `Result`), or `I64.toU8Wrap n` (wraps around) |
| to and from text | `I64.toStr n`, `U64.fromStr s` (a `Result`), `String.fromInt`, `String.toInt` (a `Maybe`) |

A character literal `'a'` is a number (its code). `Str.toUtf8 s` gives the
bytes of a string as `List U8`, and `'0'` compares with them, so the digit of
a byte `b` is `U8.toI64 (b - '0')`.

### Errors are tags

Errors are tags; you do not have to declare an error type. A function that can
fail returns `Result value _` and makes up the error tags it needs:
`Err (BadLine line)`. A caller matches on them or passes them on with `try`.

### Patterns

In `case`, in lambda parameters and on the left of `=`:

```
case xs of
    [] -> "empty"
    [x] -> "one"
    [first, second, ..] -> "two or more"
    [first, ..rest] -> "first and the rest"

fn (a, b) -> a + b                      -- tuple
fn { x, y } -> x + y                    -- record
case r of
    Ok n if n > 0 -> "positive"         -- guard
    Ok _ -> "not positive"
    Err (BadLine line) -> line
    Err _ -> "other error"
```

### Errors with `try`

`try` before a call that returns a `Result` unwraps an `Ok`, or returns the
`Err` from the enclosing function at once:

```
parseLine : Str -> Result (I64, I64) _
parseLine = fn line ->
    case String.split "," line of
        [a, b] -> Ok (try I64.fromStr a, try I64.fromStr b)
        _ -> Err (BadLine line)

parseAll : Str -> Result (List (I64, I64)) _
parseAll = fn text ->
    pairs =
        text
            |> String.lines
            |> try List.mapTry parseLine  -- `try` in a pipeline checks the result
    Ok pairs
```

`try` takes one call (`try f a b`); for more use parentheses:
`try (s |> String.trim |> parse)`. There is no postfix `?`.

### Loops: `fold`

There is no `var`, `for`, `while` or `return`. Use `List.map`, `List.filter`,
recursion, or `fold`:

```
fold xs into 0 with fn x, total -> total + x       -- inline form

xs |> fold into 0 with add                          -- the list from a pipe

fold x in xs into total = 0                         -- block form, one accumulator:
    total + x                                       -- the body is its new value

fold x in xs into count = 0, sum = 0                -- more accumulators: the body is a
    if x > 0 then { count = count + 1, sum = sum + x } else {}
                                                    -- record of the ones that change;
                                                    -- the fold's value is a record of all
```

### Effects

A name ending in `!` does something (prints, reads a file). Call effects only
from other `!` functions; `main!` is the start. Each effect is one line in a
block:

```
main! = fn () ->
    text = Stdin.readAll! ()
    Stdout.line! "read ${String.fromInt (String.length text)} bytes"
```

### Tests

```
expect add 1 2 == 3
```

Top-level `expect`s run with `punk test`. `crash` and `dbg` are only allowed
inside an `expect` (rules P101, P102).

### Modules

```
module Grid exposing (Grid, at, Cell(..))      -- (..) exposes the tags too

import Grid exposing (Grid, at)                -- in another file: Grid.punk next to it
import Grid                                    -- then use Grid.at
```

Everything a module exposes needs a type annotation (rule P201).

## Differences from Elm

| Elm | punk |
|-----|------|
| `\x -> x + 1` | `fn x -> x + 1`, several parameters `fn a, b -> ...` |
| `let a = 1 in a + 2` | a block: `a = 1` on one line, `a + 2` on the next |
| `String` type | `Str` (the module is still `String`: `String.split`) |
| `Int` is JS-sized | `Int` is 64-bit; `List.len`, `List.get`, `List.countIf`, `Dict.len` use `U64` (convert with `toInt` / `fromInt`) |
| `"a" ++ String.fromInt n` | works, but `"a${String.fromInt n}"` is the usual way |
| `Debug.log` | `dbg`, only inside `expect` |
| `Maybe` everywhere | Roc's functions return `Result` (`List.first`, `List.get`, `Dict.get`); the Elm-only ones return `Maybe` (`List.head`, `String.toInt`) |
| `List.filterMap` with `Maybe` | `List.filterMap` keeps the `Ok`s of a function that returns a `Result` |
| `case` on `x :: xs` | list patterns `[x, ..xs]`; `::` does not exist |
| `(+)`, `(::)` | write a lambda: `fn a, b -> a + b` |
| `Html`, `Browser`, `Cmd` | not yet; programs are command-line apps on a platform |
| `port`, `Task` | effects are `!` functions |
| `type alias Model = {...}` | same |
| `/=` | same (`!=` works too; write `/=`) |
| a module per file, `exposing` | same; the file name is the module name |

## Differences from Roc

You may know Roc. punk is Roc with Elm's surface; do not write Roc syntax:

| Roc | punk |
|-----|------|
| `\|a, b\| a + b` | `fn a, b -> a + b` |
| `f(a, b)` | `f a b` |
| `List.map(xs, f)`, `xs.map(f)` | `List.map f xs`, `xs \|> List.map f` |
| `match x { A => 1, B => 2 }` | `case x of` with `A -> 1` lines |
| `if c { a } else { b }` | `if c then a else b` |
| `x?` | `try x` |
| `List.keep_if`, snake_case | `List.filter` (Elm name) or `List.keepIf`; camelCase everywhere |
| `List.walk(xs, 0, \|s, x\| ...)` | `List.foldl (fn x, s -> ...) 0 xs`: the state comes last in the lambda |
| `Shape := [Circle(F64)]` | `type Shape = Circle F64` |
| `# comment` | `-- comment` |
| `var`, `for`, `while`, `return` | `fold`, recursion, `List.*` |

Roc functions without an Elm name exist too, in camelCase, with the value
they work on last: `Str.splitOn "," text`, `List.dropIf`, `U64.toStr n`.
Number functions keep Roc's order: `U64.toStr n`, `U64.fromStr s`,
`I64.toStr n`, `F64.toStr x`, `U64.absDiff a b`, `F64.sqrt x`.

## Errors

`punk check --json` writes one JSON document:

```
{
  "file": "app.punk",
  "errors": 1,
  "warnings": 0,
  "problems": [
    {
      "severity": "error",
      "code": "roc/name-not-in-scope",
      "title": "Name Not In Scope",
      "file": "app.punk",
      "line": 7, "column": 34, "endLine": 7, "endColumn": 44,
      "message": "Nothing is named notDefined in this scope. ...",
      "fix": null
    }
  ]
}
```

Positions are 1-based and in the `.punk` file. `code` is stable:

| Code | Meaning |
|------|---------|
| `P001` | punk syntax error (the message says what was expected) |
| `P101` | `crash` outside an `expect`: return a `Result` or `Maybe` instead |
| `P102` | `dbg` outside an `expect` |
| `P201` | an exposed value of a module has no type annotation |
| `roc/<title>` | a problem the type checker found, such as `roc/type-mismatch`, `roc/name-not-in-scope`, `roc/missing-method` |

Warnings (`severity: "warning"`) do not stop the program. A warning
`roc/unconditional-condition` on `main!` for a value known at compile time
(such as an example input in the file) is harmless.

Some type-checker messages mention Roc syntax (`.toStr()`, `List.len`): read
them as the punk spelling (`String.fromInt`, `List.length`).

## The platform

`test/punk/platform` provides:

```
Stdout.line! : Str => {}             -- prints a line
Stdout.write! : Str => {}            -- prints without a newline
Stderr.line! : Str => {}
Stdin.line! : () => Str              -- one line, "" at the end of the input
Stdin.readAll! : () => Str
File.read! : Str => Result Str [FileErr Str]
File.write! : Str -> Str => Result {} [FileErr Str]   -- path, text
Arg.list! : () => List Str           -- the arguments after the program name
```

Import what you use: `import pf.Stdout`, `import pf.File`, ...

## Standard library

The functions an Elm or Roc programmer reaches for first. The value a
function works on is its last argument, so they fit `|>` and partial
application.

@@stdlib@@

## Cookbook

### Read a file given on the command line, solve, print

The shape of an Advent of Code solution: the example input in the file, the
real input from a file argument. (The cookbook files live in
`examples/punk/aoc2024/`, hence their longer platform path; some use the
`test/fx/platform` test platform, which has `Stdout` too. Use
`test/punk/platform` for your own programs.)

@@example aoc2024/Day01.punk@@

### A grid: `Dict (Int, Int) a`, neighbours, recursion

Written by an agent that had only this file, on the first try.

@@example aoc2024/Day10.punk@@

### Folds

@@example fold.punk@@

### Elm's names

@@example elm.punk@@

### Standard input and files

@@example platform/io.punk@@

## Style

- `punk fmt` decides the layout; do not fight it.
- Annotate every top-level function.
- Prefer pipelines over nested calls, `case` over nested `if`, and Elm's
  names (`List.filter`, `String.split`, `Maybe`) where they exist.
- Return `Result` with made-up error tags instead of crashing.
- One way to do a thing: `fold` or `List.*` for loops, `try` for errors.
