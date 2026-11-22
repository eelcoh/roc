import Bson
import Doc
import Filter
import Update

## The app's Mongo database: documents in collections, read with `Doc`
## decoders, found with `Filter`s, changed with `Update`s.
##
##     links : Mongo.Collection
##     links =
##         Mongo.collection "links"
##
##     findLink! : Str => Result (Maybe Link) _
##     findLink! = fn id ->
##         links
##             |> Mongo.find (Filter.equals "_id" (Bson.text id))
##             |> Mongo.first! linkDecoder
##
## The name of a collection is text written in the program (rule P302), and
## the wiring says which collections the app may read and which it may change:
## any other is error "13" (Unauthorized).
##
## Errors: `MongoErr { code, message }` when the database refused the
## operation or couldn't be reached (`code` is Mongo's error code as text:
## "11000" for a duplicate key, "6" when there is no connection), and
## `DocErr message` when a document doesn't fit the decoder.
##
## (In this file the arguments are in Roc's order: the collection or query a
## function works on comes first. punk passes it last.)
Mongo := [].{
    ## A collection of the database, in punk `Mongo.collection "links"`.
    Collection :: { name : Str }

    ## A search: which documents of which collection, in what order, how many.
    ## Run it with `Mongo.all!`, `Mongo.first!` or `Mongo.count!`.
    Find :: { collection : Str, filter : Filter, sort : List(Bson.Node), skip : U64, limit : U64, none : Bool }

    collection : Str -> Collection
    collection = |name| { name: name }

    ## The documents of the collection the filter holds for, in punk
    ## `links |> Mongo.find (Filter.equals "owner" (Bson.text user))`.
    find : Collection, Filter -> Find
    find = |coll, filter| { collection: coll.name, filter, sort: [], skip: 0, limit: 0, none: Bool.False }

    ## In order of the field, smallest first. The last `sortBy` decides
    ## first, as with `List.sortBy`.
    sort_by : Find, Str -> Find
    sort_by = |query, field| { ..query, sort: List.concat([{ kind: 40, name: field, size: 0, text: "" }], query.sort) }

    ## In order of the field, largest first.
    sort_by_descending : Find, Str -> Find
    sort_by_descending = |query, field| { ..query, sort: List.concat([{ kind: 41, name: field, size: 0, text: "" }], query.sort) }

    ## Leaves out the first n documents.
    drop : Find, I64 -> Find
    drop = |query, n| { ..query, skip: if n <= 0 0 else query.skip + n.to_u64_wrap() }

    ## At most n documents. `take 0` gives none.
    take : Find, I64 -> Find
    take = |query, n| if n <= 0 {
        { ..query, none: Bool.True }
    } else {
        limit = n.to_u64_wrap()
        { ..query, limit: if query.limit == 0 or limit < query.limit limit else query.limit }
    }

    ## All documents the search finds, each through the decoder. In punk
    ## `query |> Mongo.all! decoder`.
    all! : Find, Doc.Decoder(a) => Try(List(a), [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    all! = |query, decoder| {
        if query.none {
            Ok([])
        } else {
            result = run_find!(query, query.limit)
            if result.ok {
                match Doc.decode_all(result.documents, decoder) {
                    Ok(values) => Ok(values)
                    Err(problem) => Err(DocErr(problem))
                }
            } else {
                Err(MongoErr({ code: result.error_code, message: result.error_message }))
            }
        }
    }

    ## The first document the search finds, or `Nothing`.
    first! : Find, Doc.Decoder(a) => Try([Just(a), Nothing], [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    first! = |query, decoder| {
        if query.none {
            Ok(Nothing)
        } else {
            result = run_find!(query, 1)
            if result.ok {
                match Doc.decode_all(result.documents, decoder) {
                    Ok([value, ..]) => Ok(Just(value))
                    Ok(_) => Ok(Nothing)
                    Err(problem) => Err(DocErr(problem))
                }
            } else {
                Err(MongoErr({ code: result.error_code, message: result.error_message }))
            }
        }
    }

    ## How many documents the search finds (its `drop` and `take` count).
    count! : Find => Try(I64, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    count! = |query| {
        if query.none {
            Ok(0)
        } else {
            changed(run_host!(2, query.collection, Filter.to_nodes(query.filter), [], [], query.skip, query.limit))
        }
    }

    ## Adds the document (an object) to the collection, in punk
    ## `Mongo.insert! document links`. Without an `_id`, Mongo gives it an
    ## ObjectId. An `_id` that is taken is error "11000".
    insert! : Collection, Bson.Value => Try({}, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    insert! = |coll, document| match changed(run_host!(3, coll.name, [], Bson.to_nodes(document), [], 0, 0)) {
        Ok(_) => Ok({})
        Err(e) => Err(e)
    }

    ## Adds the document unless its `_id` is taken: `True` when it was added.
    insert_if_new! : Collection, Bson.Value => Try(Bool, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    insert_if_new! = |coll, document| match changed(run_host!(4, coll.name, [], Bson.to_nodes(document), [], 0, 0)) {
        Ok(n) => Ok(n > 0)
        Err(e) => Err(e)
    }

    ## Changes every document the filter holds for, and gives how many there
    ## were. In punk `Mongo.update! filter [Update.set "url" (Bson.text url)] links`.
    update! : Collection, Filter, List(Update) => Try(I64, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    update! = |coll, filter, changes| changed(run_host!(5, coll.name, Filter.to_nodes(filter), Update.to_nodes(changes), [], 0, 0))

    ## Removes every document the filter holds for, and gives how many there
    ## were. In punk `Mongo.delete! filter links`.
    delete! : Collection, Filter => Try(I64, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    delete! = |coll, filter| changed(run_host!(6, coll.name, Filter.to_nodes(filter), [], [], 0, 0))

    run_find! : Find, U64 => { count : U64, documents : List(List(Bson.Node)), error_code : Str, error_message : Str, ok : Bool }
    run_find! = |query, limit| run_host!(1, query.collection, Filter.to_nodes(query.filter), [], query.sort, query.skip, limit)

    changed : { count : U64, documents : List(List(Bson.Node)), error_code : Str, error_message : Str, ok : Bool } -> Try(I64, [MongoErr({ code : Str, message : Str }), DocErr(Str)])
    changed = |result| if result.ok {
        Ok(result.count.to_i64_wrap())
    } else {
        Err(MongoErr({ code: result.error_code, message: result.error_message }))
    }

    ## What the host does: `op` is 1 find, 2 count, 3 insert, 4 insert if
    ## new, 5 update, 6 delete. `filter` are the nodes of a `Filter`,
    ## `document` those of the document (insert) or the changes (update),
    ## `sort` nodes of kind 40 (smallest first) and 41 (largest first), the
    ## first deciding first. A `limit` of 0 is no limit. It gives the
    ## documents found, or how many it counted, added or changed.
    run_host! : U8, Str, List(Bson.Node), List(Bson.Node), List(Bson.Node), U64, U64 => {
        count : U64,
        documents : List(List(Bson.Node)),
        error_code : Str,
        error_message : Str,
        ok : Bool,
    }
}
