## Reading the rows a query gives, as Elm's `Json.Decode` reads JSON: a
## decoder says which columns a row has and what type each one is, and turns
## the row into a punk value.
##
##     link : Row.Decoder Link
##     link =
##         Row.map2 (fn created, url -> { created, url })
##             (Row.field "created" Row.int)
##             (Row.field "url" Row.text)
##
## (In this file the arguments are in Roc's order: the decoder a function
## works on comes first. punk passes it last.)
Row := [].{
    ## One value of a row as the host gives it. `kind` is 0 for NULL, 1 text,
    ## 2 int, 3 float and 4 bool; `text` is the value written as text.
    Cell : { kind : U8, text : Str }

    ## Turns a row (the names of its columns and its cells) into an `a`, or
    ## says why it can't.
    Decoder(a) :: { run : List(Str), List(Cell) -> Try(a, Str) }

    ## Reads one cell: `Row.int`, `Row.text`, `Row.float`, `Row.bool`, and
    ## `Row.nullable` for a column that can be NULL.
    Column(a) :: { read : Cell -> Try(a, Str) }

    ## The column with this name, in punk `Row.field "url" Row.text`.
    field : Column(a), Str -> Decoder(a)
    field = |column, name| {
        run: |columns, cells| match index_of(columns, name, 0) {
            Err(NotFound) => Err("the query gives no column \"${name}\" (it gives ${Str.join_with(columns, ", ")})")
            Ok(i) => match List.get(cells, i) {
                Err(_) => Err("the row has no cell for column \"${name}\"")
                Ok(cell) => match (column.read)(cell) {
                    Ok(value) => Ok(value)
                    Err(problem) => Err("column \"${name}\": ${problem}")
                }
            }
        },
    }

    index_of : List(Str), Str, U64 -> Try(U64, [NotFound])
    index_of = |names, name, i| match List.get(names, i) {
        Err(_) => Err(NotFound)
        Ok(n) => if n == name Ok(i) else index_of(names, name, i + 1)
    }

    ## A column of type `int2`, `int4` or `int8` (`smallint`, `integer`,
    ## `bigint`).
    int : Column(I64)
    int = {
        read: |cell| match cell.kind {
            2 => match I64.from_str(cell.text) {
                Ok(n) => Ok(n)
                Err(_) => Err("\"${cell.text}\" is not an int")
            }
            k => Err("expected an int, got ${kind_name(k)}")
        },
    }

    ## A column of type `float4` or `float8` (`real`, `double precision`).
    float : Column(F64)
    float = {
        read: |cell| match cell.kind {
            3 => match F64.from_str(cell.text) {
                Ok(x) => Ok(x)
                Err(_) => Err("\"${cell.text}\" is not a float")
            }
            k => Err("expected a float, got ${kind_name(k)}")
        },
    }

    ## A column of type `text`, `varchar`, `char` or `name`.
    text : Column(Str)
    text = {
        read: |cell| match cell.kind {
            1 => Ok(cell.text)
            k => Err("expected text, got ${kind_name(k)}")
        },
    }

    ## A column of type `bool`.
    bool : Column(Bool)
    bool = {
        read: |cell| match cell.kind {
            4 => Ok(cell.text == "true")
            k => Err("expected a bool, got ${kind_name(k)}")
        },
    }

    ## A column that can be NULL: `Nothing` for NULL, `Just x` otherwise.
    nullable : Column(a) -> Column([Just(a), Nothing])
    nullable = |column| {
        read: |cell| if cell.kind == 0 {
            Ok(Nothing)
        } else {
            match (column.read)(cell) {
                Ok(value) => Ok(Just(value))
                Err(problem) => Err(problem)
            }
        },
    }

    kind_name : U8 -> Str
    kind_name = |kind| match kind {
        0 => "NULL"
        1 => "text"
        2 => "an int"
        3 => "a float"
        4 => "a bool"
        _ => "a value of an unknown kind"
    }

    ## A decoder that gives this value, whatever the row.
    succeed : a -> Decoder(a)
    succeed = |value| { run: |_, _| Ok(value) }

    ## A decoder that fails with this message.
    fail : Str -> Decoder(a)
    fail = |message| { run: |_, _| Err(message) }

    ## In punk `Row.map f decoder`.
    map : Decoder(a), (a -> b) -> Decoder(b)
    map = |decoder, f| {
        run: |columns, cells| match (decoder.run)(columns, cells) {
            Ok(a) => Ok(f(a))
            Err(e) => Err(e)
        },
    }

    ## In punk `Row.map2 f da db`: the last decoder comes first here.
    map2 : Decoder(b), (a, b -> c), Decoder(a) -> Decoder(c)
    map2 = |db, f, da| {
        run: |columns, cells| match (da.run)(columns, cells) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(columns, cells) {
                Err(e) => Err(e)
                Ok(b) => Ok(f(a, b))
            }
        },
    }

    ## In punk `Row.map3 f da db dc`.
    map3 : Decoder(c), (a, b, c -> d), Decoder(a), Decoder(b) -> Decoder(d)
    map3 = |dc, f, da, db| {
        run: |columns, cells| match (da.run)(columns, cells) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(columns, cells) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(columns, cells) {
                    Err(e) => Err(e)
                    Ok(c) => Ok(f(a, b, c))
                }
            }
        },
    }

    ## In punk `Row.map4 f da db dc dd`.
    map4 : Decoder(d), (a, b, c, d -> e), Decoder(a), Decoder(b), Decoder(c) -> Decoder(e)
    map4 = |dd, f, da, db, dc| {
        run: |columns, cells| match (da.run)(columns, cells) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(columns, cells) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(columns, cells) {
                    Err(e) => Err(e)
                    Ok(c) => match (dd.run)(columns, cells) {
                        Err(e) => Err(e)
                        Ok(d) => Ok(f(a, b, c, d))
                    }
                }
            }
        },
    }

    ## In punk `Row.map5 f da db dc dd de`.
    map5 : Decoder(e), (a, b, c, d, e -> g), Decoder(a), Decoder(b), Decoder(c), Decoder(d) -> Decoder(g)
    map5 = |de, f, da, db, dc, dd| {
        run: |columns, cells| match (da.run)(columns, cells) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(columns, cells) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(columns, cells) {
                    Err(e) => Err(e)
                    Ok(c) => match (dd.run)(columns, cells) {
                        Err(e) => Err(e)
                        Ok(d) => match (de.run)(columns, cells) {
                            Err(e) => Err(e)
                            Ok(v) => Ok(f(a, b, c, d, v))
                        }
                    }
                }
            }
        },
    }

    ## In punk `Row.andThen f decoder`: a decoder that depends on a value
    ## read before.
    and_then : Decoder(a), (a -> Decoder(b)) -> Decoder(b)
    and_then = |decoder, f| {
        run: |columns, cells| match (decoder.run)(columns, cells) {
            Err(e) => Err(e)
            Ok(a) => (f(a).run)(columns, cells)
        },
    }

    ## Decodes every row, in punk `Row.decodeRows decoder columns rows`.
    ## `Postgres.rows!` does this; it is here for tests of a decoder.
    decode_rows : List(List(Cell)), Decoder(a), List(Str) -> Try(List(a), Str)
    decode_rows = |rows, decoder, columns| decode_from(rows, decoder, columns, 0, List.with_capacity(List.len(rows)))

    decode_from : List(List(Cell)), Decoder(a), List(Str), U64, List(a) -> Try(List(a), Str)
    decode_from = |rows, decoder, columns, i, done| match List.get(rows, i) {
        Err(_) => Ok(done)
        Ok(cells) => match (decoder.run)(columns, cells) {
            Err(problem) => Err("row ${(i + 1).to_str()}: ${problem}")
            Ok(value) => decode_from(rows, decoder, columns, i + 1, List.append(done, value))
        }
    }
}
