"""Writes src/punk/llms.txt, punkroc's reference for agents, from
src/punk/llms.in.md and the source code, so it does not go stale:

    python3 src/punk/gen_llms.py            write src/punk/llms.txt
    python3 src/punk/gen_llms.py --check    fail when llms.txt is out of date

In llms.in.md:

    @@stdlib@@          the signatures of the standard library, as punkroc
                        sees them: names, argument order and types come from
                        stdlib.zig, elm.zig and Builtin.roc
    @@example <path>@@  the file examples/punk/<path>, which the golden tests
                        run, so every cookbook example is known to work

A name in STDLIB below that punkroc no longer has is an error, as is a
helper in elm.zig whose signature is missing from HELPERS.
"""

import os
import re
import sys

sys.dont_write_bytecode = True
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from gen_stdlib import module_ranges  # noqa: E402

root = os.path.normpath(os.path.join(here, "..", ".."))


def read(rel):
    with open(os.path.join(root, rel)) as f:
        return f.read()


# The functions listed, by module, in punkroc spelling. The type and argument
# order of builtins come from Builtin.roc and stdlib.zig.
STDLIB = {
    "List": [
        "map", "filter", "filterMap", "concatMap", "indexedMap", "map2",
        "foldl", "foldr", "sum", "length", "len", "isEmpty",
        "head", "tail", "first", "last", "get", "set", "update", "range",
        "reverse", "sort", "sortWith", "take", "drop", "any", "all",
        "member", "countIf", "dropIf", "findFirst", "mapTry", "append",
        "concat", "join", "maximum", "minimum", "singleton", "repeat",
        "dropAt", "splitAt",
    ],
    "String": [
        "split", "join", "lines", "words", "trim", "trimLeft", "trimRight",
        "length", "isEmpty", "contains", "startsWith", "endsWith", "replace",
        "toUpper", "toLower", "repeat", "append", "concat", "toInt",
        "fromInt",
    ],
    "Str": ["splitOn", "joinWith", "toUtf8", "fromUtf8", "dropPrefix", "dropSuffix", "splitFirst"],
    "Maybe": ["withDefault", "map", "andThen"],
    "Result": ["map", "mapError", "withDefault", "andThen", "toMaybe", "fromMaybe", "isOk"],
    "Tuple": ["first", "second", "pair", "mapFirst", "mapSecond"],
    "Dict": [
        "empty", "insert", "get", "update", "remove", "contains", "keys",
        "values", "toList", "fromList", "fold", "map", "keepIf", "len",
    ],
    "Set": [
        "empty", "insert", "contains", "remove", "fromList", "toList",
        "union", "intersection", "difference", "len", "map",
    ],
    "": ["compare", "min", "max", "identity", "toInt", "fromInt", "toFloat", "modBy", "remainderBy"],
}

# Signatures of the helpers in elm.zig and numbers.zig, which are not in
# Builtin.roc, in punkroc syntax (by their snake_case name in Roc).
HELPERS = {
    "List.range": "Int -> Int -> List Int",
    "List.head": "List a -> Maybe a",
    "List.tail": "List a -> Maybe (List a)",
    "List.maximum": "List a -> Maybe a",
    "List.minimum": "List a -> Maybe a",
    "List.length": "List a -> Int",
    "List.indexed_map": "(Int -> a -> b) -> List a -> List b",
    "List.sort_with": "(a -> a -> Order) -> List a -> List a",
    "List.take": "Int -> List a -> List a",
    "List.drop": "Int -> List a -> List a",
    "List.singleton": "a -> List a",
    "List.is_member": "a -> List a -> Bool",
    "Tuple.first": "(a, b) -> a",
    "Tuple.second": "(a, b) -> b",
    "Tuple.pair": "a -> b -> (a, b)",
    "Tuple.map_first": "(a -> x) -> (a, b) -> (x, b)",
    "Tuple.map_second": "(b -> y) -> (a, b) -> (a, y)",
    "Maybe.with_default": "a -> Maybe a -> a",
    "Maybe.map": "(a -> b) -> Maybe a -> Maybe b",
    "Maybe.and_then": "(a -> Maybe b) -> Maybe a -> Maybe b",
    "Result.and_then": "(a -> Result b err) -> Result a err -> Result b err",
    "Result.to_maybe": "Result a e -> Maybe a",
    "Result.from_maybe": "e -> Maybe a -> Result a e",
    "String.length": "Str -> Int",
    "String.lines": "Str -> List Str",
    "String.words": "Str -> List Str",
    "String.to_int": "Str -> Maybe Int",
    "String.from_int": "Int -> Str",
    "String.append": "Str -> Str -> Str",
    "String.concat": "List Str -> Str",
    "String.repeat": "Int -> Str -> Str",
    "compare": "a -> a -> Order",
    "to_int": "U64 -> Int",
    "from_int": "Int -> U64",
    "to_float": "Int -> Float",
    "min": "a -> a -> a",
    "max": "a -> a -> a",
    "identity": "a -> a",
    "mod_by": "Int -> Int -> Int",
    "remainder_by": "Int -> Int -> Int",
}

