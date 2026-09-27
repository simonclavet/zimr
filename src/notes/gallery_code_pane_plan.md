# Gallery code pane — the example's source, highlighted, under the running example

**Status: PLAN UNDER REVIEW (Sep 27). Nothing is implemented.** The open decisions (§7) get asked
one at a time; D1 goes first. §2 has the prototype and every number it produced.

---

## 0. The ask

Simon, Sep 27, looking at the gallery (`index.html#input_mouse`): make it easy to read an example's
code while the example runs. There should be a pane under the example that shows its highlighted
source.

---

## 1. What is there today (read this session)

| piece | where | what matters here |
|---|---|---|
| gallery page | `src/web/index.html`, 255 lines | Manifest-driven list. Each pick mounts a fresh `<iframe src="<name>/">` after a 120 ms debounce (`select()`). The pick lives in the hash (`index.html#<name>`). ↑↓ / j k step the list from anywhere on the page. |
| gallery CSS | `tools/docfmt.zig`, the `.g-*` block of `style` | A page may not carry its own `<style>` (doc_gate rule 2), so the pane's CSS goes here too. |
| the one highlighter | `tools/docfmt.zig` `highlightZig` (and `highlightWgsl`) | Uses `std.zig.Tokenizer` at build time and emits `tok-*` spans the shared sheet already colours. |
| script exception | `tools/doc_gate.zig` `script_ok` | `index.html` is the one page allowed a `<script>`. Nothing changes there. |
| example sources | `examples/<name>/<name>.zig` | All 304 manifest entries have one. 44 have more files. |
| shader sources | `examples/<s>.zig` + `examples/<s>_io.zig`, in the flat `examples/` folder | Wired per example by `App.shaders`, through `AppContext.addShaderDepFrom`. |
| served example | `zig-out/web/<name>/{index.html, <name>.wasm}` | Installed by `finishWgpuApp`. The pane's payload lands beside them. |
| registration | the `wgpu_apps` table and the loop after it; `launcher` built by hand after that | 301 of the 304 manifest names are table rows. |
| deploy | `dist` mirrors `zig-out/web/` into `prebuilt/` | Anything installed under `web/<name>/` ships with no extra wiring. |
| dev server | `tools/serve.zig` | Serves ONE connection at a time until it closes (the loop under "One connection at a time is fine"). §2.4 shows that it is not fine. |

★ `comptime_mandelbrot` and `bouncing_ball` are in the manifest but have NO web build. They show in
the list and never run. That drift predates this plan and is out of scope. It is flagged here so it
is not blamed on the pane.

---

## 2. Experiments — prototype and measurements (Sep 27)

The prototype is not in the repo. It is a copy of the gallery with the pane, run through the real
`docfmt.exe`, plus a Python stand-in for the build step that also fed all 304 examples through
`docfmt.exe`. It was served from `zig-out/web/_proto/` (gitignored, delete freely) by the cached
`serve.exe` and by two patched builds of it. Its pane code is Appendix A.

### 2.1 Which files an example shows

Three rules, compared over all 304 manifest examples:

| rule | result |
|---|---|
| the example's folder (`examples/<name>/*.zig`) | Misses the shared shader files of the 20 shader examples. |
| the `@import` / `@embedFile` closure inside `examples/` | Misses the `kernels.zig` job kernels (imported by module name, not by path). |
| **the folder + `App.shaders` (`<s>.zig`, `<s>_io.zig`)** | **Misses one file in one example: `examples/quad_glb_data.zig`.** It is a generated 1 048-byte GLB byte array that `gltf_textured` gets through a configure hook, and it should not be shown anyway. |

Shape of the set:
- 260 examples are one file, 23 have 2-3 files, and 21 have 4 or more.
- Main files are 191 lines at the median and 522 at p90. The longest is 4 281 (`geno_dance`).
- The largest example is `zimrphysics2d_demo`: 3 files, 6 350 lines.
- The folder rule also brings in four `native_verify.zig` files, the native build-time checks of
  `shadowmap_sw`, `cel_shading`, `shader_effects` and `hybrid_render`.

### 2.2 Payload

