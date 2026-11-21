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

/// Translates without an error, whatever the output.
fn translateOk(src: []const u8) punk.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    _ = punk.translate(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message });
        return err;
    };
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
        \\h = List.from_iter(Iter.keep_if(1..=punk_int_div(n, 2), |d| punk_int_rem(n, d) == 0))
        \\
        \\punk_int_div = |a, b| if b == 0 { 0 } else { a // b }
        \\
        \\punk_int_rem = |a, b| if b == 0 { 0 } else { a % b }
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
        \\area : Shape -> F64
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
        \\    area : Shape -> F64
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

test "error positions map back to the .punk source" {
    const src =
        \\main = fn x ->
        \\    x
        \\        |> List.keepIf isGood
        \\        |> List.map toWord
    ;
    const out = try mod.toRoc(std.testing.allocator, "map.punk", src);
    defer std.testing.allocator.free(out);
    // main = |x| List.map(List.keep_if(x, is_good), to_word)
    const line2 = out[0 .. std.mem.findScalar(u8, out, '\n') orelse out.len];
    const col = std.mem.find(u8, line2, "is_good").? + 1;
    // `is_good` in the translation is `isGood` on line 3 of the source.
    const r = (try mod.remap(std.testing.allocator, "map.punk", .{ .line = 1, .column = @intCast(col) }, .{ .line = 1, .column = @intCast(col + "is_good".len) })).?;
    defer std.testing.allocator.free(r.lines);
    try std.testing.expectEqual(@as(u32, 3), r.start.line);
    try std.testing.expectEqual(@as(u32, 24), r.start.column);
    try std.testing.expectEqual(@as(u32, 30), r.end.column);
    try std.testing.expectEqualStrings("        |> List.keepIf isGood", r.lines);
    // The whole call covers the pipeline it came from.
    const start = std.mem.find(u8, line2, "List.map").? + 1;
    const call = (try mod.remap(std.testing.allocator, "map.punk", .{ .line = 1, .column = @intCast(start) }, .{ .line = 1, .column = @intCast(line2.len + 1) })).?;
    defer std.testing.allocator.free(call.lines);
    try std.testing.expectEqual(@as(u32, 2), call.start.line);
    try std.testing.expectEqual(@as(u32, 4), call.end.line);
}

test "error messages use punkroc's names" {
    const a = std.testing.allocator;
    const c = (try mod.camelText(a, "Nothing is named not_defined, try List.keep_if")).?;
    defer a.free(c);
    try std.testing.expectEqualStrings("Nothing is named notDefined, try List.keepIf", c);
    try std.testing.expectEqual(null, try mod.camelText(a, "prefix it like _unused_name"));
    try std.testing.expectEqual(null, try mod.camelText(a, "in examples/punk/aoc_day2.punk"));
}

test "Elm names: renames, helpers and types" {
    try check(
        \\big : List Int -> Maybe Int
        \\big = fn xs ->
        \\    xs
        \\        |> List.filter (fn n -> n > 2)
        \\        |> List.head
        \\
        \\firsts = fn ps ->
        \\    List.map Tuple.first ps
        \\
        \\second = fn p ->
        \\    Tuple.second p
    ,
        \\big : List(I64) -> [Just(I64), Nothing]
        \\big = |xs| punk_list_head(List.keep_if(xs, |n| n > 2))
        \\
        \\firsts = |ps| List.map(ps, (|punk_t0| punk_t0.0))
        \\
        \\second = |p| p.1
        \\
        \\punk_list_head = |xs| match List.first(xs) { Ok(x) => Just(x), Err(_) => Nothing }
        \\
    );
}

test "Elm names: the file's own definitions win" {
    try check(
        \\type Order = Up | Down
        \\
        \\compare = fn a, b ->
        \\    Up
        \\
        \\x : Order
        \\x = compare 1 2
    ,
        \\Order := [Up, Down].{
        \\    is_eq = |punk_x, punk_y| match (punk_x, punk_y) {
        \\        (Up, Up) => True
        \\        (Down, Down) => True
        \\        _ => False
        \\    }
        \\
        \\    to_hash = |punk_x, punk_h| match punk_x {
        \\        Up => Hasher.write_u64(punk_h, 0)
        \\        Down => Hasher.write_u64(punk_h, 1)
        \\    }
        \\}
        \\
        \\compare = |a, b| Up
        \\
        \\x : Order
        \\x = compare(1, 2)
        \\
    );
}

fn checkRule(src: []const u8, line: u32, col: u32, rule: punk.Rule) error{ TestExpectedEqual, TestUnexpectedResult }!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    if (punk.translate(arena.allocator(), src, &diag)) |out| {
        std.debug.print("expected an error, got:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(line, diag.line);
    try std.testing.expectEqual(col, diag.col);
    try std.testing.expectEqualStrings(rule.code(), diag.code);
    if (!std.mem.startsWith(u8, diag.message, rule.code())) {
        std.debug.print("message was: {s}\n", .{diag.message});
        return error.TestUnexpectedResult;
    }
}

test "rules: crash and dbg only inside tests" {
    try checkRule("f = fn x ->\n    crash \"no\"\n", 2, 5, .crash_outside_test);
    try checkRule("f = fn x ->\n    y = dbg x\n    y\n", 2, 9, .dbg_outside_test);
    try checkRule("f = fn x ->\n    case x of\n        Ok v -> v\n        Err _ -> crash \"no\"\n", 4, 18, .crash_outside_test);
    try checkError("f = fn x -> dbg x\n", 1, "'dbg' is only allowed inside an 'expect' test");
    // Inside an `expect`, at the top level or in a body, they are fine.
    try check("expect\n    dbg (1 + 1) == 2\n", "expect dbg (1 + 1) == 2\n");
    try check(
        \\f = fn x ->
        \\    expect x == dbg x
        \\    x
    ,
        \\f = |x| {
        \\    expect x == (dbg x)
        \\    x
        \\}
        \\
    );
}

test "rules: the SQL of Sql.query is text in the program" {
    const head = "app [main!] { pf: platform \"p.roc\" }\n\nimport pf.Sql\n\n";
    // Text in the program, also through a pipe, `as`, or `exposing`: fine.
    try translateOk(head ++ "q = fn id -> Sql.query \"SELECT url FROM links WHERE id = $1\" [ Sql.text id ]\n");
    try translateOk(head ++ "q = fn id -> [ Sql.text id ] |> Sql.query \"SELECT 1\"\n");
    try translateOk("app [main!] { pf: platform \"p.roc\" }\n\nimport pf.Sql as Db\n\nq = Db.query (\"SELECT 1\") []\n");
    // Text made while the program runs: P301.
    try checkRule(head ++ "q = fn t -> Sql.query \"SELECT * FROM ${t}\" []\n", 5, 23, .sql_not_literal);
    try checkRule(head ++ "q = fn sql -> Sql.query sql []\n", 5, 15, .sql_not_literal);
    try checkRule(head ++ "q = fn t -> Sql.query (\"SELECT \" ++ t) []\n", 5, 13, .sql_not_literal);
    try checkRule(head ++ "qs = List.map (fn s -> s) [] |> List.map Sql.query\n", 5, 42, .sql_not_literal);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\nimport pf.Sql as Db\n\nq = fn s -> Db.query s []\n", 5, 13, .sql_not_literal);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\nimport pf.Sql exposing [query]\n\nq = fn s -> query s []\n", 5, 13, .sql_not_literal);
    // A module of the app's own called Sql is not the platform's.
    try translateOk("app [main!] { pf: platform \"p.roc\" }\n\nimport Sql\n\nq = fn s -> Sql.query s []\n");
}

test "rules: what a module exposes has a type annotation" {
    try checkRule("module M exposing (double)\n\ndouble = fn x -> x * 2\n", 3, 1, .exposed_without_annotation);
    try checkError("module M exposing (..)\n\nf : I64 -> I64\nf = fn x -> x\n\ng = fn x -> x\n", 6, "'g' is exposed, so it needs a type annotation");
    // Not exposed, or in an app: no annotation needed.
    try check("module M exposing (f)\n\nf : I64 -> I64\nf = fn x -> helper x\n\nhelper = fn x -> x\n",
        \\M := [].{
        \\    f : I64 -> I64
        \\    f = |x| helper(x)
        \\
        \\    helper = |x| x
        \\}
        \\
    );
    try check("double = fn x -> x * 2\n", "double = |x| x * 2\n");
}

test "numbers: dividing by zero gives 0, as in Elm" {
    try check("a = x // y\n",
        \\a = punk_int_div(x, y)
        \\
        \\punk_int_div = |a, b| if b == 0 { 0 } else { a // b }
        \\
    );
    try check("a = (x + 1) % 2 == 0\n",
        \\a = punk_int_rem(x + 1, 2) == 0
        \\
        \\punk_int_rem = |a, b| if b == 0 { 0 } else { a % b }
        \\
    );
    try check("a = modBy 3 x\nb = List.map (remainderBy 2) xs\n",
        \\a = punk_mod_by(3, x)
        \\b = List.map(xs, |punk_a1| punk_remainder_by(2, punk_a1))
        \\
        \\punk_mod_by = |n, x| if n == 0 { 0 } else { if x % n != 0 and (x % n < 0) != (n < 0) { x % n + n } else { x % n } }
        \\
        \\punk_remainder_by = |n, x| if n == 0 { 0 } else { x % n }
        \\
    );
}

// punk fmt (format.zig)

const format = @import("format.zig");

fn checkFormat(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const out = format.format(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message });
        return err;
    };
    try std.testing.expectEqualStrings(expected, out);
    // Formatting is idempotent.
    const again = try format.format(arena.allocator(), out, &diag);
    try std.testing.expectEqualStrings(out, again);
}

