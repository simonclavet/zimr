//! kit_mlp - networks on the GPU learning kit (`gpu/zn_mlp.zig`), on a device or on the kit's CPU twin, which runs
//! the very same kernel code on the host.
//!
//! Two things, one built on the other:
//!
//!     KitLayout, KitNetwork    THE one definition of a network on the kit: where every number lives, and the
//!                              kernels that run a network forward and back - for every learner that places
//!                              networks in the kit's buffers (EfficientTDMPC's `robot_bmpc_kit` builds its world
//!                              model of them)
//!     KitMlp                   an ordinary multilayer perceptron with its own pipe and batch, and a training step:
//!                              give it layer sizes, get `forward`, `trainStep` (one Adam step on mean-squared
//!                              error) and `parameters` - one `KitNetwork` and one application of it
//!
//! ---- THE KIT'S FIVE BUFFERS ----
//!
//! The kit's kernels read and write five flat arrays of f32, and a kernel learns where its numbers are from offsets
//! the host writes into its uniform before each dispatch:
//!
//!     params   every network's parameters, end to end             written by the host, and by Adam
//!     grads    their gradients, at THE SAME OFFSETS as params     written by the backward kernels
//!     acts     activations: inputs, every layer's outputs, the     written by the host (inputs) and the forward
//!              values a backward needs to read again
//!     dacts    gradients of activations, during a backward         written by the backward kernels
//!     loss     a few scalars, read back for reports                written by `mse_value` and its kind
//!
//! A parameter and its gradient share an offset - a dense layer's weight gradient kernel writes `grads[w_off + i]`
//! for the weight it read at `params[w_off + i]` - so a network is placed ONCE and both buffers follow. Adam's two
//! moments (`adam_m`, `adam_v`) are laid out like params too.
//!
//! ---- A NETWORK AND ITS APPLICATIONS ----
//!
//! A network's PARAMETERS live once. An APPLICATION of the network - one batch of rows pushed through it - needs
//! regions of its own in acts, for everything its backward will have to read again: each layer's linear outputs,
//! normalised rows, inverse spreads, scaled values and outputs. The two are kept apart because a learner may apply
//! one network many times before a single backward: EfficientTDMPC's dynamics head runs once for every step of an
//! unrolled window, and back-propagation through time needs every step's activations at once. So one network can
//! have many applications, each with its own regions, all reading the same parameters and all adding their gradients
//! into the same place:
//!
//!     params  [ encoder | head 0 | head 1 ]                         each network once
//!     grads   [ encoder | head 0 | head 1 ]                         same offsets; a head's gradient = sum over steps
//!     acts    [ window | encoder pass | head 0 step 0 | head 0 step 1 | ... | head 1 step 0 | ... ]
//!
//! ---- ONE LAYER ON THE KIT ----
//!
//! A layer is one of three shapes (`KitLayerKind`): a NORMED layer (TD-MPC2's `NormedDense`: linear, layer norm,
//! gain and bias, Mish - or SimNorm at the end of an encoder or a dynamics head), a dense layer with a fused tanh or
//! relu (a `KitMlp`'s hidden layers), or a PLAIN linear layer (a head). On the kit, each step of a layer is a kernel
//! of its own wherever it needs a different shape of thread (`zn_mlp`'s head draws it):
//!
//!     a normed layer      dense_fwd (linear) -> norm_fwd -> mish_fwd, or simnorm_fwd for a layer ending in SimNorm
//!     a dense layer       dense_fwd, its tanh or relu fused in
//!     a plain layer       dense_fwd (linear)
//!
//! and its backward the same kernels' backwards, in the reverse order. A layer's parameters are its tensors in
//! zimrnum's own order (`NormedDense.tensors`): W, b, then a normed layer's gain and norm bias - which is exactly what
//! the kit's kernels read at the layer's offset, so zimrnum's numbers are copied in one after another, unchanged.
//!
//! ---- DESCRIPTORS, PASSED BY VALUE ----
//!
//! A `KitNetwork`, an `Application` - and the learners built of them (`robot_bmpc_kit`'s rollout, world model, value
//! targets, policy learner) - are DESCRIPTORS: offsets and widths, and slices into memory an arena owns. They are made
//! once and never change, so they are passed and stored by value, freely copied, and every copy describes the same
//! regions. What does change lives elsewhere: the numbers in the kit's buffers, on the device; the pipe and the
//! layout, always passed as pointers (`*Pipe`, `*KitLayout`); and the few lists a descriptor grows while it is built
//! (a rollout's latent readers), in arena memory every copy's slices share. A descriptor is a few hundred bytes at
//! most - a copy costs less than reading a few cache lines, against a dispatch's microseconds - and a test keeps them
//! that small.
//!
//! ---- KitMlp: READING BACK ----
//!
//! Reading anything out of the kit goes through `readLatest`, which on the CPU twin hands over the current buffer
//! and on a GPU hands over the most recent readback - typically a frame old. So `KitMlp.forward` and the loss
//! `trainStep` returns are exact on the twin (where the tests run) and RECENT on a device. Training does not care;
//! anything that needs this frame's numbers on a GPU keeps them on the device.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const compute_host = @import("compute_host.zig");

const Allocator = std.mem.Allocator;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const float = zm.float;
const cosRad = zm.cosRad;
const pi = zm.pi;
const sinRad = zm.sinRad;
const Random = std.Random;
const ArenaAllocator = std.heap.ArenaAllocator;

// ============================================================================================================
// WHERE NUMBERS LIVE
// ============================================================================================================

/// Which of the kit's two working buffers a region lies in: the ACTIVATIONS a forward pass writes (acts), or the
/// GRADIENTS a backward pass writes (dacts). They are separate buffers with offsets of their own - an offset means
/// nothing until its buffer is named, which is why `RowColumns` carries one.
pub const KitBuffer = enum { activations, gradients };

/// A run of columns in rows laid out with a stride: row r's columns start at `offset` + r x `row_stride` +
/// `first_column`, in `buffer`. Rows of their own, packed one after another, are `packedRows`; the columns of wider
/// rows - an action inside a world model's wide rows, say - name the wide rows' stride and their first column.
pub const RowColumns = struct {
    buffer: KitBuffer = .activations,
    offset: u32,
    row_stride: u32,
    first_column: u32 = 0,

    /// Packed rows of `width` numbers each, from `offset` in the activations.
    pub fn packedRows(offset: u32, width: u32) RowColumns {
        const rows: RowColumns = .{ .offset = offset, .row_stride = width };
        return rows;
    }
};

/// `column_count` columns of `row_count` rows copied from `source` to `destination`, on the kit. The kernel follows
/// the source's buffer (`copy_columns` from activations, `copy_columns_from_gradients` from gradients), so a copy says
/// which buffer it reads and cannot read the other by mistake. The destination is always in the activations: nothing
/// copies into a gradient - a backward pass writes those itself.
pub fn copyColumns(
    comptime M: type,
    pipe: *compute_host.Compute(M),
    row_count: u32,
    column_count: u32,
    source: RowColumns,
    destination: RowColumns,
) void {
    const into_activations: bool = destination.buffer == .activations;
    assertf(into_activations, @src(), "copyColumns: a copy writes into the activations, not the gradients", .{});
    pipe.params = .{
        .rows = row_count,
        .count = column_count,
        .x_off = source.offset,
        .stride = source.row_stride,
        .col = source.first_column,
        .y_off = destination.offset,
        .destination_stride = destination.row_stride,
        .destination_column = destination.first_column,
    };
    const thread_count: u32 = row_count * column_count;
    switch (source.buffer) {
        .activations => pipe.run("copy_columns", thread_count),
        .gradients => pipe.run("copy_columns_from_gradients", thread_count),
    }
}

/// The offsets of everything in the kit's buffers, handed out in order - a counter per buffer, nothing more. Every
/// region a network or a rollout needs is RESERVED here first; only then are the buffers made, sized from the totals,
/// and filled. So every offset is known before a single float is allocated, and no two regions can overlap:
///
///     reserveActs(48)  -> 0        acts:  [ 0 ........ 48 )
///     reserveActs(16)  -> 48              [ 0 ........ 48 | 48 .. 64 )
///     reserveActs(32)  -> 64              [ 0 ........ 48 | 48 .. 64 | 64 ...... 96 )      acts_floats = 96
///
/// A params offset is a grads offset too (this file's head): the two buffers are laid out alike.
pub const KitLayout = struct {
    /// Floats reserved so far in each buffer - and so, at the end, the size each buffer must have.
    params_floats: u32 = 0,
    acts_floats: u32 = 0,
    dacts_floats: u32 = 0,

    /// `float_count` floats of params (and of grads, at the same offset): where they begin.
    pub fn reserveParams(layout: *KitLayout, float_count: u32) u32 {
        const region_start: u32 = layout.params_floats;
        layout.params_floats += float_count;
        return region_start;
    }

    /// `float_count` floats of acts: where they begin.
    pub fn reserveActs(layout: *KitLayout, float_count: u32) u32 {
        const region_start: u32 = layout.acts_floats;
        layout.acts_floats += float_count;
        return region_start;
    }

    /// `float_count` floats of dacts: where they begin.
    pub fn reserveDacts(layout: *KitLayout, float_count: u32) u32 {
        const region_start: u32 = layout.dacts_floats;
        layout.dacts_floats += float_count;
        return region_start;
    }

    /// That every region this layout reserved lies inside the kit's own buffers (`M`, the kernel module): acts holds
    /// `M.acts_len` floats, dacts `M.dacts_len` (or `M.config.max` in a module that does not size it on its own),
    /// params
    /// and grads `M.config.max` each. A layout past them would have kernels read and write beyond a buffer's end - on a
    /// device, into whatever lies after it - so whoever sizes buffers from a layout asserts this before the first
    /// upload, and the message names every number.
    /// The layout against the kit's buffers, as an error naming the first that is too small - so a learner refuses a
    /// configuration that does not fit, naming the buffer to enlarge, where `requireFitsKit` would stop the program.
    pub fn checkFitsKit(
        layout: KitLayout,
        comptime M: type,
    ) error{ KitActivationsTooSmall, KitGradientsTooSmall, KitParametersTooSmall }!void {
        const dacts_capacity: u32 = if (@hasDecl(M, "dacts_len")) M.dacts_len else M.config.max;
        if (layout.acts_floats > M.acts_len) {
            return error.KitActivationsTooSmall;
        }
        if (layout.dacts_floats > dacts_capacity) {
            return error.KitGradientsTooSmall;
        }
        if (layout.params_floats > M.config.max) {
            return error.KitParametersTooSmall;
        }
    }

    pub fn requireFitsKit(layout: KitLayout, comptime M: type) void {
        const acts_capacity: u32 = M.acts_len;
        const dacts_capacity: u32 = if (@hasDecl(M, "dacts_len")) M.dacts_len else M.config.max;
        const other_capacity: u32 = M.config.max;
        const acts_fit: bool = layout.acts_floats <= acts_capacity;
        const dacts_fit: bool = layout.dacts_floats <= dacts_capacity;
        const params_fit: bool = layout.params_floats <= other_capacity;
        const message: []const u8 = "the layout needs {d} acts, {d} dacts and {d} params; " ++
            "the kit holds {d} acts, {d} dacts and {d} of each of the others";
        assertf(acts_fit and dacts_fit and params_fit, @src(), message, .{
            layout.acts_floats,
            layout.dacts_floats,
            layout.params_floats,
            acts_capacity,
            dacts_capacity,
            other_capacity,
        });
    }

    /// The largest of the three sizes: how many values of each buffer a readback must hold to see all of it
    /// (`compute_host.Compute.element_count`).
    pub fn largestBuffer(layout: KitLayout) u32 {
        const larger_of_acts_and_dacts: u32 = @max(layout.acts_floats, layout.dacts_floats);
        return @max(larger_of_acts_and_dacts, layout.params_floats);
    }
};

