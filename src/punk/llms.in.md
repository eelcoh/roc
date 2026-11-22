# punkroc (punk)

> punkroc ("punk") is an Elm-like language on top of the Roc compiler: Elm's
> syntax, names and argument order, Roc's types, platforms and speed. Files end
> in `.punk`. This file is everything you need to write punk programs.

If you know Elm, write Elm and read the section "Differences from Elm".
Everything not listed there works as in Elm.

## Tools

The `punk` command is the Roc compiler (`zig-out/bin/punk`, also `roc`).

| Command | What it does |
|---------|--------------|
| `punk check --json app.punk` | Type-check without building. Problems as JSON on stdout (see "Errors"). Exit code 1 when there are errors. Fast (under a second). |
| `punk fmt app.punk ...` | Lay files out in the one canonical form. `--check` only lists files that are not formatted. |
| `punk app.punk [args]` | Build and run the app. |
| `punk test app.punk` | Run the `expect` tests in the file. |

Work in this loop: write the file, `punk fmt` it, `punk check --json` it, fix
the first problem, repeat; then run it. Fix problems from the top: a later one
is often caused by an earlier one.

## A program

```
app [main!] { pf: platform "../../platforms/cli/main.roc" }

import pf.Stdout

main! = fn () ->
    Stdout.line! "Hello"
```

The path after `platform` is relative to the `.punk` file; it points to
`platforms/cli/main.roc` in the punkroc repository. A file is an `app`
(it has `main!`) or a `module` (see "Modules").

## Syntax

```
-- a line comment
{- a block comment -}
{-| a doc comment, before a definition -}

answer : Int                      -- type annotation, then the definition
answer = 42

add : Int -> Int -> Int           -- functions are curried, as in Elm
add = fn a, b ->                  -- a lambda: `fn` params `->` body
    a + b

inc = add 1                       -- partial application
twice = fn f, x -> f (f x)        -- application by spaces: `f a b`, never `f(a, b)`

area = fn shape ->
    case shape of                 -- `case ... of`, as in Elm
        Circle r -> 3.14 * r * r
        Rect w h -> w * h

sign = fn n ->
    if n < 0 then -1 else if n == 0 then 0 else 1
```

Indentation is significant (4 spaces per level; tabs are an error). A body
on the next line is a block: any number of `name = value` lines and then the
result. There is no `let ... in`:

```
distance = fn a, b ->
    dx = a.x - b.x
    dy = a.y - b.y
    F64.sqrt (dx * dx + dy * dy)
```

Pipelines go line by line. `x |> f a` is `f a x`: the value goes last.

```
total =
    input
        |> String.lines
        |> List.map String.trim
        |> List.filter (fn line -> not (String.isEmpty line))
        |> List.length
```

### Values

| Kind | Syntax |
|------|--------|
| numbers | `42`, `-3`, `3.14`, `0xff`, `1_000_000` |
| strings | `"text"`, interpolation `"n = ${String.fromInt n}"` (only a `Str` goes inside `${}`), `"""` multi-line `"""` |
| characters | `'a'` |
| lists | `[1, 2, 3]`, `xs ++ ys` |
| tuples | `(1, "a")`; fields `.0`, `.1`: `pair.0`, `List.map .0 pairs` |
| records | `{ name = "Ann", age = 7 }`, `person.name`, `.name` (accessor function), update `{ person | age = 8 }`, field punning `{ name, age }` |
| tags | `Red`, `Circle 2.0`, `Ok 1`, `Err (BadLine line)`, `Just x`, `Nothing` |
| unit | `()` (argument of `main!` and other effects with no input), `{}` (empty record, the result of an effect such as `Stdout.line!`) |

### Operators

`+ - * /` (`/` on floats), `//` (integer division), `%` (remainder),
`== /= < <= > >=`, `&& ||`, `not x`, `++` (lists and strings), `|>`, `<|`.
A range of numbers is `List.range 1 5` (`[1, 2, 3, 4, 5]`). Dividing an
integer by zero gives 0, as in Elm.

### Types

```
type Shape = Circle Float | Rect Float Float     -- a union (custom type)

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)

type alias Point = { x : Int, y : Int }         -- a record type

parse : Str -> Result (List Int) _              -- `_`: let the compiler infer it
```