test "fmt: indentation, spaces and blank lines" {
    try checkFormat(
        \\app [main!] { pf: platform "../platform/main.roc" }
        \\import pf.Stdout
        \\import pf.Stdin
        \\
        \\
        \\
        \\-- Sum of things
        \\total : List I64 -> I64
        \\
        \\total = fn xs ->
        \\  fold x in xs into acc = 0
        \\      acc+x    -- add it
        \\main! = fn () ->
        \\      xs = [1,2 , 3]
        \\      r = {a=1,b= -2}
        \\      ys = xs |> List.map (fn x->x*2)   |>   List.keepIf (fn x -> x>2)
        \\      names = List.map .a [r]
        \\      case List.first ys of
        \\          Ok v ->   Stdout.line! "${I64.toStr (v + total xs + r.b)}"
        \\          Err _ -> Stdout.line! "none"   
    ,
        \\app [main!] { pf: platform "../platform/main.roc" }
        \\
        \\import pf.Stdout
        \\import pf.Stdin
        \\
        \\-- Sum of things
        \\total : List I64 -> I64
        \\total = fn xs ->
        \\    fold x in xs into acc = 0
        \\        acc + x -- add it
        \\
        \\main! = fn () ->
        \\    xs = [1, 2, 3]
        \\    r = { a = 1, b = -2 }
        \\    ys = xs |> List.map (fn x -> x * 2) |> List.keepIf (fn x -> x > 2)
        \\    names = List.map .a [r]
        \\    case List.first ys of
        \\        Ok v -> Stdout.line! "${I64.toStr (v + total xs + r.b)}"
        \\        Err _ -> Stdout.line! "none"
        \\
    );
}

