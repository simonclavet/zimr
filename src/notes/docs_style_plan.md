# docs style plan — one palette, one highlighter, one fold

**The goal: every published page is white on black, self-contained, and highlighted by the same
code.** Today there are five palettes, four font stacks, three highlighters and two pages that
fetch fonts from Google. None of that is a design decision anyone made; it is eleven pages each
styled in the turn that created it.

---

## 1. What we have, measured

Every number below came from the tree this session, not from memory.

| page | installed | theme | `<pre>` | classed | highlighter | folds |
|---|---|---|---|---|---|---|
| `src/web/readme.html` | yes | `#1f140e` sepia | 24 | 19 | **build-time, `tools/highlight.zig`** | 0 |
| `src/web/index.html` | yes | `#020617` | 0 | 0 | — | 0 |
| `src/web/tutorial.html` | yes | `#1f140e` sepia | 12 | 0 | hand spans (145) | 0 |
| `tutorials/robots.html` | yes | `#1f140e` sepia | **98** | **0** | hand spans (107) | 0 |
| `tutorials/zimrnum-tutorial.html` | yes | `#1a1a1a` on white | **469** | **0** | hand spans (431) | **276** |
| `tutorials/gpu-compute-tutorial.html` | yes | `#eef1f5` light paper | 22 | 22 | JS, 56-line fork | 0 |
| `tutorials/wgpu-ports-tutorial.html` | yes | `#1f140e` sepia | 14 | 14 | JS, 22-line fork | 0 |
| `tutorials/rtt-tutorial.html` | yes | `#1f140e` sepia | 9 | 9 | JS, 22-line fork | 0 |
| `tutorials/mujoco-tutorial.html` | yes | `#1f140e` sepia | 2 | 0 | hand spans (26) | 0 |
| `tutorials/shader_authoring_tutorial.html` | yes | `#0d1117` GitHub dark | 5 | 0 | hand spans (71) | 0 |
| `cheatsheet.html` | yes | `#0b0b0c` | 0 | 0 | hand spans (296) | 0 |
| `src/notes/retarget_tutorial.html` | **no** | `#1a1a1a` on white | 0 | 0 | — | 0 |

**Five palettes.** `#1f140e` sepia (6 pages), `#eef1f5` light paper, `#1a1a1a`-on-white (2),
`#0d1117` GitHub dark, `#0b0b0c`/`#020617` near-black (2). Under five different variable
vocabularies: `--bg-page/--text-color`, `--paper/--ink`, `--ink/--fg`, `--bg/--fg`, `--bg/--text`.
A rule copied from one page to another does not even parse in the next.

**Three highlighters, and the best one runs on one page.**

- `tools/highlight.zig` (206 lines) decodes each `<pre><code class="language-zig">` back to real
  Zig, tokenizes with **`std.zig.Tokenizer`**, and re-emits `tok-kw` / `tok-builtin` / `tok-str` /
  `tok-num` / `tok-comment`. Build-time, so the served page is pure HTML+CSS with **zero runtime
  JS**. Wired into the `readme.html` install and **nothing else**.
- A hand-rolled JS regex tokenizer, copy-pasted and then drifted into **two forks**: 56 lines in
  `gpu-compute-tutorial.html`, a stripped 22-line version byte-identical across `rtt-tutorial` and
  `wgpu-ports-tutorial`. Emits `t-kw`/`t-fn`/`t-cm`/`t-str`/`t-num`/`t-type`/`t-at` — a different
  class vocabulary from the Zig tool's, for the same job.
- Hand-authored `<span>`s: 1 076 of them across six pages, which is 1 076 chances to mis-tag a
  keyword inside a comment.

**567 of ~700 code blocks are not machine-highlighted at all** — `robots.html`'s 98 and
`zimrnum-tutorial`'s 469 are bare `<pre><code>` containing real Zig.

