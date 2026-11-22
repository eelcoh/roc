//! The wiring: `punk-library <folder>` shows the books of `<folder>/library.json`, on ambit's
//! native terminal. The app sees that folder and nothing else.

use std::process::ExitCode;

fn main() -> ExitCode {
    let Some(path) = std::env::args_os().nth(1) else {
        eprintln!("usage: punk-library <folder with library.json>");
        return ExitCode::from(2);
    };
    let folder = match ambit_caps_dir_native::NativeDir::open(&path) {
        Ok(folder) => folder,
        Err(e) => {
            eprintln!("punk-library: can't open {}: {e}", path.to_string_lossy());
            return ExitCode::FAILURE;
        }
    };
    let app = punk_library::init(folder, ambit_caps_native::StdClock::new());
    match ambit_tui_native::run(app, Default::default()) {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("punk-library: {e}");
            ExitCode::FAILURE
        }
    }
}