test "fmt: types, tuples, leading commas, multi-line strings" {
    try checkFormat(
        \\module Shapes exposing (Shape(..), area, lst, neg)
        \\
        \\type Shape = Circle F64|Rect F64 F64
        \\
        \\{-| The area. -}
        \\area : Shape -> F64
        \\area = fn shape ->
        \\   case shape of
        \\      Circle r ->
        \\         3.14 * r * r
        \\      Rect w h -> w*h
        \\
        \\lst : List I64
        \\lst =
        \\    [ 1
        \\    ,2
        \\    , -3
        \\    ]
        \\
        \\neg : ( I64, I64 ) -> I64
        \\neg = fn ( x, y ) -> -x
        \\
        \\example : Str
        \\example =
        \\  """
        \\  ab
        \\    cd
        \\  """
    ,
        \\module Shapes exposing (Shape(..), area, lst, neg)
        \\
        \\type Shape = Circle F64 | Rect F64 F64
        \\
        \\{-| The area. -}
        \\area : Shape -> F64
        \\area = fn shape ->
        \\    case shape of
        \\        Circle r ->
        \\            3.14 * r * r
        \\        Rect w h -> w * h
        \\
        \\lst : List I64
        \\lst =
        \\    [ 1
        \\    , 2
        \\    , -3
        \\    ]
        \\
        \\neg : (I64, I64) -> I64
        \\neg = fn (x, y) -> -x
        \\
        \\example : Str
        \\example =
        \\    """
        \\    ab
        \\      cd
        \\    """
        \\
    );
}

