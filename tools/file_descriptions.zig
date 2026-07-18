//! file_descriptions.zig — curated path -> description data for
//! gen_files_md.zig (the file atlas).  GENERATED from the old
//! scripts/gen_files_md.py dicts; edit descriptions here now.
//! The right long-term home for a description is the file's own //!
//! header — move entries out as files get touched.

pub const Entry = struct { path: []const u8, text: []const u8 };

pub const descriptions = [_]Entry{
    .{
        .path = "build.zig",
        .text = "The build graph: discovers shader sources, runs the SPIR-V→WGSL pipeline per " ++
            "engine/example shader, defines every wgpu example's wasm module + page " ++
            "install, the six native host demos, the host test target (with WGSL + externs " ++
            "wiring for the refAllDecls policy), lint (a hard dependency of every compile), " ++
            "smoke harnesses, docs, dist, and the standalone-HTML bakers. The single most " ++
            "load-bearing file in the repo; edit with exact-text anchors and verify with a " ++
            "full gate run.",
    },
    .{
        .path = "src/tests.zig",
        .text = "Host test aggregator and the refAllDecls policy artifact: every live source " ++
            "file is force-analyzed here so no declaration can rot unanalyzed. Also imports " ++
            "the cross-cutting test suites under src/tests/ and the spv2wgsl internals. zm " ++
            "and shader_interface are referenced as MODULES (file-importing them would " ++
            "double-own their graphs).",
    },
    .{
        .path = "src/types.zig",
        .text = "The shared vocabulary: Color, Rectangle (extern — embedded in extern ABI " ++
            "structs), Image, Texture, Mesh, Model, Material, ModelAnimation, Camera2D/3D, " ++
            "Ray/RayCollision/BoundingBox, PixelFormat, key/mouse/gesture enums. Almost " ++
            "everything imports this; it imports almost nothing.",
    },
    .{
        .path = "src/ui.zig",
        .text = "The immediate-mode UI — the Dear ImGui port, and the largest file in the tree. " ++
            "UiContext + Ui frame handles, the full widget set (windows, docking, tables, " ++
            "plots, drag-drop, text editing, multiselect, style editor), the DrawList " ++
            "replay over a generic `gl: anytype` renderer trait, layout, persistence (typed " ++
            "state storage + disk), and the raster-based screenshot/snapshot pipeline " ++
            "(renderToBytes/renderToPng/snapshotPng). The Gl selector picks WgpuGl in wasm " ++
            "builds and the inert TestGlStub (alias of shapes2d.TestGl) in host-test " ++
            "builds.",
    },
    .{
        .path = "src/runtime.zig",
        .text = "Engine runtime services, all backend-agnostic since P5: core (WindowState, " ++
            "screen/render dims, traceLog), input (keyboard/mouse/touch state machine + " ++
            "event queue), gestures, camera (updateCamera modes, camera math, screen↔world " ++
            "projection with explicit ClipPlanes), effects (clock, rng, logger with " ++
            "Prefixed/Scoped, loader), allocator helpers (freeMany etc.), and the wasm libc " ++
            "shims.",
    },
    .{
        .path = "src/wgpu.zig",
        .text = "The WebGPU handle layer: typed handles (BufferHandle, TextureHandle, " ++
            "BindGroupHandle, PipelineHandle...) over the JS bridge's integer registry, the " ++
            "extern js_* bridge declarations (comptime-gated for wasm), " ++
            "device/queue/encoder operations, buffer mapping, copyTextureToBuffer, and " ++
            "createShaderModuleWgsl. Host builds get inert fallbacks so the same code " ++
            "analyzes everywhere.",
    },
    .{
        .path = "src/wgpu_texture.zig",
        .text = "WgpuTexture: creation from Image/raw RGBA8, view + sampler management, the " ++
            "texture registry that backs WgpuGl's id-based setTexture path, and mip/format " ++
            "plumbing.",
    },
    .{
        .path = "src/wgpu_smoke_test.zig",
        .text = "Wasm-root smoke harness compiled per example by the smoke build: boots the app " ++
            "headlessly under webtests/runner.mjs (driving the dogfooded " ++
            "webtests/wgpu_smoke.zig logic), counts bridge calls per frame, and reports " ++
            "PASS lines the tier-a gate greps. Excluded from refAllDecls (wasm entry root).",
    },
    .{
        .path = "src/web.zig",
        .text = "The dom namespace: log/now_ms/canvas-size externs with host fallbacks, plus " ++
            "fetch/file-loading glue. The function-pointer sinks runtime.effects route " ++
            "through live here.",
    },
    .{
        .path = "src/utils.zig",
        .text = "Comptime feature flags (`features`), the todo() marker, allow_assert wiring " ++
            "from build_options, and small shared utilities. zimr re-exports " ++
            "features/todo as the public surface.",
    },
    .{
        .path = "src/uniform_buffer.zig",
        .text = "Typed uniform-buffer helper: extern-struct layout checking, creation, " ++
            "per-frame updates. Single-parent child of zimr (P6 merge candidate).",
    },
    .{
        .path = "src/storage_buffer.zig",
        .text = "Typed storage-buffer helper for compute + render: creation, upload, readback " ++
            "plumbing. Single-parent child of zimr (P6 merge candidate).",
    },
    .{
        .path = "src/spv2wgsl.zig",
        .text = "The pure-Zig SPIR-V→WGSL transpiler entry: parses SPIR-V binaries, " ++
            "reconstructs structured control flow via the CFG walkers in src/spv2wgsl/, " ++
            "runs the sample-uniformity pass (Chrome/Tint uniform-control-flow), and emits " ++
            "WGSL. Known item: the recursive emitFunctionBody needs a big stack on one Tint " ++
            "fixture (iterative emitter queued in P6).",
    },
    .{
        .path = "src/spv2wgsl_wasm.zig",
        .text = "Wasm entry root exposing the transpiler to the browser dev page. Excluded from " ++
            "refAllDecls (wasm root).",
    },
    .{
        .path = "src/sound.zig",
        .text = "Audio: sounds (one-shot), streams (ring-buffered PCM with FIFO recycle), and " ++
            "music, over web-audio bridge externs with host no-op fallbacks.",
    },
    .{
        .path = "src/shader_runtime_wgpu.zig",
        .text = "The typed shader runtime for the wgpu path: Resources(Schema) bind-group " ++
            "containers, typed IO structs, samplers, UBO plumbing, and the wave_fs demo IO. " ++
            "Pairs with shader_introspect's comptime schema solving.",
    },
    .{
        .path = "src/shader_introspect.zig",
        .text = "Comptime schema introspection: solveLayout (schema → ResolvedLayout of binding " ++
            "fields + groups), autoMaterial bind group layout emission, and " ++
            "assertVaryingsMatch (VS↔FS varying validation with comptime-marked " ++
            "conditions).",
    },
    .{
        .path = "src/shader_compile.zig",
        .text = "Runtime WGSL module creation + pipeline assembly helpers used by the retained " ++
            "3D path. Single-parent child of zimr (P6 merge candidate).",
    },
    .{
        .path = "src/renderer_2d.zig",
        .text = "The 2D batch renderer: shapes batch (vertex staging, per-texture bind groups " ++
            "via the registry — the turn-909 aliasing fix), orthoTopLeft (the GPU-UBO " ++
            "[16]f32 projection), per-frame UBO updates, and pipeline setup. Embeds " ++
            "default_shapes_vs/fs.wgsl.",
    },
    .{
        .path = "src/render_pass.zig",
        .text = "Render-pass state: begin/end encoding, clear values, attachment wiring over " ++
            "gpu_frame's per-frame resources.",
    },
    .{
        .path = "src/raster_pixel.zig",
        .text = "Pixel-level primitives for the software rasterizer: blending, format " ++
            "packing/unpacking, span fills.",
    },
    .{
        .path = "src/gpu.zig",
        .text = "zimr's WebGPU resource layer over raw `wgpu` (merge of pipeline_cache + " ++
            "descriptor_encoder + gpu_frame): PipelineCache/StateCombo, the descriptor " ++
            "encoders (RenderPipelineDescriptor/BindGroupEntry/...), and per-frame GpuFrame.",
    },
    .{
        .path = "src/physics.zig",
        .text = "The 3D physics engine: rigid bodies, broadphase, GJK/EPA narrow phase, " ++
            "constraint solving. Known item: an EPA degeneracy in physics_pyramid trips a " ++
            "Debug `unreachable`.",
    },
    .{
        .path = "src/gpu_iface.zig",
        .text = "WgpuBackend — the backend handle the app/frame layer threads through draw3d, " ++
            "renderer_2d and friends; device/queue access plus PassState.",
    },
    .{
        .path = "src/renderer_trait.zig",
        .text = "The renderer trait: assertIsGlContext, the comptime contract " ++
            "(begin/end/vertex2f/color4ub/setTexture/...) that WgpuGl, raster adapters and " ++
            "the test stub all satisfy, letting 2D draw code take `gl: anytype`. The GL-era " ++
            "GlAdapter died in P5.",
    },
    .{
        .path = "src/errors.zig",
        .text = "The shared error sets: LoadError, ImageGenError, GpuError and friends, plus " ++
            "error-formatting helpers.",
    },
    .{
        .path = "src/entities.zig",
        .text = "The ECS: comptime-dispatched Entities(T) pools with unified spawn, forEach, " ++
            "handles and generation checks (the pool/world_stamp/ecs consolidation).",
    },
    .{
        .path = "src/easings.zig",
        .text = "Raylib's easing functions (linear through bounce/elastic, in/out/inout) used " ++
            "by the UI animation layer and the easings examples.",
    },
    .{
        .path = "src/compute_pass.zig",
        .text = "Compute-pass encoding over the bridge: pipeline binding, dispatch, and the " ++
            "readback handshake used by double_it and the GPU compute demos.",
    },
    .{
        .path = "src/codecs.zig",
        .text = "Asset codecs: PNG encode/decode, JPEG decode, glTF/GLB parse (meshes, skins, " ++
            "animations, JOINTS/WEIGHTS → Mesh bone arrays), OBJ export support, TTF font " ++
            "parsing + atlas baking.",
    },
    .{
        .path = "src/BindGroupCache.zig",
        .text = "Cache of bind groups keyed by (layout, resources) so per-frame draws don't " ++
            "re-create identical groups across the bridge.",
    },
    .{
        .path = "tools/lint_zimr.zig",
        .text = "The AST-based style linter (a hard dep of every compile): rule 1 " ++
            "fn-args-multiline, rule 2 typed locals/globals, rule 3 branch braces, " ++
            "SCREAMING-case bans, unused-global detection, line length, plus text-based " ++
            "shader-DSL checks for _fs/_vs files. isSkipped is down to one data-file " ++
            "exception since P5.",
    },
    .{
        .path = "tools/buildaux.zig",
        .text = "Build helper subcommands invoked by build.zig: dist-copy, check-wgsl-clean " ++
            "(ERROR-marker gate on transpiled WGSL), and the standalone HTML baker " ++
            "that inlines wasm + JS into a single phone-verifiable file.",
    },
    .{
        .path = "tools/zglsl.zig",
        .text = "Zig wrapper around shader compilation used by the SPIR-V pipeline (naga/spirv " ++
            "tooling glue); the GLSL-emission half is historical since the GL retirement.",
    },
    .{
        .path = "tools/gen_files_md.zig",
        .text = "This generator (Zig port of the old gen_files_md.py): walks the tree, " ++
            "computes per-file line/fn/test counts + deps/dependents, and assembles " ++
            "src/notes/files.md from //! headers + the curated table in " ++
            "file_descriptions.zig. Run via `zig build files-md`.",
    },
    .{
        .path = "scripts/jpeg_section.zig",
        .text = "Standalone host tool for dissecting JPEG sections — codec debugging aid from " ++
            "the codecs.jpeg work.",
    },
    .{
        .path = "scripts/ui_screenshot_repro.zig",
        .text = "Standalone host repro harness that drives ui.zig's renderToPng for a specific " ++
            "layout bug outside the test suite.",
    },
    .{
        .path = "examples/quad_glb_data.zig",
        .text = "Embedded-GLB byte array (a textured quad asset) imported by gltf_textured " ++
            "as anonymous module data. Data file — the lint skip list's single exception.",
    },
    .{
        .path = "examples/shared/shaders/catalog.zig",
        .text = "The shared shader catalog examples import to reference engine + example shader " ++
            "pairs by name.",
    },
    .{
        .path = "examples/gltf_simple/cube_glb.zig",
        .text = "Embedded-GLB byte array for the simple glTF cube demo.",
    },
    .{
        .path = "examples/skinned_mesh/skinned_mesh_data.zig",
        .text = "Embedded 2KB rigged GLB (two-bone strip) the CPU-skinning demo animates.",
    },
    .{
        .path = "src/bridge.zig",
        .text = "The browser runtime for the wgpu path: WASI shim, DOM/input glue, the WebGPU " ++
            "bridge (integer-registry handle protocol, encoder ops incl. " ++
            "copyTextureToBuffer), audio, and zimrRun boot. Bundled per-example and inlined " ++
            "by the standalone baker.",
    },
    .{
        .path = "src/web/overlay_input.ts",
        .text = "DOM overlay input helpers (textarea + IME-friendly text entry) the UI text " ++
            "widgets raise; extracted from the GL runtime, now imported by src/bridge.zig.",
    },
    .{
        .path = "src/web/readme.html",
        .text = "The dark-brutalist project landing page; README.md links here. Installed into " ++
            "zig-out/web and carried by dist.",
    },
    .{
        .path = "src/web/manifest.json",
        .text = "Gallery metadata (names, descriptions, stars, filters) consumed by the wgpu " ++
            "gallery example's picker UI.",
    },
    .{
        .path = "webtests/server.ts",
        .text = "Tiny bun static server for serving zig-out/web and example pages during " ++
            "browser verification.",
    },
    .{
        .path = "webtests/wgpu_smoke.zig",
        .text = "Phase 5b dogfood: the headless smoke-test LOGIC in Zig, compiled to wasm32 and " ++
            "transpiled to JS by our own c2js, run under webtests/runner.mjs. Loads an " ++
            "example wasm, runs N frames, counts bridge calls per type, prints the PASS " ++
            "line tier-a greps. Byte-identical to the deleted .ts.",
    },
    .{
        .path = "scripts/timed-build.sh",
        .text = "Wraps a build step with wall-clock timing, exit-code capture and an append to " ++
            "build_timings.tsv — the tier-a gate entry point.",
    },
    .{
        .path = "scripts/build_cheatsheet.py",
        .text = "Generates cheatsheet.html at the repo root from CHEATSHEET.md for the " ++
            "published site.",
    },
    .{
        .path = "scripts/bootstrap-sandbox.sh",
        .text = "Sets up a fresh sandbox: PATH exports for the vendored zig + bun toolchains " ++
            "and first-build warmup.",
    },
    .{
        .path = "tools/gen_vscode.zig",
        .text = "Editor-config generator (Zig port of build_launch_json.py): reads the " ++
            "wgpu_examples array from build.zig and writes .vscode/.zed launch+task " ++
            "configs. Run via `zig build gen-vscode`.",
    },
    .{
        .path = "tools/dag_check.zig",
        .text = "Import-graph DAG gate (Zig port of the old check_dag.py): tokenizer-based " ++
            "@import scan, Tarjan SCC, no whitelist; also prints the auto-computed DAG " ++
            "layering / reading order.",
    },
    .{
        .path = "tools/import_graph.zig",
        .text = "Shared src module import-graph analysis used by dag_check, gen_files_md and " ++
            "dag_png: tokenizer @import scan, Graph build, Tarjan SCC, longest-path levels, " ++
            "and transitive reduction.",
    },
    .{
        .path = "tools/dag_png.zig",
        .text = "Renders the src dependency graph to src/notes/dag.png, drawn by zimr's own " ++
            "software rasterizer (Canvas): boxes area ~ lines-of-code, color = DAG " ++
            "level, edges = transitive reduction, laid out by level with barycenter + relaxation. " ++
            "`zig build dag-png`.",
    },
    .{
        .path = "tools/dag_font.ttf",
        .text = "RobotoMono copy embedded by dag_png.zig for on-image labels (kept beside the " ++
            "tool so @embedFile can reach it).",
    },
    .{
        .path = "scripts/refresh_upstream_index.py",
        .text = "Refreshes scripts/data/upstream_index.json — the raylib upstream example index " ++
            "used to track port coverage.",
    },
    .{
        .path = "scripts/data/upstream_index.json",
        .text = "Raylib upstream example index (name → category/status) backing the " ++
            "port-coverage tracking.",
    },
    .{
        .path = "scripts/naga-validate-corpus.sh",
        .text = "Runs naga validation over the transpiler's emitted WGSL corpus as an external " ++
            "cross-check.",
    },
    .{
        .path = "scripts/naga-validate-tint.sh",
        .text = "Runs naga validation over the Tint fixture outputs.",
    },
    .{
        .path = "scripts/timing-trend.sh",
        .text = "Plots build_timings.tsv trends — the build-cycle-time telemetry from the " ++
            "63s→5s feedback-loop work.",
    },
    .{
        .path = "tools/gen_rtt_tut.sh",
        .text = "Regenerates the RTT tutorial HTML from its sources.",
    },
    .{
        .path = "tools/gl2wgpu_ui.py",
        .text = "The port-automation script (port_ui lineage): converts GL-era UI example mains " ++
            "to the UiHost pattern — drove the bulk UI example migration.",
    },
    .{
        .path = "tools/use-prebuilt-spirv.sh",
        .text = "Switches the shader pipeline to prebuilt SPIR-V artifacts (skips the compile " ++
            "stage) for fast iteration.",
    },
    .{
        .path = "tools/build.zig.zon",
        .text = "Package manifest for the tools build (lint_zimr, buildaux, zglsl).",
    },
    .{
        .path = "webtests/smoke.ts",
        .text = "The original GL-era headless smoke shim; superseded by wgpu_smoke.zig for the " ++
            "live path.",
    },
    .{
        .path = "webtests/transpiler_corpus.zig",
        .text = "Phase 5c dogfood: the spv2wgsl corpus/fixture test LOGIC in Zig, transpiled to " ++
            "JS by our own c2js and run under runner.mjs. Walks .opt.spv inputs, transpiles " ++
            "each through the spv2wgsl wasm, MD5s the WGSL in-Zig (std.crypto), scans for " ++
            "unresolved placeholders, and checks/refreshes tests/fixtures/wgsl_corpus.json. " ++
            "Byte-identical to the deleted .ts.",
    },
    .{
        .path = "src/shaders/_deleted_glsl_placeholder.glsl",
        .text = "The GLSL gravestone: live shader entries still carry a `<name>.glsl` " ++
            "placeholder name consumer loops wire unconditionally; dies with the P6 " ++
            "wgsl-primary collapse.",
    },
    .{
        .path = "src/assets/sample.ogg",
        .text = "Small OGG used by the sound tests.",
    },
    .{
        .path = "src/assets/test_sine.wav",
        .text = "Sine-wave WAV fixture for sound tests.",
    },
    .{
        .path = "src/notes/math_audit.csv",
        .text = "The math-unification audit sheet (per-fn migration status).",
    },
    .{
        .path = "src/notes/settings.local.json",
        .text = "Local editor settings snapshot.",
    },
    .{
        .path = "src/notes/assert_demo.html",
        .text = "Standalone demo of the wasm assert/stacktrace UX.",
    },
    .{
        .path = "build.zig.zon",
        .text = "Root package manifest (no external deps by design).",
    },
    .{
        .path = ".gitignore",
        .text = "Ignore rules (caches, zig-out, prebuilt artifacts).",
    },
    .{
        .path = ".zenv.sh",
        .text = "Sourceable PATH exports for the vendored toolchains.",
    },
    .{
        .path = "LICENSE",
        .text = "Project license.",
    },
    .{
        .path = "cheatsheet.html",
        .text = "Generated API cheatsheet (from CHEATSHEET.md via scripts/build_cheatsheet.py); " ++
            "carried into dist.",
    },
    .{
        .path = "build_everything.bat",
        .text = "Windows convenience: full build battery.",
    },
    .{
        .path = "generate_vscode.bat",
        .text = "Windows convenience: regenerate launch.json.",
    },
    .{
        .path = "install-bun.sh",
        .text = "Fetches the vendored bun runtime (POSIX).",
    },
    .{
        .path = "install-bun.bat",
        .text = "Fetches the vendored bun runtime (Windows).",
    },
    .{
        .path = "serve.sh",
        .text = "Serves zig-out/web via the bun dev server (POSIX).",
    },
    .{
        .path = "serve.bat",
        .text = "Serves zig-out/web via the bun dev server (Windows).",
    },
    .{
        .path = "kill-serve.sh",
        .text = "Stops the dev server (POSIX).",
    },
    .{
        .path = "kill-serve.bat",
        .text = "Stops the dev server (Windows).",
    },
    .{
        .path = "release.sh",
        .text = "Builds + packages the dist bundle (POSIX).",
    },
    .{
        .path = "release.bat",
        .text = "Builds + packages the dist bundle (Windows).",
    },
    .{
        .path = "examples/assets/fonts/atkinson_mono_LICENSE.txt",
        .text = "License for the bundled Atkinson Hyperlegible Mono font.",
    },
    .{
        .path = "src/notes/tutorials/rtt-tutorial.html",
        .text = "Render-to-texture tutorial (generated HTML; source via tools/gen_rtt_tut.sh).",
    },
    .{
        .path = "src/notes/tutorials/wgpu-ports-tutorial.html",
        .text = "Tutorial on porting GL examples to the wgpu backend (generated HTML).",
    },
    .{
        .path = "src/notes/zmath-LICENSE.txt",
        .text = "License of the zmath library zimrmath absorbed.",
    },
    .{
        .path = "assets/sample.ogg",
        .text = "Runtime-fetched OGG sample for audio examples.",
    },
};

