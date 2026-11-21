## The time.
Clock := [].{
    ## The wall-clock time: milliseconds since 1970-01-01 UTC, like Elm's
    ## `Time.posixToMillis`. Can jump (the computer's clock is set).
    now! : () => I64
    ## Milliseconds since the program started. Never goes backwards: use it to
    ## measure how long something takes.
    elapsed! : () => I64
}
