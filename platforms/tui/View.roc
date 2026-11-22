## What the screen shows: a value the app's `view` gives, which the platform
## draws with ratatui. A view is text, a list with a highlighted line, a
## frame with a title around a view, or views above or beside each other:
##
##     view : Model -> View
##     view = fn model ->
##         View.column
##             [ View.height 1 (View.text "Library")
##             , View.block "Books" (View.list model.selected (List.map bookLine model.books))
##             , View.height 1 (View.paragraph [ [ View.span [ View.fg Yellow ] model.status ] ])
##             ]
##
## In a `column` each view without a `height` gets an equal share of what is
## left; in a `row` the same holds for `width`.
##
## (In this file the arguments are in Roc's order: the view a function works
## on comes first. punk passes it last, so `View.block "Books" v` is
## `block(v, "Books")` here.)
View := [
    Empty,
    Paragraph(List(View.Line)),
    Pick(I64, List(View.Line)),
    Column(List(View)),
    Row(List(View)),
    Sized(I64, View),
    Block(Str, View),
].{

    ## A line of text: spans, each with its own style.
    Line : List(Span)

    ## A piece of text with one style.
    Span : { attrs : List(Attr), text : Str }

    ## How a span looks.
    Attr : [Bold, Dim, Italic, Underline, Reversed, Fg(Color), Bg(Color)]

    ## The terminal's sixteen colours.
    Color : [
        Black,
        Red,
        Green,
        Yellow,
        Blue,
        Magenta,
        Cyan,
        Gray,
        DarkGray,
        LightRed,
        LightGreen,
        LightYellow,
        LightBlue,
        LightMagenta,
        LightCyan,
        White,
    ]

    ## Nothing.
    empty : View
    empty = Empty

    ## Plain text, one line per line of the text.
    text : Str -> View
    text = |t| Paragraph(List.map(Str.split_on(t, "\n"), |l| [plain(l)]))

    ## Lines of styled spans.
    paragraph : List(Line) -> View
    paragraph = |lines| Paragraph(lines)

    ## A list of lines with one highlighted (shown reversed), scrolled so that
    ## it is in sight. The first line is 0; a number outside the list
    ## highlights nothing.
    list : List(Line), I64 -> View
    list = |lines, selected| Pick(selected, lines)

    ## These views above each other, as Elm's `column`.
    column : List(View) -> View
    column = |views| Column(views)

    ## These views beside each other, as Elm's `row`.
    row : List(View) -> View
    row = |views| Row(views)

    ## This many rows high, in a `column`.
    height : View, I64 -> View
    height = |view, n| Sized(if n < 0 0 else n, view)

    ## This many columns wide, in a `row`.
    width : View, I64 -> View
    width = |view, n| Sized(if n < 0 0 else n, view)

    ## A frame with a title around the view.
    block : View, Str -> View
    block = |view, title| Block(title, view)

    ## A span: `View.span [View.bold, View.fg Yellow] "text"` in punk.
    span : Str, List(Attr) -> Span
    span = |t, attrs| { attrs, text: t }

    ## A span without a style.
    plain : Str -> Span
    plain = |t| { attrs: [], text: t }

    bold : Attr
    bold = Bold

    dim : Attr
    dim = Dim

    italic : Attr
    italic = Italic

    underline : Attr
    underline = Underline

    reversed : Attr
    reversed = Reversed

    ## The text's colour: `View.fg Yellow`.
    fg : Color -> Attr
    fg = |c| Fg(c)

    ## The colour behind the text.
    bg : Color -> Attr
    bg = |c| Bg(c)

    ## The view as the host reads it: one node per line, children after
    ## their parent (see `host/src/view.rs`).
    to_host : View -> Str
    to_host = |view| Str.join_with(encode(view, []), "\n")

    encode : View, List(Str) -> List(Str)
    encode = |view, out| match view {
        Empty => List.append(out, "E")
        Paragraph(lines) => encode_lines(lines, List.append(out, "P${List.len(lines).to_str()}"))
        Pick(selected, lines) => encode_lines(lines, List.append(out, "I${List.len(lines).to_str()} ${selected.to_str()}"))
        Column(views) => List.fold(views, List.append(out, "C${List.len(views).to_str()}"), |acc, v| encode(v, acc))
        Row(views) => List.fold(views, List.append(out, "R${List.len(views).to_str()}"), |acc, v| encode(v, acc))
        Sized(n, v) => encode(v, List.append(out, "Z${n.to_str()}"))
        Block(title, v) => encode(v, List.append(out, "B${one_line(title)}"))
    }

    encode_lines : List(Line), List(Str) -> List(Str)
    encode_lines = |lines, out| List.fold(
        lines,
        out,
        |acc, l| List.fold(l, List.append(acc, "L${List.len(l).to_str()}"), |a, s| List.append(a, "S${attrs_to_host(s.attrs)}\t${one_line(s.text)}")),
    )

    one_line : Str -> Str
    one_line = |t| t.replace_each("\n", " ").replace_each("\r", " ")

    attrs_to_host : List(Attr) -> Str
    attrs_to_host = |attrs| Str.join_with(List.map(attrs, attr_to_host), ",")

    attr_to_host : Attr -> Str
    attr_to_host = |attr| match attr {
        Bold => "b"
        Dim => "d"
        Italic => "i"
        Underline => "u"
        Reversed => "r"
        Fg(c) => "f${color_to_host(c)}"
        Bg(c) => "g${color_to_host(c)}"
    }

    color_to_host : Color -> Str
    color_to_host = |c| match c {
        Black => "0"
        Red => "1"
        Green => "2"
        Yellow => "3"
        Blue => "4"
        Magenta => "5"
        Cyan => "6"
        Gray => "7"
        DarkGray => "8"
        LightRed => "9"
        LightGreen => "10"
        LightYellow => "11"
        LightBlue => "12"
        LightMagenta => "13"
        LightCyan => "14"
        White => "15"
    }
}
