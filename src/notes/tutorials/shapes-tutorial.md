# zimr Shape System — Tutorial

A guided tour of zimr's shape-generation library: the **parametric spine**, the
built-in **primitives**, the **mesh-ops toolkit** for composing and editing
meshes, and how to render what you make. Everything here is pure Zig, lives in
`src/draw3d.zig`, and is re-exported under the flat `z.` namespace.

---

## 1. The big picture

The library is organized around one idea: **a smooth shape is a parametric
surface** — a function that maps the unit square `(u, v) ∈ [0,1]²` to a point in
space. Every curved primitive (sphere, cylinder, cone, torus, knot, plane,
klein bottle) is a ~5-line callback fed through a single core, `parametricMesh`.
On top of that sits a **mesh-ops toolkit** (`meshMerge`, `meshTranslate`, …) that
edits and combines any mesh, so shapes compose: a dumbbell is a cylinder plus
two spheres; an arrow is a cylinder plus a cone.

Three layers:

| Layer | What | Examples |
|-------|------|----------|
| **Core** | the parametric engine + normal welding | `parametricMesh`, `ParametricFn` |
| **Primitives** | shapes built on the core | `genMeshSphere`, `genMeshTorus`, … |
| **Ops** | edit/compose any mesh | `meshMerge`, `meshTranslate`, `meshScale`, `meshInvert` |

Everything produces a `types.Mesh` — the same raylib-shaped struct the rest of
zimr already renders — so the ops work on the parametric shapes *and* on the
older `genMesh*Legacy` / `genMeshCube` meshes interchangeably.

> **Coexistence, not replacement.** The seven older UV generators were renamed
> `genMesh*Legacy` (e.g. `genMeshSphereLegacy`) so the new parametric versions
> could take the canonical names. The Legacy layer still works and still backs
> the raylib-port examples; new code should prefer the parametric `genMesh*`.

---

## 2. The Mesh type and memory model

Generators follow one convention: **allocator in, `types.Mesh` out, caller
frees**.

```zig
const mesh: z.types.Mesh = try z.genMeshSphere(gpa, 0.75, 32, 24);
defer z.unloadMesh(gpa, mesh); // frees vertices/normals/texcoords/indices
```

A `types.Mesh` is an `extern struct` (raylib-compatible) holding flat arrays:
`vertices` (xyz), `normals` (xyz), `texcoords` (uv), and `indices` (u16), plus
`vertexCount` / `triangleCount`. Because indices are **u16**, a single mesh is
capped at **65 535 vertices** — `parametricMesh` returns an empty mesh if a grid
would exceed that, so keep `(slices+1)·(stacks+1) < 65536`.

---

## 3. Generating primitives

All eight take `(gpa, dims…, slices, stacks)`, where `slices`/`stacks` control
tessellation:

```zig
// gpa: std.mem.Allocator
const sphere = try z.genMeshSphere(gpa, 0.75, 32, 24);       // radius, slices, stacks
const hemi   = try z.genMeshHemiSphere(gpa, 0.8, 32, 16);    // radius, …
const cyl    = try z.genMeshCylinder(gpa, 0.5, 1.3, 28, 4);  // radius, height, …
const cone   = try z.genMeshCone(gpa, 0.6, 1.3, 28, 4);      // radius, height, …
const torus  = try z.genMeshTorus(gpa, 0.55, 0.24, 36, 18);  // radius, thickness, …
const knot   = try z.genMeshKnot(gpa, 1.0, 0.7, 128, 20);    // radius(unused), thickness, …
const plane  = try z.genMeshPlane(gpa, 1.4, 1.4, 6, 6);      // width, length, …
const klein  = try z.genMeshKlein(gpa, 0.11, 48, 26);        // scale, slices, stacks
```

Conventions worth knowing:

- **Y-up.** Cylinders and cones stand along **+Y** (0 → height); the plane lies
  in the **XZ** plane centered at the origin (a floor). par_shapes is natively
  Z-up; the core rotates it (see §7).
- **Open tubes.** The cylinder and cone are open (no end caps) — caps are made by
  composition (§5), not baked in.
- **Smooth normals.** Seams and poles are welded, so a sphere has no shading
  crease down its meridian.

---

## 4. The parametric core — authoring custom surfaces

The core is public, so you can generate *any* surface by supplying a callback:

```zig
pub const ParametricFn = *const fn (u: f32, v: f32, ctx: ?*const anyopaque) [3]f32;

pub fn parametricMesh(
    gpa: Allocator,
    uvFn: ParametricFn,
    ctx: ?*const anyopaque,
    slices: i32,
    stacks: i32,
) Allocator.Error!types.Mesh;
```

`uvFn(u, v, ctx)` returns a point in **par_shapes' Z-up** convention (the core
converts to Y-up for you). `ctx` is an optional pointer for parameters. Here's a
custom **ripple surface** (a wavy sheet):

