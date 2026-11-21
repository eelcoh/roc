//! Wiring as a Hermit unikernel (ambit's run-hermit, for the punk shortener).
//!
//! The image is the whole machine: no other files or programs exist in it, so there is nothing
//! to lock down. The only way in is the port.

use std::time::Duration;

// The kernel, with the features Cargo.toml gives it.
use hermit as _;

use ambit_server_hermit::{EphemeralKv, HermitRandom, Listen, StdClock};

pub fn main() -> Result<(), Box<dyn std::error::Error>> {
    ambit_server_hermit::init_tracing();

    let config = shortener::Config {
        base_url: "http://localhost:8080".into(),
        ttl: Duration::from_secs(7 * 24 * 3600),
    };
    // No storage on hermit yet: links are lost when the VM stops (as in ambit).
    let kv = EphemeralKv::new();
    let app = shortener::init(StdClock::new(), HermitRandom::new()?, kv, config);

    ambit_server_hermit::serve(
        app,
        Listen {
            addr: ([0, 0, 0, 0], 8080).into(),
            threads: 4,
            queue: 64,
        },
    )?;
    Ok(())
}
