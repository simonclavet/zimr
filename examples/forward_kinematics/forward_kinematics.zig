// examples/forward_kinematics/forward_kinematics.zig
//
// Forward kinematics: a chain of bones where each joint's world transform is
// its PARENT's world transform composed with the joint's local rotation. The
// angles animate (a phase-shifted sine down the chain) so the arm coils and
// sways, and the whole rig slowly spins about Y so bones pass in front of each
// other — a direct test of depth.
//
// It also exercises the custom-pipeline API on a real 3D job: ONE instanced
// draw renders all N bones. Per-bone data (a clip-space matrix, a rotation-only
// matrix for normals, and a tint) lives in a read-only STORAGE buffer indexed
// by @builtin(instance_index). No per-draw UBO churn, so none of the
// "UBO-between-draws" hazard. Depth comes from the window opting into
// depth_format, which makes the 2D main pass carry a depth attachment that a
// depth=.less custom pipeline matches.
//
// Build:      zig build wgpu-forward-kinematics
// Standalone: zig build wgpu-forward-kinematics-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const co = @import("example_common");
const Mat = zm.Mat;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const rotationZ = zm.rotationZ;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const lookAtRh = zm.lookAtRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const vec = zm.vec;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const joint_count: usize = 8;
const seg_len: f32 = 0.55;
const thickness: f32 = 0.30;

const Vtx = extern struct { pos: [3]f32, nrm: [3]f32 };

// Per-bone record mirroring the WGSL `Instance` storage struct (144 bytes).
const Instance = extern struct {
    mvp: [16]f32,
    nrm: [16]f32,
    color: [4]f32,
};

const Light = extern struct {
    dir: [4]f32,
    ambient: [4]f32,
};

// A unit cube centered at the origin, 36 vertices (6 faces x 2 tris), each
// carrying a face normal. Built at comptime from 6 face quads.
const box_verts: [36]Vtx = buildBox();

fn buildBox() [36]Vtx {
    var out: [36]Vtx = undefined;
    var w: usize = 0;
    const tri = [6]usize{ 0, 1, 2, 0, 2, 3 };
    const uv = [4][2]f32{ .{ -0.5, -0.5 }, .{ 0.5, -0.5 }, .{ 0.5, 0.5 }, .{ -0.5, 0.5 } };
    for (0..3) |a| {
        const u: usize = (a + 1) % 3;
        const v: usize = (a + 2) % 3;
        for ([2]f32{ -0.5, 0.5 }) |half| {
            var quad: [4][3]f32 = undefined;
            for (uv, 0..) |c, k| {
                var p: [3]f32 = .{ 0, 0, 0 };
                p[a] = half;
                p[u] = c[0];
                p[v] = c[1];
                quad[k] = p;
            }
            var nrm: [3]f32 = .{ 0, 0, 0 };
            nrm[a] = if (half < 0) -1.0 else 1.0;
            for (tri) |ti| {
                out[w] = .{ .pos = quad[ti], .nrm = nrm };
                w += 1;
            }
        }
    }
    return out;
}

const fk_wgsl =
    \\struct Instance {
    \\  mvp: mat4x4<f32>,
    \\  nrm: mat4x4<f32>,
    \\  color: vec4<f32>,
    \\};
    \\struct Light { dir: vec4<f32>, ambient: vec4<f32> };
    \\@group(0) @binding(0) var<uniform> light: Light;
    \\@group(0) @binding(1) var<storage, read> instances: array<Instance>;
    \\
    \\struct VsOut {
    \\  @builtin(position) clip: vec4<f32>,
    \\  @location(0) normal: vec3<f32>,
    \\  @location(1) color: vec3<f32>,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>,
    \\           @builtin(instance_index) ii: u32) -> VsOut {
    \\  let inst = instances[ii];
    \\  var out: VsOut;
    \\  out.clip = inst.mvp * vec4<f32>(pos, 1.0);
    \\  out.normal = (inst.nrm * vec4<f32>(nrm, 0.0)).xyz;
    \\  out.color = inst.color.rgb;
    \\  return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    \\  let n = normalize(in.normal);
    \\  let l = normalize(-light.dir.xyz);
    \\  let diff = max(dot(n, l), 0.0);
    \\  let lit = in.color * (light.ambient.rgb + diff * vec3<f32>(1.0, 1.0, 1.0));
    \\  return vec4<f32>(lit, 1.0);
    \\}
;

const State = struct {
    font: z.Font,
    pipeline: z.Pipeline,
    vbo: z.wgpu.BufferHandle,
    instances: z.wgpu.BufferHandle,
    light: z.wgpu.BufferHandle,
    bind_group: z.wgpu.BindGroupHandle,
};

