#!/usr/bin/env python3
"""
docs/cheatsheet-generator.py — emit docs/coverage-report.md from raylib_src/
                               and src/ by static analysis.

Usage:
    cd <zimr-repo-root>
    python3 docs/cheatsheet-generator.py > docs/coverage-report.md

What it does:
    1. Parses raylib's RLAPI/RMAPI prototypes from raylib_src/{raylib,raymath,rlgl}.h
       to build the master function inventory grouped by (module, category).
    2. Parses every src/*.zig (excluding tests) for `pub fn` declarations,
       capturing each function's allocator/error-union signature flags.
    3. Greps every examples/*.zig for word-boundary references to the
       extracted zimr function names → per-function example coverage.
    4. Emits a markdown cheatsheet with: (a) coverage stats at the top,
       (b) per-module status tables, (c) function-by-function listings
       with status icons, (d) "to-ziggify" candidates, (e) "to-port"
       raylib functions.

Conventions:
    - raylib functions are PascalCase; we match against zimr's lowerCamel
      by lowercasing both names.
    - "Ziggified" means: takes Allocator parameter AND returns error union.
      Some functions legitimately need only one or neither (math, getters,
      simple state setters).
    - Audio (raudio) and gestures (rgestures) modules are flagged
      "deferred" — out of zimr's current scope per project direction.

Reproduction:
    The script is deterministic given identical raylib_src/ + src/ +
    examples/ inputs.  Re-run after any API surface change to refresh
    docs/coverage-report.md.
"""
import re
import json
import glob
import os
from collections import Counter, defaultdict

# raylib has 150+ examples; we count zimr's directly.
RAYLIB_EXAMPLE_COUNT = 150

# ==========================================================================
# Step 1: parse raylib headers for the function inventory
# ==========================================================================

def parse_raylib_header(path, prefix, module_default):
    """Parse RLAPI/RMAPI declarations.  RLAPI ends with `;`; RMAPI bodies
    end with `{` because they're inline.  Returns list of dicts."""
    out = []
    cur_module = module_default
    cur_cat = "uncategorized"

    with open(path) as fh:
        lines = [ln.rstrip() for ln in fh.readlines()]

    i = 0
    while i < len(lines):
        line = lines[i]
        # Module marker
        m = re.match(r"^//\s+(.+?)Functions\s+\(Module:\s*(\w+)\)", line)
        if m:
            cur_module = m.group(2).strip()
            cur_cat = m.group(1).strip()
            i += 1
            continue
        # Sub-section
        m = re.match(r"^//\s+([A-Z][\w \-/,]+(?:functions|drawing|loading|operations))\b", line)
        if m:
            cur_cat = m.group(1).strip()
            i += 1
            continue
        # Function declaration
        if line.startswith(prefix + " "):
            # Capture the trailing `// description` comment before stripping.
            comment_match = re.search(r"//\s*(.*)$", line)
            comment = comment_match.group(1).strip() if comment_match else ""
            decl = re.sub(r"//.*$", "", line).rstrip()
            # Multi-line: keep collecting until we see ; or {
            while not (";" in decl or "{" in decl) and i + 1 < len(lines):
                i += 1
                nxt = lines[i]
                if not comment:
                    cm = re.search(r"//\s*(.*)$", nxt)
                    if cm:
                        comment = cm.group(1).strip()
                decl += " " + re.sub(r"//.*$", "", nxt).strip()
            m = re.match(re.escape(prefix) + r"\s+(.+?)\s+\**(\w+)\s*\((.*?)\)\s*[;{]", decl)
            if m:
                out.append({
                    "module": cur_module,
                    "category": cur_cat,
                    "fn": m.group(2),
                    "ret": m.group(1).strip(),
                    "args": m.group(3).strip(),
                    "comment": comment,
                })
        i += 1
    return out

raylib_fns = parse_raylib_header("raylib_src/raylib.h", "RLAPI", "core")
raymath_fns = parse_raylib_header("raylib_src/raymath.h", "RMAPI", "raymath")
rlgl_fns = parse_raylib_header("raylib_src/rlgl.h", "RLAPI", "rlgl")
for f in raymath_fns:
    f["module"] = "raymath"
for f in rlgl_fns:
    f["module"] = "rlgl"

raylib_master = raylib_fns + raymath_fns + rlgl_fns

# ==========================================================================
# Step 2: parse zimr's pub fn declarations
#
# zimr's API surface lives inside namespaced structs:
#     pub const text = struct {
#         pub fn draw(...) ...
#     };
# So we walk the file tracking the active namespace.  A `pub const NAME =
# struct {` opens a namespace; the matching `};` at the same indent closes
# it.  Functions declared inside such a struct are recorded with the
# namespace name as their module.
# ==========================================================================

zimr_fns = []
for path in sorted(glob.glob("src/*.zig")):
    base = os.path.basename(path)
    if "_test" in base:
        continue
    with open(path) as fh:
        src = fh.read()

    # Find every `pub fn NAME(args) ret {` and figure out which namespace
    # it lives in.  We don't fully tokenize Zig — we use indent + a small
    # stack of `pub const NAME = struct {` opens.  Function signatures may
    # span multiple lines (the Zig style guide prefers one arg per line
    # for >2 args), so we collect lines until paren depth returns to 0.
    lines = src.split("\n")
    ns_stack = []  # list of (indent_spaces, name)
    i = 0
    while i < len(lines):
        raw = lines[i]
        # Track namespace open/close.  We only care about top-level
        # `pub const NAME = struct {` (indent <= 8 spaces) — anything
        # deeper is a config struct or a private helper namespace, not
        # a public API surface.
        m_open = re.match(r"^(\s*)pub const (\w+)\s*=\s*struct\s*\{", raw)
        if m_open:
            indent = len(m_open.group(1))
            if indent <= 8:
                ns_stack.append((indent, m_open.group(2)))
            i += 1
            continue
        m_close = re.match(r"^(\s*)\};", raw)
        if m_close and ns_stack:
            indent = len(m_close.group(1))
            if ns_stack and indent == ns_stack[-1][0]:
                ns_stack.pop()
            i += 1
            continue
        # Function declaration — possibly multi-line.
        m_fn_start = re.match(r"^(\s*)pub fn\s+(\w+)\s*\(", raw)
        if m_fn_start:
            fn = m_fn_start.group(2)
            # Walk BACKWARDS to collect any /// doc-comment lines
            # immediately above this function.  Stops at the first
            # non-doc-comment line (blank, code, regular `//`).
            doc_lines = []
            k = i - 1
            while k >= 0:
                ln = lines[k].strip()
                if ln.startswith("///"):
                    # Strip the `///` prefix + one optional space.
                    text = ln[3:]
                    if text.startswith(" "):
                        text = text[1:]
                    doc_lines.append(text)
                    k -= 1
                else:
                    break
            doc_lines.reverse()
            # Brief = first non-empty doc line; truncate at first
            # period-followed-by-space-or-end (the first sentence).
            brief = ""
            for dl in doc_lines:
                if dl:
                    brief = dl
                    break
            # Take first sentence only, but don't go past 110 chars.
            if brief:
                m_period = re.search(r"\.\s|\.$", brief)
                if m_period:
                    brief = brief[: m_period.end()].rstrip()
                if len(brief) > 110:
                    brief = brief[:107].rstrip() + "..."

            # Collect lines until paren depth returns to 0 and we have
            # the entire signature including return type.
            decl = raw
            depth = decl.count("(") - decl.count(")")
            j = i
            while depth > 0 and j + 1 < len(lines):
                j += 1
                decl += " " + lines[j]
                depth += lines[j].count("(") - lines[j].count(")")
            # Now extract args + return.
            m_full = re.match(r"^\s*pub fn\s+\w+\s*\((.*)\)\s*([^\{]*?)\s*(\{|\!|$)", decl)
            if m_full:
                args = re.sub(r"\s+", " ", m_full.group(1).strip())
                ret = m_full.group(2).strip()
                module = ns_stack[-1][1] if ns_stack else base.replace(".zig", "")
                zimr_fns.append({
                    "module": module,
                    "fn": fn,
                    "args": args,
                    "ret": ret,
                    "has_alloc": bool(re.search(r"Allocator|gpa\s*:|allocator\s*:", args)),
                    "has_err": "!" in ret or "Error" in ret,
                    "brief": brief,
                })
            i = j + 1
            continue
        i += 1

