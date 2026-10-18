//! examples/geno_lab - the training lab: a run's network, shown on Geno.
//!
//! A training run is a folder (`tools/geno_trainer.zig`): its parameters in `run.zon`, its newest weights in
//! `weights`, beside them its checkpoints, its log and its status. The lab lists the run folders in `runs`, beside
//! its own executable. A run chosen there is loaded - its parameters, then its weights into a network built to them
//! - and shown: Geno on the floor following the dance, each decision the policy's mean action through DReCon's
//! filter (`ppo_track.Trainer.Show`), with the reference beside him. While the trainer runs, "reload" reads the
//! newest weights again into the same network.
//!
//! Run folders are files by path, which a page does not have: in a web build the list is left out.

const std = @import("std");
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
const native_os = z.native_os;
const zn_mlp = @import("zn_mlp");

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

const Trainer = ppo_track.Trainer(zn_mlp);
const is_browser: bool = z.host.is_browser;

const dance_zclip = @embedFile("geno_dance_zclip");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// The lab's colours: the background, the character, the reference, the floor.
const Look = struct {
    background: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 },
    character: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 },
    reference: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 },
    floor: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 },
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

/// Every kernel of `M`, with the WGSL the build made of it.
fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

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

/// A run's parameters, from the `run.zon` in `run_folder`.
fn readRunParameters(gpa: Allocator, io: Io, run_folder: []const u8) !geno.PpoRun {
    var path_buffer: [1200]u8 = undefined;
    const run_file_name: []const u8 = geno.RunFile.parameters.fileName();
    const run_path: []const u8 = pathIn(run_folder, run_file_name, &path_buffer) orelse return error.NameTooLong;
    const source: []u8 = try native_os.readWhole(gpa, io, run_path, geno.RunFile.most_bytes) orelse
        return error.NoRunFile;
    defer gpa.free(source);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const terminated_source: [:0]const u8 = try arena.dupeSentinel(u8, source, 0);
    var failure: geno.PpoRun.ParseFailure = .{ .description = "" };
    return geno.PpoRun.parse(gpa, arena, terminated_source, &failure);
}

/// Reads the weights file `weights_name` in `run_folder` - the newest weights, or a checkpoint - into `trainer`: the
/// batch they were trained to.
fn readWeights(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    weights_name: []const u8,
    trainer: *Trainer,
) !u64 {
    var path_buffer: [1200]u8 = undefined;
    const weights_file_name: []const u8 = weights_name;
    const weights_path: []const u8 = pathIn(run_folder, weights_file_name, &path_buffer) orelse
        return error.NameTooLong;
    const weights_bytes: []u8 = try native_os.readWhole(gpa, io, weights_path, geno.RunFile.most_bytes) orelse
        return error.NoWeights;
    defer gpa.free(weights_bytes);
    try trainer.importWeights(weights_bytes);
    return trainer.iterations;
}

/// The weights file in `run_folder` nearest batch `batch`: the checkpoint whose batch is nearest, when the
/// folder keeps any; else the newest weights. Written into `name_buffer`.
fn weightsNearest(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    batch: u64,
    name_buffer: []u8,
) ![]const u8 {
    const newest_name: []const u8 = geno.RunFile.weights.fileName();
    const entries: []native_os.FolderEntry = try native_os.listFolder(gpa, io, run_folder);
    defer native_os.freeFolderEntries(gpa, entries);
    var nearest_batch: ?u64 = null;
    var nearest_batch_distance: u64 = 0;
    for (entries) |entry| {
        const checkpoint_batch: u64 = geno.RunFile.checkpointBatch(entry.name) orelse continue;
        const is_after: bool = checkpoint_batch > batch;
        const batch_distance: u64 = if (is_after) checkpoint_batch - batch else batch - checkpoint_batch;
        const is_nearer: bool = nearest_batch == null or batch_distance < nearest_batch_distance;
        if (is_nearer) {
            nearest_batch_distance = batch_distance;
            nearest_batch = checkpoint_batch;
        }
    }
    const chosen_batch: u64 = nearest_batch orelse return newest_name;
    return geno.RunFile.checkpointName(chosen_batch, name_buffer);
}

// ---- The runs watched ----

/// A run as the lab watches it: its learning curve, read from its log as it grows, the points the plot draws, and
/// its status as last read.
const RunWatch = struct {
    curve: geno.RunCurve = .{},
    /// The curve's points as the plot takes them: training minutes, and the time to failure - a window in which
    /// nothing failed drawn at the plot's top.
    xs: ArrayList(f32) = .empty,
    ys: ArrayList(f32) = .empty,
    status: ?geno.RunStatus = null,
    /// The run's save interval (`PpoRun.save_minutes`), read from its `run.zon` once: what silence is judged by.
    save_minutes: ?f32 = null,

    fn deinit(watch: *RunWatch, gpa: Allocator) void {
        watch.curve.deinit(gpa);
        watch.xs.deinit(gpa);
        watch.ys.deinit(gpa);
    }
};

