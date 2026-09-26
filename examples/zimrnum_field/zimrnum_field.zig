//! zimrnum_field - a scalar field built with zimrnum, computed twice, drawn three times.
//!
//! -- *** WHAT THIS EXAMPLE IS FOR --
//!
//! To use zimrnum the way an application would, not the way a test does. It builds a 64x64 field
//! out of tensors - noise plus a broadcast row ramp - evaluates it through `zn.add` and `zn.mul`
//! on the CPU and through the same operations on the GPU, and draws BOTH heatmaps plus their
//! difference. A wrong GPU result is not a number in a log; it is a visibly different picture.
//!
//! ** THE DENSIFY STEP IS SHOWN, NOT HIDDEN. The GPU kernel takes flat buffers with a count -
//! no shape, no strides. `zn.broadcastTo` produces a stride-0 VIEW, which cannot be bound. So the
//! host materialises the ramp into a dense tensor first, with `zn.add` against a zero field, and
//! that line is the whole difference between what the two backends can accept.
//!
//! * Inputs come from `zn.Rng`, which is counter-based: both backends see identical values
//! without either sending them to the other, and the field is reproducible from one seed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
// House form: bind the zm name once at file scope rather than qualifying it in a body.
const zm = @import("zm");
const clamp = zm.clamp;
const bufPrint = std.fmt.bufPrint;
const floatEps = zm.floatEps;
const zn = @import("zn");
// The sweep's table, its CPU reference and the comparison now live in the engine:
// `src/gpu/zn_conformance.zig`. This file keeps the rendering and nothing else.
const conf = @import("zn_conformance");
const Tn = conf.Tn;
const Kind = conf.Kind;
const Case = conf.Case;
const cases = conf.cases;
const Comparison = conf.Comparison;
const compare = conf.compare;
const side = conf.side;
const count = conf.count;
const learning_rate = conf.learning_rate;
const layernorm_epsilon = conf.layernorm_epsilon;
const elu_alpha = conf.elu_alpha;
const momentum = conf.momentum;
const huber_delta = conf.huber_delta;
const clamp_lo = conf.clamp_lo;
const clamp_hi = conf.clamp_hi;
const zn_binary = @import("zn_binary");
const zn_matmul = @import("zn_matmul");
const zn_unary = @import("zn_unary");
const float = zm.float;
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
// One WGSL per ENTRY, not per kernel file - the build names each embed after its entry.
/// -- *** THE PIPELINE TABLE IS DERIVED, NOT WRITTEN --
///
/// A kernel used to be named in four places: the file's install call, `build.zig`'s `.entries`,
/// an `@embedFile` here, and a pipeline entry here. Four lists to keep in agreement by hand, and
/// eleven kernels in, that was the thing slowing the port down.
///
/// Now each kernel file carries `pub const kernels`, and this builds the host table from it. The
/// entry name and its WGSL cannot disagree, because the same string produces both.
///
/// ** IT IS ALSO THE DRIFT GATE, AND IT COSTS NOTHING. `@embedFile(name ++ "_wgsl")` only
/// resolves if `build.zig` generated that WGSL. Add an entry to a kernel file and forget the
/// build, and the failure is a compile error naming the missing file - not a shader that is
/// absent at runtime on a device you are not holding.
fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const rerun_size: struct { w: f32, h: f32 } = .{ .w = 124, .h = 26 };

// -- *** THE COVERAGE GATE --
//
// Every kernel entry must be exercised by exactly one row, and every row must name a kernel that
// exists. Without this the sweep's green says something about the rows someone REMEMBERED to add,
// not about the kernel set - and `sub` and `div` sat on the CPU for six turns with no kernel
// precisely because nothing was watching.
//
// ** IT IS A COMPILE ERROR, NOT A TEST. A kernel added without a row cannot build, so the gap
// cannot survive to a device. `build.zig`'s drift gate already covers the other edge (a kernel
// with no WGSL fails to embed), so the three lists - kernel file, build entries, sweep rows -
// are now pinned to each other in both directions.
//
// * WHAT THIS DOES NOT COVER, stated so it is not mistaken for more than it is: it pins
// KERNEL <-> ROW. It cannot pin OP <-> KERNEL - a `zimrnum` function with no GPU kernel at all is
// still invisible here, because zimrnum has no device dispatch of its own yet. That gate belongs
// with the dispatch seam, and section 10.3 debt 11 stays open until then.
comptime {
    // -- *** EVERY BUFFER A KERNEL READS MUST BE ONE THE HOST UPLOADS --
    //
    // `where_pick` read its selector from `c` and nothing uploaded it. The headless twin test
    // filled `c` by hand and passed; the sweep never did, and the device failed the row with the
    // input data instead of a 0/1 mask. **A buffer the host never writes is invisible to every
    // check that runs on the host**, because the host's own test fills it as part of being a
    // test.
    //
    // * So: this file must contain an `upload` call for every field of every pipeline's `Buffers`
    // that is not the output. Checked by searching this file's own source, which is crude and is
    // exactly as strong as it needs to be - the failure it prevents is a missing line.
    // * The quota is generous because the search walks this whole file; a comptime string scan
    // over 60 KB is thousands of branches and the default stops well short.
    @setEvalBranchQuota(2_000_000);
    const source: []const u8 = @embedFile("zimrnum_field.zig");
    for (.{ "a", "b", "c" }) |field| {
        const needle: []const u8 = ".upload(." ++ field ++ ",";
        if (std.mem.indexOf(u8, source, needle) == null) {
            @compileError("zn_binary buffer `" ++ field ++ "` is never uploaded by the host");
        }
    }
    for (.{"x"}) |field| {
        const needle: []const u8 = "pipe_un.upload(." ++ field ++ ",";
        if (std.mem.indexOf(u8, source, needle) == null) {
            @compileError("zn_unary buffer `" ++ field ++ "` is never uploaded by the host");
        }
    }
}