test "fmt: a syntax error leaves the file alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    try std.testing.expectError(error.ParseError, format.format(arena.allocator(), "x = (1 +\n", &diag));
}

test "fmt: same-ignoring-space" {
    try std.testing.expect(format.sameIgnoringSpace("a  b\n c", "a b c"));
    try std.testing.expect(!format.sameIgnoringSpace("ab", "a b"));
    try std.testing.expect(!format.sameIgnoringSpace("a", "a b"));
}

const query_head =
    \\app [main!] { pf: platform "p.roc" }
    \\
    \\import pf.Db
    \\
    \\type alias Link =
    \\    { id : Str
    \\    , url : Str
    \\    , created : Int
    \\    , note : Maybe Str
    \\    }
    \\
    \\table links : Link
    \\    key id
    \\    read everyone
    \\    insert everyone
    \\    update everyone
    \\    delete nobody
    \\
    \\
;

/// The Roc a query on `query_head`'s table translates to (the line of the
/// definition `q`), without the head.
fn checkQuery(comptime src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const out = punk.translate(arena.allocator(), query_head ++ src, &diag) catch |err| {
        std.debug.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message });
        return err;
    };
    const start = std.mem.find(u8, out, "# table links : Link\n\n").? + "# table links : Link\n\n".len;
    try std.testing.expectEqualStrings(expected, out[start..]);
}

