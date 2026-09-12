//! zimrnum_ref — regenerate the reference table in the zimrnum tutorial from the source.
//!
//! `src/zimrnum.zig` carries a test that compares the tutorial's reference table against its own
//! public surface and fails the build if either has an entry the other lacks. That test is worth
//! having, but it makes a hand-maintained table of a hundred-plus rows a standing hazard: every
//! new declaration is a build failure until someone types the row correctly.
//!
//!     zig build zimrnum-ref
//!
//! The tool reads every `pub fn` and `pub const` out of the source, pairs each with a note from
//! the table below, and rewrites the rows between the reference table's header and its closing
//! tag. The only way it can now fail is a declaration with no note — which it reports by name.
//!
//! Zig rather than a script, for the reason `doc_sync.zig` states: tooling in this tree is Zig.
//! The notes live in this file rather than beside it because a data file in a second format is a
//! second thing to keep in sync, and this table is only ever read by this program.

const std = @import("std");

const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const source_path: []const u8 = "src/zimrnum.zig";
const doc_path: []const u8 = "src/notes/tutorials/zimrnum-tutorial.html";
/// The sweep: every `Case` names a kernel and calls exactly one `zn.` function, which is how a
/// function's GPU status is derived rather than declared.
const sweep_path: []const u8 = "examples/zimrnum_field/zimrnum_field.zig";

/// The row that opens the reference table. Rows are rewritten between this and the next `</table>`.
const table_header: []const u8 =
    "<tr><th>Declaration</th><th>Signature</th><th>GPU</th><th>Notes</th></tr>";

const Note = struct { name: []const u8, text: []const u8 };