| | |
|---|---|
| inflation from highlighting (docfmt spans) | 1.7-2.2x the raw source |
| all 304 as JSON `{name, files: [{path, lines, html}]}` | **8.4 MB** total |
| all 304 as standalone docfmt pages | 11.9 MB, because the 12.8 KB stylesheet repeats 304 times |
| typical (`input_mouse`) | 10.6 KB |
| largest (`zimrphysics2d_demo`) | 587 KB, **67 KB gzipped** |
| generating all 304 through `docfmt.exe` | **2.3 s**, serial, process spawns included |

For scale, `prebuilt/` is ~350 MB, so 8.4 MB adds about 2.4%.

### 2.3 In the browser

| measurement | result |
|---|---|
| fetching the JSON locally | 5-21 ms |
| rendering a typical file | 2-18 ms |
| rendering the worst file (`scenes.zig`, 5 397 lines, 9 424 spans) | ~115-135 ms with one line-number column, ~145-160 ms with one row per line, ~200 ms with rows + wrap |
| line-number column alignment | exact over 104 567 px (5 397 lines) |
| splitting the highlighted HTML on `\n` | 0 unbalanced lines. The rows joined back equal the source byte for byte. |
| the example frame while dragging the divider | The canvas followed the frame (768×420 → 768×250) and kept rendering. |
| phone, 375×812 | The bar fits and the page does not scroll sideways. Example 445 px, code 322 px. Wrapped rows keep their number on the first row. |

★★ **A REAL UX CONFLICT, found and fixed in the prototype.** The gallery takes ↑↓ for stepping the
list anywhere on the page. Clicking into the code and pressing ↓ loaded the next example instead of
scrolling. The fix makes the code box focusable (`tabindex="0"`) and has the keydown handler ignore
events whose target is inside the pane. Verified: ↓×5 then PageDown scrolled the code
(scrollTop 200) and the example stayed put.

### 2.4 The dev server stalls — and the fix is threads, not `Connection: close`

The first multi-file test hung: `GET /julia/` never got a response. `serve.zig` serves one
connection until it closes, and a browser keeps idle sockets open: keep-alive ones, plus speculative
preconnects that never send anything. The gallery never made two requests at once until now. The
pane does: the source fetch and the frame's page go out together.

A/B with browser tabs attached to each server, 4 s timeout per request:

| server | plain request | after an idle keep-alive socket | after a silent socket |
|---|---|---|---|
| `tools/serve.zig` as is | no response | no response | no response |
| + `.keep_alive = false` | no response | no response | no response |
| **+ one thread per connection** | **200 in 0.00 s** | **200 in 0.00 s** | **200 in 0.00 s** |

★ `Connection: close` cannot fix this. A silent preconnect socket parks the accept loop in
`receiveHead` before any response is sent. Only serving connections concurrently fixes it. It
probably also explains any "example hangs on load until I refresh" seen locally. That is not
measured, only flagged.

### 2.5 A testing note, not a bug

A hidden browser pane or background tab reports `document.hidden` and never fires
`requestAnimationFrame`. The zimr runtime waits for a frame before it fetches its wasm, so examples
do not boot there. The code pane does not need a frame and still works. Test the running-example
half in a visible tab.

---

## 3. Brainstorm — every approach, including the rejected ones

### Where the highlighting happens
| approach | verdict |
|---|---|
| **at build time, through docfmt's `highlightZig` (the project's one highlighter)** | **TAKEN.** No runtime highlighter, no raw source on the site, and the same colours as every doc page. |
| a JS highlighter in the gallery | Rejected. A second highlighter is exactly what `docs_style_plan.md` removed, and it needs the raw `.zig` published. |
| the same tokenizer compiled to wasm and run in the page | Rejected for v1. It keeps one highlighter, but it still ships raw source and adds a wasm to the gallery for no visible gain. |
| Zig autodoc's source view (`zig build docs`) | Rejected. It is local only (not in `dist`), ~100 MB, and not shaped around examples. |
| linking to or framing GitHub's blob view | Rejected. GitHub refuses to be framed, offline and local serving break, and `main` is not what the deployed wasm was built from. |

### What carries the code to the page
| approach | verdict |
|---|---|
| **`web/<name>/source.json`, fetched when the pane shows an example** | **PREFERRED** (D2). 8.4 MB in total, 10 KB typical. The gallery gets the structure (paths, line counts) without parsing HTML. Not being `.html`, the dev server does not inject its HMR script into it. |
| `web/<name>/source.html`, a standalone docfmt page that the pane parses | Alternative (D2). It also gives a shareable code-only URL, but costs 11.9 MB and a DOMParser in the gallery. |
| both | Alternative (D2). About 20 MB, and two artefacts from one tool. |
| one bundle for every example | Rejected. 8.4 MB downloads before the first example shows. |
| the source inlined in each example's own page | Rejected. Every example load would pay for it, pane open or not. |

