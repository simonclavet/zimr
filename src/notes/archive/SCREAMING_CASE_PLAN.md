# Plan — eliminate SCREAMING_CASE global consts

Zig idiom: **value** consts are `snake_case`; **types** are `PascalCase`; **functions**
are `camelCase`. An all-uppercase name (`MAX_ITER`, `WHITE`, `N`) is the C-macro style we
don't want. Goal: no all-uppercase global const names anywhere in live zimr, enforced by a
lint rule.

## 1. Scope (measured)

583 all-uppercase file-scope consts total, but most are in code being deleted:

| Bucket | Count | Action |
|---|---|---|
| `rlgl.zig` + GL `zimr.zig` + `gl*`/`drawing`/`rlsw` | ~230 | none — deleted with the GL backend |
| top-level GL / redundant examples (`examples/*.zig`) | ~165 | none — deleted in the redundancy sweep |
| **wgpu example dirs** (`examples/wgpu_*/`) | **126** | **rename → snake_case** |
| **live src** (`ui`, `renderer_2d`, `render`, `types`, `physics`, …) | **~62** | **rename → snake_case** |

**~188 live consts to rename.** The rest vanish when the doomed code is deleted.

## 2. Target renames

Value consts → `snake_case`:
- `WHITE` → `white`, `MAX_ITER` → `max_iter`, `SCREEN_W`/`SCREEN_H` → `screen_w`/`screen_h`
- `ROBOTO_MONO_TTF` → `roboto_mono_ttf`, `CUBE_FS_WGSL` → `cube_fs_wgsl`, `MAT4_BYTES` → `mat4_bytes`
- `CW`/`CH`/`RW`/`RH`/`RT` → `cw`/`ch`/`rw`/`rh`/`rt`, `DEPTH` → `depth`, `LEVELS` → `levels`
- single letters (`N`, `B`, `C`, `D`, `W`, …) → a **meaningful** snake_case name (`n` is allowed
  but a real name is better — these are mostly poor names anyway)
- `DEG2RAD`/`RAD2DEG` → delete the local const; call `zm.degToRad`/`zm.radToDeg` instead

Types stay `PascalCase` (an all-caps name that is actually a *type*, e.g. a hypothetical
`RGBA`, becomes `Rgba` — but in practice almost every all-caps const is a value).

## 3. The lint rule (design)

A file-level check, same shape as `runUnusedPrivateGlobals`: walk `rootDecls`, flag any
`const`/`var` whose name has at least one letter and no lowercase letter.

```zig
/// A name is SCREAMING_CASE when it has at least one letter and no lowercase letter.
fn isScreaming(name: []const u8) bool {
    var has_letter = false;
    for (name) |ch| {
        if (ch >= 'a' and ch <= 'z') return false; // any lowercase → not screaming
        if (ch >= 'A' and ch <= 'Z') has_letter = true;
    }
    return has_letter;
}

/// Flag file-scope value consts named in SCREAMING_CASE. Zig idiom is snake_case for
/// values, PascalCase for types — an all-uppercase name is the C-macro style we don't use.
/// Suppress a genuine exception with `// lint:off screaming-const: <reason>`.
fn runScreamingConsts(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const name_tok: u32 = vd.ast.mut_token + 1;
        const name: []const u8 = ast.tokenSlice(name_tok);
        if (isScreaming(name)) {
            try ctx.emitAt(name_tok, "screaming-const", 0, "SCREAMING_CASE global '{s}' — use snake_case", .{name});
        }
    }
}
```

Notes:
- Top-level only (`rootDecls`), matching "global". Consts nested inside a top-level struct
  are out of scope for v1.
- `pub` and private both flagged — the goal is zero, period.
- `// lint:off screaming-const` exists as an escape hatch for any unavoidable case (e.g. a
  generated table) but the intent is to not use it.

## 4. Rollout (so the gate never breaks)

The rule can't be enabled while 188 violations exist. Order:

1. **Stage the rule** — land `isScreaming` + `runScreamingConsts` in `zimrlint.zig` but do
   NOT call it from `runChecks` yet (no gate impact).
2. **Convert live code in batches**, re-linting after each with the staged rule run manually
   (a one-off `runScreamingConsts`-only pass), so the gate stays green on the committed rules:
   - Batch A: the wgpu examples I've already ported (small, in-file private renames).
   - Batch B: the remaining wgpu example dirs (126 total across ~40 files).
   - Batch C: live src (~62) — handle `pub` consts carefully (cross-file references).
3. **Delete the doomed code** (GL backend + redundant examples) in the planned deletion phase
   — removes the other ~395 with zero rename effort.
4. **Enable the rule** — wire `runScreamingConsts` into `runChecks`; confirm 0 issues.

## 5. Risks

- **Public consts** (live src) have cross-file references — rename with a repo-wide
  word-boundary replace, then build + test.
- **Single-letter consts** want real names, not just lowercasing — a small design choice per
  site.
- **`unused-global` interaction** — renaming an alias to its used form is fine; just don't
  leave a now-dead old name.
- Conversions are mechanical but touch ~40 example files + several src files; do them in
  batches with a lint+build gate after each.
