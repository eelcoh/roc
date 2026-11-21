# Spike: the cli platform as a Hermit unikernel

A punk app on [`platforms/cli`](../README.md), booted as a
[Hermit](https://hermit-os.org) unikernel in QEMU. This is a spike (roadmap
step 5, goal C): it answers "can a punk app be linked for
`x86_64-unknown-hermit`?". The answer is yes; see "What it shows" below.

```
sh platforms/cli/hermit/run.sh examples/punk/hermit/hello.punk
```

```
Hallo vanuit een punk-unikernel!
Kwadraten: 1, 4, 9, 16, 25, 36, 49, 64, 81, 100
Som: 385
Klok na 2026: ja
Twee toevalsgetallen verschillen: ja
```

## How it works

1. `punk build --target=x64v1elf --output=.../libapp.a` compiles the app to a
   static archive: the cli platform's `x64v1elf` target has
   `{ inputs: [app], output: Archive }`, so roc doesn't link. The archive holds
   the app and its static data, and needs nothing from a C library: only
   `roc_alloc`, `roc_dealloc`, `roc_crashed` and the hosted functions.
2. `cargo build --target x86_64-unknown-hermit` builds this crate: the same C
   ABI as the cli host, with `platforms/roc-abi` for memory and Roc's
   values, Rust std, and the Hermit kernel (the `hermit` crate builds it from
   source). `build.rs` links `libapp.a` in (`PUNK_APP_OBJECTS`).
3. QEMU boots the image with Hermit's loader.

The baseline CPU level (`x64v1elf`) matters: with `x64elf` (AVX2) the app
hangs in QEMU's `qemu64` CPU model, which is what Hermit (and ambit) use.

## Setup

The same as ambit's hermit backend:

- Rust 1.97.1 (`rust-toolchain.toml`) with the prebuilt std for Hermit:
  ```
  v=1.97.1; n=rust-std-$v-x86_64-unknown-hermit
  curl -sSfLO https://github.com/hermit-os/rust-std-hermit/releases/download/$v/$n.tar.gz
  tar xf $n.tar.gz && rustup run $v ./$n/install.sh   # into that toolchain's sysroot
  ```
- `qemu-system-x86_64`. KVM is used when `/dev/kvm` is writable; without it
  QEMU emulates, which also works (boot to app in about 0.25 s here).
- Hermit kernel `hermit-0.13.2` with loader v0.5.6 (`run.sh` downloads it).
  As in ambit: loader v0.5.7 panics with this kernel.

## What it doesn't do (yet)

- No ambit. ambit's cli backend runs on cap-std (rustix), which doesn't build
  for Hermit. The effects here are plain std: output to the serial console, the
  clock, randomness (rdseed). Stdin is empty, there are no arguments and no
  files. A real unikernel platform is `punk/server` on `ambit-server-hermit`.
- Apps that need roc's embedded runtime objects (for example compiler-rt
  functions) weren't seen: the examples tried all linked with only the two
  objects in the archive.