**Two pages fetch Google Fonts** (`gpu-compute`, `shader_authoring`): Space Grotesk, Lora,
JetBrains Mono, plus `gstatic` preconnects. In a repo whose readme opens with "There are no
third-party libraries," the docs reach across the network for their typeface.

**One page is generated.** `tools/zimrnum_ref.zig:942-1105` writes the
`<div class="zn-source">…<details><summary><code>NAME</code></summary><pre class="zn-code">`
regions — all 276 folds. And `src/zimrnum.zig:24625` `@embedFile`s the finished page for a test.

---

## 2. The target, in one paragraph

**White on black, one stylesheet, injected at build time, no runtime JS, no network.** Every
published page opens standalone from a phone, a `file://` URL or the server and looks identical.
Code is highlighted by Zig's own tokenizer. Long blocks fold. A page's CSS is not its own business
any more.

Five properties, each checkable:

1. **One palette.** `grep` finds no hex colour in any page's body — only in the shared block.
2. **One highlighter.** Zero `<script>` in any doc page; zero hand-authored token spans.
3. **One fold idiom.** `<details>`/`<summary>`, pure CSS, no JS, works in every page.
4. **No network.** Zero `fonts.googleapis`, zero `<link rel=stylesheet>`, zero external anything.
5. **Self-contained.** Each installed page is one file. Deleting every other file leaves it
   readable.

---

## 3. The mechanism decision, made up front

**Shared external `doc.css` — REJECTED.** It is the obvious answer and it is wrong here. The
pages live in three directories in the repo (`src/web/`, `src/notes/tutorials/`, root) and land
flat in `zig-out/web/`, so one relative href cannot be right in both places. Worse, it ends the
property that matters most on a phone: a page you can open by itself.

**Build-time injection — TAKEN.** Extend the tool that already does exactly this for one page.
`tools/highlight.zig` becomes `tools/docfmt.zig`: a stdin→stdout filter that replaces a marker
with the shared `<style>` block and highlights every classed code block. `build.zig` already pipes
`readme.html` through it (`hl.setStdIn` / `captureStdOut`); the change is to run the same filter
over all eleven installed pages instead of one.

★ The shared CSS lives in **one Zig string constant** inside `docfmt.zig`. Not a file to keep in
sync, not eleven copies — one `const style =`, and the only way to change a colour is to change
it there.

---

## 4. The work, in order

### Stage 0 — decide the palette and the token set (one turn, no code)

Write the final block as a constant and look at one page rendered with it before touching ten
more. Proposed, starting from the token colours `gpu-compute` already uses, which were picked for
a dark ground and survive on pure black:

    background   #000000        comment   #6b7a8c  (italic)
    text         #ffffff        keyword   #c792ea
    dim text     #9aa0a8        function  #82d8ef
    rule         #262626        string    #9ad08a
    code ground  #0d0d0d        number    #f5a35e
    link         #82d8ef        type      #6fb6ff
                                builtin   #e9a23b

Fonts: one system mono for code, one system serif or sans for prose, **both from the stack that
ships on the device**. No download. `ui-monospace, "SF Mono", "Cascadia Mono", Menlo, monospace`
covers every platform Simon reads on.

**Done when** one page — `rtt-tutorial`, the smallest real one at 9 blocks — renders in the new
palette and Simon says yes to a screenshot.

### Stage 1 — `tools/docfmt.zig` (the whole mechanism)

Rename and extend `highlight.zig`. Four changes:

1. Accept `class="zig"` as well as `class="language-zig"`, so the JS-fork pages need no rewrite.
2. Add a `wgsl` mode. The Zig tokenizer is wrong for WGSL, but WGSL's keyword set is small and the
   lexical shape is C-like; a second small tokenizer in the same file beats a regex in ten pages.
3. Replace a `<!--docfmt:style-->` marker with the shared `<style>` block.
4. Unify the class names: emit `tok-*` everywhere, delete `t-*`.