/// One line per public declaration. A name appearing twice in the source — `init` belongs to both
/// `Rng` and `Ctx` — takes one note covering both, because the signature column already
/// distinguishes them.
const notes = [_]Note{
    .{ .name = "Error", .text = "One error set for the whole library." },
    .{ .name = "isFloat", .text = "True for f16, f32, f64." },
    .{ .name = "requireFloat", .text = "Compile-time guard; fails at the call site with the offending type named." },
    .{
        .name = "requireNumeric",
        .text = "Integers welcome. Only where the widening is TESTED at both widths.",
    },
    .{
        .name = "requireInt",
        .text = "Whole numbers only. znum's bitwiseAnd has no guard at all.",
    },
    .{
        .name = "polyakUpdate",
        .text = "Affine, not lerp: `follow = 1` is an exact copy. Not called `tau`.",
    },
    .{
        .name = "cartpoleStep",
        .text = "PURE: state in, next state out. znum mutates and warns you in prose.",
    },
    .{
        .name = "cartpoleStepBatch",
        .text = "A LOOP over the scalar step - one definition, and the GPU twin is free.",
    },
    .{ .name = "cartpoleReset", .text = "Separate from the step, which removes two flags." },
    .{ .name = "CartpoleState", .text = "Four NAMED fields, not four positions in a tensor." },
    .{ .name = "CartpoleStep", .text = "state, reward, failed - not rd[0] and rd[1]." },
    .{ .name = "Push", .text = "left or right. znum decodes `action > 0.5`." },
    .{
        .name = "categorical",
        .text = "One draw per sample. The max is subtracted, so logits of 800 work.",
    },
    .{
        .name = "boundedIndex",
        .text = "Uniform without the modulo bias every tutorial ships.",
    },
    .{ .name = "affine", .text = "a * gain + offset. One function where znum has three." },
    .{
        .name = "divFloor",
        .text = "-7/2 is -4. `div` stays float-only so integers must choose.",
    },
    .{ .name = "divTrunc", .text = "-7/2 is -3. Both are correct; the caller says which." },
    .{ .name = "divCeil", .text = "Rounds up. What you want when sizing a buffer." },
    .{
        .name = "divExact",
        .text = "Refuses to round. @divExact is UNDEFINED when inexact; this errors.",
    },
    .{ .name = "mod", .text = "Sign follows the DIVISOR: -7 mod 3 is 2. Use this to wrap an index." },
    .{
        .name = "logSoftmaxRows",
        .text = "Never forms the softmax: a value 90 below the max gives -90, not -inf.",
    },
    .{
        .name = "compareScalar",
        .text = "One function where znum has six: eq/ne/lt/le/gt/geScalar.",
    },
    .{ .name = "Comparison", .text = "Named, so the call site reads as a sentence." },
    .{
        .name = "logicalAnd",
        .text = "NOT bitwiseAnd: 2 & 1 is 0, logicalAnd(2, 1) is 1.",
    },
    .{ .name = "logicalOr", .text = "One where either is nonzero." },
    .{ .name = "logicalXor", .text = "One where exactly one is nonzero." },
    .{
        .name = "resolveInferredShape",
        .text = "The -1 dimension. Two of them, any other negative, or a non-divisor: error.",
    },
    .{ .name = "swapaxes", .text = "A VIEW - the strides trade places, no data moves." },
    .{
        .name = "stack",
        .text = "A NEW axis, so rank grows. concat grows an EXISTING axis - the usual mixup.",
    },
    .{
        .name = "shiftRows",
        .text = "The vacated rows are MISSING, not zero - zero would read as no change.",
    },
    .{
        .name = "rollingMean",
        .text = "A partial window is MISSING. Averaging what is there looks artificially smooth.",
    },
    .{
        .name = "rfftfreq",
        .text = "What frequency each bin IS. Without it a spectrum is unlabelled numbers.",
    },
    .{
        .name = "trapz",
        .text = "ENDPOINTS count half - they belong to one interval, interiors to two.",
    },
    .{
        .name = "trapzCoords",
        .text = "Uneven spacing. A non-increasing x is refused, not silently negative area.",
    },
    .{
        .name = "PerClass",
        .text = "precision, recall, f1 AND support - support tells a measured 0 from a blank.",
    },
    .{
        .name = "perClassMetrics",
        .text = "Precision is a COLUMN sum, recall a ROW sum. F1 is the harmonic mean.",
    },
    .{
        .name = "histogramEdges",
        .text = "n bins have n+1 edges. The last is set exactly, not computed.",
    },
    .{
        .name = "astype",
        .text = "Truncates toward zero. Out of range is an ERROR: Zig @intFromFloat is UB.",
    },
    .{ .name = "zeros", .text = "alloc leaves GARBAGE - the common case gets a name." },
    .{ .name = "ones", .text = "As zeros, filled with one." },
    .{ .name = "full", .text = "As zeros, filled with a value." },
    .{
        .name = "fullLike",
        .text = "Shaped like another. Writing a shape twice is how two drift apart.",
    },
    .{ .name = "zerosLike", .text = "Shaped like another, zero." },
    .{ .name = "onesLike", .text = "Shaped like another, one." },
    .{ .name = "eye", .text = "Identity, RECTANGULAR allowed - numpy does and it is useful." },
    .{ .name = "EndPoint", .text = "include or exclude. Required: the wrong one is off by one." },
    .{
        .name = "arange",
        .text = "Stop EXCLUDED, as numpy, Python range and Zig 0..n all agree.",
    },
    .{
        .name = "linspace",
        .text = "Endpoint NAMED, and the last value is set exactly rather than computed.",
    },
    .{ .name = "item", .text = "The one value of a one-element tensor. Refuses anything else." },
    .{ .name = "Extreme", .text = "largest or smallest, comptime - one branch, not a test." },
    .{
        .name = "argExtreme",
        .text = "FLAT index over the whole tensor. Ties go to the first, as numpy.",
    },
    .{
        .name = "all",
        .text = "Empty is TRUE - forced by all(a ++ b) == all(a) and all(b).",
    },
    .{ .name = "any", .text = "Empty is FALSE, by the same argument on `or`." },
    .{ .name = "countNonzero", .text = "A usize: a count is not in the tensor units." },
    .{
        .name = "nanSum",
        .text = "A separate NAME, not a flag - sumAll propagating a NaN is useful.",
    },
    .{ .name = "nanMean", .text = "NaN when every element is one. Series returns null." },
    .{ .name = "rem", .text = "Sign follows the DIVIDEND: -7 rem 3 is -1." },
    .{ .name = "bitwiseAnd", .text = "Bit by bit. Integer-only, checked at the front door." },
    .{ .name = "bitwiseOr", .text = "Bit by bit." },
    .{ .name = "bitwiseXor", .text = "Bit by bit." },
    .{
        .name = "bitwiseNot",
        .text = "Flips every bit: ~5 is -6. NOT logicalNot, which asks if it was zero.",
    },
    .{ .name = "logicalNot", .text = "One where the input was zero. znum has only this one." },
    .{
        .name = "shiftLeft",
        .text = "An over-shift is a DomainError, not Zig's undefined behaviour.",
    },
    .{ .name = "shiftRight", .text = "Arithmetic when signed, so -8 >> 1 is -4." },
    .{ .name = "lowest", .text = "The value that loses every >. -inf for floats, minInt for ints." },
    .{ .name = "highest", .text = "The mirror of lowest." },
    .{ .name = "Ddof", .text = "population or sample." },
    .{ .name = "divisor", .text = "Returns null where the divisor is undefined." },
    .{ .name = "approxEqAbs", .text = "Absolute tolerance. NaN equals nothing." },
    .{ .name = "Rng", .text = "Counter-based. A draw is a pure function of (seed, index)." },
    .{ .name = "init", .text = "Rng.init(seed) and Ctx.init(gpa, seed)." },
    .{ .name = "split", .text = "A derived generator from a label." },
    .{ .name = "bits", .text = "Raw 32-bit draw, stream 0." },
    .{ .name = "unitFloat", .text = "[0, 1) with the full mantissa of T." },
    .{ .name = "uniform", .text = "[low, high)." },
    .{ .name = "normal", .text = "Box&ndash;Muller. Its own streams." },
    .{ .name = "intBelow", .text = "[0, bound), unbiased. 0 when bound is 0." },
    .{ .name = "fillUniform", .text = "Indices 0..out.len." },
    .{ .name = "fillNormal", .text = "Indices 0..out.len." },
    .{ .name = "Ctx", .text = "{ gpa, rng } &mdash; what a call carries." },
    .{ .name = "derive", .text = "Same allocator, independent stream." },
    .{ .name = "open", .text = "Caller closes it." },
    .{ .name = "close", .text = "Frees the arena and everything in it. Once." },
    .{ .name = "allocator", .text = "Stable across copies of the scope." },
    .{ .name = "reset", .text = "Frees contents, retains capacity." },
    .{ .name = "max_rank", .text = "6." },
    .{ .name = "Tensor", .text = "A view of T-typed storage. Owns nothing." },
    .{
        .name = "Walk",
        .text = "Every position of a shape, in order. Replaces a five-line pattern written 48 times.",
    },
    .{ .name = "over", .text = "Start a Walk over a shape." },
    .{ .name = "next", .text = "The next position, or null." },
    .{
        .name = "Walk2",
        .text = "Two shapes of equal size stepped together: the ranks may differ.",
    },
    .{ .name = "Pair", .text = "The two positions of one Walk2 step." },
    .{ .name = "alloc", .text = "Dense row-major. The caller frees .data." },
    .{ .name = "fromSlice", .text = "Extents must multiply to exactly data.len." },
    .{ .name = "size", .text = "Total elements addressed." },
    .{ .name = "isContiguous", .text = "Ask before walking memory linearly." },
    .{ .name = "flatIndex", .text = "base + &Sigma; stride&middot;index." },
    .{ .name = "at", .text = "Bounds-checked read." },
    .{
        .name = "offsetOf",
        .text = "No error: for a coordinate whose rank and bounds you already know.",
    },
    .{
        .name = "at2",
        .text = "Rank named, so NO error: the bounds check is Zig's, where Zig puts it.",
    },
    .{ .name = "setAt2", .text = "The mirror of at2." },
    .{ .name = "at1", .text = "Rank-1 read, error-free." },
    .{ .name = "setAt1", .text = "Rank-1 write, error-free." },
    .{ .name = "setAt", .text = "Bounds-checked write." },
    .{ .name = "fill", .text = "Handles strided views, not only dense ones." },
    .{ .name = "reshape", .text = "Contiguous only; same element count." },
    .{ .name = "isAliased", .text = "True when a stretched axis has extent &gt; 1. Blocks writes." },
    .{ .name = "broadcastTo", .text = "Stretches with stride 0. Read-only in practice." },
    .{ .name = "slice", .text = "A window. Shares storage." },
    .{ .name = "permute", .text = "Reorders axes. order must be a permutation." },
    .{ .name = "squeeze", .text = "Removes a size-1 axis." },
    .{ .name = "unsqueeze", .text = "Inserts a size-1 axis." },
    .{ .name = "flatten", .text = "Rank-1 view. Contiguous only." },
    .{ .name = "moveAxis", .text = "The other axes keep their order." },
    .{ .name = "transpose", .text = "Exchanges two axes." },
    .{
        .name = "slice",
        .text = "Differentiable. The backward is a SCATTER: unread rows get zero.",
    },
    .{ .name = "concat", .text = "Differentiable. The backward is the slice, read backwards." },
    .{ .name = "broadcastShape", .text = "The NumPy rule. Returns the rank." },
    .{ .name = "map", .text = "Unary elementwise with a comptime function." },
    .{ .name = "zip", .text = "Binary elementwise. Broadcasts both inputs to out." },
    .{ .name = "add", .text = "" },
    .{ .name = "sub", .text = "" },
    .{ .name = "mul", .text = "Elementwise, not a matrix product." },
    .{ .name = "div", .text = "Float only." },
    .{ .name = "scale", .text = "Runtime factor, so not a zip." },
    .{ .name = "minimum", .text = "min is a reserved word." },
    .{ .name = "maximum", .text = "" },
    .{ .name = "greater", .text = "1 or 0 in T, not a bool tensor." },
    .{ .name = "less", .text = "" },
    .{ .name = "equal", .text = "Exact equality, no built-in epsilon." },
    .{ .name = "clamp", .text = "" },
    .{ .name = "lerp", .text = "Exact at both endpoints." },
    .{ .name = "sqrt", .text = "NaN below zero." },
    .{ .name = "log", .text = "NaN below zero, &minus;inf at zero." },
    .{ .name = "exp", .text = "" },
    .{ .name = "abs", .text = "" },
    .{ .name = "neg", .text = "" },
    .{ .name = "square", .text = "Exact, unlike pow(a,2)." },
    .{ .name = "tanRad", .text = "" },
    .{
        .name = "sinTurns",
        .text = "Argument in TURNS. Every quarter turn exact; whole turns exactly zero.",
    },
    .{ .name = "cosTurns", .text = "As sinTurns, a quarter turn ahead." },
    .{ .name = "tanTurns", .text = "INFINITE at 0.25 and 0.75: in turns the pole is reachable." },
    .{ .name = "asinRad", .text = "CLAMPS outside [-1,1] &mdash; zm's choice. See its note." },
    .{ .name = "acosRad", .text = "Clamps, like asin." },
    .{ .name = "atanRad", .text = "" },
    .{ .name = "sinh", .text = "By identity, so CPU and GPU compute the same expression." },
    .{ .name = "cosh", .text = "" },
    .{ .name = "asinh", .text = "No znum counterpart." },
    .{ .name = "acosh", .text = "NaN below 1. No znum counterpart." },
    .{ .name = "atanh", .text = "NaN outside (-1,1). No znum counterpart." },
    .{ .name = "rsqrt", .text = "NaN below zero." },
    .{ .name = "pow", .text = "exp(b&middot;log a). NaN for a negative base." },
    .{ .name = "exp2", .text = "2&#8319;. Named by the correspondence gate on its first run." },
    .{ .name = "log2", .text = "" },
    .{ .name = "log10", .text = "" },
    .{ .name = "expm1", .text = "exp(x) &minus; 1, without extra precision near zero." },
    .{ .name = "log1p", .text = "log(1 + x), likewise." },
    .{ .name = "cbrt", .text = "Defined for negatives: sign(x)&middot;|x|^(1/3)." },
    .{ .name = "notEqual", .text = "" },
    .{ .name = "greaterEqual", .text = "" },
    .{ .name = "lessEqual", .text = "" },
    .{ .name = "reciprocal", .text = "Infinite at zero on both backends." },
    .{ .name = "floor", .text = "" },
    .{ .name = "ceil", .text = "" },
    .{ .name = "trunc", .text = "Toward zero." },
    .{ .name = "round", .text = "Half away from zero." },
    .{ .name = "sign", .text = "Zero maps to zero." },
    .{ .name = "sinRad", .text = "" },
    .{ .name = "cosRad", .text = "" },
    .{ .name = "atan2Rad", .text = "Argument order is (y, x)." },
    .{ .name = "hypot", .text = "" },
    .{ .name = "relu", .text = "" },
    .{ .name = "sigmoid", .text = "" },
    .{ .name = "tanh", .text = "" },
    .{ .name = "gelu", .text = "tanh approximation." },
    .{
        .name = "exp",
        .text = "On the tape. Unlocks compositions, but see softplus for one it cannot.",
    },
    .{ .name = "log", .text = "On the tape. The backward needs the INPUT, not the output." },
    .{
        .name = "softplus",
        .text = "Its OWN node: log(1+exp(x)) overflows at x=89 in f32. Backward is sigmoid.",
    },
    .{
        .name = "elu",
        .text = "A real node: a branch is not a composition. Backward reads the INPUT.",
    },
    .{ .name = "mish", .text = "x * tanh(softplus(x)) - a composition once softplus is a node." },
    .{ .name = "softplus", .text = "Returns x above 20, on both backends." },
    .{ .name = "silu", .text = "x&middot;sigmoid(x), also called swish." },
    .{ .name = "leakyRelu", .text = "The slope has no default." },
    .{ .name = "elu", .text = "Continuous at zero for any alpha." },
    .{ .name = "reluGrad", .text = "Takes the forward input." },
    .{ .name = "sigmoidGrad", .text = "Takes the forward output." },
    .{ .name = "tanhGrad", .text = "Takes the forward output." },
    .{ .name = "sgdStep", .text = "Pass weight as out for in place." },
    .{ .name = "sgdMomentum", .text = "velocity updated in place. momentum 0 equals sgdStep." },
    .{
        .name = "adamStep",
        .text = "moment and velocity updated in place. step is 1-based, for the bias correction.",
    },
    .{ .name = "adamWStep", .text = "Decay applied to the WEIGHT, not the gradient." },
    .{ .name = "rmspropStep", .text = "Adam without the first moment or bias correction." },
    .{ .name = "adagradStep", .text = "Never forgets, so the rate only shrinks." },
    .{ .name = "clipByValue", .text = "Elementwise, so it CHANGES direction. See clipByNorm." },
    .{ .name = "cosineLearningRate", .text = "base down to lowest, steepest in the middle." },
    .{ .name = "warmupLearningRate", .text = "Linear ramp. 0 at step 0, base at step warmup." },
    .{ .name = "stepLearningRate", .text = "A staircase: flat, then a drop." },
    .{ .name = "exponentialLearningRate", .text = "base * exp(-decay * step)." },
    .{ .name = "Adam", .text = "Hyperparameters, defaulting to the paper's values." },
    .{ .name = "clipByNorm", .text = "Scales the whole tensor. Returns the norm before clipping." },
    .{ .name = "gradient", .text = "Central inside, one-sided at the ends." },
    .{ .name = "trapezoid", .text = "Exact for any straight line." },
    .{ .name = "interp", .text = "Clamps outside the range rather than extrapolating." },
    .{ .name = "ComplexNumber", .text = "extern, so an array is interleaved re/im." },
    .{ .name = "magnitude", .text = "" },
    .{ .name = "dft", .text = "O(n&sup2;), any length. The reference `fft` is checked against." },
    .{ .name = "fft", .text = "Radix-2, in place, power-of-two. 630&times; faster than dft at 4096." },
    .{ .name = "ifft", .text = "The whole 1/n lives here." },
    .{ .name = "fftFreq", .text = "Second half is negative frequencies." },
    .{
        .name = "rfft",
        .text = "Real input, n/2 + 1 bins. Half the transform, not a full one halved.",
    },
    .{ .name = "ConvMode", .text = "full, same, valid. Each is a window onto full." },
    .{ .name = "outputLen", .text = "Outputs a mode produces. `length` is reserved." },
    .{ .name = "convolve", .text = "Flips the kernel." },
    .{ .name = "correlate", .text = "Does not flip the kernel." },
    .{ .name = "magic", .text = "Six bytes. A wrong file is refused, not misread." },
    .{ .name = "format_version", .text = "Bumped when a layout change would be misread, not rejected." },
    .{ .name = "DType", .text = "One byte. An f32 file read as f64 is refused." },
    .{ .name = "of", .text = "The tag for a float type." },
    .{ .name = "byteWidth", .text = "Derived from the tag: 1 &lt;&lt; (tag &amp; 0xf)." },
    .{
        .name = "Categorical",
        .text = "A TYPE so sample, logProb and entropy share one normalisation.",
    },
    .{
        .name = "DiagGaussian",
        .text = "log_std, not std: exp makes it positive free, and a clamp would zero its gradient.",
    },
    .{
        .name = "logProb",
        .text = "Via logSoftmax, not log(softmax) - a confident policy underflows the naive form.",
    },
    .{
        .name = "entropy",
        .text = "An exploration bonus. A Gaussian's does not depend on its mean.",
    },
    .{
        .name = "SquashedGaussian",
        .text = "tanh into (-1,1). The correction via softplus, or it is -inf when saturated.",
    },
    .{ .name = "log_std_min", .text = "Clamped in BOTH sample and logProb, from one constant." },
    .{
        .name = "CriticAggregate",
        .text = "One knob covers TD3, SAC, DroQ, REDQ and CrossQ. A SLICE, not a pair.",
    },
    .{
        .name = "aggregateCritics",
        .text = "A minimum of unbiased estimates is biased DOWN, and that is deliberate.",
    },
    .{
        .name = "randomSubset",
        .text = "REDQ's M of N, re-drawn so the pessimism is not systematic.",
    },
    .{
        .name = "sacTarget",
        .text = "The entropy term is what makes it SAC and not TD3.",
    },
    .{ .name = "alpha", .text = "exp(log_alpha) - the coefficient itself." },
    .{
        .name = "Temperature",
        .text = "log_alpha is the parameter: a clamp on alpha zeroes its own gradient.",
    },
    .{ .name = "log_std_max", .text = "As log_std_min. SAC's usual values." },
    .{ .name = "DqnKind", .text = "double fixes the max-of-noisy-estimates upward bias." },
    .{ .name = "Transition", .text = "One step. terminal means no future to bootstrap." },
    .{
        .name = "dqnTarget",
        .text = "Online SELECTS, target EVALUATES - independent errors, so no bias feedback.",
    },
    .{
        .name = "explainedVariance",
        .text = "A critic predicting the mean has a small loss and explains NOTHING.",
    },
    .{
        .name = "PpoConfig",
        .text = "normalize_advantage ON by default - without it one rate does not transfer.",
    },
    .{
        .name = "PpoStats",
        .text = "clip_fraction and approx_kl are how you know it works. The loss alone is not.",
    },
    .{
        .name = "ppoObjective",
        .text = "KL via exp(r)-1-r, which is NON-NEGATIVE. The cheap estimator can go below 0.",
    },
    .{
        .name = "RolloutStep",
        .text = "terminal kills the BOOTSTRAP; episode_end kills the TRACE. Not one flag.",
    },
    .{
        .name = "gae",
        .text = "lambda 0 is the one-step error, 1 is the full return. Runs backward.",
    },
    .{
        .name = "clipGradNorm",
        .text = "ONE norm over all parameters - per-tensor clipping changes the DIRECTION.",
    },
    .{
        .name = "saveParameters",
        .text = "A trained network to bytes. Named p0, p1 - so the ORDER must match.",
    },
    .{
        .name = "loadParameters",
        .text = "Back into a network of the same shape. loadTensors refuses a mismatch.",
    },
    .{ .name = "NamedTensor", .text = "A name, a shape, and erased bytes." },
    .{ .name = "saveTensors", .text = "Little-endian, explicit widths. Contiguous only." },
    .{ .name = "saveNpy", .text = "numpy's format, so other tools can read it." },
    .{ .name = "loadNpy", .text = "Refuses big-endian and Fortran order rather than mis-reading." },
    .{ .name = "readNpyHeader", .text = "Shape, width and where the data starts." },
    .{ .name = "NpyHeader", .text = "What a .npy header said." },
    .{ .name = "loadTensors", .text = "Into tensors the caller holds, matched by name." },
    .{
        .name = "generalizedAdvantage",
        .text = "terminal stops the bootstrap; episode_end resets the running sum.",
    },
    .{ .name = "discountedReturns", .text = "GAE with lambda 1 and zero values." },
    .{
        .name = "silu",
        .text = "x * sigmoid(x) on the tape. The tensor version had no gradient.",
    },
    .{
        .name = "gelu",
        .text = "The tanh form every transformer runs, not the erf definition.",
    },
    .{
        .name = "glu",
        .text = "slice * sigmoid(slice). No backward: znum hand-derives one.",
    },
    .{ .name = "swiglu", .text = "The same, gated by SiLU. Every recent transformer uses it." },
    .{ .name = "Gate", .text = "sigmoid or silu, chosen at comptime." },
    .{
        .name = "ppoClipLoss",
        .text = "PPO as a LOSS. The clip acts in the backward: a clipped step gets ZERO.",
    },
    .{ .name = "constants", .text = "Node data a backward needs that are not Vars." },
    .{ .name = "normalizeAdvantages", .text = "In place. Epsilon, not DomainError, for a constant batch." },
    .{ .name = "ppoClipObjective", .text = "An objective to MAXIMISE. min(ratio·A, clip(ratio)·A)." },
    .{ .name = "entropyRows", .text = "A zero probability contributes zero." },
    .{ .name = "ReplayBuffer", .text = "A ring: the oldest transition is overwritten." },
    .{ .name = "push", .text = "" },
    .{ .name = "sample", .text = "Uniform with replacement. Addressable by (rng, index)." },
    .{ .name = "conv2d", .text = "Cross-correlation with stride and zero padding, per axis. Rank 2." },
    .{ .name = "maxPool2d", .text = "Non-overlapping square windows. Partial trailing window dropped." },
    .{ .name = "avgPool2d", .text = "" },
    .{ .name = "gatherRows", .text = "out[i] = table[rows[i]]." },
    .{ .name = "scatterAddRows", .text = "table[rows[i]] += source[i]. Repeats accumulate." },
    .{ .name = "InitScheme", .text = "xavier or he. Named once, used by every layer." },
    .{ .name = "Conv2d", .text = "Learned kernel and scalar bias. Dense's template." },
    .{ .name = "Embedding", .text = "A table of learned rows, indexed by whole numbers." },
    .{ .name = "conv2d", .text = "On the graph. Both gradients from one loop nest." },
    .{ .name = "embedding", .text = "On the graph. Gradient is a scatter-add." },
    .{ .name = "initXavier", .text = "Uniform &plusmn;&radic;(6/(in+out)). For tanh and sigmoid." },
    .{ .name = "initHe", .text = "Normal, deviation &radic;(2/in). The 2 is relu's discarded half." },
    .{ .name = "Dense", .text = "Owns its weights. Holds no Var, so it can attach to any graph." },
    .{
        .name = "Chain",
        .text = "Layers in order, parameters COLLECTED - a missing one never trains.",
    },
    .{
        .name = "BatchNorm",
        .text = "The mode is an ARGUMENT, not a field - it cannot be forgotten.",
    },
    .{
        .name = "LstmCell",
        .text = "The forget bias starts at ONE: 44x the memory after ten steps.",
    },
    .{
        .name = "Attention",
        .text = "Whether it can see the future is an ARGUMENT. Scale from the shape.",
    },
    .{
        .name = "FeedForward",
        .text = "relu or swiglu. Chosen at init: the gate changes widen's SHAPE.",
    },
    .{
        .name = "TransformerBlock",
        .text = "PRE-norm: the residual path is clear, so no warmup is needed.",
    },
    .{ .name = "Look", .text = "everywhere or backward_only. Required at every call." },
    .{ .name = "Gate", .text = "One gate reads both the input and the previous hidden state." },
    .{ .name = "Stepped", .text = "hidden AND cell - two states, and confusing them is the classic bug." },
    .{ .name = "step", .text = "One timestep, built from tape ops so the gradient is free." },
    .{ .name = "Use", .text = "training or inference. Required at every attach." },
    .{ .name = "observe", .text = "Moves the running statistics. Separate, because attach only reads." },
    .{ .name = "Parameters", .text = "Fixed array, sized at comptime from the layer list." },
    .{ .name = "Run", .text = "What Chain.attach returns: the output and every parameter." },
    .{ .name = "Attached", .text = "What attach returns: the output plus both parameter handles." },
    .{ .name = "attach", .text = "Records input @ weight + bias onto a graph." },
    .{ .name = "Optimizer", .text = "Owns per-parameter state. One type, three algorithms." },
    .{ .name = "Kind", .text = "sgd, momentum, or adam — chosen at one call site." },
    .{ .name = "step", .text = "One update for every bound parameter, from the last backward." },
    .{ .name = "Var", .text = "A handle into a Graph. An index, not a pointer." },
    .{ .name = "Graph", .text = "Reverse-mode autograd. Eager forward, recorded backward." },
    .{ .name = "parameter", .text = "A value the graph differentiates with respect to." },
    .{ .name = "constant", .text = "A fixed value; accumulates no gradient." },
    .{ .name = "valueOf", .text = "The tensor behind a Var." },
    .{ .name = "gradOf", .text = "DomainError for a constant." },
    .{ .name = "backward", .text = "Seeds 1 into a single-element value and walks the tape back." },
    .{ .name = "recompute", .text = "Replays the tape forward. Leaves keep whatever was written." },
    .{ .name = "crossEntropy", .text = "Labels are a []usize, not a Var: they have no gradient." },
    .{ .name = "dropout", .text = "Inverted. Mask drawn once and stored; see resampleDropout." },
    .{ .name = "resampleDropout", .text = "Fresh masks for every dropout node. Once per step." },
    .{
        .name = "checkGradient",
        .text = "Worst gap against a central finite difference. Restores the model.",
    },
    .{ .name = "CompensatedSum", .text = "Neumaier accumulator. Every sum in the library goes through it." },
    .{ .name = "add", .text = "" },
    .{ .name = "value", .text = "total + compensation." },
    .{ .name = "sumAll", .text = "Compensated (Neumaier)." },
    .{ .name = "sumAllFast", .text = "Pairwise. Faster, wrong under cancellation." },
    .{ .name = "meanAll", .text = "DomainError when empty." },
    .{ .name = "minAll", .text = "NaN is not ordered." },
    .{ .name = "maxAll", .text = "NaN is not ordered." },
    .{ .name = "sumAxis", .text = "The output rank is one less." },
    .{ .name = "meanAxis", .text = "" },
    .{ .name = "maxAxis", .text = "NaN never wins." },
    .{ .name = "minAxis", .text = "" },
    .{ .name = "prodAxis", .text = "" },
    .{ .name = "varianceAxis", .text = "Two-pass. ddof selects the divisor." },
    .{ .name = "prodAll", .text = "" },
    .{ .name = "cumsum", .text = "Along the last axis. Rank 1 or 2." },
    .{ .name = "cumprod", .text = "Running product along the last axis." },
    .{ .name = "cummin", .text = "Running minimum." },
    .{ .name = "cummax", .text = "Running maximum." },
    .{ .name = "diff", .text = "First position is NaN; the LENGTH IS KEPT so it still lines up." },
    .{ .name = "pctChange", .text = "As diff, and NaN where the previous value is zero." },
    .{ .name = "argmaxAxis", .text = "Index along an axis, as a float. NaN never wins." },
    .{ .name = "argminAxis", .text = "Ties go to the first." },
    .{ .name = "anyNonzero", .text = "" },
    .{ .name = "allNonzero", .text = "True for an empty tensor." },
    .{ .name = "where", .text = "mask, a, b all broadcast to out." },
    .{ .name = "argminAll", .text = "Ties to the first. NaN never wins." },
    .{ .name = "flip", .text = "Reverses one axis." },
    .{ .name = "roll", .text = "out[i] = a[(i - shift) mod n]. Positive moves forward." },
    .{ .name = "nonzero", .text = "Flat positions. Returns the count." },
    .{ .name = "booleanMask", .text = "The values at those positions." },
    .{ .name = "bincount", .text = "Out of range is an error, not a silent drop." },
    .{ .name = "sort", .text = "Ascending, into a caller-supplied slice." },
    .{ .name = "unique", .text = "Ascending, not first-seen." },
    .{ .name = "argsort", .text = "Rank 1, ascending, stable. Indices into a []usize." },
    .{ .name = "matmul", .text = "Rank 2. Compensated inner sum." },
    .{ .name = "softmaxRows", .text = "Rank 2. The row maximum is subtracted." },
    .{
        .name = "logSumExp",
        .text = "Subtracts the max first, so exp cannot overflow. Direct: inf. This: finite.",
    },
    .{ .name = "logSumExpAxis", .text = "Per row, so one saturating row does not affect its neighbours." },
    .{ .name = "stdDevAxis", .text = "The square root of varianceAxis, without a second pass." },
    .{
        .name = "determinant",
        .text = "Pivot sign times the diagonal. OVERWRITES `a`, as lu does.",
    },
    .{ .name = "layerNormRows", .text = "Rank 2, population variance, epsilon is a parameter." },
    .{
        .name = "layerNormRowsBackward",
        .text = "Every element of a row appears in every other element's gradient.",
    },
    .{ .name = "mseLoss", .text = "Returns a scalar. Shapes must match exactly." },
    .{ .name = "maeLoss", .text = "An outlier contributes its distance, not its square." },
    .{ .name = "huberLoss", .text = "Squared below delta, linear above. Slopes meet at the join." },
    .{
        .name = "binaryCrossEntropyFromLogits",
        .text = "Takes LOGITS. Finite at &plusmn;800, where the sigmoid form is not.",
    },
    .{ .name = "klDivergenceRows", .text = "sum p&middot;log(p/q). Not symmetric." },
    .{ .name = "argmaxAll", .text = "Flat index. Ties to the first; NaN never wins." },
    .{ .name = "argmaxRows", .text = "One column index per row, into a []usize." },
    .{ .name = "oneHotRows", .text = "Zeroes out first." },
    .{
        .name = "crossEntropyRows",
        .text = "Takes LOGITS. logsumexp form, finite for every finite input.",
    },
    .{ .name = "crossEntropyRowsGrad", .text = "softmax &minus; onehot, over the row count." },
    .{ .name = "accuracy", .text = "Fraction of rows whose largest logit is at the target." },
    .{ .name = "confusionMatrix", .text = "True DOWN, predicted ACROSS." },
    .{ .name = "ClassScore", .text = "Carries flags saying which zeros are undefined." },
    .{ .name = "classScore", .text = "Precision, recall, F1 for one class." },
    .{ .name = "macroF1", .text = "Unweighted, so a rare class counts as much as a common one." },
    .{ .name = "r2Score", .text = "CAN BE NEGATIVE. Worse than the mean is information." },
    .{ .name = "cosineSimilarity", .text = "DomainError on a zero vector, not 0." },
    .{ .name = "hingeLoss", .text = "Margin 1: correct but close still costs." },
    .{ .name = "materialise", .text = "Densifies any view." },
    .{ .name = "concat", .text = "Extents must match off the join axis." },
    .{ .name = "tile", .text = "Whole multiples only." },
    .{
        .name = "meshGrid",
        .text = "Two coordinate grids from two axes. Outputs are NAMED, not a [2]Tensor.",
    },
    .{
        .name = "repeatEach",
        .text = "[1,2,3] -> [1,1,2,2,3,3]. `tile` repeats the WHOLE tensor instead.",
    },
    .{ .name = "moveAxis", .text = "One axis travels, the rest close the gap. A view." },
    .{ .name = "take", .text = "Gathers named positions." },
    .{ .name = "quantile", .text = "Linear interpolation at q&middot;(n&minus;1), as numpy does." },
    .{ .name = "quantileSorted", .text = "For several quantiles of one sample." },
    .{ .name = "median", .text = "quantile(0.5)." },
    .{ .name = "skew", .text = "Population form. Zero for anything symmetric." },
    .{ .name = "kurtosis", .text = "EXCESS: three subtracted, so normal reads as zero." },
    .{ .name = "geoMean", .text = "exp(mean(log x)). The product form overflows." },
    .{ .name = "harmMean", .text = "The right average for rates." },
    .{ .name = "histogram", .text = "Equal-width bins, top edge closed." },
    .{ .name = "variance", .text = "Two passes. ddof selects the divisor." },
    .{ .name = "stdDev", .text = "" },
    .{ .name = "rootMeanSquare", .text = "" },
    .{ .name = "meanAbsDev", .text = "Mean |x &minus; mean|." },
    .{
        .name = "correlationMatrix",
        .text = "Every pair. The diagonal is ASSIGNED 1, not computed.",
    },
    .{
        .name = "coefficientOfVariation",
        .text = "Deviation as a fraction of the mean. A zero mean has no scale: DomainError.",
    },
    .{
        .name = "medianAbsDev",
        .text = "The robust one. A separate name from meanAbsDev rather than a flag.",
    },
    .{ .name = "standardError", .text = "Deviation shrunk by sqrt(N)." },
    .{ .name = "mode", .text = "Most common value; ties go to the SMALLEST, reproducibly." },
    .{
        .name = "fromTensorMarkingNaN",
        .text = "NaN in, honest mask out. Allocates only if something IS missing.",
    },
    .{ .name = "deinit", .text = "Frees the values and the mask, if there is one." },
    .{ .name = "len", .text = "Entries, present or not." },
    .{ .name = "fillMissing", .text = "A constant into every gap. The mask is then freed." },
    .{
        .name = "fillForward",
        .text = "Last real value forward. A LEADING gap stays missing - nothing to borrow.",
    },
    .{ .name = "fillBackward", .text = "The mirror. A trailing gap stays missing." },
    .{
        .name = "dropMissing",
        .text = "A NEW shorter column: dropping rows changes the length.",
    },
    .{ .name = "isValid", .text = "No mask means everything is present." },
    .{ .name = "countValid", .text = "How many entries are really there." },
    .{
        .name = "sumValid",
        .text = "SKIPS the gaps. Raw sumAll adds zero for an integer gap and looks fine.",
    },
    .{ .name = "meanValid", .text = "Null, not NaN, when nothing is present." },
    .{
        .name = "Column",
        .text = "A tagged union. `inline else` stamps one arm per type, not six copies.",
    },
    .{
        .name = "Frame",
        .text = "Named columns, all one height. A ragged table is refused at the door.",
    },
    .{ .name = "name", .text = "The column name, whatever its element type." },
    .{ .name = "width", .text = "How many columns." },
    .{ .name = "height", .text = "How many rows - every column agrees." },
    .{
        .name = "addColumn",
        .text = "Refuses a wrong height AND a duplicate name: a lookup must not be ambiguous.",
    },
    .{ .name = "find", .text = "Index of a named column, or null." },
    .{ .name = "rename", .text = "Refuses a collision; renaming to itself is a no-op." },
    .{
        .name = "dropColumn",
        .text = "Order preserved - swapping the last into the hole would reorder silently.",
    },
    .{ .name = "columnNamed", .text = "The column itself, or null." },
    .{
        .name = "Series",
        .text = "A named column. `valid == null` means all present - no mask, no cost.",
    },
    .{
        .name = "takeRows",
        .text = "ONE gather: filter, sort, sample and a join's assembly are index lists.",
    },
    .{
        .name = "firstRows",
        .text = "pandas' head. Not called `head` - that shadows three locals here.",
    },
    .{ .name = "JoinHow", .text = "inner, left, right, outer - znum's four with its meanings." },
    .{
        .name = "RowPair",
        .text = "One joined row. `no_row` beats ?usize: dense array, tight loop.",
    },
    .{ .name = "no_row", .text = "The sentinel: nothing on this side." },
    .{
        .name = "joinRows",
        .text = "The PAIRING without the gather. A missing key never matches, not even another.",
    },
    .{
        .name = "Summary",
        .text = "NAMED fields. znum returns [8]f64 and slot 3 being min is not a type.",
    },
    .{
        .name = "describe",
        .text = "The pandas eight, skipping gaps. Null when nothing is present.",
    },
    .{
        .name = "Aggregate",
        .text = "Seven that fit one pass. No variance or median stub that always errors.",
    },
    .{ .name = "needsFloat", .text = "Only mean does. znum floats all ten." },
    .{
        .name = "aggregate",
        .text = "The TYPE survives: sum of i32 is i32. A mean of i32 is a COMPILE error.",
    },
    .{
        .name = "GroupBy",
        .text = "order + starts with a TRAILING SENTINEL, so the last group is not special.",
    },
    .{
        .name = "groupBy",
        .text = "Sorted keys, so the grouping does not depend on row order. Gaps get a group.",
    },
    .{ .name = "groupCount", .text = "starts.len - 1, thanks to the sentinel." },
    .{ .name = "rows", .text = "The row indices in one group." },
    .{
        .name = "factorize",
        .text = "Two orders, caller picks. Both defensible; the wrong one is silent.",
    },
    .{ .name = "CodeOrder", .text = "first_seen like pandas, or sorted. Required." },
    .{
        .name = "valueCounts",
        .text = "Distinct values and frequencies, most common first. Returns the count.",
    },
    .{ .name = "stdErr", .text = "Sample deviation over &radic;n." },
    .{ .name = "zscore", .text = "Sample deviation." },
    .{ .name = "covariance", .text = "" },
    .{ .name = "correlation", .text = "Not clamped to [&minus;1, 1]." },
    .{ .name = "minMaxScale", .text = "DomainError on a constant tensor." },
    .{ .name = "dotAll", .text = "Sizes must match, shapes need not. Compensated." },
    .{ .name = "trace", .text = "Square, rank 2." },
    .{ .name = "norm", .text = "Frobenius. Scaled, so it does not overflow." },
    .{ .name = "lu", .text = "In place. Partial pivoting. Returns the permutation sign." },
    .{
        .name = "solve",
        .text = "Overwrites a with its factors and b with x. Several right-hand sides at once.",
    },
    .{ .name = "determinantLu", .text = "Overwrites a. Returns 0 for a singular matrix." },
    .{
        .name = "pinv",
        .text = "Via svd. Rank cutoff is rcond &middot; sigma_max, so it is scale-free.",
    },
    .{ .name = "inverse", .text = "By solving against the identity. Prefer solve." },
    .{
        .name = "svd",
        .text = "One-sided Jacobi. Never forms a&#7488;a, so small singular values survive.",
    },
    .{ .name = "matmulNT", .text = "a &middot; b&#7488;, without materialising the transpose." },
    .{ .name = "matmulTN", .text = "a&#7488; &middot; b." },
    .{ .name = "bmm", .text = "Batched: (batch,m,k) @ (batch,k,n)." },
    .{ .name = "tensordot", .text = "The general product. matmul and dot are special cases." },
    .{
        .name = "einsum",
        .text = "Comptime spec, so a malformed one is a COMPILE error naming the problem.",
    },
    .{
        .name = "Named",
        .text = "Axis names in the TYPE. axis(\"width\") is comptime; a typo is a compile error.",
    },
    .{ .name = "namedMatmul", .text = "The contracted axes must be the SAME axis, not just the same length." },
    .{ .name = "axis_names", .text = "The axis names of a Named, in order." },
    .{ .name = "axis", .text = "Comptime index of a named axis." },
    .{ .name = "extent", .text = "The length of a named axis." },
    .{ .name = "transposed", .text = "Swaps two axes AND their names." },
    .{ .name = "sumAxis", .text = "" },
    .{ .name = "meanAxis", .text = "" },
    .{ .name = "maxAxis", .text = "" },
    .{ .name = "window", .text = "A mini-batch: same type back, so nothing downstream changes." },
    .{ .name = "outer", .text = "out[i][j] = a[i] * b[j]." },
    .{ .name = "diagonal", .text = "Rectangular too: min(rows, cols) entries." },
    .{ .name = "triangle", .text = "One triangle kept, the other zeroed." },
    .{ .name = "conditionNumber", .text = "sigma_max/sigma_min. Infinite when singular." },
    .{ .name = "eigvalsSymmetric", .text = "Ascending, without keeping the vectors." },
    .{ .name = "Triangle", .text = "upper or lower." },
    .{ .name = "solveTriangular", .text = "By substitution. DomainError on a zero diagonal." },
    .{
        .name = "lstsq",
        .text = "By QR. The normal equations square the condition number; this does not.",
    },
    .{
        .name = "eigh",
        .text = "Symmetric, Jacobi. Convergence relative to the norm, so scale-free.",
    },
    .{
        .name = "qr",
        .text = "Householder. Orthogonality holds at 4e-16 where Gram-Schmidt reaches 1.8e-4.",
    },
    .{
        .name = "cholesky",
        .text = "Lower-triangular L with L&middot;L&#7488; = a. DomainError when not positive-definite.",
    },
};

