//! plot_core.zig — machinery shared by implot.zig and implot3d.zig.
//!
//! Depends only on `zm` (zimrmath) and `ui`; knows nothing about either
//! plotting library's internals, so it is safe to import from both and could
//! later move into ui.zig wholesale.
//!
//! What lives here:
//!   · Color           — the canonical concrete color (= zm.Color), plus the
//!                        conversion helpers both libraries need. zm.Color is
//!                        the single pivot between float color math and the
//!                        packed draw-list wire format, so all packing goes
//!                        through it (no hand-rolled bit twiddling).
//!   · colormap key tables — the 16 built-in colormaps' key colors, as packed
//!                        wire-format u32s (byte-identical in both libs before).
//!   · Range           — an [min,max] f32 interval with the common helpers.
//!   · niceNum / orderOfMagnitude — the shared tick-spacing math.
//!
//! What deliberately stays per-library: the Cond/Marker/Scale/Location enums
//! (their backing integer types differ between 2D and 3D, so sharing them
//! would silently change one library's values), and ColormapData (it is wired
//! to each library's allocator-failure + text-buffer plumbing).

const zm = @import("zm");
const float = zm.float;

const floori = zm.floori;
const clamp = zm.clamp;

//=============================================================================
// [SECTION] Color
//=============================================================================

/// The canonical concrete color: zm.Color (`extern struct{r,g,b,a:u8}`).
/// Construct with `Color.rgb/rgba/hex/fromVec/fromHSV`; this is what callers
/// should reach for. The float form below is only for the auto sentinel and
/// blend math inside the libraries.
const Color = zm.Color;
const Vec = zm.Vec;

/// The float color form (`@Vector(4,f32)`, sRGB 0..1, RGBA). Used where a
/// color must carry the "auto" sentinel or be blended in floating point.
const ColorF = Vec;

/// The packed draw-list wire format (0xAABBGGRR == zm.ColorU32 layout).
const ColorU32 = zm.ColorU32;
const Wire = ColorU32;

// ---- constructors (return the concrete Color) ------------------------------

/// Opaque color from 0..255 channels.
pub inline fn rgb(r: u8, g: u8, b: u8) Color {
    return Color.rgb(r, g, b);
}
/// Color from 0..255 channels including alpha.
pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return Color.init(r, g, b, a);
}
/// Color from CSS-order packed hex, 0xRRGGBBAA (e.g. `hex(0xff8800ff)`).
pub inline fn hex(value: u32) Color {
    return Color.hex(value);
}
/// Color from 0..1 sRGB floats.
pub inline fn rgbaF(r: f32, g: f32, b: f32, a: f32) Color {
    return Color.fromFloats(r, g, b, a);
}
/// Color from HSVA, all components 0..1 (hue is a fraction, not degrees).
pub inline fn hsv(h: f32, s: f32, v: f32, a: f32) Color {
    return Color.fromHSV(.{ h, s, v, a });
}

// ---- conversions (the single pivot for packing) ----------------------------

/// Pack a concrete Color to the draw-list wire format.
pub inline fn pack(c: Color) Wire {
    return c.toWire();
}
/// Unpack a wire-format color to a concrete Color.
pub inline fn unpack(w: Wire) Color {
    return Color.fromWire(w);
}
/// Pack a 0..1 sRGB float color (saturating) to the wire format.
pub inline fn packF(v: ColorF) Wire {
    return Color.fromVec(v).toWire();
}

// Common wire constants.
pub const wire_white: Wire = 0xFFFFFFFF;
pub const wire_black: Wire = 0xFF000000;
pub const wire_transparent: Wire = 0x00000000;

//=============================================================================
// [SECTION] Colormap key tables
//
// The 16 built-in colormaps, as packed wire-format key colors. Continuous maps
// are expanded to 255-step lookup tables by each library's ColormapData; the
// raw key colors live here so the data is defined exactly once.
//=============================================================================

/// Packed wire-format opaque color from 0..255 channels (table builder).
inline fn k(r: u8, g: u8, b: u8) Wire {
    return Color.init(r, g, b, 255).toWire();
}