// ============================================================================================================
// ONE LAYER
// ============================================================================================================

/// The activation of a plain network's hidden layers (`KitNetwork.initDense`, `Spec.act`).
pub const DenseActivation = enum { relu, tanh };

/// What a layer is on the kit (this file's head).
pub const KitLayerKind = enum {
    /// A plain dense layer with a tanh or relu fused into its linear part (`dense_fwd`'s own activation): a
    /// `KitMlp`'s hidden layers. Its backward scales the arriving gradient by the activation's slope, read from the
    /// stored output (`act_bwd`), in place.
    dense_tanh,
    dense_relu,
    /// A `NormedDense` ending in Mish: every hidden layer of every EfficientTDMPC network.
    normed_mish,
    /// A `NormedDense` ending in SimNorm: the last layer of the encoder and of each dynamics head, whose output is a
    /// latent state.
    normed_simnorm,
    /// A plain linear `Dense`: the last layer of a head whose outputs are logits (reward, value) or a policy's
    /// parameters.
    plain,

    /// Whether a layer of this kind is NORMED: a layer norm, a gain and a norm bias between its linear part and its
    /// activation, with regions of their own.
    pub fn isNormed(kind: KitLayerKind) bool {
        return switch (kind) {
            .normed_mish, .normed_simnorm => true,
            .dense_tanh, .dense_relu, .plain => false,
        };
    }

    /// The kit's code for the activation `dense_fwd` fuses into a layer of this kind - linear for every kind whose
    /// activation, if any, is a kernel of its own.
    fn fusedActivation(kind: KitLayerKind, comptime M: type) u32 {
        return switch (kind) {
            .dense_tanh => @backingInt(M.Act.tanh),
            .dense_relu => @backingInt(M.Act.relu),
            .normed_mish, .normed_simnorm, .plain => @backingInt(M.Act.linear),
        };
    }
};

/// One layer's shape, where its parameters are, and its norm's settings. Its parameters, from `weights_offset` on:
///
///     W           input_width x output_width     W[i, o] at weights_offset + i * output_width + o
///     b           output_width
///     gain        output_width                    a normed layer only
///     norm bias   output_width                    a normed layer only
pub const KitLayer = struct {
    kind: KitLayerKind,
    input_width: u32,
    output_width: u32,
    /// Where W begins in params - and its gradient in grads.
    weights_offset: u32,
    /// A normed layer's epsilon, added to the variance inside the square root.
    norm_epsilon: f32,
    /// A SimNorm layer's group: its outputs are softmaxed in consecutive groups of this many.
    simnorm_group: u32,
    /// The dropout rate on a normed layer's linear outputs (`zimrnum.NormedDense.dropout`): 0 for none. An
    /// application that drops out (`Dropout.on`) multiplies them by a mask before the norm, as the CPU graph does.
    dropout: f32 = 0,

    /// Where the gains begin: after W and b.
    pub fn gainsOffset(layer: KitLayer) u32 {
        const weight_floats: u32 = layer.input_width * layer.output_width;
        const bias_floats: u32 = layer.output_width;
        return layer.weights_offset + weight_floats + bias_floats;
    }

    /// How many floats the layer's parameters take: W and b, and for a normed layer the gain and the norm bias.
    pub fn parameterFloats(layer: KitLayer) u32 {
        const linear_floats: u32 = layer.input_width * layer.output_width + layer.output_width;
        const is_normed: bool = layer.kind.isNormed();
        const norm_floats: u32 = if (is_normed) 2 * layer.output_width else 0;
        return linear_floats + norm_floats;
    }
};

/// Where one APPLICATION keeps one layer's values (this file's head), each [rows, width] row-major. The forward
/// writes them going down; the backward walks back up, each step reading what its forward step left:
///
///     FORWARD, top to bottom                          BACKWARD, bottom to top
///
///     inputs              x                           inputs_gradient            dx
///       | dense_fwd                                     ^ dense_bwd_x            (dense_bwd_w: W's and b's)
///       v                                               |
///     linear_outputs      p = b + x W                 linear_outputs_gradient    dp
///       | norm_fwd        writes n and inv too          ^ norm_bwd               reads n, inv
///       v                                               |                        (norm_params_bwd: the gain's
///     scaled_values       s = n x gain + norm bias    scaled_values_gradient     ds   and the norm bias's)
///       | mish_fwd, or simnorm_fwd                      ^ mish_bwd (reads s), or simnorm_bwd (reads y)
///       v                                               |
///     outputs             y                           outputs_gradient           dy  - arriving from above
///
///     n: normalised_rows, the row's values less its mean, over its spread; inv: inverse_spreads, one per row
///
/// A plain layer is the first step alone: its outputs ARE its linear outputs, and its backward is the dense one. A
/// dense layer with a fused tanh or relu is the first step too, its activation inside `dense_fwd`: its outputs are
/// the activated values, and its backward first scales the arriving gradient by the activation's slope at them.
pub const LayerRegions = struct {
    // acts
    /// The dropout mask, [rows, outputs] - reserved only for a dropout layer in an application that drops out.
    dropout_mask: u32 = 0,
    linear_outputs: u32,
    normalised_rows: u32,
    inverse_spreads: u32,
    scaled_values: u32,
    outputs: u32,
    // dacts
    scaled_values_gradient: u32,
    linear_outputs_gradient: u32,
    inputs_gradient: u32,
};

/// What an application is for: a forward and its backward (a network that learns from it), or a forward alone (a
/// network read to act, to plan or to make targets) - which reserves no gradient regions, a third of a layer's
/// floats or more, and refuses a backward.
pub const ApplicationUse = enum {
    forward_and_backward,
    forward_only,
};

/// Whether an application drops out (`KitLayer.dropout`): the world model's value heads do while they train; the same
/// heads read as targets, and every network applied to act or to make targets, do not - as on the CPU, where dropout
/// happens only where a generator is handed in.
pub const Dropout = enum {
    off,
    on,
};

/// What a dropout mask's generator is the generator OF (`Application.writeDropoutMasks`): of the whole network, which
/// hands each layer its own split by the layer's index - as `zimrnum.Mlp.apply` does with the generator it is given -
/// or of the dropout layer itself, used as it is - as `zimrnum.Graph.resampleDropout` draws each dropout node's mask
/// from its own split of the update's generator. A network has one dropout layer at most (an `Mlp`'s first hidden one),
/// so a layer's generator is that layer's.
pub const DropoutGenerator = enum {
    network,
    layer,
};

/// What a backward does with the parameters' gradients it computes: write them over what is in grads, or add them
/// to it. A network applied once overwrites. A network applied at several steps of a window - a dynamics head - must
/// end with the SUM of every step's gradient, since every step used the same weights: its first backward overwrites,
/// and every later one adds.
pub const ParameterGradients = enum {
    overwrite,
    add,

    /// The kit's `accumulate` flag for this choice.
    fn accumulateFlag(parameter_gradients: ParameterGradients) u32 {
        return switch (parameter_gradients) {
            .overwrite => 0,
            .add => 1,
        };
    }
};

// ============================================================================================================
// A NETWORK
// ============================================================================================================

