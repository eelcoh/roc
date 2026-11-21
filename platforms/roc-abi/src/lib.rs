//! Roc's values as a compiled punk app lays them out, and the memory they live in. Shared by
//! the hosts of punkroc's platforms (`platforms/cli/host`, `platforms/server/host`).
//!
//! This is the only crate that reads raw memory. It mirrors `src/builtins/str.zig`, `list.zig`
//! and `utils.zig` of the compiler (64-bit, little-endian targets only); when an upstream merge
//! changes those, the golden tests and the server spec fail, and this file has to follow.
//!
//! Ownership follows Roc: a value handed to the app (an argument of the app's entry point, the
//! result of a hosted function) is the app's from then on, and a value the app hands over (a
//! hosted function's argument, the entry point's result) is the host's, freed when it drops.

use std::alloc::{self, Layout};
use std::cell::Cell;
use std::marker::PhantomData;
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

/// Bytes allocated and not yet freed, by all threads. Zero when a program ends, unless
/// something leaks.
static LIVE_BYTES: AtomicIsize = AtomicIsize::new(0);

thread_local! {
    /// The same, for this thread only: a server checks that one request frees what it allocated.
    static THREAD_LIVE_BYTES: Cell<isize> = const { Cell::new(0) };
}

pub fn live_bytes() -> isize {
    LIVE_BYTES.load(Ordering::Relaxed)
}

/// What this thread allocated minus what it freed.
pub fn thread_live_bytes() -> isize {
    THREAD_LIVE_BYTES.with(Cell::get)
}

fn count(bytes: isize) {
    LIVE_BYTES.fetch_add(bytes, Ordering::Relaxed);
    THREAD_LIVE_BYTES.with(|c| c.set(c.get() + bytes));
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
        count(total as isize);
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
        count(-(total as isize));
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
        count(new_total as isize - total as isize);
        let data = base.add(pre);
        data.cast::<usize>().sub(1).write(new_total);
        data
    }
}

/// Room for `data_bytes` of a string or list, with its refcount (1) in the word before the data.
/// A list of refcounted elements also keeps its length in the word before that.
fn allocate_refcounted(data_bytes: usize, elements_refcounted: bool) -> *mut u8 {
    let extra = header(elements_refcounted);
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

/// The bytes before the data of a string or list: the refcount, and for a list of refcounted
/// elements also its length.
fn header(elements_refcounted: bool) -> usize {
    if elements_refcounted { 2 * WORD } else { WORD }
}

/// Drops one reference to the string or list data at `alloc_ptr`. Returns true when that was
/// the last one: the caller then drops the elements, if any, and calls [`free_refcounted`].
///
/// # Safety
/// `alloc_ptr` is the data pointer of a live refcounted allocation of Roc's.
unsafe fn release(alloc_ptr: usize) -> bool {
    if alloc_ptr == 0 {
        return false;
    }
    // SAFETY: by the caller's promise the refcount is the word before the data. Roc may share
    // the value between threads, so the count is updated atomically, as the builtins do.
    unsafe {
        let refcount = &*((alloc_ptr - WORD) as *const AtomicIsize);
        if refcount.load(Ordering::Relaxed) == REFCOUNT_STATIC_DATA {
            return false;
        }
        refcount.fetch_sub(1, Ordering::AcqRel) == 1
    }
}

/// # Safety
/// `alloc_ptr` is the data pointer of a refcounted allocation whose last reference is gone.
unsafe fn free_refcounted(alloc_ptr: usize, elements_refcounted: bool) {
    // SAFETY: by the caller's promise.
    unsafe { deallocate((alloc_ptr - header(elements_refcounted)) as *mut u8, WORD) }
}

// --- Str ----------------------------------------------------------------------------------------

/// Roc's `Str`. Owns one reference: dropping it gives that reference back.
#[repr(C)]
pub struct RocStr {
    bytes: *mut u8,
    capacity_or_alloc_ptr: usize,
    length: usize,
}

// SAFETY: the reference it owns is counted atomically.
unsafe impl Send for RocStr {}

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

    pub fn as_bytes(&self) -> &[u8] {
        if self.is_small() {
            let len = (self.length >> (usize::BITS - 8)) & 0x7f;
            // SAFETY: a small string's bytes are the first `len` bytes of the struct itself.
            unsafe { std::slice::from_raw_parts((self as *const Self).cast::<u8>(), len) }
        } else if self.length == 0 {
            &[]
        } else {
            // SAFETY: a big string's `bytes` points at `length` live bytes.
            unsafe { std::slice::from_raw_parts(self.bytes, self.length) }
        }
    }

    pub fn as_str(&self) -> &str {
        // Roc strings are UTF-8; checking costs one pass and keeps a broken one out of `&str`.
        std::str::from_utf8(self.as_bytes()).unwrap_or("\u{FFFD}")
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
        unsafe {
            if release(alloc_ptr) {
                free_refcounted(alloc_ptr, false);
            }
        }
    }
}

