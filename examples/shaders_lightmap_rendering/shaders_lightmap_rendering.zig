//! shaders_lightmap_rendering - port of raylib's lightmap demo, expanded into a
//! proper "why lightmaps exist" showcase: a STATIC scene lit by ~30 coloured
//! point lights whose lighting - including the SHADOWS the static cubes cast on
//! the floor - is BAKED into a texture once at load, then sampled for free at
//! runtime. Runtime lighting cost: one texture fetch. Zero lights are evaluated
//! per frame.
//!
//! The floor still demonstrates the engine's uv2 path (the reason this example
//! exists): a ground quad carries pos + uv + uv2 (the reserved texcoord2 attr at
//! location 5); the primary uv tiles a subtle checker, the second uv2 samples
//! the baked lightmap, and the fragment shader multiplies them -
//! base(uv) x lightmap(uv2). The static cubes are drawn with the ordinary 3D
//! immediate path in the SAME pass (shared depth), each tinted by the baked
//! light sampled at its position - so a cube sitting in a red pool glows red.
//!
//! The bake (`bakeLightmapPixels`) is the star: for every lightmap texel it sums
//! all lights with distance falloff AND ray-marches each texel->light segment
//! against every cube AABB to carve out shadows. That's the expensive
//! precomputation a real lightmapper does offline; here it runs once at init.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const pointVec = zm.pointVec;
const f32x4 = zm.f32x4;
const splat = zm.splat;
const identity = zm.identity;
const float = zm.float;
const bufPrint = std.fmt.bufPrint;
const si = @import("shader_interface");

const vs_io = @import("lightmap_vs_io.zig");
const vs_wgsl = @embedFile("lightmap_vs.wgsl");
const fs_wgsl = @embedFile("lightmap_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// Merged schema for `loadShader` (VS uniform + FS samplers can't both go
/// through `loadShaderVF`; see cube_demo). Mirrors lightmap_vs_io.Ubo +
/// lightmap_fs_io.Samplers so the generated WGSL's binding slots line up.
const LightmapSchema = struct {
    pub const Ubo = struct {
        mvp: [4]Vec = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };
    pub const Samplers = struct {
        base: si.Sampler2D(.albedo, .{}),
        lightmap: si.Sampler2D(.emission, .{}),
    };
};

const plane_half: f32 = 4.0; // floor spans [-4, 4] -> 8x8 units
const base_tiles: f32 = 8.0; // subtle checker repeats 8x across the floor
const tex_dim: u32 = 256; // lightmap resolution
const num_lights: usize = 30;
const num_cubes: usize = 11;
const ambient: Vec = f32x4(0.05, 0.06, 0.10, 0); // dark cool ambient floor

const Light = struct {
    pos: Vec,
    color: Vec, // rgb in xyz
    intensity: f32,
};

const Cube = struct {
    center: Vec, // some sit on the floor (center.y = half.y), some float above
    half: Vec, // half-extents
    face_tint: [6]Vec, // baked light colour per face (+X,-X,+Y,-Y,+Z,-Z)
};

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(LightmapSchema),
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    base_tex: z.WgpuTexture,
    lightmap_tex: z.WgpuTexture,
    cam: z.OrbitCamera,
    cubes: [num_cubes]Cube,
};

/// Tiny deterministic LCG so the scene is identical every run (and headlessly
/// reproducible) without pulling in the RNG machinery.
const Rng = struct {
    state: u32 = 0x1234567,
    fn next(self: *Rng) f32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return float(self.state >> 8) / float(@as(u32, 1) << 24);
    }
    fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.next();
    }
};

fn buildLights() [num_lights]Light {
    // A varied palette so overlapping pools read as distinct colours.
    const palette = [_]Vec{
        f32x4(1.0, 0.55, 0.20, 0), // warm orange
        f32x4(0.25, 0.5, 1.0, 0), // cool blue
        f32x4(1.0, 0.3, 0.8, 0), // magenta
        f32x4(0.3, 1.0, 0.45, 0), // green
        f32x4(0.3, 0.9, 1.0, 0), // cyan
        f32x4(1.0, 0.9, 0.7, 0), // warm white
        f32x4(1.0, 0.25, 0.25, 0), // red
        f32x4(0.6, 0.35, 1.0, 0), // violet
    };
    var rng: Rng = .{};
    var lights: [num_lights]Light = undefined;
    var i: usize = 0;
    while (i < num_lights) : (i += 1) {
        lights[i] = .{
            .pos = f32x4(rng.range(-3.4, 3.4), rng.range(1.2, 2.7), rng.range(-3.4, 3.4), 0),
            .color = palette[i % palette.len],
            .intensity = rng.range(1.2, 1.9),
        };
    }
    return lights;
}

