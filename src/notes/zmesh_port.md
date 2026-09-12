# zmesh / par_shapes port — CURRENT PLAN

> Goal (Simon): port zmesh's shape-generation value into zimr, pure-Zig,
> idiomatic, ≤1 new file, cleverly integrated with what we already have.
> zmesh bundles par_shapes (shapes), meshoptimizer (optimization), cgltf (glTF).
> **Only par_shapes is in scope** — zimr already has its own glTF/OBJ loaders,
> and meshoptimizer is a separate concern (not shape gen).

## What we already have vs what par_shapes adds

**zimr already has** (`src/draw3d.zig`, raylib-derived, all `(gpa, …) !types.Mesh`):
genMeshCube, genMeshSphere (UV), genMeshHemiSphere, genMeshCylinder, genMeshCone,
genMeshTorus, genMeshKnot, genMeshPlane, genMeshHeightmap, genMeshCubicmap,
genMeshPoly, genMeshTangents. Plus `uploadMesh`, `unloadMesh`, `pbr3d.loadMesh`
(Mesh → GPU → draw). So the common shapes + the render path already exist.

**par_shapes NET-NEW (the reason to port):**
1. **Mesh-ops toolkit** — the biggest win, and we have NOTHING like it: `merge`,
   `weld`, `unweld`, `invert`, `translate`/`rotate`/`scale`, `computeNormals`,
   `computeAabb`, `removeDegenerate`, `clone`. These compose with our EXISTING
   generators (merge a zimr cylinder+cone into an arrow, weld a heightmap, flip
   winding, recompute normals after CPU edits).
2. **Platonic solids** — icosahedron, dodecahedron, octahedron, tetrahedron.
3. **Icosphere** (`subdivided_sphere`) — geodesic sphere, uniform triangles
   (better topology than our UV sphere for displacement/subdivision).
4. **Parametric framework** — `create_parametric(uv→xyz fn, slices, stacks)`;
   ALL parametric shapes are ~5-line callbacks on top of it, AND it lets users
   author custom surfaces (Möbius, seashell, ripple…). Elegant unifying core.
5. **Exotic** — klein bottle (trivial callback), rock (noise-displaced
   icosphere), L-system / turtle geometry (niche, ~200 lines + a parser).

**Overlap** (both have): sphere, hemisphere, cylinder, cone, torus, knot, plane.

## Design thesis (the "clever integration")
Do NOT blindly re-port shapes we already have. Add the NET-NEW value and let
overlapping shapes coexist:
- Port the **mesh-ops toolkit** (composes with existing meshes) — highest value.
- Port **platonic solids + icosphere** (new shapes we lack).
- Port the **parametric framework** (unifying core + custom-surface API), and
  express the parametric shapes (sphere/torus/cylinder/cone/hemisphere/plane/
  trefoil/klein/disk) on top of it as a CONSISTENT set that COEXISTS with
  draw3d's raylib versions — no supersede, no breakage of existing examples.

## Placement — one new file: `src/shapes.zig`
draw3d.zig is **7137 lines** — too big to absorb ~1000-1500 more logically.
`src/shapes.zig` imports `types.Mesh`, `zm` (Vec/math), `Allocator`; produces
`types.Mesh` (extern struct, u16 indices) exactly like `genMeshSphere`; and is
re-exported as `pub const shapes = @import("shapes.zig")` in zimr.zig →
`z.shapes.icosphere(gpa, 4)`, `z.shapes.merge(gpa, a, b)`. The mesh-ops operate
on ANY `types.Mesh`, including those from draw3d's `genMesh*`.

## API sketch (idiomatic Zig)
Generators (match `genMeshSphere` style): `icosphere(gpa, subd) !Mesh`,
`icosahedron/dodecahedron/octahedron/tetrahedron(gpa) !Mesh`,
`torus(gpa, slices, stacks, radius) !Mesh`, `parametricDisk`, `klein`, …
Parametric core:
`parametric(gpa, comptime uvFn: fn(f32,f32) Vec, slices, stacks) !Mesh`
(comptime-monomorphized, zero-cost for built-ins) + a runtime variant
`parametricCtx(gpa, uvFn: *const fn(f32,f32,?*anyopaque) Vec, ctx, slices, stacks)`
for user surfaces.
Mesh-ops: in-place `translate/rotate/scale/invert(mesh: *Mesh, …) void`,
`computeNormals(*Mesh) void`, `removeDegenerate(gpa, *Mesh, minArea) !void`;
functional `merge(gpa, a, b) !Mesh`, `weld(gpa, m, eps) !Mesh`,
`unweld(gpa, m) !Mesh`, `clone(gpa, m) !Mesh`, `computeAabb(m) [6]f32`.

