//! Host of punkroc's `server` platform.
//!
//! roc compiles a punk server app to an archive (`libapp.a`) that does no I/O itself: for each
//! request ambit's server platform calls [`App::handle`], which calls the app's `roc_handle`
//! with Roc's C ABI. The app reaches the world only through the functions exported here
//! (`roc_kv_get`, `roc_clock_now`, ...), and those only through the capabilities the wiring
//! handed to [`App::new`]: the app's signature is everything it can do, as in ambit.
//!
//! The crate of an app links its archive next to this library and decides, in its wiring, which
//! capabilities the app gets: the real ones in its `main`, the deterministic ones of
//! `ambit-server-sim` in its tests.

use std::cell::Cell;
use std::time::UNIX_EPOCH;

mod database;
pub use database::{Database, DbError, Rows, Value};

use ambit_caps::{Clock, Kv, Random};
use ambit_server::http::{HeaderName, HeaderValue, StatusCode, header};
pub use ambit_server::{Handler, Request, Response};
use punk_roc_abi::{RocList, RocPair, RocStr, RocTry};
pub use punk_roc_abi::{live_bytes, thread_live_bytes};

/// The app's result: `Http.Response` of `platforms/server/Http.roc`. Fields of the same alignment
/// are in alphabetical order, the `U16` comes last.
#[repr(C)]
struct RocResponse {
    body: RocList<u8>,
    headers: RocList<RocPair>,
    status: u16,
}

/// `Kv.get_host!`: `{ code : U8, text : Str }`, the `Str` first.
#[repr(C)]
pub struct RocFound {
    text: RocStr,
    code: u8,
}

/// `Sql.Param` and `Row.Cell`: `{ kind : U8, text : Str }`, the `Str` first.
#[repr(C)]
pub struct RocCell {
    text: RocStr,
    kind: u8,
}

// SAFETY: it holds a `Str`.
unsafe impl punk_roc_abi::Element for RocCell {
    const REFCOUNTED: bool = true;
}

/// What `Postgres.run_host!` gives: the fields of the same alignment in alphabetical order, the
/// `Bool` last.
#[repr(C)]
pub struct RocRun {
    affected: u64,
    columns: RocList<RocStr>,
    error_code: RocStr,
    error_message: RocStr,
    rows: RocList<RocList<RocCell>>,
    ok: bool,
}

unsafe extern "C" {
    /// The app: `handle_for_host!` of `platforms/server/main.roc`.
    fn roc_handle(
        method: RocStr,
        path: RocStr,
        query: RocStr,
        headers: RocList<RocPair>,
        body: RocList<u8>,
    ) -> RocResponse;
}

/// A punk app with its capabilities: an ambit server [`Handler`].
pub struct App {
    clock: Box<dyn Clock>,
    random: Box<dyn Random>,
    kv: Box<dyn Kv>,
    database: Box<dyn Database>,
    config: String,
}

impl App {
    /// The app, with everything it may use. `config` is what the app reads with `Config.text!`,
    /// JSON by convention.
    pub fn new(
        clock: impl Clock,
        random: impl Random,
        kv: impl Kv,
        config: impl Into<String>,
    ) -> Self {
        Self {
            clock: Box::new(clock),
            random: Box::new(random),
            kv: Box::new(kv),
            database: Box::new(database::NoDatabase),
            config: config.into(),
        }
    }

    /// The app, with the database its `Postgres` queries run on. Without one, every query
    /// fails with `PgErr { code = "08000", .. }`.
    pub fn with_database(mut self, database: impl Database) -> Self {
        self.database = Box::new(database);
        self
    }
}

