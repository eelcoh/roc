#!/bin/sh
# Golden tests: runs the punkroc examples listed in test/punk/golden/cases.txt
# and compares their output (stdout, exit code and any file they write) with
# test/punk/golden/expected/. Run from the repo root, after `zig build roc`
# and `sh test/punk/setup.sh`:
#
#     sh test/punk/golden.sh            check
#     sh test/punk/golden.sh --update   write the expected output anew
#
# Server apps are only type-checked here (their crate's cargo test runs them).
# It fails as well when a program in examples/punk/ has no case, so that a
# new example cannot be forgotten, when a .punk file there is not laid out
# as `punk fmt` would, and when src/punk/llms.txt is out of date.
set -u

root=$(pwd)
roc="$root/zig-out/bin/roc"
golden="$root/test/punk/golden"
update=no
[ "${1:-}" = "--update" ] && update=yes

if [ ! -x "$roc" ]; then
    echo "no $roc: run 'zig build roc' first"
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0
passed=0

run_case() {
    name=$1 program=$2 stdin=${3:--}
    shift 2; [ $# -gt 0 ] && shift
    dir="$work/run"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "$golden"/input/* "$dir/"
    ls "$dir" > "$work/before"
    actual="$work/actual"
    if [ "$stdin" = "-" ]; then input=/dev/null; else input="$golden/input/$stdin"; fi
    (cd "$dir" && timeout 600 "$roc" "$root/examples/punk/$program" "$@" < "$input" > "$actual" 2> "$work/stderr")
    code=$?
    echo "exit $code" >> "$actual"
    # Files the program wrote.
    for f in $(ls "$dir" | grep -vxF -f "$work/before"); do
        echo "--- $f" >> "$actual"
        cat "$dir/$f" >> "$actual"
        echo >> "$actual"
    done
    expected="$golden/expected/$name.out"
    if [ "$update" = yes ]; then
        mkdir -p "$(dirname "$expected")"
        cp "$actual" "$expected"
        echo "updated $name"
    elif [ ! -f "$expected" ]; then
        echo "FAIL $name: no expected output (run with --update)"
        failed=$((failed + 1))
    elif diff -u "$expected" "$actual" > "$work/diff"; then
        echo "ok   $name"
        passed=$((passed + 1))
    else
        echo "FAIL $name"
        sed 's/^/     /' "$work/diff"
        echo "     stderr:"
        sed 's/^/     /' "$work/stderr" | tail -n 30
        failed=$((failed + 1))
    fi
}

grep -v '^\s*#' "$golden/cases.txt" | grep -v '^\s*$' > "$work/cases"
while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    run_case "$@"
done < "$work/cases"

# A server app (on platforms/server) can't run here: it is an archive that
# its Rust crate links and tests (cargo test in its server/ folder, which runs
# ambit's spec). Here it only has to type-check.
server_apps=$(cd examples/punk && grep -l '^app.*platforms/server/main.roc' $(find . -name '*.punk') | sed 's|^\./||' | sort)
for f in $server_apps; do
    if "$roc" check "examples/punk/$f" > "$work/check" 2>&1; then
        echo "ok   check $f"
        passed=$((passed + 1))
    else
        echo "FAIL check $f"
        sed 's/^/     /' "$work/check" | tail -n 30
        failed=$((failed + 1))
    fi
done

# Every other app in examples/punk/ needs at least one case.
for f in $(cd examples/punk && grep -l '^app' $(find . -name '*.punk') | sed 's|^\./||' | grep -vxF "$server_apps" | sort); do
    if ! awk '{print $2}' "$work/cases" | grep -qxF "$f"; then
        echo "FAIL examples/punk/$f has no case in test/punk/golden/cases.txt"
        failed=$((failed + 1))
    fi
done

# Every .punk file in examples/punk/ is formatted as `punk fmt` lays it out.
unformatted=$("$roc" fmt --check $(find examples/punk -name '*.punk' | sort) 2>&1)
if [ $? -ne 0 ]; then
    echo "FAIL punk fmt --check:"
    echo "$unformatted" | sed 's/^/     /'
    failed=$((failed + 1))
else
    echo "ok   punk fmt --check"
    passed=$((passed + 1))
fi

# src/punk/llms.txt is generated from the source; it must be up to date.
if python3 src/punk/gen_llms.py --check; then
    echo "ok   llms.txt up to date"
    passed=$((passed + 1))
else
    echo "FAIL llms.txt: run python3 src/punk/gen_llms.py"
    failed=$((failed + 1))
fi

[ "$update" = yes ] && exit 0
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
