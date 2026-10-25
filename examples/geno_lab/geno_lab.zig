//! examples/geno_lab - the training lab: a run's policy, shown on Geno.
//!
//! A training run is a folder (`tools/geno_trainer.zig`): its parameters in `run.zon`, its newest weights and its
//! newest policy, beside them their checkpoints, its log and its status. The lab lists the run folders in `runs`,
//! beside its own executable. A run chosen there is loaded - its parameters, for the task, and its policy file - and
//! shown: Geno on the floor following the dance, each decision the policy's mean action through DReCon's filter
//! (`robot_lab.PolicyShow`), with the reference beside him. No learner is loaded to watch a run, so every learner's
//! run is watched this one way. A click on the learning curves shows the policy checkpoint nearest that minute; while
//! the trainer runs, "reload" puts its newest policy in place of the one shown, and the character goes on.
//!
//! The lab starts trainers too, beside its own executable: on a new run from its form, or again on a run that ended -
//! "resume", the trainer carrying on from the folder's weights and log - and asks one to stop through its `stop` file.
//! A trainer keeps running when the lab closes.
//!
//! Run folders are files by path, which a page does not have: in a web build the list is left out.

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const codecs = z.codecs;
const dance = z.robot_dance;
const ppo_track = z.robot_ppo_track;
const track = z.robot_track;
const geno = z.robot_geno;
const lab = z.robot_lab;
const native_os = z.native_os;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const qmul = zm.qmul;
const quatToMat = zm.quatToMat;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const splat = zm.splat;
const clamp = zm.clamp;
const log10 = zm.log10;
const bufPrint = std.fmt.bufPrint;
const lessThan = std.mem.lessThan;
const sortSlice = std.mem.sort;
const eql = std.mem.eql;
const splitScalar = std.mem.splitScalar;
const isAlphanumeric = std.ascii.isAlphanumeric;

const is_browser: bool = z.host.is_browser;
const log = std.log.scoped(.lab);

const dance_zclip = @embedFile("geno_dance_zclip");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// The lab's colours: the background, the character, the reference, the floor.
const Look = struct {
    background: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 },
    character: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 },
    reference: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 },
    floor: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 },
    /// What stops a new run from starting, in its form.
    problem: Color = .{ .r = 235, .g = 120, .b = 110, .a = 255 },
    /// The runs' colours on the curves, in the list's order, round again after the last.
    runs: [6]Color = .{
        .{ .r = 120, .g = 170, .b = 225, .a = 255 },
        .{ .r = 230, .g = 160, .b = 80, .a = 255 },
        .{ .r = 130, .g = 200, .b = 120, .a = 255 },
        .{ .r = 220, .g = 110, .b = 130, .a = 255 },
        .{ .r = 190, .g = 150, .b = 220, .a = 255 },
        .{ .r = 220, .g = 210, .b = 120, .a = 255 },
    },

    fn runColor(look: Look, run_index: usize) Color {
        return look.runs[run_index % look.runs.len];
    }
};

/// How often the runs' logs and statuses are read again: the trainer rewrites them every few minutes, so a few
/// seconds is often enough to see a new save soon after it lands.
const CurvesRefresh = struct {
    interval_seconds: f32 = 5,
};

/// The curves' plot: the time to failure from 1 s to 60 s on a logarithmic scale, where a policy's progress from
/// the servo's seconds to a minute takes equal room per tenfold; the marked values; the frame's height.
const CurvePlot = struct {
    lowest_seconds: f32 = 1,
    highest_seconds: f32 = 60,
    marks: [4]f32 = .{ 1, 5, 20, 60 },
    height: f32 = 180,
    /// The shortest x range, in minutes: a run's first minutes fill the plot rather than a sliver at its left.
    least_minutes: f32 = 0.1,
};

/// The floor's slab, as drawn: square, of some thickness, its top just below the grid - where the physics floor
/// is, as near as the grid's lines allow without the two fighting for the same pixels.
const Floor = struct {
    side: f32 = 16,
    thickness: f32 = 0.2,
    top: f32 = -0.005,
};

/// The new training's form (`drawNewRunWindow`): the run's parameters as its `run.zon` will hold them, the name of
/// its folder, and whether the form is open.
const NewRunForm = struct {
    is_open: bool = false,
    run: lab.PpoRun = .{},
    name_buffer: [64]u8 = @splat(0),
    name_length: usize = 0,

    fn name(form: *const NewRunForm) []const u8 {
        return form.name_buffer[0..form.name_length];
    }
};

/// A trainer this lab started (`startRun`, `resumeRun`): its run's folder name and the program. The program's watcher
/// thread keeps the program's address, so a started trainer never moves: `State.started` is a fixed array, and a slot
/// is taken again only once its trainer has ended.
const StartedTrainer = struct {
    run_name: z.Str(name_capacity) = .{},
    program: native_os.ChildProgram = .{},
    /// The program's state when the console was last told it (`watchStartedTrainers`): each change is told once.
    told_state: native_os.ChildState = .idle,

    /// How many trainers one lab starts and watches at once.
    const most: usize = 8;
    /// The longest run name a slot holds, in bytes: the new-run form's longest (`NewRunForm.name_buffer`).
    const name_capacity: usize = 64;

    fn isRunning(started: *const StartedTrainer) bool {
        return started.program.currentState() == .running;
    }
};

// ---- Run folders ----

/// The folder the lab finds runs in: `runs`, beside its own executable, written into `buffer`.
fn runsFolder(io: Io, buffer: []u8) ?[]const u8 {
    var executable_buffer: [1024]u8 = undefined;
    const executable_folder: []const u8 = native_os.executableFolder(io, &executable_buffer) orelse return null;
    return bufPrint(buffer, "{s}/runs", .{executable_folder}) catch null;
}

/// The path of `name` in `folder`, written into `buffer`.
fn pathIn(folder: []const u8, name: []const u8, buffer: []u8) ?[]const u8 {
    return bufPrint(buffer, "{s}/{s}", .{ folder, name }) catch null;
}

/// The run folders in `runs_folder`, by name: its folders, without its files. Free the list with
/// `native_os.freeFolderEntries`.
fn listRuns(gpa: Allocator, io: Io, runs_folder: []const u8) ![]native_os.FolderEntry {
    const entries: []native_os.FolderEntry = try native_os.listFolder(gpa, io, runs_folder);
    var folder_count: usize = 0;
    for (entries) |entry| {
        if (entry.kind == .folder) {
            entries[folder_count] = entry;
            folder_count += 1;
        } else {
            gpa.free(entry.name);
        }
    }
    const runs: []native_os.FolderEntry = try gpa.realloc(entries, folder_count);
    sortSlice(native_os.FolderEntry, runs, {}, struct {
        fn byName(_: void, a: native_os.FolderEntry, b: native_os.FolderEntry) bool {
            return lessThan(u8, a.name, b.name);
        }
    }.byName);
    return runs;
}

