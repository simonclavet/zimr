//! bridge.zig - THE zimr host monolith (ZIG_BRIDGE_PLAN, t1178+).
//!
//! This file is the entire browser side of zimr, written in Zig and
//! transpiled to JavaScript (zig build-obj -ofmt=c -> tools/c2js -> page).
//! ONE file by charter: it absorbs the webzig interop kernel (wz.zig,
//! taken from intake/webzig-all at Phase 1), and will grow - in banner
//! sections, draw3d-style - the Site/boot runtime with zimr's WebGPU
//! async preamble, the ~60 wgpu import implementations, the dom glue,
//! the overlay-input port, and the WebAudio section. Its `export fn
//! start()` IS the page entry point for every example.
//!
//! Style: foreign (webzig) until the scheduled cleanup pass - in the
//! lint skip ledger; the no-closures / no-indirect-calls transpiler
//! constraints are LAW here (callbacks are named fns via `func`).
//!
//! Self-import note: the absorbed kernel referred to itself as
//! @import("wz"); inside the monolith those references are local.

// Reflection helper. In Zig 0.17.0-dev.813, `@typeInfo(T).@"struct"` exposes field
// and decl metadata as parallel `.field_names`/`.field_types`/`.decl_names` arrays
// rather than an array of structs each carrying `.name`/`.type`. This pairs them
// into a {name, type} view (comptime-only) so the reflection loops below read one list.
const FieldRef = struct { name: [:0]const u8, type: type };
fn structFields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]FieldRef {
    const si = @typeInfo(T).@"struct";
    var list: [si.field_names.len]FieldRef = undefined;
    for (si.field_names, si.field_types, 0..) |field_name, field_type, i| {
        list[i] = .{ .name = field_name, .type = field_type };
    }
    return list;
}
const DeclRef = struct { name: [:0]const u8 };
fn structDecls(comptime T: type) [@typeInfo(T).@"struct".decl_names.len]DeclRef {
    const names = @typeInfo(T).@"struct".decl_names;
    var list: [names.len]DeclRef = undefined;
    for (names, 0..) |decl_name, i| {
        list[i] = .{ .name = decl_name };
    }
    return list;
}

// ===========================================================================
// The interop kernel (provided by the transpiler's baked-in JavaScript).
// ===========================================================================
pub const Handle = u32;

extern fn js_global() Handle;
extern fn js_get(
    o: Handle,
    p: [*]const u8,
    l: u32,
) Handle;
extern fn js_get_index(o: Handle, i: u32) Handle;
extern fn js_get_num(
    o: Handle,
    p: [*]const u8,
    l: u32,
) f64;
extern fn js_set(
    o: Handle,
    p: [*]const u8,
    l: u32,
    v: Handle,
) void;
extern fn js_set_num(
    o: Handle,
    p: [*]const u8,
    l: u32,
    x: f64,
) void;
extern fn js_set_index(
    o: Handle,
    i: u32,
    v: Handle,
) void;
extern fn js_call0(
    o: Handle,
    p: [*]const u8,
    l: u32,
) Handle;
extern fn js_call1(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
) Handle;
extern fn js_call2(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) Handle;
extern fn js_call3(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
) Handle;
extern fn js_call4(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
    d: Handle,
) Handle;
extern fn js_call5(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
    d: Handle,
    e: Handle,
) Handle;
extern fn js_call6(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
    d: Handle,
    e: Handle,
    sixth: Handle,
) Handle;
extern fn js_call_n(
    o: Handle,
    p: [*]const u8,
    l: u32,
    argp: u32,
    n: u32,
) Handle;
extern fn js_new0(c: Handle) Handle;
extern fn js_new1(c: Handle, a: Handle) Handle;
/// Like `js_new1`, but returns the null handle instead of letting the constructor's
/// exception escape into wasm. `new Worker(blobUrl)` throws in a sandboxed iframe, and
/// zimr must survive that rather than take the page down with it.
extern fn js_try_new1(c: Handle, a: Handle) Handle;
extern fn js_new2(
    c: Handle,
    a: Handle,
    b: Handle,
) Handle;
extern fn js_new3(
    c: Handle,
    a: Handle,
    b: Handle,
    d: Handle,
) Handle;
extern fn js_str(p: [*]const u8, l: u32) Handle;
/// Copy `l` bytes of the bridge's own memory at `p` into a fresh, standalone JS
/// Uint8Array (binary-safe, unlike js_str's UTF-8 decode). Used to lift `@embedFile`
/// asset bytes into a JS value that outlives the call.
extern fn js_bytes(p: [*]const u8, l: u32) Handle;
extern fn js_num(x: f64) Handle;
extern fn js_to_num(v: Handle) f64;
extern fn js_truthy(v: Handle) u32;
extern fn js_is_null(v: Handle) u32;
extern fn js_strict_eq(a: Handle, b: Handle) u32;
extern fn js_typeof(v: Handle) Handle;
extern fn js_func(f: *const anyopaque) Handle;
extern fn js_fn_num(f: *const anyopaque) Handle;
extern fn js_func_ctx(f: *const anyopaque, ctx: u32) Handle;
extern fn js_array() Handle;
extern fn js_push(arr: Handle, v: Handle) Handle;
extern fn js_len(v: Handle) u32;
extern fn js_free(v: Handle) void;
// Handle-table frame scope: js_mark() snapshots the table length; js_reset(m)
// reclaims every handle interned since the mark. wz.Site brackets each frame so
// per-frame transients (fmt strings, call args/returns, looked-up elements) are
// auto-freed, while handles created in onReady (below the first mark) persist.
extern fn js_mark() Handle;
extern fn js_reset(m: Handle) void;
// object literal + void-call (no return handle) + module->bridge bulk copy.
extern fn js_obj() Handle;
extern fn js_call0v(
    o: Handle,
    p: [*]const u8,
    l: u32,
) void;
extern fn js_call1v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
) void;
extern fn js_call2v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) void;
extern fn js_call3v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
) void;
extern fn js_call4v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
    d: Handle,
) void;
extern fn js_call5v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
    d: Handle,
    e: Handle,
) void;
extern fn js_read_into(
    dst: u32,
    src_mem: Handle,
    src_off: u32,
    len: u32,
) void;
// numeric-arg fast path: args passed as raw f64, no per-arg handle minted.
extern fn js_calln1(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
) Handle;
extern fn js_calln2(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
) Handle;
extern fn js_calln3(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
) Handle;
extern fn js_calln4(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
) Handle;
extern fn js_calln5(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
) Handle;
extern fn js_calln6(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    sixth: f64,
) Handle;
extern fn js_calln1v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
) void;
extern fn js_calln2v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
) void;
extern fn js_calln3v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
) void;
extern fn js_calln4v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
) void;
extern fn js_calln5v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
) void;
extern fn js_calln6v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    sixth: f64,
) void;

// ===========================================================================
// Argument marshalling: turn any supported Zig value into a JS handle.
// Resolved at comptime by type, so it compiles to a direct js_num / js_str /
// passthrough with no branching.
// ===========================================================================
inline fn f64of(x: anytype) f64 {
    return switch (@typeInfo(@TypeOf(x))) {
        .float, .comptime_float => x,
        else => @floatFromInt(x),
    };
}

fn allNumeric(comptime ArgsT: type) bool {
    inline for (structFields(ArgsT)) |f| switch (@typeInfo(f.type)) {
        .int, .comptime_int, .float, .comptime_float => {},
        else => return false,
    };
    return true;
}

fn tupleToH(t: anytype) Handle {
    const tuple_array: Handle = js_array();
    inline for (structFields(@TypeOf(t))) |f| {
        // toH dispatches tuples back to tupleToH (and tupleToH converts each
        // field via toH) - mutual recursion, so neither is fully before the other.
        // lint:off decl-order: mutual recursion toH<->tupleToH
        _ = js_push(tuple_array, toH(@field(t, f.name)));
    }
    return tuple_array;
}

fn snakeToCamel(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var up: bool = false;
        for (s) |c| {
            if (c == '_') {
                up = true;
            } else if (up) {
                out = out ++ [_]u8{if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c};
                up = false;
            } else {
                out = out ++ [_]u8{c};
            }
        }
        return out;
    }
}

fn objToH(fields: anytype) Handle {
    const o: Handle = js_obj();
    // Value is the base JS-handle wrapper used pervasively from the top of this file,
    // but its own methods reference the `g` page singleton (handle table + scratch)
    // defined far below with the other globals - a Value<->g dependency, so Value can't
    // precede all its users without dragging the whole globals cluster above it.
    // lint:off decl-order: Value<->g cycle (base wrapper uses the page-globals singleton)
    const v = Value{ .h = o };
    inline for (structFields(@TypeOf(fields))) |f| {
        v.set(comptime snakeToCamel(f.name), @field(fields, f.name));
    }
    return o;
}

inline fn toH(arg: anytype) Handle {
    const T = @TypeOf(arg);
    if (T == Value) {
        return arg.h;
    }
    return switch (@typeInfo(T)) {
        .float, .comptime_float => js_num(arg),
        .int, .comptime_int => js_num(@floatFromInt(arg)),
        .bool => js_num(if (arg) 1 else 0),
        // strings: either a slice ([]const u8) or a pointer to a byte array
        // (*const [N:0]u8, what a string literal is). Normalize to ptr+len.
        .pointer => |ptr| switch (ptr.size) {
            .slice => js_str(arg.ptr, @intCast(arg.len)),
            else => js_str(arg, arg.len), // *const [N:0]u8 coerces to [*]const u8
        },
        // an anonymous struct becomes a JS object (fields snake_case -> camelCase);
        // a tuple `.{a, b}` becomes a JS array. Recurses, so nested descriptors and
        // arrays-of-objects build in one expression. (wz.obj is the named entry point.)
        .@"struct" => |s| if (s.is_tuple) tupleToH(arg) else objToH(arg),
        else => @compileError("js: cannot pass value of type " ++ @typeName(T) ++ " to JS"),
    };
}

pub fn global() Value {
    return .{ .h = js_global() };
}

/// An explicit JS string from a Zig string literal (when you need a Value).
pub fn str(comptime s: []const u8) Value {
    return .{ .h = js_str(s.ptr, @intCast(s.len)) };
}

/// Wrap a Zig function as a JS callback value (for event listeners, rAF, ...).
/// Pass it the address of a function: `func(&onClick)`.
pub fn func(f: *const anyopaque) Value {
    return .{ .h = js_func(f) };
}

/// CanvasRenderingContext2D - the common 2D drawing API, typed.
pub const Ctx2D = extern struct {
    j: Value,

    // properties (set)
    pub fn fillStyle(self: Ctx2D, v: anytype) void {
        self.j.set("fillStyle", v);
    }
    pub fn strokeStyle(self: Ctx2D, v: anytype) void {
        self.j.set("strokeStyle", v);
    }
    pub fn lineWidth(self: Ctx2D, w: f32) void {
        self.j.set("lineWidth", w);
    }
    pub fn font(self: Ctx2D, comptime f: []const u8) void {
        self.j.set("font", str(f));
    }
    pub fn textAlign(self: Ctx2D, comptime a: []const u8) void {
        self.j.set("textAlign", str(a));
    }
    pub fn globalAlpha(self: Ctx2D, a: f32) void {
        self.j.set("globalAlpha", a);
    }

    // rectangles
    pub fn fillRect(
        self: Ctx2D,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        _ = self.j.call("fillRect", .{ x, y, w, h });
    }
    pub fn strokeRect(
        self: Ctx2D,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        _ = self.j.call("strokeRect", .{ x, y, w, h });
    }
    pub fn clearRect(
        self: Ctx2D,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        _ = self.j.call("clearRect", .{ x, y, w, h });
    }

    // paths
    pub fn beginPath(self: Ctx2D) void {
        _ = self.j.call("beginPath", .{});
    }
    pub fn closePath(self: Ctx2D) void {
        _ = self.j.call("closePath", .{});
    }
    pub fn moveTo(
        self: Ctx2D,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("moveTo", .{ x, y });
    }
    pub fn lineTo(
        self: Ctx2D,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("lineTo", .{ x, y });
    }
    pub fn arc(
        self: Ctx2D,
        x: f32,
        y: f32,
        r: f32,
        start_angle: f32,
        end_angle: f32,
    ) void {
        _ = self.j.call("arc", .{ x, y, r, start_angle, end_angle });
    }
    pub fn rect(
        self: Ctx2D,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        _ = self.j.call("rect", .{ x, y, w, h });
    }
    pub fn fill(self: Ctx2D) void {
        _ = self.j.call("fill", .{});
    }
    pub fn stroke(self: Ctx2D) void {
        _ = self.j.call("stroke", .{});
    }

    // text
    pub fn fillText(
        self: Ctx2D,
        text: anytype,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("fillText", .{ text, x, y });
    }
    pub fn strokeText(
        self: Ctx2D,
        text: anytype,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("strokeText", .{ text, x, y });
    }

    // transforms / state
    pub fn save(self: Ctx2D) void {
        _ = self.j.call("save", .{});
    }
    pub fn restore(self: Ctx2D) void {
        _ = self.j.call("restore", .{});
    }
    pub fn translate(
        self: Ctx2D,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("translate", .{ x, y });
    }
    pub fn rotate(self: Ctx2D, a: f32) void {
        _ = self.j.call("rotate", .{a});
    }
    pub fn scale(
        self: Ctx2D,
        x: f32,
        y: f32,
    ) void {
        _ = self.j.call("scale", .{ x, y });
    }
};

inline fn putc(c: u8) void {
    // `g` is THE page singleton (var g: BridgeGlobals); BridgeGlobals aggregates the
    // handle table + scratch buffers that wrap Value and the DOM types, so it lives at
    // the bottom after the cluster it owns, yet is used pervasively from here upward.
    // lint:off decl-order: page singleton g defined after the wrapper cluster it aggregates
    g.scratch.fmt[g.scratch.fmt_len] = c;
    g.scratch.fmt_len += 1;
}

fn putInt(v: i32) void {
    var n: i32 = v;
    if (n < 0) {
        putc('-');
        n = -n;
    }
    if (n == 0) {
        putc('0');
        return;
    }
    var tmp: [12]u8 = undefined;
    var k: u32 = 0;
    while (n > 0) {
        tmp[k] = '0' + @as(u8, @intCast(@mod(n, 10)));
        k += 1;
        n = @divTrunc(n, 10);
    }
    while (k > 0) {
        k -= 1;
        putc(tmp[k]);
    }
}

inline fn putArg(arg: anytype) void {
    const T = @TypeOf(arg);
    switch (@typeInfo(T)) {
        .int, .comptime_int => putInt(@intCast(arg)),
        .float, .comptime_float => putInt(@trunc(arg)),
        .pointer => inline for (arg) |c| {
            putc(c);
        }, // string literal bytes
        else => @compileError("fmt: cannot format value of type " ++ @typeName(T)),
    }
}

/// Build a JS string from a `{}`-placeholder template and a tuple of args.
pub fn fmt(comptime spec: []const u8, args: anytype) Value {
    g.scratch.fmt_len = 0;
    comptime var ai: usize = 0;
    comptime var i: usize = 0;
    inline while (i < spec.len) {
        if (spec[i] == '{' and i + 1 < spec.len and spec[i + 1] == '}') {
            putArg(args[ai]);
            ai += 1;
            i += 2;
        } else {
            putc(spec[i]);
            i += 1;
        }
    }
    return .{ .h = js_str(&g.scratch.fmt, g.scratch.fmt_len) };
}

pub const Element = extern struct {
    j: Value,

    /// el.value (as a JS value; chain `.to(f64)` / `.to(i32)` to read it)
    pub fn value(self: Element) Value {
        return self.j.get("value");
    }
    /// el.value = v
    pub fn setValue(self: Element, v: anytype) void {
        self.j.set("value", v);
    }
    /// el.textContent = v   (v: a string literal, number, or Value)
    pub fn setText(self: Element, v: anytype) void {
        self.j.set("textContent", v);
    }
    /// el.innerHTML = v
    pub fn setHtml(self: Element, v: anytype) void {
        self.j.set("innerHTML", v);
    }
    pub fn setId(self: Element, comptime id: []const u8) void {
        self.j.set("id", str(id));
    }
    pub fn setClass(self: Element, comptime cls: []const u8) void {
        self.j.set("className", str(cls));
    }
    /// el.setAttribute(name, value)
    pub fn setAttr(
        self: Element,
        comptime name: []const u8,
        comptime val: []const u8,
    ) void {
        _ = self.j.call("setAttribute", .{ str(name), str(val) });
    }
    /// el.setAttribute("style", css) - inline styles.
    pub fn setStyle(self: Element, comptime css_text: []const u8) void {
        _ = self.j.call("setAttribute", .{ str("style"), str(css_text) });
    }
    pub fn width(self: Element) f32 {
        return self.j.get("width").to(f32);
    }
    pub fn height(self: Element) f32 {
        return self.j.get("height").to(f32);
    }
    /// el.addEventListener(type, handler) - pass a Zig fn address: `.on("click", &f)`
    pub fn on(
        self: Element,
        comptime event: []const u8,
        handler: *const anyopaque,
    ) void {
        _ = self.j.call("addEventListener", .{ str(event), func(handler) });
    }
    /// el.appendChild(node)
    pub fn append(self: Element, node: Element) void {
        _ = self.j.call("appendChild", .{node.j});
    }
    /// el.getContext("2d")
    pub fn getContext2D(self: Element) Ctx2D {
        return .{ .j = self.j.call("getContext", .{str("2d")}) };
    }

    /// el.textContent = fmt(spec, args) - the format-aware text setter, the line
    /// you write most: `out.setFmt("You clicked {} times", .{count})`.
    pub fn setFmt(
        self: Element,
        comptime spec: []const u8,
        args: anytype,
    ) void {
        self.j.set("textContent", fmt(spec, args));
    }

    // classList - toggle UI state without touching className strings by hand.
    pub fn addClass(self: Element, comptime cls: []const u8) void {
        _ = self.j.get("classList").call("add", .{str(cls)});
    }
    pub fn removeClass(self: Element, comptime cls: []const u8) void {
        _ = self.j.get("classList").call("remove", .{str(cls)});
    }
    /// el.classList.toggle(cls) -> whether the class is now present.
    pub fn toggleClass(self: Element, comptime cls: []const u8) bool {
        return self.j.get("classList").call("toggle", .{str(cls)}).truthy();
    }
    pub fn hasClass(self: Element, comptime cls: []const u8) bool {
        return self.j.get("classList").call("contains", .{str(cls)}).truthy();
    }

    // form/interaction state
    /// el.checked (checkboxes/radios)
    pub fn checked(self: Element) bool {
        return self.j.get("checked").truthy();
    }
    pub fn setChecked(self: Element, on_: bool) void {
        self.j.set("checked", on_);
    }
    pub fn setDisabled(self: Element, on_: bool) void {
        self.j.set("disabled", on_);
    }
    pub fn focus(self: Element) void {
        _ = self.j.call("focus", .{});
    }
    pub fn blur(self: Element) void {
        _ = self.j.call("blur", .{});
    }
    /// el.remove() - detach from the DOM.
    pub fn remove(self: Element) void {
        _ = self.j.call("remove", .{});
    }

    /// el.querySelector(sel) - find a descendant.
    pub fn query(self: Element, comptime sel: []const u8) Element {
        return .{ .j = self.j.call("querySelector", .{str(sel)}) };
    }
    /// el.getAttribute(name)
    pub fn getAttr(self: Element, comptime name: []const u8) Value {
        return self.j.call("getAttribute", .{str(name)});
    }
    /// el.removeAttribute(name)
    pub fn removeAttr(self: Element, comptime name: []const u8) void {
        _ = self.j.call("removeAttribute", .{str(name)});
    }

    /// Create `<tag>` (optionally with class `cls`), append it to `self`, and
    /// return the new child. The building block for the helpers below.
    pub fn child(
        self: Element,
        comptime tag: []const u8,
        comptime cls: []const u8,
    ) Element {
        // document() returns Document, whose methods (create/byId/body/...) all return
        // Element, and this Element-builder calls document() back - an Element<->Document
        // mutual recursion that mirrors the DOM itself.
        // lint:off decl-order: Element<->Document cycle (Document.create returns Element)
        const e: Element = document().create(tag);
        if (cls.len != 0) {
            e.setClass(cls);
        }
        self.append(e);
        return e;
    }
    /// Like `child`, but also set the new element's text content.
    pub fn textChild(
        self: Element,
        comptime tag: []const u8,
        comptime cls: []const u8,
        comptime text: []const u8,
    ) Element {
        const e: Element = self.child(tag, cls);
        e.setText(str(text));
        return e;
    }
};

pub const Document = extern struct {
    j: Value,

    /// document.getElementById(id)
    pub fn byId(self: Document, comptime id: []const u8) Element {
        return .{ .j = self.j.call("getElementById", .{str(id)}) };
    }
    /// document.querySelector(sel)
    pub fn query(self: Document, comptime sel: []const u8) Element {
        return .{ .j = self.j.call("querySelector", .{str(sel)}) };
    }
    /// document.createElement(tag)
    pub fn create(self: Document, comptime tag: []const u8) Element {
        return .{ .j = self.j.call("createElement", .{str(tag)}) };
    }
    /// document.createTextNode(text) - appendable as a child for mixed content.
    pub fn createText(self: Document, comptime text: []const u8) Element {
        return .{ .j = self.j.call("createTextNode", .{str(text)}) };
    }
    pub fn body(self: Document) Element {
        return .{ .j = self.j.get("body") };
    }
    pub fn head(self: Document) Element {
        return .{ .j = self.j.get("head") };
    }
};

pub fn document() Document {
    return .{ .j = global().get("document") };
}

/// requestAnimationFrame(cb): schedule a callback for the next frame.
pub fn requestAnimationFrame(cb: Value) void {
    _ = global().call("requestAnimationFrame", .{cb});
}

/// Wrap a Zig fn as a JS callback with the RAW NUMERIC ABI: arguments arrive
/// as plain numbers (BigInt i64s coerced via Number), no per-arg handle is
/// minted or freed. The wgpu/wasi import namespaces use this - they are the
/// per-frame hot path and traffic exclusively in numbers and (ptr,len) pairs.
pub fn funcNum(f: *const anyopaque) Value {
    return .{ .h = js_fn_num(f) };
}