/// Reads the run in `run_folder` again: its log's new lines into its curve, the plot's points from the curve, and
/// its status. A file that cannot be read leaves what was read before.
fn readRunWatch(
    gpa: Allocator,
    io: Io,
    run_folder: []const u8,
    physics_steps_per_second: f32,
    plot: CurvePlot,
    watch: *RunWatch,
) !void {
    var path_buffer: [1200]u8 = undefined;
    const log_name: []const u8 = geno.RunFile.log.fileName();
    const log_path: []const u8 = pathIn(run_folder, log_name, &path_buffer) orelse return;
    if (try native_os.readWhole(gpa, io, log_path, geno.RunFile.most_bytes)) |log_text| {
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
    const status_name: []const u8 = geno.RunFile.status.fileName();
    const status_path: []const u8 = pathIn(run_folder, status_name, &path_buffer) orelse return;
    const status_text: []u8 = try native_os.readWhole(gpa, io, status_path, geno.RunFile.most_bytes) orelse return;
    defer gpa.free(status_text);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const terminated_status: [:0]const u8 = try arena.dupeSentinel(u8, status_text, 0);
    if (geno.RunStatus.parse(gpa, arena, terminated_status)) |status| {
        watch.status = status;
    }
    if (watch.save_minutes == null) {
        const parameters: ?geno.PpoRun = readRunParameters(gpa, io, run_folder) catch null;
        watch.save_minutes = if (parameters) |known| known.save_minutes else null;
    }
}

// ---- The run shown ----

/// A run loaded and shown: a network built to its parameters, holding its weights, and one character living what
/// the network does - and the run's folder name, its own copy, so that reloading reads the same run whatever the
/// list holds by then.
const ShownRun = struct {
    parameters: geno.PpoRun,
    trainer: *Trainer,
    show: Trainer.Show,
    name_buffer: [256]u8,
    name_length: usize,

    fn name(self: *const ShownRun) []const u8 {
        return self.name_buffer[0..self.name_length];
    }
};

/// Loads the run in `run_folder`: its parameters, a network built to them - one character's worth, since how many
/// trained does not change the network - the weights file `weights_name`, and a show of one character.
fn loadRun(
    gpa: Allocator,
    io: Io,
    pipe: *z.Compute(zn_mlp),
    imported: *rmj.Imported,
    clip: *const dance.Clip,
    run_folder: []const u8,
    weights_name: []const u8,
) !ShownRun {
    const parameters: geno.PpoRun = try readRunParameters(gpa, io, run_folder);
    if (parameters.problem() != null) {
        return error.RunOutOfRange;
    }
    var options: ppo_track.Options = parameters.recipe.options(parameters.motion);
    options.envs = 1;
    options.horizon = 8;
    const clips = [_]*const dance.Clip{clip};
    const trainer: *Trainer = try .init(gpa, pipe, &imported.model, imported.names, &clips, options);
    errdefer trainer.deinit();
    _ = try readWeights(gpa, io, run_folder, weights_name, trainer);
    const show: Trainer.Show = try trainer.startShow(gpa, 1, ppo_track.evaluation_seed);
    const folder_name: []const u8 = std.fs.path.basename(run_folder);
    var shown: ShownRun = .{
        .parameters = parameters,
        .trainer = trainer,
        .show = show,
        .name_buffer = undefined,
        .name_length = @min(folder_name.len, 256),
    };
    @memcpy(shown.name_buffer[0..shown.name_length], folder_name[0..shown.name_length]);
    return shown;
}

/// Releases a shown run: its show, then its network.
fn unloadRun(gpa: Allocator, shown: *ShownRun) void {
    Trainer.endShow(gpa, &shown.show);
    shown.trainer.deinit();
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

/// Steps the show through the frame's whole physics steps (`ppo_track.showStepsForFrame`): one at 60 frames a
/// second, the motion even at any frame rate.
fn stepShowForFrame(
    trainer: *Trainer,
    show: *Trainer.Show,
    pacing: ppo_track.ShowPacing,
    timestep: f32,
    dt: f32,
) void {
    const steps_to_take: u32 = ppo_track.showStepsForFrame(dt, timestep, pacing);
    for (0..steps_to_take) |_| {
        trainer.stepShow(show);
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
    pipe: z.Compute(zn_mlp),
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
    pacing: ppo_track.ShowPacing,
};

fn runsFolderOf(s: *const State) []const u8 {
    return s.runs_folder_buffer[0..s.runs_folder_length];
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
        s.status = .print("cannot list {s}: {s}", .{ runsFolderOf(s), @errorName(err) });
        break :list &.{};
    };
    s.watches = s.gpa.alloc(RunWatch, s.runs.len) catch &.{};
    for (s.watches) |*watch| {
        watch.* = .{};
    }
    readRuns(s, io);
    s.selected_run = null;
    const shown: *const ShownRun = if (s.shown) |*loaded| loaded else return;
    for (s.runs, 0..) |run, index| {
        if (eql(u8, run.name, shown.name())) {
            s.selected_run = index;
        }
    }
}

/// Shows the run at `index` of the list with the weights file `weights_name`, in place of the one shown.
fn showRunWith(
    s: *State,
    io: Io,
    index: usize,
    weights_name: []const u8,
) void {
    if (s.shown) |*previous| {
        unloadRun(s.gpa, previous);
        s.shown = null;
    }
    s.selected_run = index;
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = s.runs[index].name;
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    const shown: ShownRun = loadRun(s.gpa, io, &s.pipe, &s.imported, &s.clip, run_folder, weights_name) catch |err| {
        s.status = .print("{s}: {s}", .{ name, @errorName(err) });
        return;
    };
    s.shown = shown;
    s.status = .print("{s}: {s}, batch {d}", .{ name, weights_name, shown.trainer.iterations });
}

/// Shows the run at `index` of the list with its newest weights, in place of the one shown.
fn showRun(s: *State, io: Io, index: usize) void {
    showRunWith(s, io, index, geno.RunFile.weights.fileName());
}

/// Reads the shown run's newest weights again, into the same network.
fn reloadShownRun(s: *State, io: Io) void {
    const shown: *ShownRun = if (s.shown) |*loaded| loaded else return;
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = shown.name();
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    const newest_name: []const u8 = geno.RunFile.weights.fileName();
    const batch: u64 = readWeights(s.gpa, io, run_folder, newest_name, shown.trainer) catch |err| {
        s.status = .print("{s}: {s}", .{ name, @errorName(err) });
        return;
    };
    s.status = .print("{s}: batch {d}", .{ name, batch });
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
    s.pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    z.profiler.freeze();

    s.runs = &.{};
    s.runs_folder_length = 0;
    s.selected_run = null;
    s.shown = null;
    s.status = .print("", .{});
    s.look = .{};
    s.floor = .{};
    s.pacing = .{};
    s.watches = &.{};
    s.curves_refresh = .{};
    s.curve_plot = .{};
    s.since_runs_read_seconds = 0;
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
    if (s.shown) |*shown| {
        unloadRun(gpa, shown);
    }
    for (s.watches) |*watch| {
        watch.deinit(gpa);
    }
    gpa.free(s.watches);
    native_os.freeFolderEntries(gpa, s.runs);
    s.pipe.deinit();
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
/// (`RunStatus.isSilent`) - its batch, and its latest time to failure.
fn drawRunLine(
    u: ui.Ui,
    watch: *const RunWatch,
    color: Color,
    now_seconds: i64,
) void {
    const status: geno.RunStatus = watch.status orelse {
        u.textColored(color, "  no status yet", .{});
        return;
    };
    // Silence is judged by the run's save interval; a run whose `run.zon` could not be read is not judged.
    const is_silent: bool = if (watch.save_minutes) |save_minutes|
        status.isSilent(now_seconds, save_minutes)
    else
        false;
    const state_name: []const u8 = if (is_silent) "silent" else @tagName(status.state);
    if (status.recent_seconds_to_failure) |seconds| {
        u.textColored(color, "  {s}, batch {d}, loses it every {d:.1} s", .{ state_name, status.batches, seconds });
    } else {
        u.textColored(color, "  {s}, batch {d}, no losses lately", .{ state_name, status.batches });
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
        const points: []const geno.RunCurve.Point = watch.curve.points.items;
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
                    .is_last = point_index + 1 == points.len,
                };
            }
        }
    }
    return nearest;
}