/// The trainer's executable (`tools/geno_trainer.zig`), beside the lab's own - where the lab's build installs it -,
/// written into `buffer`.
fn trainerPath(io: Io, buffer: []u8) ?[]const u8 {
    var executable_buffer: [1024]u8 = undefined;
    const executable_folder: []const u8 = native_os.executableFolder(io, &executable_buffer) orelse return null;
    const trainer_file_name: []const u8 = if (builtin.os.tag == .windows) "geno_trainer.exe" else "geno_trainer";
    return pathIn(executable_folder, trainer_file_name, buffer);
}

/// The index of the run named `name` in `runs`, or null when none has that name.
fn runIndexNamed(runs: []const native_os.FolderEntry, name: []const u8) ?usize {
    for (runs, 0..) |run, index| {
        if (eql(u8, run.name, name)) {
            return index;
        }
    }
    return null;
}

/// Whether `name` can name a run's folder: not empty, and only letters, digits, '-' and '_' - nothing a path reads
/// as a separator or as a folder above.
fn isRunNameFit(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    for (name) |character| {
        const is_letter_or_digit: bool = isAlphanumeric(character);
        const is_dash_or_underscore: bool = character == '-' or character == '_';
        if (!is_letter_or_digit and !is_dash_or_underscore) {
            return false;
        }
    }
    return true;
}

/// A name no listed run has, for a new run of `motion`: its label and the first free number - `dance-1`,
/// `dance-2` - written into `buffer`.
fn freeRunName(
    runs: []const native_os.FolderEntry,
    motion: lab.PpoMotion,
    buffer: []u8,
) []const u8 {
    var number: u32 = 1;
    while (true) : (number += 1) {
        const name: []const u8 = bufPrint(buffer, "{s}-{d}", .{ motion.label(), number }) catch return "";
        const is_taken: bool = runIndexNamed(runs, name) != null;
        if (!is_taken) {
            return name;
        }
    }
}

/// A run's parameters, from the `run.zon` in `run_folder` (`lab.GenoRun`, which reads the older `PpoRun` too).
/// Memory: the file's text and the parser's work freed before it returns; the run is plain values.
fn readRunParameters(gpa: Allocator, io: Io, run_folder: []const u8) !lab.GenoRun {
    var path_buffer: [1200]u8 = undefined;
    const run_file_name: []const u8 = lab.RunFile.parameters.fileName();
    const run_path: []const u8 = pathIn(run_folder, run_file_name, &path_buffer) orelse return error.NameTooLong;
    const source: []u8 = try native_os.readWhole(gpa, io, run_path, lab.RunFile.most_bytes) orelse
        return error.NoRunFile;
    defer gpa.free(source);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const terminated_source: [:0]const u8 = try arena.dupeSentinel(u8, source, 0);
    var failure: lab.GenoRun.ParseFailure = .{ .description = "" };
    return lab.GenoRun.parse(gpa, arena, terminated_source, &failure);
}

/// Reads the policy file `policy_name` in `run_folder` - the newest policy, or a checkpoint of it (`lab.PolicyFile`).
/// A folder without one - a run from before policy files, or one that has not saved yet - is `error.NoPolicyFile`.
/// Memory: the policy's arrays are allocated with `gpa` and are the caller's to `deinit`; the file's bytes are freed
/// before it returns.
fn readPolicy(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    policy_name: []const u8,
) !lab.GenoPolicy {
    var path_buffer: [1200]u8 = undefined;
    const policy_path: []const u8 = pathIn(run_folder, policy_name, &path_buffer) orelse return error.NameTooLong;
    const policy_bytes: []u8 = try native_os.readWhole(gpa, io, policy_path, lab.RunFile.most_bytes) orelse
        return error.NoPolicyFile;
    defer gpa.free(policy_bytes);
    return lab.PolicyFile.decode(gpa, policy_bytes);
}

/// The policy file in `run_folder` nearest `minute` of training: the checkpoint whose minute is nearest, when the
/// folder keeps any; else the newest policy. Written into `name_buffer`. Memory: the folder's listing is freed before
/// it returns.
fn policyNearest(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    minute: u64,
    name_buffer: *lab.RunFile.NameBuffer,
) ![]const u8 {
    const newest_name: []const u8 = lab.RunFile.policy_name;
    const entries: []native_os.FolderEntry = try native_os.listFolder(gpa, io, run_folder);
    defer native_os.freeFolderEntries(gpa, entries);
    var nearest_minute: ?u64 = null;
    var nearest_distance: u64 = 0;
    for (entries) |entry| {
        const checkpoint_minute: u64 = lab.RunFile.policyCheckpointMinute(entry.name) orelse continue;
        const is_after: bool = checkpoint_minute > minute;
        const minute_distance: u64 = if (is_after) checkpoint_minute - minute else minute - checkpoint_minute;
        const is_nearer: bool = nearest_minute == null or minute_distance < nearest_distance;
        if (is_nearer) {
            nearest_distance = minute_distance;
            nearest_minute = checkpoint_minute;
        }
    }
    const chosen_minute: u64 = nearest_minute orelse return newest_name;
    return lab.RunFile.policyCheckpointName(chosen_minute, name_buffer);
}

// ---- The runs watched ----

/// A run's judgements as the lab shows them (`lab.JudgeLog`): the servo alone, and the newest policy with the minute
/// of training it was judged at - both on the same fixed starts, so the one is the other's baseline.
const JudgedRun = struct {
    servo: track.Judgement,
    newest: track.Judgement,
    newest_minutes: f32,
};

/// The servo's judgement and the newest one in `judge.csv`'s text: its first line of batch zero, and its last line of
/// any later batch; null until the file holds both.
fn judgedRunOf(judgements_text: []const u8) ?JudgedRun {
    var servo: ?track.Judgement = null;
    var newest: ?lab.JudgeLog.Line = null;
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, judgements_text, '\n');
    while (lines.next()) |line_text| {
        const line: lab.JudgeLog.Line = lab.JudgeLog.parseLine(line_text) orelse continue;
        if (line.batch == 0) {
            if (servo == null) {
                servo = line.judgement;
            }
        } else {
            newest = line;
        }
    }
    const servo_judgement: track.Judgement = servo orelse return null;
    const newest_line: lab.JudgeLog.Line = newest orelse return null;
    const judged: JudgedRun = .{
        .servo = servo_judgement,
        .newest = newest_line.judgement,
        .newest_minutes = newest_line.training_minutes,
    };
    return judged;
}