/// A zimrnum `Mlp(f32)` on the kit: its layers, each with where its parameters are (this file's head). `M` is the
/// kit's kernel module (`gpu/zn_mlp.zig`). It is a type parameter, as `robot_latent_kit`'s is, so that this file does
/// not import the module itself: the module is compiled for the device and for the host alike, and the code that
/// drives the kit already holds it.
pub fn KitNetwork(comptime M: type) type {
    return struct {
        const Self = @This();
        /// A pipe of the kit: the device, or the CPU twin (`compute_host.Compute.initCpu`).
        pub const Pipe = compute_host.Compute(M);

        layers: []KitLayer,

        /// `mlp` placed on the kit: every layer's parameters reserved in `layout`, in order - the hidden layers, then
        /// the last. Memory: the layer list in `arena`.
        pub fn init(arena: Allocator, layout: *KitLayout, mlp: zn.Mlp(f32)) !Self {
            const layer_count: usize = mlp.hidden.len + 1;
            const layers: []KitLayer = try arena.alloc(KitLayer, layer_count);
            for (mlp.hidden, layers[0..mlp.hidden.len]) |hidden_layer, *layer| {
                layer.* = normedLayer(layout, hidden_layer);
            }
            const last_index: usize = layer_count - 1;
            layers[last_index] = switch (mlp.last) {
                .normed => |last_normed| normedLayer(layout, last_normed),
                .plain => |last_plain| plainLayer(layout, last_plain),
            };
            const network: Self = .{ .layers = layers };
            return network;
        }

        /// A network of plain dense layers, `input_width` -> each of `hidden_widths` -> `output_width`, the hidden
        /// layers through `hidden_activation` and the last one linear (`KitMlp`'s shape): its parameters reserved in
        /// `layout`, each layer's W then b. Memory: the layer list in `arena`.
        pub fn initDense(
            arena: Allocator,
            layout: *KitLayout,
            input_width: u32,
            hidden_widths: []const u32,
            output_width: u32,
            hidden_activation: DenseActivation,
        ) !Self {
            const layer_count: usize = hidden_widths.len + 1;
            const layers: []KitLayer = try arena.alloc(KitLayer, layer_count);
            var layer_input_width: u32 = input_width;
            for (layers, 0..) |*layer, layer_index| {
                const is_last: bool = layer_index + 1 == layer_count;
                const layer_output_width: u32 = if (is_last) output_width else hidden_widths[layer_index];
                const kind: KitLayerKind = if (is_last) .plain else switch (hidden_activation) {
                    .tanh => .dense_tanh,
                    .relu => .dense_relu,
                };
                layer.* = .{
                    .kind = kind,
                    .input_width = layer_input_width,
                    .output_width = layer_output_width,
                    .weights_offset = 0,
                    .norm_epsilon = 0,
                    .simnorm_group = 8,
                };
                layer.weights_offset = layout.reserveParams(layer.parameterFloats());
                layer_input_width = layer_output_width;
            }
            const network: Self = .{ .layers = layers };
            return network;
        }

        /// A `NormedDense` as a kit layer, its parameters reserved.
        fn normedLayer(layout: *KitLayout, normed: zn.NormedDense(f32)) KitLayer {
            const kind: KitLayerKind = switch (normed.activation) {
                .mish => .normed_mish,
                .sim_norm => .normed_simnorm,
                else => normed_kind: {
                    const activation_name: []const u8 = @tagName(normed.activation);
                    assertUnreachable(@src(), "KitNetwork: a normed layer ending in {s} has no kernels on the kit", .{
                        activation_name,
                    });
                    break :normed_kind .normed_mish;
                },
            };
            // A Mish layer's group is never read; the kit's own default stands in for it.
            const simnorm_group: u32 = switch (normed.activation) {
                .sim_norm => |group| @intCast(group),
                else => 8,
            };
            var layer: KitLayer = .{
                .kind = kind,
                .input_width = @intCast(normed.dense.weight.shape[0]),
                .output_width = @intCast(normed.dense.weight.shape[1]),
                .weights_offset = 0,
                .norm_epsilon = normed.norm.epsilon,
                .simnorm_group = simnorm_group,
                .dropout = normed.dropout,
            };
            layer.weights_offset = layout.reserveParams(layer.parameterFloats());
            return layer;
        }

        /// A plain `Dense` as a kit layer, its parameters reserved.
        fn plainLayer(layout: *KitLayout, plain: zn.Dense(f32)) KitLayer {
            var layer: KitLayer = .{
                .kind = .plain,
                .input_width = @intCast(plain.weight.shape[0]),
                .output_width = @intCast(plain.weight.shape[1]),
                .weights_offset = 0,
                .norm_epsilon = 0,
                .simnorm_group = 8,
            };
            layer.weights_offset = layout.reserveParams(layer.parameterFloats());
            return layer;
        }

        /// Where the network's parameters begin in params - its first layer's W.
        pub fn paramsStart(network: Self) u32 {
            return network.layers[0].weights_offset;
        }

        /// Where the network's parameters end in params: one past its last layer's last parameter. A network's
        /// layers are placed one after another (`init`), so [paramsStart, paramsEnd) is all of it.
        pub fn paramsEnd(network: Self) u32 {
            const last_layer: KitLayer = network.layers[network.layers.len - 1];
            return last_layer.weights_offset + last_layer.parameterFloats();
        }

        /// How many inputs the network reads: its first layer's.
        pub fn inputWidth(network: Self) u32 {
            return network.layers[0].input_width;
        }

        /// The network's output width: its last layer's.
        pub fn outputWidth(network: Self) u32 {
            const last_layer: KitLayer = network.layers[network.layers.len - 1];
            return last_layer.output_width;
        }

        /// The widest any layer's output is - what `forwardHost`'s scratch is sized by (two of them).
        pub fn widestOutput(network: Self) u32 {
            var widest: u32 = 0;
            for (network.layers) |layer| {
                widest = @max(widest, layer.output_width);
            }
            return widest;
        }

        /// THE NETWORK ON THE HOST, for one input row: every layer as the kit's kernels compute it, from `params`
        /// laid out as the kit lays them (this network's offsets) - for acting on the CPU from a mirror of the
        /// device's weights. Each layer, as its kind says:
        ///
        ///     linear      p_o = b_o + sum over i of x_i W_io          (the bias first, then the inputs in order:
        ///                                                              `dense_fwd`'s order)
        ///     dense_tanh  tanh(p);   dense_relu  max(0, p)
        ///     normed_*    the layer norm of p (zimrmath's row statistics, as `norm_fwd`), times the gain, plus the
        ///                 norm bias; then Mish, or SimNorm's softmax over each group
        ///     plain       p itself
        ///
        /// `layer_scratch` holds two of the widest layer's outputs (`widestOutput`), the layers' values passed back
        /// and forth between them; the last layer writes into `output`.
        pub fn forwardHost(
            network: Self,
            params: []const f32,
            input: []const f32,
            layer_scratch: []f32,
            output: []f32,
        ) void {
            const widest: usize = network.widestOutput();
            assertf(layer_scratch.len >= 2 * widest, @src(), "scratch of {d}, the layers need {d}", .{
                layer_scratch.len,
                2 * widest,
            });
            var layer_input: []const f32 = input;
            for (network.layers, 0..) |layer, layer_index| {
                const is_last: bool = layer_index + 1 == network.layers.len;
                const scratch_half: []f32 = layer_scratch[(layer_index % 2) * widest ..][0..widest];
                const output_width: u32 = layer.output_width;
                const layer_output: []f32 = if (is_last) output[0..output_width] else scratch_half[0..output_width];
                hostLayer(layer, params, layer_input, layer_output);
                layer_input = layer_output;
            }
        }

        /// One layer of `forwardHost`, in the kernels' arithmetic.
        fn hostLayer(
            layer: KitLayer,
            params: []const f32,
            layer_input: []const f32,
            layer_output: []f32,
        ) void {
            const in_width: usize = layer.input_width;
            const out_width: usize = layer.output_width;
            const weights: []const f32 = params[layer.weights_offset..][0 .. in_width * out_width];
            const biases: []const f32 = params[layer.weights_offset + in_width * out_width ..][0..out_width];
            for (layer_output, 0..) |*value, output_index| {
                var accumulated: f32 = biases[output_index];
                for (layer_input[0..in_width], 0..) |input_value, input_index| {
                    accumulated += input_value * weights[input_index * out_width + output_index];
                }
                value.* = switch (layer.kind) {
                    .dense_tanh => zm.tanh(accumulated),
                    .dense_relu => @max(accumulated, 0),
                    .normed_mish, .normed_simnorm, .plain => accumulated,
                };
            }
            if (!layer.kind.isNormed()) {
                return;
            }
            // The layer norm over the row, then the gain and the norm bias - `norm_fwd`'s arithmetic.
            const statistics: zm.LayerNormStatistics(f32) = zm.layerNormRowStatistics(
                f32,
                zn.SliceRow(f32),
                .{ .values = layer_output },
                out_width,
                layer.norm_epsilon,
            );
            const gains: []const f32 = params[layer.gainsOffset()..][0..out_width];
            const norm_biases: []const f32 = params[layer.gainsOffset() + out_width ..][0..out_width];
            for (layer_output, gains, norm_biases) |*value, gain, norm_bias| {
                const normalised: f32 = zm.layerNormValue(f32, value.*, statistics);
                value.* = normalised * gain + norm_bias;
            }
            switch (layer.kind) {
                .normed_mish => for (layer_output) |*value| {
                    value.* = zm.mish(value.*);
                },
                .normed_simnorm => {
                    const group: usize = layer.simnorm_group;
                    var group_start: usize = 0;
                    while (group_start < out_width) : (group_start += group) {
                        const group_values: []f32 = layer_output[group_start..][0..group];
                        const group_statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(
                            f32,
                            zn.SliceRow(f32),
                            .{ .values = group_values },
                            0,
                            group,
                        );
                        for (group_values) |*value| {
                            value.* = zm.softmaxGroupValue(f32, value.*, group_statistics);
                        }
                    }
                },
                else => {},
            }
        }

        /// `mlp`'s numbers copied into the host's copy of params, at this network's offsets - every tensor of every
        /// layer in zimrnum's order, which is the order the kit's kernels read them in.
        pub fn writeParams(network: Self, mlp: zn.Mlp(f32), params: []f32) void {
            const hidden_layers: []const KitLayer = network.layers[0..mlp.hidden.len];
            for (mlp.hidden, hidden_layers) |hidden_layer, layer| {
                const tensors: [4]zn.Tensor(f32) = hidden_layer.tensors();
                writeTensors(params, layer.weights_offset, &tensors);
            }
            const last_layer: KitLayer = network.layers[network.layers.len - 1];
            switch (mlp.last) {
                .normed => |last_normed| {
                    const tensors: [4]zn.Tensor(f32) = last_normed.tensors();
                    writeTensors(params, last_layer.weights_offset, &tensors);
                },
                .plain => |last_plain| {
                    const tensors = [2]zn.Tensor(f32){ last_plain.weight, last_plain.bias };
                    writeTensors(params, last_layer.weights_offset, &tensors);
                },
            }
        }

        /// Tensors written one after another from `region_start`.
        fn writeTensors(
            params: []f32,
            region_start: u32,
            tensors: []const zn.Tensor(f32),
        ) void {
            var write_at: usize = region_start;
            for (tensors) |tensor| {
                @memcpy(params[write_at..][0..tensor.data.len], tensor.data);
                write_at += tensor.data.len;
            }
        }

        /// A new application of the network over `row_count` rows (this file's head), without dropout: its regions
        /// reserved in `layout`. Memory: the region list in `arena`.
        pub fn application(
            network: Self,
            arena: Allocator,
            layout: *KitLayout,
            row_count: u32,
        ) !Application {
            return network.applicationDropping(arena, layout, row_count, .off);
        }

        /// A new application over `row_count` rows for a forward alone (`ApplicationUse.forward_only`): no gradient
        /// regions, no dropout - a network read to act, to plan or to make targets. Memory: the region list in `arena`.
        pub fn forwardOnlyApplication(
            network: Self,
            arena: Allocator,
            layout: *KitLayout,
            row_count: u32,
        ) !Application {
            const all_regions: []LayerRegions = try arena.alloc(LayerRegions, network.layers.len);
            for (network.layers, all_regions) |layer, *regions| {
                regions.* = reserveLayerRegions(layout, layer, row_count, .forward_only);
            }
            const new_application: Application = .{
                .network = network,
                .row_count = row_count,
                .layer_regions = all_regions,
                .use = .forward_only,
            };
            return new_application;
        }

        /// A new application over `row_count` rows that drops out as `dropout` says - with a mask region for every
        /// dropout layer when it does (`Application.writeDropoutMasks` fills them). Memory: the region list in
        /// `arena`.
        pub fn applicationDropping(
            network: Self,
            arena: Allocator,
            layout: *KitLayout,
            row_count: u32,
            dropout: Dropout,
        ) !Application {
            const all_regions: []LayerRegions = try arena.alloc(LayerRegions, network.layers.len);
            for (network.layers, all_regions) |layer, *regions| {
                regions.* = reserveLayerRegions(layout, layer, row_count, .forward_and_backward);
                const drops_here: bool = dropout == .on and layer.dropout > 0;
                if (drops_here) {
                    regions.dropout_mask = layout.reserveActs(row_count * layer.output_width);
                }
            }
            const new_application: Application = .{
                .network = network,
                .row_count = row_count,
                .layer_regions = all_regions,
                .dropout = dropout,
            };
            return new_application;
        }

        /// One layer's regions for `row_count` rows. A plain layer reserves only its linear outputs - which are its
        /// outputs - and the gradients its dense backward needs; a forward-only application no gradients at all.
        fn reserveLayerRegions(
            layout: *KitLayout,
            layer: KitLayer,
            row_count: u32,
            use: ApplicationUse,
        ) LayerRegions {
            const output_floats: u32 = row_count * layer.output_width;
            const input_floats: u32 = row_count * layer.input_width;
            const is_normed: bool = layer.kind.isNormed();
            const normed_output_floats: u32 = if (is_normed) output_floats else 0;
            const normed_row_floats: u32 = if (is_normed) row_count else 0;
            const has_backward: bool = use == .forward_and_backward;
            const gradient_scale: u32 = if (has_backward) 1 else 0;
            var regions: LayerRegions = .{
                .linear_outputs = layout.reserveActs(output_floats),
                .normalised_rows = layout.reserveActs(normed_output_floats),
                .inverse_spreads = layout.reserveActs(normed_row_floats),
                .scaled_values = layout.reserveActs(normed_output_floats),
                .outputs = 0,
                .scaled_values_gradient = layout.reserveDacts(gradient_scale * normed_output_floats),
                .linear_outputs_gradient = layout.reserveDacts(gradient_scale * output_floats),
                .inputs_gradient = layout.reserveDacts(gradient_scale * input_floats),
            };
            regions.outputs = if (is_normed) layout.reserveActs(output_floats) else regions.linear_outputs;
            return regions;
        }

        /// One batch of rows through the network, forward and back (this file's head).
        pub const Application = struct {
            network: Self,
            row_count: u32,
            layer_regions: []LayerRegions,
            dropout: Dropout = .off,
            use: ApplicationUse = .forward_and_backward,

            /// Whether this application drops out at `layer`.
            fn dropsAt(app: Application, layer: KitLayer) bool {
                return app.dropout == .on and layer.dropout > 0;
            }

            /// Every dropout layer's mask set to keep every unit, unscaled - 1 everywhere: the application then
            /// computes what it would without dropout, bit for bit (an update without a generator, as the CPU's
            /// without one).
            pub fn writeKeepEverything(app: Application, acts: []f32) void {
                for (app.network.layers, app.layer_regions) |layer, regions| {
                    if (!app.dropsAt(layer)) {
                        continue;
                    }
                    const mask_floats: usize = app.row_count * layer.output_width;
                    @memset(acts[regions.dropout_mask..][0..mask_floats], 1);
                }
            }

            /// Every dropout layer's mask region uploaded from the host's copy of acts, where a mask writer filled it.
            pub fn uploadDropoutMasks(
                app: Application,
                pipe: *Pipe,
                host_acts: []const f32,
            ) void {
                for (app.network.layers, app.layer_regions) |layer, regions| {
                    if (!app.dropsAt(layer)) {
                        continue;
                    }
                    const mask_floats: u32 = app.row_count * layer.output_width;
                    pipe.uploadAt(.acts, regions.dropout_mask, host_acts[regions.dropout_mask..][0..mask_floats]);
                }
            }

            /// Every dropout layer's mask for this update, written into the host's copy of acts - drawn by zimrnum's
            /// own mask (`zimrnum.fillDropoutMask`, keep = 1 - the layer's rate) from `rng`, which is the generator of
            /// the network or of its dropout layer as `generator` says (`DropoutGenerator`): so the kit drops exactly
            /// the units the CPU agent drops with the same generator.
            pub fn writeDropoutMasks(
                app: Application,
                acts: []f32,
                rng: zn.Rng,
                generator: DropoutGenerator,
            ) !void {
                for (app.network.layers, app.layer_regions, 0..) |layer, regions, layer_index| {
                    if (!app.dropsAt(layer)) {
                        continue;
                    }
                    const layer_rng: zn.Rng = switch (generator) {
                        .network => rng.split(@intCast(layer_index)),
                        .layer => rng,
                    };
                    const mask_floats: usize = app.row_count * layer.output_width;
                    const mask_slice: []f32 = acts[regions.dropout_mask..][0..mask_floats];
                    const mask_shape = [2]usize{ app.row_count, layer.output_width };
                    const mask: zn.Tensor(f32) = try .fromSlice(mask_slice, &mask_shape);
                    const keep: f32 = 1 - layer.dropout;
                    zn.fillDropoutMask(f32, mask, layer_rng, keep);
                }
            }

            /// Where the network's outputs are after `forward`: [row_count, output width] in acts.
            pub fn outputsOffset(app: Application) u32 {
                const last_regions: LayerRegions = app.layer_regions[app.layer_regions.len - 1];
                return last_regions.outputs;
            }

            /// Where the gradient at the network's inputs is after `backward`: [rows, input width] in dacts, packed.
            pub fn inputsGradientOffset(app: Application) u32 {
                const first_regions: LayerRegions = app.layer_regions[0];
                return first_regions.inputs_gradient;
            }

            /// The forward over all `row_count` rows: the inputs from acts at `inputs_offset`, each row
            /// `inputs_row_stride` floats after the one before - 0 for packed rows (the first layer's own input width).
            /// A wider stride reads the first input-width columns of each row, so the inputs can be one part of a
            /// wider row: a dynamics head reads [z | a] from a row that holds them side by side, and the
            /// concatenation is only a layout.
            pub fn forward(
                app: Application,
                pipe: *Pipe,
                inputs_offset: u32,
                inputs_row_stride: u32,
            ) void {
                app.forwardRows(pipe, app.row_count, inputs_offset, inputs_row_stride);
            }

            /// `forward` over the first `forward_row_count` rows only - a short batch, as a `KitMlp` asked about one
            /// state at a time runs it; the rest of each region is left as it was.
            pub fn forwardRows(
                app: Application,
                pipe: *Pipe,
                forward_row_count: u32,
                inputs_offset: u32,
                inputs_row_stride: u32,
            ) void {
                var layer_inputs_offset: u32 = inputs_offset;
                var layer_inputs_row_stride: u32 = inputs_row_stride;
                for (app.network.layers, app.layer_regions) |layer, regions| {
                    linearForward(
                        pipe,
                        layer,
                        regions,
                        forward_row_count,
                        layer_inputs_offset,
                        layer_inputs_row_stride,
                    );
                    // Dropout on the linear outputs, before the norm - where the CPU graph's `NormedDense` drops.
                    if (app.dropsAt(layer)) {
                        const value_count: u32 = forward_row_count * layer.output_width;
                        pipe.params = .{
                            .count = value_count,
                            .x_off = regions.linear_outputs,
                            .z_off = regions.dropout_mask,
                        };
                        pipe.run("mask_values", value_count);
                    }
                    const is_normed: bool = layer.kind.isNormed();
                    if (is_normed) {
                        normAndActivationForward(pipe, layer, regions, forward_row_count);
                    }
                    // The next layer reads this one's outputs, packed.
                    layer_inputs_offset = regions.outputs;
                    layer_inputs_row_stride = 0;
                }
            }

            /// A layer's linear part: p = b + x W, one thread per output value (`dense_fwd`) - through the layer's
            /// fused tanh or relu for a dense layer with one.
            fn linearForward(
                pipe: *Pipe,
                layer: KitLayer,
                regions: LayerRegions,
                row_count: u32,
                layer_inputs_offset: u32,
                layer_inputs_row_stride: u32,
            ) void {
                pipe.params = .{
                    .rows = row_count,
                    .in_dim = layer.input_width,
                    .out_dim = layer.output_width,
                    .act = layer.kind.fusedActivation(M),
                    .x_off = layer_inputs_offset,
                    .y_off = regions.linear_outputs,
                    .w_off = layer.weights_offset,
                    .stride = layer_inputs_row_stride,
                };
                const output_count: u32 = row_count * layer.output_width;
                pipe.run("dense_fwd", output_count);
            }

            /// A normed layer's norm - its normalised rows, inverse spreads and scaled values, one thread per row
            /// (`norm_fwd`) - then its activation: Mish one thread per value, SimNorm one per group.
            fn normAndActivationForward(
                pipe: *Pipe,
                layer: KitLayer,
                regions: LayerRegions,
                row_count: u32,
            ) void {
                pipe.params = .{
                    .rows = row_count,
                    .out_dim = layer.output_width,
                    .x_off = regions.linear_outputs,
                    .w_off = layer.gainsOffset(),
                    .z_off = regions.normalised_rows,
                    .y_off = regions.scaled_values,
                    .l_off = regions.inverse_spreads,
                    .norm_epsilon = layer.norm_epsilon,
                };
                pipe.run("norm_fwd", row_count);
                pipe.params = .{
                    .rows = row_count,
                    .out_dim = layer.output_width,
                    .x_off = regions.scaled_values,
                    .y_off = regions.outputs,
                    .simnorm_group = layer.simnorm_group,
                };
                const value_count: u32 = row_count * layer.output_width;
                const group_count: u32 = row_count * (layer.output_width / layer.simnorm_group);
                switch (layer.kind) {
                    .normed_mish => pipe.run("mish_fwd", value_count),
                    .normed_simnorm => pipe.run("simnorm_fwd", group_count),
                    .dense_tanh, .dense_relu, .plain => {},
                }
            }

            /// The backward of the forward just run (the diagram at `LayerRegions`), from the gradient at the
            /// outputs - dacts at `outputs_gradient_offset`, [backward_row_count, output width] - to the gradient at
            /// the inputs, at `inputsGradientOffset()`. The parameters' gradients go to grads at the layers' offsets,
            /// as `parameter_gradients` says (`ParameterGradients`).
            ///
            /// The backward takes the FIRST `backward_row_count` rows of the forward's: an encoder that encodes a
            /// whole window in one pass, but whose gradient arrives only at the first step's latents, back-propagates
            /// those rows alone. The first layer's weight gradient reads the inputs again, so `inputs_offset` and
            /// `inputs_row_stride` are the forward's, and the inputs must still be there.
            pub fn backward(
                app: Application,
                pipe: *Pipe,
                backward_row_count: u32,
                inputs_offset: u32,
                inputs_row_stride: u32,
                outputs_gradient_offset: u32,
                parameter_gradients: ParameterGradients,
            ) void {
                const has_backward: bool = app.use == .forward_and_backward;
                const no_backward_message: []const u8 = "a backward through a forward-only application";
                assertf(has_backward, @src(), no_backward_message, .{});
                const accumulate_flag: u32 = parameter_gradients.accumulateFlag();
                // The gradient arriving at the layer being worked on: the network's output gradient at first, then
                // each layer's input gradient for the layer below it.
                var arriving_gradient_offset: u32 = outputs_gradient_offset;
                var layer_index: usize = app.network.layers.len;
                while (layer_index > 0) {
                    layer_index -= 1;
                    const layer: KitLayer = app.network.layers[layer_index];
                    const regions: LayerRegions = app.layer_regions[layer_index];
                    // The layer's inputs, as its forward read them: the network's for the first layer, the layer
                    // below's outputs (packed) otherwise.
                    const is_first_layer: bool = layer_index == 0;
                    const layer_inputs_offset: u32 = if (is_first_layer)
                        inputs_offset
                    else
                        app.layer_regions[layer_index - 1].outputs;
                    const layer_inputs_row_stride: u32 = if (is_first_layer) inputs_row_stride else 0;
                    // The gradient at the linear part's outputs: through the activation and the norm for a normed
                    // layer; the arriving gradient scaled by its fused activation's slope, in place, for a dense layer
                    // with one; the arriving gradient itself for a plain one, whose outputs ARE its linear outputs.
                    const linear_outputs_gradient_offset: u32 = switch (layer.kind) {
                        .normed_mish, .normed_simnorm => normAndActivationBackward(
                            pipe,
                            layer,
                            regions,
                            backward_row_count,
                            arriving_gradient_offset,
                            accumulate_flag,
                        ),
                        .dense_tanh, .dense_relu => fusedActivationBackward(
                            pipe,
                            layer,
                            regions,
                            backward_row_count,
                            arriving_gradient_offset,
                        ),
                        .plain => arriving_gradient_offset,
                    };
                    // Dropout's backward: a dropped unit passes no gradient, a kept one passes it scaled.
                    if (app.dropsAt(layer)) {
                        const value_count: u32 = backward_row_count * layer.output_width;
                        pipe.params = .{
                            .count = value_count,
                            .dy_off = linear_outputs_gradient_offset,
                            .z_off = regions.dropout_mask,
                        };
                        pipe.run("mask_gradients", value_count);
                    }
                    linearBackward(
                        pipe,
                        layer,
                        regions,
                        backward_row_count,
                        layer_inputs_offset,
                        layer_inputs_row_stride,
                        linear_outputs_gradient_offset,
                        accumulate_flag,
                    );
                    arriving_gradient_offset = regions.inputs_gradient;
                }
            }

            /// A dense layer's fused activation, backward: the arriving gradient scaled, in place, by the activation's
            /// slope at the stored outputs (`act_bwd`: tanh's 1 - y^2, relu's 0 or 1, both read from y). Returns the
            /// offset of the gradient now at the linear outputs - the same region.
            fn fusedActivationBackward(
                pipe: *Pipe,
                layer: KitLayer,
                regions: LayerRegions,
                backward_row_count: u32,
                arriving_gradient_offset: u32,
            ) u32 {
                pipe.params = .{
                    .rows = backward_row_count,
                    .out_dim = layer.output_width,
                    .act = layer.kind.fusedActivation(M),
                    .y_off = regions.outputs,
                    .dy_off = arriving_gradient_offset,
                };
                const value_count: u32 = backward_row_count * layer.output_width;
                pipe.run("act_bwd", value_count);
                return arriving_gradient_offset;
            }

            /// A layer's linear part, backward: the gradients of W and b (`dense_bwd_w`, one thread per parameter,
            /// each summing over the rows) and the gradient at the layer's inputs (`dense_bwd_x`, one thread per
            /// input value, packed).
            fn linearBackward(
                pipe: *Pipe,
                layer: KitLayer,
                regions: LayerRegions,
                backward_row_count: u32,
                layer_inputs_offset: u32,
                layer_inputs_row_stride: u32,
                linear_outputs_gradient_offset: u32,
                accumulate_flag: u32,
            ) void {
                pipe.params = .{
                    .rows = backward_row_count,
                    .in_dim = layer.input_width,
                    .out_dim = layer.output_width,
                    .x_off = layer_inputs_offset,
                    .dy_off = linear_outputs_gradient_offset,
                    .w_off = layer.weights_offset,
                    .stride = layer_inputs_row_stride,
                    .accumulate = accumulate_flag,
                };
                const weight_and_bias_count: u32 = layer.input_width * layer.output_width + layer.output_width;
                pipe.run("dense_bwd_w", weight_and_bias_count);
                pipe.params = .{
                    .rows = backward_row_count,
                    .in_dim = layer.input_width,
                    .out_dim = layer.output_width,
                    .dy_off = linear_outputs_gradient_offset,
                    .w_off = layer.weights_offset,
                    .dx_off = regions.inputs_gradient,
                };
                const input_value_count: u32 = backward_row_count * layer.input_width;
                pipe.run("dense_bwd_x", input_value_count);
            }

            /// A normed layer's activation and norm, backward, from the gradient at its outputs: the gradient at the
            /// scaled values (Mish's from the stored s, SimNorm's from the stored outputs), the gain's and norm bias's
            /// gradients, and the gradient at the linear outputs - whose offset it returns.
            fn normAndActivationBackward(
                pipe: *Pipe,
                layer: KitLayer,
                regions: LayerRegions,
                backward_row_count: u32,
                arriving_gradient_offset: u32,
                accumulate_flag: u32,
            ) u32 {
                pipe.params = .{
                    .rows = backward_row_count,
                    .out_dim = layer.output_width,
                    .x_off = regions.scaled_values,
                    .y_off = regions.outputs,
                    .dy_off = arriving_gradient_offset,
                    .dx_off = regions.scaled_values_gradient,
                    .simnorm_group = layer.simnorm_group,
                };
                const value_count: u32 = backward_row_count * layer.output_width;
                const group_count: u32 = backward_row_count * (layer.output_width / layer.simnorm_group);
                switch (layer.kind) {
                    .normed_mish => pipe.run("mish_bwd", value_count),
                    .normed_simnorm => pipe.run("simnorm_bwd", group_count),
                    .dense_tanh, .dense_relu, .plain => {},
                }
                // The gain's and the norm bias's gradients first: they read ds, which `norm_bwd` is allowed to
                // overwrite in place.
                pipe.params = .{
                    .rows = backward_row_count,
                    .out_dim = layer.output_width,
                    .dy_off = regions.scaled_values_gradient,
                    .z_off = regions.normalised_rows,
                    .w_off = layer.gainsOffset(),
                    .accumulate = accumulate_flag,
                };
                const gain_and_norm_bias_count: u32 = 2 * layer.output_width;
                pipe.run("norm_params_bwd", gain_and_norm_bias_count);
                pipe.params = .{
                    .rows = backward_row_count,
                    .out_dim = layer.output_width,
                    .dy_off = regions.scaled_values_gradient,
                    .w_off = layer.gainsOffset(),
                    .z_off = regions.normalised_rows,
                    .l_off = regions.inverse_spreads,
                    .dx_off = regions.linear_outputs_gradient,
                };
                pipe.run("norm_bwd", backward_row_count);
                return regions.linear_outputs_gradient;
            }
        };
    };
}

