# punkroc

punkroc is an experiment: Roc with an Elm-like, whitespace-based syntax.
This directory holds the translator from `.punk` to ordinary Roc source.

```
-- punkroc                              # Roc
add = fn a, b ->                        add = |a, b| a + b
    a + b
total = add 1 (add 2 3)                 total = add(1, add(2, 3))
xs |> List.keepIf isGood                List.keep_if(xs, is_good)
case r of                               match r {
    Ok v -> v                               Ok(v) => v
    Err _ -> 0                              Err(_) => 0
                                        }
type Shape = Circle F64 | Rect F64 F64  Shape := [Circle(F64), Rect(F64, F64)]
```

- `mod.zig`: the `punk` compiler module; `toRoc` is what the compiler calls.
- `translate.zig`: lexer, layout-sensitive parser and Roc emitter.
- `main.zig`: the `punk2roc` command line tool.
- `test.zig`: translation tests.

## In the compiler

The compiler translates `.punk` files as it reads them (`CoreCtx.readFile`),
so everything after the parser sees ordinary Roc:

```
zig build roc
zig-out/bin/roc examples/punk/aoc_day2_functional.punk
zig-out/bin/roc check examples/punk/aoc_day2_functional.punk
```

`import Foo` finds `Foo.punk` when there is no `Foo.roc` next to it. A module
file starts with an Elm-style header; it becomes a Roc type module:

```
module Math exposing (double)          Math := [].{
                                           double = |x| x * 2
double = fn x ->                       }
    x * 2
```

When the module declares `type Shape` with the module's own name, that type
carries the block (`Shape := [Circle(F64), ...].{ area = ... }`). The
`exposing` list is not checked yet: everything in the module is visible.
See `examples/punk/imports/`.

A syntax error in a `.punk` file is printed as `file:line:col: message`.

## Without the compiler

Try the translator on its own, without building the rest of the compiler:

```
zig test src/punk/test.zig
zig build-exe src/punk/main.zig -femit-bin=punk2roc
./punk2roc examples/punk/aoc_day2.punk
```

Step 2 changes only the syntax. `|>` still passes the value as the first
argument, like Roc. Currying and data-last pipes come in step 3.

Known gaps: multi-line strings, comments inside expressions (only comments
before definitions and statements are kept), `::` list patterns, operator
sections such as `(+)`.
