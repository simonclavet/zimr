//! lint:alias wgpu_app
//! src/wgpu_app.zig — the WebGPU `App` + `Frame` run-loop.
//!
//! This is the WebGPU counterpart to `zimr.AppBridge` + `zimr.Frame` (the GL
//! path). It exists so a WebGPU example is written in the SAME shape as a GL
//! example:
//!
//!   var zimr_app: z.App = .{};
//!   pub fn main() !void {
//!       try zimr_app.run(.{ .window = .{ .title = "...", .width = 800, .height = 600 } },
//!           State, initState, update);
//!   }
//!   fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void { ... }
//!   fn update(f: *z.Frame, s: *State) void { ... }
//!
//! WHY A PARALLEL TYPE (not one shared AppBridge)
//! The GL `Frame.gl` is a concrete `*rlgl.GlState`, and `AppBridge.run` builds
//! a GL `App` (canvas + GL context + audio + the dom RAF loop). Threading a
//! backend tag through all of that, or making `Frame.gl` polymorphic, would
//! ripple through 100+ GL examples and every `gl: anytype` drawing function.
//! Instead this module mirrors the *shape* (same `run` signature, same
//! `fn update(f, s)` author experience) with its own `Frame` whose drawing
//! handle is the WebGPU one. Examples differ by the entry type's namespace,
//! nothing else. (The WebGPU stack is documented atop `src/zimr.zig`.)
//!
//! THE FRAME LOOP
//! The WebGPU JS bridge already runs the RAF loop and calls the wasm `update`
//! export each tick (and `_initialize` once at start, which runs `main` under
//! the WASI reactor). So `main` calls `App.run`, which stores the live app on
//! the module-level `active_app` and registers the user's typed update thunk;
//! the `update` export below builds a fresh `Frame` and dispatches to it. No
//! globals beyond `active_app` (the same single-bridge-pointer pattern the GL
//! path uses via `@import("root").zimr_app`).
//!
//! v1 SCOPE (this is N3 in wgpu_new_beginnings.md)
//!  * `Frame.gl` (the immediate-mode `WgpuGl` adapter that satisfies
//!    `gl_iface`) is N4 — not here yet. This Frame carries the GPU handle
//!    (`f.gpu`), time, and window; examples drive `z.pbr3d` / `Renderer2D`
//!    through `f.gpu` for now.
//!  * `Frame.input` is a stub until input wiring lands (also N4-era): the
//!    WebGPU demos have no input exports yet.

const std = @import("std");
const gpu = @import("gpu.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const zm = @import("zm");
const Color = zm.Color;
const Camera2D = zm.Camera2D;
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const asinRad = zm.asinRad;
const atan2Rad = zm.atan2Rad;
const clamp = zm.clamp;
const float = zm.float;
const identity = zm.identity;
const inverse = zm.inverse;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const pi = zm.pi;
const tau = zm.tau;
const vec = zm.vec;
const normalize = zm.normalize;
const cross = zm.cross;
const vec4 = zm.vec4;
const assert = zm.assert;

const wgpu = @import("wgpu.zig");
const Shader2D = @import("shader2d.zig").Shader2D;
const profiler = @import("profiler.zig");
const memwatch = @import("memwatch.zig");
const gpu_iface = @import("gpu_iface.zig");
const BindGroupCache = @import("BindGroupCache.zig");
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const renderer_2d = @import("renderer_2d.zig");
const draw3d = @import("draw3d.zig");

// S4: these were byte-identical reimplementations of draw3d's — now
// re-exports (a re-export is not a redefinition under the dup-pub-fn rule).
pub const genMeshCube = draw3d.genMeshCube;
pub const genMeshTangents = draw3d.genMeshTangents;
pub const updateMeshBuffer = draw3d.updateMeshBuffer;
pub const uploadMesh = draw3d.uploadMesh;
pub const getSphereBoundingBox = draw3d.getSphereBoundingBox;
pub const getCylinderBoundingBox = draw3d.getCylinderBoundingBox;
pub const getCapsuleBoundingBox = draw3d.getCapsuleBoundingBox;
const types = @import("types.zig");
const image_mod = @import("image.zig"); // lint:off canonical-alias: `image` is a parameter name here

pub const colorFromHSV = types.colorFromHSV;
// The input state model is shared with the GL path (raylib-faithful: current/
// previous buttons, drag tracking, wheel, char queue). It's pure data + state
// logic — runtime.zig's dom externs are all at fn scope, so importing this
// namespace pulls no GL/WebGL surface into the wasm.
const input = @import("runtime.zig").input;

const GpuFrame = gpu.GpuFrame;
const Backend = gpu_iface.WgpuBackend;
const Renderer2D = renderer_2d.Renderer2D;
pub const WgpuGl = @import("WgpuGl.zig");
const PassState = gpu_iface.PassState;

// ============================================================================
// Config — mirrors zimr.Config's window shape so examples read the same.
// ============================================================================

pub const ScaleMode = enum {
    /// Logical coords == CSS px; the 2D ortho tracks the live canvas size.
    /// Lay out relative to f.window.screen_width/height (don't hardcode). The
    /// app fills the canvas but its coordinate space changes with the viewport.
    responsive,
    /// Fixed logical design size (`width` x `height`), scaled uniformly to fit
    /// the canvas with letterbox/pillarbox bars on aspect mismatch. The
    /// coordinate space is CONSTANT regardless of how the host sizes the canvas,
    /// so the app looks identical across browsers/devices. Input is mapped back
    /// to design space. Use for phone apps / fixed layouts that want one look
    /// everywhere.
    fit,
};

pub const ClearColor = struct { r: f32 = 0.05, g: f32 = 0.06, b: f32 = 0.10, a: f32 = 1.0 };

pub const WindowConfig = struct {
    title: []const u8 = "zimr",
    width: u32 = 800,
    height: u32 = 600,
    /// `.responsive` (default) or `.fit` — see ScaleMode.
    scale_mode: ScaleMode = .responsive,
    /// Depth-stencil format for the frame-owned depth attachment (GpuFrame
    /// owns + auto-resizes it). `null` = a 2D app with no depth pass.
    /// Depth-stencil format for the frame's depth attachment, or null for NONE.
    /// Defaults to null: the common 2D path (shapes/text/UI, all ported 2D
    /// examples) draws through a pipeline WITHOUT depth state, and a pass depth
    /// attachment would mismatch it -> GPU validation error -> black frame (the
    /// recurring "ported 2D demo is black" footgun). 3D demos that need depth
    /// OPT IN explicitly (.depth_format = .depth24_plus, or set f.gpu.depth_format
    /// in initState).
    depth_format: ?wgpu.TextureFormat = null,
    /// Clear color used by `beginDrawing` when the example doesn't override it.
    clear: ClearColor = .{},
};

/// Coarse per-frame phase used only for debug validation (gated by
/// `zm.allow_assert`). It lets the renderer turn illegal call orderings —
/// a 2D draw inside a 3D block, `endDrawing` with a 3D block still open,
/// `endMode3D` with no matching `beginMode3D` — into an actionable `assertf`
/// message instead of silent corruption. Compiled out of ship builds.
pub const FramePhase = enum { idle, frame_2d, mode_3d };

pub const Config = struct {
    window: WindowConfig = .{},
    /// Seed for `Frame.random`. Set it for a reproducible run; leave it null to
    /// get a fresh seed each launch — from the host's crypto entropy in a real
    /// browser, or a fixed constant on native/headless so tests stay stable.
    rng_seed: ?u64 = null,
};

/// The seed used when `Config.rng_seed` is null and no real entropy is
/// available (native builds, or a headless host that no-ops the crypto import
/// such as the smoke). Kept fixed so those runs are reproducible.
const rng_fallback_seed: u64 = 0x853c_49e6_748f_ea9b;

/// Resolve the seed for the run's PRNG. An explicit `Config.rng_seed` always
/// wins. Otherwise, on wasm we ask the host's `crypto.getRandomValues` for real
/// per-launch entropy; the buffer is PRE-FILLED with `rng_fallback_seed` so a
/// host that no-ops the crypto import (the smoke) leaves it fixed and stays
/// reproducible, while a real browser overwrites it. Native falls back directly.
fn resolveRngSeed(explicit: ?u64) u64 {
    if (explicit) |s| {
        return s;
    }
    if (comptime builtin.target.cpu.arch.isWasm()) {
        var b: [8]u8 = @bitCast(rng_fallback_seed);
        web.dom.crypto_random_fill(&b, b.len);
        return std.mem.readInt(u64, &b, .little);
    }
    return rng_fallback_seed;
}

// ============================================================================
// Per-frame state views (stamped fresh each tick onto Frame).
// ============================================================================

/// Read-only wall-clock + delta for the current frame. Mirrors the GL
/// `TimeState` shape (delta_time + time) so example logic ports unchanged.
pub const TimeState = struct {
    /// Seconds since the previous frame.
    delta_time: f32 = 0,
    /// Seconds since the app started.
    time: f32 = 0,
    /// Frames rendered so far (0 on the first update).
    frame_count: u64 = 0,
};

/// Read-only canvas/surface dimensions for the current frame. `screen_width`
/// and `screen_height` are LOGICAL (CSS) pixels — the same space 2D drawing and
/// input coordinates use (logical px == CSS px in responsive mode). The GPU
/// renders at backing resolution (CSS × devicePixelRatio); that's transparent
/// supersampling, handled by the frame/depth machinery, not exposed here.
/// from the live surface — correct at any device-pixel-ratio or after resize.
pub const WindowState = struct {
    screen_width: u32 = 0,
    screen_height: u32 = 0,

    /// Convenience: surface aspect ratio (width / height), 1.0 if unknown.
    pub fn aspect(self: WindowState) f32 {
        if (self.screen_height == 0) {
            return 1.0;
        }
        return float(self.screen_width) / float(self.screen_height);
    }

    /// Logical width/height as f32. The draw API is f32-centric, so layout code
    /// reads `f.window.widthf()` instead of `@floatFromInt(f.window.screen_width)`
    /// at every site (the recurring cast smell across ports).
    pub fn widthf(self: WindowState) f32 {
        return @floatFromInt(self.screen_width);
    }
    pub fn heightf(self: WindowState) f32 {
        return @floatFromInt(self.screen_height);
    }
};

// ============================================================================
// Frame — the per-tick parameter, mirroring zimr.Frame.
// ============================================================================

/// The per-frame parameter handed to `update`. Like the GL `Frame`, it has no
/// methods; operations are free functions / renderer methods that take the
/// handle. v1 fields: the GPU frame handle, time, and window. (`gl` + `input`
/// arrive in N4.)
pub const Frame = struct {
    /// The WebGPU per-frame state container (device/queue/surface/caches +
    /// the frame-owned depth attachment). Drive `z.pbr3d` directly with this,
    /// or open a raw pass via `z.WgpuBackend`.
    gpu: *GpuFrame,
    /// The 2D immediate-mode drawing context (the `gl: anytype` adapter that
    /// satisfies gl_iface). Use with `z.beginDrawing(f.gl)` / `z.rlBegin(f.gl)`
    /// / `z.drawRectangle(f.gl, ...)` — the same free-function shape as the GL
    /// path. Backed by the App's Renderer2D (lazily created on first
    /// beginDrawing).
    gl: *WgpuGl,
    /// Input state for the frame (mouse position/buttons/wheel, keys, touches),
    /// raylib-faithful and shared with the GL path. Read via the free-function
    /// getters: `z.getMousePosition(f.input)`, `z.isMouseButtonDown(f.input, .left)`,
    /// `z.getMouseWheelMove(f.input)`, etc. All coordinates are LOGICAL pixels.
    input: *input.InputState,
    /// Audio device for the frame. Call `z.audio_device.init(f.audio_device)`
    /// once before using `z.sounds`/`z.waves`/`z.composer`. Backend-agnostic
    /// (Web Audio); shared with the GL path.
    audio_device: *@import("sound.zig").audio_device.AudioDeviceState,
    time: TimeState,
    window: WindowState,
    /// The run's PRNG, seeded once at startup (see `Config.rng_seed`). It's the
    /// stdlib `std.Random` interface: `f.random.float(f32)`,
    /// `f.random.intRangeLessThan(u32, 0, n)`, `f.random.boolean()`, etc. The
    /// generator persists across frames (its state advances); it is NOT reseeded
    /// per tick, so sequences stay coherent frame to frame.
    random: std.Random,
};

// ============================================================================
// App — owns the long-lived WebGPU resources + the typed update dispatch.
// ============================================================================

/// Type-erased per-frame dispatch thunk (built by `run`, called by the
/// `update` export). Mirrors `AppBridge.update_fn`.
const UpdateThunk = *const fn (frame: *Frame, state: ?*anyopaque) void;

/// A complete example/app as DATA — no globals, no `main`: its config plus the
/// three lifecycle fns over its `State`. A standalone build runs ONE of these
/// full-screen via the generic runner (`src/wgpu_runner.zig`); the multi-app
/// launcher (P3) holds many (type-erased) and ticks each into a rect. The
/// example exposes `pub const app = z.AppSpec(State){ ... }` and nothing else —
/// the runner/launcher owns beginDrawing/clearBackground/endDrawing and the wasm
/// entry. `update` draws into the Frame it's handed (its viewport): local
/// coords, reads `f.window` for its size, paints its own background, and does
/// NOT open/clear/close the frame.
pub fn AppSpec(comptime StateT: type) type {
    return struct {
        pub const State = StateT;
        config: Config,
        /// Construct the State in place: fill `s.* = .{...}` (still an exhaustive
        /// literal, so a forgotten field stays a compile error), then take stable
        /// interior pointers — `&s.field`, cached sub-allocators, self-referential
        /// wiring — which are valid forever because `s` is already at its final
        /// address.
        init: fn (Allocator, *Frame, *StateT) anyerror!void,
        /// Free everything the init allocated through the allocator. Exercised by
        /// the launcher's reset + leak check (P3); a forever standalone never
        /// calls it, but it's REQUIRED so the contract is uniform.
        deinit: fn (Allocator, *StateT) void,
        /// Draw one frame into the handed Frame's viewport. No begin/clear/end.
        update: fn (*Frame, *StateT) void,
        /// MIGRATION FLAG (temporary): when false (default) the runner wraps
        /// `update` in `beginDrawing`/`endDrawing` (opens the screen pass BEFORE
        /// update). When true, the example owns its own `beginDrawing`/
        /// `endDrawing` so it can render offscreen (RTT) BEFORE opening the
        /// screen — required on tile-based mobile GPUs, where ending+reopening
        /// the swapchain mid-frame causes frame-feedback tiling. Being rolled
        /// out to every example; once all are migrated this field and the
        /// runner's wrap are deleted (uniform explicit begin/endDrawing).
        manages_own_frame: bool = false,

        /// Memory-management mode (leak_detection.md). `.managed` (default): the
        /// example must free EVERYTHING in `deinit`. The leak-test asserts both a
        /// FLAT twice-lifecycle GPU-handle census AND — via a CountingAllocator
        /// wrapping the example's gpa — that net live CPU bytes return to their
        /// pre-lifecycle baseline after `deinit` (b2 == b1), proving every
        /// individual allocation was freed, not just GPU handles. `.arena`: the
        /// example is handed the frame arena, `deinit` may be a stub, and there is
        /// no leak gate.
        ///
        /// POLICY: zimr's own examples ship with `.managed` and a leak-tight
        /// `deinit` — they are the reference for how to release resources, so
        /// they must prove they leak nothing. `.arena` exists for EXTERNAL /
        /// embedding apps that deliberately opt out of leak checking (e.g. a
        /// throwaway prototype); an in-tree example should use it only if a
        /// leak-tight `deinit` is genuinely impractical, and that is a code-review
        /// question, not a convenience.
        memory: MemoryMode = .managed,
    };
}

/// See `AppSpec.memory` for the full policy. In short: examples use `.managed`
/// (free everything, leak-checked); `.arena` is the opt-out for external apps.
pub const MemoryMode = enum(u8) { arena, managed };

/// Type-erased form of an `AppSpec(State)` — what a heterogeneous launcher list
/// holds. `init` constructs the State into a caller-provided slot of
/// `state_size`/`state_align`. Produced by `eraseApp`.
pub const AppVtable = struct {
    config: Config,
    state_size: usize,
    state_align: usize,
    init: *const fn (Allocator, *Frame, *anyopaque) anyerror!void,
    deinit: *const fn (Allocator, *anyopaque) void,
    update: *const fn (*Frame, *anyopaque) void,
};

/// Construct a spec's State into a caller-provided, already-stable slot `sp`.
/// Both entry paths — the single-app runner (via `App.run`) and the launcher
/// (via `eraseApp`) — route through here. The user fills `sp` in place: its
/// address is final, so any interior pointer they take stays valid for the app's
/// lifetime. `spec` is comptime, so the call folds away.
pub fn initInto(
    comptime spec: anytype,
    gpa: Allocator,
    f: *Frame,
    sp: *@TypeOf(spec).State,
) anyerror!void {
    try spec.init(gpa, f, sp);
}

/// Erase a typed `AppSpec(State)` (a comptime `pub const app`) into an AppVtable
/// the launcher can store next to others of different State types. The thunks
/// cast the opaque slot back to `*State`; `init` constructs straight into the
/// slot (result-location, no move) so self-referential State fields stay valid.
pub fn eraseApp(comptime spec: anytype) AppVtable {
    const State = @TypeOf(spec).State;
    const T = struct {
        fn initFn(gpa: Allocator, f: *Frame, ptr: *anyopaque) anyerror!void {
            const sp: *State = @ptrCast(@alignCast(ptr));
            try initInto(spec, gpa, f, sp);
        }
        fn deinitFn(gpa: Allocator, ptr: *anyopaque) void {
            const sp: *State = @ptrCast(@alignCast(ptr));
            spec.deinit(gpa, sp);
        }
        fn updateFn(f: *Frame, ptr: *anyopaque) void {
            const sp: *State = @ptrCast(@alignCast(ptr));
            spec.update(f, sp);
        }
    };
    return .{
        .config = spec.config,
        .state_size = @sizeOf(State),
        .state_align = @alignOf(State),
        .init = T.initFn,
        .deinit = T.deinitFn,
        .update = T.updateFn,
    };
}

/// Where + how a child app's local coordinate space maps onto the parent
/// screen, for the multi-app `pushViewport`/`popViewport` pair. `rect` is the
/// on-screen region (logical px) the child occupies. The child draws in a
/// `logical_w x logical_h` space; with `scale_to_fit` that space is uniformly
/// scaled + centered into `rect` (letterbox — the thumbnail case), otherwise it
/// maps 1:1 and the caller sets `logical_w/h` to `rect`'s size (the reflow case).
pub const Placement = struct {
    rect: types.Rectangle,
    logical_w: f32,
    logical_h: f32,
    scale_to_fit: bool = false,
};

/// Saved drawing state for one `pushViewport` level; restored by `popViewport`.
const ViewportSave = struct {
    modelview: Mat,
    window: WindowState,
};

/// Uniform scale + top-left offset (in CSS px) that maps the design rect
/// (dw x dh) centered into the canvas (cw x ch). scale = min(cw/dw, ch/dh).
const FitXform = struct { scale: f32, off_x: f32, off_y: f32 };

fn fitScaleOffset(dw: f32, dh: f32, cw: f32, ch: f32) FitXform {
    const s: f32 = @min(cw / dw, ch / dh);
    return .{ .scale = s, .off_x = (cw - dw * s) * 0.5, .off_y = (ch - dh * s) * 0.5 };
}

/// Top-left ortho for .fit: a design-space point (x,y) in [0,dw]x[0,dh] maps to
/// CSS px (off + x*scale), then to NDC. Equivalent to
/// orthoTopLeft(cw,ch) * translate(off) * scale(s) collapsed into one matrix.
fn fitOrtho(dw: f32, dh: f32, cw: f32, ch: f32) [16]f32 {
    const f: FitXform = fitScaleOffset(dw, dh, cw, ch);
    // Map design (x,y) -> NDC: ndc_x = 2*(off_x + x*s)/cw - 1
    //                          ndc_y = 1 - 2*(off_y + y*s)/ch
    const ax: f32 = 2.0 * f.scale / cw;
    const bx: f32 = 2.0 * f.off_x / cw - 1.0;
    const ay: f32 = -2.0 * f.scale / ch;
    const by: f32 = 1.0 - 2.0 * f.off_y / ch;
    // column-major 4x4 (matches orthoTopLeft's layout)
    return .{
        ax, 0,  0, 0,
        0,  ay, 0, 0,
        0,  0,  1, 0,
        bx, by, 0, 1,
    };
}

pub const App = struct {
    gpu_frame: GpuFrame = .{},
    pipeline_cache: gpu.PipelineCache = undefined,
    bind_group_cache: BindGroupCache = undefined,
    config: Config = .{},

    // 2D drawing state (for the `f.gl` immediate-mode path). The Renderer2D is
    // created lazily on the first beginDrawing — a pure-3D app (pbr3d) never
    // pays for it. `gl` + `pass` are the live per-frame drawing handles; `gl`
    // is handed to the user as `f.gl` and points at `renderer_2d` + `pass`.
    renderer_2d: ?Renderer2D = null,
    /// True once this frame's encoder (beginFrame) + Renderer2D exist.
    /// Set by `ensureFrame`, cleared at endFrame. Lets offscreen passes
    /// (beginTextureMode) create the encoder BEFORE beginDrawing opens the
    /// screen — the offscreen-first ordering that avoids tile-based-GPU
    /// swapchain-teardown tiling.
    frame_begun: bool = false,
    /// Set by beginTextureMode/Raw = was a SCREEN pass open when RTT began.
    /// If so, endTextureMode reopens it (legacy mid-frame RTT); if not
    /// (offscreen-first), the screen stays closed until beginDrawing.
    rtt_reopen_screen: bool = false,
    pass: PassState = undefined,
    gl: WgpuGl = undefined,
    /// Lazily-created vertex buffer for `drawFullscreenShader` — 3 Vertex2D
    /// covering clip space. Shared across all fullscreen sampler shaders so they
    /// don't each hand-roll one. `.invalid` until first use.
    fullscreen_vbo: wgpu.BufferHandle = .invalid,
    drawing_active: bool = false,
    /// Set while the Launcher is ticking a child app. Children must NOT call
    /// `endDrawing` (the runner/host owns frame begin+end); `endDrawing` asserts
    /// on this so a misbehaving child fails loudly instead of silently eating the
    /// host's frame + overlay.
    child_tick_active: bool = false,
    /// Debug-only frame phase (see `FramePhase`); transitions are checked with
    /// `zm.assertf` and compiled out when asserts are off.
    frame_phase: FramePhase = .idle,
    gpa: Allocator = undefined,
    counting: memwatch.CountingAllocator = undefined,

    // Input state, advanced once per frame (current→previous) after the user's
    // update. The JS bridge pushes events into it via the input_push_* exports.
    input_state: input.InputState = .{},

    // Audio device, handed to the user as `f.audio_device`. Left UNINITIALIZED
    // (ctx_id=0, not ready); a non-audio app never touches the Web Audio JS
    // bridge. An audio app calls `z.audio_device.init(f.audio_device)` (which is
    // what actually reaches the `extern "audio"` js_audio_* imports), then uses
    // z.sounds / z.waves / z.composer.
    audio_device: @import("sound.zig").audio_device.AudioDeviceState = .{},

    state: ?*anyopaque = null,
    update_fn: ?UpdateThunk = null,
    started_at_ms: f64 = 0,
    /// The run's PRNG, seeded once in `run()` from `config.rng_seed`. Persistent
    /// (not per-frame) so random sequences don't reset every tick. Surfaced to
    /// examples as `Frame.random`. Defaults to the fixed fallback seed so any
    /// path that builds a frame before `run()` still gets a valid generator.
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(rng_fallback_seed),
    frame_count: u64 = 0,
    /// Per-frame wasm-memory growth watchdog (compiled out in ship).
    mem_watch: memwatch.MemWatch = .{},

    // 3D immediate-mode state. `cube3d` is built lazily on the first
    // beginMode3D (a pure-2D app never pays for it); it owns the dedicated 3D
    // pipeline + the per-frame primitive batch. The camera view-projection is
    // written straight into its UBO at beginMode3D — no view state on the App.
    cube3d: ?draw3d.Cube3D = null,
    /// Camera for the current beginMode3D scope, in the form pbr3d needs
    /// (view + proj + eye). Set by `beginMode3D` (from its Camera3D), cleared
    /// by the raw `beginMode3DMatrix` (which has no eye). `drawModel3D` reads
    /// it so a scene's camera is specified ONCE, at beginMode3D, for both the
    /// immediate primitives and any pbr3d models.
    mode3d_cam: ?draw3d.pbr3d.Camera = null,

    /// Logical size of the CURRENT render target — set between
    /// begin/endTextureMode, null when targeting the backbuffer.  3D mode
    /// reads it so a camera rendered into an RTT gets the RTT's aspect
    /// instead of the window's (a half-width split-screen RTT must not
    /// render with full-canvas aspect).
    target_size: ?[2]u32 = null,

    // Multi-app viewport scoping (pushViewport/popViewport). A child app is
    // ticked into a sub-rect by setting the modelview to translate(+scale) its
    // local coords onto the screen and clipping to the rect; the per-frame ortho
    // is untouched, so many children share one open pass with no UBO conflict.
    // The stack saves modelview + window for restore on pop (depth = nesting).
    viewport_stack: [8]ViewportSave = undefined,
    viewport_depth: u8 = 0,

    /// Build the WebGPU runtime, allocate `State`, run `init_fn`, and register
    /// the per-frame dispatch. Same signature shape as `AppBridge.run` minus
    /// the explicit `gpa` (WebGPU examples use the wasm allocator, matching the
    /// other wgpu demos). After this returns, the JS RAF loop's `update` calls
    /// drive `update_fn` via the `update` export below.
    pub fn run(
        self: *App,
        cfg: Config,
        comptime State: type,
        comptime init_fn: fn (Allocator, *Frame, *State) anyerror!void,
        comptime update_fn: fn (*Frame, *State) void,
    ) !void {
        // Host gate: the WebGPU runtime depends on browser services that don't
        // exist natively. Returning an error here lets host test/lint builds
        // link (Zig DCE strips the wasm-only call chain).
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            return error.WgpuRequiresWasm;
        }

        self.counting = .{ .backing = std.heap.wasm_allocator };
        const gpa: Allocator = self.counting.allocator();
        self.config = cfg;
        self.gpa = gpa;
        self.rng = std.Random.DefaultPrng.init(resolveRngSeed(cfg.rng_seed));

        const device: wgpu.DeviceHandle = wgpu.initDevice();
        const queue: wgpu.QueueHandle = wgpu.getQueue(device);
        const surface: wgpu.SurfaceHandle = wgpu.getSurface();
        const fmt: wgpu.TextureFormat = wgpu.getSurfaceFormat(surface);

        self.pipeline_cache = gpu.PipelineCache.init(gpa, device);
        self.bind_group_cache = BindGroupCache.init(gpa, device);
        self.gpu_frame = GpuFrame.init(device, queue, surface, fmt, &self.pipeline_cache, &self.bind_group_cache);
        self.gpu_frame.depth_format = cfg.window.depth_format;

        // Pre-wire the gl handle: owner + pass pointers are stable; `renderer`
        // is filled by the first beginDrawing (which also lazily creates the
        // Renderer2D). f.gl points here, so z.beginDrawing(f.gl) can reach back.
        self.gl = .{ .renderer_slot = &self.renderer_2d, .pass = &self.pass, .owner = self };

        // init_fn CONSTRUCTS the State in place. The slot is `gpa.create`d
        // FIRST, so init_fn receives a `*State` whose address is already final:
        // interior pointers it takes (`&s.field`, cached sub-allocators,
        // self-referential wiring like UiHost.ctx.frame_arena) stay valid for the
        // app's whole lifetime — no move ever happens, so the release-only "stuck
        // at initialising…" self-pointer bug cannot occur regardless of how the
        // body is written. The in-place `s.* = .{...}` literal is still exhaustive
        // (Zig requires every no-default field set), so a forgotten field remains
        // a COMPILE ERROR — the black-mandelbrot zoom=0 class stays impossible.
        // The GPU device is live via the first Frame, so GPU handles get real
        // values too. (Legacy return-by-value inits reach here already wrapped in
        // an in-place adapter — see `initInto`.)
        var init_frame: Frame = self.makeFrame();
        const state_ptr: *State = try gpa.create(State);
        errdefer gpa.destroy(state_ptr);
        try init_fn(gpa, &init_frame, state_ptr);

        // Comptime-uniqued thunk: cast the opaque state back + call the user's
        // strongly-typed update. Resolves statically per run() instantiation.
        const Thunk = struct {
            fn dispatch(frame: *Frame, opaque_state: ?*anyopaque) void {
                const s: *State = @ptrCast(@alignCast(opaque_state.?));
                update_fn(frame, s);
            }
        };
        self.state = state_ptr;
        self.update_fn = Thunk.dispatch;
        self.started_at_ms = wgpu.nowMs();

        // active_app is the module singleton, typed ?*App, so it must be
        // declared after the App struct - yet App.run (here) assigns it.
        // An irreducible singleton<->type cycle.
        // lint:off decl-order: active_app is typed by App; App.run sets it
        active_app = self;
        // Install the profiler's clock (folds away when the profiler is
        // stripped). nowMs() now caches the performance object so the clock's own
        // cost stays out of the measurements; probe its resolution once so the UI
        // can show the floor (a sub-resolution phase reads 0).
        profiler.setClock(&profilerClock);
        profiler.probeResolution();
    }

    /// Build a fresh Frame for the current tick: refresh the live window dims
    /// and stamp the time state. The GpuFrame handle is stable across frames.
    pub fn makeFrame(self: *App) Frame {
        // Logical size: in .responsive this is the live CSS size; in .fit it's
        // the fixed design size (so layout/HUD code uses design coords).
        const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(self.gpu_frame.surface);
        const size: wgpu.SurfaceSize = switch (self.config.window.scale_mode) {
            .responsive => css,
            .fit => .{ .width = self.config.window.width, .height = self.config.window.height },
        };
        const t_ms: f64 = wgpu.nowMs();
        const elapsed_s: f32 = @floatCast((t_ms - self.started_at_ms) / 1000.0);
        return .{
            .gpu = &self.gpu_frame,
            .gl = &self.gl,
            .input = &self.input_state,
            .audio_device = &self.audio_device,
            .time = .{
                .delta_time = 0, // filled by the update export (needs prev ts)
                .time = elapsed_s,
                .frame_count = self.frame_count,
            },
            .window = .{ .screen_width = size.width, .screen_height = size.height },
            .random = self.rng.random(),
        };
    }

    /// Single source of truth for the 2D-frame PHASE flag. Every place that
    /// opens a 2D pass (beginDrawing, reopen2DPass, beginTextureMode/Raw) and
    /// endMode3D routes through here, so "a 2D frame is open" and
    /// "frame_phase == .frame_2d" can never disagree — the class of bug that let
    /// 3D-into-texture (beginMode3D inside an RT) assert after the offscreen-
    /// first change. beginMode3D sets .mode_3d directly (a sub-mode, not a frame).
    fn enterFrame2D(self: *App) void {
        self.frame_phase = .frame_2d;
    }
    /// Companion: mark the frame closed. Every frame-close (endDrawing, and the
    /// offscreen-first endTextureMode that leaves the screen shut) routes here.
    fn leaveFrame2D(self: *App) void {
        self.frame_phase = .idle;
    }

    /// Encoder accessor that ENFORCES a begun frame. EVERY render-pass open
    /// (beginDrawing, reopen2DPass, beginTextureMode/Raw/MrtRaw) grabs the
    /// encoder through here, so a begin*Mode path that forgets `ensureFrame`
    /// trips a loud assert instead of silently opening a pass on a dead encoder
    /// (renders nothing = a black screen). This is the guard that would have
    /// caught beginTextureModeMrtRaw's missing ensureFrame on its first run.
    fn frameEncoder(self: *App) wgpu.CommandEncoderHandle {
        assertf(
            self.frame_begun,
            @src(),
            "render pass opened without a begun frame - a begin*Mode path must call ensureFrame() first",
            .{},
        );
        return self.gpu_frame.encoder;
    }

    /// Ensure this frame's encoder + Renderer2D exist, idempotently. Called
    /// by beginDrawing AND by the first offscreen pass (beginTextureMode),
    /// so RTT can run before the screen opens; the encoder is created ONCE
    /// and reused by every pass, then submitted at endFrame.
    fn ensureFrame(self: *App) !void {
        if (self.frame_begun) {
            return;
        }
        if (self.renderer_2d == null) {
            self.renderer_2d = try Renderer2D.init(self.gpa, &self.gpu_frame);
        }
        // Reset the per-frame VBO/IBO ring base at TRUE frame start (here), NOT
        // at beginDrawing. Offscreen-first RTT geometry is written before
        // beginDrawing; resetting the base to 0 there would make the main pass
        // overwrite the RTT's still-referenced region in the shared frame
        // command buffer (a submit-time clobber). Resetting once per frame here
        // gives the RTT and main passes DISTINCT regions.
        self.renderer_2d.?.shapes_batch.vbo_vertex_base = 0;
        self.renderer_2d.?.shapes_batch.ibo_index_base = 0;
        _ = Backend.beginFrame(&self.gpu_frame);
        self.frame_begun = true;
    }

    /// Open a 2D drawing frame: acquire the surface + encoder, begin a render
    /// pass (clearing to `clear_color`), lazily create the Renderer2D, program
    /// its per-frame view-projection to a top-left ortho matching the live
    /// surface, bind its pipeline, and hand back the `WgpuGl` to draw through.
    /// Mirrors the GL path's `beginDrawing`. Returns the live `*WgpuGl`.
    fn beginDrawing(self: *App, clear_color: ClearColor) !*WgpuGl {
        // In the launcher the runner opens the frame + pass BEFORE ticking this
        // child (`child_tick_active`). A child beginning its own frame would
        // double-begin the surface; instead reuse the already-open frame so the
        // IDENTICAL example body works standalone (opens the frame here) and as
        // a launcher child (no-op begin). The child draws into the runner's
        // pass; the runner's clear stands (a child cannot re-clear a load-op
        // pass — see clearBackground). Mirrors the endDrawing no-op below.
        // A render pass is already open for this frame, so opening a SECOND one
        // here would double-begin the surface: the cryptic "recording in
        // CommandEncoder which is locked while RenderPassEncoder is open" ->
        // invalid CommandBuffer -> black screen (took three device round-trips to
        // diagnose). Two ways in: (1) a launcher child, whose runner opened the
        // frame + pass before ticking it (`child_tick_active`); (2) a redundant
        // beginDrawing in an app whose runner already opened the frame's pass, or
        // any second beginDrawing in one frame. Both reuse the open pass instead
        // — so an example that (needlessly) calls beginDrawing renders correctly
        // rather than corrupting the frame. 2D frames use `clearViewport`; a
        // stray beginDrawing is now a safe no-op. (`clearBackground` still works:
        // it ends the pass — clearing `drawing_active` — before reopening.)
        if (self.child_tick_active or self.drawing_active) {
            self.drawing_active = true;
            self.enterFrame2D();
            return &self.gl;
        }
        try self.ensureFrame();

        self.pass = Backend.beginRenderPass(self.frameEncoder(), .{
            .color_view = self.gpu_frame.surface_view,
            .clear = .{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a },
            // Attach depth when the window opted in (depth_format set). The 3D
            // immediate path batches into THIS single pass (no pass switch),
            // and the 2D pipelines carry a compare=always depth state to match.
            // `fctx.depth_view` is .invalid when no depth target → depth-free.
            .depth_view = self.gpu_frame.depth_view,
        });
        // Program the 2D view-projection to a top-left ortho at the LOGICAL
        // (CSS) size, so 2D coordinates are logical px and match input coords
        // (which arrive as CSS px). The GPU still renders at backing resolution
        // (canvas.width = CSS × DPR) — that's just supersampling; the depth
        // attachment tracks backing px via ensureDepth, independent of this.
        const size: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(self.gpu_frame.surface);
        const css_w: f32 = float(@max(size.width, 1));
        const css_h: f32 = float(@max(size.height, 1));
        const vp: [16]f32 = switch (self.config.window.scale_mode) {
            // Responsive: ortho == live CSS size; coords are CSS px.
            .responsive => renderer_2d.orthoTopLeft(css_w, css_h),
            // Fit: a CONSTANT design-size coordinate space, uniformly scaled +
            // centered into the canvas (letterbox/pillarbox), so the app looks
            // identical regardless of how the host sizes the canvas. Baked into
            // the ortho (no GPU viewport needed). The fit transform is also
            // recorded for input mapping (see fitTransform / makeFrame).
            .fit => fitOrtho(
                @floatFromInt(self.config.window.width),
                @floatFromInt(self.config.window.height),
                css_w,
                css_h,
            ),
        };
        self.renderer_2d.?.updatePerFrame(&self.gpu_frame, .{ .view_projection = vp });
        self.renderer_2d.?.bindForPass(&self.pass);

        self.pass.batch = &self.renderer_2d.?.shapes_batch;
        // (Per-frame VBO/IBO ring base is reset in ensureFrame, at true frame
        // start, so offscreen-first RTT geometry isn't clobbered — see there.)
        // Reset the gl handle to a fresh per-frame state (init applies the
        // field defaults: identity matrices, empty group, white color), then
        // restore the stable owner back-pointer.
        self.gl = WgpuGl.init(&self.renderer_2d, &self.pass);
        self.gl.owner = self;
        // Backing render-target size — for scissor clamping (WebGPU rejects an
        // oversized scissor rect; see WgpuGl.scissor/disable).
        const backing: wgpu.SurfaceSize = wgpu.getSurfaceSize(self.gpu_frame.surface);
        self.gl.render_w = backing.width;
        self.gl.render_h = backing.height;
        self.drawing_active = true;
        self.enterFrame2D();
        return &self.gl;
    }

    /// Close the 2D drawing frame: flush any batched geometry, end the render
    /// pass, and present. Mirrors the GL path's `endDrawing`.
    fn endDrawing(self: *App) void {
        // Frame begin+end is owned by the RUNNER. In the launcher the active
        // example runs as a child (`child_tick_active`) and the runner closes
        // the host frame exactly once — so a child's own `endDrawing` must be a
        // NO-OP, not a second present. This makes the IDENTICAL example body
        // correct whether it runs standalone (this call presents the frame) or
        // as a launcher child (the runner presents it). It replaces a per-frame
        // assert: rather than reporting the misuse every frame, the misuse is
        // now impossible to hit — an example can freely call `endDrawing` and
        // it does the right thing for its context.
        if (self.child_tick_active) {
            return;
        }
        if (!self.drawing_active) {
            return;
        }
        assertf(
            self.frame_phase != .mode_3d,
            @src(),
            "endDrawing while a 3D block is still open — call endMode3D first",
            .{},
        );
        // Flush whatever the immediate-mode calls accumulated. Re-bind the 2D
        // pipeline + resources first: an app may have bound a CUSTOM pipeline
        // mid-frame (z.Pipeline, for a custom render pass that composes with the
        // 2D layer). flushBatch deliberately does NOT bind a pipeline — that's
        // the consumer's job — so without this restore the accumulated 2D batch
        // (shapes/text) would be drawn through the app's foreign vertex layout,
        // misreading the vertices into garbage. bindForPass only sets the
        // pipeline + binds resources (it does not touch the batch), and the
        // setPipeline dedup makes it ~free when no custom pipeline was bound.
        self.renderer_2d.?.bindForPass(&self.pass);
        Backend.flushBatch(&self.pass);
        Backend.endRenderPass(&self.pass);
        Backend.endFrame(&self.gpu_frame);
        self.drawing_active = false;
        self.frame_begun = false;
        self.leaveFrame2D();
    }
};

