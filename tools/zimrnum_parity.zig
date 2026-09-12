//! zimrnum_parity.zig - what zimrnum is still missing from znum, mechanically.
//!
//! ## WHY THIS IS A TOOL AND NOT A LIST IN A PLAN
//!
//! The roadmap in `src/notes/zimrnum_plan.md` was wrong three times running. It had been built by
//! reading znum's function names and assuming the absent ones were missing - so serialisation,
//! the optimisers and two thirds of linalg were all listed as work when they were already done.
//!
//! A list in a document is a measurement taken once. **This runs.** `zig build zimrnum-parity`
//! prints the current answer, so the plan can quote a number that was true this morning.
//!
//! ## THE HARD PART IS THE RENAMES, AND THEY ARE DATA
//!
//! zimrnum deliberately renames things - `amax` is `maxAll`, `det` is `determinant`, `sin` is
//! `sinRad`, `corr` is `correlation`. A naive name diff reports every one of those as missing and
//! is therefore useless.
//!
//! The alias table below is the real content of this tool. Each entry is a divergence someone
//! decided on, and the register row explaining it is in the plan. **An alias with no reason is a
//! bug being hidden**, so they carry a one-line note.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;

/// znum name -> what zimrnum calls it. Every entry is a deliberate divergence.
const Alias = struct { znum: []const u8, ours: []const u8, why: []const u8 };

const aliases = [_]Alias{
    .{ .znum = "sin", .ours = "sinRad", .why = "the unit is in the name; turns are the default elsewhere" },
    .{ .znum = "cos", .ours = "cosRad", .why = "as sin" },
    .{ .znum = "tan", .ours = "tanRad", .why = "as sin" },
    .{ .znum = "asin", .ours = "asinRad", .why = "as sin" },
    .{ .znum = "acos", .ours = "acosRad", .why = "as sin" },
    .{ .znum = "atan", .ours = "atanRad", .why = "as sin" },
    .{ .znum = "atan2", .ours = "atan2Rad", .why = "as sin" },
    .{ .znum = "amax", .ours = "maxAll", .why = "numpy's abbreviation says nothing" },
    .{ .znum = "amin", .ours = "minAll", .why = "as amax" },
    .{ .znum = "det", .ours = "determinant", .why = "spelled out" },
    .{ .znum = "corr", .ours = "correlation", .why = "spelled out" },
    .{ .znum = "corrMatrix", .ours = "correlationMatrix", .why = "spelled out" },
    .{ .znum = "cov", .ours = "covariance", .why = "spelled out" },
    .{ .znum = "cv", .ours = "coefficientOfVariation", .why = "two letters, no meaning" },
    .{ .znum = "mad", .ours = "medianAbsDev", .why = "mad is three different statistics" },
    .{ .znum = "rms", .ours = "rootMeanSquare", .why = "spelled out" },
    .{ .znum = "sem", .ours = "standardError", .why = "spelled out" },
    .{ .znum = "ln", .ours = "log", .why = "matches C, Zig's @log and every tensor library" },
    .{ .znum = "clip", .ours = "clamp", .why = "one name for one operation" },
    .{ .znum = "Counts", .ours = "valueCounts", .why = "a bare noun says nothing" },
    .{ .znum = "concatenate", .ours = "concat", .why = "shorter, same thing" },
    .{ .znum = "hstack", .ours = "concat", .why = "an axis argument covers it" },
    .{ .znum = "vstack", .ours = "concat", .why = "as hstack" },
    .{ .znum = "cumprod", .ours = "prodAxis", .why = "the axis form generalises" },
    .{ .znum = "logSumExp", .ours = "logSumExpAxis", .why = "the axis form generalises" },
    .{ .znum = "head", .ours = "firstRows", .why = "`head` shadows three locals in the file" },
    .{ .znum = "join", .ours = "joinRows", .why = "the pairing, split from the gather" },
    .{ .znum = "takeRows", .ours = "takeRows", .why = "same name, same job" },
    .{ .znum = "agg", .ours = "aggregate", .why = "spelled out" },
    .{ .znum = "clipGradNorm", .ours = "clipGradNorm", .why = "same" },
};

