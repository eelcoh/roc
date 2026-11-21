//! Wiring: which capabilities the punk app gets, and with what configuration.
//!
//! The database comes from `DATABASE_URL` (`postgres://user:password@localhost/links`); the
//! app never sees it. On Linux the server is locked to its port and the database's port: no
//! files, no other connections, no other programs.

use std::time::Duration;

use ambit_lockdown::{Grant, Lockdown};
use ambit_server_native::{Listen, OsRandom, StdClock};
use punk_server_postgres::Postgres;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    ambit_server_native::init_tracing();

    let url =
        std::env::var("DATABASE_URL").map_err(|_| "set DATABASE_URL to the Postgres database")?;
    let listen = Listen {
        addr: ([127, 0, 0, 1], 8080).into(),
        threads: 8,
        queue: 256,
    };
    // One connection per server thread: no request waits for a connection.
    let database = Postgres::new(&url, listen.threads)?;
    database.batch(shortener::SCHEMA)?;

    Lockdown::new()
        .allow(&database)
        .allow(&Grant::Listen(listen.addr.port()))
        .apply_or_warn("punk-shortener-postgres")?;

    let config = shortener::Config {
        base_url: "http://localhost:8080".into(),
        ttl: Duration::from_secs(7 * 24 * 3600),
    };
    let app = shortener::init(StdClock::new(), OsRandom, database, config);
    ambit_server_native::serve(app, listen)?;
    Ok(())
}