/// Shows what a click on the curves picked: the run of the nearest point, with the checkpoint nearest its batch -
/// or the newest weights, for a run's last point (`weightsNearest`).
fn showPickedPoint(s: *State, io: Io, pick: CurvePick) void {
    var path_buffer: [1200]u8 = undefined;
    const name: []const u8 = s.runs[pick.run_index].name;
    const run_folder: []const u8 = pathIn(runsFolderOf(s), name, &path_buffer) orelse return;
    var weights_name_buffer: [64]u8 = undefined;
    const newest_name: []const u8 = geno.RunFile.weights.fileName();
    const weights_name: []const u8 = if (pick.is_last)
        newest_name
    else
        weightsNearest(s.gpa, io, run_folder, pick.batch, &weights_name_buffer) catch newest_name;
    showRunWith(s, io, pick.run_index, weights_name);
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
        for (s.runs, s.watches, 0..) |run, *watch, index| {
            const is_selected: bool = s.selected_run == index;
            if (u.selectable(run.name, is_selected, .{})) {
                showRun(s, io, index);
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
        if (u.button("reload weights", .{})) {
            reloadShownRun(s, io);
        }
        if (s.shown) |*shown| {
            u.text("{s}, batch {d}", .{ shown.parameters.motion.label(), shown.trainer.iterations });
        }
        u.text("{s}", .{s.status.slice()});
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
    }
    // The character moves evenly, whatever the frame rate (`stepShowForFrame`).
    if (s.shown) |*shown| {
        const timestep: f32 = model.opt.timestep;
        stepShowForFrame(shown.trainer, &shown.show, s.pacing, timestep, dt);
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
