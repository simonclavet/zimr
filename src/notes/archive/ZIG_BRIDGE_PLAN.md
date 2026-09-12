# ZIG_BRIDGE_PLAN — removing TypeScript/JavaScript from zimr (t1178+)

GOAL: no hand-written TypeScript, JavaScript, or HTML anywhere in zimr. The
browser bridge is written in Zig and transpiled to JS by the webzig toolchain
(Zig → C backend → c2js). Pages are generated. Bun remains ONLY for the
headless webtests. webzig is INTEGRATED — its files become first-class zimr
source modules we own, extend, and lint — not a vendored dependency directory.

---

## 1. What webzig is (study digest, from webzig-everything)

Two-artifact model. An app is (a) a normal wasm32 module and (b) a "bridge"
Zig file that is compiled with `zig build-obj -ofmt=c -target
wasm32-freestanding` and then translated C→JS by `wz_c2js.zig` (8.5k lines).
The bridge JS is inlined into a generated HTML page by the transpiler's
`--html` mode (`--wasm-url` for a sibling .wasm, `--wasm-embed` for a
single-file standalone with base64 inlining). No hand-written JS or HTML
exists anywhere in the pipeline.

The pieces and what they do:

- `wz.zig` (2.2k) — the interop library the bridge imports. JS objects are
  integer `Handle`s into a JS-side table (`__H`) with `js_mark`/`js_reset`
  scopes (per-frame reclamation). `Value` wraps a handle:
  `.call/.callVoid/.get/.getNum/.set/.at/.new`; `Element` adds DOM sugar.
  `wz.obj(.{...})` builds a JS object from an anonymous struct (snake_case →
  camelCase, nested structs/tuples). `wz.str/fmt/log/warn`, typed CSS rules,
  `setInterval`, `fetchJson(...).then(&cb).catch_(&cb)` (callback model — the
  transpiler has NO closures and NO indirect calls; callbacks are `&namedFn`
  via `func()`). Promises: `js_promise_register/status/take` — a generic
  poll-based promise kernel. `wz.input` — DOM listeners host-side, polled by
  the module via `__wz_*` imports. `wz.assets` — `@embedFile` → register →
  module reads synchronously.
- `Site(onReady, onFrame, Imports)` — boot/instantiate/frame-loop runtime.
  THE CRUX FOR ZIMR: it builds the wasm import object from `Imports`, a type
  whose every `pub fn` becomes `env.<name>` — i.e. rich import objects are a
  first-class, already-shipped mechanism. Instantiation is promise-polled;
  `onFrame` runs inside a `js_mark`/`js_reset` bracket, so import callbacks
  invoked by wasm mid-frame are leak-free by construction.
- `wz_mod.zig` — module-side runtime: `wasm_allocator`, panic/std.log →
  console (`__wz_log`), polled input, asset load.
- `contract.zig` + per-app `interface.zig` — one file imported by BOTH sides
  declaring shared `extern struct`s and the export/import function contract.
  `assertProvides/assertSubset/assertImports`, name-checked `callExport`,
  type-directed `writeStruct/readStruct`, and a comptime `CONTRACT_HASH`
  exported by the module and checked at instantiation (stale-wasm refusal).
- `wz_c2js.zig` — consumes EXACTLY the Zig C backend's dialect (not general
  C). Output JS: state-machine control flow, typed-array memory, SAFE_HEAP
  bounds/align/null checks compiled in for Debug/ReleaseSafe. Differential
  test suite vs a native oracle + fuzzer (`tests/all.sh`).
- `wz_build_helper.zig` — `addWasmSite/addJsSite/buildTranspiler/
  addDevServer`. `wz_serve.zig` — pure-Zig static dev server (std.http).

### The zimr-specific tutorial (zimr-bridge-port-to-zig.html)

The bundle includes a MEASURED port study of zimr's bridge specifically.
Five wz.zig additions were landed for it: `wz.obj`, `readSlice(T, ptr, len)`
(bulk-copy []T out of module memory — replaces the hand-written byte-cursor
decoders), `wz.Wire(T)` (comptime fixed-layout/no-host-pointer guard),
`callVoid` (no result-handle minting on the render hot path), and a
method-name memo in the interop kernel (names are comptime literals at fixed
addresses → memoized; this fixed a real 40× dispatch regression).
V8 microbenchmarks: descriptor read 77ns (Zig) vs 90ns (TS cursor) — FASTER;
void method dispatch +10ns/call (~0.1ms at 10k calls/frame — invisible);
object build slower but ~once/frame. Verdict in the doc: "Port it." Known
gap: context-carrying `.then` (typed state through async callbacks) is
designed but not landed — module-level keyed tables are the interim.

### Versions

webzig: Zig 0.17.0-dev.813. zimr pins 0.17.0-dev.704. c2js consumes the C
backend's output, which can shift between dev builds → toolchain alignment
is SPIKE 0, not an afterthought. Options: (a) bump zimr to .813+ (preferred;
zimr tracks dev anyway), (b) verify c2js on .704 output via the differential
suite, (c) pin both to one newer dev build.

---

## 2. What zimr's hand-written web layer does today (the deletion list)

- `src/web/zimr_wgpu.ts` — 1,284 lines. (1) Boot: getContext("webgpu"),
  requestAdapter/requestDevice with raised binding limits, surface
  configure/resize/DPR. (2) The import object: ~60 `extern "wgpu" fn js_*`
  implementations — handle tables per GPU type, descriptor BLOB DECODERS
  (the byte-cursor section: ~235 lines the tutorial deletes), encoder/pass
  recording, queue ops, poll-based buffer readback (mapAsync → snapshot),
  `js_adapter_info`. (3) DOM glue: title, clipboard, fullscreen,
  localStorage persistence, logging.
- `src/web/overlay_input.ts` — 393 lines: keyboard/mouse/wheel/multitouch/
  gesture capture into a polled state + the on-screen touch controls.
- `examples/*/index.html` — 143 hand-written page templates.
- build.zig: per-example `bun build zimr_wgpu.ts` bundle steps + bespoke
  standalone-HTML assembly blocks (one per *-standalone step).
- Out of scope / already-Zig: `src/web.zig`'s `extern "webgl"/"dom"/"audio"`
  legacy GL backend (untouched by this arc unless its examples migrate);
  `webtests/*.ts` (STAYS — Bun is for tests).
- `extern "audio"` (sound.zig) — WebAudio playback/streaming used by the
  audio examples: in scope, ported as its own import namespace late in the
  sequence.

zimr's wasm-side API (`src/wgpu.zig` externs, descriptor_encoder, the
handle-enum types) DOES NOT CHANGE in shape — the module half of the
boundary is already Zig and already ours. What changes is who implements
the other side.

---

## 3. Integration architecture (integrated, not vendored)

webzig's infra files move INTO zimr's tree, renamed into our namespace,
linted by zimrlint, covered by `zig build test`, and evolved as zimr code:

```
webzig/wz.zig              → ABSORBED into src/bridge.zig (one-file rule)
webzig/wz_mod.zig          → absorbed: zimr already has module-side runtime;
                              take the panic/log console sink + allocator notes
webzig/wz_c2js.zig         → tools/c2js.zig          (built like zimrlint)
webzig/wz_build_helper.zig → absorbed into build.zig (the C→JS→HTML chain
                              as a generic registration; one chain, all examples)
webzig/wz_serve.zig        → tools/serve.zig         (replaces bun dev server)
webzig/contract.zig        → ABSORBED: comptime checks inside the two monoliths
webzig/tests/              → tests absorbed under zig build test (differential
                              c2js suite + SAFE_HEAP checks become zimr gates)
```

TWO MONOLITHS (the fat-and-flat refinement). There is exactly one bridge
serving every example (as one zimr_wgpu.ts does today), so the host side is
ONE file, and the wasm-side boundary is ONE file:

```
src/bridge.zig     THE host monolith, transpiled to JS. One file containing:
                   the absorbed wz.zig interop kernel API (Value/Element/
                   handles/promises/func/obj/readSlice/Wire/css/fetch), the
                   Site runtime with zimr's multi-namespace import wiring and
                   the WebGPU async boot preamble, all ~60 wgpu import
                   implementations, the dom glue, the overlay-input port, and
                   (Phase 6) the WebAudio section. Section-banner organized,
                   like draw3d.zig. Its `export fn start()` IS the page.
src/wgpu.zig       THE app-side boundary monolith (already exists; grows):
                   externs, handle enums, wrappers, and — absorbed from
                   descriptor_encoder.zig — the shared extern descriptor
                   structs. bridge.zig imports it FOR TYPES ONLY (Zig's lazy
                   analysis keeps wasm-only decls out of the C-target build);
                   one source of truth, two compile targets, no third
                   interface file.
```

contract checks (assertImports/CONTRACT_HASH) live as comptime blocks inside
those two files — no separate contract module survives integration.

D9. THIN BRIDGE / FAT APP (doctrine, t1178). As much as possible lives in
    the wasm app; bridge.zig contains MECHANISM ONLY — the interop kernel,
    boot, generic DOM verbs, the WebGPU verb surface, the event queue. No
    page content, no layout, no app decisions. The page around (and
    including) the canvas is DEFINED BY THE APP: the wasm module's exported
    `zimr_page_main()` builds the document — headings, links, css, iframes
    (e.g. an embedded YouTube player), and the canvases themselves — through
    the dom verbs. The bridge's `start()` is only: feature-check → adapter →
    device → instantiate → call the app.

D10. THE DOM VERB NAMESPACE. A small generic import set (`extern "dom"`):
    create/append/attach/set_text/set_attr/set_style/css/remove,
    listen(elem, event, code) + poll_event (a ring of {code,a,b} records the
    app drains each frame), canvas_configure (getContext("webgpu") +
    configure on the SHARED device, context stored host-side keyed by the
    element handle) and canvas_size (CSS×DPR → backing store → reported).
    ~14 verbs give the app arbitrary page authorship; anything fancier is
    app-side Zig, per D9.

D11. SURFACES — MULTI-CANVAS IS FIRST-CLASS. One GPUDevice, N canvas
    contexts (explicitly supported by WebGPU). The app creates canvases
    dynamically, configures each, and per frame asks for each canvas's
    current texture view to render into. Engine side this becomes a
    `Surface` concept (per-surface size + current view + pass), a bounded
    generalization the RTT path already proves. Input listeners attach
    per element, so each canvas can have its own pointer stream.
    FEASIBILITY: verified by design against the spec and by the Phase-2
    slice below; the risky detail (getCurrentTexture validity is
    per-frame) matches existing single-canvas handling, just ×N.

### Design decisions

D1. IMPORT NAMESPACES. Site wires `env` only. zimr uses `extern "wgpu"` (and
    "audio"). Decision: extend our Site to take `.{ .wgpu = WgpuImports,
    .audio = AudioImports, .env = CoreImports }` (a comptime struct of
    namespaces) rather than renaming 60 externs — the wasm side stays
    byte-identical, old and new bridges stay swappable during migration.

D2. THE DESCRIPTOR BLOBS BECOME SHARED STRUCTS. Today descriptor_encoder
    serializes to bytes and TS hand-decodes. With one language on both
    sides, the bridge does `readSlice(BglEntry, ptr, len)` over the SAME
    extern structs, guarded by `Wire(T)`. descriptor_encoder's encode side
    simplifies to writing the structs verbatim (or is bypassed: pass
    ptr+len of a `[]const BglEntry` directly). The ~235-line decoder class
    is deleted; layout drift becomes a compile error; CONTRACT_HASH catches
    stale wasm. The existing encoder TESTS convert into round-trip tests of
    the shared structs.

D3. ASYNC BOOT ORDER. zimr needs adapter→device→configure BEFORE the module
    runs its first frame (limits raised from adapter.limits). Our boot.zig
    chains these with the promise kernel: requestAdapter → poll →
    requestDevice → poll → configure context → instantiate wasm (imports
    close over the now-live device state via module-level vars in the
    bridge — webzig's sanctioned pattern) → onReady → frame loop. Buffer
    readback keeps zimr's poll model unchanged (mapAsync registered, status
    polled — identical semantics to today's TS, now via the promise kernel
    or `.then(&cb)`; adopt context-.then when we land it ourselves, since
    we own the code now).

D4. HOT PATHS. Per-frame call counts in zimr (draw-heavy UI scenes,
    compute submits) are exactly the tutorial's measured case: use
    `callVoid` for all void GPU calls; method-name memo is already in the
    kernel; numeric args pass straight through. Acceptance gate: a frame-
    time A/B on wgpu-ui-full-showcase and wgpu-fluid-gpu, old vs new
    bridge, must be within noise. The transpiler peephole (monomorphic
    emission for literal method names) is a follow-up we can do — we own
    c2js.