/// A run as the lab watches it: its learning curve, read from its log as it grows, the points the plot draws, its
/// status as last read, and its newest judgement beside the servo's.
const RunWatch = struct {
    curve: lab.RunCurve = .{},
    /// The curve's points as the plot takes them: training minutes, and the time to failure - a window in which
    /// nothing failed drawn at the plot's top.
    xs: ArrayList(f32) = .empty,
    ys: ArrayList(f32) = .empty,
    status: ?lab.RunStatus = null,
    judged: ?JudgedRun = null,
    /// The run's save interval (`GenoControls.save_minutes`), read from its `run.zon` once: what silence is judged by.
    save_minutes: ?f32 = null,

    fn deinit(watch: *RunWatch, gpa: Allocator) void {
        watch.curve.deinit(gpa);
        watch.xs.deinit(gpa);
        watch.ys.deinit(gpa);
    }

    /// Whether the run's trainer has gone silent (`RunStatus.isSilent`). Silence is judged by the run's save interval,
    /// so never for a run with no status yet, or whose `run.zon` could not be read.
    fn isSilent(watch: *const RunWatch, now_seconds: i64) bool {
        const status: lab.RunStatus = watch.status orelse return false;
        const save_minutes: f32 = watch.save_minutes orelse return false;
        return status.isSilent(now_seconds, save_minutes);
    }
};

/// Reads the run in `run_folder` again: its log's new lines into its curve, the plot's points from the curve, its
/// judgements, and its status. A file that cannot be read leaves what was read before. Memory: every file's text is
/// read with `gpa` and freed before it returns; the curve's and the plot's points grow with `gpa`, as `watch`'s.
fn readRunWatch(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    physics_steps_per_second: f32,
    plot: CurvePlot,
    watch: *RunWatch,
) !void {
    var path_buffer: [1200]u8 = undefined;
    const log_name: []const u8 = lab.RunFile.log.fileName();
    const log_path: []const u8 = pathIn(run_folder, log_name, &path_buffer) orelse return;
    if (try native_os.readWhole(gpa, io, log_path, lab.RunFile.most_bytes)) |log_text| {
        defer gpa.free(log_text);
        try watch.curve.readMore(gpa, log_text, physics_steps_per_second);
    }
    watch.xs.clearRetainingCapacity();
    watch.ys.clearRetainingCapacity();
    for (watch.curve.points.items) |point| {
        const seconds_drawn: f32 = point.seconds_to_failure orelse plot.highest_seconds;
        try watch.xs.append(gpa, point.training_minutes);
        try watch.ys.append(gpa, seconds_drawn);
    }
    const judgements_name: []const u8 = lab.RunFile.judgements.fileName();
    if (pathIn(run_folder, judgements_name, &path_buffer)) |judgements_path| {
        if (try native_os.readWhole(gpa, io, judgements_path, lab.RunFile.most_bytes)) |judgements_text| {
            defer gpa.free(judgements_text);
            watch.judged = judgedRunOf(judgements_text) orelse watch.judged;
        }
    }
    const status_name: []const u8 = lab.RunFile.status.fileName();
    const status_path: []const u8 = pathIn(run_folder, status_name, &path_buffer) orelse return;
    const status_text: []u8 = try native_os.readWhole(gpa, io, status_path, lab.RunFile.most_bytes) orelse return;
    defer gpa.free(status_text);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const terminated_status: [:0]const u8 = try arena.dupeSentinel(u8, status_text, 0);
    if (lab.RunStatus.parse(gpa, arena, terminated_status)) |status| {
        watch.status = status;
    }
    if (watch.save_minutes == null) {
        const parameters: ?lab.GenoRun = readRunParameters(gpa, io, run_folder) catch null;
        watch.save_minutes = if (parameters) |known| known.controls.save_minutes else null;
    }
}

// ---- The run shown ----

/// A run loaded and shown: its policy (`lab.GenoPolicy`, the run's newest or one of its checkpoints) and one
/// character living what the policy does (`lab.PolicyShow`) - no learner is loaded, so every learner's run is watched
/// this one way - on the show's own clock. With them, the run's parameters (the new-run form starts from them), the
/// policy file's name, and the run's folder name, its own copy, so that reloading reads the same run whatever the list
/// holds by then.
///
/// Memory: the show lives in `show_arena`, on the heap so that the arena stays where its allocator points when the
/// struct moves; the policy is allocated with the lab's `gpa`, so that a newer policy can take its place while the
/// character goes on (`reloadShownRun`).
const ShownRun = struct {
    parameters: lab.GenoRun,
    show_arena: *ArenaAllocator,
    policy: lab.GenoPolicy,
    show: lab.PolicyShow,
    /// Real time, as the show's physics steps (`stepShowForFrame`): started afresh with each run shown.
    clock: ppo_track.ShowClock,
    policy_name_buffer: lab.RunFile.NameBuffer,
    policy_name_length: usize,
    name_buffer: [256]u8,
    name_length: usize,

    fn name(self: *const ShownRun) []const u8 {
        return self.name_buffer[0..self.name_length];
    }

    /// The policy file shown: `policy`, or a checkpoint's `policy_m<minute>`.
    fn policyName(self: *const ShownRun) []const u8 {
        return self.policy_name_buffer[0..self.policy_name_length];
    }
};

/// Loads the run in `run_folder`: its parameters - for the task the policy is shown on, its decision's length, its
/// filter's bodies - its policy file `policy_name`, and a show of one character. Memory: as `ShownRun` says; release
/// with `unloadRun`.
fn loadRun(
    gpa: Allocator,
    io: Io,
    imported: *rmj.Imported,
    clip: *const dance.Clip,
    run_folder: []const u8,
    policy_name: []const u8,
) !ShownRun {
    const parameters: lab.GenoRun = try readRunParameters(gpa, io, run_folder);
    if (parameters.problem() != null) {
        return error.RunOutOfRange;
    }
    var policy: lab.GenoPolicy = try readPolicy(gpa, io, run_folder, policy_name);
    errdefer policy.deinit(gpa);
    const show_arena: *ArenaAllocator = try gpa.create(ArenaAllocator);
    show_arena.* = ArenaAllocator.init(gpa);
    errdefer {
        show_arena.deinit();
        gpa.destroy(show_arena);
    }
    const arena: Allocator = show_arena.allocator();
    // The task every learner's run is on - Geno's task, DReCon's bodies - with the learner's own decision.
    const settings: lab.PolicyShowSettings = lab.showSettingsFor(parameters);
    const clips: []*const dance.Clip = try arena.dupe(*const dance.Clip, &.{clip});
    const show: lab.PolicyShow = try .start(arena, &imported.model, imported.names, clips, &policy, settings);
    const folder_name: []const u8 = std.fs.path.basename(run_folder);
    var shown: ShownRun = .{
        .parameters = parameters,
        .show_arena = show_arena,
        .policy = policy,
        .show = show,
        .clock = .{},
        .policy_name_buffer = undefined,
        .policy_name_length = @min(policy_name.len, lab.RunFile.name_capacity),
        .name_buffer = undefined,
        .name_length = @min(folder_name.len, 256),
    };
    @memcpy(shown.policy_name_buffer[0..shown.policy_name_length], policy_name[0..shown.policy_name_length]);
    @memcpy(shown.name_buffer[0..shown.name_length], folder_name[0..shown.name_length]);
    return shown;
}

/// Releases a shown run: its show and the arena it lives in, then its policy.
fn unloadRun(gpa: Allocator, shown: *ShownRun) void {
    shown.show.end();
    shown.show_arena.deinit();
    gpa.destroy(shown.show_arena);
    shown.policy.deinit(gpa);
}