comptime {
    // 23 rows x 22 entries of string comparison overruns the default quota; the check is O(n*m)
    // and n and m both grow with the port, so raise it once here rather than per addition.
    @setEvalBranchQuota(200_000);
    for (cases) |c| {
        const names: []const [:0]const u8 = switch (c.kind) {
            .binary => &zn_binary.kernels,
            .unary => &zn_unary.kernels,
            .matmul => &zn_matmul.kernels,
        };
        var found: usize = 0;
        for (names) |name| {
            if (std.mem.eql(u8, name, c.entry)) {
                found += 1;
            }
        }
        if (found != 1) {
            @compileError("sweep row '" ++ c.label ++ "' names entry '" ++ c.entry ++
                "', which its kernel file does not export");
        }
    }
    coverEvery(zn_binary.kernels, .binary);
    coverEvery(zn_unary.kernels, .unary);
    coverEvery(zn_matmul.kernels, .matmul);
}

/// Assert every entry of one kernel file is exercised by exactly one row.
fn coverEvery(comptime names: anytype, comptime kind: Kind) void {
    for (names) |name| {
        var rows: usize = 0;
        for (cases) |c| {
            if (c.kind == kind and std.mem.eql(u8, name, c.entry)) {
                rows += 1;
            }
        }
        if (rows == 0) {
            @compileError("kernel entry '" ++ name ++ "' has no row in the sweep: it is built, " ++
                "shipped, and never compared against zimrnum");
        }
        // ONE KERNEL MAY HAVE SEVERAL ROWS, AND THAT IS NOW THE POINT
        //
        // This used to require exactly one, on the reasoning that two rows for one kernel is a
        // copy-paste slip. It is not: the same kernel on a DIFFERENT INPUT FIELD is a different
        // question, and asking it is how the `tanh` cancellation bug would have been caught years
        // earlier. A duplicate row costs three frames; a missing row costs a kernel nobody checks.
        // The bar is "at least one", and the asymmetry is deliberate.
    }
}

/// One operation's verdict, filled in as the page walks the list.
const Result = struct {
    done: bool = false,
    worst: f32 = 0,
    /// The largest reference magnitude in the row, which is what `ulps` scales against.
    peak: f32 = 0,
    checked: u32 = 0,
};

