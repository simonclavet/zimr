//! src/tests/cpu_shadowmap_test.zig - proves the software rasteriser can run a
//! real TWO-PASS shadow-map pipeline end to end, entirely on the CPU:
//!
//!   Pass 1 (light's eye): rasterise the scene depth into an rgba8 "shadow map"
//!           (depth-in-red), via `dispatchVertexShader` + `rasterizeToImage`.
//!   Pass 2 (camera):       rasterise the lit scene, the fragment shader
//!           projecting into light space and SAMPLING the pass-1 image to decide
//!           shadowed vs lit - the same structure the WebGPU backend runs across
//!           two render passes, and the same `proj.y = 1 - proj.y` RTT flip.
//!
//! The inline shader pairs mirror `src/shaders/depth_*` and `lit_shadow_*`. The
//! test asserts the ground carries both a lit region and a distinctly darker
//! shadow region cast by an elevated occluder - the thing that can only happen
//! if pass 2 actually read pass 1's depth. This is the CPU-verifiable core of
//! `src/notes/cpu_shadowmap_plan.md`.

const std = @import("std");
const zm = @import("zm");
const raster_shader = @import("../raster_shader.zig");
const autoConnect = @import("../shader_connect.zig").autoConnect;

const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const Mat = zm.Mat;
const float = zm.float;
const floori = zm.floori;
const normalize = zm.normalize;
const mulMat = zm.mulMat;
const expect = std.testing.expect;

// ---------------------------------------------------------------------------
// Scene geometry (file scope so the comptime `fillAttrs` callbacks can read it):
// a large ground quad at y=0 and a smaller occluder panel floating at y=1.2.
// ---------------------------------------------------------------------------
const positions = [_]Vec3{
    // Ground quad (y=0).
    .{ -3, 0, -3 },       .{ 3, 0, -3 },       .{ 3, 0, 3 },       .{ -3, 0, 3 },
    // Occluder panel (y=1.2), centred over the origin.
    .{ -0.5, 1.2, -0.5 }, .{ 0.5, 1.2, -0.5 }, .{ 0.5, 1.2, 0.5 }, .{ -0.5, 1.2, 0.5 },
};
const normals = [_]Vec3{
    .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 },
    .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 },
};
const indices = [_]u32{
    0, 1, 2, 0, 2, 3, // ground
    4, 5, 6, 4, 6, 7, // occluder
};
const vertex_count: u32 = positions.len;

// Direction TO the light - tilted in +x so the panel's shadow falls toward -x.
const light_dir: Vec3 = .{ 0.35, 0.9, 0.0 };
const base_color: Vec3 = .{ 0.75, 0.75, 0.80 };

// ---------------------------------------------------------------------------
// Pass 1 shaders - depth-in-red (mirror src/shaders/depth_vs.zig + depth_fs.zig).
// ---------------------------------------------------------------------------
const DepthVs = struct {
    pub const Io = struct { vpos: Vec3, vp: Mat };
    pub const Out = struct { position: Vec, gray: Vec };
    pub fn shaderMain(io: Io) Out {
        const clip: Vec = zm.mulMatPoint(io.vp, io.vpos);
        const d: f32 = clip[2] / clip[3] * 0.5 + 0.5; // ndc_z*0.5+0.5
        return .{ .position = clip, .gray = .{ d, d, d, 1 } };
    }
};
const DepthFs = struct {
    pub const Io = struct { gray: Vec };
    pub const Out = struct { out_color: Vec };
    pub fn shaderMain(io: Io) Out {
        return .{ .out_color = io.gray };
    }
};
fn fillDepthAttrs(vid: u32, io: *DepthVs.Io) void {
    io.vpos = positions[vid];
}

// ---------------------------------------------------------------------------
// Pass 2 shaders - shadow-mapped Lambert (mirror lit_shadow_vs + lit_shadow_fs).
// ---------------------------------------------------------------------------
/// A CPU shadow-map handle: raw rgba8 pixels + dims, sampled nearest by red.
/// This is the shape the generated IoT's `TextureRef` gives sampling shaders on
/// the CPU target; here it is spelled out so the test needs no codegen.
const ShadowRef = struct {
    pixels: []const u8,
    w: u32,
    h: u32,
    fn sampleRed(self: ShadowRef, u: f32, v: f32) f32 {
        var uu: f32 = u;
        var vv: f32 = v;
        if (uu < 0) {
            uu = 0;
        }
        if (uu > 1) {
            uu = 1;
        }
        if (vv < 0) {
            vv = 0;
        }
        if (vv > 1) {
            vv = 1;
        }
        const w_i: i32 = @intCast(self.w);
        const h_i: i32 = @intCast(self.h);
        var x: i32 = @floor(uu * float(self.w));
        var y: i32 = @floor(vv * float(self.h));
        if (x >= w_i) {
            x = w_i - 1;
        }
        if (y >= h_i) {
            y = h_i - 1;
        }
        if (x < 0) {
            x = 0;
        }
        if (y < 0) {
            y = 0;
        }
        const idx: usize = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
        return float(self.pixels[idx]) / 255.0;
    }
};