### Which files
See §2.1 and D1.

### Layout
| approach | verdict |
|---|---|
| **a pane under the example, with a draggable divider** | **TAKEN.** It is what was asked. Examples are landscape (most ask for 800×450), so a wide, short frame loses little. |
| code to the right | Rejected. It would put a 16:9 example in a portrait-shaped frame, and the list already takes the left. |
| a toggle between the example and the code | Rejected. "At the same time" is the whole ask. |
| code overlaid on the example | Rejected. |

### Line numbers
| approach | verdict |
|---|---|
| **one row per line, numbered by a CSS counter, wrapping on phones** | **PREFERRED** (D4). |
| one number column beside one `<code>` | Alternative (D4). The simplest and a bit faster, but it cannot wrap. |
| no numbers | Alternative (D4). |

### Dev server
| approach | verdict |
|---|---|
| **one thread per accepted connection** | **TAKEN by measurement** (§2.4). |
| `std.Io.Group.concurrent` per connection | Equivalent, and either is fine. Threads are what was measured. |
| `Connection: close` | Measured insufficient. |
| delaying the source fetch until the frame has loaded | Rejected. The frame keeps fetching (runtime, wasm, assets) after `load`, and delaying does nothing about a silent socket. |

---

## 4. The design

### 4.1 Build: `tools/example_source.zig` → `web/<name>/source.json`

A small, std-only host tool, run once per example:

    example_source <name> <out.json> <display-path> <file> [<display-path> <file> ...]

- It does `@import("docfmt.zig")` and calls its `highlightZig`, which becomes `pub`. Nothing else in
  docfmt changes. **One highlighter, one file.** A docfmt mode flag was the alternative, but docfmt's
  header says it does exactly two things, and a third would make it a different tool.
- It reads each file, normalises CRLF → LF, highlights it, and writes this with `std.json` (the
  encoder escapes the `html` string, never hand code):

      {"name":"julia","files":[{"path":"examples/julia/julia.zig","lines":94,"html":"..."}, ...]}

- ★ **It asserts the invariant the gallery depends on: no highlighted span crosses a newline.** Zig
  has no multi-line token (a `\\` string is one token per line, and comments end at the newline), so
  this holds today. The assert keeps it true if WGSL tabs ever arrive (§8), because WGSL block
  comments DO span lines.
- It fails the build on a missing or empty file and names the path. Nothing is skipped silently.

Wiring in `build.zig`:
- The tool is built with the other tools, next to `docfmt_exe`, and `ReleaseSafe` like them.
- The file list is built at configure time. First `examples/<name>/<name>.zig`, then every other
  `*.zig` in `examples/<name>/`, sorted. Then, for each `App.shaders` entry, `examples/<s>.zig` and
  `examples/<s>_io.zig` if it exists. Each file goes in with `addFileArg`, so an edit to any of them
  reruns that example's step and nothing else.
- The step is created in the `wgpu_apps` loop, which has the row and therefore the shaders, and for
  `launcher`. It is installed to `web/<name>/source.json` exactly like the example's `index.html`,
  so `wgpu-<name>`, `all-examples`, `serve` and `dist` all carry it. `finishWgpuApp` takes the
  source list, so its install and its step sit beside the page's.
- Folder walks tolerate a missing folder (`catch`, never `@panic`; this is the Windows configure rule
  in claude.md).

### 4.2 Gallery: `src/web/index.html`, plus the `.g-*` CSS in `docfmt.zig`

Markup inside `.g-main`, after the stage, plus a `code` button in the bar before `open ↗`:

    <div class="g-split" id="split" title="drag to resize, double-click to reset"></div>
    <section class="g-code" id="code" aria-label="source">
        <div class="g-tabs" id="tabs"></div>
        <div class="g-src" id="src" tabindex="0"></div>
    </section>

Behaviour:
- **Pane state.** `body.code-open` shows the pane. The stage becomes
  `flex: 0 0 calc((100% - 44px) * var(--f))` and the pane takes the rest. The default split is 0.58
  for the stage, drags are held between 0.1 and 0.9, and a double-click resets it.