pub const colormap_keys = struct {
    pub const deep = [_]Wire{
        k(76, 114, 176),  k(221, 132, 82),  k(85, 168, 104),  k(196, 78, 82),
        k(129, 114, 179), k(147, 120, 96),  k(218, 139, 195), k(140, 140, 140),
        k(204, 185, 116), k(100, 181, 205),
    };
    pub const dark = [_]Wire{
        k(228, 26, 28),   k(55, 126, 184), k(77, 175, 74), k(152, 78, 163),
        k(255, 127, 0),   k(255, 255, 51), k(166, 86, 40), k(247, 129, 191),
        k(153, 153, 153),
    };
    pub const pastel = [_]Wire{
        k(251, 180, 174), k(179, 205, 227), k(204, 235, 197), k(222, 203, 228),
        k(254, 217, 166), k(255, 255, 204), k(229, 216, 189), k(253, 218, 236),
        k(242, 242, 242),
    };
    pub const paired = [_]Wire{
        k(66, 206, 227),  k(31, 120, 180), k(178, 223, 138), k(51, 160, 44),
        k(251, 154, 153), k(227, 26, 28),  k(253, 191, 111), k(255, 127, 0),
        k(202, 178, 214), k(106, 61, 154), k(255, 255, 153), k(177, 89, 40),
    };
    pub const viridis = [_]Wire{
        k(68, 1, 84),    k(72, 36, 117),  k(65, 68, 135),  k(53, 95, 141),
        k(42, 120, 142), k(33, 145, 140), k(34, 168, 132), k(68, 191, 112),
        k(122, 209, 81), k(189, 223, 38), k(253, 231, 37),
    };
    pub const plasma = [_]Wire{
        k(13, 8, 135),   k(65, 4, 157),   k(106, 0, 168),  k(143, 13, 164),
        k(177, 42, 144), k(204, 71, 120), k(225, 100, 98), k(242, 132, 75),
        k(252, 166, 54), k(252, 206, 37), k(240, 249, 33),
    };
    pub const hot = [_]Wire{
        k(64, 0, 0),     k(128, 0, 0),     k(191, 0, 0),     k(255, 0, 0),
        k(255, 64, 0),   k(255, 128, 0),   k(255, 191, 0),   k(255, 255, 0),
        k(255, 255, 85), k(255, 255, 170), k(255, 255, 255),
    };
    pub const cool = [_]Wire{
        k(0, 255, 255),   k(26, 230, 255),  k(51, 204, 255),  k(77, 179, 255),
        k(102, 153, 255), k(128, 128, 255), k(153, 102, 255), k(179, 77, 255),
        k(204, 51, 255),  k(230, 26, 255),  k(255, 0, 255),
    };
    pub const pink = [_]Wire{
        k(74, 0, 0),      k(123, 66, 66),   k(158, 93, 93),   k(186, 114, 114),
        k(198, 151, 132), k(208, 180, 147), k(218, 206, 161), k(228, 228, 174),
        k(237, 237, 205), k(246, 246, 231), k(255, 255, 255),
    };
    pub const jet = [_]Wire{
        k(0, 0, 170),   k(0, 0, 255),    k(0, 85, 255),   k(0, 170, 255),
        k(0, 255, 255), k(85, 255, 170), k(170, 255, 85), k(255, 255, 0),
        k(255, 170, 0), k(255, 85, 0),   k(255, 0, 0),
    };
    pub const twilight = [_]Wire{
        k(226, 217, 226), k(166, 191, 202), k(109, 144, 192), k(95, 88, 176),
        k(83, 30, 124),   k(47, 20, 54),    k(100, 25, 75),   k(159, 60, 80),
        k(192, 117, 94),  k(208, 179, 158), k(226, 217, 226),
    };
    pub const rdbu = [_]Wire{
        k(103, 0, 31),    k(178, 24, 43),   k(214, 96, 77),   k(244, 165, 130),
        k(253, 219, 199), k(247, 247, 247), k(209, 229, 240), k(146, 197, 222),
        k(67, 147, 195),  k(33, 102, 172),  k(5, 48, 97),
    };
    pub const brbg = [_]Wire{
        k(84, 48, 5),     k(140, 81, 10),   k(191, 129, 45),  k(223, 194, 125),
        k(246, 232, 195), k(245, 245, 245), k(199, 234, 229), k(128, 205, 193),
        k(53, 151, 143),  k(1, 102, 94),    k(0, 60, 48),
    };
    pub const piyg = [_]Wire{
        k(142, 1, 82),    k(197, 27, 125),  k(222, 119, 174), k(241, 182, 218),
        k(253, 224, 239), k(247, 247, 247), k(230, 245, 208), k(184, 225, 134),
        k(127, 188, 65),  k(77, 146, 33),   k(39, 100, 25),
    };
    pub const spectral = [_]Wire{
        k(158, 1, 66),    k(213, 62, 79),   k(244, 109, 67),  k(253, 174, 97),
        k(254, 224, 139), k(255, 255, 191), k(230, 245, 152), k(171, 221, 164),
        k(102, 194, 165), k(50, 136, 189),  k(94, 79, 162),
    };
    pub const greys = [_]Wire{ wire_white, wire_black };
};