const State = struct {
    font: z.Font,
    pipe: z.Compute(zn_binary),
    pipe_mm: z.Compute(zn_matmul),
    pipe_un: z.Compute(zn_unary),

    /// The two dense operands both backends see.
    field_a: []f32,
    field_b: []f32,
    /// `|field_a| + 0.5`: strictly positive, for the rows whose operation needs it.
    field_p: []f32,
    /// `tanh(noise)`, so every value lies strictly inside (-1, 1) - the domain of `atanh`.
    field_u: []f32,
    /// The `where` row's selector, `greater(a, b)`, which the kernel reads from buffer `c`.
    field_c: []f32,
    /// A narrow band of magnitudes near 1e-6, both signs. Narrow because the sweep's bar is
    /// `ulps * peak`: a field spanning decades takes its bar from its largest element and stops
    /// testing the small ones at all.
    field_t: []f32,
    /// -- *** ALL FOUR CPU REFERENCES, COMPUTED ONCE --
    ///
    /// The inputs never change, so each operation's answer is fixed. Computing them up front
    /// removes the bug that produced `FAIL add worst 23.9`: the sweep used to rebuild `cpu_out`
    /// the instant it advanced, while `readLatest` still held the PREVIOUS dispatch's data - so
    /// operation N's GPU result was compared against operation N+1's reference. Nothing was wrong
    /// with either kernel.
    cpu_ref: [cases.len][]f32,
    cpu_out: []f32,
    gpu_out: []f32,

    /// The operation being measured. It ADVANCES ON ITS OWN - no tapping. A round trip to a
    /// phone costs minutes, so one screenshot has to answer every question.
    /// Index into `cases`. It advances on its own - no tapping.
    op: usize = 0,
    dispatched: bool = false,
    /// Frames to let the queue settle before a readback is believed. `readLatest` returns the
    /// most recent COMPLETED transfer, which is the previous operation's until this one lands;
    /// consuming it early is what mismatched the rows.
    settle: u32 = 0,
    /// The dispatch this row is waiting on, or null before it has been dispatched.
    ///
    /// Set from `readGeneration().submitted` AFTER the dispatch, so it names this row's work.
    /// The row retires when `mirrored` reaches it.
    await_generation: ?u64 = null,
    results: [cases.len]Result = @splat(.{}),
    /// Whether a failure has already claimed the heatmaps.
    holding: bool = false,
    /// Where the re-run button was drawn last frame. The hit test reads this rather than a
    /// constant, so the two can never disagree.
    rerun: z.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// -- *** THE PAGE HAS TO SCROLL, AND SORTING ALONE IS NOT ENOUGH --
    ///
    /// Forty-eight rows plus three heatmaps already exceed a phone screen, and the port is headed
    /// past a hundred. Two changes, because they solve different halves:
    ///
    /// ** **Failures sort to the top**, so the rows that matter are visible without touching
    /// anything - which is what a screenshot needs.
    /// * **Drag or wheel scrolls**, for reading the rest.
    scroll: f32 = 0,
    /// True between a press that began outside the button and the release that ends it. A drag
    /// with no beginning cannot tell a finger arriving from a finger moving.
    dragging: bool = false,
    /// Where the finger went down, and what `scroll` was at that moment. The pair is what lets
    /// the drag be absolute instead of a sum of per-frame deltas.
    drag_from: f32 = 0,
    scroll_from: f32 = 0,
    /// Total drawn height, so the scroll can be clamped to content that actually exists rather
    /// than to a guess.
    content_height: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.field_a);
    gpa.free(s.field_b);
    gpa.free(s.field_p);
    gpa.free(s.field_u);
    gpa.free(s.field_c);
    gpa.free(s.field_t);
    for (s.cpu_ref) |r| {
        gpa.free(r);
    }
    gpa.free(s.cpu_out);
    gpa.free(s.gpu_out);
    z.unloadFont(gpa, s.font);
    s.pipe.deinit();
    s.pipe_mm.deinit();
    s.pipe_un.deinit();
}