## Conventions / constraints to reconcile
- **Axis**: par_shapes puts sphere poles on ±Z; zimr is Y-up. → convert output
  to Y-up (swap y/z) so shapes match our camera + existing meshes.
- **Indices**: `types.Mesh.indices` is `c_ushort` (u16) → **65535-vertex cap**.
  Icosphere subd ≤6 ≈ 41k verts (safe); assert + document the cap.
- **Winding/normals**: CCW outward, matching draw3d's `genMesh*`.
- **Rock noise**: reuse zimr's Perlin (expose a small `noise` helper) rather than
  port par_shapes' embedded OpenSimplex (~300 lines); Perlin displacement looks
  fine for rock.

## Scope tiers
- **Core (recommended)**: parametric framework + parametric shapes + platonic
  solids + icosphere + mesh-ops toolkit.
- **Extras (optional)**: rock (via Perlin), oriented disk, custom-parametric API,
  klein bottle (trivial).
- **Skip (recommended)**: L-system (niche, big), meshoptimizer + cgltf (zimr has
  its own), saveToObj (zimr has OBJ writing elsewhere if needed).

## Examples plan
1. **`shapes_gallery`** (or extend `models_geometric_shapes`): a rotating grid of
   the new shapes — 4 platonic solids, icosphere, torus, trefoil, klein, a custom
   parametric surface — via pbr3d. The showcase.
2. **`mesh_builder`** (mesh-ops demo): build a COMPOUND mesh — an arrow (cylinder
   shaft + cone head via `merge` + `translate`/`rotate`) or a dumbbell (2 spheres
   + cylinder). Shows merge/transform; optional weld/invert toggles.
3. **`procgen_rocks`** (if rock included): a scattered field of procedural rocks
   with varying seeds/subdivisions — shows rock + noise.
4. **`parametric_surface`** (optional): a custom uv→xyz surface (Möbius / seashell
   / ripple) — shows the custom-parametric API.

## DECISIONS (settled with Simon) + PROGRESS
- **Coexist, not supersede** — but it must read as ONE library, not raylib+parshapes bolted together.
- **Parametric spine is the backbone** — every smooth primitive is a `uv→xyz` callback on one `parametric()` core; platonic solids + icosphere are siblings; the mesh-ops toolkit is the connective tissue.
- **No new file** — everything goes in `src/draw3d.zig` (flat, fat; zimr favors big flat files over deep namespacing). Re-export under the existing scheme.
- **Gradual retirement via `Legacy` suffix (no aliases):** rename the shape gens we'll supersede to `…Legacy` + update every call site so nothing breaks; build the new parametric versions under the freed names; migrate examples over time; delete `Legacy` once unused.
- **Port need not be exact** — the bar is that a zmesh user doesn't find important capabilities missing, NOT 1:1 fidelity.
- ✅ **DONE (zimr886): step 1 — Legacy rename.** `genMeshSphere/HemiSphere/Cylinder/Cone/Torus/Knot/Plane` → `…Legacy` across all .zig (54 occurrences, 13 files); chain draw3d→wgpu_app→zimr→examples all consistent; fog_rendering + models_geometric_shapes standalones green. Left untouched (correctly): `genMeshCube/Heightmap/Cubicmap/Poly/Tangents` (no parametric successor), `manifest.json` (docs data), `claude.md` (history).

## STILL OPEN (decide as we build the new functions)
Y-up conversion · parametric fn API (comptime + runtime) · rock noise (Perlin vs
OpenSimplex vs skip) · u16 cap vs u32 · include klein / L-system · which examples.

## Original recommendations below (some superseded by the decisions above)


## ✅ zimr887 — step 2a: parametric spine landed (in draw3d.zig)
- `parametricMesh(gpa, uvFn, ctx, slices, stacks)` core: triangulates the unit grid, converts par_shapes Z-up → zimr Y-up (proper +X quarter-turn, winding preserved), welds seam/pole normals via a quantized-position hashmap so shared edges shade smoothly. Output = raylib-shaped `types.Mesh` (u16; asserts grid < 65536 verts).
- `pub const ParametricFn` + `parametricMesh` are public → users author custom surfaces.
- 8 shapes reclaiming the freed names (+ Klein, new): `genMeshSphere/HemiSphere/Cylinder/Cone/Torus/Knot/Plane` (all `(gpa, dims…, slices, stacks)`) + `genMeshKlein(gpa, scale, slices, stacks)`. Re-exported in zimr.zig.
- Gotchas hit: `phi`/`normalize3` are reserved-math names (shadow zm.*) → `ph`/`normXyz`; `z` is a top-level struct in draw3d → bare-`z` params/locals renamed `zc`.
- Compiles clean, lint 0, fog_rendering builds green. **NOT yet visually verified** — orientation/winding/normals need a render. NEXT: a gallery example (renders the 8 via pbr3d) to eyeball + confirm, then the mesh-ops toolkit, then platonic solids + icosphere.

