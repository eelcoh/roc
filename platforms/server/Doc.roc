import Bson

## Reading Mongo documents, as Elm's `Json.Decode` reads JSON: a decoder says
## which fields a document has and what type each one is, and turns the
## document into a punk value.
##
##     linkDecoder : Doc.Decoder Link
##     linkDecoder =
##         Doc.map3 (fn id, url, created -> { id, url, created })
##             (Doc.field "_id" Doc.text)
##             (Doc.field "url" Doc.text)
##             (Doc.field "created" Doc.int)
##
## A document that doesn't fit is an error that says where (`field "created":
## expected an int, got text`), never a wrong value.
##
## (In this file the arguments are in Roc's order: the decoder a function
## works on comes first. punk passes it last.)
Doc := [].{
    ## Reads the value at an index of the nodes of a document.
    Decoder(a) :: { run : List(Bson.Node), U64 -> Try(a, Str) }

    ## The field with this name of an object, in punk
    ## `Doc.field "url" Doc.text`. A document without it is an error.
    field : Decoder(a), Str -> Decoder(a)
    field = |decoder, name| {
        run: |nodes, i| match find_field(nodes, i, name) {
            Err(problem) => Err(problem)
            Ok(Missing) => Err("the document has no field \"${name}\"")
            Ok(At(j)) => match (decoder.run)(nodes, j) {
                Ok(value) => Ok(value)
                Err(problem) => Err("field \"${name}\": ${problem}")
            }
        },
    }

    ## A field that may be missing or null: `Nothing` then, `Just x` when it
    ## is there. A value of the wrong type is still an error. In punk
    ## `Doc.optionalField "title" Doc.text`.
    optional_field : Decoder(a), Str -> Decoder([Just(a), Nothing])
    optional_field = |decoder, name| {
        run: |nodes, i| match find_field(nodes, i, name) {
            Err(problem) => Err(problem)
            Ok(Missing) => Ok(Nothing)
            Ok(At(j)) => match List.get(nodes, j) {
                Ok(node) if node.kind == 0 => Ok(Nothing)
                _ => match (decoder.run)(nodes, j) {
                    Ok(value) => Ok(Just(value))
                    Err(problem) => Err("field \"${name}\": ${problem}")
                }
            }
        },
    }

    ## Where the field with this name of the object at `i` is.
    find_field : List(Bson.Node), U64, Str -> Try([At(U64), Missing], Str)
    find_field = |nodes, i, name| match List.get(nodes, i) {
        Err(_) => Err("the document ends too soon")
        Ok(node) => if node.kind == 6 {
            Ok(find_child(nodes, i + 1, i + 1 + node.size, name))
        } else {
            Err("expected an object, got ${kind_name(node.kind)}")
        }
    }

    find_child : List(Bson.Node), U64, U64, Str -> [At(U64), Missing]
    find_child = |nodes, j, end, name| if j >= end {
        Missing
    } else {
        match List.get(nodes, j) {
            Err(_) => Missing
            Ok(child) => if child.name == name At(j) else find_child(nodes, j + 1 + child.size, end, name)
        }
    }

    ## Reads the node at `i` with `read`, when it is of this kind.
    leaf : U8, Str, (Str -> Try(a, Str)) -> Decoder(a)
    leaf = |kind, expected, read| {
        run: |nodes, i| match List.get(nodes, i) {
            Err(_) => Err("the document ends too soon")
            Ok(node) => if node.kind == kind read(node.text) else Err("expected ${expected}, got ${kind_name(node.kind)}")
        },
    }

    text : Decoder(Str)
    text = leaf(1, "text", |s| Ok(s))

    ## A whole number (Mongo's int32 or int64).
    int : Decoder(I64)
    int = leaf(
        2,
        "an int",
        |s| match I64.from_str(s) {
            Ok(n) => Ok(n)
            Err(_) => Err("\"${s}\" is not an int")
        },
    )

    ## A double.
    float : Decoder(F64)
    float = leaf(
        3,
        "a float",
        |s| match F64.from_str(s) {
            Ok(x) => Ok(x)
            Err(_) => Err("\"${s}\" is not a float")
        },
    )

    bool : Decoder(Bool)
    bool = leaf(4, "a bool", |s| Ok(s == "true"))

    ## An ObjectId, as its 24 hexadecimal digits.
    object_id : Decoder(Str)
    object_id = leaf(7, "an object id", |s| Ok(s))

    ## A date, in milliseconds since 1970.
    time : Decoder(I64)
    time = leaf(
        8,
        "a date",
        |s| match I64.from_str(s) {
            Ok(n) => Ok(n)
            Err(_) => Err("\"${s}\" is not a date")
        },
    )

    ## A value that can be null: `Nothing` for null, `Just x` otherwise.
    nullable : Decoder(a) -> Decoder([Just(a), Nothing])
    nullable = |decoder| {
        run: |nodes, i| match List.get(nodes, i) {
            Ok(node) if node.kind == 0 => Ok(Nothing)
            _ => match (decoder.run)(nodes, i) {
                Ok(value) => Ok(Just(value))
                Err(problem) => Err(problem)
            }
        },
    }

    ## A list, each value through the decoder, in punk `Doc.list Doc.text`.
    list : Decoder(a) -> Decoder(List(a))
    list = |decoder| {
        run: |nodes, i| match List.get(nodes, i) {
            Err(_) => Err("the document ends too soon")
            Ok(node) => if node.kind == 5 {
                list_from(nodes, decoder, i + 1, i + 1 + node.size, 0, [])
            } else {
                Err("expected a list, got ${kind_name(node.kind)}")
            }
        },
    }

    list_from : List(Bson.Node), Decoder(a), U64, U64, U64, List(a) -> Try(List(a), Str)
    list_from = |nodes, decoder, j, end, n, done| if j >= end {
        Ok(done)
    } else {
        match List.get(nodes, j) {
            Err(_) => Ok(done)
            Ok(child) => match (decoder.run)(nodes, j) {
                Err(problem) => Err("item ${n.to_str()}: ${problem}")
                Ok(value) => list_from(nodes, decoder, j + 1 + child.size, end, n + 1, List.append(done, value))
            }
        }
    }

    kind_name : U8 -> Str
    kind_name = |kind| match kind {
        0 => "null"
        1 => "text"
        2 => "an int"
        3 => "a float"
        4 => "a bool"
        5 => "a list"
        6 => "an object"
        7 => "an object id"
        8 => "a date"
        _ => "a value punk doesn't read"
    }

    ## A decoder that gives this value, whatever the document.
    succeed : a -> Decoder(a)
    succeed = |value| { run: |_, _| Ok(value) }

    ## A decoder that fails with this message.
    fail : Str -> Decoder(a)
    fail = |message| { run: |_, _| Err(message) }

    ## In punk `Doc.map f decoder`.
    map : Decoder(a), (a -> b) -> Decoder(b)
    map = |decoder, f| {
        run: |nodes, i| match (decoder.run)(nodes, i) {
            Ok(a) => Ok(f(a))
            Err(e) => Err(e)
        },
    }

    ## In punk `Doc.map2 f da db`: the last decoder comes first here.
    map2 : Decoder(b), (a, b -> c), Decoder(a) -> Decoder(c)
    map2 = |db, f, da| {
        run: |nodes, i| match (da.run)(nodes, i) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(nodes, i) {
                Err(e) => Err(e)
                Ok(b) => Ok(f(a, b))
            }
        },
    }

    ## In punk `Doc.map3 f da db dc`.
    map3 : Decoder(c), (a, b, c -> d), Decoder(a), Decoder(b) -> Decoder(d)
    map3 = |dc, f, da, db| {
        run: |nodes, i| match (da.run)(nodes, i) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(nodes, i) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(nodes, i) {
                    Err(e) => Err(e)
                    Ok(c) => Ok(f(a, b, c))
                }
            }
        },
    }

    ## In punk `Doc.map4 f da db dc dd`.
    map4 : Decoder(d), (a, b, c, d -> e), Decoder(a), Decoder(b), Decoder(c) -> Decoder(e)
    map4 = |dd, f, da, db, dc| {
        run: |nodes, i| match (da.run)(nodes, i) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(nodes, i) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(nodes, i) {
                    Err(e) => Err(e)
                    Ok(c) => match (dd.run)(nodes, i) {
                        Err(e) => Err(e)
                        Ok(d) => Ok(f(a, b, c, d))
                    }
                }
            }
        },
    }

    ## In punk `Doc.map5 f da db dc dd de`.
    map5 : Decoder(e), (a, b, c, d, e -> g), Decoder(a), Decoder(b), Decoder(c), Decoder(d) -> Decoder(g)
    map5 = |de, f, da, db, dc, dd| {
        run: |nodes, i| match (da.run)(nodes, i) {
            Err(e) => Err(e)
            Ok(a) => match (db.run)(nodes, i) {
                Err(e) => Err(e)
                Ok(b) => match (dc.run)(nodes, i) {
                    Err(e) => Err(e)
                    Ok(c) => match (dd.run)(nodes, i) {
                        Err(e) => Err(e)
                        Ok(d) => match (de.run)(nodes, i) {
                            Err(e) => Err(e)
                            Ok(v) => Ok(f(a, b, c, d, v))
                        }
                    }
                }
            }
        },
    }

    ## In punk `Doc.andThen f decoder`: a decoder that depends on a value
    ## read before.
    and_then : Decoder(a), (a -> Decoder(b)) -> Decoder(b)
    and_then = |decoder, f| {
        run: |nodes, i| match (decoder.run)(nodes, i) {
            Err(e) => Err(e)
            Ok(a) => (f(a).run)(nodes, i)
        },
    }

    ## The first decoder that fits, in punk `Doc.oneOf [d1, d2]`.
    one_of : List(Decoder(a)) -> Decoder(a)
    one_of = |decoders| {
        run: |nodes, i| one_of_from(decoders, nodes, i, 0, []),
    }

    one_of_from : List(Decoder(a)), List(Bson.Node), U64, U64, List(Str) -> Try(a, Str)
    one_of_from = |decoders, nodes, i, n, problems| match List.get(decoders, n) {
        Err(_) => Err("none fits: ${Str.join_with(problems, "; ")}")
        Ok(decoder) => match (decoder.run)(nodes, i) {
            Ok(value) => Ok(value)
            Err(problem) => one_of_from(decoders, nodes, i, n + 1, List.append(problems, problem))
        }
    }

    ## Reads a value with the decoder, in punk `Doc.decode decoder value`.
    ## `Mongo.all!` and `Mongo.first!` do this; it is here for tests of a
    ## decoder.
    decode : Bson.Value, Decoder(a) -> Try(a, Str)
    decode = |value, decoder| (decoder.run)(Bson.to_nodes(value), 0)

    ## Reads the documents the host gave.
    decode_all : List(List(Bson.Node)), Decoder(a) -> Try(List(a), Str)
    decode_all = |documents, decoder| decode_from(documents, decoder, 0, List.with_capacity(List.len(documents)))

    decode_from : List(List(Bson.Node)), Decoder(a), U64, List(a) -> Try(List(a), Str)
    decode_from = |documents, decoder, n, done| match List.get(documents, n) {
        Err(_) => Ok(done)
        Ok(nodes) => match (decoder.run)(nodes, 0) {
            Err(problem) => Err("document ${(n + 1).to_str()}: ${problem}")
            Ok(value) => decode_from(documents, decoder, n + 1, List.append(done, value))
        }
    }
}