impl Handler for App {
    fn handle(&self, req: Request) -> Response {
        let before = thread_live_bytes();
        let response = with_app(self, || {
            let headers = req
                .headers()
                .iter()
                .map(|(name, value)| RocPair {
                    first: RocStr::new(name.as_str()),
                    second: RocStr::new(&String::from_utf8_lossy(value.as_bytes())),
                })
                .collect();
            let method = RocStr::new(req.method().as_str());
            let path = RocStr::new(req.uri().path());
            let query = RocStr::new(req.uri().query().unwrap_or(""));
            let headers = RocList::from_vec(headers);
            let body = RocList::from_bytes(req.body());
            // SAFETY: the app's entry point takes these five values (it owns them from now on)
            // and returns a response, which we own; every hosted function it calls finds the
            // app set by `with_app`.
            let response = unsafe { roc_handle(method, path, query, headers, body) };
            to_http(&response)
        });
        let leaked = thread_live_bytes() - before;
        if leaked != 0 {
            tracing::warn!(
                bytes = leaked,
                "the app did not free all it allocated for a request"
            );
        }
        response
    }
}

/// The app's response as an HTTP response. A status or header HTTP can't carry becomes a 500:
/// the app can't smuggle a line break into a header.
fn to_http(response: &RocResponse) -> Response {
    let Ok(status) = StatusCode::from_u16(response.status) else {
        tracing::error!(
            status = response.status,
            "the app answered with an invalid status"
        );
        return internal_error();
    };
    let mut http = Response::new(response.body.as_slice().to_vec());
    *http.status_mut() = status;
    for pair in response.headers.as_slice() {
        let name = HeaderName::from_bytes(pair.first.as_bytes());
        let value = HeaderValue::from_bytes(pair.second.as_bytes());
        match (name, value) {
            (Ok(name), Ok(value)) => {
                http.headers_mut().append(name, value);
            }
            _ => {
                tracing::error!(
                    name = pair.first.as_str(),
                    "the app answered with an invalid header"
                );
                return internal_error();
            }
        }
    }
    http
}

fn internal_error() -> Response {
    let mut response = Response::new(b"internal error\n".to_vec());
    *response.status_mut() = StatusCode::INTERNAL_SERVER_ERROR;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response
}

// --- The app that's running on this thread ------------------------------------------------------

thread_local! {
    /// The app handling a request on this thread, or null between requests. Each request runs
    /// on one thread from start to end, so the hosted functions find their app here.
    static CURRENT: Cell<*const App> = const { Cell::new(std::ptr::null()) };
}

fn with_app<R>(app: &App, f: impl FnOnce() -> R) -> R {
    struct Reset(*const App);
    impl Drop for Reset {
        fn drop(&mut self) {
            CURRENT.with(|c| c.set(self.0));
        }
    }
    let _reset = Reset(CURRENT.with(|c| c.replace(app)));
    f()
}

/// Gives a hosted function the app whose request is running.
fn app<R>(f: impl FnOnce(&App) -> R) -> R {
    let ptr = CURRENT.with(Cell::get);
    if ptr.is_null() {
        eprintln!("Host error: the app used an effect outside a request");
        std::process::abort();
    }
    // SAFETY: `with_app` set it from a reference that lives until it returns, and resets it on
    // the way out; `App` is only read.
    f(unsafe { &*ptr })
}

// --- The runtime: memory and crashes ------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut u8 {
    punk_roc_abi::allocate(length, alignment)
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_dealloc(ptr: *mut u8, alignment: usize) {
    // SAFETY: by the caller's promise.
    unsafe { punk_roc_abi::deallocate(ptr, alignment) }
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_realloc(ptr: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    // SAFETY: by the caller's promise.
    unsafe { punk_roc_abi::reallocate(ptr, new_length, alignment) }
}

/// # Safety
/// `bytes` points at `len` bytes.
unsafe fn text<'a>(bytes: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    // SAFETY: by the caller's promise.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) })
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    tracing::debug!("dbg: {}", unsafe { text(bytes, len) });
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    tracing::error!("expect failed: {}", unsafe { text(bytes, len) }.trim());
}

/// A crash can't unwind through the app, and the app's memory is in an unknown state, so the
/// server stops; whatever runs it starts it again. punk rules out `crash` outside tests (P101),
/// so this is a bug in the app or the compiler, not an answer to a request.
///
/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    let message = unsafe { text(bytes, len) };
    tracing::error!("the app crashed: {message}");
    eprintln!("Roc crashed: {message}");
    std::process::abort();
}