// ---- Drawing ----

/// The meshes every geom is drawn with, scaled to its size.
const Meshes = struct {
    sphere: z.Mesh,
    cube: z.Mesh,
    cylinder: z.Mesh,
};

/// A point of the robot's world, where z is up, in the drawing's, where y is up: the quarter turn about x that
/// `zm.zUpToYUp` makes, (x, y, z) to (x, z, -y).
fn yUpOf(z_up_point: Vec) Vec {
    return vec(z_up_point[0], z_up_point[2], -z_up_point[1]);
}

/// The robot in `data`, every geom at its body's place, tinted `tint`.
fn drawRobot(
    gl: *z.WgpuGl,
    model: *const rbt.Model,
    meshes: *Meshes,
    transform: *[1]Mat,
    data: *const rbt.Data,
    tint: Color,
) void {
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..model.ngeom) |geom| {
        const body: u32 = model.geom_body[geom];
        const body_position: Vec = data.body_xpos[body];
        const body_rotation: Quat = data.body_xrot[body];
        // The geom in the world: its offset from its body, turned with the body; its rotation, after the body's.
        const offset_in_world: Vec = zm.rotate(body_rotation, model.geom_pos[geom]);
        const world_position: Vec = body_position + offset_in_world;
        const world_quaternion: Quat = qmul(body_rotation, model.geom_rot[geom]);
        const world_rotation: Mat = quatToMat(world_quaternion);
        // The same place in the drawing, where y is up.
        const world_translation: Mat = translation(world_position[0], world_position[1], world_position[2]);
        const translation_drawn: Mat = mulMat(to_y_up, world_translation);
        const place: Mat = mulMat(translation_drawn, world_rotation);
        switch (model.geom_shape[geom]) {
            .sphere => |sphere| {
                const radius: f32 = sphere.radius;
                transform[0] = mulMat(place, scaling(radius, radius, radius));
                z.drawMeshInstanced(gl, &meshes.sphere, transform, tint);
            },
            .box => |box| {
                const size: Vec = box.half_extent * splat(2.0);
                transform[0] = mulMat(place, scaling(size[0], size[1], size[2]));
                z.drawMeshInstanced(gl, &meshes.cube, transform, tint);
            },
            .capsule => |capsule| {
                // The cylinder mesh rises from its base: its base moved down half the capsule's length, then the
                // mesh stretched to the capsule's radius and whole length.
                const capsule_length: f32 = 2.0 * capsule.half_height;
                const base_lowered: Mat = mulMat(place, translation(0, -capsule.half_height, 0));
                transform[0] = mulMat(base_lowered, scaling(capsule.radius, capsule_length, capsule.radius));
                z.drawMeshInstanced(gl, &meshes.cylinder, transform, tint);
            },
            else => {},
        }
    }
}

/// Steps the show through the physics steps its clock gives the frame (`ppo_track.ShowClock`): real time at any frame
/// rate and never faster, and slow motion rather than longer steps on a device that cannot keep up.
fn stepShowForFrame(
    show: *lab.PolicyShow,
    policy: *const lab.GenoPolicy,
    clock: *ppo_track.ShowClock,
    timestep: f32,
    dt: f32,
) void {
    const steps_to_take: u32 = clock.stepsForFrame(dt, timestep);
    for (0..steps_to_take) |_| {
        show.step(policy);
    }
}

/// The floor's slab: the unit cube's center half its thickness below the top, then the cube stretched to the slab.
fn drawFloor(
    gl: *z.WgpuGl,
    cube: *z.Mesh,
    transform: *[1]Mat,
    floor: Floor,
    tint: Color,
) void {
    const center_height: f32 = floor.top - 0.5 * floor.thickness;
    const center: Mat = mulMat(zm.zUpToYUp(), translation(0, 0, center_height));
    transform[0] = mulMat(center, scaling(floor.side, floor.side, floor.thickness));
    z.drawMeshInstanced(gl, cube, transform, tint);
}

// ---- The app ----

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    meshes: Meshes,
    transform: [1]Mat,
    document: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    clip: dance.Clip,
    /// The reference pose, posed from the clip at the shown character's frame.
    ghost: rbt.Data,
    runs_folder_buffer: [1024]u8,
    runs_folder_length: usize,
    runs: []native_os.FolderEntry,
    /// One per run of `runs`, in its order.
    watches: []RunWatch,
    curves_refresh: CurvesRefresh,
    curve_plot: CurvePlot,
    /// Seconds since the runs were last read (`readRunWatch`).
    since_runs_read_seconds: f32,
    selected_run: ?usize,
    shown: ?ShownRun,
    status: z.Str(160),
    look: Look,
    floor: Floor,
    new_run: NewRunForm,
    started: [StartedTrainer.most]StartedTrainer,
};

fn runsFolderOf(s: *const State) []const u8 {
    return s.runs_folder_buffer[0..s.runs_folder_length];
}

/// Says what the lab just did, or why it could not: on the panel's status line, and as a line on the console the
/// lab was started from.
fn tell(
    s: *State,
    comptime level: std.log.Level,
    comptime format: []const u8,
    arguments: anytype,
) void {
    s.status = .print(format, arguments);
    switch (level) {
        .err => log.err(format, arguments),
        .warn => log.warn(format, arguments),
        .info, .debug => log.info(format, arguments),
    }
}

/// Reads every watched run again (`readRunWatch`).
fn readRuns(s: *State, io: Io) void {
    const physics_steps_per_second: f32 = 1.0 / s.imported.model.opt.timestep;
    for (s.runs, s.watches) |run, *watch| {
        var path_buffer: [1200]u8 = undefined;
        const run_folder: []const u8 = pathIn(runsFolderOf(s), run.name, &path_buffer) orelse continue;
        readRunWatch(s.gpa, io, run_folder, physics_steps_per_second, s.curve_plot, watch) catch |err| {
            s.status = .print("{s}: {s}", .{ run.name, @errorName(err) });
        };
    }
    s.since_runs_read_seconds = 0;
}

/// The run folders listed again from the runs folder; the shown run found again in the new list, by name - or no
/// run selected, when its folder has gone.
fn refreshRuns(s: *State, io: Io) void {
    for (s.watches) |*watch| {
        watch.deinit(s.gpa);
    }
    s.gpa.free(s.watches);
    s.watches = &.{};
    native_os.freeFolderEntries(s.gpa, s.runs);
    s.runs = &.{};
    s.runs = listRuns(s.gpa, io, runsFolderOf(s)) catch |err| list: {
        tell(s, .err, "cannot list the runs: {s}", .{@errorName(err)});
        break :list &.{};
    };
    log.info("{d} runs in {s}", .{ s.runs.len, runsFolderOf(s) });
    s.watches = s.gpa.alloc(RunWatch, s.runs.len) catch &.{};
    for (s.watches) |*watch| {
        watch.* = .{};
    }
    readRuns(s, io);
    const shown: *const ShownRun = if (s.shown) |*loaded| loaded else {
        s.selected_run = null;
        return;
    };
    s.selected_run = runIndexNamed(s.runs, shown.name());
}