**Done when** `docfmt < any-page.html` produces a page with one `<style>`, no `<script>`, and
every `<pre><code class=zig>` highlighted — and `zig build readme` still produces the page it
produces today except in colour.

### Stage 2 — run it over everything, strip the per-page CSS

`build.zig`: the eleven-entry install list stops using `addInstallFileWithDir` directly and pipes
each page through `docfmt`. Then, per page, delete the `:root` block and every rule the shared
sheet now provides, leaving the `<!--docfmt:style-->` marker.

This is the bulk of the diff and it is mechanical. Order by size, smallest first, so the pattern
is proven on cheap pages: `rtt` (23 KB) → `shader_authoring` (24 KB) → `mujoco` (38 KB) →
`retarget` (38 KB) → `gpu-compute` (59 KB) → `wgpu-ports` (66 KB) → `tutorial` (71 KB) →
`cheatsheet` (100 KB) → `readme` (128 KB) → `robots` (223 KB) → `zimrnum` (998 KB).

★ **Delete the Google Fonts `<link>`s in the same edit** as the page that carries them. They are
two lines and they are the only network dependency in the docs.

**Done when** `grep -c '#[0-9a-fA-F]\{6\}'` over every page body is 0 outside the marker.

### Stage 3 — retrofit the code-block class (the 567)

`robots.html` is 98 bare `<pre><code>` blocks of real Zig — a mechanical
`<pre><code>` → `<pre><code class="zig">`. `zimrnum-tutorial`'s ~193 hand blocks are the same
edit. Then delete the hand-authored spans those pages carry, because the tokenizer now does that
work and a leftover span fights it.

★ **Check the language before classing the block.** Some `<pre>` blocks are shell, ASCII diagrams,
or MJCF XML — `highlight.zig`'s header already says those must pass through byte-for-byte. A
diagram tagged `zig` comes out speckled.

**Done when** every `<pre><code>` in the tree either carries a language class or is provably not
code.

### Stage 4 — delete the two JS forks

Once Stage 1 highlights their blocks at build time, the `<script>` in `gpu-compute`, `rtt` and
`wgpu-ports` is dead. Remove all three. Keep `gpu-compute`'s reveal-on-scroll only if Simon wants
it; it is the single remaining piece of JS in the docs and "simplest possible" argues against it.

**Done when** `grep -c '<script'` across all installed pages is 0.

### Stage 5 — folds everywhere

The `<details>` idiom is pure HTML+CSS and already proven at 276 instances. Two applications:

- **Generated:** `tools/zimrnum_ref.zig:1103` hard-codes `<pre class="zn-code">`. Change it to the
  shared class in the generator, never in the output, then `zig build zimrnum-ref` to re-emit.
- **By hand:** wrap any block over ~25 lines in `<details><summary>` across `robots.html` (98
  blocks, many long) and the rest. The summary names what the block is, so a reader skims
  structure and opens only what they want.

★ zimrnum's `summary::before { content: "source of " }` is the right trick — the summary text is
just the symbol name and the prose comes from CSS. Keep it in the shared sheet.

**Done when** no page presents more than one screen of unfolded code without a heading.

### Stage 6 — a gate, so it cannot drift back

A check step that fails the build on any installed page that: contains `<script>`, contains a
literal hex colour, contains `fonts.googleapis`, contains a `<pre><code>` with no language class,
or is missing the `<!--docfmt:style-->` marker. Five greps.

★★ **This is the stage that makes the other five permanent.** Every finding in §1 exists because
nothing checked. A style rule with no gate is a preference, and the next page will be styled in
the turn that creates it, exactly like these eleven were.

**Done when** planting each of the five violations turns the build red, one at a time.

---

## 5. What must not break

- **`src/zimrnum.zig:24625` `@embedFile`s `zimrnum-tutorial.html`** and a test reads the reference
  table out of it. Any structural edit to that page can fail a unit test that names no CSS.
  Run `zig build test-fast -Dtest-filter=` on the relevant test after touching it.