// lint:off module-var: the single live-app bridge pointer (analogue of zimr_app); set once by App.run
var active_app: ?*App = null;

/// Clock adapter handed to the profiler at startup (`*const fn () f64`).
/// performance.now() in milliseconds; the dedicated fast import lands later.
fn profilerClock() f64 {
    return wgpu.nowMs();
}

// ============================================================================
// .fit scale-mode helpers — map a fixed design-size coordinate space into the
// canvas with uniform scale + centering (letterbox/pillarbox), baked into the
// ortho so no GPU viewport is needed.
// ============================================================================

// ---- THE coordinate-space contract (single source of truth) ----------------
//
// The app ALWAYS works in ONE logical space: `f.window.screen_width/height`.
// In `.responsive` that equals the live CSS size; in `.fit` it's the fixed
// design size, letterboxed into CSS. The browser delivers CSS px (mouse/touch);
// the GPU wants backing px (scissor). These two functions are the ONLY bridge
// between CSS and logical, and EVERY input + scissor path routes through them —
// so no path can disagree with another (the bug class where touch, mouse, and
// scissor each forked their own transform and one was wrong/missing). Adding a
// new input or clip API? Call these; don't re-derive the transform.

/// CSS px (what the browser bridge delivers) -> the app's logical space.
/// Use for ALL incoming pointer/touch coordinates.
fn cssToLogical(
    app: *App,
    x: f32,
    y: f32,
) [2]f32 {
    if (app.config.window.scale_mode != .fit) {
        return .{ x, y }; // .responsive: logical == CSS
    }
    const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
    const f: FitXform = fitScaleOffset(
        @floatFromInt(app.config.window.width),
        @floatFromInt(app.config.window.height),
        @floatFromInt(@max(css.width, 1)),
        @floatFromInt(@max(css.height, 1)),
    );
    return .{ (x - f.off_x) / f.scale, (y - f.off_y) / f.scale };
}

/// The app's logical space -> CSS px. Use for ALL outgoing geometry that must
/// land in CSS/backing space (scissor rects). Returns CSS-space (x,y,w,h).
fn logicalToCss(
    app: *App,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) [4]f32 {
    if (app.config.window.scale_mode != .fit) {
        return .{ x, y, w, h }; // .responsive: CSS == logical
    }
    const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
    const f: FitXform = fitScaleOffset(
        @floatFromInt(app.config.window.width),
        @floatFromInt(app.config.window.height),
        @floatFromInt(@max(css.width, 1)),
        @floatFromInt(@max(css.height, 1)),
    );
    return .{ f.off_x + x * f.scale, f.off_y + y * f.scale, w * f.scale, h * f.scale };
}

// ============================================================================
// Public 2D drawing API — free functions taking `f.gl` (a `*WgpuGl`), mirroring
// the GL path's `z.beginDrawing(f.gl)` / `z.rlBegin(f.gl)` shape so example
// bodies read the same on both backends. beginDrawing/endDrawing recover the
// owning App from `gl.owner`; the immediate-mode primitives just drive WgpuGl's
// trait methods directly.
// ============================================================================

pub fn appOf(gl: *WgpuGl) *App {
    return @ptrCast(@alignCast(gl.owner.?));
}

/// Open a 2D drawing frame (clear defaults to the App config's clear color).
/// Returns the same `gl` for chaining. Pair with `endDrawing`.
pub fn beginDrawing(gl: *WgpuGl) void {
    const zb: profiler.Zone = profiler.zoneNamed(@src(), "beginDrawing");
    defer zb.end();
    const app: *App = appOf(gl);
    // lint:off scope-balance: engine frame primitive (frame closed by endDrawing elsewhere)
    _ = app.beginDrawing(app.config.window.clear) catch return;
}

/// Set the clear color for THIS frame and (re)begin the pass with it. Call
/// right after beginDrawing, matching the GL `clearBackground`.
pub fn clearBackground(gl: *WgpuGl, color: Color) void {
    const app: *App = appOf(gl);
    // A launcher child must not re-clear: ending + reopening the pass here would
    // tear down the runner's single-frame lifecycle, and the pass clear is a
    // fixed load-op anyway (it cannot be changed mid-pass). No-op for children —
    // the runner's clear stands, and the child draws over it. Standalone
    // behavior is unchanged. (An example can freely call clearBackground and it
    // does the right thing for its context — no launcher-specific edits.)
    if (app.child_tick_active) {
        return;
    }
    // If a pass is already open from beginDrawing, end it and reopen with the
    // requested clear (the pass's clear is a load-op, fixed at pass start).
    if (app.drawing_active) {
        Backend.endRenderPass(&app.pass);
        Backend.endFrame(&app.gpu_frame);
        app.drawing_active = false;
        app.frame_begun = false;
    }
    // raylib-style: callers pass a u8 Color (like every other draw call).
    // Convert to the 0..1 float clear the render pass wants. (Passing the u8
    // values straight through as floats clamped to WHITE — the bug behind the
    // white background.)
    // lint:off scope-balance: engine frame primitive (frame closed by endDrawing elsewhere)
    _ = app.beginDrawing(.{
        .r = float(color.r) / 255.0,
        .g = float(color.g) / 255.0,
        .b = float(color.b) / 255.0,
        .a = float(color.a) / 255.0,
    }) catch return;
}

/// Close the 2D drawing frame: flush + end pass + present.
pub fn endDrawing(gl: *WgpuGl) void {
    const ze: profiler.Zone = profiler.zoneNamed(@src(), "endDrawing");
    defer ze.end();
    appOf(gl).endDrawing();
}

// ---- immediate-mode primitives (thin wrappers over the gl_iface trait) ----

pub fn rlBegin(gl: *WgpuGl, mode: raster.DrawMode) void {
    gl.begin(mode);
}
pub fn rlEnd(gl: *WgpuGl) void {
    gl.end();
}
pub fn rlVertex2f(
    gl: *WgpuGl,
    x: f32,
    y: f32,
) void {
    gl.vertex2f(x, y);
}
pub fn rlColor4ub(
    gl: *WgpuGl,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) void {
    gl.color4ub(r, g, b, a);
}
pub fn rlTexCoord2f(
    gl: *WgpuGl,
    u: f32,
    v: f32,
) void {
    gl.texCoord2f(u, v);
}

// ---- convenience shapes (built on the immediate-mode primitives) ----

// ---- camera modes (raylib beginMode2D/3D): set up the matrix stack ----------
// Use the unified zm cameras (Camera2D/Camera3D). Between beginMode and endMode,
// `gl: anytype` 2D/3D draw code renders in the camera's space — the SAME calls
// the GL backend uses, so scene code is backend-agnostic.

/// Enter 2D camera space: subsequent draws are transformed by `cam`.
pub fn beginMode2D(gl: *WgpuGl, cam: Camera2D) void {
    gl.matrixMode(.modelview);
    gl.loadIdentity();
    const m: Mat = cam.matrix();
    gl.multMatrix(&m);
}

pub fn endMode2D(gl: *WgpuGl) void {
    gl.matrixMode(.modelview);
    gl.loadIdentity();
}

/// Switch the active blend mode for subsequent 2D draws (raylib BeginBlendMode).
/// Call endBlendMode to restore alpha. Flushes the pending batch on switch.
pub fn beginBlendMode(gl: *WgpuGl, mode: wgpu.BlendMode) void {
    gl.renderer().setBlend(gl.pass, mode);
}

pub fn endBlendMode(gl: *WgpuGl) void {
    gl.renderer().setBlend(gl.pass, .alpha);
}

/// raylib's `BeginShaderMode`: everything drawn until `endShaderMode` goes through the user's
/// fragment shader — ordinary `rect`/`circle`/`text`/`texture` draws, not a fullscreen quad.
///
/// `pipeline` comes from `z.loadShader2D`, which builds it against the engine's own shapes
/// vertex stage and layout.
pub fn beginShaderMode(gl: *WgpuGl, shader: Shader2D) void {
    gl.renderer().setUserShader(gl.pass, shader.pipeline);
    // Groups 0 (projection) and 1 (texture) survive the pipeline swap, because the user's
    // layout shares those exact bind-group-layout handles with the engine's. Group 2 is the
    // user's own and nothing else will ever set it.
    Backend.setBindGroup(gl.pass, 2, shader.params_bind_group);
}

/// raylib's `EndShaderMode`. Restores the engine's shapes shader, preserving the blend mode.
pub fn endShaderMode(gl: *WgpuGl) void {
    gl.renderer().clearUserShader(gl.pass);
}

/// Close the current render pass and reopen the main 2D pass over the
/// backbuffer, LOADING (preserving) whatever was already drawn, and restore
/// the 2D renderer's ortho + pass binding. Shared by endTextureMode (after
/// offscreen rendering) and endMode3D (after the depth-isolated 3D pass).
fn reopen2DPass(app: *App) void {
    Backend.endRenderPass(&app.pass);
    app.pass = Backend.beginRenderPass(app.frameEncoder(), .{
        .color_view = app.gpu_frame.surface_view,
        .clear = null,
        // Re-attach the SAME depth target as the frame pass (beginDrawing). The
        // immediate-3D path batches into the current pass (no pass switch), and
        // when the window opted into depth the 2D pipelines also carry depth
        // state — so the resumed pass must match. `.invalid` for a depth-less
        // 2D app keeps it depth-free. (Hardcoding null here broke any 3D / 2D
        // drawn after endTextureMode in a depth app: a depth-free pass vs a
        // depth-carrying pipeline.)
        .depth_view = app.gpu_frame.depth_view,
    });
    app.pass.queue = app.gpu_frame.queue;
    const size: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
    const css_w: f32 = float(@max(size.width, 1));
    const css_h: f32 = float(@max(size.height, 1));
    const vp: [16]f32 = switch (app.config.window.scale_mode) {
        .responsive => renderer_2d.orthoTopLeft(css_w, css_h),
        .fit => fitOrtho(
            @floatFromInt(app.config.window.width),
            @floatFromInt(app.config.window.height),
            css_w,
            css_h,
        ),
    };
    app.renderer_2d.?.updatePerFrame(&app.gpu_frame, .{ .view_projection = vp });
    app.renderer_2d.?.bindForPass(&app.pass);
    app.pass.batch = &app.renderer_2d.?.shapes_batch;
    app.enterFrame2D();
}