```zig
const RippleParams = struct { size: f32, amp: f32, freq: f32 };

fn rippleUv(u: f32, v: f32, ctx: ?*const anyopaque) [3]f32 {
    const p: *const RippleParams = @ptrCast(@alignCast(ctx.?));
    const x: f32 = (u - 0.5) * p.size;
    const y: f32 = (v - 0.5) * p.size;
    const r: f32 = @sqrt(x * x + y * y);
    const z: f32 = p.amp * @sin(p.freq * r); // height = the "up" axis (par Z)
    return .{ x, y, z };
}

pub fn makeRipple(gpa: Allocator) !z.types.Mesh {
    var params: RippleParams = .{ .size = 4.0, .amp = 0.4, .freq = 6.0 };
    return z.parametricMesh(gpa, rippleUv, @ptrCast(&params), 80, 80);
}
```

That's the whole extension mechanism. Internally every built-in shape is exactly
this — e.g. the sphere callback is just:

```zig
fn sphereUv(u: f32, v: f32, ctx: ?*const anyopaque) [3]f32 {
    const p: *const SphereParams = @ptrCast(@alignCast(ctx.?));
    const ph: f32 = u * pi;             // polar angle 0..π
    const theta: f32 = v * 2.0 * pi;    // azimuth 0..2π
    return .{
        p.radius * @cos(theta) * @sin(ph),
        p.radius * @sin(theta) * @sin(ph),
        p.radius * @cos(ph),
    };
}
```

---

## 5. The mesh-ops toolkit — compose and edit

These operate on **any** `types.Mesh`. Functional ops return a new mesh (you own
it); in-place ops mutate through a pointer.

```zig
// functional (allocate a new mesh)
pub fn meshMerge(gpa: Allocator, a: types.Mesh, b: types.Mesh) !types.Mesh; // a ∪ b
pub fn meshClone(gpa: Allocator, src: types.Mesh) !types.Mesh;

// in-place
pub fn meshTranslate(mesh: *types.Mesh, dx: f32, dy: f32, dz: f32) void;
pub fn meshScale(mesh: *types.Mesh, sx: f32, sy: f32, sz: f32) void; // renormalizes normals
pub fn meshInvert(mesh: *types.Mesh) void;                           // flip winding + normals

// query
pub fn meshComputeAabb(mesh: types.Mesh) [6]f32; // {minx,miny,minz, maxx,maxy,maxz}
```

### Composition pattern: the dumbbell (from the gallery)

`meshMerge` is the workhorse — it concatenates vertices and offsets the second
mesh's indices. Combine it with `meshTranslate` to place parts:

```zig
fn buildDumbbell(gpa: Allocator) !z.types.Mesh {
    var bar = try z.genMeshCylinder(gpa, 0.16, 1.5, 20, 2);
    z.meshTranslate(&bar, 0, -0.75, 0);          // cylinder is 0..height → centre it
    var ball_a = try z.genMeshSphere(gpa, 0.42, 20, 16);
    z.meshTranslate(&ball_a, 0, 0.75, 0);
    var ball_b = try z.genMeshSphere(gpa, 0.42, 20, 16);
    z.meshTranslate(&ball_b, 0, -0.75, 0);

    const step1 = try z.meshMerge(gpa, bar, ball_a);
    const dumbbell = try z.meshMerge(gpa, step1, ball_b);

    // merge copies data, so free the parts + the intermediate
    z.unloadMesh(gpa, bar);
    z.unloadMesh(gpa, ball_a);
    z.unloadMesh(gpa, ball_b);
    z.unloadMesh(gpa, step1);
    return dumbbell;
}
```

> **Ownership rule:** `meshMerge`/`meshClone` copy their inputs, so free the parts
> yourself. The final mesh is freed with one `unloadMesh`.

`meshInvert` is for interior shells — e.g. a skybox sphere you view from inside:
flip a big sphere so its faces point inward.

---

## 6. Rendering a mesh

Upload the CPU mesh to a `Model`, then draw it inside a 3D pass. A full minimal
app (this is essentially `examples/shapes_gallery`):

```zig
const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");

const State = struct { model: z.Model };

fn initState(gpa: std.mem.Allocator, f: *z.Frame, s: *State) !void {
    const mesh = try z.genMeshTorus(gpa, 0.6, 0.25, 36, 18);
    // loadModelFromMesh takes ownership of the mesh data (freed by unloadModel)
    s.* = .{ .model = try z.loadModelFromMesh(f.gl, gpa, mesh) };
}

fn deinit(gpa: std.mem.Allocator, s: *State) void {
    z.unloadModel(gpa, s.model);
}

fn update(f: *z.Frame, s: *State) void {
    const cam = // …an OrbitCamera or Camera3D…
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    z.drawModel(f.gl, s.model, zm.pointVec(0, 0, 0), 1.0, .{ .r = 110, .g = 150, .b = 240, .a = 255 });
    z.endMode3D(f.gl);
}
```