fn buildCubes() [num_cubes]Cube {
    var rng: Rng = .{ .state = 0x9e3779b9 };
    var cubes: [num_cubes]Cube = undefined;
    var i: usize = 0;
    while (i < num_cubes) : (i += 1) {
        const hx: f32 = rng.range(0.25, 0.65);
        const hy: f32 = rng.range(0.3, 0.9);
        const hz: f32 = rng.range(0.25, 0.65);
        // Float every third cube so they cast shadows onto the cubes/floor below
        // (and aren't all glued to the ground).
        const lift: f32 = if (i % 3 == 0) rng.range(0.7, 1.6) else 0.0;
        cubes[i] = .{
            .center = f32x4(rng.range(-2.9, 2.9), hy + lift, rng.range(-2.9, 2.9), 0),
            .half = f32x4(hx, hy, hz, 0),
            .face_tint = .{ splat(0), splat(0), splat(0), splat(0), splat(0), splat(0) },
        };
    }
    return cubes;
}

/// Slab test: does the segment origin->(origin + dir*max_t) pierce the AABB?
fn segmentHitsAabb(
    origin: Vec,
    dir: Vec,
    max_t: f32,
    c_min: Vec,
    c_max: Vec,
) bool {
    var t0: f32 = 0.0;
    var t1: f32 = max_t;
    inline for (0..3) |axis| {
        const d: f32 = dir[axis];
        if (@abs(d) < 1e-6) {
            if (origin[axis] < c_min[axis] or origin[axis] > c_max[axis]) {
                return false;
            }
        } else {
            const inv: f32 = 1.0 / d;
            var ta: f32 = (c_min[axis] - origin[axis]) * inv;
            var tb: f32 = (c_max[axis] - origin[axis]) * inv;
            if (ta > tb) {
                const tmp: f32 = ta;
                ta = tb;
                tb = tmp;
            }
            if (ta > t0) {
                t0 = ta;
            }
            if (tb < t1) {
                t1 = tb;
            }
            if (t0 > t1) {
                return false;
            }
        }
    }
    return true;
}

/// Accumulate all lights at a world point, with distance falloff and - if
/// requested - shadows from every cube except `skip` (self). This is the
/// per-texel work the bake repeats hundreds of thousands of times.
fn lightAt(
    world: Vec,
    lights: []const Light,
    cubes: []const Cube,
    occlude: bool,
    skip: i32,
) Vec {
    var acc: Vec = ambient;
    for (lights) |lt| {
        const lv: Vec = lt.pos - world;
        const dist: f32 = @sqrt(lv[0] * lv[0] + lv[1] * lv[1] + lv[2] * lv[2]);
        if (dist < 1e-4) {
            continue;
        }
        const dir: Vec = lv / splat(dist);
        const atten: f32 = lt.intensity / (0.4 + 0.25 * dist * dist);
        var shadow: f32 = 1.0;
        if (occlude) {
            const origin: Vec = world + dir * splat(0.02); // nudge off the surface
            var ci: usize = 0;
            while (ci < cubes.len) : (ci += 1) {
                if (@as(i32, @intCast(ci)) == skip) {
                    continue;
                }
                const cmin: Vec = cubes[ci].center - cubes[ci].half;
                const cmax: Vec = cubes[ci].center + cubes[ci].half;
                if (segmentHitsAabb(origin, dir, dist - 0.04, cmin, cmax)) {
                    shadow = 0.0;
                    break;
                }
            }
        }
        acc += lt.color * splat(atten * shadow);
    }
    // Reinhard tone-map. With this many overlapping lights the raw sum blows
    // past 1.0 in every channel and clamps to white, washing out all colour;
    // acc/(acc+1) compresses to [0,1) while preserving hue, so a spot dominated
    // by a red light stays red instead of saturating to white.
    return acc / (acc + splat(1.0));
}