fn noteFor(name: []const u8) ?[]const u8 {
    for (notes) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.text;
        }
    }
    return null;
}

/// Append `text` with the three characters that would otherwise be markup escaped.
fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, c),
        }
    }
}

/// ── ★★★ GPU STATUS IS DERIVED FROM THE SWEEP, NOT DECLARED IN THE SOURCE ──
///
/// Every sweep `Case` names its kernel in `.entry` and calls one `zn.` function in its `cpu`
/// body. Scanning those pairs answers "which functions have a kernel verified against them on a
/// device" from the one place that verification actually happens. A tag in the source would be a
/// second statement of the same fact, and the two would drift.
///
/// Returns the kernel names for `name`, comma-separated, or null. Up to four kernels may check
/// one function (`add` has `add` and `bcast_add`; `matmul` has three).
fn kernelsFor(gpa: Allocator, sweep: []const u8, name: []const u8) !?[]const u8 {
    var found: std.ArrayList(u8) = .empty;
    var scan: usize = 0;
    const entry_tag: []const u8 = ".entry = \"";
    while (std.mem.indexOfPos(u8, sweep, scan, entry_tag)) |hit| {
        const start: usize = hit + entry_tag.len;
        const end: usize = std.mem.indexOfScalarPos(u8, sweep, start, '"') orelse break;
        const kernel: []const u8 = sweep[start..end];
        // The cpu body follows within a few hundred bytes; the first `zn.NAME(` in it is the
        // function this row checks.
        const window_end: usize = @min(sweep.len, end + 900);
        const window: []const u8 = sweep[end..window_end];
        if (std.mem.indexOf(u8, window, "zn.")) |z| {
            const fn_start: usize = z + 3;
            var fn_end: usize = fn_start;
            while (fn_end < window.len and
                (std.ascii.isAlphanumeric(window[fn_end]) or window[fn_end] == '_'))
            {
                fn_end += 1;
            }
            if (std.mem.eql(u8, window[fn_start..fn_end], name)) {
                if (found.items.len > 0) {
                    try found.appendSlice(gpa, ", ");
                }
                try found.appendSlice(gpa, kernel);
            }
        }
        scan = end;
    }
    return if (found.items.len == 0) null else found.items;
}