/// Like `beginMode3D` but drives the depth-tested 3D batch with a caller-built
/// view-projection matrix (column-major, used as `M·v`) instead of deriving one
/// from a `Camera3D`. Lets callers supply a custom (e.g. orthographic) camera —
/// `plot3d.viewProjMatrix` uses this to align GPU geometry with its CPU axes.
/// Single shared depth-tested pass: the batch flushes at `endMode3D`; 2D drawn
/// afterwards (compare=always) composites on top.
pub fn beginMode3DMatrix(gl: *WgpuGl, view_proj: Mat) void {
    const app: *App = appOf(gl);
    assertf(
        app.frame_phase == .frame_2d,
        @src(),
        "beginMode3D in phase '{s}'; expected an open 2D frame. " ++
            "Did you forget endMode3D, or call it after endDrawing?",
        .{@tagName(app.frame_phase)},
    );
    // 3D is depth-tested: a frame with no depth attachment renders wrong/black.
    // Catch it here rather than as a silent black pass (the symptom we kept
    // hitting when a 3D app ran in a frame whose depth_format wasn't set).
    assertf(
        app.gpu_frame.depth_format != null,
        @src(),
        "beginMode3D needs a depth attachment, but the frame has none (set window.depth_format)",
        .{},
    );
    // Commit anything the 2D immediate-mode path queued before this 3D block
    // (e.g. a full-screen background quad). Without this the 2D batch would
    // flush at endDrawing — AFTER the immediate 3D draws — and paint over the
    // 3D. Flushing here lands that 2D BEHIND the 3D, which is what the call
    // order means.
    Backend.flushBatch(&app.pass);
    if (app.cube3d == null) {
        app.cube3d = draw3d.Cube3D.init(app.gpa, &app.gpu_frame) catch null;
    }
    if (app.cube3d) |*c3d| {
        c3d.beginFrame3D(view_proj);
    }
    // Raw-matrix entry has no eye/separate view+proj, so pbr3d models can't be
    // drawn in this scope (drawModel3D asserts on the null). beginMode3D fills
    // this in right after calling us.
    app.mode3d_cam = null;
    app.frame_phase = .mode_3d;
}

/// Enter 3D camera space. Opens a dedicated depth-isolated pass over the live
/// 2D content (colour loaded, depth cleared), sets the camera view-projection
/// for the batch, and starts a fresh primitive batch. near/far default to
/// raylib's 0.01 / 1000. 3D primitives drawn until endMode3D are collected and
/// issued as a single depth-tested draw.
pub fn beginMode3D(gl: *WgpuGl, cam: Camera3D) void {
    const app: *App = appOf(gl);
    const aspect: f32 = if (app.target_size) |ts|
        float(ts[0]) / float(@max(ts[1], 1))
    else blk: {
        const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
        break :blk if (css.height > 0)
            float(css.width) / float(css.height)
        else
            1.0;
    };
    const z_near: f32 = 0.01;
    const z_far: f32 = 1000.0;
    const view: Mat = cam.viewMatrix();
    // ★ `cam.projMatrix` HONOURS `cam.projection`; this used to build `perspectiveFovRh`
    // unconditionally and silently ignore the field.
    //
    // That was an inconsistency rather than a missing feature: `Camera3D.projMatrix` and
    // `getScreenToWorldRayWithViewport` both already respected `projection`, and only this
    // entry point did not. An orthographic camera passed here became a PERSPECTIVE one whose
    // `fovy_deg` was read as DEGREES — a shadow-map light with a half-extent of 4.0 turned into
    // a 4-degree telephoto that saw a fraction of one surface. Nothing asserted, nothing
    // logged: it simply rendered flat and looked like the pass had not run.
    const proj: Mat = cam.projMatrix(aspect, z_near, z_far);
    const view_proj: Mat = mulMat(proj, view);

    // lint:off scope-balance: engine primitive (forwards to beginMode3DMatrix; closed by endMode3D)
    beginMode3DMatrix(gl, view_proj);
    // Record the camera in the form pbr3d needs so `drawModel3D` can draw a
    // model in THIS scope with the same camera the immediate primitives use —
    // one camera, specified once. (beginMode3DMatrix just cleared it to null.)
    const app3d: *App = appOf(gl);
    app3d.mode3d_cam = .{
        .view = view,
        .proj = proj,
        .eye = .{ cam.position[0], cam.position[1], cam.position[2] },
    };
}

/// Append one flat-shaded triangle (world-space) to the current 3D batch.
/// Must be called between `beginMode3D`/`beginMode3DMatrix` and `endMode3D`.
pub fn drawTriangle3D(
    gl: *WgpuGl,
    a: Vec,
    b: Vec,
    c: Vec,
    color: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendTriangle(a, b, c, color);
    }
}

/// Append a lit, solid-colour cube (centre + edge length) to the current 3D
/// batch. Must be called between beginMode3D and endMode3D. Drawn with all
/// other 3D primitives this frame in a single depth-tested pass at endMode3D.
/// Default colour for 3D primitive descriptors (opaque white).
const white3d: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// Options for `drawCube` / `drawCubeWires`. `size` is per-axis (edge lengths);
/// `rotation` is any rotation matrix (build it with `zm.matFromAxisAngle`,
/// `zm.matFromRollPitchYaw`, …) — identity = axis-aligned.
pub const CubeDesc = struct {
    size: Vec = vec(1, 1, 1),
    rotation: Mat = identity(),
    color: Color = white3d,
};

/// Options for `drawSphere` / `drawSphereWires`. `rings`/`slices` control the
/// tessellation (raylib's `DrawSphereEx` args), defaulted for a smooth ball.
pub const SphereDesc = struct {
    radius: f32 = 0.5,
    rings: i32 = 16,
    slices: i32 = 16,
    color: Color = white3d,
};

/// Options for `drawCylinder` / `drawCylinderWires` (Y-axis, full height).
/// `sides` controls the tessellation.
pub const CylinderDesc = struct {
    radius: f32 = 0.5,
    height: f32 = 1.0,
    sides: i32 = 24,
    color: Color = white3d,
};

/// Options for `drawPlane` (XZ plane, normal +Y). `size` is X/Z extent.
pub const PlaneDesc = struct {
    size: zm.Vec2 = .{ 1, 1 },
    color: Color = white3d,
};

/// Draw a lit solid cube centred at `center`. See `CubeDesc` (all fields
/// defaulted — `.{}` is a unit white cube; set `.rotation` for an oriented one).
pub fn drawCube(
    gl: *WgpuGl,
    center: Vec,
    d: CubeDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendCubeEx(center, d.size, d.rotation, d.color);
    }
}

/// Draw a world-space line segment between two 3D points (unlit, flat colour).
/// Collected into the 3D batch and drawn at endMode3D.
pub fn drawLine3D(
    gl: *WgpuGl,
    start: Vec,
    end: Vec,
    color: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendLine(
            .{ start[0], start[1], start[2] },
            .{ end[0], end[1], end[2] },
            color,
        );
    }
}

/// Draw a ground grid in the XZ plane centred at the origin: `slices` cells per
/// side, `spacing` world units each. The centre cross is brighter, matching
/// raylib's DrawGrid look.
pub fn drawGrid(
    gl: *WgpuGl,
    slices: i32,
    spacing: f32,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        const half_slices: i32 = @divTrunc(slices, 2);
        const extent: f32 = float(half_slices) * spacing;
        var i: i32 = -half_slices;
        while (i <= half_slices) : (i += 1) {
            const p: f32 = float(i) * spacing;
            const col: Color = if (i == 0)
                .{ .r = 120, .g = 122, .b = 132, .a = 255 }
            else
                .{ .r = 66, .g = 68, .b = 78, .a = 255 };
            c3d.appendLine(.{ -extent, 0, p }, .{ extent, 0, p }, col);
            c3d.appendLine(.{ p, 0, -extent }, .{ p, 0, extent }, col);
        }
    }
}

/// Draw the 12 wireframe edges of a cube. Same `CubeDesc` as `drawCube`.
pub fn drawCubeWires(
    gl: *WgpuGl,
    center: Vec,
    d: CubeDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendCubeWiresEx(center, d.size, d.rotation, d.color);
    }
}

/// Draw a lit solid sphere. See `SphereDesc`.
pub fn drawSphere(
    gl: *WgpuGl,
    center: Vec,
    d: SphereDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendSphere(center, d.radius, @intCast(@max(d.rings, 2)), @intCast(@max(d.slices, 3)), d.color);
    }
}

/// Draw a lit solid Y-axis cylinder. See `CylinderDesc`.
pub fn drawCylinder(
    gl: *WgpuGl,
    center: Vec,
    d: CylinderDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendCylinder(center, d.radius, d.height * 0.5, @intCast(@max(d.sides, 3)), d.color);
    }
}

/// Draw a wireframe sphere (latitude + longitude circles). See `SphereDesc`.
/// Raylib parity: `DrawSphereWires`.
pub fn drawSphereWires(
    gl: *WgpuGl,
    center: Vec,
    d: SphereDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendSphereWires(center, d.radius, @intCast(@max(d.rings, 2)), @intCast(@max(d.slices, 3)), d.color);
    }
}

/// Draw a wireframe Y-axis cylinder (top + bottom rings + struts). See
/// `CylinderDesc`. Raylib parity: `DrawCylinderWires`.
pub fn drawCylinderWires(
    gl: *WgpuGl,
    center: Vec,
    d: CylinderDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendCylinderWires(center, d.radius, d.height * 0.5, @intCast(@max(d.sides, 3)), d.color);
    }
}

const WgpuTexture = @import("wgpu_texture.zig").WgpuTexture;

/// Draw an axis-aligned cube with `tex` mapped on each face, depth-tested in the
/// 3D pass (so it occludes / is occluded by other 3D geometry).
pub fn drawCubeTexture(
    gl: *WgpuGl,
    tex: WgpuTexture,
    center: Vec,
    size: f32,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawCubeTexture(tex, center, size, tint);
    }
}

/// Draw a camera-facing textured quad (billboard) at `pos`, `w`×`h`. `right` and
/// `up` are the camera basis vectors (e.g. derived from the view matrix); the
/// quad spans `pos ± right*w/2 ± up*h/2`.
pub fn drawBillboard(
    gl: *WgpuGl,
    tex: WgpuTexture,
    right: [3]f32,
    up: [3]f32,
    pos: Vec,
    w: f32,
    h: f32,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawBillboard(tex, right, up, pos, w, h, tint);
    }
}

/// Camera-facing textured quad framing a sprite-atlas cell. `uv_min`/`uv_max`
/// are the normalized (0..1) source rect; `anchor` positions the quad in its
/// plane in (w, h) units — {0.5, 0.5} centers on `pos`, {0.5, 0} plants its
/// bottom edge on `pos`. `right`/`up` are the camera basis (as for
/// `drawBillboard`). Raylib parity: `DrawBillboardPro`.
pub fn drawBillboardRec(
    gl: *WgpuGl,
    tex: WgpuTexture,
    right: [3]f32,
    up: [3]f32,
    pos: Vec,
    w: f32,
    h: f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    anchor: [2]f32,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawBillboardRec(tex, right, up, pos, w, h, uv_min, uv_max, anchor, tint);
    }
}

/// Draw a list of textured, depth-tested 3D triangles from `tex`. `positions`
/// and `uvs` are parallel, 3 per triangle. For projected decals and other
/// generated/clipped textured geometry that the quad/billboard helpers can't
/// express. Call inside `beginMode3D`/`endMode3D`. `opts.depth_write` (default
/// true) writes depth like opaque geometry; set false for translucent overlays
/// such as stacked decals, so they blend by draw order instead of z-fighting
/// each other (they still test against the opaque scene, so they stay occluded).
pub const TexTrisDesc = struct {
    tint: Color = white3d,
    depth_write: bool = true,
};

pub fn drawTexturedTriangles(
    gl: *WgpuGl,
    tex: WgpuTexture,
    positions: []const [3]f32,
    uvs: []const [2]f32,
    opts: TexTrisDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawTexturedTriangles(tex, positions, uvs, opts.tint, opts.depth_write);
    }
}

/// Upload a mesh as a decal RECEIVER once (returns a handle), so projected
/// decals can be painted onto it with `drawDecal`. Positions are read in their
/// current (world) space. Call at setup; the buffer persists for the app.
/// Returns null if the mesh has no geometry or the 3D system isn't ready.
pub fn uploadDecalReceiver(gl: *WgpuGl, mesh: types.Mesh) ?u32 {
    const app: *App = appOf(gl);
    // cube3d is created lazily (normally on first beginMode3D). Receivers are
    // typically uploaded at init, BEFORE any 3D block, so ensure it exists here.
    if (app.cube3d == null) {
        app.cube3d = draw3d.Cube3D.init(app.gpa, &app.gpu_frame) catch null;
    }
    if (app.cube3d) |*c3d| {
        return c3d.uploadDecalReceiver(app.gpu_frame.queue, mesh);
    }
    return null;
}

/// Options for `drawDecal`. `size` is the decal box's world extent; `tint`
/// multiplies the sampled decal texture.
pub const DecalDesc = struct {
    size: f32 = 1.0,
    tint: Color = white3d,
    /// World-space direction the projector faces (the surface normal at the
    /// hit). Fragments whose surface faces away from this are not painted, so a
    /// decal never bleeds onto the far side of its projector box.
    forward: Vec = .{ 0, 0, 1, 0 },
};

/// Paint a projected decal of `tex` onto decal-receiver `handle` (from
/// `uploadDecalReceiver`). `projector` maps world → decal-box space — build it
/// as `compose(lookAtRh(hit, hit + normal, up), rotationZ(spin))`. The receiver
/// mesh is re-drawn with a fragment shader that discards everything outside the
/// box, so only the surface patch under the projector is painted — no mesh
/// clipping, scales to any density. Call inside `beginMode3D`/`endMode3D`.
pub fn drawDecal(
    gl: *WgpuGl,
    handle: u32,
    projector: Mat,
    tex: WgpuTexture,
    opts: DecalDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawDecal(app.gpu_frame.queue, handle, projector, opts.forward, opts.size, tex, opts.tint);
    }
}

/// Draw a gradient skybox filling the far background, using `cam` to unproject.
/// `sky_bottom`/`sky_top` are linear-ish RGB (0..1). Call inside beginMode3D/
/// endMode3D, before your 3D objects (it parks at the far plane and loses the
/// depth test to anything closer, so it stays behind everything).
pub fn drawSkybox(
    gl: *WgpuGl,
    cam: Camera3D,
    sky_bottom: [3]f32,
    sky_top: [3]f32,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
        const aspect: f32 = if (css.height > 0) float(css.width) / float(css.height) else 1.0;
        const fovy_rad: f32 = cam.fovy_deg * (pi / 180.0);
        const view: Mat = cam.viewMatrix();
        const proj: Mat = perspectiveFovRh(fovy_rad, aspect, 0.01, 1000.0);
        const view_proj: Mat = mulMat(proj, view);
        c3d.drawSkybox(&app.pass, inverse(view_proj), cam.position, sky_bottom, sky_top);
    }
}

/// Draw a flat lit plane in the XZ plane (normal +Y), centred at `center`.
pub fn drawPlane(
    gl: *WgpuGl,
    center: Vec,
    d: PlaneDesc,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendPlane(center, d.size[0], d.size[1], d.color);
    }
}

/// Draw a (optionally tapered) cylinder between two world points: `start_radius`
/// at `start_pos`, `end_radius` at `end_pos`. `end_radius == 0` gives a cone; the
/// axis is arbitrary. (If you know raylib, this is `DrawCylinderEx`; a plain
/// Y-axis cylinder is `drawCylinder` with a `CylinderDesc`.)
pub fn drawCylinderBetween(
    gl: *WgpuGl,
    start_pos: Vec,
    end_pos: Vec,
    start_radius: f32,
    end_radius: f32,
    sides: i32,
    color: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendConeBetween(start_pos, end_pos, start_radius, end_radius, @intCast(@max(sides, 3)), color);
    }
}

/// Draw a capsule (cylinder body + spherical caps) between two world points.
/// Raylib parity: `DrawCapsule`.
pub fn drawCapsule(
    gl: *WgpuGl,
    start_pos: Vec,
    end_pos: Vec,
    radius: f32,
    slices: i32,
    rings: i32,
    color: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        const si: u32 = @intCast(@max(slices, 3));
        const ri: u32 = @intCast(@max(rings, 2));
        c3d.appendConeBetween(start_pos, end_pos, radius, radius, si, color);
        c3d.appendSphere(start_pos, radius, ri, si, color);
        c3d.appendSphere(end_pos, radius, ri, si, color);
    }
}

/// Axis-aligned bounding box (min/max corners). Backend-agnostic.
pub const BoundingBox = types.BoundingBox;

/// Draw a wireframe AABB as a 12-edge box.
pub fn drawBoundingBox(gl: *WgpuGl, box: BoundingBox, color: Color) void {
    const sx: f32 = @abs(box.max[0] - box.min[0]);
    const sy: f32 = @abs(box.max[1] - box.min[1]);
    const sz: f32 = @abs(box.max[2] - box.min[2]);
    const center: Vec = vec(box.min[0] + sx * 0.5, box.min[1] + sy * 0.5, box.min[2] + sz * 0.5);
    drawCubeWires(gl, center, .{ .size = vec(sx, sy, sz), .color = color });
}

/// Retained mesh + model (raylib `types` structs; shared with the GL backend).
pub const Mesh = types.Mesh;
pub const Model = types.Model;

/// Wrap a mesh in a Model (identity transform). Raylib loadModelFromMesh. `gl`
/// is accepted for call-site parity but unused on wgpu.
pub fn loadModelFromMesh(
    gl: *WgpuGl,
    gpa: Allocator,
    mesh: types.Mesh,
) Allocator.Error!types.Model {
    _ = gl;
    return draw3d.loadModelFromMesh(gpa, mesh);
}

/// Draw a Model filled at `position`, uniform `scale`, tinted. Raylib drawModel.
pub fn drawModel(
    gl: *WgpuGl,
    model: types.Model,
    position: Vec,
    scale: f32,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendModel(model, position, scale, tint);
    }
}

/// Ensure a mesh has GPU buffers, uploading it if this is the first time, and return them.
///
/// Use this when the mesh is drawn ONLY by a custom pipeline: the engine's upload is lazy and
/// triggered by `drawMeshInstanced`, so a mesh the engine never draws would otherwise never be
/// uploaded.
pub fn uploadMeshGpu(gl: *WgpuGl, mesh: *types.Mesh) ?draw3d.MeshGpu {
    const app: *App = appOf(gl);
    // ★ `cube3d` IS CREATED LAZILY, normally on the first `beginMode3D`. This is called at
    // INIT, before any 3D block has run, so without this it returns null, nothing uploads, and
    // every later pass draws nothing — a black screen and an empty shadow map, with no error.
    // `uploadDecalReceiver` guards the same way for the same reason.
    if (app.cube3d == null) {
        app.cube3d = draw3d.Cube3D.init(app.gpa, &app.gpu_frame) catch null;
    }
    if (app.cube3d) |*c3d| {
        return c3d.uploadMeshGpu(mesh, app.gpu_frame.queue);
    }
    return null;
}

/// The vertex/index buffers backing an uploaded mesh, so a pass with its OWN pipeline can draw
/// the same geometry the main pass draws — one upload, many passes.
///
/// See `draw3d.Cube3D.gpuBuffers` for the vertex layout and the null case.
pub fn meshGpuBuffers(gl: *WgpuGl, mesh: types.Mesh) ?draw3d.MeshGpu {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        return c3d.gpuBuffers(mesh);
    }
    return null;
}

/// Push a mesh's current CPU positions and normals to its GPU buffer.
///
/// ★ FOR MESHES DRAWN THROUGH THE RETAINED PATH ONLY. `drawModel` re-reads the CPU arrays
/// every frame, so a dynamic mesh drawn that way needs nothing but `updateMeshBuffer`. The
/// retained path (`drawMeshInstanced`) uploads ONCE and caches by `mesh.vaoId` — without this
/// call a CPU-skinned character would show its bind pose forever.
///
/// A no-op on a mesh that has never been uploaded, so calling it unconditionally after
/// skinning is safe.
pub fn updateMeshGpu(gl: *WgpuGl, mesh: types.Mesh) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.refreshMeshGpu(&mesh, app.gpu_frame.queue);
    }
}

/// Draw a Model as wireframe (per-triangle edges). Raylib drawModelWires.
pub fn drawModelWires(
    gl: *WgpuGl,
    model: types.Model,
    position: Vec,
    scale: f32,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.appendModelWires(model, position, scale, tint);
    }
}

/// Draw `transforms.len` copies of `mesh` in ONE instanced GPU draw — each
/// instance positioned by its column-major model matrix, all sharing `tint`.
/// Unlike `drawModel` (which CPU-transforms into the immediate batch), this
/// keeps the mesh GPU-resident and streams a per-instance buffer, so it scales
/// to thousands of copies. The mesh uploads to the GPU on first use (so pass a
/// pointer). Call between `beginMode3D` and `endMode3D`; depth-tested with the
/// rest of the 3D scene.
pub fn drawMeshInstanced(
    gl: *WgpuGl,
    mesh: *types.Mesh,
    transforms: []const Mat,
    tint: Color,
) void {
    const app: *App = appOf(gl);
    if (app.cube3d) |*c3d| {
        c3d.drawMeshInstanced(&app.pass, mesh, transforms, tint);
    }
}

/// Camera control modes for `updateCamera` (raylib-style).
pub const CameraMode = enum { custom, free, orbital, first_person };

pub fn getMouseWheelMove(in: *const input.InputState) f32 {
    return input.getMouseWheelMove(in);
}

const Vec2 = zm.Vec2;

pub fn getMouseDelta(in: *const input.InputState) Vec2 {
    return input.getMouseDelta(in);
}

/// Keyboard: is `key` currently held? Mirrors raylib's IsKeyDown.
pub fn isKeyDown(
    in: *const input.InputState,
    key: types.KeyboardKey,
) bool {
    return input.isKeyDown(in, key);
}

pub const MouseButton = types.MouseButton;

pub fn isMouseButtonDown(
    in: *const input.InputState,
    button: MouseButton,
) bool {
    return input.isMouseButtonDown(in, button);
}

pub fn isMouseButtonPressed(
    in: *const input.InputState,
    button: MouseButton,
) bool {
    return input.isMouseButtonPressed(in, button);
}

/// Update a `Camera3D` from mouse/keyboard each frame.
/// - `.orbital`: left-drag orbits around the target, wheel zooms.
/// - `.first_person` / `.free`: left-drag looks, WASD moves, wheel zooms.
/// - `.custom`: no-op (caller drives the camera). `Camera3D` stays exposed.
pub fn updateCamera(
    gl: *WgpuGl,
    camera: *Camera3D,
    mode: CameraMode,
) void {
    const app: *App = appOf(gl);
    const in: *const input.InputState = &app.input_state;
    const wheel: f32 = getMouseWheelMove(in);
    switch (mode) {
        .custom => {},
        .orbital => {
            const ox: f32 = camera.position[0] - camera.target[0];
            const oy: f32 = camera.position[1] - camera.target[1];
            const oz: f32 = camera.position[2] - camera.target[2];
            var dist: f32 = @max(@sqrt(ox * ox + oy * oy + oz * oz), 0.001);
            var yaw: f32 = atan2Rad(ox, oz);
            var pitch: f32 = asinRad(clamp(oy / dist, -1.0, 1.0));
            // Skip the delta on the press frame: getMouseDelta is current -
            // previous, and on a touch/click DOWN the previous position is
            // stale (from before the press), so the first frame's delta is a
            // large jump that pops the rotation. Only apply while held.
            if (isMouseButtonDown(in, .left) and !isMouseButtonPressed(in, .left)) {
                const d: Vec2 = getMouseDelta(in);
                yaw -= d[0] * 0.006;
                pitch += d[1] * 0.006;
            }
            pitch = clamp(pitch, -1.5, 1.5);
            dist = @max(dist * (1.0 - wheel * 0.1), 0.5);
            const cp: f32 = @cos(pitch);
            camera.position[0] = camera.target[0] + dist * cp * @sin(yaw);
            camera.position[1] = camera.target[1] + dist * @sin(pitch);
            camera.position[2] = camera.target[2] + dist * cp * @cos(yaw);
        },
        .first_person, .free => {
            var fx: f32 = camera.target[0] - camera.position[0];
            var fy: f32 = camera.target[1] - camera.position[1];
            var fz: f32 = camera.target[2] - camera.position[2];
            const flen: f32 = @max(@sqrt(fx * fx + fy * fy + fz * fz), 0.001);
            fx /= flen;
            fy /= flen;
            fz /= flen;
            var yaw: f32 = atan2Rad(fx, fz);
            var pitch: f32 = asinRad(clamp(fy, -1.0, 1.0));
            if (isMouseButtonDown(in, .left) and !isMouseButtonPressed(in, .left)) {
                const d: Vec2 = getMouseDelta(in);
                yaw += d[0] * 0.006;
                pitch -= d[1] * 0.006;
            }
            pitch = clamp(pitch, -1.5, 1.5);
            const cp: f32 = @cos(pitch);
            const ndx: f32 = cp * @sin(yaw);
            const ndy: f32 = @sin(pitch);
            const ndz: f32 = cp * @cos(yaw);
            const rlen: f32 = @max(@sqrt(ndz * ndz + ndx * ndx), 0.001);
            const rx: f32 = -ndz / rlen;
            const rz: f32 = ndx / rlen;
            const speed: f32 = 0.12 + wheel * 0.5;
            var mx: f32 = 0;
            var my: f32 = 0;
            var mz: f32 = 0;
            if (isKeyDown(in, .w)) {
                mx += ndx;
                my += ndy;
                mz += ndz;
            }
            if (isKeyDown(in, .s)) {
                mx -= ndx;
                my -= ndy;
                mz -= ndz;
            }
            if (isKeyDown(in, .d)) {
                mx += rx;
                mz += rz;
            }
            if (isKeyDown(in, .a)) {
                mx -= rx;
                mz -= rz;
            }
            camera.position[0] += mx * speed;
            camera.position[1] += my * speed;
            camera.position[2] += mz * speed;
            camera.target[0] = camera.position[0] + ndx;
            camera.target[1] = camera.position[1] + ndy;
            camera.target[2] = camera.position[2] + ndz;
        },
    }
}

