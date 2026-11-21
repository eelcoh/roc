//! Translation tests for punkroc: punkroc source in, expected Roc source out.

const std = @import("std");
const punk = @import("translate.zig");

fn check(src: []const u8, expected: []const u8) (punk.Error || error{TestExpectedEqual})!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const out = punk.translate(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message });
        return err;
    };
    try std.testing.expectEqualStrings(expected, out);
}

fn checkError(src: []const u8, line: u32, msg_part: []const u8) error{ TestExpectedEqual, TestUnexpectedResult }!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    if (punk.translate(arena.allocator(), src, &diag)) |out| {
        std.debug.print("expected an error, got:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(line, diag.line);
    if (std.mem.find(u8, diag.message, msg_part) == null) {
        std.debug.print("message was: {s}\n", .{diag.message});
        return error.TestUnexpectedResult;
    }
}

test "snake case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("keep_if", try punk.snake(a, "keepIf"));
    try std.testing.expectEqualStrings("to_utf8", try punk.snake(a, "toUTF8"));
    try std.testing.expectEqualStrings("parse_http_request", try punk.snake(a, "parseHTTPRequest"));
    try std.testing.expectEqualStrings("map2", try punk.snake(a, "map2"));
    try std.testing.expectEqualStrings("already_snake", try punk.snake(a, "already_snake"));
    try std.testing.expectEqualStrings("line!", try punk.snake(a, "line!"));
}

test "functions, application, lambdas" {
    try check(
        \\add : I64, I64 -> I64
        \\add = fn a, b ->
        \\    a + b
        \\
        \\total = add 1 (add 2 3)
        \\names = List.map (fn u -> u.firstName) users
        \\now! = fn () -> Time.now! ()
    ,
        \\add : I64, I64 -> I64
        \\add = |a, b| a + b
        \\
        \\total = add(1, add(2, 3))
        \\names = List.map(users, |u| u.first_name)
        \\now! = || Time.now!()
        \\
    );
}

test "block bodies" {
    try check(
        \\area = fn w, h ->
        \\    total = w * h
        \\    total / 2
    ,
        \\area = |w, h| {
        \\    total = w * h
        \\    total / 2
        \\}
        \\
    );
}

test "pipes pass the value last" {
    try check(
        \\result =
        \\    input
        \\        |> parse
        \\        |> List.map normalize
        \\        |> summarize
        \\
        \\other =
        \\    input
        \\    |> List.keepIf isGood
        \\
        \\ranges = text |> try List.mapTry parseRange
        \\
        \\line = name |> greet "Hello"
        \\back = greet "Hi" <| name
    ,
        \\result = summarize(List.map(parse(input), normalize))
        \\
        \\other = List.keep_if(input, is_good)
        \\
        \\ranges = List.map_try(text, parse_range)?
        \\
        \\line = greet("Hello", name)
        \\back = greet("Hi", name)
        \\
    );
}

test "case and if" {
    try check(
        \\describe = fn result ->
        \\    case result of
        \\        Ok value -> "ok: ${value}"
        \\        Err _ -> "fout"
        \\
        \\abs = fn n ->
        \\    if n < 0 then -n else n
        \\
        \\sign = fn n ->
        \\    if n < 0 then
        \\        Negative
        \\    else if n == 0 then
        \\        Zero
        \\    else
        \\        Positive
    ,
        \\describe = |result| match result {
        \\    Ok(value) => "ok: ${value}"
        \\    Err(_) => "fout"
        \\}
        \\
        \\abs = |n| if n < 0 {
        \\    -n
        \\} else {
        \\    n
        \\}
        \\
        \\sign = |n| if n < 0 {
        \\    Negative
        \\} else if n == 0 {
        \\    Zero
        \\} else {
        \\    Positive
        \\}
        \\
    );
}

test "case with multi-line arms, alternatives and guards" {
    try check(
        \\classify = fn color ->
        \\    case color of
        \\        Red | Orange -> Warm
        \\        Rgb r g b if r > b ->
        \\            label = "warmish"
        \\            Custom label
        \\        _ -> Cold
    ,
        \\classify = |color| match color {
        \\    Red | Orange => Warm
        \\    Rgb(r, g, b) if r > b => {
        \\        label = "warmish"
        \\        Custom(label)
        \\    }
        \\    _ => Cold
        \\}
        \\
    );
}

