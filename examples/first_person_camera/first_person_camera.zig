//! first_person_camera - port of the GL `first_person_camera`:
//! WASD + mouse look across procedurally generated terrain.
//!
//! What it demonstrates on the wgpu path:
//!   - `genImageChecked` -> `genMeshHeightmap` (ported to `draw3d` for this
//!     example - CPU arrays, no GL upload tail) -> `loadModelFromMesh` ->
//!     `drawModel` with per-draw tint.
//!   - `updateCamera(.first_person)`: WASD walks, the mouse looks, the wheel
//!     lengthens a step.
//!   - The pointer lock: a click asks for it (`disableCursor`), and once the
//!     platform grants it the mouse looks with no button held, the cursor
//!     hidden and held still. Escape releases it (`enableCursor`); a browser
//!     also releases it on its own Escape and when the page loses focus.
//! Unlocked, and on a phone, a left-drag or a finger still looks. The checked
//! image gives the terrain its blocky two-tone height steps, exactly like the
//! original.
const std = @import("std");
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
    // A mouse click asks for the pointer lock; a finger never does, since a phone
    // has no pointer to lock and looks by dragging instead.
    const pointer_locked: bool = z.isPointerLocked(f.input);
    const no_finger_down: bool = z.getTouchPointCount(f.input) == 0;
    if (!pointer_locked and no_finger_down and z.isMouseButtonPressed(f.input, .left)) {
        z.disableCursor(f.input);
    }
    if (pointer_locked and z.isKeyPressed(f.input, .escape)) {
        z.enableCursor(f.input);
    }
    // WASD walks, the mouse looks (locked, or dragging), the wheel lengthens a
    // step - all inside updateCamera(.first_person).
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
    f.gl.textf(
        .{ 16, 42 },
        "pos ({d:.1}, {d:.1}, {d:.1})",
        .{ s.camera.position[0], s.camera.position[1], s.camera.position[2] },
        .{ .size = 16, .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 }, .font = &s.font },
    );
    const look_hint: []const u8 = if (pointer_locked)
        "mouse: look - Esc: release - WASD: walk - wheel: speed"
    else
        "click: lock the mouse - drag: look - WASD: walk - wheel: speed";
    common.caption(f.gl, s.font, look_hint);
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