/// Wrap every `<pre><code>` example in the prose with the source of the functions it names.
///
/// ── ★★★ THE PLACEMENT IS DERIVED, NOT MARKED ──
///
/// Every example in the tutorial already names the functions it demonstrates — `zn.sqrt(...)`,
/// `zn.qr(...)`. So the generator reads the example, collects those names, and emits a fold for
/// each **immediately after the example**. No markers to place, none to keep matched, and none to
/// go stale when prose moves: the fold follows the example that earned it because it is derived
/// from the example's own text.
///
/// ★★ THE EXAMPLES THEMSELVES ARE NOT TOUCHED. They stay exactly as written and stay visible —
/// the folds are added after them, collapsed, so the page reads as it did.
///
/// ★ Idempotent: any previously generated block is stripped before the new ones are written, so
/// running the tool twice gives the same file. A generator that appends is a generator that grows
/// its output every build.
fn insertSourceFolds(
    gpa: Allocator,
    doc: []const u8,
    decls: []const Extract,
    emitted: *usize,
) ![]u8 {
    const open_tag: []const u8 = "<div class=\"zn-source\">";
    const close_tag: []const u8 = "</div><!--/zn-source-->";

    // Strip what a previous run wrote.
    var stripped: std.ArrayList(u8) = .empty;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, doc, scan, open_tag)) |hit| {
        const end: usize = std.mem.indexOfPos(u8, doc, hit, close_tag) orelse {
            std.process.fatal("zimrnum_ref: a generated source block is not closed", .{});
        };
        // ★ Back up over the newline emitted before the block, or each run leaves one more
        // behind and the file grows by 52 blank lines a build. Caught by diffing two runs, which
        // is the only check that can see it — a generator that is nearly idempotent looks
        // idempotent until someone builds twice.
        var keep_to: usize = hit;
        if (keep_to > 0 and doc[keep_to - 1] == '\n') {
            keep_to -= 1;
        }
        try stripped.appendSlice(gpa, doc[scan..keep_to]);
        scan = end + close_tag.len;
    }
    try stripped.appendSlice(gpa, doc[scan..]);
    const clean: []const u8 = stripped.items;

    // The reference table is an index, not prose; its examples are the signatures themselves.
    const prose_end: usize = std.mem.indexOf(u8, clean, "id=\"reference\"") orelse clean.len;

    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    const example_open: []const u8 = "<pre><code>";
    const example_close: []const u8 = "</code></pre>";
    while (std.mem.indexOfPos(u8, clean, cursor, example_open)) |hit| {
        if (hit >= prose_end) {
            break;
        }
        const body_at: usize = hit + example_open.len;
        const body_end: usize = std.mem.indexOfPos(u8, clean, body_at, example_close) orelse break;
        const after: usize = body_end + example_close.len;
        try out.appendSlice(gpa, clean[cursor..after]);
        cursor = after;

        // Which zn functions does this example name?
        var named: std.ArrayList([]const u8) = .empty;
        var probe: usize = body_at;
        while (std.mem.indexOfPos(u8, clean[0..body_end], probe, "zn.")) |at| {
            var stop: usize = at + 3;
            while (stop < body_end and (std.ascii.isAlphanumeric(clean[stop]) or clean[stop] == '_')) {
                stop += 1;
            }
            probe = stop;
            const name: []const u8 = clean[at + 3 .. stop];
            if (name.len == 0) {
                continue;
            }
            // ARITY: THE HALF A FOLD DOES NOT PROVE
            //
            // Attaching a fold proves the NAME resolves. It says nothing about how the example
            // CALLS it - so `zn.takeRows(gpa, column, rows)` still folds after the signature
            // gained a `comptime T`, still reads plausibly, and costs a reader who copies it an
            // hour. This counts the arguments and compares.
            //
            // Counting is by commas at depth one, with nested calls and `&.{ ... }` literals
            // skipped over. A `try` prefix or a trailing `catch` does not change the count.
            if (clean[stop] == '(') {
                var depth: usize = 0;
                var given: usize = 0;
                var in_arg: bool = false;
                // A COMMA INSIDE A STRING IS NOT AN ARGUMENT SEPARATOR
                //
                // `zn.einsum(f64, "ij,jk->ik", out, .{ a, b })` has four arguments and five
                // commas. A character scanner that does not know about quotes reads it as five,
                // which is how this check first accused a correct example.
                var in_string: bool = false;
                var walk_at: usize = stop;
                while (walk_at < body_end) : (walk_at += 1) {
                    if (in_string) {
                        if (clean[walk_at] == '"' and clean[walk_at - 1] != '\\') {
                            in_string = false;
                        }
                        continue;
                    }
                    if (clean[walk_at] == '"') {
                        in_string = true;
                        if (depth == 1) {
                            in_arg = true;
                        }
                        continue;
                    }
                    // A LINE COMMENT IS NOT AN ARGUMENT
                    //
                    // `.{},  // PpoConfig defaults` is one argument with a note after it. The
                    // segment scan counted the note as content, so a five-argument call with a
                    // trailing comment read as six - and the check accused a correct example,
                    // which is the same class of false positive the string-literal case was.
                    if (clean[walk_at] == '/' and walk_at + 1 < body_end and clean[walk_at + 1] == '/') {
                        while (walk_at < body_end and clean[walk_at] != '\n') {
                            walk_at += 1;
                        }
                        continue;
                    }
                    switch (clean[walk_at]) {
                        '(', '{', '[' => depth += 1,
                        ')', '}', ']' => {
                            depth -= 1;
                            if (depth == 0) {
                                if (in_arg) {
                                    given += 1;
                                }
                                break;
                            }
                        },
                        ',' => if (depth == 1) {
                            if (in_arg) {
                                given += 1;
                            }
                            in_arg = false;
                        },
                        ' ', '\n' => {},
                        else => if (depth == 1) {
                            in_arg = true;
                        },
                    }
                }
                for (decls) |decl| {
                    if (!std.mem.eql(u8, decl.name, name)) {
                        continue;
                    }
                    if (decl.params) |wants| {
                        if (given != wants) {
                            std.process.fatal(
                                "zimrnum_ref: the tutorial calls zn.{s} with {d} argument(s); " ++
                                    "it takes {d}. Fix the example or the function.",
                                .{ name, given, wants },
                            );
                        }
                    }
                }
            }
            var already: bool = false;
            for (named.items) |seen| {
                if (std.mem.eql(u8, seen, name)) {
                    already = true;
                }
            }
            if (!already) {
                try named.append(gpa, name);
            }
        }
        if (named.items.len == 0) {
            continue;
        }

        var wrote_any: bool = false;
        var body: std.ArrayList(u8) = .empty;
        for (named.items) |name| {
            for (decls) |decl| {
                if (!std.mem.eql(u8, decl.name, name)) {
                    continue;
                }
                try body.appendSlice(gpa, "<details><summary><code>");
                try body.appendSlice(gpa, name);
                try body.appendSlice(gpa, "</code></summary><pre class=\"zn-code\"><code>");
                try appendEscaped(gpa, &body, decl.source);
                try body.appendSlice(gpa, "</code></pre></details>\n");
                emitted.* += 1;
                wrote_any = true;
                break;
            }
        }
        if (wrote_any) {
            try out.appendSlice(gpa, "\n");
            try out.appendSlice(gpa, open_tag);
            try out.appendSlice(gpa, "\n");
            try out.appendSlice(gpa, body.items);
            try out.appendSlice(gpa, close_tag);
        }
    }
    try out.appendSlice(gpa, clean[cursor..]);
    return out.items;
}