# ==========================================================================
# Step 3: per-function example coverage
# ==========================================================================

example_files = sorted(glob.glob("examples/*.zig"))
example_text_by_path = {p: open(p).read() for p in example_files}

example_coverage = {}  # (module, fn) -> [example basenames]
for f in zimr_fns:
    name = f["fn"]
    rgx = re.compile(r"\b" + re.escape(name) + r"\b")
    hits = [
        os.path.basename(p).replace(".zig", "")
        for p, text in example_text_by_path.items()
        if rgx.search(text)
    ]
    if hits:
        example_coverage[(f["module"], f["fn"])] = hits

# Explicit rename map: raylib name → zimr name(s).  Used for functions
# that were deliberately renamed during the aggressive ziggification
# sweep (turns 1-10) to drop the C-shape `[*:0]const u8` parameters in
# favour of `[]const u8` slices.  When such a rename is recorded here,
# the cheatsheet treats the raylib function as covered, with the new
# name as the replacement.
#
# This is also the place to record "deleted in favour of std" — those
# functions point to a stdlib equivalent rather than a zimr name.
RAYLIB_TO_ZIMR_RENAMES = {
    # text drawing — slice-shape replaces null-terminated C-string
    "DrawText":               ("text",     "draw"),
    "DrawTextEx":             ("text",     "drawEx"),
    "DrawTextPro":            ("text",     "drawPro"),
    "DrawTextCodepoints":     ("text",     "drawTextCodepoints"),
    "MeasureText":            ("text",     "measure"),
    "MeasureTextEx":          ("text",     "measureEx"),
    "MeasureTextCodepoints":  ("text",     "measureTextCodepoints"),
    # text-strings management — replaced by std-library equivalents
    "TextCopy":               ("std",      "@memcpy / std.mem.copyForwards"),
    "TextIsEqual":            ("std",      "std.mem.eql(u8, a, b)"),
    "TextLength":             ("std",      "s.len / std.mem.span(s).len"),
    "TextAppend":             ("std",      "std.fmt.bufPrint"),
    "TextFindIndex":          ("std",      "std.mem.indexOf(u8, s, needle)"),
    "TextToInteger":          ("std",      "std.fmt.parseInt(c_int, s, 10)"),
    "TextToFloat":            ("std",      "std.fmt.parseFloat(f32, s)"),
    "UnloadTextLines":        ("std",      "gpa.free(slice_of_slices)"),
    # codepoint helpers — replaced by slice-native nextCodepoint/etc.
    "GetCodepointCount":      ("text",     "countCodepoints"),
    "GetCodepointNext":       ("text",     "nextCodepoint"),
    "GetCodepointPrevious":   ("text",     "prevCodepoint"),
    "GetCodepoint":           ("text",     "nextCodepoint"),
    "LoadUTF8":               ("text",     "loadUTF8"),
    "LoadCodepoints":         ("text",     "loadCodepoints"),
    "UnloadUTF8":             ("std",      "gpa.free(slice)"),
    "UnloadCodepoints":       ("std",      "gpa.free(slice)"),
    # font loading from memory — we have loadFontFromTtfData
    "LoadFontFromMemory":     ("text",     "loadFontFromTtfData"),
    "UnloadFont":             ("text",     "unloadFont"),
    "UnloadFontData":         ("text",     "unloadFontData"),
    # input — getKeyPressed returns ?KeyboardKey now (idiomatic Zig)
    "GetKeyPressed":          ("input",    "getKeyPressed"),
    "GetCharPressed":         ("input",    "getCharPressed"),
    "GetGamepadButtonPressed":("input",    "getGamepadButtonPressed"),
    # checkCollisionLines: bool+out-pointer → ?Vector2 (Zig idiom)
    "CheckCollisionLines":    ("shapes",   "checkCollisionLines"),
    # (GenImagePerlinNoise removed — zimr's genImagePerlinNoise has same
    # name; case-insensitive match catches it without a remap entry.)
    # Step-1 audit additions: already-ported but case-insensitive matcher misses.
    "LoadShaderFromMemory":         ("shaders",  "loadShaderFromMemory"),
    "UnloadShader":                 ("shaders",  "unloadShader"),
    "IsGamepadButtonPressed":       ("input",    "isGamepadButtonPressed"),
    "IsGamepadButtonDown":          ("input",    "isGamepadButtonDown"),
    "IsGamepadButtonReleased":      ("input",    "isGamepadButtonReleased"),
    "IsGamepadButtonUp":            ("input",    "isGamepadButtonUp"),
    "GetGamepadAxisMovement":       ("input",    "getGamepadAxisMovement"),
    "TraceLog":                     ("core",     "traceLog"),
    "IsCursorOnScreen":             ("input",    "isCursorOnScreen"),
    # raylib's GetSplinePointBezierQuadratic = zimr's getSplinePointBezierQuad.
    "GetSplinePointBezierQuadratic": ("shapes",  "getSplinePointBezierQuad"),
    # zimr's imageDrawRectangleLines has raylib's ImageDrawRectangleLinesEx
    # signature (dst, rec, thick, color).  raylib's *non-Ex* one takes
    # (dst, posX, posY, width, height, color) — we don't have that.
    "ImageDrawRectangleLinesEx":    ("textures", "imageDrawRectangleLines"),
    # Both raylib fns are per-vertex-color triangles; semantically same.
    "ImageDrawTriangleGradient":    ("textures", "imageDrawTriangleEx"),
    # UnloadTexture now exists as a free-standing fn (added in Step 1).
    "UnloadTexture":                ("textures", "unloadTexture"),
    # Clipboard read is async in zimr (browser API is async); raylib's
    # synchronous GetClipboardText maps to the start/poll/release trio.
    "GetClipboardText":             ("core",     "getClipboardTextAsync"),
    # raylib calls it IsWindowFullscreen; zimr drops the redundant prefix.
    "IsWindowFullscreen":           ("core",     "isFullscreen"),
    # raylib's LoadModel takes a path; zimr's wasm-first design takes
    # bytes from a fetch handle.  Map the raylib name to our entry point.
    "LoadModel":                    ("models",   "loadModelFromMemory"),
    # rlgl entry points renamed for Zig style; case-insensitive match
    # already catches them (rlgl preserved raylib's exact names).
    # NOTE: raylib's LoadShader (disk path) doesn't map cleanly — caller
    # uses `f.loader.loadFileText(path)` then `loadShaderFromMemory`.
    # No rename-map entry — left as ❌ in coverage report (correct).
    # NOTE: raylib's SetMouseCursor doesn't have a zimr equivalent yet
    # (only show/hide cursor + style 0/1).  Not in rename map.

    # ----- audio (raudio) -----------------------------------------------
    # The full WAV+OGG audio surface ships per audio-plan-v3.  Each raylib
    # audio fn either maps cleanly to a zimr namespace fn, or is recorded
    # in NOT_PORTED below with the rationale.
    "InitAudioDevice":              ("audio_device", "init"),
    "CloseAudioDevice":             ("audio_device", "close"),
    "IsAudioDeviceReady":           ("audio_device", "isReady"),
    "SetMasterVolume":              ("audio_device", "setMasterVolume"),
    "GetMasterVolume":              ("audio_device", "getMasterVolume"),
    "LoadWaveFromMemory":           ("waves", "loadFromMemory"),
    "IsWaveValid":                  ("waves", "isValid"),
    "UnloadWave":                   ("waves", "unload"),
    "WaveCopy":                     ("waves", "copy"),
    "WaveCrop":                     ("waves", "crop"),
    "WaveFormat":                   ("waves", "format"),
    "LoadWaveSamples":              ("waves", "loadSamples"),
    "UnloadWaveSamples":            ("waves", "unloadSamples"),
    "ExportWave":                   ("waves", "exportToMemory"),
    "LoadSoundFromWave":            ("sounds", "loadFromWave"),
    "LoadSoundAlias":               ("sounds", "loadAlias"),
    "IsSoundValid":                 ("sounds", "isValid"),
    "UnloadSound":                  ("sounds", "unload"),
    "UnloadSoundAlias":             ("sounds", "unload"),
    "PlaySound":                    ("sounds", "play"),
    "StopSound":                    ("sounds", "stop"),
    "PauseSound":                   ("sounds", "pause"),
    "ResumeSound":                  ("sounds", "resumeSound"),
    "IsSoundPlaying":               ("sounds", "isPlaying"),
    "SetSoundVolume":               ("sounds", "setVolume"),
    "SetSoundPitch":                ("sounds", "setPitch"),
    "SetSoundPan":                  ("sounds", "setPan"),
    "LoadMusicStreamFromMemory":    ("music", "loadFromMemory"),
    "IsMusicValid":                 ("music", "isValid"),
    "UnloadMusicStream":            ("music", "unload"),
    "PlayMusicStream":              ("music", "play"),
    "IsMusicStreamPlaying":         ("music", "isPlaying"),
    "UpdateMusicStream":            ("music", "update"),
    "StopMusicStream":              ("music", "stop"),
    "PauseMusicStream":             ("music", "pause"),
    "ResumeMusicStream":            ("music", "resumeMusic"),
    "SeekMusicStream":              ("music", "seek"),
    "SetMusicVolume":               ("music", "setVolume"),
    "SetMusicPitch":                ("music", "setPitch"),
    "SetMusicPan":                  ("music", "setPan"),
    "GetMusicTimeLength":           ("music", "getTimeLength"),
    "GetMusicTimePlayed":           ("music", "getTimePlayed"),
    "LoadAudioStream":              ("streams", "load"),
    "IsAudioStreamValid":           ("streams", "isValid"),
    "UnloadAudioStream":            ("streams", "unload"),
    "UpdateAudioStream":            ("streams", "update"),
    "IsAudioStreamProcessed":       ("streams", "isProcessed"),
    "PlayAudioStream":              ("streams", "play"),
    "PauseAudioStream":             ("streams", "pause"),
    "ResumeAudioStream":            ("streams", "resumeStream"),
    "IsAudioStreamPlaying":         ("streams", "isPlaying"),
    "StopAudioStream":              ("streams", "stop"),
    "SetAudioStreamVolume":         ("streams", "setVolume"),
    "SetAudioStreamPitch":          ("streams", "setPitch"),
    "SetAudioStreamPan":            ("streams", "setPan"),
    # ----- Phase-1A bridge-the-gap: window UX --------------------------
    "SetMouseCursor":                ("input",     "setMouseCursor"),
    "SetWindowOpacity":              ("core",      "setWindowOpacity"),
    "SetWindowFocused":              ("core",      "setWindowFocused"),
    "IsWindowResized":               ("core",      "isWindowResized"),
    "SetWindowIcon":                 ("core",      "setWindowIcon"),
    "SetWindowIcons":                ("core",      "setWindowIcons"),
    "IsFileDropped":                 ("core",      "isFileDropped"),
    "LoadDroppedFiles":              ("core",      "loadDroppedFiles"),
    "UnloadDroppedFiles":            ("core",      "unloadDroppedFiles"),

    # ----- Phase-1B bridge-the-gap: textures ---------------------------
    "ExportImageToMemory":           ("textures",  "exportImageToMemory"),
    "ImageFromChannel":              ("textures",  "imageFromChannel"),
    "ImageMipmaps":                  ("textures",  "imageMipmaps"),

    # ----- Phase-1C bridge-the-gap: rlgl -------------------------------
    "rlSetPointSize":                ("rlgl",      "rlSetPointSize"),
    "rlGetPointSize":                ("rlgl",      "rlGetPointSize"),
    "rlCheckErrors":                 ("rlgl",      "rlCheckErrors"),
    "rlSetBlendFactors":             ("rlgl",      "rlSetBlendFactors"),
    "rlSetBlendFactorsSeparate":     ("rlgl",      "rlSetBlendFactorsSeparate"),
    "rlCopyFramebuffer":             ("rlgl",      "rlCopyFramebuffer"),
}


