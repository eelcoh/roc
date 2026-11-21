#!/bin/sh
# Builds the host of punkroc's platform (test/punk/platform) and puts it where
# `roc` looks for it, for the targets of this computer. Run from the repo root:
#
#     sh test/punk/setup.sh
#
set -e
zig build build-test-hosts -Dplatform=punk

newest() { ls -t "$@" 2>/dev/null | head -n 1; }

for target in x64musl arm64musl x64mac arm64mac; do
    host=""
    for lib in $(ls -t $(find .zig-cache/o -name libhost.a)); do
        if ar t "$lib" 2>/dev/null | grep -q "test_platform_punk_host_${target}_zcu.o"; then host="$lib"; break; fi
    done
    [ -n "$host" ] || continue
    dir=test/punk/platform/targets/$target
    mkdir -p "$dir"
    cp "$host" "$dir/libhost.a"
    case $target in
        *musl)
            cp test/fx/platform/targets/$target/crt1.o test/fx/platform/targets/$target/libc.a "$dir/"
            arch=x86_64; [ "$target" = arm64musl ] && arch=aarch64
            cp "$(newest $(find .zig-cache/o -name "rcrt1_$arch.o"))" "$dir/rcrt1.o"
            ;;
    esac
    echo "punkroc platform ready for $target"
done
