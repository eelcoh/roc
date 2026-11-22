import Cmd

## The files the app may read: those in the folder the wiring gave it (its
## `folder`), and nothing outside it. Paths are relative to that folder, with
## `/` between the parts (`"books/library.json"`); `..` is refused.
##
##     File.read "library.json" Loaded
##
## gives `Loaded (Ok text)` or `Loaded (Err why)` later, as a message. The
## reading happens off the screen's thread.
File := [].{
    ## The file's text (it must be UTF-8).
    read : (Try(Str, Str) -> msg), Str -> Cmd(msg)
    read = |to_msg, path| Cmd.work("read", path, |reply| to_msg(result(reply)))

    ## The names in a folder (`""` is the app's folder itself), sorted.
    ## Folders end in `/`.
    list : (Try(List(Str), Str) -> msg), Str -> Cmd(msg)
    list = |to_msg, path| Cmd.work(
        "list",
        path,
        |reply| to_msg(Try.map_ok(result(reply), |text| if text == "" [] else Str.split_on(text, "\n"))),
    )

    result : Cmd.Reply -> Try(Str, Str)
    result = |reply| if reply.ok Ok(reply.text) else Err(reply.text)
}
