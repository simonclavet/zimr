//! depth_cue - a quick depth-visualisation preview on the way to
//! `shaders_depth_rendering`. A field of cubes over a ground grid, each shaded
//! grayscale by its distance from the camera (near = bright, far = dark), with a
//! slowly orbiting camera so the gradient sweeps across the field.
//!
//! This is the per-OBJECT depth cue: the CPU computes each cube's camera distance
//! and picks a gray tint. The faithful per-PIXEL depth-as-color port (rendering
//! linear depth into a colour target and displaying it - the same "depth-in-red"
//! technique the PBR shadow path already uses) is the next step. Built on the
//! immediate-mode 3D API (beginMode3D / drawCube / drawGrid) - no custom pipeline.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const clamp = zm.clamp;
const float = zm.float;
const Camera3D = zm.Camera3D;
const Color = zm.Color;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const grid_n: i32 = 9; // 9x9 field of cubes
const spacing: f32 = 1.7;
const cube_y: f32 = 0.45;
const near_d: f32 = 4.0; // distance mapped to full bright
const far_d: f32 = 26.0; // distance mapped to full dark

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// Grayscale colour for a world point, dark with distance from `cam`.
/// near_d -> white (1.0), far_d -> near-black (0.0), linear between.
fn grayByDistance(px: f32, py: f32, pz: f32, cam: Camera3D) Color {
    const dx: f32 = px - cam.position[0];
    const dy: f32 = py - cam.position[1];
    const dz: f32 = pz - cam.position[2];
    const dist: f32 = @sqrt(dx * dx + dy * dy + dz * dz);

    var t: f32 = (dist - near_d) / (far_d - near_d);
    t = clamp(t, 0.0, 1.0);
    const bright: f32 = 1.0 - t; // near = bright

    // 12 -> floor keeps the far end visible rather than pure black.
    const g_i: i32 = @round(12.0 + bright * 243.0);
    const g: u8 = @intCast(g_i);
    return .{ .r = g, .g = g, .b = g, .a = 255 };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;

    z.clearViewport(f, common.palette.bg);

    // Camera slowly orbits the field so the depth gradient sweeps across it.
    const orbit: f32 = t * 0.25;
    const radius: f32 = 17.0;
    const height: f32 = 11.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(orbit) * radius, height, @sin(orbit) * radius),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
        .projection = 0,
    };

    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);

    const half: f32 = float(grid_n - 1) * 0.5;
    var i: i32 = 0;
    while (i < grid_n) : (i += 1) {
        var j: i32 = 0;
        while (j < grid_n) : (j += 1) {
            const px: f32 = (float(i) - half) * spacing;
            const pz: f32 = (float(j) - half) * spacing;
            const col: Color = grayByDistance(px, cube_y, pz, cam);
            z.drawCube(f.gl, pointVec(px, cube_y, pz), .{
                .size = vec(0.85, 0.85, 0.85),
                .color = col,
            });
        }
    }

    z.endMode3D(f.gl);

    common.caption(
        f.gl,
        s.font,
        "Depth cue - cubes shaded by camera distance (near bright, far dark)",
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - depth cue",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
