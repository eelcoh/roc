## The types of a terminal app's events: what happens to it, in the order it
## happens. The app's `update` gets each one:
##
##     update : Event Msg -> Model -> (Model, Cmd Msg)
##     update = fn event, model ->
##         case event of
##             Key (Char "j") -> ...
##             Key (Ctrl "c") -> (model, Cmd.quit)
##             Resize width height -> ...
##             Msg (Loaded result) -> ...
##             _ -> (model, Cmd.none)
Tui := [].{
    ## `Key` is a key press (releases and repeats are not reported), `Paste`
    ## text pasted into the terminal in one piece, `Resize` the terminal's
    ## size in columns and rows (always the first event, and again whenever
    ## it changes), and `Msg` a message the app asked for with a `Cmd`.
    Event(msg) : [Key(Key), Paste(Str), Resize(I64, I64), Msg(msg)]

    ## A key. `Char "a"` is a character with shift already applied (`"A"`,
    ## not `"a"` and shift), `Ctrl "c"` and `Alt "x"` a character with that
    ## modifier held.
    Key : [
        Char(Str),
        Ctrl(Str),
        Alt(Str),
        Enter,
        Esc,
        Backspace,
        Delete,
        Tab,
        BackTab,
        Up,
        Down,
        Left,
        Right,
        Home,
        End,
        PageUp,
        PageDown,
        Insert,
        F(I64),
    ]

    ## The event the host describes with these numbers (see `key_to_host` in `host/src/lib.rs`):
    ## kind 0 is a key (`code` 0 a character in `text`, the others the keys
    ## below; `mods` 1 is ctrl, 2 alt), 1 a paste, 2 a resize.
    event_from_host : U8, Str, U32, U8, U16, U16 -> Event(msg)
    event_from_host = |kind, text, code, mods, width, height| match kind {
        1 => Paste(text)
        2 => Resize(width.to_i64(), height.to_i64())
        _ => Key(key_from_host(text, code, mods))
    }

    key_from_host : Str, U32, U8 -> Key
    key_from_host = |text, code, mods| match code {
        0 => match mods {
            1 => Ctrl(text)
            2 => Alt(text)
            _ => Char(text)
        }
        1 => Enter
        2 => Esc
        3 => Backspace
        4 => Delete
        5 => Tab
        6 => BackTab
        7 => Up
        8 => Down
        9 => Left
        10 => Right
        11 => Home
        12 => End
        13 => PageUp
        14 => PageDown
        15 => Insert
        n => F((n - 100).to_i64())
    }
}
