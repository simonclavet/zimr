# CHANGELOG — pruned per-turn entries (zimr264 … zimr479)

Archived out of `src/notes/claude.md` to keep the fresh-session entry point readable.

**Nothing here is lost — it is verbatim.** These are the entries that only recorded
*that a thing was built, ported, tuned or counted*: the profiler build-out, the physics
stress-scene tuning run, the box2d sample-coverage grind, the raylib Wave A/B per-example
ports, the de-wgpu rename, first-copies of turns that were logged twice, superseded WIP
notes, and the 0.17.0-dev.956 compiler section (superseded by the 1245 section).

Entries that teach a still-true rule or a root cause STAYED in claude.md.
Authoritative state lives in: the code, `src/notes/raylib_port.md` (port checklist),
`src/notes/profiler.md`, `src/notes/webgpu_control.md`, `src/notes/physics_demo.md`,
`src/notes/zig-spirv-compiler-interface.md`, and `src/web/readme.html`.

---

<!-- profiler/stress zimr264 -->
### profiler step (d): engine wiring done (zimr264)
Wired the backbone into the frame loop: `wgpu_app.zig` installs the profiler
clock at App.run (`profilerClock` -> wgpu.nowMs, fast direct import is a later
pass), calls `profiler.frameMark()` at the top of the `update` RAF export, and
wraps coarse phases as zones: `frame` (whole tick) > `update` (user thunk) +
`input.endFrame`, plus `beginDrawing`/`endDrawing` zones inside those engine
phase fns (they nest under the user's update automatically via the depth stack).
Zone handles need explicit `: profiler.Zone` annotations (untyped-local rule).
Verified: wgpu builds debug (zones in) + ship (stripped); dag-check acyclic,
profiler still L0 (new wgpu_app->profiler edge). NEXT: the overlay views
(flamegraph + frame strip + stats table) — first on-device visual.


<!-- profiler/stress zimr265 -->
### profiler step (e) part 1: flamegraph view + physics-demo wiring (zimr265)
Built src/profiler_ui.zig — APP-CALLABLE views (profiler is app-driven: no
forced hotkey/input). `flamegraph(u, frame)` draws an icicle (time-x, depth-down)
for one frame via ui.zig DrawList (addRectFilled/addRectOutline/addText), fills
width to the actual work span, hover→setTooltip with ms, 14-colour palette by
src id. `panel(u)` = header (worst-frame ms + fps) + flamegraph of worstFrame().
(`show` collided with plot_ui's pub fn show -> renamed `panel`.) profiler.zig
gained read accessors: ZoneIter/frameZones (handles ring wrap) + srcOf. Added a
`physics.step` zone in zimrphysics World.step (its 10 PHASE blocks are the next
deepen-on-demand targets). Wired examples/wgpu_zimrphysics_demo: a "Profile"
button toggles `state.profiling` -> profiler.freeze()+pause stepping (phys_accum
forced 0) and opens a "profiler — worst frame" ui window calling
z.profiler_ui.panel(u); "Resume" unfreezes. So the worst frame in the 2s before
freezing (full of physics) is what you inspect. Builds: demo + wgpu + ship;
dag-check acyclic (profiler L0, profiler_ui L9). NOTE clock is still wgpu.nowMs
(reflection, ~100µs) — physics.step is several ms so it shows fine; the fast
direct `now` import + COOP/COEP + resolution probe are the next pass. THEN the
frame strip + stats table, then deepen the physics PHASE zones.


<!-- profiler/stress zimr266 -->
### profiler: physics PHASE breakdown + UI polish (zimr266)
Deepened zimrphysics.step: added 5 phase zones under physics.step — broadphase
(P3), narrowphase (P4), solve.velocity (P5), integrate (P6), solve.position (P7)
— so the flamegraph splits the physics bar into the pieces to optimise. (P1/P2
per-body loops + P3.5 islands + P8/P9 left for further deepening; P3.5 has no
block to scope.) Demo UI: buttons 88x34 -> 82x26 and window 162->172 tall so the
Profile/Resume button isn't clipped; window title em-dash -> ASCII '-' (font has
no em-dash glyph, rendered '?'). On-device confirmed working: frame>update>
{beginDrawing, physics.step, endDrawing}, worst-frame 17.9ms/56fps. NEXT: fast
`now` import + COOP/COEP + resolution probe, then frame strip + stats table.


<!-- profiler/stress zimr267 -->
### profiler: frame strip + statistics table (zimr267)
profiler.zig read-side: frameAt(i) (i=0 newest), SrcStat + aggregate(out) — sums
per-call-site count/total/min/max across the ~2s window. profiler_ui.zig:
frameStrip(u) = DrawList history bars (newest right, green<budget/red>budget,
worst tinted, 60fps budget line); statsTable(u) = ui Table (zone|count|total|
mean|max) sorted by total desc via std.mem.sort. panel() restructured: header +
frame strip + TabBar{Flamegraph | Statistics}. The table is the "what to
optimise" report — it surfaces phases too thin to read per-frame at 100µs.
v1 cut (flamegraph + strip + stats table) now COMPLETE. Builds: demo + standalone
+ lint clean. NEXT: fast `now` import + COOP/COEP + resolution probe (sharpen
sub-0.1ms), then deepen more zones as needed.


<!-- profiler/stress zimr268 -->
### physics demo: mega "stress" scene (zimr268)
Added a `stress` scene to wgpu_zimrphysics_demo (last in the enum, after
ragdoll_pile) — one big world combining: a big spinning blender (r_wall 5 round
container, large cross-blade rotor on a swing-twist velocity motor) with 60 balls;
a Galton board fed 100 pre-stacked balls; a ~100-box pyramid (base 7, capped 100);
and a 12-link chain pendulum + heavy bob (shoved to swing). 5 builders
(stressFloor/Blender/Galton/Pyramid/Chain) each take an `o: Vec` origin, composed
at offsets on one 80x80 floor; allow_sleeping=false for max load (~270 dynamic
bodies). Built to push broad/narrow phase + the velocity/position solve sweeps —
profile it via the Profile button -> Statistics tab. Switch arms added: label,
description, camDistance(62); enum count anchor moved ragdoll_pile->stress. Lint
gotchas: `floor` is a reserved-math-name (renamed floor_shape); long
addDistanceConstraint lines wrapped via local vecs. Builds: demo + standalone.


<!-- profiler/stress zimr269 -->
### stress scene tuning (zimr269) — on-device fixes
After first device run: (1) chain bob was UNDER the floor — 12 links from an
anchor at y=11 hung the bob to y~-2.5. Fixed: top_y 11->15, n 12->10, shove 8->6
(bob now rests ~y3.6, clears floor, swings free). (2) pyramid looked incomplete
(base-7 capped at 100 left a partial top) -> base 6 = 91 cubes, complete apex,
cap removed. (3) blender "shaking" from crowding/fast tip: deeper->shallower walls
(half-h 2.6->2.0), center y 2.2->1.6, rotor 1.2->0.8 rad/s, balls 60->30, and
added 3 humanoid ragdolls (buildRagdoll, groups 40/41/42) dropped above the rotor
to be churned. (4) galton off-screen: pulled in (offset 22->15,0,-3), walls
8->6 tall, y_top 13->10, balls spread 13-wide. Features tightened (pyramid
-14,0,5; chain 0,0,15) + camDistance 62->48 so all four frame at once.


<!-- profiler/stress zimr270 -->
### stress scene v3 (zimr270) — glass galton + reverted stirrer
- render.zig: added `pub const invisible_material: u16 = 0xFFFF` + a skip in the
  drawWorld cb (`if body.material == invisible_material return`). A body with that
  material still COLLIDES but isn't drawn — "glass" walls. (is_sensor was wrong:
  it kills collision.)
- Galton: all 4 containing walls set to invisible_material (glass box — see the
  pegs + balls, not grey slabs); ball start x JITTERED via inline LCG (±0.35) so
  they scatter into a real bell curve instead of aligned columns.
- Stirrer: the big r_wall-5/blade-4.3 rotor jittered; reverted to the proven
  sceneStirrer geometry (curved wall, blade/wall ratio ~0.83, 1.5 rad/s twist
  motor) scaled ~1.3x (r_wall 3.6, blade 3.0, 36 segs) to fit the 3 ragdolls +
  ~14 mixed objects. Builds: demo + standalone + lint clean.


<!-- profiler/stress zimr271 -->
### stress scene v4 (zimr271) — hinge rotor, real galton, big projectile
- Stirrer flip FIXED: swapped the swing-twist (soft cone, lost to off-centre
  ragdoll load and flipped) for addHingeConstraint about Y with a velocity motor
  (mode=.velocity, target 1.5, max_force 1e6). A hinge geometrically removes the
  tilt DOFs, so it CANNOT flip — same pattern as sceneMotor.
- Galton: pegs now CYLINDERS (half_h 1.7, r 0.25) rotated Y->Z (quat axis x, pi/2)
  so a round face meets the drop plane; added 11 visible bin dividers (box
  0.1x1.6x1.9, material 5) so balls gather in columns; balls now all drop from the
  MIDDLE in a tight 3x3 cluster with tiny jitter (±0.1) — peg bounces do the
  spreading (real Galton).
- Launch: stress sets launch_shape to r=0.9 (3x the 0.3 default, ~27x mass);
  launchSphere throws at 26 m/s so it bowls through the pyramid when aimed.
Builds: demo + standalone + lint clean.


<!-- profiler/stress zimr272 -->
### stress scene v5 (zimr272) — 3x ragdolls, thin 300-ball galton, carousel pendulum
- buildRagdoll gained a `scale: f32` param (scales part hh/r/pos + joint pivots;
  cone angles are scale-invariant). Callers: ragdoll_pile passes 1.0, stress 3.0.
- Stirrer enlarged to hold the 3x ragdolls (hinge => no flip at any size): r_wall
  6.5, walls half-h 3.8 (48 segs), blade 5.2, center y4, hinge motor 0.8 rad/s /
  3e6 max_force; 8 loose objects + 3 ragdolls dropped from y5.5-8.5.
- Galton 2x THINNER (z half 2->1.0, back walls ±1.9->±0.95, peg cyl half_h
  1.7->0.85, bins z 1.9->0.95); 3x MORE balls (100->300, r 0.24->0.18, central
  7x3 cluster); pegs RAISED (y_top 10->13) + taller bins (half 2.0 @ y2) so pegs
  clear the buckets.
- Pendulum is now a CAROUSEL: static hub + a motorized arm (box, COM at hub,
  hinge about Y, velocity 1.3) with the 7-link chain + bob hanging from the arm
  END (x=3.5). The spinning arm drags the chain in an orbit => perpetual motion
  (no tethers; bob density 4000->1500 so links hold). camDistance 48->56.
Builds: demo + standalone + lint clean.


<!-- profiler/stress zimr273 -->
### stress scene v6 (zimr273) — chunky galton balls, 3x stirrer objects
- Galton balls: radius 0.18->0.45 (diameter ~half the board's thin width), dropped
  ONE-DEEP in Z (cz~0 + jitter) so they read as a clean 2D bell curve. Count cut
  300->120 (300 chunky balls overflow a one-deep thin board into a giant tower).
- Stirrer: new stressObjectShape picker (bigger, 5-way variety: sphere r0.45 / cube
  0.42 / ROD 1.0x0.25x0.25 / cylinder r0.38 / capsule) and object count 8->24,
  spawned in 3 layers (y5-7) under the 3 ragdolls (raised to y8/9.5/11 so nothing
  spawns overlapping). Builds: demo + standalone + lint clean.


<!-- profiler/stress zimr274 -->
### stress scene v7 (zimr274) — galton stream, taller walls, blades to the floor
- Galton balls now spawn ONE AT A TIME from the middle: new spawnStressGaltonBall
  (reuses plinko_* counters) releases one r0.45 ball every 9 steps from
  galton_origin + (jitter, y_top+2, jitter) up to 160; hooked into update for
  scene==.stress. stressGalton now takes state, stores galton_ball/origin/y_top +
  resets the counters (no more pre-spawn block). New State fields: galton_ball,
  galton_origin, galton_y_top.
- Galton walls raised 6->9 half-height (top y18) so bouncing balls can't escape.
- Stirrer blades reach the bottom: rotor center 4.0->2.3 and blade y-half 0.5->1.5
  (blades span y0.8-3.8, grazing the container floor top at 0.8). Builds: demo +
  standalone + lint clean.


<!-- profiler/stress zimr275 -->
### stress scene v8 (zimr275) — smaller galton balls, pendulum bumps pyramid
- Galton ball radius 0.45->0.225 (the 0.45 ones jammed above the first peg row).
- Pendulum (carousel) moved from (0,0,15) to (-14,0,10) — directly +z of the
  pyramid (at -14,0,5) so the orbiting bob clips the pyramid's near face once per
  revolution. Far enough from the round stirrer (origin, r6.5: nearest approach
  ~10.9 > 6.5) that the chain never fouls it.


<!-- profiler/stress zimr276 -->
### stress scene v9 (zimr276) — unstick stirrer, pendulum farther
- Stirrer was STUCK: blades touching the floor pinned objects against it and
  stalled the hinge motor. Lifted the rotor (center 2.3->3.0, blade bottom now
  ~1.5, a ~0.7 gap above the floor) so objects circulate under, and boosted motor
  max_force 3e6->1e7 so the churn can't stall it.
- Pendulum moved farther from the pyramid (-14,0,10 -> -14,0,13) so the swung-out
  bob grazes the pyramid's +z edge rather than plowing through / tangling.


<!-- profiler/stress zimr277 -->
### profiler: clock cache + resolution probe (zimr277)
- bridge.zig jsNowMs now CACHES the `performance` object handle (struct-level var,
  lint:off module-var) so each clock read is call+to_number instead of
  global()->get("performance")->call("now") — the profiler reads it 2x/zone
  (hundreds/frame), so this keeps the clock's own cost out of the measurements.
  dag-check + wgpu build clean.
- profiler.zig: probeResolution() (samples the clock for the smallest non-zero
  delta = resolution) + timerResolutionMs(); wgpu_app calls probeResolution() right
  after setClock. profiler_ui panel header now shows "timer ~Xus" so the floor is
  visible (no cross-origin isolation => ~100us clamp; with COOP/COEP => ~5us). The
  standalone (local file) can't set those headers, so it'll read ~100us; served
  with COI it auto-sharpens. NEXT (still open): GPU timing via timestamp queries;
  auto-freeze-on-spike; find-zone histogram.


<!-- profiler/stress zimr278 -->
### profiler: auto-freeze-on-spike (zimr278)
- profiler.zig: armAutoFreeze(factor, floor_ms) / disarmAutoFreeze / isAutoArmed /
  autoFroze. markFrame keeps a smoothed EMA baseline (dur_ema, 0.9/0.1) and, when
  armed + frame_count>20, freezes the rings the moment a frame exceeds
  factor*baseline AND floor_ms — so a transient hitch is captured without timing a
  button. Stays armed across unfreeze (re-captures the next spike). reset() clears
  the baseline. New headless test proves a 40ms hitch fires it while 30 steady 10ms
  frames don't (3/3 tests pass via `zig test --dep build_options`).
- profiler_ui: header shows "** auto-froze on a spike **" when autoFroze().
- demo: "Watch" button arms it (2.0x / 4ms); update mirrors profiler.isFrozen()
  into state.profiling so the panel pops up on the captured hitch; toggling off
  disarms + resumes. dag-check + demo + standalone clean.
NEXT open: GPU timing (timestamp queries; multi-turn core wgpu/bridge work);
find-zone histogram.


<!-- profiler/stress zimr279 -->
### profiler: find-zone histogram (zimr279)
- profiler.zig: frameSeriesFor(src, out:[]f64) usize — one value per frame in the
  window (inclusive total for that call site, newest first). Tests still 3/3.
- profiler_ui.zig: Statistics rows are now selectable (u.selectable); tapping a zone
  sets selected_src (tap again to clear). Below the table, zoneHistogram draws the
  per-frame distribution: 24 bins between the zone's per-frame min/max, bar height =
  frame count per bin (hist_col). A tall single bar = steady; a long tail = spiky.
  Mirrors frameStrip's DrawList usage. selected_src is a lint:off module-var.
- NOTE Zig 0.17: `.{0} ** N` array-repeat is retired -> use `@splat(0)`.
NEXT open (the big one): GPU timing via timestamp queries — multi-turn core
wgpu/bridge work (requiredFeatures + createQuerySet/resolveQuerySet + async
readback), not headless-verifiable; needs dedicated device iteration.


<!-- profiler/stress zimr280 -->
### profiler: render-path instrumentation (zimr280)
- Observation from device stats: frame mean ~9.9ms but physics.step only ~4ms +
  beginDrawing ~0.5ms -> ~5ms/frame was unzoned rendering (the world draw between
  begin/end). Now zoned:
  - render.zig drawWorld: `render.world` zone (the bodies.forEach shape-draw loop).
  - demo draw: `render.overlay` (drawSceneOverlay) + `render.ui` (ui_host.render).
  These nest under `update` alongside physics.step, so the flamegraph + stats now
  account for the whole frame. render.zig is demo-local (imports zimr as z ->
  z.profiler). Next obvious deepening: split render.world per-shape-kind, or zone
  inside the immediate-batch flush. Still the big one: GPU timing.


<!-- profiler/stress zimr281 -->
### profiler: render breakdown CONFIRMS draw-bound (zimr281)
- Device stats (stress): render.world 4.147ms mean > physics.step 3.099ms mean.
  The stress scene is CPU-DRAW-bound, not physics-bound: per-body shape
  tessellation into the immediate batch is the #1 leaf. Actionable target =
  draw submission (batch/cull), not physics tuning.
- Still ~4.5ms/frame unaccounted in update -> added render.grid (drawGrid) and
  render.flush3d (endMode3D = the 3D batch flush: vertex upload + draw recording).
  frame-update delta was ~0.02ms, so the runner's submit/present is NOT the gap;
  it's inside the demo draw. These two zones should close it.
NEXT: once flush3d is quantified, deepen render.world per-shape-kind if it's the
target; then GPU timing (the committed core effort).


<!-- profiler/stress zimr282 -->
### GPU timing increment 1: feature-detect timestamp-query (zimr282)
- Render breakdown is now complete + the scene is confirmed CPU-DRAW-bound
  (render.world ~4.1ms > physics.step ~3.1ms). Started the committed GPU-timing arc.
- bridge.zig boot stage 1: BEFORE requestDevice, feature-check
  adapter.features.has('timestamp-query') (Value.truthy()). If present: request with
  requiredFeatures:['timestamp-query'] (built via Array.new+push / Object.new+set) and
  set g.boot.timestamp_supported=true; else plain requestDevice. SAFE: requesting an
  unsupported feature would REJECT requestDevice -> black screen, so we only request
  when has() is true. note() logs "timestamp-query SUPPORTED/NOT supported" to the
  on-page log overlay so we learn if the device exposes it AT ALL before building the
  query-set/resolve/readback plumbing. (note() is comptime-string -> two static msgs.)
- g.boot.timestamp_supported persists for the next increment.
NEXT (increment 2, gated on device showing SUPPORTED): wgpu.zig createQuerySet
('timestamp', 2) + render-pass timestampWrites (beginningOfPassWriteIndex/
endOfPassWriteIndex) + resolveQuerySet -> mappable buffer + mapAsync readback (a
frame or two late); profiler stores gpu_ms/frame; profiler_ui shows CPU vs GPU.
The render pass is owned by the runner (wgpu_app/standalone) — that's the wiring site.


<!-- profiler/stress zimr283 -->
### GPU timing increment 2a: timestamp infra (zimr283)
- DEVICE CONFIRMED: log overlay showed "timestamp-query SUPPORTED". GPU timing viable.
- bridge.zig Wgpu struct: ts_query_set / ts_resolve_buf / ts_read_buf / ts_ready.
  At device init (stage 2), gated on g.boot.timestamp_supported, create:
  - querySet {type:'timestamp', count:64} (64 slots = up to 32 timed passes/frame),
  - resolve buffer 512B usage QUERY_RESOLVE|COPY_SRC (0x200|0x4),
  - readback buffer 512B usage COPY_DST|MAP_READ (0x8|0x1).
  note() logs "GPU timing infra ready". SAFE: only allocates; does NOT touch the
  render path, so boot/render can't regress. Buffer-usage values are real
  GPUBufferUsage bits (see decodeBufferUsage table @~1066).
NEXT increment 2b (the risky one, isolate it): wire timestampWrites into the frame
render pass (jsEncoderBeginRenderPass @~1172: timestampWrites={querySet, beginning/
endOfPassWriteIndex} using a per-frame slot cursor reset each frame), resolveQuerySet
+ copyBufferToBuffer(resolve->read) before submit, mapAsync(read) with a single
in-flight guard (skip if pending), parse 2 u64 ns per pass, sum deltas = GPU ms/frame,
store in profiler (new gpu_ms field on Frame or a parallel ring), profiler_ui shows
CPU vs GPU in header/strip. The frame may emit multiple passes -> sum all pairs.


<!-- profiler/stress zimr284 -->
### GPU timing increment 2b-core: live timestamps (zimr284) -- VERIFY ON DEVICE
- Full machinery wired, gated entirely on ts_ready/ts_pending (inert on unsupported
  devices, so no regression risk there):
  - Wgpu struct: ts_cursor, ts_resolve_pairs, ts_pending, ts_pid, ts_pairs_inflight,
    gpu_ms_last, ts_log_ctr.
  - __zimrGpuMs helper built at init via `new Function("ab","pairs", body)` (avoids a
    page-template script). Reconstructs each u64 ns ts as hi*2^32+lo in f64 (exact
    < 2^53), sums (end-begin) per pass -> ms. NO BigInt. [RISK: if CSP blocks the
    Function ctor this throws at init -> would need to move helper into c2js.zig page
    template. Local content:// files usually have no CSP; prior feature/query calls
    worked, so env looks permissive.]
  - jsDeviceCreateCommandEncoder: ts_cursor=0 (per-encoder reset).
  - jsEncoderBeginRenderPass: adds timestampWrites {querySet, beginningOfPassWriteIndex
    =cursor, endOfPassWriteIndex=cursor+1}, cursor+=2 (skipped while pending / on
    overflow of the 64 slots).
  - jsCommandEncoderFinish: before finish, if cursor>0 & !pending -> resolveQuerySet(0,
    cursor, resolve_buf, 0) + copyBufferToBuffer(resolve->read, cursor*8);
    ts_resolve_pairs=cursor/2.
  - jsQueueSubmit: after submit, if resolve queued & !pending -> mapAsync(read, READ);
    register promise; ts_pending=true; one in flight at a time.
  - pollGpuTiming() (top of tick stage 4): when the map resolves -> getMappedRange ->
    __zimrGpuMs -> gpu_ms_last; unmap; clear pending. Throttled console.log "zimr gpu
    ms: X" ~once/sec so the NUMBER can be sanity-checked on device BEFORE UI wiring.
- numValue is a ZimrWgpu-scope helper; in ZimrBoot (pollGpuTiming) use Value{.h=js_num()}.
DEVICE CHECK: scene still renders (no uncapturederror), and log overlay prints "zimr gpu
ms: <few ms>" periodically. If sane -> increment 2c: extern wgpu.gpuMsLast() ->
wgpu_app feeds profiler -> profiler_ui shows CPU vs GPU in header/strip. If it errors or
logs 0/NaN -> debug (likely the Function-ctor helper or a timestampWrites validation).


<!-- profiler/stress zimr285 -->
### GPU timing increment 2c: into the profiler (zimr285) -- FEATURE COMPLETE (v1)
- DEVICE CONFIRMED working: console showed "zimr gpu ms: ~2.1" steady. Note GPU
  timestamps quantize to 2^16 ns (~65us) for timing-attack mitigation (deltas come in
  65.5us steps). Frame CPU ~6.4ms vs GPU ~2ms => this stress scene is CPU-DRAW-bound
  with big GPU headroom (matches render.world/flush3d being the leaves).
- Removed the diagnostic console.log + ts_log_ctr (verified).
- bridge.zig: jsGpuMsLast() returns g.wgpu.gpu_ms_last; registered ns.set("js_gpu_ms_
  last", funcNum(&jsGpuMsLast)).
- wgpu.zig: extern js_gpu_ms_last + `pub fn gpuMs() f64` (NOT gpuMsLast -> would
  [dup-pub-fn] with profiler.gpuMsLast; cross-file col-0 pub fn names must be unique).
- profiler.zig (still L0, fed not importing): Store gpu_ms[128] ring + gpu_head/count/
  last (gpu_cap/gcap like the other caps). recordGpuMs(ms) (ignores <=0 and while
  frozen so the figure snapshots), gpuMsLast(), gpuMsMean(), frameMeanMs() (CPU mean
  over window). reset() clears them (store=.{}).
- wgpu_app.zig: after frameMark, profiler.recordGpuMs(wgpu.gpuMs()).
- profiler_ui.zig header: when gpuMsMean>0, "CPU ~X ms   GPU ~Y ms".
- 3/3 profiler tests still pass; dag-check + demo + standalone clean.
GPU TIMING ARC DONE (v1 = total of all render passes per frame). Possible later:
per-pass GPU breakdown (label each pass), GPU line on the frame strip, compute-pass
timing. Minor: a runtime ui lint warns the profiler window content > 3x viewport on
narrow screens (cosmetic).


<!-- dup first-copy zimr317 -->
### zimr317
Per Simon: dropped the backward-compat constraint (we are our only client).
Continued the shader-pipeline audit + delivered the launcher as the integration test.

DECISION (important): auto-deriving the vertex layout from VsSchema.Attributes when
vertex_buffer_layouts==null is WRONG even without backward-compat — the fullscreen
trivial_vs_io declares only pos+uv (stride 16) but the actual fullscreen buffer is
Vertex2D (stride 20 w/ color). Auto-derive would silently break EVERY fullscreen
side-by-side (mandel/rt/julia — several are launcher flagships). So the opt-in
`z.shader.vertexLayout(VsSchema)` helper is the CORRECT design (derive when buffer
== schema; pass explicit layouts otherwise). Kept it; did NOT auto-derive.

IMPROVEMENT (additive, test exit 0): added two migration-blocker knobs to ShaderDesc,
unblocking the advanced pipeline_* conversions:
  - `sample_count: u4 = 1` -> threaded into StateCombo.fromParts (was hardcoded 1 at
    the line after depth_format). Unblocks pipeline_msaa.
  - `constants: []const gpu.PipelineConstant = &.{}` -> added to the main
    RenderPipelineDescriptor (.state=state_combo path). Unblocks pipeline_constants.
  (gpu already had PipelineConstant{name,value:f64} + descriptor.constants from the
  earlier inline-WGSL pipeline work; fromParts already took sample_count:u4.)
  NOTE: the pre-bake hotCombos2D path (pre_bake_pipelines) is the 2D fast path and
  does not carry these knobs — fine, MSAA/constants shaders don't set pre_bake.

DELIVERABLE: wgpu_launcher standalone (8.4M), 13 flagships: helmet_sw (CPU/GPU PBR),
ui_full_showcase, zimrphysics_demo, mandel_sidebyside, rt_sidebyside, plot_demo,
plot3d_demo, sph_fluid_2d, ecs_boids, fluid_sort, skinned_mesh, mandel_julia,
kaleidoscope. Builds clean WITH the zimr316/317 shader-runtime changes -> serves as
the regression test for them. Earlier black-screen is resolved; builds exit 0.
NEXT: resume converting pipeline_* to Zig shaders (uniforms, then geometry/texture
batch; msaa/constants now unblocked by the new knobs).


<!-- PRIOR STATE + PLAN (0.17.0-dev.956) preamble — superseded by the 1245 section -->
### ★ PRIOR STATE + PLAN (as of the 0.17.0-dev.956 compiler) ★

**COMPILER.** Now on Zig `0.17.0-dev.956+2dca73595`, extracted at
`/home/claude/work/newzig/zig-x86_64-linux-0.17.0-dev.956+2dca73595/` (old 892 still
at `/home/claude/work/zig-x86_64-linux-0.17.0-dev.892+54537285c`). zimr compiles + runs
on 956 — DEVICE-VERIFIED via the launcher standalone + all 13 flagship standalones built
on 956. 956 already has: `@SpirvType` (sampler/image/sampled_image/runtime_array),
`@extern(..., .{ .decoration = .{ .descriptor = .{ .set, .binding } } })`, exec-mode-on-
callconv (`callconv(.{ .spirv_fragment = .{} })` — STRUCT form, not bare enum),
`std.spirv` (renamed from std.gpu). std.spirv has NO spec-constant and NO image-sample
builtins — those are not provided.

**★ HOW TO COMPILE IN THIS LIMITED SANDBOX (hard-won) ★**
RAM is only ~3.9 GB; foreground tool calls have a hard execution cap (~300–590 s);
BACKGROUND builds get REAPED (whole process tree killed) within ~5–10 min, so long
unattended builds/batches do NOT survive. Recipe:
1. **Warm the constituent modules first** with small builds (individual example/flagship
   standalones). The launcher standalone OOMs COLD — not at the link, but at the cold
   PARALLEL COMPILE of all modules at once. Once each module is cached, the heavy
   aggregate build (launcher) just links + packages: ~50 s, low memory, no OOM.
2. **Big builds: FOREGROUND, at the START of a turn, generous `timeout` (~590).** Give
   it the whole window. (`zig build wgpu-launcher-standalone -Dmode=release` after warming
   = ~50 s.)
3. **Batches of standalones: foreground, copy each to `/mnt/user-data/outputs` AS it
   finishes** (copy-as-you-go survives a mid-batch reap). ~3–4 warm standalones fit one
   foreground window. Loop: `for a in ...; do zig build wgpu-$a-standalone -Dmode=release;
   cp zig-out/standalone/wgpu_${a//-/_}.html /mnt/user-data/outputs/; done`.
4. **SPIR-V compiles REQUIRE `-fno-llvm -fno-lld`** (self-hosted backend). Without them
   zig SEGFAULTS trying to use LLVM for spirv. Full flags:
   `-target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv`.
5. If `.zig-cache` > ~6 GB or things act stale: `rm -rf .zig-cache` (but that forces a
   cold rebuild → re-warm before any aggregate build).
Launcher's 13 flagships (build.zig:1522): helmet_sw, ui_full_showcase, zimrphysics_demo,
mandel_sidebyside, rt_sidebyside, plot_demo, plot3d_demo, sph_fluid_2d, ecs_boids,
fluid_sort, skinned_mesh, mandel_julia, kaleidoscope.

**★ THE PLAN: @SpirvType arc (primary, unlocked by 956) ★**
We control spv2wgsl, so the back half (SPIR-V→WGSL) is OURS; the only question per feature
is "get the right op into the .spv." `@SpirvType` addresses THREE backlog blockers at once:
- `.sampled_image` → **samplers** (retire the workaround).
- `.image` `.usage=.storage` `.format=...` `.access=.write_only` → **storage textures**
  (= `texture_storage_2d<rgba8unorm, write>`; unblocks sampler/mipmap/array's compute-gen).
- `.runtime_array` (exposes `.len` + native indexing, last field of an `extern struct`) →
  **storage buffers** (unblocks storage/forward_kinematics) — NO asm, plain Zig indexing.

SPIKE RESULT (validated on 956, target spirv32-vulkan):
- ✓ DECLARATION WORKS: `@SpirvType` image/sampled_image + `@extern` `.descriptor` compiles
  to a valid .spv. This is the thing that was impossible on the old compiler.
- ✓ **P0 SOLVED (zimr335): the sample/store OPERATION assembles.** Opaque image types can't
  be `OpLoad`ed in plain Zig, so load+sample/store go through inline SPIR-V `asm`. The block
  was referencing SPIR-V TYPES in the asm: the prior spike bound types as VALUE operands →
  "failed to assemble". FIX = the **`"t"` (type) asm constraint** (`src/codegen/spirv/
  CodeGen.zig` `airAsm`): `[si_ty] "t" (SampledImage)` resolves via `cg.resolveType` to the
  module's real DEDUPED type id — exactly the id the `@extern` var points to, so
  `OpLoad %si_ty %ptr` type-checks. Both proven (see `src/notes/spikes/`, with README):
    - sample: `OpLoad`(SampledImage) + `OpImageSampleImplicitLod` → vec4 (856-byte .spv).
    - store:  `OpLoad`(StorageImage) + `OpImageWrite` (796-byte .spv).
  Third blocker (runtime_array) needs NO asm — plain Zig `.len`+indexing. So all three
  @SpirvType targets are unblocked.
  API GOTCHAS (validated): `format` enum is `rgba8unorm`/`rgba32f`/`r32f`/… or `.unknown`;
  `access .write_only/.read_only` are OPENCL-ONLY → use `.access = .unknown` on vulkan
  (read/write via NonReadable/NonWritable decorations); compute entry callconv needs an
  explicit workgroup size `.{ .spirv_kernel = .{ .x, .y, .z } }`; IO `@extern` takes
  `.decoration = .{ .location = N }`.
  NEXT STEP (P1): wrap the asm in one tested helper pair (`sampleLod`/`imageStore`) and
  re-back `shader_interface.Sampler2D` with `@SpirvType` (same public API).


<!-- box2d grind zimr352 -->
zimr352  wgpu_zimrphysics2d_demo + first scene (Pyramid). DRAWING APPROACH (chosen as most
         future-proof + efficient): a DebugDraw->ui.DrawList adapter. The engine ships a
         box2d-faithful b2DebugDraw (`phys.draw(world,*DebugDraw)` walks every shape/joint/
         contact/aabb and fires optional callbacks); we implement ~10 callbacks in
         examples/wgpu_zimrphysics2d_demo/render.zig that push into the UI background draw
         list. Demo never switches on shape type -> new primitives draw for free; ImDrawList
         batches to a few GPU draw calls. (Alternative: manual pure-read over world.bodies
         like the 3D demo's render.zig -- rejected for 2D since box2d's own testbed renders
         via debug-draw and DebugDraw also covers joints/contacts with zero per-shape code.)
         render.zig: Camera2D (world-m -> screen-px, Y-flipped), DrawCtx{dl,cam}, hex()
         0xRRGGBB->Color, 10 callbacks (solid/outline polygon via dl.addPolygon+addPolyline,
         solid/outline circle w/ spin spoke, capsule as stadium=2 discs+quad, line, point,
         transform axes, string, aabb), debugDraw(ctx,Options{joints,bounds,contacts}).
         main: Scene{name,build fn}; scene_list=[Pyramid]; buildPyramid = 40x1 static ground
         (top at y=0) + box2d's classic 14-row triangular pyramid of 1m boxes (dx{.5625,1.25}
         dy{1.125,0}, centered). Fixed-timestep accumulator (1/60, sub_steps=4, guard<8).
         Control window: scene buttons, paused, reset, zoom slider, joint/aabb/contact toggles.
         GOTCHAS fixed: world gravity is world.settings.gravity (Settings struct, default
         {0,-10}) NOT world.gravity; standalone step is DASH-cased wgpu-zimrphysics2d-demo-
         standalone (name underscores->dashes). build.zig: registered .{name="zimrphysics2d_
         demo"} after the 3D entry (~L1263). MODE NOTE: -Dmode is now debug|release|ship; the
         assert-on build Simon verifies = plain `release` (keeps zimr asserts; `ship` strips
         them). Old `-Dmode=release-with-zimr-asserts` no longer exists. Built release (1.88MB
         HTML), full wgpu-check GREEN (NO REGRESSIONS, smoke PASSED), both files lint+fmt 0.
         NEXT scenes (adapter already covers all shapes/joints): stack, ragdoll/revolute chain,
         capsule+circle mix, joint showcase -- pure world-building, no render changes. Also
         refresh STALE regression.zig to new API (.type->.motion_type, BodyType->MotionType).


<!-- box2d grind zimr353 -->
zimr353  wgpu_zimrphysics2d_demo: pointer DRAG (mouse + touch). box2d v3.1's mouse-pick = a
         soft MOTOR JOINT between the picked body and a movable static anchor (no mouse-joint
         type exists in v3.1; JointType={distance,filter,motor,prismatic,revolute,weld,wheel}).
         Flow: on press (and !u.wantCaptureMouse()) overlapAabb a tiny box at the pointer ->
         pickCallback keeps the nearest DYNAMIC body whose shape exactly contains the point
         (pointInGeom: local-space half-plane test for polygon, radius for circle, seg-dist for
         capsule). beginDrag: createBody static anchor at pointer; createMotorJoint(anchor=body_a,
         picked=body_b, local_frame_b=grab point in body-local via invTransformPoint, linear_hertz
         6, damping 0.7, max_spring_force 1000*mass). Each frame while held: setTransform(anchor,
         pointer, identity) so the spring drags the grab point to the cursor (off-center grabs
         rotate naturally -- the whole point of a mouse joint). Release: destroyBody(anchor) ->
         the joint is OWNED by the anchor so destroyBody auto-tears it down (private destroyJoint,
         no pub needed). Amber leash line drawn grab->pointer in the bg DrawList. loadScene sets
         drag=null (old anchor dies with old world). KEY API FACTS: OverlapCallback=*const fn(
         shape: ShapeIndex=u32, ctx)bool returns true=continue; QueryFilter{} default; createJoint
         consumes body handles via .index() only + stores BodyIndex, so phys.BodyHandle.pack(
         @intCast(idx),0) is a correct/complete handle for a body found by index (no live-cycle
         needed; Handle.pack is pub). gravity=world.settings.gravity. Input: z.getMousePosition(
         f.input)+z.isMouseButton{Pressed,Down,Released}(f.input,.left) (primary touch maps to
         mouse-left -> works on phone). Camera2D got screenToWorld (inverse of worldToScreen) in
         render.zig. No invTransformPoint2 in zm -> computed inline R(-θ)(w-p) via Rot2.cosine/sine.
         Built release (assert-on; 1.89MB HTML), full wgpu-check GREEN, both files lint+fmt 0.


<!-- dup first-copy zimr354 -->
zimr354  box2d sample-port arc, WAVE 1. Surveyed all 137 registered samples (14
         categories) and wrote the full triage in src/notes/box2d_samples_plan.md (scene-
         portable vs events-plumbing vs collision-lab vs skip-tier repros). Built the scalable
         scene system: examples/wgpu_zimrphysics2d_demo/scenes.zig owns Scene{category, name,
         build(*World)!void, update: ?*const fn(*World)void} + `pub const list` registry +
         Options-struct spawn helpers (addBody/attachBox/Circle/Capsule/OffsetBox, groundBox/
         Segment, arena, worldToLocal, pinRevolute/Weld/Distance). Main demo now imports scenes,
         drives the optional per-scene update hook once per fixed step (before phys.step), and
         picks scenes via a scrollable category-grouped list (beginChild + per-category separator
         + u.selectable highlighting current). world_capacity 1024->2048. Ported 32 wave-1 scenes
         faithful to the box2d sources: Stacking(Single Box, Vertical/Tilted/Circle/Capsule Stack,
         Confined, Double Domino, Pyramid), Bodies(Body Type, Sleep, Weeble), Continuous(Drop,
         Skinny Box, Bounce House, Wedge -- all motion_quality=.linear_cast bullets), Shapes
         (Friction, Restitution, Rounded, Ellipse=capsule, Compound, Offset, Rolling Resistance,
         Conveyor=tangent_speed, Explosion=world.explode on build, Wind=update-hook applying
         applyForceToCenter over world.active.items via pack handles), Joints(Revolute motor,
         Bridge, Ball & Chain, Cantilever weld, Soft Body=distance-spring ring+spokes), World
         (Tiles), Benchmark(Tumbler=kinematic spinning drum + grains). KEY FACTS: v3.1 joints
         take local_frame_a/b (Transform2); anchor pin = worldToLocal(body, world_anchor) into
         each frame's .p (helpers do this). Segment{point1,point2}. MotionQuality{discrete,
         linear_cast} (linear_cast=bullet/CCD). applyForceToCenter(world, body, force, wake).
         u.beginChild(id, Vec2 size, ChildFlags)/endChild (call endChild only when begin true),
         u.selectable(label, selected, opts), u.collapsingHeader(label, *bool). Lint house-rule
         line-length 120 bit the inline makeOffsetBox createShape one-liners -> added
         attachOffsetBox helper. Built release (assert-on, 1.92MB HTML), full wgpu-check GREEN,
         scenes.zig + main lint+fmt 0. WAVES 2-4 (joints needing frame/axis math, chains, events,
         collision-lab visualizers, benchmark stress) tracked in box2d_samples_plan.md.


<!-- box2d grind zimr354 -->
zimr354  box2d SAMPLE-PORT arc, WAVE 1 (verified green). Surveyed all 137 registered box2d
         samples (14 categories) and wrote src/notes/box2d_samples_plan.md: a full triage into
         4 waves + a skip-tier. Not all 137 are "scenes": ~95 are scene-portable (waves 1-3),
         ~10 are collision-LAB query visualizers (wave 4, a separate non-stepped mode), ~8 are
         bug-repro/determinism harnesses (skip unless a regression needs a visual repro), the
         rest are benchmark stress variants folded into wave 2.
         ARCHITECTURE: examples/wgpu_zimrphysics2d_demo/scenes.zig (805L) owns
         Scene{category, name, build:*const fn(*World)anyerror!void, update:?*const fn(*World)void}
         + `pub const list` registry + Options-struct spawn helpers (Body/Box/Ball/Cap structs;
         addBody returns the handle; attachBox/Circle/Capsule/OffsetBox; groundBox/groundSegment/
         arena; pinRevolute/pinWeld/pinDistance via worldToLocal(world,body,worldAnchor) →
         local_frame). Adding a sample = one build fn + one list entry; renderer/UI/drag handle
         the rest. Main demo wired to scenes.list with a scrollable category-grouped picker
         (beginChild "scene_list" + per-category separator/header + selectable→loadScene) and an
         optional per-frame update hook called inside the accumulator step loop. windUpdate +
         per-body force uses BodyHandle.pack(@intCast(idx),0) over world.active.items.
         WAVE 1 = 32 scenes across 7 categories: Stacking(Single Box, Vertical/Tilted/Circle/
         Capsule Stack, Confined, Double Domino, Pyramid), Bodies(Body Type, Sleep, Weeble),
         Continuous(Drop, Skinny Box, Bounce House, Wedge), Shapes(Friction, Restitution, Rounded,
         Ellipse, Compound, Offset, Rolling Resistance, Conveyor Belt[tangent_speed], Explosion,
         Wind[update-hook]), Joints(Revolute[motor], Bridge, Ball & Chain, Cantilever[weld],
         Soft Body[12-node distance-spring ring + cross-spokes]), World(Tiles), Benchmark(Tumbler
         [kinematic drum, 40 grains]). attachOffsetBox(w,h,hw,hh,center,density) hardcodes
         Rot2.identity (last arg = density). Built -Dmode=release (assert-on, 1.92MB HTML),
         scenes+main+render lint+fmt 0, full wgpu-check GREEN. NEXT: wave 2 (~40 joint/chain/
         stress scenes: prismatic/wheel/distance/motor/door/ragdoll/doohickey/driving, chain
         shapes, arch/cardhouse/cliff, far-world, robustness, benchmark stress), then wave 3
         (12 event-driven, need per-frame event reading), then wave 4 (collision LAB mode).


<!-- box2d grind zimr355 -->
zimr355  box2d sample-port WAVE 2 (verified green): +20 scenes → 52 total in scenes.zig.
         New joint helpers: pinPrismatic(Prism{anchor,axis_angle,motor,speed,force,spring,hertz,
         damping,limit,lo,hi}) and pinWheel(Whl{anchor,axis_angle,hertz,damping,motor,speed,
         torque}) — the joint AXIS is local_frame_a's x-axis (engine: axis=rotateVec2(frame_a.q,
         {1,0})), so axis is set via local_frame.q = Rot2.fromAngle(axis_angle) (0=+X horizontal,
         pi/2=+Y vertical); anchors are on unrotated bodies so world==local axis. attachHull(pts,
         density) = computeHull→makePolygon(hull,0) for arch voussoirs. File-scope `const pi =
         zm.pi;` (comptime_float; do NOT name a local 'pi' — reserved-math-names lint; bind zm.pi).
         NEW SCENES — Joints: Wheel(suspension), Prismatic(powered vertical lift w/ limit; motor
         drives to limit & stops since no runtime motor setter), Distance Joint(spring pendulum),
         Motor Joint(angular-motor + linear-spring held box), Door(revolute+limit, ball swings it),
         Ragdoll(capsule torso/head/arms/legs via revolute+limits), Doohickey(motorised crank→rod→
         prismatic slider mechanism), Driving(car: chassis + 2 wheel joints, back wheel motor
         speed=12; constant-motor approximation, no input). Shapes: Chain Shape (buildChainTerrain:
         25-pt sine static chain via createChain{points,is_loop=false}; balls/boxes drop on it).
         Continuous: Chain Drop (bullet box onto chain terrain). Stacking: Arch (11 interlocking
         hull voussoirs, ri=4 ro=5.4 semicircle), Card House (5 leaning tents + flat roofs), Cliff
         (mesa offset-box ledge + teetering boxes/capsule). Bodies: Pivot (revolute arm + weld
         weight tips), Kinematic (oscillating platform; kinematicUpdate hook reverses vx at ±6 by
         scanning active.items for motion_type==.kinematic and writing world.motion[idx].
         linear_velocity), Set Velocity (6 launched projectiles). Benchmark: Spinner (kinematic
         cross w=6 in arena, 120 grains), Large Pyramid (24 rows=300 boxes), Joint Grid (14x10
         distance-joint net pinned to ground = hanging mesh), Many Tumblers (3 kinematic drums).
         VERIFY NOTES for device check: chain terrain winding is left→right (if bodies fall
         through, reverse points); Driving wheel motor sign may need flip if it drives left.
         Built -Dmode=release (1.95MB), scenes lint+fmt 0, full wgpu-check GREEN. NEXT: wave 3
         (12 event-driven: contact/sensor/platformer — need a per-frame event-reading helper),
         then wave 4 (collision LAB: ray/shape cast, manifold, TOI, convex hull — separate
         non-stepped query-visualizer mode w/ custom drawing).


<!-- box2d grind zimr356 -->
zimr356  zimrphysics2d demo scene-picker REDESIGN for mobile. The 52-scene picker was a
         fixed-height beginChild("scene_list",{0,220}) scroll region — on a phone only the first
         category (Stacking) showed and the nested touch-scroll was undiscoverable. Replaced with
         TWO COMBOS: u.combo("category", &cat_i:i32, &scenes.categories, .{}) then u.combo("scene",
         &local_sel, names[0..count], .{}) listing only the active category's scenes. Any of the
         52 is two taps (combo popups are natively scrollable). scenes.zig gained: `pub const
         categories` (comptime-derived unique category names in list order, via std.mem.eql dedupe;
         needs std import + @setEvalBranchQuota), categoryIndex(name)usize, firstInCategory(cat)usize.
         State got cat_index; loadScene syncs it (categoryIndex of loaded scene) so the picker
         follows the running scene; changing the category combo loadScene(firstInCategory). Each
         frame the scene combo is rebuilt into stack buffers names[40]/globals[40] mapping local
         combo index→global scene index. Window shrank 280x480→260x300. combo sig: combo(label,
         current_index:*i32, items:[]const []const u8, opts)bool. lint+fmt 0, wgpu-check GREEN,
         release HTML 1.94MB. (Engine unchanged; pure UI.)


<!-- box2d grind zimr357 -->
zimr357  Added wgpu_zimrphysics2d_demo to the wgpu_launcher flagship roster, right after the
         Jolt 3D physics demo. TWO lists must stay in sync: (1) build.zig launcher block
         `const flagships = [_][]const u8{...}` (added "zimrphysics2d_demo" after "zimrphysics_demo")
         — each fname gets launcher_mod.addImport("ex_"++fname, app_mods.get(fname).?); app_mods is
         populated by the main example loop (app_mods.put(wgpu_app.name, m)) so the already-registered
         zimrphysics2d_demo example is available. (2) examples/wgpu_launcher/wgpu_launcher.zig
         `const flagships = [_]z.AppVtable{...}` (added z.eraseApp(@import("ex_zimrphysics2d_demo").app)
         after ex_zimrphysics_demo); source array ORDER = switch order. Multi-file example modules
         (main+render+scenes) resolve sibling @imports + @embedFile fine when imported as a module.
         The 2D demo uses depth_format=null (no depth buffer) and hosts fine as a launcher child.
         Built wgpu-launcher-standalone -Dmode=release (8.6MB bundle, all flagships), full wgpu-check
         GREEN. Launcher step names: wgpu-launcher / wgpu-launcher-standalone.


<!-- box2d grind zimr358 -->
zimr358  box2d sample-port WAVE 3 (events, verified green): +6 scenes → 58 total, new "Events"
         category. All reaction-based via the Scene.update(*World) hook reading the engine event
         streams (no custom draw needed; engine debug-draw + the contacts toggle visualise). API:
         getContactEvents(world)ContactEvents{begin:[]ContactBeginTouchEvent{shape_a,shape_b,
         contact_id}, end:[]…, hit:[]ContactHitEvent{…,point:Vec2,normal:Vec2,approach_speed:f32}};
         getSensorEvents(world)SensorEvents{begin/end:[]SensorBeginTouchEvent{sensor_shape,
         visitor_shape}}; getBodyEvents(world)[]BodyMoveEvent{transform,body:BodyIndex,user_data,
         fell_asleep}. Map a ShapeIndex→body via world.shapes.data[shape].body; act with
         applyLinearImpulseToCenter/applyForceToCenter/setTransform/setLinearVelocity using
         BodyHandle.pack(@intCast(idx),0). Hit events require ShapeDef.enable_hit_events=true
         (added `hit_events` flag to Box/Ball helpers); sensors need is_sensor=true (added
         attachSensorCircle/attachSensorBox; new bodyHandleOf/shapeBodyIndex helpers). Update hook
         runs BEFORE step so it reads the prior step's events (1-frame latency, fine). gravity_scale
         is per-body in world.motion[idx].gravity_scale (writable). SCENES — Circle Impulse (hit
         events kick bodies apart along normal when approach_speed>3, popcorn), Contact (pinball
         bumpers: contact-begin between a dynamic ball and a static bumper/wall impulses the ball
         away), Foot Sensor (capsule + foot sensor circle; sensor-begin vs ground → hop impulse,
         perpetual hoppers), Sensor Funnel (bottom sensor pad launches visitors up → fountain),
         Sensor Bookend (mid sensor box flips gravity_scale to -0.4 on begin, restores 1.0 on end →
         levitation chamber; demos begin+end), Body Move (no floor; reads body-move events and
         recycles any body below y=-14 back to y=14 via setTransform — perpetual rain over two
         static ledges). DEFERRED from wave 3: Platformer (one-way platforms need a pre-solve
         callback — enable_pre_solve flag exists on ShapeDef but no pub pre-solve setter surfaced),
         Joint/Breakable events (JointEvent{joint:u32,user_data} exists but destroyJoint is private
         — can't break a single joint; would need a pub joint-destroy). Built -Dmode=release
         (1.95MB), scenes lint+fmt 0, full wgpu-check GREEN. REMAINING: wave 4 = collision LAB
         (ray/shape cast, manifold, distance, TOI, convex hull) — a separate NON-stepped mode that
         needs draw access in its per-frame fn + an interactive draggable probe; that's an
         architectural addition (the Scene model has no draw context yet).


<!-- box2d grind zimr359 -->
zimr359  box2d sample-port WAVE 4 = collision LAB (verified green): +4 scenes → 62 total, new
         "Lab" category. ARCHITECTURE: gave Scene an optional `lab: ?*const fn(*render.LabCtx) void`.
         When set, the demo still builds the (static) geometry and draws it, then after the world
         draw calls lab(ctx) with the pointer as a draggable probe — no extra stepping needed since
         queries run off the broad-phase proxies built at createShape. render.zig gained
         LabCtx{world, dl:ui.DrawListHandle, cam:Camera2D, pointer:Vec2, pointer_down:bool, time:f32}
         with WORLD-coord draw helpers: line/mark(filled dot, px radius)/ring(world radius)/rect/
         arrow(with head). NOTE: method named `mark` not `dot` (dot is a reserved-math-name → zm.dot).
         main: State.time accumulates f.time.delta_time only in lab scenes; lab call sits after the
         debugDraw + drag-leash, before the control window; hint text switches to "Move the pointer
         to probe." SCENES (build=labObstacles: static box/box/circle/h-capsule spread out; Convex
         Hull uses labEmpty): Ray Cast (castRayClosest(world,origin,dir,.{})?RayResult{fraction,
         point,normal,shape}; draw ray to hit, faded remainder, hit dot, green normal arrow),
         Shape Cast (castShapeClosest(world,origin,proxy,dir,.{})?CastResult; proxy=makeProxy(
         &.{{0,0}}, r=0.6); draw start ring(dim) + swept ring at origin+dir*fraction + hit + normal),
         Overlap (overlapAabb a 2m box at pointer; callback marks each hit body center red; draw the
         query rect), Convex Hull (11 time-orbiting points + the pointer → computeHull(&pts)Hull{
         points:[8]Vec2,count}; draw input points dim, hull edges green, hull verts amber). Query API
         all pub: castRayClosest/castShapeClosest/overlapAabb/shapeDistance/shapeCast/collideShapes/
         makeProxy/computeHull. FURTHER LAB (not done): Distance (shapeDistance needs DistanceInput+
         SimplexCache), Manifold (collidePolygons→LocalManifold point struct), Mover (character).
         Also DISCOVERED runtime joint setters DO exist per-type (distanceSetLength/SetMotorSpeed/
         EnableSpring/... at ~10914+) — so interactive distance joints are possible; still no generic
         revolute/prismatic/wheel motor setter seen (re the Driving/Platformer input gaps). Built
         -Dmode=release (1.96MB), all 3 demo files lint+fmt 0, full wgpu-check GREEN. The 4-wave
         box2d sample-port arc is COMPLETE: 62 scenes across Stacking/Bodies/Continuous/Shapes/
         Joints/World/Benchmark/Events/Lab, with drag + a two-combo mobile picker. Launcher (zimr357)
         will bundle all 62 on its next rebuild.


<!-- box2d grind zimr367 -->
zimr367  NEW EXAMPLE — wgpu_physics_sidebyside (the harmonization payoff, made visible).
         examples/wgpu_physics_sidebyside/wgpu_physics_sidebyside.zig: two worlds side by side, a 2D
         (zimrphysics2d / Box2D port, drawn flat at z=0 on the LEFT) and a 3D (zimrphysics / Jolt port,
         RIGHT), each dropping 10 boxes that fall and pile on a static ground. Both rendered as cubes
         through ONE shared 3D camera (2D constrained to z=0). Registered in build.zig example list as
         "physics_sidebyside"; standalone target wgpu-physics-sidebyside-standalone (HTML ~1.68MB).
         The whole point: the setup + step + render code reads near-identically across engines —
           setup: createBody(world, .{ .motion_type, .position }) is IDENTICAL; only the shape model
                  differs (2D createShape(world, body, .{.geom=.{.polygon=makeBox(h,h)}}) vs 3D
                  shapes.add(.{.box=..}) + .shape in the BodyDef) — exactly how each upstream lib works.
           step:  p2.step(&w2, dt) / p3.step(&w3, dt) — identical.
           render: identical loop shape (getPosition, getRotation, drawCube); only the inherent 2D/3D
                  diff remains (Vec2+Rot2->rotationZ(angle) vs Vec+Quat->matFromQuat).
         To make the render loops parallel, added getPosition/getRotation FREE FNS to 3D (mirroring 2D's;
         return Vec/Quat vs 2D's Vec2/Rot2) reading com_pos/.rot — cold read-only API; bodies.data stays
         the internal hot-path access. A genuine small parity gain beyond the demo.
         VERIFIED: standalone builds clean, full wgpu-check GREEN. NOT visually verified here (no GPU) —
         needs Simon's device screenshot to confirm framing + that both piles settle equivalently. Camera
         vec(0,4,30)->(0,-1,0) fovy42; piles at x=+-6; tune if framing is off. Note: 2D boxes drawn as
         full cubes (not flattened) to maximize visual match; could thin-z them to read as literal squares
         if Simon prefers. Gravity set to -10 on both (2D default already -10; overrode 3D's -9.81).


<!-- box2d grind zimr368 -->
zimr368  side-by-side REWORK per Simon: 2D drawn like a 2D game + Reset button.
         examples/wgpu_physics_sidebyside — the 2D half is no longer cubes-in-a-3D-camera. It now
         renders NATIVELY: an orthographic, screen-space pass of flat filled rotated quads into the
         UI background DrawList (left half), exactly how a 2D game draws. The 3D half renders in
         perspective as cubes, scoped to the RIGHT half via pushViewport/popViewport(f, Placement{
         .rect=right-half, .logical_w/h}). An opaque slate panel fills the left half first (masks any
         3D that bleeds past the viewport edge), then the 2D ground rect + box quads + a divider line.
         Local minimal Camera2D{target,ppm,cx,cy}.toScreen centres the 2D scene at (W/4, H/2); ppm
         auto-fits. corner2d() rotates each local box corner by the body's Rot2 and projects to screen.
         RESET BUTTON: a small UI window ("controls", top-centre) with u.button("Reset both") that calls
         resetWorlds(s) — deinit both worlds, re-init, re-run setup2d/setup3d (refreshing the stored
         handle arrays). Needed State to carry gpa + a UiHost; font via @embedFile("roboto_mono_ttf")
         (already wired into the shared user_mod in build.zig — no new build wiring) + z.loadFont +
         z.UiHost.init/begin/render. The parallel SETUP + STEP code is unchanged from zimr367 (still the
         point of the demo); only rendering + the reset control are new.
         Render loops still mirror: both do getPosition/getRotation then draw — 2D as a screen quad,
         3D as a cube. HTML ~2.23MB (font + UI now linked). VERIFIED: standalone clean, full wgpu-check
         GREEN. NOT visually verified here (no GPU). Needs Simon's screenshot to confirm: 2D scene fits
         the left half (ppm), 3D undistorted in the right viewport, divider + reset window placement,
         and that pushViewport actually clips the 3D to the right (panel masks it either way). Tunables:
         cam vec(0,4,26)->(0,-1,0) fovy45; window initial_pos {W/2-82,10}; ppm = min((W/2)/11, H/9).


<!-- box2d grind zimr369 -->
zimr369  side-by-side: centre the 3D scene in the right half (Simon: it was hard against the divider).
         Root cause: the framework has NO GPU sub-rect viewport (only setScissorRect). pushViewport sets
         a scissor + a 2D modelview, but beginMode3D builds a SYMMETRIC perspectiveFovRh and centres
         world-origin on the FULL screen (= the divider), then the scissor merely clips — so the 3D pile
         sat at the left edge of the right half, at the wrong (full-screen) aspect. RTT (beginTextureMode,
         what wgpu_split_screen uses) sets app.target_size for aspect but is heavier.
         FIX (deterministic, no RTT, no guessing): drop pushViewport for the 3D; build the view-projection
         by hand and post-multiply a clip-space shift S into the right half, then feed beginMode3DMatrix:
           proj  = perspectiveFovRh(fovy, (W/2)/H, .01, 1000)   // half-width aspect => undistorted
           S     = Mat{ (0.5,0,0,0),(0,1,0,0),(0,0,1,0),(0.5,0,0,1) }  // x' = 0.5x + 0.5w
           vp    = S * proj * view ;  z.beginMode3DMatrix(gl, vp)
         S maps NDC x [-1,1] -> [0,1] (screen [W/2,W]); world-origin -> 0.5w -> screen x=0.75 = centre of
         the right half. The grid that now bleeds into the left half is covered by the opaque 2D panel
         (already proven to composite over the 3D) + the divider line. Camera pulled to vec(0,4,22) for the
         narrower aspect. Helpers all pub/reachable: z.beginMode3DMatrix, zm.{perspectiveFovRh,mulMat,vec4,Mat}.
         Lint gotcha hit + fixed: std.math is BANNED outside zimrmath (new rule: [std-math], GPU-portability,
         no lint:off). Used zm.pi via a file-scope `const pi = zm.pi;` (file-scope bind is fine; only LOCALS
         named pi are reserved). VERIFIED on device (Simon screenshot, prior turn) that 2D-native + reset +
         divider + panel all read correctly; this turn's centering is build/gate-green but NOT yet
         screenshot-verified — camera framing may want a final nudge.


<!-- box2d grind zimr370 -->
zimr370  box2d sample coverage push (Simon: "we want ALL box2d samples present"). Re-diffed our
         scenes vs the real box2d-main source (137 RegisterSample calls). STATUS: 59 live -> now 61.
         Of 83 missing diff-entries: 4 already present under our "Lab" category (Ray Cast/Shape Cast/
         Overlap World/Convex Hull = naming only), 9 need ENGINE WORK (Character|Mover, Joints|User
         Constraint, Determinism|SnapShot, Collision|{Cast World,Dynamic Tree,Manifold,Smooth Manifold,
         Time of Impact,Shape Distance}), the remaining ~70 are pure porting work with EXISTING engine
         features (re-audited: setFilter/Friction/Restitution, setBodyType, enable/disableBody,
         destroyBody/Shape, createChain, applyForce, explode, full event API, all 6 joints). Only real
         fidelity gap: no runtime motor-speed/target setter (motors set at creation). Wave order B1..B7
         recorded in box2d_samples_plan.md.
         THIS TURN (B1 start): ported Shapes|"Box Restitution" (two rows of boxes, restitution 0->1) and
         Shapes|"Filter" (left column shares a category + masks only ground => falls through itself; right
         column distinct categories => collide+stack). Added `filter: phys.Filter = .{}` to the Box options
         struct + passed it through attachBox (broadly useful for future filter samples). Lint clean, 2D
         standalone builds, full wgpu-check GREEN. NOT visually verified (Simon screenshot).
         DEFERRED in B1 (need touches): Custom Filter (custom pair-filter callback=engine), Tangent Speed
         (curved chain-conveyor=chain batch), Modify Geometry + Recreate Static (need a per-scene STATE slot
         — Scene.update is currently fn(*World)void stateless; adding state is a small infra step that also
         unblocks several Events/Continuous interactive samples), Chain Link/Segment (chain shapes).
         DECISIONS PENDING FOR SIMON: (1) the 9 engine-work items — do them or mark explicitly skipped?
         (2) add a per-scene mutable state slot to Scene (unblocks ~modify/recreate/interactive scenes)?
         Marathon: ~68 scenes remain across B1-tail..B7; will go category-by-category, each screenshot-verified.


<!-- box2d grind zimr371 -->
zimr371  box2d coverage B2 (Robustness) + per-scene CAMERA infra. Count 64 -> 69 scenes.
         (Note: my prior single-line grep UNDERCOUNTED ours — multi-line list entries were missed; the
         real base was 62 not 59, so the true "missing" is ~80 and a few diff-"missing" are actually
         present. Re-diff later with an entry-aware extractor.)
         INFRA: added per-scene camera framing. scenes.zig Scene now has `cam: ?CamHint` (CamHint{target:
         Vec2={0,4.5}, ppm:f32=34}); loadScene applies it after build, resetting to the demo default when
         null (backward-compatible — all 64 existing scenes unchanged). This was REQUIRED: every box2d
         sample sets its own camera.center+zoom, and large/tiny-scale scenes are invisible in our one
         fixed view. Mapping used: ppm ~= 300 / box2d_zoom (900x600 window).
         PORTED (Robustness, 5): HighMassRatio1 (3 unit-box pyramids each capped by a heavy density-100/
         200/300 box), HighMassRatio2 (20x20 box on two 1x1 boxes), HighMassRatio3 (20x20 box on two
         triangles via attachHull+computeHull/makePolygon), Overlap Recovery (4-row pyramid, boxes 25%
         overlapped, solver separates), Tiny Pyramid (30-row pyramid of 2.5cm squares, cam ppm=190 to see
         it). Each carries a cam hint. Lint clean, 2D standalone builds, full wgpu-check GREEN.
         DEFERRED: Robustness Cart + Multiple Prismatic (joints -> B4). World Far Pyramid/Gate/Ragdolls
         (origin at 1e6-1e7; need to confirm the f32 engine tolerates far-from-origin coords first — if not,
         port at a reduced offset or mark as engine-limited). NOT visually verified (Simon screenshot);
         the cam ppm/target values are estimates and may want nudging, esp. Tiny Pyramid + HighMassRatio.
         Still-open infra decision (unchanged): a per-scene STATE slot would unblock Modify Geometry/
         Recreate Static + interactive Events/Continuous. Next batches: B2-tail (Stacking Arch/CardHouse/
         Cliff), B3 Bodies+Continuous, B4 Joints, B5 Events, B6 Benchmark+Issues.


<!-- box2d grind zimr372 -->
zimr372  2D demo UX: global Prev/Next scene buttons (Simon: hard to flip through examples quickly).
         Added a "Scene i/N" counter + "< Prev" / "Next >" buttons (sameLine row) at the top of the
         control window. They step s.current_scene through the GLOBAL scenes.list with wraparound;
         loadScene already resets s.cat_index from the new scene's category, so categories switch
         automatically and the category/scene combos follow. The per-category combos remain for direct
         jumps. Walk order = scenes.list order (roughly category-grouped). Lint clean, 2D standalone
         builds, full wgpu-check GREEN. (Pure 2D-demo UI change; no engine/scene-content change.)


<!-- box2d grind zimr373 -->
zimr373  box2d coverage B3 (Bodies, 3). Count 69 -> 72. (Accurate re-diff this turn: 69 base /
         73 missing; Stacking fully done.)
         PORTED: Bodies|Bad (zero-density dynamic capsule = no mass, behaves kinematic; beside a normal
         capsule on a segment; omitted the per-step "for science" upward force = needs stateful hook),
         Bodies|Mixed Locks (static + free boxes + boxes with angular-z / linear-x / lin-y+ang-z / fully
         locked dofs), Bodies|Wake Touching (10 boxes settle on a segment and sleep).
         HELPER: added lock_x/lock_y/lock_rot bools to the Body options struct; addBody maps them to
         BodyDef.allowed_dofs.{translation_x,translation_y,rotation_z}=!lock (the engine stores locks in a
         BodyFlags packed struct; the public knob is allowed_dofs, NOT lock_linear_* — first compile tried
         the wrong field). Each scene carries a cam hint. Lint clean, 2D standalone builds, wgpu-check GREEN.
         NOT visually verified. Next: B3-tail Continuous(10) — mostly fast-body CCD / speculative-contact
         world setups; then B4 Joints, B5 Events, B6 Benchmark+Issues. Still deferred: World Far* (far-origin
         f32), Robustness Cart/Multiple Prismatic (joints), and the 9 engine-work items.


<!-- box2d grind zimr374 -->
zimr374  box2d coverage: Continuous CCD cluster (5). Count 72 -> 77.
         PORTED: Speculative Fallback (fast skinny box at -100 m/s onto a polygon ledge, box offset -8 from
         its body origin via attachHull), Speculative Sliver (thin triangle at -100 onto a segment),
         Speculative Ghost (small square skims a ledge, gravity off, v=0.1*1.25*60), Pixel Imperfect
         (rounded ball descends gravity-off onto a static block, lock_rot), Restitution Threshold (set
         world.settings.restitution_threshold=0.1 in the build fn; slow restitution-1 ball on a 70deg-tilted
         block barely bounces). All bodies left NON-bullet on purpose — these test box2d speculative contacts,
         not CCD bullets; relies on our v3 speculative-contact path (Skinny Box/Drop already prove it works).
         Used existing attachHull/attachCircle + the new lock_rot + round-box. Each carries a cam hint
         (ppm ~= 300/box2d_zoom). Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Remaining Continuous (5): Bounce Humans (ragdolls), Chain Slide, Segment Slide, Ghost Bumps, Pinball.
         Then B4 Joints, B5 Events, B6 Benchmark+Issues. Still deferred: World Far*, Robustness Cart/MultiPrismatic,
         9 engine-work items.


<!-- box2d grind zimr375 -->
zimr375  box2d coverage: Continuous slide tests (2). Count 77 -> 79.
         PORTED: Chain Slide (fast r=0.5 circle at 100 m/s sliding inside an 80-point closed chain LOOP
         built in 4 edge-loops; createChain(.{.points,.is_loop=true})), Segment Slide (circle on a 2-segment
         ground: horizontal floor + vertical wall via inline createShape segment geoms, slams the wall).
         Continuous now 7/10 done. Deferred (3): Bounce Humans (needs a reusable makeRagdoll(world,pos)
         helper factored out of jointRagdoll + a timed spawner = the per-scene STATE slot), Ghost Bumps
         (interactive shape-type/round/bevel toggles + destroyBody rebuild), Pinball (flippers = revolute
         motors + plunger). Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Next: B4 Joints (9 missing — several clean creation-time-motor scenes). The per-scene STATE slot
         keeps coming up (Bounce Humans, Modify Geometry, Recreate Static, interactive Events) — worth doing
         before the interactive batches.


<!-- box2d grind zimr376 -->
zimr376  box2d coverage: Joints batch start (2). Count 79 -> 81.
         PORTED: Joints|Filter Joint (createFilterJoint(world,.{.body_a,.body_b}) disables collision between
         two boxes so they overlap while resting on the ground), Joints|Top Down Friction (gravity-off arena
         of 4 segments + 10x10 grid of mixed shapes (capsule/circle/square/rounded), restitution 0.8, each
         body tied to the static frame by a MotorJoint with max_velocity_force/torque=10 => top-down friction).
         HELPER: added restitution to the Cap (capsule) options struct + attachCapsule material.
         Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Joints remaining: Motion Locks + Separation (multi-joint galleries — stateless but large, next),
         Scissor Lift (prismatic+motor), Scale Ragdoll (needs a makeRagdoll helper). BLOCKED: Gear Lift (2D
         engine has no gear joint — revolute/prismatic/wheel/distance/weld/motor only), Breakable (needs the
         state slot + joint-force check), User Constraint (custom constraint callback = engine work).
         The per-scene STATE slot + a makeRagdoll(world,pos,scale) helper are now the two biggest unlockers
         (Breakable, Scale Ragdoll, Bounce Humans, Modify Geometry, Recreate Static, interactive Events).


<!-- box2d grind zimr377 -->
zimr377  PER-SCENE STATE SLOT infra + Recreate Static + feature-completeness audit. Count 81 -> 82.
         INFRA: Scene gained build_s/update_s (stateful hooks) alongside build/update; build is now
         optional (exactly one of build/build_s). New SceneState{ body[4]:BodyHandle, joint[4]:JointHandle,
         u[4]:u32, f[4]:f32 } lives in the demo State, reset to .{} on every loadScene; update_s runs each
         FIXED step before phys.step. Demo dispatch wired at loadScene + initState (scene 0 stateless via
         build.?) + the fixed-step loop. (Also: const sc needed a type annotation for the untyped-local lint.)
         PORTED (proof): Shapes|Recreate Static (dynamic 1x1 box; each step destroyBody(old ground) then
         recreate a static segment (-10,0)-(10,0) ground, handle stashed in st.body[0], st.u[0] as the
         "exists" flag). Lint clean, 2D standalone builds (1.99MB), wgpu-check GREEN.
         AUDIT: fixed the scene-diff extractor (entries are a MIX of single-line and multi-line struct
         literals; the old regex required a newline between .category and .name and undercounted). Accurate
         status now: 82 ported / 60 remaining. Wrote a FEATURE-COMPLETENESS section in box2d_samples_plan.md
         splitting the 60 into Bucket A (~28 portable now: Benchmark 15, Issues 6, Events 6, Falling Hinges,
         Joints galleries, Bounce Humans) and Bucket B (9 ENGINE features blocking ~18: gear joint, user
         constraint, character/mover, world serialize, collision queries+lab, runtime geom setters + custom
         filter, far-origin). Bucket B needs 2D-solver work + Simon's visual verification (wgpu-check does
         not cover 2D-engine correctness) so each is flagged rather than ported blind.
         NEXT: blast Bucket A (Benchmark + Issues + Events), add makeRagdoll helper, then bring Bucket B
         engine items to Simon for prioritisation.


<!-- box2d grind zimr377 -->
zimr377  box2d coverage: ragdoll infra + 2 scenes. Count 82 -> 84. (state slot already landed +
         Shapes|Recreate Static already ported in a prior increment, taking 81->82.)
         HELPER: makeRagdoll(world, cx, cy, scale) factored out of jointRagdoll (torso/head/2 arms/2 legs
         joined by limited revolute joints, all offsets * scale). jointRagdoll now just calls it.
         PORTED: Joints|Scale Ragdoll (a row of the SAME ragdoll at scales 0.5/1.0/1.5/2.0 -> scale-invariant
         joints; box2d's version is one human + a live slider, which we render as the static row), and
         Continuous|Bounce Humans (build_s/update_s: a bouncy box arena + restitution-2 centre circle;
         update spawns one ragdoll every 2s up to 5 via makeRagdoll, and sweeps world.settings.gravity =
         (10*sin(0.5t), 10*cos(t)) so they tumble around the compass; @sin/@cos builtins, not std.math).
         Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Continuous now 8/10 (left: Ghost Bumps=interactive, Pinball=flippers). Joints 3/9.
         Two unlockers now both LIVE: per-scene state slot (build_s/update_s/SceneState{body,joint,u,f})
         and makeRagdoll. Next: Breakable (state slot + getConstraintForce -> destroy joint over threshold),
         then the Joints galleries (Motion Locks, Separation) and Scissor Lift. Still engine-blocked: Gear
         Lift (no gear joint), User Constraint (custom callback), + the Collision-query lab samples.


<!-- box2d grind zimr378 -->
zimr378  box2d coverage + ENGINE API: public destroyJoint + Joints|Breakable. Count 84 -> 85.
         ENGINE (src/zimrphysics2d.zig): added pub destroyJoint(world, JointHandle) (wakes both bodies,
         then frees the slot) -- box2d b2DestroyJoint parity. Renamed the existing internal u32 helper to
         destroyJointInternal (matching its own doc comment) + updated its one caller in destroyBody.
         PORTED: Joints|Breakable (build_s/update_s). Four boxes of increasing density (2/6/12/20) pinned
         to a static floor body by revolute joints; update reads getConstraintForce per joint (~ the weight
         held) and calls destroyJoint once |force|^2 > threshold^2 (threshold 80 in st.f[0], broken flag in
         st.u[i]) -- so the two heavy boxes break free and fall while the two light ones keep hanging.
         (box2d's Breakable cycles joint types behind a live force slider + drag; we show the force-threshold
         behaviour statically, which our no-drag/no-slider demo can render.) Lint clean (both files), 2D
         standalone builds, wgpu-check GREEN (engine change, no regressions). NOT visually verified.
         Joints now 4/9. Next: Motion Locks + Separation (multi-joint galleries), Scissor Lift. Still
         engine-blocked: Gear Lift (no gear joint), User Constraint (custom callback).


<!-- box2d grind zimr379 -->
zimr379  box2d coverage: Joints galleries (2). Count 85 -> 87.
         PORTED: Joints|Motion Locks (gallery of SIX rotation-locked 1x1 boxes, one per joint type:
         distance/motor/prismatic/revolute/weld/wheel, spaced 5 apart from x=-12.5; shows each joint holding
         an angular-locked body) and Joints|Separation (FIVE unlocked boxes spaced 10 apart over a segment
         floor: distance/prismatic/revolute/weld/wheel). Both use the existing pin* helpers + createMotorJoint;
         the interactive bits in box2d (live lock toggles, impulse-to-stress-separation) are rendered as the
         static configuration. Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Joints now 6/9. Remaining Joints: Scissor Lift (prismatic+motor scissor mechanism, next), and the
         two engine-blocked ones: Gear Lift (no gear joint in the 2D engine) + User Constraint (custom
         constraint callback). After Scissor Lift, the open fronts are: Benchmark (15, spawn-N stress),
         Issues (6 bug-repros), Events (6, via the event API), World (3 far-origin), Collision lab samples
         (6, need the lab query+draw hook wired), Shapes (chains/tangent-speed/custom-filter), Determinism,
         Character|Mover. The one remaining JOINT-TYPE gap for full box2d parity is the gear joint.


<!-- box2d grind zimr380 -->
zimr380  box2d coverage: Joints|Scissor Lift (the intricate one). Count 87 -> 88.
         PORTED: Joints|Scissor Lift -- 3 stacked levels of crossed capsule links (capsule half_len 2.5
         r 0.15, rotated +/-0.15), pinned per level with stiff revolute joints (constraint_hertz=240,
         constraint_damping_ratio=20) at base/right/middle, with a no-spring WHEEL joint on the right of
         level 0 (and on the platform's right) so the X can splay horizontally; base1/base2 + anchors swap
         each level (the scissor crossing). Topped by a 6x0.4 platform (revolute left + wheel right). A
         sprung distance-joint strut (ground (-2.5,0.2) -> mid link (0.5,0), spring on, limit 0.2..5.5)
         holds it up. Set world.settings.sub_step_count = 8 in build (box2d uses 8 here for the stiff
         joints; persists only for this scene since loadScene rebuilds the world). Used DIRECT
         create{Revolute,Wheel,Distance}Joint calls with BODY-LOCAL frames (not the worldToLocal pin
         helpers) since box2d anchors at capsule endpoints in local space. Skipped box2d's live motor on the
         strut + the car spawned on the platform. Lint clean, 2D standalone builds, wgpu-check GREEN.
         !! NOT visually verified and STRUCTURALLY COMPLEX -- if it jitters/collapses/explodes on device,
         the likely culprits are the strut (default length=1 may rest too low/high; try setting .length) or
         the stiff constraint_hertz vs our substeps. Flag for Simon's screenshot check.
         Joints now 7/9. ONLY engine-blocked ones left: Gear Lift (no gear joint), User Constraint (custom
         constraint callback). Next open fronts: Events (event API), Benchmark (spawn-N), Issues (repros),
         World (far-origin), Collision lab samples (wire the lab hook), Shapes (chains/tangent/custom-filter).


<!-- box2d grind zimr381 -->
zimr381  box2d coverage: Benchmark batch start (2). Count 88 -> 90. (Scissor Lift device-verified by
         Simon this session -- renders as a proper stable scissor, screenshot confirmed.)
         PORTED: Benchmark|Smash (gravity off; a heavy 8x8 box density 8 at (-20,0) moving +40 m/s, bullet,
         plows through a wall of 40x30 small squares starting at x=30 -- box2d uses 120x80, reduced for the
         phone) and Benchmark|Junkyard (build_s/update_s: a box-walled bucket (81 floor + 30+30 wall offset
         boxes on one static body), ~480 small Fibonacci-pentagon hulls raining in, and a KINEMATIC pusher
         box swept side to side by setting its linear velocity each frame to 6*cos(0.2t) (= position 30*sin)
         -- box2d rains ~8000 + sweeps 60, reduced/retuned for the phone). Confirmed kinematic bodies
         integrate position from user-set velocity in our engine. Lint clean (note: renamed a local from
         phi -> golden, phi is a reserved-math-name), 2D standalone builds, wgpu-check GREEN. NOT visually
         verified. Benchmark now 2/15. Remaining Benchmark: Barrel/Barrel2.4, Capacity, Cast (query),
         Compounds/Large Compounds (compound bodies, ~3000), CreateDestroy (state), Kinematic, Rain (state),
         Sensor, Shape Distance (query), Sleep, Washer. Other open fronts: Events (6), Collision lab (9),
         Issues (6), Shapes (5), World (3 far-origin), Determinism (2), Robustness (2). Engine-blocked still:
         Joints Gear Lift + User Constraint, Character Mover, collision-query (Cast/Shape Distance/etc).


<!-- box2d grind zimr382 -->
zimr382  box2d coverage: Benchmark spawn tests (2). Count 90 -> 92.
         PORTED: Benchmark|Sleep (triangular pyramid of 1x1 boxes, base 30 (box2d 100), friction 0.5, on a
         ground box whose top is at y=1; settles and sleeps) and Benchmark|Kinematic (ONE kinematic body =
         a 16x16 grid of 1x1 offset-box shapes spinning at w=1 rad/s via addBody(.{.motion=.kinematic,.w=1});
         broadphase stress). Both reduced for the phone. Lint clean, 2D standalone builds, wgpu-check GREEN.
         NOT visually verified. Benchmark now 4/15. Remaining Benchmark: Barrel/Barrel2.4 (shape-filled
         barrel), Capacity, Cast (query), Compounds/Large Compounds (~3000 two-triangle compounds),
         CreateDestroy (perf-only, low visual value), Rain (timed group spawn = state), Sensor, Shape
         Distance (query), Washer. Next: a couple more Benchmark (Barrel, Rain) or pivot to Events (6).


<!-- box2d grind zimr383 -->
zimr383  box2d coverage: Benchmark Rain + Capacity. Count 92 -> 94. (Launcher standalone rebuilt &
         delivered to Simon this session: wgpu-launcher-standalone -> wgpu_launcher.html, 8.7MB, bundles
         14 flagships incl zimrphysics2d_demo with all scenes.)
         PORTED: Benchmark|Rain (build_s/update_s: ground + ragdolls spawned one every 0.8s up to 8 at
         stepping x via makeRagdoll(scale 0.9), piling up -- box2d rains ~1000 humans through a recycling
         ring buffer; capped for the phone) and Benchmark|Capacity (a 40x25 grid of ~1000 small circles
         dropped into a 3-wall bin -- body-pool capacity; reduced). Lint clean, 2D standalone builds,
         wgpu-check GREEN. NOT visually verified. Benchmark now 6/15. Remaining Benchmark: Barrel/Barrel2.4
         (6 shape-type variants + container, involved), Cast + Shape Distance (need collision-query API),
         Compounds/Large Compounds (~3000 two-triangle compounds), CreateDestroy (perf-only), Sensor, Washer.
         Next open fronts: Events (6; Sensor Types/Hits/Joint/Persistent Contact/Projectile are event-API
         setups, Platformer is interactive), World (3 far-origin), Issues (6 repros), Shapes (5: chains/
         tangent/custom-filter), Determinism (Falling Hinges portable; SnapShot=serialization), Robustness.
         BIGGEST remaining infra lever = the collision-query LAB mode (lab hook exists on Scene): unblocks
         9 Collision + Cast + Shape Distance = ~11 samples. Engine-blocked: Gear Lift, User Constraint, Mover.


<!-- box2d grind zimr384 -->
zimr384  box2d coverage: Collision LAB mode exploited. Count 94 -> 96 scenes; missing 137-diff dropped
         more (4 re-categorised now match box2d). The lab hook (LabCtx: world, dl, cam, pointer, time +
         line/mark/ring/rect/arrow) was already fully wired; the engine already exposes the whole collision
         API (shapeDistance, collidePolygons + all collideX, shapeCast, timeOfImpact, castRayClosest,
         castShapeClosest, collideMover). So:
         RE-CATEGORISED the 4 existing "Lab" scenes to their box2d categories (no behaviour change, the lab
         visualiser keys off the .lab field not the category): Lab|Ray Cast/Shape Cast/Overlap -> Collision|
         Ray Cast/Shape Cast/Overlap World; Lab|Convex Hull -> Geometry|Convex Hull.
         ADDED 2 new lab scenes: Collision|Shape Distance (GJK shapeDistance between a fixed box A and a
         pointer-following box B; draws the two closest points + connecting segment) and Collision|Manifold
         (collidePolygons between fixed box A and a slowly-rotating box B at the pointer; draws manifold
         points + contact normal). Both build=labEmpty, cam target {0,0} ppm 44. Lint clean, gate GREEN.
         NOT visually verified (interactive: needs pointer). Remaining Collision: Cast World (~ Ray Cast vs
         world, easy next), Dynamic Tree (needs broadphase-tree access), Smooth Manifold (collideChainSegment
         AndPolygon), Time of Impact (timeOfImpact). All but Dynamic Tree are now straightforward lab ports.


<!-- box2d grind zimr385 -->
zimr385  box2d coverage: Collision labs finished (3) + engine export. Count 96 -> 99.
         ENGINE: made Sweep2 pub in zimrphysics2d.zig (it is part of the public TOIInput API surface).
         ADDED 3 lab scenes (all interactive, pointer-driven): Collision|Cast World (a rotating 32-ray fan
         from a point cast against the whole world via castRayClosest, each ray stopping at its closest hit;
         build=labObstacles), Collision|Smooth Manifold (collideChainSegmentAndPolygon: a chain segment with
         ghost1/ghost2 vertices vs a rotating box at the pointer; ghost links drawn dim to show the smoothing)
         and Collision|Time of Impact (timeOfImpact: box A sweeps L->R at the pointer height toward a fixed
         box B at origin; draws A start/end dim + A at the impact fraction bright + the TOI point; computed
         A's impact centre by manual lerp since sweepTransform2 lives in zimrmath, not phys, and zm.* is
         lint-banned in fn bodies). Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         Collision now COMPLETE except Dynamic Tree (needs broadphase AABB-tree traversal access -- not
         currently exposed; would need an engine accessor to walk the tree nodes). 38 of 137 remain.


<!-- box2d grind zimr386 -->
zimr386  box2d coverage: Shapes chains + conveyor (3). Count 99 -> 102.
         PORTED: Shapes|Tangent Speed (a flat conveyor belt of 7 segment sections each with an increasing
         surface tangent_speed -10..-70 + a ball per section carried at different speeds; box2d uses an
         SVG-path loop, we use a segmented belt with end walls), Shapes|Chain Segment (a sine-wave smooth
         chain terrain via createChain over 25 pts y=1.5*sin(0.18x) + a rolling ball -- exercises the
         ghost-linked chain so the ball doesn't catch on joins), Shapes|Chain Link (two open chains forming
         a thin channel from the box2d point arrays + a circle/capsule/box dropped in). Lint clean, 2D
         standalone builds, wgpu-check GREEN. NOT visually verified (watch Chain Segment: if the ball falls
         THROUGH the terrain the chain winding/solid-side is flipped -- box2d orders pts x=25->-25).
         Shapes now 2 left: Custom Filter (custom pair-filter callback = engine) + Modify Geometry
         (interactive runtime geom swap + UI). 36 of 137 remain. Next portable: World far-origin (3; verify
         engine large-coord tolerance first), Determinism|Falling Hinges, Robustness (Cart, Multiple
         Prismatic), Events (6), Issues (6). Mover may be portable (collideMover exists).


<!-- box2d grind zimr387 -->
zimr387  box2d coverage: Determinism + Robustness (2). Count 102 -> 104.
         PORTED: Determinism|Falling Hinges (4 columns x 20 small rounded boxes h=0.25 r=0.025, each ODD box
         hinged to the EVEN one below by a limited revolute joint lo=-0.1pi hi=0.2pi, alternating +/-0.1
         start rotation + x-shear offset 0.4h -> leaning columns topple/settle; box2d hashes the result,
         we just show it) and Robustness|Multiple Prismatic (tower of 6 0.5 boxes chained by stiff
         constraint_hertz=240 prismatic joints, localFrameA.p=(0,0.6 top of prev)/B.p=(0,-0.6 bottom),
         default horizontal axis, limit +/-6; direct createPrismaticJoint w/ body-local frames).
         Lint clean, 2D standalone builds, wgpu-check GREEN. NOT visually verified.
         === IMPORTANT ENGINE FINDING: World|Far Pyramid/Far Ragdolls/Far Gate are NOT portable. box2d builds
         them at origin (10e6, 0) and relies on box2d v3 DOUBLE-precision body positions + a delta-space
         contact solver. Our zimrphysics2d uses f32 Vec2/Transform2 and the source explicitly states
         "World-origin shifting is not supported" (line 38). At 1e7 the f32 ULP ~1m -> physics is garbage.
         These 3 are ENGINE-BLOCKED (would need f64 positions or origin-shift = major architecture work).
         34 of 137 remain. Engine-blocked now: World Far*(3, f64), Joints Gear Lift + User Constraint,
         Collision Dynamic Tree, Shapes Custom Filter + Modify Geometry, Determinism SnapShot (serialize),
         Character Mover(?). Portable left: Robustness|Cart (vehicle), Events (6), Issues (6), Benchmark
         leftovers (compounds/sensor/washer), Continuous Ghost Bumps/Pinball.


<!-- box2d grind zimr389 -->
zimr389: Continued the box2d corpus port — 3 scenes (now 109 total, 31 of 137 remaining).
         Benchmark|Compounds: grid of two-triangle compound bodies (left {-1,0/0.5,1/0,2} + right
         {1,0/-0.5,1/0,2} hulls, density1 friction0.5) dropped into a bin. box2d spawns ~3000;
         reduced to 14x14=196 for the phone. New helper benchBin(world,half_w,wall_h) = floor + 2
         walls as 3 offset boxes (box2d's ~280-box bins read identically at 3 boxes, saves pool).
         Benchmark|Barrel: same bin packed with a 14x22 grid of MIXED shapes (circle/capsule/rounded-
         box/wedge by index%4), sizes varied by a cheap deterministic hash01(n)=frac(sin(n*12.9898)*
         43758.5453) since we have no RNG. New file-scope helper hash01 + wedge hull.
         Events|Projectile Event: AUTONOMOUS port (box2d fires on Ctrl+drag) — build_s/update_s in the
         state slot. A bullet circle (r0.25, .bullet) is launched from (-12,11) v=(30,-9) at a stack of
         8 rounded boxes every 160 steps; on its first contact-begin (enable_contact_events defaults ON
         in our ShapeDef) it calls phys.explode(pos, radius1.5, impulse_per_length20) and destroyBody.
         State: u[0]=in-flight flag, u[1]=step counter, body[0]=projectile handle. Exercises bullet +
         contact events + explode + runtime destroy together. NOT visually verified.
         DEFERRED with reasons: Washer (no inner floor, parts churn at ring bottom; needs >3800 squares
         at full scale, weak at reduced scale), Large Compounds (capacity), Sensor Hits/Types + Joint +
         Persistent Contact (Events are visualization-driven — markers/overlays — and update_s has NO
         draw context; Sensor Hits also wants a runtime prismatic-motor-speed setter we don't surface;
         Projectile Event was the one Events scene with a PHYSICAL reaction). Still engine-blocked:
         World Far*(3, f64), Joints Gear Lift(gear joint)+User Constraint(callback), Collision Dynamic
         Tree, Shapes Custom Filter(callback)+Modify Geometry(interactive), Determinism SnapShot(serialize).
         Lint clean, 2D standalone builds x2, wgpu-check GREEN.


<!-- box2d grind zimr407 -->
zimr407: box2d parity — kicked off the "finish feature + sample parity" arc with an audited gap map.
         GAP (recomputed, supersedes the stale "33 of 137" memory): zimr has 115 of box2d's 137 samples
           (the 3 extras are custom Showcase scenes). 25 missing — but auditing the sources reclassified
           most of them away from "easy port". The honest split:
           * SCENE-ONLY, engine already supports, authorable now (passive/observable): Continuous|Ghost Bumps,
             Benchmark|Sensor, Events|Sensor Types, plus benchmark spawn-scenes (Barrel 2.4, CreateDestroy,
             Large Compounds) — ~6-8.
           * GATED ON SCENE INPUT (interactive in box2d; scene update hook is fn(world) with NO keyboard):
             Character|Mover (engine HAS castMover/collideMover/solvePlanes/clipVector — only input is missing!),
             Continuous|Pinball, Robustness|Cart. Events|Joint is effectively here too: zimr fully supports
             joint force/torque thresholds + getJointEvents (solver emits at 9235-9242), but box2d relies on
             MOUSE-yanking bodies to exceed threshold — gravity on a 4kg box (~40N) never hits 20000N, so a
             faithful version needs mouse drag or a procedural-stress adaptation.
           * GATED ON A NEW ENGINE FEATURE (12): World|Far Gate/Pyramid/Ragdolls (box2d v3 LARGE-WORLD mode:
             b2Pos distinct from b2Vec2, threaded through every query/cast/mover as a separate origin — zimr
             has none of it; positions are plain f32 Vec2, so 1e7 offsets would just demo the engine FAILING);
             Issues|Disable (body enable/disable); Shapes|Modify Geometry (set-geometry API); Events|Platformer
             (contact pre-solve); Shapes|Custom Filter (filter callback); Joints|User Constraint (per-step
             callback); Determinism|SnapShot (world serialization); Joints|Gear Lift; Collision|Dynamic Tree
             (BVH walk accessor for debug draw); Events|Persistent Contact.
           TAKEAWAY: "sample parity" is mostly FEATURE parity + a bit of scene-input/event-overlay infra — the
           order Simon named ("feature AND sample parity"). Two cheap infra unlocks would each free several
           scenes: (a) plumb keyboard input into the scene update hook (unlocks Mover/Pinball/Cart and a
           faithful Events|Joint), (b) per-scene draw/text in update for event overlays.
         SHIPPED THIS TURN: Continuous|Ghost Bumps (scenes.zig continuousGhostBumps) — exact 20-pt closed-loop
           chain (is_loop=true) ported point-for-point from box2d, circle dropped at {-28,18}; the smooth glide
           around the bowl is the visible ghost-vertex proof. zimr chain already supports loops (createChain
           11849, ChainDef.is_loop). Continuous now 14/15 (only interactive Pinball left).
         VERIFIED: lint clean; debug build compiles; wgpu-check GREEN (NO REGRESSIONS + wgpu_smoke); release
           standalone 2067901 bytes. NEXT: pick a feature to build first (large-world / body-disable /
           set-geometry / pre-solve) OR add the scene-input infra unlock; then continue scene ports.



<!-- box2d grind zimr408 -->
zimr408: box2d parity cont. — 2 more scene ports. zimr now 118 scenes.
         DECISION (Simon, standing): zimr will NOT implement box2d v3 large-world / f64 (b2Pos). The
           World|Far Gate/Pyramid/Ragdolls trio is therefore PERMANENTLY out of parity scope. Effective
           target drops 137 -> 134; remaining gap after this turn is ~19 (down from the audited 25, minus
           the 3 Far + the 3 scenes shipped in 407/408).
         SHIPPED THIS TURN (both passive/observable, no infra needed; verified):
           * Benchmark|Barrel 2.4 (benchmarkBarrel24): U-shaped bin (floor + two 90deg walls) packed with a
             26 x (5*26) cube grid, ported 1:1 from box2d BenchmarkBarrel24. NOTE: local named `floor` trips
             a NEW lint rule [reserved-math-names] (shadows zm.floor) — renamed to `bin_floor`. Add to the
             house-rules list: don't name locals floor/ceil/round/etc (zm reserved math words).
           * Events|Sensor Types (eventSensorTypes + eventSensorTypesUpdate, build_s/update_s): a sensor on
             each of a static / kinematic / dynamic body + a category-filtered ground; balls (DEFAULT, masked
             to be seen by every sensor) rain through. Kinematic sensor bobs y in [0,3] via update_s using
             phys.getPosition + phys.setLinearVelocity, handle stashed in st.body[0]. Dropped box2d's
             PrintOverlaps text + the per-frame raycast overlay (scene update has no text/draw access — that
             is the "event-overlay infra" unlock noted in 407). Sensor authoring: createShape directly with
             .is_sensor + .filter (attach* helpers don't expose is_sensor); filters via .filter=.{.category,.mask}.
         CATEGORY STATUS: Continuous 14/15 (only interactive Pinball left). Events now 8/12 (missing: Joint*,
           Persistent Contact, Platformer, Sensor Hits — *Joint needs mouse-drag or procedural-stress to
           exceed thresholds; engine fully supports the events). Benchmark gained Barrel 2.4.
         VERIFIED: lint clean; debug compiles; wgpu-check GREEN (NO REGRESSIONS + wgpu_smoke); release
           standalone 2071357 bytes.
         REMAINING AUTHORABLE-NOW (no new feature/infra): Benchmark|Sensor, Benchmark|CreateDestroy (update
           churn). Then the two cheap infra unlocks (still Simon's call): (a) keyboard into scene update hook
           -> Mover [engine toolkit already complete], Pinball, Cart, faithful Events|Joint; (b) per-scene
           draw/text in update -> event overlays. Then feature work: body enable/disable (Issues|Disable),
           set-geometry (Shapes|Modify Geometry), pre-solve (Events|Platformer + Shapes|Custom Filter),
           deferred-mass (b2Body_ApplyMassFromShapes — also needed for Benchmark|Large Compounds), etc.



<!-- box2d grind zimr409 -->
zimr409: box2d parity cont. — shipped Events|Sensor Hits; CLEAN scene-only pool now exhausted.
         SHIPPED: Events|Sensor Hits (eventSensorHits + launchSensorBullet + eventSensorHitsUpdate,
           build_s/update_s). Three sensors — static tripwire segment, kinematic tripwire drifting right
           (vx=0.5), dynamic capsule on a motorised prismatic (pinPrismatic axis_angle=0, motor speed 0.5
           force 1000) — tunnel-tested by a CCD bullet (r=0.25, vx=250, .bullet=true) fired from {-26.7,6}.
           box2d fires on key 'B'; here it auto-relaunches every 150 frames: launch fresh FIRST, then
           destroyBody(old) so a failed spawn can't dangle/double-free. Handle in st.body[0], counter st.u[0].
           Used destroyBody (8722) + createShape segment/capsule sensors directly (attach* don't expose is_sensor).
         STATE: zimr 119 scenes. Effective target 134 (Far trio out per Simon). REMAINING = 15, and after
           auditing sources they ALL need a feature or infra (or are hollow perf micro-benchmarks) — the easy
           faithful ports (Ghost Bumps, Barrel 2.4, Sensor Types, Sensor Hits) are now done. DO NOT force the
           rest; a faithful version of each needs one of:
           - INPUT infra (keyboard into scene update hook): Character|Mover [engine toolkit already complete],
             Continuous|Pinball, Robustness|Cart, + a faithful Events|Joint (needs drag/stress to exceed the
             joint force thresholds zimr already supports). HIGHEST YIELD: ~4 scenes from one smallish change.
           - FEATURES: custom contact-filter callback (Shapes|Custom Filter + Benchmark|Sensor); set-geometry
             (Shapes|Modify Geometry); body enable/disable (Issues|Disable — small/self-contained); contact
             pre-solve (Events|Platformer); world serialize (Determinism|SnapShot); Gear Lift; User Constraint
             (per-step callback); broadphase tree-node accessor (Collision|Dynamic Tree — small, then a lab);
             deferred-mass b2Body_ApplyMassFromShapes (Benchmark|Large Compounds); Events|Persistent Contact.
           - HOLLOW as visual scenes (raw throughput micro-benchmarks, ~100k bodies, timing-only — porting
             would be unfaithful filler): Benchmark|Cast, Benchmark|Shape Distance, Benchmark|CreateDestroy.
         NEXT IS SIMON'S CALL (the fork I keep flagging): input infra vs which feature first. My lean: input
           infra (best parity-per-effort), then custom-filter or body-disable. Verified: lint clean; debug
           compiles; wgpu-check GREEN; release standalone 2073605 bytes.



<!-- box2d grind zimr410 -->
zimr410: engine features + samples — started the feature arc. zimr 121 scenes.
         BUILT FEATURE: setShapeGeometry(world, shape, geom) + getFirstShape(world, body) [src/zimrphysics2d.zig
           after destroyShape]. Replaces a live shape's geometry in place: recompute local_centroid/
           aabb_margin (getShapeCentroid/computeShapeMargin), refit aabb/fat_aabb, broadphase.moveProxy
           (keeps proxy id so contacts survive + re-queues pair creation), then updateBodyMassData. Host test
           added ("setShapeGeometry swaps geometry, refreshing mass and broad-phase proxy"): circle->box grows
           mass >3x and the body still falls+lands on a segment. 37 physics tests pass.
         SAMPLES: Shapes|Modify Geometry (shapesModifyGeometry/Update: kinematic shape cycles circle->capsule
           ->box->segment every 75f under a dropped box) and Issues|Disable (issuesDisable/Update: motorised
           revolute arm jointed to a static platform, disableBody/enableBody toggled every 100f — guards the
           original disable-with-joint crash).
         CORRECTION (important): disableBody/enableBody ALREADY EXISTED (11912/11948) and I nearly
           reimplemented them. Pre-solve ALSO already exists (PreSolveFn type 4784 + enable_pre_solve flag +
           consulted in narrowphase 4870, settable via World NarrowPhaseConfig.pre_solve_fn/ctx). ROOT CAUSE of
           the bad audit: I used `grep -E "a\|b"` — in ERE `\|` is a LITERAL pipe, so the alternation never
           matched and several features falsely read as "missing". HOUSE-RULE for future audits: in grep -E use
           plain `|`, never `\|`. Re-audited with correct syntax.
         CORRECTED FEATURE LEDGER (what genuinely exists vs missing):
           EXISTS: body disable/enable; pre-solve callback; set-geometry (now); joint force/torque-threshold
             events (getJointEvents); ray/shape/mover casts; overlapAabb; filters.
           MISSING (real feature work): custom contact-filter callback (Shapes|Custom Filter + Benchmark|
             Sensor); world serialize (Determinism|SnapShot); gear joint (Joints|Gear Lift); per-step user
             constraint (Joints|User Constraint); broadphase tree-node accessor (Collision|Dynamic Tree, small);
             deferred-mass b2Body_ApplyMassFromShapes (Benchmark|Large Compounds); Events|Persistent Contact.
           SAMPLE-ONLY for existing features (no engine work): Events|Platformer (pre-solve; needs a ctx that
             carries the platform shape id — callback can decide one-way pass from the contact normal, no world
             access needed); Events|Joint (needs input/stress to cross thresholds).
         NEXT: build custom contact-filter callback (unlocks 2 scenes) or the tree-node accessor (small ->
           Dynamic Tree), then gear + serialize; and wire Events|Platformer onto existing pre-solve.
         VERIFIED: lint clean; 37 physics tests; wgpu-check GREEN; release standalone 2076737 bytes.



<!-- box2d grind zimr411 -->
zimr411: engine feature — custom contact-filter callback + Shapes|Custom Filter sample. zimr 122.
         BUILT FEATURE: a custom collision filter consulted at pair creation.
           - CustomFilterFn = *const fn(shape_a:u32, shape_b:u32, ctx:?*anyopaque) bool (near PreSolveFn).
           - NarrowPhaseConfig gains custom_filter_fn/custom_filter_ctx (alongside pre_solve_fn).
           - Shape + ShapeDef gain enable_custom_filtering (opt-in, threaded through createShape, mirrors
             enable_pre_solve).
           - Consulted in pairQueryCallback right after shouldShapesCollide: if either shape opted in and a
             callback is set, call it; return false → pair is skipped (no contact). Consulted once at pair
             creation (matches box2d), so it gates contact CREATION, not per-step.
           - Public setter setCustomFilterCallback(world, fn, ctx) [b2World_SetCustomFilterCallback]; null clears.
           Host test added ("custom filter callback vetoes collision between opted-in shapes"): an opted-in box
           with a reject-all filter falls straight through the ground. 38 physics tests pass.
         SAMPLE: Shapes|Custom Filter (shapesCustomFilter + free fn customFilterShouldCollide). 10 boxes opt in,
           each shape.user_data = i+1; callback collides only same-parity pairs ((a&1)+(b&1) != 1). ctx = the
           world pointer so the callback can read shape user_data; SAFE across scene switches because loadScene
           (demo line 281-282) deinit+World.init recreates the world each switch, resetting narrow_phase.
         NOTE: Benchmark|Sensor is now UNBLOCKED (it relied on this same custom-filter feature) — deferred only
           because it's a heavy sensor-grid benchmark, not because it's gated.
         REMAINING MISSING FEATURES: world serialize (Determinism|SnapShot); gear joint (Joints|Gear Lift);
           per-step user constraint (Joints|User Constraint); broadphase tree-node accessor (Collision|Dynamic
           Tree, small + a lab); deferred-mass b2Body_ApplyMassFromShapes (Benchmark|Large Compounds);
           Events|Persistent Contact. SAMPLE-ONLY (feature exists): Events|Platformer (pre-solve).
         VERIFIED: lint clean; 38 physics tests; wgpu-check GREEN; release standalone 2078909 bytes.



<!-- box2d grind zimr412 -->
zimr412: setPreSolveCallback setter + Events|Platformer (one-way platforms on existing pre-solve). zimr 123.
         FEATURE (small): public setPreSolveCallback(world, fn, ctx) [b2World_SetPreSolveCallback], symmetric
           with setCustomFilterCallback; sets world.narrow_phase.pre_solve_fn/ctx. The pre-solve machinery
           itself already existed (PreSolveFn 4784, consulted in updateContact 4881 when contact.enable_pre_solve).
         SAMPLE: Events|Platformer (eventsPlatformer/Update + free fn platformerPreSolve). Two thin static
           one-way platforms (enable_pre_solve, user_data=tag_platform) + a player capsule (enable_pre_solve,
           user_data=tag_player). Callback uses box2d's NORMAL test (NOT velocity): the manifold normal points
           shape_a->shape_b (zimrphysics2d.zig:1148); orient it platform->player via the role tags (sign=+1 if
           player is B, -1 if A); `sign*normal.y > 0.95` => player above => keep contact (land), else disable
           (rise through). ctx=world so the callback can read shape user_data tags. Player auto-jumps every 150f
           (setLinearVelocity {0,11}, which wakes it) so the one-way behaviour shows without input. Module-level
           `const tag_platform:u64=1; const tag_player:u64=2;` in scenes.zig.
         HOST TEST added ("pre-solve one-way platform passes a rising body and catches a falling one"): a box
           launched up at vy=20 from below climbs ABOVE a pre-solve platform (passes through), then falls back
           and lands on top (settles just above the platform). 39 physics tests pass.
         REMAINING MISSING FEATURES: world serialize (Determinism|SnapShot); gear joint (Joints|Gear Lift);
           per-step user constraint (Joints|User Constraint); deferred-mass b2Body_ApplyMassFromShapes
           (Benchmark|Large Compounds); Events|Persistent Contact. LOW-PRIORITY/heavy: Collision|Dynamic Tree
           (box2d sample is a 1000x1000 perf-viz; a node-AABB accessor would need free-list/traversal care);
           Benchmark|Sensor (unblocked by custom-filter but heavy). INPUT-GATED (Simon's fork): Character|Mover,
           Continuous|Pinball, Robustness|Cart, faithful Events|Joint.
         NEXT pick: gear joint (read box2d Joints|Gear Lift first to confirm the v3 mechanism) then world
           serialize; consider deferred-mass.
         VERIFIED: lint clean; 39 physics tests; wgpu-check GREEN; release standalone 2080317 bytes.



<!-- box2d grind zimr413 -->
zimr413: Joints|User Constraint (sample-only) + two corrections to the feature ledger. zimr 124.
         CORRECTION 1 — gear joint is NOT a missing feature: box2d v3 has no gear joint (grep of include/+src/
           empty). Joints|Gear Lift builds the mechanism from real TOOTHED geometry (two circles each with 16
           rounded-box teeth that mesh) + revolute motors + a 40-capsule link chain + a door. So it is a heavy
           AUTHORING task, not an engine feature — deprioritized.
         CORRECTION 2 — Joints|User Constraint needs NO engine feature. box2d implements it entirely in the
           sample's Step() from public body accessors; all of them already exist in zimr: getMass (10619),
           getRotationalInertia (10623), getLinearVelocity/getAngularVelocity (10569/10573), getWorldCenterOfMass
           (10611), getWorldPoint (10628, uses body transform = b2Body_GetWorldPoint), setLinearVelocity/
           setAngularVelocity. So this was sample-only.
         SAMPLE: Joints|User Constraint (jointsUserConstraint/Update). A density-20 box (enable_sleep=false,
           linear_damping 0.2, angular_damping 0.5) is held by two soft "cables" from a fixed anchor {3,0} to
           local anchors {1,-0.5}/{1,0.5}, computed each step as box2d's TGS soft constraint
           (hertz 3, zeta 0.7, maxForce 1000) and applied by setLinearVelocity/setAngularVelocity. Impulse is
           pull-only (clamped to [-maxForce*dt, 0]) so it can't add energy — stable at dt=1/60. No host test
           (no engine change; math is a sign-verified direct port). LINT learned: [clamp-pattern] forbids
           @max(@min(..)) — use zm.clamp; and that must be bound at file scope (no-qualified-zm) as
           `const clamp = zm.clamp;`.
         REMAINING GENUINELY-MISSING FEATURES: world serialize (Determinism|SnapShot); deferred-mass
           b2Body_ApplyMassFromShapes (Benchmark|Large Compounds); Events|Persistent Contact. HEAVY-AUTHORING/
           perf (not features): Joints|Gear Lift, Collision|Dynamic Tree, Benchmark|Sensor, other Benchmark|*.
           INPUT-GATED (Simon's fork): Character|Mover, Continuous|Pinball, Robustness|Cart, faithful
           Events|Joint.
         NEXT: world serialize (read box2d Determinism|SnapShot first — it may only snapshot/restore body
           state, lighter than full serialize) then deferred-mass.
         VERIFIED: lint clean; 39 physics tests; wgpu-check GREEN; release standalone 2081685 bytes.



<!-- box2d grind zimr414 -->
zimr414: deferred-mass feature (b2Body_ApplyMassFromShapes) + Benchmark|Large Compounds. zimr 125.
         BUILT FEATURE: defer the per-shape mass solve when assembling compound bodies.
           - ShapeDef gains `update_body_mass: bool = true`. createShape now only calls updateBodyMassData when
             that flag is set (the destroyShape recompute is untouched).
           - Public applyMassFromShapes(world, body) wraps updateBodyMassData(body.index()) — recomputes mass,
             COM, inertia from current shapes once. box2d: b2Body_ApplyMassFromShapes.
           Usage: attach N shapes with update_body_mass=false, then call applyMassFromShapes once (O(N) instead
           of O(N^2) mass solves). Host test added ("deferred mass defers the mass solve to applyMassFromShapes"):
           4 deferred boxes leave mass ~0 until applyMassFromShapes makes it 4.0, matching the same compound built
           with the default per-shape update. 40 physics tests pass.
         SAMPLE: Benchmark|Large Compounds (benchmarkLargeCompounds) — a 5x5 grid of plus-shaped compounds
           (5 boxes each, built with update_body_mass=false + applyMassFromShapes) dropped into a half-width-16
           bin. cam target {0,8} ppm 12.
         WORLD SERIALIZE (Determinism|SnapShot) — ASSESSED, NOT STARTED (needs Simon's greenlight): box2d uses
           b2World_Snapshot(world,buf,size)/b2World_Restore — a FULL binary image of the entire world (every body,
           shape, joint, contact graph, island, broadphase tree, solver state) round-tripped deterministically.
           This is the single largest remaining feature: multi-session, high-risk, deep into engine internals.
           Recommend treating it as its own dedicated effort rather than a Continue-turn item.
         REMAINING: world serialize (huge, greenlight needed); Events|Persistent Contact (medium — needs contact
           events to also report still-touching contacts, not just begin/end). HEAVY-AUTHORING/perf (not
           features): Joints|Gear Lift, Collision|Dynamic Tree, Benchmark|Sensor, other Benchmark|*. INPUT-GATED
           (Simon's fork): Character|Mover, Continuous|Pinball, Robustness|Cart, faithful Events|Joint.
         NEXT: Events|Persistent Contact (check whether getContactEvents already exposes persisted/touching
           contacts; if not, small addition) — the last tractable non-serialize feature.
         VERIFIED: lint clean; 40 physics tests; wgpu-check GREEN; release standalone 2082325 bytes.



<!-- box2d grind zimr415 -->
zimr415: contact-data introspection feature + Events|Persistent Contact. zimr 126. NON-SERIALIZE
         FEATURE WORK NOW COMPLETE.
         BUILT FEATURE: read a live contact's manifold (box2d b2Contact_GetData + contact enumeration).
           - ContactPointData { point: Vec2 (world), normal_impulse: f32 } and
             ContactData { shape_a, shape_b, normal: Vec2 (A->B), point_count, points: [2]ContactPointData }.
           - liveContactCount(world) / liveContactId(world, i): iterate the dense live list world.contact_ids.
           - isContactTouching(world, id) = contacts.data[id].flags.touching (vs a speculative pair).
           - getContactData(world, id): lifts each manifold point to world as bodies.data[body_a].center +
             anchor_a (anchor_a is COM-relative per ManifoldPoint doc, matches b2Body_GetWorldCenter+anchorA);
             impulse = total_normal_impulse. Inserted after getContactEvents (~10716).
           Begin/end ContactBeginTouchEvent/EndTouchEvent already carry contact_id (index into world.contacts).
           Host test ("getContactData reports a live touching contact's manifold"): ball (enable_sleep=false so
           the supporting impulse persists) resting on a segment yields a touching contact with a point at y≈0,
           vertical normal, and total_normal_impulse>0. 41 physics tests pass.
         SAMPLE: Events|Persistent Contact (eventsPersistentContact + eventsPersistentContactLab). A ball rolls
           in a smooth 7-pt open CHAIN bowl (ghost-vertex joins keep the roll continuous); the lab iterates live
           touching contacts and draws each manifold point (c_red dot) + its normal-impulse vector (line, scaled
           x4 for visibility since a small ball's support impulse ~0.13). Note: lab gets only *render.LabCtx
           (world, no SceneState) — so it must read contacts straight from ctx.world each frame, which is exactly
           why the enumeration accessors were added rather than event-tracking a single contact_id.
         STATUS OF box2d PARITY (effective target 134 = 137 - 3 Far large-world):
           ALL genuinely-missing ENGINE FEATURES are now built EXCEPT world serialize. Done this arc: set-geometry,
           custom contact-filter, pre-solve setter (+Platformer), deferred-mass, contact-data introspection;
           confirmed-already-present: body disable/enable, pre-solve, user-constraint accessors, gear (n/a — box2d
           v3 has none).
           REMAINING:
           - world serialize/restore (Determinism|SnapShot): HUGE, full binary world image; NEEDS SIMON GREENLIGHT,
             own dedicated effort.
           - HEAVY-AUTHORING / perf scenes (no engine feature, just lots of geometry/bodies): Joints|Gear Lift
             (toothed gears + 40-link chain), Collision|Dynamic Tree (1000x1000 perf-viz), Benchmark|Sensor and
             other Benchmark|* (Cast / Shape Distance / Create-Destroy).
           - INPUT-GATED (Simon's fork; engine support already complete): Character|Mover, Continuous|Pinball,
             Robustness|Cart, faithful Events|Joint.
         NEXT: await Simon's call — either start world serialize (big), or author the heavy non-feature scenes
           (e.g. Gear Lift / Dynamic Tree) for raw parity count.
         VERIFIED: lint clean; 41 physics tests; wgpu-check GREEN; release standalone 2083573 bytes.



<!-- box2d grind zimr421 -->
zimr421: box2d parity push (Simon: "do them all"). Authoritative re-audit + first 3 of the 6 authoring scenes.
         AUDIT (correct method this time — diffed every box2d RegisterSample vs the scene registry, not memory):
           137 box2d samples; zimr was 126. The 14 unmatched box2d samples = 3 Far (out of scope, large-world) +
           1 missing FEATURE (Determinism|SnapShot = world serialize) + 4 input-gated (Character|Mover,
           Continuous|Pinball, Events|Joint, Robustness|Cart — engine support complete, need an input layer) +
           6 authoring-only (Benchmark Cast/CreateDestroy/Sensor/Shape Distance, Collision|Dynamic Tree,
           Joints|Gear Lift). Verified the 6 need NO new engine feature: shapeDistance+makeProxy+DistanceInput/
           Output (1559/1277), castRayClosest/castShapeClosest (10345/11942), sensor events, and the BroadPhase
           DynamicTree are all already public.
         PLAN (Simon greenlit all 10 scenes; SnapShot stays the separate finale): input-gated scenes will use
           on-screen UI buttons (phone) + keyboard. Doing the 6 no-infra authoring scenes first.
         THIS SESSION (scenes.zig, +3 -> 129 total):
           - Added a tiny deterministic LCG (rngNext/rngRange) for scattering benchmark fields.
           - Benchmark|Cast: build = a 240-box scattered static field; lab = a 200-ray 360-degree fan from an
             orbiting origin, castRayClosest per ray, hits marked. (box2d original is a 1000x1000 grid + 10k
             rays/frame for desktop timing — scaled for the device.) cam {0,0}@24.
           - Benchmark|Shape Distance: lab = a probe box (follows pointer) vs a ring of 48 fixed boxes, recomputes
             GJK shapeDistance to each every frame and draws the closest-point segment. build = labEmpty. cam {0,0}@28.
           - Benchmark|CreateDestroy: build_s ground + update_s churns a 4-box cluster (destroy+respawn every
             ~0.45s, falls in between). box2d rebuilds a 100-row pyramid every frame; scenes can only track 4
             handles (SceneState) and there's no dense live-body list, so this is the create/destroy exercise
             device-sized. (If a fuller version is wanted later: add a destroyAllDynamic engine helper via the
             entities iterator + rebuild a real pyramid.)
         REMAINING authoring: Benchmark|Sensor (intricate sensor-grid perf scene), Joints|Gear Lift (toothed
           mechanism), Collision|Dynamic Tree (broadphase AABB-tree viz). Then the input layer + the 4 gated scenes.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2083837 bytes.
         NOTE: can't device-verify here (no GPU/browser) — scenes are correct by construction + compile/gate.



<!-- box2d grind zimr422 -->
zimr422: box2d parity push cont. — 2 more authoring scenes (zimr 129 -> 131). 5 of 6 authoring scenes done.
         - Collision|Dynamic Tree: visualizes the LIVE broad-phase AABB tree. build = a bin of 48 falling boxes
           (kept moving so the tree restructures); lab traverses world.broadphase.trees[dynamic] from .root
           (recursive drawTreeNode), drawing internal node AABBs dim and leaf AABBs green. Needed one tiny engine
           change: made TreeNode pub in zimrphysics2d.zig (it was private) so the visualizer can name the type for
           a typed local; DynamicTree + its .nodes/.root were already pub. Root traversal skips free-list nodes
           naturally. cam {0,6}@20.
         - Benchmark|Sensor: a 9x3 grid of static SENSOR boxes (each createShape with is_sensor + enable_sensor_
           events + user_data = cell index) that 4 dynamic balls (gravity_scale 0.4) fall straight through;
           update_s recycles each ball to the top when it drops below y=1.5. lab draws the cell outlines (dim) and
           reads getSensorEvents each frame, flashing a cell green + amber dot on every sensor BEGIN event — so it
           showcases the sensor-event API, not just geometry. Module-level grid consts (sensor_cols/rows/half/dx/
           y0/dy) shared by build + lab via sensorCellCenter(i). cam {0,6}@20. (box2d's is a 10k-sensor perf
           harness; scaled for readability.) Note: lab has no SceneState by design, so the flash is event-driven
           (stateless) rather than persistent-overlap — entry flashes read clean.
         LINT GOTCHA: a rect() call hit 121 cols; wrapped it multiline (line-length max 120).
         REMAINING: Joints|Gear Lift (deferred to its own turn — meshing toothed gears + 40-link chain + door +
           ball pile; geometry-sensitive, exact box2d numbers, can't verify mesh visually here so it needs care).
           Then the input layer (on-screen buttons + keyboard) + the 4 input-gated scenes (Mover, Pinball,
           Events|Joint, Cart). SnapShot serialize still the separate finale.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2086965 bytes. No device
           verify here — scenes correct by construction + compile/gate.



<!-- box2d grind zimr423 -->
zimr423: Joints|Gear Lift authored (zimr 131 -> 132). ALL 6 box2d authoring scenes now done.
         The signature mechanism reproduced with box2d's EXACT numbers (meshing is geometry-sensitive):
           - gear1 (driver): circle r=1 + 16 radial teeth (makeOffsetRoundedBox hw.09/hh.06/r.03) at radius
             r+tooth_hh=1.06; revolute to ground with motor (speed 1.5, torque 80). Handle stored in st.joint[0].
           - gear2 (follower): same circle + 16 teeth at radius r+tooth_hw=1.09 (the hw-vs-hh difference is what
             box2d uses to interlock); revolute to ground with a ROTATED frame (local_frame_a.q = 0.25pi) +
             enable_limit lower -0.3pi/upper 0.8pi, weak motor (0.5) — this is the winding arm. Built via
             createRevoluteJoint directly since pinRevolute hardcodes q=identity.
           - chain: 40 vertical capsule links (hl .07, r .05, density 2) pinned top-to-top via pinRevolute
             (weak 0.05 motor), hanging from gear2's rim at link_attach.
           - door: box (.15 x 1.5), revolute to last link at its top + vertical prismatic to ground
             (axis_angle 0.5pi, motor force 0.2). + 16 rolling balls as nudgeable flavor + a static floor
             (replaces box2d's SVG-path frame).
         Teeth placed by angle-tracking (k*da, da=2pi/16) feeding Rot2.fromAngle + rotateVec2 — avoids needing
           Rot2.mul (zm has no Rot2.mul). update_s cycles gear1's motor speed +/-1.5 every 5s via
           revoluteSetMotorSpeed(st.joint[0]) so the door rises/lowers on a loop. cam {-2,6.5}@30.
         LINT GOTCHA: named a body `floor` -> [reserved-math-names] (shadows zm.floor); renamed to floor_body.
         RISK (flagged, can't verify here): whether the two gears actually MESH and drive depends on the exact
           tooth geometry — replicated box2d's numbers 1:1 to maximize correctness, but this needs a device check.
           If gear1 spins free and gear2/door don't move, the mesh is off (tooth size/radius/rounding to revisit).
         REMAINING: input layer (on-screen buttons + keyboard) + the 4 input-gated scenes (Character|Mover,
           Continuous|Pinball, Events|Joint, Robustness|Cart). Then SnapShot serialize (the finale).
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2090689 bytes.



<!-- box2d grind zimr424 -->
zimr424: INPUT LAYER + first interactive scene (zimr 132 -> 133). Device-confirmed Gear Lift works.
         Input infra (scenes.zig + demo):
           - scenes.zig: new `pub const SceneInput = struct { left, right, up, down, action: bool=false }`
             + new optional Scene hook `control: ?fn(world,*SceneState,SceneInput) void`. control runs ONCE
             per frame (not per sub-step) so impulse actions like jump fire once per press.
           - demo State: added `btn: scenes.SceneInput` (on-screen button held-state); reset in loadScene.
           - demo update: inside `if(!paused)`, before the sub-step accum loop, build
             in = { .left = s.btn.left or z.isKeyDown(f.input,.left), ... .action = ... or .space } and call
             control. Keyboard arrows + space; KeyboardKey right=262,left=263,down=264,up=265,space=32.
           - demo UI: when current scene has control!=null, render a button row `< > ^ O` and set
             s.btn.<field> = u.isItemActive() after each u.button (HELD state; isItemActive at ui.zig:17091).
             On-screen buttons lag one frame (UI builds after the step) — imperceptible.
         Character|Mover (build_s + control): upright capsule (lock_rot) on stepped terrain + a floating
           ledge + loose crates. control: vx = (right-left)*6; grounded = castRayClosest down 0.93 != null;
           jump (vy=9.5) edge-triggered via st.u[0] prev-up latch so one press = one jump. Dynamic capsule
           (not the kinematic mover API) for simplicity — can upgrade to castMover/collideMover later if Simon
           wants the faithful kinematic controller. cam {0,3}@26.
         box2d parity now: 133 scenes. REMAINING input-gated: Continuous|Pinball, Robustness|Cart,
           Events|Joint. Then Determinism|SnapShot serialize = the finale.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2093729 bytes.
         (Mover control feel — speed/jump/grounded reach — is the thing to device-check.)



<!-- box2d grind zimr425 -->
zimr425: Moved the interactive control pad OUT of the UI panel into a big bottom-anchored overlay
         (Simon: "make twice bigger input buttons, outside of the ui panel" — device shot of Mover).
         Removed the in-panel < > ^ O cluster. Added a SEPARATE top-level UI window "controls" (sibling
         of the main "zimrphysics2d" window, placed after the main window block closes), shown only when
         the current scene has control!=null:
           - anchored bottom-centre every frame: setNextWindowPos({(screen_w-win_w)/2, screen_h-win_h-18})
             + setNextWindowSize, using f.window.widthf()/heightf().
           - flags: no_title_bar/no_resize/no_move/no_collapse/no_scrollbar/no_saved_settings.
           - buttons sized via ButtonOpts.size = .{72,72} (~2x default frame height); row of < > ^ O on
             one sameLine; held state still s.btn.<field> = u.isItemActive() after each button.
         API notes: u.window(title, .{.flags=...}) returns ?WindowHandle, scope via `defer win.close()`.
           ButtonOpts has `size: Vec2` (0 = auto-fit). setNextWindowPos/Size opts.once=false => re-anchor
           every frame (survives rotation/resize).
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2094109 bytes. Scene count 133.
         REMAINING: Continuous|Pinball, Robustness|Cart, Events|Joint (all reuse this pad), then SnapShot.



<!-- box2d grind zimr426 -->
zimr426: Continuous|Pinball authored (zimr 133 -> 134), 2nd interactive scene (reuses the control pad).
         Faithful to box2d sample_continuous.cpp Pinball:
           - ground = closed CHAIN LOOP, 5 pts {-8,6}{-8,20}{8,20}{8,6}{0,-2} via phys.createChain(.is_loop).
           - 2 flippers: MakeBox(1.75,0.2) at {-2,0}/{2,0}, revolute to ground with localFrameA.p = pivot
             (flipper's CENTRE — box2d pivots at body centre, not the end), localFrameB.p=0, motor torque
             1000, limit: left [-30deg,+5deg], right [-5deg,+30deg]. Handles -> st.joint[0]/[1].
           - 2 "+" spinners (MakeBox 1.5x.125 + .125x1.5) at {-4,17}/{4,8}, revolute weak motor (.1) =
             free-spinning. helper pinballSpinner(world,ground,at).
           - 2 bumpers: static circles r=1, restitution 1.5, at {-4,8}/{4,17}.
           - ball: circle r=0.2, BULLET (.bullet=true) so it can't tunnel the thin chain at speed.
         control: action/O flips BOTH (box2d uses one key); ALSO left flips left flipper, right flips right
           (independent, nicer on phone). motor speeds: up-flip left +20 / right -20, rest left -10 / right +10.
           + drain safety: if ball.y < -6, setTransform back to {1,15} + zero velocity (closed loop should
           keep it in, but CCD-escape insurance). cam {0,9}@26.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2097549 bytes.
         REMAINING interactive: Robustness|Cart, Events|Joint. Then Determinism|SnapShot serialize (finale).



<!-- box2d grind zimr429 -->
zimr429: Robustness|Cart authored (zimr 134 -> 135), 3rd interactive scene. NOTE: box2d's Cart is NOT
         keyboard-driven — it's a solver ROBUSTNESS stress test (1000-density chassis on two 0.1m wheels
         under gravity -22, passive wheel revolutes, tuning sliders). I kept the punishing setup faithful
         and ADDED wheel motors so left/right drives it (natural use of the input layer; also shows the
         joints holding the heavy chassis while rolling).
           - world.settings.gravity = {0,-22} set in build_s (loadScene resets to {0,-10} per scene, so the
             override is scene-local). ground box(20,1) at {0,-1} friction .9.
           - chassis dynamic at {0,2}, makeOffsetBox(1.0,0.25, center {0,0.25}) density 1000 friction .6.
           - 2 wheels: circle r=0.1 density 50 friction .9 rolling .02 at {-0.9,1.85}/{0.9,1.85}; revolute to
             chassis localFrameA {+-0.9,-0.15}/localFrameB 0, enable_motor torque 120. Handles st.joint[0]/[1].
           - cart starts at y=2 and DROPS ~1.75m onto the tiny wheels (part of the stress) then rests.
         control: right -> motor_speed -30 (wheels CW = roll +x), left -> +30, rest 0 = brake. Relies on the
           zimr428 wake-on-set-speed (wheels wake from the per-frame motor writes). cam {0,1.2}@50 (whole 20m
           ground ~fits a phone width; no camera-follow, so driving past ~+-9m leaves view — fine for a demo).
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2100529 bytes. 135 scenes.
         REMAINING interactive: Events|Joint. Then Determinism|SnapShot serialize (the finale).



<!-- box2d grind zimr430 -->
zimr430: Events|Joint authored (zimr 135 -> 136). LAST interactive scene -> all 4 input/interactive
         box2d samples now done (Mover, Pinball, Cart, Joint). NOTE: Events|Joint is NOT keyboard-driven;
         the interaction is the existing pointer DRAG, so it uses update_s (no control pad).
         Faithful to box2d sample_events.cpp JointEvent: ground SEGMENT {-40,0}..{40,0}; six 1x1 boxes at
         x = -12.5,-7.5,-2.5,2.5,7.5,12.5 (y0=10), each hung from ground by a DIFFERENT joint type:
           [0] distance (len 2, anchor 2m above box-top), [1] motor (max_velocity_force 1000/torque 20),
           [2] prismatic (pivot x-1), [3] revolute (pivot x-1), [4] weld (angular_hertz 2, damping .5),
           [5] wheel (hertz 1, damping .7, limit +-1, motor torque 10 speed 1, pivot x-1).
         Each base: force_threshold/torque_threshold + collide_connected + user_data = index; boxes .no_sleep
           (box2d enableSleep=false) so their joints stay active for event eval. local_frame_b via the scene
           worldToLocal(world,body,pivot) helper; local_frame_a.p = pivot directly (ground is origin/identity).
         update_s: events: []const phys.JointEvent = phys.getJointEvents(world); for each, i=user_data; if a
           destroyed-bit (st.u[0] bitmask) isn't set, set it and phys.destroyJoint(world, st.joint[i]) -> box
           drops to the segment. Needed 6 joint slots -> bumped SceneState.joint [4]->[8] (safe; no scene used
           >3). All 6 create*Joint + getJointEvents + destroyJoint + JointBaseDef thresholds/user_data already
           public.
         THRESHOLDS: box2d uses 20000 N but the demo drag tops out at ~1000*mass (~4 kN for a 4 kg box), so
           those never break. Lowered to ft=2500 / tt=1500 so a firm yank breaks a joint while gravity (~40 N)
           + gentle drags hold. cam {0,7}@23 (shows the 25 m span of 6 boxes). To break: drag a box hard.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2103517 bytes. 136 scenes.
         box2d PARITY: all 134 in-scope samples now covered (137 - 3 Far). ONLY REMAINING: Determinism|
           SnapShot (world serialize/restore) = the finale, a separate engine effort (not started).



<!-- dup first-copy zimr431 -->
zimr431: Determinism|SnapShot authored (zimr 136 -> 137). COMPLETES box2d parity: all 134 in-scope
         samples now covered (137 - 3 permanently-excluded Far scenes). Final box2d sample done.
       ENGINE: world snapshot/restore added to src/zimrphysics2d.zig (after getJointEvents, ~10809).
         pub const WorldSnapshot + pub fn snapshot(world,*const,gpa)!WorldSnapshot + pub fn restore(
         world,gpa,*WorldSnapshot)!void + WorldSnapshot.deinit(gpa). Plus host test (now 42 tests) +
         private dupSlice/poolFreedMask/snapshotPositionHash helpers.
       *** KEY ARCHITECTURAL FINDING (why it's a CHECKPOINT, not box2d's bit-exact b2World_Snapshot):
         every entity pool is ent.Entities(T) = a pool (data/cycle/free_list/free_count/watermark, all
         PUB) PLUS a parallel `ecs: Registry` kept in LOCKSTEP — pool.alloc() calls
         Entity.reserveImmediateOrErr(&self.ecs) and asserts ecs index/gen == pool index/gen
         (entities.zig:5148). The Registry is a FULL archetype ECS world (handle_tab, arches/chunks,
         hashmaps) -> NOT cheaply byte-copyable. So a raw memcpy of a pool's ALLOCATION state desyncs
         the ecs and trips that assert on the next alloc. Only the CONTACTS pool's allocation diverges
         mid-step (contacts created/destroyed); bodies/shapes/joints sets are stable. (Physics adds NO
         secondary ecs components — grep clean — so ecs is pure allocation bookkeeping mirroring the pool.)
       DESIGN (ecs-safe state checkpoint): snapshot = dupSlice of bodies.data, shapes.data, joints.data,
         motion[], state[] + counters (step_count,next_chain_id,inv_h,inv_dt). DATA only -> pool alloc
         state + ecs untouched -> lockstep preserved. restore():
           1. destroy ALL live contacts via destroyContact (iterate a COPY of contact_ids; destroyContact
              swap-removes from contact_ids, removes pair_set key, unlinks edges, frees pool+ecs in lockstep).
           2. @memcpy bodies.data/shapes.data/joints.data/motion/state from snapshot.
           3. per live body (poolFreedMask skips free slots): head_contact=null_index, contact_count=0
              (drop stale links from the data copy); wake every movable (asleep=false, sleep_time=0,
              active.appendAssumeCapacity) + rebuild active from scratch (clearRetainingCapacity first).
           4. per live shape: recompute fat AABB (computeFatShapeAabb + expandAabb) from restored body
              transform + broadphase.moveProxy (= setTransform's resync; also queues proxy for pair-finding).
           5. restore counters. Next step re-finds contacts from restored geometry.
         CONSEQUENCE: reproduces captured TRANSFORMS+VELOCITIES exactly, but warm-start is lost (one soft
           step) -> a state checkpoint, NOT a bit-identical continuation. Documented in the big header
           comment above the code. Test asserts: restored_hash==snap_hash, diverged_hash!=snap_hash,
           post-restore step stays finite (NOT hash_a==hash_b, which a true deterministic snap would need).
         FUTURE (if bit-exact ever wanted): would require snapshotting/restoring each pool's ecs Registry
           (handle_tab free list + watermark + generations) so contact warm-start can be restored in place
           -- a separate entities.zig effort, deliberately deferred.
       DEMO WIRING (examples/wgpu_zimrphysics2d_demo/): Scene gained `auto_snapshot: bool=false`. State
         gained `snap: ?phys.WorldSnapshot=null`; freed+nulled in loadScene AND demo deinit (uses
         s.mem.allocator()). In the physics substep loop, after phys.step, if sc.auto_snapshot: count
         substeps in s.scene_state.u[0]; at ==snapshot_capture_step(50) take s.snap=phys.snapshot(...);
         at >=snapshot_restore_step(200) phys.restore(...) then reset counter to 50 (LOOP: re-diverge +
         snap back, ~2.5s period). Constants snapshot_capture_step/snapshot_restore_step near fixed_dt.
         Scene registered Determinism|SnapShot: build=determinismFallingHinges (REUSED the existing
         Falling Hinges build), auto_snapshot=true, cam {0,5}@24. SnapShot interaction is purely host-
         driven (no control/input) -> no control pad.
       GOTCHA HIT: `zig fmt --check src examples build.zig tools/zimrlint.zig` is a wgpu-check gate STEP.
         The python-inserted snapshot block tripped it (fmt deviation) -> whole build cascaded as "transitive
         failure" with NO error line, masquerading as zspv/spv2wgsl/c2js tool-compile failures (red herring;
         those tools compile fine standalone). FIX: `$ZIG fmt <file>`. LESSON: after any python/manual code
         insertion, run `$ZIG fmt --check` (or just `$ZIG fmt`) on edited files BEFORE the gate; a fmt miss
         looks exactly like an unrelated tool/shader failure.
       VERIFIED: lint clean; zig fmt clean; 42/42 host tests (incl. new snapshot test); wgpu-check GREEN;
         debug+release build; release 2108613 bytes. 137 scenes. *** box2d PARITY COMPLETE. ***
       TODO (readme): src/web/readme.html still says the old scene count / lacks the snapshot feature +
         the 4 interactive scenes (Mover/Pinball/Cart/Joint) + SnapShot -- update next turn (standing
         "keep readme.html current" directive). Not done this turn (focused on the engine finale).



<!-- box2d grind zimr431 -->
zimr431: Determinism|SnapShot FINISHED -> box2d parity effort COMPLETE (all 134 in-scope samples).
         The engine snapshot/restore + demo wiring were already present from the prior session; this turn
         verified the whole path, hardened it with a jointed-world host test, and shipped.
         ENGINE (src/zimrphysics2d.zig, after getJointEvents): in-memory state CHECKPOINT, not box2d's byte
           image -- the entity pools are mirrored by a lockstep ECS registry that is NOT cheaply byte-copyable,
           so a true memcpy snapshot of the contacts pool (the only pool whose alloc set changes mid-step) is
           impossible without desyncing the registry. WorldSnapshot dups DATA only: bodies.data/shapes.data/
           joints.data/motion/state + counters (step_count,next_chain_id,inv_h,inv_dt). restore():
             1. destroy every live contact via destroyContact (ecs-safe; clears pair_set, unlinks graph, frees
                pool+ecs slot in lockstep) -- iterate a COPY of contact_ids (destroyContact swap-removes).
             2. @memcpy data back (pool ALLOCATION state + ecs registry untouched -> lockstep invariant holds).
             3. per live body: clear stale head_contact/contact_count, wake movable bodies, rebuild active list
                (poolFreedMask walks free_list to skip freed slots).
             4. per live shape: recompute fat AABB at restored transform + broadphase.moveProxy -> requeues for
                pair-finding so the NEXT step re-creates the contacts torn down in step 1.
             5. restore counters.
           Consequence: reproduces captured transforms+velocities EXACTLY but loses one step of contact
           warm-start -> a state checkpoint, NOT a bit-identical continuation. Doc comment says so plainly.
         HOST TESTS (now 43, all green): existing "reproduces the captured geometry" (boxes) PLUS new
           "reproduces a jointed world" added this turn -- a 4-link revolute chain pinned to ground (mirrors the
           falling-hinges scene's joints): step 40 -> snapshot -> step 30 (diverge) -> restore; asserts
           restored_hash==snap_hash, diverged_hash!=snap_hash, and 10 more steps stay finite. Verifies the
           joint-bearing restore path, not just free boxes. getLocalPoint(world,body,worldpt) builds the joint
           local frames.
         DEMO (wgpu_zimrphysics2d_demo.zig): State.snap: ?phys.WorldSnapshot (deinit+null in loadScene). In the
           fixed-dt substep loop, if scenes.list[cur].auto_snapshot: st.u[0] counts steps; at tick==50 capture
           (s.snap = phys.snapshot, once); at tick>=200 phys.restore + reset tick to 50 -> world visibly plays
           50..200 then snaps back, looping. Scene Determinism|SnapShot registered (scenes.zig:3296) reusing
           determinismFallingHinges build, .auto_snapshot=true, cam {0,5}@24. SceneState.joint already [8].
         VERIFIED: lint clean (engine+demo+scenes); 43/43 host tests; debug build; wgpu-check GREEN; release x2
           = 2108613 bytes. 136 scenes. readme.html unchanged (architecture doc, no sample-count claims).
         *** This closes the box2d sample-parity project: every in-scope sample (137 - 3 permanently-excluded
             Far/large-world scenes = 134) is now ported. ***



<!-- raylib port zimr441 -->
zimr441: raylib port WAVE A #1 -- wgpu_dashed_line (from shapes/shapes_dashed_line.c). New example
         examples/wgpu_dashed_line/wgpu_dashed_line.zig + a registry row in build.zig (.{ .name="dashed_line"
         ... } after lines_drawing) -- font + wgpu_common imports wire automatically for any examples/wgpu_<n>/
         dir. drawDashedLine() walks a->b in (dash+gap) periods, one drawLineEx segment per period (final dash
         clamped to the end). Phone-first adaptation of the desktop original: endpoint follows the pointer while
         held, orbits when idle; dash/gap breathe on sines (the desktop arrow-key params), tap cycles colour
         (also auto-advances every 2.5s), translucent panel reads back live Dash/Space. raylib palette
         (RED/ORANGE/GOLD/GREEN/BLUE/VIOLET/PINK/SKYBLUE). Lint caught two on first pass (unused clamp import;
         std.fmt.bufPrint in a body -> file-scope alias) -- fixed. fmt + lint clean; wgpu-check GREEN; standalone
         wgpu-dashed-line-standalone release = 1431302 bytes. Plan updated: 77 DONE / 125 TODO. Next Wave A #2:
         ring_drawing. Standard per-example flow: write -> register row -> fmt/lint -> build standalone ->
         gate -> ship html + zip -> Simon verifies.



<!-- raylib port zimr442 -->
zimr442: raylib port WAVE A #2 -- wgpu_ring_drawing (from shapes/shapes_ring_drawing.c). ENGINE addition:
         drawRing + drawRingLines added to the wgpu immediate path (src/wgpu_app.zig, right after
         drawCircleSectorLines) and re-exported from zimr.zig -- raylib has DrawRing/DrawRingLines as core API
         and they had existed only on the CPU shapes2d path, not z./wgpu. drawRing = 2 triangles per segment
         (quad outer b0/b1, inner b1/b0) via gl.begin(.triangles); the 2D pipeline cull mode is .none
         (gpu.zig:26) so winding is unconstrained. drawRingLines = inner arc + outer arc + two end caps via
         drawLineEx. Example animates what raygui sliders drove on desktop: end-angle span sweeps open/closed
         (loading-dial), radii breathe, start rotates; cycles 3 modes (filled ring / ring outline / sector
         outline) on tap + auto every 4s; panel reads back span/segs/inner/outer. Lint caught @intFromFloat
         (deprecated in this Zig -> @trunc coerces to int via the annotation; did @max in float then @trunc).
         fmt + lint clean; wgpu-check GREEN; standalone release = 1433255 bytes. Plan 78 DONE / 124 TODO.
         Next Wave A #3: circle_sector_drawing (z.drawCircleSector/Lines already exist -> example-only).



<!-- raylib port zimr443 -->
zimr443: raylib port WAVE A #3 -- wgpu_circle_sector_drawing (from shapes/shapes_circle_sector_drawing.c).
         Example-only (z.drawCircleSector/drawCircleSectorLines already exist). Filled sector (MAROON faded) +
         outline overlaid like raylib; the sample's lesson is SEGMENT COUNT, so segments oscillate 3..24 to
         show the polygonal facets become smooth, the swept angle rotates+breathes, radius pulses. Tap toggles
         segment-vertex dots so the tessellation is literally countable; panel shows segments + MANUAL/AUTO
         (segments >= ceil(span/90)) + span/radius. Lint caught three on first pass: std.math.pi (banned ->
         literal 0.017453292519943295 for deg2rad), local named `dot` (reserved math word -> dot_col), and a
         127-col line (hoisted the hint string to a const). fmt + lint clean; wgpu-check GREEN; standalone
         release = 1432764 bytes. Plan 79 DONE / 123 TODO. Next Wave A #4: rounded_rectangle_drawing.



<!-- raylib port zimr444 -->
zimr444: raylib port WAVE A #4 -- wgpu_rounded_rectangle (from shapes/shapes_rounded_rectangle_drawing.c).
         ENGINE: drawRectangleRounded + drawRectangleRoundedLines (+ private strokeArc helper) added to
         src/wgpu_app.zig and re-exported from zimr.zig -- another raylib core API absent from the wgpu path.
         Fill = three straight bands (a plus) + four corner drawCircleSector quarter-circles (TL 180-270, TR
         270-360, BR 0-90, BL 90-180; screen-y-down). Lines = four straight drawLineEx edges + four strokeArc
         polylines, with a thickness param (raylib's ...LinesEx). roundness clamp via the file-scope `clamp`
         alias (NOT zm.clamp -> no-qualified-zm). Example animates the raygui sliders: size + roundness (0->1,
         sharp->pill) + segments + thickness all breathe; cycles 3 modes (filled rounded / rounded outline /
         plain rect) on tap + auto 4s; panel reads roundness/segs(MANUAL>=4)/thickness. Three fix-ups: unused
         Vec2 import; zm.clamp->clamp; drawRectangleLinesThick takes gl first (had 3 args, needs 4). Also
         retrofitted wgpu_circle_sector_drawing to zm.degToRad (Simon flagged the pi/180 literal). fmt + lint
         clean; wgpu-check GREEN; standalone release = 1434068 bytes. Plan 80 DONE / 122 TODO. Next Wave A #5:
         pie_chart (drawCircleSector exists -> example-only).



<!-- raylib port zimr449 -->
zimr449: raylib port WAVE A #5 -- wgpu_pie_chart (from shapes/shapes_pie_chart.c). Example-only (all prims
         exist: drawCircleSector, drawCircleV, colorFromHSV, measureText, drawText). 7 slices with animated
         per-slice values (base*(0.55+0.45*sin)) so wedges continuously re-proportion; sweeps computed ONCE so
         draw + hover agree on moving boundaries. Hover: pointer dx/dy from center, dist<=radius, ang=
         radToDeg(atan2(dy,dx)) wrapped to [0,360), walk sweeps -> popped slice gets +18px radius and a name
         read-out. Percentage label per wedge at mid-angle (radius*0.68, centered via measureText), only when
         sweep>12deg. Tap toggles donut (raylib's hack: punch a bg-colour drawCircleV over the centre). Bound
         atan2/degToRad/radToDeg at file scope (no-qualified-zm -- NOT autofixable, hand-fixed radToDeg). First
         turn building with autofix default ON: my mechanical nits would have self-fixed, but I hand-cleaned the
         no-qualified-zm one (not in the autofix set) so nothing needed fixing -- build showed no "fixed N".
         fmt+lint clean, strict wgpu-check (-Dautofix=false) GREEN, standalone 1435112 bytes. Plan 81 DONE /
         121 TODO. Next Wave A #6: triangle_strip (shapes_easings? no -- shapes_triangle_strip... check list).
         Remaining Wave A: triangle_strip, rectangle_advanced, splines_drawing, following_eyes, digital_clock,
         clock_of_clocks, penrose_tile, rlgl_color_wheel, logo_raylib, logo_raylib_anim, bullet_hell.



<!-- raylib port zimr458 -->
zimr458: raylib Wave A #6 -> wgpu_triangle_strip (from shapes_triangle_strip). A gear/star built as a
         triangle strip: N segments, alternating inside-radius (0.62*R) / outside-radius points around the
         circle -> 2 triangles per segment, each filled z.colorFromHSV by angle around the wheel; points array
         [2*max_seg+2]=[122] like the raylib sample (max_seg=60). Self-animating: slow rotation (+0.004 rad/frame)
         + hue drift (+0.4 deg/frame) so it lives without input. Phone controls replace raygui: horizontal DRAG
         sets segment count (3..60 mapped over 0.15w..0.85w), TAP (press w/ <8px move) toggles the black outline
         (z.drawTriangleLines per triangle). New file examples/wgpu_triangle_strip/ + 1 build.zig registry row.
         Notes: f32->usize count via `const n: usize = @floor(s.segments)` (Zig 0.16 forwards result type, no
         @intFromFloat); usize->f32 via float() helper; bound keywords cos sin tau clamp distance + alias float.
         lint clean, standalone builds (1.4MB), strict wgpu-check GREEN. raylib_port.md now 82 DONE / 120 TODO.
         SIMON: device-verify wgpu_triangle_strip.html. NEXT Wave A #7 = shapes_rectangle_advanced.



<!-- raylib port zimr460 -->
zimr460: raylib Wave A #7 -> wgpu_rectangle_advanced (from shapes_rectangle_advanced, 4/4). Faithful port
         of DrawRectangleRoundedGradientH: builds the 12-point rounded-rect skeleton, draws 4 solid corner fans
         (left corners=left colour, right=right) via z.drawTriangle, and 5 body quads via z.drawTriangleGradient
         where left points carry `left` and right points `right` -> horizontal gradient from per-vertex lerp
         ([2]top/[9]mid/[6]bottom span it; [8]left & [4]right solid). Helper roundedGradientH(gl,x,y,w,h,roundL,
         roundR,left,right) + free arcPoint()/gradQuad(). Per-side roundness independent (raylib's headline
         feature). Presentation: a centred stack of 5 bars that BREATHE -- each oscillates its two corner radii on
         offset sine phases while gradient hues drift (colorFromHSV). Phone: horizontal DRAG sets a global
         roundness scale (0..1.3), TAP toggles per-bar outline (z.drawRectangleRoundedLines). New file
         examples/wgpu_rectangle_advanced/ + 1 build.zig row. GOTCHAS fixed: gradQuad had 9 params -> fn-args-
         multiline (split one-per-line; the default `zig build` --fix path flags it, build with -Dautofix=false to
         see compile errors cleanly); drawRectangleRoundedLines takes (gl,x,y,w,h,roundness,segments:i32,thick,
         color) as separate args NOT a Rectangle. lint clean, standalone 1.4MB, strict wgpu-check GREEN.
         raylib_port.md 83 DONE / 119 TODO. SIMON: device-verify wgpu_rectangle_advanced.html. NEXT Wave A #8
         shapes_splines_drawing.



<!-- raylib port zimr461 -->
zimr461: raylib Wave A #8 -> wgpu_splines_drawing (from shapes_splines_drawing, 3/4). Four spline families
         over one shared set of draggable points: Linear, B-Spline (Basis), Catmull-Rom, Cubic Bezier.
         ENGINE: only z.drawSplineLinear existed; added 3 wgpu_app wrappers drawSplineBasis/CatmullRom/
         BezierCubic (sample shapes2d.getSplinePoint* at 24 divs/segment -> thick polyline via drawLineEx, same
         shape as drawSplineLinear; raylib uses miter triangle-strips but sampled polyline is visually equivalent
         for the demo) + exported all 3 via zimr.zig (L186-188). Basis/CatmullRom iterate segments i where
         i+3<len; Bezier strides i+=3 over interleaved start/c1/c2/end. EXAMPLE: 5 draggable points (raylib
         coords scaled to viewport), nearestPoint() grab within 16px, drag moves selected point, clean TAP on
         empty space cycles spline_type 0-3. Bezier mode auto-derives 2 control points/segment (anchor +/-60 x,
         NOT draggable for phone simplicity), builds the [13]Vec2 interleaved array, draws curve + handle dots
         (drawCircleV warn) + tangent lines. Helpers: per-point ring (fatter+accent when focused) + [x,y] label;
         control-polygon gray lines for basis/catmull. Alive: breathing thickness 8+/-2 sin + hue drift
         (colorFromHSV). New files examples/wgpu_splines_drawing/ + 1 build.zig row. lint nits fixed (unused
         clamp/float aliases, bufPrint must be file-scope-aliased not qualified-in-body, untyped label/line,
         multiline 4-param sigs >90col, wrapped long getSplinePoint* calls). lint clean, standalone 1.4MB, strict
         wgpu-check GREEN. raylib_port.md 84 DONE / 118 TODO. SIMON: device-verify wgpu_splines_drawing.html
         (drag points, tap to cycle 4 types). NEXT Wave A #9 shapes_following_eyes.



<!-- raylib port zimr462 -->
zimr462: raylib Wave A #9 -> wgpu_following_eyes (from shapes_following_eyes, 2/4). Two scleras with irises
         that track the pointer, each iris clamped to within (scleraR - irisR) of its centre via atan2 + a
         radius clamp (irisPos helper: returns target directly if inside, else projects onto the clamp circle).
         drawEye renders sclera + iris + pupil (0.42*ir) + an up-left glint (0.16*ir) for life. PHONE FIX: no
         hover on touch, so the gaze target = finger while pressed, else a slow Lissajous wander
         (cx+cos(t*0.9)*w*0.36, cy+sin(t*1.7)*h*0.34) -- eyes look alive with zero input. Fully responsive:
         sclera radius = min(w,h)*0.18, iris=0.3*sr, eye spacing=1.35*sr off centre. Colours as module consts
         (brown/green irises, near-white sclera on dark bg, near-black pupil). Pure-presentation, NO engine
         change (only a build.zig registry row). GOTCHA: drawEye 6 params -> fn-args-multiline (one per line).
         lint clean, standalone 1.4MB, strict wgpu-check GREEN. raylib_port.md 85 DONE / 117 TODO. SIMON:
         device-verify wgpu_following_eyes.html (drag finger; idle wander). NEXT Wave A #10 shapes_digital_clock.



<!-- raylib port zimr463 -->
zimr463: raylib Wave A #10 -> wgpu_digital_clock (from shapes_digital_clock, 4/4). Two faces, tap-toggled:
         (1) custom SEVEN-SEGMENT digital readout HH:MM:SS, each glyph hand-built from 7 hexagonal bar segments
         (drawSegment = 6-vertex strip -> 4 z.drawTriangle; seg_patterns[10]u8 byte table A=bit0..G=bit6;
         per-seg native centres seg_cx/cy + seg_vert orientation, all * scale k); blinking colon dots on
         seconds parity. (2) ANALOG dial: face circle + 60 ticks (every 5th longer/thicker via drawLineEx) +
         3 hands (handTip = center + len*(cos,sin) at angle; hour=(h%12)*30+m*0.5-90, min=m*6+s*0.1-90,
         sec=s*6-90) + hub. Both faces fully responsive (digital scales k=clamp(min(w*0.92/740, h*0.62/216)),
         analog radius=min(w,h)*0.42, ks=radius/160). TIME: no wall-clock-of-day in sandbox (runtime clock is
         performance.now monotonic via dom.now_ms; bridge has a JS Date wrapper but it is not plumbed to
         examples, and adding an epoch import touches delicate c2js glue) -> seeded the clock at 10:08:00 and
         advance by @floor(f.time.time) so it ticks 1 real-sec/sec (genuine running clock, synthetic only in
         absolute time-of-day). Tap toggles face (raylib used SPACE). Pure-presentation, NO engine change
         (1 build.zig row). GOTCHAS: f.time is wgpu_app.TimeState -> field is .time (secs since start), NOT
         .current; @floor(f64)->i64 in one step (forwards result type, @intFromFloat banned); a runtime if-else
         of bare float literals is comptime_float -> extract `const factor: f32` first; two 6-param helpers ->
         fn-args-multiline. lint clean, standalone 1.4MB, strict wgpu-check GREEN. raylib_port.md 86 DONE /
         116 TODO. SIMON: device-verify wgpu_digital_clock.html (tap to switch digital<->analog; clock ticks).
         NEXT Wave A #11 shapes_clock_of_clocks.



<!-- raylib port zimr466 -->
zimr466: raylib Wave A #11 -> wgpu_clock_of_clocks (from shapes_clock_of_clocks, 2/4). FIRST real consumer
         of the zimr464/465 z.localTime() API. The time HHMMSS where each of 6 digits is a 4x6 grid of 24 tiny
         analog clocks; each cell has 2 hands whose angle-pair (Vec2 .x/.y deg) is chosen so neighbouring hands
         trace the digit strokes. Named poses tl/tr/br/bl (corner Ls), hh/vv (straight lines), zz (blank),
         driving a const digit_angles[10][24]Vec2 table (transcribed from raylib). Per second tick: src=current,
         dst=table[digit] (12h leading-zero blanked to zz), unwrap src-=360 when src>dst so hands sweep forward,
         then smoothstep lerp over 0.5s. drawClocks renders each cell as a ring (drawCircleLinesV) + 2 hands
         (drawHand = drawLineEx center->center+len*(cos,sin)); colon dots (drawCircleV) after digits 1,3. Fully
         responsive: native ~800x210 content box fit via k=clamp(min(w*0.94/800,h*0.6/210)) and centred (offx/
         offy). Tap toggles hour_mode 36-mode (12<->24; raylib SPACE). State holds current/src/dst [6][24]Vec2
         via @splat(@splat(.{0,0})). NO engine change (1 build.zig row). GOTCHAS: pose consts were SCREAMING
         (TL/HH..) -> screaming-const lint -> lowercased; then `hh` pose collided with local hours `hh`
         (shadow + the digits line silently bound the Vec2 pose -> "mixed scalar/vector @divFloor") -> renamed
         local to `hours`; var target never mutated -> const; usual untyped-local/bufPrint-alias/branch-braces/
         fn-args-multiline. VERIFIED LINKS: node-extracted the wasm, stub-instantiated -> LINK OK, dom requires
         epoch+tz true (same check that caught the zimr464 crash). lint clean, standalone 1.4MB, strict
         wgpu-check GREEN. raylib_port.md 87 DONE / 115 TODO. SIMON: device-verify wgpu_clock_of_clocks.html
         (real time, hands sweep on each tick, tap toggles 12/24h). NEXT Wave A #12 shapes_penrose_tile.



<!-- raylib port zimr467 -->
zimr467: raylib Wave A #12 -> wgpu_penrose_tile (from shapes_penrose_tile, 4/4). A Penrose tiling grown from
         an L-system + turtle graphics. rebuild(): production starts as axiom "[X]++[X]++[X]++[X]++[X]", then
         buildStep() per generation expands each W/X/Y/Z to its rule string, CONSUMES F (dropped), copies the
         rest, and halves draw_length. drawPenrose() interprets the production as a turtle: F = forward+drawLineEx
         (x repeats), +/- = turn +/-36deg (x repeats), [ / ] = push/pop a 50-deep Turtle{origin,angle} stack,
         digit 0-9 = set repeats for the next command. theta=36, start angle -90, origin at screen centre.
         Faithful + a built-in progressive reveal (raylib steps+=12/frame; I use reveal=max(12, prod_len/180) so
         it finishes in ~3s at any generation). Phone: tap cycles generations 1..4 (each rebuild re-animates).
         Self-contained, NO engine change, NO localTime (1 build.zig row). VALIDATED the L-system natively
         (throwaway zig): gen0..4 prod_len = 23/108/483/2148/9558, F-count 0/20/90/400/1780, NO truncation at
         gen4 -> trimmed str_max 65536->16384 (60pct headroom, keeps State lean). line_col is low-alpha cyan
         (a=70) so overlapping strokes build density. node link-check: LINK OK. lint clean, standalone 1.4MB,
         strict wgpu-check GREEN. raylib_port.md 88 DONE / 114 TODO. SIMON: device-verify wgpu_penrose_tile.html
         (5-fold tiling reveals; tap advances generation). NEXT Wave A #13 shapes_rlgl_color_wheel.



<!-- raylib port zimr468 -->
zimr468: raylib Wave A #13 -> wgpu_color_wheel (from shapes_rlgl_color_wheel, 3/4). HSV colour wheel as a
         fan of 120 triangles via z.drawTriangleGradient (raylib's rlBegin/rlColor4ub/rlVertex2f fan): per
         wedge i, rim verts p0/p1 at angle i*step / (i+1)*step (pos = center + R*(sin a, -cos a)), rim colours
         colorFromHSV(a/rad_per_deg,1,1), hub = colorFromHSV(0,0,value) (grey of the value). State stores the
         SEMANTIC hue/sat/value (resize-safe) not an abs handle pos. Draggable picker: drag in wheel -> off=
         m-center, sat=clamp(length(off)/R), hue from atan2(off.x,-off.y) normalised 0..tau then /rad_per_deg.
         Value via a manual rounded-track slider (drag bar). selectedColor = Color.lerp(grey(value),
         HSV(hue,sat,1), sat) (matches raylib's ColorLerp). Handle ring dims to ink_dim on dark colours. Swatch
         + "#RRGGBB (r, g, b)" hex readout (bufPrint {X:0>2}). Replaced raylib's mouse-wheel triangleCount and
         raygui slider with a fixed smooth count + a hand-drawn slider (phone has no wheel); dropped the
         ctrl+C-copy and wireframe-toggle extras. NO engine change (1 build.zig row). GOTCHA: just the usual
         untyped-local on `lay` (call result -> needs `: Layout`). lint clean, standalone 1.4MB, strict
         wgpu-check GREEN. raylib_port.md 89 DONE / 113 TODO. SIMON: device-verify wgpu_color_wheel.html (drag
         wheel picks colour, bar sets value, swatch+hex update). NEXT Wave A #14 shapes_logo_raylib.



<!-- raylib port zimr469 -->
zimr469: raylib Wave A #14 -> wgpu_logo_raylib (from shapes_logo_raylib, 1/4). The framed-square logo from
         primitives: drawRectangle outer (co.palette.ink) then drawRectangle inner (co.palette.bg) punched out
         -> a thick square frame; word centred via z.measureText. REBADGED "zimr" (not raylib) and dark-theme
         inverted (light frame on page colour). border = size*0.0625 (raylib 16/256), inner = size-2*border.
         Responsive: size = min(w,h)*0.52*breathe, centred. Added a gentle breathe (1 +/- 0.02 sin) so the
         static 1/4 feels alive. Caption keeps the original gag ("NOT a texture - every pixel is a drawn
         shape"). NO engine change (1 build.zig row). nits: unused Color alias removed; word string literal
         needs `: []const u8`. lint clean, standalone 1.4MB, strict wgpu-check GREEN. raylib_port.md 90 DONE /
         112 TODO. SIMON: device-verify wgpu_logo_raylib.html. (Per Simon: now also pasting full example source
         inline in chat each turn.) NEXT Wave A #15 shapes_logo_raylib_anim.



<!-- raylib port zimr470 -->
zimr470: raylib Wave A #15 -> wgpu_logo_raylib_anim (from shapes_logo_raylib_anim, 2/4). The logo assembled
         by a 5-state machine: st_blink (seed box blinks ~1.2s) -> st_grow1 (top+left bars grow, lerp thick->size
         over 0.55s) -> st_grow2 (bottom+right grow) -> st_letters (letters type in @floor(t/0.18), then after a
         hold fade alpha 1->0 over 1s) -> st_replay. Reparametrised raylib's integer frame counters (+4/frame,
         ==256) into dt-driven timers (frame-rate independent). Rebadged "zimr", dark-theme inverted (light bars
         co.palette.ink on bg). AUTO-LOOPS (st_replay holds 0.8s then reset) instead of raylib's R-key; tap
         replays immediately. In the fade state, top/bottom drawn full-width and left/right INSET by thick so
         corners do not double-blend through alpha. fade(a) helper scales ink alpha. NO engine change (1
         build.zig row). GOTCHA: @intFromFloat banned -> letters via `const idx: usize = @floor(t/step)`. lint
         clean; cold standalone build exceeded the 590s wrapper once (re-ran warm -> OK), 1.4MB; strict
         wgpu-check GREEN. raylib_port.md 91 DONE / 111 TODO. SIMON: device-verify wgpu_logo_raylib_anim.html
         (blink->frame grows->letters->fade->loop; tap replays). NEXT Wave A #16 shapes_bullet_hell (last Wave-A
         shapes example in the backlog list).



<!-- raylib port zimr471 -->
zimr471: PLAN (no code change) - drop the wgpu_ prefix from example folders/files/steps/html. Wrote
         src/notes/deprefix_plan.md. KEY FINDING: the prefix is synthesized CENTRALLY, not stored per-folder:
         build.zig ~3226 + ~3334 `under = b.fmt("wgpu_{s}",.{name})` (drives folder path examples/{under}/
         {under}.zig, exe name, {under}.html, smoke focus) and ~3344 `dash = b.fmt("wgpu-{s}",.{dash_name})`
         (step names). Served gallery dir is ALREADY clean (web/{name}). So the core flip is ~3 lines + a
         folder/entry-file rename. SCOPE: 187 examples/wgpu_*/ (~164 registry-driven, each with ONE prefixed
         thing: folder + entry wgpu_<name>.zig; NO sub-file carries the prefix - verified). Special non-registry:
         wgpu_common (module imported 64x + 3 build paths), wgpu_demo, wgpu_launcher, wgpu_trivial_{vs,fs}{,_io}.
         Legacy hand-kept `wgpu_examples` dashed list (build.zig 78+) feeds gen-vscode, likely out of sync.
         SCOPING RULE: keep "wgpu" where it means the BACKEND (wgpu-check gate, wgpu_smoke, wgpu-standalone,
         zimr_wgpu.ts) - only strip EXAMPLE identity. DECISIONS for Simon: (1) rename steps wgpu-<n>-><n> too?
         (2) wgpu_common: folder-only vs also rename import? (3) de-prefix demo/trivial/launcher too?
         RECOMMENDED: Phases 1+2 (central flip + registry-folder rename, driven from the .name list NOT a glob)
         as one green change first, then infra/vscode/docs as follow-up. No snapshot deliverable html this turn.
         AWAITING Simon's go-ahead + decisions before executing.



<!-- raylib port zimr472 -->
zimr472: EXECUTED the wgpu_-prefix removal Phase 1+2 (Simon's decisions: rm wgpu from step names too;
         example_common.zig for shared; gallery=all eventually; keep one backend, wgpu has no distinguishing
         value). GREEN. The prefix was synthesized centrally -> flipped 4x `under = name` + 1x `dash = dash_name`
         (+ dep `app.name`) in build.zig, then renamed 185 example folders+entry files to examples/<name>/
         <name>.zig (driven from disk folders minus specials, NOT a registry glob). Example steps are now
         <name> / <name>-standalone, html <name>.html (verified rectangle-advanced-standalone ->
         rectangle_advanced.html). COLLISIONS: de-prefixed example steps clashed with native PNG-tool steps
         julia-gallery (registry julia_gallery) and comptime-julia (registry comptime_julia) -> renamed the
         NATIVE steps to *-png so the clean names go to the examples. (Method to find collisions: regex all
         b.step("..") multiline-aware ∩ registry dash-names.) example_common: wgpu_common/common.zig ->
         example_common/example_common.zig, import "wgpu_common"->"example_common" x64 files + 3 build
         addImport + 3 paths. vscode/zed: regenerated for ALL 187 steps clean (renamed const wgpu_examples->
         example_steps + gen_vscode.zig anchor; 0 wgpu refs in configs). VERIFICATION TRICK reused: node can
         WebAssembly.Module.imports() + stub-instantiate extracted standalones. DEFERRED (see
         src/notes/deprefix_plan.md STATUS): gallery manifest all-examples (unbroken, additive curation);
         wgpu_demo (30+ refs) + wgpu_trivial_* (shared shader) de-prefix; zimr_wgpu.ts->zimr.ts (65 refs, watch
         symbol clash with `zimr`); infra step names wgpu-check->check / wgpu_smoke->smoke / wgpu-standalone->
         standalone. lint clean, strict wgpu-check GREEN. raylib_port.md unchanged 91/111. SIMON: examples now
         live at examples/<name>/<name>.zig, run via `zig build <name>` / `<name>-standalone`. NEXT: gallery-all
         + demo/trivial + zimr_wgpu.ts + infra step rename (or resume Wave A #16 bullet_hell first).



<!-- raylib port zimr473 -->
zimr473: renamed wgpu_demo -> wgpu_bringup (Simon flagged the name as weird, mused it could keep wgpu if
         it tests wgpu features -- it DOES: it is the "first complete zimr-wgpu app", raylib-parity 2D draw on
         the engine-default hand-written WGSL pipelines, exercises typed UBO + dual-texture paths, and is the
         exact wasm the wgpu_smoke harness drives -> kept wgpu, picked a name that says its role). Renamed
         folder+entry + ALL build.zig refs (wgpu_bringup_mod/exe/install/step, step "wgpu-bringup", html
         wgpu_bringup.html, smoke wasm zig-out/wgpu/wgpu_bringup.wasm, .name, smoke_focus entry) + webtests/
         wgpu_smoke.zig default path (line 509) + comment refs in wgpu_trivial_*/lambert_demo/cube_demo. The
         bringup standalone step is `wgpu-standalone` (generic 2D) -> builds wgpu_bringup.html (1.0MB).
         ALSO fixed a latent bug from zimr472: the tier-a smoke_focus CSV still listed wgpu_cube3d/
         compute_smoke/shapes_showcase/ui_color_picker/mandel_sidebyside/ui_dock_simple/ecs_solar_system (stale
         after the example rename) -> de-prefixed to match (wgpu_bringup kept); verified all 7 folders exist.
         lint clean, strict wgpu-check GREEN. DEFERRED (deprefix_plan.md): wgpu_trivial_* shared shaders,
         gallery all-examples, zimr_wgpu.ts->zimr.ts (65 refs, watch zimr clash), infra steps wgpu-check->check/
         wgpu_smoke->smoke/wgpu-standalone->standalone. raylib_port.md unchanged 91/111. NEXT: continue the
         de-wgpu infra pass (zimr_wgpu.ts + infra steps + trivial) OR resume Wave A #16 bullet_hell.



<!-- raylib port zimr474 -->
zimr474: de-wgpu INFRA pass. Renamed infra step names: wgpu-check->check (THE GATE IS NOW `zig build
         check`), wgpu-smoke->smoke, wgpu-smoke-install->smoke-install, wgpu-standalone->standalone,
         wgpu-corpus->corpus, wgpu-corpus-refresh->corpus-refresh, wgpu-diff->corpus-diff; KEPT wgpu-bringup.
         COLLISION (multiline b.step the line-based precheck missed): smoke-install clashed with a pre-existing
         legacy ReleaseSafe smoke-install (still wired, 2 dependOn) -> renamed the legacy one to
         smoke-install-safe; live wgpu successor keeps smoke-install. Updated external refs to the renamed steps
         in readme.html / transpiler_corpus.zig / file_descriptions.zig / spv2wgsl_check.zig. zimr_wgpu cleanup:
         KEY FINDING the file src/web/zimr_wgpu.ts NO LONGER EXISTS (browser runtime is src/bridge.zig -> c2js);
         all 65 zimr_wgpu refs were stale text. Removed them across src/{zimr,wgpu,bridge,draw3d}.zig +
         build.zig comments (reworded the "converging zimr_wgpu INTO zimr" narrative since the GL backend is
         gone), repointed file_descriptions.zig's dead .ts atlas entry to src/bridge.zig, fixed tutorial HTML
         @import("zimr_wgpu")->@import("zimr"), ui_panes mock strings, and neutralised tools/gl2wgpu_ui.py's
         obsolete import-rewrite; regenerated files.md (0 zimr_wgpu). Left historical journal.txt +
         blog_zimr_architecture.md. lint clean, `zig build check` GREEN, all renamed steps appear in build -l.
         DEFERRED (last de-wgpu items, deprefix_plan.md): wgpu_trivial_* shared shaders; gallery manifest
         all-examples. raylib_port.md unchanged 91/111. NEXT: trivial shaders + gallery-all, OR resume Wave A
         #16 bullet_hell.



<!-- raylib port zimr475 -->
zimr475: DE-WGPU COMPLETE (final steps). (1) wgpu_trivial_{vs,fs}{,_io}.zig -> trivial_*: renamed 4 files +
         global wgpu_trivial->trivial across build.zig (sh_name/source_path/io_path + 8 .shaders refs) and ~12
         consumers (@import io / @embedFile .wgsl / _externs all build-derived from sh_name so consistent).
         GREEN. (2) Gallery manifest: added the 25 missing examples (Wave-A shapes ports + pipeline_*) with
         descriptions auto-pulled from each //! header, heuristic module (shapes/shaders/textures/physics),
         neutral stars=2 -> 160 examples, valid JSON. The "7 not in registry" were a regex artifact (.shaders-
         bearing entries), all valid. (3) Swept 203 stale `wgpu_<example>` self-refs across 140 files (the //!
         header self-name + ui_panes mock strings + src/zimr.zig|material.zig canonical refs + readme.html
         shapes_showcase) -> de-prefixed PRECISELY via an example-name-set regex that never touches backend
         tokens (wgpu_texture/wgpu_app/WgpuGl/wgpu_ns/wgpu_smoke). Verified 0 stale example refs remain; only
         intentional BACKEND wgpu naming stays + the kept wgpu_bringup. lint clean, `zig build check` GREEN.
         raylib_port.md unchanged 91/111. The whole de-wgpu arc (zimr472 examples+example_common+vscode ->
         zimr473 wgpu_bringup -> zimr474 infra steps+zimr_wgpu -> zimr475 trivial+gallery+headers) is DONE.
         NEXT: resume raylib Wave A #16 shapes_bullet_hell (last in the backlog list).



<!-- raylib port zimr476 -->
zimr476: raylib Wave A #16 (LAST) -> bullet_hell (from shapes_bullet_hell, 1/4). WAVE A COMPLETE. Radial
         bullet-hell spawner: a ring buffer of max_bullets=3000 Bullet{pos,vel,color,active}; every 2 frames
         spawnRing fires `rows` bullets evenly around the centre (deg_per_row=360/rows), vel = speed*(cos,sin)
         of (base_dir + deg_per_row*row)*rad_per_deg, colours alternate red/blue per row; base_dir += inc each
         volley so the rings braid into a spiral. Rotating "magic circle": two drawRectanglePro squares (rec
         {x=cx,y=cy,w=h=120*scale}, origin {60,60}, rotation magic_rot & magic_rot+45) + 3 drawCircleLinesV
         rings, drawn UNDER the bullets. Reparametrised raylib's per-frame integer logic to dt: step =
         clamp(dt*60,0,3) (60fps-equivalent) scales pos/timer/rotation -> frame-rate independent. Responsive
         scale = min(w,h)/450. Replaced the keyboard controls + the DrawTexture perf-mode with: filled
         drawCircleV per bullet (engine batches; no per-bullet outline for phone perf) + tap-cycles 6 presets
         {rows,inc,speed} for spiral variety (tap-vs-drag idiom, >8px = drag). GOTCHAS: `**` array-repeat
         retired -> `.bullets = @splat(.{...})` (field type drives length); drawScene 5 params -> one-per-line
         (fn-args-multiline). NO engine change (1 build.zig row). Added to gallery manifest (shapes, now 161).
         Built via NEW step `bullet-hell-standalone` -> bullet_hell.html (1.5MB). lint clean, `zig build check`
         GREEN. raylib_port.md 92 DONE / 110 TODO, WAVE A DONE. SIMON: device-verify bullet_hell.html (spiral
         spawns, magic circle spins, tap changes pattern). NEXT: Wave B (texture/image pipeline) or another wave.



<!-- raylib port zimr478 -->
zimr478: WAVE B OPENER -> cellular_automata (from raylib textures_cellular_automata, 2/4). Wolfram 1-D
         elementary CA (rules 18/30/60/86/102/124/126/150/182/225). FIRST example to exercise the dynamic-
         texture-upload path. Idiom (mirrors raytracer): keep a CPU `pixels: []Color` (im 512x512) + a
         z.CpuFramebuffer (init(f.gpu.device, f.gpu.queue, w, h, sliceAsBytes(pixels), label)); compute
         lines_per_frame=4 rows/frame, fb.update(f.gpu.queue, sliceAsBytes(pixels)), fb.present(f.gl, x,y,w,h)
         to scale the grid into the canvas. CA rule: each cell = (rule >> neighbourhood3bit) & 1, neighbourhood
         = (left?4:0)+(center?2:0)+(right?1:0) read from the row above; "on" detected via pixel.r>128, on=
         co.palette.ink / off=co.palette.surface. Replaced raylib's fiddly per-bit rule UI with a row of 10
         tappable preset chips (current highlighted) + tap-canvas-cycles + auto-advance 1.5s after a pattern
         finishes. Uses the NEW edge-helper tap idiom (isMouseButtonPressed/Released, press-point decides chip
         vs canvas). NO engine change (1 build.zig row). lint clean; node link-check INSTANTIATES (imports
         wgpu/dom/wasi); standalone 1.4MB; `zig build check` GREEN. Added to gallery manifest (textures, 162).
         raylib_port.md 93 DONE / 109 TODO. SIMON: device-verify cellular_automata.html (CA fills downward,
         chips switch rules, auto-cycles). NEXT: more Wave B (textures_srcrec_dstrec / sprite_animation /
         image_kernel) -- several need a source image; can gen procedurally or embed.



<!-- raylib port zimr479 -->
zimr479: Wave B -> srcrec_dstrec (from raylib textures_srcrec_dstrec, 3/4). The source-rect/dest-rect
         mapping. Generate a 6-frame "spinner" sprite sheet procedurally into a z.Image (genImageColor ->
         [*]Color buffer, CPU rasterisers fillRect/fillCircle, per-frame hue tile + 6-dot track with the active
         dot bright), upload ONCE via loadTextureFromImage -> z.WgpuTexture. Then z.drawTextureRec(gl, tex,
         u0,v0,u1,v1, dx,dy,dw,dh, tint) maps frame `sel` (NORMALISED UVs u0=sel/6, u1=(sel+1)/6, v full) onto
         a scaled dest rect at dst_center (gentle pulse). Sheet shown small up top with the active frame boxed +
         crosshair through the dst centre. Tap cycles the source frame; drag moves the destination (edge-helper
         tap-vs-drag). KEY API NOTE: z.drawTextureRec's src params are NORMALISED UVs (passed straight to
         gl.texCoord2f), NOT pixels. ENGINE GAP found: drawTexturePro (rotation/origin) lives in image.zig but
         needs an rlgl-style types.Texture{.id}; it is NOT exported on z and does NOT take a WgpuTexture -> so
         no texture ROTATION yet (raylib's example spins). TODO: add a WgpuTexture drawTexturePro
         (rotation+origin) -- straightforward: bind tex + emit 2 triangles with rotated verts + UVs, mirroring
         drawTextureRec. GOTCHAS: @intFromFloat banned -> @round forwarding to i32; locals named u0/u1 SHADOW
         the primitive integer types u0/u1 -> renamed uv0/uv1; fillRect/fillCircle >=5 params -> one-per-line;
         2 long lines wrapped. lint clean; node link-check INSTANTIATES; standalone 1.4MB; `zig build check`
         GREEN. manifest 163. raylib_port.md 94 DONE / 108 TODO. SIMON: device-verify srcrec_dstrec.html. NEXT
         Wave B: textures_sprite_animation (reuse this sheet idea, advance frame on a timer) or a tex-rotation
         engine add first.



<!-- dup first-copy zimr485 -->
zimr485: ARC RADIANS — finished the geometric-angle radians conversion across the engine (Simon:
         "Finish the arc radians. No degrees in zimr internals."). Equivalence-preserving throughout
         (param*rad_per_deg -> param once the param is radians; 360/sides*rad_per_deg -> tau/sides;
         degree-stepped tessellation loops -> radian-native), so rendering is unchanged given callers
         convert deg->rad at the UI boundary.
         ENGINE (now radian-native, zero rad_per_deg/pi-180 in geometry):
           - wgpu_app.zig: drawCircleSector/Lines, drawRing/Lines, strokeArc params start_angle/end_angle
             -> *_rad (dropped *pi/180; fixed an early-out guard + 8 rounded-rect corner literals 0/90/180/
             270/360 -> 0/pi*0.5/pi/pi*1.5/pi*2.0); drawEllipse/EllipseLines/+1 10-deg loops -> 36-seg
             radian loops.
           - shapes2d.zig: all 37 rad_per_deg sites gone. Sector/ring accumulators (angle*rad_per_deg ->
             angle), adaptiveArcSegments (/90 -> /(pi/2), /360 -> /(2pi)), drawPoly/PolyLines/PolyLinesThick
             step (360/sides*rad_per_deg -> tau/sides) + PolyLinesThick inner-radius cos (removed a latent
             EXTRA rad_per_deg factor: @cos(rad_per_deg*ext/2) -> @cos(ext/2), matches raylib intent), four
             full-circle 10-deg tessellation loops -> seg_step36 (tau/36) radian loops [CAUGHT+FIXED a bug:
             drawCircleGradient indexed i=seg*10 not seg], rounded-rect corner-angle arrays {180,270,0,90}deg
             -> {pi,pi*1.5,0,pi*0.5}, per-corner step 90/seg -> (pi/2)/seg, internal 0,360 caller -> 0,tau.
             Added tau + seg_step36 aliases; removed now-unused rad_per_deg alias.
           - image.zig: imageRotate(degrees:i32) -> (angle_rad:f32); genImageGradientLinear(direction:i32
             deg) -> (direction_rad:f32), rad=(pi/2)-direction_rad.
           - draw3d.zig: 3D disc/cone-cap tessellation 360/sides + *pi/180 -> tau/sides radian.
           - ui.zig: sliderAngle now uses degFromRad/radFromDeg (was raw rad_per_deg); removed the alias.
             NOTE sliderAngle still DISPLAYS degrees to the user (stores radians) — that's the intended
             human boundary, exactly like ImGui SliderAngle.
         CALLERS converted (deg->rad via radFromDeg at the UI): vector_angle, pie_chart, circle_sector_
         drawing, shapes_showcase, keys, math_sine_cosine, ring_drawing (+ precomputed locals where the
         radFromDeg wrap pushed >120col); image.zig + leak_test test callers.
         VERIFY: shapes2d/wgpu_app/image/draw3d audited to ZERO geometric degrees; lint clean; built
         shapes_demo/rounded_rectangle/circle_sector_drawing/ring_drawing/pie_chart/vector_angle/
         math_sine_cosine/keys/ui_primitives_zoo_phone (all exit 0); node link-check INSTANTIATES
         (circle_sector_drawing, ring_drawing); `zig build check` GREEN. Equivalence-preserving + completeness
         grep-verified, but arc RENDERING is not device-verified here (gate compiles+smokes, won't catch a
         silent visual error) — Simon to eyeball the sector/ring/ellipse/rounded-rect demos.
         DELIBERATELY LEFT AS DEGREES (domain conventions / bridge parity, NOT arc geometry — flagged for
         Simon's separate call): Camera3D.fovy (raylib/3D convention, all 3D examples), colorFromHSV hue
         (universal 0-360 color convention), plot3d elevation/azimuth (matplotlib view_init convention),
         raster.zig Context.rotate(angle_deg) (rlgl/glRotatef GL convention), runtime.zig classic-bridge
         camera path (deliberate raylib-C degree parity — also has a possible Camera2D.rotation deg/rad
         double-standard vs the native path worth auditing), zimrphysics.zig joint/steer/lean defaults
         (values ARE radians, just written "70.0*pi/180" for readability; could become radFromDeg(70)).



<!-- dup first-copy zimr494 -->
zimr494: lint rule — App-type module-var EXCEPTION (Simon ask). tools/zimrlint.zig: added isAppTypedVar()
         (module-level `var` whose type node's final identifier is `App` -> exempt from rule 9 module-var; matches
         bare `App` and qualified `z.App`, not MyApp/SubApp). Wired into checkVarDecl's container branch alongside
         isAllowlistedModuleVar. Rebuilt lint (zig build lint clean), verified: `pub var zimr_app: z.App` passes
         with NO directive while a plain `var x: u32` still fires. Then REMOVED 14 now-redundant
         `// lint:off module-var:` directive lines across the 10 own-frame examples (cube_demo, damaged_helmet,
         depth_rendering, gltf_simple/textured, lambert_demo, obj_bunny/simple, pbr_demo, shadowmap). Tooling +
         comment-only change (no compiled code / shader), so no full `check` gate.

         SHADOWMAP STEP 2 PLAN (settled after infra study; do next, focused): engine two-module shaders CANNOT
         use the clean high-level path — z.Pipeline.init (src/material.zig) takes ONE combined vs+fs module
         (vs_main/fs_main) but codegen emits SEPARATE depth_vs.wgsl + depth_fs.wgsl that BOTH declare
         `entry`/`entryInputs`/`entryOutputs`/`frag_gray` (would collide if concatenated). loadShaderVF needs an
         importable io schema and is only ever used with EXAMPLE shader io (never src/shaders engine io).
         => STEP 2 stays on shadowmap's raw two-module pipeline (createShaderModuleWgsl x2, entry point "entry",
         createRenderPipeline), OWN-FRAME, TWO manual Backend passes on one beginFrame encoder — NO blit needed:
           pass 1: Backend.beginRenderPass(color=rt.color_view, depth=rt.depth_view) -> depth pipeline mode=0
                   (raw ndc_z*0.5+0.5, pbr-faithful) -> depth-in-red into a WgpuRenderTexture.create(color
                   rgba8 render_attachment+texture_binding sampleable, with_depth depth24plus).
           pass 2: Backend.beginRenderPass(color=surface, depth=surface) -> NEW `lit_shadow` engine shader
                   (Zig/shadermath, adapt pbr_fs.computeShadow: proj-divide light_space_pos, uv=xy*0.5+0.5,
                   current=z*0.5+0.5, closest=sample(rt.color as texture_2d<f32>).r, shadow=(current-bias>closest)
                   ?0:1 + [0,1] frustum guard; VS passes world_normal + light_space_pos = mulMatVec(light_vp,
                   world_pos)). group0 = camera_vp+light_vp+light_dir UBO; group1 = shadow-map texture + sampler.
         INCREMENTAL: 2a = FS outputs the raw shadow FACTOR as grayscale (white lit / black shadowed) -> Simon
         sees the cube's shadow shape on the floor; 2b = add lambert*shadow + base color. Sampler/io idiom
         template: study pbr_fs_io Samplers.shadow_map (`shader.Sampler2D(.cubemap,.{})` = plain texture_2d) +
         pbr_fs shadowProjCoords/computeShadow. RTT sampleable-color foundation already exists (wgpu_texture.zig).



<!-- dup first-copy zimr495 -->
zimr495: STEP-2 (B) BUILT — full two-pass self-contained shadow map. shadowmap.zig REWRITTEN own_frame->AppSpec
         (pub const app: z.AppSpec(State), build row own_frame removed, kept configure=wireEngineWgsl). Authored 5
         lit_shadow shader files in src/shaders/ via shadermath DSL (Ubo form for deterministic single-binding/group,
         chosen after confirming Uniforms-form codegens PER-FIELD bindings a la lambert_demo): lit_shadow_common_io
         {frag_normal vec3, frag_light_space_pos vec4}; _vs_io {Attributes pos@0 normal@1; Ubo mvp[4]v4+light_vp[4]v4};
         _vs (mulMatPoint mvp/light_vp, normalize normal); _fs_io {Inputs=Interp; Samplers.shadow_map=Sampler2D(.albedo);
         Ubo light_dir v4 + base_color v4}; _fs (shadowProjCoords persp-divide+*0.5+0.5; sample shadow_map ONCE at top
         -> hoisted let (uniform CF verified in emitted WGSL); bias=max(0.005*(1-N.L),0.0005); scalar if/else-if
         frustum-outside->1 else current-bias>closest->0; ambient 0.25 + 0.75*n_dot_l*shadow; base_color*lighting).
         Example: SceneVertex{pos,normal} stride24, floor(half4)+cube(cs0.7 @ y1.5) baked to one vbo/ibo (28v/42i).
         Two MANUAL pipelines: DEPTH (pos-only layout, color rgba8_unorm=rt, cull none, depth24plus, group0 depth Ubo
         96B mode=0) + LIT (pos+normal layout loc0@0/loc1@12, color backbuffer_fmt, cull back, depth24plus, group0 lit
         vs Ubo 128B, group1 shadow_map tex@0+sampler@1 from rt.asTexture(), group2 lit fs Ubo 32B). update: FIXED light
         {5,7,4} lookAt->orthographicRh(13,13,1,20)=stable shadow; ORBITING perspective cam (t*0.3, r9, h5); PASS1
         beginTextureMode(rt,white)->manual depth pipeline into f.gl.pass (p.queue=gf.queue; Backend.setPipeline/
         setBindGroup; render_pass.setVertexBuffer/Index/drawIndexed via rps.pass)->endTextureMode; PASS2 (reopened
         backbuffer, reopen2DPass attaches depth_view=fixed) manual lit pipeline group0/1/2 into f.gl.pass->drawScene;
         endDrawing. VERIFIED BUILD-SIDE: standalone EXIT=0, lint 0, both lit_shadow WGSL codegen'd + naga-valid, emitted
         @group/@binding EXACTLY match manual pipeline (VS g0@0 uniform, FS g1@0 tex + g1@1 sampler, g2@0 uniform),
         textureSample hoisted above branch, node link-check instantiates (imports wgpu/dom/wasi). Helper param type was
         z.wgpu.ShaderStage (not shader_introspect.Visibility). Delivered zimr495.zip + shadowmap.html.
         BLIND/UNVERIFIED (Simon device-verify): (1) shadow-map UV Y convention in WebGPU RTT (matched pbr_fs = NO
         y-flip; if wrong shadow is offset/mirrored); (2) ortho frustum tightness -> acne vs peter-panning (bias tuned
         to pbr values); (3) both floor+cube base_color 0.82 gray so shadow reads as a darker floor patch under the cube;
         (4) two-pass RTT mechanics under beginTextureMode/endTextureMode with manual pipelines into f.gl.pass. If shadow
         wrong first suspects: y-flip (proj_y = 1-proj_y) then bias then light frustum. NEXT id zimr496.



<!-- dup first-copy zimr507 -->
zimr507: COMPTIME two-pass shadow-map PROOF — de-risks the flagship's comptime corner. WORKS, bakes <60s.
         Simon: "tweak the numbers so the comptime bake and render is under 60 seconds." DONE at 28-34s.
         examples/comptime_shadowmap_proof/main.zig (native host exe; the two-pass shadow render is a comptime
         `const`, so BAKE time == COMPILE time -> `zig build comptime-shadowmap-proof -Dautofix=false` is the budget
         gate, and running it dumps comptime_lit.png + comptime_shadowmap.png to build-root for eyeball verify).
         Scene = floor(4v/2t) + one cube(24v/12t, flat per-face normals) + the normalized/rotated bunny proxy,
         MERGED into single positions/normals/COLORS/indices arrays (buildScene(), needs its OWN
         @setEvalBranchQuota(2e9) — it's a separate comptime call). Per-vertex color carried VS->FS so ONE
         depth-tested draw per pass keeps floor/cube/bunny distinct AND depth-correct.
         KEY CORRECTION vs memory: RasterizeOpts.depth_test defaults FALSE, and rasterizeToImage only uses the
         z-buffer when `.depth_test = true` (src/raster_shader.zig:284,546). Merged multi-object scenes MUST pass
         `.{ .front_face = .none, .depth_test = true }` (the old "z-buffer always-on" note was WRONG).
         Inline shaders DepthVs/DepthFs/LitVs/LitFs (mirror src/shaders/depth_* + lit_shadow_*, lifted from
         cpu_shadowmap_test): pass1 depth-in-red into shadow_map [SM*SM*4]u8 (clear white=far, @bitCast from
         [N][4]u8); pass2 lit sampling it via ShadowRef.sampleRed (clamp+nearest+red/255), LitFs bias
         @max(0.015*(1-ndl),0.008), ambient 0.25, proj[1]=1-proj[1] RTT flip. main() = page_allocator +
         std.Io.Threaded, prints stats, z.codecs.png.encode(gpa, pixels[]const u8, w, h)![]u8 -> writeFile.
         TUNABLES (top of main.zig; edit + the grid arg in build.zig to move the budget): shadow_res=64, main_w=96,
         main_h=72, grid=10 (in build.zig ->693 tris); bunny_yaw=2.3, bunny_height=1.4, light_dir={0.40,1.0,0.30}.
         Light ortho tightened to orthographicRh(7,7, 5,13) to bracket the scene (near/far were 0.1/20). NOTE: the
         *0.5+0.5 z-remap in DepthVs/LitFs (kept for parity with the proven CPU path) HALVES shadow-map precision
         under zimr's likely [0,1] WebGPU clip-z (min_red stuck ~169 not ~45); shadow DETECTION is still correct
         (both sides squished identically). Flagship could drop the z-remap for crisper maps IF zm clip-z is [0,1].
         RESULT (native, verified): EXIT=0 ELAPSED=28-34s (<60 ✓); proxy 346v/693t, scene 374v/707t; shadow-map
         min red 169 (<240 ✓); lit-band 3432 px, shadow-band 299 px (both >0 ✓); PNGs eyeball-confirmed: tan bunny +
         blue cube on floor with a coherent cast shadow, and a faint bunny/cube depth silhouette in the map.
         BUILD WIRING (build.zig, in `pub fn build` AFTER native_plot_png_step ~572 where mesh_bake_exe alias(537),
         zimr_native_mod(549), zimrmath_mod(317), host_target(524) are ALL in scope — my first attempt put it in the
         separate tools-setup fn ~2778 where zimr_native_mod is undeclared): csm_proxy_bake runs mesh_bake OBJ path
         on examples/shadowmap/bunny.obj grid=10 -> bunny_proxy import; csm_proof_exe (host, ReleaseFast) imports
         zimr_native_mod + zm + bunny_proxy; step "comptime-shadowmap-proof". Lint: examples/ IS a walk root so the
         proof file is linted (fixed 2 line-length wraps); debug-print rule is src/-only so the native proof prints
         freely. Building WITHOUT -Dautofix=false pulls the whole autofix-lint (fails fast on any violation) — use
         -Dautofix=false for isolated measurement.
         NEXT: build the full flagship examples/shadowmap_sw (GPU=examples/shadowmap/shadowmap.zig already live;
         CPU=cpu_shadowmap_test proof; comptime corner=THIS proof) + launcher entry; switch inline shaders to the
         REAL src/shaders/depth_* + lit_shadow_* (the same-shader-three-ways thesis; helmet proves real engine
         shaders comptime-bake). Harness template = cube_sidebyside.zig.


<!-- dup first-copy zimr523 -->
## zimr523 — hybrid raster+raymarch ships: WAVE 1 renderer/shader work COMPLETE
- NEW src/shaders/hybrid_raymarch_fs (+io): sphere-traced SDF scene (3 smooth-min metaballs orbiting over an analytic checkerboard floor, tetrahedron-gradient normals, sky gradient) with the hybrid handshake — hits are projected through the SAME camera VP the raster pass uses and clip.z/clip.w goes out via frag_depth. NO custom depth linearization on either side (raylib teaches both shaders a near/far formula and hopes they match; ours agree by construction). Misses write depth 1.0.
- NEW examples/hybrid_render: ONE pass, two rendering methods, one depth buffer — the marcher quad first, then 3 raster cubes (honest fog_fs@0) counter-orbiting THROUGH the metaball cluster so every frame shows raster slicing in front of and behind marched geometry. Checkboxes isolate either method (march-only == shaders_raymarching_rendering mechanically). One camera feeds both: VP for the cubes, basis vectors + tan(fov/2) for the ray fan.
- NEW hybrid-render-verify: CPU render through the real shaderMain + population census (sky/light-checker/dark-checker/blob). The census itself had a bug the assertions caught: the sky test (b>r) ran before the floor tests and the floor's slight blue tint (b=r+7) fed the whole floor to the sky bucket — pixel-level replication in python proved the RENDER was perfect (predicted dark cell value 110 matched exactly) and only the classifier order was wrong. Reordered: near-gray tests first, sky requires b>r+20.
- Facts: zm.cross is Vec4-wide (zmath heritage) — ride w=0 through basis math. CPU rasterizer picks the FIRST @Vector(4,f32) Out field and ignores frag_depth (f32) — marcher color-verifies on CPU; depth agreement is GPU-only territory (device verify).
- smoke PASS, corpus refreshed, gate green. WAVE 1 (24 items): renderer & shader features now fully DONE pending device verification of hybrid + depth_writing recheck. Next wave: WAVE 2 — 3D models, animation & loaders (20 items).


<!-- superseded WIP zimr576b (WIP) — BLOOM: all -->
## zimr576b (WIP) — BLOOM: all 4 FS compile through codegen (test rc=0). WGSL verify found a REAL pinned-sampler-vs-UBO binding collision. Diagnosis below.
- Fixed `.emissive` → `.emission` (MaterialMapIndex has emission, not emissive; also .albedo/metalness/normal/roughness/occlusion/emission/height/cubemap/irradiance/prefilter/brdf; aliases diffuse=albedo, specular=metalness).
- `zig build test` rc=0 → ALL 4 bloom FS generate externs + compile to SPIR-V + transpile to WGSL. Typed authoring end-to-end works.
- BUT WGSL verification found a REAL BUG (this is why we verify): a UBO at binding 0 + a pinned Sampler2D COLLIDE. bright_fs WGSL emits: ubo @group(0)@binding(0), src TEXTURE @group(0)@binding(0) [COLLIDES with ubo!], src_sampler @binding(2). composite worse: ubo@b0, scene tex@b0 [collide], scene_samp@b4, bloom tex@b1, bloom_samp@b5.
- ROOT CAUSE: a Sampler2D is ONE combined `zsample2d` handle that zspv --rewrite-samplers-wgsl + spv2wgsl SPLIT into a texture binding + a sampler binding. The codegen's `.pinned.binding` (e.g. 1) controls the SAMPLER's slot after the split; the TEXTURE half keeps its own default (binding 0), which collides with the UBO. So pinning a sampler does NOT reliably place its texture, and the texture defaults into the UBO's slot. Confirmed: codegen emits zm_binding(&src_sampler2d, 0, 1) — a single (group,binding) for the pair — but the split produces tex@0 + samp@2 (not the intended tex@1).
- This is the fragile zspv/spv2wgsl sampler-rewrite machinery (the exact thing PHASES P2-P5 wants to retire). The other IoT sampler shaders don't hit this because their samplers live in group 1 (material group) with NO ubo in group 1 — so tex@1b0/samp@1b1 has nothing to collide with. Bloom is the FIRST case putting a UBO and a sampler in the SAME group.
- OPTIONS for next turn (pick one):
  (A) Put the UBO in its OWN group and textures in another: e.g. ubo_group=0 (b0 alone), samplers default group 1. Post pass = 2 bind groups. Simplest, matches how every other IoT shader already works (ubo g0, samplers g1). Just DELETE the sampler pins + the ubo_group=0 line (let bright/blur default: Inputs→ubo g2? no — need ubo g0 for a post pass w/ no attributes... check uniformGroupForSchema: no Attributes + has Inputs → group 2. So ubo lands g2, samplers g1. Fine — 2 groups, no collision). Host binds group1=textures, group2=ubo.
  (B) Teach the codegen/spv2wgsl to place a pinned sampler's TEXTURE at the pin binding and the SAMPLER at pin+? — a real fix to the rewrite, higher risk, touches the fragile path.
  (C) Investigate whether spv2wgsl already supports an explicit texture-binding pin separate from the sampler.
- RECOMMENDATION: Option A. It needs zero changes to the fragile rewrite path, matches the established ubo-g?/samplers-g1 convention, and a post-process pass having 2 bind groups (uniforms + textures) is totally standard. Drop the ubo_group=0 + all .pinned configs from the 3 bloom FS io files; let the solver place ubo (g2) and samplers (g1) by default; verify tex@g1b0/samp@g1b1 (+ bloom tex@g1b2/samp@g1b3 for composite via Sampler2D_atSlot or default sequential); rewire host for 2 groups.
- Gate so far: test rc=0 (compiles), but WGSL bindings WRONG → NOT shippable yet. No zip this turn (mid-fix). Files ast+lint clean.


<!-- superseded WIP zimr576 (WIP) — BLOOM migra -->
## zimr576 (WIP) — BLOOM migration: all 4 typed FS shaders authored (bright+blur+composite+shared VS). Host wiring next.
- Priority: finish bloom, no manual WGSL, all typesafe. Key unblock (from prior recommendation): the override-constant blocker is sidestepped by making per-pass config a per-pass UBO instead of override/spec constants — clean fit since each is set once per pass. Confirmed the current pipeline_bloom.zig uses override dir_x/dir_y/texel (blur), intensity (composite), threshold (bright): exactly what we replace.
- ALL bloom shader files now authored + ast-valid + lint-clean (7 files):
  * bloom_fullscreen_common_io.zig — Interp{v_uv:Vec2} (named v_uv NOT uv to avoid shadowing the codegen's sampler-accessor `uv` param).
  * bloom_fullscreen_vs{,_io}.zig — shared fullscreen-triangle VS from vertex_index, no vbo/ubo, emits v_uv (y-down). (These 3 pre-existed from the interrupted turn.)
  * bloom_bright_fs{,_io}.zig — threshold/knee pass. ubo_group=0, Ubo{params:Vec}={thresh,..}, Sampler2D(.albedo, pinned group0 binding1). (pre-existed.)
  * bloom_blur_fs{,_io}.zig — NEW. 5-tap separable Gaussian (w 0.227/0.195/0.122, o 1.385/3.231) along per-pass dir. ONE shader for H+V — dir is a UBO value (Ubo{dir:Vec}={dir_x*texel,dir_y*texel,..}), not an override, so same compiled shader serves both directions. ubo_group=0, src Sampler2D(.albedo, pinned g0 b1). ALL 5 samples inlined at shaderMain top (lint rule: no sampler-in-helper — samples must be in shaderMain, not helper fns).
  * bloom_composite_fs{,_io}.zig — NEW. scene + bloom*intensity. ubo_group=0, Ubo{params:Vec}={intensity,..}, TWO textures: scene Sampler2D(.albedo, pinned g0 b1), bloom Sampler2D(.emissive, pinned g0 b3). NOTE each Sampler2D emits texture+sampler, so scene=(tex1,samp2), bloom=(tex3,samp4); host binds the same sampler handle to both slots (old WGSL shared one sampler — layout-equivalent).
- DURABLE LESSON: the [sampler-in-helper] lint rule forbids io.<sampler>(uv) calls inside helper fns — must sample in shaderMain and pass values down. Bit me on the blur's tap() helper; inlined all 5 taps.
- NEXT STEPS (host wiring — the substantial remaining chunk):
  1. Verify each FS transpiles to correct WGSL (build the codegen via `zig build lint`, then build-obj each to spirv → zspv --rewrite-samplers-wgsl → spv2wgsl; confirm bright: ubo@g0b0, tex@g0b1, samp@g0b2; blur same; composite: ubo@g0b0, scene tex@g0b1 samp@g0b2, bloom tex@g0b3 samp@g0b4).
  2. Rewrite examples/pipeline_bloom/pipeline_bloom.zig: delete the 3 inline-WGSL const blocks (bright/blur/composite) + fs_vs; @embedFile the generated .wgsl; build each pass pipeline with shader.Resources(<Schema>) instead of hand-wired BGLs; write per-pass UBOs (bright: {thresh}, blurH: {texel,0}, blurV: {0,texel}, composite: {intensity}); bind scene+bloom textures via Resources sampler slots.
  3. build pipeline-bloom, smoke, check NO REGRESSIONS, zig build test, standalone for device verify.
  4. Update readme REMAINING-INLINE-WGSL scoreboard (drop bloom) + the migration line.
- Gate so far: 4 new/changed files ast-valid + lint 0. NOT yet built through codegen or host — that's next turn. Tree otherwise green (zimr575 guards intact).


<!-- superseded WIP zimr577b (WIP) — BLOOM host -->
## zimr577b (WIP) — BLOOM host-wiring PLAN nailed down (exact API confirmed). Ready to execute next turn.
- Studied pipeline_bloom.zig (362 lines) + its ideal template pipeline_postprocess.zig (the "bloom is built on postprocess" analog, already fully typed). CONFIRMED the exact API to use — this is NOT z.Pipeline (which wants one combined .wgsl w/ vs_main+fs_main + override .constants). Use the TYPED path:
  * `z.shader.loadShaderVF(vs_io, fs_io, .{ .f=f.gpu, .gpa, .vs_wgsl_source=@embedFile("X_vs.wgsl"), .fs_wgsl_source=@embedFile("X_fs.wgsl"), .textures=.{ .<samplerfield>=tex }, .initial_ubo=.{...}, .color_format=.rgba8_unorm, .depth_state=.none, .label })` → returns `z.shader.LoadedShader(fs_io)` wrapping Resources.
  * LoadedShader API: `.pushUbo(f.gpu.queue, .{...})` update UBO; `.setTexture(...)` rebind a sampler; `.bindForDraw(ps)`; `.draw(ps, vcount, 1)`; `.setVertex(ps,0,vbo,size)`. For a fullscreen pass: `z.drawFullscreenShader(f.gl, fs_io, &loaded)` (binds pipeline+ALL bind groups, draws the engine fullscreen tri — works inside beginTextureMode too since it uses app.pass).
  * `.textures=.{ .scene=tex, .bloom=tex2 }` binds samplers BY SCHEMA FIELD NAME (composite has scene+bloom fields → both bound this way).
- BLOOM REWRITE RECIPE (next turn):
  1. Delete the 4 inline-WGSL consts (fs_vs, scene_wgsl, bright_wgsl, blur_wgsl, composite_wgsl) + the texBgl/texBg/fullscreen helpers + z.Pipeline usage.
  2. @embedFile the generated engine WGSL: bloom_fullscreen_vs.wgsl, bloom_bright_fs.wgsl, bloom_blur_fs.wgsl, bloom_composite_fs.wgsl (auto-discovered engine shaders, exposed to all examples via build.zig:803 addAnonymousImport). Import the _io.zig schemas.
  3. Scene pass: reuse examples/pipeline_uniforms_vs{,_io}.zig + a matching fs (like postprocess does with pipeline_uniforms) OR keep a tiny scene — DECISION: reuse pipeline_uniforms (already typed, mat4 transform + pos/color vertex, matches bloom's Vertex). Register bloom with `.shaders=&.{"pipeline_uniforms_vs","pipeline_uniforms_fs",...}` if those are example-shaders, else they're already available. VERIFY vertex layout matches (pos vec2 @0, color vec3 @1).
  4. bright: loadShaderVF(bloom_fullscreen_vs_io, bloom_bright_fs_io, .{ .textures=.{.src=rt_scene.asTexture()}, .initial_ubo=.{.params=.{thresh,0,0,0}} }). blur_h + blur_v: SEPARATE LoadedShaders (UBO baked per-direction to dodge the "can't update UBO between draws in one cmd buffer" hazard — blur_h ubo={texel,0,0,0}, blur_v ubo={0,texel,0,0}). ping-pong src via .setTexture each iter (rt_a→rt_b→rt_a). composite: loadShaderVF(...composite..., .textures=.{.scene=rt_scene.asTexture(), .bloom=rt_a.asTexture()}, .initial_ubo=.{.params=.{intensity,0,0,0}}).
  5. update(): scene→rt_scene (pushUbo transform, draw vbo); bright drawFullscreenShader→rt_a; blur loop (H→rt_b, V→rt_a) via drawFullscreenShader inside beginTextureMode; composite drawFullscreenShader→backbuffer.
  6. window.depth_format stays null (all 2D/fullscreen). rt textures are rgba8_unorm (loadRenderTexture default) — matches .color_format=.rgba8_unorm.
  7. build pipeline-bloom, smoke, check, standalone. Update readme scoreboard: drop bloom from REMAINING INLINE WGSL; note the per-pass-UBO (not override) approach.
- ONE OPEN Q: texel size. Old used override texel=3.5/rt_size baked at pipeline creation. Now it's a UBO value written at init: blur_h.initial_ubo.dir=.{3.5/512,0,0,0}, blur_v=.{0,3.5/512,0,0}. Fine.
- Gate this turn: none (planning + API confirmation only; zimr577 robustness already shipped + gated green). No new code files this turn.



---

## Second pass (Simon-approved): WebGPU-control increments, the @SpirvType migration turns,
and the 14-turn decal saga (condensed into one entry in claude.md).

<!-- webgpu-control zimr288 -->
### NEW PLAN: complete WebGPU control + raygpu parity (zimr288)
- Surveyed raygpu (uploaded zip, 55 examples). Key finding: raygpu's value is the
  app-facing LOW-LEVEL escape hatch (LoadPipeline(wgsl) + VAO/VertexAttribPointer +
  bind-by-name + DrawArrays{,Instanced,IndexedInstanced}, LoadComputePipeline +
  DispatchCompute, LoadRenderTextureEx w/ sampleCount, storage textures). zimr has the
  PLUMBING (gpu.zig descriptor encoder, shader_introspect.zig reflection, bridge
  sample_count + storage-texture binding type 5, Zig->SPIR-V->WGSL, GPU skinning) but
  exposes NONE of it to apps (only PipelineCache, engine-internal).
- Wrote `src/notes/webgpu_control.md`: goal, design principles (Zig shaders default +
  raw WGSL escape hatch; GLSL front end DECLINED), the keystone public API sketch
  (src/material.zig -> z.VertexLayout / z.Pipeline / z.ComputePipeline / z.RenderTexture
  / z.effects.Bloom / z.StorageTexture), a FULL raygpu->zimr coverage matrix (all 55,
  ✅/~/❌/⛔/🚫), and a 6-phase build-out. Made it the Current plan in claude.md;
  physics_demo.md + plot3d.md are paused-not-dropped.
- Biggest gaps to build: pipeline_* family (keystone), storage textures, bloom/post,
  MSAA, texture array/cubemap/mipmap/formats, OBJ loader, forward kinematics, gamepad,
  shader_inspection. N-A: multiwindow, wgvk/vma (their Vulkan backend), headless
  (sw-* covers it). Declined: GLSL input.


<!-- webgpu-control zimr290 -->
### Phase 1 increment 1: the public z.Pipeline API + pipeline_basic (zimr290)
- Created `src/material.zig` (L6 in the DAG) — the keystone public custom-pipeline
  API. `z.Pipeline.init(gpa, f, .{ .wgsl, .layouts, .bind_group_layouts, .topology,
  .blend, .depth, .cull, .samples, .label })` collapses the ~90 lines wgpu_cube_demo
  hand-rolls (createShaderModuleWgsl -> createPipelineLayout -> StateCombo.fromParts ->
  encodeRenderPipelineDescriptor -> createRenderPipeline) into one literal. ONE WGSL
  module serves both stages (raygpu LoadPipeline shape). Methods: bind(ps),
  setVertex(ps, slot, buf, size), drawArrays(ps, n, instances), drawIndexed(ps, ibo,
  count, size, instances). Depthless by default so it composes with the engine's 2D
  pass. `f: anytype` keeps material.zig a leaf (reads f.gpu.device/backbuffer_format/
  depth_format). Re-exports VertexFormat/Topology/Blend/Cull/Depth + VertexAttribute/
  VertexBufferLayout.
- Exported from zimr.zig: `z.material`, `z.Pipeline`, `z.PipelineOptions`,
  `z.VertexLayout` (=gpu.VertexBufferLayout), `z.VertexAttr` (=gpu.VertexAttribute).
- Created `examples/wgpu_pipeline_basic/` — raw-WGSL gradient triangle via z.Pipeline,
  drawn into f.gl.pass (the live 2D pass), composited with an immediate-mode caption.
  AppSpec pattern. Registered in build.zig example list. Proves complete control +
  composition in ~10 lines.
- KEY integration facts (confirmed via cube_demo + gpu_iface): the live pass is
  `f.gl.pass` (a `*z.PassState`); PassState.pass is the raw RenderPassEncoderHandle;
  setPipeline takes `z.shader.RenderPipeline(void,void){ .gpu_handle = h }`; custom
  draws recorded into the pass BEFORE endDrawing's flushBatch composite under the 2D
  batch. The 2D main pass is DEPTHLESS -> a custom pipeline into it must be depth=.none
  (the default) or it hits the has_depth assert -> black frame.
- Verified: lint 0 (both files), `zig build dag-check` (acyclic, material at L6),
  `zig build wgpu-pipeline-basic` clean, standalone built.
- NOTE: zimr289 was lost to an inter-turn repo reset (reverted to zimr288 state) and a
  download-failing zip; re-applied identically and re-shipped as zimr290 with a
  verified zip.
- NEXT: increment 2 = pipeline_uniforms (z.shader.Resources for reflected bind-by-name
  + a UBO/texture/sampler), then vao_multibuffer, pipeline_instancing, pipeline_constants,
  pipeline_settings. readme.html "Complete WebGPU control" section deferred until fuller.


<!-- webgpu-control zimr291 -->
### Fix: custom pipeline composing with 2D flushed garbage (zimr291)
- Device test of pipeline_basic showed the gradient triangle RENDERING (z.Pipeline
  works end-to-end on device!) but a black quad in a corner. Root cause: flushBatch
  deliberately does NOT bind a pipeline (consumer's job, per its own comment); the
  runner binds the 2D pipeline at beginDrawing, but z.Pipeline.bind replaced it
  mid-frame, so endDrawing's flushBatch drew the accumulated 2D batch (the full-screen
  clearViewport rect + caption) through the app's foreign vec2+vec3 vertex layout ->
  misread vertices -> garbage quad.
- ENGINE FIX (benefits every custom-pipeline + 2D composition): App.endDrawing now
  calls renderer_2d.bindForPass(&pass) right before flushBatch to restore the 2D
  pipeline + resources. bindForPass only setPipeline+resources.bind (does NOT clear the
  batch), and the setPipeline dedup makes it ~free when no custom pipeline was bound.
- EXAMPLE FIXES: dropped z.clearViewport (a full-screen OPAQUE 2D rect that, flushing
  after the immediate triangle, would cover it) — the pass `.clear` colour is the
  background now (set window.clear). Aspect-corrected the triangle per-frame (NDC maps
  [-1,1] to the full surface -> stretches on a portrait phone) by scaling the over-long
  axis and re-uploading the 3 verts via queueWriteBuffer (the uniforms example will
  replace this with a UBO projection matrix).
- LESSON for the plan: composing a custom pipeline with the immediate-mode 2D layer
  requires the runner to restore the 2D pipeline before the batch flush; now handled
  centrally. A custom full-screen OPAQUE 2D draw will hide earlier immediate draws
  (deferred-batch ordering) — use the pass clear for backgrounds.
- Verified: lint 0 (example + wgpu_app), dag-check clean, standalone rebuilt.


<!-- webgpu-control zimr292 -->
### Phase 1 increment 2: pipeline_uniforms + bind-group helpers (zimr292)
- Extended src/material.zig with the bind-group side: Pipeline.setBindGroup(ps, group,
  bg); re-exports ShaderStage/LayoutEntry(=shader_introspect.BindGroupLayoutEntry)/
  BindEntry(=gpu.BindGroupEntry); and three helpers wrapping encode+create —
  bindGroupLayout(gpa,f,entries,label), bindGroup(gpa,f,layout,entries,label),
  uniformBuffer(f,bytes,label). material.zig now imports shader_introspect (still L6, no
  cycle). Raw z.gpu.encode* / z.wgpu.create* remain available for finer control.
- Created examples/wgpu_pipeline_uniforms/ — a UBO mat4 transform (spin + aspect) drives
  a custom pipeline; retires pipeline_basic's per-frame vertex re-upload (verts static,
  matrix moves them). Explicit flow: describe layout -> create UBO + bind group -> hand
  layout to z.Pipeline -> per frame write UBO, bind pipeline + group, draw. Column-major
  transform built as [16]f32 (no Mat-layout dependency). Registered in build.zig.
- GOTCHA: the build gates on `zig fmt --check src examples build.zig tools/zimrlint.zig`.
  Hand-aligned matrix literals fail it (fmt strips alignment) -> "maker exited code 1"
  with the real cause buried. FIX: run `zig fmt <files>` before building. ADD TO VERIFY
  ROUTINE: lint 0 AND `zig fmt --check` AND dag-check before every build/ship.
- Verified: lint 0, zig fmt --check clean, dag-check clean, example + standalone built.
- NEXT: vao_multibuffer (multiple vertex buffers / per-instance attrs), then
  pipeline_instancing, pipeline_constants, pipeline_settings (blend/depth/cull/MSAA).


<!-- webgpu-control zimr293 -->
### Cleanup: removed GPU-timing boot log overlay lines (zimr293)
- Removed the three note() boot-log calls in bridge.zig that printed to the on-page
  overlay during boot: "timestamp-query SUPPORTED (GPU timing available)",
  "timestamp-query NOT supported (GPU timing unavailable)", and "GPU timing infra ready
  (timestamp query set + buffers)". The timestamp-query feature detection + GPU-timing
  infra setup logic is UNCHANGED — only the overlay notes are gone (they cluttered the
  standalone page). Verified: lint 0, zig fmt --check clean, dag-check clean, standalone
  rebuilt with the strings absent from the HTML.


<!-- webgpu-control zimr294 -->
### Phase 1 increment 3: vao_multibuffer (zimr294)
- Created examples/wgpu_vao_multibuffer/ — vertex attributes split across SEPARATE
  buffers (positions slot 0, colours slot 1) instead of one interleaved buffer. No new
  API needed: PipelineOptions.layouts already takes multiple VertexBufferLayouts (one
  per slot) and Pipeline.setVertex(slot,..) binds them independently. Demonstrates a
  runtime buffer SWAP: positions stay fixed while slot 1 is rebound between two colour
  palettes every ~1.2s. Reuses the UBO aspect-scale (scale2d, no rotation, upright so
  the swap reads). Registered in build.zig. This is the groundwork for per-instance
  step-mode buffers in pipeline_instancing.
- Lint catches this turn (fixed): [fn-args-multiline] (3-param fn needs each param on
  its own line) + [line-length] (the caption ternary). REMINDER: verify routine is
  zig fmt --check + lint 0 + dag-check before build/ship.
- Verified: fmt clean, lint 0, dag-check clean, standalone built.
- NEXT: pipeline_instancing (per-instance step_mode = .instance on a slot, DrawArrays
  with instance_count, @builtin(instance_index)), then pipeline_constants, pipeline_settings.


<!-- webgpu-control zimr295 -->
### Phase 1 increment 4: pipeline_instancing (zimr295)
- Created examples/wgpu_pipeline_instancing/ — ONE drawArrays(3, 126) paints a 14x9 grid
  of triangles. slot 0 = per-VERTEX shape (step .vertex); slots 1 & 2 = per-INSTANCE
  offset + colour (step .instance). The offset buffer is re-uploaded each frame (sine
  wave in Y) for dynamic per-instance data. No new API — VertexLayout.step_mode already
  exposes .instance, drawArrays already takes instance_count. Reuses UBO aspect-scale.
  Registered in build.zig.
- Verified first pass: fmt clean, lint 0, dag-check clean, standalone built.
- Phase 1 pipeline-API status: pipeline_basic ✓, pipeline_uniforms ✓, vao_multibuffer ✓,
  pipeline_instancing ✓. NEXT: pipeline_constants (override constants), pipeline_settings
  (blend/depth/cull/MSAA). Then Phase 2 (render targets, storage textures, bloom).


<!-- webgpu-control zimr296 -->
### Phase 1 increment 5: pipeline_constants + override-constant plumbing (zimr296)
- NEW PLUMBING (the one Phase-1 piece needing stack work, not just an example):
  * gpu.zig: added `PipelineConstant{name, value:f64}` + `constants: []const
    PipelineConstant = &.{}` on RenderPipelineDescriptor; added writeF64 helper;
    encodeRenderPipelineDescriptor now APPENDS (after sample_count) a u32 count then
    per-constant {writeStr(name), writeF64(value)}. Append-only -> existing callers
    (count 0) and the existing encode test unaffected. Added a round-trip unit test.
  * bridge.zig: added Cursor.f64At (DataView getFloat64, LE, +8); createRenderPipeline
    decodes the trailing constants into a JS object via Reflect.set(obj, nameValue,
    numValue) and sets it as `constants` on BOTH the vertex and fragment stage descriptors
    (only when count>0). Dynamic string keys need Reflect.set (Value.set takes comptime
    keys only).
  * material.zig: PipelineOptions.constants passthrough; re-export Constant =
    gpu.PipelineConstant.
- Created examples/wgpu_pipeline_constants/ — one WGSL with `override tint_r/g/b, ox,
  scl`; THREE pipelines built from it with different constant sets -> three differently
  tinted/placed triangles from one white mesh, no per-draw uniforms. Registered.
- Constants are fixed at pipeline creation (static demo); aspect UBO belongs with
  per-frame data instead, so left out here.
- Verified: fmt clean, lint 0 (gpu/bridge/material/example), dag-check clean,
  `zig build test` PASS (incl. new encoder test), standalone built. NOTE: zig test
  src/gpu.zig standalone fails (module graph) -> use `zig build test`.
- PHASE 1 pipeline family COMPLETE: basic, uniforms, vao_multibuffer, instancing,
  constants. pipeline_settings deferred into Phase 2 (its interesting parts -- MSAA,
  depth -- need the render-target infra). NEXT: Phase 2 (RenderTexture + MSAA + storage
  textures + bloom).


<!-- webgpu-control zimr297 -->
### Phase 2 opener: render-to-texture with a custom pipeline (zimr297)
- ENGINE FIX: endTextureMode now calls renderer_2d.bindForPass(&pass) before flushBatch
  (mirror of the endDrawing fix) so a custom pipeline composes correctly inside an
  OFFSCREEN pass too (otherwise the RT's 2D batch would flush through the foreign vertex
  layout -> garbage). beginTextureMode already repoints f.gl.pass at the RT, so a custom
  z.Pipeline draws into an offscreen target exactly like the screen.
- Created examples/wgpu_pipeline_rendertarget/ — custom pipeline (spinning gradient
  triangle, UBO rotateZ) rendered ONCE into a 480x480 color-only RenderTexture via
  beginTextureMode/endTextureMode, then stamped 3x2 across the backbuffer with
  drawTextureRec tints. "Render once, reuse many." Registered.
- KEY FACTS: loadRenderTexture makes a COLOR-ONLY rt for a 2D app (with_depth =
  depth_format != null) -> offscreen pass is depthless -> depthless custom pipeline binds
  with no depth mismatch. Color type is `zm.Color` (import "zm"), NOT z.Color. RT sampled
  via rt.asTexture() (z.WgpuTexture) + drawTextureRec(gl, tex, sx,sy,sw,sh, dx,dy,dw,dh,
  tint).
- Verified: fmt clean, lint 0, dag-check clean, `zig build test` PASS, standalone built.
- NEXT (Phase 2): sample the RT in a CUSTOM post-process pipeline (texture+sampler bind
  entries: LayoutEntry .{.texture=.{}} / .{.sampler=.{}}, BindEntry .texture_view /
  .sampler, z.wgpu.createSampler) -> a fullscreen effect -> then multi-pass bloom; then
  MSAA (samples>1 RT + resolve), storage textures, and fold in pipeline_settings.


<!-- webgpu-control zimr298 -->
### Phase 2: pipeline_postprocess — RT sampled by a custom pipeline (zimr298)
- Created examples/wgpu_pipeline_postprocess/ — the render texture becomes an INPUT:
  scene (UBO triangle) rendered into a 720x720 RT, then a custom FULLSCREEN pipeline
  samples it (chromatic aberration + vignette) into the backbuffer. The bloom/post
  foundation: a pass whose source is a prior pass's output.
- New material proven: texture + sampler bind entries. post_bgl = {@0 texture (frag),
  @1 sampler (frag)}; post_bg binds the RT's own `color_view` + `sampler` (a
  WgpuRenderTexture ships color/color_view/sampler, texture has render_attachment|
  texture_binding|copy_src usage, so its view is directly sampleable). Fullscreen
  triangle generated from @builtin(vertex_index) -> post pipeline needs NO vertex
  buffer (layouts empty). Scene aspect-corrected for the window before the square RT so
  the full-bleed post (square stretched to screen) is undistorted.
- LayoutEntry shapes used: .{ .texture = .{} } (float/d2), .{ .sampler = .{} }.
  BindEntry: .{ .texture_view = view }, .{ .sampler = handle }.
- Verified: lint 0, fmt clean, dag-check clean, standalone built.
- NEXT: multi-pass BLOOM (bright-pass + separable blur ping-pong between RTs +
  composite) building on this; then MSAA (samples>1 RT + resolve), storage textures,
  fold in pipeline_settings.


<!-- webgpu-control zimr299 -->
### Phase 2 HEADLINE: pipeline_bloom — full multi-pass bloom (zimr299)
- Created examples/wgpu_pipeline_bloom/ — 5 effect passes over 3 RTs: scene->rt_scene;
  bright-pass (luma threshold)->rt_a; separable Gaussian blur ping-pong rt_a<->rt_b x2;
  composite (scene + blurred highlights, additive)->backbuffer. The "complicated effect
  made easy" goal. Exercises the WHOLE Phase 2 surface in one example: render-to-texture,
  texture+sampler bindings, MULTI-texture bind group (composite: 2 textures + sampler),
  and override constants.
- Shared fullscreen-triangle VS concatenated into each effect shader via `fs_vs ++ ...`
  (Zig string concat). The two blur passes are ONE WGSL specialised into H and V
  pipelines by override constants (dir_x/dir_y/texel) -> no per-pass UBO, which also
  sidesteps the "writeBuffer can't interleave with encoder draws in one command buffer"
  hazard (all queue writes apply before the single submit, so a UBO updated between
  draws would show only its LAST value to every draw). bright threshold + bloom
  intensity are constants too.
- KEY: blur ping-pong bind groups are reusable across iterations (blur_h always reads
  rt_a, blur_v always reads rt_b; iteration returns data to the same RTs). Each pass is
  begin/endTextureMode (the endTextureMode 2D-rebind fix makes the empty 2D batch flush
  harmlessly). Composite draws into the backbuffer pass reopened by the last
  endTextureMode.
- Verified: fmt clean, lint 0 (first pass), dag-check clean, standalone built.
- Phase 2 status: rendertarget ✓, postprocess ✓, bloom ✓. NEXT: MSAA (samples>1 RT +
  resolve target), storage textures (compute writes a texture), fold in pipeline_settings.


<!-- webgpu-control zimr300 -->
### Bloom tuning for visibility (zimr300)
- Device test: bloom WORKING but subtle/lopsided — only the green corner (luma ~0.72)
  cleared threshold 0.55; red (~0.51) and blue (~0.53) fell below, and the near-fullscreen
  triangle left little dark margin for a halo. Tuned: smaller brighter triangle (verts
  ~0.45, colours pushed up) for dark margin, threshold 0.55->0.30 (all corners bloom),
  blur texel 1.5px->3.5px (wider), intensity 1.4->2.0, blur iters 2->3. These are all
  override constants + a const, so it was a pure value tweak.
- LESSON: bloom threshold must sit BELOW the scene's per-corner luminance or the effect
  gates unevenly; demo scenes want bright elements on a dark field with margin.
- Verified: fmt clean, lint 0, standalone rebuilt.


<!-- webgpu-control zimr301 -->
### pipeline_settings: blend modes (zimr301)
- Created examples/wgpu_pipeline_settings/ — the deferred Phase-1 example. Same cluster
  of 3 overlapping translucent RGB triangles drawn TWICE: left .blend=.alpha (composites),
  right .blend=.additive (sums toward white in overlaps). No new API — PipelineOptions
  already has .blend/.depth/.cull/.samples. Two pipelines share one WGSL + one aspect UBO;
  the horizontal offset is an override constant `ox` (-0.5 / +0.5) so the single shared
  UBO is read identically by both draws (no per-draw UBO rewrite hazard). Confirmed the
  bridge blendStateFor handles none/alpha/additive/multiply/premultiplied.
- MSAA (.samples) deferred to its own plumbing increment (needs a multisampled target +
  resolve; the begin_render_pass extern has no resolveTarget and TextureDesc has no
  sample_count -> core extern change, highest blast radius).
- Verified: fmt clean, lint 0, dag-check clean, standalone built.
- STORAGE TEXTURES feasible as next (lower risk than MSAA): TextureUsage.storage_binding,
  wgpu.createComputePipeline, compute_pass set_pipeline + dispatchWorkgroups all already
  exist -> additive material.zig ComputePipeline + storage texture, no core extern change.
- Phase 2 status: rendertarget ✓ postprocess ✓ bloom ✓ settings(blend) ✓. NEXT: storage
  textures (compute -> texture), then MSAA.


<!-- webgpu-control zimr302 -->
### Phase 2: pipeline_storage — compute writes a storage texture (zimr302)
- Created examples/wgpu_pipeline_storage/ — a COMPUTE shader writes a plasma into an
  rgba8unorm STORAGE TEXTURE (textureStore), then a fullscreen render pipeline samples it.
  The compute<->render bridge: GPU-generated texture, no CPU upload.
- Built with z.wgpu primitives (no new material API yet, to de-risk before device test):
  createTexture usage {storage_binding, texture_binding}; material.bindGroupLayout with a
  storage_texture entry {access=.write_only, format=.rgba8_unorm, visibility=.{compute=true}}
  (gpu.zig encodes tag 5, bridge decodes write-only rgba8unorm); createPipelineLayout +
  createShaderModuleWgsl + createComputePipeline(device, layout, module, "cs_main", label).
- ONE-SHOT dispatch on a DEDICATED encoder in init: createCommandEncoder ->
  compute_pass.begin/setPipeline/setBindGroup/dispatchWorkgroups(.{x,y}) /end ->
  finishCommandEncoder -> queueSubmit. Done on its own encoder because compute and render
  passes can't be open at once and the runner holds the frame's render pass open during
  update. Compute API: z.wgpu.compute_pass.{begin,setPipeline,setBindGroup,
  dispatchWorkgroups(Dispatch{x,y=1,z=1}),end}.
- Verified: fmt clean, lint 0, compiles, dag-check clean, standalone built. NOT yet
  device-confirmed (can't GPU-test compute/storage here) — needs screenshot check.
- ONCE CONFIRMED: promote a z.ComputePipeline + storage-texture helper into material.zig
  (createComputePipeline wrapper + one-shot dispatch convenience). Then MSAA (core
  begin_render_pass extern change for resolveTarget + TextureDesc.sample_count) last.
- Phase 2: rendertarget ✓ postprocess ✓ bloom ✓ settings ✓ storage (pending device) | MSAA next.


<!-- webgpu-control zimr303 -->
### z.ComputePipeline promoted into material.zig (zimr303)
- DEVICE-CONFIRMED zimr302: the compute->storage-texture->sample plasma rendered (full
  rainbow). So promoted the proven path into the public API (material.zig):
  - z.material.StorageTexture + z.material.storageTexture(f, w, h, label) — rgba8unorm
    texture with STORAGE_BINDING|TEXTURE_BINDING (one texture serves compute write + render
    read; rgba8unorm is the core write-only storage format and is filterable).
  - z.ComputePipeline (= material.ComputePipeline, exported from zimr.zig) — Options{wgsl,
    entry="cs_main", bind_group_layouts, label}; .init mirrors z.Pipeline (createShaderModule
    -> createPipelineLayout -> createComputePipeline). .dispatch(f, bind_group, groups:
    wgpu.compute_pass.Dispatch{x,y=1,z=1}) runs ONCE on its own encoder (createCommandEncoder
    -> compute_pass begin/setPipeline/setBindGroup/dispatchWorkgroups/end -> finish ->
    queueSubmit) — the right shape for a fill outside the frame render pass.
- Refactored examples/wgpu_pipeline_storage to USE the new API: ~30 lines (createTexture/
  view/layout/module/pipeline/encoder/pass/dispatch/finish/submit) collapsed to ~12. Same
  WGSL + flow as the confirmed build, so behaviour is identical.
- Verified: fmt clean, lint 0, dag-check clean, `zig build test` PASS, standalone built.
- Phase 2: rendertarget ✓ postprocess ✓ bloom ✓ settings ✓ storage ✓ (+ z.ComputePipeline
  API). REMAINING: MSAA — needs core begin_render_pass extern + TextureDesc.sample_count +
  resolveTarget; highest blast radius, do carefully/last.


<!-- webgpu-control zimr304 -->
### Phase 2 FINAL: MSAA — sample_count + resolveTarget plumbing + example (zimr304)
- ADDITIVE core plumbing (existing paths untouched, all new args trailing w/ safe defaults):
  - wgpu.TextureDesc.sample_count: u32 = 1; threaded through js_device_create_texture
    extern (+wrapper) -> bridge jsDeviceCreateTexture sets desc.sampleCount only when >1.
  - render_pass begin gains resolve_view: threaded wgpu.render_pass.BeginDesc.resolve_view
    -> wgpu_js.begin_render_pass inline (+10th arg) -> BOTH js_encoder_begin_render_pass
    extern decls (top-level ~350 AND wgpu_externs ~1244 must stay signature-identical) ->
    bridge jsEncoderBeginRenderPass sets att.resolveTarget when resolve_view != 0. Also
    gpu_iface.BeginRenderPassDesc.resolve_view -> Backend.beginRenderPass passes it.
  - INVARIANT: each extern's arg count must equal its bridge impl's f64 arg count (runtime
    link, NOT compile-checked). create_texture 8 args; begin_render_pass 10 args. Verified.
- REGRESSION-TESTED (core extern change, can't GPU-test): fmt clean, lint 0, dag-check clean,
  `zig build test` PASS, existing wgpu-pipeline-bloom rebuilds clean. Existing callers pass
  default 0/1 -> bridge skips resolveTarget / sampleCount -> identical behaviour by construction.
- Created examples/wgpu_pipeline_msaa/ — same rotating high-contrast cyan triangle into 220^2
  targets, magnified side by side: LEFT 1x (aliased, via beginTextureMode) vs RIGHT 4x MSAA
  (4-sample color tex resolved into a 1-sample sampleable RenderTexture). MSAA pass is
  SELF-MANAGED on its own encoder (createCommandEncoder -> render_pass.begin with
  resolve_view -> construct PassState{.pass=raw} -> pipeline draw -> render_pass.end ->
  finish -> queueSubmit) because a multisampled+resolve attachment can't go through
  beginTextureMode and passes can't share an open encoder. msaa_tex = createTexture
  {render_attachment only, sample_count=4, rgba8_unorm}; pipelines differ only by .samples
  (1 vs 4); rgba8_unorm == backbuffer_format (confirmed via bloom) so formats match.
- KEY: z.PassState is constructible as `.{ .pass = raw }` (all other fields default). Two
  pipelines from one WGSL differing only by .samples (the PipelineOptions knob from
  pipeline_settings). NOT yet device-confirmed — needs screenshot.
- PHASE 2 COMPLETE: rendertarget ✓ postprocess ✓ bloom ✓ settings ✓ storage ✓ (+z.ComputePipeline)
  msaa ✓(pending device). NEXT: readme.html "Complete WebGPU control" section; then Phase 3+
  (texture array/cubemap/mipmap, models/OBJ, input/gamepad, shader inspection).


<!-- webgpu-control zimr305 -->
### readme.html "Complete WebGPU control" section (zimr305)
- DEVICE-CONFIRMED zimr304: MSAA works (left 1x clearly stair-stepped, right 4x smooth).
  PHASE 2 fully device-confirmed: rendertarget, postprocess, bloom, settings, storage, msaa.
- Consolidation (the deferred plan item): added <h3 id="pipelines">Complete WebGPU control
  (custom pipelines)</h3> to src/web/readme.html after the webgpu-layer section (4 paras:
  z.Pipeline + PipelineOptions; bind-group helpers + the basic/uniforms/vao/instancing/
  constants/settings family; render targets -> rendertarget/postprocess/bloom; z.ComputePipeline
  + storageTexture -> storage, and MSAA -> msaa). Added a "custom pipelines" nav link to the
  toplinks TOC. Self-contained HTML (1 inline <style>, 0 external css) so it renders standalone.
- Verified: section + nav present, <p> tags balanced, 26 h3 total, readme intact.
- NEXT (Phase 3+, all fresh capability arcs): texture features (array/cubemap/mipmap/formats),
  models (OBJ loader/forward kinematics), input/core (gamepad, cursor, benchmarks surfacing the
  profiler), shader inspection. plot3d.md + physics_demo.md still paused-not-dropped.


<!-- webgpu-control zimr306 -->
### Phase 3 opener: pipeline_sampler — texture sampling modes (zimr306)
- Created examples/wgpu_pipeline_sampler/ — one checker+gradient pattern (painted by COMPUTE
  into a storage texture, reusing z.material.storageTexture + z.ComputePipeline) sampled four
  ways in a 2x2 grid, UVs 0..2.5: nearest/repeat, linear/repeat, linear/clamp, linear/mirror.
  Filter difference (hard texel blocks vs smooth) + address difference (tile / hold edge /
  flip) both visible. ZERO new plumbing — SamplerDesc already has mag/min_filter_linear +
  AddressMode{clamp_to_edge,repeat,mirror_repeat}, all wired in bridge createSampler.
- Shape: one render pipeline (pos+uv quad), one shared aspect UBO (read by all draws, same
  value -> no hazard), 4 bind groups differing only in the sampler at binding 2, 4 quad VBOs
  (design-space centers, UV 0..2.5 baked; vs applies aspect like pipeline_settings). Labels
  placed by mapping design center -> screen px.
- Verified: fmt clean, lint 0, dag-check clean, standalone built.
- Phase 3 remaining (need core TextureDesc plumbing like MSAA did): mipmaps (mip_level_count
  + createTextureView base-mip + sampler lod + mip-gen passes), texture arrays
  (depthOrArrayLayers + array view dim), cubemaps (6 layers + cube view; note wgpu_skybox
  already exists), texture formats. Then Phase 4 models, 5 input, 6 shader inspection.


<!-- webgpu-control zimr307 -->
### Phase 3: pipeline_mipmap — mip chain + LOD selection (zimr307)
- ADDITIVE plumbing (existing paths untouched, trailing args / new fn):
  - wgpu.TextureDesc.mip_level_count: u32 = 1 -> create_texture extern (+wrapper) ->
    bridge sets mipLevelCount when >1.
  - wgpu.createTextureViewMip(tex, base_mip, count) -> NEW extern js_texture_create_view_mip
    + bridge jsTextureCreateViewMip (createView with baseMipLevel/mipLevelCount), registered.
  - SamplerDesc.mipmap_filter_linear: bool = false -> create_sampler extern (+wrapper) ->
    bridge sets mipmapFilter "linear"/"nearest".
  - REGRESSION: fmt clean, lint 0, dag-check clean, `zig build test` PASS, wgpu-pipeline-sampler
    rebuilds clean. Existing callers default (1 / false) -> bridge skips -> identical behaviour.
- Created examples/wgpu_pipeline_mipmap/ — 256^2 texture, 9 mip levels, each painted a
  DISTINCT hue by COMPUTE (one dispatch per level; storage view = createTextureViewMip(tex,L,1);
  hue derived from textureDimensions so no per-level uniform). Drawn on a perspective ground
  plane (manual perspective+lookAt+mul4 mat helpers in the example) -> the GPU picks the LOD
  from UV derivatives so distance = mip level -> the road shows the chain as colour bands.
  Sampler mipmap_filter nearest -> crisp bands. Depthless custom pipeline (single plane, no
  occlusion needed).
- KEY: storage texture with mip_level_count>1 + per-level storage views works; each level's
  dispatch sized (dim>>L + 7)/8. createTexture used directly (z.material.storageTexture
  hardcodes mip 1). NOT yet device-confirmed (mip selection only runs on GPU) — screenshot.
- Phase 3: sampler ✓ mipmap ✓(pending device). REMAINING: texture arrays
  (depthOrArrayLayers + d2_array view), cubemaps (wgpu_skybox exists), formats. Then Phase 4
  models, 5 input, 6 shader inspection.


<!-- webgpu-control zimr308 -->
### Phase 3: pipeline_array — 2D texture arrays + BGL view_dimension (zimr308)
- DEVICE-CONFIRMED zimr307: mipmap road gorgeous (clean colour bands receding, magenta near
  -> blue far). mip_level_count + createTextureViewMip + LOD selection all work.
- ADDITIVE plumbing for arrays:
  - BGL BLOB FORMAT CHANGE (gpu.zig encoder + bridge decoder, updated in lockstep — internal
    blob, safe): each entry now emits a 5th u32 `view_dim` (@intFromEnum of texture/
    storage_texture .view_dimension; else 0). Bridge decoder reads it + viewDimStr() maps
    0->1d 1->2d 2->2d-array 3->cube 4->cube-array 5->3d, set on texture (type 4) +
    storageTexture (type 5) entries. Existing entries default .d2 (=1) -> "2d" == old hardcode.
    FIXED the gpu.zig unit test "encodeBindGroupLayoutEntries emits expected bytes" (20->24
    bytes, asserts view_dim field). This is why src changes MUST run `zig build test`.
  - wgpu.TextureDesc.array_layers -> create_texture extern (+wrapper) -> bridge sets
    depthOrArrayLayers. wgpu.createTextureViewArray(tex, layer_count) -> new extern
    js_texture_create_view_array + bridge (createView dimension="2d-array", arrayLayerCount),
    registered.
  - REGRESSION: fmt clean, lint 0, dag-check clean, `zig build test` PASS (after test fix),
    bloom + sampler rebuild clean.
- Created examples/wgpu_pipeline_array/ — 96^2 texture, 4 layers, each a distinct pattern
  (radial / stripes / checker / gradient) painted by COMPUTE via texture_storage_2d_array
  (one dispatch z=4, gid.z = layer). Render: ONE pipeline samples texture_2d_array; the layer
  index is a per-vertex f32 attribute (flat-interpolated to u32), so ONE drawArrays(24) draws
  a 2x2 grid each reading a different layer. ONE 2d-array view (createTextureViewArray) bound
  for BOTH the compute write and the sampled read. BGL entries declare view_dimension=.d2_array.
- NOT device-confirmed (array indexing only runs on GPU) — screenshot.
- Phase 3: sampler ✓ mipmap ✓ array ✓(pending device). Cubemaps: wgpu_skybox exists. Formats:
  could add later. Phase 3 essentially covered. NEXT: Phase 4 models (OBJ), 5 input, 6 shader
  inspection — or revisit paused plot3d.md / physics_demo.md.


<!-- @SpirvType migration zimr337 -->
**zimr337 — doc embedded where it can't be lost + P3 mostly-done but BLOCKED:**
- The compiler-interface contract is now a condensed self-sufficient block at the TOP of
  `src/spv2wgsl.zig` (the readme's "heart" file) — survives even if `src/notes/` is dropped.
- P1 helper REFINED to the WGSL model: WGSL has NO combined sampler, so `Texture2D()` is a
  SEPARATE sampled `OpTypeImage` (`.sampled = f32` → `texture_2d<f32>`) + `Sampler()`, paired
  by `OpSampledImage` inside an **`inline`** `sampleLod(tex, samp, uv)` (must be `inline` — no
  spirv-opt pass in the pure-Zig pipeline). Added `sampler(name,set,bind)`.
- P3 is mostly ALREADY DONE: spv2wgsl already lowers `OpImageSampleImplicitLod`→`textureSample`
  and splits images. Proven: the @SpirvType shader → native `textureSample(tex, samp, uv)` with
  `texture_2d<f32>`+`sampler`.
- ⚠ **NEW BLOCKER (P3): @extern opaque descriptors fold to `OpUndef`.** An @extern whose pointee
  is a zero-bit opaque type (image/sampler) never materializes as a descriptor `OpVariable` —
  `CodeGen.zig constantNavRef` returns `constUndef` for `!hasRuntimeBits` BEFORE `addFunctionDep`.
  So the binding silently vanishes; spv2wgsl gets an undef texture. `color`/`uv` survive (real
  bits). The behavior test misses it (only `_ = x`'s the externs, never uses one). Documented in
  the spv2wgsl header + interface doc with workaround candidates (compiler fix / asm-declared
  OpVariable / stay on `zsample2d`). The zm helpers are the correct shape + compile + lint-clean,
  but are NOT usable end-to-end until this is resolved; the old `zsample2d`/`zspv_rewrite` path
  stays the working sampler path. Host-safe (zimrmath still compiles wasm32; helpers stay lazy).


<!-- @SpirvType migration zimr338 -->
**zimr338 — STORAGE BUFFERS UNBLOCKED END-TO-END (first working @SpirvType resource path):**
- The OpUndef blocker is SPECIFIC to zero-bit opaque types. A storage-buffer struct has runtime
  bits, so its @extern MATERIALIZES as a real `var<storage, read_write>` binding (confirmed:
  OpVariable sc=12 + Binding/DescriptorSet decorations). Samplers/images stay BLOCKED.
- Plain-Zig `buf.items[i]` mis-lowers on 956 ("cannot perform pointer cast '*Buf' to '*RA'"), so
  access is via asm `OpAccessChain` (field 0 = runtime array, then element i).
- spv2wgsl PANICKED on `OpTypeRuntimeArray` ("expected type id, got kind value") — FIXED by adding
  `emitTypeRuntimeArray` (emits `array<ELEM>`, registers `.type_array` kind, extra_b=0) + the
  `.TypeRuntimeArray` switch case. Corpus clean, NO REGRESSIONS.
- NAME-COLLISION bug (same class as zimr333 `arr`): both buffers came out named `buf` (the inline
  asm `%buf` param name leaks as the FIRST OpName, real `src`/`dst` LAST on 956). GENERALIZED the
  spv2wgsl `.Name` rule to "prefer kbuf_, else LAST-wins" (`if (name_is_kbuf or !existing_is_kbuf)`)
  → correct collision-free `src`/`dst`. Corpus-verified safe.
- New zm helpers (after `imageStore`): `StorageBuffer(Elem)` = `extern struct { items: @SpirvType
  runtime_array }`, `StorageBufferPtr(Elem)`, `storageBuffer(Elem,name,set,bind)`, `inline ssboLoad`
  /`ssboStore` (asm OpAccessChain). Proven via `spike_ssbo_shader.zig` → valid WGSL, distinct
  bindings. Host-safe (lazy). Lint 0, wgpu-check green.
- NEXT: wire a real example off inline-WGSL storage buffers (`wgpu_pipeline_storage` /
  `wgpu_forward_kinematics`) onto these helpers + device-verify; expose runtime_array `.len`.


<!-- @SpirvType migration zimr339 -->
**zimr339 — sampler workaround DEAD on 956; builtins WORK; sampler-free migration is unblocked:**
- ❌ asm-declared global `OpVariable` workaround for the sampler OpUndef blocker is DEAD on 956:
  declaring ANY non-Function `OpVariable` in body inline-asm SEGFAULTS codegen (exit 139),
  confirmed for both a zero-bit opaque image AND a plain u32. So both sampler routes
  (@extern→OpUndef, asm→segfault) need a COMPILER FIX. Samplers/storage-textures stay blocked
  until a newer nightly. (Recorded in interface-doc §4 workaround list.)
- ✅ BUILTINS WORK: `@import("std").spirv` gives `vertex_index`/`instance_index` (u32 inputs),
  `position_out`/`position_in` (vec4). They have runtime bits → materialize → translate to
  `@builtin(vertex_index)` / `@builtin(position)`. Proven: a procedural `vertex_index` triangle
  → valid `@vertex` WGSL. Canary: `src/notes/spikes/spike_vertex_index.zig`.
- ⚠ GOTCHA: vertex entry callconv is the BARE tag `callconv(.spirv_vertex)` (no options);
  fragment/kernel take options (`.{ .spirv_fragment = .{} }`, `.{ .spirv_kernel = .{x,y,z} }`).
- ⇒ FEASIBILITY ESTABLISHED: everything except samplers/storage-textures now works via @SpirvType
  (builtins ✓, uniforms ✓ runtime-bits, storage buffers ✓ zimr338). The remaining manual WGSL is
  concentrated in `src/draw3d.zig`: the textured 2D shader (~L215-243, sampler → BLOCKED) plus
  SAMPLER-FREE shaders that ARE migratable now — sky (uniform-only, ~L272-296) and the particle/
  density shaders (uniform + `var<storage>` + vertex_index/instance_index, ~L5341 / ~L5504). The
  other shader families (`src/shaders/*_io.zig`: cube3d/lambert/pbr) are ALREADY pure-Zig via the
  `shader_interface` DSL (no inline WGSL).
- NEXT: migrate a sampler-free draw3d shader (sky or particle) onto @SpirvType end-to-end —
  needs the draw3d pipeline wiring (currently takes WGSL strings) to accept a compiled-Zig shader,
  and may need the `shader_interface` DSL extended with builtin + storage-buffer declarations
  (it currently models attributes/uniforms/samplers, not builtins or `var<storage>`).


<!-- @SpirvType migration zimr340 -->
**zimr340 — SKY SHADER PROVEN MIGRATABLE end-to-end (first real sampler-free WGSL elimination):**
- Wrote `draw3d.zig`'s gradient skybox VS+FS as DIRECT `@SpirvType` Zig (NOT via the codegen DSL,
  which lacks builtin/storage support) and ran both through compile → spv2wgsl. Result is a clean
  drop-in: VS → `@group(0)@binding(0) var<uniform> u` + `@builtin(vertex_index)` in +
  `@builtin(position)`/`@location(0) dir` out + `@vertex fn main`; FS → same uniform + `dir` in /
  `color` out + `@fragment`, with `zm.normalize`/`zm.clamp01` lowered as functions. The uniform
  binding MATERIALIZES (struct has runtime bits — same reason storage buffers work, unlike opaque
  samplers). Now SHIPPED as `src/shaders/skybox_{vs,fs}.zig` (see zimr342; the sky spikes were deleted).
- RECIPE for a sampler-free shader → no manual WGSL: `@extern(*addrspace(.uniform) const Ubo,
  .{.name=…,.decoration=.{.descriptor=.{.set,.binding}}})` for the UBO (load the whole struct
  `u.*` then read fields — avoids the per-field mis-lower seen on storage buffers); `@import("std")
  .spirv` for `vertex_index`/`position_out`; `@extern` `.location` for varyings/outputs; bare
  `callconv(.spirv_vertex)` / `.{.spirv_fragment=.{}}`; import `zm` for math. spv2wgsl already
  lowers all of it.
- REMAINING to actually land it in the engine (build-wiring, NOT shader work): the build's shader
  pipeline (build.zig ~L648) auto-scans `src/shaders/*.zig` and REQUIRES a `_io.zig` schema +
  generates an externs module — a direct/schema-less shader doesn't fit. So either (a) add a
  build path that compiles a plain shader `.zig` → `.wgsl` with no schema (simplest for these
  procedural shaders), or (b) extend `shader_interface`/`shader_codegen` with builtin + `var<
  storage>` declarations. Then drop `skybox_{vs,fs}.zig` into the build and swap draw3d's inline
  `skybox_vs_wgsl`/`skybox_fs_wgsl` for `@embedFile("skybox_{vs,fs}.wgsl")` (mirrors how cube3d
  already embeds its generated WGSL). Same recipe then clears the particle/density shaders
  (`var<storage>` + instance_index). Only the TEXTURED 2D shader stays blocked (sampler).


<!-- @SpirvType migration zimr341 -->
**zimr341 — CORRECTION to "textured shader blocked": the OLD zspv_rewrite sampler path WORKS on 956.**
The @SpirvType sampler block is NOT a hard wall — it only blocks the *clean/new* path. The PRE-956
sampler mechanism is fully alive: a shader declares a u32 PLACEHOLDER `extern const X_sampler2d: u32
addrspace(.constant)` (materializes — u32 has runtime bits, so NO OpUndef bail) + `zm.zsample2d(X,
uv)` (a `noinline` fn → survives as an `OpFunctionCall`), then `zspv --rewrite-samplers-wgsl
--sampler-group=N` does SPIR-V BINARY SURGERY turning the placeholder into a real
`OpTypeSampledImage` and the call into `OpImageSampleImplicitLod`. Because the rewrite operates on
the .spv AFTER the compiler, it is IMMUNE to the compiler's opaque-type limitations.
- PROVEN end-to-end on 956 with a controlled shader (`src/notes/spikes/spike_sampler_oldpath.zig`):
  build-obj → zspv rewrite → spv2wgsl yields `@group(1)@binding(0) var texture0: texture_2d<f32>;
  @group(1)@binding(1) var texture0_sampler: sampler;` + `textureSample(...)`. NO spirv-opt needed
  (the stale doc-comments mention a "limited spirv-opt pass list"; the C++ tool is gone and the
  placeholder survives `build-obj -O ReleaseFast` on its own). This is also the path pbr/lambert/
  cube3d already use — they sample textures, are pure-Zig, and build green on 956.
- ⇒ NO shader is forced into hand-written WGSL. Full all-Zig coverage TODAY via a hybrid:
  @SpirvType for uniforms/builtins/storage/IO (sky/particle), zsample2d+zspv_rewrite for textures
  (the draw3d 2D textured shader). The @SpirvType-sampler arc is now a CLEANLINESS optimization
  (drop the binary-rewrite stage once the compiler emits opaque @extern descriptors), NOT a blocker.


<!-- @SpirvType migration zimr342 -->
**zimr342 — SKYBOX MIGRATED to pure Zig + VALIDATED through the real build (first inline-WGSL elimination):**
- `src/shaders/skybox_vs.zig` + `skybox_fs.zig` now exist as DIRECT `@SpirvType` shaders (no `_io.zig`
  schema). `src/draw3d.zig` swapped the inline `skybox_vs_wgsl`/`skybox_fs_wgsl` strings for
  `@embedFile("skybox_{vs,fs}.wgsl")`. `zig build wgpu-check` → `✓ NO REGRESSIONS`, transpile-fail 0.
- BUILD-WIRING RECIPE (proven, ZERO build.zig changes needed for direct shaders):
  - `collectShaderFiles` globs `*_vs.zig`/`*_fs.zig` under src/examples/tests → drop the file in and
    it's auto-discovered. Entry MUST be `export fn entry(...)` (pipelines use `.vs_entry_point="entry"`).
  - The build loop detects a missing `<name>_io.zig` → `shader_io=null` → ShaderPipeline skips codegen
    and just does build-obj → zspv (no-op without samplers) → spv2wgsl → emits `<name>.wgsl`, wired as
    an anonymous import. `zm` is always available (`--dep zm`); `@import("std").spirv` for builtins.
  - Verify a shader fast WITHOUT a full build: `zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2
    -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv -femit-bin=/tmp/x.spv --dep zm -Mroot=src/shaders/
    <name>.zig -Mzm=src/zimrmath.zig` then run spv2wgsl on it (mirrors the build exactly).
- ⚠ LINT/FMT GOTCHA (cost a build cycle): the build's `zig fmt --check src` + `zimrlint` scan ALL of
  src INCLUDING `src/notes/spikes/*.zig`. Shaders/spikes must obey zimr style: every local TYPED
  (rule 2), no qualified `zm.x` in bodies (bind `const x = zm.x;` at file scope, rule no-qualified-zm),
  ≤120 cols. Run `zig fmt --check src` AND lint over new spike/shader files BEFORE a full build. (The
  superseded sky spikes were deleted; `spike_vertex_index.zig` was fmt'd.)
- NEXT (same recipe): `points`/`fluid_discs` (storage buffer + builtins → direct @SpirvType; entry
  points are `vs_main`/`fs_main`, and they're single-module VS+FS — keep that or update the pipeline's
  `.vs_entry_point`), then `billboard` (sampler → zsample2d + zspv rewrite). Then delete the remaining
  inline `*_wgsl` constants. Optional last: `wgpu_smoke_test.triangle`.


<!-- @SpirvType migration zimr343 -->
**zimr343 — POINTS migrated to pure Zig + build-green; skybox+points standalones out for device-verify:**
- `src/shaders/points_vs.zig` + `points_fs.zig` (direct `@SpirvType`): uniform + READ-ONLY storage
  `positions[instance_index]` + vertex_index/instance_index → instanced gradient quads. KEY: spv2wgsl
  auto-emits `var<storage, read>` for the VERTEX stage (spv2wgsl.zig:1759 — WebGPU forbids writable
  storage in vertex), so the existing read-write `zm.storageBuffer`/`ssboLoad` helpers work unchanged.
  Used `zm.ssboLoad` (asm OpAccessChain; plain indexing mis-lowers). Corners via arithmetic selects
  (avoid runtime array-index lowering risk). `draw3d.zig` `DrawPoints` swapped points_wgsl → two
  `@embedFile` modules, entry `entry`, `vs_module`/`fs_module`. `zig build wgpu-check` → NO REGRESSIONS,
  wgpu_smoke PASSED.
- GOTCHA: single-letter `const U` trips lint `screaming-const` → name uniform structs `Uniforms`/PascalCase.
- STANDALONES built (`-Dmode=release`) for Simon to eyeball (can't device-verify in sandbox):
  `wgpu_skybox.html` (skybox), `wgpu_compute_particles.html` (DrawPoints; clean — doesn't touch
  fluid_discs). If both render right, skybox+points are confirmed on-device.
- REMAINING inline WGSL in draw3d: `billboard_vs/fs` (sampler → zsample2d+zspv), `fluid_wgsl`
  (2 storage buffers + `discard`/`smoothstep`/`length` in FS — needs a discard mechanism; investigate
  std.spirv/asm OpKill). Then delete leftover `*_wgsl` consts. Optional: `wgpu_smoke_test.triangle`.


<!-- @SpirvType migration zimr347 -->
**zimr347 — billboard migrated (FIRST direct sampler + vertex-attribute shader). Build-green, corpus-green.**
- src/shaders/billboard_vs.zig: direct @SpirvType VS with VERTEX-BUFFER ATTRIBUTES (p@0 vec3, uv@1
  vec2, col@2 vec4) + camera UBO (group0/binding0, Cam{vp:[4]vec4} mirrors Cube3D cam's leading mat4)
  → clip = mulMatVec(vp, vec4(p,1)); passes uv/col to FS (o_uv@0, o_col@1). CONFIRMED vertex attributes
  work in the schema-less direct path (first direct shader to use them; skybox/points used builtins).
- src/shaders/billboard_fs.zig: direct SAMPLER FS via the proven path — `extern const tex_sampler2d:
  u32 addrspace(.constant)` placeholder + `zm.binding(&tex_sampler2d, 1, 0)` + `zm.zsample2d(...)`.
  `zspv --rewrite-samplers-wgsl` (auto in the build loop, reads the zm.binding decoration — NO
  --sampler-group override needed) → `@group(1)@binding(0) var tex: texture_2d<f32>;
  @group(1)@binding(1) var tex_sampler: sampler;` + textureSample. EXACTLY matches the host per-texture
  bind group (group1 tex@0 smp@1). Output = sampled * vertex colour (componentwise).
- draw3d.zig: inline `billboard_vs_wgsl`/`billboard_fs_wgsl` → `@embedFile("billboard_{vs,fs}.wgsl")`;
  header comment updated (no inline WGSL remains). wgpu-billboards standalone built (-Dmode=release);
  wgpu-check green NO REGRESSIONS / wgpu_smoke PASSED. Sent for device-verify.
- KEY RECIPE for future direct sampler shaders: `zm.binding(&X_sampler2d, group, bind)` puts the
  TEXTURE at (group,bind) and the SAMPLER at (group,bind+1); names: X (texture) + X_sampler. Build's
  zspv reads it from the SPIR-V — no build.zig changes. Remaining: fluid_discs (storage + discard);
  optional wgpu_smoke triangle fixture.



<!-- @SpirvType migration zimr348 -->
**zimr348 — fluid_discs migrated. ALL inline-WGSL engine shaders now pure-Zig. Build/corpus-green.**
- src/shaders/fluid_discs_vs.zig: direct @SpirvType VS — uniform (group0/b0, Uniforms mirrors
  draw3d.FluidUniforms) + TWO read-only storage buffers `positions`@1 / `density`@2 (storageBuffer +
  ssboLoad, two buffers confirmed working) + vertex_index/instance_index. 6-corner quad via the points
  arithmetic-corner trick; sim-px→logical→NDC; col = mix(lo,hi,clamp01(density.x*density_scale)).
- src/shaders/fluid_discs_fs.zig: direct FS — r=length(corner); edge fade via smoothstep(0.8,1,r).
  The original `if (r>1) discard` is reproduced WITHOUT OpKill: smoothstep clamps so alpha→0 outside
  the disc (kept an explicit `r>1 → 0`), identical under the pass's straight-alpha blend + passive
  `.always` (no depth write). No std.spirv/zm kill intrinsic exists; asm OpKill avoided. (spv2wgsl DOES
  handle OpKill→discard if a true-discard path is ever wanted.)
- draw3d.zig FluidDiscs.init: inline `fluid_wgsl` → `@embedFile("fluid_discs_{vs,fs}.wgsl")`; split the
  single module into vs_module/fs_module; entry points vs_main/fs_main → entry/entry. wgpu-fluid-gpu
  standalone built; wgpu-check green NO REGRESSIONS / wgpu_smoke PASSED. Sent for device-verify.
- STATUS: skybox + points + billboard + fluid_discs all migrated to typed pure-Zig. NO hand-written
  WGSL remains in src/draw3d.zig. Only optional leftover: wgpu_smoke_test.zig `triangle_wgsl` test
  fixture (a test-only triangle; low value, can be migrated or left).



<!-- decal saga zimr549 -->
## zimr549 — decals (WAVE 2 3D-models) + drawTexturedTriangles engine addition
- NEW examples/decals: raylib models_decals. Click a surface → splat a projected DECAL. Each decal is a REAL clipped mesh: the target's triangles are transformed into a small box oriented along the surface normal at the hit point, Sutherland–Hodgman-clipped against the box's 6 planes, fan-triangulated, given planar box-space UVs, then drawn. So the decal wraps around curvature (bullet-hole/scorch-mark technique), not a flat sticker.
- ENGINE ADDITION: z.drawTexturedTriangles(gl, tex, positions[][3]f32, uvs[][2]f32, tint) — draw an arbitrary depth-tested textured triangle list (the clipped decal geometry, which the quad/billboard helpers can't express). Cube3D.drawTexturedTriangles pushes parallel pos/uv into tex_batch + records a tex_draws segment on the DEPTH-TESTED tex_pipeline (NOT the always-facing billboard_pipeline, so decals occlude correctly). Re-exported in zimr.zig. (GOTCHA during insert: a str_replace swallowed the `fn ensureMeshGpu(...)` signature line right after drawBillboardRec — restored it; always `zig ast-check` after inserting a method between two existing ones.)
- ALGORITHM: projection = mulMat(lookAtRh(hit.point, hit.point+normal, up), rotationZ(random spin)); for each target tri → mulMatVec(projection, v) into box space → cheap fullyOutside reject (all verts beyond ±s on any axis) → clipPoly ×6 (keep n·x <= s, in-place on a [16]Vec fan) → fan-triangulate → planar UV = boxXY/decal_size + 0.5 → lift z by 0.02 toward projector (avoid z-fight) → mulMatVec(inverse(projection), v) back to world. Verified the clip in Python: a straddling tri clips to a polygon fully inside [-s,s]^3.
- Target is a procedural sphere (genMeshSphere, no external .obj) — its curvature makes the wrap obvious. Pick via getScreenToWorldRay(m, cam, vw, vh) + getRayCollisionMesh(ray, mesh, identity) [both pre-existing from mesh_picking]. Reads a Mesh's interleaved xyz verts + optional u16 indices directly (same layout getRayCollisionMesh walks). Uses z.OrbitCamera to orbit. Decal texture generated procedurally (concentric-ring target with alpha-faded edge so box seams don't show).
- Caps: max_decals=64, max_decal_tris=96/decal (fixed arrays, no per-decal alloc). Clear + hide-target buttons.
- Lint gotchas: z.Vec2 is NOT exported → use zm.Vec2; bufPrint alias (prefer-std-alias); zm.rad_per_deg file-scope alias; inner-if braces (branch-braces).
- Verified: lint 0, standalone builds, smoke PASS (no clobber), textured-path examples (billboards/directional_billboard/skybox) still PASS, gate NO REGRESSIONS + test exit 0.
- WAVE 2 now: 3D-models VISUALS group COMPLETE. Remaining WAVE 2: skeletal-animation set (animation_blending/blend_custom/timing/bone_socket — needs a bone/keyframe/blend system) + loaders (models_loading_iqm/m3d/vox).


<!-- decal saga zimr550 -->
## zimr550 — decals BUGFIX (device screenshots showed 3 defects)
- Simon's device screenshots of zimr549 decals showed: (1) decals invisible when the target sphere is SHOWN (occluded), (2) decals appearing to sit on the ground far from the click, (3) glitchy dark triangle shards among the decals. Investigated with numeric Python models of the exact zm.lookAtRh/mulMatVec math.
- ROOT CAUSES (all in genDecal's box-clip):
  1. OCCLUSION: the decal box was clipped to z in [-s, +s], but with lookAtRh(eye=hit.point, focus=hit.point+normal) the box's +z half maps INSIDE the sphere (verified: box z=+0.55 → world radius 1.464 < 2.0). Those triangles were buried and occluded by the surface → decals vanish when the target is drawn. FIX: clip z to only the OUTER half [-s, 0] (clipPoly plane {0,0,1} at s=0.0 keeps z<=0), so all decal geometry sits on/outside the surface (verified z∈[-s,0] → world r ∈ [2.0, 2.59]).
  2. SHARDS: back-facing triangles from the sphere's FAR hemisphere also pass through the box (box is only bounded in z after clipping) and clip to thin slivers → the dark shards. FIX: reject back-facing tris — compute world face normal cross(e1,e2) and skip if dot3(face_n, hit_normal) <= 0 (keep only tris facing the clicked side).
  3. LIFT DIRECTION: old lift nudged along box -z by 0.02 (too small + wrong frame). FIX: after inverse-projecting back to world, push out along the WORLD hit_normal by 0.03. genDecal now takes hit_normal.
- The "decals on the ground" (defect 2) was the +z-half geometry (defect 1) inverse-mapping to scattered world points; fixing the z-clip + back-face reject resolves it. The pick itself was always correct (preview cube was correctly on the sphere in the screenshots).
- Math verified 4 ways in Python before + after: world→box projection correct (pole→origin, far side→z=4 rejected); Sutherland-Hodgman clip keeps output inside box; post-fix all kept verts sit at world radius >= 2.0 (on/outside surface).
- Verified: lint 0, standalone builds, smoke PASS (no clobber), gate NO REGRESSIONS. AWAITING re-verify on device.
- LESSON: for projected-decal box clipping on a CURVED surface, only the outer half-box (z<=0 in the projector frame) is valid geometry; the inner half is always occluded. Back-face rejection is mandatory or the far side leaks shards.


<!-- decal saga zimr551 -->
## zimr551 — decals REAL fix: mulMat composition-order bug (row-vector vs column-vector convention)
- zimr550 fixed occlusion+shards but device showed decals still SCATTERED at random world positions (each ring rendered cleanly but nowhere near the click) + a black center notch. Root-caused by tracing zm's matrix conventions.
- **THE BUG:** `zm.mulMat(a, b)` computes A·B in COLUMN-vector (M·v) convention — its own comment says the arithmetic equals `vecMulMat(b[i], a)`, i.e. in the ROW-vector (v·M) convention it's effectively `B·A`. But `lookAtRh` produces a row-vector view matrix and `mulMatVec(m,v)` = `v·m` (row convention). So `mulMat(look, rotationZ(spin))` actually composed as `rotationZ · look` in the row convention → the random per-decal spin was applied in WORLD space around world-Z, not in decal space → every decal flung to a different world position. FIX: `projection = mulMat(rotationZ(spin), look)` (swapped order) → composes as `look · rotZ` in row convention = spin in decal space. Verified in Python: box center now maps to the hit point, all decal verts cluster near the click.
- **LESSON (important, generalizes):** zimr mixes two matrix conventions. Perspective/view MVPs use mulMat in M·v order (MVP=mulMat(proj,mulMat(view,model))). But lookAtRh/mulMatVec are ROW-vector (v·M). When composing a lookAt/view matrix with another transform via mulMat, the operand order is the REVERSE of what M·v intuition suggests. Rule of thumb: to apply matrix P then Q to a point under mulMatVec, use mulMat(Q, P) (not mulMat(P,Q)).
- **Center notch fix:** the zimr550 z-clip to [-s,0] cut the decal center (where the projector axis meets the surface at box z≈0+). Restored full box z∈[-s,s]. Occlusion no longer an issue because of the new lift approach:
- **New lift (sphere-exact):** instead of nudging along the hit normal by a hair (occluded) OR clipping the inner half (center hole), every decal vertex is now RE-PROJECTED onto a sphere of radius sphere_radius+0.03: scale = (sphere_radius+lift)/|wp|. Since the target is a sphere centered at origin, this makes decals hug the surface EXACTLY and sit just clear of it — no z-fight, no occlusion, no hole, wraps the curve perfectly. (For a non-sphere target you'd offset along the interpolated surface normal instead; noted for the animation/loader work.)
- **Back-face reject kept** (cross(e1,e2)·hit_normal > 0) — still needed so the far hemisphere doesn't project through.
- **Diagnostics added (kept for device re-verify):** on-screen debug HUD shows hit.point/normal + last decal's v0 + tri count; drawPreview now draws the ACTUAL oriented decal box (8 corners of [-s,s]^3 through inverse(look), 12 edges via drawLine3D) instead of an axis-aligned cube — this oriented box is the ground-truth cursor that makes a projection bug visible immediately (the old axis-aligned preview is what hid this). REMOVE the debug HUD once Simon confirms on device.
- Simon suggested a CPU/GPU side-by-side (like helmet_sw/shadowmap_sw). Noted: decals are ALREADY fully CPU (mesh clip), so there's no GPU-duality to compare; the equivalent ground-truth here is the oriented-box preview, now added.
- Verified: lint 0, standalone builds, smoke PASS (no clobber), gate NO REGRESSIONS. Math verified in Python end-to-end (composition + inverse + radial reproject). AWAITING device re-verify.


<!-- decal saga zimr552 -->
## zimr552 — matrix-convention hardening (Simon: raylib's mat convention is notoriously buggy; make zimr uniform + good; study deep+wide)
- CONCLUSION FROM DEEP STUDY: zimr's matrix layer is ALREADY uniform and correct. Traced the full convention: storage row-major (Mat[i] are basis rows, translation in Mat[3]), mulMatVec(m,v)=v·M (row-vector), mulMat(a,b) computes rows of B@A = "apply b FIRST then a". The public doc frames this as "column-major, M·v" (a numerically-equivalent story chosen from the zmath/DirectXMath heritage) with the idiom view_proj=mulMat(proj, view). WIDE SWEEP of all ~150 mulMat sites across 37 files: every view/MVP site is correct (mulMat(proj,view), mulMat(proj,mulMat(view,model)), OpenGL-style modelview right-accumulation). The decals port was the LONE deviation. So: do NOT change the convention (would break 37 files for nothing).
- THE ACTUAL HAZARD (nameable, now guarded): raylib's MatrixMultiply(left,right) is row-vector "apply left THEN right" — the EXACT REVERSE reading-order of zm's mulMat(a,b)="apply b then a". Porting raylib matrix expressions verbatim into mulMat silently reverses composition. This is what bit decals (splat spin applied in world space).
- GUARDRAILS ADDED (structural, not just comments):
  1. NEW zm.compose(first, then) = mulMat(then, first) — reads in APPLICATION ORDER. And zm.composeN(a,b,c). Crucially compose shares raylib's operand order, so MatrixMultiply(A,B) → compose(A,B) 1:1, no flip. Unit-tested ("compose applies first, then second …": application order, compose==mulMat-swapped, composeN==nested). decals now uses compose(look, rotationZ(spin)) — self-documenting.
  2. mulMat doc-comment: added APPLICATION ORDER note + ⚠ PORTING FROM RAYLIB block with the decals example.
  3. src/notes/math.md: new "compose — build transforms in application order" + "⚠ Porting matrix code from raylib" subsections with the raylib→zm translation TABLE (MatrixMultiply(A,B) → compose(A,B) OR mulMat(B,A), never mulMat(A,B)).
  4. claude.md standing rule 15 (matrix compose order + raylib porting), next to the float→int rule 14.
- FUTURE (noted, not done this turn): a mechanical lint rule flagging mulMat(_, lookAt*/perspective*/orthographic*) as right-operand (a view/proj matrix as the second operand is almost always the wrong order). Verified ZERO current sites match → zero false positives today, catches the exact future mistake. Good next-turn addition to zimrlint.zig.
- Verified: lint 0, decals builds + smoke PASS, host unit tests (incl. new compose tests) exit 0, gate NO REGRESSIONS.
- TAKEAWAY: when a lib has a subtle convention, the fix for footguns is an intent-named helper (compose) whose signature IS the mental model + a porting table, NOT a convention change. raylib is the #1 convention-bug source; every future raylib matrix port routes through compose.


<!-- decal saga zimr553 -->
## zimr553 — decals: bunny second target + alpha-fighting fix + hard-edge fix (device-confirmed working, polish pass)
- Device screenshot confirmed the zimr552 fix works (oriented box lands on the click, decals wrap the sphere). Simon: add the bunny next to the sphere; fix alpha-fighting between overlapping decals.
- ALPHA-FIGHTING FIX (engine): drawTexturedTriangles gained a depth_write option (public API now z.drawTexturedTriangles(gl, tex, pos, uvs, .{ .tint, .depth_write=true }) via new TexTrisDesc). depth_write=false routes to the billboard_pipeline (.less_no_write — depth-TEST but no WRITE) instead of tex_pipeline (.less — test+write). Decals now pass depth_write=false, so overlapping translucent decals blend by draw order instead of z-fighting each other at equal depth; they still test against the opaque scene so they stay occluded by the far side. (tex_pipeline vs billboard_pipeline differ ONLY in depth-write, so this reuses the existing no-write pipeline.)
- HARD-EDGE FIX (example): the decal ring texture was opaque out to r=0.9, but the decal BOX side-planes clip the geometry at the UV edges — clipping through still-opaque texels left a hard straight cut (visible in the screenshot). Fix: fade the ring fully to transparent by r≈0.72 (fade 0.55→0.72, rings packed into inner 0.7), so the box side-clip only ever cuts already-transparent area. No more hard edges.
- BUNNY SECOND TARGET: loaded examples/decals/bunny.obj (copied from obj_bunny) via z.codecs.obj.parse → toMesh, converted to a z.Mesh with recenter+scale(22)+offset(4.2,-1.6,0) BAKED into the vertices (u32→u16 indices), so pick-space == draw-space == projection-space (all identity-transform). Drawn with z.loadModelFromMesh + z.drawModel. Pick now tests BOTH meshes (getRayCollisionMesh on sphere AND bunny) and keeps the nearer hit; the hit target + on_sphere flag flow into placeDecal→genDecal.
- DUAL LIFT in genDecal(mesh, projection, hit_normal, on_sphere, ...): sphere uses the exact radial re-project (scale to sphere_radius+lift); the bunny (arbitrary mesh, no closed-form outward dir) offsets along the single hit_normal by lift. Back-face reject (cross(e1,e2)·hit_normal>0) unchanged, works for both.
- Placement verified in Python: bunny x-span ~[2.55,5.85] vs sphere [-2,2] → 0.55 gap, no overlap, both in view; camera target moved to (1.6,0,0) dist 9 to frame both.
- Still has the debug HUD + oriented-box preview from zimr551 (kept until Simon confirms bunny placement on device; REMOVE both once confirmed). wasm now 7.68MB (bunny embedded).
- Verified: lint 0, standalone builds, smoke PASS (indexed bunny draws visible, no clobber), gate NO REGRESSIONS.
- FUTURE: for truly arbitrary targets the per-vertex lift should use interpolated surface normals (barycentric over the hit triangle) not the single hit normal — fine for a smooth bunny patch, would matter on high-curvature spots. Noted for a general decal system.


<!-- decal saga zimr554 -->
## zimr554 — shader-projected decals: FOUNDATION (step 1 of decal_shader_plan.md) [Simon: do B — the real-engine decal technique]
- WHY: mesh-clip decals (zimr549-553) shatter on dense meshes. MEASURED: the bunny has 69,451 tris and ~5,404 fall inside ONE decal box, so the 96-tri output cap captures a scattered 2% subset in mesh-storage order → fragments. Per-triangle clipping fundamentally doesn't scale; real engines project a texture in the receiver's fragment shader instead.
- WROTE src/notes/decal_shader_plan.md — full 4-step plan. Technique: draw the receiver mesh a 2nd time with a decal pipeline; per fragment, transform world pos by the projector matrix (world→box), discard if outside [-s,s]^3, else sample the decal texture at planar box XY and alpha-blend. No clipping, scales to any density. Architecture decision: DEDICATED decal pipeline (like tex_pipeline), NOT a modification of the shared cube3d batch shader (too invasive).
- STEP 1 DONE (shaders + depth mode, all gated green):
  * src/shaders/decal_vs.zig — world→clip via camera UBO (group 0), forwards world pos as varying o_world@0. Direct @SpirvType style (billboard_vs template).
  * src/shaders/decal_fs.zig — group1 Proj ubo { projector: mat4, color: vec4, params: vec4 (x=half_size, y=1/decal_size) }; group2 decal {texture,sampler} via zsample2d + binding(&decal_sampler2d, 2, 0). Computes box=projector·world, discards (outputs transparent) if |box.xyz|>half, else uv=box.xy/decal_size+0.5, samples, tints. Auto-discovered by build.zig (any src/shaders/*_vs.zig + *_fs.zig compiles through SPIR-V→spv2wgsl).
  * wgpu.zig DepthMode: added less_equal_no_write=8 (test less-equal so a decal exactly on the receiver's depth passes, NO write so stacked decals don't z-fight). Wired into both exhaustive switches (depthCompare, writesDepth).
- Shaders lint-clean + compile through discovery (build green). Draft Cube3D field/type wiring was written then REVERTED (would break the build until init+flush are done) — kept the codebase green. The wiring design is fully specified in decal_shader_plan.md "NEXT (step 2)".
- NEXT (step 2, the larger half): Cube3D decal_pipeline + group1 projector-UBO ring (≥8 slots, pbr3d-ring lesson to avoid clobber) + group2 tex bgl + pos-only receiver VBO registry + flush path; public z.uploadDecalReceiver(mesh)+z.drawDecal(gl, handle, projector, tex, color). Then step 3 rewrite decals.zig (delete genDecal/clipPoly), step 4 remove debug HUD + verify bunny clean.
- Verified: lint 0, decals still builds (mesh-clip path unchanged), gate NO REGRESSIONS.


<!-- decal saga zimr554 -->
## zimr554 cont. — shader-projected decals: WIRED END-TO-END (steps 2-3 of decal_shader_plan.md)
- Completed the engine pipeline + example rewrite. The bunny-fragmentation problem is SOLVED by moving projection into the fragment shader (no mesh clipping).
- ENGINE (draw3d.zig): Cube3D.decal_pipeline (group0=camera UBO shared, group1=per-decal projector UBO, group2=decal texture reusing tex_bgl), makePipeline(.triangle_list, .back, .less_equal_no_write). Types DecalUbo {projector:mat4, color:vec4, params:vec4 (x=half, y=1/size)}, DecalReceiver {vbo, vcount}, DecalDraw {receiver, proj_slot, tex_bg}. Projector-UBO RING: decal_proj_buffer (64*256B) + decal_proj_bgs[64] pre-built bind groups each baking offset=slot*256 (because bridge setBindGroup has NO dynamic-offset param — the pbr3d-ring lesson). Methods: uploadDecalReceiver(queue, mesh) de-indexes to a pos-only triangle-soup vbo via createBufferInit; drawDecal(queue, handle, projector, size, tex, tint) writes DecalUbo to ring slot cursor%64 + records; flushDecals binds group0/1/2 + redraws the receiver's positions per decal. beginFrame3D resets cursor + clears decal_draws. Called from flush() after flushTextured. No explicit Cube3D deinit (GPU resources app-lifetime, consistent w/ mesh_gpu/tex_bind_cache).
- DEPTH: added wgpu.DepthMode.less_equal_no_write=8 (test<=, no write) so decals sit exactly on the receiver depth (equal passes) and stack without z-fighting. Both exhaustive switches updated.
- PUBLIC (wgpu_app.zig → zimr.zig): z.uploadDecalReceiver(gl, mesh) ?u32, z.drawDecal(gl, handle, projector, tex, DecalDesc{size,tint}), z.DecalDesc.
- EXAMPLE (decals.zig): receivers uploaded once in init (sphere_recv, bunny_recv); Decal is now just {projector, color, receiver}; draw loop calls z.drawDecal. DELETED all CPU-clip code (genDecal/clipPoly/readTri/fullyOutside, ~165 lines) + the drawTexturedTriangles depth_write path is no longer used BY decals (kept in engine — still used generally). Header comment rewritten to describe the shader technique. Removed the stale decal-vertex debug line (kept hit debug + oriented-box preview until device-verified).
- SHADER-PATTERN ANSWER (Simon asked why _io.zig IoT sometimes, not others): IoT (_io.zig + _common_io.zig) is for shaders that SHARE uniforms/varyings with siblings — the _common merge makes VS-out==FS-in by construction (cube3d/pbr/gbuffer/lambert/lit_shadow families). Direct @SpirvType/@extern is for small standalone single-consumer pipelines (billboard/skybox/points/fluid_discs/decal). Audited: ZERO drift (every IoT shader imports a _common; every direct shader is single-use). Decal correctly direct. No unification needed — the split is principled. Documented in decal_shader_plan.md + math is fine.
- Verified: lint 0, standalone builds, smoke PASS (no clobber — ring works), host+shader test 0, gate NO REGRESSIONS. wasm 7.75MB.
- REMAINING (step 4): device-verify bunny decals are clean discs (the whole point). Then remove debug HUD + oriented-box preview. Possible perf follow-up: 64 decals × 69k-tri bunny = heavy overdraw; add a CPU bounding-sphere reject per decal if it stutters (noted in plan).


<!-- decal saga zimr556 -->
## zimr556 — decals FIX: cube3d lazy-init at uploadDecalReceiver time (device showed DecalReceiverFailed / black screen)
- Device error: `DecalReceiverFailed` at init, black screen. Root cause: `app.cube3d` is created LAZILY — only on the first `beginMode3D` call (wgpu_app.zig ~921). But `z.uploadDecalReceiver` is called in initState, BEFORE any 3D block, so cube3d was still null → wrapper returned null → the example's `orelse return error.DecalReceiverFailed` fired.
- Smoke DIDN'T catch it because the mock harness path differed; the real device runs the true init order. (Lesson: init-time engine calls that depend on cube3d must ensure it exists.)
- FIX: `uploadDecalReceiver` public wrapper now lazy-inits cube3d if null (same 2 lines as beginMode3D: `app.cube3d = draw3d.Cube3D.init(app.gpa, &app.gpu_frame) catch null`), then uploads. Device device/queue ARE valid at initState (loadTextureFromImage already uses them there), so init succeeds.
- CONFIRMED via smoke delta: was `init 167 calls, ~0.0/frame` (cube3d null, nothing rendered) → now `init 4355 calls, ~107/frame` (full decal pipeline + receivers live).
- ENV: sandbox disk hit 100% mid-build (NoSpaceLeft). Reclaimed ~600MB: cleared /tmp/wash_* + build logs + .zig-cache/tmp scratch (safe, regenerated) + removed the 97MB raylib_src/ DUPLICATE of raylib-master (build uses raylib-master; raylib_src only in a comment). Did NOT rm -rf .zig-cache (would trigger rebuild storm).
- Verified: lint 0, standalone builds, smoke PASS (107/frame), gate NO REGRESSIONS.
- STILL step 4 pending: device-verify the shader decals actually paint clean discs on sphere + bunny, THEN remove debug HUD + oriented-box preview.


<!-- decal saga zimr557 -->
## zimr557 — decals: 3 device GPU errors fixed + lint extended to catch sampler-in-branch for DIRECT shaders (Simon: sampling-in-branch has bit us often; find a real solution)
- Device console (screenshot) showed sphere+bunny RENDERING but 3 GPU errors, decals 0/64:
  1. `textureSample must only be called from uniform control flow` (WGSL :109) — decal_fs sampled INSIDE the `if (inside)` branch. THE RECURRING ONE.
  2. `Buffer "draw3d_decal_receiver" usage doesn't include CopyDst` — created the receiver vbo with only .vertex; createBufferInit writes via queueWriteBuffer → needs .copy_dst. FIXED: `.{ .vertex = true, .copy_dst = true }`.
  3. `Invalid ShaderModule "decal_fs"` — cascade from #1.
- FIX #1 (the real one): rewrote decal_fs to sample UNCONDITIONALLY at the top of `entry()`, then MASK. Was: `if(!inside){out=0;return;} uv=...; t=zsample2d(...)`. Now: always compute clamped uv + `zsample2d`, compute box membership as an arithmetic mask `axisMask(x,half)*axisMask*axisMask` (each axisMask is a value-select `if(...)1 else 0`, compiles to OpSelect, NOT control flow around the sample), multiply into alpha. VERIFIED the emitted WGSL: `entry()` body is FLAT — textureSample at top-level, no `if` wraps it. Tint-safe.
- FIX (durable, Simon's ask): the sampler-in-branch LINT only detected `io.<method>()` calls (IoT pattern) — it SKIPS functions with no Io param, so DIRECT @SpirvType shaders (billboard/skybox/points/decal, which call `zsample2d(...)`) were NEVER scanned. That's why this recurs. EXTENDED tools/zimrlint.zig: new `isBareSamplerCall` matches `zsample2d(...)` / `zm.zsample2d(...)` by callee name; runSamplerDiscipline now also scans the `entry` fn of direct shaders (scanMainBody with empty io_name → only bare calls match). VERIFIED: flags a broken test shader (`zsample2d` in `if`) at the exact line; the fixed decal_fs + all existing direct shaders (billboard/skybox/points/fluid_discs) pass clean (no false positives). `sampleLod`/explicit-LOD exempt (no derivatives). Documented in shader-style.md.
- LESSON: when a runtime-only failure class recurs, the fix is to extend the MECHANICAL guard to the code path it was missing — here, direct shaders were an unscanned blind spot in an otherwise-good lint.
- Verified: lint 0 (incl. new direct-shader scan), standalone builds, smoke PASS 107/frame, gate NO REGRESSIONS. Still need device re-test that decals now actually PAINT (the 3 errors were blocking all decal draws).


<!-- decal saga zimr558 -->
## zimr558 — decals: sphere fix (winding/cull) — bunny decals now CLEAN (shader path proven)
- DEVICE WIN: bunny decals now render as CLEAN DISCS, zero fragmentation — the shader-projected approach works perfectly on the 69k-tri mesh. The whole point of Option B, confirmed.
- BUG: decals showed on bunny but NOT sphere. ROOT: winding/cull mismatch. genMeshSphere winds its OUTWARD faces CW (verified numerically: for a mid patch, face-normal·centroid < 0), but WebGPU default front-face is CCW and the decal pipeline used `.back` cull → the sphere's visible outer surface was culled → no decals. The bunny (OBJ) is CCW so it passed. (The normal batch pipeline that draws the sphere uses `.none` cull, which is why the sphere body itself renders fine.)
- FIX: decal_pipeline now uses `.none` cull (was `.back`). Winding-agnostic. Safe because the FS discards everything outside the projector box, AND the far/inside sphere surface the box also intersects is at greater depth than the opaque front surface, so less_equal_no_write depth-occludes it — no bleed-through.
- LESSON for future receiver meshes: decal receivers can be any winding (genMesh* = CW-outward, OBJ = CCW); the decal pipeline must NOT cull. Documented inline.
- Verified: lint 0, standalone builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- Kept debug HUD + oriented-box preview ONE more turn for device-verify of the sphere fix. Once Simon confirms decals on BOTH targets, step 4 = strip HUD + box, final ship.


<!-- decal saga zimr559 -->
## zimr559 — decals: coplanar z-fight fix via clip-space depth bias in decal_vs
- Device: decals land on BOTH sphere + bunny now, but the SPHERE decals z-fight (faceted shimmer inside each disc, mesh triangles poking through). Bunny hides it (denser mesh) but it's the same coplanar issue.
- ROOT: the decal pipeline RE-DRAWS the same receiver surface it paints on, so decal depth == receiver depth exactly → coplanar z-fighting. less_equal_no_write lets equal-depth pass but per-triangle depth interpolation wobbles → shimmer.
- FIX: depth bias toward camera in decal_vs. WebGPU [0,1] depth (smaller=nearer), NDC z = clip.z/clip.w, so `clip.z -= bias * clip.w` shifts NDC z by a constant `bias` toward near — pulls the decal reliably in front of the surface. bias=0.0008 (small enough not to visibly float off). Chose this over pipeline depthBias because the gpu.zig RenderPipeline encoder doesn't expose depthBias (would need JS-bridge plumbing).
- SPIR-V GOTCHA: first wrote `var clip=...; clip[2] -= ...;` — in-place vector element write FAILED to lower (zspv/spv2wgsl transitive failure). Fix: construct a FRESH vector `.{ clip[0], clip[1], clip[2] - bias*clip[3], clip[3] }`. Verified emitted WGSL applies the bias (position[2] = z - 0.0008*w). Rule: avoid mutable indexed writes to @Vector in shaders; build a new vector.
- Also fixed the [prefer-vec] lint (use Vec not @Vector(4,f32)).
- Verified: lint 0, builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- If bias still shows fighting at grazing angles on device, bump to ~0.0015, or switch to a proper slope-scaled pipeline depthBias (needs bridge work). Start conservative.
- Once Simon confirms clean on device: step 4 = strip debug HUD + oriented-box preview, final ship.


<!-- decal saga zimr560 -->
## zimr560 — decals: backside bleed-through fix via projector-facing test (normals added to receiver)
- Device: decals visible THROUGH the sphere — a decal on the far/back surface showed on the front. ROOT: zimr558 set the decal pipeline to `.none` cull (to handle genMeshSphere's CW winding), but that lets the projector box paint BOTH the near surface AND the far wall of the box. Combined with the zimr559 depth bias (pulls decals toward camera), far-side decal fragments could win the depth test and show through.
- FIX (the correct one, not a bias tweak): projector-FACING test in the FS. Only paint surfaces whose normal faces TOWARD the projector — exactly what real decal systems do. Needs the surface normal per fragment:
  * uploadDecalReceiver now packs pos(3f)+normal(3f) interleaved (stride 24), de-indexed; decal vertex layout gained normal @location 1; flushDecals vbo bind size *24.
  * DecalUbo gained `forward: Vec` (world dir the projector shoots along = hit normal). drawDecal takes `forward`; public DecalDesc.forward (default +z). Example stores hit.normal as decal.forward, passes it.
  * decal_vs forwards world normal (o_normal @1). decal_fs: `facing = ndotf(normalize(o_normal), proj.forward)` = 1 when dot<0.1 (front-facing incl. grazing), else 0; multiplied into alpha alongside the box `inside` mask. Value-select mask — NO branch around textureSample (verified: sample still at uniform top-level scope in emitted WGSL).
- Now a decal only paints the surface facing its projector; the far wall / backside can't bleed through, independent of cull mode or depth bias.
- Verified: lint 0, builds, smoke PASS 107/frame, gate NO REGRESSIONS. Sample stays uniform (the sampler-in-branch lint from zimr557 guards this).
- Once Simon confirms no bleed-through on device: step 4 = strip debug HUD + oriented box, final ship. The shader-decal feature (uploadDecalReceiver/drawDecal + decal pipeline) is then complete: clean discs on both sphere + dense bunny, no fragmentation, no z-fight, no bleed-through.


<!-- decal saga zimr561 -->
## zimr561 — decals: bunny bleed-through ROOT FIX (broken normals + inverted facing sign) + unified sphere/bunny to model path
- Simon: still see decals through the BUNNY from the back; sphere+bunny should use the SAME setup; some bunny clicks don't splat.
- ROOT CAUSE 1 (the big one): bunny.obj has ZERO `vn` normals. toMesh SYNTHESIZES smooth normals when a mesh lacks them (om.normals is always valid), but loadBunny gated on `om.had_normals` (false) and wrote (0,1,0) for EVERY vertex → the decal facing test compared garbage → painted both sides. FIX: loadBunny always uses om.normals (they're synthesized). 
- ROOT CAUSE 2: the facing sign was INVERTED. proj.forward = hit.normal (points OUTWARD). A front-facing fragment's own outward normal points the SAME way → dot(n,forward) > 0. My ndotf kept `d < 0.1` (the FAR side!) and rejected the front. FIX: keep `d > -0.1` (front-facing, small negative threshold for grazing). So even with the sphere's good normals the far wall was leaking; both bugs compounded.
- UNIFICATION (Simon's ask): sphere now drawn as a z.Model via loadModelFromMesh from the SAME genMeshSphere mesh used as its decal receiver — identical to the bunny path. Deleted drawSphereTextured + the immediate z.drawSphere call + sphere_tex + makeCheckerImage. Both targets: drawModel(model) + uploadDecalReceiver(sameMesh). Drawn surface == decal surface for both, by construction.
- Verified getRayCollisionMesh finds NEAREST hit (min distance) and getRayCollisionTriangle is DOUBLE-sided (no back-face cull), so picking is geometrically sound. The "some clicks miss the bunny" wasn't reproducible in code review — likely silhouette-edge grazes or the max_decals=64 cap; flagged for device observation after the normal/facing fix (a wrong-normal decal that got rejected by facing could LOOK like a missed click).
- Verified: lint 0, builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- If bleed-through gone on device: step 4 = strip HUD + oriented box, final ship. If clicks still miss, investigate getScreenToWorldRay vs the responsive-canvas scaling.


<!-- decal saga zimr562 -->
## zimr562 — decals: REMOVE depth bias (root of see-through + can't-place-on-sphere); unified mesh makes it unnecessary
- Simon: "still see decals from back side, no depth test with the geometry" + can't place decals on sphere. Image showed far-side sphere decals bleeding through the front.
- ROOT: the zimr559 depth bias (clip.z -= 0.0008*clip.w, pulls decals toward camera). It was added to fix z-fighting BACK WHEN the drawn sphere (immediate drawSphere) differed from the decal receiver (genMeshSphere). But zimr561 UNIFIED both to the SAME mesh drawn via drawModel — so the decal now re-draws bit-identical triangles at bit-identical depth. The bias is now (a) unnecessary (no surface mismatch = no z-fight) and (b) HARMFUL: 0.0008 is ~16% of the sphere front↔back NDC-depth gap (~0.0052), enough to pull far-side decals in front of the near surface → see-through. It also destabilized sphere placement.
- FIX: remove the bias entirely. decal_vs just does `position = vp * world`. With less_equal_no_write + identical geometry: near-surface decal depth == sphere depth → less_equal PASSES (decal shows); far-surface decal at far depth vs stored front depth → less_equal FAILS (occluded, no see-through). The facing test (zimr560/561) is now a clean bonus, not the sole gate.
- WHY zero bias is safe (not just smaller): the batch path (appendModel, identity transform) and the decal path both compute vp*world_pos on GPU from the SAME baked vertex bits → identical depth → equal<=equal passes. No coincident-surface dropout. (If a future receiver uses a non-identity model transform vs baked positions, revisit — a tiny 5e-5 bias would be the insurance, still << the 0.0052 occlusion gap.)
- Verified: lint 0, builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- This should close BOTH: no more back-side bleed-through (depth + facing both reject it), and decals place on the sphere again. If device confirms → step 4: strip HUD + oriented box, final ship.


<!-- decal saga zimr563 -->
## zimr563 — decals: sphere ROOT FIX — hit normal winding sign (bunny perfect, sphere was rejected by facing test)
- Device: bunny decals PERFECT (clean discs, wrap ears/body, no bleed-through). Sphere still showed NO decals. Same code path for both → geometry-specific.
- ROOT (confirmed by the debug HUD): getRayCollisionTriangle derives the hit normal from `normalize(cross(edge1, edge2))`, whose SIGN depends on triangle WINDING. genMeshSphere is CW-wound → its hit normal points INWARD, OPPOSITE the sphere's outward per-vertex normals. The OBJ bunny is CCW → hit normal points outward, consistent. HUD proof: hit (1.00,1.28,1.15) [+x+y+z octant, outward should be +] but n(-0.48,-0.66,-0.58) [NEGATIVE = inward]. The decal facing test then computed dot(outward_vertex_normal, inward_forward) ≈ -1 → rejected the ENTIRE sphere front. (This inward normal also mis-oriented the projector all along.)
- FIX (winding-independent, at pick time): flip hit.normal to point toward the RAY ORIGIN. A visible surface always faces the camera, so `if dot(hit.normal, ray.pos - hit.point) < 0: negate`. Correct for ANY winding — sphere (CW) and bunny (CCW) both get a proper outward, view-facing normal. Now facing test dot(+outward, +outward) ≈ +1 > -0.1 → kept; far side ≈ -1 → rejected. Also fixes the projector orientation.
- LESSON: NEVER trust the raw cross-product normal sign from a picked triangle — orient it against the view ray. Winding varies by mesh source (genMesh* = CW-outward, OBJ = CCW). This is the same winding gotcha that hit the decal CULL in zimr558, now biting the facing normal.
- Verified: lint 0, builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- If sphere decals now show clean on device (they should — bunny already perfect, sphere had the identical path minus this normal sign): step 4 = strip debug HUD + oriented box, FINAL SHIP of the shader-projected decal feature.


---

<!-- finished campaigns removed from claude.md's "Sharp edges": the reorder/decl-order
     tooling build-out, the dag_check/import_graph/gen_files_md port, dag_png STEP C/D/E and its
     force-directed tuning, and the NAMESPACE FLATTENING waves 1-4. The standing rules they
     produced are kept in claude.md; this is the narration. -->

- Reorder tooling (committed): `tools/decl_deps.zig` emits the file-scope dependency
  graph (`idx|first|last|name|ref_idxs`, AST-accurate); `tools/decl_reorder.py` reads it,
  does a stable SCC-condensation topological sort (Tarjan + Kahn by min original index),
  and writes a pure block-permutation so only within-SCC back-edges (true cycles) remain.
  Build: `zig build-exe -OReleaseFast -femit-bin=/tmp/decl_deps tools/decl_deps.zig`.
  Use: `/tmp/decl_deps F > d.txt; python3 tools/decl_reorder.py d.txt F out.zig`. Always
  verify out.zig with content-integrity (sorted non-blank lines identical) + ast-check +
  full build before adopting. On ui.zig it takes 50->34 violations but reshuffles ~57%% of
  the 42k-line file (dependency order vs feature order) - a tradeoff, not a free win.
- Never re-export a zm type through a namespace (e.g. `pub const Vec2 = zm.Vec2` inside
  one struct that a sibling then borrows as `other.Vec2`). That manufactures a false
  dependency edge between siblings. Instead every file/section that needs a zm type
  declares its own `const Vec2 = zm.Vec2` (binding name == member name). Big flat files,
  DAGs: a borrowed type is the usual cause of a "cycle" that is really just a re-export.
- File-level import DAG gate is `tools/dag_check.zig` (was `scripts/check_dag.py`; ported,
  python deleted). Tokenizer-based @import scan (no regex false edges from comments/strings),
  Tarjan SCC, NO whitelist (the old `ui<->zimr` allowance went stale: ui.zig imports zimr.zig
  zero times now). Also prints the auto-computed DAG layering = longest-path levels = a
  suggested bottom-up reading order (currently L0 foundations: zimrmath/types/wgpu/bridge/
  entities/... up to L9 zimr, L10 tests; 51 modules, 212 edges, 0 cycles). Gate: `zig build
  dag-check` (wired via buildTools `.dag` + addRunArtifact, replacing the python addSystemCommand).
  The levels answer the "tiers" question empirically; an ENFORCED tier table (fail on up-tier
  imports) is the natural next step but not yet built. Python purge (this arc): check_dag ->
  tools/dag_check.zig and build_launch_json -> tools/gen_vscode.zig (`zig build gen-vscode`,
  reads the wgpu_examples array, writes the 4 .vscode/.zed configs; verified byte-identical to
  the old python output). Deleted as vestigial: count_globals.py (hardcoded deleted files
  drawing/rlgl, now-zero metric, no gate) and gen_flat_exports.py (its AUTOGEN markers no longer
  exist in zimr.zig -> dead). gen_files_md.py -> tools/gen_files_md.zig (`zig build files-md`;
  the per-file atlas — line/fn/test counts, deps/dependents, curated descriptions; curated text
  lives in tools/file_descriptions.zig, generated once from the old python dicts; verified
  byte-identical to the python on the live tree before deletion). scripts/ now holds NO python
  (shell scripts + a few standalone .zig probes remain) — the python analysis/codegen purge is
  COMPLETE. build_cheatsheet was already Zig
  (tools/cheatsheet.zig). When porting a generator to Zig, prove it: snapshot the python output,
  diff the Zig output byte-for-byte before deleting the python.
- Shared graph analysis lives in `tools/import_graph.zig` (collectImports, Graph{names,adj,rev,
  total_edges}, build, sccs, levels, maxLevel). Tools pull it in as a sibling file-import
  (`const ig = @import("import_graph.zig");`) — no build.zig wiring. dag_check.zig is a thin
  gate+report on top of it (336->112 lines, output unchanged/verified). gen_files_md.zig does NOT
  yet use it — its per-file deps use naive `@import` string scans (matching the old python so the
  port could be proven byte-identical). NEXT (step C): wire import_graph into gen_files_md for a
  topography header (levels + hubs) + per-file `L#` level tag + src section ordered by level; then
  mermaid + a zimr-rendered PNG (files as rects, area ~ linecount). adj/rev ARE the deps/dependents
  the atlas already prints, so no graph is computed twice.
- STEP C DONE: gen_files_md.zig now imports import_graph (sibling, no build wiring) and emits a
  `## Topography` block (DAG levels L0..L10 with members + out-degree hubs; "51 modules, 212
  edges, 0 cycles"), prepends a per-file `L#` tag to each src-core module's stats line, and orders
  the *src (core)* section bottom-up by level (then name). Level membership + hubs verified
  IDENTICAL to `zig build dag-check` (same shared module = single source of truth). This is the
  first intentional divergence from the python output (port-proof era over). NEXT: step D — a
  mermaid block (transitive reduction first, to tame the 212-edge hairball into the ~covering
  DAG), then step E — a zimr-rendered PNG (files as rects, area ~ linecount; dogfood rlsw).
  Transitive reduction belongs in import_graph.zig (shared) so both mermaid + PNG use it.
- STEP D DONE: import_graph.zig gained `transitiveReduction(gpa, g) -> []ArrayList(u32)`
  (reachability via per-node DFS, then drop u->v if any other successor of u already reaches v;
  unique minimal DAG; result sorted by id) + `edgeCount`. gen_files_md emits a `## Dependency
  graph` block with a ```mermaid graph TD``` of the REDUCED edges: 212 -> 67 covering edges
  (3.2x). Sanity: zimr's raw out-degree 35 collapses to 6 (the rest implied via wgpu_app etc.).
  The 4 nodes isolated in the FILE graph (bridge, shader_interface, wgpu_runner, zimrmath) are
  emitted as bare mermaid nodes — they're reached via build-wired modules (`zm`), not file
  @import, so they legitimately have no file edges. Topo intro now shows the reduced count.
  NEXT: step E — zimr-rendered PNG (files as rects, area ~ linecount, laid out by level, edges
  from `reduced`). Dogfood rlsw / png_canvas. A NEW host tool (tools/dag_png.zig?) that imports
  import_graph + the engine's software renderer, writes src/notes/dag.png; wire a build step.
- STEP E DONE: tools/dag_png.zig — a NATIVE host exe (`pub fn main() !void`, std.Io.Threaded,
  page_allocator; NOT the process.Init style — note std.process.ArgIterator does NOT exist there,
  so no args, output path hardcoded "src/notes/dag.png"). Imports "zimr" + "zm" modules (wired in
  build.zig next to native_plot_png, reusing zimr_native_mod) AND sibling file import_graph.zig.
  Dogfoods png_canvas.Canvas (fillRect/line/text/savePng, ss=4 AA + font_atlas_size=128 for crisp
  glyphs, truetype via @embedFile of a copied tools/dag_font.ttf = Atkinson Hyperlegible Mono — a
  legibility-designed font, advance ~0.63em; RobotoMono was swapped out after on-phone labels were
  too faint. All on-image text is ASCII — the mono fonts lack em-dash/arrow glyphs). Labels scale
  with box size (fs = clamp(h*0.5, 10, 24)) so big boxes get big text; a name too long for a small
  box is drawn in dark ink BELOW the box instead of shrunk to mush. Renders: boxes area ~ lines-of-code (area_k px^2/line, clamped), color = DAG level
  (Spectral ramp indigo L0 -> red top), edges = transitive reduction (level-colored, alpha). Layout
  (all px, no global rescale — canvas just grows): connected nodes -> level rows (row 0 = top =
  max_level); ISOLATED nodes (the 4 module-wired foundations bridge/shader_interface/wgpu_runner/
  zimrmath, no file edges) -> a separate labeled strip at the bottom. Algorithm: repack (rows
  centered about 0) -> barycenter ordering sweeps (sort each row by mean neighbour cx) -> coordinate
  relaxation passes (cx = neighbour mean, alternating resolveLR/resolveRL overlap removal) and —
  KEY for a non-sheared, centered trunk — recenter EVERY row to mean-0 after each relax pass.
  cy in px with fixed row_vgap/top_pad, empty rows skipped. `zig build dag-png` step added. The PNG
  is NOT in the ship zip (recipe excludes *.png) — add it explicitly + present it separately.
  files.md now embeds ![dag.png] under the mermaid block. Tunables at top of dag_png.zig.

NAMESPACE FLATTENING (campaign — reduce namespace depth + count; Simon likes big flat files,
shallow dotting). Two levers: (a) FILE-AS-STRUCT collapses depth (`png_canvas.Canvas` -> the file
IS Canvas); DAG-neutral (no edge change). (b) MERGE small/sibling files cuts count (changes edges
-> gate every merge with `zig build dag-check`). Profiling shows the big files (ui 86 types,
zimrphysics 90, plot 27, entities 15) are ALREADY flat (all types at file scope) — leave them.
- WAVE 1 DONE (file-as-struct): png_canvas.zig -> Canvas.zig, bind_group_cache.zig ->
  BindGroupCache.zig. Pattern Simon wants: rename file CamelCase = the type; top-level
  `const <TypeName> = @This();` (descriptive alias, NEVER bare @This() or `Self` inline; for
  generic inner structs that can't know their name, pick a descriptive alias too); hoist the
  struct's fields+methods to file scope; nest helper types (Options, Key) under it. Importers do
  `const Canvas = @import("Canvas.zig");` then use `Canvas` / `Canvas.init`. zimr.zig re-exports
  collapse to `pub const Canvas = @import("Canvas.zig");` (dropped the redundant `png_canvas`
  namespace export).
- KEY GOTCHA + FIX: lint rule [dup-pub-fn] (tools/zimrlint.zig ~3479) forbids duplicate COLUMN-0
  `pub fn <name>` across the whole roster (flat-C-symbol/convention). File-as-struct hoists
  init/deinit/etc. to col-0 -> instant collisions (Canvas.init vs BindGroupCache.init). FIX
  (committed): the rule now EXEMPTS file-structs — any file containing a col-0 `const X = @This();`
  is treated as a TYPE whose col-0 pub fns are methods, and is skipped by the uniqueness check. So
  future file-as-struct conversions are lint-safe out of the box. (Rebuild /tmp/lint after editing
  zimrlint.zig.)
- NOT file-struct candidates (multi-export namespaces, despite 1 dominant struct): pipeline_cache
  (exports StateCombo x24, CacheKey, hashSource...), gpu_frame (GpuFrame + accessors). These belong
  to a future "merge the GPU plumbing" pass (bind_group_cache now done + pipeline_cache +
  descriptor_encoder + gpu_frame are all L1-L2 feeding gpu_iface — consolidate into one flat file).
- WAVE 3 DONE (GPU-plumbing merge — count + per-file depth reduction): pipeline_cache.zig +
  descriptor_encoder.zig + gpu_frame.zig MERGED into one big flat `gpu.zig` (632 L, L2): zimr's
  WebGPU resource layer over raw `wgpu` — PipelineCache/StateCombo/CacheKey/hashers + the descriptor
  encoders (RenderPipelineDescriptor/BindGroupEntry/Vertex*/encode*) + per-frame Backend/GpuFrame.
  BindGroupCache deliberately NOT folded in (keeps its file-struct depth-1 win; gpu.zig imports it).
  Module count 51 -> 49, edges 67 -> 63. Each importer now imports ONE `gpu` module instead of 2-3
  (real per-file namespace-surface reduction, not just count). Public API: z.descriptor_encoder +
  z.pipeline_cache collapsed to a single `z.gpu`; z.GpuFrame / z.PipelineCache direct exports kept.
  REWIRE METHOD (reusable): instances are named pipeline_cache/gpu_frame too (self.gpu_frame.surface,
  self.pipeline_cache), so only `<alias>.<ExportedSymbol>` forms were rewritten via a negative-
  lookbehind `(?<![\w.])` regex over the exact exported-symbol list -> `gpu.\1`; the compiler is the
  safety net (any over-reach = undefined-symbol error). GOTCHAS hit: (1) inserting the new import
  after `const std` failed on files whose `@import(` first appears inside a `//!` doc comment — place
  it after the first REAL top-level `const X = @import(` line instead, never above the `//!` header;
  (2) a second in-function alias `encoder2` was missed by the symbol regex (only knew
  pipeline_cache/descriptor_encoder/gpu_frame/encoder); (3) `grep | head` HID an extra consumer
  (wgpu_lambert_demo using z.descriptor_encoder) — always grep without head before declaring a rename
  complete. Verified: wgpu-hello-world/demo/fluid-gpu/cube-demo/sidebyside/compute-smoke/render-
  texture/lambert-demo all compile; dag-check passes (gpu.zig L2, no cycle); lint clean.
- WAVE 4 DONE (file-struct, depth win): wgpu_draw.zig -> WgpuGl.zig (single type WgpuGl, internal;
  importers mostly did `@import("wgpu_draw.zig").WgpuGl` which collapses to `@import("WgpuGl.zig")`).
  wgpu_app's `wgpu_gl` alias: `const WgpuGl = wgpu_gl.WgpuGl` -> `const WgpuGl = wgpu_gl` (alias now
  IS the type). The facade/dup-pub-fn concern (WgpuGl has raylib-named draw* methods, facade-paired
  with wgpu_app) resolved automatically — file-structs are dup-pub-fn-exempt. Verified via
  wgpu-hello-world + dag-check; count unchanged (rename), depth dropped (wgpu_draw.WgpuGl -> WgpuGl).
- INLINE LEVER MOSTLY EXHAUSTED: the remaining small files are NOT inlinable — they're public API
  exposed via zimr (easings/utils/sw_runtime/Canvas/kompute/compute_host/shader_codegen are z.*
  surface used by examples), shared by 2+ consumers (shader_connect), build-wired by path
  (shader_codegen, wgpu_runner), or entry points (tests, *_smoke_test, spv2wgsl_wasm). Inlining any
  would remove a public namespace or break the build wiring. So further count reduction needs
  EXAMPLE-facing API decisions, not mechanical inlines. Current: 49 modules, 63 edges. Remaining
  file-struct candidates worth a look: shader_codegen->ShaderPipeline (blocked: build-wired by path +
  also exports ShaderOpts), wgpu_texture (2 types, not single).
- WAVE 2 DONE (rlsw rename — Simon: "rl is not a thing anymore, branched from raylib"). Global
  `rlsw` -> `raster` across all code (42 .zig files) + renamed files: rlsw.zig->raster.zig (7269 L
  GL-style Context/Framebuffer software rasterizer namespace — stays a namespace, NOT a file-struct),
  rlsw_pixel->raster_pixel, rlsw_shader->raster_shader; and rlsw_adapter.zig -> SwAdapter.zig
  (file-struct: `const SwAdapter = @This();`, type SwAdapter kept since "Sw"=software is fine and
  not the raylib baggage; BlendMode nests as SwAdapter.BlendMode). zimr.zig still exports the public
  alias `pub const SwGl = @import("SwAdapter.zig")` (used by wgpu_sidebyside); dropped the redundant
  `raster_adapter` namespace export. renderer_trait re-exports SwAdapter + BlendMode from SwAdapter.zig.
  Audit before the blind global replace confirmed NO functional non-Zig rlsw refs (no build step
  names, no export/C symbols, no JS glue — only comments + the internal `rlsw_side_by_side` demo in
  raster.zig). Verified: wgpu-hello-world (full wgpu module incl raster chain) + wgpu-sidebyside
  (z.SwGl) compile; dag-check passes (topology unchanged — pure rename); cheatsheet + files.md +
  dag.png regenerated; tutorial renamed rlsw-tutorial.md -> raster-tutorial.md. (Historical
  notes/archive/* intentionally left mentioning rlsw as era context.)
- COMPILE-CHECK RECIPES for these refactors: native/Canvas path -> `zig build dag-png` (~1min,
  compiles zimr_native_mod); WebGPU path (gpu_frame/wgpu_app/caches) -> `zig build wgpu-hello-world`
  (~few min, compiles full wgpu wasm module). Both run lint over the roster as a pre-step.

## dag_png.zig — second view: force-directed / freeform (added)
`zig build dag-png` now emits TWO images: the layered `src/notes/dag.png` (DAG
direction by level) AND `src/notes/dag_force.png` (freeform Fruchterman-Reingold:
springs along ALL 195 import edges cluster coupled files; color still = DAG level).
Added `renderForce(gpa, io, graph, level, max_level, bw, bh)` + an `fd_*` tunable
block. Forces: all-pairs repulsion (k^2/d), per-edge attraction (d^2/k) over the
FULL graph.adj (not the reduced edges — full coupling drives the clusters), gentle
center gravity + a WEAK level->y bias (fd_ybias=0.028: a hint, not a rail; a strong
bias just reproduces the layered view smeared sideways). Tunables landed after
visual iteration: fd_k=126, fd_grav=0.06, fd_band=118, fd_iters=700, then box
overlap-removal passes. KEY GOTCHA: degree-0 (module-wired) nodes
bridge/shader_interface/wgpu_runner/zimrmath have NO springs, so repulsion flings
them to infinity (first run was 20553px wide). FIX: a `conn` mask excludes them from
all force/overlap/bounds loops; they're laid in a labeled bottom strip like the
layered view. Edges drawn center-to-center, faint (alpha 90), tinted by source level.
Ship recipe now adds BOTH dag.png and dag_force.png to the zip (recipe excludes *.png).

### dag_force.png REVISED (directed + late repulsion + de-hairballed)
Three changes per Simon: (1) "a file should be higher than its dependencies",
(2) "repulsion only for the last few iterations", (3) "avoid the hairball".
- HIERARCHY: a directed per-edge spring (push importer up / dep down) proved
  FRAGILE — it lost the tug-of-war with full-graph attraction + the hub nodes
  (zimr/tests import everything) and INVERTED (high-level sank to the bottom).
  Robust fix instead: y is HARD-CLAMPED into a per-DAG-level slab each iter
  (ty = (max_level-level)*fd_layer_gap, roam ±fd_slab_frac*gap). Slabs don't
  overlap, so a node can never cross a level boundary -> importer ALWAYS above
  dep, guaranteed, no inversion possible. The sim then only solves x (clustering).
- LATE REPULSION: repulsion is enabled only in the last fd_rep_tail iters, with a
  temperature RESET (fd_rep_temp) when it turns on (else cooling has already
  killed the step size and nothing fans out). Phase 1 = attraction+gravity find
  x-clusters; phase 2 = repulsion spreads for legibility. Keep fd_gravx low so
  the tail can actually fan out horizontally.
- DE-HAIRBALL: forces use the FULL import graph (graph.adj, ~195 edges) for
  clustering, but only the REDUCED skeleton (63 edges) is DRAWN, routed
  bottom-of-importer -> top-of-dependency. Huge clutter reduction.
Tunables now: fd_layer_gap=122, fd_slab_frac=0.42, fd_k=152, fd_att_yscale=0.9,
fd_gravx=0.02, fd_gravy=0.03, fd_iters=820, fd_rep_tail=330, fd_rep_temp=155.
Result ~1126x1744, monotonic color top->bottom. LESSON: for "hierarchical +
freeform", pin y by level (a clamp), force-cluster x — don't try to force y order.

### dag graph v3: module edges + free directed-y + in-degree colour
- import_graph.collectImports now maps build-wired MODULE imports to their src
  file: `@import("zm")` -> zimrmath, `@import("shader_interface")` -> itself. So
  zimrmath (imported by ~57 files) is no longer falsely isolated — it's the true
  L0 foundation. Affects ALL consumers (dag-check/files-md/dag_png). dag-check
  still acyclic (zimrmath/shader_interface are leaves). Edges 195->231, and the
  ubiquitous leaf pushes everything up one level (max level 10->11). bridge &
  wgpu_runner remain genuinely isolated (nothing imports them; build entries).
- dag_force.png REWRITTEN to drop level scaffolding entirely:
  * y is a SINGLE directed force — for each edge importer ABOVE dep, ONE-SIDED
    (only correct violations). One-sided is essential: a two-sided spring averages
    a universal leaf (zimrmath, 57 importers at all heights) to the MIDDLE; the
    one-sided version sinks it below ALL its importers -> fundamental files drop
    to the bottom. No y-attraction, no y-gravity, no clamp — y is purely the
    dependency ordering, so files float to sit between their deps (below) and
    dependees (above).
  * x: linear column spring (fd_attx) + x-only repulsion in the last fd_rep_tail
    iters + x gravity. BALANCE: x-only repulsion with large fd_k blew width to
    12568px; equilibrium spacing ~ fd_k/sqrt(fd_attx), so fd_k must be SMALL
    (~46) to match the linear spring. Tunables: fd_ygap=76, fd_yhier=0.28,
    fd_attx=0.08, fd_k=46, fd_gravx=0.05, fd_rep_tail=260, fd_rep_temp=110.
  * colour = in-degree (how many files depend on this), sqrt-scaled, via the
    existing levelColor ramp. Warm = fundamental. zimrmath renders big & red at
    the bottom; types/codecs/raster green; leaf-apps blue at the top.
- LEVEL STRUCTURE (for the "flatten to 6" goal): 12 levels = 2 aggregator roots
  (tests refAllDecls-all, zimr facade-all) + 1 ubiquitous leaf (zimrmath, like
  std) + ~9 real engine levels. Longest real chain is the render pipeline:
  wgpu_app->draw3d->WgpuGl->renderer_2d->...->text2d->image->codecs->types.
  Flattening = collapse ~3 adjacent thin layers (WgpuGl into renderer_2d/draw3d;
  flatten text2d->image->codecs so 2D content sits directly on primitives).

### dag boxes now carry key-symbol labels (both views)
- Curated `pub const key_symbols = [_]KeySyms{ .name, .syms }` table added to
  tools/file_descriptions.zig (Simon's "use the description file"). `syms` uses
  `|` as a line break, ordered most-important-first so truncation in a small box
  keeps the headline symbols. ~44 files curated (zimrmath -> "Vec2 Vec3 Vec4|Mat
  Quat|Color|...", ui -> "Ui Window|DrawList|Table TabBar|...", etc.). Auto-
  extraction was tried first and rejected: declaration order != importance
  (zimrmath led with F32x8/modAngle32; codecs' top-level pub decls were namespaces).
- dag_png.zig imports file_descriptions as a sibling; `symsFor(name)` looks up the
  label. drawNode REWRITTEN: file name across the top (shrunk to width) + the
  `|`-separated segments as lines beneath, each shrunk to fit, as many as the box
  height allows (so bigger files literally show more). No allocation — segments
  are substrings of the syms string.
- Box sizes bumped to make room: area_k 2.2->7, aspect 2.6->1.7 (squarer),
  min 64x26 -> 96x54, max 220x88 -> 300x200. Both the layered (dag.png) and
  freeform (dag_force.png) views call symsFor, so both are now labeled maps.

### integrated profiler — design locked + backbone built (active plan: src/notes/profiler.md)
Studied tracy + SimpleImGuiFlameGraph (refs in /home/claude/ref). Brainstormed
the full design one-question-at-a-time; all 8 decisions + phasing recorded in
src/notes/profiler.md (the active plan). Highlights: in-process (not Tracy's
client/server), hybrid live+freeze, ~5µs timing via COOP/COEP + a dedicated
direct `now` import, static @src() identity + optional text/value annotations,
layered instrumentation, always-recording for non-ship modes with views
defaulting to the LONGEST frame in a rolling 2s window, CPU-only v1, v1 cut =
flamegraph + frame strip + stats table.

This session shipped: (1) build-mode rename `release-no-zimr-asserts` -> `ship`
(build.zig only; trio is debug/release/ship; no other caller referenced the old
name). (2) `profile_enabled` build option derived as `mode != ship`, added to
build_opts + build_opts_wgpu; profiler reads it via defensive `@hasDecl` so any
options module lacking it just compiles the profiler out. (3) src/profiler.zig —
the comptime-gated COLLECTION BACKBONE: SourceLoc/ZoneEvent/Frame, static fixed
ring buffers (frames[256]/zones[65536]/srcs[1024], caps collapse to 0 when
disabled), pluggable clock (setClock), zone(@src())/zoneNamed/end/text/value/
setColor, frameMark, freeze/unfreeze/reset, worstFrame (longest in 2s window).
Exported as `z.profiler`, L0 leaf (imports only std + build_options). Verified:
2 headless tests pass enabled+disabled; wgpu builds at debug (in) and ship
(stripped); dag-check acyclic; lint clean. NEXT: fast `now` import + setClock
wiring + COOP/COEP, then coarse phase zones in wgpu_app, then the overlay views.

### bridge.zig boot-path readability refactor (zimr286) -- BEHAVIOR-PRESERVING
- Per Simon: NO single-call helper functions; instead brace independent sections
  inside the big functions, extract composite chained exprs into named locals,
  improve comments + names. Refactored the critical wasm-load path only:
  - tick(): doc comment; named promise_resolved/rejected consts; status local;
    performance/now_ms extracted; both stage-4 contract branches commented.
  - advance(): doc comment; each stage labelled "Stage N -> M:". Stage 1: adapter,
    adapter_features, has_timestamp_query, device_promise (var, branch-assigned).
    Stage 2: split into braced sections — device setup / GPU-timing infra (slot_count,
    buffer_bytes, resolve_usage, read_usage, function_ctor, ms_helper) / the import
    object ({dom}{wgpu}{wasi} each self-contained ending in imports.set) / instantiate
    (inline_bytes, web_assembly, wasm_url, fetch_response, instantiate_promise as a
    plain if/else not a blk: ternary). Stage 3: instance, page_main, initialize,
    performance locals.
  - start(): doc comment; have_inline_bytes/have_wasm_url; navigator/gpu/adapter_promise.
  Logic identical throughout (verified: lint 0, dag-check, demo + standalone build).
  Function values bound to locals to stay under the 120-col cap at deeper indent.

### src/web/readme.html: currency + physics/profiler/fluid pass (zimr287)
- Made current: 156 examples (was 151/180), 51 top-level src files (was 46), ~1,700
  tests (was 1,694/1,691), bridge ~4,700 lines (was ~4,000). -Dmode now debug/release/
  ship (was release-no-zimr-asserts); release = ReleaseSmall+asserts+profiler, ship =
  none. naga-tint -> wgpu-corpus everywhere (3 spots). Stale file refs fixed:
  descriptor_encoder.zig -> gpu.zig (merged pipeline_cache+descriptor_encoder+gpu_frame);
  drawing.zig -> renderer_2d.zig + gpu_iface.zig.
- NEW dedicated "#physics" section: Jolt port, full shape set (convex prims + hull +
  compound; mesh/BVH, heightfield, plane; rotated/translated + offset-COM decorators;
  narrow phase decomposes to convex leaves), broadphase->GJK/EPA->island sequential-
  impulse solver, full constraint set (point/fixed/distance/hinge/slider/swing-twist/
  gear/rack&pinion/pulley/6dof/path), motors (free/velocity/position), code snippet,
  ~30 demo scenes.
- NEW "#profiler" section: comptime-gated (zero in ship), engine auto-instruments its
  frame, zone(@src()) snippet, views (flamegraph/strip/stats/find-zone histogram),
  timer-resolution probe (~100us clamp), auto-freeze-on-spike, GPU timing via
  timestamp-query (CPU vs GPU). Demoed via Profile/Watch in the physics demo.
- Expanded GPU fluid: wgpu_fluid_gpu (20k Clavet SPH, kernels, FluidDiscs zero-readback,
  CPU-runnable) + wgpu_fluid_sort (GPU counting-sort grid: clear/count/prefix-sum/
  scatter/copyback, contiguous neighbour reads, no atomics) + wgpu_sph_fluid_2d (CPU).
- Deemphasized: folded the comptime-shader tangent into one trailing clause.
- Reordered nav: ...plot -> physics -> profiler -> entities&audio. Verified: 0 missing
  files, 0 stale strings, tags balanced (p/pre/h3/table), all nav anchors resolve.
