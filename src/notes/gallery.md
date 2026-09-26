# Gallery — bring back the streamed-wasm examples site

## Goal
Restore the examples gallery: a static page listing all examples as cards
(name · color-coded module · ⭐ complexity · description), filterable by module
buttons + a name/function search box. Clicking a card runs that example,
**streaming its `.wasm` as a separate file** (NOT a fat self-contained
standalone). `zig build serve` serves the whole thing locally; `zig build dist`
emits it for the GitHub Pages deploy.

Reference of the old rendered page: the saved view-source the gallery looked like
before (Downloads/view-source_..._Zimr_.html) — its inline `<script type=module>`
is the entire gallery logic and is recoverable verbatim.

## How it worked before / why it's broken now
The gallery page is **plain static HTML + inline JS** (no bun/TypeScript): it
`fetch("./manifest.json")`, renders a card per example, and filters client-side.
The only thing bun/TS provided was the shared runtime (`zimr.ts`) — c2js replaces
that now. Four things broke it, all in the GL→wgpu migration:

1. **Gallery + host.html deleted.** build.zig (~834) removed "the GL gallery
   picker index.html + per-example host.html + the WebGL runtime bundle."
2. **Everything embeds the wasm.** Both the standalone AND the served per-example
   page use c2js `--wasm-embed` (`bridgePage`, build.zig ~3515). c2js already has a
   `--wasm-url` streaming mode (sets `window.WASM_URL`); it's just unused.
3. **serve root mismatch.** `serve` roots at `zig-out/web` (only readme /
   cheatsheet / manifest / docs — no index, no examples). Examples install to
   `zig-out/wgpu-<name>/`, outside that root.
4. **manifest stale.** 113 GL-era names (`basic`, `cube3d`, …); current set is 158
   `wgpu_*` examples with different names. No generator — hand-made static file.

The manifest schema already matches the gallery JS exactly:
`{ examples: [ { name, module, stars, title, description, functions:[] } ] }`.

## Locked decisions
- **Streaming model = per-example pages.** Each example installs under the serve
  root as `<name>/index.html` (small) + `<name>/wgpu_<name>.wasm` (streamed). Cards
  link to `<name>/`. (The fuller "one shared zimr.js + host.html?app=" model is a
  later efficiency option, not v1.)
- **Manifest = reuse old curated + fill gaps.** Match the 113 old curated entries
  by bare name to surviving wgpu examples (reuse their module/stars/description),
  auto-scan `functions` for all 158, curate metadata for the ~45 new ones.

## Target layout (served root = `zig-out/web/`)
```
zig-out/web/
  index.html                         <- gallery (from src/web/index.html)
  manifest.json                      <- regenerated, 158 examples
  <name>/index.html                  <- streaming page (c2js --wasm-url)
  <name>/wgpu_<name>.wasm            <- streamed wasm
  readme.html, cheatsheet.html, docs/ (already installed here)
```

## Plan (phases)
1. **Stream the wasm.** Add a streaming served-page path: a `bridgePage` variant /
   flag that calls c2js with `--wasm-url wgpu_<name>.wasm` instead of
   `--wasm-embed`. Install it + the raw wasm under `zig-out/web/<name>/`. Verify one
   example streams (Network tab shows a `.wasm` GET, page is small).
2. **Gallery page.** Recreate `src/web/index.html` from the view-source. Tweaks:
   card link `host.html?app=${ex.name}` → `${ex.name}/`; copy "WebGL2" → "WebGPU";
   keep `fetch("./manifest.json")`. Install to `zig-out/web/index.html`.
3. **Regenerate manifest.** Generator (build step or `tools/`): enumerate the wgpu
   examples; `functions` auto-scanned from each source (as the old one was);
   `title` from the `wgpu_apps` table / AppSpec; `module/stars/description` reused
   from the old manifest by name, curated for the new ones. Write
   `src/web/manifest.json` (committed) — installed to the serve root already.
4. **Wire serve/dist.** `all-examples` (or a new `site` step) assembles the serve
   root (gallery + manifest + per-example streaming pages + wasm). `zig build
   serve` roots there already. `zig build dist` emits the same tree into
   `prebuilt/` for GitHub Pages.

## First provable slice
- Phase 1 on ONE example (e.g. `shapes_showcase`): streaming page + wasm under
  `zig-out/web/shapes_showcase/`, opened via the Zig server, streams and runs.
- Then Phase 2 gallery + Phase 3 manifest for the full set, Phase 4 wiring.

## Open items / notes
- Decide example SCOPE: all 158, or a curated subset (some are probes/smoke; the
  old gallery had ~113). Default: include all, but the curated metadata pass is a
  natural place to drop internal ones.
- The shared-runtime optimization (one `zimr.js` + `host.html?app=`) is a possible
  follow-up once per-example streaming works — the c2js JS is byte-identical across
  examples, so it's viable.
- Today's canvas-format fix (BGRA8→RGBA8) means RTT-using examples render on
  desktop now, so the gallery's 3D/RTT entries should work when streamed.
