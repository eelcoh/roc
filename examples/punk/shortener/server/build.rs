//! Compiles the punk app (`../Shortener.punk`) with punkroc's compiler into `libapp.a`, and
//! links it into this crate. The compiler is `zig-out/bin/punk` of this repository (run
//! `zig build roc` first), or the one in the `PUNK` environment variable.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo = manifest.join("../../../..");
    let app = manifest.join("../Shortener.punk");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let punk = std::env::var_os("PUNK")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo.join("zig-out/bin/punk"));

    println!("cargo:rerun-if-env-changed=PUNK");
    println!("cargo:rerun-if-changed={}", app.display());
    println!("cargo:rerun-if-changed={}", punk.display());
    for dir in ["platforms/server", "packages/json"] {
        for entry in std::fs::read_dir(repo.join(dir)).unwrap().flatten() {
            let path = entry.path();
            if matches!(path.extension().and_then(|e| e.to_str()), Some("roc" | "punk")) {
                println!("cargo:rerun-if-changed={}", path.display());
            }
        }
    }

    let target = match std::env::var("TARGET").unwrap().as_str() {
        "x86_64-unknown-linux-gnu" => "x64glibc",
        "aarch64-unknown-linux-gnu" => "arm64glibc",
        "x86_64-unknown-linux-musl" => "x64musl",
        "aarch64-unknown-linux-musl" => "arm64musl",
        "x86_64-apple-darwin" => "x64mac",
        "aarch64-apple-darwin" => "arm64mac",
        // Freestanding ELF at the baseline CPU level: Hermit's QEMU CPU model has no AVX.
        "x86_64-unknown-hermit" => "x64v1elf",
        other => panic!("punkroc's server platform has no target for {other} yet"),
    };
    let archive = out.join("libapp.a");
    let status = Command::new(&punk)
        .arg("build")
        .arg(format!("--target={target}"))
        .arg(format!("--output={}", archive.display()))
        .arg(&app)
        .status()
        .unwrap_or_else(|e| {
            panic!(
                "could not run {} ({e}); build the compiler with `zig build roc`, or set PUNK",
                punk.display()
            )
        });
    assert!(status.success(), "punk build failed for {}", app.display());

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=app");
}