const ZimrWgpu = struct {
    // Must match the TS bridge's TEXTURE_FORMATS indices exactly - the wasm
    // side encodes formats as these positions.
    const texture_formats = [_][]const u8{
        "undefined",       "rgba8unorm",   "rgba8unorm-srgb", "bgra8unorm",
        "bgra8unorm-srgb", "rgba16float",  "rgba32float",     "r8unorm",
        "rg8unorm",        "depth16unorm", "depth24plus",     "depth32float",
    };

    fn formatIndexOf(format: Value) u32 {
        // Mirror the TS bridge: indexOf into the shared list (built once).
        if (g.wgpu.format_list.isNull()) {
            const list: Value = global().get("Array").new(.{});
            inline for (texture_formats) |name| {
                _ = list.call("push", .{str(name)});
            }
            g.wgpu.format_list = list;
        }
        const idx: f64 = js_to_num(g.wgpu.format_list.call("indexOf", .{format}).h);
        if (idx < 0) {
            return 0;
        }
        return @trunc(idx);
    }

    fn tblInsert(v: Value) u32 {
        const id: u32 = g.wgpu.next_id;
        g.wgpu.next_id += 1;
        _ = g.wgpu.objects.call("set", .{ Value{ .h = js_num(@floatFromInt(id)) }, v });
        return id;
    }
    fn tblGet(id: f64) Value {
        return g.wgpu.objects.call("get", .{Value{ .h = js_num(id) }});
    }
    fn tblRelease(id: f64) void {
        _ = g.wgpu.objects.call("delete", .{Value{ .h = js_num(id) }});
    }

    fn modBytes(ptr: f64, len: f64) Value {
        const p: u32 = @trunc(ptr);
        const l: u32 = @trunc(len);
        const buf: Value = g.boot.module_exports.get("memory").get("buffer");
        return global().get("Uint8Array").new(.{ buf, p, l });
    }
    fn modString(ptr: f64, len: f64) Value {
        return g.boot.utf8_decoder.call("decode", .{modBytes(ptr, len)});
    }

    // ---- device / queue / surface (singletons) ----------------------------
    fn jsInitDevice() f64 {
        return 1;
    }
    fn jsDeviceGetQueue(_: f64) f64 {
        return 1;
    }
    fn jsGetSurface() f64 {
        if (!g.wgpu.have_canvas) {
            const doc: Value = (Value{ .h = js_global() }).get("document");
            const canvas: Value = doc.call("createElement", .{str("canvas")});
            canvas.get("style").set("cssText", str("position:fixed;inset:0;width:100vw;height:100vh;" ++
                "display:block;touch-action:none;user-select:none;-webkit-user-select:none"));
            _ = doc.get("body").call("appendChild", .{canvas});
            const dpr: f64 = js_to_num(global().get("devicePixelRatio").h);
            const w: u32 = @trunc(js_to_num(canvas.get("clientWidth").h) * dpr);
            const h: u32 = @trunc(js_to_num(canvas.get("clientHeight").h) * dpr);
            canvas.set("width", Value{ .h = js_num(@floatFromInt(@max(w, 1))) });
            canvas.set("height", Value{ .h = js_num(@floatFromInt(@max(h, 1))) });
            const ctx: Value = canvas.call("getContext", .{str("webgpu")});
            // rgba8unorm (not getPreferredCanvasFormat's bgra8unorm) to match the
            // engine's RGBA8 render textures - see domCanvasConfigure for why.
            const preferred: Value = str("rgba8unorm");
            const cfg: Value = global().get("Object").new(.{});
            cfg.set("device", g.boot.gpu_device);
            cfg.set("format", preferred);
            cfg.set("alphaMode", str("opaque"));
            _ = ctx.call("configure", .{cfg});
            g.wgpu.canvas = canvas;
            g.wgpu.context = ctx;
            g.wgpu.format_index = formatIndexOf(preferred);
            g.wgpu.have_canvas = true;
        }
        return 1;
    }
    fn jsSurfaceGetCurrentTexture(_: f64) f64 {
        const view: Value = g.wgpu.context.call("getCurrentTexture", .{}).call("createView", .{});
        return @floatFromInt(tblInsert(view));
    }
    fn jsSurfacePresent(_: f64) void {} // WebGPU canvas presentation is implicit
    fn jsSurfaceGetFormat(_: f64) f64 {
        return @floatFromInt(g.wgpu.format_index);
    }
    fn packedSize(w: f64, h: f64) f64 {
        const wi: u32 = @trunc(w);
        const hi: u32 = @trunc(h);
        return @floatFromInt(((wi & 0xffff) << 16) | (hi & 0xffff));
    }
    fn jsSurfaceGetSize(_: f64) f64 {
        return packedSize(js_to_num(g.wgpu.canvas.get("width").h), js_to_num(g.wgpu.canvas.get("height").h));
    }
    fn jsSurfaceGetCssSize(_: f64) f64 {
        var w: f64 = js_to_num(g.wgpu.canvas.get("clientWidth").h);
        var h: f64 = js_to_num(g.wgpu.canvas.get("clientHeight").h);
        if (w == 0) {
            w = js_to_num(g.wgpu.canvas.get("width").h);
            h = js_to_num(g.wgpu.canvas.get("height").h);
        }
        return packedSize(w, h);
    }
    fn jsSetCursorStyle(style: f64) void {
        if (!g.wgpu.have_canvas) {
            return;
        }
        const name: Value = if (style == 1) str("none") else str("default");
        g.wgpu.canvas.get("style").set("cursor", name);
    }
    // Maps the `MouseCursor` enum (types.zig) to a CSS `cursor` keyword. The
    // engine's `setMouseCursor` reaches here via `dom.set_mouse_cursor`; the
    // headless smoke auto-stubs the import, but the standalone bridge is
    // explicit, so this must exist or WASM instantiate fails with a LinkError.
    fn jsSetMouseCursor(cursor: f64) void {
        if (!g.wgpu.have_canvas) {
            return;
        }
        // Compare the incoming f64 directly (JS numbers arrive as f64), matching
        // jsSetCursorStyle above and sidestepping a redundant @intFromFloat. Codes
        // are the MouseCursor enum (types.zig): default 0, arrow 1, ibeam 2,
        // crosshair 3, pointing_hand 4, resize_ew/ns/nwse/nesw 5..8, resize_all 9,
        // not_allowed 10; unknown falls through to the CSS default arrow.
        const name: Value = if (cursor == 2)
            str("text")
        else if (cursor == 3)
            str("crosshair")
        else if (cursor == 4)
            str("pointer")
        else if (cursor == 5)
            str("ew-resize")
        else if (cursor == 6)
            str("ns-resize")
        else if (cursor == 7)
            str("nwse-resize")
        else if (cursor == 8)
            str("nesw-resize")
        else if (cursor == 9)
            str("move")
        else if (cursor == 10)
            str("not-allowed")
        else
            str("default");
        g.wgpu.canvas.get("style").set("cursor", name);
    }
    // window.open in a new tab; noopener/noreferrer keeps the opened page from
    // reaching back into this one. Backs `openUrl` (runtime.zig).
    fn jsOpenUrl(ptr: f64, len: f64) void {
        _ = global().call("open", .{ modString(ptr, len), str("_blank"), str("noopener,noreferrer") });
    }
    // navigator.clipboard is undefined in insecure (file://, plain-http) contexts,
    // so guard with truthy() to avoid throwing during a copy.
    fn jsSetClipboardText(ptr: f64, len: f64) void {
        const clipboard: Value = global().get("navigator").get("clipboard");
        if (clipboard.truthy()) {
            _ = clipboard.call("writeText", .{modString(ptr, len)});
        }
    }
    fn jsRequestPointerLock() void {
        if (g.wgpu.have_canvas) {
            // requestPointerLock() rejects when the environment forbids the lock
            // -- a sandboxed iframe without allow-pointer-lock, a request outside a
            // user gesture, or a mobile browser with no pointer to capture. An
            // uncaught rejection crashes the whole page, so swallow it. Wrapping in
            // Promise.resolve() tolerates old browsers where the call returns
            // undefined instead of a promise. Pointer lock is an optional
            // enhancement; callers must not depend on it succeeding.
            const swallow: Value = global().get("Function").new(.{
                str("c"),
                str("try{Promise.resolve(c.requestPointerLock()).catch(function(){});}catch(e){}"),
            });
            _ = swallow.call("call", .{ global(), g.wgpu.canvas });
        }
    }
    fn jsExitPointerLock() void {
        _ = global().get("document").call("exitPointerLock", .{});
    }
    fn jsPointerLockActive() f64 {
        const locked: Value = global().get("document").get("pointerLockElement");
        if (locked.isNull()) {
            return 0;
        }
        return 1;
    }
    fn jsLog(level: f64, ptr: f64, len: f64) void {
        // Matches web.zig's `js_log(level, ptr, len)`. The level param had been
        // dropped here, so every call bound ptr=level / len=ptr and read MBs of
        // garbage from a bogus address. Route by level (debug/info=0/1, warn=2,
        // err=3); `call`'s method name is comptime, hence three literal branches.
        const con: Value = global().get("console");
        const msg: Value = modString(ptr, len);
        if (level >= 3) {
            _ = con.call("error", .{msg});
        } else if (level >= 2) {
            _ = con.call("warn", .{msg});
        } else {
            _ = con.call("log", .{msg});
        }
    }

    // ---- persistence (localStorage, "zimr_"-prefixed keys) -----------------
    // Status codes match the classic contract: save returns 0 ok / 1 quota
    // / 2 unavailable; size returns byte length or -1 missing / -2
    // unavailable; read returns bytes copied or negative; remove returns 0.
    fn lsKey(key_ptr: f64, key_len: f64) Value {
        return str("zimr_").call("concat", .{modString(key_ptr, key_len)});
    }
    fn localStorage() Value {
        return global().get("localStorage");
    }
    fn jsPersistenceSave(
        key_ptr: f64,
        key_len: f64,
        val_ptr: f64,
        val_len: f64,
    ) f64 {
        const ls: Value = localStorage();
        if (ls.isNull()) {
            return 2;
        }
        _ = ls.call("setItem", .{ lsKey(key_ptr, key_len), modString(val_ptr, val_len) });
        return 0;
    }
    fn jsPersistenceSize(key_ptr: f64, key_len: f64) f64 {
        const ls: Value = localStorage();
        if (ls.isNull()) {
            return -2;
        }
        const v: Value = ls.call("getItem", .{lsKey(key_ptr, key_len)});
        if (v.isNull()) {
            return -1;
        }
        // UTF-8 byte length (TextEncoder), not JS string length.
        if (g.wgpu.text_encoder.isNull()) {
            g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
        }
        return js_to_num(g.wgpu.text_encoder.call("encode", .{v}).get("length").h);
    }
    fn jsPersistenceRead(
        key_ptr: f64,
        key_len: f64,
        out_ptr: f64,
        out_cap: f64,
    ) f64 {
        const ls: Value = localStorage();
        if (ls.isNull()) {
            return -2;
        }
        const v: Value = ls.call("getItem", .{lsKey(key_ptr, key_len)});
        if (v.isNull()) {
            return -1;
        }
        if (g.wgpu.text_encoder.isNull()) {
            g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
        }
        const bytes: Value = g.wgpu.text_encoder.call("encode", .{v});
        const n: f64 = js_to_num(bytes.get("length").h);
        if (n > out_cap) {
            return -3;
        }
        _ = modBytes(out_ptr, n).call("set", .{bytes});
        return n;
    }
    fn jsPersistenceRemove(key_ptr: f64, key_len: f64) f64 {
        const ls: Value = localStorage();
        if (ls.isNull()) {
            return 2;
        }
        _ = ls.call("removeItem", .{lsKey(key_ptr, key_len)});
        return 0;
    }

    // ---- WebSocket host (zimr P2P signaling client; see src/net.zig) ---------
    // Each socket lives in the object table as a small holder { ws, q, st }:
    //   ws = the browser WebSocket
    //   q  = a queue of received messages (each a Uint8Array of the frame bytes)
    //   st = 0 connecting / 1 open / 2 closed-or-errored
    // The onopen/onmessage/onclose/onerror handlers are PURE JS closures (built
    // with `new Function`) that only push to the queue and flip the state - they
    // never call back into wasm, so nothing re-enters a running frame. wasm drains
    // the queue by polling once per frame, exactly like the fetch bridge.
    fn jsWsOpen(url_ptr: f64, url_len: f64) f64 {
        const ws: Value = global().get("WebSocket").new(.{modString(url_ptr, url_len)});
        ws.set("binaryType", str("arraybuffer"));
        const holder: Value = global().get("Object").new(.{});
        holder.set("ws", ws);
        holder.set("q", global().get("Array").new(.{}));
        holder.set("st", @as(f64, 0)); // connecting
        // One setup function wires all four handlers onto (ws, h). Text frames
        // arrive as JS strings (encode to bytes); binary frames as ArrayBuffers.
        const setup: Value = global().get("Function").new(.{
            str("ws"),
            str("h"),
            str("ws.onopen=function(){h.st=1;};" ++
                "ws.onmessage=function(e){var d=e.data;" ++
                "h.q.push(typeof d==='string'?new TextEncoder().encode(d):new Uint8Array(d));};" ++
                "ws.onclose=function(){h.st=2;};" ++
                "ws.onerror=function(){h.st=2;};"),
        });
        _ = setup.call("call", .{ global(), ws, holder });
        return @floatFromInt(tblInsert(holder));
    }

    fn jsWsState(handle: f64) f64 {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return 2; // a handle that's gone counts as closed
        }
        return holder.getNum("st");
    }

    fn jsWsSend(handle: f64, ptr: f64, len: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        const ws: Value = holder.get("ws");
        // readyState 1 == OPEN; sending before the socket opens throws, so guard.
        if (ws.getNum("readyState") != 1) {
            return;
        }
        // Send as a text frame (a JS string) - the L0 server speaks text frames.
        _ = ws.call("send", .{modString(ptr, len)});
    }

    fn jsWsPoll(handle: f64, out_ptr: f64, out_cap: f64) f64 {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return -1;
        }
        const q: Value = holder.get("q");
        if (q.getNum("length") < 1) {
            return -1; // nothing queued right now
        }
        const msg: Value = q.call("shift", .{}); // oldest message, a Uint8Array
        const n: f64 = msg.getNum("length");
        if (n > out_cap) {
            return -2; // too big for the caller's buffer; message is dropped
        }
        _ = modBytes(out_ptr, n).call("set", .{msg});
        return n;
    }

    fn jsWsClose(handle: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        _ = holder.get("ws").call("close", .{});
        tblRelease(handle);
    }

    // Build the same-origin WebSocket URL for the current page: "wss://host" on
    // an https page, "ws://host" otherwise. Lets a page served by the signaling
    // server connect straight back to it with no hard-coded address and no
    // mixed-content trouble. Writes the URL into the caller's buffer, returns len.
    fn jsWsOriginUrl(out_ptr: f64, out_cap: f64) f64 {
        const builder: Value = global().get("Function").new(.{
            str("return (location.protocol==='https:'?'wss://':'ws://')+location.host;"),
        });
        const url: Value = builder.call("call", .{global()}); // a JS string
        if (g.wgpu.text_encoder.isNull()) {
            g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
        }
        const bytes: Value = g.wgpu.text_encoder.call("encode", .{url});
        const n: f64 = bytes.getNum("length");
        if (n > out_cap) {
            return 0;
        }
        _ = modBytes(out_ptr, n).call("set", .{bytes});
        return n;
    }

    // ---- WebRTC: peer-to-peer data channels --------------------------------
    // Same shape as the WebSocket bridge above: every RTCPeerConnection is a
    // handle whose holder carries the pc, a two-slot channel array, a buffer of
    // ICE candidates that arrived before the remote description was set, and an
    // event queue that pure-JS closures push into (they NEVER call back into
    // wasm - the game drains the queue itself via jsRtcPoll). Channel 0 is
    // "cursor" (unreliable, unordered - lossy is fine); channel 1 is "clicks"
    // (reliable, ordered). Poll event encoding (written into the game buffer):
    //   byte 0 = kind, byte 1 = channel, bytes 2.. = payload
    //   kind 1 local offer SDP | 2 local answer SDP | 3 local ICE (JSON) |
    //        4 channel open | 5 data received | 6 connection state changed
    fn jsRtcCreate() f64 {
        // Google's public STUN lets peers behind NAT discover a route. No TURN
        // in v1, so a small fraction of restrictive networks won't connect.
        const cfg: Value = global().get("Object").new(.{});
        const servers: Value = global().get("Array").new(.{});
        const stun: Value = global().get("Object").new(.{});
        stun.set("urls", str("stun:stun.l.google.com:19302"));
        _ = servers.call("push", .{stun});
        cfg.set("iceServers", servers);
        const pc: Value = global().get("RTCPeerConnection").new(.{cfg});

        const holder: Value = global().get("Object").new(.{});
        holder.set("pc", pc);
        holder.set("q", global().get("Array").new(.{}));
        holder.set("chans", global().get("Array").new(.{}));
        holder.set("pendingIce", global().get("Array").new(.{}));

        // One setup call wires the connection-level handlers and installs a
        // channel-wiring helper on the holder (h.wire), used both when WE make
        // the channels as the offerer and when they arrive via ondatachannel.
        const setup: Value = global().get("Function").new(.{
            str("pc"),
            str("h"),
            str("h.wire=function(ch,idx){ch.binaryType='arraybuffer';h.chans[idx]=ch;" ++
                "ch.onopen=function(){h.q.push({kind:4,ch:idx});};" ++
                "ch.onmessage=function(ev){var d=ev.data;" ++
                "var b=(typeof d==='string')?new TextEncoder().encode(d):new Uint8Array(d);" ++
                "h.q.push({kind:5,ch:idx,bytes:b});};};" ++
                "pc.onicecandidate=function(e){if(e.candidate){" ++
                "h.q.push({kind:3,ch:0,str:JSON.stringify(e.candidate)});}};" ++
                "pc.onconnectionstatechange=function(){" ++
                "h.q.push({kind:6,ch:0,str:pc.connectionState});};" ++
                "pc.ondatachannel=function(e){var ch=e.channel;" ++
                "h.wire(ch,(ch.label==='clicks')?1:0);};"),
        });
        _ = setup.call("call", .{ global(), pc, holder });
        return @floatFromInt(tblInsert(holder));
    }

    fn jsRtcCreateOffer(handle: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        const pc: Value = holder.get("pc");
        // Offerer creates both channels, wires them, then makes the offer.
        const cursor_opts: Value = global().get("Object").new(.{});
        cursor_opts.set("ordered", false);
        cursor_opts.set("maxRetransmits", @as(f64, 0));
        const cursor: Value = pc.call("createDataChannel", .{ str("cursor"), cursor_opts });
        const clicks_opts: Value = global().get("Object").new(.{});
        clicks_opts.set("ordered", true);
        const clicks: Value = pc.call("createDataChannel", .{ str("clicks"), clicks_opts });
        const wire: Value = holder.get("wire");
        _ = wire.call("call", .{ global(), cursor, @as(f64, 0) });
        _ = wire.call("call", .{ global(), clicks, @as(f64, 1) });
        // createOffer -> setLocalDescription -> queue the SDP for the game.
        const chain: Value = global().get("Function").new(.{
            str("pc"),
            str("h"),
            str("pc.createOffer().then(function(o){return pc.setLocalDescription(o);})" ++
                ".then(function(){h.q.push({kind:1,ch:0,str:pc.localDescription.sdp});})" ++
                ".catch(function(err){h.q.push({kind:6,ch:0,str:'offer-error:'+err});});"),
        });
        _ = chain.call("call", .{ global(), pc, holder });
    }

    fn jsRtcSetRemote(handle: f64, is_offer: f64, sdp_ptr: f64, sdp_len: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        const pc: Value = holder.get("pc");
        const desc: Value = global().get("Object").new(.{});
        desc.set("type", if (is_offer != 0) str("offer") else str("answer"));
        desc.set("sdp", modString(sdp_ptr, sdp_len));
        // setRemoteDescription is async. After it resolves we flush any ICE that
        // arrived early, and - if this was an offer (we're the answerer) - create
        // the answer right here so it can't race ahead of the remote description.
        // (`d` and `isOffer` come in as the 3rd/4th call args - arguments[2] and
        // arguments[3] - to keep new Function at its 3-arg limit.)
        const chain: Value = global().get("Function").new(.{
            str("pc"),
            str("h"),
            str("var d=arguments[2];var isOffer=arguments[3];" ++
                "pc.setRemoteDescription(d).then(function(){" ++
                "var p=h.pendingIce;for(var i=0;i<p.length;i++){" ++
                "pc.addIceCandidate(p[i]).catch(function(){});}h.pendingIce=[];" ++
                "if(isOffer){return pc.createAnswer().then(function(a){" ++
                "return pc.setLocalDescription(a);}).then(function(){" ++
                "h.q.push({kind:2,ch:0,str:pc.localDescription.sdp});});}})" ++
                ".catch(function(err){h.q.push({kind:6,ch:0,str:'remote-error:'+err});});"),
        });
        _ = chain.call("call", .{ global(), pc, holder, desc, if (is_offer != 0) @as(f64, 1) else @as(f64, 0) });
    }

    fn jsRtcAddIce(handle: f64, cand_ptr: f64, cand_len: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        const pc: Value = holder.get("pc");
        // Buffer candidates that arrive before the remote description is set;
        // jsRtcSetRemote flushes them once it resolves. (`s` comes in as the 3rd
        // call arg - arguments[2] - to keep new Function at its 3-arg limit.)
        const add: Value = global().get("Function").new(.{
            str("pc"),
            str("h"),
            str("var s=arguments[2];var c=JSON.parse(s);if(pc.remoteDescription){" ++
                "pc.addIceCandidate(c).catch(function(){});}else{h.pendingIce.push(c);}"),
        });
        _ = add.call("call", .{ global(), pc, holder, modString(cand_ptr, cand_len) });
    }

    fn jsRtcSend(handle: f64, channel: f64, ptr: f64, len: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        const idx: u32 = @trunc(channel);
        const ch: Value = holder.get("chans").at(idx);
        if (ch.isNull()) {
            return; // channel not open yet
        }
        // Cache the guarded-send helper on window (send can be per-frame hot, so
        // no re-parsing a Function each call). Sending on a non-open channel
        // throws, so the guard checks readyState first.
        if (global().get("__zimrRtcSend").isNull()) {
            const f: Value = global().get("Function").new(.{
                str("ch"),
                str("b"),
                str("if(ch&&ch.readyState==='open'){ch.send(b);}"),
            });
            global().set("__zimrRtcSend", f);
        }
        _ = global().get("__zimrRtcSend").call("call", .{ global(), ch, modBytes(ptr, len) });
    }

    fn jsRtcPoll(handle: f64, out_ptr: f64, out_cap: f64) f64 {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return -1;
        }
        const q: Value = holder.get("q");
        if (q.getNum("length") < 1) {
            return -1; // nothing queued
        }
        const ev: Value = q.call("shift", .{});
        const kind: f64 = ev.getNum("kind");
        const ch: f64 = ev.getNum("ch");
        var payload: Value = global().get("Uint8Array"); // placeholder; unused for kind 4
        var plen: f64 = 0;
        if (kind == 5) {
            payload = ev.get("bytes");
            plen = payload.getNum("length");
        } else if (kind != 4) {
            if (g.wgpu.text_encoder.isNull()) {
                g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
            }
            payload = g.wgpu.text_encoder.call("encode", .{ev.get("str")});
            plen = payload.getNum("length");
        }
        const total: f64 = 2 + plen;
        if (total > out_cap) {
            return -2; // too big for the caller's buffer; event dropped
        }
        const buf: Value = modBytes(out_ptr, total);
        buf.setAt(0, kind);
        buf.setAt(1, ch);
        if (plen > 0) {
            _ = buf.call("set", .{ payload, @as(f64, 2) });
        }
        return total;
    }

    fn jsRtcClose(handle: f64) void {
        const holder: Value = tblGet(handle);
        if (holder.isNull()) {
            return;
        }
        _ = holder.get("pc").call("close", .{});
        tblRelease(handle);
    }
    var perf_obj_handle: Handle = 0; // lint:off module-var: cached performance object (a stable page global)
    fn jsNowMs() f64 {
        // Cache the `performance` object so each read is one call + one to-number,
        // not global()->get("performance")->call("now") every time. The profiler
        // reads this twice per zone (hundreds/frame), so the saved crossings keep
        // the clock's own cost out of the measurements.
        if (perf_obj_handle == 0) {
            perf_obj_handle = global().get("performance").h;
        }
        const perf: Value = .{ .h = perf_obj_handle };
        return js_to_num(perf.call("now", .{}).h);
    }
    /// `Date.now()` - wall-clock milliseconds since the Unix epoch (UTC).
    fn jsEpochMs() f64 {
        return js_to_num(global().get("Date").call("now", .{}).h);
    }
    /// `new Date().getTimezoneOffset()` - minutes to add to local to reach UTC.
    fn jsTzOffsetMin() f64 {
        return js_to_num(global().get("Date").new(.{}).call("getTimezoneOffset", .{}).h);
    }
    /// Most recent summed GPU pass time (ms) from the timestamp-query readback,
    /// or 0 when GPU timing is unsupported/not yet sampled. The profiler reads
    /// this each frame (see wgpu_app) and records it alongside CPU frame time.
    fn jsGpuMsLast() f64 {
        return g.wgpu.gpu_ms_last;
    }

    // ---- buffers -----------------------------------------------------------
    const buffer_usage_bits = [_]u32{ 0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080, 0x0100, 0x0200 };
    fn decodeBufferUsage(bits: u32) u32 {
        // zimr bit i -> GPUBufferUsage flag (MAP_READ..QUERY_RESOLVE); the
        // numeric flag values happen to coincide with the zimr bit order, so
        // the decode is a masked identity - kept as a loop for clarity if the
        // orders ever diverge.
        var out: u32 = 0;
        inline for (buffer_usage_bits, 0..) |flag, i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0) {
                out |= flag;
            }
        }
        return out;
    }
    fn jsDeviceCreateBuffer(
        _: f64,
        size: f64,
        usage: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        const desc: Value = global().get("Object").new(.{});
        desc.set("size", Value{ .h = js_num(size) });
        desc.set("usage", Value{ .h = js_num(@floatFromInt(decodeBufferUsage(@trunc(usage)))) });
        desc.set("label", modString(label_ptr, label_len));
        const buf: Value = g.boot.gpu_device.call("createBuffer", .{desc});
        return @floatFromInt(tblInsert(buf));
    }
    fn jsBufferDestroy(id: f64) void {
        const buf: Value = tblGet(id);
        if (!buf.isNull()) {
            _ = buf.call("destroy", .{});
        }
        tblRelease(id);
    }
    fn jsQueueWriteBuffer(
        _: f64,
        buffer: f64,
        offset: f64,
        data_ptr: f64,
        data_len: f64,
    ) void {
        const buf: Value = tblGet(buffer);
        if (buf.isNull()) {
            return;
        }
        _ = g.boot.gpu_queue.call("writeBuffer", .{ buf, Value{ .h = js_num(offset) }, modBytes(data_ptr, data_len) });
    }

    // ---- shader modules / samplers ----------------------------------------
    fn jsDeviceCreateShaderModuleWgsl(
        _: f64,
        wgsl_ptr: f64,
        wgsl_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        const desc: Value = global().get("Object").new(.{});
        desc.set("code", modString(wgsl_ptr, wgsl_len));
        desc.set("label", modString(label_ptr, label_len));
        const module: Value = g.boot.gpu_device.call("createShaderModule", .{desc});

        // ---- ASK THE SHADER MODULE WHAT WAS WRONG WITH IT ----
        //
        // `createShaderModule` never throws. A module that failed to compile is returned as a
        // live object, and the first thing anyone hears about it is the CASCADE, one call later:
        //
        //     [Invalid ShaderModule "diff_forward"] is invalid due to a previous error.
        //      - While validating compute stage ...
        //
        // "a previous error" is the actual message, and without this it is never printed. Two
        // device round-trips were spent reading transpiler output by eye because of that.
        //
        // `getCompilationInfo()` is where Dawn puts the real diagnostic, with a line and column
        // into the WGSL it rejected. It is a Promise and this bridge call is synchronous, so the
        // report is attached and left to fire: the handle returns immediately, the pipeline
        // still fails, and the useful message lands on the same error surface a moment later.
        // Order on screen is not the point - having the message at all is.
        reportShaderCompilation(module);

        return @floatFromInt(tblInsert(module));
    }

    /// Attach a diagnostic reporter to a freshly created shader module.
    ///
    /// Errors go to `window.__wzFail`, the page's existing full-screen error surface, so a
    /// compile failure paints the same way an uncaught exception does. Warnings are left to the
    /// console: a warning that paints over the app is a warning nobody keeps.
    fn reportShaderCompilation(module: Value) void {
        const fun: Value = global().get("Function");
        const reporter: Value = fun.new(.{
            str("m"),
            str(
                \\if (!m) { return; }
                \\if (!m.getCompilationInfo) {
                \\  if (window.__wzFail) { window.__wzFail("no getCompilationInfo on this device"); }
                \\  return;
                \\}
                \\m.getCompilationInfo().then(function (info) {
                \\  var out = [];
                \\  for (var i = 0; i < info.messages.length; i++) {
                \\    var g = info.messages[i];
                \\    if (g.type !== "error") { console.warn("[wgsl] " + g.message); continue; }
                \\    out.push("WGSL " + g.type + " at line " + g.lineNum + ":" + g.linePos +
                \\             " of \"" + (m.label || "?") + "\"\n  " + g.message);
                \\  }
                \\  if (out.length && window.__wzFail) { window.__wzFail(out.join("\n\n")); }
                \\  else if (info.messages.length === 0 && m.label && window.__wzNoteOk) {
                \\    window.__wzNoteOk(m.label);
                \\  }
                \\}).catch(function (e) {
                \\  if (window.__wzFail) { window.__wzFail("getCompilationInfo failed: " + e); }
                \\});
            ),
        });
        _ = reporter.call("call", .{ global(), module });
    }
    fn jsDeviceCreateSampler(
        _: f64,
        mag_linear: f64,
        min_linear: f64,
        address_mode: f64,
        mipmap_linear: f64,
    ) f64 {
        const desc: Value = global().get("Object").new(.{});
        desc.set("magFilter", if (mag_linear != 0) str("linear") else str("nearest"));
        desc.set("minFilter", if (min_linear != 0) str("linear") else str("nearest"));
        desc.set("mipmapFilter", if (mipmap_linear != 0) str("linear") else str("nearest"));
        const mode: Value = if (address_mode == 1)
            str("repeat")
        else if (address_mode == 2)
            str("mirror-repeat")
        else
            str("clamp-to-edge");
        desc.set("addressModeU", mode);
        desc.set("addressModeV", mode);
        const sampler: Value = g.boot.gpu_device.call("createSampler", .{desc});
        return @floatFromInt(tblInsert(sampler));
    }

    // ---- command encoding (the 3a slice; passes land in 3d) ---------------
    fn jsDeviceCreateCommandEncoder(_: f64) f64 {
        g.wgpu.ts_cursor = 0; // fresh encoder: restart timestamp slot allocation
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createCommandEncoder", .{})));
    }
    fn jsCommandEncoderFinish(encoder: f64) f64 {
        const enc: Value = tblGet(encoder);
        // GPU timing: if this encoder recorded timed passes and no readback is in
        // flight, resolve the timestamps into the resolve buffer and copy them to
        // the mappable read buffer (both within this command buffer).
        g.wgpu.ts_resolve_pairs = 0;
        if (g.wgpu.ts_ready and !g.wgpu.ts_pending and g.wgpu.ts_cursor > 0) {
            const count: u32 = g.wgpu.ts_cursor;
            const bytes: u32 = count * 8;
            _ = enc.call("resolveQuerySet", .{
                g.wgpu.ts_query_set,   numValue(0), numValue(@floatFromInt(count)),
                g.wgpu.ts_resolve_buf, numValue(0),
            });
            _ = enc.call("copyBufferToBuffer", .{
                g.wgpu.ts_resolve_buf,          numValue(0),
                g.wgpu.ts_read_buf,             numValue(0),
                numValue(@floatFromInt(bytes)),
            });
            g.wgpu.ts_resolve_pairs = count / 2;
        }
        const cmd: Value = enc.call("finish", .{});
        tblRelease(encoder);
        return @floatFromInt(tblInsert(cmd));
    }
    fn jsQueueSubmit(_: f64, cmd_buffer: f64) void {
        const cmd: Value = tblGet(cmd_buffer);
        if (cmd.isNull()) {
            return;
        }
        const list: Value = global().get("Array").new(.{});
        _ = list.call("push", .{cmd});
        _ = g.boot.gpu_queue.call("submit", .{list});
        tblRelease(cmd_buffer);
        // GPU timing: the timestamps copied into ts_read_buf by this submit become
        // readable once the GPU finishes; mapAsync resolves then. One in flight at
        // a time - the tick poll completes + unmaps before the next is started.
        if (g.wgpu.ts_resolve_pairs > 0 and !g.wgpu.ts_pending) {
            const bytes: f64 = @floatFromInt(g.wgpu.ts_resolve_pairs * 2 * 8);
            const mode_read: Value = numValue(1);
            const zero_off: Value = numValue(0);
            const size_v: Value = numValue(bytes);
            const promise: Value = g.wgpu.ts_read_buf.call("mapAsync", .{ mode_read, zero_off, size_v });
            g.wgpu.ts_pid = js_promise_register(promise.h);
            g.wgpu.ts_pairs_inflight = g.wgpu.ts_resolve_pairs;
            g.wgpu.ts_pending = true;
            g.wgpu.ts_resolve_pairs = 0;
        }
    }

    // ---- render pass (flat params, no descriptor blob) ---------------------
    fn jsEncoderBeginRenderPass(
        encoder: f64,
        color_view: f64,
        clear_r: f64,
        clear_g: f64,
        clear_b: f64,
        clear_a: f64,
        load_op: f64,
        store_op: f64,
        depth_view: f64,
        resolve_view: f64,
    ) f64 {
        const enc: Value = tblGet(encoder);
        const view: Value = tblGet(color_view);
        if (enc.isNull() or view.isNull()) {
            return 0;
        }
        const att: Value = global().get("Object").new(.{});
        att.set("view", view);
        if (resolve_view != 0) {
            const rv: Value = tblGet(resolve_view);
            if (!rv.isNull()) {
                att.set("resolveTarget", rv);
            }
        }
        const col: Value = global().get("Object").new(.{});
        col.set("r", Value{ .h = js_num(clear_r) });
        col.set("g", Value{ .h = js_num(clear_g) });
        col.set("b", Value{ .h = js_num(clear_b) });
        col.set("a", Value{ .h = js_num(clear_a) });
        att.set("clearValue", col);
        att.set("loadOp", if (load_op == 1) str("clear") else str("load"));
        att.set("storeOp", if (store_op == 1) str("discard") else str("store"));
        const atts: Value = global().get("Array").new(.{});
        _ = atts.call("push", .{att});
        const desc: Value = global().get("Object").new(.{});
        desc.set("colorAttachments", atts);
        if (depth_view != 0) {
            const dv: Value = tblGet(depth_view);
            if (!dv.isNull()) {
                const datt: Value = global().get("Object").new(.{});
                datt.set("view", dv);
                datt.set("depthLoadOp", str("clear"));
                datt.set("depthStoreOp", str("store"));
                datt.set("depthClearValue", Value{ .h = js_num(1.0) });
                desc.set("depthStencilAttachment", datt);
            }
        }
        // GPU timing: tag this pass with begin/end timestamp slots when timing is
        // live and the read buffer is free. Skipped while a readback is pending
        // (the read buffer is mapped) and when the 64-slot set would overflow.
        if (g.wgpu.ts_ready and !g.wgpu.ts_pending and g.wgpu.ts_cursor + 2 <= 64) {
            const tsw: Value = global().get("Object").new(.{});
            tsw.set("querySet", g.wgpu.ts_query_set);
            const begin_idx: f64 = @floatFromInt(g.wgpu.ts_cursor);
            const end_idx: f64 = @floatFromInt(g.wgpu.ts_cursor + 1);
            tsw.set("beginningOfPassWriteIndex", Value{ .h = js_num(begin_idx) });
            tsw.set("endOfPassWriteIndex", Value{ .h = js_num(end_idx) });
            desc.set("timestampWrites", tsw);
            g.wgpu.ts_cursor += 2;
        }
        return @floatFromInt(tblInsert(enc.call("beginRenderPass", .{desc})));
    }
    // ---- MRT render pass: N color attachments from a wasm-memory handle
    //      array (u32 LE view handles), one clear/load/store for all,
    //      shared depth.  The deferred G-buffer pass is the caller. --------
    fn jsEncoderBeginRenderPassMrt(
        encoder: f64,
        views_ptr: f64,
        views_len: f64,
        clear_r: f64,
        clear_g: f64,
        clear_b: f64,
        clear_a: f64,
        load_op: f64,
        store_op: f64,
        depth_view: f64,
    ) f64 {
        const enc: Value = tblGet(encoder);
        if (enc.isNull()) {
            return 0;
        }
        const atts: Value = global().get("Array").new(.{});
        var c: Cursor = Cursor.make(views_ptr, views_len * 4);
        var i: u32 = 0;
        const n: u32 = @trunc(views_len);
        while (i < n) : (i += 1) {
            const view: Value = tblGet(@floatFromInt(c.u32At()));
            if (view.isNull()) {
                return 0;
            }
            const att: Value = global().get("Object").new(.{});
            att.set("view", view);
            const col: Value = global().get("Object").new(.{});
            col.set("r", Value{ .h = js_num(clear_r) });
            col.set("g", Value{ .h = js_num(clear_g) });
            col.set("b", Value{ .h = js_num(clear_b) });
            col.set("a", Value{ .h = js_num(clear_a) });
            att.set("clearValue", col);
            att.set("loadOp", if (load_op == 1) str("clear") else str("load"));
            att.set("storeOp", if (store_op == 1) str("discard") else str("store"));
            _ = atts.call("push", .{att});
        }
        const desc: Value = global().get("Object").new(.{});
        desc.set("colorAttachments", atts);
        if (depth_view != 0) {
            const dv: Value = tblGet(depth_view);
            if (!dv.isNull()) {
                const datt: Value = global().get("Object").new(.{});
                datt.set("view", dv);
                datt.set("depthLoadOp", str("clear"));
                datt.set("depthStoreOp", str("store"));
                datt.set("depthClearValue", Value{ .h = js_num(1.0) });
                desc.set("depthStencilAttachment", datt);
            }
        }
        // Same GPU-timing tagging as the single-attachment pass.
        if (g.wgpu.ts_ready and !g.wgpu.ts_pending and g.wgpu.ts_cursor + 2 <= 64) {
            const tsw: Value = global().get("Object").new(.{});
            tsw.set("querySet", g.wgpu.ts_query_set);
            const begin_idx: f64 = @floatFromInt(g.wgpu.ts_cursor);
            const end_idx: f64 = @floatFromInt(g.wgpu.ts_cursor + 1);
            tsw.set("beginningOfPassWriteIndex", Value{ .h = js_num(begin_idx) });
            tsw.set("endOfPassWriteIndex", Value{ .h = js_num(end_idx) });
            desc.set("timestampWrites", tsw);
            g.wgpu.ts_cursor += 2;
        }
        return @floatFromInt(tblInsert(enc.call("beginRenderPass", .{desc})));
    }
    fn jsRenderPassSetPipeline(pass: f64, pipeline: f64) void {
        const p: Value = tblGet(pass);
        const pl: Value = tblGet(pipeline);
        if (!p.isNull() and !pl.isNull()) {
            _ = p.call("setPipeline", .{pl});
        }
    }
    fn jsRenderPassSetBindGroup(pass: f64, group_index: f64, bind_group: f64) void {
        const p: Value = tblGet(pass);
        const bg: Value = tblGet(bind_group);
        if (!p.isNull() and !bg.isNull()) {
            _ = p.call("setBindGroup", .{ Value{ .h = js_num(group_index) }, bg });
        }
    }
    fn jsRenderPassSetVertexBuffer(
        pass: f64,
        slot: f64,
        buffer: f64,
        offset: f64,
        _: f64,
    ) void {
        const p: Value = tblGet(pass);
        const buf: Value = tblGet(buffer);
        if (!p.isNull() and !buf.isNull()) {
            _ = p.call("setVertexBuffer", .{ Value{ .h = js_num(slot) }, buf, Value{ .h = js_num(offset) } });
        }
    }
    fn jsRenderPassSetIndexBuffer(
        pass: f64,
        buffer: f64,
        format: f64,
        offset: f64,
        _: f64,
    ) void {
        const p: Value = tblGet(pass);
        const buf: Value = tblGet(buffer);
        if (!p.isNull() and !buf.isNull()) {
            const name: Value = if (format == 1) str("uint32") else str("uint16");
            _ = p.call("setIndexBuffer", .{ buf, name, Value{ .h = js_num(offset) } });
        }
    }
    fn jsRenderPassDraw(
        pass: f64,
        vertex_count: f64,
        instance_count: f64,
        first_vertex: f64,
        first_instance: f64,
    ) void {
        const p: Value = tblGet(pass);
        if (p.isNull()) {
            return;
        }
        _ = p.call("draw", .{
            Value{ .h = js_num(vertex_count) },
            Value{ .h = js_num(instance_count) },
            Value{ .h = js_num(first_vertex) },
            Value{ .h = js_num(first_instance) },
        });
    }
    fn jsRenderPassDrawIndexed(
        pass: f64,
        index_count: f64,
        instance_count: f64,
        first_index: f64,
        base_vertex: f64,
        first_instance: f64,
    ) void {
        const p: Value = tblGet(pass);
        if (p.isNull()) {
            return;
        }
        _ = p.call("drawIndexed", .{
            Value{ .h = js_num(index_count) },
            Value{ .h = js_num(instance_count) },
            Value{ .h = js_num(first_index) },
            Value{ .h = js_num(base_vertex) },
            Value{ .h = js_num(first_instance) },
        });
    }
    fn jsRenderPassSetScissorRect(
        pass: f64,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    ) void {
        const p: Value = tblGet(pass);
        if (p.isNull()) {
            return;
        }
        _ = p.call("setScissorRect", .{
            Value{ .h = js_num(x) },
            Value{ .h = js_num(y) },
            Value{ .h = js_num(w) },
            Value{ .h = js_num(h) },
        });
    }
    fn jsRenderPassEnd(pass: f64) void {
        const p: Value = tblGet(pass);
        if (!p.isNull()) {
            _ = p.call("end", .{});
        }
        tblRelease(pass);
    }

    // ---- compute pass -------------------------------------------------------
    fn jsEncoderBeginComputePass(encoder: f64) f64 {
        const enc: Value = tblGet(encoder);
        if (enc.isNull()) {
            return 0;
        }
        return @floatFromInt(tblInsert(enc.call("beginComputePass", .{})));
    }
    fn jsComputePassSetPipeline(pass: f64, pipeline: f64) void {
        const p: Value = tblGet(pass);
        const pl: Value = tblGet(pipeline);
        if (!p.isNull() and !pl.isNull()) {
            _ = p.call("setPipeline", .{pl});
        }
    }
    fn jsComputePassSetBindGroup(pass: f64, group_index: f64, bind_group: f64) void {
        const p: Value = tblGet(pass);
        const bg: Value = tblGet(bind_group);
        if (!p.isNull() and !bg.isNull()) {
            _ = p.call("setBindGroup", .{ Value{ .h = js_num(group_index) }, bg });
        }
    }
    fn jsComputePassDispatchWorkgroups(pass: f64, x: f64, y: f64, z: f64) void {
        const p: Value = tblGet(pass);
        if (p.isNull()) {
            return;
        }
        _ = p.call("dispatchWorkgroups", .{
            Value{ .h = js_num(x) },
            Value{ .h = js_num(y) },
            Value{ .h = js_num(z) },
        });
    }
    fn jsComputePassEnd(pass: f64) void {
        const p: Value = tblGet(pass);
        if (!p.isNull()) {
            _ = p.call("end", .{});
        }
        tblRelease(pass);
    }

    // ---- textures -----------------------------------------------------------
    fn formatName(index: u32) Value {
        inline for (texture_formats, 0..) |name, i| {
            if (index == i) {
                return str(name);
            }
        }
        return str("rgba8unorm");
    }
    const texture_usage_bits = [_]u32{ 0x01, 0x02, 0x04, 0x08, 0x10 };
    fn decodeTextureUsage(bits: u32) u32 {
        var out: u32 = 0;
        inline for (texture_usage_bits, 0..) |flag, i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0) {
                out |= flag;
            }
        }
        return out;
    }
    fn jsDeviceCreateTexture(
        _: f64,
        width: f64,
        height: f64,
        format: f64,
        usage: f64,
        label_ptr: f64,
        label_len: f64,
        sample_count: f64,
        mip_level_count: f64,
        array_layers: f64,
    ) f64 {
        const size: Value = global().get("Object").new(.{});
        size.set("width", Value{ .h = js_num(width) });
        size.set("height", Value{ .h = js_num(height) });
        size.set("depthOrArrayLayers", Value{ .h = js_num(@max(array_layers, 1)) });
        const desc: Value = global().get("Object").new(.{});
        desc.set("size", size);
        desc.set("format", formatName(@trunc(format)));
        desc.set("usage", Value{ .h = js_num(@floatFromInt(decodeTextureUsage(@trunc(usage)))) });
        desc.set("label", modString(label_ptr, label_len));
        if (sample_count > 1) {
            desc.set("sampleCount", Value{ .h = js_num(sample_count) });
        }
        if (mip_level_count > 1) {
            desc.set("mipLevelCount", Value{ .h = js_num(mip_level_count) });
        }
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createTexture", .{desc})));
    }
    fn jsTextureCreateView(texture: f64) f64 {
        const tex: Value = tblGet(texture);
        if (tex.isNull()) {
            return 0;
        }
        return @floatFromInt(tblInsert(tex.call("createView", .{})));
    }
    fn jsTextureCreateViewMip(texture: f64, base_mip: f64, mip_count: f64) f64 {
        const tex: Value = tblGet(texture);
        if (tex.isNull()) {
            return 0;
        }
        const desc: Value = global().get("Object").new(.{});
        desc.set("baseMipLevel", Value{ .h = js_num(base_mip) });
        desc.set("mipLevelCount", Value{ .h = js_num(mip_count) });
        return @floatFromInt(tblInsert(tex.call("createView", .{desc})));
    }
    fn jsTextureCreateViewArray(texture: f64, layer_count: f64) f64 {
        const tex: Value = tblGet(texture);
        if (tex.isNull()) {
            return 0;
        }
        const desc: Value = global().get("Object").new(.{});
        desc.set("dimension", str("2d-array"));
        desc.set("baseArrayLayer", Value{ .h = js_num(0) });
        desc.set("arrayLayerCount", Value{ .h = js_num(layer_count) });
        return @floatFromInt(tblInsert(tex.call("createView", .{desc})));
    }
    fn jsTextureDestroy(texture: f64) void {
        const tex: Value = tblGet(texture);
        if (!tex.isNull()) {
            _ = tex.call("destroy", .{});
        }
        tblRelease(texture);
    }
    fn jsBindGroupDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsBindGroupLayoutDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsPipelineLayoutDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsRenderPipelineDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsComputePipelineDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsSamplerDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsShaderModuleDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsTextureViewDestroy(id: f64) void {
        tblRelease(id);
    }
    fn jsQueueWriteTexture(
        _: f64,
        texture: f64,
        width: f64,
        height: f64,
        bytes_per_row: f64,
        data_ptr: f64,
        data_len: f64,
        mip_level: f64,
    ) void {
        const tex: Value = tblGet(texture);
        if (tex.isNull()) {
            return;
        }
        const dst: Value = global().get("Object").new(.{});
        dst.set("texture", tex);
        if (mip_level != 0) {
            dst.set("mipLevel", Value{ .h = js_num(mip_level) });
        }
        const layout: Value = global().get("Object").new(.{});
        layout.set("bytesPerRow", Value{ .h = js_num(bytes_per_row) });
        const extent: Value = global().get("Object").new(.{});
        extent.set("width", Value{ .h = js_num(width) });
        extent.set("height", Value{ .h = js_num(height) });
        _ = g.boot.gpu_queue.call("writeTexture", .{ dst, modBytes(data_ptr, data_len), layout, extent });
    }

    // ---- binary descriptor decoding (Phase 3c) -----------------------------
    // Complex descriptors cross the wasm boundary as packed little-endian
    // blobs (encoders live Zig-side in pipeline_cache.zig & friends). A
    // Cursor walks a DataView over module memory; layouts are documented at
    // each decoder, byte-for-byte the TS bridge's formats.
    const Cursor = struct {
        view: Value,
        offset: u32,

        fn make(ptr: f64, len: f64) Cursor {
            const p: u32 = @trunc(ptr);
            const l: u32 = @trunc(len);
            const buf: Value = g.boot.module_exports.get("memory").get("buffer");
            const dv: Value = global().get("DataView").new(.{
                buf,
                Value{ .h = js_num(@floatFromInt(p)) },
                Value{ .h = js_num(@floatFromInt(l)) },
            });
            return .{ .view = dv, .offset = 0 };
        }
        fn u32At(self: *Cursor) u32 {
            const little_endian: Value = global().get("Boolean").call("call", .{ Value{ .h = 0 }, numValue(1) });
            const at: Value = .{ .h = js_num(@floatFromInt(self.offset)) };
            const v: f64 = js_to_num(self.view.call("getUint32", .{ at, little_endian }).h);
            self.offset += 4;
            return @trunc(v);
        }
        fn u64At(self: *Cursor) f64 {
            const lo: f64 = @floatFromInt(self.u32At());
            const hi: f64 = @floatFromInt(self.u32At());
            return lo + hi * 4294967296.0;
        }
        fn f64At(self: *Cursor) f64 {
            const little_endian: Value = global().get("Boolean").call("call", .{ Value{ .h = 0 }, numValue(1) });
            const at: Value = .{ .h = js_num(@floatFromInt(self.offset)) };
            const v: f64 = js_to_num(self.view.call("getFloat64", .{ at, little_endian }).h);
            self.offset += 8;
            return v;
        }
        fn strAt(self: *Cursor, base_ptr: f64) Value {
            const len: u32 = self.u32At();
            const off_f: f64 = @floatFromInt(self.offset);
            const text: Value = ZimrWgpu.modString(base_ptr + off_f, @floatFromInt(len));
            self.offset += len;
            return text;
        }
    };

    fn numValue(x: f64) Value {
        return .{ .h = js_num(x) };
    }

    // Blob: count, then per entry { binding u32, visibility u32, type_tag
    // u32, extra u32 }. Tags: 0 uniform / 1 ro-storage / 2 rw-storage
    // (extra = minBindingSize), 3 sampler (extra 1 = non-filtering),
    // 4 texture (float, 2d), 5 storage texture (write-only rgba8unorm).
    fn viewDimStr(v: u32) Value {
        return switch (v) {
            0 => str("1d"),
            2 => str("2d-array"),
            3 => str("cube"),
            4 => str("cube-array"),
            5 => str("3d"),
            else => str("2d"),
        };
    }
    fn decodeBindGroupLayoutEntries(ptr: f64, len: f64) Value {
        const out: Value = global().get("Array").new(.{});
        if (len == 0) {
            return out;
        }
        var c: Cursor = Cursor.make(ptr, len);
        const count: u32 = c.u32At();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry: Value = global().get("Object").new(.{});
            entry.set("binding", numValue(@floatFromInt(c.u32At())));
            entry.set("visibility", numValue(@floatFromInt(c.u32At())));
            const type_tag: u32 = c.u32At();
            const extra: u32 = c.u32At();
            const view_dim: u32 = c.u32At();
            switch (type_tag) {
                0, 1, 2 => {
                    const buffer: Value = global().get("Object").new(.{});
                    const kind: Value = switch (type_tag) {
                        0 => str("uniform"),
                        1 => str("read-only-storage"),
                        else => str("storage"),
                    };
                    buffer.set("type", kind);
                    buffer.set("minBindingSize", numValue(@floatFromInt(extra)));
                    entry.set("buffer", buffer);
                },
                3 => {
                    const sampler: Value = global().get("Object").new(.{});
                    sampler.set("type", if (extra == 1) str("non-filtering") else str("filtering"));
                    entry.set("sampler", sampler);
                },
                4 => {
                    const texture: Value = global().get("Object").new(.{});
                    texture.set("sampleType", str("float"));
                    texture.set("viewDimension", viewDimStr(view_dim));
                    entry.set("texture", texture);
                },
                else => {
                    const st: Value = global().get("Object").new(.{});
                    st.set("access", str("write-only"));
                    st.set("format", str("rgba8unorm"));
                    st.set("viewDimension", viewDimStr(view_dim));
                    entry.set("storageTexture", st);
                },
            }
            _ = out.call("push", .{entry});
        }
        return out;
    }

    // Blob: count, then per entry { binding u32, resource_type u32,
    // handle u32, offset u64, size u64 }. Types: 0 buffer (size 0 = whole),
    // 1 sampler, 2 texture view.
    fn decodeBindGroupEntries(ptr: f64, len: f64) Value {
        const out: Value = global().get("Array").new(.{});
        if (len == 0) {
            return out;
        }
        var c: Cursor = Cursor.make(ptr, len);
        const count: u32 = c.u32At();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry: Value = global().get("Object").new(.{});
            entry.set("binding", numValue(@floatFromInt(c.u32At())));
            const resource_type: u32 = c.u32At();
            const handle: f64 = @floatFromInt(c.u32At());
            const offset: f64 = c.u64At();
            const size: f64 = c.u64At();
            if (resource_type == 0) {
                const res: Value = global().get("Object").new(.{});
                res.set("buffer", tblGet(handle));
                res.set("offset", numValue(offset));
                if (size != 0) {
                    res.set("size", numValue(size));
                }
                entry.set("resource", res);
            } else {
                entry.set("resource", tblGet(handle)); // sampler or texture view
            }
            _ = out.call("push", .{entry});
        }
        return out;
    }

    fn jsDeviceCreateBindGroupLayout(
        _: f64,
        entries_ptr: f64,
        entries_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        const desc: Value = global().get("Object").new(.{});
        desc.set("entries", decodeBindGroupLayoutEntries(entries_ptr, entries_len));
        desc.set("label", modString(label_ptr, label_len));
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createBindGroupLayout", .{desc})));
    }
    fn jsDeviceCreateBindGroup(
        _: f64,
        layout: f64,
        entries_ptr: f64,
        entries_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        const desc: Value = global().get("Object").new(.{});
        desc.set("layout", tblGet(layout));
        desc.set("entries", decodeBindGroupEntries(entries_ptr, entries_len));
        desc.set("label", modString(label_ptr, label_len));
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createBindGroup", .{desc})));
    }
    fn jsDeviceCreatePipelineLayout(
        _: f64,
        bgls_ptr: f64,
        bgls_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        // bgls is a [*]const u32 of bind group layout HANDLES.
        const list: Value = global().get("Array").new(.{});
        var c: Cursor = Cursor.make(bgls_ptr, bgls_len * 4);
        var i: u32 = 0;
        const n: u32 = @trunc(bgls_len);
        while (i < n) : (i += 1) {
            _ = list.call("push", .{tblGet(@floatFromInt(c.u32At()))});
        }
        const desc: Value = global().get("Object").new(.{});
        desc.set("bindGroupLayouts", list);
        desc.set("label", modString(label_ptr, label_len));
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createPipelineLayout", .{desc})));
    }

    const vertex_formats = [_][]const u8{
        "float32", "float32x2", "float32x3", "float32x4",
        "uint32",  "uint32x2",  "uint8x4",   "unorm8x4",
    };
    fn vertexFormatName(index: u32) Value {
        inline for (vertex_formats, 0..) |name, i| {
            if (index == i) {
                return str(name);
            }
        }
        return str("float32");
    }
    fn topologyName(index: u32) Value {
        const names = [_][]const u8{ "point-list", "line-list", "line-strip", "triangle-list", "triangle-strip" };
        inline for (names, 0..) |name, i| {
            if (index == i) {
                return str(name);
            }
        }
        return str("triangle-list");
    }
    fn cullModeName(index: u32) Value {
        const names = [_][]const u8{ "none", "front", "back" };
        inline for (names, 0..) |name, i| {
            if (index == i) {
                return str(name);
            }
        }
        return str("none");
    }
    fn blendComponent(comptime src: []const u8, comptime dst: []const u8) Value {
        const out: Value = global().get("Object").new(.{});
        out.set("srcFactor", str(src));
        out.set("dstFactor", str(dst));
        out.set("operation", str("add"));
        return out;
    }
    fn blendStateFor(mode: u32, target: Value) void {
        // 0 none; 1 alpha; 2 additive; 3 multiply; 4 premultiplied - the
        // engine's whole blending vocabulary, matching the TS bridge.
        const blend: Value = global().get("Object").new(.{});
        switch (mode) {
            1 => {
                blend.set("color", blendComponent("src-alpha", "one-minus-src-alpha"));
                // Alpha channel: "over" (one, one-minus-src-alpha), NOT (one,
                // zero). Replace-alpha punched holes in render-textures - a
                // transparent glyph/shape pixel (src a=0) wrote a=0 over the
                // cleared a=1, so sampling the RT later (e.g. drawCubeTexture)
                // showed through. Over keeps a cleared RT opaque: a stays 1.
                // The swapchain is opaque so this is invisible on screen.
                blend.set("alpha", blendComponent("one", "one-minus-src-alpha"));
            },
            2 => {
                blend.set("color", blendComponent("src-alpha", "one"));
                blend.set("alpha", blendComponent("one", "one"));
            },
            3 => {
                blend.set("color", blendComponent("dst", "zero"));
                blend.set("alpha", blendComponent("dst-alpha", "zero"));
            },
            4 => {
                blend.set("color", blendComponent("one", "one-minus-src-alpha"));
                blend.set("alpha", blendComponent("one", "one-minus-src-alpha"));
            },
            else => return,
        }
        target.set("blend", blend);
    }

    // Blob: vbl_count, per VBL { stride u32, step_mode u32, attr_count u32,
    // per attr { format_idx u32, offset u32, shader_location u32 } }, then
    // len-prefixed vs_entry + fs_entry strings, then topo/cull/blend/depth/
    // color_format/depth_format/sample_count u32s. depth mode 7 = test
    // without write (the transparent-sprite state).
    fn jsDeviceCreateRenderPipeline(
        _: f64,
        layout: f64,
        vs_module: f64,
        fs_module: f64,
        descriptor_ptr: f64,
        descriptor_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        var c: Cursor = Cursor.make(descriptor_ptr, descriptor_len);
        const vertex_buffers: Value = global().get("Array").new(.{});
        const vbl_count: u32 = c.u32At();
        var i: u32 = 0;
        while (i < vbl_count) : (i += 1) {
            const layout_obj: Value = global().get("Object").new(.{});
            layout_obj.set("arrayStride", numValue(@floatFromInt(c.u32At())));
            layout_obj.set("stepMode", if (c.u32At() == 1) str("instance") else str("vertex"));
            const attrs: Value = global().get("Array").new(.{});
            const attr_count: u32 = c.u32At();
            var a: u32 = 0;
            while (a < attr_count) : (a += 1) {
                const attr: Value = global().get("Object").new(.{});
                attr.set("format", vertexFormatName(c.u32At()));
                attr.set("offset", numValue(@floatFromInt(c.u32At())));
                attr.set("shaderLocation", numValue(@floatFromInt(c.u32At())));
                _ = attrs.call("push", .{attr});
            }
            layout_obj.set("attributes", attrs);
            _ = vertex_buffers.call("push", .{layout_obj});
        }
        const vs_entry: Value = c.strAt(descriptor_ptr);
        const fs_entry: Value = c.strAt(descriptor_ptr);
        const topo: u32 = c.u32At();
        const cull: u32 = c.u32At();
        const blend: u32 = c.u32At();
        const depth: u32 = c.u32At();
        const color_format: u32 = c.u32At();
        const depth_format: u32 = c.u32At();
        const sample_count: u32 = c.u32At();
        // Depth compare + write are baked by the encoder from the typed
        // wgpu.DepthMode (exhaustive depthCompare()/writesDepth()); consume them
        // verbatim instead of re-deriving from `depth`. A position-indexed
        // compare table and a `depth != 7` write rule both silently mis-handle
        // any added/reordered DepthMode - the class behind zimr345's
        // writing-`.always` black-screen. (`depth` is still read above, used
        // only for the none/no-attachment check below.)
        const depth_compare: Value = c.strAt(descriptor_ptr);
        const depth_write: u32 = c.u32At();

        // Pipeline-overridable constants (raygpu `override`): build a JS object
        // keyed by name; applied to both stages below.
        const const_count: u32 = c.u32At();
        const constants_obj: Value = global().get("Object").new(.{});
        const reflect: Value = global().get("Reflect");
        var ci: u32 = 0;
        while (ci < const_count) : (ci += 1) {
            const cname: Value = c.strAt(descriptor_ptr);
            const cval: f64 = c.f64At();
            _ = reflect.call("set", .{ constants_obj, cname, numValue(cval) });
        }

        const desc: Value = global().get("Object").new(.{});
        desc.set("label", modString(label_ptr, label_len));
        desc.set("layout", tblGet(layout));
        const vertex: Value = global().get("Object").new(.{});
        vertex.set("module", tblGet(vs_module));
        vertex.set("entryPoint", vs_entry);
        vertex.set("buffers", vertex_buffers);
        if (const_count > 0) {
            vertex.set("constants", constants_obj);
        }
        desc.set("vertex", vertex);
        const target: Value = global().get("Object").new(.{});
        target.set("format", formatName(color_format));
        blendStateFor(blend, target);
        const targets: Value = global().get("Array").new(.{});
        _ = targets.call("push", .{target});
        // MRT tail: extra color targets for locations 1..N.  Blend-free by
        // design - the only multi-target consumer today is the G-buffer, and
        // blending positions/normals would be nonsense.  Encoded LAST in the
        // blob (see gpu.zig encodeRenderPipelineDescriptor).
        const extra_target_count: u32 = c.u32At();
        var ti: u32 = 0;
        while (ti < extra_target_count) : (ti += 1) {
            const extra: Value = global().get("Object").new(.{});
            extra.set("format", formatName(c.u32At()));
            _ = targets.call("push", .{extra});
        }
        const fragment: Value = global().get("Object").new(.{});
        fragment.set("module", tblGet(fs_module));
        fragment.set("entryPoint", fs_entry);
        fragment.set("targets", targets);
        if (const_count > 0) {
            fragment.set("constants", constants_obj);
        }
        desc.set("fragment", fragment);
        const primitive: Value = global().get("Object").new(.{});
        primitive.set("topology", topologyName(topo));
        primitive.set("cullMode", cullModeName(cull));
        desc.set("primitive", primitive);
        const multisample: Value = global().get("Object").new(.{});
        multisample.set("count", numValue(@floatFromInt(sample_count)));
        desc.set("multisample", multisample);
        if (depth != 0 and depth_format != 0) {
            const ds: Value = global().get("Object").new(.{});
            ds.set("format", formatName(depth_format));
            const write_enabled: Value = global().get("Boolean").call(
                "call",
                .{ Value{ .h = 0 }, numValue(if (depth_write != 0) 1 else 0) },
            );
            ds.set("depthWriteEnabled", write_enabled);
            ds.set("depthCompare", depth_compare);
            desc.set("depthStencil", ds);
        }
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createRenderPipeline", .{desc})));
    }
    fn jsDeviceCreateComputePipeline(
        _: f64,
        layout: f64,
        shader_module: f64,
        entry_point_ptr: f64,
        entry_point_len: f64,
        label_ptr: f64,
        label_len: f64,
    ) f64 {
        const compute: Value = global().get("Object").new(.{});
        compute.set("module", tblGet(shader_module));
        compute.set("entryPoint", modString(entry_point_ptr, entry_point_len));
        const desc: Value = global().get("Object").new(.{});
        desc.set("layout", tblGet(layout));
        desc.set("compute", compute);
        desc.set("label", modString(label_ptr, label_len));
        return @floatFromInt(tblInsert(g.boot.gpu_device.call("createComputePipeline", .{desc})));
    }

    // ---- copies + async buffer readback (Phase 3d remainder) ---------------
    fn jsEncoderCopyBufferToBuffer(
        encoder: f64,
        src: f64,
        src_off: f64,
        dst: f64,
        dst_off: f64,
        size: f64,
    ) void {
        const enc: Value = tblGet(encoder);
        if (enc.isNull()) {
            return;
        }
        _ = enc.call("copyBufferToBuffer", .{
            tblGet(src),    numValue(src_off),
            tblGet(dst),    numValue(dst_off),
            numValue(size),
        });
    }
    fn jsEncoderCopyTextureToBuffer(
        encoder: f64,
        texture: f64,
        dst: f64,
        bytes_per_row: f64,
        width: f64,
        height: f64,
    ) void {
        const enc: Value = tblGet(encoder);
        if (enc.isNull()) {
            return;
        }
        const src: Value = global().get("Object").new(.{});
        src.set("texture", tblGet(texture));
        const dst_obj: Value = global().get("Object").new(.{});
        dst_obj.set("buffer", tblGet(dst));
        dst_obj.set("bytesPerRow", numValue(bytes_per_row));
        const extent: Value = global().get("Object").new(.{});
        extent.set("width", numValue(width));
        extent.set("height", numValue(height));
        _ = enc.call("copyTextureToBuffer", .{ src, dst_obj, extent });
    }

    // Async readback, poll-based. The TS version mutated a closure-captured
    // record from mapAsync().then(); closures don't exist here, so the read
    // record is a JS object {buf, size, promise_id, data} in the handle
    // table, and the POLL drives the state machine through the promise
    // kernel: resolved -> snapshot getMappedRange (the mapped ArrayBuffer
    // detaches on unmap, so copy first), unmap, stash data.
    fn jsBufferReadStart(buf_id: f64, size: f64) f64 {
        const buf: Value = tblGet(buf_id);
        if (buf.isNull()) {
            return 0;
        }
        const map_read: f64 = 1; // GPUMapMode.READ
        const promise: Value = buf.call("mapAsync", .{ numValue(map_read), numValue(0), numValue(size) });
        const rec: Value = global().get("Object").new(.{});
        rec.set("buf", buf);
        rec.set("size", numValue(size));
        rec.set("pid", numValue(@floatFromInt(js_promise_register(promise.h))));
        rec.set("data", Value{ .h = 0 });
        return @floatFromInt(tblInsert(rec));
    }
    fn jsBufferReadPoll(handle: f64) f64 {
        const rec: Value = tblGet(handle);
        if (rec.isNull()) {
            return 0;
        }
        if (!rec.get("data").isNull()) {
            return 1;
        }
        const pid: u32 = @trunc(js_to_num(rec.get("pid").h));
        const status: u32 = js_promise_status(pid);
        if (status == 0) {
            return 0;
        }
        _ = js_promise_take(pid);
        if (status == 2) {
            // Rejected map: mark ready-with-empty so the poller doesn't hang.
            rec.set("data", global().get("Uint8Array").new(.{num(0)}));
            return 1;
        }
        const buf: Value = rec.get("buf");
        const size: Value = rec.get("size");
        const mapped: Value = global().get("Uint8Array").new(.{buf.call("getMappedRange", .{ numValue(0), size })});
        rec.set("data", mapped.call("slice", .{}));
        _ = buf.call("unmap", .{});
        return 1;
    }
    fn jsBufferReadInto(handle: f64, ptr: f64, len: f64) void {
        const rec: Value = tblGet(handle);
        if (rec.isNull()) {
            return;
        }
        const data: Value = rec.get("data");
        if (data.isNull()) {
            return;
        }
        const dst: Value = modBytes(ptr, len);
        const avail: f64 = js_to_num(data.get("length").h);
        const n: f64 = if (len < avail) len else avail;
        _ = dst.call("set", .{data.call("subarray", .{ numValue(0), numValue(n) })});
    }
    fn jsBufferReadRelease(handle: f64) void {
        tblRelease(handle);
    }

    fn jsAdapterInfo(ptr: f64, cap: f64) f64 {
        const info: Value = g.boot.gpu_adapter.get("info");
        var text: Value = str("adapter info unavailable");
        if (!info.isNull()) {
            const parts: Value = global().get("Array").new(.{});
            _ = parts.call("push", .{info.get("vendor")});
            _ = parts.call("push", .{info.get("architecture")});
            _ = parts.call("push", .{info.get("device")});
            _ = parts.call("push", .{info.get("description")});
            text = parts.call("filter", .{global().get("Boolean")}).call("join", .{str(" | ")});
        }
        if (g.wgpu.text_encoder.isNull()) {
            g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
        }
        // encodeInto a view over MODULE memory: wasm Memory buffers are
        // non-resizable, so this is the legal one-pass path.
        const dst: Value = modBytes(ptr, cap);
        const result: Value = g.wgpu.text_encoder.call("encodeInto", .{ text, dst });
        return js_to_num(result.get("written").h);
    }

    /// Build the "wgpu" import namespace (classic verbs; the slice's
    /// current_view/clear pair stays alongside in the same object).
    fn install(ns: Value) void {
        ns.set("js_init_device", funcNum(&jsInitDevice));
        ns.set("js_device_get_queue", funcNum(&jsDeviceGetQueue));
        ns.set("js_get_surface", funcNum(&jsGetSurface));
        ns.set("js_surface_get_current_texture", funcNum(&jsSurfaceGetCurrentTexture));
        ns.set("js_surface_present", funcNum(&jsSurfacePresent));
        ns.set("js_surface_get_format", funcNum(&jsSurfaceGetFormat));
        ns.set("js_surface_get_size", funcNum(&jsSurfaceGetSize));
        ns.set("js_surface_get_css_size", funcNum(&jsSurfaceGetCssSize));
        ns.set("js_now_ms", funcNum(&jsNowMs));
        ns.set("js_gpu_ms_last", funcNum(&jsGpuMsLast));
        ns.set("js_device_create_buffer", funcNum(&jsDeviceCreateBuffer));
        ns.set("js_buffer_destroy", funcNum(&jsBufferDestroy));
        ns.set("js_queue_write_buffer", funcNum(&jsQueueWriteBuffer));
        ns.set("js_device_create_shader_module_wgsl", funcNum(&jsDeviceCreateShaderModuleWgsl));
        ns.set("js_device_create_sampler", funcNum(&jsDeviceCreateSampler));
        ns.set("js_device_create_command_encoder", funcNum(&jsDeviceCreateCommandEncoder));
        ns.set("js_command_encoder_finish", funcNum(&jsCommandEncoderFinish));
        ns.set("js_queue_submit", funcNum(&jsQueueSubmit));
        ns.set("js_encoder_begin_render_pass", funcNum(&jsEncoderBeginRenderPass));
        ns.set("js_encoder_begin_render_pass_mrt", funcNum(&jsEncoderBeginRenderPassMrt));
        ns.set("js_render_pass_set_pipeline", funcNum(&jsRenderPassSetPipeline));
        ns.set("js_render_pass_set_bind_group", funcNum(&jsRenderPassSetBindGroup));
        ns.set("js_render_pass_set_vertex_buffer", funcNum(&jsRenderPassSetVertexBuffer));
        ns.set("js_render_pass_set_index_buffer", funcNum(&jsRenderPassSetIndexBuffer));
        ns.set("js_render_pass_draw", funcNum(&jsRenderPassDraw));
        ns.set("js_render_pass_draw_indexed", funcNum(&jsRenderPassDrawIndexed));
        ns.set("js_render_pass_set_scissor_rect", funcNum(&jsRenderPassSetScissorRect));
        ns.set("js_render_pass_end", funcNum(&jsRenderPassEnd));
        ns.set("js_encoder_begin_compute_pass", funcNum(&jsEncoderBeginComputePass));
        ns.set("js_compute_pass_set_pipeline", funcNum(&jsComputePassSetPipeline));
        ns.set("js_compute_pass_set_bind_group", funcNum(&jsComputePassSetBindGroup));
        ns.set("js_compute_pass_dispatch_workgroups", funcNum(&jsComputePassDispatchWorkgroups));
        ns.set("js_compute_pass_end", funcNum(&jsComputePassEnd));
        ns.set("js_device_create_texture", funcNum(&jsDeviceCreateTexture));
        ns.set("js_texture_create_view", funcNum(&jsTextureCreateView));
        ns.set("js_texture_create_view_mip", funcNum(&jsTextureCreateViewMip));
        ns.set("js_texture_create_view_array", funcNum(&jsTextureCreateViewArray));
        ns.set("js_texture_destroy", funcNum(&jsTextureDestroy));
        ns.set("js_bind_group_destroy", funcNum(&jsBindGroupDestroy));
        ns.set("js_bind_group_layout_destroy", funcNum(&jsBindGroupLayoutDestroy));
        ns.set("js_pipeline_layout_destroy", funcNum(&jsPipelineLayoutDestroy));
        ns.set("js_render_pipeline_destroy", funcNum(&jsRenderPipelineDestroy));
        ns.set("js_compute_pipeline_destroy", funcNum(&jsComputePipelineDestroy));
        ns.set("js_sampler_destroy", funcNum(&jsSamplerDestroy));
        ns.set("js_shader_module_destroy", funcNum(&jsShaderModuleDestroy));
        ns.set("js_texture_view_destroy", funcNum(&jsTextureViewDestroy));
        ns.set("js_queue_write_texture", funcNum(&jsQueueWriteTexture));
        ns.set("js_device_create_bind_group_layout", funcNum(&jsDeviceCreateBindGroupLayout));
        ns.set("js_device_create_bind_group", funcNum(&jsDeviceCreateBindGroup));
        ns.set("js_device_create_pipeline_layout", funcNum(&jsDeviceCreatePipelineLayout));
        ns.set("js_device_create_render_pipeline", funcNum(&jsDeviceCreateRenderPipeline));
        ns.set("js_device_create_compute_pipeline", funcNum(&jsDeviceCreateComputePipeline));
        ns.set("js_encoder_copy_buffer_to_buffer", funcNum(&jsEncoderCopyBufferToBuffer));
        ns.set("js_encoder_copy_texture_to_buffer", funcNum(&jsEncoderCopyTextureToBuffer));
        ns.set("js_buffer_read_start", funcNum(&jsBufferReadStart));
        ns.set("js_buffer_read_poll", funcNum(&jsBufferReadPoll));
        ns.set("js_buffer_read_into", funcNum(&jsBufferReadInto));
        ns.set("js_buffer_read_release", funcNum(&jsBufferReadRelease));
        ns.set("js_adapter_info", funcNum(&jsAdapterInfo));
    }
};

