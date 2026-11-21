## Randomness.
Random := [].{
    ## 64 random bits: from the operating system when the app runs, from a
    ## seed in tests (the same seed gives the same bits).
    u64! : () => U64
}
