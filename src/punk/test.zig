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
        \\ranges = text |> List.mapTry parseRange?
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
        \\Shape := [Circle(F64), Rect(F64, F64)]
        \\
        \\Maybe(a) := [Just(a), Nothing]
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

test "var, for, while" {
    try check(
        \\sum = fn xs ->
        \\    var total = 0
        \\    for x in xs
        \\        total = total + x
        \\    "${Num.toStr total}"
        \\
        \\count = fn () ->
        \\    var i = 0
        \\    while i < 5
        \\        i = i + 1
        \\    i
    ,
        \\sum = |xs| {
        \\    var $total = 0
        \\    for x in xs {
        \\        $total = $total + x
        \\    }
        \\    "${Num.to_str($total)}"
        \\}
        \\
        \\count = || {
        \\    var $i = 0
        \\    while $i < 5 {
        \\        $i = $i + 1
        \\    }
        \\    $i
        \\}
        \\
    );
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
        \\    name = List.first args?
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

test "postfix try binds to the whole call" {
    try check(
        \\f = fn a ->
        \\    x = U64.fromStr a?
        \\    Ok x
    ,
        \\f = |a| {
        \\    x = U64.from_str(a)?
        \\    Ok(x)
        \\}
        \\
    );
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
        \\d = List.fold (fn acc, x -> acc + x) 0 xs
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
    const iface = try interface.scanRoc(arena.allocator(), files.entries[1][1]);
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