# Functions raylib has but zimr deliberately doesn't, with rationale.
# These show up in the cheatsheet as "intentionally skipped" rather than
# "missing" — the distinction matters for prioritising future work.
# Rationale buckets:
#   FETCH:    file-path I/O — use z.fetch + a *FromMemory variant
#   STD:      Zig stdlib has a clean equivalent
#   N/A-WEB:  fundamentally doesn't apply on the web platform
#   AUTO:     handled by zimr's runtime loop / Frame
#   SCOPE:    feature out of scope (VR, automation, compute shaders)
#   GAP:      could be ported, just hasn't been (a real to-do)
NOT_PORTED = {
    # ====================================================================
    # core — Window-related: most "window" concepts don't apply to canvas
    # ====================================================================
    "InitWindow":              "AUTO: handled by z.run(.window={...}, ...)",
    "CloseWindow":             "AUTO: runtime handles teardown",
    "IsWindowReady":           "AUTO: frame callbacks only fire when ready",
    "IsWindowHidden":          "N/A-WEB: use document.hidden via Page Visibility API",
    "IsWindowMinimized":       "N/A-WEB: no window minimize concept in browser",
    "IsWindowMaximized":       "N/A-WEB: canvas always fills its element",
    "IsWindowState":           "N/A-WEB: state flags are GLFW-specific",
    "SetWindowState":          "N/A-WEB: state flags are GLFW-specific",
    "ClearWindowState":        "N/A-WEB: state flags are GLFW-specific",
    "ToggleBorderlessWindowed": "N/A-WEB: browser fullscreen has one mode (toggleFullscreen covers it)",
    "MaximizeWindow":          "N/A-WEB: no maximize concept",
    "MinimizeWindow":          "N/A-WEB: no minimize concept",
    "RestoreWindow":           "N/A-WEB: no minimize/maximize state",
    "SetWindowPosition":       "N/A-WEB: browsers don't let pages move themselves",
    "SetWindowMonitor":        "N/A-WEB: no monitor concept in browser",
    "SetWindowMinSize":        "N/A-WEB: canvas-element sizing is parent-driven",
    "SetWindowMaxSize":        "N/A-WEB: see SetWindowMinSize",
    "GetWindowHandle":         "N/A-WEB: returns native HWND / X11 handle",
    "GetMonitorCount":         "N/A-WEB: no monitor enumeration in browser",
    "GetCurrentMonitor":       "N/A-WEB: no monitor concept",
    "GetMonitorPosition":      "N/A-WEB: no monitor concept",
    "GetMonitorWidth":         "N/A-WEB: use screen.width if essential",
    "GetMonitorHeight":        "N/A-WEB: use screen.height if essential",
    "GetMonitorPhysicalWidth": "N/A-WEB: physical mm not exposed by browser",
    "GetMonitorPhysicalHeight": "N/A-WEB: physical mm not exposed by browser",
    "GetMonitorRefreshRate":   "N/A-WEB: rAF rate is the effective refresh",
    "GetWindowPosition":       "N/A-WEB: pages don't know their own screen position",
    "GetMonitorName":          "N/A-WEB: monitor names not exposed",
    "GetClipboardImage":       "GAP: navigator.clipboard.read() is async; not yet wired",
    "EnableEventWaiting":      "AUTO: runtime uses rAF; no event-wait toggle",
    "DisableEventWaiting":     "AUTO: see EnableEventWaiting",

    # ====================================================================
    # core — Drawing-related: managed by zimr's runtime
    # ====================================================================
    "ClearBackground":         "AUTO: use frame.clear(color)",
    "BeginDrawing":            "AUTO: runtime opens a frame each tick",
    "EndDrawing":              "AUTO: runtime closes the frame",
    "BeginVrStereoMode":       "SCOPE: VR is out of scope",
    "EndVrStereoMode":         "SCOPE: VR is out of scope",
    "LoadVrStereoConfig":      "SCOPE: VR is out of scope",
    "UnloadVrStereoConfig":    "SCOPE: VR is out of scope",

    # ====================================================================
    # core — Custom frame control + memory + shader file
    # ====================================================================
    "SwapScreenBuffer":        "AUTO: browser composites; rAF schedules paint",
    "PollInputEvents":         "AUTO: browser fires events asynchronously",
    "WaitTime":                "N/A-WEB: blocking the main thread is an anti-pattern",
    "LoadShader":              "FETCH: use Loader.loadFileText + shaders.loadShaderFromMemory",
    "SetConfigFlags":          "AUTO: use the Config struct passed to z.run",
    "MemAlloc":                "STD: use a std.mem.Allocator",
    "MemRealloc":              "STD: use Allocator.realloc",
    "MemFree":                 "STD: use Allocator.free",

    # ====================================================================
    # core — File system: browsers have no synchronous filesystem
    # ====================================================================
    "SaveFileData":            "FETCH: use dom.downloadBlob (no FS write in browsers)",
    "ExportDataAsCode":        "SCOPE: niche debug tool — write a Zig comptime instead",
    "LoadFileText":            "FETCH: use Loader.loadFileText",
    "UnloadFileText":          "STD: gpa.free(text)",
    "SaveFileText":            "FETCH: see SaveFileData",
    "SetLoadFileDataCallback": "AUTO: zimr's Loader interface replaces this hook",
    "SetSaveFileDataCallback": "AUTO: see SetLoadFileDataCallback",
    "SetLoadFileTextCallback": "AUTO: see SetLoadFileDataCallback",
    "SetSaveFileTextCallback": "AUTO: see SetLoadFileDataCallback",
    "FileRename":              "N/A-WEB: no FS write access",
    "FileRemove":              "N/A-WEB: no FS write access",
    "FileCopy":                "N/A-WEB: no FS access",
    "FileMove":                "N/A-WEB: no FS write access",
    "FileTextReplace":         "N/A-WEB: no FS write access",
    "FileTextFindIndex":       "N/A-WEB: no FS access",
    "FileExists":              "N/A-WEB: no FS access (network 404 != exists)",
    "DirectoryExists":         "N/A-WEB: no FS access",
    "IsFileExtension":         "STD: std.mem.endsWith(u8, name, ext)",
    "GetFileLength":           "STD: use the Loader handle's size or HEAD request",
    "GetFileModTime":          "N/A-WEB: no FS metadata",
    "GetFileExtension":        "STD: std.fs.path.extension",
    "GetFileName":             "STD: std.fs.path.basename",
    "GetFileNameWithoutExt":   "STD: std.fs.path.stem",
    "GetDirectoryPath":        "STD: std.fs.path.dirname",
    "GetPrevDirectoryPath":    "STD: std.fs.path.dirname twice",
    "GetWorkingDirectory":     "N/A-WEB: cwd has no meaning in a browser",
    "GetApplicationDirectory": "N/A-WEB: see GetWorkingDirectory",
    "MakeDirectory":           "N/A-WEB: no FS access",
    "ChangeDirectory":         "N/A-WEB: no cwd",
    "IsPathFile":              "N/A-WEB: no FS access",
    "LoadDirectoryFiles":      "N/A-WEB: no FS enumeration",
    "LoadDirectoryFilesEx":    "N/A-WEB: see LoadDirectoryFiles",
    "UnloadDirectoryFiles":    "N/A-WEB: see LoadDirectoryFiles",
    "GetDirectoryFileCount":   "N/A-WEB: no FS enumeration",
    "GetDirectoryFileCountEx": "N/A-WEB: no FS enumeration",
    "CompressData":            "STD: std.compress.zlib (or DEFLATE / gzip variants)",
    "DecompressData":          "STD: std.compress.zlib",
    "EncodeDataBase64":        "STD: std.base64.standard.Encoder",
    "DecodeDataBase64":        "STD: std.base64.standard.Decoder",
    "ComputeCRC32":            "STD: std.hash.Crc32",
    "ComputeMD5":              "STD: std.crypto.hash.Md5",
    "ComputeSHA1":              "STD: std.crypto.hash.Sha1",
    "ComputeSHA256":           "STD: std.crypto.hash.sha2.Sha256",
    "LoadAutomationEventList": "SCOPE: input recording/replay is out of scope",
    "UnloadAutomationEventList": "SCOPE: see LoadAutomationEventList",
    "ExportAutomationEventList": "SCOPE: see LoadAutomationEventList",
    "SetAutomationEventList":  "SCOPE: see LoadAutomationEventList",
    "SetAutomationEventBaseFrame": "SCOPE: see LoadAutomationEventList",
    "StartAutomationEventRecording": "SCOPE: see LoadAutomationEventList",
    "StopAutomationEventRecording":  "SCOPE: see LoadAutomationEventList",
    "PlayAutomationEvent":     "SCOPE: see LoadAutomationEventList",

    # ====================================================================
    # core — Input
    # ====================================================================
    "SetGamepadMappings":      "N/A-WEB: browser GamePad API uses fixed standard mapping",
    "SetMousePosition":        "N/A-WEB: browsers don't allow programmatic cursor positioning (security)",
    "SetMouseOffset":          "N/A-WEB: zimr has no viewport-offset concept",
    "SetMouseScale":           "N/A-WEB: see SetMouseOffset",

    # ====================================================================
    # textures
    # ====================================================================
    "LoadImage":               "FETCH: Loader.loadFileData + textures.loadImageFromMemory",
    "LoadImageRaw":            "FETCH: same + raw decoder (zimr exposes loadImageFromMemory only)",
    "LoadImageAnim":           "SCOPE: animated GIF/etc decoder not in scope",
    "LoadImageAnimFromMemory": "SCOPE: see LoadImageAnim",
    "ExportImage":             "FETCH: encode + dom.downloadBlob (no FS write in browsers)",
    "ExportImageAsCode":       "SCOPE: niche debug tool",
    "LoadImagePalette":        "SCOPE: palette extraction is niche",
    "UnloadImageColors":       "STD: gpa.free(slice)",
    "UnloadImagePalette":      "STD: gpa.free(slice)",
    "LoadTexture":             "FETCH: Loader.loadFileData + loadImageFromMemory + loadTextureFromImage",

    # ====================================================================
    # text
    # ====================================================================
    "LoadFont":                "FETCH: Loader.loadFileData + text.loadFontFromTtfData",
    "LoadFontEx":              "FETCH: see LoadFont; loadFontFromTtfData accepts size + codepoints",
    "LoadFontFromImage":       "SCOPE: bitmap-font-from-atlas-image is niche",
    "LoadFontData":            "SCOPE: raylib-internal data shape; loadFontFromTtfData covers usage",
    "ExportFontAsCode":        "SCOPE: niche debug tool",
    "LoadTextLines":           "STD: std.mem.splitScalar(u8, text, '\\n')",
    "TextFormat":              "STD: std.fmt.allocPrint or comptime fmt",
    "TextSubtext":             "STD: text[pos..pos+len] slice",
    "TextRemoveSpaces":        "STD: std.mem.replaceScalar(u8, ...)",
    "GetTextBetween":          "STD: std.mem.indexOf chained",
    "TextReplace":             "STD: std.mem.replace",
    "TextReplaceAlloc":        "STD: std.mem.replaceOwned",
    "TextReplaceBetween":      "STD: composition of indexOf + replace",
    "TextReplaceBetweenAlloc": "STD: see TextReplaceBetween",
    "TextInsert":              "STD: std.fmt.allocPrint with concat",
    "TextInsertAlloc":         "STD: see TextInsert",
    "TextJoin":                "STD: std.mem.join",
    "TextSplit":               "STD: std.mem.splitScalar (iterator) or splitAny",
    "TextToUpper":             "STD: std.ascii.allocUpperString",
    "TextToLower":             "STD: std.ascii.allocLowerString",
    "TextToPascal":            "SCOPE: case conversion not in stdlib; userland helper",
    "TextToSnake":             "SCOPE: see TextToPascal",
    "TextToCamel":             "SCOPE: see TextToPascal",
    "CodepointToUTF8":         "RENAME: see text.encodeCodepoint(u21) -> Utf8Bytes",

    # ====================================================================
    # models
    # ====================================================================
    "ExportMesh":              "FETCH: encode + dom.downloadBlob",
    "ExportMeshAsCode":        "SCOPE: niche debug tool",
    "GenMeshCubicmap":         "SCOPE: voxel mesh from image map; niche",
    "LoadMaterials":           "FETCH: loadModelFromMemory pulls materials inline from glTF",

    # ====================================================================
    # audio
    # ====================================================================
    "LoadWave":                "FETCH: use z.fetch + waves.loadFromMemory",
    "LoadSound":               "FETCH: use z.fetch + sounds.loadFromMemory",
    "LoadMusicStream":         "FETCH: use z.fetch + music.loadFromMemory",
    "UpdateSound":             "SCOPE: redundant with AudioStream on web",
    "ExportWaveAsCode":        "SCOPE: niche debug tool",
    "SetAudioStreamCallback":  "N/A-WEB: Web Audio uses AudioWorklet (different model); per-frame streams.update is the userland equivalent",
    "AttachAudioStreamProcessor": "N/A-WEB: see SetAudioStreamCallback",
    "DetachAudioStreamProcessor": "N/A-WEB: see SetAudioStreamCallback",
    "AttachAudioMixedProcessor": "N/A-WEB: global mixer hook — Web Audio's master gain doesn't expose a tap",
    "DetachAudioMixedProcessor": "N/A-WEB: see AttachAudioMixedProcessor",
    "LoadAudioStreamFromMemory": "non-existent in raylib (synthetic name from older docs)",
    "SetAudioStreamBufferSizeDefault": "N/A-WEB: miniaudio backend internal",
    "LoadWaveFromSamples":     "STD: composer.tone covers the synthetic-wave use case",

    # ====================================================================
    # rlgl — advanced GL features mostly tied to compute / WebGL2 limits
    # ====================================================================
    "rlEnableStatePointer":    "N/A-WEB: legacy GL2 immediate-mode state-pointer style — not in WebGL2",
    "rlDisableStatePointer":   "N/A-WEB: see rlEnableStatePointer",
    "rlLoadExtensions":        "N/A-WEB: browser handles extension loading",
    "rlGetProcAddress":        "N/A-WEB: WebGL2 has no procAddress concept",
    "rlGetVersion":            "N/A-WEB: WebGL version is implicit",
    "rlLoadRenderBatch":       "AUTO: zimr uses auto-batching via rlgl_gpu",
    "rlUnloadRenderBatch":     "AUTO: see rlLoadRenderBatch",
    "rlSetRenderBatchActive":  "AUTO: see rlLoadRenderBatch",
    "rlCheckRenderBatchLimit": "AUTO: see rlLoadRenderBatch",
    "rlSetVertexAttributeDefault": "GAP: not commonly used; could port",
    "rlReadTexturePixels":     "STD: use textures.loadImageFromTexture",
    "rlReadScreenPixels":      "STD: use textures.loadImageFromScreen",
    "rlLoadShaderProgram":     "STD: rlLoadShaderProgramEx is the slice-shape version",
    "rlLoadShaderProgramCompute": "N/A-WEB: WebGL2 has no compute shaders (need WebGPU)",
    "rlUnloadShader":          "RENAME: see rlUnloadShaderProgram (raylib renamed across versions)",
    "rlComputeShaderDispatch": "N/A-WEB: see rlLoadShaderProgramCompute",
    "rlLoadShaderBuffer":      "N/A-WEB: SSBOs need WebGL2 + extension or WebGPU",
    "rlUnloadShaderBuffer":    "N/A-WEB: see rlLoadShaderBuffer",
    "rlUpdateShaderBuffer":    "N/A-WEB: see rlLoadShaderBuffer",
    "rlBindShaderBuffer":      "N/A-WEB: see rlLoadShaderBuffer",
    "rlReadShaderBuffer":      "N/A-WEB: see rlLoadShaderBuffer",
    "rlCopyShaderBuffer":      "N/A-WEB: see rlLoadShaderBuffer",
    "rlGetShaderBufferSize":   "N/A-WEB: see rlLoadShaderBuffer",
    "rlBindImageTexture":      "N/A-WEB: image load/store needs compute (WebGPU)",
    "rlGetMatrixProjectionStereo": "SCOPE: VR is out of scope",
    "rlGetMatrixViewOffsetStereo": "SCOPE: VR is out of scope",
    "rlSetMatrixProjectionStereo": "SCOPE: VR is out of scope",
    "rlSetMatrixViewOffsetStereo": "SCOPE: VR is out of scope",
    "rlLoadDrawCube":          "SCOPE: raylib-example helper, not API",
    "rlLoadDrawQuad":          "SCOPE: raylib-example helper, not API",
}


