//! docfmt - build-time formatter for every published zimr doc page.
//!
//! A plain stdin -> stdout filter, run from build.zig over each page in the web
//! install list.  It does exactly two things:
//!
//!   1. Replaces the `<!--docfmt:style-->` marker with THE shared stylesheet -
//!      the single `style` constant below.  There is no doc.css: the pages live
//!      in three directories in the repo and land flat in zig-out/web, so one
//!      relative href cannot be correct in both places, and an external sheet
//!      would end the property that matters most on a phone - a page you can
//!      open by itself.  One constant, eleven pages, no copies to drift.
//!
//!   2. Highlights every `<code class="zig">`, `<code class="language-zig">` and
//!      `<code class="wgsl">` block.  Zig goes through std.zig.Tokenizer - Zig's
//!      own lexer, so a keyword inside a comment or a string can never be
//!      mis-tagged.  WGSL gets the small tokenizer at the bottom of this file.
//!      Everything else - prose, shell blocks, MJCF, the ASCII pipeline diagrams
//!      in bare `<pre><code>` - passes through byte-for-byte.
//!
//! On brand: the highlighting happens at BUILD time, so every served page is
//! pure HTML+CSS with zero runtime JS and zero network fetches.  This replaces
//! tools/highlight.zig (which did (2) for Zig, on readme.html alone) and the two
//! drifted forks of a hand-rolled JS regex tokenizer that lived inline in
//! gpu-compute-tutorial, rtt-tutorial and wgpu-ports-tutorial.
//!
//! Usage: `docfmt < page.html > page.out.html`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const File = std.Io.File;
const Token = std.zig.Token;
const Tag = std.zig.Token.Tag;

const style_marker = "<!--docfmt:style-->";