pub const example_notes = [_]Entry{
    .{
        .path = "damaged_helmet",
        .text = "The flagship 3D demo: Khronos DamagedHelmet GLB through the retained-mesh PBR " ++
            "path, with the CPU|GPU corner composite (raster renders the same scene into a " ++
            "corner blit).",
    },
    .{
        .path = "skinned_mesh",
        .text = "CPU-skinned animation v1: glTF skin/animation sampling, zm row-vector pose " ++
            "math (invBind·world), nlerp between keyframes, per-frame vertex deform + " ++
            "updateMeshBuffer.",
    },
    .{
        .path = "sidebyside",
        .text = "One shader, three executors: the same kernel run on CPU (raster), GPU (wgpu) and " ++
            "at comptime, blitted side by side with a pointer-follow divider.",
    },
    .{
        .path = "mandel_sidebyside",
        .text = "Mandelbrot variant of the side-by-side trio (CPU | GPU | comptime) with the " ++
            "helmet-style ensureCpuTarget mechanics.",
    },
    .{
        .path = "rt_sidebyside",
        .text = "Raytracer variant of the side-by-side trio.",
    },
    .{
        .path = "cube_sidebyside",
        .text = "Spinning-cube variant of the side-by-side trio.",
    },
    .{
        .path = "split_screen",
        .text = "Two render-textures, two cameras, zone tints — exercises App.target_size and " ++
            "per-target aspect in beginMode3D.",
    },
    .{
        .path = "first_person_camera",
        .text = "updateCamera(.first_person) over a genMeshHeightmap terrain.",
    },
    .{
        .path = "texture_readback",
        .text = "GPU→CPU readback via the copyTextureToBuffer bridge op: renders to a 256² RTT, " ++
            "copies to a mapped buffer (256-aligned rows), polls with a frame-delayed state " ++
            "machine, verifies pixels.",
    },
    .{
        .path = "ui_demo",
        .text = "The big ImGui-style demo window — the UI suite's standard phone-verification " ++
            "standalone.",
    },
    .{
        .path = "ui_kanban_board",
        .text = "Drag-and-drop kanban board exercising drag-drop + persistence.",
    },
    .{
        .path = "gallery",
        .text = "The example gallery/picker page driven by manifest.json.",
    },
    .{
        .path = "recursive_hud",
        .text = "Renders the UI into a texture and draws that texture inside the UI — RTT " ++
            "composition via app-side beginTextureMode.",
    },
};