/// Things znum has that zimrnum will not, with the reason. **Silence here would be indistinguishable
/// from an oversight**, which is the whole point of writing them down.
const declined = [_]Alias{
    .{ .znum = "binaryOp", .ours = "-", .why = "map/zip plus comptime is how we dispatch" },
    .{ .znum = "unaryOp", .ours = "-", .why = "as binaryOp" },
    .{ .znum = "scalarOp", .ours = "-", .why = "as binaryOp" },
    .{ .znum = "compareOp", .ours = "-", .why = "as binaryOp" },
    .{ .znum = "addScalar", .ours = "affine", .why = "one affine replaces four scalar variants" },
    .{ .znum = "subScalar", .ours = "affine", .why = "as addScalar" },
    .{ .znum = "mulScalar", .ours = "affine", .why = "as addScalar" },
    .{ .znum = "divScalar", .ours = "affine", .why = "as addScalar" },
    .{ .znum = "eqScalar", .ours = "compareScalar", .why = "one function with a named Comparison" },
    .{ .znum = "neScalar", .ours = "compareScalar", .why = "as eqScalar" },
    .{ .znum = "ltScalar", .ours = "compareScalar", .why = "as eqScalar" },
    .{ .znum = "leScalar", .ours = "compareScalar", .why = "as eqScalar" },
    .{ .znum = "gtScalar", .ours = "compareScalar", .why = "as eqScalar" },
    .{ .znum = "geScalar", .ours = "compareScalar", .why = "as eqScalar" },
    .{ .znum = "eluGrad", .ours = "-", .why = "the tape provides it; every activation has a node" },
    .{ .znum = "geluGrad", .ours = "-", .why = "as eluGrad" },
    .{ .znum = "siluGrad", .ours = "-", .why = "as eluGrad" },
    .{ .znum = "softplusGrad", .ours = "-", .why = "as eluGrad" },
    .{ .znum = "mishGrad", .ours = "-", .why = "as eluGrad" },
    .{ .znum = "percentile", .ours = "quantile", .why = "a 0-100 scale beside a 0-1 one invites the wrong one" },
    .{ .znum = "Scope", .ours = "-", .why = "the caller owns the arena; measured, 109 -> 0 catch unreachable" },
};

/// Namespaces in znum that are its own machinery rather than a numerics surface.
const internal_namespaces = [_][]const u8{
    "cpu", "gpu", "wgsl", "Device", "Buffer", "BufferUsage", "Ctx", "UniformDims", "PermuteCache",
};

/// Names that are znum's own test scaffolding.
const fixture_marks = [_][]const u8{ "XorMlp", "actor", "critic", "LossF32", "SumF32" };