const LitVs = struct {
    pub const Io = struct { vpos: Vec3, vnrm: Vec3, cam_vp: Mat, light_vp: Mat };
    pub const Out = struct { position: Vec, frag_normal: Vec3, frag_lpos: Vec };
    pub fn shaderMain(io: Io) Out {
        return .{
            .position = zm.mulMatPoint(io.cam_vp, io.vpos),
            .frag_normal = io.vnrm, // identity model -> attribute normal is world
            .frag_lpos = zm.mulMatPoint(io.light_vp, io.vpos),
        };
    }
};
const LitFs = struct {
    pub const Io = struct {
        frag_normal: Vec3,
        frag_lpos: Vec,
        shadow: ShadowRef,
        ldir: Vec3,
        albedo: Vec3,
    };
    pub const Out = struct { out_color: Vec };
    pub fn shaderMain(io: Io) Out {
        const ld: Vec3 = normalize(io.ldir);
        const n: Vec3 = normalize(io.frag_normal);
        const ndl: f32 = @max(n[0] * ld[0] + n[1] * ld[1] + n[2] * ld[2], 0.0);

        // Project into light clip space, remap to [0,1], flip v (RTT top-left).
        const inv_w: f32 = 1.0 / io.frag_lpos[3];
        var proj: Vec3 = .{ io.frag_lpos[0] * inv_w, io.frag_lpos[1] * inv_w, io.frag_lpos[2] * inv_w };
        proj = proj * @as(Vec3, @splat(0.5)) + @as(Vec3, @splat(0.5));
        proj[1] = 1.0 - proj[1];

        const closest: f32 = io.shadow.sampleRed(proj[0], proj[1]);
        const current: f32 = proj[2];
        // 8-bit shadow map -> the depth quantum is 1/255 ~ 0.0039, so the constant
        // bias floor MUST clear it or the ground self-shadows (acne). This large
        // floor is the precision tax of the rgba8 map; a float (r32/rgba16f)
        // sampler - the next step in cpu_shadowmap_plan.md - lets it drop ~5x.
        const bias: f32 = @max(0.015 * (1.0 - ndl), 0.008);

        var shadow: f32 = 1.0;
        if (proj[0] < 0.0 or proj[0] > 1.0 or proj[1] < 0.0 or proj[1] > 1.0 or proj[2] > 1.0) {
            shadow = 1.0;
        } else if ((current - bias) > closest) {
            shadow = 0.0;
        }

        const ambient: f32 = 0.25;
        const lit: f32 = ambient + (1.0 - ambient) * ndl * shadow;
        return .{ .out_color = .{ io.albedo[0] * lit, io.albedo[1] * lit, io.albedo[2] * lit, 1.0 } };
    }
};
fn fillLitAttrs(vid: u32, io: *LitVs.Io) void {
    io.vpos = positions[vid];
    io.vnrm = normals[vid];
}

fn luminance(c: [4]u8) f32 {
    return 0.299 * float(c[0]) + 0.587 * float(c[1]) + 0.114 * float(c[2]);
}

/// Project a world point through `vp` to integer pixel coords using the SAME
/// NDC->screen mapping `rasterizeToImage` uses (row 0 = top). Null if behind.
fn projectToPixel(vp: Mat, p: Vec3, comptime W: usize, comptime H: usize) ?[2]usize {
    const clip: Vec = zm.mulMatPoint(vp, p);
    if (clip[3] <= 1e-6) {
        return null;
    }
    const inv_w: f32 = 1.0 / clip[3];
    const sx: f32 = (clip[0] * inv_w + 1.0) * 0.5 * float(W);
    const sy: f32 = (1.0 - (clip[1] * inv_w + 1.0) * 0.5) * float(H);
    if (sx < 0 or sy < 0 or sx >= float(W) or sy >= float(H)) {
        return null;
    }
    return .{ floori(usize, sx), floori(usize, sy) };
}