## ✅ zimr889 — step 2b: mesh-ops toolkit (core) + gallery composition demo
- Core ops in draw3d.zig, operate on any raylib-shaped `types.Mesh` (parametric OR genMesh*): `meshMerge(gpa,a,b)` (concat verts/normals/texcoords, offset b's indices), `meshTranslate/meshScale` (in-place; scale renormalizes normals by inverse), `meshInvert` (flip winding + negate normals), `meshComputeAabb`, `meshClone`. Re-exported. v1 assumes verts/normals/texcoords/indices present (true for all zimr gens).
- Gallery now renders a 9th shape: a dumbbell composed via `meshMerge` + `meshTranslate` (cylinder bar + 2 end spheres) — verifies the ops visually + headlessly (smoke census balanced).
- Still TODO: meshRotate (Rodrigues), weld/unweld/removeDegenerate, a disk generator (→ capped cylinder/cone), platonic solids + icosphere, and a dedicated mesh_builder example.

## ✅ zimr891 — step 2c: meshRotate + genMeshDisk + mesh_builder example
- `meshRotate(mesh, axis_x, axis_y, axis_z, radians)` — in-place Rodrigues rotation of verts + normals (axis auto-normalized; normals stay unit so no renormalize). The missing transform — lets you orient a part before merging.
- `genMeshDisk(gpa, radius, slices)` — flat triangle-fan disk in XZ facing +Y. The cap primitive.
- Re-exported. Verbose names + casual comments throughout (Simon's ask).
- NEW `examples/mesh_builder`: builds a solid CAPPED CYLINDER (cylinder + top disk + inverted bottom disk via meshMerge) and an ARROW pointing +X (cylinder shaft + cone head, both spun -90° about Z with meshRotate). Exercises rotate/disk/invert/translate/merge together. Census balanced.
- Gotchas: `z` (top-level struct in draw3d) shadowed by a `z` param again → renamed spin() params vx/vy/vz; `var` that's never mutated (passed by value to merge) must be `const`.
- Roadmap now: weld/unweld/removeDegenerate → platonic solids → icosphere → rock → retire Legacy.

## ✅ zimr892 — step 3: platonic solids (flat-shaded)
- `flatShadedFromFaces(gpa, corners, tri_indices)` helper: unwelds (3 unique verts per triangle) + per-face normal → crisp faceted look; applies Z-up→Y-up. Reuses `normXyz`.
- 4 generators from par_shapes tables: `genMeshTetrahedron/Octahedron/Icosahedron/Dodecahedron` (dodeca pentagons fan-triangulated at build). Re-exported. Verbose names + casual comments.
- NEW `examples/platonic_solids`: the four solids in a row, faceted. Census balanced.
- Roadmap left: weld/unweld ops (exposed) → **icosphere** (subdivide icosahedron + normalize + weld) → rock → retire Legacy.

## ✅ zimr893 — step 4: icosphere (geodesic sphere)
- `genMeshIcosphere(gpa, radius, subdivisions)`: seeds from the icosahedron (normalized to unit), subdivides each triangle 1→4 with a shared edge-midpoint cache (std.AutoHashMap keyed by order-independent (lo<<32|hi)), projects every new vertex onto the sphere via normXyz. Normals = unit positions (free on a unit sphere). subdivisions clamped to 6 (u16 cap; L6 ≈ 41k verts). Re-exported. Verbose names + casual comments.
- NEW `examples/icosphere_demo`: 4 icospheres at subd 0/1/2/3 in a row — shows the icosahedron rounding into a smooth sphere. Census balanced.
- Gotcha: `z` local shadowed top-level `z` again (→ seed_z); `@min(@max())` tripped clamp-pattern lint (→ bound `clamp`).
- SHAPE SET NOW: 8 parametric primitives + disk + 4 platonic solids + icosphere + full mesh-ops toolkit. Roadmap left: weld/unweld/removeDegenerate (exposed ops) → procedural rock (noise-displaced icosphere, reuse Perlin) → retire Legacy. The "shapes a zmesh user expects" list is essentially complete.

## ✅ zimr894 — step 5: procedural rock (noise-displaced icosphere) — THE payoff
- Compact 3D value-noise in draw3d (our own, not par_shapes' OpenSimplex): `latticeHash3` (integer-lattice hash), `valueNoise3` (trilinear-blended cell corners + smoothstep fade), `fractalNoise3` (4-octave fbm). Verbose names + casual comments.
- `genMeshRock(gpa, radius, subdivisions, seed)`: starts from a UNIT icosphere, shoves each vertex in/out along its direction by fbm noise (seed → 3 decorrelated offsets → a different rock), then recomputes smooth normals from the bumpy surface via parametricWeldNormals. errdefer unloadMesh guards the icosphere on failure. This is exactly why the icosphere's even triangles matter — a UV sphere would tear at the poles.
- NEW `examples/rock_demo`: 7 unique rocks (same generator, different seeds/sizes/earthy tints) scattered on the grid. Census balanced.
- Gotcha: `z` param shadow again in valueNoise3/fractalNoise3 → px/py/pz.
- SHAPE LIBRARY IS FEATURE-COMPLETE for the zmesh/par_shapes bar: 8 parametric primitives + custom-surface API + disk + 4 platonic solids + icosphere + procedural rock + full mesh-ops toolkit (merge/translate/rotate/scale/invert/aabb/clone). Roadmap left: expose weld/unweld/removeDegenerate as public ops; then retire the genMesh*Legacy layer (migrate remaining examples).

## ✅ zimr895 — step 6: vertex-level cleanup ops (weld/unweld/removeDegenerate)
- `meshUnweld(gpa, mesh)`: 3 unique verts per triangle + flat face normals (faceting; keeps source texcoords). `meshWeld(gpa, mesh, epsilon)`: merges coincident verts via quantized-position hashmap, remaps indices, averages+normalizes normals. `meshRemoveDegenerate(gpa, mesh, min_area)`: drops zero-area/sliver triangles (2-pass, keeps verts). All re-exported. Verbose names + casual comments.
- mesh_builder gained `verifyCleanupOps` — a headless self-check (runs at init) asserting unweld→3v/tri, weld shrinks, removeDegenerate keeps a clean torus. Uses `zm.assert(ok, @src())` (the codebase's own assert family — std.debug.assert is lint-banned). Smoke PASS, census balanced.
- Rough turn: str_replace double-applied the ops block (removed the dupe in draw3d + zimr); assert path was zm.assert not z.assertf.
- MESH-OPS TOOLKIT NOW COMPLETE: merge/translate/rotate/scale/invert/computeAabb/clone + unweld/weld/removeDegenerate. Shape library fully feature-complete vs zmesh/par_shapes.
- ONLY REMAINING: retire the genMesh*Legacy layer (migrate the ~8 examples still calling the Legacy names to the new parametric generators, then delete the Legacy fns).

## ✅ zimr896 — step 7 (FINAL): Legacy layer retired — PORT COMPLETE
- Migrated all Legacy call sites (8 examples + leak_test) to the new parametric generators. Mapping: torus/knot/plane 1:1; sphere/hemisphere swap last two args (Legacy rings,slices → new slices,stacks); cylinder/cone gain a stacks arg. Note: migrated cylinders/cones are now OPEN (new parametric ones have no caps) — acceptable per "not exact".
- Deleted the 7 genMesh*Legacy functions from draw3d (591 lines) + their re-exports from wgpu_app (2) and zimr (7). Updated stale comment/error-string refs (genMeshSphereLegacy → genMeshSphere).
- Verified: all 8 migrated examples build green (8/8), draw3d + zimr lint 0, models_geometric_shapes smoke PASS + census balanced. 0 Legacy defs, 0 Legacy calls remain in code (only docs/history mention the old names).
- **THE zmesh/par_shapes PORT IS COMPLETE.** Final surface (all in draw3d.zig, flat, re-exported under z.*): parametric spine (parametricMesh + ParametricFn) · 8 parametric primitives (sphere/hemisphere/cylinder/cone/torus/knot/plane/klein) · genMeshDisk · 4 platonic solids · icosphere · procedural rock · mesh-ops toolkit (merge/translate/rotate/scale/invert/computeAabb/clone/unweld/weld/removeDegenerate). Examples: shapes_gallery, mesh_builder, platonic_solids, icosphere_demo, rock_demo. Tutorial: src/notes/tutorials/shapes-tutorial.md.

## zimr897 — documentation + attribution for the shape features
- **LICENSE:** added two third-party attribution subsections — `par_shapes` (Philip Rideout, MIT, © 2019) as the algorithm/design inspiration for the whole shape library (full MIT notice reproduced), and `zmesh` (Michal Ziulek + zig-gamedev, MIT) as the API-surface reference studied. Both note no code was copied — pure-Zig reimplementation.
- **src/web/readme.html:** new "Procedural shapes and mesh editing" subsection under #threed (parametric spine + primitives + platonic/icosphere/rock + custom-surface example + the mesh-ops toolkit + an arrow-composition example), plus a #shapes TOC nav link. Points to the demos + tutorial and credits par_shapes.