/// Shows the run at `index` of the list with the policy file `policy_name`, in place of the one shown.
fn showRunWith(
    s: *State,
    io: Io,
    index: usize,
    policy_name: []const u8,
) void {
    if (s.shown) |*previous| {
        unloadRun(s.gpa, previous);
        s.shown = null;
    }
    s.selected_run = index;
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = s.runs[index].name;
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    const shown: ShownRun = loadRun(s.gpa, io, &s.imported, &s.clip, run_folder, policy_name) catch |err| {
        if (err == error.NoPolicyFile) {
            tell(s, .warn, "{s}: no policy file - a run from before them, or one not saved yet", .{name});
        } else {
            tell(s, .warn, "{s}: cannot show it: {s}", .{ name, @errorName(err) });
        }
        return;
    };
    s.shown = shown;
    tell(s, .info, "showing {s}: {s}", .{ name, policy_name });
}

/// Shows the run at `index` of the list with its newest policy, in place of the one shown.
fn showRun(s: *State, io: Io, index: usize) void {
    showRunWith(s, io, index, lab.RunFile.policy_name);
}

/// Reads the shown run's newest policy again and puts it in place of the one shown: the character goes on, now
/// acting by the newer policy (the show takes its policy at every step).
fn reloadShownRun(s: *State, io: Io) void {
    const shown: *ShownRun = if (s.shown) |*loaded| loaded else return;
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = shown.name();
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    const newest_name: []const u8 = lab.RunFile.policy_name;
    const newer_policy: lab.GenoPolicy = readPolicy(s.gpa, io, run_folder, newest_name) catch |err| {
        tell(s, .warn, "{s}: cannot reload: {s}", .{ name, @errorName(err) });
        return;
    };
    shown.policy.deinit(s.gpa);
    shown.policy = newer_policy;
    shown.policy_name_length = newest_name.len;
    @memcpy(shown.policy_name_buffer[0..newest_name.len], newest_name);
    tell(s, .info, "reloaded {s}: its newest policy", .{name});
}

// ---- Starting and stopping runs ----

/// Opens the new training's form: its parameters the shown run's - so trying a variation of a run is changing one
/// field - or the defaults when no run is shown, and a name no run has.
fn openNewRunForm(s: *State) void {
    const form: *NewRunForm = &s.new_run;
    // The form is PPO's for now: a PPO run starts it from its own settings, another learner's from the defaults.
    form.run = if (s.shown) |*shown| (shown.parameters.toPpoRun() orelse .{}) else .{};
    const name: []const u8 = freeRunName(s.runs, form.run.motion, &form.name_buffer);
    form.name_length = name.len;
    form.is_open = true;
    const source: []const u8 = if (s.shown) |*shown| shown.name() else "the defaults";
    log.info("new training: parameters from {s}, named {s}", .{ source, name });
}

/// Why the form's run cannot start, or null when it can: a name unfit for a folder or already a run's, or a
/// parameter the trainer would refuse (`PpoRun.problem`).
fn newRunProblem(form: *const NewRunForm, runs: []const native_os.FolderEntry) ?[]const u8 {
    const name: []const u8 = form.name();
    if (!isRunNameFit(name)) {
        return "name: letters, digits, - and _ only";
    }
    const is_taken: bool = runIndexNamed(runs, name) != null;
    if (is_taken) {
        return "name: a run of that name exists";
    }
    return form.run.problem();
}

/// A slot of `started` free for another trainer: one never used, or whose trainer has ended. Null when every slot's
/// trainer still runs.
fn freeStartedSlot(started: []StartedTrainer) ?*StartedTrainer {
    for (started) |*slot| {
        if (!slot.isRunning()) {
            return slot;
        }
    }
    return null;
}

/// Whether a trainer this lab started still runs on the run named `name`.
fn isTrainerRunningOn(started: []const StartedTrainer, name: []const u8) bool {
    for (started) |*slot| {
        const is_on_this_run: bool = eql(u8, slot.run_name.slice(), name);
        if (is_on_this_run and slot.isRunning()) {
            return true;
        }
    }
    return false;
}

/// What a trainer needs to start: a slot of `State.started` to watch it in, and the trainer's executable.
const TrainerLaunch = struct {
    slot: *StartedTrainer,
    trainer_path: []const u8,
};

/// A free slot and the trainer beside the lab, its path written into `path_buffer`. Null, after saying why, when
/// every slot's trainer still runs or no trainer is there - found out before a run's folder is touched, so that a run
/// whose trainer cannot start leaves nothing behind.
fn trainerLaunch(s: *State, io: Io, path_buffer: []u8) ?TrainerLaunch {
    const slot: *StartedTrainer = freeStartedSlot(&s.started) orelse {
        tell(s, .warn, "{d} trainers already run: stop one first", .{StartedTrainer.most});
        return null;
    };
    const trainer_path: []const u8 = trainerPath(io, path_buffer) orelse {
        tell(s, .err, "cannot find the lab's own folder", .{});
        return null;
    };
    if (!native_os.fileExists(io, trainer_path)) {
        tell(s, .err, "no trainer beside the lab: see the console", .{});
        log.err("no trainer at {s}: build it with `zig build geno-lab -Dplatform=windows`", .{trainer_path});
        return null;
    }
    const launch: TrainerLaunch = .{ .slot = slot, .trainer_path = trainer_path };
    return launch;
}

/// Starts the trainer on the run named `name`, in `folder`, watched in the launch's slot: `--run=<folder>`, as the
/// trainer takes its run (`tools/geno_trainer.zig`).
fn startTrainer(
    io: Io,
    launch: TrainerLaunch,
    name: []const u8,
    folder: []const u8,
) void {
    var run_argument_buffer: [1300]u8 = undefined;
    const run_argument: []const u8 = bufPrint(&run_argument_buffer, "--run={s}", .{folder}) catch return;
    const argv: [2][]const u8 = .{ launch.trainer_path, run_argument };
    log.info("{s}: starting {s} {s}", .{ name, launch.trainer_path, run_argument });
    launch.slot.run_name = .print("{s}", .{name});
    launch.slot.told_state = .idle;
    launch.slot.program.start(io, &argv);
}