/// Curated "what's important in this file" labels for the dependency-graph
/// boxes (tools/dag_png.zig). `|` is a line break; symbols are ordered
/// most-important-first so truncation in a small box keeps the headline ones.
pub const KeySyms = struct { name: []const u8, syms: []const u8 };
pub const key_symbols = [_]KeySyms{
    .{ .name = "zimrmath", .syms = "Vec2 Vec3 Vec4|Mat Quat|Color|sin cos atan2|lookAt perspective|slerp fft" },
    .{ .name = "types", .syms = "Color Rectangle|Image Texture|Font Model|Camera Shader|Material Mesh" },
    .{ .name = "entities", .syms = "Entity Registry|Chunk Handle|Node Ref|spawn forEach (ECS)" },
    .{ .name = "ui", .syms = "Ui Window|DrawList|Table TabBar|Dock Tween|widgets (ImGui)" },
    .{ .name = "zimrphysics", .syms = "World Body|Shape Constraint|Vehicle Character|Ragdoll SoftBody|collide step" },
    .{ .name = "raster", .syms = "Context|Framebuffer|Texture|DrawMode|BlendFactor (SW GL)" },
    .{ .name = "draw3d", .syms = "Mesh Model|genMeshCube|genMeshSphere|drawModel|ray collision|pbr3d" },
    .{ .name = "gpu", .syms = "PipelineCache|GpuFrame|StateCombo|descriptors" },
    .{ .name = "codecs", .syms = "png jpeg|truetype|gltf|audio|rectpack" },
    .{ .name = "image", .syms = "genImage*|drawTexture|imageDraw*|color ops" },
    .{ .name = "text2d", .syms = "Font|loadFont|drawText|measure|truetype" },
    .{ .name = "shapes2d", .syms = "drawCircle|drawRectangle|drawLine|drawTriangle|splines" },
    .{ .name = "renderer_2d", .syms = "Renderer2D|ShapesBatch|MatrixStack" },
    .{ .name = "WgpuGl", .syms = "vertex2f|matrixMode|setBlendMode|GL-style" },
    .{ .name = "SwAdapter", .syms = "SwGl|vertex2f|matrixMode|BlendMode" },
    .{ .name = "plot", .syms = "Plot Axis|Marker|Colormap|Legend (ImPlot)" },
    .{ .name = "plot3d", .syms = "Plot3D|plotScatter|plotSurface|plotMesh (ImPlot3D)" },
    .{ .name = "plot_ui", .syms = "Subplots|Series|Overlay|DragHandle" },
    .{ .name = "plot_core", .syms = "Colormap|sampleColormap" },
    .{ .name = "spv2wgsl", .syms = "convertSpirvToWgsl|ir sccp|wgsl_check" },
    .{ .name = "shader_runtime_wgpu", .syms = "RenderPipeline|loadShader|ShaderDesc" },
    .{ .name = "shader_introspect", .syms = "solveLayout|BindGroupLayout|validate" },
    .{ .name = "shader_interface", .syms = "Sampler2D|Attr|binding|shared" },
    .{ .name = "shader_codegen", .syms = "ShaderPipeline (build-time)" },
    .{ .name = "shader_connect", .syms = "autoConnect" },
    .{ .name = "wgpu", .syms = "Device Queue|Texture handles|createBuffer|createPipeline" },
    .{ .name = "wgpu_app", .syms = "App AppSpec|beginDrawing|drawCube|Launcher (facade)" },
    .{ .name = "wgpu_texture", .syms = "WgpuTexture|WgpuRenderTexture" },
    .{ .name = "gpu_iface", .syms = "ShapesBatch|WgpuBackend|SwBackend|FrameContext" },
    .{ .name = "renderer_trait", .syms = "BlendMode|assertIsGlContext" },
    .{ .name = "BindGroupCache", .syms = "getOrBuild|invalidate|Key" },
    .{ .name = "compute_host", .syms = "Compute|Backend" },
    .{ .name = "kompute", .syms = "Config Ctx|installKernel" },
    .{ .name = "sound", .syms = "audio_device|music sounds|waves" },
    .{ .name = "runtime", .syms = "core input|gestures|camera|effects" },
    .{ .name = "easings", .syms = "linear|sineInOut|cubicInOut|elastic bounce" },
    .{ .name = "raster_pixel", .syms = "PixelFormat|readColor|writeColor" },
    .{ .name = "raster_shader", .syms = "rasterizeTriangles|frag/vert dispatch" },
    .{ .name = "bridge", .syms = "JS bridge|Document Element|fetch Promise|Wasm" },
    .{ .name = "web", .syms = "dom|audio|fetch" },
    .{ .name = "utils", .syms = "features|BoundedArray" },
    .{ .name = "errors", .syms = "LoadError|PngError|FetchError" },
    .{ .name = "Canvas", .syms = "fillRect line|text|circleFilled|savePng" },
    .{ .name = "zimr", .syms = "public API facade|re-exports all" },
    .{ .name = "profiler", .syms = "zone @src()|frameMark|freeze|worstFrame|2s ring (Tracy-style)" },
    .{ .name = "profiler_ui", .syms = "flamegraph|panel|app-callable views" },
};
