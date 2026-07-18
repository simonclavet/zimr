# engine_findings.md — the standing register of problems + opportunities

Simon asked for this to be kept: **every engine problem or improvement opportunity noticed while doing
other work goes here**, whether or not it was fixed in the turn that found it. A finding that only lives
in a turn journal entry is a finding that gets lost. Fixed items stay (struck through with the turn that
closed them) so the same hole is not rediscovered a third time.

## The pattern behind most of these

Three of the five bugs below are the SAME bug wearing different clothes: **a resource that is correct
exactly once per frame, used more than once per frame.** WebGPU's `queue.writeBuffer` calls all execute
before the frame's single submit, so writing one buffer at one offset twice in a frame means the FIRST
recorded pass silently reads the SECOND pass's data. The engine had already learned this lesson twice
(the 2D shapes vertex ring; the renderer_2d ortho ring) and written it down — and then the 3D path,
the instanced path, and the typed-shader UBO each shipped with the same defect anyway.

**The generalisable rule: any GPU resource written during a frame needs a frame-scoped cursor, not an
offset-0 write. "Once per frame" is not an invariant you can assume — it is one you must enforce.**
`Resources.writeUbo` even documents "★ INVARIANT: at most ONE write per frame ★" — and nothing checks it.
The smoke ClobberScan is the only thing standing between this class of bug and the device, which is why
its own reporter being broken (finding 4) was so expensive.

---

## OPEN

### 1. `Resources` has no UBO ring — every typed shader is one pass away from this bug
`shader_runtime_wgpu.zig:writeUbo` writes ONE buffer at offset 0 and its bind group is pinned to offset 0.
Its doc comment states the one-write-per-frame invariant but nothing enforces it, and there is no supported
way for a typed shader to be used in two passes in a frame. Every ring in the tree (renderer_2d ortho,
draw3d decal projector, draw3d view-projection as of zimr857) is therefore a HAND-ROLLED bypass of
`Resources`, each re-implementing "N slots at a 256-B stride + one pre-built bind group per slot".
**Opportunity:** make it a first-class option — `Resources(Schema).init(gpa, f, .{ .ubo_ring = 16 })` —
so `writeUbo` advances a cursor, `bind` binds the current slot, and the three hand-rolled rings collapse
into one implementation. The blast radius is real (bind-group rebuild on `set` must become ring-aware),
which is why zimr857 did the contained fix instead. **Decision needed from Simon.**
Cheaper interim: make `writeUbo` ASSERT the invariant it documents (encoder-scoped write counter, panic on
the second write). That converts a silent wrong-render into a loud failure without any redesign.

### 2. The WGSL corpus fixture is keyed by INPUT HASH, so a compiler bump zeroes its coverage silently
`tests/fixtures/wgsl_corpus.json` maps `spv_input_hash -> wgsl_output_hash`. New compiler = new SPIR-V bytes
= every key dies at once; the 1398 bump orphaned all 138 entries and `check` still printed `✓ NO REGRESSIONS`
having compared nothing. `corpus-refresh` then wrote `52 live + 138 carried` — the orphans can never match
again, so the file grows ~52 dead pins per bump, forever. **Fix:** key by SHADER NAME (stable across
compilers), store a reviewable structural digest (entry points, binding table, resource decls) instead of an
opaque hash, and make "0 live matches" a hard FAIL. A gate that can print ✓ while comparing nothing is a
tautology — this codebase's own rule.

### 3. c2js miscompiles `std.Io.Writer`'s error path (`ReferenceError: t19 is not defined`)
A `bufPrint` OVERFLOW inside the transpiled smoke harness does not reach its `catch` — it dies in JS with an
undefined temp. zimr857 sized the buffers so the overflow stops happening, but the transpiler bug is still
there, and it means **any `catch` on a formatting error in transpiled code is a lie**. `printPass` already
carries a scar from this area ("avoids std.fmt's float path, which trips a c2js BigInt/Number mix"). Worth a
focused c2js session: build a minimal repro (bufPrint into a too-small buffer), find the temp that is emitted
but never declared, and add it to `tools/c2js_cases`.

