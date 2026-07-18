#!/usr/bin/env python3
# tools/gl2wgpu_ui.py — GL→WebGPU migration helper for UiContext/UiHost examples.
#
# Converts a GL example (examples/<base>.zig, using `zimr_app.run` + `ui.UiContext`)
# into a wgpu descriptor example (examples/wgpu_<base>/wgpu_<base>.zig, using
# `z.AppSpec` + `z.UiHost`). One-shot: folds in every fixup we'd otherwise apply by
# hand (snake_case consts, .ctx accessors, z.ui_real, f.time.time).
#
# The fiddly bit is initState. GL's signature is an out-param
# `fn initState(gpa, _, s: *State) !void` that fills `s.*`; wgpu wants
# `fn initState(gpa, f) !State` that RETURNS a State. Naively rewriting
# `s.* = .{...};` → `return .{...};` breaks any example that SEEDS state after the
# literal (loops calling `func(s)`, @memcpy, etc.) — the seeding becomes unreachable
# and `s` is undefined. Instead we keep `s` as a `*State` pointing at a local
# `result`, so the body is untouched, and `return result;` at the end:
#
#     fn initState(gpa, f) !State {
#         const font = try z.loadFont(...);
#         var result: State = undefined;
#         const s: *State = &result;
#         s.* = .{ .ui_host = z.UiHost.init(gpa, font) };   // converted literal
#         <original seeding, verbatim — s.x and func(s) just work>
#         return result;
#     }
#
# Examples NOT handled (need separate work, will assert/fail loudly):
#   - draw-list with u32/ColorU32 colors (DrawList add* take Color now)
#   - inputMultiline already works (textarea overlay), but verify per-example
#   - resisters with a non-standard initState/beginFrame signature

import re
import os
import sys