test "cpu two-pass shadow map: occluder casts a visible ground shadow" {
    // ---- Light view-projection (orthographic, directional). ----
    const center: Vec = .{ 0, 0.5, 0, 1 };
    const l4: Vec = .{ light_dir[0], light_dir[1], light_dir[2], 0 };
    const light_eye: Vec = center + l4 * @as(Vec, @splat(8.0));
    const light_view: Mat = zm.lookAtRh(light_eye, center, .{ 0, 0, 1, 0 });
    const light_proj: Mat = zm.orthographicRh(6.0, 6.0, 0.1, 20.0);
    const light_vp: Mat = mulMat(light_proj, light_view);

    // ---- Pass 1: depth-in-red into the shadow map. ----
    const SM: usize = 128;
    var depth_outs: [vertex_count]DepthVs.Out = undefined;
    raster_shader.dispatchVertexShader(
        DepthVs,
        &depth_outs,
        .{ .vpos = undefined, .vp = light_vp },
        vertex_count,
        fillDepthAttrs,
    );
    const shadow_img: [SM * SM][4]u8 = raster_shader.rasterizeToImage(
        DepthVs,
        DepthFs,
        SM,
        SM,
        &depth_outs,
        &indices,
        .{ .gray = undefined },
        comptime autoConnect(DepthVs.Out, DepthFs.Io),
        .{ .front_face = .none },
        .{ 255, 255, 255, 255 }, // clear = far (white = depth 1.0)
    );

    // Sanity: the occluder must have written something NEARER than the clear in
    // the middle of the map (else pass 1 did nothing and pass 2 is meaningless).
    var min_red: u8 = 255;
    for (shadow_img) |px| {
        if (px[0] < min_red) {
            min_red = px[0];
        }
    }
    try expect(min_red < 240);

    // Flatten to a byte slice for the CPU sampler.
    var sm_bytes: [SM * SM * 4]u8 = undefined;
    for (shadow_img, 0..) |px, i| {
        sm_bytes[i * 4 + 0] = px[0];
        sm_bytes[i * 4 + 1] = px[1];
        sm_bytes[i * 4 + 2] = px[2];
        sm_bytes[i * 4 + 3] = px[3];
    }
    const shadow_ref: ShadowRef = .{ .pixels = &sm_bytes, .w = SM, .h = SM };

    // ---- Camera view-projection. ----
    const W: usize = 160;
    const H: usize = 120;
    const cam_eye: Vec = .{ 3.0, 3.0, 3.6, 1 };
    const cam_view: Mat = zm.lookAtRh(cam_eye, .{ 0, 0.3, 0, 1 }, .{ 0, 1, 0, 0 });
    const cam_proj: Mat = zm.perspectiveFovRh(0.9, float(W) / float(H), 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    // ---- Pass 2: lit + shadow-sampled into the framebuffer. ----
    var lit_outs: [vertex_count]LitVs.Out = undefined;
    raster_shader.dispatchVertexShader(
        LitVs,
        &lit_outs,
        .{ .vpos = undefined, .vnrm = undefined, .cam_vp = cam_vp, .light_vp = light_vp },
        vertex_count,
        fillLitAttrs,
    );
    const final_img: [W * H][4]u8 = raster_shader.rasterizeToImage(
        LitVs,
        LitFs,
        W,
        H,
        &lit_outs,
        &indices,
        .{
            .frag_normal = undefined,
            .frag_lpos = undefined,
            .shadow = shadow_ref,
            .ldir = light_dir,
            .albedo = base_color,
        },
        comptime autoConnect(LitVs.Out, LitFs.Io),
        .{ .front_face = .none },
        .{ 12, 12, 28, 255 }, // clear = dark sky (kept out of the shadow band)
    );

    // ---- Classify pixel luminances. Fully-lit ground ~ base*(0.25+0.75*0.9) ~
    // 176; shadowed ground ~ base*0.25 ~ 48; sky ~ 15. Count the two ground
    // bands; both must be populated for a real cast shadow to exist. ----
    var shadow_px: u32 = 0;
    var lit_px: u32 = 0;
    for (final_img) |px| {
        const l: f32 = luminance(px);
        if (l >= 30 and l <= 80) {
            shadow_px += 1;
        }
        if (l >= 150 and l <= 200) {
            lit_px += 1;
        }
    }

    // (No stdout here: this runs under `zig build test`'s `--listen=-` IPC, which
    // std.debug.print would corrupt. The assertions below ARE the test; run the
    // file standalone with a debug main if a visual of the shadow map is wanted.)

    // ---- Rigorous, targeted check: a ground point KNOWN to sit in the panel's
    // cast shadow must be markedly darker than a ground point in the open. The
    // panel (centre x=0, y=1.2) casts along -L onto the ground near x~-0.47, so
    // (-0.45,0,0) is shadowed and (1.8,0,0) is lit; the camera sees both (the
    // low panel doesn't screen-occlude either). This distinguishes a real cast
    // shadow from residual acne (which the raised bias has removed). ----
    const shadow_pt: ?[2]usize = projectToPixel(cam_vp, .{ -0.45, 0, 0 }, W, H);
    const lit_pt: ?[2]usize = projectToPixel(cam_vp, .{ 1.8, 0, 0 }, W, H);
    try expect(shadow_pt != null and lit_pt != null);
    const l_shadow: f32 = luminance(final_img[shadow_pt.?[1] * W + shadow_pt.?[0]]);
    const l_lit: f32 = luminance(final_img[lit_pt.?[1] * W + lit_pt.?[0]]);
    try expect(l_lit - l_shadow > 60.0); // clearly darker in shadow
    try expect(l_shadow < 90.0); // shadow-pt really is in shadow (~ ambient)
    try expect(l_lit > 140.0); // lit-pt really is lit

    try expect(lit_px > 100); // the scene is mostly lit ground + panel
    try expect(shadow_px > 15); // a distinct shadow region exists
}