### 4. ~~The smoke harness could DETECT a clobber but never NAME one~~ — FIXED (zimr857)
`printClobberFail` built a ~360-byte message and handed it to `printFail`, whose line buffer was 256 bytes.
The overflow hit finding 3 and crashed Node with a JS stack trace instead of printing the diagnosis. So the
single most valuable gate in the tree — the only thing that sees queue-timeline clobbers — had a failure
path that had, apparently, never once been exercised end to end. **Lesson: test the FAILURE path of a gate,
not just its success path.** A gate whose red output crashes is a gate you will learn to ignore.

### 5. `zig fmt --check` runs inside the build but is not in the lint report
A formatting slip fails the build with `failed command: zig fmt --check ...` and a 200-line step trace, while
`zig build lint` (the thing you naturally run first) reports 0 issues. Two gates, two vocabularies, one of them
unhelpful. **Opportunity:** have `lint` run `zig fmt --check` and print the offending files in the same
`file:line: [rule]` shape as every other violation.

### 6. A `timeout`-killed build leaves an ORPHANED compiler burning the only core
`timeout 170 zig build ...` kills the `zig build` parent; the `zig build-exe` child it spawned keeps running.
On a 1-core box that zombie halves (or worse) every subsequent build, and the symptom is maddeningly indirect:
a focused smoke that takes 3 seconds on a clean core "hangs" for 170s, and the build log shows it compiling an
example you never asked for. Found t1284 after an orphan had been compiling `triangle_strip`'s Debug smoke wasm
for ~25 minutes. **Opportunity (real fix, not a discipline fix):** wrap the build invocation so the child dies
with the parent — `timeout --kill-after=5 --signal=INT 170 setsid ...` plus a process-group kill, or simply
have the build wrapper `pgrep -x zig` and refuse to start while another compile is live. Discipline ("remember
to pgrep") is what we have now, and discipline is what failed.

### 7. The smoke's per-example wasm builds are `-ODebug`
Visible in the orphan's command line: `-ODebug -target wasm32-wasi-none`. Per the measurements already in
claude.md, Debug costs ~2.4x the RAM of release for the same compile time — and this is the single heaviest
thing that runs on a 4GB box. An unfocused `zig build test` therefore builds a pile of Debug example wasms.
**Opportunity:** check whether the smoke actually needs Debug (it reads exports and counts host calls; it does
not read stack traces), and if not, drop it to release and take the RAM back. Focused smoke is fine either way
(3s, one wasm — the `-Dfocus` gate genuinely filters the BUILD, not just the run).

---

## FIXED in zimr857 (kept as a record of the shape)

- **`gl.texture(.source)` lied about its units.** Documented "in pixels", consumed as raw 0..1 UVs. All five
  call sites hand-divided by the texture size (`sr.x / tw`, ...) — five private copies of one transform — and
  none could express raylib's negative-extent FLIP, which is exactly what you need to draw a render texture.
  Now: pixels, with the flip, converted once inside the primitive. Same bug class as the `.fit` scissor
  letterbox (a transform re-derived per caller instead of living in one place) — that comment has now been
  written three times in this codebase.
- **The 3D camera UBO was single-slot.** `beginMode3D` → `resources.writeUbo` → one buffer at offset 0. Two
  3D passes in a frame (split-screen, minimap, 3D-into-RT — all things the engine advertises) meant every pass
  read the LAST camera. `split_screen` was RED on the clobber gate and nobody had run it. Now a 16-slot ring
  with a pre-built bind group per slot and an encoder-scoped overflow assert.
- **The 3D vertex streams restarted at offset 0 per flush.** Solid, line, textured and instanced. The
  instanced one did not even need a second pass to break: two `drawMeshInstanced` calls in one frame both
  wrote offset 0, so the first draw rendered the second mesh's transforms. Now all four append at a
  frame-scoped cursor, reset on encoder change.

## Stale documentation found (fixed in place)

- claude.md line ~4071 asserted "beginMode3D can NOT run inside beginTextureMode ... DON'T try to render
  immediate-3D into an RT". Untrue since the phase-SSOT fix — `split_screen` and `text_on_texture` both do it.
  A rule that has silently become false is worse than no rule: it stops you attempting the thing that works.
- claude.md's cold-setup step named `zig build --build-file tools/build.zig`; there is no `tools/build.zig`.
- `.zenv.sh` pinned a `0.17.0-dev.704` toolchain directory that had not existed for months, so sourcing it put
  no zig on PATH at all. Now glob-resolved.
