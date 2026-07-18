# JPEG decoder port plan

**Goal**: add a baseline JPEG decoder to `src/codecs.zig` as a sibling
to the existing `png` section, so `loadModelFromMemory` can render
real-world glTF assets (DamagedHelmet + many others) that ship JPEG
textures instead of PNG.

**Reference implementations studied** (not to copy — to learn from):
- `stb_image.h` from `raylib/src/external/` — the canonical C
  single-header.  Lines 1914–4080 (~2,170 lines) cover JPEG.
- `zigimg/src/formats/jpeg/` — modular Zig port.  Total ~1,400 lines
  for the decoder (writer excluded), split across 7 files.

This document is the result of reading both and extracting the
structural lessons; we'll write our own implementation in zimr's
established `codecs.zig` style.

---

## 1 What JPEG decoding actually requires

A baseline JPEG (the only kind we'll support; see scope below) is
decoded by these stages, each well-defined by ITU T.81:

1. **Marker scan** — file is a stream of `0xFF`-prefixed 2-byte
   markers, most followed by a length-prefixed segment.  Walk
   linearly, dispatch on marker type.
2. **Segment parse** — three structural segments matter:
   - `DQT` (Define Quantization Table) — up to 4 tables, each 64
     bytes (zigzag-ordered).
   - `DHT` (Define Huffman Table) — up to 4 DC + 4 AC tables, each
     a canonical (length-counts + symbol-table) Huffman code.
   - `SOF0` (Start Of Frame, baseline DCT) — image dimensions,
     8-bit precision, component list (Y/Cb/Cr + sampling factors +
     which DQT to use).
   - `SOS` (Start Of Scan) — selects which Huffman tables each
     component uses for the entropy-coded segment that follows.
3. **Entropy decode** — bit-stream of Huffman-coded coefficients
   forming 8×8 blocks of i16 DCT coefficients.  DC coefficients are
   differentially coded across blocks of the same component; AC
   coefficients use run-length-encoded zeros plus the magnitude
   bits.  Output: one `[64]i16` block per component per MCU
   ("Minimum Coded Unit" = an interleaved tile of component blocks
   sized by the chroma sampling).
4. **Dequantize** — element-wise multiply each block by its
   component's quant table.
5. **Inverse DCT (IDCT)** — 8×8 frequency-domain → 8×8 spatial
   samples.  ~80 lines of fixed-point math per block.  Several
   standard algorithms exist (AAN, Loeffler/Ligtenberg, IJG); they
   differ in operation count, not output (within rounding).
6. **Chroma upsample** — for 4:2:0 / 4:2:2 subsampling, replicate
   or bilinearly interpolate Cb/Cr to match Y resolution.
7. **YCbCr → RGB** — fixed-point matrix multiply per pixel, plus
   level shift (+128) and clamp to [0, 255].

The output of stage 7 matches our existing `png.Image` shape:
RGBA8, contiguous.

---

## 2 Reference comparison: stb_image vs zigimg

Both correctly handle baseline JPEG.  They differ in style:

| | **stb_image (C)** | **zigimg (Zig)** |
|---|---|---|
| Lines | ~2,170 (JPEG only) | ~1,400 |
| Layout | One big file with sections | Modular: 7 files |
| State | Single fat struct `stbi__jpeg` | Per-stage structs (Frame, Scan, Table) |
| Huffman | "Fast" table (9-bit lookup) + slow fallback | Same idea (9-bit lookup), HashMap fallback |
| IDCT | Two variants: ref + SIMD | One variant (Loeffler-style fixed-point) |
| Progressive | YES — adds significant complexity | YES (also adds complexity) |
| Color modes | Y, YCbCr, CMYK (legacy) | Grayscale + RGB |
| Errors | C-style int returns | Zig `error{...}` enum |
| File I/O | Custom callback context | `std.Io.Reader` |

**What we'll borrow from each**:
- *stb_image*: the **fast Huffman table** trick (9-bit lookup
  that short-circuits the common case — most JPEG codes are ≤9
  bits) is a measurable speedup and not hard to implement.
- *zigimg*: the **module split** by concern (markers / Huffman /
  IDCT / color) maps cleanly to Zig.  Their Loeffler-style IDCT
  is short and readable — we can write our own version of the
  same algorithm.
- *Neither* will be copied verbatim.  The IDCT in particular has
  several decades of folklore around constant choices; we'll write
  it from the well-known Loeffler equations with our own variable
  names and use the references to cross-check numerics on a known
  block.

**What we'll deliberately NOT borrow**:
- stb_image's manual SIMD (premature for our use; LLVM auto-vec
  handles the hot loop fine).
