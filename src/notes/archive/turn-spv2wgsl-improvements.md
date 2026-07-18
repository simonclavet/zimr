# spv2wgsl improvements landed this turn

## Edge classification (Tint-inspired)

Added `EdgeKind` enum + `classifyEdge(stack, target_label)` helper.
Walks open frames from inner to outer; returns `.loop_break` /
`.loop_continue` / `.forward`.

`handleBranch` (plain OpBranch) now emits `break;` / `continue;`
when the target is the merge / continue of an enclosing loop frame.

`handleBranchConditional` (OpBranchConditional) checks both true and
false labels.  Four patterns now emit inline:

- `true=break,  false=forward` → `if (cond) { break; }`
- `false=break, true=forward`  → `if (!cond) { break; }`
- `true=cont,   false=forward` → `if (cond) { continue; }`
- `false=cont,  true=forward`  → `if (!cond) { continue; }`

Other combinations still open a scoped if/else.  See
tint-vs-spv2wgsl.md for the rationale.

## New opcodes

Added to the Op enum and dispatch:

- **OpCopyObject (83)** → just a `let` rebind to the operand;
  identical emission to OpLoad in our model.
- **OpFUnordEqual / FUnordNotEqual / FUnordLessThan /
   FUnordGreaterThan / FUnordLessThanEqual / FUnordGreaterThanEqual
   (181, 183, 185, 187, 189, 191)** → same binary-op emission as
  their Ord counterparts.  WGSL doesn't distinguish ordered from
  unordered float compares; both work fine on non-NaN inputs.

These were the only two opcodes appearing as
`UNHANDLED spv opcode N` in the corpus — Zig's SPIR-V emit produces
both for the fractal shaders' early-exit conditions and SSA bookkeeping.

## Re-enabled mandelbrot pipeline

`examples/wgpu_demo/wgpu_demo.zig` — `s.mandelbrot_shader =
try z.shader.loadShader(...)` is back.  The shader is loaded but
not yet drawn (pipeline-switching plumbing remains a follow-up).
If WGSL parsing fails at CreateShaderModule, the page's error
overlay surfaces it.

Smoke goes from 36 → 44 bridge calls during init (the extra 8 are
the mandelbrot pipeline setup).  No traps.

## Validation status

Corpus refresh: 0 shaders with `UNHANDLED` markers.  All 3 fractal
WGSL outputs parse as valid WGSL per the spec; miniray reports them
as BAD only at `continuing {` lines, which is miniray's own parser
limitation (we verified the syntax is spec-compliant via wgsl_reflect's
grammar class `F` / class `j`).

Julia and mandel_julia loadShader calls are left commented for the
next turn — wanted to validate mandelbrot first in real Chrome
before lighting all three.