const cube_fill: Vec = f32x4(0.10, 0.11, 0.15, 0); // per-face floor so no face is pure black

/// The 6 cube faces: outward unit normal + 4 corner sign-vectors (+/-1 per axis).
/// Windings yield outward normals so the immediate renderer's Lambert shades
/// them correctly; the solid pipeline is no-cull so visibility is winding-safe
/// regardless. A world corner is `center + corner * half`.
const CubeFace = struct { n: Vec, corners: [4]Vec };
const cube_faces = [6]CubeFace{
    .{ .n = f32x4(1, 0, 0, 0), .corners = .{
        f32x4(1, -1, -1, 0), f32x4(1, 1, -1, 0), f32x4(1, 1, 1, 0), f32x4(1, -1, 1, 0),
    } },
    .{ .n = f32x4(-1, 0, 0, 0), .corners = .{
        f32x4(-1, -1, 1, 0), f32x4(-1, 1, 1, 0), f32x4(-1, 1, -1, 0), f32x4(-1, -1, -1, 0),
    } },
    .{ .n = f32x4(0, 1, 0, 0), .corners = .{
        f32x4(-1, 1, -1, 0), f32x4(-1, 1, 1, 0), f32x4(1, 1, 1, 0), f32x4(1, 1, -1, 0),
    } },
    .{ .n = f32x4(0, -1, 0, 0), .corners = .{
        f32x4(-1, -1, -1, 0), f32x4(1, -1, -1, 0), f32x4(1, -1, 1, 0), f32x4(-1, -1, 1, 0),
    } },
    .{ .n = f32x4(0, 0, 1, 0), .corners = .{
        f32x4(-1, -1, 1, 0), f32x4(1, -1, 1, 0), f32x4(1, 1, 1, 0), f32x4(-1, 1, 1, 0),
    } },
    .{ .n = f32x4(0, 0, -1, 0), .corners = .{
        f32x4(1, -1, -1, 0), f32x4(-1, -1, -1, 0), f32x4(-1, 1, -1, 0), f32x4(1, 1, -1, 0),
    } },
};

/// Baked colour for one cube face: sum only the lights on this face's side (so
/// opposite faces differ), each attenuated by distance and BLOCKED by any other
/// cube in the way - that occlusion is the cube-on-cube shadow. A fill floor
/// keeps a fully-blocked face dim-grey rather than pure black. No Lambert weight
/// here: the immediate renderer folds in its own directional shade.
fn faceColor(
    face_center: Vec,
    normal: Vec,
    lights: []const Light,
    cubes: []const Cube,
    skip: i32,
) Vec {
    var acc: Vec = cube_fill;
    const origin: Vec = face_center + normal * splat(0.02);
    for (lights) |lt| {
        const lv: Vec = lt.pos - face_center;
        const dist: f32 = @sqrt(lv[0] * lv[0] + lv[1] * lv[1] + lv[2] * lv[2]);
        if (dist < 1e-4) {
            continue;
        }
        const dir: Vec = lv / splat(dist);
        if (dir[0] * normal[0] + dir[1] * normal[1] + dir[2] * normal[2] <= 0.05) {
            continue; // light behind this face
        }
        const atten: f32 = lt.intensity / (0.4 + 0.25 * dist * dist);
        var shadow: f32 = 1.0;
        var ci: usize = 0;
        while (ci < cubes.len) : (ci += 1) {
            if (@as(i32, @intCast(ci)) == skip) {
                continue;
            }
            const cmin: Vec = cubes[ci].center - cubes[ci].half;
            const cmax: Vec = cubes[ci].center + cubes[ci].half;
            if (segmentHitsAabb(origin, dir, dist - 0.04, cmin, cmax)) {
                shadow = 0.0;
                break;
            }
        }
        acc += lt.color * splat(atten * shadow);
    }
    return acc / (acc + splat(1.0)); // tone-map, keep hue
}