- zigimg's `Image` / `FormatInterface` framework (we have our own
  `Image` in `codecs.zig`).
- zigimg's `Frame` allocator-per-component model (overkill for
  RGBA8-only output; we can decode straight to a single output
  buffer).

---

## 3 Scope — what we WILL and WON'T support

**Will**: baseline 8-bit sequential JPEG with Huffman coding,
YCbCr or grayscale, common chroma subsampling (4:4:4, 4:2:2,
4:2:0).  This covers ~95%+ of JPEGs in the wild including every
texture in Khronos's glTF Sample Models.

**Won't (out of scope for v1)**:
- Progressive JPEG — large amount of extra state (scan resumption,
  successive-approximation bands).  Add later if we hit one.
- Arithmetic coding (SOF9–15) — essentially unused due to patent
  history; no glTF asset in the wild uses it.
- 12-bit precision (SOF1) — astronomical/medical use only.
- Lossless JPEG (SOF3, SOF7) — never seen in 3D assets.
- Hierarchical / differential modes (SOF5–7, 13–15) — same.
- CMYK / YCCK — print-prepress holdovers, not in glTF.
- EXIF / ICC profile / thumbnail handling — irrelevant for textures.
- Encoding (we only need decode for now).

If we hit an unsupported feature we return a specific error
(`UnsupportedMode` / `UnsupportedPrecision` / etc.) and let the
caller fall back gracefully — same pattern `materialsFromGltf`
just learned to apply for image-format failures.

---

## 4 Phased implementation roadmap

Each phase ends with a test that confirms its piece works against
DamagedHelmet's textures (already in `examples/assets/`).

### Phase A — Marker scanner + segment parse (no entropy decode)

**Deliverable**: `codecs.jpeg.scanMarkers(bytes) → Header` returning
just `{ width, height, components, sampling_factors, quant_table_ids,
huffman_table_ids }`.  No decoded pixels.

**Files touched**: `src/codecs.zig` — add a `jpeg` section after
the `png` section, mirroring its style.

**Pieces**:
- `pub const Error = error{...}` enum matching the surface.
- `pub const Image = struct { ... }` — same shape as
  `png.Image` (RGBA8, w, h, deinit).
- `const Markers = enum(u16) { soi = 0xFFD8, eoi = 0xFFD9, sof0 = 0xFFC0, ... }`.
- Marker walk loop with switch dispatch.
- `parseDqt`, `parseDht`, `parseSof0`, `parseSos` helpers (just
  read into structs; no Huffman table construction yet).

**Estimated effort**: 4-6 h.  Most of this is mechanical
byte-stream parsing with length-checks.

**Test**: feed `DamagedHelmet.glb`'s first image (offset 0x88e28
through end of its JPEG bytes — locate via the BIN-chunk scan we
already did) and assert dimensions match what `file` says.

### Phase B — Huffman tables + entropy decode

**Deliverable**: produce `[][64]i16` of dequantized coefficient
blocks in MCU order.  No IDCT yet.

**Pieces**:
- `HuffmanTable` struct with the 9-bit "fast" lookup + a slower
  walk for >9-bit codes.  Built from the (length-counts, symbols)
  pairs DHT segments deliver.
- `BitReader` that handles the JPEG-specific `0xFF` byte-stuffing
  quirk (every literal `0xFF` in the entropy stream is followed
  by `0x00` which is skipped during decode).
- DC differential decode (carries a per-component "previous DC"
  across blocks).
- AC run-length-zero + magnitude decode (the standard `(run, size)`
  Huffman symbols).
- MCU assembly per component sampling factors.
- Dequantize step folded in (multiply each coefficient by its
  quant table entry before output — saves one pass over the data).

**Estimated effort**: 6-10 h.  This is the densest part.  Huffman
construction has subtle edge cases (zero-length runs, EOB markers,
end-of-bit-stream handling).