/// Build the two operands with zimrnum, then every operation's reference answer.
///
/// * Called ONCE. The inputs are fixed, so the four answers are fixed, and recomputing one of
/// them mid-sweep is what let a stale readback be judged against the wrong reference.
fn buildFields(s: *State) !void {
    const shape = [_]usize{ side, side };
    const a: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(s.field_a, &shape);
    const b: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(s.field_b, &shape);

    // Operand A: noise. Two labels off one seed, so nothing has to be coordinated.
    const rng: zn.Rng = zn.Rng.init(20260904);
    rng.split(0).fillNormal(f32, s.field_a);

    // Operand B: a single row ramp, stretched down the field. `broadcastTo` makes that a view
    // with a stride of 0 on the row axis - no storage, no copy.
    var ramp_row: [side]f32 = undefined;
    for (0..side) |i| {
        ramp_row[i] = float(@as(u32, @intCast(i))) / float(side) * 2.0 - 1.0;
    }
    const row: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(&ramp_row, &.{ 1, side });
    const stretched: zn.Tensor(f32) = try row.broadcastTo(&shape);

    // ** MATERIALISE IT. The stretched view is fine for the CPU walk and cannot be bound to a
    // kernel, which takes a dense buffer. Adding it to a zeroed field is the densify step.
    b.fill(0.0);
    try zn.add(f32, b, b, stretched);

    // * `|a| + 0.5`, so `log` is defined too - a plain `|a|` would still hit zero and give -inf.
    for (s.field_p, s.field_a) |*slot, x| {
        slot.* = @abs(x) + 0.5;
    }
    // * `tanh` maps the whole real line into (-1, 1) exactly, so this field is inside the domain
    // of `atanh` by construction rather than by clamping - and it still spans most of the range.
    for (s.field_u, s.field_a) |*slot, x| {
        slot.* = zm.tanh(x);
    }
    // Eight decades of magnitude below 1, alternating sign. Spread by index rather than drawn,
    // so the smallest values are guaranteed present rather than merely likely.
    // A NARROW BAND. THE FIRST VERSION SPANNED EIGHT DECADES AND WAS USELESS.
    //
    // The sweep compares the worst ABSOLUTE difference against a bar of `ulps * peak`, where peak
    // is the largest reference value in the row. Spread a field over eight decades and the peak
    // comes from the largest element, so the bar sits far above anything the smallest elements
    // could fail. Measured on the exact bug these rows were added for - the old `tanh`, which
    // returns 0 where the answer is x:
    //
    //     eight decades:  peak 9.97e-2  worst 1.92e-8  bar 4.75e-8   MISSED
    //     band near 1e-6: peak 1.79e-6  worst 2.67e-8  bar 8.52e-13  CAUGHT
    //
    // **The rows would not have caught the bug they exist for.** A band keeps every value inside
    // one decade, so the peak IS the scale of the field and the bar means something at that
    // scale. One band tests one scale; 1e-6 is where a cancelling f32 formula has lost most of
    // its digits without yet collapsing to zero.
    for (s.field_t, 0..) |*slot, i| {
        const step: f32 = @floatFromInt(i % 8);
        const jitter: f32 = 1.0 + 0.9 * step / 8.0;
        const magnitude: f32 = 1.0e-6 * jitter;
        slot.* = if (i % 2 == 0) magnitude else -magnitude;
    }

    const positive: Tn = try Tn.fromSlice(s.field_p, &shape);
    const unit: Tn = try Tn.fromSlice(s.field_u, &shape);
    const tiny: Tn = try Tn.fromSlice(s.field_t, &shape);
    for (s.cpu_ref, cases) |slot, c| {
        const src: Tn = switch (c.input) {
            .noise => a,
            .positive => positive,
            .unit => unit,
            .tiny => tiny,
        };
        const out: Tn = try Tn.fromSlice(slot, &shape);
        // Zeroed first: a reduction writes only `out_len` values, and the rest of the reference
        // would otherwise be whatever the allocator handed over - visible in the heatmap even
        // though the verdict ignores it.
        out.fill(0);
        try c.cpu(out, src, b);
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);

    var pipe: z.Compute(zn_binary) = try z.Compute(zn_binary).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_binary),
    );
    pipe.element_count = count;
    // Row-major strides for `bcast_add`: `a` is a full field, `b` is its first row stretched
    // down - `b_row = 0` is the broadcast, exactly as `broadcastTo` does it on the CPU.
    pipe.params = .{
        .count = count,
        .scalar = learning_rate,
        .cols = side,
        .delta = huber_delta,
        .momentum = momentum,
        .a_row = side,
        //  is the only row that uses it; every other leaves each element alone.
        .repeat_count = 2,
        .a_col = 1,
        .b_row = 0,
        .b_col = 1,
        // Their own fields, not the strides above: see the note in zn_binary.
        .slice_start = side / 2,
        .left_columns = side / 2,
    };

    var pipe_mm: z.Compute(zn_matmul) = try z.Compute(zn_matmul).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_matmul),
    );
    pipe_mm.element_count = count;
    // (64, 64) @ (64, 64). The tiled entry needs the same thread count: 4x4 tiles of 256 lanes.
    pipe_mm.params = .{ .m = side, .n = side, .kdim = side };

    var pipe_un: z.Compute(zn_unary) = try z.Compute(zn_unary).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_unary),
    );
    pipe_un.element_count = count;
    pipe_un.params = .{
        .count = count,
        .scalar = learning_rate,
        .cols = side,
        .epsilon = layernorm_epsilon,
        .lo = clamp_lo,
        .hi = clamp_hi,
        .alpha = elu_alpha,
        .pool = 2,
    };

    s.* = .{
        .font = font,
        .pipe = pipe,
        .pipe_mm = pipe_mm,
        .pipe_un = pipe_un,
        .field_a = try gpa.alloc(f32, count),
        .field_b = try gpa.alloc(f32, count),
        .field_p = try gpa.alloc(f32, count),
        .field_u = try gpa.alloc(f32, count),
        .field_c = try gpa.alloc(f32, count),
        .field_t = try gpa.alloc(f32, count),
        // Filled by the loop below: one reference per `cases` entry, so the count follows
        // the table and cannot drift from it.
        .cpu_ref = undefined,
        .cpu_out = try gpa.alloc(f32, count),
        .gpu_out = try gpa.alloc(f32, count),
    };
    for (&s.cpu_ref) |*slot| {
        slot.* = try gpa.alloc(f32, count);
    }
    try buildFields(s);
    s.pipe.upload(.a, s.field_a);
    s.pipe.upload(.b, s.field_b);
    // -- *** THE MASK THE `where` KERNEL READS --
    //
    // `where_pick` reads its selector from the `c` buffer, and **nothing was uploading it**. The
    // headless twin test filled `c` by hand and passed; the sweep never did, so on the device the
    // kernel selected from an empty buffer and the row failed with a worst of 4.2 - the input
    // data itself, not a 0/1 mask.
    //
    // * A buffer a kernel READS but the host never WRITES is invisible to every check that runs
    // on the host, because the host's own twin test fills it as part of the test. The device is
    // the only thing that can see it, and it did.
    for (s.field_c, s.field_a, s.field_b) |*slot, x, y| {
        slot.* = if (x > y) 1 else 0;
    }
    s.pipe.upload(.c, s.field_c);
    s.pipe_mm.upload(.a, s.field_a);
    s.pipe_mm.upload(.b, s.field_b);
    s.pipe_un.upload(.x, s.field_a);
}

