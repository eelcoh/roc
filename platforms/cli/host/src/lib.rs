//! Host of punkroc's `cli` platform.
//!
//! roc compiles a punk app to an object that does no I/O itself. It calls the functions this
//! library exports (`roc_alloc`, `roc_stdout_line`, ...) with Roc's C ABI, and this library's
//! `main` calls the app's `roc_main`. Behind those functions is ambit's cli platform: the app is
//! an `ambit_cli::App`, run by ambit's native backend, with ambit's capabilities.
//!
//! - `punk-roc-abi` (`platforms/roc-abi`): Roc's values and memory, the only raw-memory code,
//!   shared with the server platform.
//! - `platform.rs`: what each effect does, safe Rust on ambit's capabilities.
//! - this file: the exported symbols, and the wiring.

#![cfg_attr(test, allow(dead_code))]

mod platform;

use std::cell::Cell;
use std::ffi::{CStr, c_char, c_int};

use ambit_cli::{App, Args, Exit, Io};
use platform::Caps;
use punk_roc_abi as roc;
use roc::{RocList, RocStr, RocTry};

#[cfg(not(test))]
unsafe extern "C" {
    /// The app: `main_for_host!` of `platforms/cli/main.roc`, which takes and returns nothing.
    fn roc_main();
}

/// The unit tests have no app.
#[cfg(test)]
unsafe fn roc_main() {}

// --- The wiring ---------------------------------------------------------------------------------

/// The punk app, as ambit sees it.
struct PunkApp {
    caps: Caps,
}

impl App for PunkApp {
    type Done = Exit;

    fn run(self, _args: &[String], io: &mut Io<'_>) -> Exit {
        let session = Session {
            caps: self.caps,
            io,
        };
        with_session(session, || {
            // SAFETY: the app's entry point takes nothing and returns nothing; every hosted
            // function it calls finds the session set here.
            unsafe { roc_main() }
        });
        Exit::SUCCESS
    }
}

/// What the hosted functions work with while the app runs.
struct Session<'a, 'io> {
    caps: Caps,
    io: &'a mut Io<'io>,
}

thread_local! {
    /// The session of the app that's running, or null outside `PunkApp::run`.
    static SESSION: Cell<*mut Session<'static, 'static>> = const { Cell::new(std::ptr::null_mut()) };
}

/// Runs `f` with `session` reachable from the hosted functions, and takes it away again after.
fn with_session(mut session: Session<'_, '_>, f: impl FnOnce()) {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            SESSION.with(|s| s.set(std::ptr::null_mut()));
        }
    }
    let ptr = (&mut session as *mut Session<'_, '_>).cast::<Session<'static, 'static>>();
    SESSION.with(|s| s.set(ptr));
    let _reset = Reset;
    f();
}

/// Gives a hosted function the running app's session.
fn session<R>(f: impl FnOnce(&mut Session<'_, '_>) -> R) -> R {
    // Taken out while in use, so two calls can never hold it at once.
    let ptr = SESSION.with(|s| s.replace(std::ptr::null_mut()));
    if ptr.is_null() {
        eprintln!("Host error: the app used an effect outside main!");
        std::process::exit(1);
    }
    struct Put(*mut Session<'static, 'static>);
    impl Drop for Put {
        fn drop(&mut self) {
            SESSION.with(|s| s.set(self.0));
        }
    }
    let _put = Put(ptr);
    // SAFETY: `ptr` points at the session `with_session` set, which lives until it returns and
    // is reset on the way out; it was taken out of SESSION above, so this is the only reference.
    f(unsafe { &mut *ptr })
}

