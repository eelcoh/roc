## Randomness from the operating system.
Random := [].{
    ## 64 random bits from the operating system's secure random source. Use it
    ## as the seed of a pure generator, or directly for an id.
    u64! : () => U64
}
