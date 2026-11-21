## Reading and writing files.
File := [].{
    ## The whole file at the path (relative to the current directory).
    read! : Str => Try(Str, [FileErr(Str)])
    ## Writes the text to the file at the path, replacing what was there.
    ## The text comes first here, so punkroc writes `File.write! path text`
    ## (and `text |> File.write! path`).
    write! : Str, Str => Try({}, [FileErr(Str)])
}