test "types: nominal, alias, unions" {
    try check(
        \\type Shape
        \\    = Circle F64
        \\    | Rect F64 F64
        \\
        \\type Maybe a = Just a | Nothing
        \\
        \\type alias Point = { x : F64, y : F64 }
        \\
        \\warm : (Red | Orange) -> Str
        \\isRed : (Red | ..) -> Bool
        \\dropRed : (Red | ..others) -> (Gone | ..others)
        \\parse : Str -> Try U64 (Empty | NotANumber)
        \\first : List a -> Try a (ListWasEmpty)
        \\apply : (a -> b), List a -> List b
        \\run! : List Str => Try {} (Exit I32 | ..)
        \\named : { a | name : Str } -> Str
    ,
        \\Shape := [Circle(F64), Rect(F64, F64)].{
        \\    is_eq = |punk_x, punk_y| match (punk_x, punk_y) {
        \\        (Circle(punk_a1), Circle(punk_b1)) => punk_a1 == punk_b1
        \\        (Rect(punk_a1, punk_a2), Rect(punk_b1, punk_b2)) => punk_a1 == punk_b1 and punk_a2 == punk_b2
        \\        _ => False
        \\    }
        \\
        \\    to_hash = |punk_x, punk_h| match punk_x {
        \\        Circle(punk_a1) => punk_a1.to_hash(Hasher.write_u64(punk_h, 0))
        \\        Rect(punk_a1, punk_a2) => punk_a2.to_hash(punk_a1.to_hash(Hasher.write_u64(punk_h, 1)))
        \\    }
        \\}
        \\
        \\Maybe(a) := [Just(a), Nothing].{
        \\    is_eq = |punk_x, punk_y| match (punk_x, punk_y) {
        \\        (Just(punk_a1), Just(punk_b1)) => punk_a1 == punk_b1
        \\        (Nothing, Nothing) => True
        \\        _ => False
        \\    }
        \\
        \\    to_hash = |punk_x, punk_h| match punk_x {
        \\        Just(punk_a1) => punk_a1.to_hash(Hasher.write_u64(punk_h, 0))
        \\        Nothing => Hasher.write_u64(punk_h, 1)
        \\    }
        \\}
        \\
        \\Point : { x : F64, y : F64 }
        \\
        \\warm : [Red, Orange] -> Str
        \\is_red : [Red, ..] -> Bool
        \\drop_red : [Red, ..others] -> [Gone, ..others]
        \\parse : Str -> Try(U64, [Empty, NotANumber])
        \\first : List(a) -> Try(a, ListWasEmpty)
        \\apply : (a -> b), List(a) -> List(b)
        \\run! : List(Str) => Try({}, [Exit(I32), ..])
        \\named : { name : Str, ..a } -> Str
        \\
    );
}

test "records" {
    try check(
        \\person = { name = "Sam", age = 32, isAdmin = False }
        \\older = { person | age = person.age + 1 }
        \\make = fn name, age -> { name, age }
        \\getName = fn { name } -> name
    ,
        \\person = { name: "Sam", age: 32, is_admin: False }
        \\older = { ..person, age: person.age + 1 }
        \\make = |name, age| { name, age }
        \\get_name = |{ name }| name
        \\
    );
}

test "no var, for, while or return" {
    try checkError("sum = fn xs ->\n    var total = 0\n    total\n", 2, "punkroc has no 'var'");
    try checkError("f = fn xs ->\n    for x in xs\n        x\n", 2, "use 'fold x in xs");
    try checkError("f = fn n ->\n    while n > 0\n        n\n", 2, "punkroc has no 'while'");
    try checkError("f = fn n ->\n    return n\n", 2, "punkroc has no 'return'");
}