def is_explicitly_renamed(rname):
    """Return (module, zimr_name) if `rname` is in the rename map, else None."""
    return RAYLIB_TO_ZIMR_RENAMES.get(rname)



zimr_by_lname = defaultdict(list)
for f in zimr_fns:
    zimr_by_lname[f["fn"].lower()].append(f)

import sys

# When True, find_zimr prints a warning to stderr whenever a rename-map
# entry's target isn't found in zimr's source.  Run with this on after
# editing the rename map to catch typos / stale entries:
#
#   DEBUG_RENAMES=1 python3 src/notes/cheatsheet-generator.py > /tmp/cov.md
#
# (The flag also reads from the env so we don't need to edit code each
# time we want to audit.)
import os as _os
DEBUG_RENAMES = _os.environ.get("DEBUG_RENAMES") == "1"


def find_zimr(rname):
    """Return list of zimr fns matching this raylib name (case-insensitive),
    or a synthetic single-element list if `rname` is in the explicit
    rename map."""
    rename = RAYLIB_TO_ZIMR_RENAMES.get(rname)
    if rename is not None:
        ns, target = rename
        if ns == "std":
            # Synthetic entry pointing to a stdlib equivalent.
            return [{
                "module": ns,
                "fn": target,
                "args": "",
                "ret": "",
                "has_alloc": False,
                "has_err": False,
                "is_std": True,
            }]
        # Look up the actual zimr fn in the named module.
        for f in zimr_fns:
            if f["module"] == ns and f["fn"] == target:
                return [f]
        # Rename-map target doesn't resolve.  Fall through to the
        # case-insensitive lookup below; warn if requested.
        if DEBUG_RENAMES:
            sys.stderr.write(
                f"[rename-map WARN] {rname} -> ({ns}, {target}) not found in zimr\n"
            )
    candidates = {rname.lower()}
    if rname[:1].isupper():
        candidates.add((rname[0].lower() + rname[1:]).lower())
    out = []
    for c in candidates:
        for f in zimr_by_lname.get(c, []):
            if f not in out:
                out.append(f)
    return out

