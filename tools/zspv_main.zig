//! tools/zspv_main.zig - the `zspv` command line: argument parsing and the subcommands.
//!
//! `zspv.zig` reads and writes SPIR-V and `zspv_rewrite.zig` rewrites it. This file is the only
//! one that needs both, which is what keeps the two libraries from importing each other (the
//! `import-cycle` lint rule). `build.zig` roots the `zspv` executable here.
//!
//! Usage:
//!   zspv <input.spv> <output.spv>                                  # identity round-trip
//!   zspv --check <input.spv>                                       # parse + verify
//!   zspv --dump <input.spv>                                        # instruction dump
//!   zspv --rewrite-samplers <in.spv> <out.spv>                     # GL-path sampler rewrite
//!   zspv --rewrite-samplers-wgsl [--sampler-group=N] <in.spv> <out.spv>

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const zspv = @import("zspv.zig");
const rewriter = @import("zspv_rewrite.zig");
const Module = zspv.Module;
const read = zspv.read;
const write = zspv.write;

fn printUsage(io: std.Io) void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
    stderr_w.interface.print(
        \\usage: zspv <input.spv> <output.spv>                     # identity round-trip
        \\       zspv --check <input.spv>                          # parse + verify, no output
        \\       zspv --dump <input.spv>                           # instruction dump
        \\       zspv --rewrite-samplers <in.spv> <out.spv>        # S1.4.5b combined-sampler rewrite (GLSL/GL path)
        \\       zspv --rewrite-samplers-wgsl [--sampler-group=N] <in.spv> <out.spv>
        \\           # split-sampler rewrite (WGSL/wgpu path).  --sampler-group sets
        \\           # the @group(N) for synthesized samplers (default 0).
        \\
    , .{}) catch {}; // lint:off catch-suppression: stderr write, best-effort
    stderr_w.interface.flush() catch {}; // lint:off catch-suppression: stderr flush, best-effort
}

fn cmdCheck(
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_w.interface.print(
        "ok: parsed {d} instructions, header.bound={d}\n",
        .{ mod.instructions.len, mod.header[2] },
    );
    try stdout_w.interface.flush();
}

fn cmdDump(
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_w.interface.print(
        "SPIR-V version=0x{x:0>8} generator=0x{x:0>8} bound={d} schema={d}\n",
        .{ mod.header[0], mod.header[1], mod.header[2], mod.header[3] },
    );
    try stdout_w.interface.print(
        "{d} instructions:\n",
        .{mod.instructions.len},
    );
    for (mod.instructions, 0..) |instr, i| {
        try stdout_w.interface.print(
            "  [{d:>5}] op={d:>3} wc={d:>2} operands={any}\n",
            .{ i, instr.opcode, instr.operands.len + 1, instr.operands },
        );
    }
    try stdout_w.interface.flush();
}

/// Read SPIR-V from `in_path`, run the S1.4.5b sampler rewrite,
/// write the result to `out_path`.  Phase 2 of the SPIR-V tool work.
/// See `tools/zspv_rewrite.zig` for the rewrite logic.
fn cmdRewriteSamplers(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    var mod: Module = try read(arena, bytes);

    try rewriter.rewriteSamplers(arena, &mod);

    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = alloc_writer.written() });
}

/// WGSL-shape variant of cmdRewriteSamplers - produces SPIR-V with
/// SEPARATE texture and sampler bindings and OpSampledImage combine
/// sites.  This is the shape that survives translation to WGSL via
/// `tools/spv2wgsl.zig`.  Once Phase F of the wgpu migration ships
/// (GL deletion), this becomes the only sampler-rewrite mode and
/// `cmdRewriteSamplers` above goes away.  See
/// `src/notes/webgpu-migration-plan.md` section 3 for context.
fn cmdRewriteSamplersWgsl(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
    sampler_group: u32,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    var mod: Module = try read(arena, bytes);

    try rewriter.rewriteSamplersWgsl(arena, &mod, sampler_group);

    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = alloc_writer.written() });
}

fn cmdRoundtrip(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    // Write to an Allocating writer first, then to disk.  Lets us
    // validate the round-trip is byte-identical with the input
    // before committing.
    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);
    const out_bytes: []const u8 = alloc_writer.written();

    // Sanity check: in Phase 1 (no transformation), output must
    // match input byte-for-byte.  If this ever fails, the
    // reader/writer is dropping or duplicating data.
    if (!eql(u8, bytes, out_bytes)) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_w.interface.print(
            "error: round-trip mismatch: {d} input bytes -> {d} output bytes\n",
            .{ bytes.len, out_bytes.len },
        );
        try stderr_w.interface.flush();
        std.process.exit(1);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out_bytes });
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    // Collect argv into a flat list.  Zig 0.16's args API requires
    // going through an Iterator (cross-platform: Windows args are
    // WTF-16 internally, need conversion to UTF-8).
    var args_list: ArrayList([]u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    if (args.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }

    // Subcommand dispatch
    if (eql(u8, args[1], "--check")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdCheck(io, gpa, args[2]);
    } else if (eql(u8, args[1], "--dump")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdDump(io, gpa, args[2]);
    } else if (eql(u8, args[1], "--rewrite-samplers")) {
        if (args.len != 4) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRewriteSamplers(io, gpa, args[2], args[3]);
    } else if (eql(u8, args[1], "--rewrite-samplers-wgsl")) {
        // Optional `--sampler-group=N` flag: sets the
        // DescriptorSet decoration (== @group(N) in WGSL) for the
        // synthesized texture+sampler variables.  Default 0 - the
        // WebGPU convention is "group 0 = per-frame globals," so
        // shaders bundled into a pipeline alongside a VS UBO at
        // group 0 binding 0 want their samplers in a different
        // group (typically 1, the per-material group).  The engine
        // shapes shader uses this; future engine shaders that share
        // a pipeline with a VS UBO will too.
        var sampler_group: u32 = 0;
        var pos_args: [2][]const u8 = .{ "", "" };
        var pos_count: usize = 0;
        for (args[2..]) |a| {
            if (startsWith(u8, a, "--sampler-group=")) {
                const v: []const u8 = a["--sampler-group=".len..];
                sampler_group = std.fmt.parseInt(u32, v, 10) catch {
                    printUsage(io);
                    std.process.exit(2);
                };
            } else {
                if (pos_count >= 2) {
                    printUsage(io);
                    std.process.exit(2);
                }
                pos_args[pos_count] = a;
                pos_count += 1;
            }
        }
        if (pos_count != 2) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRewriteSamplersWgsl(io, gpa, pos_args[0], pos_args[1], sampler_group);
    } else {
        // Default: identity round-trip.
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRoundtrip(io, gpa, args[1], args[2]);
    }
}
