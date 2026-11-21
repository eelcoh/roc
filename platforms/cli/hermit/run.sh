#!/usr/bin/env bash
# Spike: builds a punk app on the cli platform as a Hermit unikernel image, and boots it in QEMU.
#
#     sh platforms/cli/hermit/run.sh examples/punk/hermit/hello.punk
#
# Run from the repo root, with `zig-out/bin/punk` built (zig build roc) or PUNK set. Needs
# the Rust std for x86_64-unknown-hermit (see README.md) and qemu-system-x86_64. The image is written to
# platforms/cli/hermit/target/x86_64-unknown-hermit/release/punk-cli-hermit.
# Started with `sh`: go on in bash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
app=${1:?"usage: run.sh app.punk"}
here=platforms/cli/hermit

# The compiler: zig-out/bin/punk of this repository, or the one in PUNK (as the shortener's build.rs).
punk=${PUNK:-zig-out/bin/punk}
if [ ! -x "$punk" ]; then
    echo "run.sh: no punk compiler at $punk. Build it with 'zig build roc' (from the repo root), or set PUNK."
    exit 1
fi
if ! rustup run 1.97.1 rustc --print sysroot >/dev/null 2>&1 \
    || [ ! -d "$(rustup run 1.97.1 rustc --print sysroot)/lib/rustlib/x86_64-unknown-hermit" ]; then
    echo "run.sh: Rust 1.97.1 has no std for x86_64-unknown-hermit. See 'Setup' in $here/README.md."
    exit 1
fi
if ! command -v qemu-system-x86_64 >/dev/null; then
    echo "run.sh: qemu-system-x86_64 is not installed."
    exit 1
fi

# 1. The app as a static archive, for freestanding x86-64 at the baseline CPU level (x64v1elf):
#    Hermit's QEMU CPU model has no AVX. The cli platform's x64v1elf target has
#    `output: Archive`, so roc doesn't link: cargo links the image.
mkdir -p "$here/target"
archive=$PWD/$here/target/libapp.a
"$punk" build --target=x64v1elf --output="$archive" "$app"

# 2. The image: the hermit host (Rust std + kernel) with the app linked in.
(cd "$here" && PUNK_APP_OBJECTS="$archive" cargo build --release --target x86_64-unknown-hermit)
image=$here/target/x86_64-unknown-hermit/release/punk-cli-hermit
ls -l "$image"

# 3. Boot it. The loader version must match the kernel (0.13.2 needs loader v0.5.6, as in ambit).
loader=$here/target/hermit-loader-x86_64-v0.5.6
[ -f "$loader" ] || curl -sSfL -o "$loader" \
    https://github.com/hermit-os/loader/releases/download/v0.5.6/hermit-loader-x86_64
accel=()
[ -w /dev/kvm ] && accel=(-enable-kvm)
# isa-debug-exit: QEMU's exit status is (the program's << 1) | 1, so 3 means the app ended with 0.
set +e
qemu-system-x86_64 ${accel[@]+"${accel[@]}"} \
    -cpu qemu64,apic,fsgsbase,fxsr,rdrand,rdseed,rdtscp,xsave,xsaveopt \
    -smp 1 -m 64M -display none -serial stdio \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -kernel "$loader" -initrd "$image"
status=$?
set -e
[ "$status" = 3 ] && exit 0
exit "$status"