# Elm's module name for Roc's: `String.split` is `Str.split_on`.
MODULE_ALIASES = {"String": "Str", "Result": "Try"}


def snake(name):
    return re.sub(r"([A-Z])", lambda m: "_" + m.group(1).lower(), name)


def camel(name):
    return re.sub(r"_([a-z0-9])", lambda m: m.group(1).upper(), name)


def tables():
    stdlib = read("src/punk/stdlib.zig")
    elm = read("src/punk/elm.zig")
    numbers = read("src/punk/numbers.zig")
    fns = {}
    for m in re.finditer(r'\.\{ "([\w.!]+)", Fn\{ \.arity = (\d+), \.order = \.(\w+)(?:, \.state_last = (\d+))? \} \}', stdlib):
        fns[m.group(1)] = (int(m.group(2)), m.group(3), int(m.group(4) or 0))
    aliases = dict(re.findall(r'\.\{ "(Result\.\w+)", "(Try\.\w+)" \}', stdlib))
    renames_block = elm[elm.index("const renames"):elm.index("const helpers")]
    renames = dict(re.findall(r'\.\{ "([\w.]+)", "([\w.]+)" \}', renames_block))
    helpers = set(re.findall(r'\.\{ "([\w.]+)", Helper\{', elm))
    helpers |= set(re.findall(r'"(mod_by|remainder_by)"', numbers))
    return fns, aliases, renames, helpers


def builtin_sigs():
    lines = read("src/build/roc/Builtin.roc").split("\n")
    ranges = module_ranges(lines)
    sigs = {}
    for mod in ["Str", "List", "Try", "Dict", "Set"]:
        a, b = ranges[mod]
        for i in range(a, b):
            m = re.match(r"^\t\t([a-z][a-z0-9_!]*) : (.+)$", lines[i])
            if m:
                sigs.setdefault(f"{mod}.{m.group(1)}", m.group(2))
    return sigs


# Roc types to punkroc types.

def split_top(s, sep=","):
    parts, depth, cur = [], 0, ""
    for c in s:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if depth == 0 and c == sep:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
    parts.append(cur.strip())
    return parts


def top_arrow(s):
    depth = 0
    for k, c in enumerate(s):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and s[k : k + 2] in ("->", "=>"):
            return k
    return None


def fn_parts(s):
    """`a, b -> c` as (["a", "b"], "->", "c"), or None."""
    k = top_arrow(s)
    if k is None:
        return None
    params = [] if s[:k].strip() == "()" else split_top(s[:k])
    return params, s[k : k + 2], s[k + 2 :].strip()


def needs_parens(t):
    return " " in t and not (t.startswith("(") and t.endswith(")")) and not t.startswith("[") and not t.startswith("{")