/// Starts the form's run: its folder made, its `run.zon` written, and the trainer beside the lab started on it
/// (`startTrainer`). Each step is told on the console; a step that fails stops there, saying why.
fn startRun(s: *State, io: Io) void {
    const name: []const u8 = s.new_run.name();
    var trainer_path_buffer: [1200]u8 = undefined;
    const launch: TrainerLaunch = trainerLaunch(s, io, &trainer_path_buffer) orelse return;
    var folder_buffer: [1200]u8 = undefined;
    const folder: []const u8 = pathIn(runsFolderOf(s), name, &folder_buffer) orelse return;
    native_os.makeFolder(io, folder) catch |err| {
        tell(s, .err, "{s}: cannot make its folder: {s}", .{ name, @errorName(err) });
        return;
    };
    log.info("{s}: made {s}", .{ name, folder });

    // The parameters, written as the trainer will read them: the form's PPO settings as a `GenoRun`, which names its
    // learner.
    var text: Io.Writer.Allocating = .init(s.gpa);
    defer text.deinit();
    const new_run: lab.GenoRun = .fromPpoRun(s.new_run.run);
    new_run.write(&text.writer) catch {
        tell(s, .err, "{s}: out of memory writing run.zon", .{name});
        return;
    };
    text.writer.writeAll("\n") catch {
        tell(s, .err, "{s}: out of memory writing run.zon", .{name});
        return;
    };
    var run_file_buffer: [1300]u8 = undefined;
    const run_file_name: []const u8 = lab.RunFile.parameters.fileName();
    const run_file_path: []const u8 = pathIn(folder, run_file_name, &run_file_buffer) orelse return;
    native_os.writeWhole(s.gpa, io, run_file_path, text.written()) catch |err| {
        tell(s, .err, "{s}: cannot write run.zon: {s}", .{ name, @errorName(err) });
        return;
    };
    log.info("{s}: wrote {s}:\n{s}", .{ name, run_file_path, text.written() });

    startTrainer(io, launch, name, folder);
    s.new_run.is_open = false;
    // The new folder joins the list at once; its line fills in once the trainer writes its first status.
    refreshRuns(s, io);
}

/// Whether the run named `name`, watched in `watch`, can have its trainer started again: its status says it ended -
/// stopped, or finished - or says it trains from a trainer gone silent (`RunWatch.isSilent`, taken to have died), and
/// no trainer this lab started runs on it, which covers the seconds before a resumed trainer writes its first status.
/// A run with no status yet is never resumable: its trainer may still be starting.
fn isRunResumable(
    watch: *const RunWatch,
    started: []const StartedTrainer,
    name: []const u8,
    now_seconds: i64,
) bool {
    const status: lab.RunStatus = watch.status orelse return false;
    const has_ended: bool = status.state == .stopped or status.state == .finished;
    const has_ended_or_gone_silent: bool = has_ended or watch.isSilent(now_seconds);
    return has_ended_or_gone_silent and !isTrainerRunningOn(started, name);
}

/// Starts the trainer again on the run named `name` (`isRunResumable`), on its folder as it stands: the trainer
/// carries on from the folder's weights, log and judgements (`tools/geno_trainer.zig`), under its `run.zon` - which the
/// lab leaves alone, so a limit raised there by hand holds. Weights that no longer fit the run are the trainer's to
/// refuse, and it then leaves the folder untouched.
fn resumeRun(s: *State, io: Io, name: []const u8) void {
    // A slot must hold the whole name, or `isTrainerRunningOn` cannot match it and the run would offer "resume" again
    // while its trainer runs. The form's names always fit; a folder made by hand may not.
    const is_name_held: bool = name.len <= StartedTrainer.name_capacity;
    if (!is_name_held) {
        tell(s, .warn, "{s}: not resumed - its name is over {d} bytes", .{ name, StartedTrainer.name_capacity });
        return;
    }
    var trainer_path_buffer: [1200]u8 = undefined;
    const launch: TrainerLaunch = trainerLaunch(s, io, &trainer_path_buffer) orelse return;
    var folder_buffer: [1200]u8 = undefined;
    const folder: []const u8 = pathIn(runsFolderOf(s), name, &folder_buffer) orelse return;
    startTrainer(io, launch, name, folder);
    tell(s, .info, "{s}: resuming - its trainer carries on from its weights", .{name});
}

/// Asks the run named `name` to stop: its `stop` file written, which the trainer reads after its batch - it saves
/// its weights, log and status, and exits.
fn requestStop(s: *State, io: Io, name: []const u8) void {
    var folder_buffer: [1200]u8 = undefined;
    const folder: []const u8 = pathIn(runsFolderOf(s), name, &folder_buffer) orelse return;
    var stop_buffer: [1300]u8 = undefined;
    const stop_file_name: []const u8 = lab.RunFile.stop.fileName();
    const stop_path: []const u8 = pathIn(folder, stop_file_name, &stop_buffer) orelse return;
    native_os.writeWhole(s.gpa, io, stop_path, "") catch |err| {
        tell(s, .err, "{s}: cannot write its stop file: {s}", .{ name, @errorName(err) });
        return;
    };
    tell(s, .info, "{s}: asked to stop - it saves, then exits", .{name});
}

/// What a trainer's end means, from its exit code (`lab.TrainerExit`).
fn trainerEndMeaning(exit_code: u32) []const u8 {
    const exit: lab.TrainerExit = lab.TrainerExit.fromCode(exit_code) orelse return "ended from outside";
    return switch (exit) {
        .finished => "finished or stopped, everything saved",
        .refused => "refused the run - its reason is above",
        .failed => "failed - its reason is above",
    };
}

/// Tells the console each change of a started trainer's state: running, ended and how, or not started at all.
fn watchStartedTrainers(s: *State) void {
    for (&s.started) |*started| {
        const state: native_os.ChildState = started.program.currentState();
        if (state == started.told_state) {
            continue;
        }
        started.told_state = state;
        const name: []const u8 = started.run_name.slice();
        const exit_code: u32 = started.program.exit_code;
        switch (state) {
            .idle => {},
            .running => log.info("{s}: trainer running, process {d}", .{ name, started.program.process_id }),
            .closed, .failed => {
                const level_is_error: bool = state == .failed;
                const meaning: []const u8 = trainerEndMeaning(exit_code);
                if (level_is_error) {
                    tell(s, .err, "{s}: trainer exit {d}: {s}", .{ name, exit_code, meaning });
                } else {
                    tell(s, .info, "{s}: trainer exit {d}: {s}", .{ name, exit_code, meaning });
                }
            },
            .not_started => tell(s, .err, "{s}: the trainer did not start", .{name}),
        }
    }
}

