# punkroc's server platform

The platform for punk HTTP servers. Its host is written in Rust, on
[ambit](https://github.com/eelcoh/ambit)'s `server` platform and capabilities:
ambit owns the listener, the threads and the limits (body size, timeouts, a
full queue answers 503), and calls the punk app once per request.

```
app [handle!] { pf: platform "../../../platforms/server/main.roc", json: "../../../packages/json/main.roc" }

import pf.Http exposing [Request, Response]
import pf.Kv

handle! : Request => Response
handle! = fn req ->
    case (req.method, req.path) of
        ("GET", "/hello") -> { status = 200, headers = [], body = Str.toUtf8 "hello\n" }
        _ -> { status = 404, headers = [], body = [] }
```

| Module | Functions |
|--------|-----------|
| `Http` | the types `Request` (`method`, `path`, `query`, `headers`, `body : List U8`) and `Response` (`status : U16`, `headers`, `body : List U8`) |
| `Kv` | `get! : Str => Result (Maybe Str) [KvErr Str]`, `put! key value`, `delete! key` (both `Result {} [KvErr Str]`) |
| `Clock` | `now! : () => I64` (milliseconds since 1970) |
| `Random` | `u64! : () => U64` |
| `Config` | `text! : () => Str`, the configuration the wiring gives the app (JSON, read with `json.Decode`) |
| `Log` | `info!`, `warn!`, `error! : Str => {}` |
| `Postgres` | `rows! : Row.Decoder a -> Sql.Query => Result (List a) _`, `row!` (at most one row: `Maybe a`), `execute! : Sql.Query => Result U64 _` (rows changed) |
| `Sql` | `query : Str -> List Sql.Param -> Sql.Query` (the SQL is a literal, rule P301), parameters `text`, `int`, `float`, `bool`, `null`, `nullable` |
| `Row` | decoders as Elm's `Json.Decode`: `field "url" Row.text`, columns `int`, `float`, `text`, `bool`, `nullable`; `map` to `map5`, `succeed`, `fail`, `andThen` |

The example app is ambit's link shortener: `examples/punk/shortener/`, and
the same app with its links in Postgres: `examples/punk/shortener-postgres/`.

## Postgres

```
import pf.Postgres
import pf.Sql
import pf.Row

type alias Link = { created : Int, url : Str }

linkRow : Row.Decoder Link
linkRow =
    Row.map2 (fn created, url -> { created, url })
        (Row.field "created" Row.int)
        (Row.field "url" Row.text)

findLink : Str -> Sql.Query
findLink = fn id ->
    Sql.query "SELECT created, url FROM links WHERE id = $1" [Sql.text id]

resolve! : Str => Result (Maybe Link) _
resolve! = fn id ->
    Postgres.row! linkRow (findLink id)
```

- **No SQL from text.** A `Sql.Query` is SQL written in the program plus the
  values for its parameters. `Sql.Query` is opaque, so only `Sql.query` makes
  one, and punk only accepts a string literal without `${...}` as its SQL
  (rule P301): `Sql.query ("SELECT * FROM " ++ table) []` doesn't compile. A
  value from a request can only ever be a parameter.
- **Typed both ways.** The host prepares the SQL and checks each parameter
  against the type the statement wants (`Sql.int` for an `integer`, an `Int`
  that doesn't fit an `int4` is an error, not a wrapped number). A column is
  read as bool, int (`int2/4/8`), float (`float4/8`) or text (`text`,
  `varchar`, `char`, `name`); for any other type the error says how to
  convert it in the SQL (`created::text`). The decoder then checks each
  column's kind, so a row that doesn't fit is `RowErr "column \"created\":
  expected an int, got text"`, not a wrong value.
- **Errors are values.** `PgErr { code, message }` has Postgres's SQLSTATE
  (`23505` is a unique violation, `08000` is no connection); the shortener
  answers 503 for it and 500 for a `RowErr`.
- **A capability.** The wiring opens the database and hands it to the app
  (`App::with_database`); the app never sees the connection string, and an
  app without one gets `PgErr { code = "08000", .. }` for every query.
- **What B1 builds on.** The Acadia-style query language (roadmap B1) will
  compile a pipeline (`Db.access links |> Db.filter ... |> Db.selectAll`) to
  exactly these two values, a `Sql.Query` and a `Row.Decoder`, made by the
  compiler from the table's type, and run them with `Postgres.rows!`. Written
  SQL with `Sql.query` stays as the escape hatch.

The database itself is the crate `postgres/` (`punk-server-postgres`), for
the wiring on Linux and macOS:

```rust
let database = punk_server_postgres::Postgres::new(&std::env::var("DATABASE_URL")?, 8)?;
database.batch(include_str!("../../schema.sql"))?;   // the app's tables
Lockdown::new().allow(&database) ...                   // its port (and the resolver for a name)
let app = punk_server::App::new(clock, random, kv, config).with_database(database);
```

It is a pool of at most `max` connections: a query takes a free one, or
opens one, or waits up to 5 seconds (then `PgErr { code = "53300" }`). A
broken connection is dropped and the next query opens a new one, so the app
recovers by itself when the database comes back. Each connection prepares a
statement once and keeps it. `options=-c statement_timeout=5s` in the
connection string limits how long a query may take.

## What the app can do

Only what the platform hands it, as in ambit: a clock, randomness, one
key-value store, one database, its configuration and a log. There is no file, network,
process or environment access in the API, so a punk server app can't reach
anything else, whatever its code does. Which store, which clock and which
configuration is up to the wiring, a few lines of Rust per app (like ambit's
`run-native`): the real ones in its `main`, the deterministic ones of
`ambit-server-sim` in its tests. The wiring of the shortener also locks the
whole process to its database file and its port (ambit's `Lockdown`: Landlock
and seccomp on Linux).

The response goes through the host before it is sent: a status outside 100 to
999 or a header name or value HTTP can't carry (a line break, for instance)
turns the response into a 500, so request data can't smuggle a header in. The
app never sees the connection.

A crash of the app (only possible through a bug: punk rejects `crash` outside
tests, P101) stops the server: it can't unwind through compiled punk, and
whatever runs the server starts it again.

## Building and testing an app

A server app isn't run with `punk app.punk`. `punk build` compiles it into an
archive (`output: Archive` in `main.roc`), and a small Rust crate next to the
app links that archive with this host and is the program:

```
examples/punk/shortener/
    Shortener.punk          the app
    server/
        Cargo.toml          depends on platforms/server/host and ambit
        build.rs            runs `punk build` on Shortener.punk, links libapp.a
        src/lib.rs          init(clock, random, kv, config): the app as an ambit Handler
        src/main.rs         the wiring: native store, clock, randomness, lockdown, port
        src/hermit.rs       the wiring as a Hermit unikernel (ambit's hermit backend)
        tests/spec.rs       ambit's spec/tests/shortener.rs, copied unchanged
        acceptance.sh       ambit's black-box HTTP tests, native or hermit
```

```
zig build roc
cd examples/punk/shortener/server
cargo test                  # ambit's spec, against the punk app
cargo run --release         # http://localhost:8080
```

`build.rs` uses `zig-out/bin/punk` of this repository, or the compiler named
by the `PUNK` environment variable.

### As a unikernel

The same app runs as a [Hermit](https://hermit-os.org) unikernel, on ambit's
hermit backend. For `x86_64-unknown-hermit`, `build.rs` compiles the app for
`x64v1elf` (freestanding x86-64 at the baseline CPU level: Hermit's QEMU CPU
model has no AVX), and `src/hermit.rs` does the wiring as ambit's
`run-hermit` does: an in-memory store (links are lost when the VM stops),
the hardware random generator, and port 8080 over virtio-net.

```
cargo build --release --target x86_64-unknown-hermit   # a 1.8 MB image
./acceptance.sh hermit      # boots it in QEMU and runs ambit's HTTP tests
```

Setup (the Rust std for Hermit, QEMU, the loader) as in
`platforms/cli/hermit/README.md`. Nothing has to be locked down: the image is
the whole machine, and the only way in is the port.

## How the host fits together

```
 Shortener.punk ─ punk build ─▶ libapp.a       (the app: no I/O of its own)
                                  │  calls roc_alloc, roc_kv_get, roc_clock_now, ...
                                  ▼  is called as roc_handle, once per request
 host/ (Rust, crate punk-server)  App: ambit_server::Handler
                                  │
 server/ (the app's crate) ─────▶ init(...) -> impl Handler; main(): ambit_server_native::serve
```

- `main.roc` and the other `.roc` files: the platform's API, what a punk app
  sees. `hosted { ... }` maps each effect to the C symbol the host exports.
- `host/src/lib.rs`: `App`, the punk app as an ambit `Handler`; the exported
  runtime functions and effects. Each request runs on one thread from start to
  end; the effects find the request's capabilities in a thread-local.
- `../roc-abi`: Roc's `Str`, `List` and `Try`, and the allocator, shared with
  the cli platform.

After each request the host checks that the app freed everything it
allocated for it, and logs a warning when not (`tests/platform.rs` of the
shortener checks it too).

## Not there yet

- Transactions: each query commits on its own. A `Transaction a` value (as
  in Acadia) comes with the query language, B1.
- Row-level security: decided to be mandatory per table, comes with B1/B2.
  Until then the database's own roles and policies are the wiring's job.
- TLS to the database (`NoTls` now: for a database on the same machine or a
  private network), and Postgres on hermit (the `postgres` crate needs
  tokio, which doesn't run there yet).
- Times, UUIDs, JSON and `numeric` as their own types: convert them in the
  SQL for now.

- `Kv.scan` (ambit has it): no app needed it yet.
- A typed configuration instead of `Config.text!`: the platform would need a
  type variable for it, and the JSON decoder does the job.
- A store that survives a restart on hermit (ambit has none there yet either).