- **Fetch.** The gallery fetches `<name>/source.json` only while the pane is open, inside the SAME
  120 ms debounce as the frame mount, so holding ↓ skims the list without fetching. A request
  counter drops a slow response that lost to a newer pick. Opening the pane later fetches for the
  current example. A missing file shows "No source for <name>." in the pane.
- **Tabs.** One per file, labelled with the basename and line count, with the full path as the
  tooltip. The main file comes first. The code scrolls to the top when the file or the example
  changes.
- **Rows.** `html.split("\n")`, dropping the trailing empty line, one `<span class="l">` per line,
  joined with nothing (a newline between block rows would render as a blank line). The numbers come
  from `counter-increment` on `::before`, so they are never selected or copied.
  `white-space: pre-wrap` applies only under 700 px.
- **Copy.** A `copy` button copies the rows' text joined with `\n`, which is the file exactly
  (verified byte-equal in the prototype). The `html` is trusted build output, escaped by docfmt's
  `escapeInto`. The gallery never builds HTML from source text itself.
- **Divider drag.** Pointer capture on the divider, and `iframe { pointer-events: none }` while
  dragging, or the frame swallows the pointer as soon as the divider crosses it. `touch-action: none`
  makes a finger drag instead of scroll.
- **Keys.** `c` toggles the pane when the gallery has focus (a focused example keeps its keys). With
  focus inside the pane the gallery ignores keys, so ↑↓, PgUp, PgDn and Space scroll the code (§2.3).
- **Remembered per viewer.** Pane open/closed and the split are kept in `localStorage`. Every access
  is wrapped in try/catch (private windows throw), and absent values fall back to the defaults.
- **Default** (D3): open at 700 px wide and above, closed below.
- **Stacking.** The phone drawer (`.g-side`, fixed, z-index 1) must sit above the divider (z-index 2
  in the prototype), so the drawer gets the higher index.

CSS: about 30 lines go into the `.g-*` block of docfmt's `style`, and the prototype's rules are
already written (Appendix A). They use only the existing tokens (`--rule`, `--panel`, `--faint`,
`--tok-fn`), so the "one palette" rule holds.

### 4.3 Dev server: `tools/serve.zig`

- The accept loop spawns a thread per connection (`std.Thread.spawn` + `detach`). The body is the
  current inner loop, moved into `serveConnection`. This is a host tool, so threads are fine;
  claude.md's "no `std.Thread`" is about the browser target.
- ★ **While there, free the per-request buffers.** `handleRequest` allocates the whole file (`raw`)
  and the copy with the HMR script injected, and frees neither, so every wasm served leaks its full
  size. A per-request arena, reset after `respond`, fixes it (touching a fn means bringing the whole
  fn up to spec).
- The header's "One connection at a time is fine" goes, replaced by the reason from §2.4.
- A regression test: factor the loop so a test can run it on port 0 in a thread, open a silent
  socket, request `/` on a second socket, and expect a response within a second. That is §2.4's A/B
  in Zig. Prove it red on the old loop first. It needs a small step, wired into `check` if it stays
  under a second.

### 4.4 What does NOT change
- `manifest.json`. The file list comes from the build, not from a hand-kept field.
- Example pages, `bridgePage`, `zimr.js`, the wasm.
- `doc_gate`. There is still one `<script>` exception, no new `<style>` and no new colour.
- The standalone example pages (`<name>-standalone`). They get no pane; the gallery is the viewer.

---

## 5. Stages

**S0 — the server.** Threads, the per-request arena, the regression test.
*Done when* the test fails on the old loop and passes on the new one, and `zig build serve-only`
serves today's gallery unchanged.

**S1 — one example's `source.json`.** Make `highlightZig` `pub`, add `tools/example_source.zig`, and
wire it for ONE example: `julia`, with 5 files, 4 of them shaders.
*Done when* `zig-out/web/julia/source.json` exists, every `lines` matches its file's line count, each
file's rows joined back equal the file byte for byte, and editing `examples/julia_fs.zig` reruns
only that step.

**S2 — every example.** The `wgpu_apps` loop plus `launcher`.
*Done when* every served `web/<name>/` has a `source.json` (every table row plus `launcher`), the
total is about 8.4 MB, and a warm `zig build` reruns none of those steps.

