import Sql
import Row
import Postgres

## The query language of punk (roadmap B1): queries on a `table` that punk
## declares, written as pipelines,
##
##     findLink : Str -> Db.Query (Maybe Link)
##     findLink = fn id ->
##         links
##             |> Db.filter (fn link -> link.id == id)
##             |> Db.first
##
## punk compiles each pipeline to one SQL statement with parameters, and the
## rows it gives to a decoder for the type of its result. `Db.run! query`
## runs it as nobody; `Db.runAs! user query` as the user, for the tables
## whose policies look at the user. `Db.filter`,
## `Db.map`, `Db.all`, `Db.first`, `Db.insert`, `Db.insertIfNew`, `Db.update`
## and `Db.delete` exist only in punk: the functions below are what punk
## writes for them, so a program never calls them itself.
Db := [].{
    ## A query and what its result is: the rows it gives, read into a value,
    ## or the number of rows it changed. Run it with `Db.run!`.
    Query(a) :: { sql : Sql.Query, read : List(Str), List(List(Row.Cell)), U64 -> Try(a, Str) }

    ## Runs the query on the app's database. In punk `Db.run! query`.
    run! : Query(a) => Try(a, [PgErr({ code : Str, message : Str }), RowErr(Str)])
    run! = |query| run_as!([], query)

    ## What punk writes for `Db.runAs! user query`: runs the query with the
    ## fields of the user that the tables' policies look at, as settings of
    ## its transaction (`("punk.user_id", user.id)`).
    run_as! : List((Str, Str)), Query(a) => Try(a, [PgErr({ code : Str, message : Str }), RowErr(Str)])
    run_as! = |settings, query| {
        result = Postgres.run_host!(settings, Sql.to_params(query.sql), Sql.to_sql(query.sql))
        if result.ok {
            match (query.read)(result.columns, result.rows, result.affected) {
                Ok(value) => Ok(value)
                Err(problem) => Err(RowErr(problem))
            }
        } else {
            Err(PgErr({ code: result.error_code, message: result.error_message }))
        }
    }

    ## The SQL punk made for the query, for a log line or a test.
    to_sql : Query(a) -> Str
    to_sql = |query| Sql.to_sql(query.sql)

    ## What punk writes for `Db.all`: every row the SQL gives.
    all_rows : List(Sql.Param), Str, Row.Decoder(a) -> Query(List(a))
    all_rows = |params, sql, decoder| {
        sql: Sql.query(params, sql),
        read: |columns, rows, _| Row.decode_rows(rows, decoder, columns),
    }

    ## What punk writes for `Db.first`: the first row, `Nothing` when there
    ## is none. The SQL ends in `LIMIT 1`.
    first_row : List(Sql.Param), Str, Row.Decoder(a) -> Query([Just(a), Nothing])
    first_row = |params, sql, decoder| {
        sql: Sql.query(params, sql),
        read: |columns, rows, _| match List.first(rows) {
            Err(_) => Ok(Nothing)
            Ok(row) => match Row.decode_rows([row], decoder, columns) {
                Ok([value]) => Ok(Just(value))
                Ok(_) => Ok(Nothing)
                Err(problem) => Err(problem)
            }
        },
    }

    ## What punk writes for `Db.insert`, `Db.update` and `Db.delete`: the
    ## number of rows the SQL changed.
    changes : List(Sql.Param), Str -> Query(I64)
    changes = |params, sql| {
        sql: Sql.query(params, sql),
        read: |_, _, affected| Ok(affected.to_i64_wrap()),
    }

    ## Reads the column `name` and goes on with its value.
    field : Row.Column(a), Str, (a -> Row.Decoder(b)) -> Row.Decoder(b)
    field = |column, name, next| Row.and_then(Row.field(column, name), next)

    ## The end of a decoder punk writes: the value it read.
    done : a -> Row.Decoder(a)
    done = |value| Row.succeed(value)

    read_text : Row.Column(Str)
    read_text = Row.text

    read_int : Row.Column(I64)
    read_int = Row.int

    read_float : Row.Column(F64)
    read_float = Row.float

    read_bool : Row.Column(Bool)
    read_bool = Row.bool

    read_nullable : Row.Column(a) -> Row.Column([Just(a), Nothing])
    read_nullable = |column| Row.nullable(column)

    setting_text : Str, Str -> (Str, Str)
    setting_text = |name, value| (name, value)

    setting_int : Str, I64 -> (Str, Str)
    setting_int = |name, value| (name, value.to_str())

    setting_float : Str, F64 -> (Str, Str)
    setting_float = |name, value| (name, value.to_str())

    setting_bool : Str, Bool -> (Str, Str)
    setting_bool = |name, value| (name, if value "true" else "false")

    param_text : Str -> Sql.Param
    param_text = |value| Sql.text(value)

    param_int : I64 -> Sql.Param
    param_int = |value| Sql.int(value)

    param_float : F64 -> Sql.Param
    param_float = |value| Sql.float(value)

    param_bool : Bool -> Sql.Param
    param_bool = |value| Sql.bool(value)

    param_nullable : [Just(a), Nothing], (a -> Sql.Param) -> Sql.Param
    param_nullable = |maybe, to_param| Sql.nullable(maybe, to_param)
}