test "fold: inline, and without the list in a pipe" {
    try check(
        \\som = fn xs ->
        \\    fold xs into 0 with fn x, total -> total + x
        \\
        \\run = fn instrs ->
        \\    instrs
        \\        |> fold into { on = True, total = 0 } with step
        \\        |> .total
        \\
        \\pairs = fold List.indexed xs into 0
        \\    with add
    ,
        \\som = |xs| List.fold(xs, 0, |total, x| total + x)
        \\
        \\run = |instrs| (|punk_record| punk_record.total)(List.fold(instrs, { on: True, total: 0 }, |punk_s1, punk_s2| step(punk_s2, punk_s1)))
        \\
        \\pairs = List.fold(List.indexed(xs), 0, |punk_s3, punk_s4| add(punk_s4, punk_s3))
        \\
    );
}

test "fold: block form with one and with more accumulators" {
    try check(
        \\som = fn xs ->
        \\    fold x in xs into total = 0
        \\        total + x
        \\
        \\maxIndex = fn xs ->
        \\    fold (i, x) in List.indexed xs into bestI = 0, bestX = 0
        \\        if x > bestX then { bestI = i, bestX = x } else {}
        \\
        \\run = fn instrs ->
        \\    result =
        \\        fold instr in instrs into on = True, total = 0
        \\            case instr of
        \\                Do -> { on = True }
        \\                Dont -> { on = False }
        \\                Mul a b -> if on then { total = total + a * b } else {}
        \\    result.total
    ,
        \\som = |xs| List.fold(xs, 0, |total, x| total + x)
        \\
        \\max_index = |xs| List.fold(List.indexed(xs), { best_i: 0, best_x: 0 }, |punk_fold1, (i, x)| {
        \\    { best_x, .. } = punk_fold1
        \\    if x > best_x {
        \\        { ..punk_fold1, best_i: i, best_x: x }
        \\    } else {
        \\        punk_fold1
        \\    }
        \\})
        \\
        \\run = |instrs| {
        \\    result = List.fold(instrs, { on: True, total: 0 }, |punk_fold2, instr| {
        \\        { on, total } = punk_fold2
        \\        match instr {
        \\            Do => { ..punk_fold2, on: True }
        \\            Dont => { ..punk_fold2, on: False }
        \\            Mul(a, b) => if on {
        \\                { ..punk_fold2, total: total + a * b }
        \\            } else {
        \\                punk_fold2
        \\            }
        \\        }
        \\    })
        \\    result.total
        \\}
        \\
    );
}

test "fold: errors" {
    try checkError("s = fold xs 0 with f\n", 1, "expected 'into'");
    try checkError("s = fold xs into 0 f\n", 2, "expected 'with'");
    try checkError("s =\n    fold x in xs into a = 0, b = 0\n        { c = 1 }\n", 2, "'c' is not an accumulator");
    try checkError("s =\n    fold x in xs into a = 0, a = 1\n        a\n", 2, "named twice");
    try checkError("s =\n    fold x in xs into a = 0\ny = 1\n", 3, "indented further");
}

test "comments, headers, effects, try" {
    try check(
        \\app [main!] { pf: platform "../platform/main.roc" }
        \\
        \\import pf.Stdout
        \\
        \\{-| Says hello.
        \\-}
        \\main! = fn args ->
        \\    -- greet everyone
        \\    name = try List.first args
        \\    Stdout.line! "Hello, ${name}!"
        \\    Ok {}
    ,
        \\app [main!] { pf: platform "../platform/main.roc" }
        \\
        \\import pf.Stdout
        \\
        \\## Says hello.
        \\main! = |args| {
        \\    # greet everyone
        \\    name = List.first(args)?
        \\    Stdout.line!("Hello, ${name}!")
        \\    Ok({})
        \\}
        \\
    );
}

test "try binds to the whole call" {
    try check(
        \\f = fn a ->
        \\    x = try U64.fromStr a
        \\    Ok x
    ,
        \\f = |a| {
        \\    x = U64.from_str(a)?
        \\    Ok(x)
        \\}
        \\
    );
}

test "try inside tuples, operators and pipelines" {
    try check(
        \\pair = fn a, b -> Ok (try parse a, try parse b)
        \\
        \\product = fn x, y -> Ok (try number x * try number y)
        \\
        \\ranges = fn input ->
        \\    input
        \\        |> Str.trim
        \\        |> Str.splitOn ","
        \\        |> try List.mapTry parseRange
        \\        |> List.len
        \\        |> Ok
        \\
        \\whole = fn s -> try (s |> Str.trim |> parse)
    ,
        \\pair = |a, b| Ok((parse(a)?, parse(b)?))
        \\
        \\product = |x, y| Ok(number(x)? * number(y)?)
        \\
        \\ranges = |input| Ok(List.len(List.map_try(Str.split_on(Str.trim(input), ","), parse_range)?))
        \\
        \\whole = |s| parse(Str.trim(s))?
        \\
    );
}