/// THE stylesheet.  Every published page gets exactly this and nothing else, so
/// changing a colour here changes it everywhere.  Softer than pure white on
/// pure black, which is punishing on a 3000-line page like robots.html.
///
/// Two surfaces, and only two: `--bg` is the page, `--panel` is anything set
/// apart from it - a code block, a callout, the GPU side of a CPU/GPU split.
/// The split in gpu-compute-tutorial stays; it is a teaching device. It just
/// uses these two values now instead of a light-paper/dark-slate palette of
/// its own.
const style =
    \\<style>
    \\:root{
    \\  /* two surfaces, one ink */
    \\  --bg:#0a0a0a;          /* the page */
    \\  --panel:#141414;       /* anything set apart: code, callout, device side */
    \\  --panel-2:#1b1b1b;     /* a panel on a panel (figcaption, summary) */
    \\  --fg:#e8e8e8;          /* body text */
    \\  --dim:#9aa0a8;         /* secondary text, captions */
    \\  --faint:#6b7280;       /* labels, line numbers, table headers */
    \\  --rule:#262626;        /* every border in the document */
    \\  --link:#82d8ef;
    \\  /* tokens — the one set, shared by the Zig and WGSL highlighters */
    \\  --tok-comment:#6b7a8c;
    \\  --tok-kw:#c792ea;
    \\  --tok-fn:#82d8ef;
    \\  --tok-str:#9ad08a;
    \\  --tok-num:#f5a35e;
    \\  --tok-type:#6fb6ff;
    \\  --tok-builtin:#e9a23b;
    \\  /* one font: mono, from whatever ships on the device. No download. */
    \\  --mono:ui-monospace,"SF Mono","Cascadia Mono","Segoe UI Mono",Menlo,Consolas,monospace;
    \\  --maxw:860px;
    \\}
    \\*{box-sizing:border-box;}
    \\html{-webkit-text-size-adjust:100%;}
    \\body{
    \\  margin:0 auto;padding:2.2rem 1.1rem 6rem;max-width:var(--maxw);
    \\  background:var(--bg);color:var(--fg);
    \\  font-family:var(--mono);font-size:15px;line-height:1.65;
    \\}
    \\h1,h2,h3,h4{font-family:var(--mono);font-weight:700;line-height:1.25;margin:2.2em 0 .7em;}
    \\h1{font-size:1.6rem;margin-top:0;}
    \\h2{font-size:1.25rem;border-bottom:1px solid var(--rule);padding-bottom:.35em;}
    \\h3{font-size:1.05rem;}
    \\h4{font-size:.95rem;color:var(--dim);}
    \\p{margin:0 0 1.1em;}
    \\a{color:var(--link);text-decoration:none;border-bottom:1px solid var(--rule);}
    \\a:hover{border-bottom-color:var(--link);}
    \\strong,b{color:#fff;font-weight:700;}
    \\em,i{color:var(--dim);font-style:italic;}
    \\hr{border:0;border-top:1px solid var(--rule);margin:2.4em 0;}
    \\small,.dim{color:var(--dim);font-size:.87em;}
    \\.faint{color:var(--faint);}
    \\ul,ol{margin:0 0 1.1em;padding-left:1.5em;}
    \\li{margin:.3em 0;}
    \\blockquote{margin:1.2em 0;padding:.1em 0 .1em 1em;border-left:2px solid var(--rule);color:var(--dim);}
    \\/* code */
    \\pre{
    \\  margin:1.1em 0;padding:14px 16px;background:var(--panel);
    \\  border:1px solid var(--rule);border-radius:3px;
    \\  overflow-x:auto;font-size:13px;line-height:1.6;
    \\}
    \\pre,code,kbd,samp{font-family:var(--mono);}
    \\pre code{background:none;padding:0;border:0;font-size:inherit;color:var(--fg);}
    \\code{background:var(--panel);padding:.1em .35em;border-radius:2px;font-size:.92em;color:#fff;}
    \\.tok-comment{color:var(--tok-comment);font-style:italic;}
    \\.tok-kw{color:var(--tok-kw);}
    \\.tok-fn{color:var(--tok-fn);}
    \\.tok-str{color:var(--tok-str);}
    \\.tok-num{color:var(--tok-num);}
    \\.tok-type{color:var(--tok-type);}
    \\.tok-builtin{color:var(--tok-builtin);}
    \\/* a captioned code block: <figure class="code"><figcaption>… */
    \\figure{margin:1.3em 0;}
    \\figure.code{margin:1.3em 0;}
    \\figure.code figcaption{
    \\  background:var(--panel-2);border:1px solid var(--rule);border-bottom:0;
    \\  border-radius:3px 3px 0 0;padding:6px 12px;font-size:11.5px;color:var(--faint);
    \\  display:flex;justify-content:space-between;gap:1em;
    \\}
    \\figure.code figcaption .lang{color:var(--dim);text-transform:uppercase;letter-spacing:.16em;}
    \\figure.code pre{margin:0;border-radius:0 0 3px 3px;}
    \\/* folds — pure CSS, no JS. The summary text is just the name; the prose
    \\   comes from ::before, which is zimrnum-tutorial's trick and a good one. */
    \\details{border:1px solid var(--rule);border-radius:3px;margin:.5em 0;background:var(--panel);}
    \\details[open]{background:var(--bg);}
    \\summary{
    \\  cursor:pointer;padding:.4em .8em;color:var(--dim);font-size:.9em;
    \\  list-style:none;user-select:none;
    \\}
    \\summary::-webkit-details-marker{display:none;}
    \\summary::before{content:"\\25b8\\00a0";color:var(--faint);}
    \\details[open]>summary::before{content:"\\25be\\00a0";}
    \\summary:hover{color:var(--fg);}
    \\details>pre{margin:0;border:0;border-top:1px solid var(--rule);border-radius:0;}
    \\.src-fold>summary::after{content:" \\2014 source";color:var(--faint);}
    \\/* callouts — one box, a coloured left rule says which kind */
    \\.note,.warn,.good,.bad{
    \\  margin:1.2em 0;padding:.7em 1em;background:var(--panel);
    \\  border:1px solid var(--rule);border-left-width:3px;border-radius:3px;
    \\}
    \\.note{border-left-color:var(--tok-fn);}
    \\.warn{border-left-color:var(--tok-builtin);}
    \\.good{border-left-color:var(--tok-str);}
    \\.bad{border-left-color:#e0555f;}
    \\/* tables */
    \\table{border-collapse:collapse;width:100%;margin:1.2em 0;font-size:13px;}
    \\th,td{border:1px solid var(--rule);padding:.45em .7em;text-align:left;vertical-align:top;}
    \\th{color:var(--faint);font-weight:700;background:var(--panel);}
    \\/* the CPU/GPU split: two surfaces, same two colours as everything else */
    \\.split{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:1.3em 0;}
    \\.split>*{min-width:0;}
    \\.split-cpu,.split-gpu{border:1px solid var(--rule);border-radius:3px;padding:2px;}
    \\.split-cpu{background:var(--bg);}
    \\.split-gpu{background:var(--panel);}
    \\.split-cpu>pre,.split-gpu>pre{margin:0;border:0;background:none;}
    \\.split h4,.split .lab{
    \\  margin:.2em 0 .4em;padding:4px 10px;font-size:11px;letter-spacing:.16em;
    \\  text-transform:uppercase;color:var(--faint);border-bottom:1px solid var(--rule);
    \\}
    \\@media(max-width:700px){.split{grid-template-columns:1fr;}}
    \\/* media */
    \\img,svg,canvas,video{max-width:100%;height:auto;}
    \\iframe{max-width:100%;border:1px solid var(--rule);border-radius:3px;background:#000;}
    \\/* a live demo embedded in a page: the full column, 16:9. Without a size the
    \\   frame is the browser default 300x150 and the app boots that small. */
    \\.demo-embed{margin:1.6em 0;}
    \\.demo-embed iframe{display:block;width:100%;aspect-ratio:16/9;}
    \\.demo-embed figcaption{color:var(--dim);font-size:.9em;margin-top:.5em;}
    \\/* Inline marks the pages already use, mapped onto the SAME token colours
    \\   rather than given colours of their own — cheatsheet's signature rows,
    \\   the reference tables, and the two semantic marks that carry teaching
    \\   weight in shader-authoring (`hazard` = the hand-counted integer, and the
    \\   old/new path contrast). One palette, reused. */
    \\.sig{margin:1.2em 0 .2em;padding-top:.8em;border-top:1px solid var(--rule);}
    \\.k{color:var(--tok-kw);}
    \\.nm{color:var(--tok-fn);font-weight:700;}
    \\.ns{color:var(--faint);}
    \\.eq{color:var(--dim);}
    \\.doc{color:var(--dim);margin:.2em 0 .6em;}
    \\.num,.n{color:var(--tok-num);}
    \\.host,.lab,.lang,.path,.tag,.stage,.sec-num,.lesson-num{
    \\  color:var(--faint);font-size:.85em;letter-spacing:.12em;text-transform:uppercase;
    \\}
    \\.anchor{border:0;color:var(--faint);opacity:0;padding-left:.4em;}
    \\h1:hover .anchor,h2:hover .anchor,h3:hover .anchor{opacity:1;}
    \\.chip{
    \\  display:inline-block;padding:.05em .5em;margin:0 .15em;border:1px solid var(--rule);
    \\  border-radius:2px;color:var(--dim);font-size:.82em;
    \\}
    \\.chip.on{color:var(--fg);border-color:var(--tok-fn);}
    \\.hazard{color:#e0555f;font-weight:700;}
    \\.hl-old{color:var(--tok-builtin);}
    \\.hl-new{color:var(--tok-fn);}
    \\.yes,.good-mark{color:var(--tok-str);}
    \\.callout{
    \\  margin:1.2em 0;padding:.7em 1em;background:var(--panel);
    \\  border:1px solid var(--rule);border-left:3px solid var(--tok-fn);border-radius:3px;
    \\}
    \\.zn-source{margin:.6em 0 1.4em;}
    \\.lesson{margin:2em 0;}
    \\.lesson-title{font-weight:700;color:#fff;}
    \\.lesson-goal{color:var(--dim);}
    \\/* page furniture: the landing page and the tutorials' own scaffolding */
    \\.blog-container,.wrap,.max{max-width:var(--maxw);margin:0 auto;}
    \\.title{font-size:1.8rem;margin:0 0 .2em;}
    \\.subtitle,.lede,.sub{
    \\  border:0;font-size:1rem;font-weight:400;color:var(--dim);
    \\  margin:0 0 1.6em;line-height:1.6;
    \\}
    \\.eyebrow{color:var(--faint);font-size:.85em;letter-spacing:.14em;text-transform:uppercase;}
    \\.toplinks{
    \\  display:flex;flex-wrap:wrap;gap:.1em 1.1em;margin:0 0 2em;
    \\  padding:.9em 0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule);
    \\  font-size:.88em;
    \\}
    \\.toplinks a{border:0;color:var(--dim);}
    \\.toplinks a:hover,.toplinks a.offsite{color:var(--link);}
    \\.wip-warning{
    \\  margin:0 0 2em;padding:.8em 1em;background:var(--panel);
    \\  border:1px solid var(--rule);border-left:3px solid var(--tok-builtin);border-radius:3px;
    \\  color:var(--dim);font-size:.9em;
    \\}
    \\.wip-warning strong{display:block;color:var(--tok-builtin);margin-bottom:.2em;}
    \\/* cheatsheet: one declaration per .fn row */
    \\.fn{margin:1.1em 0;}
    \\.what,.body{color:var(--dim);}
    \\.sketch{color:var(--dim);}
    \\.pane{border:1px solid var(--rule);border-radius:3px;margin:1.1em 0;}
    \\.pane-head{
    \\  padding:5px 11px;background:var(--panel-2);border-bottom:1px solid var(--rule);
    \\  color:var(--faint);font-size:11.5px;letter-spacing:.12em;text-transform:uppercase;
    \\}
    \\.cell{padding:.5em .8em;}
    \\.swatch{display:inline-block;width:.9em;height:.9em;border:1px solid var(--rule);vertical-align:-1px;}
    \\.old,.meh{color:var(--tok-builtin);}
    \\.new,.win{color:var(--tok-str);}
    \\.crit{
    \\  margin:1.2em 0;padding:.7em 1em;background:var(--panel);
    \\  border:1px solid var(--rule);border-left:3px solid #e0555f;border-radius:3px;
    \\}
    \\/* The examples gallery (index.html): the list of examples on the left, the
    \\   selected one running in a frame that fills the rest. On a phone the list
    \\   is a drawer over the example, under the bar. `list-open` shows the list. */
    \\body.gallery{
    \\  max-width:none;margin:0;padding:0;height:100vh;height:100dvh;overflow:hidden;
    \\  display:grid;grid-template-columns:1fr;grid-template-rows:minmax(0,1fr);
    \\  color-scheme:dark;
    \\}
    \\body.gallery.list-open{grid-template-columns:minmax(240px,25%) 1fr;}
    \\.gallery a{border:0;}
    \\.g-side{display:none;flex-direction:column;min-height:0;background:var(--bg);border-right:1px solid var(--rule);}
    \\.list-open .g-side{display:flex;}
    \\.g-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:0 1em;padding:.7em 1em .6em;font-size:.85em;}
    \\.g-head a{color:var(--dim);}
    \\.g-head a:hover{color:var(--link);}
    \\.g-head .g-logo{margin-right:auto;font-size:1.1rem;font-weight:700;color:var(--fg);white-space:nowrap;}
    \\.g-filters{display:flex;flex-wrap:wrap;gap:.4em;padding:0 1em;}
    \\.g-filters input,.g-filters select{
    \\  min-width:0;padding:.35em .5em;background:var(--panel);color:var(--fg);
    \\  border:1px solid var(--rule);border-radius:3px;font:inherit;font-size:.85em;
    \\}
    \\.g-filters input{flex:1 1 10em;}
    \\.g-filters select{flex:1 1 auto;}
    \\.g-filters input:focus,.g-filters select:focus{outline:none;border-color:var(--tok-fn);}
    \\.g-count{padding:.45em 1em;color:var(--faint);font-size:.75em;border-bottom:1px solid var(--rule);}
    \\.g-list{flex:1;overflow-y:auto;padding-bottom:3em;font-size:13px;}
    \\.g-group{
    \\  position:sticky;top:0;padding:.8em 1em .3em;background:var(--bg);
    \\  color:var(--faint);font-size:.8em;letter-spacing:.14em;text-transform:uppercase;
    \\}
    \\/* scroll-margin: scrolled into view, a row clears the sticky module heading */
    \\.g-item{
    \\  display:flex;justify-content:space-between;gap:.6em;padding:.15em 1em;
    \\  color:var(--dim);border-left:2px solid transparent;scroll-margin-top:2.4em;
    \\}
    \\.g-item:hover{color:var(--fg);background:var(--panel);}
    \\.g-item.on{color:#fff;background:var(--panel-2);border-left-color:var(--tok-fn);}
    \\.g-item span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    \\.g-stars{color:var(--faint);font-size:.8em;white-space:nowrap;}
    \\.g-none{padding:1em;color:var(--faint);}
    \\.g-main{display:flex;flex-direction:column;min-width:0;min-height:0;}
    \\.g-bar{
    \\  flex:none;display:flex;align-items:center;gap:.4em;height:44px;padding:0 .6em;
    \\  border-bottom:1px solid var(--rule);white-space:nowrap;
    \\}
    \\.g-btn{
    \\  flex:none;width:30px;height:30px;padding:0;background:var(--panel);color:var(--dim);
    \\  border:1px solid var(--rule);border-radius:3px;font:inherit;cursor:pointer;
    \\}
    \\.g-btn:hover{color:var(--fg);border-color:var(--tok-fn);}
    \\.g-title{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;padding-left:.4em;}
    \\.g-desc{margin-left:.6em;color:var(--dim);font-size:.9em;}
    \\.g-open{flex:none;padding:0 .4em;font-size:.9em;}
    \\.g-stage{flex:1;position:relative;min-height:0;}
    \\.g-stage iframe{position:absolute;inset:0;width:100%;height:100%;max-width:none;border:0;border-radius:0;}
    \\.g-intro{max-width:36em;margin:12vh auto 0;padding:0 1.5em;}
    \\@media(max-width:700px){
    \\  body.gallery.list-open{grid-template-columns:1fr;}
    \\  .g-side{position:fixed;inset:44px 0 0 0;z-index:1;border-right:0;}
    \\  .g-item{padding:.45em 1em;}
    \\  .g-desc{display:none;}
    \\}
    \\/* A tutorial pointer, sitting directly under the heading whose subject it
    \\   covers rather than pooled in a list at the foot of the page. */
    \\.tut{
    \\  margin:.2em 0 1.3em;padding:.55em .9em;background:var(--panel);
    \\  border:1px solid var(--rule);border-left:3px solid var(--tok-fn);border-radius:3px;
    \\  color:var(--dim);font-size:.9em;
    \\}
    \\.tut a{color:var(--link);border:0;font-weight:700;}
    \\.tut-index{list-style:none;padding-left:0;}
    \\.tut-index li{padding:.25em 0;border-bottom:1px solid var(--rule);}
    \\.tut-index a{border:0;}
    \\/* `.reveal` was animated in by the JS that docfmt replaced; without a rule
    \\   it is simply visible, which is the correct end state. */
    \\@media(max-width:700px){body{font-size:14px;padding:1.4rem .8rem 4rem;}pre{font-size:12px;}}
    \\</style>
;

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;

    const src: []u8 = try readAllStdin(gpa, io);

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;

    try transform(gpa, w, src);

    try File.stdout().writeStreamingAll(io, aw.written());
}

/// Which highlighter a `<code class="...">` value selects.  An unrecognised class
/// means "not code we know", and the block passes through untouched - that is
/// what keeps shell blocks and ASCII diagrams from coming out speckled.
const Lang = enum { zig, wgsl };

fn langOf(class: []const u8) ?Lang {
    if (std.mem.eql(u8, class, "zig")) {
        return .zig;
    }
    if (std.mem.eql(u8, class, "language-zig")) {
        return .zig;
    }
    if (std.mem.eql(u8, class, "wgsl")) {
        return .wgsl;
    }
    if (std.mem.eql(u8, class, "language-wgsl")) {
        return .wgsl;
    }
    return null;
}

fn transform(gpa: Allocator, w: *Writer, src: []const u8) !void {
    const code_open: []const u8 = "<code class=\"";
    var i: usize = 0;
    while (i < src.len) {
        // Whichever comes first: the style marker or the next classed code block.
        const marker_at: ?usize = std.mem.indexOfPos(u8, src, i, style_marker);
        const code_at: ?usize = std.mem.indexOfPos(u8, src, i, code_open);

        const next: usize = @min(
            marker_at orelse src.len,
            code_at orelse src.len,
        );
        if (next == src.len) {
            break;
        }
        try w.writeAll(src[i..next]);

        if (marker_at != null and next == marker_at.?) {
            try w.writeAll(style);
            i = next + style_marker.len;
            continue;
        }

        // A classed <code>. Read the class value, then decide.
        const class_start: usize = next + code_open.len;
        const class_end: usize = std.mem.indexOfScalarPos(u8, src, class_start, '"') orelse {
            try w.writeAll(src[next..]);
            return;
        };
        const gt_at: usize = std.mem.indexOfScalarPos(u8, src, class_end, '>') orelse {
            try w.writeAll(src[next..]);
            return;
        };
        const class: []const u8 = src[class_start..class_end];
        const body_start: usize = gt_at + 1;
        const lang: ?Lang = langOf(class);
        if (lang == null) {
            // Not a language we highlight - emit the opener and carry on from
            // just past it, so a nested classed block is still found.
            try w.writeAll(src[next..body_start]);
            i = body_start;
            continue;
        }
        const close_at: usize = std.mem.indexOfPos(u8, src, body_start, "</code>") orelse {
            try w.writeAll(src[next..]);
            return;
        };
        try w.writeAll(src[next..body_start]);
        try highlightBlock(gpa, w, src[body_start..close_at], lang.?);
        i = close_at;
    }
    try w.writeAll(src[i..]);
}

fn highlightBlock(gpa: Allocator, w: *Writer, escaped: []const u8, lang: Lang) !void {
    // HTML-decode back to real source (normalizing CRLF -> LF).
    const decoded: []const u8 = try htmlDecode(gpa, escaped);
    switch (lang) {
        .zig => try highlightZig(gpa, w, decoded),
        .wgsl => try highlightWgsl(w, decoded),
    }
}

// ---------------------------------------------------------------- Zig

/// Writes `decoded` (plain Zig source, LF line endings) as escaped HTML with
/// `tok-*` spans. `pub` for its one other caller, tools/example_source.zig,
/// which highlights the gallery's example sources with this same code - so the
/// code pane and every doc page share one highlighter. No span it writes
/// crosses a newline: Zig has no multi-line token (a `\\` string is one token
/// per line, and comments end at the newline).
pub fn highlightZig(gpa: Allocator, w: *Writer, decoded: []const u8) !void {
    const buf: [:0]u8 = try gpa.allocSentinel(u8, decoded.len, 0);
    @memcpy(buf, decoded);

    var tok: std.zig.Tokenizer = .init(buf);
    var cursor: usize = 0;
    while (true) {
        const t: Token = tok.next();
        // The gap between tokens holds whitespace and `//` line comments, which
        // the tokenizer skips; emit it with comment spans applied.
        try emitGap(w, decoded[cursor..t.loc.start]);
        if (t.tag == .eof) {
            break;
        }
        const text: []const u8 = decoded[t.loc.start..t.loc.end];
        // An identifier immediately followed by `(` is a call - the one piece of
        // context std.zig.Token does not carry, and the one that makes a code
        // block readable at a glance.
        const is_call: bool = t.tag == .identifier and
            std.mem.indexOfScalarPos(u8, decoded, t.loc.end, '(') == t.loc.end;
        const cls: ?[]const u8 = if (is_call) "tok-fn" else classOfZig(t.tag);
        try emitSpan(w, cls, text);
        cursor = t.loc.end;
    }
}

fn classOfZig(tag: Tag) ?[]const u8 {
    return switch (tag) {
        .string_literal, .multiline_string_literal_line, .char_literal => "tok-str",
        .number_literal => "tok-num",
        .builtin => "tok-builtin",
        .doc_comment, .container_doc_comment => "tok-comment",
        else => if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) "tok-kw" else null,
    };
}

// ---------------------------------------------------------------- WGSL

// WGSL's lexical shape is C-like and its keyword set is small, so a single
// left-to-right pass is enough - and being one pass is what stops a keyword
// inside a comment or a string from ever being tagged.
const wgsl_kw = [_][]const u8{
    "fn",      "let",      "var",   "const",  "struct",   "return", "if",    "else",
    "for",     "while",    "loop",  "break",  "continue", "switch", "case",  "default",
    "discard", "override", "alias", "enable", "requires", "true",   "false", "bitcast",
};
const wgsl_ty = [_][]const u8{
    "u32",        "i32",     "f32",     "f16",       "bool",     "vec2",    "vec3",  "vec4",
    "vec2u",      "vec3u",   "vec4u",   "vec2f",     "vec3f",    "vec4f",   "vec2i", "vec3i",
    "vec4i",      "mat2x2",  "mat3x3",  "mat4x4",    "array",    "atomic",  "ptr",   "texture_2d",
    "sampler",    "storage", "uniform", "workgroup", "function", "private", "read",  "write",
    "read_write",
};

fn isWgslWord(list: []const []const u8, w: []const u8) bool {
    for (list) |k| {
        if (std.mem.eql(u8, k, w)) {
            return true;
        }
    }
    return false;
}

fn highlightWgsl(w: *Writer, src: []const u8) !void {
    var i: usize = 0;
    while (i < src.len) {
        const c: u8 = src[i];
        // line comment
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            var j: usize = i;
            while (j < src.len and src[j] != '\n') : (j += 1) {}
            try emitSpan(w, "tok-comment", src[i..j]);
            i = j;
            continue;
        }
        // block comment
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const end: usize = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse src.len;
            const stop: usize = @min(end + 2, src.len);
            try emitSpan(w, "tok-comment", src[i..stop]);
            i = stop;
            continue;
        }
        // attribute: @group, @binding, @workgroup_size...
        if (c == '@' and i + 1 < src.len and isIdentStart(src[i + 1])) {
            var j: usize = i + 1;
            while (j < src.len and isIdentPart(src[j])) : (j += 1) {}
            try emitSpan(w, "tok-builtin", src[i..j]);
            i = j;
            continue;
        }
        // number
        if (isDigit(c) and (i == 0 or !isIdentPart(src[i - 1]))) {
            var j: usize = i;
            while (j < src.len and (isHexDigit(src[j]) or src[j] == 'x' or src[j] == 'X' or
                src[j] == '.' or src[j] == '_' or src[j] == 'u' or src[j] == 'i' or
                src[j] == 'h' or src[j] == 'f')) : (j += 1)
            {}
            try emitSpan(w, "tok-num", src[i..j]);
            i = j;
            continue;
        }
        // identifier / keyword / type / call
        if (isIdentStart(c)) {
            var j: usize = i;
            while (j < src.len and isIdentPart(src[j])) : (j += 1) {}
            const word: []const u8 = src[i..j];
            var k: usize = j;
            while (k < src.len and (src[k] == ' ' or src[k] == '\t')) : (k += 1) {}
            const cls: ?[]const u8 = if (isWgslWord(&wgsl_kw, word))
                "tok-kw"
            else if (isWgslWord(&wgsl_ty, word))
                "tok-type"
            else if (k < src.len and src[k] == '(')
                "tok-fn"
            else
                null;
            try emitSpan(w, cls, word);
            i = j;
            continue;
        }
        try escapeInto(w, src[i .. i + 1]);
        i += 1;
    }
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isIdentStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---------------------------------------------------------------- shared

fn emitSpan(w: *Writer, cls: ?[]const u8, text: []const u8) !void {
    if (cls) |c| {
        try w.writeAll("<span class=\"");
        try w.writeAll(c);
        try w.writeAll("\">");
        try escapeInto(w, text);
        try w.writeAll("</span>");
    } else {
        try escapeInto(w, text);
    }
}

// Emit an inter-token gap, wrapping `//` line comments in a comment span and
// passing whitespace through untouched.
fn emitGap(w: *Writer, gap: []const u8) !void {
    var run_start: usize = 0;
    var j: usize = 0;
    while (j < gap.len) {
        if (gap[j] == '/' and j + 1 < gap.len and gap[j + 1] == '/') {
            try escapeInto(w, gap[run_start..j]);
            var k: usize = j;
            while (k < gap.len and gap[k] != '\n') {
                k += 1;
            }
            try w.writeAll("<span class=\"tok-comment\">");
            try escapeInto(w, gap[j..k]);
            try w.writeAll("</span>");
            j = k;
            run_start = k;
        } else {
            j += 1;
        }
    }
    try escapeInto(w, gap[run_start..]);
}

// Re-escape for HTML text content.  Only &, <, > matter; quotes stay literal,
// matching the existing convention (e.g. `"zimr"` unescaped in code).
fn escapeInto(w: *Writer, s: []const u8) !void {
    var start: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        const rep: ?[]const u8 = switch (s[j]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (rep) |r| {
            try w.writeAll(s[start..j]);
            try w.writeAll(r);
            start = j + 1;
        }
    }
    try w.writeAll(s[start..]);
}

// Decode the handful of entities the pages actually use, and normalize line
// endings.  A bare `&` (Zig address-of, e.g. `&sw`) that isn't a known entity is
// kept literal - the pages write those unescaped.
fn htmlDecode(gpa: Allocator, s: []const u8) ![]u8 {
    var out: ArrayList(u8) = .empty;
    var j: usize = 0;
    while (j < s.len) {
        const c: u8 = s[j];
        if (c == '\r') {
            try out.append(gpa, '\n');
            j += if (j + 1 < s.len and s[j + 1] == '\n') @as(usize, 2) else 1;
            continue;
        }
        if (c == '&') {
            const rest: []const u8 = s[j..];
            if (std.mem.startsWith(u8, rest, "&lt;")) {
                try out.append(gpa, '<');
                j += 4;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&gt;")) {
                try out.append(gpa, '>');
                j += 4;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&amp;")) {
                try out.append(gpa, '&');
                j += 5;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&quot;")) {
                try out.append(gpa, '"');
                j += 6;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&#39;")) {
                try out.append(gpa, '\'');
                j += 5;
                continue;
            }
        }
        try out.append(gpa, c);
        j += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn readAllStdin(gpa: Allocator, io: std.Io) ![]u8 {
    var list: ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    const in: File = File.stdin();
    while (true) {
        var iov = [_][]u8{&buf};
        const n: usize = in.readStreaming(io, &iov) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            break;
        }
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}