/// The command line, from C's `main`. An argument that isn't UTF-8 ends the program, with exit
/// code 2, as in ambit's native backend: the app could only see a mangled copy, which might name
/// a different file.
///
/// # Safety
/// `argv` holds `argc` C strings, as C's `main` gets them.
unsafe fn args(argc: c_int, argv: *const *const c_char) -> Args {
    let mut list = Vec::new();
    for index in 0..argc.max(0) as usize {
        // SAFETY: by the caller's promise.
        let arg = unsafe { CStr::from_ptr(*argv.add(index)) };
        match arg.to_str() {
            Ok(arg) => list.push(arg.to_owned()),
            Err(_) => {
                eprintln!(
                    "argument {index} is not valid UTF-8: {}",
                    arg.to_string_lossy()
                );
                std::process::exit(2);
            }
        }
    }
    Args::new(list)
}

/// The program's entry point.
///
/// # Safety
/// Called by the C runtime, with the command line.
#[cfg(not(test))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    // SAFETY: C's `main` gets argc and argv.
    let args = unsafe { args(argc, argv) };
    let app = PunkApp {
        caps: Caps::new(&args),
    };
    let exit = ambit_cli_native::run(app, &args);
    let leaked = roc::live_bytes();
    if leaked != 0 {
        eprintln!("Memory leak detected: {leaked} bytes were not freed");
    }
    c_int::from(exit.0)
}

// --- The runtime: memory and crashes ------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut u8 {
    roc::allocate(length, alignment)
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_dealloc(ptr: *mut u8, alignment: usize) {
    // SAFETY: by the caller's promise.
    unsafe { roc::deallocate(ptr, alignment) }
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_realloc(ptr: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    // SAFETY: by the caller's promise.
    unsafe { roc::reallocate(ptr, new_length, alignment) }
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
    eprintln!("ROC DBG: {}", unsafe { text(bytes, len) });
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    eprintln!("Expect failed: {}", unsafe { text(bytes, len) }.trim());
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    // What the app printed before it crashed still comes out, before the crash.
    let ptr = SESSION.with(|s| s.get());
    if !ptr.is_null() {
        // SAFETY: as in `session`; the app is stopped inside this call, so nothing else uses it.
        let _ = unsafe { &mut *ptr }.io.out.flush();
    }
    // SAFETY: by the caller's promise.
    eprintln!("\nRoc crashed: {}", unsafe { text(bytes, len) });
    std::process::exit(1);
}

// --- Hosted functions: the effects of platforms/cli/*.roc ---------------------------------------
//
// Each takes its arguments with Roc's C ABI. A `RocStr` argument is owned: it is freed (its
// reference given back) when it goes out of scope here.

#[unsafe(no_mangle)]
pub extern "C" fn roc_arg_list() -> RocList<RocStr> {
    session(|s| RocList::of_strs(&s.caps.args))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clock_now() -> i64 {
    session(|s| s.caps.now_millis())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clock_elapsed() -> i64 {
    session(|s| s.caps.elapsed_millis())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_random_u64() -> u64 {
    session(|s| s.caps.random_u64())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_file_read(path: RocStr) -> RocTry {
    session(|s| match s.caps.read_file(path.as_str()) {
        Ok(text) => RocTry::ok(RocStr::new(&text)),
        Err(message) => RocTry::err(RocStr::new(&message)),
    })
}

/// `File.write!`: the text comes first in Roc, so that punk writes `File.write! path text`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_file_write(text: RocStr, path: RocStr) -> RocTry {
    session(|s| match s.caps.write_file(path.as_str(), text.as_str()) {
        Ok(()) => RocTry::ok_unit(),
        Err(message) => RocTry::err(RocStr::new(&message)),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stderr_line(line: RocStr) {
    session(|s| platform::stderr_line(s.io, line.as_str()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdin_line() -> RocStr {
    session(|s| RocStr::new(&platform::stdin_line(s.io)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdin_read_all() -> RocStr {
    session(|s| RocStr::new(&platform::stdin_read_all(s.io)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdout_line(line: RocStr) {
    session(|s| platform::stdout_line(s.io, line.as_str()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdout_write(text: RocStr) {
    session(|s| platform::stdout_write(s.io, text.as_str()))
}
