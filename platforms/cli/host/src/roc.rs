//! Roc's values as the compiled app lays them out, and the memory they live in.
//!
//! This is the only module that reads raw memory. It mirrors
//! `src/builtins/str.zig`, `list.zig` and `utils.zig` of the compiler (64-bit,
//! little-endian targets only); `platforms/cli/README.md` says what to check
//! when upstream changes those.

use std::alloc::{self, Layout};
use std::mem::ManuallyDrop;
use std::sync::atomic::{AtomicIsize, Ordering};

const WORD: usize = size_of::<usize>();

/// The high bit of the last byte marks a small string, whose bytes are inside the struct.
const SMALL_STR_BIT: usize = 1 << (usize::BITS - 1);
/// Marks `capacity_or_alloc_ptr` of a slice of a bigger string or list.
const SEAMLESS_SLICE_TAG: usize = 1;
/// The refcount of data that lives as long as the program (literals). Never freed.
const REFCOUNT_STATIC_DATA: isize = 0;

const _: () = assert!(WORD == 8 && cfg!(target_endian = "little"));

// --- Memory -------------------------------------------------------------------------------------

/// Bytes the app has allocated and not yet freed. Zero when it ends, unless something leaks.
static LIVE_BYTES: AtomicIsize = AtomicIsize::new(0);

pub fn live_bytes() -> isize {
    LIVE_BYTES.load(Ordering::Relaxed)
}

/// `roc_dealloc` is not told the size, so every allocation starts with a prefix that holds it,
/// in the word right before the data. The prefix keeps the data aligned.
fn prefix(alignment: usize) -> usize {
    alignment.max(WORD)
}

fn layout(total: usize, alignment: usize) -> Layout {
    Layout::from_size_align(total, prefix(alignment)).unwrap_or_else(|_| out_of_memory())
}

pub fn out_of_memory() -> ! {
    eprintln!("Host error: out of memory");
    std::process::exit(1)
}

pub fn allocate(length: usize, alignment: usize) -> *mut u8 {
    let pre = prefix(alignment);
    let total = length.checked_add(pre).unwrap_or_else(|| out_of_memory());
    // SAFETY: the layout is never zero-sized (it holds at least the prefix), and the size is
    // written inside the block, in the word before the data.
    unsafe {
        let base = alloc::alloc(layout(total, alignment));
        if base.is_null() {
            out_of_memory();
        }
        let data = base.add(pre);
        data.cast::<usize>().sub(1).write(total);
        LIVE_BYTES.fetch_add(total as isize, Ordering::Relaxed);
        data
    }
}

/// # Safety
/// `data` came from [`allocate`] or [`reallocate`] with the same alignment, and is not used after.
pub unsafe fn deallocate(data: *mut u8, alignment: usize) {
    let pre = prefix(alignment);
    // SAFETY: by the caller's promise, the size is in the word before `data`.
    unsafe {
        let total = data.cast::<usize>().sub(1).read();
        LIVE_BYTES.fetch_sub(total as isize, Ordering::Relaxed);
        alloc::dealloc(data.sub(pre), layout(total, alignment));
    }
}

/// # Safety
/// As [`deallocate`]; the old pointer is not used after.
pub unsafe fn reallocate(data: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    let pre = prefix(alignment);
    let new_total = new_length
        .checked_add(pre)
        .unwrap_or_else(|| out_of_memory());
    // SAFETY: by the caller's promise, the size is in the word before `data`; `realloc` keeps
    // the alignment of the old layout and the bytes of the old block.
    unsafe {
        let total = data.cast::<usize>().sub(1).read();
        let base = alloc::realloc(data.sub(pre), layout(total, alignment), new_total);
        if base.is_null() {
            out_of_memory();
        }
        LIVE_BYTES.fetch_add(new_total as isize - total as isize, Ordering::Relaxed);
        let data = base.add(pre);
        data.cast::<usize>().sub(1).write(new_total);
        data
    }
}

/// Room for `data_bytes` of a string or list, with its refcount (1) in the word before the data.
/// A list of refcounted elements also keeps its length in the word before that.
fn allocate_refcounted(data_bytes: usize, elements_refcounted: bool) -> *mut u8 {
    let extra = if elements_refcounted { 2 * WORD } else { WORD };
    let base = allocate(
        data_bytes
            .checked_add(extra)
            .unwrap_or_else(|| out_of_memory()),
        WORD,
    );
    // SAFETY: `extra` bytes before the data are ours, and word-aligned.
    unsafe {
        let data = base.add(extra);
        data.cast::<isize>().sub(1).write(1);
        data
    }
}

/// Drops one reference to the string or list data at `alloc_ptr`, and frees it with the last.
///
/// # Safety
/// `alloc_ptr` is the data pointer of a live refcounted allocation of Roc's, with `extra`
/// header bytes before it.
unsafe fn release(alloc_ptr: usize, extra: usize) {
    if alloc_ptr == 0 {
        return;
    }
    // SAFETY: by the caller's promise the refcount is the word before the data. Roc may share
    // the value between threads, so the count is updated atomically, as the builtins do.
    unsafe {
        let refcount = &*((alloc_ptr - WORD) as *const AtomicIsize);
        if refcount.load(Ordering::Relaxed) == REFCOUNT_STATIC_DATA {
            return;
        }
        if refcount.fetch_sub(1, Ordering::AcqRel) == 1 {
            deallocate((alloc_ptr - extra) as *mut u8, WORD);
        }
    }
}

