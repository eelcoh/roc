## What the app asks the platform to do after an update, as Elm's `Cmd`: a
## value that describes work, which the platform does and answers with a
## message. The app never waits: the answer comes later as `Msg msg`.
##
##     Cmd.none
##     Cmd.quit
##     Cmd.batch [ Cmd.after 500 Tick, File.read "library.json" Loaded ]
##
## (In this file the arguments are in Roc's order: punk passes the command a
## function works on last, so `Cmd.map Page cmd` is `map(cmd, Page)` here.)
##
## Work is done off the screen's thread: `kind` names it, `arg` is what it
## works on, and `reply` turns the host's answer into the app's message.
Cmd(msg) := [None, Quit, Batch(List(Cmd(msg))), Work({ kind : Str, arg : Str, reply : Cmd.Reply -> msg })].{

    ## The host's answer to a piece of work: `ok`, and the result or why it
    ## failed in `text`.
    Reply : { ok : Bool, text : Str }

    ## Nothing to do. (A function here, so that it can be a `Cmd` of any
    ## message: punk writes `Cmd.none`.)
    none : () -> Cmd(msg)
    none = || None

    ## End the program. The platform restores the terminal.
    quit : () -> Cmd(msg)
    quit = || Quit

    ## All of these, in this order.
    batch : List(Cmd(msg)) -> Cmd(msg)
    batch = |cmds| Batch(cmds)

    ## The message, this many milliseconds from now, on the platform's clock.
    after : msg, I64 -> Cmd(msg)
    after = |msg, ms| Work({ kind: "after", arg: if ms < 0 "0" else ms.to_str(), reply: |_| msg })

    ## The same work, its message wrapped: for a part of the app with its
    ## own messages, as Elm's `Cmd.map`.
    map : Cmd(a), (a -> b) -> Cmd(b)
    map = |cmd, f| match cmd {
        None => None
        Quit => Quit
        Batch(cmds) => Batch(List.map(cmds, |c| map(c, f)))
        Work(w) => Work({ kind: w.kind, arg: w.arg, reply: |r| f((w.reply)(r)) })
    }

    ## Work of a kind the host knows (`read`, `list`, `now`, ...), for the
    ## platform's own modules.
    work : Str, Str, (Cmd.Reply -> msg) -> Cmd(msg)
    work = |kind, arg, reply| Work({ kind, arg, reply })

    ## The command as the host reads it, one line per piece of work
    ## (`quit`, or `<id>\t<kind>\t<arg>`, the arg with `\\`, `\n` and `\t`
    ## escaped), with the replies still to come under their ids. Ids count on
    ## from `next`.
    to_host : Cmd(msg), U64 -> { lines : List(Str), waiting : List({ id : U64, reply : Cmd.Reply -> msg }), next : U64 }
    to_host = |cmd, next| collect(cmd, { lines: [], waiting: [], next })

    collect : Cmd(msg), { lines : List(Str), waiting : List({ id : U64, reply : Cmd.Reply -> msg }), next : U64 } -> { lines : List(Str), waiting : List({ id : U64, reply : Cmd.Reply -> msg }), next : U64 }
    collect = |cmd, acc| match cmd {
        None => acc
        Quit => { ..acc, lines: List.append(acc.lines, "quit") }
        Batch(cmds) => List.fold(cmds, acc, |a, c| collect(c, a))
        Work(w) => {
            lines: List.append(acc.lines, "${acc.next.to_str()}\t${w.kind}\t${escape(w.arg)}"),
            waiting: List.append(acc.waiting, { id: acc.next, reply: w.reply }),
            next: acc.next + 1,
        }
    }

    escape : Str -> Str
    escape = |text| text
        .replace_each("\\", "\\\\")
        .replace_each("\n", "\\n")
        .replace_each("\t", "\\t")
}