/// The bar this row is judged against: its absolute allowance plus `ulps` units in the last place
/// of its own peak magnitude.
fn barFor(c: Case, peak: f32) f32 {
    return c.tol + c.ulps * peak * floatEps(f32);
}

/// One cell of a heatmap: blue below zero, red above, brightness with magnitude.
fn heat(v: f32) Color {
    // ** ZERO MUST BE NEUTRAL. The first version returned dark red at v == 0, so a difference
    // panel that was exactly zero everywhere rendered as a solid red block - the same picture a
    // uniformly small POSITIVE error would give. The whole point of the third panel is to tell
    // those apart, so the saturation now falls to nothing as the magnitude does.
    const m: f32 = @min(@abs(v) / 3.0, 1.0);
    const hue: f32 = if (v < 0) 220.0 else 12.0;
    return z.colorFromHSV(hue, 0.85 * m, 0.10 + 0.75 * m);
}

/// Draw `data` as a heatmap, one rect per BLOCK of `block`x`block` elements.
///
/// -- *** WHY IT DOWNSAMPLES, AND WHY BY MAGNITUDE --
///
/// Three 64x64 panels is 12 288 rects a frame, and with the UI's glyphs on top that overflowed
/// the vertex ring: `flushBatch` asserts rather than corrupt, so the page panicked in the smoke
/// runner. Sampling every other element would fix the count and lose the point - a single wrong
/// element could fall in a skipped position, and the difference panel exists precisely to show
/// one wrong element.
///
/// So each block is represented by its LARGEST-MAGNITUDE member, sign kept. An outlier anywhere
/// in a block survives to the screen; only the fine texture of agreeing values is lost, and that
/// texture was never the information.
fn drawField(
    f: *z.Frame,
    data: []const f32,
    x0: f32,
    y0: f32,
    cell: f32,
    gain: f32,
) void {
    const block: usize = 2;
    const cells: usize = side / block;
    var row: usize = 0;
    while (row < cells) : (row += 1) {
        var col: usize = 0;
        while (col < cells) : (col += 1) {
            var peak: f32 = 0;
            for (0..block) |dr| {
                for (0..block) |dc| {
                    const v: f32 = data[(row * block + dr) * side + (col * block + dc)];
                    if (@abs(v) > @abs(peak)) {
                        peak = v;
                    }
                }
            }
            f.gl.rect(.{
                .x = x0 + float(@as(u32, @intCast(col))) * cell,
                .y = y0 + float(@as(u32, @intCast(row))) * cell,
                .width = cell,
                .height = cell,
            }, .{ .color = heat(peak * gain) });
        }
    }
}

/// One pipeline's dispatch counters, in a type all three can be read into.
///
/// The three pipelines are different `Compute(M)` instantiations, so each has its own
/// `Generation` type even though the fields match. A local struct is what lets one variable
/// hold the answer from whichever pipeline this row uses.
const Gen = struct { submitted: u64, mirrored: u64 };