/// Restore the 2D renderer's pipeline + bind state IN-PLACE after a custom 3D
/// batch (`beginMode3DMatrix`..`endMode3D`) flushed into the current pass, so
/// subsequent 2D/UI composes on top of the 3D in the SAME pass. Unlike
/// `reopenOverlayPass`, this does NOT end/reopen the render pass — on tile-based
/// mobile GPUs a pass switch drops the just-drawn 3D content (the tile isn't
/// reloaded), so single-pass restore is required to keep the 3D visible.
pub fn restore2DState(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    if (app.renderer_2d) |*r2d| {
        r2d.bindForPass(&app.pass);
        app.pass.batch = &r2d.shapes_batch;
    }
}

/// Leave 3D space: flush the batch into the depth-isolated pass (one draw),
/// then reopen the 2D pass (preserving the 3D render) and restore the 2D ortho.
pub fn endMode3D(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    assertf(
        app.frame_phase == .mode_3d,
        @src(),
        "endMode3D without a matching beginMode3D (phase '{s}')",
        .{@tagName(app.frame_phase)},
    );
    if (app.cube3d) |*c3d| {
        c3d.flush(&app.pass);
    }
    // Restore the 2D pipeline + batch so any 2D/UI drawn after the 3D composes
    // on top of it in the same pass. Promotes the formerly-manual
    // `restore2DState` step to automatic, so callers can't forget it.
    restore2DState(gl);
    app.enterFrame2D();
}

/// Draw a pbr3d model inside a `beginMode3D`/`endMode3D` scope — the one door
/// for lit, textured models in the app's shared pass. The scope owns the
/// 2D↔3D transition (beginMode3D flushed the 2D backdrop BEHIND the 3D;
/// endMode3D restores 2D after), so this call is just "draw the model": no
/// manual flush, no restore, no writeback bookkeeping. The camera comes from
/// beginMode3D (specified once, shared with the immediate primitives); pass
/// only the light + model + transform. Immediate primitives (drawSphere,
/// drawCube) and models may be freely interleaved in one scope — each flush
/// rebinds its own pipeline.
pub fn drawModel3D(
    gl: *WgpuGl,
    renderer: *draw3d.pbr3d.Renderer,
    light: draw3d.pbr3d.Light,
    model: draw3d.pbr3d.Model,
    model_matrix: Mat,
) void {
    const app: *App = appOf(gl);
    assertf(
        app.frame_phase == .mode_3d,
        @src(),
        "drawModel3D outside a beginMode3D/endMode3D scope (phase '{s}') — wrap it in beginMode3D(cam)…endMode3D",
        .{@tagName(app.frame_phase)},
    );
    const cam: draw3d.pbr3d.Camera = app.mode3d_cam orelse {
        assertUnreachable(
            @src(),
            "drawModel3D needs beginMode3D(Camera3D); the raw beginMode3DMatrix has no eye for lighting",
            .{},
        );
        return;
    };
    // Commit any immediate primitives queued before this model so they land in
    // submit order (drawStream rebinds cube3d on flush; the model rebinds pbr3d).
    if (app.cube3d) |*c3d| {
        c3d.flush(&app.pass);
    }
    const desc: draw3d.pbr3d.FrameDesc = .{ .camera = cam, .light = light };
    renderer.drawIntoPass(&app.pass, &app.gpu_frame, desc, model, model_matrix);
}

// ---- OrbitCamera: reusable orbit / pan / zoom controller ------------------
//
// Every 3D example was re-implementing the same spherical camera: a drag to
// orbit, a pinch / wheel to zoom, some ad-hoc pan. `OrbitCamera` holds that
// state (a target point + yaw/pitch/distance) and turns per-frame input into a
// ready `Camera3D`. One shared idiom across mouse and touch:
//
//   * ORBIT  — one-finger drag, or LEFT-mouse drag.
//   * PAN    — two-finger drag (average motion), or RIGHT/MIDDLE-mouse drag;
//              moves the target across the camera's screen plane.
//   * ZOOM   — two-finger pinch, or the mouse wheel; changes distance.
//
// Orbiting is gated on `!ui_wants_mouse` so grabbing a slider never spins the
// scene. Call `update` once per frame and feed the result to `beginMode3D`.

/// Tuning for `OrbitCamera.update`. All defaulted; override selectively.
/// The shape of a pointer gesture. `single` is a mouse drag OR one finger;
/// `multi` is two-or-more fingers (pinch / two-finger pan).
pub const GestureMode = enum { none, single, multi };

fn gestureMode(f: *Frame, touches: i32) GestureMode {
    if (touches >= 2) {
        return .multi;
    }
    const button_down: bool = isMouseButtonDown(f.input, .left) or
        isMouseButtonDown(f.input, .right) or
        isMouseButtonDown(f.input, .middle);
    if (touches == 1 or button_down) {
        return .single;
    }
    return .none;
}

/// WHERE a gesture is, for the purpose of deciding which viewport owns it. A
/// pinch has no single position, so it anchors at the MIDPOINT of the two
/// fingers — which is exactly where the user thinks they are pinching.
fn gestureAnchor(f: *Frame, mode: GestureMode) Vec2 {
    if (mode == .multi) {
        const a: Vec2 = getTouchPosition(f.input, 0);
        const b: Vec2 = getTouchPosition(f.input, 1);
        return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
    }
    return getMousePosition(f.input);
}

/// A null region means "the whole screen" — the single-viewport default.
fn regionHolds(region: ?types.Rectangle, p: Vec2) bool {
    const r: types.Rectangle = region orelse return true;
    return p[0] >= r.x and p[0] < r.x + r.width and
        p[1] >= r.y and p[1] < r.y + r.height;
}

pub const OrbitOptions = struct {
    /// Radians of yaw/pitch per pixel of drag.
    orbit_sensitivity: f32 = 0.006,
    /// World units panned per pixel of drag, scaled by distance so panning
    /// feels the same at any zoom.
    pan_sensitivity: f32 = 0.0015,
    /// Multiplier per wheel notch / fraction of pinch travel.
    zoom_sensitivity: f32 = 0.1,
    /// Distance clamp so you can't zoom through the target or fly away.
    min_distance: f32 = 1.0,
    max_distance: f32 = 500.0,
    /// Pitch clamp (radians) so you can't roll over the poles (gimbal flip).
    min_pitch: f32 = -1.5,
    max_pitch: f32 = 1.5,
    /// Field of view (degrees) for the produced camera.
    fovy_deg: f32 = 45.0,
    /// When true, a drag while the UI wants the pointer is ignored (default).
    respect_ui: bool = true,
    /// The VIEWPORT this camera steers (logical coords), or `null` for the whole
    /// screen. A gesture belongs to the region under its ANCHOR: the pointer for
    /// a mouse or one-finger drag, and the MIDPOINT OF THE TWO FINGERS for a
    /// pinch / two-finger pan — a pinch has no single position, and the midpoint
    /// is what the user perceives as "where" they are pinching. Ownership is
    /// LATCHED when the gesture starts, so a drag that wanders across a divider
    /// keeps steering the camera it began on. The wheel is not a gesture: it
    /// follows the hovered pointer.
    ///
    /// This is what lets N cameras share one screen (split screen, a minimap, a
    /// CPU|GPU side-by-side) without every example hand-rolling its own
    /// hit-test-and-latch. Give each camera its pane; the routing is the
    /// controller's job.
    region: ?types.Rectangle = null,
};

/// A spherical orbit camera. Construct with `OrbitCamera.init`, then call
/// `update` each frame. `target`, `yaw`, `pitch`, `distance` are public so an
/// app can snap or animate the camera directly between updates.
pub const OrbitCamera = struct {
    /// The point the camera looks at and orbits around (world space).
    target: Vec = vec(0, 0, 0),
    /// Horizontal angle (radians) around +Y.
    yaw: f32 = 0.6,
    /// Vertical angle (radians); 0 is level, + looks down from above.
    pitch: f32 = 0.5,
    /// Distance from `target` to the eye.
    distance: f32 = 10.0,
    /// Up vector (world). Rarely changed.
    up: Vec = vec(0, 1, 0),

    // Gesture bookkeeping (previous-frame values for delta computation).
    prev_pinch: f32 = 0,
    prev_pan: Vec2 = .{ 0, 0 },
    panning: bool = false,
    /// True once a mouse/one-finger drag has been running for at least one
    /// frame. The FIRST frame of a drag is skipped: on touch (and after any
    /// pointer jump) `getMouseDelta` on that frame is the leap from a stale
    /// previous position, which would "pop" the camera. We orbit/pan only from
    /// the second frame on, when both positions come from the live drag.
    dragging: bool = false,
    /// The shape of the gesture in progress. Ownership is re-decided whenever
    /// this changes (none -> drag, drag -> pinch), never mid-gesture.
    gesture: GestureMode = .none,
    /// Did the in-progress gesture begin inside `opts.region`? Latched.
    owns_gesture: bool = false,

    /// Start looking at `target` from `distance` away, at a pleasant 3/4 angle.
    pub fn init(target: Vec, distance: f32) OrbitCamera {
        return .{ .target = target, .distance = distance };
    }

    /// The current eye position, derived from target + spherical angles.
    pub fn eye(self: OrbitCamera) Vec {
        const cp: f32 = @cos(self.pitch);
        return vec(
            self.target[0] + self.distance * cp * @sin(self.yaw),
            self.target[1] + self.distance * @sin(self.pitch),
            self.target[2] + self.distance * cp * @cos(self.yaw),
        );
    }

    /// The `Camera3D` for this frame. Also the return of `update`.
    pub fn camera(self: OrbitCamera, opts: OrbitOptions) Camera3D {
        return .{
            .position = self.eye(),
            .target = self.target,
            .up = self.up,
            .fovy_deg = opts.fovy_deg,
            .projection = 0,
        };
    }

    /// Read this frame's input and move the camera. `ui_wants_mouse` should be
    /// `ui.wantCaptureMouse()` (pass `false` if there's no UI). Returns the
    /// resulting `Camera3D` ready for `beginMode3D`.
    ///
    /// With `opts.region` set, this camera only answers to gestures that BEGAN
    /// inside that viewport (see `OrbitOptions.region`).
    pub fn update(
        self: *OrbitCamera,
        f: *Frame,
        ui_wants_mouse: bool,
        opts: OrbitOptions,
    ) Camera3D {
        const ui_blocked: bool = opts.respect_ui and ui_wants_mouse;
        const touches: i32 = getTouchPointCount(f.input);
        const mode: GestureMode = gestureMode(f, touches);

        // Ownership is decided ONCE per gesture, at its anchor, and re-decided
        // when the gesture changes shape (a second finger lands: a pinch is a
        // new gesture, and the user means the pane under the two fingers).
        if (mode == .none) {
            self.gesture = .none;
            self.owns_gesture = false;
        } else if (mode != self.gesture) {
            self.gesture = mode;
            self.owns_gesture = regionHolds(opts.region, gestureAnchor(f, mode));
        }
        const blocked: bool = ui_blocked or !self.owns_gesture;

        if (touches >= 2) {
            // The two-finger path used to run even while the UI wanted the
            // pointer — pinching ON a panel zoomed the scene behind it.
            if (!blocked) {
                self.handleTwoFinger(f, opts);
            } else {
                self.prev_pinch = 0;
            }
            // A one-finger drag can't be in progress while two fingers are down;
            // clear it so lifting back to one finger re-skips its first frame.
            self.dragging = false;
        } else {
            self.prev_pinch = 0;
            if (!blocked) {
                self.handleMouse(f, opts);
            } else {
                // UI (or another viewport) owns the pointer this frame; end any
                // drag so resuming control doesn't apply a stale jump.
                self.dragging = false;
                self.panning = false;
            }
        }

        // Mouse wheel zoom (desktop). Not a gesture — there is nothing to latch,
        // so it simply follows the pointer: the pane under the cursor zooms.
        const wheel: f32 = getMouseWheelMove(f.input);
        if (wheel != 0 and !ui_blocked and regionHolds(opts.region, getMousePosition(f.input))) {
            // `wheel` is per-notch (bridge.zig normalizes it), so this is
            // exactly what zoom_sensitivity documents: a fraction per notch.
            self.applyZoom(-wheel * opts.zoom_sensitivity, opts);
        }

        self.clampAll(opts);
        return self.camera(opts);
    }

    /// Two fingers: the average-of-both motion pans, the spread change zooms.
    fn handleTwoFinger(self: *OrbitCamera, f: *Frame, opts: OrbitOptions) void {
        const a: Vec2 = getTouchPosition(f.input, 0);
        const b: Vec2 = getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const spread: f32 = @sqrt(dx * dx + dy * dy);
        const mid: Vec2 = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };

        if (self.prev_pinch > 0) {
            // Pinch → zoom (fraction of travel), midpoint drift → pan.
            const dz: f32 = (self.prev_pinch - spread) / @max(self.prev_pinch, 1.0);
            self.applyZoom(dz, opts);
            self.applyPan(mid[0] - self.prev_pan[0], mid[1] - self.prev_pan[1], opts);
        }
        self.prev_pinch = spread;
        self.prev_pan = mid;
        self.panning = false;
    }

    /// Left drag orbits; right/middle drag pans; the wheel (handled by caller)
    /// zooms.
    fn handleMouse(self: *OrbitCamera, f: *Frame, opts: OrbitOptions) void {
        const left: bool = isMouseButtonDown(f.input, .left);
        const pan_btn: bool = isMouseButtonDown(f.input, .right) or isMouseButtonDown(f.input, .middle);
        if (left and !pan_btn) {
            // Skip the first frame of the drag — its delta is a stale-position
            // jump that pops the camera (worst on touch). Apply from frame 2.
            if (self.dragging) {
                const d: Vec2 = getMouseDelta(f.input);
                self.yaw -= d[0] * opts.orbit_sensitivity;
                self.pitch += d[1] * opts.orbit_sensitivity;
            }
            self.dragging = true;
            self.panning = false;
        } else if (pan_btn) {
            if (self.dragging) {
                const d: Vec2 = getMouseDelta(f.input);
                self.applyPan(d[0], d[1], opts);
            }
            self.dragging = true;
            self.panning = true;
        } else {
            self.dragging = false;
            self.panning = false;
        }
    }

    /// Move the target across the camera's screen plane by a pixel delta.
    fn applyPan(self: *OrbitCamera, dpx: f32, dpy: f32, opts: OrbitOptions) void {
        // Camera basis: forward = target - eye, right = forward × up,
        // screen-up = right × forward. Pan scales with distance so it tracks
        // the cursor at any zoom.
        const e: Vec = self.eye();
        var fwd: Vec = vec(self.target[0] - e[0], self.target[1] - e[1], self.target[2] - e[2]);
        fwd = normalize(fwd);
        const right: Vec = normalize(cross(fwd, self.up));
        const scr_up: Vec = cross(right, fwd);
        const scale: f32 = opts.pan_sensitivity * self.distance;
        // Drag right → scene moves right → target moves left (screen convention).
        const kx: f32 = -dpx * scale;
        const ky: f32 = dpy * scale;
        self.target = vec(
            self.target[0] + right[0] * kx + scr_up[0] * ky,
            self.target[1] + right[1] * kx + scr_up[1] * ky,
            self.target[2] + right[2] * kx + scr_up[2] * ky,
        );
    }

    /// Change distance by a fraction (positive = zoom out, negative = zoom in).
    fn applyZoom(self: *OrbitCamera, frac: f32, opts: OrbitOptions) void {
        _ = opts;
        self.distance *= (1.0 + frac);
    }

    fn clampAll(self: *OrbitCamera, opts: OrbitOptions) void {
        self.distance = clamp(self.distance, opts.min_distance, opts.max_distance);
        self.pitch = clamp(self.pitch, opts.min_pitch, opts.max_pitch);
    }
};

/// Close the current render pass and reopen a fresh one over the same surface
/// (colour LOADED, not cleared). Use after a custom render pass (e.g.
/// `FluidDiscs.draw`) that leaves pass/pipeline state the 2D batch can't
/// recover from on some drivers — the reopened pass restores the 2D renderer's
/// pipeline + bind groups + batch, so subsequent 2D drawing (and UI) composes
/// correctly ON TOP of whatever the custom pass rendered.
pub fn reopenOverlayPass(gl: *WgpuGl) void {
    reopen2DPass(appOf(gl));
}

// ---- camera modes end -------------------------------------------------------

/// Filled rectangle from a Rectangle struct.
pub fn drawRectangleRec(
    gl: *WgpuGl,
    rec: types.Rectangle,
    color: Color,
) void {
    drawRectangle(gl, .{ rec.x, rec.y }, .{ rec.width, rec.height }, color);
}

/// Fill the CURRENT viewport (the area `f.window` reports) with `color`. The
/// descriptor-app equivalent of `clearBackground`: a child can't clear the
/// render pass (the runner/launcher owns that), so it paints its own background
/// by filling its rect. Full-screen standalone OR a launcher cell — same call,
/// because `f.window` is whatever region the app was handed.
pub fn clearViewport(f: *Frame, color: Color) void {
    drawRectangleRec(f.gl, .{ .x = 0, .y = 0, .width = f.window.widthf(), .height = f.window.heightf() }, color);
}

/// Filled circle at a Vec2 center.
/// Filled circle (triangle fan) at `center`, `segments` controls smoothness.
pub fn drawCircle(
    gl: *WgpuGl,
    center: Vec2,
    radius: f32,
    color: Color,
    segments: u32,
) void {
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const seg: u32 = @max(segments, 3);
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const a0: f32 = tau * float(i) / float(seg);
        const a1: f32 = tau * float(i + 1) / float(seg);
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + radius * @cos(a0), cy + radius * @sin(a0));
        gl.vertex2f(cx + radius * @cos(a1), cy + radius * @sin(a1));
    }
    gl.end();
}

/// Filled axis-aligned rectangle at `position` with `size` (logical pixels).
pub fn drawRectangle(gl: *WgpuGl, position: Vec2, size: Vec2, color: Color) void {
    const x: f32 = position[0];
    const y: f32 = position[1];
    const w: f32 = size[0];
    const h: f32 = size[1];
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    // two triangles (x,y)-(x+w,y)-(x+w,y+h) and (x,y)-(x+w,y+h)-(x,y+h)
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y + h);
    gl.end();
}

/// Filled ellipse at `center` with horizontal/vertical radii.
pub fn drawEllipse(
    gl: *WgpuGl,
    center: Vec2,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const rx: f32 = radiusH;
    const ry: f32 = radiusV;
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const ell_step: f32 = pi * 2.0 / 36.0;
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        const a0: f32 = float(i) * ell_step;
        const a1: f32 = float(i + 1) * ell_step;
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + @cos(a1) * rx, cy + @sin(a1) * ry);
        gl.vertex2f(cx + @cos(a0) * rx, cy + @sin(a0) * ry);
    }
    gl.end();
}

/// Ellipse outline (line loop) at `center` with horizontal/vertical radii.
pub fn drawEllipseLines(
    gl: *WgpuGl,
    center: Vec2,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const rx: f32 = radiusH;
    const ry: f32 = radiusV;
    const ell_step: f32 = pi * 2.0 / 36.0;
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        const a0: f32 = float(i) * ell_step;
        const a1: f32 = float(i + 1) * ell_step;
        drawLine(
            gl,
            .{ cx + @cos(a0) * rx, cy + @sin(a0) * ry },
            .{ cx + @cos(a1) * rx, cy + @sin(a1) * ry },
            1.0,
            color,
        );
    }
}

/// Filled triangle with a per-vertex colour, linearly interpolated across the face by the
/// GPU (raylib DrawTriangleGradient-style). Corners: v0, v1, v2 with colours c0, c1, c2.
pub fn drawTriangleGradient(
    gl: *WgpuGl,
    v0: Vec2,
    v1: Vec2,
    v2: Vec2,
    c0: Color,
    c1: Color,
    c2: Color,
) void {
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(c0.r, c0.g, c0.b, c0.a);
    gl.vertex2f(v0[0], v0[1]);
    gl.color4ub(c1.r, c1.g, c1.b, c1.a);
    gl.vertex2f(v1[0], v1[1]);
    gl.color4ub(c2.r, c2.g, c2.b, c2.a);
    gl.vertex2f(v2[0], v2[1]);
    gl.end();
}

/// Filled triangle in a single colour (raylib DrawTriangle).
pub fn drawTriangle(
    gl: *WgpuGl,
    v0: Vec2,
    v1: Vec2,
    v2: Vec2,
    color: Color,
) void {
    drawTriangleGradient(gl, v0, v1, v2, color, color, color);
}

/// True if `point` lies inside the axis-aligned `rec` (raylib CheckCollisionPointRec).
pub fn checkCollisionPointRec(point: Vec2, rec: types.Rectangle) bool {
    return point[0] >= rec.x and point[0] <= rec.x + rec.width and
        point[1] >= rec.y and point[1] <= rec.y + rec.height;
}

/// A line between two Vec2 endpoints with a given thickness (thin quad).
pub fn drawLine(
    gl: *WgpuGl,
    a: Vec2,
    b: Vec2,
    thick: f32,
    color: Color,
) void {
    const dx: f32 = b[0] - a[0];
    const dy: f32 = b[1] - a[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len < 1.0e-6) {
        return;
    }
    const nx: f32 = -dy / len * (thick * 0.5);
    const ny: f32 = dx / len * (thick * 0.5);
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(a[0] + nx, a[1] + ny);
    gl.vertex2f(a[0] - nx, a[1] - ny);
    gl.vertex2f(b[0] - nx, b[1] - ny);
    gl.vertex2f(a[0] + nx, a[1] + ny);
    gl.vertex2f(b[0] - nx, b[1] - ny);
    gl.vertex2f(b[0] + nx, b[1] + ny);
    gl.end();
}

/// Circle outline at a Vec2 center (raylib DrawCircleLinesV) via line segments.
pub fn drawCircleLines(
    gl: *WgpuGl,
    center: Vec2,
    radius: f32,
    color: Color,
) void {
    const ell_step: f32 = pi * 2.0 / 36.0;
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        const a0: f32 = float(i) * ell_step;
        const a1: f32 = float(i + 1) * ell_step;
        drawLine(
            gl,
            .{ center[0] + @cos(a0) * radius, center[1] + @sin(a0) * radius },
            .{ center[0] + @cos(a1) * radius, center[1] + @sin(a1) * radius },
            1.0,
            color,
        );
    }
}

/// Polyline through `points` (raylib drawSplineLinear): a line segment between each
/// consecutive pair. For static wave traces, sampled curves, paths.
pub fn drawSplineLinear(
    gl: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 2) {
        return;
    }
    var i: usize = 0;
    while (i + 1 < points.len) : (i += 1) {
        drawLine(gl, points[i], points[i + 1], thick, color);
    }
}

