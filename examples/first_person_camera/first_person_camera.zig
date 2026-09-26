//! first_person_camera - port of the GL `first_person_camera`:
//! WASD + drag-look across procedurally generated terrain.
//!
//! What it demonstrates on the wgpu path:
//!   - `genImageChecked` -> `genMeshHeightmap` (ported to `draw3d` for this
//!     example - CPU arrays, no GL upload tail) -> `loadModelFromMesh` ->
//!     `drawModel` with per-draw tint.
//!   - `updateCamera(.first_person)`: WASD walks, left-drag looks, wheel
//!     scales speed.
//! The GL original gated controls behind pointer-lock (`disableCursor`);
//! the wgpu bridge has no pointer-lock wiring and the demos are
//! phone-first, so drag-look is always live here instead - same controls,
//! no capture dance.  The checked image gives the terrain its blocky
//! two-tone height steps, exactly like the original.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const heightmap_size: i32 = 32;

const State = struct {
    font: z.Font,
    terrain: z.Model,
    camera: Camera3D = .{
        .position = pointVec(8, 5, 8),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 60,
        .projection = 0,
    },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.terrain);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Checked image as the heightmap: alternating tiles -> blocky
    // two-height terrain (the original's look).
    const heightmap: z.Image = try z.genImageChecked(
        gpa,
        heightmap_size,
        heightmap_size,
        4,
        4,
        c.slate_700,
        c.slate_500,
    );
    defer z.unloadImage(gpa, heightmap);

    const terrain_mesh: z.Mesh = try z.genMeshHeightmap(gpa, heightmap, vec(32, 4, 32));
    const terrain: z.Model = try z.loadModelFromMesh(f.gl, gpa, terrain_mesh);
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .terrain = terrain,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // WASD walks, left-drag looks, wheel scales speed - all inside
    // updateCamera(.first_person).
    z.updateCamera(f.gl, &s.camera, .first_person);

    z.clearViewport(f, c.sky_950);
    z.beginMode3D(f.gl, s.camera);

    // Terrain centered on the origin (genMeshHeightmap puts its origin at
    // the heightmap's (0,0) corner; offset by -size/2 to center it).
    z.drawModel(f.gl, s.terrain, pointVec(-16, 0, -16), 1.0, c.emerald_400);

    // Reference grid above the terrain + two landmarks to look at.
    z.drawGrid(f.gl, 20, 1.0);
    z.drawCube(f.gl, pointVec(0, 5, 0), .{ .size = vec(1, 1, 1), .color = c.amber_500 });
    z.drawSphere(f.gl, pointVec(5, 6, 0), .{ .radius = 0.5, .rings = 8, .slices = 16, .color = c.rose_500 });

    z.endMode3D(f.gl);

    f.gl.text(
        .{ 16, 14 },
        "first-person camera",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    var hud_buf: [96]u8 = undefined;
    const hud: []const u8 = bufPrint(&hud_buf, "pos ({d:.1}, {d:.1}, {d:.1})", .{
        s.camera.position[0],
        s.camera.position[1],
        s.camera.position[2],
    }) catch "pos (?)";
    f.gl.text(.{ 16, 42 }, hud, .{ .size = 16, .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 }, .font = &s.font });
    common.caption(f.gl, s.font, "WASD: walk - drag: look - wheel: speed - heightmap terrain via genMeshHeightmap");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - first-person camera",
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
