# Migrating from raylib — matrix conventions

zimr started as a Zig port of raylib, and for a long time it inherited
raylib's matrix convention verbatim — including a long-documented
quirk in how matrix multiplication is defined.  The matrix-fix arc
(turns 206-21x) corrected this.  If you are porting raylib (or
raylib-rs, or raylib-zig) code into zimr, this is the one area where
the math does **not** translate one-to-one.  Read this first.

For the original upstream discussion, see raylib issues
[#3039](https://github.com/raysan5/raylib/issues/3039) and
[#4858](https://github.com/raysan5/raylib/issues/4858).


## The one big change: `MatrixMultiply` → `matrixMul`

raylib's `MatrixMultiply(left, right)` does **not** compute the
standard mathematical product `left * right`.  It computes the
**reversed** product — the result is mathematically `right * left`.
raylib's own header acknowledges this; the matrices are effectively
stored transposed, and the multiply is reversed to match.

zimr removed the inherited `matrixMultiply` entirely.  Its replacement,
`matrixMul`, computes the **standard** product:

```
matrixMul(A, B)  ==  math  A * B        (result[r,c] = Σ_k A[r,k] * B[k,c])
```

### Porting rule

Every `MatrixMultiply(L, R)` becomes **`matrixMul(R, L)`** — swap the
two arguments:

| raylib / old zimr                | zimr now                     |
|----------------------------------|------------------------------|
| `MatrixMultiply(a, b)`           | `matrixMul(b, a)`            |
| `MatrixMultiply(model, view)`    | `matrixMul(view, model)`     |
| `MatrixMultiply(MatrixMultiply(s, r), t)` | `matrixMul(t, matrixMul(r, s))` |

The argument swap exactly cancels the direction change, so a correct
raylib program stays correct after the swap — the *behavior* is
identical, only the *spelling* changes.

If you call the removed `matrixMultiply` by name, zimr gives you a
compile error pointing back here:

```
error: matrixMultiply has been removed — use matrixMul (standard
math A*B). matrixMultiply(L, R) computed the REVERSED product R*L;
port it as matrixMul(R, L). See src/notes/migrating-from-raylib.md
```


## Why this matters: chains read the natural way now

Under raylib's convention, a model-view-projection chain is written
"inside-out" — the first transform applied to the vertex appears
*first* in the argument list:

```c
// raylib: reads inside-out
Matrix mvp = MatrixMultiply(MatrixMultiply(model, view), projection);
```

With `matrixMul` the same chain reads "outside-in", matching how the
math is written on paper (`projection * view * model`, applied to a
column vector, rightmost first):

```zig
// zimr: reads like the math
const mvp = matrixMul(projection, matrixMul(view, model));
```

A TRS (translate-rotate-scale) transform — scale applied to the
vertex first, then rotate, then translate — is math `T * R * S`:

```zig
const transform = matrixMul(t, matrixMul(r, s));   // math T * R * S
```


## What did NOT change

- **All matrix-*building* helpers are unchanged.**  `matrixTranslate`,
  `matrixScale`, `matrixRotate` / `matrixRotateX/Y/Z`,
  `matrixPerspective`, `matrixOrtho`, `matrixFrustum`, `matrixLookAt`,
  `matrixInvert`, `matrixTranspose` — each already produced a standard
  matrix per the field-name convention.  Only the *multiply* was
  reversed; the builders were always correct.
- **`vector3Transform(v, M)` is unchanged** — it applies `M` to the
  column vector `v` (`M * v`), standard convention.
- **The `Matrix` struct field names** (`m0`..`m15`) are unchanged.
  Phase C of the matrix-fix arc may reorder the struct's *memory
  layout* (so it is genuinely column-major), but the field names and
  their mathematical meaning stay the same — `m12`/`m13`/`m14` are
  still the translation column, etc.  Code that accesses `mat.m12`
  keeps working.
- **GPU upload** (`matrixToFloatV`, the `glUniformMatrix4fv` path) is
  unchanged.  The bytes handed to the shader are the same; this
  migration changed only how matrix composition is *spelled* in
  source, not the rendered result.


## Quick reference — common idioms

| Goal                              | zimr code                                            |
|-----------------------------------|------------------------------------------------------|
| Model-view-projection             | `matrixMul(proj, matrixMul(view, model))`            |
| TRS transform (`T * R * S`)       | `matrixMul(t, matrixMul(r, s))`                      |
| Compose two transforms `A` then `B` (B applied to vertex first... no — A first) | apply A first → `matrixMul(B, A)` |
| Apply transform `M` to a point    | `vector3Transform(point, M)`                         |
| Inverse-transpose (normal matrix) | `matrixTranspose(matrixInvert(model))`               |

> Note on "A then B": if you want a vertex transformed by `A` and
> *then* by `B`, the matrix is math `B * A` — write `matrixMul(B, A)`.
> The transform applied first sits on the *right*.  This is standard
> linear algebra; it only felt different under raylib's reversed
> `MatrixMultiply`.


## Coming: the zmath-adoption rename map

zimr's math library is being hard-forked onto zig-gamedev's zmath
(see `zmath-adoption-plan.md`).  When that lands, the raylib-style
names (`vector3DotProduct`, `matrixInvert`, …) are replaced by
zmath's (`dot3`, `inverse`, …) — one canonical name per concept, no
aliases.  A full mapping table will be filled in here as Z3 migrates
call sites.  Most are pure renames; the behavioural changes to watch:

- **`Vector2LineAngle` → `lineAngle2`: the sign flipped.**  raylib's
  `Vector2LineAngle` returns a *clockwise-positive* angle (negated
  `atan2`); raylib's own source has a TODO questioning that.  zimr's
  `lineAngle2` is **counter-clockwise positive**, consistent with
  every other angle in the library (`angle2`, `rotate2`, the matrix
  rotations).  Raylib code that depended on the old sign must negate
  the result.