`drawModel(gl, model, position, scale, tint)` renders through the immediate 3D
path, which applies a fixed directional shade (`0.35 + 0.65·n·l`) using the
mesh's normals — which is why correct, welded normals matter.

---

## 7. How it works internally

**The triangulation.** `parametricMesh` samples a `(slices+1) × (stacks+1)` grid
of points via `uvFn`, sets each vertex's `texcoord` to its `(u, v)`, and emits
two triangles per grid cell.

**Y-up conversion.** par_shapes puts the "up"/pole axis on **Z**; zimr is Y-up.
The core remaps each generated point with a proper quarter-turn about X so the
winding (and therefore outward normals) is preserved:

```zig
verts[i + 0] = p[0];   // par x  -> zimr x
verts[i + 1] = p[2];   // par z (up) -> zimr y (up)
verts[i + 2] = -p[1];  // par y  -> zimr -z   (determinant +1 → handedness kept)
```

**Welded normals.** Naively accumulating face normals per vertex leaves a seam
where the uv wraps (the sphere's θ=0 and θ=2π columns are the same points but
distinct vertices, so they'd get different normals → a shading crease). The core
fixes this by accumulating area-weighted face normals, then **welding**: it
buckets vertices by quantized position (`round(pos · 10⁴)`) in a hashmap, sums
each bucket's normals, and writes the shared, normalized result back. Poles get
the same treatment.

**u16 indices.** All indices are 16-bit for compact buffers, hence the 65 535
vertex ceiling.

---

## 8. Ideas for improving the system

- **Auto-merge dual-stage nicety aside — real one:** a `meshWeld(gpa, mesh, eps)`
  that deduplicates coincident *vertices* (not just normals) and remaps indices.
  Generated grids duplicate the seam column; welding shrinks vertex counts and is
  a prerequisite for clean subdivision.
- **`meshRotate(mesh, axis, radians)`** (Rodrigues) — the missing transform.
  Without it you can't orient parts, so an arrow (cone rotated onto a shaft) or a
  chair leg can't be assembled yet. High value, ~20 lines.
- **A disk generator + capped variants.** `genMeshDisk` (a triangle fan) unlocks
  `meshCap`/capped cylinder + cone via `meshMerge`, closing the "open tube" gap.
- **Analytic normals for custom surfaces.** For user callbacks the weld handles
  seams, but a `parametricMeshAnalytic` that finite-differences `uvFn` for exact
  normals (with a pole fallback) would give crisper shading on high-frequency
  surfaces like the ripple.
- **`meshTransform(mesh, mat4)`** taking a `zm` matrix — one general op instead of
  translate/scale/rotate, composable with the rest of zimr's math.
- **u32 index path.** A `MeshLarge` or an index-width flag would lift the 65 535
  cap for dense icospheres/terrain. Cross-cutting (touches upload + draw), so it's
  a deliberate call, not a freebie.
- **Builder ergonomics.** A small `ShapeBuilder` that chains ops
  (`builder.add(sphere).translate(…).merge(cone)…build()`) and frees intermediates
  for you would remove the manual `unloadMesh` bookkeeping that `meshMerge` needs.
- **Tangents on generation.** Wire `genMeshTangents` in so parametric meshes are
  normal-map-ready without a second call.

---

## 9. Future work (the roadmap)

Ordered roughly by value:

1. **Finish the transform set** — `meshRotate`, then `meshTransform(mat4)`.
2. **Disk + caps** — `genMeshDisk`, capped cylinder/cone; then the classic
   `mesh_builder` example (arrow, capped cylinder, chair) showing composition.
3. **Weld / unweld / removeDegenerate** — the vertex-level cleanup ops from
   par_shapes, enabling subdivision and robust merges.
4. **Platonic solids** — `genMeshIcosahedron / Dodecahedron / Octahedron /
   Tetrahedron` (hardcoded tables; not parametric, they're siblings of the core).
5. **Icosphere** — `genMeshIcosphere(subdivisions)` (subdivide + weld + normalize):
   uniform geodesic sphere, far better topology than the UV sphere for
   displacement. Caps at ~subdivision 6 under u16.
6. **Procedural rock** — noise-displaced icosphere, reusing zimr's Perlin rather
   than porting par_shapes' OpenSimplex blob. Feeds a `procgen_rocks` example.
7. **Retire the Legacy layer** — once the parametric shapes are proven and the
   raylib-port examples migrate over, delete the `genMesh*Legacy` functions.
8. **Optional exotics** — oriented disk, extra parametric surfaces (Möbius,
   seashell) as showcase content for the custom-surface API.

The north star: a zmesh/par_shapes user coming to zimr finds every capability
they'd reach for — rich primitives, a general parametric core, and a composable
mesh-ops toolkit — expressed as one coherent, flat Zig API.