# ==========================================================================
# Step 5: emit the cheatsheet
# ==========================================================================

# Audio used to be in DEFERRED but is now fully ported (audio-plan-v3:
# WAV+OGG end-to-end).  rgestures stays deferred — it's web-pointer-events
# territory we haven't touched yet.
DEFERRED = {"rgestures"}

total_raylib = len(raylib_master)
in_scope = sum(1 for r in raylib_master if r["module"] not in DEFERRED)
matched_in_scope = sum(
    1 for r in raylib_master
    if r["module"] not in DEFERRED and find_zimr(r["fn"])
)
matched_total = sum(1 for r in raylib_master if find_zimr(r["fn"]))

print("# zimr cheatsheet")
print()
print("_Auto-generated audit of zimr's API surface against raylib 6.0._  ")
print("_Modeled on raylib's own cheatsheet at https://www.raylib.com/cheatsheet/cheatsheet.html._  ")
print("_Re-generate with `python3 docs/cheatsheet-generator.py > docs/coverage-report.md`._")
print()

# Header stats
print("## Coverage at a glance")
print()
print("| Metric | Value |")
print("| ------ | ----- |")
print(f"| Total raylib functions (raylib.h + raymath.h + rlgl.h) | **{total_raylib}** |")
print(f"| Out of scope (rgestures, deferred) | {total_raylib - in_scope} |")
print(f"| In-scope raylib functions | **{in_scope}** |")
print(f"| Matched in zimr (by name) | **{matched_in_scope}** |")
print(f"| Intentionally not ported (web-platform mismatch / use stdlib) | {sum(1 for r in raylib_master if r['fn'] in NOT_PORTED)} |")
print(f"| **Coverage of in-scope raylib API** | **{100*matched_in_scope/in_scope:.1f}%** |")
print(f"| zimr public functions | {len(zimr_fns)} |")
print(f"| zimr functions with `Allocator` parameter | {sum(1 for f in zimr_fns if f['has_alloc'])} |")
print(f"| zimr functions returning error union | {sum(1 for f in zimr_fns if f['has_err'])} |")
print(f"| zimr functions fully ziggified (alloc + error) | {sum(1 for f in zimr_fns if f['has_alloc'] and f['has_err'])} |")
print(f"| zimr functions referenced by an example | {len(example_coverage)} ({100*len(example_coverage)/len(zimr_fns):.1f}%) |")
print(f"| zimr examples shipped | {len(example_files)} |")
print(f"| raylib reference example count | ~{RAYLIB_EXAMPLE_COUNT} |")
print(f"| **Example portage** | **{100*len(example_files)/RAYLIB_EXAMPLE_COUNT:.0f}%** |")
print()

