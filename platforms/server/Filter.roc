import Bson

## Which documents of a collection a Mongo query is about:
##
##     Filter.all
##         [ Filter.equals "owner" (Bson.text user)
##         , Filter.atLeast "created" (Bson.int since)
##         ]
##
## A filter is made only by these functions, and the host writes Mongo's
## operators for it (`$eq`, `$gte`, ...): a value is always compared as data,
## so a value from a request can't become an operator (`{"$ne": ""}`), and
## there is no `$where` or other JavaScript. The field names are text written
## in the program (rule P302).
##
## (In this file the arguments are in Roc's order: punk passes the field
## name first.)
##
## The filter as the host receives it: `Bson.Node`s of kind 20 (all of
## the filters that follow), 21 (any of them), 22 (the field `name`
## compared by `text` with the value that follows) and 23 (the field
## `name` exists when `text` is "true").
Filter :: { nodes : List(Bson.Node) }.{
    ## The field has this value. In punk `Filter.equals "url" (Bson.text url)`.
    equals : Bson.Value, Str -> Filter
    equals = |value, field| compare("equals", field, value)

    not_equals : Bson.Value, Str -> Filter
    not_equals = |value, field| compare("not_equals", field, value)

    less_than : Bson.Value, Str -> Filter
    less_than = |value, field| compare("less_than", field, value)

    at_most : Bson.Value, Str -> Filter
    at_most = |value, field| compare("at_most", field, value)

    greater_than : Bson.Value, Str -> Filter
    greater_than = |value, field| compare("greater_than", field, value)

    at_least : Bson.Value, Str -> Filter
    at_least = |value, field| compare("at_least", field, value)

    ## The field has one of these values, in punk
    ## `Filter.oneOf "status" [Bson.text "open", Bson.text "new"]`.
    one_of : List(Bson.Value), Str -> Filter
    one_of = |values, field| compare("one_of", field, Bson.list(values))

    ## The document has the field.
    exists : Str -> Filter
    exists = |field| { nodes: [{ kind: 23, name: field, size: 0, text: "true" }] }

    ## The document doesn't have the field.
    missing : Str -> Filter
    missing = |field| { nodes: [{ kind: 23, name: field, size: 0, text: "false" }] }

    ## All of the filters hold. `Filter.all []` is every document.
    all : List(Filter) -> Filter
    all = |filters| group(20, filters)

    ## At least one of the filters holds. `Filter.any []` is no document.
    any : List(Filter) -> Filter
    any = |filters| group(21, filters)

    ## Every document of the collection.
    everything : Filter
    everything = { nodes: [{ kind: 20, name: "", size: 0, text: "" }] }

    ## The nodes of the filter, as the host receives them.
    to_nodes : Filter -> List(Bson.Node)
    to_nodes = |filter| filter.nodes

    compare : Str, Str, Bson.Value -> Filter
    compare = |op, field, value| {
        inner = Bson.to_nodes(value)
        { nodes: List.concat([{ kind: 22, name: field, size: List.len(inner), text: op }], inner) }
    }

    group : U8, List(Filter) -> Filter
    group = |kind, filters| {
        inner = List.fold(filters, [], |done, filter| List.concat(done, filter.nodes))
        { nodes: List.concat([{ kind, name: "", size: List.len(inner), text: "" }], inner) }
    }
}
