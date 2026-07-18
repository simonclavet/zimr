PROPOSED KEYWORD ADDITIONS — for approval (nothing applied yet)
================================================================

TIER A — TYPES, zero collisions, RECOMMEND ADD (27):
  Aabb  Aabb2  Boolx16  Boolx4  Boolx8  CameraProjection  ColorU32  Complex  F32x16  F32x4Component  F32x8  Mat  Mat2  Mat22  Mat3  OrthoBasis3  Plane2  Quat  RayCamera  RayCameraDesc  Rot2  Sweep2  Transform2  Trs  Vec  Vec2i  Vec3

TIER B — TYPES, add after a tiny fix (2 sites each):
  Vec2 (2 dup redefs: compute_host `@Vector(2,f32)`, runtime `@import("zm").Vec2`)
  Color (1: wgpu.zig extern Color RGBA — reconcile with zm.Color)

TIER C — TYPES with LEGITIMATE non-zm uses — RECOMMEND EXCLUDE
(unless we unify types.Ray/Camera with zm, a separate decision):
  Ray (5 — raytracer/plot3d custom structs + types.Ray aliases)
  RayCollision (2 — types.RayCollision)
  Camera2D/Camera3D (2 — custom/types camera structs)
  Transform (1 — plot.zig's own 2D plot transform)

TIER D — FUNCTIONS, distinctive, zero collisions, OPTIONAL (11):
  complex  f32x4  f32x8  lerpV  mapLinear  modAngle  mulMat  mulMatVec  niceNum  swizzle  vec

EXCLUDE — common-word functions (collide w/ natural locals/methods, like ln/sqrt2):
  identity  inverse  translation  quat  transpose  determinant  scaling  remap  splat

NOTE: runtime.zig:3523 `const Vec2 = @import("zm").Vec2;` is really zm.Vec2 in a
form the canonical-binding check misses — fix is to also exempt `@import("zm").X`.