test "a postfix ? points to try" {
    try checkError("f = fn a ->\n    x = U64.fromStr a?\n    Ok x\n", 2, "'try f x' instead of 'f x?'");
    try checkError("f = fn a -> g try a\n", 1, "unexpected");
}

test "operators" {
    try check(
        \\a = (x + y) * z
        \\b = x + y * z
        \\c = ok && not done || x /= y
        \\d = first ++ second
        \\e = f -1
        \\g = x - 1
        \\h = 1..=(n // 2) |> Iter.keepIf (fn d -> n % d == 0) |> List.fromIter
    ,
        \\a = (x + y) * z
        \\b = x + y * z
        \\c = ok and !done or x != y
        \\d = first.concat(second)
        \\e = f(-1)
        \\g = x - 1
        \\h = List.from_iter(Iter.keep_if(1..=(n // 2), |d| n % d == 0))
        \\
    );
}

test "lambda body block inside an argument" {
    try check(
        \\out = xs |> List.map (fn x ->
        \\        y = x * 2
        \\        y + 1)
    ,
        \\out = List.map(xs, |x| {
        \\    y = x * 2
        \\    y + 1
        \\})
        \\
    );
}

test "errors" {
    try checkError("x = 1\n  y = 2\n", 2, "unexpected");
    try checkError("f = fn x ->\n    case x of A -> 1\n", 2, "own lines");
    try checkError("r = { a: 1 }\n", 1, "use '='");
    try checkError("x =\n\tfoo\n", 2, "tabs");
}

test "module header becomes a type module" {
    try check(
        \\module Math exposing (double)
        \\
        \\import Helper
        \\
        \\{-| Twice the number. -}
        \\double : I64 -> I64
        \\double = fn x ->
        \\    x * 2
        \\
        \\sumAll = fn xs -> List.sum xs
    ,
        \\import Helper
        \\
        \\Math := [].{
        \\    ## Twice the number.
        \\    double : I64 -> I64
        \\    double = |x| x * 2
        \\
        \\    sum_all = |xs| List.sum(xs)
        \\}
        \\
    );
}

test "module whose type has the module's name" {
    try check(
        \\module Shape exposing (Shape(..), area)
        \\
        \\type Shape
        \\    = Circle F64
        \\    | Rect F64 F64
        \\
        \\area = fn shape ->
        \\    case shape of
        \\        Circle r -> 3.0 * r * r
        \\        Rect w h -> w * h
    ,
        \\Shape := [Circle(F64), Rect(F64, F64)].{
        \\    is_eq = |punk_x, punk_y| match (punk_x, punk_y) {
        \\        (Circle(punk_a1), Circle(punk_b1)) => punk_a1 == punk_b1
        \\        (Rect(punk_a1, punk_a2), Rect(punk_b1, punk_b2)) => punk_a1 == punk_b1 and punk_a2 == punk_b2
        \\        _ => False
        \\    }
        \\
        \\    to_hash = |punk_x, punk_h| match punk_x {
        \\        Circle(punk_a1) => punk_a1.to_hash(Hasher.write_u64(punk_h, 0))
        \\        Rect(punk_a1, punk_a2) => punk_a2.to_hash(punk_a1.to_hash(Hasher.write_u64(punk_h, 1)))
        \\    }
        \\
        \\    area = |shape| match shape {
        \\        Circle(r) => 3.0 * r * r
        \\        Rect(w, h) => w * h
        \\    }
        \\}
        \\
    );
}

test "builtins take the value they work on last" {
    try check(
        \\a = List.map double xs
        \\b = Str.splitOn "," text
        \\c = Str.joinWith ", " names
        \\d = List.fold (fn x, acc -> acc + x) 0 xs
        \\e = List.map2 (fn x, y -> x + y) xs ys
        \\f = Result.withDefault 0 (U64.fromStr s)
        \\g = Result.map double r
        \\h = Dict.insert key value dict
        \\i = U64.pow 10 digits
    ,
        \\a = List.map(xs, double)
        \\b = Str.split_on(text, ",")
        \\c = Str.join_with(names, ", ")
        \\d = List.fold(xs, 0, |acc, x| acc + x)
        \\e = List.map2(xs, ys, |x, y| x + y)
        \\f = Try.ok_or(U64.from_str(s), 0)
        \\g = Try.map_ok(r, double)
        \\h = Dict.insert(dict, key, value)
        \\i = U64.pow(10, digits)
        \\
    );
}

test "currying: partial application of known functions" {
    try check(
        \\add : I64 -> I64 -> I64
        \\add = fn a, b ->
        \\    a + b
        \\
        \\inc = add 1
        \\incAll = List.map (add 1)
        \\three = inc 2
        \\six = List.map (add 1) [1, 2] |> List.sum
        \\mapper = List.map
        \\later = add (expensive 5)
    ,
        \\add : I64, I64 -> I64
        \\add = |a, b| a + b
        \\
        \\inc = |punk_a1| add(1, punk_a1)
        \\inc_all = |punk_a2| List.map(punk_a2, |punk_a3| add(1, punk_a3))
        \\three = inc(2)
        \\six = List.sum(List.map([1, 2], |punk_a4| add(1, punk_a4)))
        \\mapper = |punk_a5, punk_a6| List.map(punk_a6, punk_a5)
        \\later = {
        \\    punk_v7 = expensive(5)
        \\    |punk_a8| add(punk_v7, punk_a8)
        \\}
        \\
    );
}

test "currying: nested lambdas, extra arguments, shadowing" {
    try check(
        \\add = fn a -> fn b -> a + b
        \\
        \\pick = fn flag ->
        \\    if flag then add else fn a, b -> a - b
        \\
        \\x = pick True 1 2
        \\
        \\apply = fn add, y ->
        \\    add y
        \\
        \\local = fn n ->
        \\    times = fn a, b -> a * b
        \\    double = times 2
        \\    double n
    ,
        \\add = |a, b| a + b
        \\
        \\pick = |flag| if flag {
        \\    add
        \\} else {
        \\    |a, b| a - b
        \\}
        \\
        \\x = pick(True)(1, 2)
        \\
        \\apply = |add, y| add(y)
        \\
        \\local = |n| {
        \\    times = |a, b| a * b
        \\    double = |punk_a1| times(2, punk_a1)
        \\    double(n)
        \\}
        \\
    );
}

test "curried function types" {
    try check(
        \\f : I64 -> I64 -> I64
        \\g : (a -> b -> c) -> List a -> List b -> List c
        \\h : Str -> (Str -> Str)
        \\r : Result I64 Str
        \\run! : () => Result {} Str
    ,
        \\f : I64, I64 -> I64
        \\g : (a, b -> c), List(a), List(b) -> List(c)
        \\h : Str, Str -> Str
        \\r : Try(I64, Str)
        \\run! : () => Try({}, Str)
        \\
    );
}

test "currying: a definition gets the arity of its annotation" {
    try check(
        \\pick : Bool -> I64 -> I64 -> I64
        \\pick = fn useAdd ->
        \\    if useAdd then add else mul
        \\
        \\x = pick True 3 4
    ,
        \\pick : Bool, I64, I64 -> I64
        \\pick = |use_add, punk_a1, punk_a2| (if use_add {
        \\    add
        \\} else {
        \\    mul
        \\})(punk_a1, punk_a2)
        \\
        \\x = pick(True, 3, 4)
        \\
    );
}

// Step 4: modules

const mod = @import("mod.zig");
const interface = @import("interface.zig");

/// A file system in memory, for the translator's reader.
const Files = struct {
    entries: []const [2][]const u8,

    fn read(ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]u8 {
        const fs: *const Files = @ptrCast(@alignCast(ctx.?));
        for (fs.entries) |entry| {
            if (samePath(entry[0], path)) return a.dupe(u8, entry[1]) catch null;
        }
        return null;
    }

    /// Paths are joined with `\\` on Windows; the entries use `/`.
    fn samePath(entry: []const u8, path: []const u8) bool {
        if (entry.len != path.len) return false;
        for (entry, path) |e, p| {
            const same = e == p or (e == '/' and std.fs.path.isSep(p));
            if (!same) return false;
        }
        return true;
    }
};

const files = Files{ .entries = &.{
    .{
        "app/Grid.punk",
        \\module Grid exposing (Grid, size)
        \\
        \\type alias Grid = List (List U8)
        \\
        \\size : Grid -> U64
        \\size = fn g -> List.len g
    },
    .{
        "app/Math.punk",
        \\module Math exposing (add, double, Shape(..), Color)
        \\
        \\add : I64 -> I64 -> I64
        \\add = fn a, b -> a + b
        \\
        \\double = fn x -> x * 2
        \\
        \\secret = fn x -> x
        \\
        \\type Shape = Circle F64 | Square F64
        \\
        \\type Color = Red | Green
    },
    .{
        "app/Text.roc",
        \\Text := [].{
        \\    ## Repeat a string.
        \\    repeat : Str, U64 -> Str
        \\    repeat = |s, n| s
        \\
        \\    pad_left = |s, n, c| s
        \\
        \\    shout : Str -> Str
        \\    shout = |s|
        \\        x : Str
        \\        x = s
        \\        x
        \\
        \\    greeting : Str
        \\    greeting = "hi"
        \\}
    },
    .{
        "cache/AbC123/Wrap.roc",
        \\Wrap := [].{
        \\    surround : Str, Str, Str -> Str
        \\    surround = |s, l, r| s
        \\}
    },
    .{
        "app/../pf/Stdout.roc",
        \\Stdout := [].{
        \\    line! : Str => {}
        \\    write_both! : Str, Str => {}
        \\}
    },
} };

fn checkWith(src: []const u8, expected: []const u8) (punk.Error || error{TestExpectedEqual})!void {
    const reader = mod.Reader{ .ctx = @ptrCast(@constCast(&files)), .read = Files.read };
    const out = try mod.toRocWith(std.testing.allocator, "app/main.punk", src, reader);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn checkWithError(src: []const u8, line: u32, msg_part: []const u8) error{ TestExpectedEqual, TestUnexpectedResult }!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const resolver = punk.Resolver{ .ctx = @ptrCast(@constCast(&files)), .load = testLoad };
    if (punk.translateWith(arena.allocator(), src, &diag, resolver)) |out| {
        std.debug.print("expected an error, got:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(line, diag.line);
    if (std.mem.find(u8, diag.message, msg_part) == null) {
        std.debug.print("message was: {s}\n", .{diag.message});
        return error.TestUnexpectedResult;
    }
}

/// The resolver mod.zig builds, for a file in `app/`.
fn testLoad(ctx: ?*anyopaque, a: std.mem.Allocator, imp: punk.Import) punk.Error!?*const punk.Interface {
    return mod.loadFrom(.{ .ctx = ctx, .read = Files.read }, "app", a, imp);
}

test "modules: arity of functions from imported punkroc modules" {
    try checkWith(
        \\import Math
        \\
        \\inc = Math.add 1
        \\all = List.map (Math.add 10) [1, 2]
        \\d = Math.double 4
    ,
        \\import Math
        \\
        \\inc = |punk_a1| Math.add(1, punk_a1)
        \\all = List.map([1, 2], |punk_a2| Math.add(10, punk_a2))
        \\d = Math.double(4)
        \\
    );
}

test "modules: Roc modules take their arguments in Roc's order" {
    try checkWith(
        \\app [main!] { pf: platform "../pf/main.roc" }
        \\
        \\import pf.Stdout
        \\import Text
        \\
        \\three = Text.repeat 3 "ab"
        \\threeTimes = Text.repeat 3
        \\padded = "x" |> Text.padLeft 5 " "
        \\loud = Text.shout "hey"
        \\main! = fn () ->
        \\    Stdout.writeBoth! "a" "b"
        \\    "hi" |> Stdout.line!
    ,
        \\app [main!] { pf: platform "../pf/main.roc" }
        \\
        \\import pf.Stdout
        \\import Text
        \\
        \\three = Text.repeat("ab", 3)
        \\three_times = |punk_a1| Text.repeat(punk_a1, 3)
        \\padded = Text.pad_left("x", 5, " ")
        \\loud = Text.shout("hey")
        \\main! = || {
        \\    Stdout.write_both!("b", "a")
        \\    Stdout.line!("hi")
        \\}
        \\
    );
}

/// Where the test's URL packages are; the compiler downloads them.
fn testPackageDir(_: ?*anyopaque, _: std.mem.Allocator, url: []const u8) ?[]const u8 {
    return if (std.mem.endsWith(u8, url, "/AbC123.tar.zst")) "cache/AbC123" else null;
}

test "modules: modules of URL packages are read where the package is" {
    const src =
        \\app [main!] { pf: platform "../pf/main.roc", w: "https://example.com/AbC123.tar.zst" }
        \\
        \\import w.Wrap
        \\
        \\quoted = "hi" |> Wrap.surround "<" ">"
        \\wrap = Wrap.surround "(" ")"
        \\
    ;
    const reader = mod.Reader{ .ctx = @ptrCast(@constCast(&files)), .read = Files.read, .packageDir = testPackageDir };
    const out = try mod.toRocWith(std.testing.allocator, "app/main.punk", src, reader);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\app [main!] { pf: platform "../pf/main.roc", w: "https://example.com/AbC123.tar.zst" }
        \\
        \\import w.Wrap
        \\
        \\quoted = Wrap.surround("hi", "<", ">")
        \\wrap = |punk_a1| Wrap.surround(punk_a1, "(", ")")
        \\
    , out);
    // Without a way to find the package, its functions keep Roc's order.
    try checkWith(src,
        \\app [main!] { pf: platform "../pf/main.roc", w: "https://example.com/AbC123.tar.zst" }
        \\
        \\import w.Wrap
        \\
        \\quoted = Wrap.surround("<", ">", "hi")
        \\wrap = Wrap.surround("(", ")")
        \\
    );
}

test "syntax errors are kept for the compiler to report" {
    try std.testing.expectError(error.ParseError, mod.toRoc(std.testing.allocator, "bad.punk", "x = (1 +\n"));
    const msg = (try mod.syntaxError(std.testing.allocator, "bad.punk")).?;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.startsWith(u8, msg, "bad.punk:2:1: "));
    const out = try mod.toRoc(std.testing.allocator, "bad.punk", "x = 1\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(null, try mod.syntaxError(std.testing.allocator, "bad.punk"));
}

test "modules: names an import exposes unqualified" {
    try checkWith(
        \\import Math exposing [add]
        \\import Text exposing [repeat]
        \\
        \\inc = add 1
        \\r = repeat 2 "x"
    ,
        \\import Math exposing [add]
        \\import Text exposing [repeat]
        \\
        \\inc = |punk_a1| add(1, punk_a1)
        \\r = repeat("x", 2)
        \\
    );
}

test "modules: the exposing list is checked" {
    try checkWithError("import Math\n\nx = Math.secret 1\n", 3, "Math does not expose secret");
    try checkWithError("import Math\n\nx = Math.nothing 1\n", 3, "Math has no nothing");
    try checkWithError("import Math\n\nx = Math.Red\n", 3, "does not expose the tags of Color");
    try checkWithError("import Math exposing [secret]\n\nx = 1\n", 1, "Math does not expose secret");
    try checkWithError("module M exposing (foo)\n\nbar = 1\n", 1, "does not define it");
    try checkWithError("module M exposing (Foo(..))\n\nbar = 1\n", 1, "does not define it");
    // Exposed tags and Roc modules are fine.
    try checkWith("import Math\n\nx = Math.Circle 1.0\n", "import Math\n\nx = Math.Circle(1.0)\n");
    try checkWith("import Text\n\nx = Text.whatever 1\n", "import Text\n\nx = Text.whatever(1)\n");
}

test "modules: scanning a Roc module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const iface = try interface.scanRoc(arena.allocator(), files.entries[2][1]);
    try std.testing.expectEqual(@as(?u8, 2), iface.values.get("repeat").?);
    try std.testing.expectEqual(@as(?u8, 3), iface.values.get("pad_left").?);
    try std.testing.expectEqual(@as(?u8, 1), iface.values.get("shout").?);
    try std.testing.expectEqual(@as(?u8, null), iface.values.get("greeting").?);
    try std.testing.expect(!iface.values.contains("x"));
    try std.testing.expectEqual(@as(?u8, 2), interface.typeArity(" List(a), (a -> b) -> List(b)"));
    try std.testing.expectEqual(@as(?u8, 0), interface.typeArity(" () => {}"));
    try std.testing.expectEqual(@as(?u8, 1), interface.typeArity(" a -> Str where a.to_str : a -> Str"));
    try std.testing.expectEqual(@as(?u8, null), interface.typeArity(" { a : I64 -> I64 }"));
    try std.testing.expectEqual(@as(?u8, 0), interface.lambdaArity("|| 1"));
    try std.testing.expectEqual(@as(?u8, 2), interface.lambdaArity("|{ a, b }, c| a"));
}

test "accessor functions" {
    try check("xs = List.map .name people\n", "xs = List.map(people, |punk_record| punk_record.name)\n");
    try check("x = (.0) pair\n", "x = (|punk_record| punk_record.0)(pair)\n");
    try check("x = person.name\n", "x = person.name\n");
}

test "import exposing with parentheses" {
    try check("import Grid exposing (Cells, atPoint, Shape(..))\n\nx = 1\n", "import Grid exposing [Cells, at_point, Shape]\n\nx = 1\n");
}

test "empty sets and dicts are values" {
    try check("s = Set.empty |> Set.insert 1\n", "s = Set.insert(Set.empty(), 1)\n");
    try check("d = Dict.empty\n", "d = Dict.empty()\n");
}

test "multi-line strings" {
    // Indented between lines of their own: the indentation and the outer line breaks go.
    try check("example =\n    \"\"\"\n    3   4\n      \"x\" ${name}\n    \"\"\"\n\ny = 1\n", "example = \"3   4\\n  \\\"x\\\" ${name}\"\n\ny = 1\n");
    // Otherwise the text is kept as it is.
    try check("x = \"\"\"a\nb\"\"\"\ny = 2\n", "x = \"a\\nb\"\ny = 2\n");
    try checkError("x = \"\"\"a\n", 1, "unterminated multi-line string");
    // Line numbers after the string still count its lines.
    try checkError("x = \"\"\"a\nb\nc\"\"\"\ny = )\n", 4, "expected an expression");
}

test "folds take the state last, as Elm's foldl" {
    try check("d = List.fold (fn x, acc -> acc - x) 0 xs\n", "d = List.fold(xs, 0, |acc, x| acc - x)\n");
    try check("d = Dict.fold (fn k, v, acc -> acc + k * v) 0 dict\n", "d = Dict.fold(dict, 0, |acc, k, v| acc + k * v)\n");
    // A named function is wrapped; a builtin inside keeps punkroc's order.
    try check("s = List.fold Set.insert Set.empty xs\n", "s = List.fold(xs, Set.empty(), |punk_s1, punk_s2| Set.insert(punk_s1, punk_s2))\n");
    // fold_rev already takes the item first.
    try check("d = List.foldRev (fn x, acc -> acc - x) 0 xs\n", "d = List.fold_rev(xs, 0, |x, acc| acc - x)\n");
}

test "a type alias with the name of its module" {
    // In the module: Roc's `Grid` is the module itself, so the alias is `GridAlias`.
    try check(
        \\module Grid exposing (Grid, size)
        \\
        \\type alias Grid = List (List U8)
        \\
        \\size : Grid -> U64
        \\size = fn g -> List.len g
        \\
    ,
        \\Grid := [].{
        \\    GridAlias : List(List(U8))
        \\
        \\    size : GridAlias -> U64
        \\    size = |g| List.len(g)
        \\}
        \\
    );
    // From another module, exposed or qualified.
    try checkWith("import Grid exposing (Grid, size)\n\nf : Grid -> Grid.Grid -> U64\nf = fn a, b -> size a\n", "import Grid exposing [size]\n\nf : Grid.GridAlias, Grid.GridAlias -> U64\nf = |a, b| size(a)\n");
    try checkWith("import Grid exposing (Grid)\n\nf : Grid -> U64\nf = fn a -> Grid.size a\n", "import Grid\n\nf : Grid.GridAlias -> U64\nf = |a| Grid.size(a)\n");
}
