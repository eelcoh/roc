#!/bin/sh
# Builds the hosts of the platforms the punkroc examples use (punkroc's own
# test/punk/platform and upstream's test/fx/platform) and puts them where
# `roc` looks for them, for the targets of this computer. Run from the repo root:
#
#     sh test/punk/setup.sh
#
set -e

# The compiler needs exactly this Zig (see build.zig.zon); another version
# fails with errors such as "invalid builtin function: '@backingInt'".
want=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)
have=$(zig version 2>/dev/null || echo none)
if [ "$have" != "$want" ]; then
    echo "punkroc needs Zig $want, but 'zig' here is $have ($(command -v zig || echo 'not found'))."
    echo "See 'Zig' in src/punk/README.md."
    exit 1
fi

newest() { ls -t "$@" 2>/dev/null | head -n 1; }

for platform in punk fx; do
    zig build build-test-hosts -Dplatform=$platform
    for target in x64musl arm64musl x64mac arm64mac; do
        host=""
        for lib in $(ls -t $(find .zig-cache/o -name libhost.a)); do
            if ar t "$lib" 2>/dev/null | grep -q "test_platform_${platform}_host_${target}_zcu.o"; then host="$lib"; break; fi
        done
        [ -n "$host" ] || continue
        dir=test/$platform/platform/targets/$target
        mkdir -p "$dir"
        cp "$host" "$dir/libhost.a"
        case $target in
            *musl)
                if [ "$platform" != fx ]; then
                    cp test/fx/platform/targets/$target/crt1.o test/fx/platform/targets/$target/libc.a "$dir/"
                fi
                arch=x86_64; [ "$target" = arm64musl ] && arch=aarch64
                cp "$(newest $(find .zig-cache/o -name "rcrt1_$arch.o"))" "$dir/rcrt1.o"
                ;;
        esac
        echo "$platform platform ready for $target"
    done
done