# Per-module table
print("## Per-module coverage")
print()
print("| raylib module | raylib fns | ported | %  | example coverage |")
print("| ------------- | ---------: | -----: | -: | ---------------: |")
mod_order = ["core", "rcamera", "shapes", "textures", "text", "models",
             "audio", "rgestures", "raymath", "rlgl"]
for mod in mod_order:
    rfns = [r for r in raylib_master if r["module"] == mod]
    if not rfns:
        continue
    pported = sum(1 for r in rfns if find_zimr(r["fn"]))
    pct = 100 * pported / len(rfns)
    derived = []
    seen = set()
    for r in rfns:
        for d in find_zimr(r["fn"]):
            k = (d["module"], d["fn"])
            if k not in seen:
                seen.add(k)
                derived.append(d)
    used = sum(1 for d in derived if (d["module"], d["fn"]) in example_coverage)
    ex_pct = 100 * used / len(derived) if derived else 0
    note = " _(deferred)_" if mod in DEFERRED else ""
    print(f"| {mod}{note} | {len(rfns)} | {pported} | {pct:.1f}% | {used}/{len(derived)} ({ex_pct:.1f}%) |")
print()

# Function-by-function status
print("## Function-by-function status")
print()
print("Legend:  ✅ ported  ·  ❌ not yet ported  ·  🧪 exercised by an example  ·  💧 takes Allocator  ·  ❗ returns error union")
print()

by_module_cat = defaultdict(lambda: defaultdict(list))
for r in raylib_master:
    by_module_cat[r["module"]][r["category"]].append(r)

for mod in mod_order:
    if mod not in by_module_cat:
        continue
    print(f"### `{mod}`")
    print()
    for cat, fns in by_module_cat[mod].items():
        ported = sum(1 for f in fns if find_zimr(f["fn"]))
        print(f"#### {cat}  ({ported}/{len(fns)})")
        print()
        for r in fns:
            zfns = find_zimr(r["fn"])
            if zfns:
                best = next(
                    (z for z in zfns if z["fn"].lower() == r["fn"].lower()),
                    zfns[0]
                )
                in_examples = (best["module"], best["fn"]) in example_coverage
                marks = "✅"
                if in_examples:
                    marks += "🧪"
                if best["has_alloc"]:
                    marks += "💧"
                if best["has_err"]:
                    marks += "❗"
                ex_list = ""
                if in_examples:
                    ex_list = " — _" + ", ".join(example_coverage[(best["module"], best["fn"])][:3]) + "_"
                print(f"- {marks} `{r['fn']}` → `z.{best['module']}.{best['fn']}`{ex_list}")
            else:
                print(f"- ❌ `{r['fn']}({r['args'][:60]}{'...' if len(r['args'])>60 else ''})`")
        print()

# To-ziggify candidates
print("## Functions that should be ziggified")
print()
print("Functions whose names suggest they should take `Allocator` and/or return `!T`")
print("(load*, decode*, save*, gen*, build*, *FromMemory etc.) but don't yet.  Some of")
print("these are accurate as-is (e.g. legacy C-shim entry points by design); review")
print("each against its module's design before mechanically converting.")
print()

