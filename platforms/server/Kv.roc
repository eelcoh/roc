## A key-value store: the app's only storage. Keys and values are text. Each
## call is on its own; there are no transactions.
Kv := [].{
    ## The value stored under the key: `Ok (Just value)`, `Ok Nothing` when
    ## there is none, or `Err (KvErr message)` when the store failed.
    get! : Str => Try([Just(Str), Nothing], [KvErr(Str)])
    get! = |key| {
        found = get_host!(key)
        match found.code {
            0 => Ok(Nothing)
            1 => Ok(Just(found.text))
            _ => Err(KvErr(found.text))
        }
    }

    ## Stores the value under the key, replacing what was there. The value
    ## comes first here, so that punkroc writes `Kv.put! key value` (and
    ## `value |> Kv.put! key`), as `File.write!` of the cli platform.
    put! : Str, Str => Try({}, [KvErr(Str)])

    ## Removes the key and its value. Removing a key that isn't there is fine.
    delete! : Str => Try({}, [KvErr(Str)])

    ## What the host gives: code 0 is not there, 1 is found (the value is in
    ## `text`), 2 is a failure (the message is in `text`).
    get_host! : Str => { code : U8, text : Str }
}
