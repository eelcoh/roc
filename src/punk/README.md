# punkroc

punkroc is an experiment: Roc with an Elm-like, whitespace-based syntax.
This directory holds the translator from `.punk` to ordinary Roc source.

```
-- punkroc                              # Roc
add = fn a, b ->                        add = |a, b| a + b
    a + b
total = add 1 (add 2 3)                 total = add(1, add(2, 3))
xs |> List.keepIf isGood                List.keep_if(xs, is_good)
inc = add 1                             inc = |punk_a1| add(1, punk_a1)
case r of                               match r {
    Ok v -> v                               Ok(v) => v
    Err _ -> 0                              Err(_) => 0
                                        }
type Shape = Circle F64 | Rect F64 F64  Shape := [Circle(F64), Rect(F64, F64)]
```

- `mod.zig`: the `punk` compiler module; `toRoc` is what the compiler calls.
- `translate.zig`: lexer, layout-sensitive parser and Roc emitter.
- `stdlib.zig`: arity and argument order of the builtins (from `gen_stdlib.py`).
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

## Currying and data-last pipes (step 3)

punkroc follows Elm here, on top of Roc's multi-argument functions.

**`|>` passes the value last.** `x |> f a` is `f a x`.

**Builtins take the value they work on last.** For List, Str, Try (also
spelled `Result`), Iter, Set and Dict, Roc's first argument moves to the
end: `List.map f xs`, `Str.splitOn "," text`, `Dict.insert k v dict`.
Folds take the function first, as Elm's `foldl` (`List.fold f 0 xs`), and so
does `map2` (`List.map2 f xs ys`). Both orders then fit `|>`:

```
-- punkroc                              # Roc
text                                    List.map_try(
    |> Str.trim                             Str.split_on(Str.trim(text), ","),
    |> Str.splitOn ","                      parse_range,
    |> List.mapTry parseRange?          )?
```

`Result.map`, `Result.mapError` and `Result.withDefault` are Roc's
`Try.map_ok`, `Try.map_err` and `Try.ok_or`; a type `Result a e` is
`Try(a, e)`. Other modules (U64, platform modules, packages) keep Roc's
order: `U64.pow 10 n` is `U64.pow(10, n)`. Watch out for functions with two
arguments of the same kind: `List.concat xs ys` is `ys` followed by `xs`
(`ys |> List.concat xs` reads right); `xs ++ ys` is clearer.

**Functions are curried.** Give a function fewer arguments and you get a
function that wants the rest:

```
add : I64 -> I64 -> I64                 add : I64, I64 -> I64
add = fn a, b ->                        add = |a, b| a + b
    a + b
inc = add 1                             inc = |punk_a1| add(1, punk_a1)
all = List.map (add 1)                  all = |punk_a2| List.map(punk_a2, |punk_a3| add(1, punk_a3))
```

Types are curried too: `A -> B -> C`, `A -> (B -> C)` and `A, B -> C` are all
Roc's `A, B -> C`. So are lambdas: `fn a -> fn b -> a + b` is `|a, b| a + b`.
A definition with fewer parameters than its annotation gets the rest passed
on (`pick : Bool -> I64 -> I64 -> I64` with `pick = fn b -> ...`).

How it works: Roc functions are not curried, so the translator writes partial
applications as lambdas. It knows the arity of the builtins above and of every
function defined or annotated in the same file. Arguments of a partial
application that are not plain values are computed once, before the lambda.
Calls to functions it knows nothing about (lambda parameters, record fields,
functions from other modules) pass all arguments at once, as in Roc; partial
application of those does not work yet. See `examples/punk/currying.punk`.

Known gaps: multi-line strings, comments inside expressions (only comments
before definitions and statements are kept), `::` list patterns, operator
sections such as `(+)`.
