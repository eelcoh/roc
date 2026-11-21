## Reading and writing files, but only the ones named on the command line.
##
## `punk app.punk input.txt` lets the app read and write `input.txt`, and
## nothing else: a path the app makes up itself gives `FileErr`. The user
## who types the command decides what the app may touch (ambit's `Named`
## capability).
File := [].{
    ## The whole file at the path, as text.
    read! : Str => Try(Str, [FileErr(Str)])
    ## Writes the text to the file at the path, replacing what was there.
    ## All or nothing: after a crash the file has its old or its new text.
    ## The text comes first here, so punkroc writes `File.write! path text`
    ## (and `text |> File.write! path`).
    write! : Str, Str => Try({}, [FileErr(Str)])
}