Builtin types: `Int` (64-bit, `I64`), `Float` (`F64`), `Bool` (`True`,
`False`), `Str`, `List a`, `Dict k v`, `Set a`, `Maybe a` (`Just a |
Nothing`), `Result ok err` (`Ok ok | Err err`), `Order` (`LT | EQ | GT`), and
Roc's sized numbers `U8 U16 U32 U64 I8 I16 I32 I64 F32 F64 Dec`.

Your own types, tuples, records, lists and strings support `==` and can be
`Dict` keys and `Set` members: `Dict (Int, Int) Int` is the usual grid.

### Numbers and characters

A number literal gets its type from where it is used; give a top-level
value an annotation (`total : U64`) when it matters. `Int` and `I64` are the
same type, as are `Float` and `F64`. Convert between sized numbers with the
functions of the source type:

| From to | Function |
|---------|----------|
| `U64` to `Int`, `Int` to `U64` | `toInt n`, `fromInt n` |
| always fits (`U8` to `I64`, `I32` to `I64`, ...) | `U8.toI64 b`, `I32.toI64 n` |
| may not fit | `I64.toU8Try n` (a `Result`), or `I64.toU8Wrap n` (wraps around) |
| to and from text | `I64.toStr n`, `U64.fromStr s` (a `Result`), `String.fromInt`, `String.toInt` (a `Maybe`) |

A character literal `'a'` is a number (its code). `Str.toUtf8 s` gives the
bytes of a string as `List U8`, and `'0'` compares with them, so the digit of
a byte `b` is `U8.toI64 (b - '0')`.

### Errors are tags

Errors are tags; you do not have to declare an error type. A function that can
fail returns `Result value _` and makes up the error tags it needs:
`Err (BadLine line)`. A caller matches on them or passes them on with `try`.

### Patterns

In `case`, in lambda parameters and on the left of `=`:

```
case xs of
    [] -> "empty"
    [x] -> "one"
    [first, second, ..] -> "two or more"
    [first, ..rest] -> "first and the rest"

fn (a, b) -> a + b                      -- tuple
fn { x, y } -> x + y                    -- record
case r of
    Ok n if n > 0 -> "positive"         -- guard
    Ok _ -> "not positive"
    Err (BadLine line) -> line
    Err _ -> "other error"
```

### Errors with `try`

`try` before a call that returns a `Result` unwraps an `Ok`, or returns the
`Err` from the enclosing function at once:

```
parseLine : Str -> Result (I64, I64) _
parseLine = fn line ->
    case String.split "," line of
        [a, b] -> Ok (try I64.fromStr a, try I64.fromStr b)
        _ -> Err (BadLine line)

parseAll : Str -> Result (List (I64, I64)) _
parseAll = fn text ->
    pairs =
        text
            |> String.lines
            |> try List.mapTry parseLine  -- `try` in a pipeline checks the result
    Ok pairs
```

`try` takes one call (`try f a b`); for more use parentheses:
`try (s |> String.trim |> parse)`. There is no postfix `?`.

### Loops: `fold`

There is no `var`, `for`, `while` or `return`. Use `List.map`, `List.filter`,
recursion, or `fold`:

```
fold xs into 0 with fn x, total -> total + x       -- inline form

xs |> fold into 0 with add                          -- the list from a pipe

fold x in xs into total = 0                         -- block form, one accumulator:
    total + x                                       -- the body is its new value

fold x in xs into count = 0, sum = 0                -- more accumulators: the body is a
    if x > 0 then { count = count + 1, sum = sum + x } else {}
                                                    -- record of the ones that change;
                                                    -- the fold's value is a record of all
```

### Effects

A name ending in `!` does something (prints, reads a file). Call effects only
from other `!` functions; `main!` is the start. Each effect is one line in a
block:

```
main! = fn () ->
    text = Stdin.readAll! ()
    Stdout.line! "read ${String.fromInt (String.length text)} bytes"
```

### Tests

```
expect add 1 2 == 3
```

Top-level `expect`s run with `punk test`. `crash` and `dbg` are only allowed
inside an `expect` (rules P101, P102).

### Modules

```
module Grid exposing (Grid, at, Cell(..))      -- (..) exposes the tags too

import Grid exposing (Grid, at)                -- in another file: Grid.punk next to it
import Grid                                    -- then use Grid.at
```

