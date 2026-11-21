//! ambit's link shortener, written in punk: `../Shortener.punk` is the app, this crate gives it
//! the same Rust entry point as ambit's `apps/shortener`, so ambit's spec runs against it.
//!
//! - `POST /links` with a URL as body: creates a short link, `201` with the short URL.
//! - `GET /<id>`: `302` to the URL, `404` if unknown, `410` once expired.

use std::time::Duration;

use ambit_caps::{Clock, Kv, Random};
use ambit_server::Handler;

pub struct Config {
    /// Prefix for the short URLs this app hands out, e.g. `https://ambit.link`.
    pub base_url: String,
    /// How long a link stays valid.
    pub ttl: Duration,
}

/// The app's capabilities: this signature is everything it can do.
pub fn init(clock: impl Clock, random: impl Random, kv: impl Kv, config: Config) -> impl Handler {
    // What the punk app reads with `Config.text!` and its `settings` decoder.
    let json = format!(
        r#"{{"baseUrl":{},"ttlSeconds":{}}}"#,
        json_string(&config.base_url),
        config.ttl.as_secs()
    );
    punk_server::App::new(clock, random, kv, json)
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

#[cfg(test)]
mod tests {
    use super::json_string;

    #[test]
    fn strings_are_escaped() {
        assert_eq!(json_string("a\"b\\c\n\u{1}"), r#""a\"b\\c\n\u0001""#);
    }
}
