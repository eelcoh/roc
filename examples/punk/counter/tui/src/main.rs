//! The wiring: the counter gets the system clock, on ambit's native terminal.
fn main() -> std::io::Result<()> {
    let app = punk_counter::init(ambit_caps_native::StdClock::new());
    ambit_tui_native::run(app, Default::default())?;
    Ok(())
}