/// B-spline through `points` (does not pass through endpoints). Sampled into 24
/// line segments per span and drawn as a thick polyline.
pub fn drawSplineBasis(
    gl: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: usize = 24;
    var prev: Vec2 = shapes2d.getSplinePointBasis(points[0], points[1], points[2], points[3], 0.0);
    var i: usize = 0;
    while (i + 3 < points.len) : (i += 1) {
        var j: usize = 1;
        while (j <= divs) : (j += 1) {
            const t: f32 = float(j) / float(divs);
            const cur: Vec2 = shapes2d.getSplinePointBasis(
                points[i],
                points[i + 1],
                points[i + 2],
                points[i + 3],
                t,
            );
            drawLine(gl, prev, cur, thick, color);
            prev = cur;
        }
    }
}

/// Catmull-Rom spline through `points[1..len-1]`. Sampled and drawn as a thick polyline.
pub fn drawSplineCatmullRom(
    gl: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: usize = 24;
    var prev: Vec2 = points[1];
    var i: usize = 0;
    while (i + 3 < points.len) : (i += 1) {
        var j: usize = 1;
        while (j <= divs) : (j += 1) {
            const t: f32 = float(j) / float(divs);
            const cur: Vec2 = shapes2d.getSplinePointCatmullRom(
                points[i],
                points[i + 1],
                points[i + 2],
                points[i + 3],
                t,
            );
            drawLine(gl, prev, cur, thick, color);
            prev = cur;
        }
    }
}

/// Cubic-Bezier spline. `points` are interleaved start/control1/control2/end per
/// segment (stride 3). Sampled and drawn as a thick polyline.
pub fn drawSplineBezierCubic(
    gl: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: usize = 24;
    var prev: Vec2 = points[0];
    var i: usize = 0;
    while (i + 3 < points.len) : (i += 3) {
        var j: usize = 1;
        while (j <= divs) : (j += 1) {
            const t: f32 = float(j) / float(divs);
            const cur: Vec2 = shapes2d.getSplinePointBezierCubic(
                points[i],
                points[i + 1],
                points[i + 2],
                points[i + 3],
                t,
            );
            drawLine(gl, prev, cur, thick, color);
            prev = cur;
        }
    }
}

/// A dashed line from `start` to `end_`: `dash`-px on, `gap`-px off, repeating.
pub fn drawLineDashed(
    gl: *WgpuGl,
    start: Vec2,
    end_: Vec2,
    thick: f32,
    dash: f32,
    gap: f32,
    color: Color,
) void {
    const dx: f32 = end_[0] - start[0];
    const dy: f32 = end_[1] - start[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len < 1.0e-4) {
        return;
    }
    const ux: f32 = dx / len;
    const uy: f32 = dy / len;
    const period: f32 = @max(dash + gap, 1.0e-3);
    var t: f32 = 0;
    while (t < len) : (t += period) {
        const seg: f32 = @min(t + dash, len);
        const a: Vec2 = .{ start[0] + ux * t, start[1] + uy * t };
        const b: Vec2 = .{ start[0] + ux * seg, start[1] + uy * seg };
        drawLine(gl, a, b, thick, color);
    }
}

/// Radial-gradient filled circle (raylib DrawCircleGradient): `inner` at the centre fading
/// to `outer` at the rim, as a triangle fan.
pub fn drawCircleGradient(
    gl: *WgpuGl,
    cx: f32,
    cy: f32,
    radius: f32,
    inner: Color,
    outer: Color,
) void {
    const segs: usize = 36;
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a0: f32 = float(i) / float(segs) * pi * 2.0;
        const a1: f32 = float(i + 1) / float(segs) * pi * 2.0;
        gl.color4ub(inner.r, inner.g, inner.b, inner.a);
        gl.vertex2f(cx, cy);
        gl.color4ub(outer.r, outer.g, outer.b, outer.a);
        gl.vertex2f(cx + @cos(a0) * radius, cy + @sin(a0) * radius);
        gl.color4ub(outer.r, outer.g, outer.b, outer.a);
        gl.vertex2f(cx + @cos(a1) * radius, cy + @sin(a1) * radius);
    }
    gl.end();
}

/// Filled regular polygon (raylib DrawPoly) of `sides` sides, `rotation_rad` in radians.
pub fn drawPoly(
    gl: *WgpuGl,
    center: Vec2,
    sides: i32,
    radius: f32,
    rotation_rad: f32,
    color: Color,
) void {
    const n: usize = @intCast(@max(sides, 3));
    const rot: f32 = rotation_rad;
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a0: f32 = rot + float(i) / float(n) * pi * 2.0;
        const a1: f32 = rot + float(i + 1) / float(n) * pi * 2.0;
        gl.vertex2f(center[0], center[1]);
        gl.vertex2f(center[0] + @cos(a0) * radius, center[1] + @sin(a0) * radius);
        gl.vertex2f(center[0] + @cos(a1) * radius, center[1] + @sin(a1) * radius);
    }
    gl.end();
}

/// Regular-polygon outline (raylib DrawPolyLines).
pub fn drawPolyLines(
    gl: *WgpuGl,
    center: Vec2,
    sides: i32,
    radius: f32,
    rotation_rad: f32,
    color: Color,
) void {
    const n: usize = @intCast(@max(sides, 3));
    const rot: f32 = rotation_rad;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a0: f32 = rot + float(i) / float(n) * pi * 2.0;
        const a1: f32 = rot + float(i + 1) / float(n) * pi * 2.0;
        const p0: Vec2 = .{ center[0] + @cos(a0) * radius, center[1] + @sin(a0) * radius };
        const p1: Vec2 = .{ center[0] + @cos(a1) * radius, center[1] + @sin(a1) * radius };
        drawLine(gl, p0, p1, 1.0, color);
    }
}

/// Vertical-gradient rectangle (raylib DrawRectangleGradientV): `top` to `bottom`.
pub fn drawRectangleGradientVertical(
    gl: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    top: Color,
    bottom: Color,
) void {
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(top.r, top.g, top.b, top.a);
    gl.vertex2f(x, y);
    gl.color4ub(bottom.r, bottom.g, bottom.b, bottom.a);
    gl.vertex2f(x, y + h);
    gl.color4ub(bottom.r, bottom.g, bottom.b, bottom.a);
    gl.vertex2f(x + w, y + h);
    gl.color4ub(top.r, top.g, top.b, top.a);
    gl.vertex2f(x, y);
    gl.color4ub(bottom.r, bottom.g, bottom.b, bottom.a);
    gl.vertex2f(x + w, y + h);
    gl.color4ub(top.r, top.g, top.b, top.a);
    gl.vertex2f(x + w, y);
    gl.end();
}

/// Four-corner gradient rectangle (raylib DrawRectangleGradientEx): top-left, bottom-left,
/// bottom-right, top-right corner colours.
pub fn drawRectangleGradientCorners(
    gl: *WgpuGl,
    rec: types.Rectangle,
    tl: Color,
    bl: Color,
    br: Color,
    tr: Color,
) void {
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(tl.r, tl.g, tl.b, tl.a);
    gl.vertex2f(rec.x, rec.y);
    gl.color4ub(bl.r, bl.g, bl.b, bl.a);
    gl.vertex2f(rec.x, rec.y + rec.height);
    gl.color4ub(br.r, br.g, br.b, br.a);
    gl.vertex2f(rec.x + rec.width, rec.y + rec.height);
    gl.color4ub(tl.r, tl.g, tl.b, tl.a);
    gl.vertex2f(rec.x, rec.y);
    gl.color4ub(br.r, br.g, br.b, br.a);
    gl.vertex2f(rec.x + rec.width, rec.y + rec.height);
    gl.color4ub(tr.r, tr.g, tr.b, tr.a);
    gl.vertex2f(rec.x + rec.width, rec.y);
    gl.end();
}

/// Triangle fan from `points[0]` (raylib DrawTriangleFan).
pub fn drawTriangleFan(
    gl: *WgpuGl,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 3) {
        return;
    }
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        gl.vertex2f(points[0][0], points[0][1]);
        gl.vertex2f(points[i][0], points[i][1]);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
    }
    gl.end();
}

/// Triangle outline (raylib DrawTriangleLines): the three edges.
pub fn drawTriangleLines(
    gl: *WgpuGl,
    v0: Vec2,
    v1: Vec2,
    v2: Vec2,
    color: Color,
) void {
    drawLine(gl, v0, v1, 1.0, color);
    drawLine(gl, v1, v2, 1.0, color);
    drawLine(gl, v2, v0, 1.0, color);
}

/// Filled circular sector / pie wedge (raylib DrawCircleSector): the area swept from
/// `start_angle` to `end_angle` (radians) about `center`, as a triangle fan of `segments`.
pub fn drawCircleSector(
    gl: *WgpuGl,
    center: Vec2,
    radius: f32,
    start_angle_rad: f32,
    end_angle_rad: f32,
    segments: i32,
    color: Color,
) void {
    const seg: i32 = @max(segments, 1);
    const a0: f32 = start_angle_rad;
    const a1: f32 = end_angle_rad;
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: i32 = 0;
    while (i < seg) : (i += 1) {
        const f0: f32 = float(i) / float(seg);
        const f1: f32 = float(i + 1) / float(seg);
        const b0: f32 = a0 + (a1 - a0) * f0;
        const b1: f32 = a0 + (a1 - a0) * f1;
        gl.vertex2f(center[0], center[1]);
        gl.vertex2f(center[0] + radius * @cos(b1), center[1] + radius * @sin(b1));
        gl.vertex2f(center[0] + radius * @cos(b0), center[1] + radius * @sin(b0));
    }
    gl.end();
}

/// Outlined circular sector (raylib drawCircleSectorLines): the arc from `start_angle`
/// to `end_angle` (radians) plus the two radii to the centre, in `segments` steps.
pub fn drawCircleSectorLines(
    gl: *WgpuGl,
    center: Vec2,
    radius: f32,
    start_angle_rad: f32,
    end_angle_rad: f32,
    segments: i32,
    color: Color,
) void {
    const seg: i32 = @max(segments, 1);
    const a0: f32 = start_angle_rad;
    const a1: f32 = end_angle_rad;
    var prev: Vec2 = .{ center[0] + radius * @cos(a0), center[1] + radius * @sin(a0) };
    drawLine(gl, center, prev, 1.0, color);
    var i: i32 = 0;
    while (i < seg) : (i += 1) {
        const fr: f32 = float(i + 1) / float(seg);
        const a: f32 = a0 + (a1 - a0) * fr;
        const cur: Vec2 = .{ center[0] + radius * @cos(a), center[1] + radius * @sin(a) };
        drawLine(gl, prev, cur, 1.0, color);
        prev = cur;
    }
    drawLine(gl, prev, center, 1.0, color);
}

/// Filled circular ring / annulus (raylib DrawRing): the area between `inner_radius` and
/// `outer_radius`, swept from `start_angle` to `end_angle` (radians) in `segments` steps.
/// Two triangles per segment; the 2D pipeline doesn't cull, so winding is unconstrained.
pub fn drawRing(
    gl: *WgpuGl,
    center: Vec2,
    inner_radius: f32,
    outer_radius: f32,
    start_angle_rad: f32,
    end_angle_rad: f32,
    segments: i32,
    color: Color,
) void {
    if (start_angle_rad == end_angle_rad) {
        return;
    }
    const seg: i32 = @max(segments, 1);
    const a0: f32 = start_angle_rad;
    const a1: f32 = end_angle_rad;
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: i32 = 0;
    while (i < seg) : (i += 1) {
        const f0: f32 = float(i) / float(seg);
        const f1: f32 = float(i + 1) / float(seg);
        const b0: f32 = a0 + (a1 - a0) * f0;
        const b1: f32 = a0 + (a1 - a0) * f1;
        const c0: f32 = @cos(b0);
        const s0: f32 = @sin(b0);
        const c1: f32 = @cos(b1);
        const s1: f32 = @sin(b1);
        // Quad (outer b0, outer b1, inner b1, inner b0) as two triangles.
        gl.vertex2f(center[0] + outer_radius * c0, center[1] + outer_radius * s0);
        gl.vertex2f(center[0] + outer_radius * c1, center[1] + outer_radius * s1);
        gl.vertex2f(center[0] + inner_radius * c1, center[1] + inner_radius * s1);
        gl.vertex2f(center[0] + outer_radius * c0, center[1] + outer_radius * s0);
        gl.vertex2f(center[0] + inner_radius * c1, center[1] + inner_radius * s1);
        gl.vertex2f(center[0] + inner_radius * c0, center[1] + inner_radius * s0);
    }
    gl.end();
}

/// Outlined ring (raylib DrawRingLines): the inner arc, the outer arc, and the two end caps.
pub fn drawRingLines(
    gl: *WgpuGl,
    center: Vec2,
    inner_radius: f32,
    outer_radius: f32,
    start_angle_rad: f32,
    end_angle_rad: f32,
    segments: i32,
    color: Color,
) void {
    const seg: i32 = @max(segments, 1);
    const a0: f32 = start_angle_rad;
    const a1: f32 = end_angle_rad;
    var prev_o: Vec2 = .{ center[0] + outer_radius * @cos(a0), center[1] + outer_radius * @sin(a0) };
    var prev_i: Vec2 = .{ center[0] + inner_radius * @cos(a0), center[1] + inner_radius * @sin(a0) };
    drawLine(gl, prev_i, prev_o, 1.0, color); // start cap
    var i: i32 = 0;
    while (i < seg) : (i += 1) {
        const fr: f32 = float(i + 1) / float(seg);
        const a: f32 = a0 + (a1 - a0) * fr;
        const cur_o: Vec2 = .{ center[0] + outer_radius * @cos(a), center[1] + outer_radius * @sin(a) };
        const cur_i: Vec2 = .{ center[0] + inner_radius * @cos(a), center[1] + inner_radius * @sin(a) };
        drawLine(gl, prev_o, cur_o, 1.0, color);
        drawLine(gl, prev_i, cur_i, 1.0, color);
        prev_o = cur_o;
        prev_i = cur_i;
    }
    drawLine(gl, prev_i, prev_o, 1.0, color); // end cap
}

/// Stroke a circular arc as a polyline (helper for rounded-rectangle outlines).
fn strokeArc(
    gl: *WgpuGl,
    cx: f32,
    cy: f32,
    radius: f32,
    start_angle_rad: f32,
    end_angle_rad: f32,
    segments: i32,
    thick: f32,
    color: Color,
) void {
    const seg: i32 = @max(segments, 1);
    const a0: f32 = start_angle_rad;
    const a1: f32 = end_angle_rad;
    var prev: Vec2 = .{ cx + radius * @cos(a0), cy + radius * @sin(a0) };
    var i: i32 = 0;
    while (i < seg) : (i += 1) {
        const fr: f32 = float(i + 1) / float(seg);
        const a: f32 = a0 + (a1 - a0) * fr;
        const cur: Vec2 = .{ cx + radius * @cos(a), cy + radius * @sin(a) };
        drawLine(gl, prev, cur, thick, color);
        prev = cur;
    }
}

/// Filled rounded rectangle (raylib DrawRectangleRounded). `roundness` in [0,1] sets the corner
/// radius as a fraction of the shorter half-extent; `segments` is the per-corner arc tessellation.
/// Built from three straight bands (a plus) plus four corner sectors.
pub fn drawRectangleRounded(
    gl: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: i32,
    color: Color,
) void {
    const r: f32 = clamp(roundness, 0.0, 1.0) * 0.5 * @min(w, h);
    if (r <= 0.0) {
        drawRectangle(gl, .{ x, y }, .{ w, h }, color);
        return;
    }
    const seg: i32 = @max(segments, 2);
    drawRectangle(gl, .{ x, y + r }, .{ w, h - 2.0 * r }, color); // middle band
    drawRectangle(gl, .{ x + r, y }, .{ w - 2.0 * r, r }, color); // top band
    drawRectangle(gl, .{ x + r, y + h - r }, .{ w - 2.0 * r, r }, color); // bottom band
    drawCircleSector(gl, .{ x + r, y + r }, r, 0.5, 0.75, seg, color); // top-left
    drawCircleSector(gl, .{ x + w - r, y + r }, r, 0.75, 1.0, seg, color); // top-right
    drawCircleSector(gl, .{ x + w - r, y + h - r }, r, 0.0, 0.25, seg, color); // bottom-right
    drawCircleSector(gl, .{ x + r, y + h - r }, r, 0.25, 0.5, seg, color); // bottom-left
}

/// Outlined rounded rectangle with thickness (raylib DrawRectangleRoundedLinesEx): four straight
/// edges plus four corner arcs.
pub fn drawRectangleRoundedLines(
    gl: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: i32,
    thick: f32,
    color: Color,
) void {
    const r: f32 = clamp(roundness, 0.0, 1.0) * 0.5 * @min(w, h);
    if (r <= 0.0) {
        drawRectangleLines(gl, .{ x, y }, .{ w, h }, thick, color);
        return;
    }
    const seg: i32 = @max(segments, 2);
    drawLine(gl, .{ x + r, y }, .{ x + w - r, y }, thick, color); // top
    drawLine(gl, .{ x + r, y + h }, .{ x + w - r, y + h }, thick, color); // bottom
    drawLine(gl, .{ x, y + r }, .{ x, y + h - r }, thick, color); // left
    drawLine(gl, .{ x + w, y + r }, .{ x + w, y + h - r }, thick, color); // right
    strokeArc(gl, x + r, y + r, r, pi, pi * 1.5, seg, thick, color);
    strokeArc(gl, x + w - r, y + r, r, pi * 1.5, pi * 2.0, seg, thick, color);
    strokeArc(gl, x + w - r, y + h - r, r, 0.0, pi * 0.5, seg, thick, color);
    strokeArc(gl, x + r, y + h - r, r, pi * 0.5, pi, seg, thick, color);
}

/// Outlined rectangle at `position`/`size` with a `thickness` border (inset bands).
pub fn drawRectangleLines(
    gl: *WgpuGl,
    position: Vec2,
    size: Vec2,
    thickness: f32,
    color: Color,
) void {
    const rx: f32 = position[0];
    const ry: f32 = position[1];
    const rw: f32 = size[0];
    const rh: f32 = size[1];
    var t: f32 = thickness;
    const max_t: f32 = @min(rw, rh) * 0.5;
    if (t > max_t) {
        t = max_t;
    }
    drawRectangle(gl, .{ rx, ry }, .{ rw, t }, color); // top
    drawRectangle(gl, .{ rx, ry + rh - t }, .{ rw, t }, color); // bottom
    drawRectangle(gl, .{ rx, ry + t }, .{ t, rh - 2 * t }, color); // left
    drawRectangle(gl, .{ rx + rw - t, ry + t }, .{ t, rh - 2 * t }, color); // right
}

/// Rectangle with an origin offset and rotation (raylib DrawRectanglePro).
/// `origin` is subtracted before rotating; `rotation_rad` is in radians. Solid fill.
pub fn drawRectangleRotated(
    gl: *WgpuGl,
    rec: types.Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    color: Color,
) void {
    var tl: Vec2 = undefined;
    var tr: Vec2 = undefined;
    var bl: Vec2 = undefined;
    var br: Vec2 = undefined;
    if (rotation_rad == 0.0) {
        const x: f32 = rec.x - origin[0];
        const y: f32 = rec.y - origin[1];
        tl = .{ x, y };
        tr = .{ x + rec.width, y };
        bl = .{ x, y + rec.height };
        br = .{ x + rec.width, y + rec.height };
    } else {
        const rad: f32 = rotation_rad;
        const s_: f32 = @sin(rad);
        const c_: f32 = @cos(rad);
        const x: f32 = rec.x;
        const y: f32 = rec.y;
        const dx: f32 = -origin[0];
        const dy: f32 = -origin[1];
        tl = .{ x + dx * c_ - dy * s_, y + dx * s_ + dy * c_ };
        tr = .{ x + (dx + rec.width) * c_ - dy * s_, y + (dx + rec.width) * s_ + dy * c_ };
        bl = .{ x + dx * c_ - (dy + rec.height) * s_, y + dx * s_ + (dy + rec.height) * c_ };
        br = .{
            x + (dx + rec.width) * c_ - (dy + rec.height) * s_,
            y + (dx + rec.width) * s_ + (dy + rec.height) * c_,
        };
    }
    gl.bindTexture(.{}); // shapes bind white up front (text leaves the atlas bound)
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(tl[0], tl[1]);
    gl.vertex2f(bl[0], bl[1]);
    gl.vertex2f(br[0], br[1]);
    gl.vertex2f(tl[0], tl[1]);
    gl.vertex2f(br[0], br[1]);
    gl.vertex2f(tr[0], tr[1]);
    gl.end();
}

// ---- textured 2D (N5e) ----

const WgpuRenderTexture = @import("wgpu_texture.zig").WgpuRenderTexture;
const codecs = @import("codecs.zig");

/// Decode PNG bytes into a CPU Image (RGBA8). Agnostic (codecs.png.decode).
pub fn loadImageFromMemory(gpa: Allocator, bytes: []const u8) !types.Image {
    const decoded: codecs.png.Image = try codecs.png.decode(gpa, bytes);
    return types.Image{
        .data = decoded.pixels.ptr,
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .mipmaps = 1,
        // codecs.png decodes to RGBA8. Use the real PixelFormat value (not 0,
        // which isn't a valid enum member) so image* ops that read the format
        // via @enumFromInt work instead of tripping an illegal-enum panic.
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    };
}

/// Upload a decoded RGBA8 Image to a GPU texture (wgpu loadTextureFromImage).
pub fn loadTextureFromImage(gl: *WgpuGl, image: types.Image) WgpuTexture {
    const app: *App = appOf(gl);
    const w: u32 = @intCast(image.width);
    const h: u32 = @intCast(image.height);
    const bytes: []const u8 = @as([*]const u8, @ptrCast(image.data.?))[0 .. w * h * 4];
    return WgpuTexture.createFromPixels(app.gpu_frame.device, app.gpu_frame.queue, .{
        .width = w,
        .height = h,
        .pixels = bytes,
        .label = "loaded_image",
    });
}

/// Bind a texture as the active 2D material. raylib's `rlSetTexture` shape.
pub fn rlSetTexture(gl: *WgpuGl, tex: WgpuTexture) void {
    gl.bindTexture(tex);
}

/// Re-upload an Image's pixels into an existing GPU texture in place (raylib
/// `UpdateTexture`). The Image dims must match `tex`. Cheap per-frame — no new
/// texture is created, so use this for animated/streamed content instead of
/// re-running loadTextureFromImage (which churns GPU resources).
pub fn updateTexture(gl: *WgpuGl, tex: WgpuTexture, image: types.Image) void {
    const app: *App = appOf(gl);
    const w: u32 = @intCast(image.width);
    const h: u32 = @intCast(image.height);
    const bytes: []const u8 = @as([*]const u8, @ptrCast(image.data.?))[0 .. w * h * 4];
    tex.updatePixels(app.gpu_frame.queue, bytes);
}

/// Create an offscreen render texture (raylib `loadRenderTexture`). Draw into it between
/// `beginTextureMode`/`endTextureMode`, then display it with
/// `drawTextureRec(rt.asTexture(), ...)`. It owns a color texture, view, and sampler.
pub fn loadRenderTexture(
    gl: *WgpuGl,
    width: i32,
    height: i32,
) WgpuRenderTexture {
    const app: *App = appOf(gl);
    // Match the window's depth state: when the app opted into a depth pass
    // (.depth_format set), the 2D pipelines carry depth state, so an RTT pass
    // they draw into must also have a depth attachment — otherwise the pipeline
    // is incompatible with the depth-less RTT pass. 2D apps get a color-only RTT.
    return WgpuRenderTexture.create(app.gpu_frame.device, .{
        .width = @intCast(width),
        .height = @intCast(height),
        .with_depth = app.gpu_frame.depth_format != null,
        .depth_format = app.gpu_frame.depth_format orelse .depth24_plus,
        .label = "render_texture",
    });
}

/// Like `loadRenderTexture`, but selects the color-sampler filter.
/// `nearest_filter = true` gives point sampling — a low-res target stays CRISP
/// when scaled up (pixel-art), matching raylib's default texture filter;
/// `false` matches `loadRenderTexture` (bilinear).
pub fn loadRenderTextureEx(
    gl: *WgpuGl,
    width: i32,
    height: i32,
    nearest_filter: bool,
) WgpuRenderTexture {
    const app: *App = appOf(gl);
    return WgpuRenderTexture.create(app.gpu_frame.device, .{
        .width = @intCast(width),
        .height = @intCast(height),
        .with_depth = app.gpu_frame.depth_format != null,
        .depth_format = app.gpu_frame.depth_format orelse .depth24_plus,
        .nearest_filter = nearest_filter,
        .label = "render_texture",
    });
}

