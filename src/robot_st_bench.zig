//! robot_st_bench - SuperTrack's learning curve on Geno, deterministic, on the CPU (plan B1).
//!
//! Every recipe decision still open - the offset scale and noise, the losses, the optimiser, the world model's
//! form - is a question about a LEARNING CURVE, and two curves are only comparable on a fixed rig: the same clip,
//! the same characters, the same judge, the same seed. This is that rig. It trains the CPU learner on the 10-second
//! dance with `robot_lab.supertrack_recipe` in SuperTrack's rhythm - collect a few steps, one world-model update,
//! one policy update - and every so often stops to LOOK: the judge in the real simulator (its 20 fixed starts, 0.5 s
//! apart, the task's own rule) and the world model's diagnosis where the policy actually goes (trust and
//! exploitation, `Learner.diagnose`). One CSV row per look, written the moment it is measured, so a killed run keeps
//! everything it got to.
//!
//! Deterministic: the same seed and options give the same rows, number for number, except the wall-clock column -
//! which is what makes two curves a comparison rather than two anecdotes. And LOOKING DOES NOT TOUCH TRAINING: the row
//! at an iteration is the same whether the bench looked every 20 iterations or every 40 (measured), so `--every` is
//! only a question of how much of the run goes to measuring. Run it from the repository root (the model
//! and the capture are read from `src/tests/fixtures/robot/` and `assets/lafan1/`):
//!
//!     zig build st-bench                                      builds it into tools/zig-out/bin
//!     tools/zig-out/bin/st_bench --minutes=10 --out=/tmp/curve.csv
//!     tools/zig-out/bin/st_bench --iterations=400 --action-scale=2.09 --out=/tmp/arm_b.csv     an A/B arm
//!
//! TWO BUILDS of this one file (Simon's choice, option C of the Sep 27 review): `st_bench`, ReleaseFast, for long
//! runs, and `st_bench_safe`, ReleaseSafe - every index checked, every assert a stop - at 1.7x the time. Neither
//! changes a number: the rows are bitwise identical when nothing is wrong. So a configuration is CLEARED by running
//! its first stretch Safe and holding the Fast run's rows against it; a matching prefix says the Fast run met no bad
//! index and no failed assert there (and says nothing past it):
//!
//!     tools/zig-out/bin/st_bench_safe --iterations=200 <arm options> --out=/tmp/arm_safe.csv
//!     tools/zig-out/bin/st_bench --minutes=30 <arm options> --out=/tmp/arm.csv
//!     tools/zig-out/bin/st_bench --compare=/tmp/arm_safe.csv,/tmp/arm.csv
//!
//! `--compare` checks the configuration lines too, so it cannot clear one arm with another's rows. And in BOTH builds
//! an error-level log is fatal (`fatalLog`): ReleaseFast strips a failed assert down to a log line, and a run that
//! logged one is not a curve. `--prove-fatal-log=1` logs one on purpose - the run must die - to show the stop works.
//!
//! Options: `st_bench --help` lists every one with the default a run really uses (read from `cpu_recipe`). The
//! command line is std's cli parser (`src/command_line.zig`): an unknown or malformed option is refused with the
//! usage (exit 1) - a misspelt option silently ignored would run the baseline under an A/B's name - and so is any
//! setting the learner would refuse (`LearnerOptions.problem`), before anything is built.

const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zm");
const rbt = @import("robot.zig");
const dance = @import("robot_dance.zig");
const track = @import("robot_track.zig");
const latent = @import("robot_latent.zig");
const geno = @import("robot_geno.zig");
const lab = @import("robot_lab.zig");

const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const float64 = zm.float64;
const eql = std.mem.eql;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const indexOfScalar = std.mem.indexOfScalar;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const ArrayList = std.ArrayList;
const cli = @import("cli");

/// std's own logger, then a STOP for anything at error level. A stripped assert (ReleaseFast) is only a
/// `std.log.err` line, and so is anything else in the engine that knows it has gone wrong; either way the run has
/// stopped being a measurement, so the bench stops too instead of finishing with a plausible curve.
fn fatalLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);
    if (level == .err) {
        @panic("st_bench: stopped on the error logged above - a run that logged one is not a curve");
    }
}