**Test**: assert total coefficient count equals
`ceil(w/8) * ceil(h/8) * sum(sampling_factors)`; spot-check a few
DC values for sanity.

### Phase C — IDCT + chroma upsample + YCbCr→RGB

**Deliverable**: full RGBA8 output, end-to-end.

**Pieces**:
- `idctBlock(in: *[64]i16, out: *[64]u8)` — Loeffler-style 1-D ×
  2 passes, fixed-point with 12-fractional-bit constants.  ~80
  lines.  Write from scratch with the well-known coefficients;
  cross-check against zigimg/stb_image on the same input block.
- Chroma upsample for the three common subsampling modes (skip
  cleverness — replicate-by-2 is fine for v1; bilinear can come
  later if needed).
- YCbCr → RGB matrix:
  - R = Y                + 1.402   × (Cr − 128)
  - G = Y − 0.34414 × (Cb − 128) − 0.71414 × (Cr − 128)
  - B = Y + 1.772   × (Cb − 128)
  Implemented in fixed-point, clamp to `[0, 255]`, alpha = 255.

**Estimated effort**: 4-6 h.

**Test**: decode DamagedHelmet's first JPEG, write to PNG via
`zigimg`'s encoder offline (or just to a raw .ppm), eyeball.

### Phase D — Integration with materialsFromGltf

**Deliverable**: DamagedHelmet renders with its texture.

**Pieces**:
- In `src/drawing.zig` materialsFromGltf, replace the
  "JPEG → log warning, skip" branch with a call to
  `codecs_mod.jpeg.decode(gpa, img_bytes)`.  On error, fall back to
  the same "warn + leave untextured" path so we never abort the
  whole model load.
- Auto-dispatch: in the same function, switch on `mime_type`
  (or sniff magic bytes when mime_type is null) and route to
  `png.decode` vs `jpeg.decode`.

**Estimated effort**: 2-4 h.

**Test**: `damaged_helmet.html` shows the helmet with textures
applied (orange-brown weathered metal look, the canonical visual).

---

## 5 Effort estimate

Sum of phase estimates: **16-26 hours**, realistically across
3-5 sessions.  Phase B dominates.  Risk concentrations:
- Huffman edge cases (Phase B) — easy to mis-handle stuffing,
  bit-direction, or EOB.  Mitigation: cross-check coefficient
  blocks against zigimg's output on the same input file.
- IDCT numerics (Phase C) — small rounding differences in the
  fixed-point constants cause off-by-1 pixel values.  Mitigation:
  comparison test against a reference output produced with another
  decoder on the same input file.

---

## 6 Things this plan does NOT do

- We do not commit to performance work.  Decode speed for a
  2048² JPEG inside wasm should be ~50-200 ms one-shot at init
  time, which is fine for our use case (textures load once).  If
  it becomes a bottleneck we revisit with SIMD intrinsics or
  per-block parallelism.
- We do not address JPEG ENCODING.  zimr currently never produces
  JPEG; we always emit PNG for any image-writing path.
- We do not change the `Image` shape.  Decoder output remains
  RGBA8 contiguous, same as PNG.  Callers don't notice which codec
  ran.

---

## 7 References to keep around (not in-repo)

- `/tmp/raylib-master/src/external/stb_image.h` — keep around as
  the cross-check oracle.  Lines 1914-4080 are the JPEG decoder.
- `/tmp/zigimg/zigimg-master/src/formats/jpeg/` — same role,
  Zig-flavored.  `Frame.zig` is the IDCT + render reference,
  `huffman.zig` is the table reference, `Scan.zig` is the entropy
  decoder reference.
- ITU-T Rec T.81 (Sept 1992) — the actual JPEG standard, ~180
  pages.  Worth a skim for the marker tables; chapter F covers
  baseline coding specifically.

---

## 8 When to actually do this

This plan exists; the work doesn't start automatically.  Trigger
when:
- A real PBR asset Simon wants to render uses JPEG textures and
  the "untextured base color" fallback isn't good enough; OR
- We circle back to S1.5 batch 2 and want shader-arc demos with
  real materials.

Until then the existing JPEG-graceful-degrade fallback in
materialsFromGltf is sufficient — assets load with geometry +
base color and don't abort.
