//! shaders_normalmap_rendering — port of raylib [shaders] example - normalmap.
//! raylib source: examples/shaders/shaders_normalmap_rendering.c (assets:
//! tiles_diffuse.png, tiles_normal.png — copied under examples/assets/normalmap,
//! zlib-licensed, porting encouraged).
//!
//! What a normal map is: the floor is a FLAT quad, but `normalmap_fs` perturbs
//! the surface normal per-texel from the tangent-space normal map, so the moving
//! light rakes across grout lines and bevels that aren't in the geometry. Toggle
//! it off and the same quad lights as the flat plane it really is.
//!
//! This is the deliberately-simple, non-PBR version (see `src/shaders/
//! normalmap_fs.zig`): one directional light, Lambert diffuse + Blinn-Phong
//! specular. It reuses the pbr3d renderer purely as plumbing (mesh upload,
//! tangents, the 2-texture material, camera/light uniforms, `drawModel3D`), but
//! swaps in our own fragment shader via `.fs_wgsl`.
//!
//! Controls (our engine's own camera + UI, a bit more verbose than raylib):
//!   - drag = orbit, pinch/wheel = zoom  (z.OrbitCamera)
//!   - UI panel: toggle the normal map, toggle the auto-orbiting light, and a
//!     manual light-angle slider.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Camera3D = zm.Camera3D;
const tau = zm.tau;
const pointVec = zm.pointVec;
const TextureRef = z.pbr3d.TextureRef;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const normalmap_fs_wgsl = @embedFile("normalmap_fs.wgsl");
const tiles_diffuse_png = @embedFile("tiles_diffuse.png");
const tiles_normal_png = @embedFile("tiles_normal.png");

pub var zimr_app: z.App = .{};

const State = struct {
    renderer: z.pbr3d.Renderer,
    // ONE tile diffuse, SHARED across both models (normal-map on vs off) via
    // `TextureRef.shared` — no duplicate GPU texture. The example owns it and
    // frees it once in deinit; the models don't (their `.shared` slot is unowned).
    diffuse: z.WgpuTexture,
    bumpy: z.pbr3d.Model,
    flat: z.pbr3d.Model,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    use_normal_map: bool = true,
    auto_light: bool = true,
    light_angle: f32 = 0.9,
};

fn loadTileTexture(
    gpa: Allocator,
    f: *z.Frame,
    png_bytes: []const u8,
    label: []const u8,
) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png_bytes);
    defer z.unloadImage(gpa, img);
    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    const pixels: []const u8 = @as([*]const u8, @ptrCast(img.data))[0 .. @as(usize, w) * h * 4];
    return z.WgpuTexture.createMipmappedFromPixels(gpa, f.gpu.device, f.gpu.queue, .{
        .pixels = pixels,
        .width = w,
        .height = h,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .label = label,
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const gf: *z.GpuFrame = f.gpu;
    var renderer: z.pbr3d.Renderer = try z.pbr3d.Renderer.init(.{
        .device = gf.device,
        .queue = gf.queue,
        .gpa = gpa,
        .surface_format = gf.backbuffer_format,
        .depth_format = .depth24_plus,
        .vs_wgsl = pbr_vs_wgsl,
        .fs_wgsl = normalmap_fs_wgsl,
        // A single flat floor has no "inside", and the demo lets you orbit
        // freely above AND below it — cull nothing so the tiles show from
        // either side (the vertex normal stays +Y, so it lights the same).
        .cull_mode = .none,
    });

    // ONE tile diffuse, shared across both models; one normal map, owned by
    // `bumpy` (the only model that binds it).
    const diffuse: z.WgpuTexture = try loadTileTexture(gpa, f, tiles_diffuse_png, "tiles_diffuse");
    const normal_tex: z.WgpuTexture = try loadTileTexture(gpa, f, tiles_normal_png, "tiles_normal");

    var mesh: z.Mesh = try z.genMeshPlane(gpa, 6.0, 6.0, 1, 1);
    try z.genMeshTangents(gpa, &mesh);
    // bumpy binds the real tile normal map; flat omits it, so loadMesh fills the
    // normal slot with a flat (0,0,1) neutral → the same quad, no perturbation.
    const bumpy: z.pbr3d.Model = try renderer.loadMesh(mesh, .{
        .base_color = TextureRef.shared(diffuse),
        .normal = TextureRef.owned(normal_tex),
    });
    const flat: z.pbr3d.Model = try renderer.loadMesh(mesh, .{
        .base_color = TextureRef.shared(diffuse),
    });
    z.unloadMesh(gpa, mesh);

    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{
        .renderer = renderer,
        .diffuse = diffuse,
        .bumpy = bumpy,
        .flat = flat,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cam = .{ .target = pointVec(0, 0, 0), .distance = 8.0, .pitch = 0.7, .yaw = 0.7 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    // Models free their OWNED maps (bumpy: normal + neutrals; flat: neutrals).
    // The shared diffuse is unowned by both, so the example frees it once.
    s.bumpy.deinit();
    s.flat.deinit();
    s.diffuse.deinit();
    s.renderer.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const t: f32 = f.time.time;

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ @min(260, vw - 16), 150 }, .{});
    if (u.window("normal map", .{})) |w| {
        defer w.close();
        _ = u.checkbox("normal map", &s.use_normal_map);
        _ = u.checkbox("auto-orbit light", &s.auto_light);
        if (!s.auto_light) {
            _ = u.slider("light angle", &s.light_angle, .{ .min = 0.0, .max = tau, .fmt = "{d:.2}" });
        }
        if (u.button("reset view", .{})) {
            s.cam = .{ .target = pointVec(0, 0, 0), .distance = 8.0, .pitch = 0.7, .yaw = 0.7 };
        }
    }

    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .fovy_deg = 45.0,
        .min_distance = 3.0,
        .max_distance = 24.0,
    });
    const angle: f32 = if (s.auto_light) t * 0.6 else s.light_angle;
    const light_dir: [3]f32 = .{ -@cos(angle), -0.65, -@sin(angle) };
    const light: z.pbr3d.Light = .{ .dir = light_dir, .color = .{ 1.0, 0.95, 0.88 }, .ambient = .{ 0.13, 0.13, 0.16 } };

    z.clearViewport(f, .{ .r = 12, .g = 14, .b = 20, .a = 255 });

    // ONE 3D scope owns the whole transition: beginMode3D flushes the 2D
    // background BEHIND the 3D and records the camera; endMode3D restores 2D
    // for the UI below. The plane (a pbr3d model via drawModel3D) and the light
    // marker (an immediate sphere) share that one camera — no per-draw
    // view/proj, no drawInApp, no manual restore2DState.
    z.beginMode3D(f.gl, cam);
    z.drawModel3D(f.gl, &s.renderer, light, if (s.use_normal_map) s.bumpy else s.flat, zm.identity());
    // Light indicator at the directional light's source (-light_dir), so it
    // orbits with the angle — same idea as raylib's normalmap marker sphere.
    const sun_r: f32 = 5.0;
    const sun_pos: zm.Vec = pointVec(-light_dir[0] * sun_r, -light_dir[1] * sun_r, -light_dir[2] * sun_r);
    z.drawSphere(f.gl, sun_pos, .{ .radius = 0.3, .color = .{ .r = 255, .g = 221, .b = 92, .a = 255 } });
    z.endMode3D(f.gl);

    const hint: []const u8 = "drag = orbit   pinch/wheel = zoom";
    f.gl.text(.{ 14, vh - 30 }, hint, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "WebGPU - normal mapping - a flat quad that lights like it has depth");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shaders - normal map rendering",
            .width = 900,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