/// Every log goes through `fatalLog` (below): std reads this from the root file.
pub const std_options: std.Options = .{ .logFn = fatalLog };

// `anytype` above is std's logger signature, not a choice made here: pinned to exactly the default logger's type, so
// the hook cannot drift from what std calls.
comptime {
    if (@TypeOf(fatalLog) != @TypeOf(std.log.defaultLog)) {
        @compileError("fatalLog must have std.log.defaultLog's exact signature");
    }
}

/// The judge's starts are this many frames apart: every 0.5 s at 60 Hz, 20 of them on the 10-second dance.
const judge_spacing: usize = 30;

/// The recipe at the CPU's sizes (plan B1: hidden 64-128, batch 32-64) - every decision the plan made, with widths
/// a one-core sandbox can iterate on. The window stays SuperTrack's 16 (the recipe's own).
const cpu_recipe: lab.SuperTrackRecipe = blk: {
    var recipe: lab.SuperTrackRecipe = lab.supertrack_recipe;
    recipe.learner.hidden = 64;
    recipe.learner.batch = 32;
    recipe.learner.world.hidden = 64;
    recipe.learner.world.batch = 32;
    break :blk recipe;
};

/// A recipe switch on the command line (`--sees-applied=off`): a plain `bool` option can only be SET, and these
/// default to the recipe's own value, which is on.
const Switch = enum { on, off };

fn switchOf(value: bool) Switch {
    return if (value) .on else .off;
}

/// The command line (std's cli: `@"--name"` fields are options). Every recipe default is READ from `cpu_recipe`,
/// so `--help` prints what a run really uses and the two cannot drift.
const BenchArgs = struct {
    @"--minutes": f64 = 10.0,
    @"--iterations": usize = 0,
    @"--every": usize = 100,
    @"--seed": u64 = cpu_recipe.learner.seed,
    @"--out": []const u8 = "st_bench.csv",
    @"--compare": ?[]const u8 = null,
    @"--prove-fatal-log": bool = false,
    @"--action-scale": f32 = cpu_recipe.action_scale,
    @"--sigma": f32 = cpu_recipe.learner.sigma,
    @"--twin-world": Switch = switchOf(cpu_recipe.learner.twin_world),
    @"--w-disagree": f32 = cpu_recipe.learner.w_disagree,
    @"--filter": f32 = cpu_recipe.learner.filter,
    @"--decide-every": u32 = cpu_recipe.learner.decide_every,
    @"--sees-applied": Switch = switchOf(cpu_recipe.learner.sees_applied),
    @"--clip-normaliser": Switch = switchOf(cpu_recipe.learner.world.normalize_from_clips),
    @"--envs": usize = 8,
    @"--collect": usize = 4,
    @"--capacity": usize = 256,
    @"--hidden": usize = cpu_recipe.learner.hidden,
    @"--window": usize = cpu_recipe.learner.window,
    @"--batch": usize = cpu_recipe.learner.batch,
    @"--world-hidden": usize = cpu_recipe.learner.world.hidden,
    @"--world-steps": usize = cpu_recipe.learner.world.steps,
    @"--world-batch": usize = cpu_recipe.learner.world.batch,
};

