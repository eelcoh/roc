#!/usr/bin/env bash
# Spike: builds a punk app on the cli platform as a Hermit unikernel image, and boots it in QEMU.
#
#     sh platforms/cli/hermit/run.sh examples/punk/hermit/hello.punk
#
# Run from the repo root, with `zig-out/bin/punk` built (zig build roc). Needs the Rust std for
# x86_64-unknown-hermit (see README.md) and qemu-system-x86_64. The image is written to
# platforms/cli/hermit/target/x86_64-unknown-hermit/release/punk-cli-hermit.
set -euo pipefail
app=${1:?"usage: run.sh app.punk"}
here=platforms/cli/hermit

# 1. The app as objects, for freestanding x86-64 at the baseline CPU level (x64v1elf): Hermit's
#    QEMU CPU model has no AVX. roc can't link a Hermit image itself, so the build stops at
#    "missing host symbols" (that's expected) and --keep-temp keeps the objects it made.
out=$(zig-out/bin/punk build --target=x64v1elf --keep-temp --output=/dev/null "$app" 2>&1 || true)
dir=$(printf '%s\n' "$out" | grep -A2 'Kept temporary directory' | grep -o '[^ ]*/roc/tmp/[0-9a-f]*' | head -n 1 || true)
if [ -z "$dir" ] || ! printf '%s\n' "$out" | grep -q 'missing host symbols'; then
    printf '%s\n' "$out"
    echo "run.sh: roc did not make the app's objects (see above)"
    exit 1
fi
case $dir in /*) ;; *) dir="$PWD/$dir" ;; esac
objects=$(ls "$dir"/*.o | tr '\n' ' ')

# 2. The image: the hermit host (Rust std + kernel) with the app's objects linked in.
(cd "$here" && PUNK_APP_OBJECTS="$objects" cargo build --release --target x86_64-unknown-hermit)
rm -rf "$dir"
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
qemu-system-x86_64 "${accel[@]}" \
    -cpu qemu64,apic,fsgsbase,fxsr,rdrand,rdseed,rdtscp,xsave,xsaveopt \
    -smp 1 -m 64M -display none -serial stdio \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -kernel "$loader" -initrd "$image"
status=$?
set -e
[ "$status" = 3 ] && exit 0
exit "$status"