/// Draw a cube as 6 flat-shaded faces, each with its baked colour, via the
/// immediate 3D path (shares the floor's pass + depth).
fn drawLitCube(gl: *z.WgpuGl, cube: Cube) void {
    inline for (0..6) |fi| {
        const t: Vec = cube.face_tint[fi];
        const r: u8 = toU8(t[0]);
        const g: u8 = toU8(t[1]);
        const b: u8 = toU8(t[2]);
        const c0: Vec = cube.center + cube_faces[fi].corners[0] * cube.half;
        const c1: Vec = cube.center + cube_faces[fi].corners[1] * cube.half;
        const c2: Vec = cube.center + cube_faces[fi].corners[2] * cube.half;
        const c3: Vec = cube.center + cube_faces[fi].corners[3] * cube.half;
        z.drawTriangle3D(gl, c0, c1, c2, .{ .r = r, .g = g, .b = b, .a = 255 });
        z.drawTriangle3D(gl, c0, c2, c3, .{ .r = r, .g = g, .b = b, .a = 255 });
    }
}

fn toU8(x: f32) u8 {
    const c: f32 = if (x < 0) 0 else if (x > 1) 1 else x;
    return @round(c * 255.0);
}

/// A near-white checker so the baked light colour dominates the look.
fn makeBasePixels(gpa: Allocator) ![]u8 {
    const px: []u8 = try gpa.alloc(u8, tex_dim * tex_dim * 4);
    const cell: u32 = tex_dim / 8;
    var y: u32 = 0;
    while (y < tex_dim) : (y += 1) {
        var x: u32 = 0;
        while (x < tex_dim) : (x += 1) {
            const light_cell: bool = ((x / cell) + (y / cell)) % 2 == 0;
            const i: usize = (y * tex_dim + x) * 4;
            const v: u8 = if (light_cell) 225 else 190;
            px[i] = v;
            px[i + 1] = v;
            px[i + 2] = v;
            px[i + 3] = 255;
        }
    }
    return px;
}