const ZimrWasi = struct {
    fn ok() f64 {
        return 0;
    }
    fn badf() f64 {
        return 8;
    }
    fn randomGet(ptr: f64, len: f64) f64 {
        const view: Value = ZimrWgpu.modBytes(ptr, len);
        _ = global().get("crypto").call("getRandomValues", .{view});
        return 0;
    }
    fn procExit(code: f64) void {
        _ = global().call("__wzFail", .{fmt("proc_exit({d})", .{code})});
    }

    fn install(ns: Value) void {
        const success = [_][]const u8{
            "fd_write",       "fd_close",          "fd_fdstat_get", "fd_sync",
            "clock_time_get", "clock_res_get",     "poll_oneoff",   "args_sizes_get",
            "args_get",       "environ_sizes_get", "environ_get",
        };
        inline for (success) |name| {
            ns.set(name, funcNum(&ok));
        }
        const efile = [_][]const u8{
            "fd_read",          "fd_pwrite",            "fd_pread",              "fd_seek",
            "fd_filestat_get",  "fd_filestat_set_size", "fd_filestat_set_times", "fd_readdir",
            "path_open",        "path_filestat_get",    "path_create_directory", "path_remove_directory",
            "path_unlink_file", "path_rename",          "path_link",             "path_symlink",
            "path_readlink",
        };
        inline for (efile) |name| {
            ns.set(name, funcNum(&badf));
        }
        ns.set("random_get", funcNum(&randomGet));
        ns.set("proc_exit", funcNum(&procExit));
    }
};

const ZimrInput = struct {
    fn ex() Value {
        return g.boot.module_exports;
    }
    fn callIfPresent(comptime name: []const u8, args: anytype) void {
        if (!ex().get(name).isNull()) {
            _ = ex().call(name, args);
        }
    }
    fn localXY(event: Value) [2]f64 {
        const canvas: Value = g.wgpu.canvas;
        const rect: Value = canvas.call("getBoundingClientRect", .{});
        const rw: f64 = js_to_num(rect.get("width").h);
        const rh: f64 = js_to_num(rect.get("height").h);
        // `clientWidth/Height` are the UN-transformed CSS layout size; the bounding
        // rect is POST-transform. Their ratio is the container's effective scale,
        // so pointer coords stay correct even when an ancestor (e.g. the in-app
        // viewer) CSS-scales the canvas. In a plain browser the ratio is 1 (no-op).
        const sx: f64 = if (rw > 0) js_to_num(canvas.get("clientWidth").h) / rw else 1;
        const sy: f64 = if (rh > 0) js_to_num(canvas.get("clientHeight").h) / rh else 1;
        const x: f64 = (js_to_num(event.get("clientX").h) - js_to_num(rect.get("left").h)) * sx;
        const y: f64 = (js_to_num(event.get("clientY").h) - js_to_num(rect.get("top").h)) * sy;
        return .{ x, y };
    }
    fn numArg(x: f64) Value {
        return .{ .h = js_num(x) };
    }

    fn pointerId(e: Value) f64 {
        return js_to_num(e.get("pointerId").h);
    }
    fn onPointerDown(ev: Handle) void {
        const e: Value = .{ .h = ev };
        const p: [2]f64 = localXY(e);
        // Per-pointer -> the touch ring.
        callIfPresent("zimr_input_push_touch_down", .{ numArg(pointerId(e)), numArg(p[0]), numArg(p[1]) });
        // Mouse channel: move-then-button on every down (the proven TS shape).
        callIfPresent("input_push_mouse_move", .{ numArg(p[0]), numArg(p[1]) });
        callIfPresent("input_push_mouse_button_down", .{numArg(js_to_num(e.get("button").h))});
        g.input.dragging = true;
        _ = e.call("preventDefault", .{});
    }
    fn onPointerMove(ev: Handle) void {
        const e: Value = .{ .h = ev };
        const p: [2]f64 = localXY(e);
        // Per-pointer -> the touch ring (tracks by id).
        callIfPresent("zimr_input_push_touch_move", .{ numArg(pointerId(e)), numArg(p[0]), numArg(p[1]) });
        // Mouse channel on EVERY move, exactly as the proven TS bridge did
        // (no isPrimary gate - the viewer may report isPrimary falsey for a
        // touch pointer, which would silently drop the drag).
        callIfPresent("input_push_mouse_move", .{ numArg(p[0]), numArg(p[1]) });
    }
    fn onPointerUp(ev: Handle) void {
        const e: Value = .{ .h = ev };
        callIfPresent("zimr_input_push_touch_up", .{numArg(pointerId(e))});
        g.input.dragging = false;
        callIfPresent("input_push_mouse_button_up", .{numArg(js_to_num(e.get("button").h))});
    }
    fn onWheel(ev: Handle) void {
        const e: Value = .{ .h = ev };
        // Normalize to raylib's contract: ~1.0 per wheel notch. The browser
        // reports deltas in whatever unit `deltaMode` says -- pixels (~100 per
        // notch on Chrome), lines (~3 per notch), or pages (1 per notch) -- and
        // forwarding those raw made one notch read as ~100. Every consumer here
        // is written for per-notch units (ui.zig scrolls `5 * font_size` PER
        // UNIT, plot_ui's zoom_rate is "fraction per wheel notch"), so raw px
        // sent scroll and camera zoom straight to their limits in one notch.
        // Trackpads keep their fine-grained feel: small pixel deltas stay
        // small fractions of a notch.
        const delta_mode: u32 = @trunc(js_to_num(e.get("deltaMode").h));
        const per_notch: f64 = switch (delta_mode) {
            1 => 3.0, // DOM_DELTA_LINE: ~3 lines per notch
            2 => 1.0, // DOM_DELTA_PAGE: already one notch
            else => 100.0, // DOM_DELTA_PIXEL: ~100 px per notch
        };
        callIfPresent("input_push_mouse_wheel", .{
            numArg(js_to_num(e.get("deltaX").h) / per_notch),
            numArg(-js_to_num(e.get("deltaY").h) / per_notch),
        });
        _ = e.call("preventDefault", .{});
    }
    fn onKeyDown(ev: Handle) void {
        const e: Value = .{ .h = ev };
        const repeat: f64 = if (e.get("repeat").truthy()) 1 else 0;
        callIfPresent("input_push_key_down", .{ numArg(js_to_num(e.get("keyCode").h)), numArg(repeat) });
    }
    fn onKeyUp(ev: Handle) void {
        const e: Value = .{ .h = ev };
        callIfPresent("input_push_key_up", .{numArg(js_to_num(e.get("keyCode").h))});
    }
    fn onContextMenu(ev: Handle) void {
        const e: Value = .{ .h = ev };
        _ = e.call("preventDefault", .{});
    }
    fn onDeviceMotion(ev: Handle) void {
        const e: Value = .{ .h = ev };
        // accelerationIncludingGravity is the device's PROPER acceleration - the
        // one vector that already fuses gravity + motion (equivalence principle).
        // It's null until the first real sample, and stays null on non-https
        // origins (which fire the event but withhold data) -> skip those, the app
        // keeps its plain-down fallback.
        const acc: Value = e.get("accelerationIncludingGravity");
        if (!acc.truthy()) {
            return;
        }
        // screen.orientation.angle (0/90/180/270) lets the reader rotate the
        // device frame into the current canvas. Default 0 if unavailable.
        var angle: f64 = 0;
        const scr: Value = global().get("screen");
        if (scr.truthy()) {
            const ori: Value = scr.get("orientation");
            if (ori.truthy()) {
                angle = js_to_num(ori.get("angle").h);
            }
        }
        callIfPresent("input_push_motion", .{
            numArg(js_to_num(acc.get("x").h)),
            numArg(js_to_num(acc.get("y").h)),
            numArg(js_to_num(acc.get("z").h)),
            numArg(angle),
        });
    }

    /// Attach the full listener set; the canvas must exist (the classic
    /// engine creates it via js_get_surface during _initialize).
    /// {passive: false} - REQUIRED for touch/wheel. Browsers default these
    /// listeners to passive, which makes preventDefault() a silent no-op and
    /// lets a wrapping scroll container (e.g. an embedding iframe/in-app
    /// viewer) STEAL the gesture after touchstart - the canvas never sees
    /// touchmove. Top-level Chrome has no such container so it "worked"
    /// there; the in-app viewer did not. Non-passive + preventDefault keeps
    /// the whole gesture ours.
    fn passiveFalse() Value {
        const opts: Value = global().get("Object").new(.{});
        opts.set("passive", global().get("Boolean").call("call", .{ Value{ .h = 0 }, numArg(0) }));
        return opts;
    }
    fn install() void {
        // Pointer Events ONLY - they unify mouse + touch + pen, so we never
        // double-bind (binding touch* alongside pointer* double-delivered
        // each finger and, worse, touchstart's preventDefault suppressed the
        // primary finger's pointer events - the "first finger dead" bug).
        // All listeners on the CANVAS; setPointerCapture in onPointerDown
        // keeps a straying drag attached without window-level listeners
        // (which were the iframe-fragile part in the in-app viewer).
        // Pointer Events ONLY (they unify mouse/touch/pen). DOWN + WHEEL on
        // the canvas; MOVE/UP/CANCEL on WINDOW so a drag that leaves the
        // canvas still tracks WITHOUT setPointerCapture (capture broke move
        // delivery for touch pointers inside the in-app viewer's iframe -
        // press landed, drag died). This is assert_demo.html's proven shape.
        const canvas: Value = g.wgpu.canvas;
        const opts: Value = passiveFalse();
        _ = canvas.call("addEventListener", .{ str("pointerdown"), func(&onPointerDown), opts });
        _ = global().call("addEventListener", .{ str("pointermove"), func(&onPointerMove), opts });
        _ = global().call("addEventListener", .{ str("pointerup"), func(&onPointerUp), opts });
        _ = global().call("addEventListener", .{ str("pointercancel"), func(&onPointerUp), opts });
        _ = canvas.call("addEventListener", .{ str("wheel"), func(&onWheel), opts });
        _ = global().call("addEventListener", .{ str("keydown"), func(&onKeyDown) });
        _ = global().call("addEventListener", .{ str("keyup"), func(&onKeyUp) });
        // Accelerometer (tilt). Harmless if unused - the handler just routes
        // samples into input state. On Android it fires immediately; iOS would
        // need a tap-gated requestPermission() (deferred - Android-first).
        // Data only arrives on https/localhost origins (see onDeviceMotion).
        _ = global().call("addEventListener", .{ str("devicemotion"), func(&onDeviceMotion) });
        _ = canvas.call("addEventListener", .{ str("contextmenu"), func(&onContextMenu) });
    }
};

