import Sql
import Row

## The app's database: running `Sql.Query`s on the Postgres database the wiring
## gives the app. The host keeps a pool of connections; each call takes one,
## runs the query and gives it back. There are no transactions yet: each
## query commits on its own.
##
## Errors: `PgErr { code, message }` when the database refused the query or
## couldn't be reached (`code` is Postgres's SQLSTATE, such as "23505" for a
## unique violation, or "08000" when there is no connection), and
## `RowErr message` when a row doesn't fit the decoder.
Postgres := [].{
    ## All rows the query gives, each through the decoder. In punk
    ## `Postgres.rows! decoder query`.
    rows! : Sql.Query, Row.Decoder(a) => Try(List(a), [PgErr({ code : Str, message : Str }), RowErr(Str)])
    rows! = |query, decoder| {
        result = run_host!([], Sql.to_params(query), Sql.to_sql(query))
        if result.ok {
            match Row.decode_rows(result.rows, decoder, result.columns) {
                Ok(values) => Ok(values)
                Err(problem) => Err(RowErr(problem))
            }
        } else {
            Err(PgErr({ code: result.error_code, message: result.error_message }))
        }
    }

    ## The one row the query gives, `Nothing` when it gives none, and a
    ## `RowErr` when it gives more than one. In punk
    ## `Postgres.row! decoder query`.
    row! : Sql.Query, Row.Decoder(a) => Try([Just(a), Nothing], [PgErr({ code : Str, message : Str }), RowErr(Str)])
    row! = |query, decoder| {
        result = run_host!([], Sql.to_params(query), Sql.to_sql(query))
        if result.ok {
            match result.rows {
                [] => Ok(Nothing)
                [_] => match Row.decode_rows(result.rows, decoder, result.columns) {
                    Ok([value]) => Ok(Just(value))
                    Ok(_) => Ok(Nothing)
                    Err(problem) => Err(RowErr(problem))
                }
                _ => Err(RowErr("expected at most one row, the query gave ${List.len(result.rows).to_str()}"))
            }
        } else {
            Err(PgErr({ code: result.error_code, message: result.error_message }))
        }
    }

    ## Runs a query that changes something (`INSERT`, `UPDATE`, `DELETE`, ...)
    ## and gives the number of rows it changed. Rows it returns are ignored.
    execute! : Sql.Query => Try(U64, [PgErr({ code : Str, message : Str })])
    execute! = |query| {
        result = run_host!([], Sql.to_params(query), Sql.to_sql(query))
        if result.ok {
            Ok(result.affected)
        } else {
            Err(PgErr({ code: result.error_code, message: result.error_message }))
        }
    }

    ## What the host gives for a query: the column names and the rows, or the
    ## error. The host prepares the SQL, gives each parameter the type the
    ## statement wants and reads each column as text, int, float or bool. The
    ## settings (`("punk.user_id", "u1")`, from `Db.runAs!`) hold for the
    ## query's transaction only: the policies of the tables read them.
    run_host! : List((Str, Str)), List(Sql.Param), Str => {
        affected : U64,
        columns : List(Str),
        error_code : Str,
        error_message : Str,
        rows : List(List(Row.Cell)),
        ok : Bool,
    }
}
