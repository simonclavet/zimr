# mocap_plan.md — mocap in zimr: BVH, FBX, and a skinned character

## STATUS — read this first

    DONE   codecs.bvh          parser + writer + round trip          (§3, §7)
    DONE   web.userfile        drag-and-drop + mobile file picker    (§4)
    DONE   examples/mocap_viewer  drop-to-view scrubber, ON DEVICE   (§5)
    DONE   codecs.fbx          container / objects / transform /
                               curves / takes  — 5 layers            (§8)
    DONE   bvh.fromFbx         FBX normalised INTO BVH               (§8)
    DONE   fbx.meshOf          Geometry -> triangulated welded mesh   (§11a)
    DONE   fbx.skinOf          Cluster -> boneIndices/boneWeights      (§11b)
    DONE   loadFbxModel        FBX -> Model + skeleton + clip, 1 call  (§11c)
    DONE   viewer reads FBX    sniffed by magic, one branch             (§11d)
    DONE   geno_dance         two rigs side by side, both skinned      (§11e-f)
    NEXT   the GenoView look  shadow+SSAO+lighting+FXAA, capsules     (§12)

Cross-validation that must keep holding: `dance1_subject2` exists as BOTH a `.bvh` and a `.fbx`,
and the same golden frame-0 joint positions come out of both paths. Any change that breaks that
has broken one of the two readers.

**Fixtures** (in `intake/`, excluded from snapshots — tests SKIP when absent):

    dance1_subject2.bvh      43 MB   7889 frames @ 60fps, 75 joints, ZYX, 6ch everywhere
    0005_2FeetJump001.bvh   1.5 MB   2575 frames @ 120fps, 25 joints, XYZ, 6/3 layout
    dance1_subject2.fbx      8.7 MB  same capture as the .bvh — the cross-check
    subject2.fbx              16 MB  RAW OPTICAL capture: 61 markers, no skeleton
    Geno.fbx                 1.2 MB  the character: mesh + skin + the SAME 75 joints
    Geno_bind / Geno_stance   ~0.9 MB each
    metahuman.fbx             10 MB  UE5 MetaHuman: BLEND SHAPES, no skeleton. v7400 —
                                     the only large file on the 13-byte-header path
    Drop_Kick.fbx            2.1 MB  Mixamo: 65 joints, 2 skinned meshes, TWO TAKES —
                                     the first of which is EMPTY

Goal, originally: `codecs.zig` gains `bvh`, and a `mocap_viewer` example reproduces **BVHView**'s
viewer — drop `.bvh` files onto the window, see them play. That is done and confirmed on device;
the arc has since extended through FBX to a skinned character (§10).

Reference implementations, all read for this plan:
- **BVHView** (`bvhview.c`, 4491 lines) — the original, single file, and it **already ships a
  working web build with drag-and-drop**.
- **flomo** (`Flomo/src/`) — Simon's descendant of it; adds FBX, retargeting, motion matching.
- **ufbx** (`Flomo/FBX2BVH/vendor/ufbx.c`, 33k lines) — ★ THE authority for FBX. flomo's own
  loader is a 435-line adapter over it; reading flomo alone teaches nothing about the format.
- **GenoView** (`genoview.c`) — the skinned-character target: shadow map, SSAO, FXAA, foot IK.

Fixture: `dance1_subject2.bvh`. Every number in §2 was measured from it, not assumed.

---

## 1. ★ The fixtures disprove two things I would otherwise have written

**(a) There is no fixed rotation order.** Three are now in evidence across the two fixtures and the
reference implementation:

    flomo CLAUDE.md + its FBX writer   ZXY   "R = Rz*Rx*Ry"
    dance1_subject2.bvh                ZYX   CHANNELS 6 Xpos Ypos Zpos Zrot Yrot Xrot
    0005_2FeetJump001.bvh              XYZ   CHANNELS 6 Xpos Ypos Zpos Xrot Yrot Zrot

Any hardcoded order is wrong on at least two of the three, and the failure is a plausible-looking
but wrong pose rather than an error. Both reference parsers are already general:
`TransformDataSampleFrame` (`transform_data.h:45`) and BVHView's equivalent accumulate
`rot = rot * quatFromAxisAngle(axis, deg)` walking `channels[]` **in file order**. **Follow the
code, not the note.**

**(b) "Root has 6 channels, other joints have 3" holds for one fixture and not the other.**
2FeetJump is the textbook shape (1x6 + 24x3). dance1 puts **6 channels on all 75 joints**.
Consequence in dance1, from the sampler's semantics: position channels **overwrite** `offset`, so
**every joint's OFFSET is ignored during sampling** — local translation comes wholly from motion
data. The offsets still matter for the up-axis heuristic (§2), which reads them directly. Code that
special-cases either layout breaks on the other.

---

## 2. Measured facts — TWO fixtures, and they disagree about almost everything

Everything below was computed from the files, not assumed. **The two disagree on channel layout,
rotation order, frame rate and units** — which is the whole reason this section exists.

                              dance1_subject2.bvh          0005_2FeetJump001.bvh
    size                      43.2 MB                      1.51 MB
    joints with channels      75                           25
    end sites                 21   (96 entries)            5    (30 entries)
    channels / frame          450  (75 x 6)                78   (1x6 + 24x3)
    channel layout            6 on EVERY joint             6 on root, 3 on the rest
    rotation order            Z Y X                        X Y Z
    frames                    7889                         2575
    frame time                0.016667  (60 fps, 131.5 s)  0.008333  (120 fps, 21.5 s)
    root OFFSET               (179.24, 82.76, 332.46)      (0, 0, 0)
    line endings              CRLF                         CRLF
    longest joint name        —                            18  (`RightHandThumb_end`)

