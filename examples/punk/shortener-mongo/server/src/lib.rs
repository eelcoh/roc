//! ambit's link shortener, written in punk, with its links in Mongo: `../Shortener.punk` is the
//! app. This crate gives it the same entry point as ambit's `apps/shortener`, with a document
//! database where ambit's has a key-value store.
//!
//! - `POST /links` with a URL as body: creates a short link, `201` with the short URL.
//! - `GET /<id>`: `302` to the URL, `404` if unknown, `410` once expired.

use std::time::Duration;

use ambit_caps::{Clock, Random};
use ambit_server::Handler;
use punk_server::Documents;

/// The collection the app uses, and how: the wiring allows it, and no other.
pub const COLLECTION: &str = "links";

pub struct Config {
    /// Prefix for the short URLs this app hands out, e.g. `https://ambit.link`.
    pub base_url: String,
    /// How long a link stays valid.
    pub ttl: Duration,
}

/// The app's capabilities: this signature is everything it can do. The app needs no key-value
/// store, so it gets one that fails every call.
pub fn init(
    clock: impl Clock,
    random: impl Random,
    documents: impl Documents,
    config: Config,
) -> impl Handler {
    // What the punk app reads with `Config.text!` and its `settings` decoder.
    let json = format!(
        r#"{{"baseUrl":{},"ttlSeconds":{}}}"#,
        json_string(&config.base_url),
        config.ttl.as_secs()
    );
    punk_server::App::new(clock, random, NoKv, json).with_documents(documents)
}

/// The key-value store of an app that has a database instead.
struct NoKv;

impl ambit_caps::Kv for NoKv {
    fn get(&self, _: &[u8]) -> Result<Option<Vec<u8>>, ambit_caps::KvError> {
        Err(no_kv())
    }
    fn put(&self, _: &[u8], _: &[u8]) -> Result<(), ambit_caps::KvError> {
        Err(no_kv())
    }
    fn delete(&self, _: &[u8]) -> Result<(), ambit_caps::KvError> {
        Err(no_kv())
    }
    fn scan(&self, _: &[u8]) -> Result<Vec<ambit_caps::Entry>, ambit_caps::KvError> {
        Err(no_kv())
    }
}

fn no_kv() -> ambit_caps::KvError {
    ambit_caps::KvError::new("this app has no key-value store")
}

/// `text` as a JSON string.
fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
