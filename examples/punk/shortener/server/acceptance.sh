#!/usr/bin/env bash
# Black-box acceptance tests over HTTP, the same for every backend: ambit's
# scripts/acceptance.sh (pinned commit), with only the startup changed for this crate.
# Usage (from this folder): ./acceptance.sh native|hermit
#
# hermit needs the Rust std for x86_64-unknown-hermit and qemu-system-x86_64, as in
# platforms/cli/hermit/README.md. KVM is used when /dev/kvm is writable.
set -euo pipefail
cd "$(dirname "$0")"
backend=${1:?usage: $0 native|hermit}
base=http://localhost:8080
log=$(mktemp)

case $backend in
  native)
    cargo build -q --locked --release
    ./target/release/punk-shortener >"$log" 2>&1 & ;;
  hermit)
    sysroot=$(rustup run 1.97.1 rustc --print sysroot 2>/dev/null || true)
    if [ ! -d "$sysroot/lib/rustlib/x86_64-unknown-hermit" ]; then
      echo "Rust 1.97.1 has no std for x86_64-unknown-hermit: see 'Setup' in platforms/cli/hermit/README.md"
      exit 1
    fi
    command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 is not installed"; exit 1; }
    cargo build -q --locked --release --target x86_64-unknown-hermit
    # Loader v0.5.6 matches hermit 0.13.2; v0.5.7 panics in early paging with this kernel.
    loader=target/hermit-loader-x86_64-v0.5.6
    [ -f "$loader" ] || curl -sSfL -o "$loader" \
      https://github.com/hermit-os/loader/releases/download/v0.5.6/hermit-loader-x86_64
    accel=()
    [ -w /dev/kvm ] && accel=(-enable-kvm)
    qemu-system-x86_64 ${accel[@]+"${accel[@]}"} \
      -cpu qemu64,apic,fsgsbase,fxsr,rdrand,rdseed,rdtscp,xsave,xsaveopt \
      -smp 1 -m 64M -display none -serial stdio \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -kernel "$loader" -initrd target/x86_64-unknown-hermit/release/punk-shortener \
      -netdev user,id=net0,hostfwd=tcp::8080-:8080,net=192.168.76.0/24,dhcpstart=192.168.76.9 \
      -device virtio-net-pci,netdev=net0,disable-legacy=on >"$log" 2>&1 & ;;
  *) echo "unknown backend: $backend"; exit 2 ;;
esac
pid=$!
# Cleanup must not change the exit status (set -e also applies inside the trap).
trap 'kill $pid 2>/dev/null || true; pkill -P $pid 2>/dev/null || true; rm -f "$log"' EXIT

# Without KVM, QEMU emulates and the image takes a few seconds to come up.
for _ in $(seq 300); do curl -s -o /dev/null -m 0.2 $base/ && break; sleep 0.1; done
failures=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

short=$(curl -s -X POST --data 'https://example.com/a?b=c' $base/links)
check "create returns a short url under base_url" "$base/" "${short%???????}"
check "short link redirects" 302 "$(status "$short")"
check "redirect target" "https://example.com/a?b=c" "$(curl -s -o /dev/null -w '%{redirect_url}' "$short")"
check "unknown id" 404 "$(status $base/zzzzzzz)"
check "unknown route" 404 "$(status $base/nope/nope)"
check "invalid url" 400 "$(status -X POST --data 'javascript:alert(1)' $base/links)"
check "body over 1 MiB" 413 "$(head -c 2000000 /dev/zero | status -X POST --data-binary @- $base/links)"
check "headers over 16 KiB" 431 "$(status -H "X-Big: $(head -c 20000 /dev/zero | tr '\0' a)" $base/)"
check "chunked body" 501 "$(echo https://x.org | status -X POST -H 'Transfer-Encoding: chunked' --data-binary @- $base/links)"

# Not `wait` without arguments: that would also wait for the server.
codes=$(mktemp)
pids=()
for i in $(seq 20); do
  # One write per result (-w with the newline), so concurrent appends don't interleave.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST --data "https://example.com/$i" $base/links >>"$codes" &
  pids+=($!)
done
wait "${pids[@]}"
check "20 concurrent creates" "20" "$(grep -cx 201 "$codes")"
rm -f "$codes"

if [ $failures -gt 0 ]; then
  echo "acceptance ($backend): $failures failed"; echo "--- log"; cat "$log"; exit 1
fi
echo "acceptance ($backend): OK"