const bench_cli: cli.Config(BenchArgs) = .{
    // Both builds come from this one file, so the name follows the build.
    .prog = if (builtin.mode == .safe) "tools/zig-out/bin/st_bench_safe" else "tools/zig-out/bin/st_bench",
    .description = "SuperTrack's learning curve on Geno's 10-second dance (plan B1): one CSV row per look. Run " ++
        "it from the repository root. Two builds, identical numbers: st_bench, and st_bench_safe (every index " ++
        "checked).",
    .args = .{
        .@"--minutes" = .{ .description = "wall-clock budget, used when --iterations is 0" },
        .@"--iterations" = .{ .description = "a hard stop at this iteration (0: the minutes decide)" },
        .@"--every" = .{ .description = "iterations between looks - a look is a whole judgement" },
        .@"--seed" = .{ .description = "the fleet's, the learner's and its world model's" },
        .@"--compare" = .{ .description = "a.csv,b.csv: hold two runs against each other instead of running" },
        .@"--prove-fatal-log" = .{ .description = "log an error on purpose - the run must die" },
        .@"--action-scale" = .{ .description = "radians of joint offset per unit of action" },
        .@"--sigma" = .{ .description = "exploration noise, in units of action" },
        .@"--twin-world" = .{ .description = "a second world model; rollouts step through the two's average" },
        .@"--w-disagree" = .{ .description = "the price on the two models' disagreement (needs --twin-world on)" },
        .@"--filter" = .{ .description = "Simon's filter: the share of a new decision in what is applied" },
        .@"--decide-every" = .{ .description = "physics steps per decision (2: 30 Hz)" },
        .@"--sees-applied" = .{ .description = "the policy sees the action it is applying (A1)" },
        .@"--clip-normaliser" = .{ .description = "the world model's normaliser from the clip (F4a)" },
        .@"--envs" = .{ .description = "characters training at once" },
        .@"--collect" = .{ .description = "steps each character collects per iteration" },
        .@"--capacity" = .{ .description = "each character's replay, in steps" },
    },
};

/// Exit codes, not errors, for the outcomes that are expected: std logs an error returned from `main` at error level,
/// which `fatalLog` would turn into a panic - right for a failure, wrong for a refusal or a disagreement. A refusal
/// is 1, the code std's cli exits with for a command line it cannot parse.
const exit_ok: u8 = 0;
const exit_refused: u8 = 1;
const exit_disagree: u8 = 2;

/// A line to stdout through the Io layer (the lint keeps `std.debug.print` out of `src/`). The caller formats: no
/// `anytype` here.
fn say(io: Io, text: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, text);
}

/// A file's lines, the empty last one dropped.
fn csvLines(arena: Allocator, text: []const u8) ![][]const u8 {
    var lines: ArrayList([]const u8) = .empty;
    var it = splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > 0) {
            try lines.append(arena, line);
        }
    }
    return lines.items;
}