/// What a network is: its shape, how it is trained, and how many examples at a time.
pub const Spec = struct {
    inputs: u32,
    /// Hidden layer widths, in order. Empty makes a single linear layer.
    hidden: []const u32,
    outputs: u32,
    /// The activation on every hidden layer; the output layer is always linear, because a bounded
    /// output would quietly bound whatever the network is predicting.
    act: DenseActivation = .relu,
    /// Examples per step. Every buffer is sized for this, so it is fixed for the network's life.
    rows: u32 = 256,
    /// How large the OUTPUT layer starts, as a uniform range around zero. One leaves it alone.
    ///
    /// A residual policy wants this tiny. Its job is to correct an open-loop controller that is
    /// already nearly right, and a network whose first outputs are large drowns that controller in
    /// noise before it has learned anything - DReCon measured the difference (their Fig 9: 0.4
    /// against 0.2 mean reward at the start of training, and the gap never closes). It matters
    /// more here than for them, because our open-loop servo is stronger than theirs.
    output_scale: f32 = 1.0,
    rate: f32 = 1.0e-3,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 1.0e-8,
    seed: u64 = 1,
};

// ============================================================================================================
// AN ORDINARY MLP, TRAINED
// ============================================================================================================

/// An ordinary multilayer perceptron on the kit, with its own pipe and batch (this file's head): one `KitNetwork` of
/// plain dense layers and one application of it, the batch's inputs and targets beside it, and a training step of
/// mean-squared error and Adam. Generic over the kit's kernel module, as `KitNetwork` is.
pub fn KitMlp(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);

        gpa: Allocator,
        arena: ArenaAllocator,
        pipe: *compute_host.Compute(M),
        spec: Spec,
        layout: KitLayout,
        network: Network,
        application: Network.Application,
        /// acts: the batch's inputs, [rows, inputs], and its targets, [rows, outputs].
        inputs_offset: u32,
        targets_offset: u32,
        /// dacts: the gradient at the outputs, [rows, outputs] - where the backward starts.
        outputs_gradient_offset: u32,
        /// Total parameters: every layer's W then b, end to end from params offset 0.
        param_count: u32,
        /// A host-side mirror of the weights, as of the last `syncParameters`.
        cpu_params: []f32,
        adam_step: u32 = 0,

        pub fn init(gpa: Allocator, pipe: *compute_host.Compute(M), spec: Spec) !*Self {
            assertf(spec.inputs > 0 and spec.outputs > 0 and spec.rows > 0, @src(), "empty network", .{});
            const self: *Self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .arena = ArenaAllocator.init(gpa),
                .pipe = pipe,
                .spec = spec,
                .layout = .{},
                .network = undefined,
                .application = undefined,
                .inputs_offset = 0,
                .targets_offset = 0,
                .outputs_gradient_offset = 0,
                .param_count = 0,
                .cpu_params = undefined,
            };
            errdefer self.arena.deinit();
            const owned: Allocator = self.arena.allocator();
            // The hidden sizes are copied: a `Spec` is kept for the network's life, and a caller that built its layer
            // sizes in a scratch buffer would otherwise leave a dangling slice behind.
            self.spec.hidden = try owned.dupe(u32, spec.hidden);
            // The layout: the parameters from offset 0; in acts the batch's inputs first, then the application's
            // regions, then the targets; in dacts the application's gradients, then the outputs' gradient.
            const layout: *KitLayout = &self.layout;
            self.network = try Network.initDense(owned, layout, spec.inputs, self.spec.hidden, spec.outputs, spec.act);
            self.inputs_offset = layout.reserveActs(spec.rows * spec.inputs);
            self.application = try self.network.application(owned, layout, spec.rows);
            self.targets_offset = layout.reserveActs(spec.rows * spec.outputs);
            self.outputs_gradient_offset = layout.reserveDacts(spec.rows * spec.outputs);
            self.param_count = layout.params_floats;
            // Every region has to fit the kit's buffers, and the parameters are what surprises you: a
            // 361 -> 512 -> 512 -> 108 network is half a million weights, twice what the kit holds. Better a message
            // naming the numbers than a kernel writing past the end of a buffer.
            layout.requireFitsKit(M);
            self.cpu_params = try owned.alloc(f32, self.param_count);
            // He initialisation for relu, Xavier for tanh: the scale that keeps a signal's variance from shrinking or
            // exploding as it passes through the layers. Biases start at zero.
            var rng: Random.DefaultPrng = .init(spec.seed);
            const random: Random = rng.random();
            for (self.network.layers, 0..) |layer, layer_index| {
                const is_last: bool = layer_index + 1 == self.network.layers.len;
                const fan_in: f32 = float(layer.input_width);
                const gain: f32 = if (spec.act == .relu) 2.0 else 1.0;
                const deviation: f32 = @sqrt(gain / fan_in);
                const weight_count: u32 = layer.input_width * layer.output_width;
                for (0..weight_count) |weight_index| {
                    const value: f32 = if (is_last and spec.output_scale != 1.0)
                        spec.output_scale * (2.0 * random.float(f32) - 1.0)
                    else
                        deviation * random.floatNorm(f32);
                    self.cpu_params[layer.weights_offset + weight_index] = value;
                }
                @memset(self.cpu_params[layer.weights_offset + weight_count ..][0..layer.output_width], 0.0);
            }
            self.pipe.element_count = @max(self.param_count, 1);
            self.uploadParameters();
            const zeros: []f32 = try gpa.alloc(f32, self.param_count);
            defer gpa.free(zeros);
            @memset(zeros, 0.0);
            pipe.upload(.adam_m, zeros);
            pipe.upload(.adam_v, zeros);
            // From here on, one number comes back per step - the loss. Anything wider is asked for explicitly,
            // because the readback copies its prefix out of EVERY buffer.
            pipe.element_count = 1;
            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa: Allocator = self.gpa;
            self.arena.deinit();
            gpa.destroy(self);
        }

        /// The weights as of the last successful `syncParameters`: every layer's W then its bias, end to end.
        pub fn parameters(self: *Self) []const f32 {
            return self.cpu_params;
        }

        /// Ask for the weights to come back with the next submitted work. They are not free - on a device this widens
        /// the readback of every buffer - so nothing asks by default.
        pub fn requestParameters(self: *Self) void {
            self.pipe.element_count = @max(self.pipe.element_count, self.param_count);
        }

        /// Copy the weights out of the latest readback into the host mirror; false if none has arrived yet, or if it
        /// was too short because nobody asked (`requestParameters`).
        pub fn syncParameters(self: *Self) bool {
            const params: []const f32 = self.pipe.readLatest(.params) orelse return false;
            if (params.len < self.param_count) {
                return false;
            }
            @memcpy(self.cpu_params, params[0..self.param_count]);
            return true;
        }

        pub fn setParameters(self: *Self, values: []const f32) void {
            assertf(values.len == self.param_count, @src(), "{d} parameters, wanted {d}", .{
                values.len,
                self.param_count,
            });
            @memcpy(self.cpu_params, values);
            self.uploadParameters();
        }

        fn uploadParameters(self: *Self) void {
            self.pipe.upload(.params, self.cpu_params);
        }

        /// The forward pass, from `inputs` into `out` - any number of rows up to the network's batch size: a rollout
        /// asks one state at a time, and padding it out to a full batch would be a hundred times the work for the same
        /// answer. The buffers are already the full size, so a short batch leaves the rest untouched.
        pub fn forward(self: *Self, inputs: []const f32, out: []f32) !void {
            const rows: u32 = @intCast(inputs.len / self.spec.inputs);
            const shapes_fit: bool = rows > 0 and rows <= self.spec.rows and inputs.len == rows * self.spec.inputs and
                out.len == rows * self.spec.outputs;
            const shape_message: []const u8 =
                "forward got {d} inputs and {d} outputs, which is not {d} rows of {d} and {d}";
            assertf(shapes_fit, @src(), shape_message, .{
                inputs.len,
                out.len,
                rows,
                self.spec.inputs,
                self.spec.outputs,
            });
            // What comes back: the kit copies the first `element_count` elements of each buffer, and it has to be set
            // before the work is submitted, not before the read. Widened just for this pass, then put back: a caller
            // training in a loop should not silently start paying for a forward pass it did once.
            const outputs_offset: u32 = self.application.outputsOffset();
            const outputs_end: u32 = outputs_offset + rows * self.spec.outputs;
            const previous_element_count: u32 = self.pipe.element_count;
            defer self.pipe.element_count = previous_element_count;
            self.pipe.element_count = outputs_end;
            self.pipe.uploadAt(.acts, self.inputs_offset, inputs);
            self.pipe.beginRecording();
            self.application.forwardRows(self.pipe, rows, self.inputs_offset, 0);
            self.pipe.submitRecording();
            const acts: []const f32 = self.pipe.readLatest(.acts) orelse return error.NoReadback;
            if (acts.len < outputs_end) {
                return error.NoReadback;
            }
            @memcpy(out, acts[outputs_offset..][0..out.len]);
        }

        /// One step: forward, mean-squared error against `targets`, backward, Adam. Returns the loss BEFORE the step,
        /// which is what a training curve wants.
        pub fn trainStep(self: *Self, inputs: []const f32, targets: []const f32) !f32 {
            const rows: u32 = self.spec.rows;
            const shapes_fit: bool = inputs.len == rows * self.spec.inputs and targets.len == rows * self.spec.outputs;
            assertf(shapes_fit, @src(), "a step wants {d} in and {d} targets, got {d} and {d}", .{
                rows * self.spec.inputs,
                rows * self.spec.outputs,
                inputs.len,
                targets.len,
            });
            self.adam_step += 1;
            // Only the loss comes back - ONE number. The readback copies the first `element_count` elements of every
            // buffer, so asking for the weights here would copy a prefix of all seven of them on every step, to learn
            // a single float. Ask for the weights with `requestParameters` when you actually want them.
            self.pipe.element_count = @max(self.pipe.element_count, 1);
            self.pipe.uploadAt(.acts, self.inputs_offset, inputs);
            self.pipe.uploadAt(.acts, self.targets_offset, targets);
            const outputs_offset: u32 = self.application.outputsOffset();
            self.pipe.beginRecording();
            self.application.forward(self.pipe, self.inputs_offset, 0);
            // The loss, and the gradient it starts.
            self.pipe.params = .{
                .rows = rows,
                .out_dim = self.spec.outputs,
                .y_off = outputs_offset,
                .t_off = self.targets_offset,
            };
            self.pipe.run("mse_value", 1);
            self.pipe.params = .{
                .rows = rows,
                .out_dim = self.spec.outputs,
                .y_off = outputs_offset,
                .t_off = self.targets_offset,
                .dy_off = self.outputs_gradient_offset,
            };
            const output_value_count: u32 = rows * self.spec.outputs;
            self.pipe.run("mse_bwd", output_value_count);
            self.application.backward(self.pipe, rows, self.inputs_offset, 0, self.outputs_gradient_offset, .overwrite);
            // Adam over every parameter at once: they are one contiguous block from offset 0. Its bias corrections as
            // zimrnum's Adam forms them (`zn.adamCorrectionMultipliers`): the host works out 1 / (1 - beta^t), since a
            // kernel has no `pow`.
            const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(
                f32,
                self.spec.beta1,
                self.spec.beta2,
                self.adam_step,
            );
            self.pipe.params = .{
                .count = self.param_count,
                .w_off = 0,
                .rate = self.spec.rate,
                .beta1 = self.spec.beta1,
                .beta2 = self.spec.beta2,
                .epsilon = self.spec.epsilon,
                .correction1 = corrections.first,
                .correction2 = corrections.second,
            };
            self.pipe.run("adam", self.param_count);
            self.pipe.submitRecording();
            const loss: []const f32 = self.pipe.readLatest(.loss) orelse return error.NoReadback;
            if (loss.len < 1) {
                return error.NoReadback;
            }
            // If someone asked for the weights, they are in this readback too.
            _ = self.syncParameters();
            return loss[0];
        }
    };
}