/// THE BAKE: every texel = summed many-light lighting + cube shadows. Expensive,
/// done once. Returns the pixels; caller owns them.
fn bakeLightmapPixels(
    gpa: Allocator,
    lights: []const Light,
    cubes: []const Cube,
) ![]u8 {
    const px: []u8 = try gpa.alloc(u8, tex_dim * tex_dim * 4);
    const dimf: f32 = float(tex_dim - 1);
    var ty: u32 = 0;
    while (ty < tex_dim) : (ty += 1) {
        const v: f32 = float(ty) / dimf;
        const wz: f32 = -plane_half + 2.0 * plane_half * v;
        var tx: u32 = 0;
        while (tx < tex_dim) : (tx += 1) {
            const u: f32 = float(tx) / dimf;
            const wx: f32 = -plane_half + 2.0 * plane_half * u;
            const world: Vec = f32x4(wx, 0.0, wz, 0);
            const lit: Vec = lightAt(world, lights, cubes, true, -1);
            const i: usize = (ty * tex_dim + tx) * 4;
            px[i] = toU8(lit[0]);
            px[i + 1] = toU8(lit[1]);
            px[i + 2] = toU8(lit[2]);
            px[i + 3] = 255;
        }
    }
    return px;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const lights: [num_lights]Light = buildLights();
    var cubes: [num_cubes]Cube = buildCubes();
    // Bake 6 per-face colours per cube (each shadowed by the OTHER cubes) - the
    // face-level cube-on-cube shadowing.
    var ci: usize = 0;
    while (ci < num_cubes) : (ci += 1) {
        inline for (0..6) |fi| {
            const fc: Vec = cubes[ci].center + cube_faces[fi].n * cubes[ci].half;
            cubes[ci].face_tint[fi] = faceColor(fc, cube_faces[fi].n, &lights, &cubes, @intCast(ci));
        }
    }

    // Ground quad: pos(3), uv(2), uv2(2). uv tiles the checker; uv2 spans 0..1.
    const h: f32 = plane_half;
    const t: f32 = base_tiles;
    const verts = [_]f32{
        -h, 0, -h, 0, 0, 0, 0,
        h,  0, -h, t, 0, 1, 0,
        h,  0, h,  t, t, 1, 1,
        -h, 0, h,  0, t, 0, 1,
    };
    const idx = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = verts.len * @sizeOf(f32),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "lightmap_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(verts[0..]));
    const ibo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = idx.len * @sizeOf(u16),
        .usage = .{ .index = true, .copy_dst = true },
        .label = "lightmap_ibo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, ibo, 0, std.mem.sliceAsBytes(idx[0..]));

    const base_px: []u8 = try makeBasePixels(gpa);
    defer gpa.free(base_px);
    const base_tex: z.WgpuTexture = z.WgpuTexture.createFromPixels(f.gpu.device, f.gpu.queue, .{
        .width = tex_dim,
        .height = tex_dim,
        .pixels = base_px,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .repeat,
        .label = "lightmap_base",
    });

    const lm_px: []u8 = try bakeLightmapPixels(gpa, &lights, &cubes);
    defer gpa.free(lm_px);
    const lightmap_tex: z.WgpuTexture = z.WgpuTexture.createFromPixels(f.gpu.device, f.gpu.queue, .{
        .width = tex_dim,
        .height = tex_dim,
        .pixels = lm_px,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .clamp_to_edge,
        .label = "lightmap_baked",
    });

    const shader: z.shader.LoadedShader(LightmapSchema) = try z.shader.loadShader(LightmapSchema, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .depth_state = .less_equal,
        .initial_ubo = .{ .mvp = identity() },
        .textures = .{ .base = base_tex, .lightmap = lightmap_tex },
        .label = "shaders_lightmap_rendering",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .shader = shader,
        .vbo = vbo,
        .ibo = ibo,
        .base_tex = base_tex,
        .lightmap_tex = lightmap_tex,
        .cam = .{ .target = pointVec(0, 0.3, 0), .distance = 11.0, .pitch = 0.5, .yaw = 0.7 },
        .cubes = cubes,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.ibo);
    s.base_tex.deinit();
    s.lightmap_tex.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const aspect: f32 = f.window.widthf() / @max(f.window.heightf(), 1.0);
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 50 });
    // ONE view_proj shared by the custom floor pipeline AND the immediate cubes.
    // beginMode3D builds its own with near/far 0.01/1000; if the floor used a
    // different near/far its depth values wouldn't be comparable to the cubes'
    // and the floor would paint over them. So compute it once (matching those
    // planes) and feed the cubes the SAME matrix via beginMode3DMatrix.
    const vp: [4]Vec = cam.viewProj(aspect, 0.01, 1000.0);
    s.shader.pushUbo(f.gpu.queue, .{ .mvp = vp });

    z.clearViewport(f, .{ .r = 6, .g = 7, .b = 12, .a = 255 });

    // 1. the lit floor - custom uv2 pipeline, bracketed inside f.gl's pass.
    const ps: *z.PassState = f.gl.pass;
    f.gl.flushBeforeMaterialSwap();
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, 4 * 7 * @sizeOf(f32));
    s.shader.setIndex(ps, s.ibo, .uint16, 6 * @sizeOf(u16));
    s.shader.drawIndexed(ps, 6, 1);
    f.gl.renderer().bindForPass(ps);

    // 2. the static cubes - ordinary 3D immediate path, SAME pass + depth + the
    //    SAME view_proj as the floor. Each is tinted by the baked light at its
    //    position.
    z.beginMode3DMatrix(f.gl, vp);
    for (s.cubes) |cube| {
        drawLitCube(f.gl, cube);
    }
    z.endMode3D(f.gl);

    // 3. HUD.
    var buf: [96]u8 = undefined;
    const line: []const u8 = bufPrint(
        &buf,
        "{d} coloured lights + baked shadows from {d} static cubes",
        .{ num_lights, num_cubes },
    ) catch "";
    f.gl.text(.{ 16, 16 }, "lightmap: baked many-light scene", .{
        .size = 24,
        .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 },
        .font = &s.font,
    });
    f.gl.text(.{ 16, 46 }, line, .{
        .size = 16,
        .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 },
        .font = &s.font,
    });
    common.caption(f.gl, s.font, "runtime lighting cost: 1 texture fetch, 0 lights - it's all in the lightmap");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - lightmap rendering",
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