def ty(s, state_last=False):
    """A Roc type in punkroc syntax."""
    s = s.strip()
    s = re.sub(r"\s+where\s+\[.*\]$", "", s)
    f = fn_parts(s)
    if f:
        params, arrow, ret = f
        params = [ty(p) for p in params]
        if state_last and len(params) > 1:
            params = params[1:] + params[:1]
        params = [f"({p})" if fn_parts(p) else p for p in params]
        if not params:
            params = ["()"]
        return " -> ".join(params) + f" {arrow} " + ty(ret)
    m = re.match(r"^([A-Z][\w.]*)\((.*)\)$", s)
    if m:
        name = {"Try": "Result"}.get(m.group(1), m.group(1))
        args = []
        for a in split_top(m.group(2)):
            t = ty(a)
            args.append(f"({t})" if needs_parens(t) or fn_parts(t) else t)
        return " ".join([name] + args)
    if s.startswith("(") and s.endswith(")") and fn_parts(s[1:-1]):
        return ty(s[1:-1], state_last)
    if s.startswith("(") and s.endswith(")"):
        inner = split_top(s[1:-1])
        if len(inner) == 1:
            t = ty(inner[0])
            return f"({t})"
        return "(" + ", ".join(ty(x) for x in inner) + ")"
    if s.startswith("[") and s.endswith("]"):
        tags = []
        for t in split_top(s[1:-1]):
            m = re.match(r"^([A-Z]\w*)\((.*)\)$", t)
            tags.append(m.group(1) + " " + " ".join(ty(x) for x in split_top(m.group(2))) if m else t)
        return "[" + ", ".join(tags) + "]"
    if s.startswith("{") and s.endswith("}"):
        fields = []
        for fld in split_top(s[1:-1]):
            if ":" in fld:
                n, t = fld.split(":", 1)
                fields.append(f"{camel(n.strip())} : {ty(t)}")
        return "{ " + ", ".join(fields) + " }" if fields else "{}"
    s = re.sub(r"^_(\w)", r"\1", s)
    return camel(s)


def reorder(params, order):
    n = len(params)
    if order == "rotate" and n > 1:
        return params[1:] + params[:1]
    if order == "reverse":
        return params[::-1]
    if order == "fn_first" and n > 1:
        return params[-1:] + params[:-1]
    return params


def signature(mod, name, fns, aliases, renames, helpers, sigs):
    qual = f"{mod}.{snake(name)}" if mod else snake(name)
    if qual in helpers:
        if qual not in HELPERS:
            sys.exit(f"gen_llms.py: no signature for the helper {qual} in HELPERS")
        return HELPERS[qual]
    roc = aliases.get(qual) or renames.get(qual) or qual
    rmod, rname = roc.split(".", 1) if "." in roc else ("", roc)
    rmod = MODULE_ALIASES.get(rmod, rmod)
    roc = f"{rmod}.{rname}"
    if roc not in fns or roc not in sigs:
        sys.exit(f"gen_llms.py: punkroc has no {mod + '.' if mod else ''}{name} (looked for {roc})")
    arity, order, state_last = fns[roc]
    if rname == "empty":
        # A value in punkroc (`Set.empty`), a function in Roc.
        return ty(fn_parts(sigs[roc])[2])
    f = fn_parts(sigs[roc])
    if f is None:
        return ty(sigs[roc])
    params, arrow, ret = f
    params = reorder(params, order)
    out = []
    for p in params:
        t = ty(p, state_last=bool(state_last))
        out.append(f"({t})" if fn_parts(t) else t)
    if not out:
        out = ["()"]
    return " -> ".join(out) + f" {arrow} " + ty(re.sub(r"\s+where\s+\[.*\]$", "", ret))


def stdlib_section():
    fns, aliases, renames, helpers = tables()
    sigs = builtin_sigs()
    out = []
    for mod, names in STDLIB.items():
        out.append(f"### {mod or 'Basics (no module)'}")
        out.append("")
        out.append("```")
        for name in names:
            sig = signature(mod, name, fns, aliases, renames, helpers, sigs)
            out.append(f"{mod + '.' if mod else ''}{name} : {sig}")
        out.append("```")
        out.append("")
    return "\n".join(out).rstrip("\n")


def generate():
    text = read("src/punk/llms.in.md")
    text = text.replace("@@stdlib@@", stdlib_section())

    def example(m):
        path = m.group(1)
        return "```\n" + read(os.path.join("examples/punk", path)).rstrip("\n") + "\n```"

    text = re.sub(r"@@example ([\w./-]+)@@", example, text)
    header = "<!-- Generated by src/punk/gen_llms.py from src/punk/llms.in.md; do not edit. -->\n"
    return header + text


def main():
    out = generate()
    path = os.path.join(root, "src/punk/llms.txt")
    if "--check" in sys.argv:
        current = open(path).read() if os.path.exists(path) else ""
        if current != out:
            sys.exit("src/punk/llms.txt is out of date: run python3 src/punk/gen_llms.py")
        return
    with open(path, "w") as f:
        f.write(out)


if __name__ == "__main__":
    main()