// ============================================================================================================
// ONE CLIPPED ADAM STEP
// ============================================================================================================

/// ONE CLIPPED ADAM STEP over a contiguous range of parameters - the optimiser step of every network on the kit that
/// learns alone (SuperTrack's critic, a flow actor), on the gradients its backward left in the gradient buffer:
///
///     clip    the range's gradients, as one vector: when its length passes `gradient_clip`, scaled down to that
///             length, its direction kept - one batch with an outlying target cannot throw the weights far. The
///             length is summed in chunks (`grad_square_partials`, one per `chunk_floats`), then the chunks'
///             sums and the factor that brings the length within the limit, 1 when it already is (`clip_factor`).
///             Then, with an `element_clip`, each number bounded on its own: a spike concentrated in a few weights
///             barely lengthens the whole vector, and is caught here instead (SuperMimic's policy: the length to
///             1.0, then each number to 0.1, in its loss's units).
///     Adam    each weight moved by its running mean of gradients over the root of its running mean of squared
///             gradients (`adam_clipped`), both means corrected for having started at zero
///             (`zn.adamCorrectionMultipliers`: after one update the first mean is (1 - beta1) g, and dividing by
///             1 - beta1^t gives g back; the correction fades as t grows).
pub const ClippedAdam = struct {
    /// The step's settings.
    pub const Settings = struct {
        learning_rate: f32 = 3e-4,
        gradient_clip: f32 = 20,
        /// Each gradient's bound after the global factor; 0: none.
        element_clip: f32 = 0,
        beta1: f32 = 0.9,
        beta2: f32 = 0.999,
        epsilon: f32 = 1e-8,
    };

    params_start: u32,
    params_count: u32,
    chunk_floats: u32,
    /// A partial sum of squares per chunk of the range, then the norm and the factor.
    partials_offset: u32,
    norm_offset: u32,

    /// The clip's regions for the `params_count` parameters from `params_start`, reserved in `layout`.
    pub fn reserve(layout: *KitLayout, params_start: u32, params_count: u32) ClippedAdam {
        const chunk_floats: u32 = 1024;
        const chunk_count: u32 = (params_count + chunk_floats - 1) / chunk_floats;
        const adam: ClippedAdam = .{
            .params_start = params_start,
            .params_count = params_count,
            .chunk_floats = chunk_floats,
            .partials_offset = layout.reserveActs(chunk_count),
            .norm_offset = layout.reserveActs(2),
        };
        return adam;
    }

    /// The step (this type's head), the `update_count`-th from 1.
    pub fn step(
        adam: ClippedAdam,
        comptime M: type,
        pipe: *compute_host.Compute(M),
        settings: Settings,
        update_count: u32,
    ) void {
        const chunk_count: u32 = (adam.params_count + adam.chunk_floats - 1) / adam.chunk_floats;
        pipe.params = .{
            .count = adam.params_count,
            .stride = adam.chunk_floats,
            .w_off = adam.params_start,
            .y_off = adam.partials_offset,
        };
        pipe.run("grad_square_partials", chunk_count);
        pipe.params = .{
            .rows = chunk_count,
            .x_off = adam.partials_offset,
            .z_off = adam.norm_offset,
            .clip = settings.gradient_clip,
        };
        pipe.run("clip_factor", 1);
        const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(
            f32,
            settings.beta1,
            settings.beta2,
            update_count,
        );
        // The factor sits right after the norm.
        const clip_factor_offset: u32 = adam.norm_offset + 1;
        pipe.params = .{
            .count = adam.params_count,
            .w_off = adam.params_start,
            .x_off = clip_factor_offset,
            .rate = settings.learning_rate,
            .beta1 = settings.beta1,
            .beta2 = settings.beta2,
            .epsilon = settings.epsilon,
            .correction1 = corrections.first,
            .correction2 = corrections.second,
            .gradient_element_clip = settings.element_clip,
        };
        pipe.run("adam_clipped", adam.params_count);
    }
};