const ZimrBoot = struct {
    const EvRec = extern struct { code: u32, a: f32, b: f32 };

    fn note(comptime msg: []const u8) void {
        // Route to console.log - the page's bottom log overlay mirrors it and
        // devtools shows it. (The old bare <pre> rendered black-on-black on the
        // dark page, which is why these diagnostics were invisible.)
        _ = global().get("console").call("log", .{str(msg)});
    }

    /// Surface uncaptured WebGPU validation errors (device 'uncapturederror').
    /// These are otherwise SILENT - a bad pipeline/pass (e.g. a render pipeline
    /// whose depth-stencil doesn't match the pass's depth attachment) just paints
    /// black with no clue. Logging the GPU's own message turns "why is it black?"
    /// into a one-line diagnosis, on-device (the page log mirrors console.error).
    ///
    /// ALSO paints it full-screen via `__wzFail`. console.error alone is not
    /// enough on a phone: the bottom log overlay is `bottom:0` and
    /// `pointer-events:none`, so inside an embedded viewer (the Claude app's
    /// HTML preview, an iframe, any chrome that overlaps the bottom strip) it can
    /// be cropped out of sight - and a webview has no devtools to fall back on.
    /// A command-buffer rejection paints black anyway, so there is nothing to
    /// occlude: taking the screen is strictly better than being invisible. The
    /// panel is selectable, so the GPU's exact wording can be copied off-device.
    fn onGpuError(ev: Handle) void {
        const e: Value = .{ .h = ev };
        const msg: Value = e.get("error").get("message");
        _ = global().get("console").call("error", .{ str("[zimr GPU] "), msg });
        const fail: Value = global().get("__wzFail");
        // __wzFail takes ONE argument, so the message goes through alone; the
        // panel supplies its own heading.
        if (fail.h != 0) {
            _ = fail.call("call", .{ global(), msg });
        }
    }

    fn modU8(ptr: u32, len: u32) Value {
        const buf: Value = g.boot.module_exports.get("memory").get("buffer");
        return global().get("Uint8Array").new(.{ buf, ptr, len });
    }
    fn modStr(ptr: Handle, len: Handle) Value {
        const p: u32 = @trunc(js_to_num(ptr));
        const l: u32 = @trunc(js_to_num(len));
        return g.boot.utf8_decoder.call("decode", .{modU8(p, l)});
    }

    // ---- the "dom" import namespace (D10) --------------------------------
    fn domCreate(tp: Handle, tl: Handle) u32 {
        return (Value{ .h = js_global() }).get("document").call("createElement", .{modStr(tp, tl)}).h;
    }
    fn domAttachBody(h: Handle) void {
        _ = document().body().j.call("appendChild", .{Value{ .h = @trunc(js_to_num(h)) }});
    }
    fn domAppend(parent: Handle, child: Handle) void {
        const p: Value = .{ .h = @trunc(js_to_num(parent)) };
        _ = p.call("appendChild", .{Value{ .h = @trunc(js_to_num(child)) }});
    }
    fn domSetText(
        h: Handle,
        p: Handle,
        l: Handle,
    ) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        e.set("textContent", modStr(p, l));
    }
    fn domSetAttr(
        h: Handle,
        kp: Handle,
        kl: Handle,
        vp: Handle,
        vl: Handle,
    ) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        _ = e.call("setAttribute", .{ modStr(kp, kl), modStr(vp, vl) });
    }
    fn domSetStyle(
        h: Handle,
        p: Handle,
        l: Handle,
    ) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        e.get("style").set("cssText", modStr(p, l));
    }
    fn domCss(p: Handle, l: Handle) void {
        const st: Value = (Value{ .h = js_global() }).get("document").call("createElement", .{str("style")});
        st.set("textContent", modStr(p, l));
        _ = document().head().j.call("appendChild", .{st});
    }
    fn domRemove(h: Handle) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        _ = e.call("remove", .{});
    }
    fn onDomEvent(ev: Handle) void {
        // The event carries our code on the listener target (data-zb attr).
        const e: Value = .{ .h = ev };
        const tgt: Value = e.get("currentTarget");
        const code: u32 = @trunc(js_to_num(tgt.call("getAttribute", .{str("data-zbcode")}).h));
        if (g.boot.event_count < g.boot.event_ring.len) {
            g.boot.event_ring[g.boot.event_count] = .{
                .code = code,
                .a = @floatCast(js_to_num(e.get("offsetX").h)),
                .b = @floatCast(js_to_num(e.get("offsetY").h)),
            };
            g.boot.event_count += 1;
        }
    }
    fn domListen(
        h: Handle,
        ep: Handle,
        el: Handle,
        code: Handle,
    ) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        _ = e.call("setAttribute", .{ str("data-zbcode"), Value{ .h = code } });
        _ = e.call("addEventListener", .{ modStr(ep, el), func(&onDomEvent) });
    }
    fn domPollEvent(out_ptr: Handle) u32 {
        if (g.boot.event_count == 0) {
            return 0;
        }
        g.boot.event_count -= 1;
        const rec: EvRec = g.boot.event_ring[g.boot.event_count];
        const p: u32 = @trunc(js_to_num(out_ptr));
        const dv: Value = global().get("DataView").new(.{g.boot.module_exports.get("memory").get("buffer")});
        _ = dv.call("setUint32", .{ p, rec.code, true });
        _ = dv.call("setFloat32", .{ p + 4, rec.a, true });
        _ = dv.call("setFloat32", .{ p + 8, rec.b, true });
        return 1;
    }
    fn domCanvasConfigure(h: Handle) u32 {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        const ctx: Value = e.call("getContext", .{str("webgpu")});
        if (ctx.isNull()) {
            return 0;
        }
        // Force rgba8unorm rather than getPreferredCanvasFormat() (bgra8unorm on
        // desktop). The engine is RGBA8 everywhere - render textures are
        // rgba8unorm - so a BGRA8 canvas makes the cached 2D "shapes" pipeline
        // (built for the backbuffer format) incompatible with render-texture
        // passes. One format across the whole engine keeps that pipeline valid
        // in both the swapchain and RTT passes.
        const preferred_format: Value = str("rgba8unorm");
        const cfg: Value = global().get("Object").new(.{});
        cfg.set("device", g.boot.gpu_device);
        cfg.set("format", preferred_format);
        cfg.set("alphaMode", str("opaque"));
        _ = ctx.call("configure", .{cfg});
        _ = g.boot.canvas_contexts.call("set", .{ Value{ .h = @trunc(js_to_num(h)) }, ctx });
        return 1;
    }
    fn domCanvasSize(h: Handle, out_ptr: Handle) void {
        const e: Value = .{ .h = @trunc(js_to_num(h)) };
        const dpr: f64 = js_to_num(global().get("devicePixelRatio").h);
        const w: u32 = @trunc(js_to_num(e.get("clientWidth").h) * dpr);
        const ht: u32 = @trunc(js_to_num(e.get("clientHeight").h) * dpr);
        e.set("width", Value{ .h = js_num(@floatFromInt(w)) });
        e.set("height", Value{ .h = js_num(@floatFromInt(ht)) });
        const p: u32 = @trunc(js_to_num(out_ptr));
        const dv: Value = global().get("DataView").new(.{g.boot.module_exports.get("memory").get("buffer")});
        _ = dv.call("setUint32", .{ p, w, true });
        _ = dv.call("setUint32", .{ p + 4, ht, true });
    }

    // ---- user-file port (drag-and-drop + the mobile file picker) ---------
    //
    // Both entry points feed ONE queue, because a caller should not care whether the bytes
    // arrived by drag or by picker - see `web.zig`'s `userfile` for the full rationale.
    //
    // * `preventDefault` is needed on BOTH `dragover` AND `drop`. Without the first the drop
    // event never fires; without the second the browser NAVIGATES AWAY to the dropped file,
    // discarding the whole app. It is the classic first bug in every web drop implementation
    // and it looks exactly like "the page crashed".

    fn ufEnsureQueue() void {
        if (g.userfile.queue.h == 0) {
            g.userfile.queue = global().get("Array").new(.{});
        }
    }

    /// A resolved `arrayBuffer()`: push `{ name, bytes }` onto the queue.
    ///
    /// The name is carried on the promise itself (`p.__zimr_name`) rather than in a Zig-side
    /// map, because several reads can be in flight at once and the transpiler forbids closures
    /// - so the only place to hang per-operation state is the JS object already in hand.
    fn ufOnBuffer(buf_h: Handle) void {
        ufEnsureQueue();
        const buf: Value = .{ .h = buf_h };
        const rec: Value = global().get("Object").new(.{});
        rec.set("bytes", global().get("Uint8Array").new(.{buf}));
        rec.set("name", g.userfile.pending_name);
        _ = g.userfile.queue.call("push", .{rec});
    }

    fn ufAcceptFile(file: Value) void {
        // Remember the name before the read starts; `ufOnBuffer` has no other way to get it.
        g.userfile.pending_name = file.get("name");
        _ = file.call("arrayBuffer", .{}).call("then", .{func(&ufOnBuffer)});
    }

    fn ufOnDragOver(ev: Handle) void {
        const e: Value = .{ .h = ev };
        _ = e.call("preventDefault", .{});
    }

    fn ufOnDrop(ev: Handle) void {
        const e: Value = .{ .h = ev };
        _ = e.call("preventDefault", .{});
        const dt: Value = e.get("dataTransfer");
        if (dt.isNull()) {
            return;
        }
        const files: Value = dt.get("files");
        if (files.isNull()) {
            return;
        }
        const n: f64 = js_to_num(files.get("length").h);
        var i: f64 = 0;
        while (i < n) : (i += 1) {
            ufAcceptFile(files.call("item", .{num(i)}));
        }
    }

    fn ufOnPicked(ev: Handle) void {
        const e: Value = .{ .h = ev };
        const picker: Value = e.get("target");
        const files: Value = picker.get("files");
        if (files.isNull()) {
            return;
        }
        const n: f64 = js_to_num(files.get("length").h);
        var i: f64 = 0;
        while (i < n) : (i += 1) {
            ufAcceptFile(files.call("item", .{num(i)}));
        }
        // Clear the value, or picking the SAME file twice fires no second `change` event.
        picker.set("value", str(""));
    }

    fn ufEnsureListening() void {
        if (g.userfile.listening) {
            return;
        }
        g.userfile.listening = true;
        ufEnsureQueue();
        const target: Value = global().get("window");
        _ = target.call("addEventListener", .{ str("dragover"), func(&ufOnDragOver) });
        _ = target.call("addEventListener", .{ str("drop"), func(&ufOnDrop) });
    }

    fn ufPendingCount() f64 {
        if (g.userfile.queue.h == 0) {
            return 0;
        }
        return js_to_num(g.userfile.queue.get("length").h);
    }

    fn ufHead() Value {
        return g.userfile.queue.call("at", .{num(0)});
    }

    fn ufNextSize() f64 {
        if (ufPendingCount() == 0) {
            return 0;
        }
        return js_to_num(ufHead().get("bytes").get("length").h);
    }

    fn ufNextName(out_ptr: f64, out_cap: f64) f64 {
        if (ufPendingCount() == 0) {
            return 0;
        }
        if (g.wgpu.text_encoder.isNull()) {
            g.wgpu.text_encoder = global().get("TextEncoder").new(.{});
        }
        const bytes: Value = g.wgpu.text_encoder.call("encode", .{ufHead().get("name")});
        const n: f64 = js_to_num(bytes.get("length").h);
        if (n > out_cap) {
            return 0;
        }
        _ = modU8(@trunc(out_ptr), @trunc(n)).call("set", .{bytes});
        return n;
    }

    /// Copy the head's bytes out and drop it. A too-small buffer returns 0 and LEAVES the file
    /// queued, so a caller that mis-sized can size again from `nextSize` and retry rather than
    /// silently lose the drop.
    fn ufReadNext(out_ptr: f64, out_cap: f64) f64 {
        if (ufPendingCount() == 0) {
            return 0;
        }
        const bytes: Value = ufHead().get("bytes");
        const n: f64 = js_to_num(bytes.get("length").h);
        if (n > out_cap) {
            return 0;
        }
        _ = modU8(@trunc(out_ptr), @trunc(n)).call("set", .{bytes});
        _ = g.userfile.queue.call("shift", .{});
        return n;
    }

    fn ufDiscardNext() void {
        if (ufPendingCount() == 0) {
            return;
        }
        _ = g.userfile.queue.call("shift", .{});
    }

    /// Park the invisible `<input type="file">` over the caller's button rectangle.
    ///
    /// Opacity 0 rather than `display:none` or `visibility:hidden`: a hidden input cannot be
    /// tapped, and the whole point is that the TAP must land on a real DOM element so the
    /// browser sees a genuine user gesture. The canvas still draws the visible button.
    fn ufSetPickerRect(
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        accept_ptr: f64,
        accept_len: f64,
    ) void {
        ufEnsureListening();
        if (g.userfile.input.h == 0) {
            const el: Value = document().j.call("createElement", .{str("input")});
            el.set("type", str("file"));
            const st: Value = el.get("style");
            st.set("position", str("fixed"));
            st.set("opacity", str("0"));
            st.set("zIndex", str("99998"));
            st.set("cursor", str("pointer"));
            _ = el.call("addEventListener", .{ str("change"), func(&ufOnPicked) });
            _ = document().body().j.call("appendChild", .{el});
            g.userfile.input = el;
        }
        const el: Value = g.userfile.input;
        el.set("accept", modStr(js_num(accept_ptr), js_num(accept_len)));
        const st: Value = el.get("style");
        st.set("display", str("block"));
        ovSetPx(st, "left", x);
        ovSetPx(st, "top", y);
        ovSetPx(st, "width", w);
        ovSetPx(st, "height", h);
    }

    /// The Save overlay: created once, a real `<a>` so a tap on it is a genuine gesture - which a
    /// mobile browser requires before it will save a file, exactly as it does before opening a
    /// picker.
    fn ufEnsureSaveAnchor() void {
        if (g.userfile.save.h != 0) {
            return;
        }
        const el: Value = document().j.call("createElement", .{str("a")});
        const st: Value = el.get("style");
        st.set("position", str("fixed"));
        st.set("opacity", str("0"));
        st.set("zIndex", str("99998"));
        st.set("cursor", str("pointer"));
        st.set("display", str("none"));
        _ = document().body().j.call("appendChild", .{el});
        g.userfile.save = el;
    }

    /// Make `bytes` the file the Save overlay hands over, named `name`. The Blob takes a COPY of
    /// wasm memory, so the caller may reuse its buffer the moment this returns.
    fn ufOffer(ptr: f64, len: f64, name_ptr: f64, name_len: f64) void {
        ufEnsureSaveAnchor();
        const view: Value = modU8(@trunc(ptr), @trunc(len));
        const copy: Value = global().get("Uint8Array").new(.{view});
        const parts: Value = global().get("Array").new(.{});
        _ = parts.call("push", .{copy});
        const opts: Value = global().get("Object").new(.{});
        opts.set("type", str("application/octet-stream"));
        const blob: Value = global().get("Blob").new(.{ parts, opts });
        if (g.userfile.save_url.h != 0) {
            _ = global().get("URL").call("revokeObjectURL", .{g.userfile.save_url});
        }
        const url: Value = global().get("URL").call("createObjectURL", .{blob});
        g.userfile.save_url = url;
        g.userfile.save.set("href", url);
        g.userfile.save.set("download", modStr(js_num(name_ptr), js_num(name_len)));
    }

    fn ufSetSaveRect(x: f64, y: f64, w: f64, h: f64) void {
        ufEnsureSaveAnchor();
        const st: Value = g.userfile.save.get("style");
        st.set("display", str("block"));
        ovSetPx(st, "left", x);
        ovSetPx(st, "top", y);
        ovSetPx(st, "width", w);
        ovSetPx(st, "height", h);
    }

    fn ufHideSave() void {
        if (g.userfile.save.h == 0) {
            return;
        }
        g.userfile.save.get("style").set("display", str("none"));
    }

    fn ufHidePicker() void {
        if (g.userfile.input.h == 0) {
            return;
        }
        g.userfile.input.get("style").set("display", str("none"));
    }

    // ---- text-input overlay port (mobile soft-keyboard for editable widgets) ----
    // Ported from the proven src/web/zimr.ts (turn 302; zhobo63-style VISIBLE
    // overlay). A real <input> is positioned over the wasm-drawn widget, focused
    // right after display:block (the trick that pops the mobile keyboard), and
    // polled each frame for its value. TS closures become named handlers here
    // (the transpiler forbids closures / indirect calls - callbacks are `func`).
    // Coords are identity: exact under .responsive (CSS px == wasm px); .fit-mode
    // letterbox scaling and the char-filter `input` listener are follow-ups.
    // overlay state lives in g.overlay (the page singleton) - see BridgeGlobals.

    fn ovKeyIs(k: Value, comptime lit: []const u8) bool {
        return js_to_num(k.call("localeCompare", .{str(lit)}).h) == 0;
    }
    fn ovSetPx(s: Value, comptime field: []const u8, v: f64) void {
        const i: i32 = @trunc(v);
        s.set(field, fmt("{}px", .{i}));
    }
    fn ovRgbCss(rgba_h: Handle) Value {
        // Alpha treated opaque: fmt truncates floats (no fractional alpha), and
        // the focus swap reads fine fully-opaque. Full alpha is a follow-up.
        const rgba: u32 = @trunc(js_to_num(rgba_h));
        const r: u32 = rgba & 0xFF;
        const gg: u32 = (rgba >> 8) & 0xFF;
        const b: u32 = (rgba >> 16) & 0xFF;
        return fmt("rgb({},{},{})", .{ r, gg, b });
    }
    fn overlayOnBlur(_: Handle) void {
        if (g.overlay.el.h == 0) {
            return;
        }
        g.overlay.el.get("style").set("display", str("none"));
        g.overlay.visible = false;
    }
    fn overlayOnKeydown(ev: Handle) void {
        if (g.overlay.el.h == 0) {
            return;
        }
        const e: Value = .{ .h = ev };
        const key: Value = e.get("key");
        if (ovKeyIs(key, "Enter")) {
            _ = e.call("preventDefault", .{});
            _ = g.overlay.el.call("blur", .{});
        } else if (ovKeyIs(key, "Escape")) {
            _ = e.call("preventDefault", .{});
            if (g.overlay.escape_clears) {
                g.overlay.el.set("value", str(""));
            }
            _ = g.overlay.el.call("blur", .{});
        } else if (g.overlay.allow_tab and ovKeyIs(key, "Tab")) {
            _ = e.call("preventDefault", .{});
            const a: Value = g.overlay.el.get("selectionStart");
            const b: Value = g.overlay.el.get("selectionEnd");
            _ = g.overlay.el.call("setRangeText", .{ str("\t"), a, b, str("end") });
        }
    }
    fn ensureOverlayInput() void {
        if (g.overlay.el.h != 0) {
            return;
        }
        const el: Value = document().j.call("createElement", .{str("input")});
        el.set("type", str("text"));
        el.set("autocomplete", str("off"));
        el.set("autocapitalize", str("off"));
        el.set("spellcheck", false);
        el.set("enterKeyHint", str("done"));
        const s: Value = el.get("style");
        s.set("position", str("fixed"));
        s.set("zIndex", str("999"));
        s.set("boxSizing", str("border-box"));
        s.set("margin", str("0"));
        s.set("padding", str("0 4px"));
        s.set("border", str("none"));
        s.set("outline", str("none"));
        s.set("display", str("none"));
        _ = el.call("addEventListener", .{ str("blur"), func(&overlayOnBlur) });
        _ = el.call("addEventListener", .{ str("keydown"), func(&overlayOnKeydown) });
        _ = document().body().j.call("appendChild", .{el});
        g.overlay.el = el;
    }
    fn domShowOverlayInput(
        x: Handle,
        y: Handle,
        w: Handle,
        h: Handle,
        text_ptr: Handle,
        text_len: Handle,
        font_px: Handle,
        fg: Handle,
        bg: Handle,
    ) void {
        ensureOverlayInput();
        if (g.overlay.el.h == 0) {
            return;
        }
        const tlen: u32 = @trunc(js_to_num(text_len));
        if (tlen > 0) {
            g.overlay.el.set("value", modStr(text_ptr, text_len));
        } else {
            g.overlay.el.set("value", str(""));
        }
        const s: Value = g.overlay.el.get("style");
        s.set("fontFamily", str("ui-monospace, monospace"));
        ovSetPx(s, "fontSize", js_to_num(font_px));
        ovSetPx(s, "lineHeight", @max(1.0, js_to_num(h)));
        s.set("color", ovRgbCss(fg));
        s.set("backgroundColor", ovRgbCss(bg));
        ovSetPx(s, "left", js_to_num(x));
        ovSetPx(s, "top", js_to_num(y));
        ovSetPx(s, "width", @max(1.0, js_to_num(w)));
        ovSetPx(s, "height", @max(1.0, js_to_num(h)));
        s.set("display", str("block"));
        g.overlay.visible = true;
        // Focus must come AFTER display:block - focusing a display:none element
        // is a no-op on mobile, and this focus is what raises the soft keyboard.
        _ = g.overlay.el.call("focus", .{});
        const n: u32 = g.overlay.el.get("value").getU32("length");
        _ = g.overlay.el.call("setSelectionRange", .{ n, n });
    }
    fn domHideOverlayInput() void {
        if (g.overlay.el.h == 0) {
            return;
        }
        _ = g.overlay.el.call("blur", .{});
        g.overlay.el.get("style").set("display", str("none"));
        g.overlay.visible = false;
    }
    fn domUpdateOverlayInputRect(x: Handle, y: Handle, w: Handle, h: Handle) void {
        if (g.overlay.el.h == 0 or !g.overlay.visible) {
            return;
        }
        const s: Value = g.overlay.el.get("style");
        ovSetPx(s, "left", js_to_num(x));
        ovSetPx(s, "top", js_to_num(y));
        ovSetPx(s, "width", @max(1.0, js_to_num(w)));
        ovSetPx(s, "height", @max(1.0, js_to_num(h)));
    }
    fn domOverlayInputIsVisible() u32 {
        return if (g.overlay.visible) 1 else 0;
    }
    fn domGetOverlayInputText(out_ptr: Handle, max_len: Handle) usize {
        if (g.overlay.el.h == 0) {
            return 0;
        }
        const v: Value = g.overlay.el.get("value");
        if (v.getU32("length") == 0) {
            return 0;
        }
        const enc: Value = global().get("TextEncoder").new(.{});
        const bytes: Value = enc.call("encode", .{v});
        const blen: u32 = bytes.getU32("length");
        const max: u32 = @trunc(js_to_num(max_len));
        const n: u32 = @min(blen, max);
        const p: u32 = @trunc(js_to_num(out_ptr));
        _ = modU8(p, n).call("set", .{bytes.call("subarray", .{ @as(u32, 0), n })});
        return n;
    }
    fn domSetInputMode(ptr: Handle, len: Handle) void {
        if (g.overlay.el.h == 0) {
            return;
        }
        const l: u32 = @trunc(js_to_num(len));
        if (l == 0) {
            g.overlay.el.set("inputMode", str(""));
        } else {
            g.overlay.el.set("inputMode", modStr(ptr, len));
        }
    }
    fn domSetOverlayInputPassword(on: Handle) void {
        if (g.overlay.el.h == 0) {
            return;
        }
        g.overlay.el.set("type", if (js_to_num(on) != 0) str("password") else str("text"));
    }
    fn domSetOverlayInputReadOnly(on: Handle) void {
        if (g.overlay.el.h == 0) {
            return;
        }
        g.overlay.el.set("readOnly", js_to_num(on) != 0);
    }
    fn domSetOverlayInputEscapeClears(on: Handle) void {
        g.overlay.escape_clears = js_to_num(on) != 0;
    }
    fn domSetOverlayInputAllowTab(on: Handle) void {
        g.overlay.allow_tab = js_to_num(on) != 0;
    }
    fn domSetOverlayInputCharFilters(flags: Handle) void {
        g.overlay.char_filters = @trunc(js_to_num(flags));
    }

    // ---- textarea overlay port (the multiline sibling of the <input> above) ----
    // Same VISIBLE-overlay doctrine, but its OWN page singleton (g.overlay_ta):
    // only one widget is focused at a time, yet an <input> and a <textarea> are
    // different DOM nodes, so caching one handle for both would dangle on a type
    // switch. Everything mirrors the <input> port except Enter handling - see
    // domSetOverlayTextareaCtrlEnterForNewline.

    fn overlayTaOnBlur(_: Handle) void {
        if (g.overlay_ta.el.h == 0) {
            return;
        }
        g.overlay_ta.el.get("style").set("display", str("none"));
        g.overlay_ta.visible = false;
    }
    fn overlayTaOnKeydown(ev: Handle) void {
        if (g.overlay_ta.el.h == 0) {
            return;
        }
        const e: Value = .{ .h = ev };
        const key: Value = e.get("key");
        if (ovKeyIs(key, "Enter")) {
            // Default (ctrl_enter off): fall through - let the browser insert the
            // newline as it normally would. When on: plain Enter commits (blur),
            // and Ctrl/Cmd+Enter inserts the '\n' manually.
            if (g.overlay_ta.ctrl_enter_for_newline) {
                _ = e.call("preventDefault", .{});
                const ctrl: bool = js_to_num(e.get("ctrlKey").h) != 0 or
                    js_to_num(e.get("metaKey").h) != 0;
                if (ctrl) {
                    const a: Value = g.overlay_ta.el.get("selectionStart");
                    const b: Value = g.overlay_ta.el.get("selectionEnd");
                    _ = g.overlay_ta.el.call("setRangeText", .{ str("\n"), a, b, str("end") });
                } else {
                    _ = g.overlay_ta.el.call("blur", .{});
                }
            }
        } else if (ovKeyIs(key, "Escape")) {
            _ = e.call("preventDefault", .{});
            if (g.overlay_ta.escape_clears) {
                g.overlay_ta.el.set("value", str(""));
            }
            _ = g.overlay_ta.el.call("blur", .{});
        } else if (g.overlay_ta.allow_tab and ovKeyIs(key, "Tab")) {
            _ = e.call("preventDefault", .{});
            const a: Value = g.overlay_ta.el.get("selectionStart");
            const b: Value = g.overlay_ta.el.get("selectionEnd");
            _ = g.overlay_ta.el.call("setRangeText", .{ str("\t"), a, b, str("end") });
        }
    }
    fn ensureOverlayTextarea() void {
        if (g.overlay_ta.el.h != 0) {
            return;
        }
        const el: Value = document().j.call("createElement", .{str("textarea")});
        el.set("autocomplete", str("off"));
        el.set("autocapitalize", str("off"));
        el.set("spellcheck", false);
        const s: Value = el.get("style");
        s.set("position", str("fixed"));
        s.set("zIndex", str("999"));
        s.set("boxSizing", str("border-box"));
        s.set("margin", str("0"));
        s.set("padding", str("2px 4px"));
        s.set("border", str("none"));
        s.set("outline", str("none"));
        s.set("resize", str("none"));
        s.set("overflow", str("auto"));
        s.set("whiteSpace", str("pre-wrap"));
        s.set("display", str("none"));
        _ = el.call("addEventListener", .{ str("blur"), func(&overlayTaOnBlur) });
        _ = el.call("addEventListener", .{ str("keydown"), func(&overlayTaOnKeydown) });
        _ = document().body().j.call("appendChild", .{el});
        g.overlay_ta.el = el;
    }
    fn domShowOverlayTextarea(
        x: Handle,
        y: Handle,
        w: Handle,
        h: Handle,
        text_ptr: Handle,
        text_len: Handle,
        font_px: Handle,
        fg: Handle,
        bg: Handle,
    ) void {
        ensureOverlayTextarea();
        if (g.overlay_ta.el.h == 0) {
            return;
        }
        const tlen: u32 = @trunc(js_to_num(text_len));
        if (tlen > 0) {
            g.overlay_ta.el.set("value", modStr(text_ptr, text_len));
        } else {
            g.overlay_ta.el.set("value", str(""));
        }
        const s: Value = g.overlay_ta.el.get("style");
        s.set("fontFamily", str("ui-monospace, monospace"));
        ovSetPx(s, "fontSize", js_to_num(font_px));
        // Multiline: line spacing follows the FONT, not the box height. The
        // <input> sets lineHeight == h to center its single line; a textarea
        // wants normal leading so wrapped rows read correctly.
        ovSetPx(s, "lineHeight", @max(1.0, js_to_num(font_px) * 1.3));
        s.set("color", ovRgbCss(fg));
        s.set("backgroundColor", ovRgbCss(bg));
        ovSetPx(s, "left", js_to_num(x));
        ovSetPx(s, "top", js_to_num(y));
        ovSetPx(s, "width", @max(1.0, js_to_num(w)));
        ovSetPx(s, "height", @max(1.0, js_to_num(h)));
        s.set("display", str("block"));
        g.overlay_ta.visible = true;
        // Focus AFTER display:block - focusing a display:none node is a no-op on
        // mobile, and this focus is what raises the soft keyboard.
        _ = g.overlay_ta.el.call("focus", .{});
        const n: u32 = g.overlay_ta.el.get("value").getU32("length");
        _ = g.overlay_ta.el.call("setSelectionRange", .{ n, n });
    }
    fn domHideOverlayTextarea() void {
        if (g.overlay_ta.el.h == 0) {
            return;
        }
        _ = g.overlay_ta.el.call("blur", .{});
        g.overlay_ta.el.get("style").set("display", str("none"));
        g.overlay_ta.visible = false;
    }
    fn domUpdateOverlayTextareaRect(x: Handle, y: Handle, w: Handle, h: Handle) void {
        if (g.overlay_ta.el.h == 0 or !g.overlay_ta.visible) {
            return;
        }
        const s: Value = g.overlay_ta.el.get("style");
        ovSetPx(s, "left", js_to_num(x));
        ovSetPx(s, "top", js_to_num(y));
        ovSetPx(s, "width", @max(1.0, js_to_num(w)));
        ovSetPx(s, "height", @max(1.0, js_to_num(h)));
    }
    fn domOverlayTextareaIsVisible() u32 {
        return if (g.overlay_ta.visible) 1 else 0;
    }
    fn domGetOverlayTextareaText(out_ptr: Handle, max_len: Handle) usize {
        if (g.overlay_ta.el.h == 0) {
            return 0;
        }
        const v: Value = g.overlay_ta.el.get("value");
        if (v.getU32("length") == 0) {
            return 0;
        }
        const enc: Value = global().get("TextEncoder").new(.{});
        const bytes: Value = enc.call("encode", .{v});
        const blen: u32 = bytes.getU32("length");
        const max: u32 = @trunc(js_to_num(max_len));
        const n: u32 = @min(blen, max);
        const p: u32 = @trunc(js_to_num(out_ptr));
        _ = modU8(p, n).call("set", .{bytes.call("subarray", .{ @as(u32, 0), n })});
        return n;
    }
    fn domSetOverlayTextareaReadOnly(on: Handle) void {
        if (g.overlay_ta.el.h == 0) {
            return;
        }
        g.overlay_ta.el.set("readOnly", js_to_num(on) != 0);
    }
    fn domSetOverlayTextareaEscapeClears(on: Handle) void {
        g.overlay_ta.escape_clears = js_to_num(on) != 0;
    }
    fn domSetOverlayTextareaAllowTab(on: Handle) void {
        g.overlay_ta.allow_tab = js_to_num(on) != 0;
    }
    fn domSetOverlayTextareaCharFilters(flags: Handle) void {
        g.overlay_ta.char_filters = @trunc(js_to_num(flags));
    }
    fn domSetOverlayTextareaCtrlEnterForNewline(on: Handle) void {
        g.overlay_ta.ctrl_enter_for_newline = js_to_num(on) != 0;
    }

    // Fill a wasm buffer with cryptographically-strong random bytes from the
    // host's crypto.getRandomValues - the backing for `Config.rng_seed == null`
    // (a fresh per-launch seed for `Frame.random`). Same idiom as the WASI
    // random_get shim; a byte view over [ptr, ptr+len) is filled in place.
    fn domCryptoRandomFill(ptr: Handle, len: Handle) void {
        const p: u32 = @trunc(js_to_num(ptr));
        const n: u32 = @trunc(js_to_num(len));
        _ = global().get("crypto").call("getRandomValues", .{modU8(p, n)});
    }

    // ---- minimal "wgpu" verbs for the Phase-2 slice ----------------------
    fn wgpuCurrentView(h: Handle) u32 {
        const ctx: Value = g.boot.canvas_contexts.call("get", .{Value{ .h = @trunc(js_to_num(h)) }});
        return ctx.call("getCurrentTexture", .{}).call("createView", .{}).h;
    }
    fn wgpuClear(
        view: Handle,
        red: Handle,
        green: Handle,
        blue: Handle,
    ) void {
        const enc: Value = g.boot.gpu_device.call("createCommandEncoder", .{});
        const att: Value = global().get("Object").new(.{});
        att.set("view", Value{ .h = @trunc(js_to_num(view)) });
        const col: Value = global().get("Object").new(.{});
        col.set("r", Value{ .h = red });
        col.set("g", Value{ .h = green });
        col.set("b", Value{ .h = blue });
        col.set("a", Value{ .h = js_num(1.0) });
        att.set("clearValue", col);
        att.set("loadOp", str("clear"));
        att.set("storeOp", str("store"));
        const atts: Value = global().get("Array").new(.{});
        _ = atts.call("push", .{att});
        const desc: Value = global().get("Object").new(.{});
        desc.set("colorAttachments", atts);
        const pass: Value = enc.call("beginRenderPass", .{desc});
        _ = pass.call("end", .{});
        const cmd: Value = enc.call("finish", .{});
        const cmds: Value = global().get("Array").new(.{});
        _ = cmds.call("push", .{cmd});
        _ = g.boot.gpu_queue.call("submit", .{cmds});
    }

    // ---- boot state machine ----------------------------------------------
    // GPU timing: complete the in-flight timestamp readback if the GPU has
    // finished. Runs once per frame (top of stage 4). When the map resolves,
    // sum the per-pass (end-begin) deltas via __zimrGpuMs, stash ms, unmap.
    fn pollGpuTiming() void {
        if (!g.wgpu.ts_pending) {
            return;
        }
        const status: u32 = js_promise_status(g.wgpu.ts_pid);
        if (status == 0) {
            return; // still mapping
        }
        _ = js_promise_take(g.wgpu.ts_pid);
        if (status == 1) {
            const bytes: f64 = @floatFromInt(g.wgpu.ts_pairs_inflight * 2 * 8);
            const zero_v: Value = .{ .h = js_num(0) };
            const bytes_v: Value = .{ .h = js_num(bytes) };
            const ab: Value = g.wgpu.ts_read_buf.call("getMappedRange", .{ zero_v, bytes_v });
            const pairs_f: f64 = @floatFromInt(g.wgpu.ts_pairs_inflight);
            const ms: f64 = js_to_num(global().call("__zimrGpuMs", .{ ab, Value{ .h = js_num(pairs_f) } }).h);
            g.wgpu.gpu_ms_last = ms;
            _ = g.wgpu.ts_read_buf.call("unmap", .{});
        }
        g.wgpu.ts_pending = false;
    }

    /// The one rAF callback that drives everything. While booting (stages 1-3)
    /// it polls the in-flight promise and hands the result to advance(); once
    /// running (stage 4) it ticks one frame of the wasm module. It re-arms itself
    /// every call until stage 0, which means "stopped" (idle or a fatal error).
    fn tick(_: Handle) void {
        switch (g.boot.stage) {
            // Booting: an adapter (1), device (2), or instantiate (3) promise is
            // pending. Poll it; advance on success, report + halt on rejection.
            1, 2, 3 => {
                const promise_resolved: u32 = 1;
                const promise_rejected: u32 = 2;
                const status: u32 = js_promise_status(g.boot.pending_promise);
                if (status == promise_resolved) {
                    const result: Value = .{ .h = js_promise_take(g.boot.pending_promise) };
                    advance(result);
                } else if (status == promise_rejected) {
                    // Surface the ACTUAL rejection reason: the registry stored the
                    // rejected promise's error (a LinkError names the exact missing
                    // host import; a RangeError means OOM). console.error mirrors to
                    // the on-page log overlay, turning "bad bundle" into a diagnosis.
                    const reason: Value = .{ .h = js_promise_take(g.boot.pending_promise) };
                    _ = global().get("console").call("error", .{
                        str("zimr boot: promise rejected -> "),
                        reason.get("message"),
                        reason,
                    });
                    switch (g.boot.stage) {
                        1 => note("zimr boot: stage 1 requestAdapter rejected (no WebGPU adapter available)."),
                        2 => note("zimr boot: stage 2 requestDevice rejected (close other GPU tabs, then reload)."),
                        else => note(
                            "zimr boot: stage 3 WASM instantiate rejected " ++
                                "(see the error above: a missing host import, OOM, or a malformed bundle).",
                        ),
                    }
                    g.boot.stage = 0;
                    return;
                }
            },
            // Running: drive exactly one frame of the instantiated module.
            4 => {
                // Finish any in-flight GPU-timestamp readback before this frame
                // records the next one (it reuses the same read buffer).
                pollGpuTiming();
                const performance: Value = global().get("performance");
                const now_ms: f64 = js_to_num(performance.call("now", .{}).h);
                if (g.boot.classic_contract) {
                    // Classic wasi reactor: the bridge owns timing and passes the
                    // elapsed seconds since the previous frame to update(dt).
                    const dt_seconds: f64 = (now_ms - g.boot.last_frame_ms) / 1000.0;
                    g.boot.last_frame_ms = now_ms;
                    _ = g.boot.module_exports.call("update", .{Value{ .h = js_num(dt_seconds) }});
                } else {
                    // Page contract: zimr_frame(now_ms) owns its own timing.
                    _ = g.boot.module_exports.call("zimr_frame", .{Value{ .h = js_num(now_ms) }});
                }
            },
            else => {},
        }
        // Keep the loop alive unless a fatal error set stage 0 above.
        if (g.boot.stage != 0) {
            requestAnimationFrame(g.boot.tick_callback);
        }
    }
    /// The boot state machine's transition handler: given the value a stage's
    /// promise resolved to (`v`), set up that stage's results and kick off the
    /// next stage's async work. Walks adapter (1) -> device (2) -> instantiate
    /// (3) -> run (4). tick() polls the promise between calls.
    fn advance(v: Value) void {
        switch (g.boot.stage) {
            // Stage 1 -> 2: the WebGPU adapter resolved. Decide whether GPU timing
            // is available, then request the logical device.
            1 => {
                const adapter: Value = v;
                g.boot.gpu_adapter = adapter;
                // No raised limits needed any more: each compute kernel now binds
                // ONLY the storage buffers it uses (per-kernel bind groups, see
                // compute_host.zig), so every kernel stays within WebGPU's
                // guaranteed 8-storage-buffer floor. We used to raise
                // maxStorageBuffersPerShaderStage here because the old shared bind
                // group bound ALL of a module's buffers to every kernel (the
                // counting-sort fluid has 10), which broke on stock devices and
                // forced this adapter-dependent request. A plain requestDevice
                // works everywhere now.
                //
                // GPU timing (profiler): the 'timestamp-query' feature lets us
                // measure GPU-side pass durations. It's optional and absent on
                // many mobile drivers, so we feature-check the adapter and only
                // request it when present - requesting an unsupported feature
                // would REJECT requestDevice and black-screen the boot.
                const adapter_features: Value = adapter.get("features");
                const has_timestamp_query: bool = adapter_features.call("has", .{str("timestamp-query")}).truthy();
                g.boot.timestamp_supported = has_timestamp_query;

                // requestDevice(...) -> a promise of the GPUDevice. Request the
                // timestamp-query feature only when the adapter advertises it.
                var device_promise: Value = undefined;
                if (has_timestamp_query) {
                    const required_features: Value = global().get("Array").new(.{});
                    _ = required_features.call("push", .{str("timestamp-query")});
                    const device_desc: Value = global().get("Object").new(.{});
                    device_desc.set("requiredFeatures", required_features);
                    device_promise = adapter.call("requestDevice", .{device_desc});
                } else {
                    device_promise = adapter.call("requestDevice", .{});
                }
                g.boot.pending_promise = js_promise_register(device_promise.h);
                g.boot.stage = 2;
            },
            // Stage 2 -> 3: the device resolved. Wire error reporting, build the
            // optional GPU-timing infra and the wasm import object, then start
            // instantiation of the module itself.
            2 => {
                const device: Value = v;
                g.boot.gpu_device = device;
                g.boot.gpu_queue = device.get("queue");
                // Surface GPU validation errors instead of silently going black.
                _ = device.call("addEventListener", .{ str("uncapturederror"), func(&onGpuError) });

                // ---- GPU-timing infra (only when 'timestamp-query' was granted) ----
                // Build the timestamp query set + its two staging buffers once,
                // now that the device exists. 64 slots = up to 32 timed passes per
                // frame. Left entirely inert (ts_ready stays false) otherwise.
                if (g.boot.timestamp_supported) {
                    const slot_count: u32 = 64;
                    const buffer_bytes: u32 = slot_count * 8; // one u64 timestamp per slot

                    // The query set the render passes write begin/end stamps into.
                    const query_desc: Value = global().get("Object").new(.{});
                    query_desc.set("type", str("timestamp"));
                    query_desc.set("count", Value{ .h = js_num(@floatFromInt(slot_count)) });
                    g.wgpu.ts_query_set = device.call("createQuerySet", .{query_desc});

                    // GPU-side resolve target: resolveQuerySet writes the raw u64s here.
                    const resolve_usage: u32 = 0x0200 | 0x0004; // QUERY_RESOLVE | COPY_SRC
                    const resolve_desc: Value = global().get("Object").new(.{});
                    resolve_desc.set("size", Value{ .h = js_num(@floatFromInt(buffer_bytes)) });
                    resolve_desc.set("usage", Value{ .h = js_num(@floatFromInt(resolve_usage)) });
                    g.wgpu.ts_resolve_buf = device.call("createBuffer", .{resolve_desc});

                    // CPU-mappable readback: we copy the resolved data here, then mapAsync it.
                    const read_usage: u32 = 0x0008 | 0x0001; // COPY_DST | MAP_READ
                    const read_desc: Value = global().get("Object").new(.{});
                    read_desc.set("size", Value{ .h = js_num(@floatFromInt(buffer_bytes)) });
                    read_desc.set("usage", Value{ .h = js_num(@floatFromInt(read_usage)) });
                    g.wgpu.ts_read_buf = device.call("createBuffer", .{read_desc});

                    g.wgpu.ts_ready = true;

                    // Summing helper: the mapped buffer holds u64 ns timestamps
                    // (begin,end per pass). Reconstruct each as hi*2^32+lo in f64
                    // (ns-since-boot fits < 2^53, so exact) and sum (end-begin) ->
                    // ms. Built via the Function constructor to avoid a separate
                    // page-template script; deltas are small so no BigInt needed.
                    const helper_body: []const u8 =
                        "const a=new Uint32Array(ab);let s=0;for(let i=0;i<pairs;i++){" ++
                        "const b=a[i*4+1]*4294967296+a[i*4];" ++
                        "const e=a[i*4+3]*4294967296+a[i*4+2];s+=e-b;}return s/1e6;";
                    const function_ctor: Value = global().get("Function");
                    const ms_helper: Value = function_ctor.new(.{ str("ab"), str("pairs"), str(helper_body) });
                    global().set("__zimrGpuMs", ms_helper);
                }

                // ---- the wasm import object ----
                // The module links against three namespaces of host functions:
                // `dom`, `wgpu`, and `wasi_snapshot_preview1`. Each is its own
                // self-contained block that ends by attaching itself to `imports`.
                const imports: Value = global().get("Object").new(.{});
                {
                    // dom: element/canvas verbs, input + pointer-lock, persistence,
                    // and the text-overlay (a real <input> for the soft keyboard).
                    const dom: Value = global().get("Object").new(.{});
                    dom.set("create", func(&domCreate));
                    dom.set("attach_body", func(&domAttachBody));
                    dom.set("append", func(&domAppend));
                    dom.set("set_text", func(&domSetText));
                    dom.set("set_attr", func(&domSetAttr));
                    dom.set("set_style", func(&domSetStyle));
                    dom.set("css", func(&domCss));
                    dom.set("remove", func(&domRemove));
                    dom.set("listen", func(&domListen));
                    dom.set("poll_event", func(&domPollEvent));
                    dom.set("canvas_configure", func(&domCanvasConfigure));
                    dom.set("canvas_size", func(&domCanvasSize));
                    dom.set("js_log", funcNum(&ZimrWgpu.jsLog));
                    dom.set("js_epoch_ms", funcNum(&ZimrWgpu.jsEpochMs));
                    dom.set("js_tz_offset_min", funcNum(&ZimrWgpu.jsTzOffsetMin));
                    dom.set("js_set_cursor_style", funcNum(&ZimrWgpu.jsSetCursorStyle));
                    dom.set("js_set_mouse_cursor", funcNum(&ZimrWgpu.jsSetMouseCursor));
                    dom.set("js_open_url", funcNum(&ZimrWgpu.jsOpenUrl));
                    dom.set("js_set_clipboard_text", funcNum(&ZimrWgpu.jsSetClipboardText));
                    dom.set("js_request_pointer_lock", funcNum(&ZimrWgpu.jsRequestPointerLock));
                    dom.set("js_exit_pointer_lock", funcNum(&ZimrWgpu.jsExitPointerLock));
                    dom.set("js_pointer_lock_active", funcNum(&ZimrWgpu.jsPointerLockActive));
                    dom.set("js_persistence_save", funcNum(&ZimrWgpu.jsPersistenceSave));
                    dom.set("js_persistence_size", funcNum(&ZimrWgpu.jsPersistenceSize));
                    dom.set("js_persistence_read", funcNum(&ZimrWgpu.jsPersistenceRead));
                    dom.set("js_persistence_remove", funcNum(&ZimrWgpu.jsPersistenceRemove));
                    // User-supplied files: drag-and-drop plus the mobile file picker.
                    dom.set("js_userfile_pending_count", funcNum(&ZimrBoot.ufPendingCount));
                    dom.set("js_userfile_next_size", funcNum(&ZimrBoot.ufNextSize));
                    dom.set("js_userfile_next_name", funcNum(&ZimrBoot.ufNextName));
                    dom.set("js_userfile_read_next", funcNum(&ZimrBoot.ufReadNext));
                    dom.set("js_userfile_discard_next", funcNum(&ZimrBoot.ufDiscardNext));
                    dom.set("js_userfile_set_picker_rect", funcNum(&ZimrBoot.ufSetPickerRect));
                    dom.set("js_userfile_hide_picker", funcNum(&ZimrBoot.ufHidePicker));
                    dom.set("js_userfile_offer", funcNum(&ZimrBoot.ufOffer));
                    dom.set("js_userfile_set_save_rect", funcNum(&ZimrBoot.ufSetSaveRect));
                    dom.set("js_userfile_hide_save", funcNum(&ZimrBoot.ufHideSave));
                    // WebSocket client (P2P signaling - see src/net.zig).
                    dom.set("js_ws_open", funcNum(&ZimrWgpu.jsWsOpen));
                    dom.set("js_ws_state", funcNum(&ZimrWgpu.jsWsState));
                    dom.set("js_ws_send", funcNum(&ZimrWgpu.jsWsSend));
                    dom.set("js_ws_poll", funcNum(&ZimrWgpu.jsWsPoll));
                    dom.set("js_ws_close", funcNum(&ZimrWgpu.jsWsClose));
                    dom.set("js_ws_origin_url", funcNum(&ZimrWgpu.jsWsOriginUrl));
                    dom.set("js_rtc_create", funcNum(&ZimrWgpu.jsRtcCreate));
                    dom.set("js_rtc_create_offer", funcNum(&ZimrWgpu.jsRtcCreateOffer));
                    dom.set("js_rtc_set_remote", funcNum(&ZimrWgpu.jsRtcSetRemote));
                    dom.set("js_rtc_add_ice", funcNum(&ZimrWgpu.jsRtcAddIce));
                    dom.set("js_rtc_send", funcNum(&ZimrWgpu.jsRtcSend));
                    dom.set("js_rtc_poll", funcNum(&ZimrWgpu.jsRtcPoll));
                    dom.set("js_rtc_close", funcNum(&ZimrWgpu.jsRtcClose));
                    // Text-input overlay host functions: a real <input> positioned
                    // over the wasm-drawn widget (ported from src/web/zimr.ts). These
                    // satisfy the imports editable-widget modules need AND make typing
                    // + the mobile soft keyboard actually work.
                    dom.set("js_show_overlay_input", func(&domShowOverlayInput));
                    dom.set("js_hide_overlay_input", func(&domHideOverlayInput));
                    dom.set("js_get_overlay_input_text", func(&domGetOverlayInputText));
                    dom.set("js_overlay_input_is_visible", func(&domOverlayInputIsVisible));
                    dom.set("js_update_overlay_input_rect", func(&domUpdateOverlayInputRect));
                    dom.set("js_set_input_mode", func(&domSetInputMode));
                    dom.set("js_set_overlay_input_allow_tab", func(&domSetOverlayInputAllowTab));
                    dom.set("js_set_overlay_input_char_filters", func(&domSetOverlayInputCharFilters));
                    dom.set("js_set_overlay_input_escape_clears", func(&domSetOverlayInputEscapeClears));
                    dom.set("js_set_overlay_input_password", func(&domSetOverlayInputPassword));
                    dom.set("js_set_overlay_input_read_only", func(&domSetOverlayInputReadOnly));
                    // Textarea overlay: the multiline sibling of the <input> port,
                    // backed by its own <textarea> singleton (g.overlay_ta).
                    dom.set("js_show_overlay_textarea", func(&domShowOverlayTextarea));
                    dom.set("js_hide_overlay_textarea", func(&domHideOverlayTextarea));
                    dom.set("js_get_overlay_textarea_text", func(&domGetOverlayTextareaText));
                    dom.set("js_overlay_textarea_is_visible", func(&domOverlayTextareaIsVisible));
                    dom.set("js_update_overlay_textarea_rect", func(&domUpdateOverlayTextareaRect));
                    dom.set("js_set_overlay_textarea_allow_tab", func(&domSetOverlayTextareaAllowTab));
                    dom.set("js_set_overlay_textarea_char_filters", func(&domSetOverlayTextareaCharFilters));
                    dom.set("js_set_overlay_textarea_escape_clears", func(&domSetOverlayTextareaEscapeClears));
                    dom.set("js_set_overlay_textarea_read_only", func(&domSetOverlayTextareaReadOnly));
                    dom.set(
                        "js_set_overlay_textarea_ctrl_enter_for_newline",
                        func(&domSetOverlayTextareaCtrlEnterForNewline),
                    );
                    // Crypto entropy for the null-seed RNG path (Frame.random).
                    dom.set("js_crypto_random_fill", func(&domCryptoRandomFill));
                    imports.set("dom", dom);
                }
                {
                    // wgpu: the two clear/view verbs plus the full classic zimr
                    // WebGPU surface installed by ZimrWgpu (Phase 3).
                    const wgpu_ns: Value = global().get("Object").new(.{});
                    wgpu_ns.set("current_view", func(&wgpuCurrentView));
                    wgpu_ns.set("clear", func(&wgpuClear));
                    ZimrWgpu.install(wgpu_ns);
                    imports.set("wgpu", wgpu_ns);
                }
                {
                    // audio: the WebAudio host. Without this the "audio" import is
                    // undefined and EVERY audio example dies at instantiate.
                    const audio_ns: Value = global().get("Object").new(.{});
                    ZimrAudio.install(audio_ns);
                    imports.set("audio", audio_ns);
                }
                {
                    // jobs: the Web Worker pool behind `zimr.jobs`. The workers are NOT
                    // spawned here - `available()` brings them up lazily on first use, so
                    // an app that never submits a job never creates a thread.
                    const jobs_ns: Value = global().get("Object").new(.{});
                    ZimrJobs.install(jobs_ns);
                    imports.set("jobs", jobs_ns);
                }
                {
                    // wasi: the minimal WASI shim the wasm32-wasi target needs.
                    const wasi: Value = global().get("Object").new(.{});
                    ZimrWasi.install(wasi);
                    imports.set("wasi_snapshot_preview1", wasi);
                }

                // ---- instantiate the module ----
                // Two delivery paths, both yielding a promise of {module, instance}
                // that stage 3 unwraps identically:
                //   * standalone build: the page inlines the wasm as WASM_BYTES, so
                //     instantiate directly from the bytes.
                //   * served gallery page: only WASM_URL is set, so stream-compile
                //     the sibling .wasm as it downloads (instantiateStreaming).
                const inline_bytes: Value = global().get("WASM_BYTES");
                const web_assembly: Value = global().get("WebAssembly");
                var instantiate_promise: Value = undefined;
                if (inline_bytes.isNull()) {
                    const wasm_url: Value = global().get("WASM_URL");
                    const fetch_response: Value = global().call("fetch", .{wasm_url});
                    instantiate_promise = web_assembly.call("instantiateStreaming", .{ fetch_response, imports });
                } else {
                    instantiate_promise = web_assembly.call("instantiate", .{ inline_bytes, imports });
                }
                g.boot.pending_promise = js_promise_register(instantiate_promise.h);
                g.boot.stage = 3;
            },
            // Stage 3 -> 4: the module instantiated. Pull its exports, start it
            // under whichever contract it implements, then enter the run loop.
            3 => {
                // `v` is { module, instance }; we only need the instance's exports.
                const instance: Value = v.get("instance");
                g.boot.module_exports = instance.get("exports");

                // Two app contracts, distinguished by which entry point is exported.
                const page_main: Value = g.boot.module_exports.get("zimr_page_main");
                if (page_main.isNull()) {
                    // Classic zimr app (wasm32-wasi reactor): run its initializer
                    // once now; update(dt) then drives from the rAF tick (stage 4).
                    g.boot.classic_contract = true;
                    const initialize: Value = g.boot.module_exports.get("_initialize");
                    if (!initialize.isNull()) {
                        _ = g.boot.module_exports.call("_initialize", .{});
                    }
                    // Wire DOM input only if this app actually owns a canvas.
                    if (g.wgpu.have_canvas) {
                        ZimrInput.install();
                    }
                    // Seed the frame clock so the first update(dt) gets a sane delta.
                    const performance: Value = global().get("performance");
                    g.boot.last_frame_ms = js_to_num(performance.call("now", .{}).h);
                } else {
                    // Page contract: zimr_page_main() sets everything up itself.
                    _ = g.boot.module_exports.call("zimr_page_main", .{});
                }
                g.boot.stage = 4;
            },
            else => {},
        }
    }
};