Everything a module exposes needs a type annotation (rule P201).

## Differences from Elm

| Elm | punk |
|-----|------|
| `\x -> x + 1` | `fn x -> x + 1`, several parameters `fn a, b -> ...` |
| `let a = 1 in a + 2` | a block: `a = 1` on one line, `a + 2` on the next |
| `String` type | `Str` (the module is still `String`: `String.split`) |
| `Int` is JS-sized | `Int` is 64-bit; `List.len`, `List.get`, `List.countIf`, `Dict.len` use `U64` (convert with `toInt` / `fromInt`) |
| `"a" ++ String.fromInt n` | works, but `"a${String.fromInt n}"` is the usual way |
| `Debug.log` | `dbg`, only inside `expect` |
| `Maybe` everywhere | Roc's functions return `Result` (`List.first`, `List.get`, `Dict.get`); the Elm-only ones return `Maybe` (`List.head`, `String.toInt`) |
| `List.filterMap` with `Maybe` | `List.filterMap` keeps the `Ok`s of a function that returns a `Result` |
| `case` on `x :: xs` | list patterns `[x, ..xs]`; `::` does not exist |
| `(+)`, `(::)` | write a lambda: `fn a, b -> a + b` |
| `Html`, `Browser` | not yet; programs are command-line apps, servers or terminal apps on a platform |
| `Cmd`, `Browser.element` | the tui platform: `init`, `update`, `view` and `Cmd` (see "The tui platform") |
| `port`, `Task` | effects are `!` functions |
| `type alias Model = {...}` | same |
| `/=` | same (`!=` works too; write `/=`) |
| a module per file, `exposing` | same; the file name is the module name |

## Differences from Roc

You may know Roc. punk is Roc with Elm's surface; do not write Roc syntax:

| Roc | punk |
|-----|------|
| `\|a, b\| a + b` | `fn a, b -> a + b` |
| `f(a, b)` | `f a b` |
| `List.map(xs, f)`, `xs.map(f)` | `List.map f xs`, `xs \|> List.map f` |
| `match x { A => 1, B => 2 }` | `case x of` with `A -> 1` lines |
| `if c { a } else { b }` | `if c then a else b` |
| `x?` | `try x` |
| `List.keep_if`, snake_case | `List.filter` (Elm name) or `List.keepIf`; camelCase everywhere |
| `List.walk(xs, 0, \|s, x\| ...)` | `List.foldl (fn x, s -> ...) 0 xs`: the state comes last in the lambda |
| `Shape := [Circle(F64)]` | `type Shape = Circle F64` |
| `# comment` | `-- comment` |
| `var`, `for`, `while`, `return` | `fold`, recursion, `List.*` |

Roc functions without an Elm name exist too, in camelCase, with the value
they work on last: `Str.splitOn "," text`, `List.dropIf`, `U64.toStr n`.
Number functions keep Roc's order: `U64.toStr n`, `U64.fromStr s`,
`I64.toStr n`, `F64.toStr x`, `U64.absDiff a b`, `F64.sqrt x`.

## Errors

`punk check --json` writes one JSON document:

```
{
  "file": "app.punk",
  "errors": 1,
  "warnings": 0,
  "problems": [
    {
      "severity": "error",
      "code": "roc/name-not-in-scope",
      "title": "Name Not In Scope",
      "file": "app.punk",
      "line": 7, "column": 34, "endLine": 7, "endColumn": 44,
      "message": "Nothing is named notDefined in this scope. ...",
      "fix": null
    }
  ]
}
```

Positions are 1-based and in the `.punk` file. `code` is stable:

| Code | Meaning |
|------|---------|
| `P001` | punk syntax error (the message says what was expected) |
| `P101` | `crash` outside an `expect`: return a `Result` or `Maybe` instead |
| `P102` | `dbg` outside an `expect` |
| `P201` | an exposed value of a module has no type annotation |
| `P301` | the SQL of `Sql.query` is not a string literal: pass values as parameters (`$1`) |
| `P401` | a `table` declaration: its row type is not a record of storable columns, its key is not a column, or a policy line is missing |
| `P402` | a query that can't run in the database: not a pipeline from a table to `Db.all`/`first`/`update`/`delete`, or a function the database can't run |
| `P403` | a query uses a column the table doesn't have, or a value of the wrong type |
| `P404` | a query does what the table's policy forbids (`delete nobody`), or `Db.runAs!` where no policy looks at the user |
| `P405` | the tables differ from `schema.sql`: run `punk check --schema`, with a `migrate` when rows change; or a `migrate` that is done |
| `roc/<title>` | a problem the type checker found, such as `roc/type-mismatch`, `roc/name-not-in-scope`, `roc/missing-method` |