test "queries: a pipeline from a table is one SQL statement" {
    // The whole row, the first one: a decoder for every column.
    try checkQuery("q = fn id -> links |> Db.filter (fn link -> link.id == id) |> Db.first\n",
        \\q = |id| Db.first_row([Db.param_text(id)], "SELECT id, url, created, note FROM links WHERE id = $1 LIMIT 1", Db.field(Db.read_text, "id", |punk_c1| Db.field(Db.read_text, "url", |punk_c2| Db.field(Db.read_int, "created", |punk_c3| Db.field(Db.read_nullable(Db.read_text), "note", |punk_c4| Db.done({ id: punk_c1, url: punk_c2, created: punk_c3, note: punk_c4 }))))))
        \\
    );
    // One column; values from outside the query are parameters, typed by
    // the column they meet; Nothing is NULL; filters are joined with AND.
    try checkQuery(
        \\q = fn cutoff ->
        \\    links
        \\        |> Db.filter (fn link -> link.created < cutoff + 5 && (link.note == Nothing || link.url /= "x"))
        \\        |> Db.filter (fn link -> not (link.note /= Nothing))
        \\        |> Db.map .url
        \\        |> Db.all
        \\
    ,
        \\q = |cutoff| Db.all_rows([Db.param_int(cutoff + 5), Db.param_text("x")], "SELECT url FROM links WHERE created < $1 AND (note IS NULL OR url <> $2) AND NOT (note IS NOT NULL)", Db.field(Db.read_text, "url", Db.done))
        \\
    );
    // A record of values, with SQL expressions.
    try checkQuery("q = links |> Db.map (fn l -> { url = l.url, later = l.created * 2 }) |> Db.all\n",
        \\q = Db.all_rows([Db.param_int(2)], "SELECT url, created * $1 AS later FROM links", Db.field(Db.read_text, "url", |punk_c1| Db.field(Db.read_int, "later", |punk_c2| Db.done({ url: punk_c1, later: punk_c2 }))))
        \\
    );
    // A Maybe column compared with a value.
    try checkQuery("q = fn n -> links |> Db.filter (fn l -> l.note == n) |> Db.all\n",
        \\q = |n| Db.all_rows([Db.param_nullable(n, Db.param_text)], "SELECT id, url, created, note FROM links WHERE note IS NOT DISTINCT FROM $1", Db.field(Db.read_text, "id", |punk_c1| Db.field(Db.read_text, "url", |punk_c2| Db.field(Db.read_int, "created", |punk_c3| Db.field(Db.read_nullable(Db.read_text), "note", |punk_c4| Db.done({ id: punk_c1, url: punk_c2, created: punk_c3, note: punk_c4 }))))))
        \\
    );
}

test "queries: insert and update" {
    // A record written in the query: a parameter per column.
    try checkQuery("q = fn id, url -> Db.insert { id, url, created = 5, note = Nothing } links\n",
        \\q = |id, url| Db.changes([Db.param_text(id), Db.param_text(url), Db.param_int(5), Db.param_nullable(Nothing, Db.param_text)], "INSERT INTO links (id, url, created, note) VALUES ($1, $2, $3, $4)")
        \\
    );
    // Any other row is computed once.
    try checkQuery("q = fn link -> Db.insertIfNew link links\n",
        \\q = |link| {
        \\    punk_row1 = link
        \\    Db.changes([Db.param_text(punk_row1.id), Db.param_text(punk_row1.url), Db.param_int(punk_row1.created), Db.param_nullable(punk_row1.note, Db.param_text)], "INSERT INTO links (id, url, created, note) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING")
        \\}
        \\
    );
    try checkQuery("q = fn id, url -> links |> Db.filter (fn l -> l.id == id) |> Db.update (fn l -> { l | url = url, created = l.created + 1 })\n",
        \\q = |id, url| Db.changes([Db.param_text(url), Db.param_int(1), Db.param_text(id)], "UPDATE links SET url = $1, created = created + $2 WHERE id = $3")
        \\
    );
}

test "queries: keywords as names, and the schema" {
    const src =
        \\app [main!] { pf: platform "p.roc" }
        \\
        \\import pf.Db as Q
        \\
        \\type alias Order =
        \\    { orderId : Int
        \\    , user : Str
        \\    , total : Float
        \\    , paid : Bool
        \\    , memo : Maybe Str
        \\    }
        \\
        \\table order : Order
        \\    key orderId
        \\    read everyone
        \\    insert nobody
        \\    update nobody
        \\    delete everyone
        \\
        \\q = fn u -> order |> Q.filter (fn o -> o.user == u && o.paid) |> Q.delete
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const out = try punk.translate(arena.allocator(), src, &diag);
    try std.testing.expect(std.mem.find(u8, out, "q = |u| Q.changes([Q.param_text(u)], \"DELETE FROM \\\"order\\\" WHERE \\\"user\\\" = $1 AND paid\")") != null);
    try std.testing.expectEqualStrings(
        \\-- Made by `punk check --schema` from the tables of the program. Until punk
        \\-- has verified migrations (roadmap B2), a change to a table is a change you
        \\-- also make to the database by hand.
        \\
        \\CREATE TABLE IF NOT EXISTS "order" (
        \\    order_id bigint PRIMARY KEY,
        \\    "user" text NOT NULL,
        \\    total double precision NOT NULL,
        \\    paid boolean NOT NULL,
        \\    memo text
        \\);
        \\ALTER TABLE "order" ENABLE ROW LEVEL SECURITY;
        \\ALTER TABLE "order" FORCE ROW LEVEL SECURITY;
        \\DROP POLICY IF EXISTS order_read ON "order";
        \\CREATE POLICY order_read ON "order" FOR SELECT USING (true);
        \\DROP POLICY IF EXISTS order_insert ON "order";
        \\DROP POLICY IF EXISTS order_update ON "order";
        \\DROP POLICY IF EXISTS order_delete ON "order";
        \\CREATE POLICY order_delete ON "order" FOR DELETE USING (true);
        \\
    , try punk.schema(arena.allocator(), src, &diag));
}

