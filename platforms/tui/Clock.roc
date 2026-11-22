import Cmd

## The time, as Elm's `Time.now`: a command that answers with the
## milliseconds since 1970 on the platform's clock.
##
##     Clock.now GotTime
Clock := [].{
    now : (I64 -> msg) -> Cmd(msg)
    now = |to_msg| Cmd.work(
        "now",
        "",
        |reply| to_msg(
            match I64.from_str(reply.text) {
                Ok(ms) => ms
                Err(_) => 0
            },
        ),
    )
}