// --- Str ----------------------------------------------------------------------------------------

/// Roc's `Str`. Owns one reference: dropping it gives that reference back.
#[repr(C)]
pub struct RocStr {
    bytes: *mut u8,
    capacity_or_alloc_ptr: usize,
    length: usize,
}

impl RocStr {
    pub fn empty() -> Self {
        Self {
            bytes: std::ptr::null_mut(),
            capacity_or_alloc_ptr: 0,
            length: SMALL_STR_BIT,
        }
    }

    pub fn new(text: &str) -> Self {
        let bytes = text.as_bytes();
        if bytes.len() < size_of::<Self>() {
            let mut small = [0u8; size_of::<Self>()];
            small[..bytes.len()].copy_from_slice(bytes);
            small[size_of::<Self>() - 1] = bytes.len() as u8 | 0x80;
            // SAFETY: RocStr is three plain words; any bit pattern is a valid one.
            return unsafe { std::mem::transmute::<[u8; size_of::<Self>()], Self>(small) };
        }
        let data = allocate_refcounted(bytes.len(), false);
        // SAFETY: `data` has room for `bytes.len()` bytes.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len()) };
        Self {
            bytes: data,
            capacity_or_alloc_ptr: bytes.len() << 1,
            length: bytes.len(),
        }
    }

    fn is_small(&self) -> bool {
        self.length & SMALL_STR_BIT != 0
    }

    pub fn as_str(&self) -> &str {
        let bytes = if self.is_small() {
            let len = (self.length >> (usize::BITS - 8)) & 0x7f;
            // SAFETY: a small string's bytes are the first `len` bytes of the struct itself.
            unsafe { std::slice::from_raw_parts((self as *const Self).cast::<u8>(), len) }
        } else if self.length == 0 {
            &[]
        } else {
            // SAFETY: a big string's `bytes` points at `length` live bytes.
            unsafe { std::slice::from_raw_parts(self.bytes, self.length) }
        };
        // Roc strings are UTF-8; checking costs one pass and keeps a broken one out of `&str`.
        std::str::from_utf8(bytes).unwrap_or("\u{FFFD}")
    }
}

impl Drop for RocStr {
    fn drop(&mut self) {
        if self.is_small() {
            return;
        }
        let alloc_ptr = if self.capacity_or_alloc_ptr & SEAMLESS_SLICE_TAG != 0 {
            self.capacity_or_alloc_ptr & !SEAMLESS_SLICE_TAG
        } else {
            self.bytes as usize
        };
        // SAFETY: a big string or a slice of one points into a live string allocation, which
        // has one word (the refcount) before its data.
        unsafe { release(alloc_ptr, WORD) }
    }
}

// --- List Str -----------------------------------------------------------------------------------

/// Roc's `List(Str)`, made by the host and handed to the app, which owns it from then on.
#[repr(C)]
pub struct RocList {
    bytes: *mut u8,
    length: usize,
    capacity_or_alloc_ptr: usize,
}

impl RocList {
    pub fn of_strs(items: &[String]) -> Self {
        if items.is_empty() {
            return Self {
                bytes: std::ptr::null_mut(),
                length: 0,
                capacity_or_alloc_ptr: 0,
            };
        }
        let width = size_of::<RocStr>();
        let data = allocate_refcounted(items.len() * width, true);
        // SAFETY: `data` has room for the items; the word two before it holds the length,
        // for a slice of this list to free it.
        unsafe {
            data.cast::<usize>().sub(2).write(items.len());
            for (i, item) in items.iter().enumerate() {
                data.add(i * width)
                    .cast::<RocStr>()
                    .write(RocStr::new(item));
            }
        }
        Self {
            bytes: data,
            length: items.len(),
            capacity_or_alloc_ptr: items.len() << 1,
        }
    }
}

// --- Try ----------------------------------------------------------------------------------------

/// `Try(Str, [FileErr(Str)])` and `Try({}, [FileErr(Str)])`: the payload, then the tag. Tags are
/// numbered in alphabetical order: `Err` is 0, `Ok` is 1. For `Ok({})` the payload is unused.
#[repr(C)]
pub struct RocTry {
    payload: ManuallyDrop<RocStr>,
    tag: u8,
}

impl RocTry {
    pub fn ok(value: RocStr) -> Self {
        Self {
            payload: ManuallyDrop::new(value),
            tag: 1,
        }
    }

    pub fn ok_unit() -> Self {
        Self::ok(RocStr::empty())
    }

    pub fn err(message: RocStr) -> Self {
        Self {
            payload: ManuallyDrop::new(message),
            tag: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_round_trip_small_and_big() {
        for text in [
            "",
            "a",
            "twenty-three bytes long",
            "twenty-four bytes long!!",
            "ü and more than twenty-four bytes",
        ] {
            let s = RocStr::new(text);
            assert_eq!(s.as_str(), text);
            assert_eq!(s.is_small(), text.len() < 24, "{text}");
        }
        assert_eq!(RocStr::empty().as_str(), "");
    }

    #[test]
    fn a_list_frees_nothing_by_itself() {
        let list = RocList::of_strs(&["a".into(), "a string longer than a small one".into()]);
        assert_eq!(list.length, 2);
        // The app frees it; here, by hand: the big string, then the list.
        unsafe {
            std::ptr::drop_in_place(list.bytes.add(24).cast::<RocStr>());
            release(list.bytes as usize, 16);
        }
    }
}