/// The bridge entry point, called once from the page's inline boot script. It
/// sets up the reused JS singletons, decides whether there's a wasm module to
/// run at all, and - if so - kicks off the adapter->device->instantiate->run
/// pipeline by entering stage 1 and starting the rAF loop.
export fn start() void {
    // One-time JS singletons the bridge reuses on every frame: a UTF-8 decoder
    // for reading wasm strings, the id->object maps backing WebGPU handles and
    // canvas contexts, and the single rAF callback that drives the boot machine.
    g.boot.utf8_decoder = global().get("TextDecoder").new(.{});
    g.wgpu.objects = global().get("Map").new(.{});
    g.audio.objects = global().get("Map").new(.{});
    g.boot.canvas_contexts = global().get("Map").new(.{});

    // The job pool's containers are minted HERE, at boot, and not lazily inside
    // `ZimrJobs.spawn` - because spawn() is first reached from inside a frame, and
    // every handle minted during a frame is reclaimed by that frame's js_reset. A
    // long-lived handle born inside the bracket is a DANGLING handle one frame later.
    // (The workers themselves are still created lazily; they are held by these JS
    // objects, so they need no handle of their own to survive.)
    g.jobs.workers = global().get("Array").new(.{});
    g.jobs.busy_with = global().get("Array").new(.{});
    g.jobs.ready = global().get("Array").new(.{});
    g.jobs.queue = global().get("Array").new(.{});
    g.jobs.results = global().get("Map").new(.{});
    g.jobs.abandoned = global().get("Set").new(.{});
    g.jobs.kernel_errors = global().get("Map").new(.{});
    g.boot.tick_callback = func(&ZimrBoot.tick);

    // "bridge-hello" mode: the page loaded the bridge but ships no module to run
    // (neither inlined WASM_BYTES nor a streamable WASM_URL). Nothing else to do.
    const have_inline_bytes: bool = !global().get("WASM_BYTES").isNull();
    const have_wasm_url: bool = !global().get("WASM_URL").isNull();
    if (!have_inline_bytes and !have_wasm_url) {
        ZimrBoot.note("zimr bridge: mechanism online; no WASM_BYTES/WASM_URL on this page (bridge-hello mode).");
        return;
    }

    // The pipeline needs a WebGPU adapter first. If the browser exposes no
    // WebGPU at all, stop here with a clear message rather than failing deeper.
    const navigator: Value = (Value{ .h = js_global() }).get("navigator");
    const gpu: Value = navigator.get("gpu");
    if (gpu.isNull()) {
        ZimrBoot.note("zimr: WebGPU is not available in this browser.");
        return;
    }

    // Enter stage 1: request the adapter and start the loop. tick() polls this
    // promise and calls advance() once it resolves.
    const adapter_promise: Value = gpu.call("requestAdapter", .{});
    g.boot.pending_promise = js_promise_register(adapter_promise.h);
    g.boot.stage = 1;
    requestAnimationFrame(g.boot.tick_callback);
}

