import Bson

## How `Mongo.update!` changes the documents it finds:
##
##     Mongo.update! (Filter.equals "_id" (Bson.text id))
##         [ Update.set "url" (Bson.text url)
##         , Update.increment "visits" 1
##         ]
##         links
##
## As with `Filter`, the host writes Mongo's operators (`$set`, `$unset`,
## `$inc`), the values are data, and the field names are text written in the
## program (rule P302).
##
## (In this file the arguments are in Roc's order: punk passes the field
## name first.)
##
## One change as the host receives it: a `Bson.Node` of kind 30 (set the
## field `name` to the value that follows), 31 (remove it) or 32 (add the
## number that follows to it).
Update :: { nodes : List(Bson.Node) }.{
    ## Sets the field to the value, in punk `Update.set "url" (Bson.text url)`.
    set : Bson.Value, Str -> Update
    set = |value, field| change(30, field, Bson.to_nodes(value))

    ## Removes the field.
    unset : Str -> Update
    unset = |field| change(31, field, [])

    ## Adds the number to the field (a missing field counts as 0), in punk
    ## `Update.increment "visits" 1`.
    increment : I64, Str -> Update
    increment = |n, field| change(32, field, Bson.to_nodes(Bson.int(n)))

    ## The nodes of the changes, as the host receives them.
    to_nodes : List(Update) -> List(Bson.Node)
    to_nodes = |changes| List.fold(changes, [], |done, c| List.concat(done, c.nodes))

    change : U8, Str, List(Bson.Node) -> Update
    change = |kind, field, inner| {
        nodes: List.concat([{ kind, name: field, size: List.len(inner), text: "" }], inner),
    }
}
