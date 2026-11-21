//! Wiring: which capabilities the punk app gets.
//!
//! The app connects with `DATABASE_URL` (`postgres://notes_app:password@localhost/notes`), as a
//! role that keeps to row-level security (no superuser). The table and its policies are made at
//! the start with `DATABASE_OWNER_URL`, a role that owns them and lets the app's role use them.
//! On Linux the server is then locked to its port and the database's port.

use ambit_lockdown::{Grant, Lockdown};
use ambit_server_native::{Listen, OsRandom, StdClock};
use punk_server_postgres::{Config, Owner, Postgres};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    ambit_server_native::init_tracing();

    let url =
        std::env::var("DATABASE_URL").map_err(|_| "set DATABASE_URL to the Postgres database")?;
    let owner_url = std::env::var("DATABASE_OWNER_URL")
        .map_err(|_| "set DATABASE_OWNER_URL to the role that owns the app's tables")?;
    let app_role = url
        .parse::<Config>()?
        .get_user()
        .ok_or("DATABASE_URL names no user")?
        .to_owned();
    let owner = Owner::connect(&owner_url)?;
    owner.batch(notes::SCHEMA)?;
    owner.grant(&app_role)?;
    drop(owner);

    let listen = Listen {
        addr: ([127, 0, 0, 1], 8080).into(),
        threads: 8,
        queue: 256,
    };
    let database = Postgres::new(&url, listen.threads)?;

    Lockdown::new()
        .allow(&database)
        .allow(&Grant::Listen(listen.addr.port()))
        .apply_or_warn("punk-notes")?;

    let app = notes::init(StdClock::new(), OsRandom, database);
    ambit_server_native::serve(app, listen)?;
    Ok(())
}