Warnings (`severity: "warning"`) do not stop the program. A warning
`roc/unconditional-condition` on `main!` for a value known at compile time
(such as an example input in the file) is harmless.

Some type-checker messages mention Roc syntax (`.toStr()`, `List.len`): read
them as the punk spelling (`String.fromInt`, `List.length`).

## The platform

`platforms/cli` (`app [main!] { pf: platform "platforms/cli/main.roc" }`,
relative to your file) provides:

```
Stdout.line! : Str => {}             -- prints a line
Stdout.write! : Str => {}            -- prints without a newline
Stderr.line! : Str => {}
Stdin.line! : () => Str              -- one line, "" at the end of the input
Stdin.readAll! : () => Str
File.read! : Str => Result Str [FileErr Str]
File.write! : Str -> Str => Result {} [FileErr Str]   -- path, text
Arg.list! : () => List Str           -- the arguments after the program name
Clock.now! : () => I64               -- milliseconds since 1970 (Elm's posixToMillis)
Clock.elapsed! : () => I64           -- milliseconds since the program started
Random.u64! : () => U64              -- 64 random bits from the OS
```

`File.read!` and `File.write!` only work on files named on the command line
(`punk app.punk input.txt`); any other path gives `Err (FileErr msg)`. Take
the path from `Arg.list!`, never write a file name into the program.

Import what you use: `import pf.Stdout`, `import pf.File`, ...

A package name may be capitalized, as modules are: `{ Platform: platform
"...", Json: "..." }` with `import Platform.Stdout` and `import Json.Decode
as D`. That is the style for new code; `pf` and `json` keep working.

### The server platform

