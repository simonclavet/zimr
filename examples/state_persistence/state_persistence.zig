//! state_persistence - save an example's state and get it back in the next run:
//! after a page reload in the browser, or a restart natively. It serializes a
//! plain struct with `z.serialize` (the versioned protobuf-style serializer) and
//! keeps the bytes as a saved value (`z.saveValue`): in the browser's storage on
//! the web, in a file under the user's application data natively. Tweak the
//! colour and sliders, press Save, then reload the page or restart the program:
//! the tweaks, and how many times they were saved, come back. The round trip is
//! the point: a plain Zig struct -> bytes -> saved value -> bytes -> struct.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui_real;

const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;
const Vec3 = zm.Vec3;

// the key the bytes are saved under
const storage_key = "state_persistence_demo";

// The state we persist - a plain struct the serializer walks field by field.
// Field numbers are assigned in declaration order, so you could add a field
// here later and old saves would still load (missing field keeps its default).
const SavedState = struct {
    color_r: f32 = 0.90,
    color_g: f32 = 0.45,
    color_b: f32 = 0.30,
    spin_speed: f32 = 0.6,
    cube_scale: f32 = 1.0,
    save_count: u32 = 0,
    // a zm type persisted alongside the scalars. Added LAST so older saves
    // (without it) still load - the versioned format just fills the default.
    position: Vec3 = .{ 0, 0, 0 },
};

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Model,
    cam: z.OrbitCamera,
    saved: SavedState,
    loaded_from_storage: bool,
    status: []const u8, // a one-line feedback message (always a static string)
};

fn colorByte(v: f32) u8 {
    // colorEdit keeps v in [0,1], so this can't overflow u8
    return @round(v * 255.0);
}

/// The saved state, or null if there is nothing saved. Saved values are bytes kept
/// as they went in, so the serialized struct comes back exactly.
fn loadSaved(gpa: Allocator) ?SavedState {
    var buffer: [4096]u8 = undefined;
    const raw: []u8 = z.loadValue(storage_key, &buffer) orelse return null;
    // SavedState is all scalars, so the decode allocates nothing to free
    return z.serialize.decode(SavedState, raw, gpa) catch null;
}

/// Serialize the state and save the bytes. Returns a status line describing what
/// happened; a save the platform cannot make is logged by it.
fn saveToStorage(gpa: Allocator, saved: SavedState) []const u8 {
    const bytes: []u8 = z.serialize.encodeAlloc(saved, gpa) catch {
        return "Save failed: out of memory.";
    };
    defer gpa.free(bytes);
    z.saveValue(storage_key, bytes);
    return "Saved.";
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 20);
    const cube_mesh: z.types.Mesh = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    // start from whatever we saved last time, or the struct defaults
    const restored: ?SavedState = loadSaved(gpa);
    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cube = try z.loadModelFromMesh(f.gl, gpa, cube_mesh),
        .cam = .{ .target = pointVec(0, 0.1, 0), .distance = 4.5, .pitch = 0.45, .yaw = 0.7 },
        .saved = restored orelse .{},
        .loaded_from_storage = restored != null,
        .status = if (restored != null)
            "Restored from the saved value."
        else
            "No save yet - tweak, then hit Save.",
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadModel(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // auto-orbit the camera; the spin speed is one of the saved values, so the
    // slider visibly (and persistently) drives the scene
    s.cam.yaw += f.time.delta_time * s.saved.spin_speed;
    // pass "true" so the orbit camera ignores mouse drag (the UI owns the mouse)
    const cam: Camera3D = s.cam.update(f, true, .{ .fovy_deg = 45 });

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 24, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 8, 0.5);
    const p: Vec3 = s.saved.position;
    z.drawModel(f.gl, s.cube, pointVec(p[0], p[1], p[2]), s.saved.cube_scale, .{
        .r = colorByte(s.saved.color_r),
        .g = colorByte(s.saved.color_g),
        .b = colorByte(s.saved.color_b),
        .a = 255,
    });
    z.endMode3D(f.gl);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("State (saved across runs)", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 340, 320 },
    })) |w| {
        defer w.close();
        u.text("A struct -> bytes -> saved value -> back.", .{});
        u.text("Tweak, Save, then reload or restart.", .{});
        u.text("Loaded from storage: {s}", .{if (s.loaded_from_storage) "yes" else "no"});
        u.text("Saved {d} time(s)", .{s.saved.save_count});
        u.text("{s}", .{s.status});

        // colorEdit wants a [3]f32; sync it back into our three fields
        var rgb = [3]f32{ s.saved.color_r, s.saved.color_g, s.saved.color_b };
        if (u.colorEdit("Cube colour", &rgb, .{})) {
            s.saved.color_r = rgb[0];
            s.saved.color_g = rgb[1];
            s.saved.color_b = rgb[2];
        }
        _ = u.slider("Spin speed", &s.saved.spin_speed, .{ .min = 0, .max = 3 });
        _ = u.slider("Cube scale", &s.saved.cube_scale, .{ .min = 0.3, .max = 2.5 });

        // position is a zm.Vec3; its elements aren't addressable, so slide a
        // plain [3]f32 copy and write it back into the vector
        var pos = [3]f32{ s.saved.position[0], s.saved.position[1], s.saved.position[2] };
        _ = u.slider("Pos X", &pos[0], .{ .min = -3, .max = 3 });
        _ = u.slider("Pos Y", &pos[1], .{ .min = -3, .max = 3 });
        _ = u.slider("Pos Z", &pos[2], .{ .min = -3, .max = 3 });
        s.saved.position = .{ pos[0], pos[1], pos[2] };

        if (u.button("Save", .{})) {
            s.saved.save_count += 1;
            s.status = saveToStorage(s.gpa, s.saved);
            s.loaded_from_storage = true;
        }
        if (u.button("Clear saved", .{})) {
            z.removeValue(storage_key);
            s.saved = .{};
            s.loaded_from_storage = false;
            s.status = "Cleared. Defaults restored.";
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - state persistence",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