// --- List ---------------------------------------------------------------------------------------

/// A value that can be an element of a [`RocList`].
///
/// # Safety
/// `REFCOUNTED` is true exactly when Roc counts references inside the element (a `Str`, a list,
/// a tuple holding one), and the type has the size, alignment and layout Roc gives the element.
pub unsafe trait Element {
    const REFCOUNTED: bool;
}

// SAFETY: a byte, not refcounted.
unsafe impl Element for u8 {
    const REFCOUNTED: bool = false;
}

// SAFETY: a `Str` holds a reference.
unsafe impl Element for RocStr {
    const REFCOUNTED: bool = true;
}

/// Roc's `(Str, Str)`: two fields of the same alignment keep their order.
#[repr(C)]
pub struct RocPair {
    pub first: RocStr,
    pub second: RocStr,
}

// SAFETY: it holds two `Str`s.
unsafe impl Element for RocPair {
    const REFCOUNTED: bool = true;
}

/// Roc's `List(T)`. Owns one reference: dropping it gives that reference back, and with the
/// last one the elements and the list itself are freed.
#[repr(C)]
pub struct RocList<T: Element> {
    bytes: *mut T,
    length: usize,
    capacity_or_alloc_ptr: usize,
    _elements: PhantomData<T>,
}

impl<T: Element> RocList<T> {
    pub fn empty() -> Self {
        Self {
            bytes: std::ptr::null_mut(),
            length: 0,
            capacity_or_alloc_ptr: 0,
            _elements: PhantomData,
        }
    }

    /// A list of the items, which it owns from now on.
    pub fn from_vec(items: Vec<T>) -> Self {
        if items.is_empty() {
            return Self::empty();
        }
        let width = size_of::<T>();
        assert!(align_of::<T>() <= WORD, "an element aligned beyond a word");
        let data = allocate_refcounted(items.len() * width, T::REFCOUNTED).cast::<T>();
        let length = items.len();
        // SAFETY: `data` has room for the items; for refcounted elements the word two before it
        // holds the length, for a slice of this list to free them.
        unsafe {
            if T::REFCOUNTED {
                data.cast::<usize>().sub(2).write(length);
            }
            for (i, item) in items.into_iter().enumerate() {
                data.add(i).write(item);
            }
        }
        Self {
            bytes: data,
            length,
            capacity_or_alloc_ptr: length << 1,
            _elements: PhantomData,
        }
    }

    pub fn as_slice(&self) -> &[T] {
        if self.length == 0 || self.bytes.is_null() {
            return &[];
        }
        // SAFETY: a list's `bytes` points at `length` live elements.
        unsafe { std::slice::from_raw_parts(self.bytes, self.length) }
    }

    fn is_slice(&self) -> bool {
        self.capacity_or_alloc_ptr & SEAMLESS_SLICE_TAG != 0
    }
}

impl RocList<u8> {
    pub fn from_bytes(bytes: &[u8]) -> Self {
        Self::from_vec(bytes.to_vec())
    }
}

impl RocList<RocStr> {
    pub fn of_strs(items: &[String]) -> Self {
        Self::from_vec(items.iter().map(|item| RocStr::new(item)).collect())
    }
}

impl<T: Element> Drop for RocList<T> {
    fn drop(&mut self) {
        let alloc_ptr = if self.is_slice() {
            self.capacity_or_alloc_ptr & !SEAMLESS_SLICE_TAG
        } else {
            self.bytes as usize
        };
        // SAFETY: a list with data points into a live list allocation of Roc's. When the last
        // reference goes, every element of the allocation (not only those of a slice) is
        // dropped: their number is the length, or for a slice the count before the refcount.
        unsafe {
            if !release(alloc_ptr) {
                return;
            }
            if T::REFCOUNTED {
                let count = if self.is_slice() {
                    (alloc_ptr as *const usize).sub(2).read()
                } else {
                    self.length
                };
                let first = alloc_ptr as *mut T;
                for i in 0..count {
                    std::ptr::drop_in_place(first.add(i));
                }
            }
            free_refcounted(alloc_ptr, T::REFCOUNTED);
        }
    }
}

// --- Try ----------------------------------------------------------------------------------------

/// `Try(Str, [SomeErr(Str)])` and `Try({}, [SomeErr(Str)])`: the payload, then the tag. Tags are
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
    fn lists_free_their_elements() {
        let before = thread_live_bytes();
        let list = RocList::of_strs(&["a".into(), "a string longer than a small one".into()]);
        assert_eq!(list.as_slice()[1].as_str(), "a string longer than a small one");
        let pairs = RocList::from_vec(vec![RocPair {
            first: RocStr::new("location"),
            second: RocStr::new("https://example.com/a/long/enough/path"),
        }]);
        let bytes = RocList::from_bytes(b"hello");
        assert_eq!(bytes.as_slice(), b"hello");
        assert!(thread_live_bytes() > before);
        drop((list, pairs, bytes));
        assert_eq!(thread_live_bytes(), before);
    }
}