pub const css = struct {
    // css.zig - type-safe, runtime-mutable styling, authored in Zig.
    //
    // The whole model in one sentence: a `Style` is a struct with one field per CSS
    // property - fill in the ones you want, the compiler checks them.
    //
    //   css.rule(".card", .{
    //       .background_color = css.cssVar("panel"),     // a Color
    //       .border_radius    = css.px(8),               // a Length
    //       .display          = .flex,                   // an enum value
    //       .padding          = "14px 16px",             // composite -> a string
    //       .raw              = &.{ .{ "backdrop-filter", "blur(8px)" } }, // escape hatch
    //   });
    //
    // Why this shape:
    //   * Typos are compile errors - `.bordr_radius` is not a field of `Style`.
    //   * Values can't be mixed up - `color` is `?Color`, so `.color = px(8)` won't
    //     compile. `Length`, `Color`, `Number` are distinct types.
    //   * Keyword properties are enums - `.display = .flex` autocompletes and can't
    //     be mistyped; exotic keywords use `.raw`.
    //   * Composite shorthands (padding, border, font, transition...) are plain
    //     strings, because their value genuinely is free-form.
    //   * Anything not modelled goes in `.raw` as name/value pairs. Nothing is
    //     locked out.
    //
    // Comptime does the authoring; the result goes into the LIVE CSSOM, so styling
    // stays mutable at runtime any way you like:
    //   * `theme(.{...})` writes design tokens as CSS custom properties; `setVar`
    //     changes one at runtime and the whole page re-themes.
    //   * `rule(...)` returns a live `Rule` you can `.set(...)`, `.setProp(...)`,
    //     or `.unset(...)` later.
    //   * `styleEl(el, .{...})` sets inline styles; element class helpers swap
    //     whole rule-sets.

    // ===========================================================================
    // comptime string helpers (no std - std.fmt would drag in the Io.Writer vtable,
    // which bloats and breaks the C->JS transpile). Returning `comptime blk: { ...
    // break :blk &final; }` puts the bytes in static memory, usable at runtime.
    // ===========================================================================

    fn dec(comptime n: i64) []const u8 {
        return comptime blk: {
            if (n == 0) {
                break :blk "0";
            }
            const neg: bool = n < 0;
            var x: u64 = if (neg) @intCast(-n) else @intCast(n);
            var tmp: [20]u8 = undefined;
            var k: usize = 0;
            while (x > 0) : (x /= 10) {
                tmp[k] = '0' + @as(u8, @intCast(x % 10));
                k += 1;
            }
            var out: [21]u8 = undefined;
            var m: usize = 0;
            if (neg) {
                out[m] = '-';
                m += 1;
            }
            while (k > 0) {
                k -= 1;
                out[m] = tmp[k];
                m += 1;
            }
            const final: [m]u8 = out[0..m].*;
            break :blk &final;
        };
    }

    fn fmtFloat(comptime v: f64) []const u8 {
        return comptime blk: {
            const neg: bool = v < 0;
            const av: f64 = if (neg) -v else v;
            const scaled: u64 = @round(av * 1_000_000.0);
            const ip: u64 = scaled / 1_000_000;
            var fp: u64 = scaled % 1_000_000;
            var ib: [20]u8 = undefined;
            var ik: usize = 0;
            if (ip == 0) {
                ib[0] = '0';
                ik = 1;
            } else {
                var t: u64 = ip;
                while (t > 0) : (t /= 10) {
                    ib[ik] = '0' + @as(u8, @intCast(t % 10));
                    ik += 1;
                }
            }
            var out: [40]u8 = undefined;
            var n: usize = 0;
            if (neg) {
                out[n] = '-';
                n += 1;
            }
            var r: usize = ik;
            while (r > 0) {
                r -= 1;
                out[n] = ib[r];
                n += 1;
            }
            if (fp > 0) {
                var fd: [6]u8 = undefined;
                var j: usize = 6;
                while (j > 0) : (j -= 1) {
                    fd[j - 1] = '0' + @as(u8, @intCast(fp % 10));
                    fp /= 10;
                }
                var last: usize = 6;
                while (last > 0 and fd[last - 1] == '0') {
                    last -= 1;
                }
                out[n] = '.';
                n += 1;
                var c: usize = 0;
                while (c < last) : (c += 1) {
                    out[n] = fd[c];
                    n += 1;
                }
            }
            const final: [n]u8 = out[0..n].*;
            break :blk &final;
        };
    }

    // snake_case AND camelCase -> kebab-case
    fn kebab(comptime s: []const u8) []const u8 {
        return comptime blk: {
            var buf: [s.len * 2]u8 = undefined;
            var n: usize = 0;
            for (s) |c| {
                if (c == '_') {
                    buf[n] = '-';
                    n += 1;
                } else if (c >= 'A' and c <= 'Z') {
                    buf[n] = '-';
                    n += 1;
                    buf[n] = c + 32;
                    n += 1;
                } else {
                    buf[n] = c;
                    n += 1;
                }
            }
            const final: [n]u8 = buf[0..n].*;
            break :blk &final;
        };
    }

    // ===========================================================================
    // typed values - distinct types so a Color can't be used where a Length is
    // expected, and vice-versa. Build them with the helpers below, never by hand.
    // ===========================================================================
    pub const Length = struct { repr: []const u8 };
    pub const Color = struct { repr: []const u8 };
    pub const Number = struct { repr: []const u8 };

    pub fn px(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "px" };
    }
    pub fn pct(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "%" };
    }
    pub fn em(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "em" };
    }
    pub fn rem(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "rem" };
    }
    pub fn vh(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "vh" };
    }
    pub fn vw(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "vw" };
    }
    pub fn fr(comptime n: f64) Length {
        return .{ .repr = comptime fmtFloat(n) ++ "fr" };
    }
    pub const auto = Length{ .repr = "auto" };
    pub const zero = Length{ .repr = "0" };

    pub fn num(comptime n: f64) Number {
        return .{ .repr = comptime fmtFloat(n) };
    }

    pub fn hex(comptime val: u24) Color {
        return .{ .repr = comptime blk: {
            const digits: []const u8 = "0123456789abcdef";
            var buf: [7]u8 = undefined;
            buf[0] = '#';
            var i: usize = 6;
            var x: u24 = val;
            while (i >= 1) : (i -= 1) {
                buf[i] = digits[@as(usize, @intCast(x & 0xf))];
                x >>= 4;
            }
            const final: [7]u8 = buf;
            break :blk &final;
        } };
    }
    pub fn rgb(
        comptime red: u8,
        comptime green: u8,
        comptime blue: u8,
    ) Color {
        return .{ .repr = comptime "rgb(" ++ dec(red) ++ "," ++ dec(green) ++ "," ++ dec(blue) ++ ")" };
    }
    pub fn rgba(
        comptime red: u8,
        comptime green: u8,
        comptime blue: u8,
        comptime alpha: f64,
    ) Color {
        return .{ .repr = comptime "rgba(" ++ dec(red) ++ "," ++ dec(green) ++
            "," ++ dec(blue) ++ "," ++ fmtFloat(alpha) ++ ")" };
    }
    pub fn named(comptime name: []const u8) Color {
        return .{ .repr = name };
    }
    pub const transparent = Color{ .repr = "transparent" };
    pub const currentColor = Color{ .repr = "currentColor" };

    // Typed references to theme tokens. A bare var(--x) is type-erased, so say which
    // kind it holds: cssVar -> Color, lenVar -> Length, numVar -> Number. rawVar
    // gives the plain "var(--x)" string for embedding inside a shorthand.
    pub fn cssVar(comptime name: []const u8) Color {
        return .{ .repr = comptime "var(--" ++ name ++ ")" };
    }
    pub fn lenVar(comptime name: []const u8) Length {
        return .{ .repr = comptime "var(--" ++ name ++ ")" };
    }
    pub fn numVar(comptime name: []const u8) Number {
        return .{ .repr = comptime "var(--" ++ name ++ ")" };
    }
    pub fn rawVar(comptime name: []const u8) []const u8 {
        return comptime "var(--" ++ name ++ ")";
    }

    // ===========================================================================
    // keyword enums - closed value sets, so they autocomplete and can't be mistyped.
    // ===========================================================================
    pub const Display = enum {
        flex,
        grid,
        block,
        none,
        @"inline",
        inline_block,
        inline_flex,
        inline_grid,
        contents,
        table,
        flow_root,
    };
    pub const Position = enum { static, relative, absolute, fixed, sticky };
    pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
    pub const BoxSizing = enum { border_box, content_box };
    pub const TextAlign = enum { left, right, center, justify, start, end };
    pub const Align = enum {
        start,
        end,
        center,
        stretch,
        baseline,
        flex_start,
        flex_end,
        space_between,
        space_around,
        space_evenly,
        normal,
    };
    pub const Overflow = enum { visible, hidden, scroll, auto, clip };
    pub const WhiteSpace = enum { normal, nowrap, pre, pre_wrap, pre_line, break_spaces };
    pub const BorderStyle = enum {
        none,
        solid,
        dashed,
        dotted,
        double,
        groove,
        ridge,
        inset,
        outset,
        hidden,
    };

    /// Typed builder for the `border` shorthand: `.border = border(px(1), .solid, cssVar("line"))`.
    pub fn border(
        comptime w: Length,
        comptime style: BorderStyle,
        comptime c: Color,
    ) []const u8 {
        return comptime w.repr ++ " " ++ @tagName(style) ++ " " ++ c.repr;
    }

    // ===========================================================================
    // the Style struct - one field per CSS property. Unset fields (null) are
    // omitted. `raw` is the escape hatch for anything not modelled here.
    // ===========================================================================
    pub const Decl = struct { []const u8, []const u8 };

    pub const Style = struct {
        // layout / flexbox
        display: ?Display = null,
        position: ?Position = null,
        top: ?Length = null,
        right: ?Length = null,
        bottom: ?Length = null,
        left: ?Length = null,
        z_index: ?Number = null,
        box_sizing: ?BoxSizing = null,
        overflow: ?Overflow = null,
        overflow_x: ?Overflow = null,
        overflow_y: ?Overflow = null,
        flex_direction: ?FlexDirection = null,
        flex_wrap: ?[]const u8 = null,
        align_items: ?Align = null,
        align_self: ?Align = null,
        align_content: ?Align = null,
        justify_content: ?Align = null,
        justify_items: ?Align = null,
        flex: ?[]const u8 = null,
        flex_grow: ?Number = null,
        flex_shrink: ?Number = null,
        flex_basis: ?Length = null,
        order: ?Number = null,
        gap: ?Length = null,
        row_gap: ?Length = null,
        column_gap: ?Length = null,
        // box model
        width: ?Length = null,
        height: ?Length = null,
        min_width: ?Length = null,
        min_height: ?Length = null,
        max_width: ?Length = null,
        max_height: ?Length = null,
        margin: ?[]const u8 = null,
        margin_top: ?Length = null,
        margin_right: ?Length = null,
        margin_bottom: ?Length = null,
        margin_left: ?Length = null,
        padding: ?[]const u8 = null,
        padding_top: ?Length = null,
        padding_right: ?Length = null,
        padding_bottom: ?Length = null,
        padding_left: ?Length = null,
        // border / outline
        border: ?[]const u8 = null,
        border_width: ?Length = null,
        border_style: ?BorderStyle = null,
        border_color: ?Color = null,
        border_radius: ?Length = null,
        outline: ?[]const u8 = null,
        // color / background
        color: ?Color = null,
        background: ?[]const u8 = null,
        background_color: ?Color = null,
        background_image: ?[]const u8 = null,
        opacity: ?Number = null,
        // typography
        font: ?[]const u8 = null,
        font_family: ?[]const u8 = null,
        font_size: ?Length = null,
        font_weight: ?[]const u8 = null,
        font_style: ?[]const u8 = null,
        line_height: ?[]const u8 = null,
        letter_spacing: ?Length = null,
        text_align: ?TextAlign = null,
        text_decoration: ?[]const u8 = null,
        text_transform: ?[]const u8 = null,
        white_space: ?WhiteSpace = null,
        word_break: ?[]const u8 = null,
        color_scheme: ?[]const u8 = null,
        // misc
        cursor: ?[]const u8 = null,
        transition: ?[]const u8 = null,
        transform: ?[]const u8 = null,
        box_shadow: ?[]const u8 = null,
        content: ?[]const u8 = null,
        visibility: ?[]const u8 = null,
        pointer_events: ?[]const u8 = null,
        user_select: ?[]const u8 = null,
        // escape hatch: arbitrary name/value pairs
        raw: ?[]const Decl = null,
    };

    // render any field value to its CSS string
    fn render(comptime val: anytype) []const u8 {
        const T = @TypeOf(val);
        return switch (@typeInfo(T)) {
            .@"enum" => kebab(@tagName(val)),
            .@"struct" => val.repr, // Length / Color / Number
            .pointer => |p| if (p.child == u8 or
                (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8))
                val
            else
                @compileError("css: value must be a string, not " ++ @typeName(T)),
            else => @compileError("css: cannot render value of type " ++ @typeName(T)),
        };
    }

    fn eqlStr(comptime a: []const u8, comptime b: []const u8) bool {
        if (a.len != b.len) {
            return false;
        }
        for (a, b) |x, y| {
            if (x != y) {
                return false;
            }
        }
        return true;
    }

    // Style -> "prop:val;prop:val;" (comptime)
    fn declBody(comptime style: Style) []const u8 {
        return comptime blk: {
            @setEvalBranchQuota(200000);
            var out: []const u8 = "";
            for (structFields(Style)) |f| {
                if (eqlStr(f.name, "raw")) {
                    continue;
                }
                if (@field(style, f.name)) |val| {
                    out = out ++ kebab(f.name) ++ ":" ++ render(val) ++ ";";
                }
            }
            if (style.raw) |pairs| {
                for (pairs) |d| {
                    out = out ++ d[0] ++ ":" ++ d[1] ++ ";";
                }
            }
            break :blk out;
        };
    }

    /// Render a Style to a `prop:val;...` string (e.g. for an inline `style="..."`).
    pub fn styleString(comptime style: Style) []const u8 {
        return comptime declBody(style);
    }

    // ===========================================================================
    // runtime - the live CSSOM. Authoring is comptime; everything below is mutable.
    // ===========================================================================
    fn applyStyle(decl_style: Value, comptime style: Style) void {
        inline for (comptime structFields(Style)) |f| {
            if (comptime eqlStr(f.name, "raw")) {
                if (style.raw) |pairs| {
                    inline for (pairs) |d| {
                        _ = decl_style.call("setProperty", .{ d[0], d[1] });
                    }
                }
            } else if (@field(style, f.name)) |val| {
                _ = decl_style.call("setProperty", .{ comptime kebab(f.name), render(val) });
            }
        }
    }

    /// A stylesheet you can insert rules into. Use `Sheet.create()` for an isolated
    /// one, or the module-level `rule`/`ruleRaw` which share a default sheet.
    pub const Sheet = struct {
        j: Value,
        pub fn create() Sheet {
            const st: Element = document().create("style");
            document().head().append(st);
            return .{ .j = st.j.get("sheet") };
        }
        pub fn rule(
            self: Sheet,
            comptime selector: []const u8,
            comptime style: Style,
        ) Rule {
            const rule_text: []const u8 = comptime selector ++ "{" ++ declBody(style) ++ "}";
            const idx = self.j.get("cssRules").get("length").to(u32);
            _ = self.j.call("insertRule", .{ rule_text, idx });
            return .{ .j = self.j.get("cssRules").at(idx) };
        }
        pub fn ruleRaw(self: Sheet, comptime css_text: []const u8) void {
            _ = self.j.call("insertRule", .{ css_text, self.j.get("cssRules").get("length").to(u32) });
        }
    };

    // Lazily-created default sheet. A `?Sheet` global initializes to null and is
    // created on first use - the transpiler honours optional/bool static init.
    fn defaultSheet() Sheet {
        if (g.default_sheet == null) {
            g.default_sheet = Sheet.create();
        }
        return g.default_sheet.?;
    }

    /// Add a static rule to the default sheet - the common case (define and forget,
    /// no `_ =` needed). `:hover`, descendant selectors and `@media` all work - the
    /// selector is a real selector. To mutate a rule at runtime, use `ruleLive`.
    pub fn rule(comptime selector: []const u8, comptime style: Style) void {
        _ = defaultSheet().rule(selector, style);
    }
    /// Like `rule`, but returns a live handle whose `.set`/`.unset`/`.setProp` change
    /// the rule at runtime.
    pub fn ruleLive(comptime selector: []const u8, comptime style: Style) Rule {
        return defaultSheet().rule(selector, style);
    }
    /// Raw rule text on the default sheet - for `@keyframes` and other at-rules.
    pub fn ruleRaw(comptime css_text: []const u8) void {
        defaultSheet().ruleRaw(css_text);
    }

    /// A live CSS rule. `set` merges declarations, `unset` removes one - both at runtime.
    pub const Rule = struct {
        j: Value,
        pub fn set(self: Rule, comptime style: Style) void {
            applyStyle(self.j.get("style"), style);
        }
        pub fn setProp(
            self: Rule,
            comptime name: []const u8,
            value: []const u8,
        ) void {
            _ = self.j.get("style").call("setProperty", .{ comptime kebab(name), value });
        }
        pub fn unset(self: Rule, comptime name: []const u8) void {
            _ = self.j.get("style").call("removeProperty", .{comptime kebab(name)});
        }
    };

    /// Design tokens -> CSS custom properties on :root. `theme(.{ .bg = hex(0x101010) })`
    /// defines `--bg`; reference it with `cssVar("bg")`/`lenVar`/`numVar`; change it
    /// live with `setVar`.
    pub fn theme(comptime tokens: anytype) void {
        const st: Value = document().j.get("documentElement").get("style");
        inline for (comptime structFields(@TypeOf(tokens))) |f| {
            _ = st.call(
                "setProperty",
                .{ comptime "--" ++ kebab(f.name), render(@field(tokens, f.name)) },
            );
        }
    }

    /// Change a token at runtime. The value may be a typed value (Color/Length/...)
    /// built however you like - including from runtime data - or a plain string.
    pub fn setVar(comptime name: []const u8, value: anytype) void {
        const st: Value = document().j.get("documentElement").get("style");
        const prop: []const u8 = comptime "--" ++ kebab(name);
        if (comptime @typeInfo(@TypeOf(value)) == .pointer) {
            _ = st.call("setProperty", .{ prop, value });
        } else {
            _ = st.call("setProperty", .{ prop, value.repr });
        }
    }

    /// Inline styles on a single element, at runtime.
    pub fn styleEl(el: Element, comptime style: Style) void {
        applyStyle(el.j.get("style"), style);
    }
};

// ===========================================================================
// ZimrAudio - the "audio" wasm import namespace (WebAudio).
//
// The Zig engine has declared `extern "audio" fn js_audio_*` (src/web.zig) since
// the SFX subsystem landed, and the smoke harness stubs them - but NOTHING ever
// provided them to a browser. `imports` carried only dom / wgpu / wasi / env, so
// every audio example died at `WebAssembly.instantiate` with
// "Import 'audio': module is not an object or function". It was invisible
// in-sandbox precisely because smoke supplies the import that the browser lacks.
//
// This is that host, ported from the pre-wgpu TypeScript bridge (`src/web/zimr.ts`
// in the old tree) - same object graph, same id discipline, same semantics - but
// written in Zig and transpiled to JS by c2js, so the page has ONE host language.
//
// The object graph per voice mirrors the TS exactly:
//     BufferSource -> Gain (volume) -> StereoPanner (pan) -> masterGain -> destination
//
// Records (context / source / decode) are plain JS objects kept in one Map, so
// `pause` can rebuild a source later: a stopped AudioBufferSourceNode is NOT
// restartable - Web Audio makes them one-shot - so `resume` constructs a fresh
// node and starts it at the saved offset. That single fact is why a source record
// exists at all.
// ===========================================================================
const ZimrAudio = struct {
    /// Local clamp - bridge.zig deliberately has no zimrmath dependency (it is the
    /// HOST, compiled to JS, not engine code).
    fn clampF(v: f64, lo: f64, hi: f64) f64 {
        if (v < lo) {
            return lo;
        }
        if (v > hi) {
            return hi;
        }
        return v;
    }

    fn insert(v: Value) f64 {
        const id: u32 = g.audio.next_id;
        g.audio.next_id += 1;
        const idf: f64 = @floatFromInt(id);
        _ = g.audio.objects.call("set", .{ num(idf), v });
        return idf;
    }
    fn lookup(id: f64) Value {
        if (id <= 0) {
            return .{ .h = 0 };
        }
        return g.audio.objects.call("get", .{num(id)});
    }
    fn drop(id: f64) void {
        _ = g.audio.objects.call("delete", .{num(id)});
    }

    // ---- context ----------------------------------------------------------

    fn createContext() f64 {
        // Safari still only ships the prefixed constructor.
        var ctor: Value = global().get("AudioContext");
        if (ctor.isNull()) {
            ctor = global().get("webkitAudioContext");
        }
        if (ctor.isNull()) {
            return 0;
        }
        const ctx: Value = ctor.new(.{});
        if (ctx.isNull()) {
            return 0;
        }
        const master: Value = ctx.call("createGain", .{});
        master.get("gain").set("value", 1.0);
        _ = master.call("connect", .{ctx.get("destination")});

        const rec: Value = global().get("Object").new(.{});
        rec.set("ctx", ctx);
        rec.set("master", master);
        return insert(rec);
    }

    fn closeContext(ctx_id: f64) void {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return;
        }
        _ = rec.get("ctx").call("close", .{});
        drop(ctx_id);
    }

    /// Browsers start an AudioContext SUSPENDED until a user gesture; the engine
    /// calls this from its input handler, so the first tap unlocks sound.
    fn resumeContext(ctx_id: f64) void {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return;
        }
        _ = rec.get("ctx").call("resume", .{});
    }

    fn getSampleRate(ctx_id: f64) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        return rec.get("ctx").getNum("sampleRate");
    }

    fn getCurrentTime(ctx_id: f64) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        return rec.get("ctx").getNum("currentTime");
    }

    fn getMasterVolume(ctx_id: f64) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        return rec.get("master").get("gain").getNum("value");
    }

    fn setMasterVolume(ctx_id: f64, v: f64) void {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return;
        }
        rec.get("master").get("gain").set("value", v);
    }

    // ---- buffers ----------------------------------------------------------

    /// Upload INTERLEAVED f32 PCM from wasm memory as an AudioBuffer.
    ///
    /// The Float32Array is a VIEW over the wasm heap, so it must be copied before
    /// it reaches Web Audio: the heap can move when it grows, and `copyToChannel`
    /// must not alias it. Mono takes a one-call fast path; multi-channel has to be
    /// de-interleaved, since Web Audio stores planar channels and JS has no
    /// strided typed-array view.
    fn loadBuffer(
        ctx_id: f64,
        sample_rate: f64,
        channels: f64,
        frame_count: f64,
        data_ptr: f64,
        data_len: f64,
    ) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        if (frame_count <= 0 or channels < 1 or channels > 32) {
            return 0;
        }
        if (data_len != frame_count * channels) {
            return 0; // the caller's own arithmetic disagrees - refuse rather than read garbage
        }
        const ctx: Value = rec.get("ctx");

        const mem: Value = g.boot.module_exports.get("memory").get("buffer");
        const view: Value = global().get("Float32Array").new(.{ mem, num(data_ptr), num(data_len) });
        const src: Value = view.call("slice", .{}); // detach from the wasm heap

        const buf: Value = ctx.call("createBuffer", .{ num(channels), num(frame_count), num(sample_rate) });
        if (buf.isNull()) {
            return 0;
        }

        const chans: u32 = @trunc(channels);
        const frames: u32 = @trunc(frame_count);
        if (chans == 1) {
            _ = buf.call("copyToChannel", .{ src, num(0), num(0) });
            return insert(buf);
        }
        var c: u32 = 0;
        while (c < chans) : (c += 1) {
            const plane: Value = global().get("Float32Array").new(.{num(frame_count)});
            var f: u32 = 0;
            while (f < frames) : (f += 1) {
                plane.setAt(f, src.at(f * chans + c));
            }
            _ = buf.call("copyToChannel", .{ plane, num(@floatFromInt(c)), num(0) });
        }
        return insert(buf);
    }

    fn unloadBuffer(_: f64, buffer_id: f64) void {
        drop(buffer_id);
    }

    // ---- sources ----------------------------------------------------------

    /// Build and start one voice. `when == 0` means "now"; `offset` seeks into the
    /// buffer (that's what makes `resume` work).
    fn startSource(
        ctx_id: f64,
        buffer_id: f64,
        volume: f64,
        pitch: f64,
        pan: f64,
        looping: bool,
        when: f64,
        offset: f64,
    ) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        const buf: Value = lookup(buffer_id);
        if (buf.isNull()) {
            return 0;
        }
        const ctx: Value = rec.get("ctx");

        const node: Value = ctx.call("createBufferSource", .{});
        node.set("buffer", buf);
        node.get("playbackRate").set("value", pitch);
        node.set("loop", looping);

        const gain: Value = ctx.call("createGain", .{});
        gain.get("gain").set("value", volume);
        const panner: Value = ctx.call("createStereoPanner", .{});
        panner.get("pan").set("value", pan);

        _ = node.call("connect", .{gain});
        _ = gain.call("connect", .{panner});
        _ = panner.call("connect", .{rec.get("master")});

        const dur: f64 = buf.getNum("duration");
        const off: f64 = clampF(offset, 0.0, dur);

        const src_rec: Value = global().get("Object").new(.{});
        src_rec.set("ctxId", ctx_id);
        src_rec.set("node", node);
        src_rec.set("gain", gain);
        src_rec.set("buffer", buf);
        src_rec.set("pitch", pitch);
        src_rec.set("looping", looping);
        src_rec.set("startedAt", if (when > 0) when else ctx.getNum("currentTime"));
        src_rec.set("pausedOffset", off);
        src_rec.set("playing", 1);

        const id: f64 = insert(src_rec);

        // No closures in Zig->JS: bind the source id into the handler instead.
        // `onended` also fires on an explicit stop(), so the handler re-checks the
        // record - a paused voice already cleared `playing` and must SURVIVE, or
        // resume would have nothing to rebuild from.
        node.set("onended", func(&onSourceEnded).call("bind", .{ num(0), num(id) }));
        _ = node.call("start", .{ num(when), num(off) });
        return id;
    }

    fn onSourceEnded(id_h: Handle) void {
        const id: f64 = js_to_num(id_h);
        const rec: Value = lookup(id);
        if (rec.isNull()) {
            return;
        }
        if (rec.getNum("playing") == 0) {
            return; // paused deliberately - keep the record for resume
        }
        rec.set("playing", 0);
        drop(id); // played to its end: the voice is spent
    }

    fn playBuffer(
        ctx_id: f64,
        buffer_id: f64,
        volume: f64,
        pitch: f64,
        pan: f64,
        looping: f64,
    ) f64 {
        return startSource(ctx_id, buffer_id, volume, pitch, pan, looping != 0, 0, 0);
    }

    fn playBufferAt(
        ctx_id: f64,
        buffer_id: f64,
        volume: f64,
        pitch: f64,
        pan: f64,
        when: f64,
    ) f64 {
        return startSource(ctx_id, buffer_id, volume, pitch, pan, false, when, 0);
    }

    fn playBufferWithOffset(
        ctx_id: f64,
        buffer_id: f64,
        volume: f64,
        pitch: f64,
        pan: f64,
        looping: f64,
        offset: f64,
    ) f64 {
        return startSource(ctx_id, buffer_id, volume, pitch, pan, looping != 0, 0, offset);
    }

    fn stopBuffer(_: f64, source_id: f64) void {
        const rec: Value = lookup(source_id);
        if (rec.isNull()) {
            return;
        }
        const node: Value = rec.get("node");
        if (!node.isNull()) {
            _ = node.call("stop", .{});
            _ = node.call("disconnect", .{});
        }
        drop(source_id);
    }

    /// Web Audio source nodes are ONE-SHOT - a stopped node can never restart. So
    /// pause banks the play position and throws the node away; `resume` builds a
    /// new one at that offset. Elapsed time is scaled by pitch, because
    /// playbackRate stretches wall-clock against buffer-time.
    fn pauseBuffer(_: f64, source_id: f64) void {
        const rec: Value = lookup(source_id);
        if (rec.isNull() or rec.getNum("playing") == 0) {
            return;
        }
        const ctx_rec: Value = lookup(rec.getNum("ctxId"));
        if (ctx_rec.isNull()) {
            return;
        }
        const t_now: f64 = ctx_rec.get("ctx").getNum("currentTime");
        const elapsed: f64 = (t_now - rec.getNum("startedAt")) * rec.getNum("pitch");
        const dur: f64 = rec.get("buffer").getNum("duration");
        const off: f64 = clampF(rec.getNum("pausedOffset") + elapsed, 0.0, dur);
        rec.set("pausedOffset", off);
        rec.set("playing", 0); // set BEFORE stop(), so onended sees a deliberate pause

        const node: Value = rec.get("node");
        if (!node.isNull()) {
            _ = node.call("stop", .{});
            _ = node.call("disconnect", .{});
        }
        rec.set("node", 0);
    }

    fn resumeBuffer(_: f64, source_id: f64) void {
        const rec: Value = lookup(source_id);
        if (rec.isNull() or rec.getNum("playing") != 0) {
            return;
        }
        const ctx_rec: Value = lookup(rec.getNum("ctxId"));
        if (ctx_rec.isNull()) {
            return;
        }
        const ctx: Value = ctx_rec.get("ctx");
        const node: Value = ctx.call("createBufferSource", .{});
        node.set("buffer", rec.get("buffer"));
        node.get("playbackRate").set("value", rec.getNum("pitch"));
        node.set("loop", rec.getNum("looping") != 0);
        _ = node.call("connect", .{rec.get("gain")}); // reuse the existing gain->panner->master chain
        node.set("onended", func(&onSourceEnded).call("bind", .{ num(0), num(source_id) }));
        _ = node.call("start", .{ num(0), num(rec.getNum("pausedOffset")) });

        rec.set("node", node);
        rec.set("startedAt", ctx.getNum("currentTime"));
        rec.set("playing", 1);
    }

    fn isBufferPlaying(_: f64, source_id: f64) f64 {
        const rec: Value = lookup(source_id);
        if (rec.isNull()) {
            return 0;
        }
        return rec.getNum("playing");
    }

    // ---- async decode -----------------------------------------------------

    /// `decodeAudioData` is asynchronous and the wasm cannot block, hence the
    /// poll triad: kick off a decode, ask `is_decode_ready`, then `take` the
    /// buffer. The decode record is a JS object BOUND into the callbacks - that's
    /// how a closure-free Zig->JS host remembers which decode finished.
    fn decodeOggBytes(ctx_id: f64, data_ptr: f64, data_len: f64) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        // decodeAudioData DETACHES the ArrayBuffer it is given - hand it a private
        // copy, never a view onto the wasm heap.
        const src: Value = ZimrWgpu.modBytes(data_ptr, data_len);
        const copy: Value = global().get("Uint8Array").new(.{num(data_len)});
        _ = copy.call("set", .{src});

        const pending: Value = global().get("Object").new(.{});
        pending.set("ready", 0);
        const id: f64 = insert(pending);

        _ = rec.get("ctx").call("decodeAudioData", .{
            copy.get("buffer"),
            func(&onDecodeOk).call("bind", .{ num(0), pending }),
            func(&onDecodeFail).call("bind", .{ num(0), pending }),
        });
        return id;
    }

    fn onDecodeOk(pending_h: Handle, buf_h: Handle) void {
        const pending: Value = .{ .h = pending_h };
        pending.set("result", Value{ .h = buf_h });
        pending.set("ready", 1);
    }

    /// A FAILED decode still reports "ready" - otherwise the engine would poll
    /// forever. `take` then finds no result and returns 0, which is exactly the
    /// invalid-buffer answer the Zig side already handles.
    fn onDecodeFail(pending_h: Handle) void {
        const pending: Value = .{ .h = pending_h };
        pending.set("ready", 1);
    }

    fn isDecodeReady(_: f64, decode_id: f64) f64 {
        const rec: Value = lookup(decode_id);
        if (rec.isNull()) {
            return 0;
        }
        return rec.getNum("ready");
    }

    fn takeDecodedBuffer(_: f64, decode_id: f64) f64 {
        const rec: Value = lookup(decode_id);
        if (rec.isNull()) {
            return 0;
        }
        if (rec.getNum("ready") == 0) {
            return 0; // still decoding - keep the record and let the caller poll again
        }
        const result: Value = rec.get("result");
        drop(decode_id);
        if (result.isNull()) {
            return 0; // decode failed
        }
        return insert(result); // promote the AudioBuffer to a buffer id
    }

    fn cancelDecode(_: f64, decode_id: f64) void {
        // The in-flight decodeAudioData callback still fires; it just writes into a
        // record nobody will read. Dropping the id is the cancel.
        drop(decode_id);
    }

    // ---- analyser (FFT tap) -----------------------------------------------

    /// Attach an AnalyserNode to the master bus. It is a TAP, not a filter: master
    /// already feeds `destination`, so connecting it additionally to the analyser
    /// hands the FFT the same signal without changing what you hear. The analyser
    /// deliberately connects onward to NOTHING.
    fn createAnalyser(ctx_id: f64, fft_size: f64) f64 {
        const rec: Value = lookup(ctx_id);
        if (rec.isNull()) {
            return 0;
        }
        const an: Value = rec.get("ctx").call("createAnalyser", .{});
        if (an.isNull()) {
            return 0;
        }
        an.set("fftSize", fft_size);
        _ = rec.get("master").call("connect", .{an});
        return insert(an);
    }

    /// Write the current magnitude spectrum into wasm memory, one byte per bin.
    /// `getByteFrequencyData` fills the typed array IN PLACE - and the array we
    /// hand it is a view straight onto the wasm heap, so the samples land in the
    /// caller's slice with no intermediate copy.
    fn getFrequencyData(_: f64, analyser_id: f64, out_ptr: f64, out_len: f64) f64 {
        const an: Value = lookup(analyser_id);
        if (an.isNull()) {
            return 0;
        }
        const bins: f64 = an.getNum("frequencyBinCount");
        const n: f64 = @min(bins, out_len);
        if (n <= 0) {
            return 0;
        }
        _ = an.call("getByteFrequencyData", .{ZimrWgpu.modBytes(out_ptr, n)});
        return n;
    }

    fn destroyAnalyser(_: f64, analyser_id: f64) void {
        const an: Value = lookup(analyser_id);
        if (an.isNull()) {
            return;
        }
        _ = an.call("disconnect", .{});
        drop(analyser_id);
    }

    fn install(ns: Value) void {
        ns.set("js_audio_create_context", funcNum(&createContext));
        ns.set("js_audio_close_context", funcNum(&closeContext));
        ns.set("js_audio_resume_context", funcNum(&resumeContext));
        ns.set("js_audio_get_sample_rate", funcNum(&getSampleRate));
        ns.set("js_audio_get_current_time", funcNum(&getCurrentTime));
        ns.set("js_audio_get_master_volume", funcNum(&getMasterVolume));
        ns.set("js_audio_set_master_volume", funcNum(&setMasterVolume));
        ns.set("js_audio_load_buffer", funcNum(&loadBuffer));
        ns.set("js_audio_unload_buffer", funcNum(&unloadBuffer));
        ns.set("js_audio_play_buffer", funcNum(&playBuffer));
        ns.set("js_audio_play_buffer_at", funcNum(&playBufferAt));
        ns.set("js_audio_play_buffer_with_offset", funcNum(&playBufferWithOffset));
        ns.set("js_audio_stop_buffer", funcNum(&stopBuffer));
        ns.set("js_audio_pause_buffer", funcNum(&pauseBuffer));
        ns.set("js_audio_resume_buffer", funcNum(&resumeBuffer));
        ns.set("js_audio_is_buffer_playing", funcNum(&isBufferPlaying));
        ns.set("js_audio_decode_ogg_bytes", funcNum(&decodeOggBytes));
        ns.set("js_audio_is_decode_ready", funcNum(&isDecodeReady));
        ns.set("js_audio_take_decoded_buffer", funcNum(&takeDecodedBuffer));
        ns.set("js_audio_cancel_decode", funcNum(&cancelDecode));
        ns.set("js_audio_create_analyser", funcNum(&createAnalyser));
        ns.set("js_audio_get_frequency_data", funcNum(&getFrequencyData));
        ns.set("js_audio_destroy_analyser", funcNum(&destroyAnalyser));
    }
};