ziggify_keywords = ("load", "decode", "save", "gen", "build",
                    "fromMemory", "fromFile", "create", "import", "export")
to_ziggify = []
for f in zimr_fns:
    name_l = f["fn"].lower()
    suspicious = any(k.lower() in name_l for k in ziggify_keywords)
    # Don't flag wasm_fwd / rlgl_gpu — those are forwarders / GPU primitives
    skip = f["module"] in ("wasm_fwd", "rlgl_gpu", "rlgl")
    if suspicious and not (f["has_alloc"] and f["has_err"]) and not skip:
        to_ziggify.append(f)

print(f"_{len(to_ziggify)} candidates_")
print()
for f in to_ziggify:
    flags = []
    if not f["has_alloc"]:
        flags.append("no-alloc")
    if not f["has_err"]:
        flags.append("no-error")
    args_short = f["args"][:60] + ("..." if len(f["args"]) > 60 else "")
    print(f"- `z.{f['module']}.{f['fn']}({args_short})` -> `{f['ret']}`  _({', '.join(flags)})_")
print()

# ==========================================================================
# Zig-idiom audit — flag specific non-idiomatic patterns
# ==========================================================================
print("## Zig-idiom audit")
print()
print("Specific anti-patterns lurking in the public surface.  These are")
print("more actionable than the heuristic _ziggify_ list above — each entry")
print("here is an opportunity to drop a C-ism without changing semantics.")
print()

# Anti-pattern detectors.  Each returns a list of (label, fn_dict).
non_idiomatic = defaultdict(list)
zimr_names_set = {f["fn"] for f in zimr_fns}
for f in zimr_fns:
    # Skip wasm_fwd / rlgl_gpu / fwd — they're intentional C-shape
    # forwarders for the JS bridge.  rlgl preserves raylib's exact C
    # shape so user code that already targets rlgl translates verbatim.
    if f["module"] in ("wasm_fwd", "rlgl_gpu", "rlgl", "fwd"):
        continue
    args = f["args"]
    # 1. C-string parameters (null-terminated `[*:0]const u8`) — should
    #    be `[]const u8` (slice).  raylib heritage; we ziggified most
    #    in turns 1-10 but some remain.
    if "[*:0]" in args:
        non_idiomatic["C-string params (`[*:0]const u8`)"].append(f)
    # 2. C-style many-pointers (`[*c]T`) — should be `[]T` or `[*]T`.
    if "[*c]" in args or "[*c]" in f["ret"]:
        non_idiomatic["C-style many-pointer (`[*c]T`)"].append(f)
    # 3. `*c_int` / `*c_uint` out-params — should return a struct or ?T.
    if re.search(r"\*\s*c_(int|uint|long)", args):
        non_idiomatic["out-params via *c_int (`fn fooBar(out: *c_int)` style)"].append(f)
    # 4. `_z` suffix — convention from earlier ziggification.  We only
    #    flag the lowercase-underscore form (`_z`); bare `Z` suffixes
    #    are routinely axis names like `matrixRotateZ` and would
    #    false-positive.
    if f["fn"].endswith("_z"):
        non_idiomatic["`_z` suffix (likely vestigial slice-variant naming)"].append(f)
    # 5. Returns `anyerror` — should be a specific error set.
    if "anyerror" in f["ret"]:
        non_idiomatic["returns `anyerror` (should be a specific error set)"].append(f)

if non_idiomatic:
    for label, fns in non_idiomatic.items():
        print(f"### {label}  ({len(fns)})")
        print()
        for f in fns[:30]:
            args_short = f["args"][:60] + ("..." if len(f["args"]) > 60 else "")
            print(f"- `z.{f['module']}.{f['fn']}({args_short})` -> `{f['ret']}`")
        if len(fns) > 30:
            print(f"- _... and {len(fns) - 30} more_")
        print()
else:
    print("_No anti-patterns detected in current source._")
    print()

# To-port raylib functions (in-scope only)
print("## Top raylib functions still to port (in-scope only)")
print()
unmatched = [
    r for r in raylib_master
    if r["module"] not in DEFERRED and not find_zimr(r["fn"])
]
print(f"_{len(unmatched)} in-scope raylib functions not yet ported._")
print()

unmatched_by_mc = defaultdict(lambda: defaultdict(list))
for r in unmatched:
    unmatched_by_mc[r["module"]][r["category"]].append(r)

for mod in mod_order:
    if mod in DEFERRED or mod not in unmatched_by_mc:
        continue
    total_missing = sum(len(v) for v in unmatched_by_mc[mod].values())
    print(f"### `{mod}`  ({total_missing} missing)")
    print()
    for cat, fns in unmatched_by_mc[mod].items():
        print(f"**{cat}** ({len(fns)})")
        names = [r["fn"] for r in fns]
        for i in range(0, len(names), 3):
            row = names[i:i + 3]
            print("  - `" + "`  ·  `".join(row) + "`")
        print()


# ==========================================================================
# Step 6: emit HTML cheatsheet (modeled on raylib's cheatsheet.html)
#
# Outputs a single self-contained HTML file with all functions on one line
# each, grouped by module + category, with a brief comment.  Status icons:
#   ✓ ported   ✗ not ported   ⚑ intentionally skipped (web-platform mismatch)
#   ★ exercised by an example
#
# A small TOC at the top jumps to each module section.  Filter box at the
# top filters fns live by name match (vanilla JS, no deps).
# ==========================================================================

import html as _html

HTML_OUT = "/home/claude/zimr/src/notes/cheatsheet.html"


def html_escape(s):
    return _html.escape(s) if s else ""