/// One declaration's exact source text, as the compiler's own parser sees it.
const Extract = struct {
    name: []const u8,
    source: []const u8,
    /// How many parameters the declaration takes, or null if it is not a function.
    ///
    /// Used to check the tutorial's examples. A fold proves a NAME exists - the generator
    /// looks it up to attach the source - but says nothing about how it is CALLED. An example
    /// written `zn.takeRows(gpa, column, rows)` when the signature gained a `comptime T` still
    /// attaches its fold and still reads plausibly, and a reader who copies it loses an hour.
    params: ?usize,
};

/// Every top-level declaration in `path`, with its exact span.
///
/// ── ★★★ THE COMPILER'S PARSER, NOT A BRACE COUNTER ──
///
/// Slicing from `pub fn NAME(` to a matching `}` by counting braces is thirty lines and wrong:
/// zimrnum contains `"{d}"` format strings and comments with braces, and a counter cannot tell
/// those from code. `std.zig.Ast` is the parser the compiler uses, ships with it, and gives each
/// declaration's first and last token directly. **It is exact by construction rather than exact
/// until someone writes an unusual string.**
///
/// ★ The span starts at the first doc-comment token, so a fold shows the documentation with the
/// code — which is most of what a reader wants and all of what makes the doc comment worth
/// writing.
///
/// ★ Tests are skipped: only `fn_decl` and the `const` forms are collected, and a `test` block is
/// neither.
fn extractDeclarations(gpa: Allocator, source: [:0]const u8) ![]Extract {
    var ast: std.zig.Ast = try std.zig.Ast.parse(gpa, source, .{});
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        std.process.fatal("zimrnum_ref: {s} did not parse; {d} errors", .{ source_path, ast.errors.len });
    }
    var out: std.ArrayList(Extract) = .empty;
    for (ast.rootDecls()) |node| {
        const tag: std.zig.Ast.Node.Tag = ast.nodeTag(node);
        const is_decl: bool = tag == .fn_decl or tag == .simple_var_decl or
            tag == .aligned_var_decl or tag == .global_var_decl;
        if (!is_decl) {
            continue;
        }
        // Count the parameters by walking the prototype's tokens between its parentheses at
        // depth one - commas plus one, or zero for `()`. The AST has a full `fnProto` view but
        // it needs a buffer and several node kinds; this is the same answer in five lines.
        var param_count: ?usize = null;
        if (tag == .fn_decl) {
            var t: std.zig.Ast.TokenIndex = ast.firstToken(node);
            const stop: std.zig.Ast.TokenIndex = ast.lastToken(node);
            // COUNT SEGMENTS WITH CONTENT, NOT COMMAS PLUS ONE
            //
            // `zig fmt` puts a TRAILING COMMA on every multiline parameter list, so
            // `commas + 1` counts one parameter too many for exactly the declarations this
            // file is full of. Counting segments that actually contain something is immune.
            var depth: usize = 0;
            var counted: usize = 0;
            var in_segment: bool = false;
            while (t <= stop) : (t += 1) {
                switch (ast.tokenTag(t)) {
                    .l_paren => depth += 1,
                    .r_paren => {
                        depth -= 1;
                        if (depth == 0) {
                            if (in_segment) {
                                counted += 1;
                            }
                            break;
                        }
                    },
                    .comma => if (depth == 1) {
                        if (in_segment) {
                            counted += 1;
                        }
                        in_segment = false;
                    },
                    else => if (depth == 1) {
                        in_segment = true;
                    },
                }
            }
            param_count = counted;
        }
        const first: std.zig.Ast.TokenIndex = ast.firstToken(node);
        const last: std.zig.Ast.TokenIndex = ast.lastToken(node);
        var begin: usize = ast.tokenStart(first);
        // Walk back over any doc comment attached to this declaration.
        var probe: std.zig.Ast.TokenIndex = first;
        while (probe > 0 and ast.tokenTag(probe - 1) == .doc_comment) {
            probe -= 1;
            begin = ast.tokenStart(probe);
        }
        const last_start: usize = ast.tokenStart(last);
        var end: usize = last_start;
        while (end < source.len and source[end] != '\n') {
            end += 1;
        }
        const text: []const u8 = source[begin..@min(end + 1, source.len)];
        // ★ The name comes from the DECLARATION line, not the first line of the span: the span
        // begins at the doc comment, so its first line is prose.
        const decl_line: []const u8 = source[ast.tokenStart(first)..@min(ast.tokenStart(first) + 200, source.len)];
        const line_end: usize = std.mem.indexOfScalar(u8, decl_line, '\n') orelse decl_line.len;
        const name: []const u8 = declName(decl_line[0..line_end]) orelse continue;
        try out.append(gpa, .{ .name = name, .source = text, .params = param_count });
    }
    return out.items;
}

