//! Spike: the host of punkroc's `cli` platform as a Hermit unikernel.
//!
//! The same C ABI as `platforms/cli/host`: the app calls `roc_alloc`, `roc_stdout_line`, ...
//! and this program's `main` calls the app's `roc_main`. Memory and Roc's values come from the
//! cli host's own `roc.rs`. The effects are plain std here, not ambit: ambit's cli platform runs
//! on cap-std (rustix), which doesn't build for Hermit. A real unikernel platform would sit on
//! ambit's hermit backend (`ambit-server-hermit`) instead.
//!
//! What the app can reach in the image: output (the serial console), the clock, randomness.
//! Stdin is empty, there are no arguments and no files.

#[cfg(target_os = "hermit")]
use hermit as _;

#[path = "../../host/src/roc.rs"]
#[allow(dead_code)]
mod roc;

use std::io::Write;
use std::sync::OnceLock;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use roc::{RocList, RocStr, RocTry};

unsafe extern "C" {
    /// The app: `main_for_host!` of `platforms/cli/main.roc`.
    fn roc_main();
}

static START: OnceLock<Instant> = OnceLock::new();

fn main() {
    START.get_or_init(Instant::now);
    // SAFETY: the app's entry point takes nothing and returns nothing.
    unsafe { roc_main() }
    let _ = std::io::stdout().flush();
    let leaked = roc::live_bytes();
    if leaked != 0 {
        eprintln!("Memory leak detected: {leaked} bytes were not freed");
    }
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
    let _ = std::io::stdout().flush();
    // SAFETY: by the caller's promise.
    eprintln!("\nRoc crashed: {}", unsafe { text(bytes, len) });
    std::process::exit(1);
}

// --- Hosted functions: the effects of platforms/cli/*.roc ---------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn roc_arg_list() -> RocList {
    RocList::of_strs(&[])
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clock_now() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(since) => since.as_millis() as i64,
        Err(before) => -(before.duration().as_millis() as i64),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clock_elapsed() -> i64 {
    START.get_or_init(Instant::now).elapsed().as_millis() as i64
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_random_u64() -> u64 {
    // Hermit's entropy comes from rdseed/rdrand; without it this fails, and the program ends.
    getrandom::u64().unwrap_or_else(|e| {
        eprintln!("Host error: no randomness: {e}");
        std::process::exit(1)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_file_read(path: RocStr) -> RocTry {
    RocTry::err(RocStr::new(&format!(
        "{}: there are no files in this unikernel",
        path.as_str()
    )))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_file_write(_text: RocStr, path: RocStr) -> RocTry {
    RocTry::err(RocStr::new(&format!(
        "{}: there are no files in this unikernel",
        path.as_str()
    )))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stderr_line(line: RocStr) {
    eprintln!("{}", line.as_str());
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdin_line() -> RocStr {
    RocStr::new("")
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdin_read_all() -> RocStr {
    RocStr::new("")
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdout_line(line: RocStr) {
    println!("{}", line.as_str());
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_stdout_write(text: RocStr) {
    print!("{}", text.as_str());
    let _ = std::io::stdout().flush();
}