// ============================================================================================================
// THE FLOW POLICY ON THE KIT
/// SHARES OF ONE UPDATE BETWEEN SEVERAL TEACHERS: each teacher's gradient over a network's parameters measured alone,
/// scaled to the share it is given, and summed -
///
///     g = sum over teachers of  share_i x g_i / |g_i|            (a teacher whose gradient has no length adds nothing)
///
/// - so the update's direction is the teachers' in the proportions asked for, whatever the natural sizes of their
/// losses: a teacher whose loss is a thousand times smaller than another's still moves the network by its share, and
/// none drowns the others. Each teacher's backward writes its gradient over the parameters' gradient range
/// (`ParameterGradients.overwrite`); `absorb` measures it and adds it, scaled, into the sum; `finish` puts the sum
/// where the optimiser reads the gradient. The lengths are measured as `ClippedAdam` measures its own (partial sums of
/// squares by chunk, then their compensated sum), and the latest teacher's natural length stays readable at
/// `factor_offset`.
pub const TeacherShares = struct {
    params_start: u32,
    params_count: u32,
    chunk_floats: u32,
    partials_offset: u32,
    /// The latest teacher's length and factor (`share_factor`), and the sum, in acts.
    factor_offset: u32,
    sum_offset: u32,

    /// The regions for `params_count` parameters from `params_start`, reserved in `layout`.
    pub fn reserve(
        layout: *KitLayout,
        params_start: u32,
        params_count: u32,
    ) TeacherShares {
        const chunk_floats: u32 = 1024;
        const chunk_count: u32 = (params_count + chunk_floats - 1) / chunk_floats;
        const shares: TeacherShares = .{
            .params_start = params_start,
            .params_count = params_count,
            .chunk_floats = chunk_floats,
            .partials_offset = layout.reserveActs(chunk_count),
            .factor_offset = layout.reserveActs(2),
            .sum_offset = layout.reserveActs(params_count),
        };
        return shares;
    }

    /// The gradient a teacher's backward has just written over the range, at length `share`, into the sum - written
    /// over it for the first teacher of an update (`is_first`), added for the others. The teacher's own length is left
    /// at `factor_offset` for a statistic to copy.
    pub fn absorb(
        shares: TeacherShares,
        comptime M: type,
        pipe: *compute_host.Compute(M),
        share: f32,
        is_first: bool,
    ) void {
        const chunk_count: u32 = (shares.params_count + shares.chunk_floats - 1) / shares.chunk_floats;
        pipe.params = .{
            .count = shares.params_count,
            .stride = shares.chunk_floats,
            .w_off = shares.params_start,
            .y_off = shares.partials_offset,
        };
        pipe.run("grad_square_partials", chunk_count);
        pipe.params = .{
            .rows = chunk_count,
            .x_off = shares.partials_offset,
            .z_off = shares.factor_offset,
            .loss_weight = share,
        };
        pipe.run("share_factor", 1);
        pipe.params = .{
            .count = shares.params_count,
            .w_off = shares.params_start,
            .x_off = shares.factor_offset + 1,
            .y_off = shares.sum_offset,
            .col = if (is_first) 0 else 1,
        };
        pipe.run("add_scaled_gradients", shares.params_count);
    }

    /// The summed gradient over the range, where the optimiser reads it.
    pub fn finish(
        shares: TeacherShares,
        comptime M: type,
        pipe: *compute_host.Compute(M),
    ) void {
        pipe.params = .{
            .count = shares.params_count,
            .w_off = shares.params_start,
            .y_off = shares.sum_offset,
        };
        pipe.run("gradients_from_sum", shares.params_count);
    }
};

