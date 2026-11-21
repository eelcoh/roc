## A plain Roc module, used from punkroc (app.punk). Its functions take the
## value they work on first, as Roc functions do.
Text := [].{
    ## The string `n` times.
    repeat : Str, U64 -> Str
    repeat = |s, n| Str.repeat(s, n)

    ## The string with `prefix` in front of it.
    with_prefix : Str, Str -> Str
    with_prefix = |s, prefix| Str.concat(prefix, s)
}