D5. NO INDIRECT CALLS / NO CLOSURES in bridge code. Style rule for
    src/bridge/*: callbacks are named module-level fns passed by address;
    comptime parameters keep Zig→Zig calls direct. Add a lint note.

D6. HTML GENERATION. c2js `--html` replaces all 143 index.html templates
    AND the bespoke standalone blocks: every example gets `<name>` (page +
    .wasm) and `<name>-standalone` (single file, `--wasm-embed`) from ONE
    generic registration path in build.zig. Canvas/viewport/title come from
    flags; anything page-specific (the fluid's meta tags, manifest) becomes
    bridge-Zig DOM/CSS code at `start()`, not HTML.

D7. DEV SERVER. tools/serve.zig (from wz_serve) replaces the bun dev
    server. `zig build run-<example>`; correct application/wasm MIME.

D8. INPUT. overlay_input.ts port: pointer/touch/gesture listeners in
    input_bridge.zig writing the SAME polled state layout zimr's wasm
    already reads (the existing input externs keep their signatures).
    wz.input is the skeleton; zimr's richer model (multitouch slots,
    gestures, wheel, key queue) is ported feature-for-feature with the
    gestures-testbed example as the acceptance harness.

---

## 4. Phases

PHASE 0 — toolchain + transpiler spike (gate for everything).
  RESULT (run t1178, same session as this plan): the COMPLETE webzig suite
  — transpiler battery + differential/fuzz, contract drift checks,
  SAFE_HEAP, module runtime, the three end-to-end examples through DOM
  mocks, async fetch, and the real-wasm oracle — is ALL GREEN under
  zimr's exact pinned Zig (0.17.0-dev.704+b8cb78023), no changes needed.
  R1 is retired; no pin bump required to start. Note: the webzig test
  harnesses run their JS under node (v22 here); when integrating them
  into zig build test, route them through Bun to keep the "Bun only for
  tests" rule single-runtime. The pristine webzig source is staged at
  `intake/webzig-all/` in-repo (outside lint scope) as the integration
  source of truth; files are MOVED out of intake into src/ and tools/ as
  each phase lands, and intake/ is deleted when Phase 6 completes.

PHASE 1 — DONE (t1178, same session). src/bridge.zig seeded (wz.zig
  absorbed under a zimr charter header + a temporary smoke start(); two
  upstream fixes folded in: an arc()-parameter shadow of the start export,
  and the css background field name). tools/c2js.zig built in-tree
  (registered in tools/build.zig). The chain runs as `zig build
  bridge-hello`: 85KB monolith Zig → 73.9KB C → 46.3KB self-contained
  HTML, zero errors. The transpiled JS was EXECUTED under the webzig DOM
  mock in node: DOM built, 1 CSS rule inserted, the click handler mutated
  Zig state across two synthetic clicks — smoke green. src/bridge.zig is
  in the lint skip ledger; tests.zig inclusion deferred to the cleanup
  pass (the monolith's native-target analysis is not yet a goal).
  ORIGINAL SCOPE — the monolith seed + hello parity. tools/c2js.zig built like
  zimrlint; src/bridge.zig created by absorbing wz.zig (zimr header,
  section banners, temporary `start()` smoke); a `bridge-hello` build step
  runs the full chain (build-obj -ofmt=c → c2js --html → page +
  standalone); the generated JS is smoke-run under the webzig DOM-mock
  harness. lint: bridge.zig + tools/c2js.zig enter the lint skip ledger
  during intake, with a cleanup pass scheduled before Phase 3 exits.

PHASE 2 — boot + dom verbs + the APP-OWNS-THE-PAGE slice (reshaped per
  D9–D11). bridge.zig gains: the WebGPU async preamble (gpu feature check →
  requestAdapter → requestDevice → instantiate WASM_BYTES → call the app),
  the dom verb namespace, the event ring, and a minimal wgpu verb pair
  (current_view + clear) for the slice. The slice app (wasm) builds the
  ENTIRE page from Zig: heading, prose, a link, an embedded YouTube iframe,
  and TWO dynamically created canvases on the shared device, each cleared
  with its own animated color, one responding to clicks — proving D9, D10,
  and D11 in a single phone screenshot. Both bridges coexist; examples opt
  in per-step.

PHASE 3 — the real wgpu verb surface (IN PROGRESS, t1178+).
  CONTRACT (from src/wgpu.zig + src/web/zimr_wgpu.ts, the authoritative
  pair): ~45 unique `extern "wgpu"` verbs; u32 handles into per-type
  host tables; complex descriptors cross as BINARY BLOBS (ptr+len into
  module memory) decoded host-side; labels/entry points as (ptr,len)
  strings. Boot contract for zimr apps (wasm32-wasi REACTOR): provide
  `wasi_snapshot_preview1` (stubs + real random_get via crypto over a
  fresh module-memory view), call `_initialize()` once, then drive
  `update(dt_SECONDS)` from rAF. The new bridge supports BOTH app
  contracts by export detection: `zimr_page_main`/`zimr_frame(ms)`
  (bridge-native, D9 app-owns-page) and `_initialize`/`update(dt)`
  (zimr classic; the bridge lazily creates a primary fullscreen canvas
  for the legacy surface verbs — documented transitional until zimr's
  app side creates its canvas through the dom verbs).
  SUB-PHASES:
    3a framework: DONE (t1178+). wasi namespace (stubs + real random_get
       + proc_exit -> overlay), dual-contract boot by export detection,
       g.wgpu ONE cross-type handle table (single counter — ids unique
       across types, type confusion can't alias), transitional primary
       canvas + surface group (packed sizes, format indexOf list),
       buffers (create/destroy/write), WGSL shader modules, samplers,
       encoder/finish/submit, now_ms. Verbs use the raw numeric ABI via
       the new kernel wrapper js_fn_num (BigInt i64 -> Number, no per-arg
       handle churn). PROVEN by examples/bridge_classic_probe (wasm32-wasi
       reactor, `zig build bridge-classic-probe`; NOTE: reactor exports
       beyond _initialize need explicit --export=...) under the counting
       jsdom gate (classic_gate.mjs): configure/writeBuffer/shader/
       sampler/buffer == 1 each, 3 frame submits, zero page errors.
       LESSON re-learned: regenerate pages only AFTER rebuilding c2js —
       the kernel and the binary must move together (the gate caught a
       stale-binary js_fn_num miss in one run).
    3b resources: buffers (create/destroy/write/read 4-step), textures
       (create/view/destroy/write), samplers, shader modules (WGSL).
    3c binary descriptor decoders: DONE (t1178+). A Cursor (DataView
       over module memory, LE) decodes byte-for-byte the TS formats:
       bind-group-layout entries (6 type tags), bind-group entries
       (buffer/sampler/view resources, u64 offset+size), pipeline
       layout (u32 handle array), the full render-pipeline blob (vertex
       buffer layouts + attrs, len-prefixed vs/fs entries — same-module
       both-entries shape exercised — topology/cull/blend table/depth
       modes incl. 7 = test-no-write, color+depth formats, msaa count),
       compute pipeline. The probe encodes the blob Zig-side
       (BlobWriter) and DRAWS A TRIANGLE; the gate asserts the decoded
       descriptor field-by-field. 3d also complete: copies, the async
       readback rebuilt closure-free on the promise kernel (record
       object in the handle table, poll drives mapAsync ->
       snapshot-before-unmap), adapter_info via encodeInto over module
       memory (legal: wasm buffers are non-resizable). REMAINING gaps
       vs the TS bridge: none in the verb surface — 3e is next.
    3d passes: MOSTLY DONE (t1178+) — the entire flat-param surface
       shipped early since render passes carry NO descriptor blob:
       begin_render_pass (clear colors, load/store ops, optional depth
       attachment), set_pipeline/bind_group/vertex_buffer/index_buffer,
       draw, draw_indexed, scissor, end; the full compute-pass group;
       textures (create/view/destroy/write_texture). The probe now
       renders a breathing animated clear + paints a success banner via
       dom verbs from the SAME module (namespace coexistence proven) —
       probes must self-report success visually, a black page that
       merely isn't erroring reads as dead. REMAINING in 3d: buffer
       readback 4-step, copy_buffer_to_buffer / copy_texture_to_buffer,
       adapter_info.
    3e DEVICE-PROVEN (t1178+): wgpu_basic (tinted-checker triangle,
       caption text — the font atlas lives) AND wgpu_input_mouse (ball
       tracks the finger, instruction text, cursor status) both render
       and take touch input on the Pixel through the all-Zig bridge.
       wgpu_basic (the full 2.25MB engine: Renderer2D, font atlas) built
       via `zig build wgpu-smoke-install -Dfocus=wgpu_basic`, embedded
       with `c2js --html --wasm-embed`. Its import manifest: 27 wasi
       (all covered), 31 wgpu (all covered), dom just js_log (added).
       Input is PUSH-BASED — the host calls exported pushers — so the
       bridge gained ZimrInput: pointer (down pushes move-then-button,
       window move/up gated by a dragging flag, pointer capture style),
       wheel (dx, -dy), keys (keyCode + repeat), char, touch by
       identifier over changedTouches, contextmenu suppressed; coords
       CSS px via getBoundingClientRect; installed after _initialize
       once the engine has created the primary canvas. NOTE: reactor
       exports beyond _initialize need --export= per name; the smoke
       install step already does this. engine_gate.mjs (generous mock
       device incl. limits/getBindGroupLayout/compilation info): 1
       configure, 1 pipeline, 2 BGLs, 4 BGs, 3 textures, 582 buffer
       writes, 83 frame submits, zero errors. SECOND example
       wgpu_input_mouse also GREEN incl. synthesized pointer/wheel
       events through ZimrInput (37 post-input frames, no errors); it
       surfaced the wgpu-path dom remainder, now provided:
       js_set_cursor_style (0 default / 1 none, on the primary canvas),
       js_request/exit_pointer_lock, js_pointer_lock_active. Promotion
       is ONE COMMAND now — addWgpuSmoke also emits
       zig-out/bridge-pages/<name>.html (bridge.c Run is byte-identical
       across examples, so the cache collapses it). Once device-proven, the
       TS deletion list: src/web/zimr_wgpu.ts (1284 ln),
       src/web/overlay_input.ts (393 ln), per-example index.html boot
       scripts.

PHASE 4 — TS retirement (IN PROGRESS, t1178+).
  Sequencing: migrate consumers first, delete second. Consumers of
  zimr_wgpu.ts / overlay_input.ts (overlay imported BY zimr_wgpu, they
  die together): the per-example bun bundle Runs (19 refs in build.zig),
  buildaux's wgpu-standalone HTML assembly, 143 example index.html boot
  scripts, webtests/wgpu_smoke.ts, serve.
  4a DONE: addWgpuStandalone swapped — every `<name>-standalone` step
     (all 8 call sites incl. the generic loop) now emits the BRIDGE page.
     BEHAVIOR CHANGE: output moved from source-tree prebuilt/standalone/
     (buildaux wrote out-of-tree) to install-tree zig-out/standalone/.
     The bundle Runs are orphaned (registered, never executed) until the
     sweep. Gate sweep on release standalones: input/engine/classic/
     slice all GREEN. MODE RULE ENFORCED: standalones for the phone are
     built -Dmode=release (ReleaseSmall + zimr asserts); the engine wasm
     drops 2.25MB(debug) -> 584KB, pages 3.5MB -> 1.29MB.
  4b DONE: the SERVED page is the bridge page too. finishWgpuApp now
     installs <dash>/index.html = the bridge page (new bridgePage()
     helper shared with addWgpuStandalone), dropping BOTH the per-
     example bun bundle of zimr_wgpu.ts AND the examples/<name>/
     index.html copy. `zig build serve` / serve-only / the HMR client
     keep working unchanged: server.ts appends its reload <script>
     after c2js's output (c2js emits a spec-legal HTML5 doc using
     optional-tag shorthand — <!doctype>+charset+viewport+title, no
     explicit body; the append runs fine). smoke-test is ORTHOGONAL —
     it loads wasm under Bun with stub imports, no page involved —
     and still PASSES (wgpu_basic: init 34 calls, healthy verb order).
     The per-example .wasm still installs alongside index.html (the
     addInstallArtifact stays) — only the TS/page plumbing changed.
     addWgpuStandalone slimmed to 6 params (the 3 TS-era args gone);
     all 8 call sites updated. ALSO converted the 7 BESPOKE 3D blocks
     (wgpu_demo, cube, lambert, pbr, gltf-textured, gltf-simple,
     damaged_helmet — the ones that own their GPU frame, each had its
     own manual bun-bundle + index install): every one now installs the
     bridge page as index.html via bridgePage(); their bundle Runs and
     step deps removed. RESULT: ZERO active references to zimr_wgpu.ts /
     overlay_input.ts anywhere in build.zig (only comments remain). The
     3D cube boots GREEN through the bridge (depth pipeline, 86 frames);
     pbr helmet page is 6.1MB (embedded glTF + textures), cube 864KB.
  4c DONE (t1178+) — THE SWEEP. Deleted: src/web/zimr_wgpu.ts (1284
     ln), src/web/overlay_input.ts (393 ln), all 143
     examples/*/index.html (22,594 ln), and buildaux's wgpu-standalone
     subcommand (~525 ln incl. the HTML template + htmlEscapeAlloc;
     buildaux 644 -> 119 ln). The zimr WebGPU runtime now has ZERO
     hand-written JavaScript or TypeScript — every page is bridge.zig
     -> C -> c2js. Proven by a COLD build (cache wiped) of
     wgpu_basic + wgpu_ui_color_picker with all deletions in place:
     clean, lint 0/265. While sweeping, the bridge gained the verbs
     the broader suite needs that the smoke trio didn't exercise:
     persistence (js_persistence_save/size/read/remove — localStorage,
     "zimr_"-prefixed keys, contract status codes, UTF-8 byte sizing
     via TextEncoder). The UI color picker (imports persistence) boots
     GREEN. Full post-deletion verification: engine/input/classic/
     slice gates GREEN + wgpu_smoke PASSED (2 wasms incl. color
     picker, init 30 calls). NOTE the overlay-input externs in
     src/web.zig (js_show_overlay_input et al.) tree-shake out when
     unused, so no current example needs them; if a future UI example
     does, port overlay_input.ts's textarea logic into ZimrInput then.
  INPUT FOLLOWUP (t1178+, device-reported, TWO wrong guesses then fixed):
  Symptom: touch worked in top-level Chrome, NOT in the Claude in-app
  viewer; sharpened on retest to "FIRST finger does nothing, SECOND
  finger moves the ball" in input_mouse.
  Wrong guess 1: passive listeners letting an iframe steal the gesture
  (added {passive:false} — necessary but not the cause).
  Wrong guess 2: setPointerCapture (wasn't even in the code).
  ACTUAL CAUSE: ZimrInput bound BOTH the Pointer Events model (pointer*)
  AND the legacy Touch model (touch*) on the canvas. A single finger
  fires both. Worse, pushTouches called preventDefault() on touchstart,
  which SUPPRESSES the compatibility pointer events for the PRIMARY
  finger — so the mouse channel (input_push_mouse_move, which
  input_mouse's getMousePosition reads) never fired for finger 1, while
  a second finger slipped through. Double-binding two input models for
  the same physical pointers is the antipattern.
  FIX: Pointer Events ONLY. ZimrInput now binds pointerdown/move/up/
  cancel + wheel on the CANVAS with {passive:false}; every pointer
  drives the touch ring (id = pointerId), and the PRIMARY pointer
  (isPrimary) ALSO drives the mouse channel. setPointerCapture(pointerId)
  on down keeps a straying drag attached so canvas-level listeners
  suffice (no window listeners — those were the iframe-fragile part).
  Deleted: the four touch* listeners, pushTouches, onTouch*, and
  ZimrInput's local eqlStr (now unused). jsdom input gate green
  (synth pointer drag, 37 post-input frames); DEVICE retest pending.
  LESSON: never bind Pointer + Touch models together; pointer events
  already unify mouse/touch/pen. And test the in-app viewer, not just
  Chrome — its iframe context exposed what top-level Chrome masked.
  ROUND 2 (device): after the pointer-only switch, press worked but
  DRAG didn't move the disk. Cause: the setPointerCapture(pointerId) I
  added (to justify canvas-only listeners) breaks pointermove delivery
  for TOUCH pointers inside the viewer's iframe. FIX: drop capture
  entirely; move/up/cancel go back on WINDOW (down + wheel stay on
  canvas) — assert_demo.html's original proven shape. The fullscreen
  canvas means an off-canvas stray is moot. jsdom green (36 frames via
  window drag); device retest pending. META-LESSON: setPointerCapture
  is NOT free in embedded/iframe touch contexts — prefer window-level
  move/up, which is what the pre-bridge pages always used.
  ROUND 3 (THE ACTUAL FIX — studied the proven TS standalones in
  prebuilt/, which survived deletion with the old working JS baked in):
  symptom "drag works ~2mm then dies" = the browser claiming the gesture
  at its pan-slop threshold. The OLD TS page's canvas CSS had
  `touch-action: none` (+ user-select:none); the c2js bridge page set
  cssText WITHOUT it, so the browser default reclaimed the gesture.
  jsGetSurface now sets the full proven CSS incl. touch-action:none.
  SECOND divergence found reading the TS: it pushed input_push_mouse_move
  on EVERY pointermove/down — NO isPrimary gate (I'd added one; the
  viewer may report isPrimary falsey for touch, silently dropping the
  drag). Removed it. Both fixes baked (touch-action:none verified in the
  bridge C). LESSON: the pre-bridge standalones in prebuilt/ are the
  canonical reference for browser-glue behavior — consult them.

  ============================================================
  BUN REMOVAL (t1178+, answering "can we drop bun entirely?")
  ============================================================
  Audit found 5 bun touch-points, two categories:
    TESTS (wgpu_smoke.ts, transpiler_corpus.ts): need a JS runtime ONLY
      for WebAssembly.instantiate + a host-import shim; all else is
      node:fs/crypto/path. NO pure-Zig path exists without embedding a
      wasm interpreter (wasmtime/wasmer are Rust; std has no wasm VM;
      `zig run` can't instantiate arbitrary wasm with custom host
      imports) — disproportionate to build one for tests. SIMPLEST
      ubiquitous runner that runs wasm with JS host fns = NODE. Node 22
      strips TS types inline (--experimental-strip-types) and runs both
      harnesses UNMODIFIED. DONE: build.zig routes all test steps through
      `js_test_runner = {"node","--experimental-strip-types"}` (one
      const, 4 call sites). `zig build wgpu-smoke` + `wgpu-corpus` pass
      via Node. Bun is NO LONGER a test dependency.
    DEV SERVER (server.ts via serve / serve-only): the last 2 bun refs.
      Needs http + static files + an HMR websocket. Pure-Zig replacement
      already scoped: tools/serve.zig (std.http) per D7 / wz_serve. NOT
      yet done — the one remaining bun usage, isolated to local dev.
  So: tests are Bun-free today (Node); FULL bun removal = land
  tools/serve.zig. No pure-Zig wasm runner is realistic short of writing
  an interpreter, so Node is the right "simplest available" choice for
  the wasm-execution tests.

  ============================================================
  PHASE 5 — DOGFOOD: zero hand-written JS/TS, even in tests
  ============================================================
  PRINCIPLE: if c2js is good enough to be the ENTIRE runtime, it is good
  enough to write the tests in. Every line of hand-written .ts/.js in the
  repo becomes Zig compiled to wasm -> C -> JS via our own pipeline. The
  only JS that may remain is mechanically EMITTED by c2js (never hand-
  authored) plus an irreducible host-boundary stub that does nothing but
  WebAssembly.instantiate + fs read (a JS engine can't be removed without
  writing a wasm interpreter; that stub is the minimum and is FIXED — one
  file, reused by all tests, ideally itself emitted/owned by c2js).

  Hand-written JS/TS inventory to eliminate (2407 ln):
    webtests/wgpu_smoke.ts      (456) — DONE 5b: -> webtests/wgpu_smoke.zig
                                  (transpiled by c2js, run via runner.mjs),
                                  byte-identical output, .ts deleted.
    webtests/transpiler_corpus.ts (425) — run spv2wgsl wasm over inputs,
                                  hash outputs, diff vs fixture JSON.
    webtests/smoke.ts           (1044) — the broader smoke battery.
    webtests/server.ts          (482) — dev server (its own track: D7
                                  tools/serve.zig, pure Zig, no JS at all).

  ARCHITECTURE (the test harness, dogfooded):
    - TEST LOGIC -> Zig. Shim construction, call counting, type
      classification, report formatting, fixture hashing/diffing: all
      pure computation, compiles to wasm32, transpiled by c2js to a bare
      JS module (no --html). This is "a zimr app whose job is testing."
    - HOST STUB -> the one fixed JS file (call it webtests/runner.mjs,
      ~30-40 ln, the ONLY hand-written JS allowed, and minimal enough to
      audit at a glance): read argv, read the test-logic JS (c2js output)
      and the SUT wasm bytes, instantiate the test-logic module, expose
      a tiny host API to it (read_file, instantiate_sut, call_export,
      print), and let the Zig test driver run. Node executes this stub.
    - The shims the test provides to the SUT are GENERATED by the test-
      logic wasm (it already knows every js_* name); the stub installs
      them. Same host-boundary pattern as bridge.zig, pointed at testing.
    SUB-PHASES (each: write Zig, transpile, prove parity vs the .ts it
    replaces by identical PASS/FAIL output, then delete the .ts):
      5a DONE (t1178+). webtests/runner.mjs is the fixed host stub (~150
         ln, the ONLY hand-written JS in the test path): readFile, argv,
         print/eprint, exit, and instantiateSut/sutCall/sutCallLog. It
         instantiates the SUT behind a Proxy so any import the SUT asks
         for is auto-stubbed (records "unhandled:<name>") — instantiation
         never fails on a missing import; declared names record their
         call + return a fresh numeric handle. KEY MECHANIC: c2js bare
         output DEFINES the entry (_start) in script scope but doesn't
         call it (the --html path calls start() from an inline <script>;
         no auto-invoke in bare mode, and an ESM import leaves _start
         module-private). So runner.mjs reads the c2js JS text and runs
         it via indirect eval, then invokes the entry — the kernel (js_*
         fns, __HEAPU8) declared by that same text stays in scope. The
         Zig test logic reaches __host via the SAME bridge interop
         primitives (js_global/js_get/js_call*/js_str/js_num/js_obj) the
         real bridge uses for document/wgpu. PROVEN end-to-end: a Zig
         logic module read wgpu_basic.wasm, instantiated it, ran
         _initialize + 3 update() frames, and counted 97 host calls —
         all logic in Zig, transpiled by our own c2js.
      5b DONE (t1178+). webtests/wgpu_smoke.zig is the full port: wgpu
         verb name table (21 handle + 22 void + 3 specials), dom (43) +
         audio (20) name lists, wasi (empty; runner Proxy-stubs), the
         loop (instantiate, require {memory,_initialize,update}, run
         _initialize + N update(1/60)), per-type tally with a top-10
         by-type/frame line, missing-export/instantiate failure paths,
         and --wasm/--web-dir/--focus/--frames via __host.argv(). Output
         is BYTE-IDENTICAL to the old .ts (diff'd on wgpu_basic@60: zero
         diff). runner.mjs gained the host-fact returns (dpi/sample-rate/
         persistence-absent), the packed-size + advancing-clock specials,
         full-signature call recording, and listWasms for dir mode.
         build.zig: both `wgpu-smoke` AND `smoke-test` now transpile
         wgpu_smoke.zig via c2js (a build-obj->c2js LazyPath pair) and
         run it under `node runner.mjs <js>` — verified green through the
         build. webtests/wgpu_smoke.ts (456 ln) DELETED.
         GOTCHA found+fixed: std.fmt's {d:.1} float path trips a c2js
         BigInt/Number mix in computePow5 — avoided by formatting the
         per-frame number with integer-tenths math. (A real c2js float-
         format bug worth a differential case later; logged here.)
      5c DONE (t1178+). webtests/transpiler_corpus.zig is the full port of
         the 425-ln .ts. It walks a corpus root (default .zig-cache) for
         *.opt.spv via __host.listFiles, dedups by MD5 of the SPIR-V bytes
         (__host.md5File) size-sorted small-first, instantiates the
         spv2wgsl wasm (input_buffer_ptr / input_buffer_capacity /
         transpile(len)u64 / last_error_code), and for each shader: writes
         the SPIR-V into the SUT input buffer (__host.sutMemWrite), calls
         transpile via __host.sutCallPacked (which splits the packed
         ptr|len u64 BigInt into two numbers across the bridge), reads the
         WGSL back out of SUT memory (__host.sutMemRead), MD5s it IN ZIG
         (std.crypto.hash.Md5 + a md5Hex helper), and scans for
         __unresolved_N__ placeholders (Zig string scan, total + distinct).
         It prints the corpus summary + the per-shader detail table (exact
         padEnd/padStart matching via writePadEnd/writePadStart/
         stripCachePrefix helpers) and does fixture CHECK (default) or
         --refresh-fixture WRITE (__host.writeFile, fixture JSON built with
         std.fmt). Output is BYTE-IDENTICAL to the old .ts — including the
         capacity .toLocaleString() ("1,048,576", done by calling
         toLocaleString on a js_num), the NaN% clean-rate on an empty
         corpus (JS 0/0; replicated by emitting literal "NaN" when n==0),
         the empty detail table, and the "ENTIRE CORPUS TRANSPILES CLEANLY"
         verdict. runner.mjs gained sutCallPacked / sutMemWrite / sutMemRead
         / listFiles / md5File / fileSize / writeFile / readText. build.zig:
         both `wgpu-corpus` AND `wgpu-corpus-refresh` now transpile
         transpiler_corpus.zig via c2js (a build-obj->c2js LazyPath pair,
         reused across both steps) and run it under `node runner.mjs <js>
         [--refresh-fixture]`, depending on transpiler_wasm_install (the
         SUT) + tools_subbuild (c2js) — verified green through `zig build
         wgpu-corpus` (15 fixture entries checked, NO REGRESSIONS). The
         last .ts test-runner const (js_test_runner) is now removed; no .ts
         test invocations remain in build.zig. webtests/transpiler_corpus.ts
         (425 ln) DELETED. NOTE: this config has spirv-opt disabled and the
         SPIR-V tools unbuilt, so there are currently 0 .opt.spv inputs —
         both .ts and .zig run against an empty live set and validate the
         fixture-loading + check/refresh paths; the transpile/hash/scan
         machinery is correct-by-construction (the WGSL MD5 + placeholder
         scan are pure Zig) and exercised the moment .opt.spv inputs exist.
      5d + 5e DONE (t1178+) — by DELETION, not porting (see rationale).
         Discovery: smoke.ts (1044 ln) was the GL-era headless smoke
         harness — its bulk is a ~380-line FakeGL bridge feeding a `webgl`
         import namespace. But the WebGL backend was retired; an
         authoritative WebAssembly.Module.imports() check on the current
         wgpu wasms shows they import ONLY {wasi_snapshot_preview1, dom,
         wgpu} — `webgl` is fully DCE'd, so smoke.ts services an import
         group no live wasm uses. It was also already UNWIRED (the
         `smoke-test` step runs wgpu_smoke.zig via runner.mjs since 5b; the
         only smoke.ts mentions in build.zig are comments). server.ts (482
         ln) was the bun dev server with WS hot-reload; it was superseded
         by tools/serve.zig (static serve + HMR <script> injection) and is
         likewise unwired (comment-only refs). Porting either would be
         porting dead code, against the dogfood mandate's intent. So both
         were DELETED. server.ts's WebSocket-broadcast + recursive-watcher
         + scheduleRebuild design (documented in its own header comments,
         preserved in git/zip history) is the reference for serve.zig's
         live-reload follow-on (std.http.Server.respondWebSocket).
         5e AUDIT RESULT: webtests/ now contains exactly runner.mjs (the
         fixed host stub: WebAssembly.instantiate + fs + the host
         primitives) + wgpu_smoke.zig + transpiler_corpus.zig. The repo's
         ONLY hand-written non-Zig source is runner.mjs; everything else in
         the JS path is c2js's EMITTED output. Dogfood mandate satisfied:
         test LOGIC is Zig-through-our-own-c2js; only the irreducible host
         shim is hand-JS. build.zig reconfigures clean after the deletions
         (all steps present, lint 0).

  ============================================================
  C2JS DIFFERENTIAL GATE + the lint/transpile split (t1178+)
  ============================================================
  CONCERN: c2js must transpile ARBITRARY Zig, not just zimr's linted
  subset — but every Zig file actually USED in zimr must pass lint. These
  are different requirements and must not collide.
  RESOLUTION (verified):
    - The original webzig transpiler's 100-case differential suite lives
      in-tree at intake/webzig-all/webzig/tests/cases/*.zig. Each case is
      `export fn run_test() i32` returning 0. Many DELIBERATELY violate
      house style (untyped locals, unbraced ifs, odd bit widths, pointer
      aliasing — 3..12 lint issues each) BECAUSE they exist to exercise
      transpiler lowerings on constructs zimr's own code never uses.
    - They are correctly EXEMPT from lint: the build's lint walk roots are
      {src, examples, tools} ONLY — intake/ is never walked, so no case
      file is ever linted. (Confirmed: cases report many lint issues
      individually, but the build never sees them.)
    - They WERE NOT being run as an automated regression gate (the bridge
      arc ran them manually via a /tmp/wzsuite clone that doesn't persist).
      NOW WIRED: `zig build c2js-diff`. For each case it builds a native
      oracle (case + oracle_main.zig) and runs it, transpiles the SAME
      case through OUR c2js -> JS, runs run_test() under NODE, and asserts
      js result == native result AND no /*TODO|/*? unhandled-lowering
      marker reached the output. differential.sh exits 1 on any failure,
      so it's a real CI gate. CURRENT: all 99 agree with native, 1
      skipped (interop, no oracle), 0 fail — our transpiler passes the
      entire original corpus on zimr's pinned Zig (dev.704).
    - The differential script is already Node-based on the JS side (no
      bun). It's invoked via `sh -c` for glob expansion of cases/*.zig.
      FOLLOW-ON (Phase 5): replace the shell driver with a pure-Zig one
      to match the dogfood mandate; the regression COVERAGE is in place
      now regardless.
  SO: transpiler correctness on arbitrary Zig is gated by c2js-diff
  (cases unlinted, under intake/); zimr's own sources are gated by lint
  (under src/examples/tools). Orthogonal, both automated.

  ============================================================
  REMAINING WORK — logical order
  ============================================================
  1. tools/serve.zig (D7): DONE (t1178+). Pure-Zig std.http static dev
     server on the 0.17 Io.Threaded API (DebugAllocator, std.process.Init,
     IpAddress.listen, Io.File I/O); correct MIME (.wasm->application/wasm),
     no-store caching, HMR <script> injected before </body>. Verified
     live. build.zig serve/serve-only invoke tools/zig-out/bin/serve —
     ZERO bun refs in build.zig. SCOPE: static serve + injection only;
     the live-reload WebSocket + watch + zig-build re-spawn is the
     documented follow-on (std.http.Server has respondWebSocket).
  2. PHASE 5 dogfood (above): tests in Zig via c2js. COMPLETE (t1178+).
     5a/5b/5c ported (wgpu_smoke.zig + transpiler_corpus.zig, byte-
     identical, wired green); 5d/5e done by deleting the dead GL-era
     smoke.ts + the superseded server.ts (both unwired). The repo's only
     hand-written non-Zig is now webtests/runner.mjs (host stub) + c2js
     emitted output. Together with step 1 (serve.zig), the JS-purge /
     bun-removal arc is DONE.
  3. PORT_PLAN frontier (separate effort): GL->wgpu example port
     (retained-mesh instancing was the active edge ~turn 1102), then the
     queued engine bugs (FluidDiscs pass-restore; spv2wgsl atomics arc).
  Rationale for THIS order: (1) is small, isolated, and finishes the bun
  story cleanly; (2) is the dogfood mandate and builds on the now-stable
  bridge + Node test path; (3) is feature work orthogonal to the JS-purge
  and can proceed independently once the toolchain is pure.

  ARC COMPLETE: thin-bridge/fat-app, dual contract, ~45 wgpu verbs +
  full dom/wasi/persistence surface, push input, all examples (2D +
  bespoke 3D) served and standalone as single-file all-Zig pages.

  ============================================================
  spv2wgsl TEST-SETUP AUDIT (t1178+) — "is the spv2wgsl test
  setup clean?" Verified + fixed.
  ============================================================
  FINDING 1 (good): spirv-opt is NOT in the shipping path. The WGSL
    pipeline (shader_codegen.zig, emit_wgsl=true hardcoded) feeds zspv's
    `shader.rewritten.spv` STRAIGHT into spv2wgsl — no spirv-opt, no
    spirv-val. spirv-opt is disabled project-wide (it injected OpUndef
    into OpPhi predecessors). Builds produce shader.spv (raw, pre-zspv)
    + shader.rewritten.spv (the real spv2wgsl input); `.opt.spv` is
    NEVER produced.
  FINDING 2 (bug, FIXED): BOTH corpus tests scanned for `.opt.spv` — an
    artifact that no longer exists — so their internal-corpus arm ran
    against an EMPTY live set and could never catch a regression. The
    contract was inverted when spirv-opt was dropped but the tests
    weren't updated. FIX: point both at `shader.rewritten.spv`:
      - webtests/transpiler_corpus.zig (the dogfooded JS-path `wgpu-corpus`):
        listFiles suffix .opt.spv -> .rewritten.spv. Now finds 33 files /
        12 unique, transpiles all 12 cleanly, 100% clean rate.
      - src/tests/spv2wgsl_corpus_test.zig (the pure-Zig `wgpu-diff`):
        candidate "shader.opt.spv" -> "shader.rewritten.spv". Internal
        corpus now 33/33 ok (was 0 found).
    Plus build.zig comments updated to match.
  FINDING 3 (pre-existing breakage, FIXED): `wgpu-diff`'s test MODULE
    (diff_mod) had drifted out of sync with src/tests.zig's needs — it
    wired only the .glsl placeholders + zm + shader_interface, MISSING
    build_options (ui.zig @imports it) and the .wgsl twin embeds
    (renderer_2d @embedFiles default_shapes_vs.wgsl & co). So wgpu-diff
    didn't even COMPILE. FIX: mirror test_mod's shader-wiring loop exactly
    (.glsl placeholder, .wgsl twin, shapes externs modules, build_options).
    Now 28/28 tests pass.
  FIXTURE RE-BASELINE: tests/fixtures/wgsl_corpus.json was 15 entries of
    `.opt.spv` MD5s (stale). Refreshed against the live .rewritten.spv:
    now 12 entries (MD5(rewritten.spv) -> MD5(wgsl)), version 1. `zig
    build wgpu-corpus` is green (NO REGRESSIONS), deterministic across
    runs.
  c2js BUG FOUND (worth a differential case): the kernel's __jstr caches
    decoded strings BY POINTER (`__nc.get(p)`), assuming a given wasm
    address always holds the same string — true for static string
    literals. But a reused STACK buffer passed to js_get/js_call breaks
    this: the first decode is cached and every later call at that address
    returns the STALE string. Hit it in checkFixture (looked up
    expected[spv_md5] where spv_md5 reused one kbuf each iteration -> got
    the first key's value forever). WORKAROUND in the .zig: read the
    fixture value via Object.values indexing (parallel to Object.keys)
    instead of a pointer-keyed js_get. The c2js fix (invalidate __nc on
    heap write, or don't cache non-literal pointers) is a separate item;
    the hazard is logged here for a differential regression case.
  NAGA — the standing Rust question (NOT resolved, flagged): naga lives
    ONLY in the build-time WGSL validators (`naga-tint`,
    `naga-validate-corpus`) — never shipped in the wasm, same category as
    the (now-unused) spirv tools. It closes a gap the differential tests
    can't: spv2wgsl can emit WGSL that's structurally "handled" but that a
    browser would still reject; naga is the only thing that catches that
    short of launching a real browser. Eliminating it means either
    reimplementing enough WGSL validation in Zig (large) or accepting the
    browser as the sole external validator (slower feedback). Deferred —
    worth a dedicated design pass; the test COVERAGE is correct now
    regardless.


PHASE 5 — the example fleet + HTML deletion. Generic registration converts
  all examples to generated pages; delete 143 index.html + the per-example
  bun bundle steps + the bespoke standalone blocks. Phone re-verification
  of the standing standalones (fluid, helmet, ui) — same -Dmode=release
  semantics preserved in the new chain.

PHASE 6 — audio + cleanup. audio_bridge.zig (WebAudio graph + streaming
  worklet path) with the three audio examples as acceptance. Delete
  zimr_wgpu.ts. README + cheatsheet + tutorials updated; webtests remain
  the only TS, run by Bun, clearly marked test-only.

---

## 5. Risks, ordered

R1 Zig-pin / C-dialect coupling (Phase 0 exists for this; we own c2js, so
   drift is fixable but costs time).
R2 Hidden TS behaviors: zimr_wgpu.ts has accreted subtleties (resize
   races, the DPR/css-size derivation, format tables, error texts asserts
   rely on). Mitigation: port method-by-method against the live file; the
   smoke harness diff-runs both bridges per example.
R3 Async edge cases: device-lost, instantiation failure paths, mapAsync
   ordering under batching. Mitigation: poll-kernel unit tests + the fluid
   readback as the canary.
R4 Performance on real phone GPUs (the V8 numbers are desktop Node):
   re-run the t1178 phone matrix (fluid at 20k) on the new bridge before
   deleting the old one.
R2b RESOLVED CLASS (found on-device t1178): views over the kernel's
   RESIZABLE ArrayBuffer (__MEM, the @wasmMemoryGrow mechanism) are
   rejected by spec-strict Web APIs in Chrome ("The provided ArrayBuffer
   value must not be resizable") while node's implementations accept
   them — so webzig's own node-based suite cannot catch it. Hit in
   TextDecoder.decode (js_str/__jstr) on the phone; fixed in OUR
   tools/c2js by decoding/encoding through fresh copies (slice +
   boundary-safe encode for js_string_into), with a kernel-invariant
   check (no `decode(new Uint8Array(__MEM`) in the page smoke. The
   self-reporting --html overlay (also ours) is what surfaced the exact
   line from the device. Perf of the fix, measured old-vs-new on V8 and
   then optimized (hybrid: slice for <256B, persistent fixed scratch
   above; encodeInto→scratch for string_into): js_str 12B 223→245ns,
   1KB 393→514ns, js_string_into 52B 163→252ns — all sub-µs cold paths;
   the hot name path is memoized (one copy ever per comptime name). RULE going forward: any heap view handed to a
   Web API must be a copy or proven view-tolerant; audit per phase.
R2c RESOLVED (found on-device t1178, after the globals consolidation):
   the C backend addresses a fixed array inside a struct inside a GLOBAL
   struct as `&(&(&((T*)&g))->a)->ring)->array[i]` — a nested arrow chain
   the transpiler's &-as-value branch could not model, leaking a JS
   property access on a heap offset (`(addr).ring` -> undefined). Fixed in
   tools/c2js by invoking the tag-tracking lvalue walker as the branch's
   LAST resort (after every specialized handler, so relocated globals etc.
   keep their proven paths), in a new `prefix` walk mode that stops at
   pointer arithmetic — `(Rec*)addr + 1` strides by the CAST element, so
   the surrounding expression owns the `+`, not the inner chain (eating it
   inside the chain strided by the wrapper size, a second silent
   miscompile the differential case now covers). Guarded by
   tests/cases/global_struct_array_member.zig (kept in-repo at
   tools/c2js_cases/); webzig suite ALL GREEN with the fix. The
   self-reporting overlay + the honest click-dispatching jsdom gate
   (click_gate.mjs — events must be dispatched and PAGE ERROR shown, not
   grep-filtered away) are what caught it.
R5 Source-map/debuggability regression vs readable TS: adopt c2js source
   maps + SAFE_HEAP in Debug; document the workflow in the bridge tutorial.
R6 Audio worklets may exceed the current c2js surface (worklet code runs
   in a separate scope): isolate in Phase 6; fallback is a generated-once
   worklet emitted by the SAME toolchain from a tiny dedicated bridge file.

## 6. What gets deleted, when all phases land

zimr_wgpu.ts (1,284), overlay_input.ts (393), 143 index.html files, every
`bun build` invocation outside webtests/, the bespoke standalone HTML
assembly in build.zig, and descriptor_encoder's hand-decoded byte protocol
(superseded by shared structs). Hand-written non-Zig in the repo after
this arc: webtests/*.ts (test-only) and readme/cheatsheet doc pages —
which can themselves later be emitted by a docs step if we choose.

  ============================================================
  LINT: three changes (t1178+)
  ============================================================
  1. SCOPE — "lint all our zig before compiling, except c2js tests":
     Already true for compilation: build.zig ~4441-4443 makes EVERY
     .compile step depend on lint_run_install, and ~4462 gates the
     install step. ADDED `webtests` to the lint walk roots (now {src,
     examples, tools, webtests}) so the dogfooded test logic
     (wgpu_smoke.zig etc.) is linted too. The c2js differential cases
     under intake/ stay UNLINTED (intake/ is not a walk root) — correct,
     since they must exercise arbitrary non-house-style Zig. The walk's
     `tests/` prefix-skip still drops src/tests, examples/tests, etc.
  2. RULE array-mult (`**` retired) — IMPLEMENTED. The rule note existed
     but had no check. `**` is a PARSE error in dev.704 (tokenizes as two
     `*` with one-sided whitespace), so an AST check can't see it; added
     `scanArrayMult`, a raw-byte pre-parse scan (skips strings/char-lits/
     comments/`\\` multiline) that emits the helpful "use @splat" message
     before the generic parse-error. Verified: flags `[_]u8{0} ** 4`, not
     `**` inside strings/comments; `@splat(...)` is clean.
  3. RULE int-from-float (ban bare @intFromFloat) — IMPLEMENTED.
     `checkIntFromFloat` flags `@intFromFloat(x)` UNLESS the arg is an
     explicit rounding builtin (@trunc/@floor/@ceil/@round), so
     `@intFromFloat(@trunc(x))` is the sanctioned form. `lint:off
     int-from-float: reason` works as the escape hatch. NOTE @trunc
     returns a FLOAT so it wraps INSIDE @intFromFloat (not a replacement);
     verified `@intFromFloat(@trunc(x))` is byte-identical to
     `@intFromFloat(x)` (both truncate toward zero) — so migration is
     mechanically SAFE / no behavior change.
     ⚠ BLAST RADIUS: 176 bare @intFromFloat across the linted tree.
     Migrated the 6 in webtests/wgpu_smoke.zig (this session's code).
     DONE (option B, hand-migrated per author intent, t1178+): all 173
     src/+examples/ sites migrated by READING each in context and picking
     the correct rounding:
       - @round for COLOR/intensity/alpha quantization (image color
         conversions, ui/example channel math, audio sample quantization
         in sound.zig) — truncation biases/darkens, round is correct.
       - @round (dropping the manual `+ 0.5`) for the round-to-nearest
         idiom in image line-drawing.
       - @floor for INDICES from ratios / spatial-hash CELL coords
         (ui tab/bar selection, fluid & sph grid cells, palette indices)
         and for rasterizer bbox MIN (image triangle), @ceil for bbox MAX.
       - @trunc everywhere truncation-toward-zero was the existing intent:
         pixel COORDS/rect/size, device-pixel DIMENSIONS, JS-number
         pointer/len/id/format reads (bridge), FPS displays, already-
         integral values (ceil'd counts), glyph outline coords (codecs).
     Verified @intFromFloat(@trunc(x)) == @intFromFloat(x) so trunc cases
     are zero behavior change; round/floor/ceil are deliberate
     improvements at sites where the old truncation was latent-buggy.
     RESULT: lint 0 issues across all 267 build-set files; tier-a build
     compiles + smoke-passes (8 wgpu wasms). webtests/wgpu_smoke.zig (now
     linted, since webtests joined the walk roots) also brought to house
     style (multiline externs, typed locals, line wraps).