**S3 — the pane.** Markup, CSS into docfmt, JS.
*Done when* the checklist below passes in a visible desktop tab and at 375×812.

**S4 — docs.** One sentence in `src/web/readme.html` where it points at the gallery, the new tool's
`//!` header (the file atlas reads it), and `zig build files-md` if the atlas lists tools.

### The S3 checklist (the §2 numbers become acceptance bars)
- Try `input_mouse` (1 file), `julia` (5 files), `zimrphysics2d_demo` (3 files, including the
  5 397-line tab), `launcher`, and `comptime_mandelbrot` (no source, so it shows the message).
- The `scenes.zig` tab opens in under ~200 ms, and a typical file in under 20 ms.
- Drag the divider: the example keeps rendering at its new size.
- Hold ↓ through ten examples: no source fetch goes out until the pick settles (network tab).
- Click into the code: ↓ and PgDn scroll it and the example does not change. `c` outside the pane
  toggles it.
- Copy a file and diff it against the source: identical.
- Reload: the pane state and the split come back. In a private window: defaults, no error.
- At 375×812: the bar fits, rows wrap, numbers sit on the first row of a wrapped line, and the drawer
  covers the divider.
- `zig build doc-gate` is green.

---

## 6. Risks and sharp edges
- **Same-origin frame, same event loop.** The example runs on the gallery's own thread, so an example
  that blocks for a second freezes the pane with it. The list already has this problem; the pane
  does not make it worse. It is noted so it is not blamed on the pane.
- **Configure-time folder listing.** A NEW file in an example's folder shows up only after a
  reconfigure, which every `zig build` does anyway. The alternative, the tool reading the folder
  itself, loses exact caching.
- **A shader shared by many examples** (`trivial_vs`) shows in each of their tabs, and editing it
  reruns all their source steps, a few ms each.
- **WGSL** (§8). Block comments break the newline invariant. The tool's assert catches that the
  first time, by design.
- **Big files.** The 5 397-line tab costs 150-200 ms once. If that ever matters,
  `content-visibility: auto` on chunks of rows would help. It is not needed now.

---

## 7. Decisions

### Open — asked one at a time
- **D1 — which files the pane shows.**
  (a) the folder + `App.shaders`, every `.zig` in the example's folder including the four
  `native_verify.zig` checks, plus its shader files **[recommended]**;
  (b) the same, but skipping `native_verify.zig`, so only what runs in the browser;
  (c) the main file only;
  (d) (a) plus the generated WGSL as extra tabs now instead of later.
- **D2 — the payload.** (a) `source.json` only **[recommended]**; (b) standalone `source.html`
  pages; (c) both.
- **D3 — the default state.** (a) open on wide screens, closed on phones, remembered
  **[recommended]**; (b) always closed until toggled; (c) always open.
- **D4 — line numbers.** (a) one row per line with CSS-counter numbers, wrapping on phones
  **[recommended]**; (b) one number column, no wrap; (c) none.

### Settled by the experiments (listed again for the final agreement)
- Highlighting happens at build time through docfmt's `highlightZig`. There is no runtime
  highlighter.
- The pane sits under the example, with a draggable divider.
- `serve.zig` gets a thread per connection (§2.4) and stops leaking per request.
- Keys inside the pane belong to the pane (§2.3), and `c` toggles it.
- The source fetch shares the frame's 120 ms debounce.

---

## 8. Later — not in v1
- **Generated WGSL as extra tabs** for shader and compute examples. Zig and its WGSL side by side is
  a zimr showpiece, and docfmt already has `highlightWgsl`. It needs spans split at newlines (§4.1).
- **Deep links.** `index.html#julia/julia_fs.zig:42` would open the pane on that file and line. Rows
  make this easy.
- **Search that reaches into the code.** The gallery search already covers the manifest's
  `functions` field, which is empty for every example. The same tool could list the `z.*` calls each
  example makes.
- **A "maximize code" toggle** (divider to the top).
- **The folder's non-code files** (`.bvh`, `.xml`, `.png`) as a list under the tabs.

---

## 9. Where things live
- plan: this file
- prototype, generator and server patches: the Sep 27 session scratchpad (gone with the session;
  Appendix A keeps the pane code). `zig-out/web/_proto/` holds its output (gitignored, delete freely).