`platforms/server` is for HTTP servers (on ambit's server platform). The app
is one function, called for every request:

```
app [handle!] { pf: platform "platforms/server/main.roc", json: "packages/json/main.roc" }

import pf.Http exposing [Request, Response]

handle! : Request => Response
handle! = fn req ->
    case req.method of
        "GET" if req.path == "/hello" -> { status = 200, headers = [], body = Str.toUtf8 "hello\n" }
        _ -> { status = 404, headers = [], body = [] }
```

```
Request : { method : Str, path : Str, query : Str, headers : List (Str, Str), body : List U8 }
Response : { status : U16, headers : List (Str, Str), body : List U8 }
Kv.get! : Str => Result (Maybe Str) [KvErr Str]
Kv.put! : Str -> Str => Result {} [KvErr Str]      -- key, value
Kv.delete! : Str => Result {} [KvErr Str]
Clock.now! : () => I64                              -- milliseconds since 1970
Random.u64! : () => U64
Config.text! : () => Str                            -- the configuration, JSON: decode it with json.Decode
Log.info! : Str => {}                               -- also Log.warn!, Log.error!
```

Header names in a request are lower case. The app has no other way to reach
the world: no files, no network, no environment. It is not run with
`punk app.punk`: `punk build` makes an archive that a small Rust crate links
and tests (see `platforms/server/README.md` and `examples/punk/shortener/`).
Annotate an effect with more arguments as `Settings -> Str => Result Response _`.

### Postgres: tables and queries

Declare a table in punk, with the type of its rows, its key and who may
read, insert, update and delete its rows (a table without all four doesn't
compile, P401). Queries are pipelines from the table; punk turns each one
into one SQL statement with parameters, and checks the columns and their
types. `punk check --schema app.punk` writes `schema.sql` next to the app:
the versions of the tables, which the wiring applies in order.

```
import pf.Db

type alias Link =
    { id : Str
    , url : Str
    , created : Int
    }

table links : Link
    key id
    read everyone
    insert everyone
    update nobody
    delete nobody

findLink : Str -> Db.Query (Maybe Link)
findLink = fn id ->
    links
        |> Db.filter (fn link -> link.id == id)
        |> Db.first

-- in an effect: case try Db.run! (findLink id) of ...
```

A policy can also be a function of the user and the row. It becomes a
Postgres row-level security policy, so the database itself keeps to it, also
for SQL by hand. Run a query as the user with `Db.runAs!`; with `Db.run!` the
user is nobody, and a policy that looks at the user is false.

```
table notes : Note
    key id
    read fn user, note -> note.public || note.owner == user.id
    insert fn user, note -> note.owner == user.id
    update fn user, note -> note.owner == user.id
    delete nobody

-- in an effect: notes = try Db.runAs! { id = "ann" } (notes |> Db.all)
```

The fields of the user (`user.id`) get their type from the column they meet,
and Roc checks that the record given to `Db.runAs!` has them. A policy uses
the columns, the fields of the user and constants. The app's database role
must keep to row-level security: the host refuses a superuser or a role with
`BYPASSRLS`.

When a table changes, the program doesn't compile (P405) until `punk check
--schema` has added a version to `schema.sql`. A new table, a new `Maybe`
column and a new policy need nothing more; any other change needs a
migration from the old row to the new one, which is removed again once the
version is in `schema.sql`:

```
migrate links
    fn old -> { old | createdAt = old.created, owner = "anonymous" }
```

`createdAt = old.created` renames a column, another value is computed in the
database for the rows there are (as in a query, without values from
outside), and an old column the new row doesn't take is dropped.

```
Db.join : table -> (row -> row2 -> Bool) -> query -- JOIN ... ON; the steps after it take a row of each
Db.filter : (row -> Bool) -> query -> query       -- several filters: AND
Db.sortBy : (row -> key) -> query -> query        -- ORDER BY ... ASC; the last sortBy decides first
Db.sortByDescending : (row -> key) -> query -> query
Db.drop : Int -> query -> query                   -- OFFSET
Db.take : Int -> query -> query                   -- LIMIT
Db.map : (row -> b) -> query -> query             -- .url, or a record { url = l.url, ... }
Db.all : query -> Db.Query (List row)             -- ends a query
Db.first : query -> Db.Query (Maybe row)          -- LIMIT 1
Db.insert : row -> table -> Db.Query Int          -- the number of rows changed
Db.insertIfNew : row -> table -> Db.Query Int     -- ON CONFLICT DO NOTHING: 0 when the key is taken
Db.update : (row -> row) -> query -> Db.Query Int -- (fn l -> { l | url = new }), after filters
Db.delete : query -> Db.Query Int
Db.run! : Db.Query a => Result a _                -- errors: PgErr { code, message }, RowErr Str
Db.runAs! : user -> Db.Query a => Result a _      -- as the user, for the policies; 42501 when one refuses
Db.transaction! : ({} => Result a e) => Result a e        -- Ok commits, Err rolls back
Db.transactionAs! : user -> ({} => Result a e) => Result a e
Db.toSql : Db.Query a -> Str
```

Joins, sorting and paging stay one SQL statement. The steps come in this
order: `join`, `filter`, `sortBy`, `drop`, `take`, `map`; after a `join` each
function takes a row of each table, and the query ends with a `map` that
names what it gives:

```
publicNotes : Db.Query (List { name : Str, body : Str })
publicNotes =
    notes
        |> Db.join people (fn note, person -> note.owner == person.id)
        |> Db.filter (fn note, _ -> note.public)
        |> Db.sortBy (fn note, _ -> note.body)
        |> Db.sortBy (fn _, person -> person.name)   -- by name, then by body
        |> Db.take 20
        |> Db.map (fn note, person -> { name = person.name, body = note.body })
        |> Db.all
```

A transaction runs a function of queries on one connection: all of its
changes hold when it gives `Ok`, none when it gives `Err`. The queries in
`Db.transactionAs! user` run as that user (`Db.runAs! user`); transactions
don't nest.

```
pinOnly! = fn user, id ->
    _ = try Db.runAs! user (unpinAll user.id)
    count = try Db.runAs! user (pin id)
    if count == 0 then Err NotFound else Ok count

-- Db.transactionAs! user (fn _ -> pinOnly! user id)
```

Column types: `Str`, `Int`, `Float`, `Bool`, and `Maybe` of one of these
(a column that can be NULL; compare it with `== Nothing`). The functions of
`filter`, `map` and `update` are written in the query (`fn link -> ...`) and
use only the row's fields, values from outside the query (they become
parameters), `==`, `/=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `not`, `+`, `-`,
`*` and `++`; anything else is P402: compute it before the query. A query
has at most one `map`, `take` and `drop`; `update` and `delete` only take
filters. A table's name is not a value: it only starts a query. For what the
query language can't do yet (left joins, aggregates, grouping), write the
SQL yourself with `Sql.query`:

### Postgres: SQL by hand

The database the wiring gives the app. A query is SQL written in the program
plus its parameters (`$1`, `$2`, ...); a row decoder reads the rows, as
`json.Decode` reads JSON. The SQL of `Sql.query` has to be a string literal
without `${...}` (rule P301): values always go in as parameters.

```
import pf.Postgres
import pf.Sql
import pf.Row

linkRow : Row.Decoder Link
linkRow =
    Row.map2 (fn created, url -> { created, url })
        (Row.field "created" Row.int)
        (Row.field "url" Row.text)

findLink : Str -> Sql.Query
findLink = fn id ->
    Sql.query "SELECT created, url FROM links WHERE id = $1" [Sql.text id]

-- in an effect: case try Postgres.row! linkRow (findLink id) of ...
```

```
Sql.query : Str -> List Sql.Param -> Sql.Query      -- the Str must be a literal (P301)
Sql.text : Str -> Sql.Param                        -- also Sql.int (Int), Sql.float, Sql.bool, Sql.null
Sql.nullable : (a -> Sql.Param) -> Maybe a -> Sql.Param
Row.field : Str -> Row.Column a -> Row.Decoder a   -- by column name
Row.int, Row.float, Row.text, Row.bool : Row.Column _   -- Row.nullable : Row.Column a -> Row.Column (Maybe a)
Row.map, Row.map2 ... Row.map5, Row.succeed, Row.fail, Row.andThen
Postgres.rows! : Row.Decoder a -> Sql.Query => Result (List a) _
Postgres.row! : Row.Decoder a -> Sql.Query => Result (Maybe a) _      -- more than one row is a RowErr
Postgres.execute! : Sql.Query => Result U64 _                         -- the number of rows changed
-- errors: PgErr { code : Str, message : Str } (code is the SQLSTATE, "23505" = unique violation), RowErr Str
```

Columns are read as bool, int (`int2/4/8`), float (`float4/8`) or text
(`text`, `varchar`); convert anything else in the SQL (`created::text`,
`extract(epoch from t)::int8`). A parameter must have the type the query
expects (`Sql.int` for an `integer` column). Each query commits on its own:
there are no transactions yet.

### JSON: the `json` package

Elm's `Json.Decode` and `Json.Encode`, as the modules `Decode` and `Encode`
of the package `packages/json` (add `json: "packages/json/main.roc"` to the
app header, relative to your file):

```
import json.Decode as D
import json.Encode as E

type alias Link = { url : Str, created : Int }

link : D.Decoder Link
link =
    D.map2 (fn url, created -> { url, created })
        (D.field "url" D.string)
        (D.field "created" D.int)

D.decodeString link text                    -- Result Link D.Error; D.errorToString for a message
E.encode 0 (E.object [("url", E.string l.url), ("created", E.int l.created)])
```

Decoders: `string int float bool null value list keyValuePairs field at index
maybe nullable oneOf succeed fail map map2 map3 map4 map5 andThen`. Encoders:
`string int float bool null list object dict`, and `E.encode indent value`.
There is no `andMap`: use `map2` to `map5`, or `andThen`. `Value` (`import
json.Value`) is the JSON tree; `Value.parse : Str -> Result Value Str`.
Do not compare a `Value` or a `D.Error` with `==` (the compiler hangs); compare
the encoded text instead.

### The tui platform

`platforms/tui` is for terminal apps (on ambit's tui platform), in the Elm
architecture. The app exposes its `Model` and `Msg` types and `main`:

```
app [Model, Msg, main] { Platform: platform "platforms/tui/main.roc" }

import Platform.Tui exposing [Event]
import Platform.Cmd
import Platform.View
import Platform.File

main = { init = init, update = update, view = view }

init : (Model, Cmd Msg)                            -- a value, not a function
init = ({ books = [] }, File.read "library.json" Loaded)

update : Event Msg -> Model -> (Model, Cmd Msg)
update = fn event, model ->
    case event of
        Key (Char "q") -> (model, Cmd.quit)
        Key Down -> ...
        Msg (Loaded (Ok text)) -> ...
        _ -> (model, Cmd.none)

view : Model -> View
```

```
Event msg = Key Tui.Key | Paste Str | Resize Int Int | Msg msg   -- Resize: columns, rows; always first
Tui.Key = Char Str | Ctrl Str | Alt Str | Enter | Esc | Backspace | Delete | Tab | BackTab
        | Up | Down | Left | Right | Home | End | PageUp | PageDown | Insert | F Int
Cmd.none, Cmd.quit : Cmd msg
Cmd.batch : List (Cmd msg) -> Cmd msg
Cmd.after : Int -> msg -> Cmd msg                  -- milliseconds
Cmd.map : (a -> b) -> Cmd a -> Cmd b
File.read : Str -> (Result Str Str -> msg) -> Cmd msg            -- only in the app's folder
File.list : Str -> (Result (List Str) Str -> msg) -> Cmd msg     -- "" is the folder; folders end in /
Clock.now : (Int -> msg) -> Cmd msg                -- milliseconds since 1970
View.text : Str -> View                            -- lines of plain text
View.paragraph : List View.Line -> View            -- View.Line = List View.Span
View.list : Int -> List View.Line -> View          -- the line at this index highlighted, kept in sight
View.column, View.row : List View -> View          -- above / beside each other, sharing the room
View.height, View.width : Int -> View -> View      -- this many rows (in a column) / columns (in a row)
View.block : Str -> View -> View                   -- a frame with a title
View.empty : View
View.span : List View.Attr -> Str -> View.Span     -- View.span [View.bold, View.fg Yellow] "text"
View.plain : Str -> View.Span
View.bold, View.dim, View.italic, View.underline, View.reversed : View.Attr
View.fg, View.bg : View.Color -> View.Attr         -- Black Red Green Yellow Blue Magenta Cyan Gray DarkGray
                                                   -- LightRed ... LightCyan White
```

A tag with arguments is a function, as in Elm: `File.read path Loaded`.
Effects are commands: the app has no `!` functions; the platform does the
work off the screen's thread and answers with a `Msg`. Like a server, a
terminal app is not run with `punk app.punk`: a small Rust crate links it
and tests it on ambit's sim (see `platforms/tui/README.md` and
`examples/punk/library/`). `compare` does not take `Str` (Roc's strings have
no order): compare `Str.toUtf8` bytes.

## Standard library

The functions an Elm or Roc programmer reaches for first. The value a
function works on is its last argument, so they fit `|>` and partial
application.

@@stdlib@@

## Cookbook

### Read a file given on the command line, solve, print

The shape of an Advent of Code solution: the example input in the file, the
real input from a file argument. (The cookbook files live in
`examples/punk/aoc2024/`, hence their longer platform path; some use the
`test/fx/platform` test platform, which has `Stdout` too. Use
`platforms/cli` for your own programs.)

@@example aoc2024/Day01.punk@@

### A grid: `Dict (Int, Int) a`, neighbours, recursion

Written by an agent that had only this file, on the first try.

@@example aoc2024/Day10.punk@@

### Folds

@@example fold.punk@@

### Elm's names

@@example elm.punk@@

### Standard input and files

@@example platform/io.punk@@

### JSON decoders and encoders

@@example json/json.punk@@

### A server: ambit's link shortener

@@example shortener/Shortener.punk@@

### The same shortener with its links in Postgres

@@example shortener-postgres/Shortener.punk@@

### A terminal app

The smallest one; `examples/punk/library/Library.punk` is crossload's
library view (sorting, marking, searching), with its tests on ambit's sim.

@@example counter/Counter.punk@@

## Style

- `punk fmt` decides the layout; do not fight it.
- Annotate every top-level function.
- Prefer pipelines over nested calls, `case` over nested `if`, and Elm's
  names (`List.filter`, `String.split`, `Maybe`) where they exist.
- Return `Result` with made-up error tags instead of crashing.
- One way to do a thing: `fold` or `List.*` for loops, `try` for errors.