const policy_head =
    \\app [main!] { pf: platform "p.roc" }
    \\
    \\import pf.Db
    \\
    \\type alias Note =
    \\    { id : Str
    \\    , owner : Str
    \\    , level : Int
    \\    , public : Bool
    \\    , memo : Maybe Str
    \\    }
    \\
    \\table notes : Note
    \\    key id
    \\    read fn user, note -> note.public || note.owner == user.id || user.isAdmin
    \\    insert fn user, note ->
    \\        note.owner == user.id && note.level <= user.level
    \\    update fn user, _ -> user.isAdmin
    \\    delete fn _, note -> note.owner == "it's me" && note.level > 2
    \\
    \\
;

test "policies: functions of the user and the row are row-level security" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: punk.Diagnostic = .{};
    const schema = punk.schema(arena.allocator(), policy_head, &diag) catch |err| {
        std.debug.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message });
        return err;
    };
    const policies = schema[std.mem.find(u8, schema, "ALTER TABLE").?..];
    try std.testing.expectEqualStrings(
        \\ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
        \\ALTER TABLE notes FORCE ROW LEVEL SECURITY;
        \\DROP POLICY IF EXISTS notes_read ON notes;
        \\CREATE POLICY notes_read ON notes FOR SELECT USING (public OR owner = NULLIF(current_setting('punk.user_id', true), '') OR NULLIF(current_setting('punk.user_is_admin', true), '')::boolean);
        \\DROP POLICY IF EXISTS notes_insert ON notes;
        \\CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), '') AND level <= NULLIF(current_setting('punk.user_level', true), '')::bigint);
        \\DROP POLICY IF EXISTS notes_update ON notes;
        \\CREATE POLICY notes_update ON notes FOR UPDATE USING (NULLIF(current_setting('punk.user_is_admin', true), '')::boolean) WITH CHECK (NULLIF(current_setting('punk.user_is_admin', true), '')::boolean);
        \\DROP POLICY IF EXISTS notes_delete ON notes;
        \\CREATE POLICY notes_delete ON notes FOR DELETE USING (owner = 'it''s me' AND level > 2);
        \\
    , policies);

    // `Db.runAs!` gives the fields of the user that the policies look at.
    const out = try punk.translate(arena.allocator(), policy_head ++ "main! = fn u -> Db.runAs! u (notes |> Db.all)\n", &diag);
    const start = std.mem.find(u8, out, "main! = ").?;
    try std.testing.expectEqualStrings(
        \\main! = |u| {
        \\    punk_user1 = u
        \\    Db.run_as!([Db.setting_text("punk.user_id", punk_user1.id), Db.setting_bool("punk.user_is_admin", punk_user1.is_admin), Db.setting_int("punk.user_level", punk_user1.level)], Db.all_rows([], "SELECT id, owner, level, public, memo FROM notes", Db.field(Db.read_text, "id", |punk_c2| Db.field(Db.read_text, "owner", |punk_c3| Db.field(Db.read_int, "level", |punk_c4| Db.field(Db.read_bool, "public", |punk_c5| Db.field(Db.read_nullable(Db.read_text), "memo", |punk_c6| Db.done({ id: punk_c2, owner: punk_c3, level: punk_c4, public: punk_c5, memo: punk_c6 }))))))))
        \\}
        \\
    , out[start..]);
}