/// Like `loadRenderTexture`, but the depth attachment is SAMPLEABLE
/// (`depth32float` + `texture_binding`) so a later pass can read it as a
/// `texture_depth_2d` — the foundation for depth-visualisation and shadow-map
/// passes (raylib `LoadRenderTextureDepthTex`). Get the depth as a bindable
/// texture with `rt.asDepthTexture()`. Always carries a color attachment too.
pub fn loadRenderTextureDepthTex(
    gl: *WgpuGl,
    width: i32,
    height: i32,
) WgpuRenderTexture {
    const app: *App = appOf(gl);
    return WgpuRenderTexture.create(app.gpu_frame.device, .{
        .width = @intCast(width),
        .height = @intCast(height),
        .with_depth = true,
        .sampleable_depth = true,
        .label = "render_texture_depthtex",
    });
}

/// Free a render texture's GPU resources (raylib `unloadRenderTexture`).
pub fn unloadRenderTexture(gl: *WgpuGl, rt: *WgpuRenderTexture) void {
    _ = gl;
    rt.deinit();
}

/// Sampler filtering for a registered texture (raylib's `TEXTURE_FILTER_*`).
/// `.point` = nearest-neighbour: crisp, blocky when magnified — right for
/// pixel-art and for text drawn at its baked size. `.bilinear` = smooth
/// interpolation — right for photos, and for text scaled well off its baked size.
/// (raylib's TRILINEAR additionally needs mipmaps, which the 2D atlas path
/// doesn't generate, so it isn't offered rather than being faked.)
pub const TextureFilter = enum { point, bilinear };

/// Change a texture's sampler filter after creation (raylib `SetTextureFilter`).
/// Takes the texture ID the 2D renderer registered — e.g. `font.texture.id` for
/// a font atlas, or the id from `registerTexture`.
///
/// Flushes the pending 2D batch first: the filter lives in the sampler, which is
/// baked into the texture's bind group, so changing it destroys and rebuilds that
/// bind group — and any geometry still staged against the old one would submit a
/// destroyed handle.
pub fn setTextureFilter(gl: *WgpuGl, texture_id: u32, filter: TextureFilter) void {
    const app: *App = appOf(gl);
    if (app.renderer_2d == null) {
        return;
    }
    // Only flush when a pass is actually open (calling this from `init`, before
    // any frame, is the common case — there is nothing staged to flush yet).
    if (app.drawing_active) {
        gl.flushBeforeMaterialSwap();
    }
    app.renderer_2d.?.setTextureFilterById(texture_id, filter == .bilinear);
}

/// Register a GPU texture (e.g. a render texture's `asTexture()`) with the 2D
/// renderer and return a draw-list texture id usable with
/// `DrawList.addTexturedQuad` / `ui.image`. Register ONCE and cache the id —
/// the renderer keeps the mapping for the texture's lifetime; calling per frame
/// leaks ids. Lets a depth-tested 3D render texture be composited as a 2D image
/// in the correct z-order (e.g. plot3d's GPU surface fill inside the plot pane).
pub fn registerTexture(gl: *WgpuGl, tex: WgpuTexture) u32 {
    const app: *App = appOf(gl);
    // Ensure the 2D renderer exists before registering. It is created lazily on
    // the first frame, but examples register textures in `init` (before any
    // frame), where it is still null — loadFont ensures it the same way. Without
    // this, registerTexture silently returned 0 (an invalid id), so every
    // `drawTexturePro`/`drawTextureNPatch` with a user texture drew nothing.
    if (app.renderer_2d == null) {
        app.renderer_2d = Renderer2D.init(app.gpa, &app.gpu_frame) catch return 0;
    }
    return app.renderer_2d.?.registerTexture(tex);
}

/// Redirect 2D drawing to the offscreen `rt`. Flushes the current pass, opens a fresh
/// pass targeting the render texture, and sets the 2D ortho to the render texture's size.
/// `clear` is explicit: a color clears the texture on entry; `null` PRESERVES last frame's
/// contents (load) so you can accumulate — fade + draw for trails. Pair with
/// `endTextureMode`. Call between begin/endDrawing.
pub fn beginTextureMode(
    gl: *WgpuGl,
    rt: WgpuRenderTexture,
    clear: ?Color,
) void {
    const app: *App = appOf(gl);
    // beginTextureMode drives the immediate-mode 2D renderer into the RTT, so it
    // binds the 2D "shapes" pipeline (built for rgba8_unorm). WebGPU validates a
    // SetPipeline against the pass's attachment formats immediately, so a
    // non-rgba8 render texture makes that bind fail before any draw. Catch it
    // here with guidance instead of surfacing an opaque GPU attachment-mismatch.
    assertf(
        rt.format == .rgba8_unorm,
        @src(),
        "beginTextureMode needs an rgba8_unorm render texture (the 2D renderer's pipeline format); " ++
            "got .{s}. For a custom-format RTT drawn with your OWN pipeline (e.g. a float shadow/depth " ++
            "map), use beginTextureModeRaw + endTextureModeRaw — they open the offscreen pass without " ++
            "binding the 2D pipeline.",
        .{@tagName(rt.format)},
    );
    app.ensureFrame() catch return;
    // Offscreen-first (RTT before beginDrawing): no screen pass to tear down.
    app.rtt_reopen_screen = app.drawing_active;
    // The offscreen pass IS an open 2D frame — set the phase so beginMode3D
    // (3D INTO a render texture) works whether or not the screen was open.
    app.enterFrame2D();
    if (app.drawing_active) {
        Backend.flushBatch(&app.pass);
        Backend.endRenderPass(&app.pass);
    }
    app.pass = Backend.beginRenderPass(app.frameEncoder(), .{
        .color_view = rt.color_view,
        .clear = if (clear) |col| .{
            .r = float(col.r) / 255.0,
            .g = float(col.g) / 255.0,
            .b = float(col.b) / 255.0,
            .a = float(col.a) / 255.0,
        } else null,
        .depth_view = rt.depth_view,
    });
    const vp: [16]f32 = renderer_2d.orthoTopLeft(
        @floatFromInt(@max(rt.width, 1)),
        @floatFromInt(@max(rt.height, 1)),
    );
    app.renderer_2d.?.updatePerFrame(&app.gpu_frame, .{ .view_projection = vp });
    app.renderer_2d.?.bindForPass(&app.pass);
    app.pass.batch = &app.renderer_2d.?.shapes_batch;
    app.target_size = .{ @max(rt.width, 1), @max(rt.height, 1) };
}

/// End offscreen rendering: flush, close the render-texture pass, reopen the backbuffer
/// pass PRESERVING what was drawn before `beginTextureMode` (load, not clear), and
/// restore the 2D ortho to the live viewport.
pub fn endTextureMode(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    // Same restore as endDrawing: a custom pipeline may have been bound while
    // rendering into the offscreen pass, so re-bind the 2D pipeline before
    // draining the batch (flushBatch does not bind one).
    app.renderer_2d.?.bindForPass(&app.pass);
    Backend.flushBatch(&app.pass);
    app.target_size = null;
    if (app.rtt_reopen_screen) {
        reopen2DPass(app);
        app.enterFrame2D();
    } else {
        // Offscreen-first: leave the screen closed; it opens once at beginDrawing,
        // which re-arms the 2D phase. Until then there's no open frame.
        Backend.endRenderPass(&app.pass);
        app.leaveFrame2D();
    }
}

/// Open an offscreen render pass into `rt` WITHOUT binding the 2D renderer's
/// pipeline — for callers that draw with their OWN render pipeline (a shadow,
/// depth, or postprocess pass) into a render texture of ANY color format.
///
/// `beginTextureMode` hard-binds the rgba8 "shapes" pipeline, which WebGPU
/// rejects as an attachment-format mismatch on a non-rgba8 RTT. This variant
/// binds no pipeline: the caller sets its pipeline + bind groups on `gl.pass`
/// and issues draws. Pair with `endTextureModeRaw`. Nothing is batched, so no
/// 2D flush happens on close.
pub fn beginTextureModeRaw(gl: *WgpuGl, rt: WgpuRenderTexture, clear: ?Color) void {
    const app: *App = appOf(gl);
    app.ensureFrame() catch return;
    // Offscreen-first (RTT before beginDrawing): no screen pass to tear down.
    app.rtt_reopen_screen = app.drawing_active;
    // The offscreen pass IS an open 2D frame — set the phase so beginMode3D
    // (3D INTO a render texture) works whether or not the screen was open.
    app.enterFrame2D();
    if (app.drawing_active) {
        Backend.flushBatch(&app.pass);
        Backend.endRenderPass(&app.pass);
    }
    app.pass = Backend.beginRenderPass(app.frameEncoder(), .{
        .color_view = rt.color_view,
        .clear = if (clear) |col| .{
            .r = float(col.r) / 255.0,
            .g = float(col.g) / 255.0,
            .b = float(col.b) / 255.0,
            .a = float(col.a) / 255.0,
        } else null,
        .depth_view = rt.depth_view,
    });
    app.pass.queue = app.gpu_frame.queue;
    app.target_size = .{ @max(rt.width, 1), @max(rt.height, 1) };
}

/// Close a `beginTextureModeRaw` pass and reopen the backbuffer pass (with the
/// frame's depth target + the 2D renderer re-bound), like `endTextureMode` but
/// skipping the 2D flush — a raw pass batches nothing.
pub fn endTextureModeRaw(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    app.target_size = null;
    if (app.rtt_reopen_screen) {
        reopen2DPass(app);
        app.enterFrame2D();
    } else {
        // Offscreen-first: leave the screen closed; it opens once at beginDrawing,
        // which re-arms the 2D phase. Until then there's no open frame.
        Backend.endRenderPass(&app.pass);
        app.leaveFrame2D();
    }
}

/// MRT sibling of `beginTextureModeRaw`: open ONE render pass writing to
/// SEVERAL render textures at once — the fragment shader's `@location(N)`
/// output lands in `rts[N]`.  This is the deferred G-buffer pass: three
/// attachments filled by one geometry walk.
///
/// Depth comes from `rts[0]` — create the FIRST render texture
/// `with_depth = true` and leave the rest color-only (one scene, one depth
/// test; per-attachment depth buffers would be meaningless anyway).  All
/// attachments share the clear color and must share dimensions (WebGPU
/// validates that; we just don't lie about it).  Close with the ordinary
/// `endTextureModeRaw`.
pub fn beginTextureModeMrtRaw(
    gl: *WgpuGl,
    rts: []const WgpuRenderTexture,
    clear: ?Color,
) void {
    const app: *App = appOf(gl);
    app.ensureFrame() catch return;
    // Offscreen-first (RTT before beginDrawing): no screen pass to tear down.
    app.rtt_reopen_screen = app.drawing_active;
    app.enterFrame2D();
    if (app.drawing_active) {
        Backend.flushBatch(&app.pass);
        Backend.endRenderPass(&app.pass);
    }
    var views: [8]wgpu.TextureViewHandle = undefined;
    const n: usize = @min(rts.len, views.len);
    for (rts[0..n], views[0..n]) |rt, *v| {
        v.* = rt.color_view;
    }
    app.pass = Backend.beginRenderPassMrt(app.frameEncoder(), .{
        .color_views = views[0..n],
        .clear = if (clear) |col| .{
            .r = float(col.r) / 255.0,
            .g = float(col.g) / 255.0,
            .b = float(col.b) / 255.0,
            .a = float(col.a) / 255.0,
        } else null,
        .depth_view = if (rts.len > 0) rts[0].depth_view else null,
    });
    app.pass.queue = app.gpu_frame.queue;
    if (rts.len > 0) {
        app.target_size = .{ @max(rts[0].width, 1), @max(rts[0].height, 1) };
    }
}

/// Draw a whole texture at (x, y) at its natural size (1 logical px per texel
/// unless `scale` differs), tinted by `tint`. Sets the texture, emits a UV'd
/// quad, then resets to the white texture so later solid-color draws are
/// untextured.
pub fn drawTexture(
    gl: *WgpuGl,
    tex: WgpuTexture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    tint: Color,
) void {
    gl.bindTexture(tex);
    gl.begin(.triangles);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    // (x,y)-(x+w,y)-(x+w,y+h) and (x,y)-(x+w,y+h)-(x,y+h), UVs 0..1 top-left.
    gl.texCoord2f(0, 0);
    gl.vertex2f(x, y);
    gl.texCoord2f(1, 0);
    gl.vertex2f(x + w, y);
    gl.texCoord2f(1, 1);
    gl.vertex2f(x + w, y + h);
    gl.texCoord2f(0, 0);
    gl.vertex2f(x, y);
    gl.texCoord2f(1, 1);
    gl.vertex2f(x + w, y + h);
    gl.texCoord2f(0, 1);
    gl.vertex2f(x, y + h);
    gl.end();
    gl.bindTexture(.{}); // reset to white so subsequent shapes are solid
}

/// Draw a sub-rectangle `src` (in 0..1 UV space) of `tex` into the screen
/// rect (dx, dy, dw, dh). The building block for glyph quads (N5f).
pub fn drawTextureRec(
    gl: *WgpuGl,
    tex: WgpuTexture,
    src_u0: f32,
    src_v0: f32,
    src_u1: f32,
    src_v1: f32,
    dx: f32,
    dy: f32,
    dw: f32,
    dh: f32,
    tint: Color,
) void {
    gl.bindTexture(tex);
    gl.begin(.triangles);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    gl.texCoord2f(src_u0, src_v0);
    gl.vertex2f(dx, dy);
    gl.texCoord2f(src_u1, src_v0);
    gl.vertex2f(dx + dw, dy);
    gl.texCoord2f(src_u1, src_v1);
    gl.vertex2f(dx + dw, dy + dh);
    gl.texCoord2f(src_u0, src_v0);
    gl.vertex2f(dx, dy);
    gl.texCoord2f(src_u1, src_v1);
    gl.vertex2f(dx + dw, dy + dh);
    gl.texCoord2f(src_u0, src_v1);
    gl.vertex2f(dx, dy + dh);
    gl.end();
}

/// raylib `DrawTexturePro`: draw the `source` sub-rect (in texture PIXELS) of `tex` into the `dest`
/// rectangle, scaled, and rotated `rotation_rad` RADIANS about `origin`. `origin` is measured from the
/// destination's top-left, and `dest.x`/`dest.y` is the screen point that the origin lands on (so
/// origin = {dest.width/2, dest.height/2} rotates about the destination's centre). This mirrors
/// `drawTextureRec`'s immediate-mode emission but adds rotation + a pixel-space source rectangle.
/// Radians, not degrees: zimr's API is radians-centric; convert at the UI layer with `radFromDeg`.
pub fn drawTextureRotated(
    gl: *WgpuGl,
    tex: WgpuTexture,
    source: types.Rectangle,
    dest: types.Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    tint: Color,
) void {
    const tw: f32 = float(tex.width);
    const th: f32 = float(tex.height);
    const su0: f32 = source.x / tw;
    const sv0: f32 = source.y / th;
    const su1: f32 = (source.x + source.width) / tw;
    const sv1: f32 = (source.y + source.height) / th;

    const sn: f32 = @sin(rotation_rad);
    const cs: f32 = @cos(rotation_rad);
    const ox: f32 = -origin[0];
    const oy: f32 = -origin[1];
    const dw: f32 = dest.width;
    const dh: f32 = dest.height;

    // dest.x/dest.y is the pivot; each corner offset (relative to origin) is rotated about it.
    const tlx: f32 = dest.x + ox * cs - oy * sn;
    const tly: f32 = dest.y + ox * sn + oy * cs;
    const trx: f32 = dest.x + (ox + dw) * cs - oy * sn;
    const tryy: f32 = dest.y + (ox + dw) * sn + oy * cs;
    const brx: f32 = dest.x + (ox + dw) * cs - (oy + dh) * sn;
    const bry: f32 = dest.y + (ox + dw) * sn + (oy + dh) * cs;
    const blx: f32 = dest.x + ox * cs - (oy + dh) * sn;
    const bly: f32 = dest.y + ox * sn + (oy + dh) * cs;

    gl.bindTexture(tex);
    gl.begin(.triangles);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    gl.texCoord2f(su0, sv0);
    gl.vertex2f(tlx, tly);
    gl.texCoord2f(su1, sv0);
    gl.vertex2f(trx, tryy);
    gl.texCoord2f(su1, sv1);
    gl.vertex2f(brx, bry);
    gl.texCoord2f(su0, sv0);
    gl.vertex2f(tlx, tly);
    gl.texCoord2f(su1, sv1);
    gl.vertex2f(brx, bry);
    gl.texCoord2f(su0, sv1);
    gl.vertex2f(blx, bly);
    gl.end();
}

// ---- CpuFramebuffer (K2): present a CPU-side RGBA8 pixel buffer on the GPU ---
//
// The bridge between any CPU pixel producer (the raster software rasterizer, a
// raytracer, a fractal computed on the CPU) and the WGPU backend. Allocate one
// per source, `update` it with fresh RGBA8 bytes each frame, then `present` it
// into a screen rectangle. This is the single abstraction the side-by-side demo
// uses for its software half AND that the raytracer uses for its image — the
// SAME helper, so the producing code never mentions GL or WGPU.
//
// Pattern (validated in mandel_sidebyside): create a copy_dst texture once,
// wgpu.queueWriteTexture each frame, drawTextureRec to blit. Nearest sampling
// keeps low-res software output crisp when scaled up.
pub const CpuFramebuffer = struct {
    tex: WgpuTexture,
    width: u32,
    height: u32,
    /// A registered-texture id (distinct material bind group). We blit via
    /// setTexture(id), NOT bindTexture(tex): bindTexture rebuilds the SHARED
    /// material bind group (bind_groups[1]) in place, which the deferred shapes
    /// batch also references — so a prior untextured draw (the GPU scene) would
    /// end up sampling THIS framebuffer at submit time (black-shapes bug). A
    /// registered id gets its own bind group handle, leaving the scene's intact.
    /// Registered lazily on first present (the Renderer2D doesn't exist until
    /// the first beginDrawing, after initState).
    tex_id: u32 = 0,
    registered: bool = false,

    /// Create a framebuffer sized `width`x`height`, initialized from `pixels`
    /// (RGBA8, len == width*height*4). Call once (e.g. in initState); keep the
    /// returned value on your State.
    pub fn init(
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        width: u32,
        height: u32,
        pixels: []const u8,
        label: []const u8,
    ) CpuFramebuffer {
        return .{
            .tex = WgpuTexture.createFromPixels(device, queue, .{
                .width = width,
                .height = height,
                .pixels = pixels,
                .label = label,
            }),
            .width = width,
            .height = height,
        };
    }

    /// Upload fresh pixels (RGBA8, len == width*height*4) for this frame.
    pub fn update(
        self: *CpuFramebuffer,
        queue: wgpu.QueueHandle,
        pixels: []const u8,
    ) void {
        wgpu.queueWriteTexture(queue, self.tex.handle, self.width, self.height, self.width * 4, pixels);
    }

    /// Blit the whole framebuffer into the screen rectangle (dx,dy,dw,dh) in
    /// logical/design pixels — scaling as needed (nearest filter). Uses the
    /// Recreate the backing texture at a new size and (if already presented
    /// at least once) swap it into the 2D registry under the SAME id, so a
    /// rotation / canvas-resize doesn't accumulate registry slots.  `pixels`
    /// must be the new size's worth of RGBA8 (typically the freshly-resized
    /// CPU producer's buffer).  The old GPU texture is destroyed.
    pub fn resize(
        self: *CpuFramebuffer,
        gl: *WgpuGl,
        width: u32,
        height: u32,
        pixels: []const u8,
        label: []const u8,
    ) void {
        if (width == self.width and height == self.height) {
            return;
        }
        const app: *App = appOf(gl);
        self.tex.deinit(); // free the old texture's handle + view + sampler
        self.tex = WgpuTexture.createFromPixels(app.gpu_frame.device, app.gpu_frame.queue, .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .label = label,
        });
        self.width = width;
        self.height = height;
        if (self.registered) {
            gl.renderer().updateRegisteredTexture(self.tex_id, self.tex);
        }
    }

    /// registered-id texture path (distinct bind group; see `tex_id`).
    pub fn present(
        self: *CpuFramebuffer,
        gl: *WgpuGl,
        dx: f32,
        dy: f32,
        dw: f32,
        dh: f32,
    ) void {
        if (!self.registered) {
            self.tex_id = gl.renderer().registerTexture(self.tex);
            self.registered = true;
        }
        gl.setTexture(self.tex_id);
        gl.begin(.triangles);
        gl.color4ub(255, 255, 255, 255);
        gl.texCoord2f(0, 0);
        gl.vertex2f(dx, dy);
        gl.texCoord2f(1, 0);
        gl.vertex2f(dx + dw, dy);
        gl.texCoord2f(1, 1);
        gl.vertex2f(dx + dw, dy + dh);
        gl.texCoord2f(0, 0);
        gl.vertex2f(dx, dy);
        gl.texCoord2f(1, 1);
        gl.vertex2f(dx + dw, dy + dh);
        gl.texCoord2f(0, 1);
        gl.vertex2f(dx, dy + dh);
        gl.end();
        // Reset to the untextured (white) material so following shape draws
        // (e.g. the divider) aren't tinted by this texture.
        gl.setTexture(0);
    }

    /// Free the GPU upload texture (handle + view + sampler). Its registry entry
    /// (the material bind group) is cleared on teardown by resetRegistry /
    /// releaseOwner; the texture itself is CpuFramebuffer-owned, freed here.
    pub fn deinit(self: *CpuFramebuffer) void {
        self.tex.deinit();
    }
};

// ---- text (N5f) ----
//
// The GL text stack in drawing.zig is already generic over `gl: anytype`
// (drawWithFont -> drawCodepoint -> drawTextureRotated), and the atlas BAKE
// (bakeFontAtlas, via codecs' TTF toolkit) is backend-agnostic, producing a
// CPU RGBA8 atlas image + per-glyph recs/metrics. So the wgpu text path is:
// bake -> upload the atlas as a WgpuTexture -> register it for an id -> build a
// types.Font carrying that id -> let the reusable drawWithFont render it.

const text2d = @import("text2d.zig");

pub const Font = types.Font;

// ---- UiHost: drive the REAL ui.zig (ImGui) on the WebGPU backend ------------
// ui.zig is backend-agnostic at the draw layer (DrawList.render(gl: anytype) ->
// drawing.shapes/text), and its `Gl` type is build-switched to WgpuGl for this
// module. UiHost bridges the wgpu frame to ui.zig's beginFrameRaw/uiRenderNow:
// it owns the persistent UiContext, builds an InputSnapshot from the frame
// input, and supplies a ShapesTextureState (id 0 = WgpuGl's white/untextured
// bind group, so solid shapes sample white) + a FontCache wrapping the font.
const ui = @import("ui.zig");
const shapes2d = @import("shapes2d.zig");
const raster = @import("raster.zig");
const shader_interface = @import("shader_interface");
const shader_introspect = @import("shader_introspect.zig");
const shader_runtime = @import("shader_runtime_wgpu.zig");
const web = @import("web.zig");

pub fn getMousePosition(in: *const input.InputState) Vec2 {
    return input.getMousePosition(in);
}

/// Number of fingers currently down (0..MAX_TOUCH_POINTS). For pinch: read 2+.
pub fn getTouchPointCount(in: *const input.InputState) i32 {
    return input.getTouchPointCount(in);
}

/// Position of touch point `index` (0-based) in logical/design pixels.
pub fn getTouchPosition(in: *const input.InputState, index: i32) Vec2 {
    return input.getTouchPosition(in, index);
}

pub fn isMouseButtonReleased(
    in: *const input.InputState,
    button: MouseButton,
) bool {
    return input.isMouseButtonReleased(in, button);
}