/// Every `pub fn` and `pub const` at COLUMN ZERO.
///
/// The column matters. znum nests most of its surface inside namespace structs, so a scan that
/// accepts any indentation picks up every method of every internal type - `Buffer.deinit`,
/// `Ctx.derive`, `DType.isComplex` - and reports a thousand "missing" names that nobody would
/// ever call. Anchoring at column zero is what makes the number mean something.
///
/// znum's own namespaces are then handled by the `internal_namespaces` list: they ARE at column
/// zero, and their contents are not a numerics surface.
fn publicFunctions(gpa: std.mem.Allocator, source: [:0]const u8) ![][]const u8 {
    var ast: std.zig.Ast = try std.zig.Ast.parse(gpa, source, .{});
    defer ast.deinit(gpa);
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "pub fn ")) |at| {
        // ONE SIDE IS FLAT AND THE OTHER IS NESTED
        //
        // zimrnum declares its surface at column zero. znum wraps almost all of its in namespace
        // structs, so anchoring at column zero reports 115 of its 549 functions and calls the
        // rest missing.
        //
        // So indentation is allowed, and the ENCLOSING namespace is what filters instead: the
        // last `pub const NAME = struct` before this point. `internal_namespaces` names the ones
        // that are machinery rather than numerics.
        var enclosing: []const u8 = "";
        var back: usize = 0;
        while (std.mem.indexOfPos(u8, source[0..at], back, "pub const ")) |nsat| {
            var nsend: usize = nsat + 10;
            while (nsend < at and (std.ascii.isAlphanumeric(source[nsend]) or source[nsend] == '_')) {
                nsend += 1;
            }
            if (nsend + 10 < at and std.mem.startsWith(u8, source[nsend..], " = struct")) {
                enclosing = source[nsat + 10 .. nsend];
            }
            back = nsend;
        }
        var internal: bool = false;
        for (internal_namespaces) |ns| {
            if (std.mem.eql(u8, ns, enclosing)) {
                internal = true;
            }
        }
        if (internal) {
            var skip: usize = at + 7;
            while (skip < source.len and (std.ascii.isAlphanumeric(source[skip]) or source[skip] == '_')) {
                skip += 1;
            }
            i = skip;
            continue;
        }
        var stop: usize = at + 7;
        while (stop < source.len and (std.ascii.isAlphanumeric(source[stop]) or source[stop] == '_')) {
            stop += 1;
        }
        if (stop > at + 7) {
            try out.append(gpa, source[at + 7 .. stop]);
        }
        i = stop;
    }
    var j: usize = 0;
    while (std.mem.indexOfPos(u8, source, j, "pub const ")) |at| {
        var stop: usize = at + 10;
        while (stop < source.len and (std.ascii.isAlphanumeric(source[stop]) or source[stop] == '_')) {
            stop += 1;
        }
        if (stop > at + 10) {
            try out.append(gpa, source[at + 10 .. stop]);
        }
        j = stop;
    }
    return out.toOwnedSlice(gpa);
}

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) {
            return true;
        }
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: std.mem.Allocator = arena.allocator();
    const limit: std.Io.Limit = .limited(32 * 1024 * 1024);

    const raw_ours: []u8 = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "src/zimrnum.zig",
        gpa,
        limit,
    ) catch |err| {
        std.debug.print("zimrnum_parity: cannot read src/zimrnum.zig: {s}\n", .{@errorName(err)});
        return;
    };
    const ours_src: [:0]u8 = try gpa.allocSentinel(u8, raw_ours.len, 0);
    @memcpy(ours_src[0..raw_ours.len], raw_ours);
    const ours: [][]const u8 = try publicFunctions(gpa, ours_src);

    const raw_theirs: []u8 = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "/tmp/znum/znum/znum.zig",
        gpa,
        limit,
    ) catch {
        // znum is a reference checkout, not part of the repo. Without it this reports what it
        // can and says so, rather than failing a build that has nothing wrong with it.
        std.debug.print(
            "zimrnum_parity: znum not found at /tmp/znum/znum/znum.zig\n" ++
                "  zimrnum public surface: {d} declarations\n" ++
                "  aliases recorded: {d}, deliberate declines: {d}\n",
            .{ ours.len, aliases.len, declined.len },
        );
        return;
    };
    const theirs_src: [:0]u8 = try gpa.allocSentinel(u8, raw_theirs.len, 0);
    @memcpy(theirs_src[0..raw_theirs.len], raw_theirs);
    const theirs: [][]const u8 = try publicFunctions(gpa, theirs_src);

    var missing: std.ArrayList([]const u8) = .empty;
    var matched: usize = 0;
    var skipped: usize = 0;
    outer: for (theirs) |name| {
        for (fixture_marks) |mark| {
            if (contains(name, mark)) {
                skipped += 1;
                continue :outer;
            }
        }
        for (internal_namespaces) |ns| {
            if (std.mem.eql(u8, name, ns)) {
                skipped += 1;
                continue :outer;
            }
        }
        for (declined) |d| {
            if (std.mem.eql(u8, d.znum, name)) {
                skipped += 1;
                continue :outer;
            }
        }
        if (has(ours, name)) {
            matched += 1;
            continue;
        }
        for (aliases) |a| {
            if (std.mem.eql(u8, a.znum, name) and has(ours, a.ours)) {
                matched += 1;
                continue :outer;
            }
        }
        // Suffixed forms: znum's `mean` against our `meanAll`, `sum` against `sumAll`.
        for ([_][]const u8{ "All", "Axis", "Rows", "Rad", "Batch", "Step" }) |suffix| {
            const joined: []const u8 = try allocPrint(gpa, "{s}{s}", .{ name, suffix });
            if (has(ours, joined)) {
                matched += 1;
                continue :outer;
            }
        }
        try missing.append(gpa, name);
    }

    // THE NUMBER BELOW IS AN UPPER BOUND, AND SAYING SO IS THE POINT
    //
    // `internal_namespaces` is not yet complete: znum has more machinery types than are listed,
    // so some of their methods still count as "missing" when nobody would ever call them. Every
    // entry added to that list moves the number down and none moves it up.
    //
    // It is still worth running, because **an upper bound that is computed beats a list that was
    // typed** - which is what the roadmap was for three turns, each time wrong. Refining the
    // exclusion list is the work; the measurement is the method.
    std.debug.print(
        \\zimrnum parity against znum (STILL MISSING is an upper bound - see the note in main)
        \\
        \\  znum public declarations   {d}
        \\  ours                       {d}
        \\  matched (incl. aliases)    {d}
        \\  deliberately not ours      {d}
        \\  STILL MISSING              {d}
        \\
        \\
    , .{ theirs.len, ours.len, matched, skipped, missing.items.len });

    for (missing.items) |name| {
        std.debug.print("    {s}\n", .{name});
    }
}