/// The declared name on a `pub fn` / `pub const` line, or null.
fn declName(line: []const u8) ?[]const u8 {
    const trimmed: []const u8 = std.mem.trim(u8, line, " ");
    const rest: []const u8 = if (std.mem.startsWith(u8, trimmed, "pub fn "))
        trimmed["pub fn ".len..]
    else if (std.mem.startsWith(u8, trimmed, "pub const "))
        trimmed["pub const ".len..]
    else
        return null;
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }
    return if (end == 0) null else rest[0..end];
}

/// The declaration as it appears, minus the `pub fn ` / `pub const ` prefix and any trailing `{`.
/// The signature, spanning as many lines as the declaration takes, flattened to one.
///
/// A MULTI-LINE DECLARATION IS THE COMMON CASE, NOT THE EXCEPTION
///
/// The `fn-args-multiline` lint rule requires one parameter per line for anything with three or
/// more, so most of this library's declarations span several lines. Reading only the first gave
/// signatures like `varianceAxis(` and `where(` - a column showing the opening bracket and
/// nothing else.
///
/// So this walks forward from the declaration to the `{` that opens the body, collapsing runs of
/// whitespace. `allocator` is written into the returned buffer, which the caller owns.
fn declSignature(gpa: Allocator, source: []const u8, line_start: usize) ![]const u8 {
    const trimmed_start: usize = blk: {
        var i: usize = line_start;
        while (i < source.len and source[i] == ' ') : (i += 1) {}
        break :blk i;
    };
    const head: []const u8 = source[trimmed_start..];
    const skip: usize = if (std.mem.startsWith(u8, head, "pub fn "))
        "pub fn ".len
    else if (std.mem.startsWith(u8, head, "pub const "))
        "pub const ".len
    else
        0;
    var at: usize = trimmed_start + skip;
    // To the `{` that opens the body, or the end of the line for a `const` with no body. A
    // declaration's parameter list can contain braces - `&.{ ... }` in a default - so the scan
    // tracks paren depth and stops at a brace only outside them.
    var depth: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    var last_was_space: bool = false;
    while (at < source.len) : (at += 1) {
        const c: u8 = source[at];
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth > 0) {
                depth -= 1;
            }
        } else if (c == '{' and depth == 0) {
            break;
        } else if (c == '\n' and depth == 0) {
            // A `pub const X = 3;` ends at its line; a multi-line fn is still inside parens.
            break;
        }
        if (c == ' ' or c == '\n' or c == '\t') {
            if (!last_was_space and out.items.len > 0) {
                try out.append(gpa, ' ');
            }
            last_was_space = true;
            continue;
        }
        last_was_space = false;
        try out.append(gpa, c);
    }
    // TIDY THE SEAMS THE FLATTENING LEAVES
    //
    // Collapsing newlines to spaces puts one after the opening `(` and one before the closing
    // one, and `zig fmt`'s trailing comma on a multi-line list becomes `, )`. None of that is
    // wrong, and all of it reads as sloppy in a reference column.
    var tidy: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const c: u8 = out.items[i];
        // A space right after `(`.
        if (c == ' ' and tidy.items.len > 0 and tidy.items[tidy.items.len - 1] == '(') {
            continue;
        }
        // `, )` and ` )` before a close.
        if ((c == ',' or c == ' ') and i + 2 <= out.items.len) {
            var look: usize = i;
            while (look < out.items.len and (out.items[look] == ',' or out.items[look] == ' ')) {
                look += 1;
            }
            if (look < out.items.len and out.items[look] == ')') {
                i = look - 1;
                continue;
            }
        }
        try tidy.append(gpa, c);
    }
    const flat: []const u8 = std.mem.trimEnd(u8, tidy.items, " ");
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, flat, "="), " ");
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const limit: std.Io.Limit = .limited(16 * 1024 * 1024);

    const source: []u8 = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, gpa, limit);
    const doc: []u8 = try std.Io.Dir.cwd().readFileAlloc(init.io, doc_path, gpa, limit);
    const sweep: []u8 = try std.Io.Dir.cwd().readFileAlloc(init.io, sweep_path, gpa, limit);
    var with_kernel: usize = 0;

    // ── ★★★ THE SOURCE FOLDS, BEFORE THE TABLE ──
    //
    // The table splice searches for its header in `doc`, so the folds have to be in place first
    // or the second transform would be working on a stale string. Both are pure functions of the
    // source, so running them in this order twice gives the same file.
    const sentinel: [:0]u8 = try gpa.allocSentinel(u8, source.len, 0);
    @memcpy(sentinel[0..source.len], source);
    const decls: []Extract = try extractDeclarations(gpa, sentinel);
    var folds: usize = 0;
    const doc_with_folds: []u8 = try insertSourceFolds(gpa, doc, decls, &folds);

    var rows: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var missing: std.ArrayList(u8) = .empty;

    var cursor: usize = 0;
    while (cursor < source.len) {
        const line_start: usize = cursor;
        const line_stop: usize = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse
            source.len;
        cursor = line_stop + 1;
        const line: []const u8 = source[line_start..line_stop];
        const name: []const u8 = declName(line) orelse continue;
        const text: []const u8 = noteFor(name) orelse blk: {
            try missing.appendSlice(gpa, name);
            try missing.append(gpa, ' ');
            break :blk "";
        };
        try rows.appendSlice(gpa, "<tr><td><code>");
        try rows.appendSlice(gpa, name);
        try rows.appendSlice(gpa, "</code></td><td><code>");
        try appendEscaped(gpa, &rows, try declSignature(gpa, source, line_start));
        try rows.appendSlice(gpa, "</code></td><td>");
        // ★ A METHOD IS NEITHER. `Graph.add` shares a name with the module-level `add` that has a
        // kernel, but the graph runs on the host; showing the kernel there would be a false
        // claim. Methods are marked as such and the lookup is skipped.
        const is_method: bool = line.len > 0 and line[0] == ' ';
        if (is_method) {
            try rows.appendSlice(gpa, "<span class=\"host\">method</span>");
        } else if (try kernelsFor(gpa, sweep, name)) |kernels| {
            try rows.appendSlice(gpa, "<code>");
            try rows.appendSlice(gpa, kernels);
            try rows.appendSlice(gpa, "</code>");
            with_kernel += 1;
        } else {
            try rows.appendSlice(gpa, "<span class=\"host\">host</span>");
        }
        try rows.appendSlice(gpa, "</td><td>");
        try rows.appendSlice(gpa, text);
        try rows.appendSlice(gpa, "</td></tr>\n");
        count += 1;
    }

    const header_at: usize = std.mem.indexOf(u8, doc_with_folds, table_header) orelse {
        std.process.fatal("{s}: reference table header not found", .{doc_path});
    };
    const rows_start: usize = header_at + table_header.len;
    const rows_end: usize = std.mem.indexOfPos(u8, doc_with_folds, rows_start, "</table>") orelse {
        std.process.fatal("{s}: reference table is not closed", .{doc_path});
    };

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, doc_with_folds[0..rows_start]);
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, rows.items);
    try out.appendSlice(gpa, doc_with_folds[rows_end..]);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = doc_path, .data = out.items });

    // A declaration with no note is the one failure this tool can still have, so it names them
    // rather than leaving a silently blank column.
    if (missing.items.len > 0) {
        std.process.fatal(
            "zimrnum_ref: {d} rows written, but these have no note: {s}",
            .{ count, missing.items },
        );
    }
    // ── ★★★ THE HEADING NUMBERS ARE CHECKED, BECAUSE NOTHING ELSE WAS CHECKING THEM ──
    //
    // Four separate `h2` sections had all numbered their subsections `14.x`: every time a section
    // was inserted the ones after it kept their old prefix, and the drift was invisible because
    // the reference-table test only compares declarations. **Fourteen headings were wrong before
    // anyone looked.** Numbering is the reader's map of the document, so it gets a gate.
    //
    // ★ Every `h3` must carry its enclosing `h2`'s number and count up from 1 within it.
    {
        var section: usize = 0;
        var subsection: usize = 0;
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, doc_with_folds, scan, "<h")) |hit| {
            if (hit + 3 >= doc_with_folds.len or
                (doc_with_folds[hit + 2] != '2' and doc_with_folds[hit + 2] != '3'))
            {
                scan = hit + 2;
                continue;
            }
            const close: usize = std.mem.indexOfScalarPos(u8, doc_with_folds, hit, '>') orelse break;
            const number_end: usize =
                std.mem.indexOfAnyPos(u8, doc_with_folds, close + 1, " .<") orelse break;
            const number: usize =
                std.fmt.parseInt(usize, doc_with_folds[close + 1 .. number_end], 10) catch {
                    scan = close;
                    continue;
                };
            if (doc_with_folds[hit + 2] == '2') {
                section = number;
                subsection = 0;
            } else {
                subsection += 1;
                if (number != section) {
                    std.process.fatal(
                        "zimrnum_ref: heading {d}.x sits under section {d}",
                        .{ number, section },
                    );
                }
                const dot: usize = number_end;
                const sub_end: usize =
                    std.mem.indexOfAnyPos(u8, doc_with_folds, dot + 1, " <") orelse break;
                const sub: usize =
                    std.fmt.parseInt(usize, doc_with_folds[dot + 1 .. sub_end], 10) catch 0;
                if (sub != subsection) {
                    std.process.fatal(
                        "zimrnum_ref: heading {d}.{d} should be {d}.{d}",
                        .{ number, sub, section, subsection },
                    );
                }
            }
            scan = close;
        }
    }

    const msg: []u8 = try allocPrint(
        gpa,
        "zimrnum_ref: {d} rows, {d} with a kernel, {d} source folds -> {s}\n",
        .{ count, with_kernel, folds, doc_path },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, msg);
}