test "rules: policies (P401..P404)" {
    const head =
        \\app [main!] { pf: platform "p.roc" }
        \\
        \\import pf.Db
        \\
        \\type alias L =
        \\    { id : Str
        \\    , owner : Str
        \\    , note : Maybe Str
        \\    }
        \\
        \\table ls : L
        \\    key id
        \\    insert nobody
        \\    update nobody
        \\    delete nobody
        \\
    ;
    // A policy is a function of the user and the row.
    try checkRule(head ++ "    read fn l -> l.owner == \"x\"\n", 16, 5, .table_decl);
    // ... of the row, the user and constants only.
    try checkRule(head ++ "    read fn u, l -> l.owner == someone\n", 16, 32, .not_in_database);
    try checkRule(head ++ "    read fn u, l -> l.owner == String.toLower u.id\n", 16, 32, .not_in_database);
    // A field of the user gets its type from the column it meets.
    try checkRule(head ++ "    read fn u, l -> u.id == u.other\n", 16, 23, .query_type);
    try checkRule(head ++ "    read fn u, l -> l.note == u.note\n", 16, 33, .query_type);
    try checkRule(head ++ "    read fn u, l -> l.owner == u.id && u.id\n", 16, 42, .query_type);
    try checkRule(head ++ "    read fn u, l -> l.owner\n", 16, 23, .query_type);
    // Db.runAs! needs a policy that looks at the user.
    try checkRule(head ++ "    read everyone\n\nmain! = fn u -> Db.runAs! u (ls |> Db.all)\n", 18, 17, .not_allowed);
}

test "rules: tables and queries (P401..P404)" {
    // P401: a table needs a record type it can store, and a whole policy.
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\ntable links : Link\n    read everyone\n", 3, 15, .table_decl);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\ntype alias L =\n    { id : Str }\n\ntable ls : L\n    read everyone\n", 6, 7, .table_decl);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\ntype alias L =\n    { id : List Str }\n\ntable ls : L\n    read everyone\n", 4, 7, .table_decl);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\ntype alias L =\n    { id : Str }\n\ntable ls : L\n    key name\n", 7, 9, .table_decl);
    try checkRule("app [main!] { pf: platform \"p.roc\" }\n\ntype alias L =\n    { id : Str }\n\ntable ls : L\n    read somebody\n", 7, 10, .table_decl);
    // P402: what can't run in the database.
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> String.startsWith \"x\" l.url) |> Db.all\n", 19, 33, .not_in_database);
    try checkRule(query_head ++ "q = fn f -> links |> Db.filter f |> Db.all\n", 19, 32, .not_in_database);
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.id == \"x\")\n", 19, 14, .not_in_database);
    try checkRule(query_head ++ "q = links\n", 19, 5, .not_in_database);
    try checkRule(query_head ++ "q = links |> Db.map .url |> Db.filter (fn u -> u == \"x\") |> Db.all\n", 19, 14, .not_in_database);
    try checkRule(query_head ++ "q = Db.all\n", 19, 5, .not_in_database);
    // P403: columns the table has, values of their type.
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.name == \"x\") |> Db.all\n", 19, 35, .query_type);
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.created == \"x\") |> Db.all\n", 19, 46, .query_type);
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.url) |> Db.all\n", 19, 28, .query_type);
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.url == Nothing) |> Db.all\n", 19, 42, .query_type);
    try checkRule(query_head ++ "q = links |> Db.filter (fn l -> l.note < \"x\") |> Db.all\n", 19, 40, .query_type);
    try checkRule(query_head ++ "q = fn id -> Db.insert { id } links\n", 19, 14, .query_type);
    // P404: what the policy forbids.
    try checkRule(query_head ++ "q = links |> Db.delete\n", 19, 14, .not_allowed);
}
