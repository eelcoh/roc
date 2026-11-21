## The time.
Clock := [].{
    ## The wall-clock time: milliseconds since 1970-01-01 UTC, like Elm's
    ## `Time.posixToMillis`. In tests it is a clock the test sets.
    now! : () => I64
}