def port(base: str, font_size: int = 22) -> str:
    src = f"examples/{base}.zig"
    s = open(src).read()
    orig = s

    # --- imports ---
    s = s.replace('const z = @import("zimr");', 'const z = @import("zimr");', 1)
    s = s.replace("const ui = z.ui;", "const ui = z.ui_real;", 1)
    s = s.replace("z.ui.", "z.ui_real.")  # inline z.ui.X references

    # --- State: drop GL UI-host fields, swap the context type ---
    s = re.sub(r"\n[ \t]*font_cache: z\.FontCache = \.\{\},", "", s)
    s = re.sub(r"\n[ \t]*shapes_texture: z\.ShapesTextureState = \.\{\},", "", s)
    s = s.replace("ui_ctx: ui.UiContext,", "ui_host: z.UiHost,", 1)
    s = s.replace("ui_ctx: z.ui_real.UiContext,", "ui_host: z.UiHost,", 1)
    s = s.replace("ui_ctx: ui.UiContext = undefined,", "ui_host: z.UiHost = undefined,", 1)
    s = s.replace("ui_ctx: z.ui_real.UiContext = undefined,", "ui_host: z.UiHost = undefined,", 1)
    s = s.replace("s.ui_ctx", "s.ui_host")
    # UiContext fields accessed via the host go through .ctx (UiHost wraps UiContext)
    for field in ("persistence_key", "metrics", "debug_log"):
        s = s.replace(f"s.ui_host.{field}", f"s.ui_host.ctx.{field}")

    # --- window config (title/width/height for the AppSpec) ---
    m = re.search(r"\.window = \.\{(.*?)\},\s*\},\s*State,\s*initState,\s*update\);", s, re.S)
    win = m.group(1)
    title = re.search(r'\.title = ("[^"]*")', win).group(1)
    width = re.search(r"\.width = ([^,\n]+),", win).group(1).strip()
    height = re.search(r"\.height = ([^,\n]+),", win).group(1).strip()

    # --- main block -> AppSpec + deinit ---
    # The zimr_app bridge and `pub fn main` may be ADJACENT (most examples) or
    # SEPARATED by the State struct / helper fns (e.g. input_flags_zoo, notes).
    # Match each independently so both layouts work.
    zimr_app_re = re.compile(r"(?:///[^\n]*\n)*pub var zimr_app: z\.AppBridge = \.\{\};\s*\n")
    main_re = re.compile(
        r"pub fn main\(init: std\.process\.Init\) !void \{.*?\}, State,\s*initState,\s*update\);\s*\n\}",
        re.S,
    )
    app = (
        "pub const app: z.AppSpec(State) = .{\n"
        "    .config = .{\n"
        "        .window = .{\n"
        f"            .title = {title},\n"
        f"            .width = {width},\n"
        f"            .height = {height},\n"
        "            .scale_mode = .responsive,\n"
        "            .depth_format = null,\n"
        "        },\n"
        "    },\n"
        "    .init = initState,\n"
        "    .deinit = deinit,\n"
        "    .update = update,\n"
        "};\n\n"
        "fn deinit(gpa: std.mem.Allocator, s: *State) void {\n"
        "    _ = gpa;\n"
        "    s.ui_host.deinit();\n"
        "}"
    )
    s, n0 = zimr_app_re.subn("", s, 1)
    assert n0 == 1, f"{base}: zimr_app decl not found"
    s, n = main_re.subn(app, s, 1)
    assert n == 1, f"{base}: main block not matched"

    # --- initState: out-param -> return State (robust; body untouched) ---
    init_re = re.compile(
        r"fn initState\(\s*gpa: std\.mem\.Allocator,\s*[_a-z]+: \*z\.Frame,\s*s: \*State,\s*\) !void \{(.*?)\n\}",
        re.S,
    )
    mi = init_re.search(s)
    assert mi, f"{base}: initState signature not matched"
    body = mi.group(1)
    body = re.sub(r"[ \t]*try z\.loadFontFromTtfBytes\(.*?\);\n?", "", body, count=1, flags=re.S)
    body = body.replace(".ui_ctx = ui.UiContext.init(gpa)", ".ui_host = z.UiHost.init(gpa, font)")
    body = body.replace(".ui_ctx = z.ui_real.UiContext.init(gpa)", ".ui_host = z.UiHost.init(gpa, font)")
    new_init = (
        "fn initState(gpa: std.mem.Allocator, f: *z.Frame) !State {\n"
        f'    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), {font_size});\n'
        "    var result: State = undefined;\n"
        "    const s: *State = &result;"
        f"{body}\n"
        "    return result;\n}"
    )
    s = s[: mi.start()] + new_init + s[mi.end():]

    # strip GL style-tweaks in initState (UiHost defaults cover them)
    s = re.sub(r"[ \t]*s\.ui_host\.style\.[a-z_]+ = [^;]+;\n", "", s)

    # --- update: the runner owns the frame ---
    s = re.sub(r"[ \t]*z\.beginDrawing\(f\.gl\);\n", "", s)
    s = re.sub(r"[ \t]*defer z\.endDrawing\(f\.gl\);\n", "", s)
    s = re.sub(r"[ \t]*z\.endDrawing\(f\.gl\);\n", "", s)
    s = re.sub(r"z\.clearBackground\(f\.gl, ", "z.clearViewport(f, ", s)
    s = s.replace("s.ui_host.beginFrame(f, &s.shapes_texture, &s.font_cache)", "s.ui_host.begin(f)")
    s = s.replace("s.ui_host.endFrame(f, &s.shapes_texture, &s.font_cache)", "s.ui_host.render(f)")

    # --- widget/API fixups (folded in so port() is one-shot) ---
    s = s.replace(".ui_host.style", ".ui_host.ctx.style")
    s = s.replace(".ui_host.input", ".ui_host.ctx.input")
    s = s.replace(".ui_host.drag_drop", ".ui_host.ctx.drag_drop")
    s = s.replace("f.time.current", "f.time.time")

    # snake_case SCREAMING module-level consts (the lint forbids SCREAMING_CASE)
    for name in sorted(set(re.findall(r"\bconst ([A-Z][A-Z0-9_]+)\b", s)), key=len, reverse=True):
        s = re.sub(r"\b" + name + r"\b", name.lower(), s)

    # late: statement-form `s.X = ui.UiContext.init(gpa)` escapes the literal pass
    s = s.replace("ui.UiContext.init(gpa)", "z.UiHost.init(gpa, font)")
    s = s.replace("z.ui_real.UiContext.init(gpa)", "z.UiHost.init(gpa, font)")

    # --- guards ---
    assert s != orig, f"{base}: no change"
    code = re.sub(r"//[^\n]*", "", s)  # ignore // comments
    code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)  # ignore "..." string literals
    code = re.sub(r"\\\\[^\n]*", "", code)  # ignore \\ multiline string lines
    assert "UiContext" not in code, f"{base}: UiContext residual"
    assert "beginFrame" not in code and "endFrame" not in code, f"{base}: beginFrame/endFrame residual"
    assert "zimr_app" not in code, f"{base}: zimr_app residual"

    os.makedirs(f"examples/wgpu_{base}", exist_ok=True)
    open(f"examples/wgpu_{base}/wgpu_{base}.zig", "w").write(s)
    return title


if __name__ == "__main__":
    for b in sys.argv[1:]:
        t = port(b)
        print(f"ported {b}  title={t}")