// --- Hosted functions: the effects of platforms/server/*.roc ------------------------------------
//
// Each takes its arguments with Roc's C ABI. A `RocStr` argument is owned: it is freed (its
// reference given back) when it goes out of scope here.

#[unsafe(no_mangle)]
pub extern "C" fn roc_clock_now() -> i64 {
    app(|app| match app.clock.now().duration_since(UNIX_EPOCH) {
        Ok(since) => since.as_millis() as i64,
        Err(before) => -(before.duration().as_millis() as i64),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_random_u64() -> u64 {
    app(|app| app.random.u64())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_config_text() -> RocStr {
    app(|app| RocStr::new(&app.config))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_kv_get(key: RocStr) -> RocFound {
    app(|app| match app.kv.get(key.as_bytes()) {
        Ok(None) => RocFound {
            text: RocStr::empty(),
            code: 0,
        },
        Ok(Some(value)) => match String::from_utf8(value) {
            Ok(text) => RocFound {
                text: RocStr::new(&text),
                code: 1,
            },
            Err(_) => RocFound {
                text: RocStr::new("the stored value is not UTF-8 text"),
                code: 2,
            },
        },
        Err(e) => RocFound {
            text: RocStr::new(&e.to_string()),
            code: 2,
        },
    })
}

/// `Kv.put!`: the value comes first in Roc, so that punk writes `Kv.put! key value`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_kv_put(value: RocStr, key: RocStr) -> RocTry {
    app(|app| match app.kv.put(key.as_bytes(), value.as_bytes()) {
        Ok(()) => RocTry::ok_unit(),
        Err(e) => RocTry::err(RocStr::new(&e.to_string())),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_kv_delete(key: RocStr) -> RocTry {
    app(|app| match app.kv.delete(key.as_bytes()) {
        Ok(()) => RocTry::ok_unit(),
        Err(e) => RocTry::err(RocStr::new(&e.to_string())),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_log_info(message: RocStr) {
    tracing::info!("{}", message.as_str());
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_log_warn(message: RocStr) {
    tracing::warn!("{}", message.as_str());
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_log_error(message: RocStr) {
    tracing::error!("{}", message.as_str());
}

/// `Postgres.run_host!`: runs one query on the app's database. The parameters come first, as in
/// `Postgres.roc`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_pg_run(params: RocList<RocCell>, sql: RocStr) -> RocRun {
    let mut values = Vec::with_capacity(params.as_slice().len());
    for (i, param) in params.as_slice().iter().enumerate() {
        match database::from_cell(param.kind, param.text.as_str()) {
            Some(value) => values.push(value),
            None => {
                return run_failed(&DbError::new(
                    "22000",
                    format!("parameter ${} is broken", i + 1),
                ));
            }
        }
    }
    let result = app(|app| app.database.run(sql.as_str(), &values));
    match result {
        Ok(rows) => RocRun {
            affected: rows.affected,
            columns: RocList::of_strs(&rows.columns),
            error_code: RocStr::empty(),
            error_message: RocStr::empty(),
            rows: RocList::from_vec(
                rows.rows
                    .iter()
                    .map(|row| {
                        RocList::from_vec(
                            row.iter()
                                .map(|value| {
                                    let (kind, text) = database::to_cell(value);
                                    RocCell {
                                        text: RocStr::new(&text),
                                        kind,
                                    }
                                })
                                .collect(),
                        )
                    })
                    .collect(),
            ),
            ok: true,
        },
        Err(e) => {
            tracing::warn!(code = e.code.as_str(), "query failed: {}", e.message);
            run_failed(&e)
        }
    }
}

fn run_failed(e: &DbError) -> RocRun {
    RocRun {
        affected: 0,
        columns: RocList::empty(),
        error_code: RocStr::new(&e.code),
        error_message: RocStr::new(&e.message),
        rows: RocList::empty(),
        ok: false,
    }
}
