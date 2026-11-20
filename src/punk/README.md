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

- `translate.zig`: lexer, layout-sensitive parser and Roc emitter.
- `main.zig`: the `punk2roc` command line tool.
- `test.zig`: translation tests.

Try it without building the rest of the compiler:

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