pub const UiHost = struct {
    ctx: ui.UiContext,
    shapes: shapes2d.ShapesTextureState,
    font_cache: text2d.FontCache,
    window: WindowStateUi,

    const WindowStateUi = @import("runtime.zig").core.WindowState;

    pub fn init(gpa: Allocator, font: Font) UiHost {
        var shapes: shapes2d.ShapesTextureState = .{};
        // WgpuGl id 0 IS the white/untextured bind group; point the shapes
        // white pixel at it so solid-color UI shapes render (no extra texture).
        shapes.texture.id = 0;
        return .{
            .ctx = ui.UiContext.init(gpa),
            .shapes = shapes,
            .font_cache = .{ .loaded = true, .font = font },
            .window = .{},
        };
    }

    pub fn deinit(self: *UiHost) void {
        self.ctx.deinit();
    }

    /// Begin a UI frame: build the input snapshot from `f`, stamp the canvas
    /// size, and return the `Ui` handle for widget calls. Pair with `render`.
    pub fn begin(self: *UiHost, f: *Frame) ui.Ui {
        // Precondition: the UI is built INTO the open draw frame, so
        // beginDrawing MUST have run first. Calling begin() before
        // beginDrawing (or clearing after it) renders the UI into no
        // pass — a silent blank window. Trap it with a clear message
        // instead. Surfaces on the page via std_options = z.std_options.
        const app: *App = appOf(f.gl);
        assertf(
            app.drawing_active,
            @src(),
            "UiHost.begin called before z.beginDrawing - build the UI inside a " ++
                "draw frame: call z.beginDrawing(f.gl) (and clearBackground) " ++
                "BEFORE ui_host.begin(f)",
            .{},
        );
        const m: Vec2 = getMousePosition(f.input);
        // The window's screen-vs-render dims drive drawing.zig's scissor DPR
        // ratio (sx = render/screen) AND its Y-flip (render_h - y). The render
        // dims MUST be EXACTLY the ones WgpuGl uses for its own gl.scissor clamp,
        // or the clip lands in the wrong region (the recurring "scissored" bug).
        // begin() runs AFTER beginDrawing, so f.gl.render_w/h are already set to
        // the backing size — read THOSE (single source of truth), never re-query
        // the surface (which can drift across a resize between the two calls).
        const app_for_size: *App = app;
        const css_sz: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app_for_size.gpu_frame.surface);
        self.window.render_width = @intCast(@max(f.gl.render_w, 1));
        self.window.render_height = @intCast(@max(f.gl.render_h, 1));

        // The `.fit` letterbox, from the ONE derivation. The UI's clip rects arrive in LOGICAL
        // (design) space; the scissor path needs logical -> CSS -> backing, and without this it
        // only ever did the CSS -> backing half.
        const fit: FitXform = if (app.config.window.scale_mode == .fit)
            fitScaleOffset(
                float(app.config.window.width),
                float(app.config.window.height),
                float(@max(css_sz.width, 1)),
                float(@max(css_sz.height, 1)),
            )
        else
            .{ .scale = 1.0, .off_x = 0.0, .off_y = 0.0 };
        self.window.fit_scale = fit.scale;
        self.window.fit_off_x = fit.off_x;
        self.window.fit_off_y = fit.off_y;
        // screen (logical) = render / dpr; derive dpr from backing/css so the
        // ratio render/screen reproduces the true device-pixel-ratio even if the
        // CSS query and the gl render dims came from slightly different moments.
        const dpr_x: f32 = if (css_sz.width > 0)
            float(f.gl.render_w) / float(css_sz.width)
        else
            1.0;
        const dpr_y: f32 = if (css_sz.height > 0)
            float(f.gl.render_h) / float(css_sz.height)
        else
            1.0;
        const sw_f: f32 = float(f.gl.render_w) / @max(dpr_x, 0.0001);
        const sh_f: f32 = float(f.gl.render_h) / @max(dpr_y, 0.0001);
        self.window.screen_width = @trunc(@max(1.0, sw_f));
        self.window.screen_height = @trunc(@max(1.0, sh_f));
        const snap: ui.InputSnapshot = .{
            .mouse_pos = m,
            .mouse_left_down = isMouseButtonDown(f.input, .left),
            .mouse_left_clicked = isMouseButtonPressed(f.input, .left),
            .mouse_left_released = isMouseButtonReleased(f.input, .left),
            .mouse_right_clicked = isMouseButtonPressed(f.input, .right),
            .mouse_wheel_y = getMouseWheelMove(f.input),
            .touch_count = getTouchPointCount(f.input),
            .touch_pos = .{ getTouchPosition(f.input, 0), getTouchPosition(f.input, 1) },
            .delta_time = f.time.delta_time,
        };
        const ui_handle: ui.Ui = self.ctx.beginFrameRaw(
            snap,
            f.input,
            @intCast(f.window.screen_width),
            @intCast(f.window.screen_height),
            f.gl,
            &self.shapes,
            &self.font_cache,
        );
        return ui_handle;
    }

    /// Replay the UI draw lists to the frame's gl (single pass). Call after the
    /// widget calls, before endDrawing.
    pub fn render(self: *UiHost, f: *Frame) void {
        self.ctx.endFrameNoRender();
        ui.uiRenderNow(&self.ctx, f.gl, &self.window, &self.shapes, &self.font_cache);
    }
};

/// Load a TTF/OTF font for the WebGPU 2D path: bake an ASCII (32..126) atlas at
/// `size` px, upload it as a texture, register it, and return a `Font` whose
/// `texture.id` is the registered id (so `drawText` -> the reusable
/// `drawWithFont` -> `drawTextureRotated(gl, font.texture, ...)` resolves it via
/// WgpuGl.setTexture). Caller keeps the Font on its State; the glyph/rec slices
/// are gpa-owned. Must be called from initState (needs the App's renderer +
/// device; the renderer is created lazily on first beginDrawing, so this
/// triggers that).
pub fn loadFont(
    f: *Frame,
    gpa: Allocator,
    ttf_bytes: []const u8,
    size: i32,
) !Font {
    // ASCII 32..126 — the printable set the FPS counter / labels need.
    var codepoints: [95]u21 = undefined;
    for (&codepoints, 0..) |*cp, k| {
        cp.* = @intCast(32 + k);
    }
    return loadFontEx(f, gpa, ttf_bytes, size, &codepoints);
}

/// Release a font COMPLETELY: free its CPU glyph/rec arrays AND its GPU atlas
/// (texture + material bind group), recycling the registry slot.
///
/// Use this when REPLACING a font while the app runs — e.g. re-baking it with
/// more codepoints. `z.unloadFont` frees only the CPU side, which is right at
/// teardown (`deinit` has no `gl`, and the registry reset reclaims every
/// engine-owned texture anyway) but wrong mid-run: each re-bake would register a
/// NEW atlas and abandon the old one. After `max_registered_textures` (64) of
/// those, `registerTexture` runs out of slots and hands back the white texture —
/// and the text silently turns into solid blocks.
///
/// The batch is flushed first when a pass is open, because staged geometry can
/// still reference the bind group being destroyed.
pub fn releaseFont(gl: *WgpuGl, gpa: Allocator, font: Font) void {
    const app: *App = appOf(gl);
    if (app.renderer_2d) |*r| {
        if (app.drawing_active) {
            gl.flushBeforeMaterialSwap();
        }
        r.releaseTextureById(font.texture.id);
    }
    text2d.unloadFontOwned(gpa, font);
}

/// Like `loadFont`, but bakes an EXPLICIT codepoint set instead of ASCII 32..126
/// (raylib `LoadFontEx` with a `codepoints` array). This is how you get accented
/// Latin, Greek, Cyrillic, CJK, arrows, box-drawing — anything outside ASCII.
///
/// Only the codepoints you ask for are baked, so the atlas stays small: pass the
/// ranges the app actually renders, not "all of Unicode". A codepoint the TTF
/// has no glyph for bakes as the font's fallback/notdef rather than failing.
/// The slice is consumed during the call (the atlas copies what it needs), so a
/// stack array is fine.
pub fn loadFontEx(
    f: *Frame,
    gpa: Allocator,
    ttf_bytes: []const u8,
    size: i32,
    codepoints: []const u21,
) !Font {
    const app: *App = appOf(f.gl);
    // Ensure the Renderer2D (which owns the texture registry + device) exists.
    if (app.renderer_2d == null) {
        app.renderer_2d = try Renderer2D.init(gpa, &app.gpu_frame);
    }
    const r: *Renderer2D = &app.renderer_2d.?;

    const tt: codecs.truetype.Font = try codecs.truetype.loadFontFromTtf(gpa, ttf_bytes);
    // Bake the atlas at DEVICE pixels (logical size × devicePixelRatio), not logical
    // size. The wgpu 2D path renders into the backing store (CSS × DPR); an atlas baked
    // at logical size gets UPSCALED on a high-DPR phone → blurry text. Baking at
    // size×DPR makes the atlas ~1:1 with the backing → sharp. baseSize tracks the bake
    // size, so drawText/measureText still produce LOGICAL sizes (the scale divides it
    // back out) — transparent to callers, just crisper. DPR = backing/CSS surface size.
    //
    // OVERSAMPLE headroom: the atlas is frozen at load-time DPR and never re-baked, so
    // any later MAGNIFICATION (entering browser fullscreen — a `.fit`-mode app scales its
    // fixed design surface up to the whole monitor, ~2.4–3× on 1080p, more on 1440p/4K —
    // moving to a denser monitor, or drawing text bigger than `size`) samples a too-small
    // atlas → blur. Baking 3× the currently-needed density gives that magnification
    // headroom. This is only affordable because the atlas is MIPMAPPED (see
    // createMipmappedFromPixels): without mips, a 3× atlas would badly alias small text on
    // minification; with a mip chain the GPU picks a level near the on-screen size, so the
    // same atlas stays crisp whether the text is tiny (UI labels) or fullscreen-huge. The
    // multiplier is capped so a high-DPR phone doesn't blow the atlas up (memory is
    // width×height + a ~33% mip tail, so it grows with the square of the multiplier).
    const oversample: f32 = 3.0;
    const css_sz: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
    const back_sz: wgpu.SurfaceSize = wgpu.getSurfaceSize(app.gpu_frame.surface);
    const dpr: f32 = if (css_sz.width > 0)
        float(back_sz.width) / float(css_sz.width)
    else
        1.0;
    // clamp the TOTAL bake density (dpr × oversample) to [1, 4]: 3× headroom on a DPR-1
    // desktop (where fullscreen magnification bites hardest), still bounded on a DPR-3
    // phone. baseSize carries the real bake height, so the logical scale stays exact.
    const bake_mult: f32 = clamp(dpr * oversample, 1.0, 4.0);
    const bake_size: i32 = @round(float(size) * bake_mult);
    const atlas: text2d.FontAtlas = try text2d.bakeFontAtlas(gpa, &tt, bake_size, codepoints, 1);
    // The atlas image (RGBA8) is uploaded to the GPU; free the CPU copy after.
    defer image_mod.unloadImage(gpa, atlas.image);

    const aw: u32 = @intCast(atlas.image.width);
    const ah: u32 = @intCast(atlas.image.height);
    const pixels: []const u8 = @as([*]const u8, @ptrCast(atlas.image.data.?))[0 .. aw * ah * 4];
    // Mipmapped, trilinear-sampled glyph atlas. The atlas is baked OVERSAMPLED
    // (see `oversample` above), so at draw time it is almost always MINIFIED —
    // and plain bilinear undersamples past ~2× reduction, which is what left the
    // small on-screen/UI text aliased ("pixelated") even after switching off
    // NEAREST. A precomputed mip chain lets the GPU pick a level near the
    // on-screen size, so both tiny UI labels and large fullscreen text stay
    // crisp. createFromPixels defaults to NEAREST (blocky at any non-1:1 scale).
    const tex: WgpuTexture = try WgpuTexture.createMipmappedFromPixels(
        gpa,
        app.gpu_frame.device,
        app.gpu_frame.queue,
        .{
            .pixels = pixels,
            .width = aw,
            .height = ah,
            .format = .rgba8_unorm,
        },
    );
    const tex_id: u32 = r.registerOwnedTexture(tex);

    return .{
        .baseSize = atlas.base_size,
        .glyphCount = @intCast(atlas.glyphs.len),
        .glyphPadding = atlas.glyph_padding,
        .texture = .{ .id = tex_id, .width = @intCast(aw), .height = @intCast(ah) },
        .recs = atlas.recs.ptr,
        .glyphs = atlas.glyphs.ptr,
    };
}

/// raylib's `LoadFontData(..., FONT_SDF, ...)` — bake a font as a SIGNED
/// DISTANCE FIELD. Unlike the coverage atlas (`loadFont`/`loadFontEx`), an SDF
/// atlas stays crisp when magnified far past its bake size, because a
/// `smoothstep(0.5 ± w, alpha)` fragment shader reconstructs the edge from the
/// distance instead of interpolating coverage (which blurs). Draw the returned
/// font INSIDE `beginShaderMode(sdf_shader)` / `endShaderMode` — the shader
/// (`src/shaders/text_sdf_fs.zig`) is the SDF twin of the shapes fragment stage.
///
/// `sdf_size` is the atlas bake height in px (raylib uses ~16–64; larger =
/// smoother field, bigger atlas). The atlas is baked at that size (no oversample
/// — the SDF carries the scale) then converted with `image_mod.coverageToSdf`, and
/// uploaded LINEAR-filtered (bilinear interpolation of the distance is what
/// makes the edge smooth). Free with `z.unloadFont` / `releaseFont` as usual.
pub fn loadFontSdf(
    f: *Frame,
    gpa: Allocator,
    ttf_bytes: []const u8,
    sdf_size: i32,
) !Font {
    const app: *App = appOf(f.gl);
    if (app.renderer_2d == null) {
        app.renderer_2d = try Renderer2D.init(gpa, &app.gpu_frame);
    }
    const r: *Renderer2D = &app.renderer_2d.?;

    var codepoints: [95]u21 = undefined;
    for (&codepoints, 0..) |*cp, k| {
        cp.* = @intCast(32 + k);
    }

    const tt: codecs.truetype.Font = try codecs.truetype.loadFontFromTtf(gpa, ttf_bytes);
    // Bake the coverage atlas at the SDF size directly — no DPR/oversample: the
    // distance field, not extra texels, is what buys magnification headroom.
    const atlas: text2d.FontAtlas = try text2d.bakeFontAtlas(gpa, &tt, sdf_size, &codepoints, 1);
    defer image_mod.unloadImage(gpa, atlas.image);

    // Coverage → SDF, in place. Spread is the distance (px) mapped to the
    // ±0.5 alpha range. It must stay near a glyph's stroke half-width (a few
    // px) or the field compresses toward 0.5 and nothing renders solid — a
    // spread of size/8 was the bug that made SDF text mottle. ~size/18 keeps a
    // 64px bake's interior near ~0.8 and the background at 0, a clean split.
    const spread: f32 = @max(3.0, float(sdf_size) / 18.0);
    try image_mod.coverageToSdf(gpa, atlas.image, spread);

    const aw: u32 = @intCast(atlas.image.width);
    const ah: u32 = @intCast(atlas.image.height);
    const pixels: []const u8 = @as([*]const u8, @ptrCast(atlas.image.data.?))[0 .. aw * ah * 4];
    // LINEAR (bilinear) sampling: the shader reads a smoothly interpolated
    // distance and thresholds it. NEAREST would step the field and re-alias.
    const tex: WgpuTexture = WgpuTexture.createFromPixels(app.gpu_frame.device, app.gpu_frame.queue, .{
        .pixels = pixels,
        .width = aw,
        .height = ah,
        .format = .rgba8_unorm,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .label = "sdf_font_atlas",
    });
    const tex_id: u32 = r.registerOwnedTexture(tex);

    return .{
        .baseSize = atlas.base_size,
        .glyphCount = @intCast(atlas.glyphs.len),
        .glyphPadding = atlas.glyph_padding,
        .texture = .{ .id = tex_id, .width = @intCast(aw), .height = @intCast(ah) },
        .recs = atlas.recs.ptr,
        .glyphs = atlas.glyphs.ptr,
    };
}

/// raylib's `LoadFontFromImage` — build a Font from a BITMAP-FONT image
/// (XNA style), where glyphs sit on a `key`-coloured background separated by
/// key-coloured borders. Segments the image (via `image_mod.segmentSpriteFont`, a
/// pure/unit-tested port of raylib's scan), replaces the key colour with
/// transparent, uploads the cleaned image as a NEAREST-filtered atlas, and
/// returns a Font whose glyphs carry `advanceX = 0` — the draw path advances by
/// the rec width for image fonts, exactly like raylib's `DrawTextEx`.
///
/// `first_char` is the codepoint of the FIRST glyph (raylib uses 32 = space);
/// glyphs are numbered sequentially from there. `image` is NOT consumed — the
/// caller still owns and frees it (only the cleaned COPY is uploaded). Free the
/// returned Font with `z.unloadFont` / `releaseFont` like any TTF font.
pub fn loadFontFromImage(
    gl: *WgpuGl,
    gpa: Allocator,
    image: types.Image,
    key: Color,
    first_char: i32,
) !Font {
    const max_glyphs: usize = 256;
    // These read the `image` ARGUMENT, not the `image_mod` module -- a rename
    // that half-landed left four references pointing at the module, which has no
    // such fields. Nothing caught it because Zig's lazy analysis never reached
    // this fn: no example calls loadFontFromImage, so only `zig build test`
    // (which does refAllDecls) ever tried to compile it, and that step was
    // already failing for its own reasons.
    if (image.width <= 0 or image.height <= 0 or image.data == null) {
        return error.InvalidImage;
    }
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const src: [*]const u8 = @ptrCast(image.data.?);

    // Segment glyphs (pure CPU, unit-tested against a reference in image_mod.zig).
    var temp_recs: [max_glyphs]types.Rectangle = undefined;
    var temp_vals: [max_glyphs]i32 = undefined;
    const layout: image_mod.SpriteFontLayout =
        try image_mod.segmentSpriteFont(image, key, first_char, &temp_recs, &temp_vals);
    const count: usize = layout.count;

    // Cleaned atlas: copy the pixels and turn every key pixel transparent, so
    // the background doesn't show and bilinear edges don't bleed the key colour.
    const n_bytes: usize = w * h * 4;
    const cleaned: []u8 = try gpa.alloc(u8, n_bytes);
    defer gpa.free(cleaned);
    @memcpy(cleaned, src[0..n_bytes]);
    {
        var i: usize = 0;
        while (i < w * h) : (i += 1) {
            const b: usize = i * 4;
            if (cleaned[b + 0] == key.r and cleaned[b + 1] == key.g and
                cleaned[b + 2] == key.b and cleaned[b + 3] == key.a)
            {
                cleaned[b + 0] = 0;
                cleaned[b + 1] = 0;
                cleaned[b + 2] = 0;
                cleaned[b + 3] = 0;
            }
        }
    }

    // Upload as a NEAREST atlas (pixel fonts stay crisp at integer scale) and
    // register it engine-owned (freed with the renderer's registry at teardown).
    const app: *App = appOf(gl);
    if (app.renderer_2d == null) {
        app.renderer_2d = try Renderer2D.init(gpa, &app.gpu_frame);
    }
    const r: *Renderer2D = &app.renderer_2d.?;
    const tex: WgpuTexture = WgpuTexture.createFromPixels(app.gpu_frame.device, app.gpu_frame.queue, .{
        .pixels = cleaned,
        .width = @intCast(w),
        .height = @intCast(h),
        .label = "spritefont_atlas",
    });
    const tex_id: u32 = r.registerOwnedTexture(tex);

    // Final glyph/rec arrays (freed by unloadFont/unloadFontOwned via freeMany).
    const recs: []types.Rectangle = try gpa.alloc(types.Rectangle, count);
    errdefer gpa.free(recs);
    const glyphs: []types.GlyphInfo = try gpa.alloc(types.GlyphInfo, count);
    errdefer gpa.free(glyphs);
    for (0..count) |k| {
        recs[k] = temp_recs[k];
        glyphs[k] = .{
            .value = temp_vals[k],
            .offsetX = 0,
            .offsetY = 0,
            .advanceX = 0,
            // XNA image fonts have no per-glyph CPU bitmap; a zeroed Image is
            // null-data, so unloadImage no-ops on it (safe teardown).
            .image = std.mem.zeroes(types.Image),
        };
    }

    return .{
        .baseSize = @intFromFloat(recs[0].height),
        .glyphCount = @intCast(count),
        .glyphPadding = 0,
        .texture = .{ .id = tex_id, .width = @intCast(w), .height = @intCast(h) },
        .recs = recs.ptr,
        .glyphs = glyphs.ptr,
    };
}

/// Draw `text` at (x, y) in `size` px, tinted `color`. Routes through the
/// reusable, backend-agnostic `drawWithFont` (line spacing 0, glyph spacing 0).
pub fn drawText(
    gl: *WgpuGl,
    font: Font,
    text: []const u8,
    x: f32,
    y: f32,
    size: f32,
    color: Color,
) void {
    text2d.drawWithFont(gl, 0, font, text, .{ x, y }, size, 0, color);
}

/// Measure `text` at `size` px → (width, height) in logical px.
pub fn measureText(
    font: Font,
    text: []const u8,
    size: f32,
) Vec2 {
    return text2d.measureWithFont(0, font, text, size, 0);
}

/// raylib's `MeasureTextEx` — measure with an explicit inter-glyph `spacing`
/// (the drawing side is `gl.text(pos, s, .{ .spacing = ... })`). Needed to
/// centre a spacing-adjusted string.
pub fn measureTextEx(
    font: Font,
    text: []const u8,
    size: f32,
    spacing: f32,
) Vec2 {
    return text2d.measureWithFont(0, font, text, size, spacing);
}

// ---- scissor / clip (N5g) ----
// Restrict drawing to a rectangle (in logical coords — same space as
// drawRectangle etc.). Flushes the batch first (the scissor is a pass-state
// change, so prior geometry isn't retroactively clipped), converts logical ->
// BACKING px (accounting for DPR and .fit letterbox), and sets the GPU scissor.

fn logicalToBacking(
    app: *App,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) [4]u32 {
    const css: wgpu.SurfaceSize = wgpu.getSurfaceCssSize(app.gpu_frame.surface);
    const backing: wgpu.SurfaceSize = wgpu.getSurfaceSize(app.gpu_frame.surface);
    const cssw: f32 = float(@max(css.width, 1));
    const cssh: f32 = float(@max(css.height, 1));
    const bw: f32 = float(@max(backing.width, 1));
    const bh: f32 = float(@max(backing.height, 1));

    // logical -> CSS via the ONE shared transform (same one input inverts).
    const c: [4]f32 = logicalToCss(app, x, y, w, h);
    const rx: f32 = bw / cssw;
    const ry: f32 = bh / cssh;
    // CSS -> backing px.
    var px: f32 = c[0] * rx;
    var py: f32 = c[1] * ry;
    var pw: f32 = c[2] * rx;
    var ph: f32 = c[3] * ry;

    // Layer-2 guard: a scissor rect MUST be contained in the render area, or
    // WebGPU rejects the whole command buffer (the turn-912 dead-screen). A
    // coordinate-space mistake upstream lands here as an out-of-bounds rect.
    // Debug-assert containment so the mistake panics at the offending call;
    // then CLAMP to [0, backing] so release builds degrade gracefully (a
    // slightly-wrong clip) instead of a GPU crash + blank canvas.
    assert(px >= -0.5 and py >= -0.5 and
        px + pw <= bw + 0.5 and py + ph <= bh + 0.5, @src()); // scissor out of render area — coord-space bug
    if (px < 0) {
        pw += px;
        px = 0;
    }
    if (py < 0) {
        ph += py;
        py = 0;
    }
    if (px + pw > bw) {
        pw = bw - px;
    }
    if (py + ph > bh) {
        ph = bh - py;
    }
    if (pw < 0) {
        pw = 0;
    }
    if (ph < 0) {
        ph = 0;
    }

    return .{
        @trunc(px),
        @trunc(py),
        @trunc(pw),
        @trunc(ph),
    };
}

/// Clip subsequent 2D drawing to (x, y, w, h) in logical coords. Pair with
/// endScissorMode. raylib's beginScissorMode shape.
/// Map a child app into `placement` for one tick: set the modelview to
/// translate(+scale) the child's LOCAL coords onto the parent screen, clip to
/// the rect, and report the child's logical size via `f.window`. The per-frame
/// projection ortho is UNCHANGED — the placement rides in the modelview (applied
/// per-vertex at emit time), so any number of children share one open render
/// pass + one ortho with no UBO conflict. Pair with `popViewport`. This is the
/// multi-app launcher's workhorse; an example body never calls it. Nestable (a
/// child may itself be a launcher).
pub fn pushViewport(f: *Frame, placement: Placement) void {
    const app: *App = appOf(f.gl);
    assertf(
        app.viewport_depth < app.viewport_stack.len,
        @src(),
        "pushViewport: stack overflow (max {d} nested viewports)",
        .{app.viewport_stack.len},
    );
    // Commit geometry drawn under the prior modelview/scissor before changing them.
    f.gl.flushBeforeMaterialSwap();

    app.viewport_stack[app.viewport_depth] = .{ .modelview = f.gl.modelview, .window = f.window };
    app.viewport_depth += 1;

    const lw: f32 = @max(placement.logical_w, 1);
    const lh: f32 = @max(placement.logical_h, 1);
    var s: f32 = 1;
    var ox: f32 = placement.rect.x;
    var oy: f32 = placement.rect.y;
    if (placement.scale_to_fit) {
        s = @min(placement.rect.width / lw, placement.rect.height / lh);
        ox = placement.rect.x + (placement.rect.width - lw * s) * 0.5;
        oy = placement.rect.y + (placement.rect.height - lh * s) * 0.5;
    }
    // modelview = translate(ox,oy) * scale(s): local (x,y) -> (s*x+ox, s*y+oy).
    // Column-major (4 columns), matching the rest of the matrix stack.
    f.gl.modelview = .{
        vec4(s, 0, 0, 0),
        vec4(0, s, 0, 0),
        vec4(0, 0, 1, 0),
        vec4(ox, oy, 0, 1),
    };
    // Clip to the on-screen rect (logical px -> backing px, via the scissor path).
    const rr: types.Rectangle = placement.rect;
    const r: [4]u32 = logicalToBacking(app, rr.x, rr.y, rr.width, rr.height);
    wgpu.render_pass.setScissorRect(app.pass.pass, r[0], r[1], r[2], r[3]);
    // The child sees its own logical size as the window.
    f.window = .{ .screen_width = @trunc(lw), .screen_height = @trunc(lh) };
}