fn readAll(arena: Allocator, io: Io, path: []const u8) ![]u8 {
    var file: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try arena.alloc(u8, info.size);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

/// Two CSV rows agree when every column but the second (the wall clock) is the same text.
fn rowsAgree(a: []const u8, b: []const u8) bool {
    var it_a = splitScalar(u8, a, ',');
    var it_b = splitScalar(u8, b, ',');
    var column: usize = 0;
    while (true) : (column += 1) {
        const field_a: ?[]const u8 = it_a.next();
        const field_b: ?[]const u8 = it_b.next();
        if (field_a == null or field_b == null) {
            return field_a == null and field_b == null;
        }
        const is_wall_clock: bool = column == 1;
        if (!is_wall_clock and !eql(u8, field_a.?, field_b.?)) {
            return false;
        }
    }
}

/// Hold two runs' CSVs against each other (`--compare=a.csv,b.csv`): every configuration line (`#`) but the one
/// naming the build, then the rows both have - every column but the wall clock. One run is usually a Safe PREFIX
/// of the other, so the longer one's extra rows are not compared, and the answer says how far agreement reaches.
/// False, with the two lines printed, when they disagree - or when there is nothing to compare, which clears nothing.
fn compareRuns(arena: Allocator, io: Io, pair: []const u8) !bool {
    const comma: usize = indexOfScalar(u8, pair, ',') orelse {
        try say(io, "st_bench: --compare wants two files, a.csv,b.csv\n");
        return false;
    };
    const lines_a: [][]const u8 = try csvLines(arena, try readAll(arena, io, pair[0..comma]));
    const lines_b: [][]const u8 = try csvLines(arena, try readAll(arena, io, pair[comma + 1 ..]));
    var rows_compared: usize = 0;
    var last_iteration: []const u8 = "none";
    for (lines_a[0..@min(lines_a.len, lines_b.len)], lines_b[0..@min(lines_a.len, lines_b.len)]) |a, b| {
        const is_build_line: bool = startsWith(u8, a, "# build:") and startsWith(u8, b, "# build:");
        if (is_build_line) {
            continue;
        }
        const is_row: bool = a.len > 0 and a[0] >= '0' and a[0] <= '9';
        const agree: bool = if (is_row) rowsAgree(a, b) else eql(u8, a, b);
        if (!agree) {
            try say(io, try allocPrint(arena, "st_bench: the runs DISAGREE\n  {s}\n  {s}\n", .{ a, b }));
            return false;
        }
        if (is_row) {
            rows_compared += 1;
            last_iteration = a[0 .. indexOfScalar(u8, a, ',') orelse a.len];
        }
    }
    if (rows_compared == 0) {
        try say(io, "st_bench: no rows in common - nothing is cleared\n");
        return false;
    }
    try say(io, try allocPrint(arena, "st_bench: the same configuration, and {d} rows agree through iteration {s} " ++
        "(wall clock aside); {d} and {d} lines in the two files\n", .{
        rows_compared,
        last_iteration,
        lines_a.len,
        lines_b.len,
    }));
    return true;
}

/// The recipe a run trains with: `cpu_recipe` with every field the command line carries set from it - so the recipe
/// is exactly what `--help` says, and every seed follows `--seed`.
fn recipeFrom(args: BenchArgs) lab.SuperTrackRecipe {
    var recipe: lab.SuperTrackRecipe = cpu_recipe;
    recipe.action_scale = args.@"--action-scale";
    const learner: *latent.LearnerOptions = &recipe.learner;
    learner.sigma = args.@"--sigma";
    learner.twin_world = args.@"--twin-world" == .on;
    learner.w_disagree = args.@"--w-disagree";
    learner.filter = args.@"--filter";
    learner.decide_every = args.@"--decide-every";
    learner.sees_applied = args.@"--sees-applied" == .on;
    learner.world.normalize_from_clips = args.@"--clip-normaliser" == .on;
    learner.hidden = args.@"--hidden";
    learner.window = args.@"--window";
    learner.batch = args.@"--batch";
    learner.world.hidden = args.@"--world-hidden";
    learner.world.steps = args.@"--world-steps";
    learner.world.batch = args.@"--world-batch";
    learner.seed = args.@"--seed";
    learner.world.seed = args.@"--seed";
    return recipe;
}

/// Why a run is refused before anything is built, or null: the learner's own rule (`LearnerOptions.problem`), then
/// the bench's. A stripped assert would only log, and the bad setting would RUN.
fn refusal(args: BenchArgs, recipe: lab.SuperTrackRecipe) ?[]const u8 {
    const run_sane: bool = args.@"--every" > 0 and args.@"--envs" > 0 and args.@"--collect" > 0 and
        args.@"--minutes" > 0.0;
    if (!run_sane) {
        return "--every, --envs, --collect and --minutes must be above 0";
    }
    if (recipe.learner.problem()) |why| {
        return why;
    }
    if (!(recipe.action_scale > 0.0)) {
        return "the action scale is not above 0";
    }
    // A replay no longer than a window never yields one: that network would never update, and its curve would sit
    // flat at its start as if nothing it tried helped.
    const longest_window: usize = @max(recipe.learner.window, recipe.learner.world.steps);
    if (args.@"--capacity" <= longest_window + 1) {
        return "--capacity: a replay no longer than a window never yields one";
    }
    return null;
}

fn secondsSince(io: Io, started: Io.Timestamp) f64 {
    const elapsed_ns: i96 = Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
    return float64(elapsed_ns) * 1.0e-9;
}

/// What one look finds: the judge's verdict in the real simulator, and the world model's diagnosis where the policy
/// goes. Both from the judge's fixed starts, so two looks - and two runs - measure the same thing.
const Look = struct {
    judgement: track.Judgement,
    diagnosis: latent.Diagnosis,
};

fn lookAt(
    gpa: Allocator,
    m: *rbt.Model,
    learner: *latent.Learner,
    clip: *const dance.Clip,
    starts: []const usize,
) !Look {
    const options: track.Fleet.Options = learner.fleet.options;
    const judgement: track.Judgement = try track.judge(gpa, m, clip, options, starts, learner.judgeActor());
    const diagnosis: latent.Diagnosis = try learner.diagnose(clip, starts, learner.options.window);
    return .{ .judgement = judgement, .diagnosis = diagnosis };
}

/// A loss for the CSV: empty until the network has had its first update (too little data before that).
fn lossText(arena: Allocator, loss: ?f32) ![]const u8 {
    if (loss) |value| {
        return allocPrint(arena, "{d:.6}", .{value});
    }
    return "";
}

fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    args: BenchArgs,
    recipe: lab.SuperTrackRecipe,
) !void {
    const task: *geno.GenoTask = (try geno.GenoTask.init(gpa, io, .dance_5_15)) orelse {
        try say(io, "st_bench: the Geno model or the dance capture is missing - run from the repository root\n");
        return error.MissingAssets;
    };
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clip: *const dance.Clip = &task.clip;
    const clips = [_]*const dance.Clip{clip};
    const fleet: *track.Fleet = try .init(gpa, m, &clips, .{
        .envs = args.@"--envs",
        .capacity = args.@"--capacity",
        .action_scale = recipe.action_scale,
        .task = recipe.trainingTask(),
        .body_names = task.imported.names,
        .seed = args.@"--seed",
    });
    defer fleet.deinit();
    const learner: *latent.Learner = try .init(gpa, fleet, recipe.learner);
    defer learner.deinit();
    const starts: []usize = try track.evenStarts(gpa, clip, judge_spacing);
    defer gpa.free(starts);

    // What the run IS, read back from the objects it runs with (not from the command line), and the servo alone on
    // the same judge - the number every row is read against.
    const options: latent.LearnerOptions = learner.options;
    const servo: track.Judgement = try track.judge(gpa, m, clip, fleet.options, starts, null);
    const preamble: []u8 = try allocPrint(arena, "# st_bench on dance_5_15, seed {d}: scale {d:.3} rad, " ++
        "sigma {d:.3}, twin world {}, w_disagree {d:.3}, filter {d:.2}, decide every {d}, " ++
        "sees applied {}, clip normaliser {}, grace {d} steps\n" ++
        "# sizes: {d} characters x {d} steps an iteration, replay {d} each; policy {d} wide, window {d}, batch {d}; " ++
        "world {d} wide, {d} steps, batch {d}\n" ++
        "# servo alone, {d} starts: mttf {d:.3} s, {d} to the end, reward {d:.4}\n" ++
        "# build: {s}\n" ++
        "iteration,wall_s,samples,world_loss,policy_loss,mttf_s,share_to_end,reward,trust,exploitation\n", .{
        args.@"--seed",
        fleet.options.action_scale,
        options.sigma,
        learner.twin != null,
        options.w_disagree,
        options.filter,
        options.decide_every,
        learner.applied_block != null,
        options.world.normalize_from_clips,
        fleet.options.task.termination.grace_steps,
        fleet.options.envs,
        args.@"--collect",
        fleet.options.capacity,
        options.hidden,
        options.window,
        options.batch,
        options.world.hidden,
        options.world.steps,
        options.world.batch,
        starts.len,
        servo.meanTimeToFailure(),
        servo.reached_end,
        servo.meanReward(),
        @tagName(builtin.mode),
    });
    try say(io, preamble);
    const file: Io.File = try Io.Dir.cwd().createFile(io, args.@"--out", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, preamble);

    const started: Io.Timestamp = Io.Clock.now(.awake, io);
    // Where an iteration's time goes (plan risk 1: is the CPU fast enough to show learning?) - the three phases of
    // SuperTrack's rhythm, summed over the run. Looks are the bench's cost, not the learner's, and are not in them.
    var collect_ns: i96 = 0;
    var world_ns: i96 = 0;
    var policy_ns: i96 = 0;
    var world_loss: ?f32 = null;
    var policy_loss: ?f32 = null;
    var iteration: usize = 0;
    while (true) : (iteration += 1) {
        const wall_seconds: f64 = secondsSince(io, started);
        const out_of_iterations: bool = args.@"--iterations" > 0 and iteration >= args.@"--iterations";
        const out_of_time: bool = args.@"--iterations" == 0 and wall_seconds >= args.@"--minutes" * 60.0;
        const last: bool = out_of_iterations or out_of_time;
        if (iteration % args.@"--every" == 0 or last) {
            const seen: Look = try lookAt(gpa, m, learner, clip, starts);
            var samples: u64 = 0;
            for (fleet.replay.written) |written| {
                samples += written;
            }
            const line: []u8 = try allocPrint(arena, "{d},{d:.1},{d},{s},{s},{d:.4},{d:.3},{d:.5},{d:.5},{d:.5}\n", .{
                iteration,
                wall_seconds,
                samples,
                try lossText(arena, world_loss),
                try lossText(arena, policy_loss),
                seen.judgement.meanTimeToFailure(),
                seen.judgement.shareToEnd(),
                seen.judgement.meanReward(),
                seen.diagnosis.trust(),
                seen.diagnosis.exploitation(),
            });
            try file.writeStreamingAll(io, line);
            // The iteration rate counts training alone, and splits it by phase.
            const training_seconds: f64 = float64(collect_ns + world_ns + policy_ns) * 1.0e-9;
            const rate: f64 = if (training_seconds > 0.0) float64(iteration) / training_seconds else 0.0;
            const per_iteration: f64 = 1.0e-6 / float64(@max(iteration, 1));
            try say(io, try allocPrint(arena, "st_bench: iteration {d} at {d:.0} s ({d:.1} it/s training: collect " ++
                "{d:.0} + world {d:.0} + policy {d:.0} ms each): mttf {d:.2} s, {d} of {d} to the end, reward " ++
                "{d:.3}, trust {d:.3}, exploitation {d:.3}\n", .{
                iteration,
                wall_seconds,
                rate,
                float64(collect_ns) * per_iteration,
                float64(world_ns) * per_iteration,
                float64(policy_ns) * per_iteration,
                seen.judgement.meanTimeToFailure(),
                seen.judgement.reached_end,
                seen.judgement.starts,
                seen.judgement.meanReward(),
                seen.diagnosis.trust(),
                seen.diagnosis.exploitation(),
            }));
        }
        if (last) {
            break;
        }
        // SuperTrack's rhythm: collect with the policy exploring, then one update of each network.
        const t0: i96 = Io.Clock.now(.awake, io).nanoseconds;
        learner.act(args.@"--collect", 1.0);
        const t1: i96 = Io.Clock.now(.awake, io).nanoseconds;
        if (try learner.trainWorld(fleet)) |loss| {
            world_loss = loss;
        }
        const t2: i96 = Io.Clock.now(.awake, io).nanoseconds;
        if (try learner.trainPolicy()) |loss| {
            policy_loss = loss;
        }
        const t3: i96 = Io.Clock.now(.awake, io).nanoseconds;
        collect_ns += t1 - t0;
        world_ns += t2 - t1;
        policy_ns += t3 - t2;
    }
    try say(io, try allocPrint(arena, "st_bench: {d} iterations, rows in {s}\n", .{ iteration, args.@"--out" }));
}

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;
    // Every line of text the run prints or writes lives here until the end: a few hundred bytes a look.
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // `--help` prints every option with its default and exits 0; a command line that does not fit `BenchArgs`
    // prints the same and exits 1 (`exit_refused`).
    const args: BenchArgs = cli.args(&init, BenchArgs, bench_cli);
    if (args.@"--prove-fatal-log") {
        std.log.err("st_bench: --prove-fatal-log - this line must stop the run", .{});
    }
    if (args.@"--compare") |pair| {
        const agree: bool = try compareRuns(arena, io, pair);
        return if (agree) exit_ok else exit_disagree;
    }
    const recipe: lab.SuperTrackRecipe = recipeFrom(args);
    if (refusal(args, recipe)) |why| {
        try say(io, try allocPrint(arena, "st_bench: refused: {s}\n", .{why}));
        return exit_refused;
    }
    try run(gpa, arena, io, args, recipe);
    return exit_ok;
}
