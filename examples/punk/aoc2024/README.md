# Advent of Code 2024 in punkroc

Days 1 to 7 and 11, each on the example input from the puzzle text, in the
functional style (pipelines, recursion, no `var`). `Grid.punk` is a small
punkroc module that days 4 and 6 share.

```
zig build roc
zig-out/bin/roc examples/punk/aoc2024/Day06.punk
```

| Day | Answers (example) | Shows |
|-----|-------------------|-------|
| 1   | 11, 31            | tuples, `.0` accessors, `List.map2` |
| 2   | 2, 4              | ranges, `List.dropAt` |
| 3   | 161, 48           | parsing with `Str.splitOn`, `[first, ..]` patterns |
| 4   | 18, 9             | the `Grid` module, records, `Result.andThen` |
| 5   | 143, 123          | `Set`, `List.sortWith` with `Order` (`LT \| EQ \| GT`) |
| 6   | 41, 6             | own union type with `==`, record update, loop detection |
| 7   | 3749, 11387       | `type Op`, recursion with early stop |
| 11  | 55312, 65601038650482 | `Dict` of counts, `fold ... into ... with` |