- touched in v1: `tools/serve.zig`, `tools/docfmt.zig` (one `pub` and the CSS),
  `tools/example_source.zig` (new), `build.zig`, `src/web/index.html`, `src/web/readme.html`

---

## Appendix A — the prototype's pane code (verified in the browser; a starting point, not final)

CSS (goes into docfmt's `style`, `.g-*` block). In the prototype it sat in a page `<style>`, which
the real page may not have:

```css
.g-main{--f:.58;}
.g-stage{flex:1 1 0;}
.code-open .g-stage{flex:0 0 calc((100% - 44px) * var(--f));}
.g-split{display:none;flex:none;height:9px;margin:-4px 0;position:relative;z-index:2;cursor:row-resize;touch-action:none;}
.g-split::after{content:"";position:absolute;left:0;right:0;top:4px;height:1px;background:var(--rule);}
.g-split:hover::after,.dragging .g-split::after{top:3px;height:3px;background:var(--tok-fn);}
.code-open .g-split{display:block;}
.dragging{cursor:row-resize;user-select:none;}
.dragging iframe{pointer-events:none;}
.g-code{display:none;flex:1 1 0;min-height:0;flex-direction:column;background:var(--bg);}
.code-open .g-code{display:flex;}
.g-tabs{flex:none;display:flex;overflow-x:auto;background:var(--panel);border-bottom:1px solid var(--rule);font-size:12px;scrollbar-width:thin;}
.g-tab{
  flex:none;padding:.45em .9em;background:none;color:var(--dim);font:inherit;cursor:pointer;white-space:nowrap;
  border:0;border-right:1px solid var(--rule);border-bottom:2px solid transparent;
}
.g-tab:hover{color:var(--fg);}
.g-tab.on{color:#fff;background:var(--bg);border-bottom-color:var(--tok-fn);}
.g-tab .n{margin-left:.6em;color:var(--faint);font-size:.9em;}
.g-tab.g-copy{margin-left:auto;border-left:1px solid var(--rule);border-right:0;}
.g-src{flex:1;min-height:0;overflow:auto;}
.g-src:focus{outline:none;}
.g-src:focus-visible{outline:1px solid var(--tok-fn);outline-offset:-1px;}
.g-src pre{
  margin:0;padding:8px 0 3em;background:none;border:0;border-radius:0;overflow:visible;
  font-size:12.5px;line-height:1.55;
}
/* one row per source line; the number is a CSS counter, so it is never
   selected or copied, and it stays on the first row of a wrapped line */
.g-src code{display:block;counter-reset:ln;padding:0;}
.g-src .l{display:block;position:relative;min-height:1.55em;padding:0 1.2em 0 calc(4ch + 2.2em);}
.g-src .l::before{
  counter-increment:ln;content:counter(ln);position:absolute;left:0;top:0;bottom:0;
  width:calc(4ch + 1em);padding-right:.9em;box-sizing:border-box;
  text-align:right;color:var(--faint);border-right:1px solid var(--rule);
}
@media(max-width:700px){.g-src .l{white-space:pre-wrap;overflow-wrap:anywhere;}}
.g-src-msg{padding:1em 1.2em;color:var(--faint);}
.g-btn.g-wide{width:auto;padding:0 .7em;font-size:.85em;}
.g-btn.on{color:var(--fg);border-color:var(--tok-fn);}
/* not in the prototype, and needed (§4.2): the phone drawer above the divider */
@media(max-width:700px){.g-side{z-index:3;}}
```

JS (the pane's part; `select()` gains `if (codeOpen) loadSource(ex);` inside its existing mount
timer, and `load()` calls `applyCode()` after `render()`):

```js
// Per-viewer conveniences: pane open/closed and the split. Browser storage can
// throw (private mode, blocked site data), so every access is guarded.
const store = {
    get(k, d) { try { const v = localStorage.getItem("zimr.gallery." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem("zimr.gallery." + k, JSON.stringify(v)); } catch { } },
};
const SPLIT_DEFAULT = 0.58;
let codeOpen = store.get("code", !narrow.matches);
let frac = store.get("split", SPLIT_DEFAULT);
let source = null;      // { name, files: [{ path, lines, html }] } for `current`
let sourceReq = 0;      // a newer pick wins over a slow fetch

function applyCode() {
    document.body.classList.toggle("code-open", codeOpen);
    codeBtn.classList.toggle("on", codeOpen);
    main.style.setProperty("--f", frac.toFixed(4));
    if (codeOpen && current && (!source || source.name !== current.name)) {
        loadSource(current);
    }
}

async function loadSource(ex) {
    if (source && source.name === ex.name) {
        return;
    }
    const req = ++sourceReq;
    tabs.replaceChildren();
    srcBox.innerHTML = `<p class="g-src-msg">loading ${escapeHtml(ex.name)} source…</p>`;
    let files;
    try {
        const r = await fetch(`${ex.name}/source.json`);
        if (!r.ok) {
            throw new Error(`HTTP ${r.status}`);
        }
        files = (await r.json()).files;
    } catch (e) {
        if (req === sourceReq) {
            srcBox.innerHTML = `<p class="g-src-msg">No source for ${escapeHtml(ex.name)}.</p>`;
        }
        return;
    }
    if (req !== sourceReq) {
        return;
    }
    source = { name: ex.name, files };
    tabs.innerHTML = files.map((f, i) =>
        `<button class="g-tab" data-i="${i}" title="${escapeHtml(f.path)}">${escapeHtml(f.path.split("/").pop())}<span class="n">${f.lines}</span></button>`
    ).join("") + `<button class="g-tab g-copy" id="copy" title="copy this file">copy</button>`;
    showFile(0);
}

function showFile(i) {
    const f = source.files[i];
    for (const t of tabs.querySelectorAll(".g-tab[data-i]")) {
        t.classList.toggle("on", +t.dataset.i === i);
    }
    // No highlighted token crosses a newline (Zig has no multi-line tokens),
    // so every line's HTML is balanced and can be its own row.
    const lines = f.html.split("\n");
    if (lines.length > 0 && lines[lines.length - 1] === "") {
        lines.pop();
    }
    srcBox.innerHTML = `<pre><code>${lines.map(l => `<span class="l">${l}</span>`).join("")}</code></pre>`;
    srcBox.scrollTop = 0;
    srcBox.scrollLeft = 0;
}

tabs.addEventListener("click", async e => {
    const t = e.target.closest(".g-tab");
    if (!t || !source) {
        return;
    }
    if (t.id === "copy") {
        const rows = [...srcBox.querySelectorAll(".l")];
        try {
            await navigator.clipboard.writeText(rows.map(r => r.textContent).join("\n") + "\n");
            t.textContent = "copied";
        } catch {
            t.textContent = "copy failed";
        }
        setTimeout(() => { t.textContent = "copy"; }, 1200);
        return;
    }
    showFile(+t.dataset.i);
});

codeBtn.addEventListener("click", () => {
    codeOpen = !codeOpen;
    store.set("code", codeOpen);
    applyCode();
});

// Drag the rule between the example and the code. The frame is made inert
// while dragging, or it swallows the pointer as soon as the rule moves over it.
split.addEventListener("pointerdown", e => {
    e.preventDefault();
    split.setPointerCapture(e.pointerId);
    document.body.classList.add("dragging");
});
split.addEventListener("pointermove", e => {
    if (!split.hasPointerCapture(e.pointerId)) {
        return;
    }
    const top = stage.getBoundingClientRect().top;
    const room = main.getBoundingClientRect().bottom - top;
    frac = Math.min(0.9, Math.max(0.1, (e.clientY - top) / room));
    main.style.setProperty("--f", frac.toFixed(4));
});
const endDrag = () => {
    document.body.classList.remove("dragging");
    store.set("split", frac);
};
split.addEventListener("pointerup", endDrag);
split.addEventListener("pointercancel", endDrag);
split.addEventListener("dblclick", () => {
    frac = SPLIT_DEFAULT;
    store.set("split", frac);
    applyCode();
});

// In the existing keydown handler, before the list keys:
//     if (e.target.closest && e.target.closest(".g-code")) { return; }   // the pane's keys scroll the code
// and one more branch beside j / k:
//     } else if (e.key === "c") { codeBtn.click();
```

---

## Journal
- **Sep 27** — Studied the gallery, docfmt, doc_gate, serve and the example registry. Measured the
  three file-list rules over all 304 examples. Built the pane prototype and ran it in the browser at
  desktop and phone sizes. Found the dev-server stall and A/B'd three servers, and found and fixed
  the key conflict. Plan written; D1 goes first.