fn hsv(h: f32, s: f32, v: f32) [4]f32 {
    const c: f32 = v * s;
    const hp: f32 = h * 6.0;
    const x: f32 = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m: f32 = v - c;
    var rgb: [3]f32 = .{ 0, 0, 0 };
    if (hp < 1.0) {
        rgb = .{ c, x, 0 };
    } else if (hp < 2.0) {
        rgb = .{ x, c, 0 };
    } else if (hp < 3.0) {
        rgb = .{ 0, c, x };
    } else if (hp < 4.0) {
        rgb = .{ 0, x, c };
    } else if (hp < 5.0) {
        rgb = .{ x, 0, c };
    } else {
        rgb = .{ c, 0, x };
    }
    return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m, 1 };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(box_verts)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "fk_box_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&box_verts));

    const instances: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = joint_count * @sizeOf(Instance),
        .usage = .{ .storage = true, .copy_dst = true },
        .label = "fk_instances",
    });

    const light_init: Light = .{ .dir = .{ -0.4, -0.7, -0.55, 0 }, .ambient = .{ 0.20, 0.22, 0.28, 0 } };
    const light: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(Light),
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = "fk_light",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, light, 0, std.mem.asBytes(&light_init));

    const bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .uniform_buffer = .{} } },
        .{ .binding = 1, .visibility = .{ .vertex = true }, .resource = .{ .storage_buffer = .{ .read_only = true } } },
    }, "fk_bgl");

    const bind_group: z.wgpu.BindGroupHandle = try z.material.bindGroup(gpa, f, bgl, &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = light } } },
        .{ .binding = 1, .resource = .{ .buffer = .{ .handle = instances } } },
    }, "fk_bg");

    const layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Vtx),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    const pipeline: z.Pipeline = try z.Pipeline.init(gpa, f, .{
        .wgsl = fk_wgsl,
        .layouts = &.{layout},
        .bind_group_layouts = &.{bgl},
        .depth = .less,
        .cull = .none,
        .label = "forward_kinematics",
    });

    // bgl fed both the bind group and the pipeline's layout; the pipeline has
    // internalized what it needs, so the build-time layout can be released now.
    z.wgpu.destroyBindGroupLayout(bgl);

    s.* = .{
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24),
        .pipeline = pipeline,
        .vbo = vbo,
        .instances = instances,
        .light = light,
        .bind_group = bind_group,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    const view: Mat = lookAtRh(vec(0, 0.3, 7.5), vec(0, 0.2, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.7, aspect, 0.1, 100.0);
    const view_proj: Mat = mulMat(proj, view);

    // Root frame: spin the whole rig about Y so depth ordering changes, and
    // drop the base so the chain rises through the middle of the view.
    const total: f32 = @as(f32, joint_count) * seg_len;
    var joint_world: Mat = mulMat(rotationY(t * 0.55), translation(0, -total * 0.5, 0));

    var records: [joint_count]Instance = undefined;
    var i: usize = 0;
    while (i < joint_count) : (i += 1) {
        const fi: f32 = float(i);
        // Phase-shifted sway about Z plus a gentle bend about X down the chain.
        const ang_z: f32 = std.math.sin(t * 1.6 + fi * 0.7) * 0.42;
        const ang_x: f32 = std.math.sin(t * 1.1 + fi * 0.5) * 0.18;
        const local_rot: Mat = mulMat(rotationZ(ang_z), rotationX(ang_x));

        // Rotation applied at this joint (rigid -> good for normals too).
        const rot_world: Mat = mulMat(joint_world, local_rot);

        // The bone box spans [0, seg_len] in local +Y, with `thickness` sides.
        const bone_local: Mat = mulMat(translation(0, seg_len * 0.5, 0), scaling(thickness, seg_len, thickness));
        const model: Mat = mulMat(rot_world, bone_local);

        records[i] = .{
            .mvp = matToArray(mulMat(view_proj, model)),
            .nrm = matToArray(rot_world),
            .color = hsv(fi / @as(f32, joint_count), 0.55, 0.95),
        };

        // Advance to the next joint's base: up the length of this bone.
        joint_world = mulMat(rot_world, translation(0, seg_len, 0));
    }

    z.wgpu.queueWriteBuffer(f.gpu.queue, s.instances, 0, std.mem.sliceAsBytes(&records));

    const ps: *z.PassState = f.gl.pass;
    s.pipeline.bind(ps);
    s.pipeline.setBindGroup(ps, 0, s.bind_group);
    s.pipeline.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(box_verts)));
    s.pipeline.drawArrays(ps, box_verts.len, joint_count);

    co.caption(f.gl, s.font, "forward_kinematics: one instanced draw, per-joint world matrices");
    z.endDrawing(f.gl);
}

fn matToArray(m: Mat) [16]f32 {
    var out: [16]f32 = undefined;
    inline for (0..4) |r| {
        inline for (0..4) |c| {
            out[r * 4 + c] = m[r][c];
        }
    }
    return out;
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.wgpu.destroyRenderPipeline(s.pipeline.handle);
    z.wgpu.destroyPipelineLayout(s.pipeline.layout);
    z.wgpu.destroyShaderModule(s.pipeline.module);
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.instances);
    z.wgpu.destroyBuffer(s.light);
    z.wgpu.destroyBindGroup(s.bind_group);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - forward kinematics",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.03, .g = 0.04, .b = 0.06, .a = 1.0 },
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