// ============================================================================================================

/// THE FLOW POLICY ON THE KIT - `zimrrl.FlowPolicy`'s sampler and training gradients in the kit's kernels, over the
/// same velocity network (a `KitNetwork` built from the flow's own `Mlp`, so the CPU reference's numbers carry over
/// unchanged).
///
/// ---- THE WIDE ROWS ----
///
/// The velocity network reads rows [condition | x | time features]: the condition what the policy observes, x the
/// point on the flow's path, the time as `time_frequencies` sine-cosine pairs (`zn_mlp.flow_time_features`). A row's
/// x columns start at `condition_width`, its time columns after them.
///
/// ---- SAMPLING (`Sampler`, `sample`) ----
///
///     block 0   [ c | x_0 = the noise | time 0 ]  --v-->  Euler step  -->  block 1's x columns
///     block 1   [ c | x_1             | time 1/K ] --v-->  Euler step  -->  block 2's x columns
///     ...
///     block K-1 [ c | x_(K-1)         | time (K-1)/K ] --v--> Euler step --> the action, wherever the caller reads it
///
/// One forward-only application of the network per step, each on its own block, so every step's activations stay
/// where they are for whoever looks at them. Nothing differentiates through the chain: FlowDPG does not need it.
///
/// ---- TRAINING (`Trainer`) ----
///
/// One application, forward and backward, on the training rows: each row's point on its straight path from its noise
/// to its action at its own time (`flow_path_points`), the velocity there, and either the flow matching gradient
/// (`mse_bwd` against the path's velocity) or FlowDPG's (`flow_dpg_bwd`, with the cost's gradient at each action);
/// then back through the network into its weights' gradients.
pub fn KitFlow(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        pub const Pipe = Network.Pipe;

        pub const Options = struct {
            euler_steps: u32 = 4,
            time_frequencies: u32 = 3,
        };

        network: Network,
        condition_width: u32,
        action_width: u32,
        options: Options,

        /// A flow over the velocity network `velocity_mlp`, placed in `layout`. Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            velocity_mlp: zn.Mlp(f32),
            condition_width: u32,
            action_width: u32,
            options: Options,
        ) !Self {
            // At least one Euler step: with none, the sampler would never write its action.
            assertf(options.euler_steps >= 1, @src(), "a flow needs at least one Euler step", .{});
            const network: Network = try .init(arena, layout, velocity_mlp);
            const flow: Self = .{
                .network = network,
                .condition_width = condition_width,
                .action_width = action_width,
                .options = options,
            };
            const expected_input_width: u32 = flow.wideRowWidth();
            const matches_network: bool = network.inputWidth() == expected_input_width;
            assertf(matches_network, @src(), "the velocity network reads {d} inputs, the flow's rows are {d} wide", .{
                network.inputWidth(),
                expected_input_width,
            });
            return flow;
        }

        /// A wide row's width: the condition, the point, the time features.
        pub fn wideRowWidth(flow: Self) u32 {
            return flow.condition_width + flow.action_width + 2 * flow.options.time_frequencies;
        }

        /// Where a wide row's point and its time features begin.
        pub fn pointColumn(flow: Self) u32 {
            return flow.condition_width;
        }

        pub fn timeColumn(flow: Self) u32 {
            return flow.condition_width + flow.action_width;
        }

        /// A sampler over `rows` rows: one wide-row block and one forward-only application per Euler step.
        pub const Sampler = struct {
            rows: u32,
            blocks_at: []const u32,
            applications: []const Network.Application,
        };

        /// A sampler for `rows` rows (`Sampler`), its regions reserved in `layout`. Memory: `arena`.
        pub fn initSampler(
            flow: Self,
            arena: Allocator,
            layout: *KitLayout,
            rows: u32,
        ) !Sampler {
            const step_count: u32 = flow.options.euler_steps;
            const blocks_at: []u32 = try arena.alloc(u32, step_count);
            const applications: []Network.Application = try arena.alloc(Network.Application, step_count);
            for (blocks_at, applications) |*block_at, *step_application| {
                block_at.* = layout.reserveActs(rows * flow.wideRowWidth());
                step_application.* = try flow.network.forwardOnlyApplication(arena, layout, rows);
            }
            const sampler: Sampler = .{ .rows = rows, .blocks_at = blocks_at, .applications = applications };
            return sampler;
        }

        /// The sampler's conditions [rows, condition] written into every block's condition columns, and the noise
        /// [rows, action] - already at its scale - into the first block's point columns, in the host's copy of acts.
        pub fn writeSamplerInputs(
            flow: Self,
            host_acts: []f32,
            sampler: Sampler,
            conditions: []const f32,
            noise: []const f32,
        ) void {
            const width: u32 = flow.wideRowWidth();
            const condition_width: usize = flow.condition_width;
            const action_width: usize = flow.action_width;
            for (sampler.blocks_at, 0..) |block_at, block_index| {
                for (0..sampler.rows) |row| {
                    const row_start: usize = block_at + row * width;
                    const row_condition: []const f32 = conditions[row * condition_width ..][0..condition_width];
                    @memcpy(host_acts[row_start..][0..condition_width], row_condition);
                    if (block_index == 0) {
                        const point_start: usize = row_start + condition_width;
                        const row_noise: []const f32 = noise[row * action_width ..][0..action_width];
                        @memcpy(host_acts[point_start..][0..action_width], row_noise);
                    }
                }
            }
        }

        /// THE SAMPLER (this type's head): K Euler steps from the noise in the first block, the action written to
        /// `destination` - packed rows of its own (`RowColumns.packedRows`), or the action columns of whatever rows
        /// read it next (a world model's wide rows, say, which then need no copy).
        ///
        /// Worked, for K = 4: the first block holds each row's noise x_0; step 0 writes time 0's features, applies the
        /// velocity network to the block, and writes x_1 = x_0 + v / 4 into the second block's point columns; steps 1
        /// and 2 do the same from their blocks at times 1/4 and 1/2; step 3, at time 3/4, writes x_4 - the action -
        /// to the destination instead of a fifth block. Four applications, four blocks, one action per row.
        pub fn sample(
            flow: Self,
            pipe: *Pipe,
            sampler: Sampler,
            destination: RowColumns,
        ) void {
            // The Euler step writes into the activations; an action is never written into a gradient.
            const into_activations: bool = destination.buffer == .activations;
            assertf(into_activations, @src(), "sample: the action is written into the activations", .{});
            const width: u32 = flow.wideRowWidth();
            const step_count: u32 = flow.options.euler_steps;
            const step_size: f32 = 1.0 / float(step_count);
            for (sampler.blocks_at, sampler.applications, 0..) |block_at, step_application, step_index| {
                const step_number: u32 = @intCast(step_index);
                const step_time: f32 = float(step_number) * step_size;
                pipe.params = .{
                    .rows = sampler.rows,
                    .y_off = block_at,
                    .stride = width,
                    .col = flow.timeColumn(),
                    .flow_time = step_time,
                    .flow_time_per_row = 0,
                    .flow_frequencies = flow.options.time_frequencies,
                };
                pipe.run("flow_time_features", sampler.rows * flow.options.time_frequencies);
                step_application.forward(pipe, block_at, width);
                // The next point: the next block's point columns, or, after the last step, the action's place.
                const is_last_step: bool = step_number + 1 == step_count;
                const destination_at: u32 = if (is_last_step) destination.offset else sampler.blocks_at[step_index + 1];
                const destination_stride: u32 = if (is_last_step) destination.row_stride else width;
                const destination_column: u32 = if (is_last_step) destination.first_column else flow.pointColumn();
                pipe.params = .{
                    .rows = sampler.rows,
                    .count = flow.action_width,
                    .x_off = block_at,
                    .stride = width,
                    .col = flow.pointColumn(),
                    .z_off = step_application.outputsOffset(),
                    .y_off = destination_at,
                    .flow_step = step_size,
                    .destination_stride = destination_stride,
                    .destination_column = destination_column,
                };
                pipe.run("flow_euler_step", sampler.rows * flow.action_width);
            }
        }

        /// THE SAMPLER ON THE HOST, for one row: K Euler steps from `noise` (already at its scale) for `condition`, the
        /// action into `action` - from `params` laid out as the kit lays them (a mirror of the device's weights),
        /// every step as `sample` computes it on the kit. `input_scratch` holds one wide row (`wideRowWidth`),
        /// `layer_scratch` two of the network's widest outputs, `velocity_scratch` one velocity (the action's width).
        pub fn sampleHost(
            flow: Self,
            params: []const f32,
            condition: []const f32,
            noise: []const f32,
            input_scratch: []f32,
            layer_scratch: []f32,
            velocity_scratch: []f32,
            action: []f32,
        ) void {
            const condition_width: usize = flow.condition_width;
            const action_width: usize = flow.action_width;
            const step_count: u32 = flow.options.euler_steps;
            const step_size: f32 = 1.0 / float(step_count);
            @memcpy(input_scratch[0..condition_width], condition);
            const point: []f32 = input_scratch[condition_width..][0..action_width];
            @memcpy(point, noise);
            const time_feature_count: usize = 2 * flow.options.time_frequencies;
            const time_features: []f32 = input_scratch[condition_width + action_width ..][0..time_feature_count];
            for (0..step_count) |step_index| {
                const step_time: f32 = float(step_index) * step_size;
                // The time features as `flow_time_features` writes them: sin and cos of pi 2^p t.
                for (0..flow.options.time_frequencies) |pair| {
                    const frequency: f32 = @floatFromInt(@as(u32, 1) << @intCast(pair));
                    const angle_rad: f32 = pi * frequency * step_time;
                    time_features[2 * pair] = sinRad(angle_rad);
                    time_features[2 * pair + 1] = cosRad(angle_rad);
                }
                const wide_row: []const f32 = input_scratch[0..flow.wideRowWidth()];
                flow.network.forwardHost(params, wide_row, layer_scratch, velocity_scratch);
                // The Euler step, as `flow_euler_step`: the point moved by the step times the velocity.
                for (point, velocity_scratch[0..action_width]) |*point_value, velocity| {
                    point_value.* += step_size * velocity;
                }
            }
            @memcpy(action, point);
        }

        /// Training over `rows` rows: the wide rows, the network's application on them (forward and backward), and
        /// every row's action, noise, time, path velocity and cost gradient (packed), and the velocity's gradient.
        pub const Trainer = struct {
            rows: u32,
            wide_rows_at: u32,
            application: Network.Application,
            actions_at: u32,
            noise_at: u32,
            times_at: u32,
            path_velocities_at: u32,
            cost_gradients_at: u32,
            velocity_gradient_at: u32,
        };

        /// A trainer for `rows` rows (`Trainer`), its regions reserved in `layout`. Memory: `arena`.
        pub fn initTrainer(
            flow: Self,
            arena: Allocator,
            layout: *KitLayout,
            rows: u32,
        ) !Trainer {
            const packed_floats: u32 = rows * flow.action_width;
            const trainer: Trainer = .{
                .rows = rows,
                .wide_rows_at = layout.reserveActs(rows * flow.wideRowWidth()),
                .application = try flow.network.application(arena, layout, rows),
                .actions_at = layout.reserveActs(packed_floats),
                .noise_at = layout.reserveActs(packed_floats),
                .times_at = layout.reserveActs(rows),
                .path_velocities_at = layout.reserveActs(packed_floats),
                .cost_gradients_at = layout.reserveActs(packed_floats),
                .velocity_gradient_at = layout.reserveDacts(packed_floats),
            };
            return trainer;
        }

        /// The training rows' points and velocity: each row's point on its path at its own time, its time features,
        /// the network's velocity there - the forward both gradients start from.
        fn trainingForward(flow: Self, pipe: *Pipe, trainer: Trainer) void {
            const width: u32 = flow.wideRowWidth();
            pipe.params = .{
                .rows = trainer.rows,
                .count = flow.action_width,
                .x_off = trainer.actions_at,
                .z_off = trainer.noise_at,
                .t_off = trainer.times_at,
                .y_off = trainer.wide_rows_at,
                .stride = width,
                .col = flow.pointColumn(),
                .u_off = trainer.path_velocities_at,
            };
            pipe.run("flow_path_points", trainer.rows * flow.action_width);
            pipe.params = .{
                .rows = trainer.rows,
                .y_off = trainer.wide_rows_at,
                .stride = width,
                .col = flow.timeColumn(),
                .t_off = trainer.times_at,
                .flow_time_per_row = 1,
                .flow_frequencies = flow.options.time_frequencies,
            };
            pipe.run("flow_time_features", trainer.rows * flow.options.time_frequencies);
            trainer.application.forward(pipe, trainer.wide_rows_at, width);
        }

        /// THE FLOW MATCHING GRADIENT: `weight` x the mean |v - (a - x_0)|^2 over the training rows, into the
        /// network's weights' gradients - written over them, or added to what another teacher left there
        /// (`parameter_gradients`). The rows' conditions must be in the wide rows, and their actions, noise and
        /// times in place.
        ///
        /// It is how a flow DISTILLS a set of actions - a planner's answers, say: its minimum is the field whose flow
        /// carries the noise onto the actions' distribution, so actions that differ for the same condition - a step to
        /// the left and a step to the right - stay apart, each reached from its share of the noise, where a regression
        /// would learn their average, and between a step left and a step right is no step at all.
        pub fn flowMatchingGradient(
            flow: Self,
            pipe: *Pipe,
            trainer: Trainer,
            weight: f32,
            parameter_gradients: ParameterGradients,
        ) void {
            flow.trainingForward(pipe, trainer);
            pipe.params = .{
                .rows = trainer.rows,
                .out_dim = flow.action_width,
                .y_off = trainer.application.outputsOffset(),
                .t_off = trainer.path_velocities_at,
                .dy_off = trainer.velocity_gradient_at,
                .loss_weight = weight,
            };
            pipe.run("mse_bwd", trainer.rows * flow.action_width);
            flow.trainingBackward(pipe, trainer, parameter_gradients);
        }

        /// EACH EXAMPLE'S FLOW MATCHING LOSS, AVERAGED OVER ITS DRAWS - FPO's stand-in for an action's negative
        /// log-likelihood (`zimrrl.FlowPolicy.drawLosses`, whose arithmetic this follows), into acts at `losses_at`,
        /// one per example. The trainer's rows hold `draws` consecutive rows per example - the example's condition in
        /// each wide row and its action in each action row, every row with a noise and a time of its own - so it has
        /// `trainer.rows / draws` examples. The training forward over every row (`trainingForward`), then each
        /// example's mean over its draws of the squared error summed over the action's numbers (`flow_draw_losses`).
        /// Computed at the weights an update starts from, these are FPO's OLD losses; on the same rows and draws after
        /// the weights move, its new ones - the same draws for both, so their ratio is exactly 1 while nothing has
        /// changed.
        pub fn drawLosses(
            flow: Self,
            pipe: *Pipe,
            trainer: Trainer,
            draws: u32,
            losses_at: u32,
        ) void {
            const whole_examples: bool = draws > 0 and trainer.rows % draws == 0;
            assertf(whole_examples, @src(), "{d} rows are not whole examples of {d} draws", .{ trainer.rows, draws });
            const examples: u32 = trainer.rows / draws;
            flow.trainingForward(pipe, trainer);
            pipe.params = .{
                .rows = examples,
                .count = draws,
                .out_dim = flow.action_width,
                .y_off = trainer.application.outputsOffset(),
                .t_off = trainer.path_velocities_at,
                .x_off = losses_at,
            };
            pipe.run("flow_draw_losses", examples);
        }

        /// FPO'S GRADIENT (`zimrrl.fpoLoss`): `weight` x PPO's clipped surrogate for a flow, into the network's
        /// weights' gradients - written over them, or added to what another teacher left (`parameter_gradients`). The
        /// trainer's rows hold `draws` consecutive draws per example, exactly as they held them when the OLD losses
        /// (`numbers.old_losses_at`) were taken (`drawLosses`); the NEW losses are taken here on the same rows at the
        /// current weights (into `numbers.new_losses_at`) - so their ratio is exactly 1 until the weights have moved.
        /// Then `fpo_velocity_gradient` (its comment derives it) with the advantages and the `clip`, and back through
        /// the network.
        pub fn fpoGradient(
            flow: Self,
            pipe: *Pipe,
            trainer: Trainer,
            draws: u32,
            numbers: FpoNumbers,
            clip: f32,
            weight: f32,
            parameter_gradients: ParameterGradients,
        ) void {
            flow.drawLosses(pipe, trainer, draws, numbers.new_losses_at);
            const examples: u32 = trainer.rows / draws;
            pipe.params = .{
                .rows = examples,
                .count = draws,
                .out_dim = flow.action_width,
                .y_off = trainer.application.outputsOffset(),
                .t_off = trainer.path_velocities_at,
                .x_off = numbers.old_losses_at,
                .u_off = numbers.new_losses_at,
                .v_off = numbers.advantages_at,
                .dy_off = trainer.velocity_gradient_at,
                .loss_weight = weight,
                .clip = clip,
            };
            pipe.run("fpo_velocity_gradient", trainer.rows * flow.action_width);
            flow.trainingBackward(pipe, trainer, parameter_gradients);
        }

        /// Where FPO's per-example numbers are, in acts, [examples] each: the old losses (taken at the round's
        /// start), the new (taken by `fpoGradient` itself), and the advantages.
        pub const FpoNumbers = struct {
            old_losses_at: u32,
            new_losses_at: u32,
            advantages_at: u32,
        };

        /// FLOWDPG'S GRADIENT (`zimrrl.FlowPolicy.flowDpgTargets`): the velocity regressed toward the target with the
        /// cost's gradient at each action (in the trainer's `cost_gradients_at`) - a step of `step_share` of the
        /// flow's own motion, or of `step_floor` when it moves less - plus `anchor` times the flow matching term,
        /// into the network's weights' gradients, written over them or added (`parameter_gradients`).
        pub fn flowDpgGradient(
            flow: Self,
            pipe: *Pipe,
            trainer: Trainer,
            step_share: f32,
            step_floor: f32,
            anchor: f32,
            parameter_gradients: ParameterGradients,
        ) void {
            flow.trainingForward(pipe, trainer);
            pipe.params = .{
                .rows = trainer.rows,
                .count = flow.action_width,
                .x_off = trainer.application.outputsOffset(),
                .u_off = trainer.path_velocities_at,
                .v_off = trainer.cost_gradients_at,
                .t_off = trainer.times_at,
                .dy_off = trainer.velocity_gradient_at,
                .flow_step_share = step_share,
                .flow_step_floor = step_floor,
                .flow_anchor = anchor,
            };
            pipe.run("flow_dpg_bwd", trainer.rows);
            flow.trainingBackward(pipe, trainer, parameter_gradients);
        }

        /// Back through the network from the velocity's gradient into its weights' gradients - over them, or added.
        fn trainingBackward(
            flow: Self,
            pipe: *Pipe,
            trainer: Trainer,
            parameter_gradients: ParameterGradients,
        ) void {
            trainer.application.backward(
                pipe,
                trainer.rows,
                trainer.wide_rows_at,
                flow.wideRowWidth(),
                trainer.velocity_gradient_at,
                parameter_gradients,
            );
        }
    };
}
