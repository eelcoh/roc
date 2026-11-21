## Queries: SQL text that is part of the program, with the values for its
## parameters (`$1`, `$2`, ...) next to it. A value never becomes part of the
## SQL text, so a request can't change what a query does.
Sql := [].{
    ## A query, ready for `Postgres.rows!`, `Postgres.row!` or
    ## `Postgres.execute!`. Only `Sql.query` makes one, and punk only accepts
    ## SQL written in the program there (rule P301), so there is no way to run
    ## SQL made from text.
    Query :: { sql : Str, params : List(Param) }

    ## The value of one parameter. `kind` is 0 for NULL, 1 text, 2 int, 3 float
    ## and 4 bool; `text` is the value written as text. The host turns it into
    ## the type the database expects for that parameter, or fails the query.
    Param :: { kind : U8, text : Str }

    ## The query with this SQL and these parameters, in punk
    ## `Sql.query "SELECT url FROM links WHERE id = $1" [Sql.text id]`. The
    ## parameters come first here, so that punk writes the SQL first.
    query : List(Param), Str -> Query
    query = |params, sql| { sql, params }

    ## The SQL of the query, for a log line.
    to_sql : Query -> Str
    to_sql = |q| q.sql

    ## The parameters of the query, as the host receives them.
    to_params : Query -> List(Param)
    to_params = |q| q.params

    text : Str -> Param
    text = |value| { kind: 1, text: value }

    int : I64 -> Param
    int = |value| { kind: 2, text: value.to_str() }

    float : F64 -> Param
    float = |value| { kind: 3, text: value.to_str() }

    bool : Bool -> Param
    bool = |value| { kind: 4, text: if value "true" else "false" }

    ## SQL's NULL, for a parameter of any type.
    null : Param
    null = { kind: 0, text: "" }

    ## `Nothing` as NULL, `Just x` as the parameter `x` gives, in punk
    ## `Sql.nullable Sql.text maybeName`.
    nullable : [Just(a), Nothing], (a -> Param) -> Param
    nullable = |maybe, to_param| match maybe {
        Just(value) => to_param(value)
        Nothing => { kind: 0, text: "" }
    }
}