def emit_html():
    parts = []
    P = parts.append

    P("<!doctype html>\n")
    P('<html lang="en"><head><meta charset="utf-8">\n')
    P("<title>zimr cheatsheet</title>\n")
    P('<meta name="viewport" content="width=device-width,initial-scale=1">\n')
    P("<style>\n")
    P("""
    :root {
        --bg: #1a1d23;
        --fg: #e7e9ee;
        --muted: #8b94a3;
        --accent: #f6c177;
        --ok: #a3e3a3;
        --bad: #e58e8e;
        --skip: #8aa9d6;
        --code-bg: #14161b;
        --border: #2a2e36;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        font-size: 14px;
        line-height: 1.5;
    }
    header {
        padding: 24px 32px 12px;
        border-bottom: 1px solid var(--border);
        position: sticky;
        top: 0;
        background: var(--bg);
        z-index: 10;
    }
    header h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
    header p.tag { margin: 0; color: var(--muted); font-size: 13px; }
    #stats {
        display: flex;
        gap: 24px;
        flex-wrap: wrap;
        padding: 12px 32px;
        background: #20242c;
        font-size: 13px;
        border-bottom: 1px solid var(--border);
    }
    #stats .stat .num { color: var(--accent); font-weight: 600; font-size: 16px; }
    #stats .stat .label { color: var(--muted); margin-left: 4px; }
    #toc {
        padding: 12px 32px;
        background: #20242c;
        border-bottom: 1px solid var(--border);
        display: flex;
        gap: 16px;
        flex-wrap: wrap;
        align-items: center;
    }
    #toc a {
        color: var(--accent);
        text-decoration: none;
        font-weight: 500;
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 13px;
    }
    #toc a:hover { text-decoration: underline; }
    #filter {
        margin-left: auto;
        padding: 6px 10px;
        background: var(--code-bg);
        color: var(--fg);
        border: 1px solid var(--border);
        border-radius: 4px;
        font-size: 13px;
        font-family: ui-monospace, monospace;
        min-width: 200px;
    }
    main { padding: 16px 32px 64px; }
    section.module {
        margin-top: 24px;
        border-top: 1px solid var(--border);
        padding-top: 12px;
    }
    section.module > h2 {
        font-size: 18px;
        font-weight: 600;
        margin: 0 0 4px;
        color: var(--fg);
    }
    section.module > h2 .pct {
        margin-left: 12px;
        font-size: 13px;
        color: var(--muted);
        font-weight: 400;
    }
    section.module h3 {
        font-size: 13px;
        font-weight: 500;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--muted);
        margin: 18px 0 4px;
    }
    .fn {
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 13px;
        padding: 2px 0;
        display: grid;
        grid-template-columns: 24px minmax(280px, 0.5fr) 1fr;
        gap: 12px;
        align-items: baseline;
    }
    .fn .icon { text-align: center; user-select: none; font-size: 14px; }
    .fn .icon.ok { color: var(--ok); }
    .fn .icon.bad { color: var(--bad); }
    .fn .icon.skip { color: var(--skip); }
    .fn .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .fn .name .arrow { color: var(--muted); }
    .fn .name .target { color: var(--accent); }
    .fn .desc { color: var(--muted); font-family: -apple-system, sans-serif; font-size: 13px; }
    .fn .desc .star { color: var(--accent); margin-right: 4px; }
    .fn.hidden { display: none; }
    .fn.skipped { opacity: 0.6; }
    .fn .desc .skipnote { color: var(--skip); font-style: italic; }
    .legend {
        font-size: 12px;
        color: var(--muted);
        padding: 8px 32px;
        border-bottom: 1px solid var(--border);
    }
    .legend .icon { display: inline-block; width: 16px; text-align: center; }
    """)
    P("\n</style>\n")
    P("</head><body>\n")

    # -- Header --
    P('<header>\n')
    P('  <h1>zimr cheatsheet</h1>\n')
    P('  <p class="tag">Public API surface · auto-generated against raylib 6.0 · '
      f'{matched_in_scope}/{in_scope} of in-scope raylib functions covered '
      f'({100*matched_in_scope/in_scope:.0f}%)</p>\n')
    P('</header>\n')

    # -- Legend --
    P('<div class="legend">\n')
    P('  <span class="icon ok">✓</span> ported &nbsp; ')
    P('<span class="icon bad">✗</span> not ported &nbsp; ')
    P('<span class="icon skip">⚑</span> intentionally skipped (web-platform mismatch / use stdlib) &nbsp; ')
    P('<span style="color:var(--accent)">★</span> exercised by an example\n')
    P('</div>\n')

    # -- Stats --
    intentionally_skipped = sum(1 for r in raylib_master if r["fn"] in NOT_PORTED)
    P('<div id="stats">\n')
    P(f'  <div class="stat"><span class="num">{total_raylib}</span><span class="label">raylib functions</span></div>\n')
    P(f'  <div class="stat"><span class="num">{matched_in_scope}</span><span class="label">ported</span></div>\n')
    P(f'  <div class="stat"><span class="num">{intentionally_skipped}</span><span class="label">intentionally skipped</span></div>\n')
    P(f'  <div class="stat"><span class="num">{len(zimr_fns)}</span><span class="label">zimr public fns</span></div>\n')
    P(f'  <div class="stat"><span class="num">{len(example_files)}</span><span class="label">examples</span></div>\n')
    P(f'  <div class="stat"><span class="num">{len(example_coverage)}</span><span class="label">fns exercised</span></div>\n')
    P('</div>\n')

    # -- TOC + filter --
    P('<nav id="toc">\n')
    for mod in mod_order:
        if mod not in by_module_cat:
            continue
        rfns = [r for r in raylib_master if r["module"] == mod]
        pp = sum(1 for r in rfns if find_zimr(r["fn"]))
        deferred = " (skipped)" if mod in DEFERRED else ""
        P(f'  <a href="#{html_escape(mod)}">{html_escape(mod)} <span style="color:var(--muted)">{pp}/{len(rfns)}{deferred}</span></a>\n')
    P('  <input id="filter" type="search" placeholder="filter by name…" autocomplete="off">\n')
    P('</nav>\n')

    P('<main>\n')

    for mod in mod_order:
        if mod not in by_module_cat:
            continue
        rfns_all = [r for r in raylib_master if r["module"] == mod]
        pported = sum(1 for r in rfns_all if find_zimr(r["fn"]))
        pct = 100 * pported / len(rfns_all)
        deferred_note = ' <span style="color:var(--skip)">(deferred)</span>' if mod in DEFERRED else ""

        P(f'<section class="module" id="{html_escape(mod)}">\n')
        P(f'  <h2>{html_escape(mod)}{deferred_note}<span class="pct">{pported} / {len(rfns_all)} ({pct:.0f}%)</span></h2>\n')

        for cat, fns in by_module_cat[mod].items():
            P(f'  <h3>{html_escape(cat)}</h3>\n')
            for r in fns:
                zfns = find_zimr(r["fn"])
                rname = r["fn"]
                rcomment = r.get("comment", "")
                if zfns:
                    best = next(
                        (z for z in zfns if z["fn"].lower() == rname.lower()),
                        zfns[0]
                    )
                    in_examples = (best["module"], best["fn"]) in example_coverage
                    star = '<span class="star" title="exercised by an example">★</span>' if in_examples else ""
                    desc = best.get("brief") or rcomment or ""
                    name_html = (f'<span class="name"><b>{html_escape(rname)}</b>'
                                 f' <span class="arrow">→</span> '
                                 f'<span class="target">z.{html_escape(best["module"])}.{html_escape(best["fn"])}</span>'
                                 f'</span>')
                    P(f'  <div class="fn"><span class="icon ok">✓</span>{name_html}'
                      f'<span class="desc">{star}{html_escape(desc)}</span></div>\n')
                elif rname in NOT_PORTED:
                    name_html = f'<span class="name"><b>{html_escape(rname)}</b></span>'
                    skip_reason = NOT_PORTED[rname]
                    P(f'  <div class="fn skipped"><span class="icon skip">⚑</span>{name_html}'
                      f'<span class="desc"><span class="skipnote">skipped:</span> {html_escape(skip_reason)}</span></div>\n')
                else:
                    name_html = f'<span class="name"><b>{html_escape(rname)}</b></span>'
                    P(f'  <div class="fn"><span class="icon bad">✗</span>{name_html}'
                      f'<span class="desc">{html_escape(rcomment)}</span></div>\n')

        P('</section>\n')

    P('</main>\n')

    # -- Filter JS --
    P('<script>\n')
    P("""
    const inp = document.getElementById('filter');
    const fns = Array.from(document.querySelectorAll('.fn'));
    inp.addEventListener('input', () => {
        const q = inp.value.trim().toLowerCase();
        for (const f of fns) {
            const txt = f.textContent.toLowerCase();
            if (q === '' || txt.includes(q)) {
                f.classList.remove('hidden');
            } else {
                f.classList.add('hidden');
            }
        }
    });
    """)
    P('\n</script>\n')
    P('</body></html>\n')

    out = "".join(parts)
    with open(HTML_OUT, "w") as fh:
        fh.write(out)
    sys.stderr.write(f"[html] wrote {HTML_OUT} ({len(out):,} bytes)\n")


emit_html()
