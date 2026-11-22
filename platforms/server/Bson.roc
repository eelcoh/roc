## Documents for Mongo, written as Elm's `Json.Encode` writes JSON:
##
##     linkDocument : Link -> Bson.Value
##     linkDocument = fn link ->
##         Bson.object
##             [ ("_id", Bson.text link.id)
##             , ("url", Bson.text link.url)
##             , ("created", Bson.int link.created)
##             ]
##
## A value is data, never a query: a key can't start with `$` (the host
## refuses the document), so a value from a request can't become one of
## Mongo's operators. Filters and changes are made by `Filter` and `Update`.
##
## (In this file the arguments are in Roc's order: punk passes the value a
## function works on last.)
Bson := [].{
    ## One value as it goes to the host and back: the values of a document in
    ## order, each list and object followed by what is in it. `kind` is 0 for
    ## null, 1 text, 2 int, 3 float, 4 bool, 5 list, 6 object, 7 object id, 8
    ## time and 9 a type punk doesn't read (described in `text`); `name` is
    ## the key of a value in an object; `size` is how many values follow that
    ## are inside this one (0 for all but lists and objects).
    Node : { kind : U8, name : Str, size : U64, text : Str }

    ## A value: text, a number, a list, an object, ... Only the functions of
    ## this module make one.
    Value :: { nodes : List(Node) }

    text : Str -> Value
    text = |value| leaf(1, value)

    int : I64 -> Value
    int = |value| leaf(2, value.to_str())

    float : F64 -> Value
    float = |value| leaf(3, value.to_str())

    bool : Bool -> Value
    bool = |value| leaf(4, if value "true" else "false")

    null : Value
    null = leaf(0, "")

    ## `Nothing` as null, `Just x` as the value `x` gives, in punk
    ## `Bson.nullable Bson.text maybeTitle`.
    nullable : [Just(a), Nothing], (a -> Value) -> Value
    nullable = |maybe, to_value| match maybe {
        Just(value) => to_value(value)
        Nothing => leaf(0, "")
    }

    ## Mongo's ObjectId, from its 24 hexadecimal digits (as `Doc.objectId`
    ## gives them). The host refuses a broken one.
    object_id : Str -> Value
    object_id = |hex| leaf(7, hex)

    ## A moment in time, in milliseconds since 1970 (as `Clock.now!` gives
    ## it), stored as Mongo's date.
    time : I64 -> Value
    time = |millis| leaf(8, millis.to_str())

    ## A list of values, in punk `Bson.list [Bson.text "a", Bson.text "b"]`.
    list : List(Value) -> Value
    list = |values| {
        inner = List.fold(values, [], |done, value| List.concat(done, value.nodes))
        { nodes: List.concat([{ kind: 5, name: "", size: List.len(inner), text: "" }], inner) }
    }

    ## An object: keys and their values, in this order.
    object : List((Str, Value)) -> Value
    object = |fields| {
        inner = List.fold(
            fields,
            [],
            |done, (name, value)| List.concat(done, named(value.nodes, name)),
        )
        { nodes: List.concat([{ kind: 6, name: "", size: List.len(inner), text: "" }], inner) }
    }

    ## The nodes of a value, as the host receives them.
    to_nodes : Value -> List(Node)
    to_nodes = |value| value.nodes

    ## A value from the nodes the host gave (a document, or a value in it).
    from_nodes : List(Node) -> Value
    from_nodes = |nodes| { nodes: nodes }

    leaf : U8, Str -> Value
    leaf = |kind, value| { nodes: [{ kind, name: "", size: 0, text: value }] }

    named : List(Node), Str -> List(Node)
    named = |nodes, name| match List.first(nodes) {
        Ok(first) => match List.set(nodes, 0, { ..first, name }) {
            Ok(renamed) => renamed
            Err(_) => nodes
        }
        Err(_) => nodes
    }
}
