//! Wiring: which capabilities the punk app gets, and with what configuration.
//!
//! The database comes from `DATABASE_URL` (`postgres://app:password@localhost/links`); the
//! app never sees it. Its role keeps to row-level security (no superuser): the tables and their
//! policies are made at the start by `DATABASE_OWNER_URL`, a role that owns them, which lets the
//! app's role use them. On Linux the server is locked to its port and the database's port: no
//! files, no other connections, no other programs.

use std::time::Duration;

use ambit_lockdown::{Grant, Lockdown};
use ambit_server_native::{Listen, OsRandom, StdClock};
use punk_server_postgres::{Config, Owner, Postgres};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    ambit_server_native::init_tracing();

    let url =
        std::env::var("DATABASE_URL").map_err(|_| "set DATABASE_URL to the Postgres database")?;
    let listen = Listen {
        addr: ([127, 0, 0, 1], 8080).into(),
        threads: 8,
        queue: 256,
    };
    let owner_url = std::env::var("DATABASE_OWNER_URL")
        .map_err(|_| "set DATABASE_OWNER_URL to the role that owns the app's tables")?;
    let app_role = url
        .parse::<Config>()?
        .get_user()
        .ok_or("DATABASE_URL names no user")?
        .to_owned();
    let owner = Owner::connect(&owner_url)?;
    owner.batch(shortener::SCHEMA)?;
    owner.grant(&app_role)?;
    drop(owner);

    // One connection per server thread: no request waits for a connection.
    let database = Postgres::new(&url, listen.threads)?;

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