// ===========================================================================
// ZimrJobs - the Web Worker pool behind `zimr.jobs`.
// ===========================================================================
//
// WHAT A WEB WORKER IS, for anyone who has not met one.
//
// A Web Worker is a second JavaScript thread. It shares NOTHING with the page: not a
// variable, not the DOM, not the canvas, not WebGPU. The only way to speak to it is
// `postMessage(value)`, and the value is COPIED across the boundary - except for an
// ArrayBuffer listed as "transferable", which is handed over wholesale and DETACHED
// from the sender. A transfer is O(1) no matter how big the buffer is.
//
// Two consequences shape everything below:
//
//   1. A worker cannot run the app's wasm. It has no WebGPU and no DOM, so 96 of the
//      app's imports would be missing. Instead each worker instantiates its own copy
//      of a SEPARATE, freestanding kernel wasm (~19 KB) with ZERO imports - nothing to
//      stub, and only ~1 MB of linear memory per worker.
//   2. There is no shared memory. `SharedArrayBuffer` requires cross-origin isolation
//      headers (COOP/COEP) that a downloaded standalone page does not have - this was
//      MEASURED on-device (crossOriginIsolated: false), not assumed. So every job's
//      bytes are copied in, and the result is transferred back.
//
// WHY THE APP NEVER BLOCKS. `submit` posts a message and returns a handle immediately.
// The worker's reply lands in `results` whenever it lands. `poll` just looks in that
// map. The app never waits on anything: it asks once a frame and gets on with drawing.
//
// IF WORKERS ARE UNAVAILABLE - `new Worker()` THROWS inside a sandboxed iframe (the
// Claude artifact preview is one) - then `available()` reports 0 and `src/jobs.zig`
// runs the kernel inline on the main thread instead. The app is none the wiser; it
// just hitches, exactly as it would have if it had never used jobs.
const ZimrJobs = struct {
    /// The worker's own program is no longer HERE, and that is the point.
    ///
    /// It is `src/jobs_worker.zig` - a Zig program, compiled to JavaScript by the same
    /// `build-obj -ofmt=c` -> c2js path that produces this file - and the page carries it as
    /// `window.ZIMR_WORKER_JS`, exactly as it carries `ZIMR_KERNEL_WASM`.
    ///
    /// What used to be here was ~40 lines of hand-written JavaScript in a Zig string. It was
    /// the ONLY hand-written JS in the engine and it produced the two worst bugs in the jobs
    /// system: an ABI spelled twice with nothing checking the two spellings agreed, and an
    /// `async` handler whose `await` let a job re-enter before the kernel wasm had finished
    /// instantiating (sixteen tiles submitted on one frame, none ever returned, no error).
    ///
    /// Neither is writable now. The ABI is a `pub const` both sides read, and there is no
    /// `await` in Zig to reach for.
    fn workerProgram() Value {
        return global().get("ZIMR_WORKER_JS");
    }

    /// `new Worker(url)`, but survivable. In a sandboxed iframe (the Claude artifact
    /// preview is one) the blob: URL has an opaque origin and the constructor throws a
    /// SecurityError. That is not an error condition for us - it just means no workers,
    /// so `jobs.zig` runs kernels inline instead. Returns a null Value on refusal.
    fn tryNewWorker(url: Value) Value {
        return .{ .h = js_try_new1(global().get("Worker").h, url.h) };
    }

    /// Bring the pool up on first use. Called from `available()`, so an app that never
    /// submits a job never spawns a thread.
    fn spawn() void {
        if (g.jobs.spawned) {
            return;
        }
        g.jobs.spawned = true; // whatever happens, only try once

        // The kernel wasm is inlined into the page by the build (base64 -> Uint8Array).
        // No kernels in this example? Then there is nothing to run and no pool.
        const kernel_wasm: Value = global().get("ZIMR_KERNEL_WASM");
        if (kernel_wasm.isNull()) {
            return;
        }

        // How many? `hardwareConcurrency` is the core count. We take half, and never more
        // than 4: this pool exists to move work OFF the main thread, not to chase
        // throughput (measured: 8 workers give only ~3.4x aggregate on a phone, and a hot
        // CPU throttles the GPU - which for a renderer is a bad trade).
        //
        // The clamp is written POSITIVELY. `hardwareConcurrency` is absent on some
        // browsers, `getNum` reads that back as NaN, and `NaN < 2` is FALSE - so
        // `if (cores < 2) cores = 2;` would leave NaN in place and `@trunc(NaN / 2)` into
        // a u32 is illegal behaviour. Asking `>= 2` instead makes the missing case fall
        // into the default, which is what a default is for.
        const reported: f64 = global().get("navigator").getNum("hardwareConcurrency");
        const cores: f64 = if (reported >= 2) reported else 2;
        var want: u32 = @trunc(cores / 2);
        if (want < 1) {
            want = 1;
        }
        if (want > 4) {
            want = 4;
        }

        // (workers / busy_with / queue / results were minted at boot - see start().)

        // A Worker normally loads its program from a URL. We have no separate .js file
        // (the whole app is ONE html file), so we wrap the source in a Blob and hand
        // out an object URL for it. This is also the step that THROWS in a sandboxed
        // iframe, because a blob: URL there has an opaque origin.
        // The program is `src/jobs_worker.zig`, compiled to JS by c2js and injected into the
        // page as `window.ZIMR_WORKER_JS`. Its last line calls its own `start()`, which
        // registers the message handler - everything after that happens because the browser
        // delivers a message.
        const parts: Value = global().get("Array").new(.{});
        _ = parts.call("push", .{workerProgram()});
        _ = parts.call("push", .{str("\n;start();\n")});
        const opts: Value = global().get("Object").new(.{});
        opts.set("type", str("text/javascript"));
        const blob: Value = global().get("Blob").new(.{ parts, opts });
        const url: Value = global().get("URL").call("createObjectURL", .{blob});

        var i: u32 = 0;
        while (i < want) : (i += 1) {
            const w: Value = tryNewWorker(url);
            if (w.isNull()) {
                // Refused - a sandboxed iframe forbids blob: workers. Any workers we
                // already started are real OS threads: kill them before giving up, or
                // they idle forever holding a wasm instance each.
                var k: u32 = 0;
                const started: u32 = g.jobs.workers.getU32("length");
                while (k < started) : (k += 1) {
                    _ = g.jobs.workers.at(k).call("terminate", .{});
                }
                _ = g.jobs.workers.call("splice", .{ num(0), num(@floatFromInt(started)) });
                _ = g.jobs.busy_with.call("splice", .{ num(0), num(@floatFromInt(started)) });
                g.jobs.usable = false;
                return;
            }
            w.set("onmessage", func(&onWorkerMessage).call("bind", .{ num(0), num(@floatFromInt(i)) }));
            _ = g.jobs.workers.call("push", .{w});
            _ = g.jobs.busy_with.call("push", .{num(0)});
            _ = g.jobs.ready.call("push", .{num(0)}); // not until it says so

            // Give the worker its program: a private COPY of the kernel wasm bytes.
            const msg: Value = global().get("Object").new(.{});
            msg.set("t", str("init"));
            msg.set("wasm", kernel_wasm);
            _ = w.call("postMessage", .{msg});
        }
        g.jobs.usable = true;
    }

    /// Is a boolean-ish JS field SET?
    ///
    /// This exists because `getNum` on an ABSENT field yields NaN, and NaN fails every
    /// comparison - so `if (v.getNum("failed") != 0)` is TRUE when the field is missing.
    /// That is not a hypothetical: it shipped. A successful job sends no `failed` field,
    /// so every success took the failure branch. The test must be POSITIVE, and asking it
    /// through a named helper means nobody has to remember why.
    fn flagSet(v: Value, comptime name: []const u8) bool {
        return v.getNum(name) >= 1;
    }

    /// A worker replied. Record the result under its handle and give that worker the next
    /// queued job.
    ///
    /// This runs from a postMessage event, which fires OUTSIDE the frame's
    /// js_mark/js_reset bracket - so it must open its own handle scope or it leaks one
    /// handle per job, forever. (`onKeyDown` has the same problem and the same fix.) The
    /// result survives the reset because the JS Map holds the OBJECT; only the
    /// handle-table slot is reclaimed.
    fn onWorkerMessage(worker_idx_h: Handle, event_h: Handle) void {
        const m: Handle = js_mark();
        defer js_reset(m);

        const data: Value = (Value{ .h = event_h }).get("data");

        // The 'ready' handshake carries no handle, so `handle` reads back as NaN. NaN
        // fails EVERY comparison - including `== 0` - so test for a real handle
        // positively. Same trap as `flagSet` above; same answer.
        const handle: f64 = data.getNum("handle");
        if (!(handle >= 1)) {
            // ...and THIS is the handshake. It used to be dropped on the floor here, which
            // meant nothing ever knew a worker had finished instantiating, and `pump()`
            // would post jobs to a worker whose `ex` was still undefined. They threw inside
            // the worker and were never heard from again.
            const slot_r: u32 = @trunc(js_to_num(worker_idx_h));
            g.jobs.ready.setAt(slot_r, num(1));
            pump(); // anything queued while it was booting can go now
            return;
        }

        // Did the owner give up while this was in flight (Job.deinit)? Then throw the
        // result away instead of parking a multi-megabyte Uint8Array in the Map that
        // nobody will ever come back for.
        if (js_to_num(g.jobs.abandoned.call("has", .{num(handle)}).h) != 0) {
            _ = g.jobs.abandoned.call("delete", .{num(handle)});
        } else if (flagSet(data, "failed")) {
            // -2 = "the kernel failed", distinct from -1 = "still running". An error
            // cannot cross the wasm boundary as a value, so log its NAME here - on the
            // page overlay, which is the only console a phone has.
            //
            // Two ARGUMENTS, not a concatenation: `String.concat` is not a function.
            // `concat` lives on String.PROTOTYPE, so it exists on a string INSTANCE and
            // not on the String constructor - and `console.error` takes varargs anyway,
            // which is both simpler and impossible to get wrong.
            _ = global().get("console").call("error", .{
                str("zimr.jobs: kernel failed:"),
                data.get("err"),
            });
            _ = g.jobs.results.call("set", .{ num(handle), num(-2) });
            // ...and KEEP the name, so `Job.errorName()` can hand it back to the app. It is
            // the difference between "KernelFailed" and "ShortPayload" on a phone screen.
            _ = g.jobs.kernel_errors.call("set", .{ num(handle), data.get("err") });
        } else {
            const bytes: Value = global().get("Uint8Array").new(.{data.get("result")});
            _ = g.jobs.results.call("set", .{ num(handle), bytes });
        }

        const slot: u32 = @trunc(js_to_num(worker_idx_h));
        g.jobs.busy_with.setAt(slot, num(0)); // this worker is free again
        pump();
    }

    /// Hand queued jobs to idle workers until one or the other runs out.
    fn pump() void {
        var i: u32 = 0;
        const n: u32 = g.jobs.workers.getU32("length");
        while (i < n) : (i += 1) {
            if (g.jobs.queue.getU32("length") == 0) {
                return;
            }
            // NOT READY = NOT ELIGIBLE. Written positively (`>= 1`), because `getNum` on an
            // absent element yields NaN and NaN fails every comparison - so `!= 1` would be
            // TRUE for a missing entry and we would be right back where we started.
            if (!(js_to_num(g.jobs.ready.at(i).h) >= 1)) {
                continue;
            }
            if (g.jobs.busy_with.at(i).isNull()) {
                continue;
            }
            if (js_to_num(g.jobs.busy_with.at(i).h) != 0) {
                continue; // busy
            }
            const job: Value = g.jobs.queue.call("shift", .{});
            const handle: f64 = job.getNum("handle");
            g.jobs.busy_with.setAt(i, num(handle));

            const msg: Value = global().get("Object").new(.{});
            msg.set("t", str("job"));
            msg.set("handle", num(handle));
            msg.set("kernel", job.get("kernel"));
            msg.set("bytes", job.get("bytes"));

            // TRANSFER the payload rather than let postMessage structured-CLONE it.
            // A transfer hands the ArrayBuffer over and detaches it here: O(1), however
            // many megabytes it holds. Cloning a 4 MB image every job would undo much of
            // the point of moving the work off-thread in the first place.
            const transfer: Value = global().get("Array").new(.{});
            _ = transfer.call("push", .{job.get("bytes")});
            _ = g.jobs.workers.at(i).call("postMessage", .{ msg, transfer });
        }
    }

    // ---- the four functions the wasm imports -------------------------------

    /// Is a real pool behind this? `src/jobs.zig` asks BEFORE staging a job, and runs
    /// the kernel inline if the answer is no.
    fn available() f64 {
        spawn();
        return if (g.jobs.usable) 1 else 0;
    }

    /// Copy `len` bytes of header++payload out of the APP's wasm memory and queue them.
    /// Returns a handle, or 0 if we could not take the job.
    ///
    /// The copy is not optional: the bytes live in the app's linear memory, which the
    /// worker cannot see, and which may be resized (and thus detached) at any moment.
    /// Take a job's HEADER and PAYLOAD SEPARATELY and join them into the single buffer that
    /// crosses to the worker.
    ///
    /// The header and payload used to arrive already joined, because `jobs.zig` allocated a
    /// `staged` buffer and memcpy'd both into it. That allocation was a MULTI-MEGABYTE
    /// `gpa.alloc` on every single dispatch, in the frame path - precisely the mistake that
    /// cost `Job.poll` 154 ms on the landing frame, still live on the input side.
    ///
    /// It bought nothing. This function has to allocate a JS-owned buffer anyway (the one it
    /// transfers to the worker), so it can do the joining while it copies. Two copies of the
    /// payload became one, and a per-dispatch megabyte allocation became zero.
    fn submit(
        name_ptr: f64,
        name_len: f64,
        header_ptr: f64,
        header_len: f64,
        payload_ptr: f64,
        payload_len: f64,
    ) f64 {
        if (!g.jobs.usable) {
            return 0;
        }

        // VIEWS on the app's wasm heap - free, and valid only until the next allocation.
        const header_view: Value = ZimrWgpu.modBytes(header_ptr, header_len);
        const payload_view: Value = ZimrWgpu.modBytes(payload_ptr, payload_len);

        // The one buffer that crosses. It is JS-owned because it gets TRANSFERRED to the
        // worker, which detaches it - we must not hand over a view of our own heap.
        const total_len: f64 = header_len + payload_len;
        const joined: Value = global().get("Uint8Array").new(.{num(total_len)});
        _ = joined.call("set", .{header_view}); // header at offset 0
        _ = joined.call("set", .{ payload_view, num(header_len) }); // payload right after it

        const handle: u32 = g.jobs.next_handle;
        g.jobs.next_handle += 1;

        const job: Value = global().get("Object").new(.{});
        job.set("handle", num(@floatFromInt(handle)));
        job.set("kernel", ZimrWgpu.modString(name_ptr, name_len)); // the kernel's NAME
        job.set("bytes", joined.get("buffer"));
        _ = g.jobs.queue.call("push", .{job});

        pump();
        return @floatFromInt(handle);
    }

    /// -1 while it runs, >= 0 = the result's byte length, -2 = the kernel failed.
    ///
    /// NEVER COERCE `r` TO A NUMBER HERE. The map holds either the result (a Uint8Array) or
    /// the number -2 (the kernel failed). Asking `Number(r)` to tell those apart looks free
    /// and is not: on the success path `r` is the RESULT - 2.7 MB for a 1024x1024 PNG - and
    /// JS coerces a TypedArray to a number via `toString()`, which builds a string of 2.7
    /// MILLION comma-separated integers (~10 MB of text), parses it to NaN, and throws it
    /// away.
    ///
    /// Measured on a phone: **95 ms**, every landing frame, to evaluate a failure flag. The
    /// worker had already given the frame back; this took it away again. It is the reason
    /// `worker_png` appeared to "hitch anyway" and nearly cost the jobs system its case.
    ///
    /// Ask `typeof` instead. A number is the failure marker; anything else is the result, and
    /// its `.length` is the byte count.
    fn poll(handle: f64) f64 {
        if (!g.jobs.usable) {
            return -1;
        }
        const r: Value = g.jobs.results.call("get", .{num(handle)});
        if (r.isNull()) {
            return -1; // still queued or still running
        }
        // `Number.isFinite` does NOT coerce its argument: it is false for anything that is
        // not already a number. So it separates the failure marker (-2) from the result
        // (a Uint8Array) without ever asking the array what it looks like as a string.
        const is_num: bool = global().get("Number").call("isFinite", .{r}).truthy();
        if (is_num) {
            return -2; // the failure marker - the only number we ever store
        }
        return r.getNum("length"); // a Uint8Array: O(1), no coercion, no 10 MB string
    }

    /// Copy the finished result INTO the app's wasm memory at `dst`, and retire it.
    fn take(handle: f64, dst: f64, cap: f64) f64 {
        const r: Value = g.jobs.results.call("get", .{num(handle)});
        if (r.isNull()) {
            return 0;
        }
        var n: f64 = r.getNum("length");
        if (n > cap) {
            n = cap;
        }
        const view: Value = ZimrWgpu.modBytes(dst, n);
        _ = view.call("set", .{r.call("subarray", .{ num(0), num(n) })});
        _ = g.jobs.results.call("delete", .{num(handle)});
        return n;
    }

    /// The owner is done with this job and will never collect it - because it failed,
    /// or because the app dropped the handle (`Job.deinit` on an in-flight job).
    ///
    /// Drop any result we are already holding, and remember the handle so that a reply
    /// still in flight is discarded on arrival rather than retained forever. Without
    /// this, abandoning a job leaks its entire result buffer for the life of the page.
    /// The owner gave up on this job (`Job.deinit`, or a `Group` being torn down).
    ///
    /// A cancelled job is in exactly one of three places, and each needs different treatment:
    ///
    ///   STILL QUEUED, never dispatched.
    ///       Take it OUT of the queue. This used to be skipped, and it was not merely wasted
    ///       work - it was wasted work that DELAYED THE LIVE WORK BEHIND IT. `rt_workers`
    ///       re-renders on every frame the camera moves, cancelling sixteen tiles and
    ///       submitting sixteen more; the dead ones stayed queued AHEAD of the new ones, so a
    ///       one-second drag left the pool grinding through hundreds of tiles for camera
    ///       positions the user had already left. Splicing it out is the whole fix.
    ///
    ///   RUNNING on a worker.
    ///       We cannot stop it - a worker runs one job to completion and there is no way to
    ///       interrupt wasm mid-call. Mark the handle abandoned so the eventual reply is
    ///       thrown away instead of parking a multi-megabyte result in the map that nobody
    ///       will ever collect.
    ///
    ///   ALREADY FINISHED, result sitting in the map.
    ///       Delete it. Same reason.
    ///
    /// Note what this buys beyond speed: `abandoned` is now BOUNDED by the number of jobs
    /// actually in flight. Before, a handle cancelled while queued was added to the set, then
    /// dispatched anyway, and only removed when its reply arrived - so the set tracked every
    /// cancellation the page had ever made. Now a queued job leaves no trace at all, because
    /// no reply will ever come for it.
    fn cancel(handle: f64) void {
        if (handle == 0) {
            return;
        }

        // Already finished? Drop the result, and the failure name with it.
        _ = g.jobs.results.call("delete", .{num(handle)});
        _ = g.jobs.kernel_errors.call("delete", .{num(handle)});

        // Still queued? Remove it, and we are done - no worker will ever touch it, so no
        // reply will ever arrive, so there is nothing to abandon.
        const queued_count: u32 = g.jobs.queue.getU32("length");
        var queue_index: u32 = 0;
        while (queue_index < queued_count) : (queue_index += 1) {
            const queued_job: Value = g.jobs.queue.at(queue_index);
            const queued_handle: f64 = queued_job.getNum("handle");
            if (queued_handle == handle) {
                _ = g.jobs.queue.call("splice", .{ num(@floatFromInt(queue_index)), num(1) });
                return;
            }
        }

        // Not queued, so it is either running on a worker right now or its reply is already in
        // flight. Either way a `done` message is coming for a job nobody wants.
        _ = g.jobs.abandoned.call("add", .{num(handle)});
    }

    /// Copy the failed kernel's error NAME into `dst`, and return how many bytes it wrote.
    /// Zero if this handle has no recorded failure.
    fn errorName(handle: f64, dst: f64, cap: f64) f64 {
        const name: Value = g.jobs.kernel_errors.call("get", .{num(handle)});
        if (name.isNull()) {
            return 0;
        }

        // TextEncoder.encodeInto writes UTF-8 straight into our wasm memory and reports how
        // much fitted - no intermediate array, and no way to overrun `cap`.
        const encoder: Value = global().get("TextEncoder").new(.{});
        const view: Value = ZimrWgpu.modBytes(dst, cap);
        const stats: Value = encoder.call("encodeInto", .{ name, view });
        return stats.getNum("written");
    }

    fn install(ns: Value) void {
        ns.set("js_jobs_available", funcNum(&available));
        ns.set("js_jobs_error_name", funcNum(&errorName));
        ns.set("js_jobs_submit", funcNum(&submit));
        ns.set("js_jobs_poll", funcNum(&poll));
        ns.set("js_jobs_take", funcNum(&take));
        ns.set("js_jobs_cancel", funcNum(&cancel));
    }
};

const BridgeGlobals = struct {
    const Boot = struct {
        stage: u32 = 0, // 0 idle, 1 adapter, 2 device, 3 instantiate, 4 run
        pending_promise: u32 = 0,
        gpu_adapter: Value = undefined,
        gpu_device: Value = undefined,
        gpu_queue: Value = undefined,
        timestamp_supported: bool = false, // adapter exposes 'timestamp-query' (GPU timing)
        module_exports: Value = undefined,
        utf8_decoder: Value = undefined,
        canvas_contexts: Value = undefined, // elem handle -> GPUCanvasContext
        tick_callback: Value = undefined,
        event_ring: [64]ZimrBoot.EvRec = undefined,
        event_count: u32 = 0,
        // Which app contract the instantiated module speaks (detected from
        // its exports at stage 3): bridge-native `zimr_page_main` +
        // `zimr_frame(ms)`, or classic zimr `_initialize` + `update(dt_s)`.
        classic_contract: bool = false,
        last_frame_ms: f64 = 0,
    };
    const Input = struct {
        ready: bool = false,
        held_key_codes: Value = undefined, // a JS Set of held KeyboardEvent.code strings
        mouse_x_css: f32 = 0,
        mouse_y_css: f32 = 0,
        mouse_button_bits: u32 = 0,
        dragging: bool = false, // classic pointer-capture gate
    };
    const Assets = struct {
        ready: bool = false,
        registered_assets: Value = undefined, // a JS Map: name -> Uint8Array
    };
    const Module = struct {
        mem: Value = undefined, // the wasm module's memory Value, set at instantiation
        mem_ready: bool = false,
    };
    const Scratch = struct {
        read_staging: [1 << 16]u8 align(16) = undefined,
        call_args: [16]Handle = undefined,
        fmt: [512]u8 = undefined,
        fmt_len: u32 = 0,
    };
    const Wgpu = struct {
        // ONE table for every wgpu resource. Ids are unique ACROSS types
        // (a single counter), which is strictly safer than per-type tables:
        // passing a buffer id where a texture id belongs can never alias.
        // Id 1 is reserved: device == queue == surface == 1, matching the
        // classic TS bridge's singleton convention.
        objects: Value = undefined, // a JS Map: id -> GPU object
        next_id: u32 = 2,
        // The transitional primary canvas for the classic (single-surface)
        // zimr contract - lazily created by js_get_surface. Apps written
        // against the D9 doctrine create their own canvases via dom verbs.
        canvas: Value = undefined,
        context: Value = undefined,
        format_index: u32 = 0,
        have_canvas: bool = false,
        format_list: Value = .{ .h = 0 }, // lazily-built JS array of format names
        text_encoder: Value = .{ .h = 0 }, // lazily-built TextEncoder (adapter_info)
        // GPU timing (profiler): a timestamp query set + a QUERY_RESOLVE|COPY_SRC
        // resolve buffer + a COPY_DST|MAP_READ readback buffer. Created once at
        // device init when 'timestamp-query' is supported; inert otherwise.
        ts_query_set: Value = .{ .h = 0 },
        ts_resolve_buf: Value = .{ .h = 0 },
        ts_read_buf: Value = .{ .h = 0 },
        ts_ready: bool = false, // infra created and usable
        ts_cursor: u32 = 0, // timestamp slots written on the current encoder
        ts_resolve_pairs: u32 = 0, // pass pairs queued for resolve at finish
        ts_pending: bool = false, // a mapAsync readback is in flight (read buf busy)
        ts_pid: u32 = 0, // promise id of the in-flight mapAsync
        ts_pairs_inflight: u32 = 0, // pass count of the in-flight readback
        gpu_ms_last: f64 = 0, // most recent summed GPU pass time (ms)
    };
    /// Text-input overlay state (the DOM <input> shared across show/poll/hide).
    const Overlay = struct {
        el: Value = .{ .h = 0 }, // the <input> or <textarea>; .h == 0 = not created yet
        visible: bool = false,
        escape_clears: bool = false,
        allow_tab: bool = false,
        char_filters: u32 = 0,
        ctrl_enter_for_newline: bool = false, // textarea-only; the <input> ignores it
    };
    /// WebAudio host state. Same doctrine as `Wgpu`: ONE Map and ONE counter, so
    /// ids are unique ACROSS types (context / buffer / source / decode) and
    /// handing a buffer id where a source id belongs can never alias silently.
    /// Id 0 is reserved for "invalid" - what every `js_audio_*` returns on
    /// failure, matching the Zig declarations in `src/web.zig`.
    const Audio = struct {
        objects: Value = undefined, // JS Map: id -> AudioContext rec / AudioBuffer / source rec / decode rec
        next_id: u32 = 1,
    };

    /// The Web Worker pool that backs `zimr.jobs`.
    ///
    /// A Web Worker is a SECOND JavaScript thread. It shares NOTHING with the page:
    /// no variables, no DOM, no canvas, no WebGPU. The only way to talk to it is to
    /// `postMessage` a value, which is COPIED across (or, for an ArrayBuffer, handed
    /// over wholesale and detached from the sender - a "transfer", which costs nothing
    /// however large it is).
    ///
    /// That isolation is exactly why a kernel must be a pure function, and why each
    /// worker runs its own copy of a small, separately-compiled kernel wasm rather
    /// than sharing the app's. There is no shared memory to share: `SharedArrayBuffer`
    /// needs cross-origin isolation headers we do not have, which was measured, not
    /// assumed.
    const Jobs = struct {
        spawned: bool = false, // have we tried to create the workers yet?
        usable: bool = false, // ...and did it work? (a sandboxed iframe says no)
        workers: Value = undefined, // JS Array of Worker
        busy_with: Value = undefined, // JS Array: worker index -> job handle it is running (0 = idle)
        /// JS Array: worker index -> 1 once that worker has INSTANTIATED its kernel wasm.
        ///
        /// The worker's `onmessage` is ASYNC: the `init` handler `await`s
        /// `WebAssembly.instantiate` and YIELDS. A job that arrives during that window finds
        /// `ex` still undefined, throws inside the worker, and is never heard from again.
        ///
        /// The worker has always posted `{t:'ready'}` when it finished instantiating. The
        /// host has always THROWN IT AWAY - the handshake carries no handle, so it fell
        /// through the `handle >= 1` guard and vanished. So `pump()` would dispatch to a
        /// worker that could not yet run anything.
        ///
        /// `worker_png` never hit it: one job, submitted many frames after the pool came up.
        /// `rt_workers` submits SIXTEEN on the first frame - the same frame `spawn()` runs -
        /// and every one of them raced the instantiation. Sixteen tiles, none ever landed,
        /// and not one error anywhere.
        ready: Value = undefined,
        queue: Value = undefined, // JS Array of job records waiting for a free worker
        results: Value = undefined, // JS Map: handle -> Uint8Array (done) or -2 (failed)
        /// JS Map: handle -> the failed kernel's error NAME, as a string.
        ///
        /// The worker has always SENT this ("ShortPayload", "OutOfMemory", ...). The host used
        /// to print it to `console.error` and then throw it away, so Zig only ever saw -2 and
        /// every failure surfaced as a bare `error.KernelFailed`. On a phone, where there is no
        /// console to read, that is indistinguishable from no diagnosis at all.
        kernel_errors: Value = undefined,
        abandoned: Value = undefined, // JS Set of handles whose owner gave up; late replies are dropped
        next_handle: u32 = 1,
    };

    boot: Boot = .{},
    wgpu: Wgpu = .{},
    audio: Audio = .{},
    jobs: Jobs = .{},
    input: Input = .{},
    assets: Assets = .{},
    module: Module = .{},
    scratch: Scratch = .{},
    default_sheet: ?css.Sheet = null, // lazily-created default stylesheet
    overlay: Overlay = .{},
    overlay_ta: Overlay = .{}, // multiline sibling of `overlay`; its own <textarea>
    userfile: UserFile = .{},
};

/// Drag-and-drop + file-picker state. See `web.zig`'s `userfile` namespace for the protocol
/// and for why the picker must be a real DOM element rather than a wasm-drawn button.
const UserFile = struct {
    /// JS array of `{ name, bytes }`, oldest first. Files land here only once their
    /// `arrayBuffer()` has resolved, so anything in the queue is complete and readable.
    queue: Value = .{ .h = 0 },
    /// The transparent `<input type="file">` parked over the caller's Load button.
    input: Value = .{ .h = 0 },
    /// The transparent `<a download>` parked over the caller's Save button, and the object URL
    /// it currently points at - revoked whenever a newer file replaces it, so offering a fresh
    /// file every few seconds does not leak the old ones.
    save: Value = .{ .h = 0 },
    save_url: Value = .{ .h = 0 },
    /// Drop listeners are attached once, lazily - attaching them at boot would mean every
    /// page paid for a feature almost none of them use.
    listening: bool = false,
    /// The name of the file whose `arrayBuffer()` is currently in flight.
    pending_name: Value = .{ .h = 0 },
};

// lint:off module-var: THE one page singleton - see BridgeGlobals doc above
var g: BridgeGlobals = .{};

pub const Event = extern struct {
    j: Value,

    pub fn offsetX(self: Event) f32 {
        return self.j.get("offsetX").to(f32);
    }
    pub fn offsetY(self: Event) f32 {
        return self.j.get("offsetY").to(f32);
    }
    pub fn clientX(self: Event) f32 {
        return self.j.get("clientX").to(f32);
    }
    pub fn clientY(self: Event) f32 {
        return self.j.get("clientY").to(f32);
    }
    pub fn key(self: Event) Value {
        return self.j.get("key");
    }
    /// KeyboardEvent.code - the physical key ("ArrowLeft", "KeyW"), layout-independent.
    pub fn code(self: Event) Value {
        return self.j.get("code");
    }
    /// event.target, as an Element.
    pub fn target(self: Event) Element {
        return .{ .j = self.j.get("target") };
    }
    pub fn preventDefault(self: Event) void {
        _ = self.j.call("preventDefault", .{});
    }
    pub fn stopPropagation(self: Event) void {
        _ = self.j.call("stopPropagation", .{});
    }
};

/// A JS Promise, handled with CALLBACKS (no Asyncify, no blocking). `.then(&onOk)`
/// registers a Zig fn that JS calls with the resolved value (a Handle - `wz.wrap` it);
/// `.catch_(&onErr)` handles rejection. Both return the next Promise, so you can chain
/// `wz.fetch(u).then(&ok).catch_(&err)`. Callbacks are `fn(wz.Handle) void` - do the next
/// async step (e.g. `res.json().then(&onData)`) inside the callback.
pub const Promise = extern struct {
    j: Value,
    /// .then(onResolve) - onResolve is a `&fn(wz.Value) void`.
    pub fn then(self: Promise, on_resolve: *const anyopaque) Promise {
        return .{ .j = self.j.call("then", .{func(on_resolve)}) };
    }
    /// .then with a typed context: `p.thenCtx(rec, onMapped)` where rec is a pointer
    /// and `onMapped: fn(@TypeOf(rec), wz.Value) void`. The context is threaded to the
    /// callback so per-operation state needn't live in a global - closures-with-state
    /// without Asyncify. (The resolved Value is valid only inside the callback.)
    pub fn thenCtx(
        self: Promise,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), Value) void,
    ) Promise {
        const Ctx = @TypeOf(ctx);
        const Tramp = struct {
            fn entry(c: u32, v: Handle) void {
                cb(@as(Ctx, @ptrFromInt(c)), .{ .h = v });
            }
        };
        const h = js_func_ctx(&Tramp.entry, @intCast(@intFromPtr(ctx)));
        return .{ .j = self.j.call("then", .{Value{ .h = h }}) };
    }
    /// .catch with a typed context (see thenCtx).
    pub fn catchCtx(
        self: Promise,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), Value) void,
    ) Promise {
        const Ctx = @TypeOf(ctx);
        const Tramp = struct {
            fn entry(c: u32, v: Handle) void {
                cb(@as(Ctx, @ptrFromInt(c)), .{ .h = v });
            }
        };
        const h = js_func_ctx(&Tramp.entry, @intCast(@intFromPtr(ctx)));
        return .{ .j = self.j.call("catch", .{Value{ .h = h }}) };
    }
    /// .catch(onReject) - named `catch_` because `catch` is a Zig keyword.
    pub fn catch_(self: Promise, on_reject: *const anyopaque) Promise {
        return .{ .j = self.j.call("catch", .{func(on_reject)}) };
    }
    /// .finally(onDone) - runs on settle (resolve OR reject); onDone takes no args.
    pub fn finally(self: Promise, on_done: *const anyopaque) Promise {
        return .{ .j = self.j.call("finally", .{func(on_done)}) };
    }
};

/// A fetch Response. `.json()`/`.text()` return Promises (the body is async); `.ok()`
/// and `.status()` are immediate. (For most calls, prefer `wz.fetchJson`/`fetchText`,
/// which skip straight to the parsed body.)
pub const Response = extern struct {
    j: Value,
    /// response.json() -> Promise of the parsed value.
    pub fn json(self: Response) Promise {
        return .{ .j = self.j.call("json", .{}) };
    }
    /// response.text() -> Promise of the body string.
    pub fn text(self: Response) Promise {
        return .{ .j = self.j.call("text", .{}) };
    }
    /// response.ok - true for a 2xx status.
    pub fn ok(self: Response) bool {
        return self.j.get("ok").truthy();
    }
    /// response.status - the HTTP status code.
    pub fn status(self: Response) f64 {
        return self.j.get("status").to(f64);
    }
};

pub const Value = extern struct {
    h: Handle,

    /// obj.prop  (returns the property as a Value)
    pub fn get(self: Value, comptime name: []const u8) Value {
        return .{ .h = js_get(self.h, name.ptr, @intCast(name.len)) };
    }
    /// obj.prop as a number, read directly with no intermediate handle - for the hot
    /// numeric reads (event.offsetX every move, canvas.width, element.scrollTop, ...).
    /// `getNum` returns f64; `getU32`/`getF32` are typed conveniences.
    pub fn getNum(self: Value, comptime name: []const u8) f64 {
        return js_get_num(self.h, name.ptr, @intCast(name.len));
    }
    pub fn getU32(self: Value, comptime name: []const u8) u32 {
        return @trunc(self.getNum(name));
    }
    pub fn getF32(self: Value, comptime name: []const u8) f32 {
        return @floatCast(self.getNum(name));
    }
    /// obj.prop = value   (value is marshalled: number, string, bool, or Value)
    pub fn set(
        self: Value,
        comptime name: []const u8,
        value: anytype,
    ) void {
        // A number or bool goes straight to the slot via js_set_num, so no handle is
        // minted for the value. Strings, Values and nested structs go through toH,
        // which builds the JS string / object the property needs.
        switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int, .float, .comptime_float => js_set_num(
                self.h,
                name.ptr,
                @intCast(name.len),
                f64of(value),
            ),
            .bool => js_set_num(self.h, name.ptr, @intCast(name.len), if (value) 1 else 0),
            else => js_set(self.h, name.ptr, @intCast(name.len), toH(value)),
        }
    }
    /// obj[i]
    pub fn at(self: Value, i: u32) Value {
        return .{ .h = js_get_index(self.h, i) };
    }
    /// obj[i] = value
    pub fn setAt(
        self: Value,
        i: u32,
        value: anytype,
    ) void {
        js_set_index(self.h, i, toH(value));
    }

    /// obj.method(...args) - args is a tuple of mixed types, each marshalled.
    /// Dispatches by comptime arity to the fixed-arity kernel calls (no buffer)
    /// for up to 6 args; falls back to a heap arg-buffer for more.
    pub fn call(
        self: Value,
        comptime name: []const u8,
        args: anytype,
    ) Value {
        const n: usize = args.len; // comptime
        const p: [*]const u8 = name.ptr;
        const l: u32 = @intCast(name.len);
        if (comptime args.len >= 1 and args.len <= 6 and allNumeric(@TypeOf(args))) {
            return .{ .h = switch (n) {
                1 => js_calln1(self.h, p, l, f64of(args[0])),
                2 => js_calln2(self.h, p, l, f64of(args[0]), f64of(args[1])),
                3 => js_calln3(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2])),
                4 => js_calln4(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(args[3])),
                5 => js_calln5(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(
                    args[3],
                ), f64of(args[4])),
                6 => js_calln6(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(
                    args[3],
                ), f64of(args[4]), f64of(args[5])),
                else => unreachable,
            } };
        }
        if (n == 0) {
            return .{ .h = js_call0(self.h, p, l) };
        }
        if (n == 1) {
            return .{ .h = js_call1(self.h, p, l, toH(args[0])) };
        }
        if (n == 2) {
            return .{ .h = js_call2(self.h, p, l, toH(args[0]), toH(args[1])) };
        }
        if (n == 3) {
            return .{ .h = js_call3(
                self.h,
                p,
                l,
                toH(args[0]),
                toH(args[1]),
                toH(args[2]),
            ) };
        }
        if (n == 4) {
            return .{ .h = js_call4(
                self.h,
                p,
                l,
                toH(args[0]),
                toH(args[1]),
                toH(args[2]),
                toH(args[3]),
            ) };
        }
        if (n == 5) {
            return .{ .h = js_call5(
                self.h,
                p,
                l,
                toH(args[0]),
                toH(args[1]),
                toH(args[2]),
                toH(args[3]),
                toH(args[4]),
            ) };
        }
        if (n == 6) {
            return .{ .h = js_call6(
                self.h,
                p,
                l,
                toH(args[0]),
                toH(args[1]),
                toH(args[2]),
                toH(args[3]),
                toH(args[4]),
                toH(args[5]),
            ) };
        }
        // >6 args: marshal into the shared buffer, then js_call_n.
        comptime var i: usize = 0;
        inline while (i < n) : (i += 1) {
            g.scratch.call_args[i] = toH(args[i]);
        }
        return .{ .h = js_call_n(self.h, p, l, @intCast(@intFromPtr(&g.scratch.call_args[0])), n) };
    }

    /// obj.method(...args) for a VOID method: no result handle is minted (the hot
    /// render-loop calls - setPipeline/setBindGroup/draw/end - are all void, and the
    /// discarded return-handle is pure overhead + handle-table churn otherwise).
    pub fn callVoid(
        self: Value,
        comptime name: []const u8,
        args: anytype,
    ) void {
        const n: usize = args.len;
        const p: [*]const u8 = name.ptr;
        const l: u32 = @intCast(name.len);
        if (comptime args.len >= 1 and args.len <= 6 and allNumeric(@TypeOf(args))) {
            switch (n) {
                1 => js_calln1v(self.h, p, l, f64of(args[0])),
                2 => js_calln2v(self.h, p, l, f64of(args[0]), f64of(args[1])),
                3 => js_calln3v(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2])),
                4 => js_calln4v(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(args[3])),
                5 => js_calln5v(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(
                    args[3],
                ), f64of(args[4])),
                6 => js_calln6v(self.h, p, l, f64of(args[0]), f64of(args[1]), f64of(args[2]), f64of(
                    args[3],
                ), f64of(args[4]), f64of(args[5])),
                else => unreachable,
            }
            return;
        }
        switch (n) {
            0 => js_call0v(self.h, p, l),
            1 => js_call1v(self.h, p, l, toH(args[0])),
            2 => js_call2v(self.h, p, l, toH(args[0]), toH(args[1])),
            3 => js_call3v(self.h, p, l, toH(args[0]), toH(args[1]), toH(args[2])),
            4 => js_call4v(self.h, p, l, toH(args[0]), toH(args[1]), toH(args[2]), toH(args[3])),
            5 => js_call5v(self.h, p, l, toH(args[0]), toH(args[1]), toH(args[2]), toH(args[3]), toH(args[4])),
            else => {
                _ = self.call(name, args); // rare high-arity void: fall back (mints a handle)
            },
        }
    }

    /// new Ctor(...args)
    pub fn new(self: Value, args: anytype) Value {
        const n: usize = args.len;
        if (n == 0) {
            return .{ .h = js_new0(self.h) };
        }
        if (n == 1) {
            return .{ .h = js_new1(self.h, toH(args[0])) };
        }
        if (n == 2) {
            return .{ .h = js_new2(self.h, toH(args[0]), toH(args[1])) };
        }
        if (n == 3) {
            return .{ .h = js_new3(self.h, toH(args[0]), toH(args[1]), toH(args[2])) };
        }
        @compileError("js: new with more than 3 args not supported");
    }

    /// Coerce this JS value to a concrete Zig type. `to(f64)`, `to(i32)`, `to(bool)`.
    pub fn to(self: Value, comptime T: type) T {
        return switch (@typeInfo(T)) {
            .float => @floatCast(js_to_num(self.h)),
            .int => @trunc(js_to_num(self.h)),
            .bool => js_truthy(self.h) != 0,
            else => @compileError("js: cannot convert JS value to " ++ @typeName(T)),
        };
    }

    pub fn truthy(self: Value) bool {
        return js_truthy(self.h) != 0;
    }
    /// (number).toFixed(digits) -> a string Value, e.g. for prices: `price.toFixed(2)`.
    pub fn toFixed(self: Value, digits: u32) Value {
        return self.call("toFixed", .{digits});
    }
    pub fn isNull(self: Value) bool {
        return js_is_null(self.h) != 0;
    }
    pub fn eql(self: Value, other: Value) bool {
        return js_strict_eq(self.h, other.h) != 0;
    }
    pub fn typeOf(self: Value) Value {
        return .{ .h = js_typeof(self.h) };
    }
    /// Release the handle so its slot is reclaimed (a free-list reuses freed
    /// indices). Usually unnecessary inside a wz.Site frame: each frame is
    /// bracketed by js_mark/js_reset, so handles minted during onFrame (and the
    /// callbacks WASM invokes) are freed automatically. Free explicitly only for
    /// long-lived transients you mint OUTSIDE the frame loop.
    pub fn free(self: Value) void {
        js_free(self.h);
    }

    // --- typed views (zero-cost reinterpretations) ---
    pub fn asElement(self: Value) Element {
        return .{ .j = self };
    }
    pub fn asCtx2D(self: Value) Ctx2D {
        return .{ .j = self };
    }
    pub fn asEvent(self: Value) Event {
        return .{ .j = self };
    }
    pub fn asPromise(self: Value) Promise {
        return .{ .j = self };
    }
    pub fn asResponse(self: Value) Response {
        return .{ .j = self };
    }
};