//=============================================================================
// [SECTION] Colormap enum + stateless sampling
//
// The 16 built-in colormaps as an enum, plus the sampling math both plotting
// libraries share. plot.zig calls `sampleColormap` directly (stateless,
// built-ins only); plot3d.zig builds its allocator-backed ColormapData on top
// of `sampleKeys`/`lerpWire` so it can also hold runtime-registered maps. The
// data lives once in `colormap_keys`; the math lives once here.
//=============================================================================

/// The 16 built-in colormaps. Discriminants are explicit so the value is a
/// stable index/wire id shared by both libraries (matches ImPlot's order).
pub const Colormap = enum(i32) {
    deep = 0,
    dark = 1,
    pastel = 2,
    paired = 3,
    viridis = 4,
    plasma = 5,
    hot = 6,
    cool = 7,
    pink = 8,
    jet = 9,
    twilight = 10,
    rd_bu = 11,
    br_bg = 12,
    pi_yg = 13,
    spectral = 14,
    greys = 15,
};

/// Qualitative maps pick a discrete key color; continuous maps interpolate.
fn isQualitative(cmap: Colormap) bool {
    return switch (cmap) {
        .deep, .dark, .pastel, .paired => true,
        else => false,
    };
}

/// The packed wire-format key colors backing a built-in colormap.
fn keysOf(cmap: Colormap) []const Wire {
    return switch (cmap) {
        .deep => &colormap_keys.deep,
        .dark => &colormap_keys.dark,
        .pastel => &colormap_keys.pastel,
        .paired => &colormap_keys.paired,
        .viridis => &colormap_keys.viridis,
        .plasma => &colormap_keys.plasma,
        .hot => &colormap_keys.hot,
        .cool => &colormap_keys.cool,
        .pink => &colormap_keys.pink,
        .jet => &colormap_keys.jet,
        .twilight => &colormap_keys.twilight,
        .rd_bu => &colormap_keys.rdbu,
        .br_bg => &colormap_keys.brbg,
        .pi_yg => &colormap_keys.piyg,
        .spectral => &colormap_keys.spectral,
        .greys => &colormap_keys.greys,
    };
}

/// Linearly interpolate two wire-format colors at t in [0,1], in straight sRGB
/// byte space. The single color-blend primitive both libraries reach for
/// (packing goes through `Color`, never hand-rolled bit math).
pub fn lerpWire(a: Wire, b: Wire, t: f32) Wire {
    return pack(Color.lerp(unpack(a), unpack(b), t));
}

/// Continuously sample a list of wire-format key colors at t in [0,1],
/// interpolating between the two adjacent keys.
pub fn sampleKeys(keys: []const Wire, t_in: f32) Wire {
    const t: f32 = clamp(t_in, 0.0, 1.0);
    if (keys.len == 1) {
        return keys[0];
    }
    const n: usize = keys.len - 1;
    const scaled: f32 = t * float(n);
    var i: usize = @floor(scaled);
    if (i >= n) {
        i = n - 1;
    }
    const frac: f32 = scaled - float(i);
    return lerpWire(keys[i], keys[i + 1], frac);
}

/// Stateless sample of a built-in colormap at t in [0,1]. Qualitative maps pick
/// a discrete key; continuous maps interpolate. Returns a concrete Color. This
/// is the shared engine behind plot.zig's public `sampleColormap`; the distinct
/// name keeps it from colliding with plot3d's ctx-bound `sampleColormap`.
pub fn sampleBuiltinColormap(cmap: Colormap, t_in: f32) Color {
    const keys: []const Wire = keysOf(cmap);
    if (keys.len == 0) {
        return unpack(wire_white);
    }
    const t: f32 = clamp(t_in, 0.0, 1.0);
    if (isQualitative(cmap)) {
        var idx: usize = @floor(float(keys.len) * t);
        if (idx >= keys.len) {
            idx = keys.len - 1;
        }
        return unpack(keys[idx]);
    }
    return unpack(sampleKeys(keys, t));
}

//=============================================================================
// [SECTION] Tick math
//=============================================================================

/// Order of magnitude of a value (0 for 0).
pub inline fn orderOfMagnitude(val: f32) i32 {
    return if (val == 0) 0 else floori(i32, @log10(@abs(val)));
}