/// The new training's form, while it is open: the run's name, every parameter of `PpoRun` (`ui.editStruct`), what
/// stops it from starting, and start, defaults and cancel.
fn drawNewRunWindow(s: *State, u: ui.Ui, io: Io) void {
    const form: *NewRunForm = &s.new_run;
    if (!form.is_open) {
        return;
    }
    const window_options: ui.WindowOpts = .{ .initial_pos = .{ 392, 4 }, .initial_size = .{ 420, 520 } };
    const window: ui.WindowHandle = u.window("new training", window_options) orelse return;
    defer window.close();
    _ = u.inputText("name", &form.name_buffer, &form.name_length, .{});
    _ = u.editStruct(&form.run);
    const problem: ?[]const u8 = newRunProblem(form, s.runs);
    if (problem) |why| {
        u.textColored(s.look.problem, "{s}", .{why});
    }
    if (u.button("start", .{})) {
        if (problem) |why| {
            tell(s, .warn, "not started: {s}", .{why});
        } else {
            startRun(s, io);
        }
    }
    u.sameLine(.{});
    if (u.button("defaults", .{})) {
        form.run = .{};
    }
    u.sameLine(.{});
    if (u.button("cancel", .{})) {
        form.is_open = false;
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.font = try z.loadFont(f, gpa, roboto_mono_ttf, 16);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cam = z.OrbitCamera.init(vec(0.0, 0.7, 0), 4.0);
    s.meshes = .{
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
    };
    s.transform = .{zm.identity()};

    // Geno, exactly as the training page and the trainer build him.
    s.document = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    s.robot = try mjcf.readRobot(gpa, &s.document);
    for (s.robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = geno.standing_armature;
        }
    }
    const physics_options: rbt.Options = geno.physicsOptions();
    s.imported = try rmj.build(gpa, &s.robot, physics_options);
    s.clip = try dance.Clip.fromBytes(gpa, dance_zclip);
    s.ghost = try rbt.Data.init(gpa, &s.imported.model);
    z.profiler.freeze();

    s.runs = &.{};
    s.runs_folder_length = 0;
    s.selected_run = null;
    s.shown = null;
    s.status = .print("", .{});
    s.look = .{};
    s.floor = .{};
    s.watches = &.{};
    s.curves_refresh = .{};
    s.curve_plot = .{};
    s.since_runs_read_seconds = 0;
    s.new_run = .{};
    s.started = @splat(.{});
    if (comptime !is_browser) {
        // An app has no `main` to receive an `Io`; the engine's services hold one for it.
        const io: Io = native_os.servicesIo();
        const runs_folder: []const u8 = runsFolder(io, &s.runs_folder_buffer) orelse "runs";
        s.runs_folder_length = runs_folder.len;
        refreshRuns(s, io);
        // The first run is shown at once: there is something to look at from the start.
        if (s.runs.len > 0) {
            showRun(s, io, 0);
        }
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    // Trainers keep running without the lab: their runs carry on, and a lab started later shows them.
    if (comptime !is_browser) {
        for (&s.started) |*started| {
            if (started.isRunning()) {
                log.info("{s}: keeps training after the lab closes - stop it with its stop file", .{
                    started.run_name.slice(),
                });
            }
            started.program.deinit();
        }
    }
    if (s.shown) |*shown| {
        unloadRun(gpa, shown);
    }
    for (s.watches) |*watch| {
        watch.deinit(gpa);
    }
    gpa.free(s.watches);
    native_os.freeFolderEntries(gpa, s.runs);
    s.ghost.deinit();
    s.clip.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.document.deinit();
    z.unloadMesh(gpa, s.meshes.cylinder);
    z.unloadMesh(gpa, s.meshes.cube);
    z.unloadMesh(gpa, s.meshes.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// A run's line under its name, in its colour: its state - "silent" for a trainer that has stopped writing
/// (`RunWatch.isSilent`) - its batch, and its latest time to failure.
fn drawRunLine(
    u: ui.Ui,
    watch: *const RunWatch,
    color: Color,
    now_seconds: i64,
) void {
    const status: lab.RunStatus = watch.status orelse {
        u.textColored(color, "  no status yet", .{});
        return;
    };
    const is_silent: bool = watch.isSilent(now_seconds);
    const state_name: []const u8 = if (is_silent) "silent" else @tagName(status.state);
    if (status.recent_seconds_to_failure) |seconds| {
        u.textColored(color, "  {s}, batch {d}, loses it every {d:.1} s", .{ state_name, status.batches, seconds });
    } else {
        u.textColored(color, "  {s}, batch {d}, no losses lately", .{ state_name, status.batches });
    }
    // The newest judgement, with its standard error, beside the servo judged on the same starts.
    const judged: JudgedRun = watch.judged orelse return;
    const servo_seconds: f32 = judged.servo.meanTimeToFailure();
    const judged_seconds: f32 = judged.newest.meanTimeToFailure();
    if (judged.newest.meanTimeToFailureError()) |error_seconds| {
        u.textColored(color, "  judged {d:.2} +- {d:.2} s, the servo {d:.2} s", .{
            judged_seconds,
            error_seconds,
            servo_seconds,
        });
    } else {
        u.textColored(color, "  judged: never lost on its starts (over {d:.1} s), the servo {d:.2} s", .{
            judged_seconds,
            servo_seconds,
        });
    }
}

/// The most training minutes any run has, and at least `least_minutes`: the curves' x range.
fn curvesMostMinutes(watches: []const RunWatch, least_minutes: f32) f32 {
    var most_minutes: f32 = least_minutes;
    for (watches) |watch| {
        const point_count: usize = watch.xs.items.len;
        const last_minutes: f32 = if (point_count > 0) watch.xs.items[point_count - 1] else 0;
        most_minutes = @max(most_minutes, last_minutes);
    }
    return most_minutes;
}

/// The runs' curves on one plot: the time to failure against training minutes, each run in its colour, with its
/// servo's time to failure dashed. Where the plot was clicked, in minutes and seconds.
fn drawCurves(
    u: ui.Ui,
    watches: []const RunWatch,
    look: Look,
    plot: CurvePlot,
) ?ui.PlotClick {
    var curves_buffer: [16]ui.PlotCurve = undefined;
    const curve_count: usize = @min(watches.len, curves_buffer.len);
    const most_minutes: f32 = curvesMostMinutes(watches, plot.least_minutes);
    for (watches[0..curve_count], 0..) |watch, index| {
        const servo_seconds: ?f32 = if (watch.status) |status| status.servo_seconds_to_failure else null;
        curves_buffer[index] = .{
            .xs = watch.xs.items,
            .ys = watch.ys.items,
            .color = look.runColor(index),
            .baseline = servo_seconds,
        };
    }
    return u.plotCurves("curves", curves_buffer[0..curve_count], .{
        .x_max = most_minutes,
        .y_min = plot.lowest_seconds,
        .y_max = plot.highest_seconds,
        .y_scale = .logarithmic,
        .y_marks = &plot.marks,
        .x_unit = " min",
        .y_unit = "s",
        .height = plot.height,
    });
}

/// How many tenfolds `seconds` is above the plot's lowest time to failure, held to the plot's range: its place up
/// the logarithmic axis.
fn decadesAboveLowest(seconds: f32, plot: CurvePlot) f32 {
    const kept_seconds: f32 = clamp(seconds, plot.lowest_seconds, plot.highest_seconds);
    const ratio_to_lowest: f32 = kept_seconds / plot.lowest_seconds;
    return log10(ratio_to_lowest);
}

/// A point of the curves: which run's, and which batch - and whether it is the run's last.
const CurvePick = struct {
    run_index: usize,
    batch: u64,
    /// The point's minute of training: the policy checkpoint nearest it is the one shown.
    training_minutes: f32,
    is_last: bool,
};

/// The curve point nearest a click, measured as the curves are drawn: minutes as a share of the x range, seconds
/// as a share of the logarithmic y range - so that a minute and a tenfold count alike. Null when no run has a point.
fn nearestCurvePoint(
    watches: []const RunWatch,
    click: ui.PlotClick,
    plot: CurvePlot,
) ?CurvePick {
    const most_minutes: f32 = curvesMostMinutes(watches, plot.least_minutes);
    const y_decades: f32 = decadesAboveLowest(plot.highest_seconds, plot);
    const click_decades: f32 = decadesAboveLowest(click.y, plot);
    var nearest: ?CurvePick = null;
    var nearest_squared_distance: f32 = 0;
    for (watches, 0..) |watch, run_index| {
        const points: []const lab.RunCurve.Point = watch.curve.points.items;
        for (watch.xs.items, watch.ys.items, 0..) |minutes, seconds, point_index| {
            const point_decades: f32 = decadesAboveLowest(seconds, plot);
            const x_share_apart: f32 = (minutes - click.x) / most_minutes;
            const y_share_apart: f32 = (point_decades - click_decades) / y_decades;
            const squared_distance: f32 = x_share_apart * x_share_apart + y_share_apart * y_share_apart;
            const is_nearer: bool = nearest == null or squared_distance < nearest_squared_distance;
            if (is_nearer) {
                nearest_squared_distance = squared_distance;
                nearest = .{
                    .run_index = run_index,
                    .batch = points[point_index].batch,
                    .training_minutes = points[point_index].training_minutes,
                    .is_last = point_index + 1 == points.len,
                };
            }
        }
    }
    return nearest;
}

/// Shows what a click on the curves picked: the run of the nearest point, with the policy checkpoint nearest its
/// minute - or the newest policy, for a run's last point (`policyNearest`).
fn showPickedPoint(s: *State, io: Io, pick: CurvePick) void {
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = s.runs[pick.run_index].name;
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    var policy_name_buffer: lab.RunFile.NameBuffer = undefined;
    const newest_name: []const u8 = lab.RunFile.policy_name;
    const picked_minute: u64 = @round(@max(pick.training_minutes, 0));
    const policy_name: []const u8 = if (pick.is_last)
        newest_name
    else
        policyNearest(s.gpa, io, run_folder, picked_minute, &policy_name_buffer) catch newest_name;
    showRunWith(s, io, pick.run_index, policy_name);
}

/// The panel: the runs, the shown run's batch, and reloading. Whether the mouse is the panel's.
fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    if (u.window("lab", .{ .initial_pos = .{ 4, 4 }, .initial_size = .{ 380, 470 } })) |window| {
        defer window.close();
        if (comptime is_browser) {
            u.text("run folders are listed natively", .{});
            return captured;
        }
        const io: Io = native_os.servicesIo();
        const now_seconds: i64 = native_os.wallClockSeconds(io);
        u.text("runs in {s}", .{runsFolderOf(s)});
        if (u.button("start new training", .{})) {
            openNewRunForm(s);
        }
        for (s.runs, s.watches, 0..) |run, *watch, index| {
            // Each row's own id: the rows' buttons share their labels.
            u.pushIdInt(@intCast(index));
            defer u.popId();
            const is_selected: bool = s.selected_run == index;
            if (u.selectable(run.name, is_selected, .{})) {
                showRun(s, io, index);
            }
            // A run's line starts with its button, where the panel's width cannot push it out of view: "stop" while
            // its trainer trains, "resume" once the run has ended or its trainer has gone silent - a silent trainer
            // reads no stop file.
            const state: ?lab.RunState = if (watch.status) |status| status.state else null;
            const says_training: bool = state == .training or state == .measuring_servo;
            const is_training: bool = says_training and !watch.isSilent(now_seconds);
            const is_resumable: bool = isRunResumable(watch, &s.started, run.name, now_seconds);
            if (is_training) {
                if (u.button("stop", .{})) {
                    requestStop(s, io, run.name);
                }
                u.sameLine(.{});
            } else if (is_resumable) {
                if (u.button("resume", .{})) {
                    resumeRun(s, io, run.name);
                }
                u.sameLine(.{});
            }
            drawRunLine(u, watch, s.look.runColor(index), now_seconds);
        }
        const click: ?ui.PlotClick = drawCurves(u, s.watches, s.look, s.curve_plot);
        if (click) |clicked| {
            if (nearestCurvePoint(s.watches, clicked, s.curve_plot)) |pick| {
                showPickedPoint(s, io, pick);
            }
        }
        if (s.runs.len == 0) {
            u.text("no runs yet", .{});
        }
        if (u.button("refresh", .{})) {
            refreshRuns(s, io);
        }
        u.sameLine(.{});
        if (u.button("reload policy", .{})) {
            reloadShownRun(s, io);
        }
        if (s.shown) |*shown| {
            u.text("{s}, {s}", .{ shown.parameters.task.motion.label(), shown.policyName() });
        }
        u.text("{s}", .{s.status.slice()});
    }
    if (comptime !is_browser) {
        drawNewRunWindow(s, u, native_os.servicesIo());
    }
    return captured;
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const dt: f32 = f.time.delta_time;
    const model: *const rbt.Model = &s.imported.model;
    // The runs' logs and statuses read again every few seconds (`CurvesRefresh`).
    if (comptime !is_browser) {
        s.since_runs_read_seconds += dt;
        const is_read_due: bool = s.since_runs_read_seconds >= s.curves_refresh.interval_seconds;
        if (is_read_due) {
            readRuns(s, native_os.servicesIo());
        }
        watchStartedTrainers(s);
    }
    // The character moves at real time whatever the frame rate, and never faster (`stepShowForFrame`).
    if (s.shown) |*shown| {
        const timestep: f32 = model.opt.timestep;
        stepShowForFrame(&shown.show, &shown.policy, &shown.clock, timestep, dt);
    }

    z.clearViewport(f, s.look.background);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    // The camera follows the character, whom the dance carries around the room: it orbits his root.
    if (s.shown) |*shown| {
        const root_body: usize = 1;
        const character: *const rbt.Data = &shown.show.fleet.data[0];
        const root_position: Vec = character.body_xpos[root_body];
        s.cam.target = yUpOf(root_position);
    }
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.5, .max_distance = 10.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.5);
    drawFloor(gl, &s.meshes.cube, &s.transform, s.floor, s.look.floor);
    if (s.shown) |*shown| {
        // The reference, where the character should be; then the character.
        const fleet: *track.Fleet = shown.show.fleet;
        const character_frame: usize = fleet.frame[0];
        const last_frame: usize = s.clip.frame_count - 1;
        const frame: usize = @min(character_frame, last_frame);
        @memcpy(s.ghost.pos, s.clip.pose(frame));
        s.ghost.stage = .stale;
        rbt.kinematics(model, &s.ghost);
        drawRobot(gl, model, &s.meshes, &s.transform, &s.ghost, s.look.reference);
        drawRobot(gl, model, &s.meshes, &s.transform, &fleet.data[0], s.look.character);
    }
    z.endMode3D(gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - the training lab",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
