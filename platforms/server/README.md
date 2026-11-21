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

The example app is ambit's link shortener: `examples/punk/shortener/`.

## What the app can do

Only what the platform hands it, as in ambit: a clock, randomness, one
key-value store, its configuration and a log. There is no file, network,
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
        tests/spec.rs       ambit's spec/tests/shortener.rs, copied unchanged
```

```
zig build roc
cd examples/punk/shortener/server
cargo test                  # ambit's spec, against the punk app
cargo run --release         # http://localhost:8080
```

`build.rs` uses `zig-out/bin/punk` of this repository, or the compiler named
by the `PUNK` environment variable.

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

- `Kv.scan` (ambit has it): no app needed it yet.
- A typed configuration instead of `Config.text!`: the platform would need a
  type variable for it, and the JSON decoder does the job.
- Running on hermit (ambit's unikernel backend): a separate spike.