/// Restore the drawing state saved by the matching `pushViewport`: modelview,
/// `f.window`, and the scissor (reset to the full surface). One-level/grid use
/// is exact; nested-scissor INTERSECTION is a later refinement (a deeper child's
/// clip currently widens back to the full surface until its own pushViewport
/// reclips — fine for a flat grid).
pub fn popViewport(f: *Frame) void {
    const app: *App = appOf(f.gl);
    assertf(app.viewport_depth > 0, @src(), "popViewport without a matching pushViewport", .{});
    f.gl.flushBeforeMaterialSwap();
    app.viewport_depth -= 1;
    const save: ViewportSave = app.viewport_stack[app.viewport_depth];
    f.gl.modelview = save.modelview;
    f.window = save.window;
    const backing: wgpu.SurfaceSize = wgpu.getSurfaceSize(app.gpu_frame.surface);
    wgpu.render_pass.setScissorRect(app.pass.pass, 0, 0, backing.width, backing.height);
}

/// Stable, sequential child id handed out by `Launcher.add`.
pub const ChildId = usize;

/// A multi-app launcher: holds N type-erased child apps, each with its OWN
/// leak-checking allocator, and ticks/resets/removes them. A "launcher app"
/// (itself an AppSpec) drives this from its `update` (see
/// examples/gallery_all). No globals — everything lives in the Launcher
/// value + the Frame it is handed. Children are heap-allocated records so their
/// per-child allocator never moves (an ArrayList realloc would dangle it).
pub const Launcher = struct {
    /// Slot alignment for a child's State. Covers @Vector(4,f32)/Mat etc.;
    /// asserted per add so an over-aligned State fails loudly, not silently.
    const slot_align = 16;

    const Rec = struct {
        // Per-child owner gen for registry attribution (id+1, so never 0).
        gen: u32 = 0,
        vt: AppVtable,
        // DebugAllocator's `safety` defaults to runtime_safety: ON in debug, OFF
        // in ReleaseSmall. That's exactly the policy we want — leak detection in
        // debug only — so we DON'T override it. In release the per-child
        // allocator is a thin passthrough and reset's leak check is a no-op.
        dbg: std.heap.DebugAllocator(.{}),
        state: []align(slot_align) u8,
        alive: bool,
    };

    backing: Allocator,
    recs: ArrayList(*Rec),

    pub fn init(backing: Allocator) Launcher {
        return .{ .backing = backing, .recs = .empty };
    }

    pub fn deinit(self: *Launcher) void {
        for (self.recs.items) |rec| {
            if (rec.alive) {
                rec.vt.deinit(rec.dbg.allocator(), @ptrCast(rec.state.ptr));
            }
            _ = rec.dbg.deinit();
            self.backing.free(rec.state);
            self.backing.destroy(rec);
        }
        self.recs.deinit(self.backing);
    }

    /// Tag subsequent texture registrations with a child's gen (0 to clear), so
    /// the shared registry can release exactly that child on teardown. No-op if
    /// the engine renderer isn't created yet.
    fn setChildRegOwner(f: *Frame, owner: u32) void {
        if (appOf(f.gl).renderer_2d) |*r| {
            r.setRegOwner(owner);
        }
    }

    /// Add a child: allocate its State slot + its own leak-checking allocator,
    /// then run the app's `init`. `init` needs a live-GPU Frame. Returns the id.
    pub fn add(self: *Launcher, f: *Frame, vt: AppVtable) !ChildId {
        assertf(
            vt.state_align <= slot_align,
            @src(),
            "child State align {d} exceeds launcher slot align {d}",
            .{ vt.state_align, slot_align },
        );
        const rec: *Rec = try self.backing.create(Rec);
        errdefer self.backing.destroy(rec);
        rec.* = .{ .gen = @intCast(self.recs.items.len + 1), .vt = vt, .dbg = .{}, .state = undefined, .alive = false };
        rec.state = try self.backing.alignedAlloc(u8, comptime .fromByteUnits(slot_align), @max(vt.state_size, 1));
        errdefer self.backing.free(rec.state);
        setChildRegOwner(f, rec.gen);
        defer setChildRegOwner(f, 0);
        try vt.init(rec.dbg.allocator(), f, @ptrCast(rec.state.ptr));
        rec.alive = true;
        try self.recs.append(self.backing, rec);
        return self.recs.items.len - 1;
    }

    /// Add a child WITHOUT initializing it yet (lazy): allocate its State slot
    /// and record the vtable, but defer `init` until the child is first ticked.
    /// Keeps boot light when hosting many heavy apps — only the shown app pays
    /// its init cost, on the frame it's first switched to. No Frame needed here.
    pub fn addDeferred(self: *Launcher, vt: AppVtable) !ChildId {
        assertf(
            vt.state_align <= slot_align,
            @src(),
            "child State align {d} exceeds launcher slot align {d}",
            .{ vt.state_align, slot_align },
        );
        const rec: *Rec = try self.backing.create(Rec);
        errdefer self.backing.destroy(rec);
        rec.* = .{ .gen = @intCast(self.recs.items.len + 1), .vt = vt, .dbg = .{}, .state = undefined, .alive = false };
        rec.state = try self.backing.alignedAlloc(u8, comptime .fromByteUnits(slot_align), @max(vt.state_size, 1));
        errdefer self.backing.free(rec.state);
        try self.recs.append(self.backing, rec);
        return self.recs.items.len - 1;
    }

    /// Init a deferred child on first use. Returns false if it isn't runnable
    /// (init failed). A live-GPU Frame is required (init builds GPU resources).
    fn ensureInit(self: *Launcher, f: *Frame, rec: *Rec) bool {
        _ = self;
        if (rec.alive) {
            return true;
        }
        setChildRegOwner(f, rec.gen);
        defer setChildRegOwner(f, 0);
        rec.vt.init(rec.dbg.allocator(), f, @ptrCast(rec.state.ptr)) catch |e| {
            std.log.err("zimr launcher: child init failed: {s}", .{@errorName(e)});
            return false;
        };
        rec.alive = true;
        return true;
    }

    /// Tick a child into `placement`: push the viewport, run its `update`, pop.
    pub fn tick(self: *Launcher, f: *Frame, id: ChildId, placement: Placement) void {
        const rec: *Rec = self.recs.items[id];
        const app: *App = appOf(f.gl);
        const prev: bool = app.child_tick_active;
        app.child_tick_active = true;
        defer app.child_tick_active = prev;
        if (!self.ensureInit(f, rec)) {
            return;
        }
        setChildRegOwner(f, rec.gen);
        defer setChildRegOwner(f, 0);
        pushViewport(f, placement);
        rec.vt.update(f, @ptrCast(rec.state.ptr));
        popViewport(f);
    }

    /// Tick a child full-screen with NO viewport push: the child owns the whole
    /// frame exactly as standalone (it may clear and even call endDrawing). Used
    /// by the launcher, which shows one example at a time full-screen — pairing a
    /// `pushViewport` with a child that ends the frame would pop a closed pass.
    pub fn tickFullscreen(self: *Launcher, f: *Frame, id: ChildId) void {
        const rec: *Rec = self.recs.items[id];
        // The child draws its scene + its own UI; the launcher composes the
        // switcher on top, and the runner closes the frame once. A child must NOT
        // call endDrawing — that's asserted via child_tick_active in App.endDrawing.
        const app: *App = appOf(f.gl);
        const prev: bool = app.child_tick_active;
        app.child_tick_active = true;
        defer app.child_tick_active = prev;
        if (!self.ensureInit(f, rec)) {
            return;
        }
        setChildRegOwner(f, rec.gen);
        defer setChildRegOwner(f, 0);
        rec.vt.update(f, @ptrCast(rec.state.ptr));
    }

    /// Reset a child: deinit -> LEAK-CHECK (its allocator must come back empty)
    /// -> re-init. A leak is logged (not fatal) and points at the child's
    /// `deinit` not freeing everything `init` allocated. Needs a live-GPU Frame.
    pub fn reset(self: *Launcher, f: *Frame, id: ChildId) void {
        const rec: *Rec = self.recs.items[id];
        if (!rec.alive) {
            return;
        }
        rec.vt.deinit(rec.dbg.allocator(), @ptrCast(rec.state.ptr));
        if (rec.dbg.deinit() == .leak) {
            std.log.warn(
                "zimr launcher: child {d} leaked on reset - its deinit didn't free all of init's allocations",
                .{id},
            );
        }
        rec.dbg = .{};
        // Release this child's registry entries (bind groups + engine-owned font
        // atlas), reclaiming the ids — siblings in a shared registry are untouched.
        if (appOf(f.gl).renderer_2d) |*r| {
            r.releaseOwner(rec.gen);
        }
        setChildRegOwner(f, rec.gen);
        defer setChildRegOwner(f, 0);
        rec.vt.init(rec.dbg.allocator(), f, @ptrCast(rec.state.ptr)) catch |e| {
            std.log.err("zimr launcher: child {d} re-init failed: {s}", .{ id, @errorName(e) });
            rec.alive = false;
        };
    }
};

pub fn beginScissorMode(
    gl: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) void {
    const app: *App = appOf(gl);
    gl.flushBeforeMaterialSwap(); // flush so prior geometry isn't clipped
    const rect: [4]u32 = logicalToBacking(app, x, y, w, h);
    wgpu.render_pass.setScissorRect(app.pass.pass, rect[0], rect[1], rect[2], rect[3]);
}

/// Remove the clip rect (reset scissor to the full surface).
pub fn endScissorMode(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    gl.flushBeforeMaterialSwap();
    const backing: wgpu.SurfaceSize = wgpu.getSurfaceSize(app.gpu_frame.surface);
    wgpu.render_pass.setScissorRect(app.pass.pass, 0, 0, backing.width, backing.height);
}
// ---- fullscreen shader (N6: the GPU half of the side-by-side) ----
//
// Run an engine `_fs.zig` shader's pipeline (built via z.shader.loadShader) as
// a fullscreen pass: bind its pipeline + UBO group on the live pass, then draw
// a single triangle that covers clip space ([-1,-1],[3,-1],[-1,3]). The shader's
// VS passes positions straight to clip space, so the 2D ortho doesn't apply.

/// Bind a loaded fullscreen shader's pipeline + bind groups on the current
/// drawing pass. Flushes any pending 2D batch first (it belongs to the shapes
/// pipeline). Generic over the shader's schema. Pair with drawFullscreenTriangle.
pub fn bindFullscreenShader(
    gl: *WgpuGl,
    comptime SchemaT: type,
    loaded: *shader_runtime.LoadedShader(SchemaT),
) void {
    comptime assertFullscreenBatchSafe(SchemaT);
    const app: *App = appOf(gl);
    // Flush the shapes batch so prior 2D geometry is committed under its own
    // pipeline before we swap to the fullscreen shader.
    Backend.flushBatch(&app.pass);
    loaded.bindForDraw(&app.pass);
    // The fullscreen triangle is drawn THROUGH the 2D shapes batch but under the
    // pipeline we just bound — so that batch is now owned by THIS pipeline.
    // Record it, or the flush guard in `drawFullscreenTriangle` sees
    // current(fullscreen) != owner(stale 2D) and fires a false positive on a
    // correct draw. `drawFullscreenTriangle` calls `bindForPass` right after the
    // triangle flush, which restores the 2D pipeline AND owner — so subsequent
    // 2D drawing stays correctly owned and guarded (nothing is masked).
    app.pass.batch_owner_pipeline = app.pass.current_pipeline;
}

// The 2D batch reserves the same `@group` the DSL assigns material samplers
// to — that's WHY the batch can clobber a fullscreen sampler shader, and why
// `assertFullscreenBatchSafe` keys on `batch_reserved_group`. Tie the two
// numbers at compile time so they can never diverge and quietly defeat the
// guard (e.g. samplers move groups but the batch doesn't).
comptime {
    if (gpu_iface.batch_reserved_group != shader_interface.sampler_group) {
        @compileError("gpu_iface.batch_reserved_group must equal shader_interface.sampler_group: " ++
            "the 2D shapes batch binds its atlas at the material-sampler group, and the " ++
            "fullscreen-batch-safety guard relies on that equality.");
    }
}

/// Compile-time guard: `bindFullscreenShader` + `drawFullscreenTriangle` route
/// the draw through the 2D shapes batch, whose flush re-binds `@group(N)` (N =
/// `gpu_iface.batch_reserved_group`) to its texture atlas. A shader that uses
/// that group — e.g. ANY texture sampler — would have its binding silently
/// clobbered and sample the atlas instead (the postprocess "bars" bug). This
/// turns that footgun into a compile error pointing at the safe path. Cost:
/// zero at runtime; it fires before anything ships.
fn assertFullscreenBatchSafe(comptime SchemaT: type) void {
    const si = shader_introspect;
    const layout: si.ResolvedLayout = si.solveLayout(SchemaT);
    const reserved: u32 = gpu_iface.batch_reserved_group;
    if (layout.groups_used & (@as(u8, 1) << @intCast(reserved)) != 0) {
        @compileError("Schema `" ++ @typeName(SchemaT) ++ "` binds a resource at @group(1), " ++
            "but bindFullscreenShader/drawFullscreenTriangle draw through the 2D shapes batch, " ++
            "which binds @group(1) to its texture atlas on flush — your binding (e.g. a texture " ++
            "sampler) would be silently clobbered and the shader would sample the atlas instead. " ++
            "Use `z.drawFullscreenShader(gl, " ++ @typeName(SchemaT) ++ ", &loaded)` instead: it " ++
            "draws through the shader's OWN pipeline + bind groups and never touches the batch.");
    }
}

/// Draw a fullscreen triangle through the currently-bound pipeline (set by
/// bindFullscreenShader). Uses the shapes batch's vertex/index buffers for the
/// 3 verts, in clip-space coords. After this, the next 2D draw rebinds the
/// shapes pipeline via the batch's normal flush path.
///
/// ONLY valid for fullscreen shaders that don't use `@group(1)` (e.g. FS-UBO at
/// group 2); the batch owns group 1. For texture-sampling fullscreen shaders use
/// `drawFullscreenShader`.
pub fn drawFullscreenTriangle(gl: *WgpuGl) void {
    const app: *App = appOf(gl);
    // Fullscreen triangle covering clip space. UVs follow the GPU's natural
    // convention here (v=0 at clip y=-1 = screen bottom). The TOP-LEFT-origin
    // agreement with raster is enforced on the raster side instead (see
    // raster_shader.dispatchFragmentShader), keeping this triangle's UVs the
    // simple, non-degenerate gradient the batch interpolates correctly.
    Backend.drawTriangleBatched(&app.pass, .{
        .p0 = .{ -1, -1 },
        .p1 = .{ 3, -1 },
        .p2 = .{ -1, 3 },
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 2, 0 },
        .uv2 = .{ 0, 2 },
        .colors = .{ .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 } },
    });
    Backend.flushBatch(&app.pass);
    // Re-bind the shapes pipeline for any subsequent 2D drawing this frame.
    app.renderer_2d.?.bindForPass(&app.pass);
}

/// Fullscreen verts for `drawFullscreenShader` — one big clip-space triangle,
/// uv 0..2 (the 0..1 window is the inscribed region). Vertex2D layout, matching
/// the default 2D vertex layout a `loadShaderVF` pipeline uses.
const fullscreen_verts = [_]gpu_iface.Vertex2D{
    .{ .pos = .{ -1, -1 }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 } },
    .{ .pos = .{ 3, -1 }, .uv = .{ 2, 0 }, .color = .{ 255, 255, 255, 255 } },
    .{ .pos = .{ -1, 3 }, .uv = .{ 0, 2 }, .color = .{ 255, 255, 255, 255 } },
};

fn ensureFullscreenVbo(app: *App) wgpu.BufferHandle {
    if (app.fullscreen_vbo == .invalid) {
        app.fullscreen_vbo = wgpu.createBuffer(app.gpu_frame.device, .{
            .size = @sizeOf(@TypeOf(fullscreen_verts)),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "engine_fullscreen_vbo",
        });
        wgpu.queueWriteBuffer(app.gpu_frame.queue, app.fullscreen_vbo, 0, std.mem.sliceAsBytes(&fullscreen_verts));
    }
    return app.fullscreen_vbo;
}

/// Draw a fullscreen triangle through a loaded shader's OWN pipeline + bind
/// groups (its `Resources`), with a shared engine-owned fullscreen vertex
/// buffer — NOT the 2D shapes batch. This is the correct path for ANY fullscreen
/// shader that samples a texture: the batch binds its atlas at `@group(1)` on
/// flush, which would clobber a shader's group-1 sampler. Works for UBO-only
/// fullscreen shaders too (it's strictly safe), so it's the general fullscreen-
/// shader draw. One call does bind + draw; no separate `bindFullscreenShader`.
pub fn drawFullscreenShader(
    gl: *WgpuGl,
    comptime SchemaT: type,
    loaded: *shader_runtime.LoadedShader(SchemaT),
) void {
    const app: *App = appOf(gl);
    // Commit any pending 2D geometry under the shapes pipeline first.
    Backend.flushBatch(&app.pass);
    const vbo: wgpu.BufferHandle = ensureFullscreenVbo(app);
    // Bind the shader's pipeline + ALL its bind groups (its group-1 sampler
    // survives — nothing touches the batch's group-1 binding after this).
    loaded.bindForDraw(&app.pass);
    loaded.setVertex(&app.pass, 0, vbo, @sizeOf(@TypeOf(fullscreen_verts)));
    loaded.draw(&app.pass, 3, 1);
    // Restore the shapes pipeline for any subsequent 2D drawing this frame.
    if (app.renderer_2d) |*r| {
        r.bindForPass(&app.pass);
    }
}

// `@import("root").zimr_app` — a single bridge pointer, not mutable app state.
// (Audited the same way: it's a bridge handle, not user data.)
// lint:off module-var: previous-frame timestamp for delta_time, owned by the frame driver
var prev_frame_ms: f64 = 0;

/// The wasm `update` export the JS RAF loop calls each tick. Builds a fresh
/// Frame (live window dims + dt) and dispatches to the user's update. No-op
/// until `App.run` has set `active_app`, so a RAF tick firing between wasm
/// instantiation and `main` running is harmless.
pub export fn update(dt_seconds: f32) void {
    _ = dt_seconds; // we compute dt from timestamps for monotonicity
    const app: *App = active_app orelse return;
    const thunk: UpdateThunk = app.update_fn orelse return;

    // Close the previous frame / open this one, then wrap the whole tick.
    profiler.frameMark();
    profiler.recordGpuMs(wgpu.gpuMs()); // GPU pass time from the last readback
    const zframe: profiler.Zone = profiler.zoneNamed(@src(), "frame");
    defer zframe.end();

    var frame: Frame = app.makeFrame();
    // delta_time from successive timestamps (the JS dt arg can be unreliable
    // across the first tick / tab-switch; a monotonic diff is steadier).
    const t_ms: f64 = wgpu.nowMs();
    if (prev_frame_ms != 0) {
        frame.time.delta_time = @floatCast((t_ms - prev_frame_ms) / 1000.0);
    }
    prev_frame_ms = t_ms;

    {
        const zu: profiler.Zone = profiler.zoneNamed(@src(), "update");
        defer zu.end();
        thunk(&frame, app.state);
    }
    // Advance input (current→previous) so just-pressed/released edge queries
    // work next frame, and clear the per-frame wheel/char deltas.
    {
        const zi: profiler.Zone = profiler.zoneNamed(@src(), "input.endFrame");
        defer zi.end();
        input.endFrame(&app.input_state);
    }
    app.frame_count += 1;
    // Smoke detector for unbounded wasm-memory growth (a per-frame leak).
    app.mem_watch.tick(app.frame_count);
}

// ============================================================================
// Input ingress — the wasm exports the JS bridge calls on DOM events. Each
// routes into the active App's input state. Coordinates arrive in LOGICAL
// pixels (the bridge converts clientX/Y → canvas-local at the JS edge), the
// same contract as the GL path. No-ops before App.run sets active_app.
// ============================================================================

fn inputState() ?*input.InputState {
    const app: *App = active_app orelse return null;
    return &app.input_state;
}

pub export fn input_push_mouse_move(x: f32, y: f32) void {
    const app: *App = active_app orelse return;
    // CSS px (from the bridge) -> the app's logical space (see cssToLogical).
    const p: [2]f32 = cssToLogical(app, x, y);
    input.pushMouseMove(&app.input_state, p[0], p[1]);
}
/// The JS `devicemotion` handler calls this with accelerationIncludingGravity
/// (m/s², device natural frame) and screen.orientation.angle. Routes into the
/// active App's motion state; `z.getDeviceGravity(f.input)` reads it back. One
/// channel is all we need — it already fuses gravity and motion (equivalence
/// principle), so there's no separate "linear acceleration" to plumb.
pub export fn input_push_motion(ax: f32, ay: f32, az: f32, screen_angle: f32) void {
    const app: *App = active_app orelse return;
    input.pushMotion(&app.input_state, ax, ay, az, screen_angle);
}
pub export fn input_push_mouse_button_down(button: i32) void {
    if (inputState()) |s| {
        input.pushMouseButtonDown(s, button);
    }
}
pub export fn input_push_mouse_button_up(button: i32) void {
    if (inputState()) |s| {
        input.pushMouseButtonUp(s, button);
    }
}
pub export fn input_push_mouse_wheel(dx: f32, dy: f32) void {
    if (inputState()) |s| {
        input.pushMouseWheel(s, dx, dy);
    }
}
pub export fn input_push_key_down(key: i32, repeat: i32) void {
    if (inputState()) |s| {
        input.pushKeyDown(s, key, repeat);
    }
}
pub export fn input_push_key_up(key: i32) void {
    if (inputState()) |s| {
        input.pushKeyUp(s, key);
    }
}
pub export fn input_push_char(codepoint: i32) void {
    if (inputState()) |s| {
        input.pushChar(s, codepoint);
    }
}
pub export fn zimr_input_push_touch_down(
    id: i32,
    x: f32,
    y: f32,
) void {
    const app: *App = active_app orelse return;
    // Same CSS->logical mapping as the mouse, so touch and mouse agree in BOTH
    // scale modes (previously touch skipped the .fit inverse — a latent gap).
    const p: [2]f32 = cssToLogical(app, x, y);
    input.pushTouchDown(&app.input_state, id, p[0], p[1]);
}
pub export fn zimr_input_push_touch_move(
    id: i32,
    x: f32,
    y: f32,
) void {
    const app: *App = active_app orelse return;
    const p: [2]f32 = cssToLogical(app, x, y);
    input.pushTouchMove(&app.input_state, id, p[0], p[1]);
}
pub export fn zimr_input_push_touch_up(id: i32) void {
    if (inputState()) |s| {
        input.pushTouchUp(s, id);
    }
}

// ============================================================================
// Input query API — free functions over f.input, mirroring the GL path's
// `z.getMousePosition` / `z.isMouseButtonDown` shape so example bodies read the
// same on both backends.
// ============================================================================

/// The effective gravity the fluid feels (canvas space, m/s², unnormalised;
/// (0,9.8) when no sensor). Multiply by one gain. Tilt, shake, flat-float and
/// free-fall all emerge from this single vector. See input.getDeviceGravity.
pub fn getDeviceGravity(in: *const input.InputState) Vec2 {
    return input.getDeviceGravity(in);
}
pub fn getMouseX(in: *const input.InputState) i32 {
    return input.getMouseX(in);
}
pub fn getMouseY(in: *const input.InputState) i32 {
    return input.getMouseY(in);
}
/// Keyboard: was `key` pressed this frame (rising edge)? raylib's IsKeyPressed.
pub fn isKeyPressed(
    in: *const input.InputState,
    key: types.KeyboardKey,
) bool {
    return input.isKeyPressed(in, key);
}

/// Pop the next queued typed character (a Unicode codepoint), or null once the
/// per-frame queue is drained. raylib's `GetCharPressed`. It consumes from the
/// queue, so it takes a mutable `*InputState` (which `f.input` is).
pub fn getCharPressed(in: *input.InputState) ?u21 {
    return input.getCharPressed(in);
}

test "refAllDecls: every decl compiles (catches removed-API / non-generic breakage)" {
    // refAllDecls forces semantic analysis of each top-level decl, so a removed
    // stdlib API in a non-generic fn (e.g. the Zig 0.17 bufPrintZ/dupeZ/meta.Int
    // removals) fails here instead of silently slipping through. NOTE: it does
    // NOT analyze generic fn bodies until they're instantiated, so it's a
    // partial net -- real generic coverage comes from tests that call them.
    std.testing.refAllDecls(@This());
}