- **`zimrnum-tutorial.html` is partly GENERATED.** Everything between `<div class="zn-source">` and
  `</div><!--/zn-source-->` belongs to `tools/zimrnum_ref.zig`. Edit the generator; a hand edit is
  erased by the next `zig build zimrnum-ref`, silently.
- **`readme.html` carries a live `<iframe src="launcher/index.html">`.** It is the front page's
  whole point. Restyling must not touch it.
- **`readme.html`'s content is load-bearing** — claude.md's "First thing each session" says read
  it, and every path/type/namespace it names is kept current. This plan changes its **appearance
  only**. No prose edits ride along.
- **`retarget_tutorial.html` is not in the install list.** Either add it in Stage 2 or leave it
  internal — but decide, rather than leaving it the one page nobody restyles.

---

## 6. Decisions — MADE

1. **Softer, not literal.** `#e8e8e8` on `#0a0a0a`.
2. **`gpu-compute-tutorial` keeps its CPU/GPU split**, recoloured to the shared palette: the
   host side is `--bg`, the device side is `--panel`. The split survives as a teaching device
   without a palette of its own.
3. **Mono throughout**, prose included, from the system stack. No download.
4. **`cheatsheet.html` is in scope.**
5. **`retarget_tutorial.html` stays internal**, unpublished.
6. **The file atlas gets an HTML version** — added after the fact, and now `zig build files-html`.

---

## 7. What landed, and what is left

**Stage 0-2 — done.** `tools/docfmt.zig` replaces `tools/highlight.zig`. One `const style`
constant, taken by a `<!--docfmt:style-->` marker in each page at install time. All twelve pages
carry it; none carries its own CSS; the two Google Fonts pages fetch nothing. `zig build
doc-pages` runs green in 16s.

★ **`index.html`'s `<script>` is the gallery's manifest filter and search — application code.**
The first migration pass stripped `<script>` from every page and silently broke it. The keep-list
in `scripts/docs_restyle.py` and the `script_ok` array in `tools/doc_gate.zig` both name it now.

**Stage 3 — done.** 416 bare `<pre><code>` blocks classed (`robots.html` 56, `zimrnum-tutorial`
359, `mujoco` 1), guarded twice: it must look like Zig, and it must contain no nested tag.
docfmt HTML-decodes and re-escapes a block's contents, so a nested `<span>` would come out as
visible text.

**Stage 4 — done, with one deliberate exception.** `tutorial.html`'s 12 blocks had pure-syntax
spans: stripped, classed, tokenized. `shader_authoring_tutorial.html`'s 5 blocks carry SEMANTIC
spans — `hazard` marks the hand-counted integers the page is about, `hl-old`/`hl-new` mark the
two paths it contrasts — so those blocks keep their spans and stay out of the tokenizer. Their
73 syntax spans were renamed onto the shared `tok-*` vocabulary instead, so there is still only
one set of token colours in the tree.

**Stage 5 — NOT done.** `robots.html`'s 98 blocks are classed but unfolded. The `<details>`
idiom, the `.src-fold` rule and the generator's emit are all in place; what remains is wrapping
the long blocks and writing a summary line for each, which is editorial work rather than
mechanical.

**Stage 6 — done.** `tools/doc_gate.zig`, wired into `zig build check` and standalone as
`zig build doc-gate`. Four properties: exactly one marker, no `<style>`, no `<script>` (except
the named gallery), no webfont fetch. Each was planted one at a time and confirmed to turn the
build red.

★ The fifth property the plan originally wanted — "every code block carries a language class" —
is deliberately NOT gated. Shell transcripts, MJCF and the ASCII pipeline diagrams live in bare
`<pre><code>` too, and a diagram tagged `zig` comes out speckled. Classing them is a judgement,
so it stays a judgement rather than becoming a rule that forces a wrong answer.
