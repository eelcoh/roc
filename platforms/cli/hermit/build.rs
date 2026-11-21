//! Links the compiled punk app into the image. `PUNK_APP_OBJECTS` holds the paths of what roc
//! made for the app (the `libapp.a` of `punk build --target=x64v1elf`, or object files),
//! separated by spaces (see README.md).
fn main() {
    println!("cargo::rerun-if-env-changed=PUNK_APP_OBJECTS");
    let objects = std::env::var("PUNK_APP_OBJECTS").unwrap_or_default();
    if objects.trim().is_empty() {
        panic!("PUNK_APP_OBJECTS is empty: give the libapp.a roc made, see README.md");
    }
    for object in objects.split_whitespace() {
        println!("cargo::rerun-if-changed={object}");
        println!("cargo::rustc-link-arg={object}");
    }
}