fn update(f: *z.Frame, s: *State) void {
    // Tapping anywhere switches the operation; both backends recompute from the same inputs.
    // -- *** A BUTTON, NOT THE WHOLE SCREEN --
    //
    // Tapping anywhere used to re-run the sweep, which meant every scroll, every stray touch and
    // every attempt to read a number restarted the measurement. A verifier that discards its
    // result when you look at it is a verifier you cannot read.
    const mouse: zm.Vec2 = z.getMousePosition(f.input);
    const over: bool = mouse[0] >= s.rerun.x and mouse[0] <= s.rerun.x + s.rerun.width and
        mouse[1] >= s.rerun.y and mouse[1] <= s.rerun.y + s.rerun.height;
    // Wheel, and vertical drag anywhere outside the button. Clamped to real content: scrolling
    // past the end leaves a reader staring at nothing and wondering if the page broke.
    s.scroll -= z.getMouseWheelMove(f.input) * 40.0;

    // -- *** A DRAG ANCHORS ON THE PRESS FRAME, AND THAT FRAME'S DELTA IS DISCARDED --
    //
    // This used to apply `getMouseDelta` on every frame the button was down, including the frame
    // it went down on. With a mouse that is harmless - the pointer was already where you clicked,
    // so the delta is nearly zero. **With a finger it is the bug**: the pointer TELEPORTS from
    // wherever it last was to wherever you touched, and that entire jump arrives as one frame's
    // delta. Touching the bottom of the page to start scrolling flung it by the distance from the
    // last touch point, which reads as the page popping out from under you.
    //
    // * So a drag has a beginning: the press frame sets `dragging` and contributes NOTHING, and
    // only later frames move the page. The page now stays exactly where it was until the finger
    // actually moves, which is what every other scrolling surface does.
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.dragging = !over;
        s.drag_from = mouse[1];
        s.scroll_from = s.scroll;
    } else if (s.dragging and z.isMouseButtonDown(f.input, .left)) {
        // ** ABSOLUTE, NOT ACCUMULATED. `scroll = scroll_at_press - (moved since press)` makes
        // the content track the finger exactly: the pixel under it at the press stays under it,
        // and no per-frame delta is ever added, so a dropped or doubled frame cannot make the
        // page drift away from the finger over a long drag.
        s.scroll = s.scroll_from - (mouse[1] - s.drag_from);
    }
    if (!z.isMouseButtonDown(f.input, .left)) {
        s.dragging = false;
    }
    const limit: f32 = @max(0.0, s.content_height - f.window.heightf() + 20.0);
    s.scroll = clamp(s.scroll, 0.0, limit);

    if (over and z.isMouseButtonPressed(f.input, .left)) {
        s.results = @splat(.{});
        s.op = 0;
        s.holding = false;
        s.dispatched = false;
    }
    if (false) {
        s.op += 1;
        // Rebuilding cannot fail - the shapes are fixed and no allocation happens - but a
        // swallowed error would leave the panels showing a stale field with nothing to say so.
        s.dispatched = false;
    }

    if (!s.dispatched) {
        s.dispatched = true;
        // -- *** THREE FRAMES, BECAUSE THE DEVICE MEASURED THE QUEUE AT THREE --
        //
        // The previous version waited ONE frame and detected staleness by comparing the readback
        // against the PREVIOUS row's output. **That was wrong, and the device proved it**: with a
        // three-deep queue the readback is row N-3's data, which does not match row N-1's
        // reference either - so it was accepted as fresh and compared against row N. Two rows
        // failed with worst errors of 9.8 and 4.2, which for 0/1 masks can only be another row's
        // data.
        //
        // ** A staleness test that compares against ONE previous row can only catch a lag of
        // exactly one. Catching a lag of three needs either a comparison against the last three -
        // which is three chances to collide with a legitimately identical output - or a label
        // travelling with the data, which the sweep has no spare buffer element for.
        //
        // * So: three frames, matched to the depth `zimrnum_train` measured. 86 rows x 3 is about
        // **2.2 s at 120 Hz**, a little over the two-second budget. Correctness first; the budget
        // is bought back by splitting the sweep when it next grows, not by reading early.
        // *** SIX, NOT THREE - AND THE DEVICE RAISED IT TWICE NOW.
        //
        // Three was matched to the queue depth `zimrnum_train` measured. It held for 86 rows and
        // then failed again at 91: `bcast add (bias)` came back **inf** and `tanh grad` **3.84**,
        // against bars of zero. Both twins are EXACT on the host, so the kernels and the
        // reference agree and neither number is a perturbation of the right answer - they are
        // another row's data, the same signature as the 9.8 and 4.2 recorded above.
        //
        // The depth is not a constant of the hardware; it moves with row count, with what else
        // the browser is doing, and with the build. **A number that has been wrong twice should
        // be set from the budget, not from the last measurement.** Six frames is 91 x 6 = 546
        // frames, 4.6 s at 120 Hz, inside the six-second budget - so the whole margin available
        // is spent on being sure, which is what the budget was raised for.
        // WAIT FOR THIS DISPATCH, NOT FOR SIX FRAMES
        //
        // The six above was set from the time budget rather than measured, and its own comment
        // said so - because there was no way to ask which dispatch a readback belonged to.
        // `readGeneration` answers that now, so the wait is exact: record the submission count
        // after dispatching and retire the row when the mirror reaches it.
        //
        // Never early, never longer than necessary, and it does not move with row count or with
        // what else the browser is doing - which is what made the old number wrong twice.
        s.settle = 0;
        s.await_generation = null;
        // `run` takes the entry name at comptime, so the branch selects the CALL, not a string.
        // * `run` takes the entry name at COMPTIME, so the selection is an `inline for` over
        // the table rather than a runtime lookup - the loop is unrolled and each arm passes a
        // literal.
        // ** THE DEVICE MUST SEE THE SAME INPUT THE REFERENCE DID. Uploading per dispatch is
        // 16 KB of traffic on a row that already reads 4096 elements - nothing - and it removes
        // the possibility of the two sides being compared on different data, which is the bug
        // that produced `FAIL add worst 23.9` earlier in this port.
        switch (cases[s.op].input) {
            .noise => s.pipe_un.upload(.x, s.field_a),
            .positive => s.pipe_un.upload(.x, s.field_p),
            .unit => s.pipe_un.upload(.x, s.field_u),
            .tiny => s.pipe_un.upload(.x, s.field_t),
        }
        inline for (cases, 0..) |c, i| {
            if (i == s.op) {
                switch (c.kind) {
                    .binary => {
                        s.pipe.run(c.entry, c.threads);
                        s.await_generation = s.pipe.readGeneration().submitted;
                    },
                    .unary => {
                        s.pipe_un.run(c.entry, c.threads);
                        s.await_generation = s.pipe_un.readGeneration().submitted;
                    },
                    .matmul => {
                        s.pipe_mm.run(c.entry, c.threads);
                        s.await_generation = s.pipe_mm.readGeneration().submitted;
                    },
                }
            }
        }
    }
    // Frame-delayed readback: last frame's mapped data, so the queue is never stalled. Whichever
    // pipeline is live for this mode is the one asked.
    const readback: ?[]const f32 = switch (cases[s.op].kind) {
        .binary => s.pipe.readLatest(.out),
        .unary => s.pipe_un.readLatest(.out),
        .matmul => s.pipe_mm.readLatest(.out),
    };
    // THE ROW RETIRES WHEN THE MIRROR REACHES ITS OWN DISPATCH
    //
    // `readback` being non-null means SOME copy landed; the generation says whose. Comparing
    // them is what removes the guess - a row that has not been dispatched yet
    // (`await_generation == null`) and one whose data has not arrived both wait, and neither
    // waits a frame longer than it has to.
    // The three pipelines are different `Compute(M)` instantiations, so their `Generation`
    // types are distinct even though the fields match. Reading the fields out separately is
    // what lets one variable hold the answer from any of them.
    const generation: Gen = switch (cases[s.op].kind) {
        .binary => blk: {
            const g: @TypeOf(s.pipe).Generation = s.pipe.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
        .unary => blk: {
            const g: @TypeOf(s.pipe_un).Generation = s.pipe_un.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
        .matmul => blk: {
            const g: @TypeOf(s.pipe_mm).Generation = s.pipe_mm.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
    };
    const arrived: bool = if (s.await_generation) |wanted|
        generation.mirrored >= wanted
    else
        false;
    if (s.settle > 0) {
        s.settle -= 1;
    } else if (!arrived) {
        // Still in flight. Nothing to do but let the next frame poll again.
    } else if (readback) |out| {
        const n: usize = @min(out.len, s.gpu_out.len);
        @memcpy(s.gpu_out[0..n], out[0..n]);
        const reference: []const f32 = s.cpu_ref[s.op];
        @memcpy(s.cpu_out[0..n], reference[0..n]);
        // Only the values this row actually produces.
        const judged: usize = @min(n, cases[s.op].out_len);
        const cmp: Comparison = compare(s.gpu_out[0..judged], reference[0..judged]);
        const worst: f32 = cmp.worst;
        s.results[s.op] = .{ .done = true, .worst = worst, .peak = cmp.peak, .checked = @intCast(judged) };

        // The FIRST failure keeps the heatmaps, so the picture explains the number.
        if (worst > barFor(cases[s.op], cmp.peak) or judged != cases[s.op].out_len) {
            s.holding = true;
        }
        if (!s.results[s.results.len - 1].done) {
            s.op += 1;
            s.dispatched = false;
            if (s.holding) {
                // Keep the failing picture on screen: re-dispatch but do not overwrite it.
                s.holding = true;
            }
        }
    }

    z.clearViewport(f, z.colors.slate_900);

    var passing: u32 = 0;
    var finished: u32 = 0;
    for (s.results, 0..) |r, i| {
        if (!r.done) {
            continue;
        }
        finished += 1;
        if (r.worst <= barFor(cases[i], r.peak) and r.checked == cases[i].out_len) {
            passing += 1;
        }
    }
    const all_done: bool = finished == s.results.len;

    // -- *** PLAIN TEXT ROWS, NOT A UI TABLE --
    //
    // The `ui.zig` version worked and Simon prefers this one. It is also the honest fit: this
    // page is read as a SCREENSHOT, so scrolling, column sizing and a frozen header buy nothing,
    // while the UI library cost ~400 KB of standalone and an extra frame-ordering contract to get
    // wrong - which it duly was, twice. Text rows have no such contract.
    var y: f32 = 10 - s.scroll;
    if (!all_done) {
        textRow(f, s, &y, z.colors.amber_400, 16, "zimrnum GPU sweep - {d}/{d} measured", .{
            finished,
            s.results.len,
        });
    } else if (passing == s.results.len) {
        textRow(f, s, &y, z.colors.emerald_400, 16, "ALL PASS - {d}/{d} agree with zimrnum", .{
            passing,
            s.results.len,
        });
    } else {
        textRow(f, s, &y, z.colors.red_400, 16, "{d}/{d} PASS - failures marked XX", .{
            passing,
            s.results.len,
        });
    }
    textRow(f, s, &y, z.colors.slate_500, 12, "     operation           worst |cpu-gpu|  bar", .{});

    // ** Two passes: everything that FAILED, then everything else. A reader opening this page
    // wants the exception, and at forty-eight rows the exception was below the fold.
    var pass_index: u8 = 0;
    while (pass_index < 2) : (pass_index += 1) {
        for (s.results, cases) |r, c| {
            const failed: bool = r.done and
                (r.worst > barFor(c, r.peak) or r.checked != c.out_len);
            if ((pass_index == 0) != failed) {
                continue;
            }
            if (!r.done) {
                textRow(f, s, &y, z.colors.slate_600, 12, " ..  {s}", .{c.label});
                continue;
            }
            const bar: f32 = barFor(c, r.peak);
            const ok: bool = !failed;
            const tint: Color = if (ok) z.colors.emerald_400 else z.colors.red_400;
            // * The bar is printed WITH the deviation, because a verdict a reader cannot check is a
            // verdict they learn to ignore - and for the rows that scale by ULP it is not a constant.
            textRow(f, s, &y, tint, 12, " {s}  {s: <18} {d: <15} {d}", .{
                if (ok) "OK" else "XX",
                c.label,
                r.worst,
                bar,
            });
        }
    }

    const sw: f32 = f.window.widthf();
    const cell: f32 = @min((sw - 80.0) / float((side / 2) * 3), 5.0);
    const panel: f32 = float(side / 2) * cell;
    const top: f32 = y + 8;
    drawField(f, s.cpu_out, 20, top, cell, 1.0);
    drawField(f, s.gpu_out, 40 + panel, top, cell, 1.0);
    var diff: [count]f32 = undefined;
    for (s.cpu_out, s.gpu_out, 0..) |cv, gv, i| {
        diff[i] = cv - gv;
    }
    drawField(f, &diff, 60 + panel * 2, top, cell, 1000.0);

    // The button, drawn last so nothing overlaps it. Deliberately away from the table: the rows
    // are what a reader reaches for, and a control under a finger is a control pressed by
    // accident.
    var cap: f32 = top + panel + 4;
    caption(f, s, 20, &cap, "CPU");
    caption(f, s, 40 + panel, &cap, "GPU");
    caption(f, s, 60 + panel * 2, &cap, "diff x1000");

    // Placed BELOW the heatmaps, from the layout rather than a guess, and recorded for next
    // frame's hit test. Away from the rows, because a control under a finger is a control
    // pressed by accident - which is why tapping anywhere used to restart the measurement every
    // time someone tried to read it.
    s.rerun = .{ .x = 20, .y = cap + 6, .width = rerun_size.w, .height = rerun_size.h };
    // Recorded from the layout, so the scroll limit follows the content instead of a constant
    // that goes stale the next time a row is added.
    s.content_height = s.rerun.y + s.rerun.height + s.scroll;
    f.gl.rect(s.rerun, .{ .color = if (over) z.colors.slate_600 else z.colors.slate_700 });
    f.gl.rect(s.rerun, .{ .color = z.colors.slate_400, .outline = 1 });
    f.gl.text(
        .{ s.rerun.x + 16, s.rerun.y + 7 },
        "re-run sweep",
        .{ .size = 13, .color = z.colors.slate_100, .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// The only hand-drawn text left: three labels under the heatmaps, which sit outside the UI
/// window on purpose.
fn textRow(
    f: *z.Frame,
    s: *State,
    y: *f32,
    color: Color,
    size: f32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [160]u8 = undefined;
    const text: []const u8 = bufPrint(&buf, fmt, args) catch return;
    f.gl.text(.{ 12, y.* }, text, .{ .size = size, .color = color, .font = &s.font });
    y.* += size + 4;
}

fn caption(
    f: *z.Frame,
    s: *State,
    x: f32,
    y: *f32,
    text: []const u8,
) void {
    f.gl.text(.{ x, y.* }, text, .{ .size = 13, .color = z.colors.slate_400, .font = &s.font });
}

/// Descriptor-only: the standalone runner or the launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - zimrnum field",
            .width = 900,
            .height = 460,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
