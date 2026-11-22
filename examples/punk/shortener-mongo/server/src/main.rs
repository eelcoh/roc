//! Wiring: which capabilities the punk app gets, and with what configuration.
//!
//! The database comes from `MONGO_URL` (`mongodb://app:password@localhost:27017`) and
//! `MONGO_DATABASE` (default `shortener`); the app never sees them, and may only read and write
//! the collection `links`. On Linux the server is locked to its port and the database's port:
//! no files, no other connections, no other programs.

use std::time::Duration;

use ambit_lockdown::{Grant, Lockdown};
use ambit_server_native::{Listen, OsRandom, StdClock};
use punk_server_mongo::{Access, Mongo};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    ambit_server_native::init_tracing();

    let url = std::env::var("MONGO_URL").map_err(|_| "set MONGO_URL to the Mongo server")?;
    let name = std::env::var("MONGO_DATABASE").unwrap_or_else(|_| "shortener".into());
    let listen = Listen {
        addr: ([127, 0, 0, 1], 8080).into(),
        threads: 8,
        queue: 256,
    };
    let mongo = Mongo::connect(&url, &name)?.allow(shortener::COLLECTION, Access::ReadWrite);

    Lockdown::new()
        .allow(&mongo)
        .allow(&Grant::Listen(listen.addr.port()))
        .apply_or_warn("punk-shortener-mongo")?;

    let config = shortener::Config {
        base_url: "http://localhost:8080".into(),
        ttl: Duration::from_secs(7 * 24 * 3600),
    };
    let app = shortener::init(StdClock::new(), OsRandom, mongo, config);
    ambit_server_native::serve(app, listen)?;
    Ok(())
}
