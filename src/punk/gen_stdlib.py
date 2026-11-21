"""Prints the builtin table for src/punk/stdlib.zig from Builtin.roc.

    python3 src/punk/gen_stdlib.py src/build/roc/Builtin.roc

Paste the output between `initComptime(.{` and `});` at the end of stdlib.zig.
"""

import re
import sys

MODULES = ["Str", "List", "Try", "Iter", "Dict", "Set"]
SKIP = {"parser_for", "encoder_for", "step", "custom"}
FN_FIRST = {"map2", "map3", "map4", "map2!"}


def module_ranges(lines):
    starts = []
    for i, line in enumerate(lines):
        m = re.match(r"^\t([A-Z][A-Za-z0-9]*)\b.*::?=?", line)
        if m and (" :: " in line or " := " in line):
            starts.append((i, m.group(1)))
    ranges = {}
    for k, (i, name) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        ranges.setdefault(name, (i, end))
    return ranges


def arity(sig):
    depth, args = 0, 1
    for k, c in enumerate(sig):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c == ",":
            args += 1
        elif depth == 0 and sig[k : k + 2] in ("->", "=>"):
            return 0 if sig[:k].strip() == "()" else args
    return None


def main(path):
    lines = open(path).read().split("\n")
    ranges = module_ranges(lines)
    for mod in MODULES:
        a, b = ranges[mod]
        print(f"    // {mod}")
        seen = set()
        for i in range(a, b):
            m = re.match(r"^\t\t([a-z][a-z0-9_!]*) : (.+)$", lines[i])
            if not m or m.group(1) in SKIP or m.group(1) in seen:
                continue
            n = arity(m.group(2))
            if n is None:
                continue
            name = m.group(1)
            seen.add(name)
            if n < 2 or (mod, name) == ("Dict", "single"):
                order = "none"
            elif name.startswith("fold"):
                order = "reverse"
            elif name in FN_FIRST:
                order = "fn_first"
            else:
                order = "rotate"
            print(f'    .{{ "{mod}.{name}", Fn{{ .arity = {n}, .order = .{order} }} }},')


main(sys.argv[1])
