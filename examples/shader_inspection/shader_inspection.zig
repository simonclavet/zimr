// examples/shader_inspection/shader_inspection.zig
//
// Shader inspection: paste WGSL, see the bind-group layout it expects. This is
// the read-out side of the custom-pipeline API — `z.material.reflectWgslBindings`
// scans the source for every `@group(N) @binding(M) var ...` declaration and
// classifies each as uniform / storage / texture / sampler / storage_texture.
// The same data feeds `z.material.bindGroupLayout`, so what you see here is what
// a pipeline built from this shader would bind.
//
// Build:      zig build wgpu-shader-inspection
// Standalone: zig build wgpu-shader-inspection-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const bufPrint = std.fmt.bufPrint;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// A representative custom-pipeline shader: bindings across three groups and one
// of every kind the reflector understands. (Entry points are stubs — only the
// declarations matter for inspection.)
const demo_wgsl =
    \\struct Camera { view: mat4x4<f32>, proj: mat4x4<f32> };
    \\
    \\// scene-wide group 0
    \\@group(0) @binding(0) var<uniform> camera: Camera;
    \\@group(0) @binding(1) var<storage, read> joints: array<mat4x4<f32>>;
    \\
    \\// material group 1
    \\@group(1) @binding(0) var albedo: texture_2d<f32>;
    \\@group(1) @binding(1) var albedo_sampler: sampler;
    \\@group(1) @binding(2) var layers: texture_2d_array<f32>;
    \\
    \\// compute output group 2
    \\@group(2) @binding(0) var out_image: texture_storage_2d<rgba8unorm, write>;
    \\
    \\@vertex fn vs_main() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }
    \\@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }
;

const State = struct {
    font: z.Font,
    bindings: []z.material.WgslBinding,
};

fn kindColor(kind: z.material.WgslBinding.Kind) zm.Color {
    return switch (kind) {
        .uniform => .{ .r = 90, .g = 200, .b = 230, .a = 255 },
        .storage => .{ .r = 120, .g = 220, .b = 150, .a = 255 },
        .texture => .{ .r = 240, .g = 160, .b = 90, .a = 255 },
        .sampler => .{ .r = 235, .g = 215, .b = 110, .a = 255 },
        .storage_texture => .{ .r = 220, .g = 130, .b = 230, .a = 255 },
        .unknown => .{ .r = 150, .g = 150, .b = 160, .a = 255 },
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const bindings: []z.material.WgslBinding = try z.material.reflectWgslBindings(gpa, demo_wgsl);
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .bindings = bindings,
    };
}

fn update(f: *z.Frame, s: *State) void {
    f.gl.text(.{ 28, 28 }, "shader inspection", .{ .size = 30, .color = co.palette.ink, .font = &s.font });
    f.gl.text(
        .{ 28, 66 },
        "bind-group layout reflected from WGSL",
        .{ .size = 16, .color = co.palette.ink_dim, .font = &s.font },
    );

    var buf: [256]u8 = undefined;
    var y: f32 = 120;
    for (s.bindings) |b| {
        const line: []const u8 = bufPrint(
            &buf,
            "@group({d}) @binding({d})  {s:<16} {s} : {s}",
            .{ b.group, b.binding, b.kindLabel(), b.name, b.detail },
        ) catch continue;
        f.gl.text(.{ 28, y }, line, .{ .size = 19, .color = kindColor(b.kind), .font = &s.font });
        y += 34;
    }

    var foot: [64]u8 = undefined;
    const summary: []const u8 = bufPrint(&foot, "{d} bindings", .{s.bindings.len}) catch "";
    f.gl.text(.{ 28, y + 12 }, summary, .{ .size = 16, .color = co.palette.ink_dim, .font = &s.font });

    z.endDrawing(f.gl);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.material.freeWgslBindings(gpa, s.bindings);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - shader inspection",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.039, .g = 0.047, .b = 0.071, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