// snake_case (Zig field convention) -> camelCase (JS/WebGPU key convention).
/// Build a JS object from a Zig anonymous struct: `wz.obj(.{ .size = 256, .label = "x" })`.
/// Fields are marshalled by type (numbers/strings/bools/Values, nested objects, and
/// tuples-as-arrays) and snake_case keys become camelCase. The descriptor-building win.
pub fn obj(fields: anytype) Value {
    return .{ .h = objToH(fields) };
}

/// Compile-time guard for a struct read straight out of module memory: it must be a
/// fixed-layout `extern struct` with no host pointers (a module address is not a host
/// pointer) and no optionals. Misuse is a compile error, not a silent wrong read.
pub fn Wire(comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".layout != .@"extern") {
            @compileError("wz.Wire: " ++ @typeName(T) ++ " must be an `extern struct` (fixed, shared layout)");
        }
        for (structFields(T)) |f| {
            switch (@typeInfo(f.type)) {
                .pointer => @compileError("wz.Wire: field '" ++ f.name ++
                    "' is a pointer; a module address is not a host pointer."),
                .optional => @compileError("wz.Wire: field '" ++ f.name ++
                    "' is optional; optionals have no fixed wire layout."),
                else => {},
            }
        }
        return T;
    }
}

// scratch the bulk module-memory reader copies into before reinterpreting (see
// Wasm.readSlice). Bounds descriptor reads; one copy replaces N per-field crossings.

/// A handle table for bridges: maps 1-based ids (0 = none/invalid) to live values,
/// reusing released ids via a free list. One per resource kind - the table every
/// bridge needs to hand the module small integer handles for GPU/DOM objects while
/// keeping the real JS values (wz.Value) host-side. Fixed capacity, no allocator;
/// overflowing it traps rather than silently overwriting, since a too-small cap or a
/// handle leak is a bug you want to hear about. `get` returns null for 0 or any id
/// that was never issued or has been released.
pub fn Table(comptime T: type, comptime capacity: usize) type {
    return struct {
        slots: [capacity]?T = undefined, // every id in [1,next) is written before read
        free: [capacity]u32 = undefined,
        free_n: usize = 0,
        next: u32 = 1, // 0 reserved for "invalid"
        const Self = @This();

        /// Store a value, return its id (never 0).
        pub fn insert(self: *Self, value: T) u32 {
            const id = if (self.free_n > 0) blk: {
                self.free_n -= 1;
                break :blk self.free[self.free_n];
            } else blk: {
                const i = self.next;
                if (i >= capacity) unreachable; // table full - raise the capacity
                self.next += 1;
                break :blk i;
            };
            self.slots[id] = value;
            return id;
        }
        /// The value for `id`, or null if 0 / never issued / released.
        pub fn get(self: *const Self, id: u32) ?T {
            if (id == 0 or id >= self.next) {
                return null;
            }
            return self.slots[id];
        }
        /// Release `id` so its slot is reused by a later insert. No-op on invalid ids.
        pub fn remove(self: *Self, id: u32) void {
            if (id == 0 or id >= self.next or self.slots[id] == null) {
                return;
            }
            self.slots[id] = null;
            self.free[self.free_n] = id;
            self.free_n += 1;
        }
    };
}

// shared scratch for the rare >6-argument call (see Value.call)

// numeric-arg fast path: a call whose args are all ints/floats skips minting a
// handle per argument (js_num + a handle-table slot each) and passes raw f64s to
// the js_callnN kernels. Hot graphics/WebGPU calls - fillRect, draw, setViewport,
// dispatchWorkgroups - are all-numeric, and this brings them to parity with a
// hand-written `obj.method(x, y, ...)`. Detected at comptime, so non-numeric calls
// compile to the handle path with no runtime branch.

// ===========================================================================
// Value - a handle to any JS value.
// ===========================================================================

// ===========================================================================
// Free helpers - the JS globals.
// ===========================================================================
pub fn window() Value {
    return global();
}
pub fn console() Value {
    return global().get("console");
}
pub fn math() Value {
    return global().get("Math");
}
/// An explicit JS number Value.
pub fn num(x: f64) Value {
    return .{ .h = js_num(x) };
}
/// Wrap a raw handle (e.g. a callback parameter from JS) as a Value.
pub fn wrap(h: Handle) Value {
    return .{ .h = h };
}
/// A new empty JS array.
pub fn array() Value {
    return .{ .h = js_array() };
}

// ---- timers --------------------------------------------------------------
// Each takes a Zig fn address (`&tick`) just like `Element.on`, and returns the
// timer id as a Value so you can cancel it. `setInterval(&tick, 1000)`.

/// setInterval(handler, ms) -> id
pub fn setInterval(handler: *const anyopaque, ms: u32) Value {
    return global().call("setInterval", .{ func(handler), ms });
}
/// setTimeout(handler, ms) -> id
pub fn setTimeout(handler: *const anyopaque, ms: u32) Value {
    return global().call("setTimeout", .{ func(handler), ms });
}
/// clearInterval(id) - id is the Value returned by setInterval.
pub fn clearInterval(id: Value) void {
    _ = global().call("clearInterval", .{id});
}
/// clearTimeout(id)
pub fn clearTimeout(id: Value) void {
    _ = global().call("clearTimeout", .{id});
}

// ---- ubiquitous built-ins ------------------------------------------------

/// Math.random() - a float in [0, 1). (For seeded/repeatable randomness use Zig's
/// std.Random instead; this is the quick JS one.)
pub fn random() f64 {
    return math().call("random", .{}).to(f64);
}
/// Date.now() - milliseconds since the epoch.
pub fn now() f64 {
    return global().get("Date").call("now", .{}).to(f64);
}
/// A JS Date - `wz.date()` gives you `new Date()` (now). Methods return the same
/// strings JS does; reach `.j` for anything not wrapped.
pub const Date = extern struct {
    j: Value,
    /// toLocaleTimeString() -> "3:04:11 PM"
    pub fn localeTime(self: Date) Value {
        return self.j.call("toLocaleTimeString", .{});
    }
    /// toLocaleDateString() -> "6/9/2026"
    pub fn localeDate(self: Date) Value {
        return self.j.call("toLocaleDateString", .{});
    }
    /// toISOString() -> "2026-06-09T15:04:11.000Z"
    pub fn iso(self: Date) Value {
        return self.j.call("toISOString", .{});
    }
    /// getTime() -> ms since the epoch
    pub fn getTime(self: Date) f64 {
        return self.j.call("getTime", .{}).to(f64);
    }
};

/// new Date() - the current moment, as a typed Date facade.
pub fn date() Date {
    return .{ .j = global().get("Date").new(.{}) };
}

// ---- console (format-aware, like the rest of webzig) ---------------------
// `log("count = {}", .{n})` reads like console.log with a template literal, but
// the formatting is the std.fmt `{}` you already use everywhere else.

/// console.log(fmt(spec, args))
pub fn log(comptime spec: []const u8, args: anytype) void {
    _ = console().call("log", .{fmt(spec, args)});
}
/// console.warn(fmt(spec, args))
pub fn warn(comptime spec: []const u8, args: anytype) void {
    _ = console().call("warn", .{fmt(spec, args)});
}
/// console.error(fmt(spec, args))  (named `err` - `error` is a Zig keyword)
pub fn err(comptime spec: []const u8, args: anytype) void {
    _ = console().call("error", .{fmt(spec, args)});
}

/// JSON.stringify / JSON.parse. `stringify` takes any JS Value; `parse` takes a
/// string (literal or Value) and returns the parsed Value.
pub const json = struct {
    pub fn stringify(v: Value) Value {
        return global().get("JSON").call("stringify", .{v});
    }
    pub fn parse(s: anytype) Value {
        return global().get("JSON").call("parse", .{s});
    }
};

/// localStorage - string key/value persistence. `get` returns a Value that is
/// `null` when the key is absent (check with `.isNull()`); `set` stores any value
/// (numbers/strings coerce). Keys are comptime (they are part of your app, not data).
pub const storage = struct {
    fn ls() Value {
        return global().get("localStorage");
    }
    pub fn get(comptime key: []const u8) Value {
        return ls().call("getItem", .{str(key)});
    }
    pub fn set(comptime key: []const u8, v: anytype) void {
        _ = ls().call("setItem", .{ str(key), v });
    }
    pub fn remove(comptime key: []const u8) void {
        _ = ls().call("removeItem", .{str(key)});
    }
    pub fn clear() void {
        _ = ls().call("clear", .{});
    }
};

// ---- fetch (async, callback-based - no Asyncify, no blocking) ------------
// `fetch` resolves to a Response; `fetchJson`/`fetchText` skip straight to the
// parsed body. Handle the result with `.then(&onData)` (and `.catch_(&onErr)`):
// your callback is `fn(wz.Handle) void`, called with the resolved value.
//
//   fn load() void { _ = wz.fetchJson("/api/user").then(&onUser); }
//   fn onUser(h: wz.Handle) void {
//       const u = wz.wrap(h);
//       name_el.setText(u.get("name"));
//   }

/// fetch(url) -> Promise that resolves to a Response (use `.json()`/`.text()` for
/// the body). `url` is a string literal or a Value.
pub fn fetch(url: anytype) Promise {
    return .{ .j = global().call("fetch", .{url}) };
}
/// fetch(url) then r.json() -> Promise resolving DIRECTLY to the parsed JSON value.
pub fn fetchJson(url: anytype) Promise {
    return .{ .j = .{ .h = js_fetch_json(toH(url)) } };
}
/// fetch(url) then r.text() -> Promise resolving DIRECTLY to the body as a string.
pub fn fetchText(url: anytype) Promise {
    return .{ .j = .{ .h = js_fetch_text(toH(url)) } };
}

// ===========================================================================
// Typed facades - thin wrappers so common code reads exactly like JS.
// Each is just a Value plus typed methods; reach `.j` for anything not wrapped.
// ===========================================================================

// ===========================================================================
// String building - the way JS uses template literals, with std.fmt-style `{}`.
//   fmt("{} + {} = {}", .{a, b, a + b})   ~=   `${a} + ${b} = ${a + b}`
// Placeholders accept integers, floats (truncated to integer), and string
// literals. Returns a JS string Value ready to assign.
//
// Uses one shared buffer, so it is for sequential UI code (not reentrant).
// ===========================================================================

// ---- UI building helpers -------------------------------------------------
// Convenience on top of the DOM facade so a Zig "page" reads declaratively
// instead of repeating create/setClass/setAttr/append by hand. All take
// comptime strings (the slice-by-value constraint), which suits static layout.

/// A `<button>` labelled `label_text`, wired to `handler` (a `&fn` pointer) on
/// click, appended to `parent`.
pub fn button(
    parent: Element,
    comptime label_text: []const u8,
    handler: *const anyopaque,
) Element {
    const b: Element = parent.textChild("button", "", label_text);
    b.on("click", handler);
    return b;
}

/// A `.out` result line (id `id`) that a handler writes into. Starts as a dash.
pub fn output(parent: Element, comptime id: []const u8) Element {
    const o: Element = parent.child("div", "out");
    o.setId(id);
    o.setText(str("\u{2014}"));
    return o;
}

/// Build a JS string from a runtime byte buffer - the dynamic-length escape
/// hatch that `str` (comptime) and `fmt` (numbers only) don't cover.
pub fn strBuf(ptr: [*]const u8, len: u32) Value {
    return .{ .h = js_str(ptr, len) };
}

// ===========================================================================
// WASM hosting - load a sibling .wasm module and drive it from Zig.
//
// The module lives in ITS OWN linear memory (exported as `memory`); this bridge
// runs in the transpiler's separate heap. We never touch the module's memory
// directly - we read it on the JS side (a Uint8Array over its buffer) and copy
// regions into a canvas. Instantiation is async (a Promise); the animation loop
// is requestAnimationFrame. Both are hidden behind `Site(...)` below so the
// bridge reads like synchronous setup + a per-frame function.
// ===========================================================================
extern fn js_promise_register(ph: Handle) u32;
extern fn js_promise_status(id: u32) u32;
extern fn js_promise_take(id: u32) Handle;
extern fn js_fetch_json(u: Handle) Handle;
extern fn js_fetch_text(u: Handle) Handle;

/// A live WebAssembly instance: its exports object and its (exported) memory.
pub const Wasm = extern struct {
    instance: Value,
    exports: Value,
    mem: Value,

    /// Call an exported function: `wasm.call("render", .{t})`.
    pub fn call(
        self: Wasm,
        comptime name: []const u8,
        args: anytype,
    ) Value {
        return self.exports.call(name, args);
    }
    /// Call an exported function and read its result as a number.
    pub fn num(
        self: Wasm,
        comptime name: []const u8,
        args: anytype,
    ) f64 {
        return self.exports.call(name, args).to(f64);
    }
    /// A fresh Uint8Array VIEW over the module's whole linear memory. (Re-made
    /// each call: a WASM memory can grow and detach its old buffer.)
    pub fn view(self: Wasm) Value {
        return global().get("Uint8Array").new(.{self.mem.get("buffer")});
    }
    /// Copy `len` bytes of the module's memory from `offset` into a canvas
    /// ImageData's pixel array: `imageData.data.set(view.subarray(off, off+len))`.
    pub fn blitInto(
        self: Wasm,
        image_data: Value,
        offset: u32,
        len: u32,
    ) void {
        const region: Value = self.view().call("subarray", .{ offset, offset + len });
        _ = image_data.get("data").call("set", .{region});
    }

    /// A fresh DataView over the module's whole linear memory (re-made each call,
    /// since a growing memory detaches its old buffer). The typed accessors below
    /// use it to read/write struct fields at known byte offsets - the manual,
    /// little-endian layout that BOTH sides must agree on by hand.
    pub fn dataView(self: Wasm) Value {
        return global().get("DataView").new(.{self.mem.get("buffer")});
    }
    pub fn getU32(self: Wasm, off: u32) u32 {
        return @trunc(self.dataView().call("getUint32", .{ off, true }).to(f64));
    }
    pub fn setU32(
        self: Wasm,
        off: u32,
        v: u32,
    ) void {
        _ = self.dataView().call("setUint32", .{ off, v, true });
    }
    pub fn getF32(self: Wasm, off: u32) f32 {
        return @floatCast(self.dataView().call("getFloat32", .{ off, true }).to(f64));
    }
    pub fn setF32(
        self: Wasm,
        off: u32,
        v: f32,
    ) void {
        _ = self.dataView().call("setFloat32", .{ off, v, true });
    }
    // 8- and 16-bit accessors, so the comptime marshaller (contract.zig) can
    // place sub-word `extern struct` fields at their natural width.
    pub fn getU8(self: Wasm, off: u32) u8 {
        return @trunc(self.dataView().call("getUint8", .{off}).to(f64));
    }
    pub fn setU8(
        self: Wasm,
        off: u32,
        v: u8,
    ) void {
        _ = self.dataView().call("setUint8", .{ off, v });
    }
    pub fn getU16(self: Wasm, off: u32) u16 {
        return @trunc(self.dataView().call("getUint16", .{ off, true }).to(f64));
    }
    pub fn setU16(
        self: Wasm,
        off: u32,
        v: u16,
    ) void {
        _ = self.dataView().call("setUint16", .{ off, v, true });
    }
    /// Encode a JS string as UTF-8 into the module's memory at `off`; returns the
    /// number of bytes written. (The host handing the module a run-of-text.)
    pub fn writeStr(
        self: Wasm,
        off: u32,
        s: Value,
    ) u32 {
        const bytes: Value = global().get("TextEncoder").new(.{}).call("encode", .{s});
        _ = self.view().call("set", .{ bytes, off });
        return @trunc(bytes.get("length").to(f64));
    }
    /// Decode `len` bytes of the module's memory at `off` as a UTF-8 JS string.
    /// (The module handing the host a run-of-text.)
    pub fn readStr(
        self: Wasm,
        off: u32,
        len: u32,
    ) Value {
        const region: Value = self.view().call("subarray", .{ off, off + len });
        return global().get("TextDecoder").new(.{}).call("decode", .{region});
    }
    /// Read `len` values of `T` out of the module's memory at byte `ptr` in ONE bulk
    /// copy, then reinterpret natively - no per-field DataView crossing. `T` must pass
    /// `Wire` (a shared `extern struct`), so the wire format IS the struct both sides
    /// share: reorder a field and both move together. Returns a view into a reused
    /// scratch buffer - valid until the next readSlice/readStruct call.
    pub fn readSlice(
        self: Wasm,
        comptime T: type,
        ptr: u32,
        len: u32,
    ) []const T {
        _ = Wire(T);
        const nbytes = len * @sizeOf(T);
        if (nbytes > g.scratch.read_staging.len) {
            unreachable; // descriptors fit in 64 KiB
        }
        js_read_into(@intFromPtr(&g.scratch.read_staging[0]), self.mem.h, ptr, nbytes);
        return @as([*]const T, @ptrCast(@alignCast(&g.scratch.read_staging[0])))[0..len];
    }
    /// Read a single `T` from module memory at byte `ptr` (see readSlice).
    pub fn readStruct(
        self: Wasm,
        comptime T: type,
        ptr: u32,
    ) T {
        return self.readSlice(T, ptr, 1)[0];
    }
};

// ===========================================================================
// Host-side module runtime - the JS half of wz_mod.zig's imports. The module
// passes (ptr, len) pairs into ITS OWN memory; the host reads them here. `g.module.mem`
// is the module's memory, captured by Site once the module is live (before any
// import can fire), so these helpers and the input/log sinks can decode module
// strings without each needing a handle to the Wasm wrapper.
// ===========================================================================

/// Decode a (ptr, len) pair - passed by the module as numbers - as a UTF-8 string
/// living in the module's linear memory.
fn moduleStr(ptr_h: Handle, len_h: Handle) Value {
    const ptr: u32 = @trunc(js_to_num(ptr_h));
    const len: u32 = @trunc(js_to_num(len_h));
    const view: Value = global().get("Uint8Array").new(.{ g.module.mem.get("buffer"), ptr, len });
    return global().get("TextDecoder").new(.{}).call("decode", .{view});
}

/// input - poll the keyboard and mouse from the module (see wz_mod.zig's
/// `wzm.input`). Call `wz.input.attach(canvas)` once from your bridge (e.g. in
/// onReady), passing the canvas you blit to; that registers DOM listeners and
/// tracks held keys + mouse position/buttons. The module then queries this state
/// synchronously each frame through the imports Site wires below - no event
/// plumbing crosses into WASM.
pub const input = struct {

    // DOM listeners. Events fire OUTSIDE the frame's js_mark/js_reset bracket, so
    // each opens its own handle scope to stay leak-free; the Set keeps string
    // VALUES (not handles), so they persist after the scope closes.
    fn onKeyDown(e_h: Handle) void {
        const m: Handle = js_mark();
        _ = g.input.held_key_codes.call("add", .{wrap(e_h).get("code")});
        js_reset(m);
    }
    fn onKeyUp(e_h: Handle) void {
        const m: Handle = js_mark();
        _ = g.input.held_key_codes.call("delete", .{wrap(e_h).get("code")});
        js_reset(m);
    }
    fn onMouse(e_h: Handle) void {
        const m: Handle = js_mark();
        const e: Value = wrap(e_h);
        g.input.mouse_x_css = @floatCast(js_to_num(e.get("offsetX").h));
        g.input.mouse_y_css = @floatCast(js_to_num(e.get("offsetY").h));
        g.input.mouse_button_bits = @trunc(js_to_num(e.get("buttons").h));
        js_reset(m);
    }

    /// Register key/mouse listeners. `canvas` is the element you blit to (mouse
    /// coords come back canvas-relative). Call once, before the frame loop.
    pub fn attach(canvas: Value) void {
        g.input.held_key_codes = global().get("Set").new(.{});
        g.input.ready = true;
        const win: Value = global();
        _ = win.call("addEventListener", .{ str("keydown"), func(&onKeyDown) });
        _ = win.call("addEventListener", .{ str("keyup"), func(&onKeyUp) });
        _ = canvas.call("addEventListener", .{ str("mousemove"), func(&onMouse) });
        _ = canvas.call("addEventListener", .{ str("mousedown"), func(&onMouse) });
        _ = canvas.call("addEventListener", .{ str("mouseup"), func(&onMouse) });
    }

    // The host-import handlers (wired into env by Site.boot).
    fn keyDownQuery(ptr_h: Handle, len_h: Handle) u32 {
        if (!g.input.ready) {
            return 0;
        }
        return js_truthy(g.input.held_key_codes.call("has", .{moduleStr(ptr_h, len_h)}).h);
    }
    fn mouseXQuery() f32 {
        return g.input.mouse_x_css;
    }
    fn mouseYQuery() f32 {
        return g.input.mouse_y_css;
    }
    fn buttonsQuery() u32 {
        return g.input.mouse_button_bits;
    }
};

/// assets - bytes the module can pull synchronously (see wz_mod.zig's `wzm.asset`).
/// Register each asset once (e.g. in onReady), typically straight from `@embedFile`:
///
///     wz.assets.register("level.dat", @embedFile("level.dat"));
///
/// The bytes are copied into a JS value and keyed by name; the module then reads
/// them with wzm.asset.size/read/load. Because the bytes ride inside the page, this
/// works for the standalone (single-file) build as well as the served one.
pub const assets = struct {
    fn ensure() void {
        if (!g.assets.ready) {
            g.assets.registered_assets = global().get("Map").new(.{});
            g.assets.ready = true;
        }
    }

    /// Register `bytes` under `name`. `bytes` is usually an `@embedFile` result.
    pub fn register(name: []const u8, bytes: []const u8) void {
        ensure();
        const key: Value = .{ .h = js_str(name.ptr, @intCast(name.len)) };
        const val: Value = .{ .h = js_bytes(bytes.ptr, @intCast(bytes.len)) };
        _ = g.assets.registered_assets.call("set", .{ key, val });
    }

    // The host-import handlers (wired into env by Site.boot). The module passes the
    // asset name as (ptr, len) into ITS memory; we decode it, look it up, and (for
    // read) copy the bytes into the module's memory at the destination it gave.
    fn sizeQuery(name_ptr: Handle, name_len: Handle) u32 {
        if (!g.assets.ready) {
            return 0;
        }
        const v: Value = g.assets.registered_assets.call("get", .{moduleStr(name_ptr, name_len)});
        if (v.isNull()) {
            return 0; // unregistered -> 0
        }
        return @trunc(js_to_num(v.get("length").h));
    }
    fn readQuery(
        name_ptr: Handle,
        name_len: Handle,
        dest: Handle,
        cap: Handle,
    ) u32 {
        if (!g.assets.ready) {
            return 0;
        }
        const v: Value = g.assets.registered_assets.call("get", .{moduleStr(name_ptr, name_len)});
        if (v.isNull()) {
            return 0;
        }
        const len: u32 = @trunc(js_to_num(v.get("length").h));
        const capn: u32 = @trunc(js_to_num(cap));
        const n: u32 = if (len < capn) len else capn;
        const destn: u32 = @trunc(js_to_num(dest));
        const mview: Value = global().get("Uint8Array").new(.{g.module.mem.get("buffer")});
        _ = mview.call("set", .{ v.call("subarray", .{ @as(u32, 0), n }), destn });
        return n;
    }
};

/// The WASM-site runtime. Parameterized by two comptime callbacks so every
/// Zig->Zig call is a DIRECT call (the transpiler has no indirect-call support):
///   * `onReady(Wasm)` runs once the module is live - size the canvas, etc.
///   * `onFrame(Wasm)` runs every animation frame - call into WASM, blit.
/// Usage:
///   const App = js.Site(onReady, onFrame);
///   App.boot();
pub fn Site(
    comptime onReady: fn (Wasm) void,
    comptime onFrame: fn (Wasm) void,
    comptime Imports: type,
) type {
    return struct {
        var w: Wasm = undefined;
        var pid: u32 = 0;
        var poll_cb: Value = undefined;
        var frame_cb: Value = undefined;

        /// fetch(url) -> WebAssembly.instantiateStreaming -> (poll until ready) ->
        /// onReady -> start the per-frame loop.
        /// Begin loading the module. The page wrapper decides HOW: a standalone
        /// page sets `window.WASM_BYTES` (a Uint8Array decoded from inlined
        /// base64) -> instantiate from bytes; otherwise `window.WASM_URL` is a
        /// sibling file -> fetch + instantiateStreaming. The module exports its own
        /// memory; the import object holds the `Imports` host fns plus the built-in
        /// `__wz_log` console sink (used only if the module opts into wz_mod).
        pub fn boot() void {
            const wa: Value = global().get("WebAssembly");
            // Build the WASM import object: { env: { <each pub fn in Imports> } }.
            // Each Zig fn is wrapped as a JS callback (`func`); the module calls
            // them by the names declared here, which must match its
            // `extern "env" fn` declarations. (Imports must hold only pub fns.)
            const env: Value = global().get("Object").new(.{});
            inline for (comptime structDecls(Imports)) |d| {
                env.set(d.name, func(&@field(Imports, d.name)));
            }
            // Always provide the module-runtime imports (the console sink and the
            // input pollers). Harmless if unused (an unimported entry is ignored);
            // required the moment a module opts into wz_mod's panic/log/input.
            env.set("__wz_log", func(&hostLog));
            env.set("__wz_key_down", func(&input.keyDownQuery));
            env.set("__wz_mouse_x", func(&input.mouseXQuery));
            env.set("__wz_mouse_y", func(&input.mouseYQuery));
            env.set("__wz_mouse_buttons", func(&input.buttonsQuery));
            env.set("__wz_asset_size", func(&assets.sizeQuery));
            env.set("__wz_asset_read", func(&assets.readQuery));
            const imports: Value = global().get("Object").new(.{});
            imports.set("env", env);
            const bytes: Value = global().get("WASM_BYTES");
            // Branch on a scalar handle (no struct-typed value crosses the if).
            var ph: Handle = 0;
            if (bytes.isNull()) {
                const resp: Value = global().call("fetch", .{global().get("WASM_URL")});
                ph = wa.call("instantiateStreaming", .{ resp, imports }).h;
            } else {
                ph = wa.call("instantiate", .{ bytes, imports }).h;
            }
            pid = js_promise_register(ph);
            poll_cb = func(&poll);
            frame_cb = func(&tick);
            requestAnimationFrame(poll_cb);
        }
        fn poll(_: Handle) void {
            if (js_promise_status(pid) == 0) {
                requestAnimationFrame(poll_cb); // still pending - check next frame
                return;
            }
            const result: Value = wrap(js_promise_take(pid));
            const inst: Value = result.get("instance");
            const exports_val: Value = inst.get("exports");
            w = .{ .instance = inst, .exports = exports_val, .mem = exports_val.get("memory") };
            g.module.mem = w.mem; // share the module's memory with the host import sinks
            g.module.mem_ready = true;
            onReady(w);
            requestAnimationFrame(frame_cb);
        }
        fn tick(_: Handle) void {
            // Open a handle-table scope for the frame: everything interned during
            // onFrame (and the import callbacks WASM invokes) is transient and is
            // reclaimed by js_reset, so a long-running loop never grows __H.
            // Persistent handles (w, frame_cb, and anything onReady stored) were
            // interned before this mark and survive.
            const m: Handle = js_mark();
            onFrame(w);
            requestAnimationFrame(frame_cb);
            js_reset(m);
        }
        // The console sink for the module's panic/std.log (see wz_mod.zig). Wired
        // into the import object below as `env.__wz_log`, so a module that opts in
        // (`pub const panic = wzm.panic; std_options.logFn = wzm.log`) gets its
        // panics and logs in the browser console for free - and a module that opts
        // out simply never imports it. The module passes (level, ptr, len) as
        // numbers; we read that slice of ITS memory as UTF-8 and print by level.
        fn hostLog(
            level_h: Handle,
            ptr_h: Handle,
            len_h: Handle,
        ) void {
            const level: u32 = @trunc(js_to_num(level_h));
            const msg: Value = moduleStr(ptr_h, len_h);
            const c: Value = console();
            switch (level) {
                2 => _ = c.call("error", .{msg}),
                1 => _ = c.call("warn", .{msg}),
                else => _ = c.call("log", .{msg}),
            }
        }
    };
}

// ===========================================================================
// css - type-safe, runtime-mutable styling authored in Zig. Folded in here so
// the bridge reaches it as `js.css.rule(...)` with no extra module to wire.
// (Full design notes are inside the struct.)
// ===========================================================================

// ===========================================================================
// ZIMR BOOT + DOM VERBS (ZIG_BRIDGE_PLAN Phase 2; doctrine D9-D11)
//
// Mechanism only - the PAGE IS DEFINED BY THE APP. start() does exactly:
// feature-check -> requestAdapter -> requestDevice -> instantiate WASM_BYTES
// -> call the app's exported `zimr_page_main()` -> rAF-drive `zimr_frame(t)`.
// The app builds the document (headings, links, iframes, css, and the
// canvases themselves) through the generic "dom" import verbs below; the
// shared GPUDevice serves every canvas the app creates (D11).
// ===========================================================================

// ===========================================================================
// THE ONE GLOBAL - every page-lifetime mutable in the bridge, in one place.
//
// The transpiled JS is single-threaded and has no init-order machinery, so
// page singletons are unavoidable; what IS avoidable is scattering them.
// Sub-structs group by domain; sizes are the working minimum:
//   * scratch.read_staging: descriptor readSlice staging. Phase 3 reads
//     bind-group/pipeline descriptor arrays through it - 64 KiB is the
//     contract ceiling (asserted at the read site).
//   * scratch.fmt: the sequential UI fmt builder (documented non-reentrant).
//   * scratch.call_args: per-call handle marshalling (max arity 16).
// ===========================================================================

// ===========================================================================
// PHASE 3a - the classic zimr wgpu contract (ZIG_BRIDGE_PLAN Phase 3)
//
// Mirrors src/bridge.zig verb-for-verb: u32 handles in one table,
// singleton ids (device == queue == surface == 1), packed (w<<16)|h sizes,
// texture formats as indices into the shared list below, and binary
// descriptor blobs (3c) read from module memory. All verbs use the raw
// numeric ABI (funcNum): params arrive as plain f64 numbers.
// ===========================================================================

// ===========================================================================
// WASI shim - wasm32-wasi REACTOR support for classic zimr apps. Every stub
// mirrors the per-example pages' minimal shim: 0 for success-ish ops, EBADF
// (8) for filesystem ops; random_get is real (crypto over a fresh
// module-memory view); proc_exit paints the self-reporting overlay.
// ===========================================================================

// ===========================================================================
// CLASSIC INPUT WIRING - zimr apps receive input by EXPORTING push
// functions (input_push_mouse_move, zimr_input_push_touch_down, ...) that
// the host calls from DOM events. Conventions mirror the shipped pages:
// coordinates are CSS px relative to the canvas, wheel sends (dx, -dy),
// pointerdown pushes a move first then the button, window-level move/up
// only while dragging, touches by identifier, contextmenu suppressed.
// ===========================================================================
