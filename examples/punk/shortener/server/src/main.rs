//! Wiring: which capabilities the punk app gets, and with what configuration (ambit's
//! run-native, for the punk shortener).
//!
//! On Linux the server is locked to its database and its port: no other files, no outgoing
//! connections, no other programs.
//!
//! As a Hermit unikernel the wiring is `hermit.rs` instead.

#[cfg(target_os = "hermit")]
mod hermit;

#[cfg(target_os = "hermit")]
use hermit::main;

#[cfg(not(target_os = "hermit"))]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::time::Duration;

    use ambit_caps_kv_native::NativeKv;
    use ambit_lockdown::{Grant, Lockdown};
    use ambit_server_native::{Listen, OsRandom, StdClock};

    ambit_server_native::init_tracing();

    let config = shortener::Config {
        base_url: "http://localhost:8080".into(),
        ttl: Duration::from_secs(7 * 24 * 3600),
    };
    std::fs::create_dir_all("data")?;
    let kv = NativeKv::open("data/app.redb")?;
    let listen = Listen {
        addr: ([127, 0, 0, 1], 8080).into(),
        threads: 8,
        queue: 256,
    };
    Lockdown::new()
        .allow(&kv)
        .allow(&Grant::Listen(listen.addr.port()))
        .apply_or_warn("punk-shortener")?;

    let app = shortener::init(StdClock::new(), OsRandom, kv, config);
    ambit_server_native::serve(app, listen)?;
    Ok(())
}