★ **THREE ROTATION ORDERS ARE NOW IN EVIDENCE**: `ZXY` (flomo's CLAUDE.md and its FBX writer),
`ZYX` (dance1), `XYZ` (2FeetJump). Any hardcoded order is wrong on at least two of the three. The
composition order must come from the parsed `channels[]` list, full stop.

★ **BOTH CHANNEL LAYOUTS MUST WORK.** dance1 puts 6 channels on all 75 joints (so every joint
translates and every OFFSET is ignored at sample time); 2FeetJump uses the textbook 6-on-root /
3-elsewhere. Code that special-cases either shape breaks on the other.

**Golden frame-0 values** (sampled per §3, then FK, in file units, before any scaling). These are
the acceptance criterion for Phases 1–3:

    dance1_subject2                        0005_2FeetJump001
      Hips      (179.2447,  82.7627, 332.4578)    Hips      ( 1.1473, 32.8029,  1.7158)
      Spine     (179.2380,  91.5324, 330.1974)    Head      ( 2.3308, 57.4773,  4.3906)
      Head      (178.7699, 151.5824, 330.6483)    LeftFoot  ( 8.3880,  1.9723, -0.4477)
      LeftHand  (237.2591, 145.6055, 354.7706)    RightHand (-7.6398, 32.3560,  0.6576)
      RightFoot (163.0706,   7.3789, 330.5580)
      max Y = 162.7564                            max Y = 61.6882

### ★ The unit heuristic MISFIRES on the second file — and that is fine, because it is only a default

    dance1:      height 162.76 > 10  -> scale 0.01  -> 1.63 m   CORRECT
    2FeetJump:   height  61.69 > 10  -> scale 0.01  -> 0.62 m   WRONG (a 62 cm human)

61.69 is neither metres nor centimetres — at `0.0254` (inches) it gives 1.57 m, which is a plausible
human. flomo's binary "cm or m?" guess has no way to reach that.

**Both reference tools solve this the same way: they do not trust the heuristic, they ship manual
unit buttons.** `flomo.cpp:1327-1349` and `bvhview.c:3656-3662` both offer

    m (1.0)   cm (0.01)   inch (0.0254)   feet (0.3048)   auto (1.8 / height)

with the load-time heuristic choosing only the initial selection, and `auto` normalising any file to
a 1.8 m figure. **Ship the same five buttons.** Do not spend effort making the heuristic cleverer —
the reference implementations already concluded it cannot be made right, and the escape hatch is
four lines of UI.

**Up-axis heuristic** — both files are Y-up and both are classified correctly:

    dance1:     sum|y| = 647.11, sum|z| = 405.58   ->  not Z-up   (correct)
    2FeetJump:  sum|y| = 110.52, sum|z| =  25.24   ->  not Z-up   (correct)

But on dance1 the root's `offset.z = 332` is a **world placement**, not a bone direction, and
contributes 82% of the entire Z sum; excluding the root drops Z from 405.58 to ~73. 2FeetJump's root
offset is `(0,0,0)`, so excluding it changes nothing there. Excluding the root is strictly safer on
this evidence. ★ **Neither fixture is Z-up, so the rotation path in §3 has NO real test** — a
synthetic Z-up file is mandatory in Phase 0, and a real one is still wanted.

---

## 3. BVH semantics to implement

**Data model** (mirrors `definitions.h:773` / `bvhview.c:749`):

    Channel = enum { x_position, y_position, z_position, x_rotation, y_rotation, z_rotation }
    Joint   = { parent: i32, name, offset: [3]f32, channels: []Channel, end_site: bool }
    Data    = { joints: []Joint, frame_count, channel_count, frame_time: f32, motion: []f32 }

`motion` is flat, indexed `frame * channel_count + offset`.

**Sampling** (`transform_data.h:45`), per joint, walking `channels[]` in order:

    position = offset            // then position channels OVERWRITE a component
    rotation = identity          // rotation channels COMPOSE: rot = rot * axisAngle(axis, deg)

**One global cursor** walks the whole frame row across all joints. Both references assert
`offset == channelCount` at the end (`transform_data.h:99`, `bvhview.c:1308`). Keep it — it catches
malformed files at frame 0 instead of yielding garbage.

**Forward kinematics** (`transform_data.h:290`), one forward pass, `assert(parent <= i)`:

    p == -1:  globalPos[i] = localPos[i]                          globalRot[i] = localRot[i]
    else:     globalPos[i] = rotate(localPos[i], globalRot[p]) + globalPos[p]
              globalRot[i] = globalRot[p] * localRot[i]

Parents precede children because the parser appends depth-first.

**End sites** are real joint entries (offset, zero channels) so the bone to each extremity draws.
21 of them here.

**Case-insensitive keywords.** Both references match `HIERARCHY`/`ROOT`/`JOINT`/`End Site`
caselessly, with the comment that real files don't respect case. Free robustness.

---

## 4. ★ Web drag-and-drop: BVHView gets it free, zimr cannot

**How BVHView does it.** `bvhview.c:3844` is plain raylib — `IsFileDropped()` →
`LoadDroppedFiles()` → `CharacterDataLoadFromFile(path)` → `UnloadDroppedFiles()`. There is **no
drop JavaScript in `shell.html` at all.** The web build works because of two Makefile flags
(`Makefile:58`):

    -s USE_GLFW=3 -s FORCE_FILESYSTEM=1

GLFW's emscripten port listens for the browser drop event, reads the files asynchronously, writes
them into the emscripten MEMFS, and only then fires the GLFW drop callback with **paths**. raylib
sees ordinary paths and `fopen` works. The async read is hidden by a virtual filesystem.

**zimr has neither.** Verified: no `dragover`/`drop` listeners in `bridge.zig` (the `fn drop(id)`
there releases JS handles — unrelated), and **no runtime file input of any kind** — every example
gets assets via `@embedFile` at comptime (`obj_bunny.zig:27`, `gltf_simple.zig:24`). There is no
virtual FS to hide the asynchrony behind, and adding one to get a synchronous-path illusion would be
a large detour for no benefit.

So zimr's API should expose the asynchrony honestly, as a polled queue that fills as reads complete.
**Two entry points, one queue** — drop on desktop, file picker on mobile (§4a):

    z.requestUserFile(gl, ".bvh")           // opens the OS picker; mobile path
    z.userFileCount(gl) -> usize
    z.takeUserFile(gl, gpa) -> ?UserFile    // { name: []const u8, bytes: []const u8 }, caller owns

Named `userFile`, not `droppedFile`: once a picker feeds the same queue, "dropped" is a lie about
where the bytes came from. The example polls each frame exactly as it would poll `IsFileDropped()`;
files arrive a frame or two after the drop or the pick, which is invisible to a human.

Implementation notes for `bridge.zig`:
- `preventDefault` on **both** `dragover` and `drop`, or the browser navigates away to the file.
  This is the classic first bug in every web drop implementation.
- Read via `File.arrayBuffer()`, copy into wasm memory, push onto the queue.
- A 43 MB drop is realistic (§2) — do not assume small files; grow or reject explicitly.

### 4a. ★ The mobile picker, and the user-gesture trap

Dropping a file is not a thing on a phone. The web answer is the standard one: a hidden
`<input type="file" accept=".bvh">` that gets `.click()`ed, which opens the native picker. Same
`File.arrayBuffer()` read afterwards, same queue.

★ **THE TRAP: `input.click()` ONLY WORKS INSIDE A REAL USER-GESTURE HANDLER, AND ZIMR'S UI BUTTONS
ARE NOT ONE.** zimr's UI is immediate-mode and drawn *inside* the wasm, so a "Load file" button is
pixels on a canvas, not a DOM element. The press is detected while walking the UI during the frame —
i.e. inside a `requestAnimationFrame` callback, not inside the `pointerdown` listener that delivered
the tap. By then the browser's transient-activation token has expired and the picker is silently
blocked. On desktop it often works anyway; on mobile Safari it reliably does not. Discovering this
after the UI is built is the expensive order.

**zimr already solved this exact class of problem.** `bridge.zig:2960` — the text-input overlay port
for the mobile soft keyboard: *"A real `<input>` is positioned over the wasm-drawn widget, focused
right after display:block (the trick that pops the mobile keyboard)."* Same shape here: position a
real (transparent) `<input type="file">` over wherever the wasm draws its Load button, so the tap
lands on a DOM element and the gesture is genuine. Reuse that port's coordinate handling — its note
records that coords are identity under `.responsive` and that `.fit-mode` letterbox scaling is still
a follow-up, which applies to us too.

Fallback if the overlay proves awkward: have the `pointerdown` listener ask the wasm "is a file
button under this point?" and call `.click()` synchronously from inside that listener. Uglier, but
it keeps the gesture token.

**Available for the viewer UI:** `ui.slider` (`ui.zig:15004`), `ui.button` (14766), `ui.checkbox`
(14989), `ui.combo` (15970). **3D:** `drawSphereWires`, `drawCubeWires`, `drawLine3D`, `drawGrid`,
`drawCylinderBetween`, `drawCapsule`.

---

## 5. Viewer behaviour to reproduce

**Drop to load** (`bvhview.c:3844`, `flomo.cpp:2315`): every path in the drop is attempted; each
success appends a clip and becomes active (`characterData.active = count - 1`).

**Many clips at once.** `CharacterData` (`character_data.h:18`) is parallel arrays — `bvhData`,
`names`, `filePaths`, `scales`, `autoScales`, `opacities`, `radii`, `colors`, `upAxes`, `xformData`
— plus an `active` index. Colour assigned per index. Name is the basename (scan past the last `/`
and `\`, `character_data.h:172`).

**Skeleton rendering** (`flomo.cpp:887`):

    non-end-site joint : drawSphereWires(globalPos[i], 0.01, rings 4, slices 6, color)
    end site (optional): drawCubeWires (globalPos[i], {0.02,0.02,0.02}, endSiteColor)
    any joint w/ parent: drawLine3D(globalPos[i], globalPos[parent[i]], color)

Optional axis triads (`flomo.cpp:928`): size 0.1, `X→RED, Y→GREEN, Z→BLUE`, rotated by
`globalRotations[i]`. **Build this early** — it is the fastest way to see a wrong rotation order,
which given §1(a) is the most likely bug.

**Playback state** (`flomo.cpp:216`):

    looping, inplace (lock root translation), playTime, frameSnap,
    sampleMode (nearest | linear | cubic, default linear), frameMin/frameMax trim

`inplace` and the trim range are what make it a scrubber rather than a player. Both are cheap.

★ **Per-clip unit selector — REQUIRED, not optional** (`flomo.cpp:1327-1349`,
`bvhview.c:3656-3662`). Five choices: `m (1.0)`, `cm (0.01)`, `inch (0.0254)`, `feet (0.3048)`,
`auto (1.8/height)`. The load-time heuristic picks the initial one and **is wrong on 2FeetJump**
(§2), so without these buttons that fixture renders as a 62 cm figure and the viewer looks broken on
the second file it is handed. This is the cheapest possible fix for the single most likely
"why does it look wrong" report.

**Sampling modes** (`transform_data.h:103-160`): nearest = 1 frame, linear = 2 + blend, cubic = 4.
Ship nearest + linear; cubic later.

---

## 6. ★ The fixture is 43.2 MB and CANNOT be embedded as-is

The launcher standalone is currently 13.1 MB **total**. `@embedFile` of the full clip would more
than quadruple it, and the base64 wasm embedding inflates it further.

Measured trim options (header is 15.2 KB; motion rows average 5736 bytes):

    200 frames (3.3 s)  -> ~1.11 MB
    300 frames (5.0 s)  -> ~1.66 MB
    600 frames (10.0 s) -> ~3.30 MB

**DECIDED: ship the first 5 seconds — a 300-frame trim at 1.66 MB**, produced by a committed script
so it is reproducible and the provenance is recorded. That is the same order as `hello_world.html`
(1.7 MB) and comfortable inside the launcher. The trim exists already (`intake/`, verified: 300 rows
x 450 values, `Frames:` header rewritten, CRLF preserved).

Two further reductions are available if it needs to be smaller: drop the position channels from
non-root joints (they are 3 of every 6 numbers and, for a rigid skeleton, redundant — but note §1(b),
this file genuinely carries them, so this is a re-authoring not a filter), or emit fewer significant
digits — the file stores values like `1.81973137e-05` at a precision no viewer can show.

---

## 7. Phases

**Phase 0 — fixtures + golden tests.** Commit **both** fixtures and the trim script. Assert the §2
frame-0 globals for each, to 1e-3. The pair is the point: dance1 covers 6-channels-everywhere + ZYX
+ 60 fps, 2FeetJump covers 6/3 + XYZ + 120 fps, and **either alone would let a wrong implementation
pass**. Add a synthetic 2-joint file for a readable failure when something basic breaks, and a
synthetic **Z-up** file — neither real fixture is Z-up, so that rotation path is otherwise
untested.

**Phase 1 — `codecs.bvh` reader.** Case-insensitive keywords, CRLF tolerance, data-driven channel
order, the `offset == channel_count` assert, end sites as real joints. `LoadError`, matching `gltf`
and `stl`. No engine types — `codecs` is imported standalone by `mesh_bake`.

**Phase 2 — writer + round-trip test.** Parse → write → parse → compare. Cheapest correctness net;
also produces the trimmed fixture.

**Phase 3 — engine conversion in `draw3d.zig`.** `bvh.Data` → `ModelSkeleton` + `ModelAnimation`
(precedent: `loadModelAnimations`, `draw3d.zig:5312`, which owns allocation and pairs with an
`unload`). Plus the FK helper and the sampling modes.

★ **DECIDED: `BoneInfo.name` is a fixed `[32]u8` (`types.zig:479`) — TRUNCATE LOUDLY.** This
fixture's names are short (`Hips`, `Spine1`, `LeftHand`) so it will not bite today, but Mixamo's
`mixamorig:LeftHandMiddle4_end` is 29 bytes plus the NUL and its siblings overflow. Silent
truncation gives two bones the same name, which quietly breaks any later name-based retargeting.

"Loudly" means specifically:
- Truncate to 31 bytes + NUL, and **`std.log.warn` once per truncated joint** with the full name,
  the truncated name and the joint index — not a single summary line, because the useful signal is
  *which* joints collided.
- **Detect the collision, not just the overflow.** Truncation is harmless until two names become
  equal; that is the condition that actually breaks retargeting. After building the table, scan for
  duplicates among truncated entries and warn separately and more loudly for those.
- Keep the untruncated name in `bvh.Data` regardless. `codecs` has no 32-byte limit — the constraint
  belongs to the engine type, so the format-level data should stay lossless and let a future
  retargeter read full names from there.

**Phase 4 — user file input as engine surface** (§4, §4a). `bridge.zig` drop listeners + async read
+ polled queue, **plus** the overlaid `<input type="file">` for the mobile picker, both feeding one
`userFile` queue; exposed in `zimr.zig`. Independently useful to every future example wanting
user-supplied assets. Build the picker path first, not last: it is the one with the user-gesture
trap, and it is the only path that works on the device Simon actually tests on.

**Phase 5 — the `mocap_viewer` example.** Orbit camera, grid, embedded clip on start, drop-to-load,
multi-clip list with per-clip colour, skeleton draw per §5, scrub timeline, play/pause, loop,
in-place, sample-mode combo, and a joints/frames/duration/fps readout.

**Phase 6 — the heuristics and the unit selector** (§2). Up-axis detection, the initial unit guess,
and the five-button `m / cm / inch / feet / auto` selector. Note the ordering: the selector matters
MORE than the heuristic, because the heuristic is provably wrong on 2FeetJump and the selector is
what makes that recoverable. Settle the root-offset question here too. Left until the viewer exists
because a wrong up-axis is obvious on screen and nearly invisible in a test.

Phases 1–3 are testable headless; Phase 5 is the deliverable.

---

## 7a. ★ FUTURE PHASE — BVHView's analytical capsule shadows and AO

Studied but deliberately NOT implemented yet; recorded so the technique is not re-derived. This
is what makes BVHView's screenshots look like a renderer rather than a debug view, and it is a
self-contained arc that can land after the viewer works.

**The skeleton is CAPSULES, not spheres-and-lines.** The wireframe path (`flomo.cpp:887`,
`drawSphereWires` + `drawLine3D`) is the debug view. The presentation view draws one capsule per
bone and lights it analytically.

**Everything is analytical — there is no shadow map and no SSAO buffer.** The fragment shader is
handed the capsule list as uniform arrays and evaluates occlusion in closed form
(`bvhview.c:2680`):

    uniform vec3  shadowCapsuleStarts[SHADOW_CAPSULES_MAX];   // 64
    uniform vec3  shadowCapsuleVectors[SHADOW_CAPSULES_MAX];
    uniform float shadowCapsuleRadii[SHADOW_CAPSULES_MAX];
    uniform sampler2D shadowLookupTable;   + resolution
    uniform vec3  aoCapsuleStarts[AO_CAPSULES_MAX];           // 32
    ...  aoLookupTable + resolution

The closed forms come from Shadertoy `3stcD4` (`SphereOcclusionLookup`, `SphereOcclusion`, and
capsule equivalents at `bvhview.c:1916`). The **lookup tables are precomputed textures** for the
expensive part of those integrals — the shader samples rather than evaluating `acos`/`atan` per
pixel per capsule.

★ **`AO_RATIO_MAX = 4.0` is the culling criterion, and it is why this is affordable.** AO from a
capsule is defined to reach zero at four radii, so anything further away is provably invisible
and can be dropped before it ever reaches a uniform slot. With 32 AO and 64 shadow slots against
a 75-joint skeleton, that culling is not an optimisation — it is what makes the uniform arrays
big enough. Capsules are sorted by distance (`CapsuleSort`, `bvhview.c:2037`) so the nearest
ones win the slots.

Why it suits zimr specifically: it is a pure fragment-shader technique with two small lookup
textures and no extra render targets, so it needs no shadow-map pass, no depth prepass and no
G-buffer — it should port to the typed-shader path more or less directly. The uniform arrays are
the one thing to think about: a WGSL uniform array of that size wants a storage buffer, which
zimr already has (`wgpu.StorageBuffer`).

## 8. FBX — `codecs.fbx` (was `src/fbx.zig`; merged into codecs.zig)

**All five layers are DONE and living in `codecs.zig`**, 157 tests, 0 lint, `check` green.

★ **THE REFERENCE IS `ufbx.c`, NOT flomo.** flomo's `fbx_loader.h` is 435 lines, which badly
understates the job — it is a thin ADAPTER over ufbx, and **ufbx.c is 33,096 lines** (it is in
the uploaded zip at `Flomo/FBX2BVH/vendor/ufbx.c`; read it, do not guess the format). Everything
hard is delegated:

    ufbx_load_file(target_axes, target_unit_meters)  -> container, connections, axis + unit conv
    node->node_to_parent / node_to_world             -> the full transform chain, composed
    ufbx_evaluate_transform(anim, node, time)        -> curve lookup + interpolation + chain

Porting flomo alone would produce a file that calls functions nobody has written.

### Layering — each independently testable, which is the point of naming them

    1. Container   bytes    -> a tree of typed Nodes      DONE
    2. Objects     the tree -> objects + typed connections
    3. Transform   a node   -> its local matrix
    4. Animation   curves   -> a value at time t
    5. Adapter     all that -> `codecs.bvh.Data`

★ Layer 5 is the shape flomo proved: **FBX normalizes INTO BVH**, not into a parallel
representation. The sampler, forward kinematics, `ModelAnimation` conversion and the viewer then
work on FBX for free, and FBX costs one file rather than a second pipeline.

### Layer 1 facts, from `ufbxi_binary_parse_node` (ufbx.c:8958)

- Magic is 23 bytes, `"Kaydara FBX Binary  \x00\x1a\x00"`, then a u32 version.
- ★ **The record header WIDENS AT VERSION 7500**: three u64 fields (25 bytes) instead of three
  u32 (13). Reading the wrong width does not fail loudly — it yields a plausible end offset and
  the parse walks into the middle of a record. Both widths are covered by the tests.
- A record whose end offset AND name length are both zero is the **sentinel** terminating a
  child list; it is 13 or 25 zero bytes and looks like padding.
- Property codes: `Y i16, C bool, I i32, F f32, D f64, L i64` scalars; `f d i l b` arrays;
  `S` string and `R` raw blob, both u32-length-prefixed.
- Array header is `u32 length, u32 encoding, u32 compressed_length`; **`encoding == 1` is
  zlib-framed DEFLATE**, which real files use for anything large, so a decompressor is not
  optional. zimr already pays for one (`codecs.png`).
- Trust the record's DECLARED end offset over your own arithmetic — exporters leave padding.

Children are a contiguous SPAN into `Document.nodes`, like `codecs.xml`'s elements, built via a
scratch `pending` list for the same reason: a child's subtree is parsed before the next sibling
is known, so appending directly would interleave grandchildren between siblings.

★ **`fbx.Writer` — synthetic documents, because THERE IS NO .fbx FIXTURE.** flomo's `data/` was
never uploaded, so without a writer the container could not be tested at all. It also reaches
paths a captured file would not reach on demand (7400 vs 7500 headers, encoding 0 vs 1). Same
discipline as `bvh_synth`: the writer never parses.

Two stdlib traps, both already answered in-tree by `codecs.png`:
`std.compress.flate.Compress.init` asserts its output buffer is longer than 8 bytes (so an
Allocating writer cannot start empty) and needs its own `max_window_len` window; and inflate
must use `streamRemaining` into a FIXED writer — `readSliceAll` looks equivalent but drives the
decompressor's rebase path, which asserts against the empty window buffer and panics with an
integer overflow.

### ★ TWO REAL FIXTURES ARRIVED, AND THE CONTAINER READ BOTH FIRST TRY

    intake/dance1_subject2.fbx   9.1 MB   version 7700   6540 nodes, 22573 values
    intake/sample.fbx            3.4 MB   version 7400    204 nodes,   686 values

One on each side of the 7500 header split, which is exactly the pair the synthetic tests were
written to cover — and both parsed with no changes. **`dance1_subject2.fbx` is the SAME capture
as the BVH**, so layers 2-5 have ground truth: the §2 golden frame-0 values must come out the
same way through the FBX path.

**`sample.fbx` is a Blender 2.79 export of a STATIC MESH — no animation at all.** Its `Objects`
holds one `Geometry` and one `Model`, `Takes` is empty, and there are no `AnimationCurve`
records. Useful as a negative case (a loader must say "no animation" rather than crash or
invent one), not as a mocap fixture.

### Facts measured from `dance1_subject2.fbx` — these drive layers 2-4

**Object census** (440 `Objects` children): 76 `Model`, 75 `NodeAttribute`, 76 `Deformer`,
152 `AnimationCurve`, 57 `AnimationCurveNode`, 1 each of `AnimationStack` / `AnimationLayer` /
`Geometry` / `Material`.

★ **76 Models against the BVH's 75 joints.** The extra one is the container node flomo detects
and skips (`FBXNodeHasTranslationAnimation` + "has children") — so that heuristic is not
folklore, it is load-bearing on this very file.

★ **Names carry a `\x00\x01` separator**: the Model name field is literally
`"Hips\x00\x01Model"` — `Name\0\1ClassName`. A reader that takes the field whole gets joint
names no lookup will ever match.

★ **Only 57 of 76 models are animated**, and there are 152 curves — so most joints have NO
curves and their local transform must come from the static `Lcl Translation`/`Lcl Rotation`
properties. A loader that only walks curves silently loses two thirds of the skeleton.

**The transform chain is sparse but NOT collapsible** (counts out of 76 models):

    PreRotation      10      <- ★ NON-ZERO. Skipping it mis-poses 10 joints, subtly.
    RotationPivot     1
    ScalingPivot      1
    RotationOrder     6      <- 70 models rely on the DEFAULT order
    PostRotation      0
    RotationOffset    0
    ScalingOffset     0
    GeometricTranslation 0
    Lcl Translation  73   Lcl Rotation 69   Lcl Scaling 65   InheritType 76

So the needed composition reduces to `T · Rp · Rpre · R · Rp⁻¹ · Sp · S · Sp⁻¹`, and
**PreRotation is the term that must not be dropped** — it appears on exactly the joints where a
wrong pose looks plausible.

**GlobalSettings**: `UpAxis 1` (Y), `UpAxisSign 1`, `FrontAxis 2`, `CoordAxis 0`,
`UnitScaleFactor 1.0`, `TimeMode 3`. Already Y-up, no unit conversion — matching the BVH being
Y-up. Note this contradicts flomo's hardcoded `offsetScale = 0.01` (cm->m), which is right for
ufbx's `target_unit_meters` normalisation but wrong as a blanket constant: read
`UnitScaleFactor` instead.

**Connections**: 646 total — 362 `OO` (object-to-object: the node hierarchy) and 284 `OP`
(object-to-property: a curve node bound to `"Lcl Translation"` / `"Lcl Rotation"`). The `OP`
property strings are exactly the names flomo greps for.

**AnimationCurve layout**: `Default`, `KeyVer 4009`, `KeyTime` (i64 array),
`KeyValueFloat` (f32 array), `KeyAttrFlags`, `KeyAttrDataFloat`, `KeyAttrRefCount`.

★ **The curves are DENSELY BAKED — 7888 keys, one per frame**, against the BVH's 7889 frames.
So this capture needs no interpolation to reproduce the BVH; sampling at key times suffices.
Interpolation still has to be written (a hand-authored FBX will not be baked), but it is not on
the critical path to first pixels.

★ **The ktime unit is derivable from the file, not folklore**: successive keys differ by
`769769300`, and `769769300 × 60 = 46186158000` exactly — the FBX ktime-per-second constant,
confirming 60 fps and matching the BVH's `Frame Time: 0.016667`.

`KeyAttrFlags = 264` = `0x108`: cubic interpolation (bit 0x8) with tangent mode 0x100.

**NEXT: layer 2** — objects + connections. The `Connections` edge list is untyped (`OO`/`OP` by
i64 id), so it must be resolved into a typed graph before anything else can ask "what is this
node'''s parent" or "which curve drives this property".

## 8b. Why the rest of FBX is still the expensive part

The remaining layers are where the cost is. `ufbx_evaluate_transform` composes FBX's full chain
(`T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹`, per-node `RotationOrder`, geometric transforms) and
interpolates curves. That, not the binary container, is the cost.

Copy its shape when we do it: **it does not produce an FBX structure — it resamples into `BVHData`**
(root 6 channels, others 3, end sites 0), so everything downstream sees only BVH. One
representation, two front-ends. Gotchas it documented: static `Reference`/`World` nodes above the
hips in Mixamo exports (detected via "no `Lcl Translation` animation", skipped), and mixed units in
one API (`node_to_world` in metres, `node_to_parent` in file units, hence `offsetScale = 0.01`).

Cheapest path if the corpus is FBX: flomo already ships `-fbx2bvh`. Convert once and the whole
corpus is viewable after Phase 5.

---

## 9. Decisions taken, and what is still open

**DECIDED**

1. **Embedded clip** = first 5 seconds, 300 frames, 1.66 MB. (§6)
2. **`BoneInfo.name` overflow** = truncate loudly, warn per joint, and separately detect the
   truncated-name *collisions* that are the thing actually worth failing over. (Phase 3)
3. **Mobile input** = a real `<input type="file">` overlaid on the canvas, reusing the soft-keyboard
   overlay port at `bridge.zig:2960`; drop and picker feed one `userFile` queue. (§4a)

**STILL OPEN**

4. **Exclude the root offset from the up-axis sum?** (§2) It contributes 82% of Z on this fixture,
   and it is a world placement rather than a bone direction. Recommend excluding it; flomo's exact
   formula stays the default until there is a real Z-up file to compare both against.
5. **A Z-up fixture.** Both real files are Y-up, so §3's coordinate rotation — the messiest code in
   the plan, since it must re-decompose rotations into each joint's own channel order — has no real
   test. A synthetic one goes in at Phase 0, but a real Z-up capture (many optical systems export
   one) is still wanted before Phase 6 is trusted.
6. **A file with long joint names.** 2FeetJump's longest is 18 chars, dance1's are shorter, Geno's
   match dance1's; none reaches the 32-byte `BoneInfo.name` limit, so the truncate-loudly path
   (Phase 3) is untested by real data. Any Mixamo export would cover it.
7. **Inverse bind: derive or store?** (§11) Recommend deriving from `bindPose` and asserting
   against `Geno.fbx`'s `TransformLink`, so no shared type changes.
8. **A multi-take FBX.** Takes are modelled and the filter is asserted to be a no-op on the
   single-take fixtures, but nothing here has two. Simon has one — running it through
   `fbx.takeCount` / `takeAt` would close the last guess in the FBX reader.

---

## 10. Journal

**Phase 0 + Phase 1 DONE.** `codecs.bvh` parses; `src/bvh_synth.zig` generates test files.

`bvh_synth.zig` — procedural BVH generation. Options: `joint_count`, `frame_count`,
`frame_time`, `rotation_order` (zyx/xyz/zxy), `layout` (root_only/all_joints), `bone_length`,
`z_up`, `crlf`, `name_prefix`, `end_site`, `rotation_step`, `root_step`. It writes text and never
parses — keeping the generator ignorant of the parser is what stops the two agreeing on a shared
misreading. The skeleton is a straight chain because a chain's FK has a closed form a test can
state; branching is what the real fixtures are for.

★ Two generator details that make tests sharper, worth preserving:
- The per-frame angle goes on the joint's **FIRST rotation channel only**. A reader that ignored
  `channels[]` would then produce a *different* pose for `.zyx` vs `.xyz`, so the difference is
  the assertion (test: "rotation order changes the pose").
- A non-root joint with position channels is emitted **at its own bone offset**, so the pose is
  identical whether or not the reader honours OFFSET. That equivalence is what makes the dance1
  layout (6 channels everywhere, offsets dead) safe to assert on.

**7 tests, all green, in `codecs.zig`:** both real fixtures against the §2 golden FK values
(dance1 96 joints/450 channels/300 frames; 2FeetJump 30 joints/78 channels/2575 frames/5 end
sites), synthetic rest-pose FK, synthetic Z-up, the rotation-order discrimination test, malformed
input (4 shapes), and case-insensitive keywords. Fixtures are read through `bvh_readFixture`,
which **skips rather than fails** when `intake/` is absent — that directory is excluded from
snapshots, so a fresh checkout has the tests but not the 43 MB of data.

Implementation notes:
- The scanner is token-based, not line-based: `\r` is ordinary whitespace, which makes CRLF a
  non-issue instead of a special case, and lets a `CHANNELS` list wrap.
- `eatKeyword` saves and restores position, so keyword probing is free and case-insensitive.
- `}` pops to the joint that OPENED the brace and then steps to ITS parent — getting this wrong
  attaches siblings to the wrong parent, which FK then hides by still producing a plausible pose.
- End sites are named `<parent>_end`; the format gives them no name and a viewer's joint list
  needs one.

★ **LOOK IN THE TREE BEFORE CONCLUDING AN API "IS GONE".** Two 1902 lookups cost a round each,
and both were already answered by existing code:
- `std.heap.GeneralPurposeAllocator` was merely **RENAMED to `std.heap.DebugAllocator`**
  (`lib/std/heap.zig:24`). It is not gone. Most of the tree does not use it anyway — engine code
  takes an `Allocator` parameter, and tools use `ArenaAllocator` (`tools/zspv.zig:262`).
- `std.Io` changed substantially; `std.fs.cwd()` is now `std.Io.Dir.cwd()` and takes an explicit
  `std.Io` — see `spv2wgsl.zig:3311` (read a fixture) and `Canvas.zig:466` (write a file) for
  worked idioms.
The general rule: grep `src/` and `tools/` for the API first. This codebase is 200k lines and
almost every stdlib call it needs already appears somewhere.

Lint required: `zm.float`/`zm.radFromDeg` bound once at file scope (never qualified in a body),
`assert(ok, @src())` instead of `std.debug.assert`, type annotations on locals, braces on every
`if`, 120 columns.

**Phase 2 DONE.** `bvh.encode(gpa, Data) -> []u8`, matching `png.encode`'s
`encode(allocator, ...) Error![]u8` shape. 10 BVH tests green, 0 lint findings, `check` green.

★ **Floats are written with `{d}` (shortest round-trippable), NOT `{d:.6}`.** dance1 stores
values like `1.81973137e-05`; six decimals flattens those to `0.000000`, and the round-trip test
would then fail for a formatting reason having nothing to do with parsing. The motion comparison
is `expectEqualSlices(f32, ...)` — EXACT, not approximate — precisely so a formatting regression
cannot hide.

The encoder recomputes each joint's depth by **walking the parent chain**, rather than tracking a
depth counter while emitting. That makes it independent of everything except parents-preceding-
children, and it is what the branching test below actually checks.

Round-trip coverage:
- **24 generated variants**: 3 rotation orders x 2 layouts x z_up x crlf, with rotation and root
  translation both non-zero. Parse -> encode -> parse must agree on hierarchy, per-joint channel
  lists, offsets and every motion float.
- **A real capture** (2FeetJump, 2575 frames), so the tiny-value formatting question is settled
  against real data rather than synthetic round numbers.
- **A hand-written BRANCHING skeleton** — root -> (a -> end) plus root -> b. The generator only
  makes chains, and a chain can never catch a `}` handler that closes the wrong number of levels:
  the giveaway is `b`'s parent being the root rather than `a`, which a chain has no way to
  express. Worth keeping in mind generally — the generator's shape is also its blind spot.

Convention note: `codecs.zig` already had `stl_expect*` file-scope aliases because inner
namespaces shadow bare `expectEqual`. The bvh tests follow with `bvh_expect*`; adding unprefixed
file-scope bindings breaks the build with "ambiguous reference".

**Phase 3 DONE.** `draw3d.loadBvhSkeletalClip(gpa, bvh.Data) -> BvhSkeletalClip`, paired with
`unloadBvhSkeletalClip`, plus `bvhForwardKinematics`. 3 more tests, 0 lint findings, `check` green.

`BvhSkeletalClip` wraps `ModelSkeleton` + `ModelAnimation` + `frame_time` + `end_site: []bool`.
The end-site flags need their own array because `BoneInfo` cannot express them and a renderer
styles them differently. Helpers `boneName(i)` and `pose(k, i)` hide the `[*c]` casts — a
`&bones[i].name` through a `[*c]` is an ALLOWZERO pointer that `std.mem.sliceTo` refuses, and
every caller would otherwise repeat the same `@ptrCast(@alignCast(...))`.

★ **DO NOT free a `BvhSkeletalClip` with `unloadModel`.** That path frees `skeleton.bindPose`
with `libc.free` (`draw3d.zig:5305`) because it exists for models raylib's C loader allocated.
Ours comes from a Zig allocator. Mixing them is a crash, not a style question — hence the
separate `unloadBvhSkeletalClip`.

**Truncate-loudly, as specified.** `bvhCopyBoneName` warns per joint with the full name, the
byte count and the truncated result; a separate pass then warns again for any PAIR that
truncates to the same 31 bytes, naming both joints — that collision, not the truncation, is what
breaks name-based retargeting. `codecs.bvh` keeps names untruncated: the 32-byte limit belongs to
the engine type, not the format. Test uses `name_prefix = "mixamorig:LeftHandMiddle"`, the real
Mixamo case.

The FK golden values are re-asserted HERE through the engine types, not just at the codecs level,
so a conversion bug cannot hide behind a correct parser.

More 1902/tree lookups that were already answered in-tree: `errors.LoadError` has
`InvalidDimensions`, not `InvalidData`; `zm.Vec` is `@Vector(4, f32)` so `+` adds directly (there
is no `zm.add`); `zig test` on `draw3d.zig` needs `--dep shader_interface` as well as `--dep zm`.

**REFACTOR (after review): the loader now follows `xml`'s shape, not its own.** Reading the other
codecs properly changed four things, and each was a real defect rather than a style preference:

1. **Arena-owned `Data`.** `xml.Document` holds a `*std.heap.ArenaAllocator` and frees in one
   call. BVH now does the same, so `deinit()` takes no allocator and the per-joint
   `free(name)` / `free(channels)` loop is gone — that loop was a leak waiting to be written.
2. **`Diagnostic { line, context }`, actually reachable.** The first version tracked a line
   number and never surfaced it: the doc comment promised locations the API could not give.
   Now `parse(gpa, source, ?*Diagnostic)` reports the failing line AND the offending token,
   asserted in the tests. ★ The line is counted from the source ON DEMAND inside `fail()`,
   not tracked per token — failures are rare and files are 43 MB, so O(n) once on the error
   path beats a branch per token, and it deletes the `line_start` bookkeeping entirely.
3. **`std.mem.tokenizeAny`, as `stl.parseAscii` uses.** The hand-written `Scanner` (skipSpace,
   token, peek) is gone. `TokenIterator.index` is the whole of its state, so case-insensitive
   keyword probing is save-index / next / compare / restore-index — four lines instead of a
   struct. `\r` is just another delimiter, which is why CRLF needs no special case.
4. **`try` throughout instead of `catch return Error.OutOfMemory` on every allocation.** With
   the arena's `Allocator` and `Error` containing `OutOfMemory`, the coercion is automatic.
   That deleted roughly thirty `catch return` clauses.

Also split `Error.Malformed` into `MalformedHierarchy` / `BadChannels` / `BadMotion` (xml has
nine variants, each documented), moved channel names onto the enum as `Channel.name()` /
`Channel.fromName()` so the reader and writer cannot disagree about spelling, and **deleted
`Channel.isPosition` — nothing called it.** Speculative API is still dead code.

Two lint rules worth remembering: `std.math` is banned outside `zimrmath` with no `lint:off`
(use the `@mulWithOverflow` builtin to guard a size multiply read from a file), and
`useless-error-return` fires on an `Error!void` fn whose only failure is `return self.fail(...)`
via `orelse` — an explicit `if (x == null) { return self.fail(...); }` satisfies it.

Enum reflection in 1902 is `@typeInfo(T).@"enum".field_names` (see `ui.zig:19637`), not
`.fields`.

**Phase 4 DONE.** `web.userfile` (the Zig API) + the `bridge.zig` handlers. 3 host tests,
0 lint findings, `check` green.

★ **THE PROTOCOL WAS ALREADY IN THE TREE.** `web.audio`'s OGG decode documents a four-step
polling protocol for exactly this problem — a browser API that resolves later, on a
single-threaded runtime that cannot block (`web.zig:971`). `userfile` mirrors it:
`pendingCount()` -> `nextSize()` / `nextName(buf)` -> `readNext(buf)` -> `discardNext()`. No new
shape was invented; the file already had the answer.

Decisions worth keeping:
- **The externs live in the `dom` import namespace, not one of their own.** `bridge.zig` already
  routes persistence, clipboard, WebSocket and WebRTC through `dom`, and a fourth namespace
  would also need registering in the smoke runner's import spec.
- **`readNext` with a too-small buffer returns 0 and LEAVES the file queued**, so a caller who
  mis-sized can size again from `nextSize()` and retry instead of silently losing a drop.
- **The picker `<input>` is `opacity: 0`, NOT `display:none`/`visibility:hidden`.** A hidden
  input cannot be tapped, and the entire point is that the tap must land on a real DOM element
  so the browser sees a genuine gesture (§4a). The canvas still draws the visible button; the
  caller feeds its rectangle to `setPickerRect` every frame, because a stale overlay swallows
  taps meant for something else.
- **`ufOnPicked` clears `input.value`** — without it, picking the SAME file twice fires no
  second `change` event, and the second attempt looks like a hang.
- **The in-flight file NAME rides on the promise** rather than a Zig-side map: several reads can
  be in flight and the transpiler forbids closures, so the JS object in hand is the only place
  to hang per-operation state.

★ `preventDefault` on **both** `dragover` and `drop`. Without the first, `drop` never fires;
without the second, the browser NAVIGATES AWAY to the dropped file and the app vanishes — which
looks exactly like a crash.

Tree lookups that saved guessing: `ZimrBoot` has its own `modU8`, while `modBytes`/`numValue`
belong to `ZimrWgpu`; the file-scope `num(x)` at `bridge.zig:6127` is the general
number-to-`Value`. `web.zig` already binds `expectEqual` at file scope.

**Phase 5 IN PROGRESS.** `examples/mocap_viewer` compiles and is registered; `check` stays green.
Orbit camera, grid, embedded 300-frame clip, drop-to-load, multi-clip list with per-clip colour
and visibility, wireframe skeleton with optional end sites and RGB axis triads, scrub timeline,
play/loop/in-place, and the five-button `m/cm/inch/feet/auto` unit selector.

★ **THE BIND-GROUP VALIDATOR FIRED — ON A REAL EXAMPLE, HEADLESSLY. That is the true positive it
never had.**

    ✗ FAIL mocap_viewer  gpu-validation: drawIndexed with pipeline "shapes" needs a bind group
    at group 1 (its layout "resources_bgl" declares 2 binding(s)) but none is set.

Not a false alarm: `zig build check` is green with the validator active, and `robot_3d` fails
smoke for an unrelated wasm trap rather than a gpu-validation finding. Only the new example
trips it.

Hypothesis TESTED AND REFUTED: "mocap_viewer is the first example that draws only WIREFRAME
primitives, so nothing textured ever binds the atlas." Adding a solid `drawSphere` changes
nothing.

★ The remaining explanation is the divergence recorded during the wgpu_bringup hunt and never
resolved: **`setPipeline` updates `ps.current_pipeline` but does NOT invalidate
`ps.current_bind_groups`, while WebGPU DOES invalidate bind groups when an incompatible pipeline
layout is set.** So after a 3D pipeline is bound and the shapes pipeline comes back, the batch's
`setBindGroup(1, atlas)` is DEDUPED — the tracker still believes the atlas is bound — and the
device is left with group 1 unset. The validator models WebGPU's rule; `gpu_iface`'s dedup does
not. This example mixes 3D primitives and 2D UI in a way the existing set apparently does not.

**RESOLVED — and the `--trace-calls` tracer settled it in one run, no device round needed.**
The trace named the exact instruction sequence:

    set_pipeline(96, 82)        <- back to "shapes" after 3D pipelines 104/105
    set_bind_group(96, 0, 13)   <- group 0 rebound (resources.bind)
    set_bind_group(96, 0, 19)   <- group 0 again (the ortho ring override)
    draw_indexed(...)           <- NO group 1 bind in between
    set_bind_group(96, 1, 91)   <- group 1 only AFTER the failing draw

Group 1 was last set BEFORE the 3D pipelines. `resources.bind` does try to rebind it; the dedup
in `setBindGroup` eats the call because `ps.current_bind_groups[1]` still holds the stale atlas.

★ **FIX: `WgpuBackend.invalidateBindGroups(ps)`, called at the top of
`Renderer2D.bindForPass`.** That function is called both at pass start and as the RESTORE after
a foreign pipeline, and in the restore case the device has already invalidated the groups while
the tracker has not. Binding unconditionally is what "bind for pass" has to mean; the cost is a
few redundant binds per pass. `✓ PASS mocap_viewer`, `check` green, 0 lint.

Blast radius checked before fixing: `bone_socket` (3D + skinned mesh) passes clean, so the
validator was not blanket-failing 3D — the bug needed a return to the 2D shapes batch after a
foreign pipeline, which no existing example did.

★ **This is the payoff the validator was built for.** Two turns ago it was "an unfired gun" with
an unproven true-positive path. It has now caught a REAL engine bug — the same
tracker-vs-device divergence first suspected during the wgpu_bringup hunt and left unresolved —
at the door, headlessly, on the first new example to expose it. The `--trace-calls` addition
(now logging ARGS, not just verb names: for a bind-group bug the index is the whole question)
is what turned the finding into a diagnosis.

**Viewer CONFIRMED WORKING ON DEVICE** (Simon, turn after Phase 5) — so drag-and-drop, the
picker overlay and the whole `userfile` path are validated in a real browser, not just against
host stubs.

**Embedded clip changed to frames 1200-1800 (20 s to 30 s, 10 s at 60 fps), 3.62 MB.** The
opening seconds of `dance1_subject2` are mostly the performer standing still, so the first-5-s
cut made the default look broken. Standalone is now 7.4 MB (was 4.6 MB with the 5 s clip);
still well under the 13 MB launcher.

★ **`tools/bvh_trim.zig` — the trim is now a committed tool, not a hand-run script.** It runs on
zimr's OWN codec (`bvh.parse` then `bvh.encode`), which is the point: the shipped asset is a
product of the round trip the tests assert, so a parser or writer regression breaks the example
rather than silently diverging from the library that reads it. It also exercises the codec on
the full 43 MB capture — 6 s, parse and re-encode.

    bvh_trim intake/dance1_subject2.bvh examples/mocap_viewer/dance1_20s.bvh 1200 600

Wired in `build.zig` next to `mesh_bake`, with its own host-side `codecs` module instance for
the same reason (disjoint compile graph keeps the one-file-per-module rule satisfied).
Trimming is a slice, not a copy: `motion` is row-major, so a frame range is one contiguous
sub-slice and the hierarchy is shared verbatim.

Tool-writing note: native tools take `pub fn main(init: std.process.Init)`, taking `init.gpa`
and `init.io` — there is no `std.process.argsAlloc`, and no need to build a `std.Io.Threaded`.
Argv comes from `std.process.Args.Iterator.initAllocator(init.minimal.args, gpa)`. Copied from
`tools/mesh_bake.zig:308`.

**NEXT** — Phase 6: the up-axis heuristic and the initial unit guess (the selector itself is
already in the viewer).: orbit camera, grid, embedded clip, drop-to-load,
multi-clip list, skeleton draw, scrub timeline, and the `m/cm/inch/feet/auto` unit selector
(§5 — required, not optional).

---

## 11. ★ THE GENOVIEW TARGET — skinned character, and what it needs from us

`GenoView-InverseKinematics` (Simon's raylib app) is the shape this should reach: a skinned
character with shadow mapping, SSAO, FXAA and foot-locking IK. Studied, and it changes the plan
in one important way — **the animation half is already done; the MESH half is the gap.**

### The fixtures are the same character

    Geno.fbx            v7700   287 objects   75 LimbNode + 1 Mesh + 1 Geometry (9332 verts)
                                1 Deformer/Skin + 75 Deformer/Cluster, 7 Cameras
    dance1_subject2.fbx v7700   440 objects   75 LimbNode + 1 Mesh named "Geno", 152 curves
    subject2.fbx        v7700   287 objects   61 OpticalMarker + 7 Camera (raw capture)

★ **All 75 joint names match between `Geno.fbx` and `dance1_subject2.fbx`** — verified by
comparing the two name sets, not assumed. So the dance capture drives the Geno rig directly, and
"load the character, play the mocap on it" is a two-file demo rather than a retargeting problem.
That is the acceptance test for this arc.

Our parser reads all three today with no changes.

### ★ THE DATA MODEL ALREADY MATCHES. This is the key finding.

`genoview.c`'s `LoadGenoModel` fills a raylib `Model` with `meshes[0].boneIds` (u8 x 4 per
vertex) and `boneWeights` (f32 x 4); `LoadGenoModelAnimation` fills a raylib `ModelAnimation`.
**zimr's `types.Model` / `types.Mesh` / `types.ModelAnimation` ARE those types** — they were
ported. There is no impedance mismatch to design around:

    GenoView                      zimr                                status
    meshes[0].boneIds             Mesh.boneIndices [*c]u8, 4/vertex   type exists, NO PRODUCER
    meshes[0].boneWeights         Mesh.boneWeights [*c]f32, 4/vertex  type exists, NO PRODUCER
    model bones / bindPose        ModelSkeleton {bones, bindPose}     built by loadBvhSkeletalClip
    ModelAnimation.framePoses     ModelAnimation.keyframePoses        built by loadBvhSkeletalClip
    Geno.bin (offline export)     —                                   NOT NEEDED: we read FBX

★ GenoView needs an offline Maya/Python step (`export_geno.py`) to bake `Geno.bin` because
raylib cannot read FBX. **We read the FBX directly, so that step disappears.** That is the
concrete win over the reference implementation, and worth stating as a goal so nobody later
reimplements the workaround.

### What FBX carries that we do not yet extract

Measured from `Geno.fbx`:

    Geometry.Vertices            27996 doubles = 9332 vertices
    Geometry.PolygonVertexIndex  37320 ints    ★ a NEGATIVE index marks a polygon's last
                                               corner, encoded as ~i — an FBX quirk, not a bug
    Geometry.LayerElementNormal / LayerElementUV / LayerElementMaterial / Layer
    Deformer "Skin"    (1)       Link_DeformAcuracy
    Deformer "Cluster" (75)      Indexes (i32[]), Weights (f64[]),
                                 Transform (f64[16]), TransformLink (f64[16])

**One cluster per joint**, each listing the vertices it influences and their weights — the
TRANSPOSE of what a GPU wants. `Mesh.boneIndices` is per-vertex with four slots, so extraction
must invert the mapping, keep the four strongest weights per vertex and RENORMALISE them.
`export_geno.py:143-151` does exactly that (`argsort`, take 4, divide by the sum); a naive port
that just takes the first four influences silently loses weight and deforms subtly wrongly.

`TransformLink` is the BONE's global transform at bind time, `Transform` the mesh's. The
inverse-bind matrix a skinning shader wants is built from those.

★ **`ModelSkeleton` HAS NO INVERSE-BIND FIELD.** It carries `bindPose` (a TRS per bone), and
`examples/skinned_mesh` keeps its own `inverse_bind: [max_joints]Mat` alongside. Inverse bind is
derivable by inverting the bind pose's world matrix, but FBX states it explicitly.
**Decide before writing the extractor:** derive from `bindPose` (no change to a shared type, one
more place to drift) or add the field (touches `types.zig`). Recommend DERIVING, and asserting
the derived matrix against the file's `TransformLink` on `Geno.fbx` — that buys the check
without the type change.

### ★ THE INDEX-SPACE CONSTRAINT, which is where this would go wrong quietly

`bvh.fromFbx` numbers joints in DEPTH-FIRST walk order. A Cluster names its bone by FBX object
id. If mesh extraction resolves cluster → bone independently, the two index spaces diverge and
the mesh binds to the wrong bones — a skeleton that animates correctly wearing a mesh that
deforms wrongly, which reads as "the skinning is broken" rather than "the indices disagree".

**Mesh extraction must SHARE the builder's object-index → joint-index map, not rebuild it.**
`FbxBuilder` already keeps `sources` (joint → FBX object); the extractor needs the inverse. This
is the single most important structural decision in the next phase.

### Phases

- **10a. `fbx` mesh extraction** → `types.Mesh`: positions, normals, UVs, indices, triangulating
  the polygon list via the negative-index terminator. No skinning yet; testable against
  `Geno.fbx`'s 9332 vertices.
- **11b. Skin weights** → `boneIndices` / `boneWeights`: invert the cluster mapping, top 4,
  renormalise. Shares the index map (above).
- **11c. `loadFbxModel`** → a `types.Model` carrying skeleton + mesh, so `drawModel` works and
  the existing `skinned_mesh` path applies.
- **11d. The viewer opens BOTH formats — DONE.** `mocap_viewer` now takes `.bvh` and `.fbx`
  by drop or picker; smoke PASS, standalone 7.4 MB.

  ★ **THE FORMAT IS SNIFFED FROM THE BYTES, NOT THE NAME.** A dropped file is called whatever
  the user called it, and on the web there is no path at all — but an FBX opens with a 23-byte
  magic, so the content answers definitively.

  ★ **The whole change is ONE BRANCH in `addClip`**, because both arms end at the same
  `bvh.Data`. Everything below — skeleton conversion, sampling, forward kinematics, the
  timeline, the unit selector — never learns which format it came from. That is the dividend of
  flomo's decision to normalise FBX INTO BVH rather than build a parallel representation, and
  it is the strongest evidence the decision was right: a format many times more complex cost
  one `if`.

  A non-character FBX reports "no skeleton (mesh or marker data?)" rather than "parse failed",
  since `subject2.fbx` and `metahuman.fbx` are perfectly valid files.

  ★★★ **THIS IS WHERE THE FBX CODE WAS FIRST COMPILED FOR WASM, AND IT DID NOT BUILD.**
  `usize` is 32-BIT on wasm32 while `h.count` is a u64 read straight from the file, so
  `for (0..h.count)` is a compile error there — and a bare `@intCast` would have TRUNCATED a
  hostile count into a small, plausible loop. Now bounded against the bytes remaining: every
  value costs at least one byte, so a count larger than what is left cannot be honest.

  ★ Worth generalising: **166 host tests passing says nothing about the 32-bit target.** Any
  new `codecs` work should be built for wasm before it is called done — `zig build <example>`
  is the cheapest way to force it.

- **11e. `examples/geno_dance` — DONE.** The FBX character wearing the BVH capture. Smoke PASS,
  standalone 9.1 MB, 0 lint, `check` green. This is the arc's payoff: `Geno.fbx` -> mesh + skin
  + skeleton, `dance1_20s.bvh` -> motion, CPU skinning, `drawModel`.

  ★ **NO RETARGETING, AND IT IS MEASURED**: the two skeletons agree on **96/96 bones — same
  names at the same indices**, end sites included. Verified index by index, not inferred from
  the names lining up. So dance frame joint `i` drives mesh joint `i` with no mapping table.
  The example re-checks it at load and says so in the UI, because the day it stops being true
  the mesh should not deform quietly wrongly.

  ★ **INVERSE BIND: DERIVED, and §11's open question is now closed.** `Geno.fbx`'s own take IS
  its bind pose (one frame, 0.017 s), so forward kinematics on frame 0 gives `bindWorld`
  directly, and a RIGID inverse (transpose the rotation, negate the translation through it) is
  exact — BVH carries only rotation and translation, so there is no scale to worry about. No
  new field on a shared type, no second source of truth.

  ★★★ **THE BUG THIS FOUND: `unloadModel` FREES SKELETON ARRAYS WITH `libc.free`.** It predates
  the gpa-allocating loaders. `loadFbxModel` points `model.skeleton` at the arrays the clip owns
  — deliberately, so `updateModelAnimation` can reach them without a copy — and letting both
  teardown paths run crashes. **60 frames rendered perfectly and the smoke died in
  `runnerDeinit`**, which is the signature of an ownership bug rather than a logic one. Fixed at
  the source: `FbxModel.deinit` clears the BORROWED pointers before `unloadModel` sees them.
  This is the same hazard already recorded for `unloadBvhSkeletalClip`, now hit for real.

  Two Zig notes: a `Mat` row is a SIMD vector, so transposing needs `inline for` — a vector
  cannot be indexed with a runtime value. And `zimr.draw3d` is a hand-written re-export
  namespace, so new `draw3d` API is invisible to examples until it is listed there.

  ★★★ **DEVICE TEST: THE MESH EXPLODED INTO A FAN OF TRIANGLES AND KEPT MOVING WHILE PAUSED —
  and the SKELETON overlay was PERFECT.** That split is the entire diagnosis: parse, forward
  kinematics and pose were all correct, so only the skinning could be wrong; and "still moving
  with playback off" means the input is changing, i.e. FEEDBACK.

  **BUG 0 — `updateMeshBuffer` WRITES INTO `mesh.vertices` ITSELF.** Reading the rest pose from there
  means every frame skins the PREVIOUS frame's output — the figure inflates and drifts forever.
  `examples/skinned_mesh` keeps `base_positions` for exactly this reason and I did not copy the
  pattern. Fixed by saving the rest pose at load.

  ★★★ **SECOND DEVICE TEST: TORSO CORRECT, LIMBS AS TENTACLES — "a possessed Dr Octopus".**
  Two more real bugs, and the first one shows why the invariant test was not enough.

  **BUG A — THE BIND POSE MUST BE READ, NOT DERIVED.** Each skin `Cluster` records
  `TransformLink`: the bone's global transform AT THE MOMENT THE SKIN WAS BOUND. Deriving the
  bind from the node hierarchy's rest pose looks reasonable and is wrong — on `Geno.fbx` the
  two disagree badly down the limbs, which is exactly the torso-fine/limbs-wrong signature.

  ★ **AND THE PASSING IDENTITY TEST COULD NOT HAVE CAUGHT IT**, because
  `inverse(X) * X == identity` FOR ANY X. That check validates the inverse and the multiply
  order and never the CHOICE of X. A green test proved less than it appeared to.

  **BUG B — A GEOMETRY'S CONTROL POINTS ARE IN ITS NODE'S LOCAL SPACE.** `Geno.fbx`'s mesh node
  carries `Lcl Translation (0, 139.99, -0.11)` and a 1.032 scale; its raw vertices run Y -138 to
  +28 (origin at the shoulders) while its skeleton stands Y 1 to 171. Without composing the mesh
  node's own world transform the character sits **139 units underground at exactly the right
  size and shape** — which staring at the geometry alone would never reveal. Fixed by baking
  `fbx.globalTransform` into positions, and its rotation/scale into normals, at load.

  Also learned: `Transform` on a Cluster is NOT "the mesh's global at bind" — `Geno.fbx`'s 75
  clusters carry **67 distinct** ones, so it is per-cluster bookkeeping. The bind matrix is just
  `inverse(TransformLink)`.

  ★★★★ **FIFTH ROUND — THE STEP BACK, TEN HYPOTHESES, AND THE REAL ROOT CAUSE.**
  Simon: "you are stuck. Form 10 hypotheses and design experiments to disprove each."
  That was right, and the cheapest experiment answered it immediately.

  **THE EXPERIMENT**: if a joint's bind position is correct, the vertices it dominantly weights
  must CLUSTER AROUND IT. Take each joint's vertex centroid; compare to the candidate bind.

      bind from FK on the file's frame 0      mean 35.0 units off, worst 55.5
      bind from the clusters' TransformLink   mean  5.0 units off, worst 20.9

  5 units is flesh-radius around a bone; 35 is a limb length. **`Geno.fbx`'s frame 0 is a T-POSE
  — every hand joint at Y~138, arms horizontal — while the MESH is modelled in an A-POSE, its
  hand vertices centred near Y~95.** Skinning an A-posed mesh against a T-posed bind tears the
  limbs off, which is precisely what every screenshot showed.

  ★★ **AND `TransformLink` IS WHAT I HAD, AND REJECTED, TWO REVISIONS EARLIER.** The evidence
  against it — `inverse(TransformLink) * bindWorldFromFk` deviating from the identity on all 96
  joints — was CORRECT AND EXPECTED: two genuinely different poses SHOULD differ. It only read
  as a bug because the two zm convention faults below were still corrupting the render, so
  switching binds changed nothing visible. **Correct evidence, misread, because a second fault
  masked the test.** With one fault outstanding, no single-variable experiment is conclusive.

  **RESULT**: the mesh now hugs its skeleton on every sampled frame of a foreign clip —

      frame   0  bones (98,-1,344)..(193,163,410)   mesh (95,-2,338)..(193,164,409)
      frame 400  bones (-35,2,442)..(17,142,514)    mesh (-37,-1,439)..(25,146,514)

  ★ **THE PERMANENT GUARD IS THE CENTROID TEST**, because it asks a question about the WORLD
  rather than about matrix algebra. Bind-pose identity, bounding boxes and the convention checks
  ALL passed with the wrong pose; none of them compared the mesh to the skeleton POSITIONALLY.
  The foreign-clip tolerances also dropped from 60 units to 15 — a wrong bind needed the slack.

  ★★★ **FOURTH DEVICE TEST — AND TWO zm CONVENTIONS.** Simon: "are we sure
  the mesh is compatible? Look at genoview. Maybe look at the bind pose first." Backing up that
  far was right, and the answer came from MEASURING the animated result rather than the bind:

      hips-point (0,85.5,0) -> (-8.4, 80.6, -27.3)      should be the animated hips
      frame 0    bones (98,-1,344)..(193,163,410)
                 mesh  (-89,-58,-88)..(85,163,110)      centred on the ORIGIN

  The mesh was not following the root at all. Two causes, both convention, **both invisible in a
  bind pose** — which is why every bind-pose test passed while the animation was broken:

  1. ★ **`zm.vec` IS A DIRECTION (lane 3 = 0)**, and its own doc comment says so. Using it for a
     vertex POSITION discards every skin matrix's translation. `zm.pointVec` sets lane 3 to 1;
     `examples/skinned_mesh` writes `f32x4(x, y, z, 1.0)` explicitly for exactly this reason.
  2. ★★ **`zm.mulMat(a, b)` APPLIES b FIRST, THEN a** — opposite to reading it left-to-right and
     opposite to raylib's `MatrixMultiply`, which is precisely the difference Simon warned
     about. Measured: `mulMat(rotate90Z, translate10X)` sends (1,0,0) to (0,11,0). So "rotate
     then translate" is `mulMat(translation, rotation)`, and "invBind then world" is
     `mulMat(world, invBind)`.

  After both: `hips-point (0,85.5,0) -> (130.7, 66.7, 369.7)`, **exactly the animated hips**,
  and the mesh tracks the skeleton across every sampled frame while the root travels.

  Also settled: the earlier `TransformLink` detour was chasing a symptom of these two. Deriving
  the bind from the same FK the animation uses is correct AND simplest — and the inverse is now
  composed from inverse PARTS (`mulMat(matFromQuat(conjugate(q)), translationV(-p))`) rather
  than by inverting a matrix by hand, so it needs no assumption about where the translation
  lives.

  ★ **The permanent guard is a convention test plus a FOREIGN-CLIP test.** The bind-pose
  identity check could never have caught either bug; driving the character with a DIFFERENT
  clip and requiring the mesh to stay wrapped around its own bones catches both.

  ★★★ **THIRD DEVICE TEST, AND THE STEP BACK THAT SETTLED IT.** Still broken. Simon's pointer —
  "our matrix multiplication is different from raylib, and our skinning demo in the launcher
  WORKS" — was the right instruction: stop reasoning about FBX and compare against
  `examples/skinned_mesh`, which is correct in OUR conventions.

  Two hypotheses were TESTED AND REJECTED before the real one, which is the part worth keeping:
  - `matFromQuat` vs `zm.rotate` disagreeing about direction. A three-line test says they agree.
    (Kept as a permanent test: the skeleton overlay draws POSITIONS ONLY, so a transposed
    rotation would be invisible there while corrupting every skin matrix.)
  - The FBX `Transform`/`TransformLink` composition order. Changing it moved nothing.

  ★ **THE MEASUREMENT THAT ANSWERED IT**: `inverse(TransformLink) * bindWorldFromFk` against the
  identity deviates on **ALL 96 joints, worst 194 at LeftArm**. So `TransformLink` is expressed
  in a space this pipeline never visits — it predates the BVH normalisation the skeleton goes
  through — and mixing the two binds the mesh to transforms its own skeleton never reaches.

  **THE FIX: DERIVE THE BIND FROM THE SAME FK THE ANIMATION USES.** Self-consistent by
  construction — same `bvhForwardKinematics`, same matrix build, same conventions. The identity
  check now reads **0.0000 across all 96 joints**, and the bounding boxes finally agree:

      bones  (-89.3,  1.1, -9.6)..(90.4, 171.1, 15.0)
      mesh   (-59.7, -0.5,-16.2)..(59.7, 170.2, 11.9)

  ★★ **AND DERIVING IS WHAT I TRIED FIRST.** It produced tentacles — but the cause was the
  MISSING MESH-NODE TRANSFORM, not the derivation. Changing both at once hid which was which;
  they had to be separated to tell apart. **Fixing two things in one step cost two device
  rounds.** The Z-spread "known residual" recorded last revision was this same bug, and it is
  gone rather than tolerated — the test now asserts all three axes tightly.

  **SUPERSEDED — the depth axis.** After both fixes X and Y land within a few units of the
  skeleton (mesh Y -1..170 against bones 1..171), but the skinned mesh spans ~104 units in Z
  against the skeleton's 25. Placement and bind are right; something still spreads vertices
  along the capture's depth axis. The test asserts X/Y tightly and Z loosely WITH A COMMENT
  SAYING SO — a tolerance wide enough to hide this would also hide a relapse.

  ★ **The regression test is an INVARIANT, not a screenshot**: posing the character with its
  OWN bind pose must reproduce the rest mesh, because
  `skin[j] = inverse(bindWorld[j]) * bindWorld[j] = identity`. Worst vertex error is under 0.01
  on a ~160-unit mesh across all 10329 vertices. Any error in the inverse, the multiply order
  or the joint indexing shows up as displacement — whereas a rendered frame only ever says
  "looks wrong". Had this existed before the device test, it would have proven the MATH was
  fine and pointed straight at the buffer aliasing.
- **11f. SIDE BY SIDE — DONE, and it is the generalisation proof.** `geno_dance` now stands two
  characters together:

      Geno.fbx + dance1_20s.bvh   75+21 bones, 1 mesh, 10 s, motion BORROWED
      Drop_Kick.fbx (Mixamo)      65 bones, TWO meshes, 2.9 s, motion its OWN take

  ★ They share nothing — bone count, naming (`mixamorig:`), mesh count, frame rate, and even
  how the motion arrives all differ. Everything the Geno path proved could still have been
  Geno-specific; this is the check that it is not. It also exercises the MULTI-MESH path, which
  Geno never does.

  The centroid test runs on both: Geno scores mean 5.0, **Drop_Kick scores 4.1** — the same
  flesh-radius figure on a rig that shares nothing with it. Asserted for both.

  Each clip loops on its own length, so a 10-second capture and a 2.9-second kick play together
  without one truncating the other. Standalone 11.8 MB, smoke PASS.

- **11g. CLEANUP PASS — DONE.** The pipeline works; this made it readable.

  ★ **CPU SKINNING IS NOW ENGINE API, NOT EXAMPLE CODE**: `draw3d.poseSkinMatrices` +
  `draw3d.skinMeshCpu`. It was written THREE times — twice in tests, once in the example — and
  every copy had to independently get right the two zm conventions that took five device rounds
  to find. Their docs are now the single place those live, next to the test that pins them.

  ★ **`examples/geno_dance` no longer imports a single matrix function.** It went from
  hand-rolling `mulMat`/`mulMatVec`/`matFromQuat`/`translationV`/`pointVec` to importing none
  of them. Getting the conventions wrong is no longer something an example CAN do — which is
  worth more than any comment warning about it.

  Dead code removed: `clusterInverseBind` still carried the abandoned `Transform` composition
  and a long comment arguing for an order that is no longer taken. Its doc now states what is
  true — the bind is `inverse(TransformLink)`, and `Transform` is deliberately unused because
  `Geno.fbx` has 67 distinct ones across 75 clusters.

  The example's module doc described one character; it now describes both and points at where
  the math lives.

### ★ FIVE FIXTURES, AND THE FIFTH BROKE THE RULE AGAIN

`metahuman.fbx` (UE5 MetaHuman, v7400, 10 MB) parses in 136 ms and is a **blend-shape rig**:

    5 Models: 4 Null + 1 Mesh          (no LimbNode anywhere)
    3 Geometry: 1 Mesh + 2 Shape       (morph targets)
    3 Deformers: 1 BlendShape + 2 BlendShapeChannel   (no Cluster)
    47 AnimationCurves driving blend-shape WEIGHTS

The four Nulls are `rig`, `body_grp`, `geometry_grp`, `body_lod0_grp` — ORGANISATIONAL GROUP
NODES. The blacklist fallback admitted all four and produced a four-bone "skeleton".

**Both tiers of joint detection are now POSITIVE:**

    by_subtype       the file names its joints (LimbNode / Limb / Root)        exact
    by_skin_cluster  no named joints, but a skin Cluster points at a Model —
                     a Cluster exists solely to bind vertices to a bone        exact
    none             neither signal -> NoSkeleton

Measured, that separates all five: Geno 75 Cluster-bound Models, MetaHuman 0. A `Null`-boned rig
still loads provided it is skinned; an unskinned one honestly reports `NoSkeleton`, because with
neither naming nor binding nothing in the file says which transforms are bones.

★★★ **AND flomo's CONTAINER HEURISTIC MISFIRED ON `Geno.fbx`.** Detecting the Mixamo container
as "no translation animation but has children" skipped **Hips itself** on a BIND-POSE export
(take = 0.017 s, so nothing translates): 74 joints where the identical skeleton in
`dance1_subject2.fbx` gave 75. One silently missing root bone. Replaced by "is this node a
joint?" — simpler, correct on an unanimated rig, and still steps over a Mixamo `Reference`
because that is a `Null`. Both counts are asserted now, from both files.

### ★★★ THE MIXAMO FILE DISPROVED "JUST PICK THE FIRST TAKE"

`Drop_Kick.fbx` (v7700, 2.1 MB, 65 `mixamorig:` joints, 2 skinned meshes, 129 Clusters)
declares two stacks:

    take[0] "Take 001"    3.333 s declared,   0 curve nodes   <- an empty placeholder
    take[1] "mixamo.com"  2.900 s declared,  53 curve nodes   <- the actual motion

★ **Both carry `LocalStop`, so DURATION CANNOT TELL THEM APART.** Only the curve count can.
Converting take 0 — which is what "just pick the first" means — produces a clip that loads,
reports a plausible 3.3 seconds, and never moves. Silent, and it would have looked like a
skinning or sampling bug rather than a take bug.

So `Take` now carries `curve_node_count`, and **`fbx.defaultTake` chooses by CONTENT: the first
take that actually has curves, falling back to the first.** `FromFbxOptions.take` became
`?usize` — `null` means that default, an index names a specific take. One scan, and a whole
class of silent failure disappears. Verified: the other four fixtures are unchanged.

Two more things this file settled:
- ★ **NO `Reference` CONTAINER.** Its root Model IS `mixamorig:Hips`, a LimbNode, sitting beside
  the two meshes. The container node flomo's heuristic was written for is not universal even in
  Mixamo output — a second, independent reason the rule is now "is this node a joint?".
- ★ **The closest approach yet to the 32-byte `BoneInfo.name` limit**: the synthesised end site
  `mixamorig:RightHandMiddle4_end` is 30 bytes, fitting with ONE byte spare before the NUL. The
  truncate-loudly path (§7 Phase 3) is still untested by real data, but only just — a slightly
  longer rig prefix would trigger it.

### Still not handled in the FBX reader, deliberately named

- **Big-endian FBX** — ufbx has `file_big_endian` throughout; vanishingly rare.
- **Optical marker data as such** — `subject2.fbx` is correctly refused as a skeleton, but its
  61 markers are real motion nobody reads. A marker-cloud viewer is a separate feature.
- **ASCII FBX** — reported as `AsciiUnsupported`; a different parser entirely.
- **Blend shapes / morph targets.** `metahuman.fbx` animates 47 curves of blend-shape weight and
  we read none of them. `NoSkeleton` is the right answer to "give me a skeleton", but the file
  is not static, and a MetaHuman viewer would need `Geometry/Shape` deltas plus the
  `BlendShapeChannel` weight curves. A separate feature, worth its own phase.
---

## 12. ★ THE GENOVIEW LOOK — a precise plan

Target: the orange figure with **self-shadowing and self-AO**, a checkered ground, and the
skeleton drawn as **capsules**. Reference is `GenoView-main/genoview.c` (903 lines — the plain
viewer, simpler than the IK fork) plus its six shaders, all studied.

### The reference pipeline, exactly

    1  SHADOW MAP   depth-only from the light      -> shadowMap
    2  G-BUFFER     colour+spec, normal+gloss, depth
    3  SSAO+SHADOW  one pass, packed R/G           -> ssaoFront
    4  BLUR x2      separable, depth+normal aware  -> ssaoBack -> ssaoFront
    5  LIGHTING     gbuffer + ssao + sun/sky/ground -> lighted
    6  FXAA                                        -> screen

★★★ **STEP 3 IS THE WHOLE TRICK, AND IT IS NOT WHAT THE NAME SUGGESTS.** AO and SHADOW are
computed in the SAME pass and packed into ONE texture — `finalColor.r = ssao`,
`finalColor.g = shadow`. Both are then softened by the SAME two blur passes. The shadow lookup
is a SINGLE stochastic tap (`shadowMap` sampled at `fragPosLightSpace.xy + shadowInvResolution *
seed.xy`, seed from a hash of the pixel), so the blur that de-noises the AO also turns one
jittered shadow sample into a soft shadow. **One pass and two blurs buy soft shadows AND soft
AO** — do not build PCF and SSAO separately.

`lighting.fs` then reads `ssaoData.g` as `sunShadow` and `ssaoData.r` as `ambientShadow`: the
sun term is multiplied by the first, the sky/ambient terms by the second. **That separation is
what makes it read as self-shadowing rather than a dark blob.**

### What zimr ALREADY has — reuse, do not rewrite

    step 1  `examples/shadowmap` + `lit_shadow_vs`/`lit_shadow_fs`   depth pass, RTT, bias tuning
    step 2  `examples/deferred_render` + `gbuffer_vs`/`gbuffer_fs`   MRT G-buffer
    step 4  `bloom_blur_fs` in `examples/pipeline_bloom`             separable blur, ping-pong RTT
    step 6  `examples/pipeline_postprocess`                          fullscreen post chain
    all     `bloom_fullscreen_vs`                                    the fullscreen triangle

So four of six stages are ports of existing zimr examples, not new work.

### ★ SHADERS ARE AUTHORED IN ZIG — what a new one actually costs

Not GLSL. Each shader is a PAIR under `src/shaders/`:

    <name>_io.zig      the typed schema — `Attributes`, `Ubo`, `Storage`, `Builtins`,
                       `Outputs`. ★ FIELD ORDER IS `@location(N)`.
    <name>.zig         `pub fn shaderMain(io_in: Io) Out`, written in Zig against `zm`,
                       ending in `comptime { _ = shader_externs.installSpirvEntry(shaderMain); }`
    <name>_common_io.zig   the interp struct shared by a vs/fs pair

`gbuffer_fs.zig` (51 lines) is the model to copy: three `Outputs` fields, three MRT
attachments. Porting a GLSL shader therefore means REWRITING it as Zig, not pasting it — and
the `_io` schema has to be designed first because it is what generates the bindings.

★★ **AND OUR G-BUFFER ALREADY STORES WORLD POSITION** (`g_world_pos` at location 0), which
GenoView does NOT — it reconstructs position from depth with `camInvProj`/`camInvViewProj`.
So our SSAO pass can read position directly and **drop four matrix uniforms and both
`LinearDepth`/`NonlinearDepth` helpers**. The port is genuinely simpler than the original, and
the simplification is forced by what zimr already chose to store.

### The new shaders, each with its schema sketched

- **`ssao_shadow_fs`** — reads `g_world_pos`, `g_world_normal` and the shadow map; writes ONE
  vec4 with `r = ao`, `g = shadow`. Ubo: light view-proj, light dir, shadow inv-resolution,
  camera view (AO works in view space), radius/bias/intensity/turns.
  SAO estimator: 9 spiral samples, 7 turns, radius 0.5, bias 0.025, intensity 0.15,
  `f = max(r*r - vv, 0); occ += f*f*f * max(vn / (0.001 + vv), 0)`, normalised by `r^6`.
  Shadow: ONE tap jittered by `shadowInvResolution * hash(uv)`.
- **`ssao_blur_fs`** — ★ NOT `bloom_blur_fs`. This one is BILATERAL: each of 7 taps (stride 2,
  one axis per pass) is weighted by `FastNegExp` of squared position difference (scaled 0.05)
  AND by normal similarity, so occlusion does not bleed across a silhouette. Needs
  `g_world_pos` + `g_world_normal` alongside the input texture — three samplers.
- **`lighting_fs`** — sun + sky + ground hemisphere with gamma in/out; `ssao.g` multiplies the
  SUN term, `ssao.r` multiplies the SKY/AMBIENT terms. Specularity 0.5, glossiness 10 from the
  G-buffer's packed `.a` channels.
- **`fxaa_fs`** — 47 lines of luma-edge FXAA; the smallest of the four.

### ★ BOTH CPU AND GPU SKINNING — and the GPU path is already possible

Correcting the earlier note that said "do not add GPU skinning": the engine has every piece.

    shader.StorageBuf(Mat, .read)   `fluid_discs_vs` ALREADY uses two in a VERTEX shader
    shader.Attr(.uvec4, N)          bone indices as u32x4
    wgpu.VertexFormat.uint8x4       the packed on-GPU format Mesh.boneIndices already is
    types.Mesh.boneMatrices         the palette pointer, already in the type

So `skinned_gbuffer_vs` is:

    Attributes { position .vec3, normal .vec3, uv .vec2,
                 bone_indices .uvec4 (loc 6), bone_weights .vec4 (loc 7) }
    Storage    { bone_matrices: shader.StorageBuf(Mat, .read) }
    body       skinned = Σ w[k] * (bone[idx[k]] · position)   — the SAME math as
               `draw3d.skinMeshCpu`, moved to the vertex stage

★ **KEEP BOTH, AND SAY WHY** — this is not indecision:

    CPU (`draw3d.skinMeshCpu`)   works today, no shader variant, runs on the SOFTWARE renderer,
                                 and is the only version you can step through in a debugger.
                                 Right for one character and for diagnosing a bind pose.
    GPU (`skinned_gbuffer_vs`)   no per-frame vertex upload, scales to many characters, and is
                                 what a shadow pass wants (the depth pass needs the SAME
                                 skinned positions — on the CPU path that is a second upload,
                                 on the GPU path it is the same storage buffer bound twice).

★★ **THE SHADOW PASS IS THE ARGUMENT FOR GPU SKINNING.** GenoView has BOTH `shadow.vs` and
`skinnedShadow.vs` for exactly this reason: a skinned character must be skinned again for the
light's depth pass. With CPU skinning that means uploading the deformed mesh once and drawing
it twice — workable. With GPU skinning both passes read one palette. **Phase 12a can ship on
the CPU path; 12h swaps it without touching the look**, which keeps the two arcs separate the
way §11 learned to.

### Reuse map — the four existing examples to copy from

    12a shadow map   `examples/shadowmap`          depth pass, RTT, `lit_shadow_*`, bias tuning
    12b G-buffer     `examples/deferred_render`    MRT, `gbuffer_*`, `loadRenderTexture`
    12d blur         `examples/pipeline_bloom`     ping-pong RTT, `bloom_fullscreen_vs`
    12f FXAA         `examples/pipeline_postprocess`  fullscreen post chain

`bloom_fullscreen_vs` is the fullscreen-triangle vertex shader every post pass reuses — none of
12c/12d/12e/12f needs a new vertex shader.

### ★ ADVERSARIAL REVIEW — what this plan gets wrong if nobody checks

**1. THE SOFTWARE RASTERIZER CANNOT RUN A DEFERRED PIPELINE.** `raster.zig:609` is explicit:
"raster supports a single color attachment + a single depth attachment per framebuffer (no MRT,
no stencil)." So the G-buffer path is GPU-ONLY, and `examples/shadowmap_sw`'s trick — the SAME
shader files on CPU, GPU and at comptime — does not extend to §12.

That is acceptable, but it must be a STATED choice rather than a discovery. Two consequences:
- **Shadow mapping alone stays portable** (single attachment), so 12a runs everywhere and is
  worth keeping separable from the rest.
- If a software-renderer version is ever wanted, the route is a NORMAL+DEPTH PREPASS into one
  attachment instead of MRT — two single-target passes rather than one multi-target pass. Do
  not discover this after building the deferred version.

**2. `FbxModel` IS AN AGGREGATE, AND THAT NEEDS DEFENDING** in a codebase that prefers flat
functions over frameworks. The flat alternative — `loadFbxMesh` / `loadFbxSkeleton` /
`loadFbxBindMatrices` as three independent calls — would parse the file three times AND, far
worse, would let a caller build the mesh against one joint numbering and the skeleton against
another. §11b's whole point is that this failure is undiagnosable from a screenshot. The
aggregate exists to make the wrong combination UNREPRESENTABLE, which is the one thing worth
bundling for. **It is plain data plus free functions — `loadFbxModel` / `unloadFbxModel` — with
no methods**, matching `unloadModel` / `unloadMesh` / `unloadBvhSkeletalClip`.

★ A method `FbxModel.deinit(gpa)` shipped briefly and was WRONG for this codebase: every other
release in `draw3d` is a free `unloadX(gpa, x)`. Fixed.

**3. SIX RENDER TARGETS IS A LOT FOR A PHONE.** shadow map + 3 G-buffer attachments + 2 SSAO
ping-pong + lighted. At 1080p that is roughly 40 MB of attachments before the mesh. The
reference runs on desktop. **Measure this on device at 12b, not at 12f** — the cheapest fix
(half-resolution SSAO, which is standard and nearly free visually) is easy to adopt early and
disruptive to retrofit.

**4. ★★ `drawModel` IS THE IMMEDIATE PATH AND MUST NOT BE USED FOR A MULTI-PASS CHARACTER.**
`appendModel` walks EVERY TRIANGLE on the CPU, transforming each vertex to world and appending
to `cube3d`'s batch. `geno_dance` draws ~68k triangles (18660 + 28272 + 20840). Drawing the same
model into a shadow pass AND a G-buffer pass would walk all of them TWICE PER FRAME on the CPU,
and six passes would be worse.

**The engine already has the retained path: `drawMeshInstanced`.** It uploads a mesh to a
VBO/IBO once, lazily, into the `MeshGpu` registry keyed by `Mesh.vaoId - 1`, and draws it with
a transform list. Upload once, draw N times — which is exactly what a multi-pass renderer needs.
**§12 uses `drawMeshInstanced` for the character and the ground; `drawModel` stays for the
one-pass examples it was written for.**

★★★ **AND THIS IS THE REAL ARGUMENT FOR GPU SKINNING, sharper than the shadow-pass one.**
With CPU skinning the vertices change every frame, so the retained VBO must be RE-UPLOADED each
frame: ~68k vertices of position data. With GPU skinning the VBO is static for the life of the
character and the only per-frame upload is the bone palette — **96 matrices instead of 68,000
vertices**. That is a three-orders-of-magnitude difference in per-frame bandwidth, and it grows
with mesh detail rather than with rig complexity. CPU skinning stays for the software renderer
and for debugging; GPU skinning is what the deferred path should ship on.

**5. NOTHING HERE USES THE ECS, AND IT SHOULD NOT YET.** `entities.zig` has `SlotMap`, arches
and chunks; a scene of many characters would belong there. Two characters in a fixed array is
the right size for the demo, and pretending otherwise would be the framework-building this
codebase avoids. ★ The natural boundary: when a character becomes a THING IN A SCENE rather
than a thing the example owns, it becomes components — mesh handle, clip handle, pose buffer —
not before.

### ★ THE PREDICTED END STATE — what "done" looks like

If §12 lands as planned, an app that wants the GenoView look writes roughly this, and nothing
else:

    // once
    const geno = try z.draw3d.loadFbxModel(gpa, fbx_bytes, .{});
    const rig  = try z.draw3d.uploadSkinnedMesh(gl, geno);      // 12h: static VBO + palette buffer

    // per frame
    z.draw3d.poseSkinMatrices(clip, geno.inverse_bind, k, positions, rotations, skin);
    z.draw3d.uploadBonePalette(gl, rig, skin);                  // 96 matrices, not 68k vertices
    z.render3d.drawShadowed(gl, &scene, .{ .ssao = true, .fxaa = true });

Three verbs at load, three per frame. **No object owns a render graph; no callback is
registered; nothing is subclassed.** The passes are a flat function that takes a scene list and
an options struct, the way `drawModel` takes a model and a tint.

★ The test for "did we build a framework by accident": can an example draw ONE unskinned cube
with the same shaded look, without constructing a character? If the answer needs a
`Renderer` object, the design went wrong.

### Phases, each independently verifiable

- **12a-1. Checkered ground + orange character — DONE.** Smoke PASS, `check` green, 0 lint.
  `genImageChecked(64, 64, 8, 8)` uploaded once, drawn as a large CUBE sunk to `y = -extent/2`
  so only its top face shows.

  ★ Why a sunken cube and not a plane: `drawCubeTexture` takes a single UNIFORM size, so a thin
  slab is not expressible — and a solid receiver is what 12a-2's shadow pass wants anyway,
  rather than a zero-height plane. The checker squares come from the IMAGE, not tiled UVs,
  because a cube face's UVs run 0..1.

  The character is tinted raylib ORANGE like GenoView. Keeping that now makes it obvious when
  §12e's lighting pass starts contributing colour of its own, instead of both changes landing
  together.

  Cost: 143.7 host calls/frame, up from 130.7 — the ground is one textured cube.

  ★★ **AND THE "STRANGE TEXTURE" ON GENO WAS FIXABLE.** Simon flagged dark banding down its
  limbs and assumed it could not be improved. Measured instead:

      Geno.fbx       52.6% of triangles have a vertex normal OPPOSING their winding
      Drop_Kick.fbx   0.0%

  Same loader, same code path. The winding is not the problem — recomputing normals from it
  gives a distribution matching Drop_Kick's almost exactly, while Geno's STORED normals differ
  by 24 points. The asset's normals are simply inconsistent (GenoView never sees this because
  it renders `Geno.bin`, re-exported from Maya, not the FBX).

  Fix: `draw3d.computeMeshNormals(mesh)` — area-weighted smooth normals from the winding — with
  `LoadFbxModelOptions.recompute_normals` opting in. ★ OPT-IN, NOT AUTOMATIC: averaging
  destroys the hard edges that authored normals exist to encode, so silently overwriting them
  would ruin any hard-surface model. Geno asks for it; Mixamo does not.

  ★ The test asserts "fewer than 10 opposed", not zero: a smooth normal is the area-weighted
  average of a vertex's faces, so a SLIVER triangle can still land on the wrong side of its own
  tiny face. Measured 1 of 18660. Demanding zero would be asserting that no mesh has slivers.

- **12a-2. RETAINED DRAW PATH — DONE, with an honest negative measurement.**
  `geno_dance` now draws its characters with `drawMeshInstanced` instead of `drawModel`.

  ★ **THE RETAINED PATH HAD NO DYNAMIC-VERTEX SUPPORT AT ALL, AND THAT WAS THE REAL BLOCKER.**
  `ensureMeshGpu` uploads once and caches by `mesh.vaoId`, so a CPU-skinned character drawn
  that way would have shown its BIND POSE FOREVER. `examples/dynamic_mesh` never hit this
  because it uses the IMMEDIATE path. Closed with `draw3d.refreshMeshGpu` +
  `wgpu_app.updateMeshGpu(gl, mesh)` — the VBO is already `copy_dst`, so a refresh is one
  `queueWriteBuffer`.

  ★★ **AND THE MEASUREMENT WENT THE WRONG WAY: 143.7 -> 158.9 host calls/frame.** Not a
  regression to explain away — the METRIC does not capture what changed. The immediate path
  walks ~68k triangles INSIDE WASM and flushes one big buffer write; the runner counts host
  calls, so all that CPU work is invisible to it, while the retained path's three
  `queueWriteBuffer`s are counted. **Host calls/frame is the wrong instrument for CPU-side
  batching work.**

  The retained path is still right, and the reason is arithmetic rather than measured: at ONE
  pass the two are comparable, but the immediate path repeats its 68k-triangle walk FOR EVERY
  PASS while the retained path uploads once and each extra pass is a draw call. The win
  appears at 12a-3, not here. ★ Recording the negative result rather than a claimed win —
  and noting that confirming it needs a wasm-side profile, not the smoke counter.

  NEEDS A DEVICE LOOK: `drawMeshInstanced` goes through `cube3d_instanced_vs` rather than the
  immediate batch's shader. The smoke says it draws; whether it SHADES identically is a
  question only eyes answer.

- **12a-3. THE LIGHT'S-EYE PASS — DONE.** The scene is now rendered a SECOND time from an
  orthographic camera placed along `-light_dir`, into a 1024x1024 render texture, and shown
  small in the top-right corner behind a `light view` toggle.

  ★ **DELIBERATELY ONLY STEP ONE.** It encodes no depth and casts no shadow. It exists so the
  LIGHT CAMERA can be checked ON ITS OWN — a frustum that misses the characters is obvious as a
  picture and invisible once buried under a depth encoding and a projection lookup. This is
  §12's "verify each stage by displaying its output" applied to the first stage.

  `drawScene` was factored out so the camera pass and the light pass draw the IDENTICAL scene —
  a shadow map that renders a different scene than it shades is the classic source of shadows
  that do not line up.

  ★★★ **AND THE QUEUE-TIMELINE VALIDATOR CAUGHT A REAL HAZARD IMMEDIATELY**:

      ✗ FAIL geno_dance  queue-timeline clobber: buffer 221 (label='mesh_vbo') offset 0
        written 2+ times in frame 0 (180 total violations) — only the LAST write reaches the
        whole frame.

  `updateMeshGpu` was inside `drawScene`, so adding a second pass made it write each character's
  VBO twice per frame. **`queueWriteBuffer` is not ordered against draws within a frame** — only
  the last write reaches the whole frame. Here both writes held identical data, so NOTHING
  WOULD HAVE LOOKED WRONG; it would have become a real bug the moment two passes wanted
  different vertex data. Fixed by hoisting the upload into the once-per-frame pose step, which
  is where it belonged anyway.

  ★ Note the pattern: this is the third time a smoke-harness validator has found something the
  render could not show. Cost: 158.9 -> 223.0 host calls/frame for the extra pass.

  ★★ **AND THE INSET DID NOT APPEAR ON DEVICE**, with the toggle on and the smoke passing. It
  was anchored to the CONFIGURED `screen_w` (1000) rather than the live viewport, so on a phone
  it sat off the right edge — a draw outside the viewport is indistinguishable from one that
  never happened. Now positioned from `f.window.widthf()` / `heightf()` and sized as a fraction
  of `@min(w, h)`, bottom-right. Recorded in claude.md: the configured window size is a
  REQUEST, not the viewport.

  ★★★ **THEN THE INSET RENDERED FLAT GREY — because `beginMode3D` IGNORES
  `Camera3D.projection`.** It builds `perspectiveFovRh` unconditionally, so the orthographic
  light camera became a PERSPECTIVE one reading `fovy_deg = 4.0` as 4 DEGREES: a telephoto lens
  seeing about half a checker square. No assert, no validator hit, smoke green — it just looked
  like the pass had not run.

  ★★★ **FIXED AT THE SOURCE RATHER THAN WORKED AROUND.** `Camera3D.projMatrix` and
  `getScreenToWorldRayWithViewport` already honoured `projection` — only `beginMode3D` did not,
  which made it an INCONSISTENCY rather than a missing feature, and made the fix safe (nothing
  in the tree passed an ortho camera to it). `beginMode3D` now calls `cam.projMatrix`.

  The example was then SIMPLIFIED back to a plain `Camera3D` + `beginMode3D`, which is the real
  verification: the simple form only works if the fix is right. `orthographic_projection` still
  smokes green, and a `zimrmath` test pins the matrix shape and that ortho `fovy_deg` is a
  world HEIGHT, not an angle.

  ★ Two device rounds went to this one inset, both from the same class of fault — an API
  accepting a value it silently ignores. Preferring to FIX that over documenting it is now a
  standing note in claude.md.

- **12a-4. THE OCCLUSION MASK, AND THE BLOCKER THAT HAD TO GO FIRST — DONE.**
  Smoke PASS, `check` green, 218 calls/frame.

  ★★★ **THE RETAINED VBOs WERE UNREACHABLE FROM A CUSTOM PASS.** `mesh_gpu` is private to
  `Cube3D` and `drawMeshInstanced` was the only way in, so a shadow or G-buffer pass wanting
  its OWN pipeline had no route to the vertices it had just uploaded — it would have needed a
  second copy, which is precisely the cost the retained path exists to avoid. Found by asking
  "can the next pass reach these buffers?" BEFORE writing the pass, rather than after.

  Fixed with `z.meshGpuBuffers(gl, mesh) ?MeshGpu` (vbo, ibo, index_count). The vertex layout
  is documented at the accessor: 3 floats position + 3 floats normal, 24-byte stride, which
  matches `gbuffer_vs`'s `Attr(.vec3, 0)` + `Attr(.vec3, 1)` — so a custom pipeline can consume
  it with no repacking. **§12b's G-buffer pass now has a route to the geometry.**

  The light pass now renders an OCCLUSION MASK: clear to black, casters only, flat white.
  ★ A mask gives HARD ground shadows with NO depth comparison and therefore NO BIAS TO TUNE —
  it is the cheapest thing that produces a real shadow, and it is judgeable on its own as a
  silhouette. Depth encoding (§12a-5) is what buys SELF-shadowing; this buys the ground shadow,
  which is the visually dominant half.

  `drawCasters` was split out of `drawScene` so the camera pass and the light pass share ONE
  definition of what casts — making "the shadow map rendered a different scene than it shades"
  impossible rather than merely unlikely.

- **12a-5. PREREQUISITES CLEARED — the shadow lookup can now be written.**

  ★ **THE ENGINE'S WGSL IS NOT AVAILABLE TO EXAMPLES BY DEFAULT.** `wireEngineWgsl(ctx, mod)`
  is called PER-EXAMPLE from a `configure` hook (`configureHelmetSw` and friends), not
  generically — so `@embedFile("depth_vs.wgsl")` in a fresh example fails to resolve. Added
  `configureGenoDance` and registered it. **Verified by probe**: an `@embedFile` of
  `depth_vs.wgsl` now resolves (it failed before, and the only remaining complaint was the
  lint's "unused global", which is the probe succeeding).

  So `geno_dance` can now build its own pipelines from `depth_vs/fs` and `lit_shadow_vs/fs`
  rather than duplicating those shaders — and combined with `z.meshGpuBuffers` from 12a-4, a
  custom pass has both the SHADERS and the GEOMETRY it needs.

  ★★ **LIGHT FRUSTUM TIGHTENED, 4.0 -> 1.6.** The mask made the waste visible: two characters
  occupying a small fraction of a 1024x1024 target with the rest empty black. They stand at
  x = +/-0.7 and reach ~1.8 tall, so 1.6 wraps them with room for a kick — **roughly six times
  the texels on the silhouettes that matter**, for free. The cost is that anything outside the
  box casts nothing; that is the standard directional trade, and the standard fix is to follow
  the subject rather than to widen.

  ★ Worth noting the ordering that made this cheap: the mask was built and LOOKED AT before the
  lookup existed. Resolution waste is obvious in a silhouette and invisible in a finished
  shadow.

- **12a-6. THE SHADOW LOOKUP — DONE.** The ground is now a `genMeshPlane` drawn through a
  hand-built pipeline pairing `lit_shadow_vs/fs`, sampling the light pass. Smoke PASS with no
  bind-group violations and no leaks, `check` green, 226 calls/frame.

  What it took, so the next custom pass is quicker: three bind-group layouts (VS uniforms at
  group 0, samplers at 1, FS uniforms at 2 — the engine's stage-segregated scheme), a pipeline
  layout, two shader modules, two UBOs rewritten per frame, a sampler bind group pointing at
  the render texture, and a vertex layout of pos+normal at 24-byte stride — **the same layout
  `Cube3D`'s `MeshVertex` uses**, so the characters can join this pass unchanged in 12a-7.

  ★ **THE LIGHT PASS NOW ALWAYS RUNS.** It used to be gated on the debug toggle; the ground
  samples it every frame, so the toggle was demoted to controlling only whether the result is
  DISPLAYED. A debug view and a dependency are different things.

  ★ **ONE light camera, computed once**, feeding both the light pass and the ground's lookup.
  Deriving it twice is how a shadow ends up projected from a slightly different place than it
  was rendered from — a class of bug that looks like bad bias.

  ★★ **`bindForPass` AFTER THE FOREIGN PIPELINE.** Binding a custom pipeline into the screen
  pass leaves the 2D renderer's state wrong, and §11's bind-group fix is what makes the restore
  correct: WebGPU drops bind groups on an incompatible layout change while the tracker does
  not. That fix was made for a bug found by the validator months of work ago; this is the first
  place it was needed deliberately.

  ★ **THE LEAK CHECKER EARNED ITS KEEP IMMEDIATELY**: `buffer+4 bind_group+3
  bind_group_layout+3 pipeline_layout+1 render_pipeline+1`. Bind-group LAYOUTS and pipeline
  layouts are counted too, not just buffers — easy to forget because they feel like
  descriptions rather than objects.

  ★★★ **THE MASK WAS THE WRONG INPUT, AND THE DEVICE SHOWED IT INVERTED.** A dark square with
  a BRIGHT figure in it. `lit_shadow_fs` does a DEPTH COMPARISON — it reads the map as
  distance-from-light and shadows a fragment whose own distance is greater. Feeding it
  white-on-black meant the empty map (0.0 = "very near") shadowed the entire frustum footprint
  while the silhouettes (1.0 = "very far") came out lit. **Exactly backwards, and exactly what
  the arithmetic predicts** — the mask shortcut was never compatible with a depth-comparing
  receiver.

  Fixed with a second custom pipeline running `depth_vs/fs` in `mode = 0`, which writes
  `ndc_z*0.5+0.5` — precisely the quantity `lit_shadow_fs` expects. ★ **The two shaders are a
  MATCHED PAIR; substituting for either half is what went wrong.**

  ★★ **AND THE CLEAR COLOUR IS WHITE, NOT BLACK** — "nothing here, infinitely far". Clearing
  to black would make every untouched texel read as depth 0, nearer than anything, and shadow
  the whole frustum. Same inversion, different cause; worth stating because black is the
  instinctive choice for an empty buffer.

  ★ `meshGpuBuffers` (§12a-4) is now USED as intended: the depth pass draws the SAME VBOs the
  camera pass draws, so one upload per frame feeds both. The depth pass is position-only, so
  the frame got CHEAPER: 226 -> 209.8 host calls.

  **LIGHT BOX NOW FOLLOWS THE CASTERS.** 1.6 spent resolution well but clipped the dance —
  `dance1` travels, so a box centred on the origin loses the character as it steps away, seen
  as a shadow that simply stops. `lightTarget` re-centres on the characters' root midpoint each
  frame at 2.6 half-width. ★ Following keeps texel density; widening throws it away.

  TRADE MADE: the checkerboard is gone, because `lit_shadow_fs` shades a flat `base_color`.
  It returns in §12e, where the albedo comes from the G-buffer rather than a shader constant.

- **12a-7. SELF-SHADOWING — DONE, and it was almost free.**

  ★ **SELF-SHADOWING IS NOT A SEPARATE FEATURE.** The depth map already contained the
  characters — they are the casters — and `lit_shadow_fs` shadows any fragment whose light-space
  depth exceeds the map's. Drawing the characters with the RECEIVING shader is the whole of it:
  an arm now darkens the chest behind it because the arm is nearer the light. No new pass, no
  new shader, one more pipeline binding.

  The characters left the engine's batch entirely (no more `drawMeshInstanced`), which exposed
  a gap: **the engine's mesh upload is lazy and only `drawMeshInstanced` triggers it**, so a
  mesh drawn ONLY by custom pipelines would never get buffers and would silently not render.
  Closed with `z.uploadMeshGpu(gl, mesh)`.

  ★★★ **AND IT SHIPPED BLACK.** `uploadMeshGpu` was called from `initState`, but `cube3d` is
  created LAZILY on the first `beginMode3D` — so at init it was still null, the guard took the
  null branch, nothing uploaded, and both passes drew nothing. Black screen, pure-white shadow
  map, **smoke PASSING**.

  `uploadDecalReceiver` already guarded for exactly this and documents why; the new entry point
  was written without the guard. ★ The lesson is in claude.md: any `wgpu_app` function touching
  `cube3d` that could be called from init must construct it first.

  ★★ **THE SMOKE CANNOT SEE THIS CLASS OF BUG.** Drawing nothing is a valid frame — no
  validation error, no clobber, no leak. The signal that DOES exist is the host-call count:
  4250 -> 4485 at init once the uploads actually happened. Worth reading call counts as
  evidence, not just as cost.

  Also reverted in the same fix: the 3D block had been made conditional on `show_skeleton`.
  `beginMode3D` is what puts the pass into the depth-tested state the custom pipelines rely on,
  so gating it would make the shadowed geometry depend on whether a debug gizmo is enabled.

  ★★★ **THEN THE SELF-SHADOW CAME OUT AS HUGE SMOOTH BANDS** across the body and head, in
  places with nothing above them. Two causes, both in HOW THE SHADOW MAP WAS CREATED rather
  than in the shadowing:

  1. ★★ **`loadRenderTexture` GIVES rgba8 — 256 DEPTH LEVELS.** The bias defaults in
     `lit_shadow_fs_io` are tuned for an f16 map and are roughly EIGHT TIMES too small against
     an 8-bit one, which is exactly the "smooth bands of false shadow" signature. Fixed by
     building the target with `RenderTexture.create(.{ .format = .rgba16_float, .with_depth =
     true })`, as `examples/shadowmap` does.
  2. ★ **`loadRenderTexture`'s SAMPLER IS LINEAR.** Filtering blends depths ACROSS SILHOUETTE
     EDGES, and a blended depth is a distance to nothing — the comparison against it is
     meaningless. A NEAREST sampler with `clamp_to_edge` replaces it.

  ★★★ **`shadowmap` HAD A COMMENT PREDICTING BOTH**, at the line creating its render texture:
  "a float colour target stores the light-view depth at ~16-bit precision (vs 256 levels for
  rgba8), which is what lets the shadow bias drop low enough to avoid both acne and
  peter-panning. Sampled with a NEAREST sampler below — linear filtering would blend depths
  across silhouette edges and corrupt the comparison."

  I had read that file for its pipeline structure and copied the pipeline, but reached for the
  CONVENIENCE constructor for the target. ★ The lesson: when porting from a reference, the
  RESOURCE SETUP carries as much hard-won detail as the draw code, and a convenience wrapper is
  precisely where a specialised requirement gets silently dropped.

  Bias is now two SLIDERS rather than constants: self-shadow acne on a curved character is far
  pickier than a flat floor, and the right value depends on map precision and light angle.

  ★★ **SHARING WITH `examples/shadowmap`, ANSWERED BY COUNTING**: `uniformLayout` and
  `uniformBindGroup` were byte-identical in **TWELVE** examples — shadowmap, deferred_render,
  cel_shading, fog_rendering, mesh_picking, hybrid_render, cubicmap, box_collisions,
  depth_writing, first_person_maze, shadowmap_sw, geno_dance. Not example scaffolding: it is
  what EVERY hand-built pipeline needs before it can bind anything. Now
  `z.gpu.uniformBindGroupLayout` / `z.gpu.uniformBindGroup`, with `geno_dance` migrated. The
  other eleven are a mechanical follow-up.

  ALSO DUPLICATED, not yet fixed: `DepthUbo`/`LitVsUbo`/`LitFsUbo` are hand-copied mirrors of
  `depth_vs_io.Ubo` / `lit_shadow_*_io.Ubo` in 2-3 examples each. ★ The real fix is not a
  shared copy but WIRING THE ENGINE SHADERS' `_io` MODULES to examples the way their `.wgsl`
  already is — then the schema has one definition and a drift is a compile error rather than
  garbage transforms. Needs a build.zig change alongside `wireEngineWgsl`.

- **12a-9. NORMALS WERE NEVER SKINNED — found while adding the light sliders.**

  ★★★ **`skinMeshCpu` WROTE POSITIONS ONLY.** The mesh deformed every frame while its NORMALS
  stayed in the BIND POSE, so the lighting was fixed to the rest pose on a moving body. That is
  precisely the "looks wrong in some places, fine in others" symptom Simon reported and
  attributed to Geno's normal data — the data was fine; the pipeline never rotated it.

  Invisible on a static mesh, invisible in any bind-pose test, and invisible in the bounding-box
  and centroid tests, which are about POSITIONS.

  ★ Normals are skinned with `vec` — a DIRECTION, lane 3 = 0 — so the skin matrix's translation
  is excluded. **The same `vec`/`pointVec` distinction that cost days on positions, now used
  deliberately in the opposite direction**: a position needs the translation, a normal must not
  have it. The rotation-only inverse-transpose is skipped on purpose: these skin matrices carry
  no scale or shear, and for those the matrix is its own correct normal transform.

  Cost: 234 -> 258 host calls/frame (a second buffer upload per mesh).

- **12a-11. MAKING THE NORMALS MISTAKE HARDER — three fixes, ranked by how much they help.**

  1. ★★ **THE SIGNATURE.** `skinMeshCpu` now requires `base_normals` and `out_normals`. With
     normals absent from the parameter list the omission was UNREPRESENTABLE by a caller and
     lived inside the function where nobody could see it. Six arguments is the right price.
  2. ★ **AN EXACT INVARIANT TEST**: for a vertex bound entirely to one bone, the skinned normal
     must equal that bone's skin rotation applied to the rest normal. Plus two guards on the
     guard — assert that >100 single-bone vertices were actually checked (otherwise the loop
     asserts nothing and passes) and that the pose actually moved the mesh.
  3. A comment. Written, but worth little alone: it does not fire.

  ★★★ **THE TEST WAS VERIFIED TO FAIL.** The bug was reintroduced deliberately, the test caught
  it, and only then was it known to be a guard. An invariant nobody has watched fail is a hope.

  ★ Checked whether this was systemic: `Mesh.animVertices`/`animNormals` exist in the type for
  raylib parity but nothing writes them, so `skinMeshCpu` is the only CPU skinning path in the
  engine. Not systemic.

  ★ And what did NOT catch it: bounding boxes, vertex centroids, the foreign-clip test — every
  one about POSITIONS. A bind-pose test is the identity for normals too, so it passes either
  way. **When adding a geometry test, ask which channels it exercises.**

- **12a-10. LIGHT YAW/PITCH SLIDERS.** ★ A fixed light HIDES normal errors: a facet with a bad
  normal just looks like a slightly odd shade and nothing contradicts it. SWEEPING the light
  makes it obvious — correct normals shade smoothly and continuously, while a bad patch pops,
  stays flat, or lights in the wrong direction. Cheapest normal debugger available, and unlike
  a normals-as-colour view it needs no new shader. Defaults reproduce the previous fixed
  direction.

- **12a-8. Migrate the other eleven examples to `z.gpu.uniformBindGroup*`; wire engine `_io`.**

  ★ **THE RECEIVER MUST BECOME A CUSTOM-PIPELINE MESH, AND THAT IS THE WHOLE COST OF THIS
  STEP.** The ground is drawn with `drawCubeTexture` (immediate batch), and the retained path
  cannot replace it directly: `drawMeshInstanced` binds ONE fixed pipeline
  (`cube3d_instanced_vs` + `cube3d_fs`) with no texture support, so switching would silently
  drop the checkerboard.

  So 12a-6 is: build the ground as a `genMeshPlane`, upload it, and draw it through a
  hand-built pipeline pairing `lit_shadow_vs/fs` — which needs shader modules, bind-group
  layouts, a pipeline layout, two UBOs and a sampler. `examples/shadowmap` is 774 lines largely
  because of exactly this scaffolding. Both prerequisites are now in place (§12a-4's
  `meshGpuBuffers`, §12a-5's WGSL wiring); this is a full session's work and should not be
  started at the tail of one. Port `examples/shadowmap`'s depth pass; put the character
  and a checkered ground under it. Verifiable on device: does the figure cast onto the ground?
  ★ This phase is single-attachment and therefore STILL PORTABLE to the software renderer —
  keep it that way, so there is a fallback look if the deferred path proves too heavy on
  mobile.
- **12b-0. `ssao_fs` AUTHORED — the shader exists; wiring is next. GATE IS RED, SEE BELOW.**

  ★ **SHADERS ARE AUTO-DISCOVERED**: any `_vs.zig`/`_fs.zig` dropped under `src/shaders/` is
  compiled through the SPIR-V pipeline and exposed as an `@embedFile`-able `<name>.wgsl`. No
  build.zig entry needed for the shader itself.

  Written: `ssao_fs_io.zig` (schema), `ssao_common_io.zig` (the one varying), `ssao_fs.zig`
  (Scalable Ambient Obscurance). It reuses `deferred_shading_vs` as its vertex stage — same
  fullscreen quad, same UV flip — rather than shipping a second copy.

  ★★ **SIMPLER THAN THE REFERENCE, BECAUSE OF WHAT OUR G-BUFFER STORES.** GenoView's `ssao.fs`
  reconstructs each sample's position from DEPTH, costing it an inverse projection, an inverse
  view-projection and two linearisation helpers. `gbuffer_fs` already writes WORLD POSITION, so
  all of that disappears: this shader reads positions directly and needs only the view matrix.

  ★★★ **TWO HARD CONSTRAINTS THE LINTER TAUGHT, both worth knowing before writing any shader
  that loops:**
  1. `[sampler-in-branch]` — WGSL rejects an IMPLICIT-LOD sample (`textureSample`) reached
     through non-uniform control flow; Tint errors with "must only be called from uniform
     control flow", and **neither naga nor nagac catches it, so it only shows at runtime**.
     zimrlint catches it at build time. The fix is `sampleLevel` (`<name>Level(uv, lod)`,
     lowering to `textureSampleLevel`), which is derivative-free and therefore legal in a loop.
     SSAO cannot be written any other way.
  2. Branches around samples must become ARITHMETIC. The sky early-out and the uncovered-
     neighbour `continue` are now coverage MULTIPLIERS, keeping the shader branch-free.

  Also: `io_in.u.<field>` accesses the UBO (not `.ubo`), `zm.dot` returns a SCALAR here, and
  `_io` files import `zm` for `Vec` rather than taking it from `shader_interface`.

  ★★★ **RUN DOWN: THE TRANSPILER WAS MISSING `OpFMod`. FIXED — 164 ok, 0 failed, check GREEN.**

  ★ **AND MY EARLIER "VERIFIED NOT CAUSED BY THIS SHADER" WAS WRONG.** I removed the three
  ssao source files, saw the same 5 failures, and concluded they were pre-existing. The
  verification was INVALID: the corpus scans compiled `.spv` in the BUILD CACHE, and deleting
  the sources does not delete the cached output. All 5 traced to this turn — 3 to the shader,
  2 to zero-byte `.spv` left by its failed intermediate compiles. **When a check reads from a
  cache, removing the source is not a control.**

  Diagnosis, once the failures were attributed properly:

      err :1233: let _4977: f32 = f32();  // UNHANDLED spv opcode 141
      err :1235: let _4987: f32 = f32();  // UNHANDLED spv opcode 141

  Opcode 141 is **`OpFMod`**, and `ssao_fs` calls `@mod` exactly twice — matching `err=2`.
  `FRem`(140), `SRem`, `SMod` and `UMod` were all handled; the enum simply stopped at 140.

  ★★ **NOT A COMPILER REGRESSION.** The hypothesis was that the Zig bump changed SPIR-V output.
  It did not: 161 other shaders translate fine. **`OpFMod` had never been implemented because
  no shader in the tree had ever called `@mod`** — the gap sat invisible behind a corpus that
  could not reach it.

  ★★ **AND `%` WOULD HAVE BEEN THE WRONG FIX.** WGSL's float `%` is TRUNC-based, which is
  `OpFRem`. `OpFMod` is FLOOR-based and takes the sign of the DIVISOR: `@mod(-1.0, 6.28)` must
  be ~5.28, and an angle wrap depends on it. Lowered as `a - b * floor(a / b)`. The old
  fallback emitted `f32()` — literal ZERO — with only a comment in the output.

  ★★★ **AND THE CORPUS ITSELF WAS FIXED — "should it consider cached spv whose source is
  gone?"** `listOurCorpus` walks `.zig-cache/o/<hash>/` blindly; it has no idea which sources
  exist. Three consequences, all of which bit this session:

    1. A deleted or renamed shader keeps being checked until the cache is cleared.
    2. Every revision of a shader under development accumulates — iterating on ONE shader left
       THREE cached entries, all failing, reading as three independent problems.
    3. ★ Deleting a source is NOT a control experiment. That is what produced the wrong
       "pre-existing" conclusion.

  **FIXED (verified):** `statFile` now requires size > 0, so the zero-byte `.spv` a FAILED
  compile leaves behind is skipped instead of being scored TRANS-FAIL — build detritus was
  being reported as a translator bug. Verified by planting an empty `.spv` and confirming the
  gate stays green.

  **FIXED (verified):** every failure row now prints `shader: <name>`, recovered from the
  SPIR-V debug strings. A content hash is unactionable, and the missing attribution is what
  made the wrong conclusion easy. Verified on a deliberately corrupted module: it reports
  `shader: ssao_fs` alongside the error.

  **DOCUMENTED, NOT FIXED:** excluding stale entries whose source is gone needs a
  build-supplied manifest of live `.spv` paths — a larger change, and the current breadth is
  partly deliberate (it reaches shaders no example draws). The trap is written at
  `listOurCorpus` so the next reader is not caught by it.

  ★ The shader now serves as permanent corpus coverage for the opcode: it lives in
  `src/shaders/`, so every `check` run translates and validates it. A probe under
  `src/shaders/probes/` would NOT have worked — discovery skips that directory.

- **12b. G-BUFFER — DONE.** Three attachments (world position, world normal, albedo) filled by
  ONE geometry walk via `beginTextureModeMrtRaw`. Smoke PASS first try, no bind-group or leak
  violations, `check` green. 258 -> 341 host calls/frame for the extra pass.

  ★ **POSITION AND NORMAL ARE rgba16-FLOAT.** SSAO measures DISTANCES between sampled
  positions; at 8 bits per channel those quantise into terraces and the occlusion estimator
  reads the steps as geometry. Albedo stays rgba8 — colour genuinely needs only 8 bits. This
  is the same precision lesson the shadow map taught, applied before it could bite twice.

  ★ **CLEARED TO ZERO ALPHA**, because `ssao_fs` reads alpha as its COVERAGE flag: a pixel the
  geometry never touched has a meaningless position, and treating it as a real surface would
  let the background occlude the scene.

  ★ **SIZED TO A FIXED 1024 SQUARE, NOT THE WINDOW.** A G-buffer normally matches the
  backbuffer, which means rebuilding on every resize — and half-resolution SSAO is the standard
  trade anyway (adversarial point 3 flagged attachment memory on mobile). Matching the window
  is a refinement for after the AO is known to be correct.

  ★★ **AND THE INSET NOW SELECTS WHICH TARGET IT SHOWS** — shadow map, position, normal, or
  albedo. That is §12's method made concrete: a six-pass pipeline where only the final image is
  visible is one where any single stage can be silently wrong, and this session already lost
  rounds to an inverted shadow and a flat-grey light view that were only diagnosable BECAUSE
  their stage could be looked at alone.

  `pos_normal` at 24-byte stride paid off exactly as intended: the G-buffer pipeline consumes
  the SAME VBOs the shadow and lit passes do, with no repacking.

- **12b-1. PASS ORDERING — the G-buffer pass had drifted BELOW `clearViewport`.**
  Every RTT pass now runs before the screen pass opens; the camera update was hoisted above
  them since it depends only on the UI context.

  ★ Found by reading the ordering, not by reproducing: the comment said "── THE G-BUFFER
  PREPASS ── before the screen pass opens" and sat directly UNDER `clearViewport`. It was true
  when written and the call drifted later. **A comment asserting an ordering the code does not
  enforce is worse than none.**

  ★ HONEST: this is a real correctness fix — an offscreen pass opened over a live screen pass
  forces a mid-frame 2D flush and a reopen — but I could NOT confirm it is the cause of the
  duplicated UI panel. The host-call count is unchanged (341.1), and `reopen2DPass` does
  restore the correct screen ortho, so the projection theory does not hold up. If the duplicate
  survives this fix, the next suspects are the ghost/no-clear path Simon raised (an explicit
  background or skybox draw) and the UI host's own render being reached twice.

- **12c. SSAO PASS WIRED — DONE. Displayed raw; NOT yet composited.**
  Smoke PASS, no bind-group violations, no leaks, `check` green. 341 -> 405 host calls/frame.

  ★ **DISPLAYED BEFORE COMPOSITED, DELIBERATELY.** The inset gains an `ao` view and the
  default selection is now that view. §12 says a broken AO term is obvious as a greyscale image
  and invisible once multiplied into a lit colour — and this session has already spent rounds
  on an inverted shadow that was only findable because its stage could be looked at alone.
  Radius, bias and power are live sliders next to it.

  ★ **rgba8 IS ENOUGH FOR AO, unlike the G-buffer.** AO is a 0..1 coverage number multiplied
  into a colour; 256 levels beats what the eye resolves in shading. The G-buffer needed f16
  because it stores POSITIONS, and the estimator works on DIFFERENCES between them. Same
  question, opposite answer, for a reason worth keeping straight.

  ★ **NEAREST sampler on both G-buffer inputs.** A filtered world position is a point on no
  surface and the occlusion test against it is meaningless — the same fault that made the
  shadows band two phases ago.

  ★ The AO target carries a DEPTH attachment it never tests: a pipeline's state combo must name
  a depth format and it has to match the pass's attachments. `deferred_render`'s shading pass
  does the same, with the note that the quad at z=0 against a cleared depth of 1.0 always
  passes.

  The vertex stage is `deferred_shading_vs`, reused — same fullscreen quad, same UV flip.

- **12d-1. AO COMPOSITED — and it needed NO new shader.**
  Smoke PASS, all GPU handles balanced, `check` green, 169 corpus ok. 405 -> 424 calls/frame.

  ★ AO is a 0..1 factor and the composite is `lit *= ao`, which is exactly what a
  MULTIPLY-blended fullscreen quad does. The engine's 2D pipeline already carries a `.multiply`
  variant (`beginBlendMode(gl, .multiply)`), so the whole composite is ONE textured draw
  between the lit geometry and the UI. Toggle: `ao`.

  ★ **ORDER: after the 3D, BEFORE the UI.** The UI is not part of the scene and must not be
  multiplied by an occlusion factor computed from scene geometry.

  ★★ **THIS IS DELIBERATELY CRUDER THAN GENOVIEW**, and §12e is where it stops being so.
  GenoView feeds AO into its LIGHTING shader, separating `ssaoData.r` (ambient) from `.g`
  (sun): AO darkens the SKY term while direct sunlight stays clean. A flat multiply darkens
  everything, including fully lit surfaces, which reads heavy. Doing the cheap version first
  makes the AO visible in the render NOW and leaves the correct version to the phase that adds
  a lighting pass to put it in.

  ★★★ **AND IT WAS NOT AO AT ALL — TWO BUGS, BOTH IN THE SHADER'S INPUTS.**

  1. ★★ **THE NORMAL DECODE UNDID AN ENCODING THAT WAS NEVER APPLIED.** `ssao_fs` read
     `nrm_texel * 2 - 1`, the standard unpack for a normal stored unsigned in rgba8. But
     `gbuffer_fs` writes the RAW world normal — `.{ n[0], n[1], n[2], 1.0 }` — into an
     **rgba16-FLOAT** target, which stores negatives directly. So (0,1,0) was read as
     (-1,1,-1): every surface faced a direction it does not, and the `vn` occlusion term was
     noise. **Reading the target's FORMAT before writing the decode would have settled it in
     one look** — the unsigned encoding is what an rgba8 normal target WOULD need.

  2. ★★ **THE PER-PIXEL HASH DIED AT SCALE, giving HORIZONTAL STREAKS.** It computed
     `fract(px * py + px * 0.5)`; at 1024x1024 `px * py` reaches ~1e6, where consecutive f32
     values are ~0.06 apart. Taking `mod 1.0` of something that coarse yields a handful of
     distinct angles instead of a spread, so whole regions share one spiral start. Fixed by
     FOLDING the pixel coords into a 64-pixel tile first — where f32 still has ~7e-6 spacing —
     and using R2 low-discrepancy constants. A repeating 64-pixel pattern vanishes under the
     blur; a quantised one does not.

  ★ Both are input-handling bugs rather than estimator bugs, and both are the same shape as
  earlier faults this arc: an assumption about what another stage produces, never checked
  against that stage. The G-buffer's own source line was three greps away.

  STILL RAW — the 9-sample spiral is jittered per pixel and expects the bilateral blur (12d-2)
  to clean it up. Expect visible noise.

- **12d-2. BILATERAL BLUR — DONE.** Two 7-tap passes, ping-ponging `ssao_rt` -> `ssao_blur_rt`
  -> `ssao_rt`. Smoke PASS, handles balanced, `check` green, 171 corpus ok. 424 -> 480
  calls/frame.

  ★ **NOT `bloom_blur_fs`, and the difference matters.** A bloom blur averages by distance
  alone, which BLEEDS AO ACROSS SILHOUETTES: a dark crease behind a character smears onto it,
  and the ground picks up shading from the figure standing on it. This one weights each tap by
  world-POSITION proximity AND NORMAL alignment, so samples from a different surface contribute
  almost nothing — which is why it needs the G-buffer alongside the AO texture.

  ★ **THE TWO WEIGHTS REJECT DIFFERENT THINGS.** Position rejects a neighbour that is far in
  world space but adjacent on screen (ground behind a character). Normal rejects one that is
  close in space but faces elsewhere (the two sides of a sharp crease). Either alone leaves a
  visible class of bleed; both are exposed as sliders.

  ★ **PING-PONG BACK INTO `ssao_rt`**, so the composite and the debug inset keep reading ONE
  texture whether blurring is on or off. A `blur` toggle switches it without anything
  downstream knowing.

  ★ Separable: 2x7 taps buy the reach of a 49-tap square for 14 samples. Bilateral weights are
  not strictly separable in theory; the error is invisible against the noise this removes.

  Zig-shader notes for the next one: an ANONYMOUS literal does not coerce into a generic
  parameter — `normalize(.{x, y, z, 0})` fails where a named `const v: Vec = .{...}` works.
  Everything else carried over from `ssao_fs`: `sampleLevel` in loops, `inline for`, coverage
  as a multiplier rather than a branch.

- **12e. Lighting pass: fold AO into the SKY term rather than a flat multiply; checker back.** Port `examples/deferred_render`. Verify by displaying each attachment.
  ★ MEASURE ATTACHMENT MEMORY AND FRAME TIME ON DEVICE HERE, while the pipeline is still two
  passes — see adversarial point 3. Half-resolution SSAO is cheap to adopt now, expensive later.
- **12c. `ssao_shadow_fs`.** Display R and G channels raw before wiring lighting — a broken AO
  term is obvious as a greyscale image and invisible once multiplied into a lit colour.
- **12d. Bilateral blur x2.** Verify the noise disappears without bleeding across silhouettes.
- **12e. `lighting_fs`.** The orange figure appears.
- **12f. FXAA.**
- **12g. CAPSULE SKELETON — DONE.** One capsule per bone, joint to parent, with a live radius
  slider. Smoke PASS, `check` green, no change in host calls.

  ★ **`wgpu_app.drawCapsule` ALREADY EXISTED** (raylib parity: cylinder body + two spherical
  caps, via `appendConeBetween` + two `appendSphere`). Nothing new was needed in the engine —
  checking before writing saved building a primitive that was already there.

  ★ Root and end sites are drawn as BARE SPHERES: a capsule needs two endpoints, the root has
  no parent, and an end site's bone is the synthetic stub §7 adds to give a leaf a direction.
  Zero-length bones are caught explicitly — `drawCapsule` would otherwise build a degenerate
  cylinder, and coincident joints do occur.

  Kept as GEOMETRY, deliberately: §7a's analytical capsule shadows and AO are a different
  lighting model, and mixing them into §12's deferred pipeline would mean maintaining two.
- **12h. GPU skinning, as a swap.** ★ Not merely an optimisation here: it is what makes the
  retained VBO static, cutting the per-frame upload from ~68k vertices to 96 matrices (point 4). `skinned_gbuffer_vs` + a bone-palette storage buffer, with
  `skinMeshCpu` kept and both exercised — the CPU path stays the software-renderer and
  debugging route, and the two must agree. ★ A test that skins the same frame BOTH ways and
  compares vertex positions is the cheap way to keep them honest.

★ **Verify each stage by DISPLAYING ITS OUTPUT, not by looking at the final image.** §11 cost
five device rounds to a bug that was invisible in the composite; a pipeline with six stages
needs each one inspectable on its own. GenoView's `shadow.vs`, `ssao.fs`, `fxaa.fs`
  are the reference; §7a's analytical capsule AO is the alternative worth comparing against.

---

## 13. ★ MOCAP ON ROBOTS — see `src/notes/retarget_plan.md` (the current plan)
