//! robot_bmpc_kit - EfficientTDMPC's world model on the GPU learning kit (`gpu/zn_mlp.zig`): on a device, or on the
//! kit's CPU twin, which runs the very same kernel code on the host.
//!
//! `robot_bmpc` is the CPU agent: zimrnum's graph records every operation and differentiates it, which is clear and
//! easy to check, and slow. This file lays the same world model out for the kit's kernels, so that the agent can train
//! where the compute is. It builds on `kit_mlp`'s one definition of a network on the kit - `KitLayout` (where every
//! number lives) and `KitNetwork` (a zimrnum `Mlp` placed in the kit's buffers, with its applications; `kit_mlp`'s
//! head explains the buffers, the network against its applications, and one layer's kernels) - and adds what is
//! EfficientTDMPC's own:
//!
//!     KitRollout       the world model on a replay window: the encoder, every dynamics head unrolled through the
//!                      window, and the consistency loss back-propagated through time
//!     KitWorldModel    the rollout with its reward and value heads, the whole loss, and the optimiser's update

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const zrl = @import("zrl");
const kit_mlp = @import("kit_mlp.zig");
const bmpc = @import("robot_bmpc.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const KitLayout = kit_mlp.KitLayout;
const KitNetwork = kit_mlp.KitNetwork;
const LayerRegions = kit_mlp.LayerRegions;
const ParameterGradients = kit_mlp.ParameterGradients;
const assertf = zm.assertf;
const float = zm.float;

// ============================================================================================================
// SHARED DISPATCHES
// ============================================================================================================

/// What `place_columns` copies: `rows` packed rows of `count` values from acts at `source_offset`, into columns
/// `first_column` .. `first_column` + `count` of the rows `row_stride` floats apart at acts `destination_offset`.
/// EfficientTDMPC's networks read WIDE ROWS [ z | a ] - a latent and an action side by side - so most placements are
/// a latent into a wide row's z columns (first column 0) or an action into its a columns (first column the latent's
/// width):
///
///     packed latents  [ z_0 ]                   wide rows   [ z_0 | a_0 ]
///                     [ z_1 ]   --placement-->              [ z_1 | a_1 ]       row_stride = latent + action
///                     [ z_2 ]                               [ z_2 | a_2 ]
pub const ColumnPlacement = struct {
    rows: u32,
    count: u32,
    source_offset: u32,
    destination_offset: u32,
    row_stride: u32,
    first_column: u32,
};

/// `placement`'s copy (`place_columns`), one thread per value copied.
pub fn placeColumns(
    comptime M: type,
    pipe: *KitNetwork(M).Pipe,
    placement: ColumnPlacement,
) void {
    pipe.params = .{
        .rows = placement.rows,
        .count = placement.count,
        .x_off = placement.source_offset,
        .y_off = placement.destination_offset,
        .stride = placement.row_stride,
        .col = placement.first_column,
    };
    const value_count: u32 = placement.rows * placement.count;
    pipe.run("place_columns", value_count);
}

/// The bins a two-hot head predicts over (`zimrnum.CategoricalScalar`): BMPC's 101 on [-10, 10] of the symlog axis.
pub fn TwoHotBins(comptime M: type) type {
    return struct {
        low: f32 = -10,
        high: f32 = 10,
        axis: M.TwoHotAxis = .symlog,
    };
}

/// A two-hot head's logits read back as numbers, one per row (`twohot_decode`): each row's softmax-weighted mean bin
/// position, taken back from the bins' axis - what `CategoricalScalar.decodeRows` computes on the host - into acts at
/// `values_offset`. How the value targets and the planner's scorer read their rewards and values.
pub fn decodeTwoHotRows(
    comptime M: type,
    pipe: *KitNetwork(M).Pipe,
    head_pass: KitNetwork(M).Application,
    bins: TwoHotBins(M),
    values_offset: u32,
) void {
    const row_count: u32 = head_pass.row_count;
    pipe.params = .{
        .rows = row_count,
        .out_dim = head_pass.network.outputWidth(),
        .x_off = head_pass.outputsOffset(),
        .y_off = values_offset,
        .twohot_low = bins.low,
        .twohot_high = bins.high,
        .twohot_axis = @backingInt(bins.axis),
    };
    pipe.run("twohot_decode", row_count);
}

/// The device's acts as of every dispatch made so far - for a result the host needs NOW (a decision's actions, to step
/// the environments; reanalyze's targets, to write into the replay). On the CPU twin the readback is always current. On
/// a device the readback lands a frame or more after the dispatches it reflects, and a read taken before it caught up
/// would return the previous update's numbers as if they were this one's: such a read is refused, loudly, naming
/// `what` - the caller must wait until the readback is current (`readGeneration`) before asking.
fn readCurrentActs(
    comptime M: type,
    pipe: *KitNetwork(M).Pipe,
    what: []const u8,
) ![]const f32 {
    const generation: KitNetwork(M).Pipe.Generation = pipe.readGeneration();
    const readback_is_current: bool = generation.mirrored >= generation.submitted;
    const dispatches_behind: u64 = generation.submitted -| generation.mirrored;
    assertf(readback_is_current, @src(), "{s}: the readback is {d} dispatches behind", .{ what, dispatches_behind });
    const device_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    return device_acts;
}

/// The `floats` values at `offset` of the host's copy of acts, uploaded to the same place on the device. A learner's
/// writers fill regions of the host's copy, and each region goes up on its own: the rest of acts holds state the
/// device keeps and the host does not mirror - the running scale, a planner's Gaussians - which a whole upload would
/// overwrite.
fn uploadActsRegion(
    comptime M: type,
    pipe: *KitNetwork(M).Pipe,
    host_acts: []const f32,
    offset: u32,
    floats: u32,
) void {
    pipe.uploadAt(.acts, offset, host_acts[offset..][0..floats]);
}

// ============================================================================================================
// THE WORLD MODEL'S ROLLOUT
// ============================================================================================================

/// THE LATENT ROLLOUT ON THE KIT - zimrrl's `LatentRollout`, the same arithmetic laid out for the kernels.
///
/// ---- WHAT IT COMPUTES ----
///
/// A replay WINDOW is `horizon` consecutive steps of a character, taken `window_count` times side by side: the first
/// observation, the actions really taken, and each step's next observation. The world model is trained to predict,
/// from the first observation's latent alone, the latents of everything that followed:
///
///     z_0      = encoder(o_0)                         the first observation's latent
///     z*_(t+1) = encoder(n_t)                         what really followed step t, as a latent - the TARGET
///     z_(t+1)  = head(z_t, a_t)                       each dynamics head's PREDICTION, rolled from z_0
///
///     consistency = mean over heads of  sum over t of  rho^t / H x mean over the window's values of
///                                                      (z_(t+1) - z*_(t+1))^2
///
/// rho^t (BMPC's rho = 0.5) trusts a step's error less the more predicted steps it stands on. The targets are held
/// fixed - no gradient flows into the encoder through them - or the cheapest agreement would be to encode every
/// observation to one point.
///
/// ---- THE LAYOUT ----
///
///     acts:  observations    [ o_0 | n_0 | n_1 | ... | n_(H-1) ]       (H + 1) x W rows, step-major
///            encoder pass    [ z_0 | z*_1 | z*_2 | ... | z*_H  ]       the same rows, encoded once
///            per head h, per step t:
///              wide row      X_t  = [ z_t | a_t ]                     W rows of latent + action
///              application   head_h(X_t) -> z_(t+1)                   its own regions, for the backward
///     dacts: per head h, per step t: the gradient at z_(t+1)
///            the gradient at z_0, summed over the heads
///
/// ---- THE FORWARD ----
///
/// The encoder runs once over the whole window. Then every head is rolled, one step after another, the steps joined
/// by `place_columns`, which copies a latent into the z columns of a wide row:
///
///     encoder pass --z_0--> X_0 = [z_0|a_0] -head-> z_1 --> X_1 = [z_1|a_1] -head-> z_2 --> X_2 -head-> z_3
///                                                    |                              |                  |
///                     consistency at each step:  vs z*_1                         vs z*_2            vs z*_3
///
/// ---- THE BACKWARD: BACK-PROPAGATION THROUGH TIME ----
///
/// A prediction z_(t+1) matters twice: its own consistency error, and - unless it is the last - as the input of the
/// next step, through which it shapes every later prediction. So its gradient arrives by two roads, and the steps
/// are walked in reverse, the later step's road known by the time an earlier step needs it:
///
///     step t = H-1 .. 0:
///       d z_(t+1)  =  this step's consistency gradient                         mse_bwd, weighted
///                  +  the z columns of d X_(t+1), the next step's input        lat_take (after the last step)
///                  +  what every other READER of z_(t+1) took back             lat_take, one per reader - the
///                                                                              reward and value heads
///       d X_t      =  back through the head at step t                          its weight gradients ADDED to
///                                                                              the steps after's
///
///     the z columns of d X_0 are this head's share of d z_0; summed over the heads, they back-propagate through
///     the encoder - over the first block's rows only, the targets taking no gradient
pub fn KitRollout(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        pub const Pipe = Network.Pipe;

        pub const Options = struct {
            /// H: the steps of each window - H actions, H + 1 observations.
            horizon: u32,
            /// W: the windows rolled side by side.
            window_count: u32,
            observation_width: u32,
            action_width: u32,
            /// The consistency's per-step weight is rho^t (BMPC's 0.5).
            rho: f32 = 0.5,
        };

        /// Another application that READ a latent of the rollout: its inputs began with z_t, in the latent columns
        /// of rows `inputs_row_stride` floats apart - a reward head reading the wide row [z_t | a_t], a value head
        /// reading its z columns alone. Its input gradient's latent columns are more gradient at z_t, which the
        /// backward adds where z_t's gradient is gathered (`addLatentReader`).
        pub const LatentReader = struct {
            inputs_gradient_offset: u32,
            inputs_row_stride: u32,
        };

        /// One dynamics head on the window (this type's head): a wide row, an application and a prediction
        /// gradient for every step.
        pub const DynamicsHead = struct {
            network: Network,
            /// acts: X_t = [ z_t | a_t ], [window_count, latent + action], for each step t < horizon.
            wide_row_offsets: []u32,
            /// The head applied at each step t, reading X_t.
            step_applications: []Network.Application,
            /// dacts: the gradient at z_(t+1), [window_count, latent], for each step t < horizon.
            prediction_gradient_offsets: []u32,
            /// The other applications that read z_t, for each t <= horizon (`LatentReader`).
            latent_readers: []ArrayList(LatentReader),
        };

        options: Options,
        latent_width: u32,
        /// acts: [ o_0 | n_0 | ... | n_(H-1) ], (horizon + 1) x window_count rows of the observation, step-major.
        observations_offset: u32,
        /// The encoder applied to every observation of the window at once.
        encoder_pass: Network.Application,
        dynamics_heads: []DynamicsHead,
        /// dacts: the gradient at z_0, [window_count, latent] - every head's share summed.
        first_latent_gradient_offset: u32,
        /// acts: which windows still count at each step, [horizon x window_count] step-major - 1 while a window's
        /// episode runs, 0 once an earlier step ended it - and each step's mean factor, [horizon]: window_count / the
        /// windows still counting (0 when none is). Every loss of the window reads them (`zn_mlp.RowMask`), as every
        /// loss of the CPU agent's reads `LatentRollout`'s own columns. `writeWindow` sets them to "nothing
        /// finished", `writeFinished` to a replay batch's flags.
        counting_offset: u32,
        mean_factors_offset: u32,

        /// The rollout's regions reserved in `layout` - for `encoder` and `dynamics_networks`, whose parameters
        /// are already placed. Memory: the lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            encoder: Network,
            dynamics_networks: []const Network,
            options: Options,
        ) !Self {
            const horizon: u32 = options.horizon;
            const window_count: u32 = options.window_count;
            const latent_width: u32 = encoder.outputWidth();
            const wide_row_width: u32 = latent_width + options.action_width;
            const observation_rows: u32 = (horizon + 1) * window_count;
            const observations_offset: u32 = layout.reserveActs(observation_rows * options.observation_width);
            const encoder_pass: Network.Application = try encoder.application(arena, layout, observation_rows);
            const dynamics_heads: []DynamicsHead = try arena.alloc(DynamicsHead, dynamics_networks.len);
            for (dynamics_heads, dynamics_networks) |*dynamics_head, dynamics_network| {
                const wide_row_offsets: []u32 = try arena.alloc(u32, horizon);
                const step_applications: []Network.Application = try arena.alloc(Network.Application, horizon);
                const prediction_gradient_offsets: []u32 = try arena.alloc(u32, horizon);
                const latent_readers: []ArrayList(LatentReader) = try arena.alloc(
                    ArrayList(LatentReader),
                    horizon + 1,
                );
                @memset(latent_readers, .empty);
                for (wide_row_offsets, step_applications, prediction_gradient_offsets) |*wide_row, *step, *gradient| {
                    wide_row.* = layout.reserveActs(window_count * wide_row_width);
                    step.* = try dynamics_network.application(arena, layout, window_count);
                    gradient.* = layout.reserveDacts(window_count * latent_width);
                }
                dynamics_head.* = .{
                    .network = dynamics_network,
                    .wide_row_offsets = wide_row_offsets,
                    .step_applications = step_applications,
                    .prediction_gradient_offsets = prediction_gradient_offsets,
                    .latent_readers = latent_readers,
                };
            }
            const first_latent_gradient_offset: u32 = layout.reserveDacts(window_count * latent_width);
            const counting_offset: u32 = layout.reserveActs(horizon * window_count);
            const mean_factors_offset: u32 = layout.reserveActs(horizon);
            const rollout: Self = .{
                .options = options,
                .latent_width = latent_width,
                .observations_offset = observations_offset,
                .encoder_pass = encoder_pass,
                .dynamics_heads = dynamics_heads,
                .first_latent_gradient_offset = first_latent_gradient_offset,
                .counting_offset = counting_offset,
                .mean_factors_offset = mean_factors_offset,
            };
            return rollout;
        }

        /// Another application whose inputs begin with head `head_index`'s z_`step` (`LatentReader`): its gradient
        /// joins z_step's in the backward. Memory: the reader list grows in `arena`.
        pub fn addLatentReader(
            rollout: Self,
            arena: Allocator,
            head_index: usize,
            step: usize,
            reader: LatentReader,
        ) !void {
            const readers: *ArrayList(LatentReader) = &rollout.dynamics_heads[head_index].latent_readers[step];
            try readers.append(arena, reader);
        }

        /// A wide row's width: the latent, then the action.
        pub fn wideRowWidth(rollout: Self) u32 {
            return rollout.latent_width + rollout.options.action_width;
        }

        /// Where the encoder's latents of step `step`'s observations are in acts: z_0 at step 0, the target z*_step
        /// after - [window_count, latent].
        pub fn encodedLatentsOffset(rollout: Self, step: u32) u32 {
            const step_floats: u32 = rollout.options.window_count * rollout.latent_width;
            return rollout.encoder_pass.outputsOffset() + step * step_floats;
        }

        /// A window written into the host's copy of acts, before it is uploaded: the observations as `LatentRollout`
        /// takes them ([(horizon + 1) x window_count, observation], step-major), and each step's actions
        /// ([horizon x window_count, action], step-major) into the action columns of every head's wide rows - beside
        /// the z columns the forward fills - with every window counting (`writeFinished` marks the ones that are not).
        pub fn writeWindow(
            rollout: Self,
            acts: []f32,
            observations: []const f32,
            actions: []const f32,
        ) void {
            const options: Options = rollout.options;
            @memcpy(acts[rollout.observations_offset..][0..observations.len], observations);
            // Nothing finished, until `writeFinished` says otherwise: every window counts, every factor is 1.
            @memset(acts[rollout.counting_offset..][0 .. options.horizon * options.window_count], 1);
            @memset(acts[rollout.mean_factors_offset..][0..options.horizon], 1);
            const wide_row_width: u32 = rollout.wideRowWidth();
            for (rollout.dynamics_heads) |dynamics_head| {
                for (dynamics_head.wide_row_offsets, 0..) |wide_row_offset, step| {
                    for (0..options.window_count) |window| {
                        const action_start: usize = (step * options.window_count + window) * options.action_width;
                        const action: []const f32 = actions[action_start..][0..options.action_width];
                        const row_start: usize = wide_row_offset + window * wide_row_width;
                        const action_columns_start: usize = row_start + rollout.latent_width;
                        @memcpy(acts[action_columns_start..][0..options.action_width], action);
                    }
                }
            }
        }

        /// What `writeWindow` wrote, uploaded from the host's copy of acts: the observations, and every head's wide
        /// rows (their z columns too, which the forward overwrites).
        pub fn uploadWindow(rollout: Self, pipe: *Pipe, host_acts: []const f32) void {
            const options: Options = rollout.options;
            const observation_floats: u32 = (options.horizon + 1) * options.window_count * options.observation_width;
            uploadActsRegion(M, pipe, host_acts, rollout.observations_offset, observation_floats);
            const wide_row_floats: u32 = options.window_count * rollout.wideRowWidth();
            for (rollout.dynamics_heads) |dynamics_head| {
                for (dynamics_head.wide_row_offsets) |wide_row_offset| {
                    uploadActsRegion(M, pipe, host_acts, wide_row_offset, wide_row_floats);
                }
            }
            rollout.uploadFinished(pipe, host_acts);
        }

        /// What `writeFinished` wrote, uploaded: the counting column and the mean factors.
        pub fn uploadFinished(rollout: Self, pipe: *Pipe, host_acts: []const f32) void {
            const options: Options = rollout.options;
            uploadActsRegion(M, pipe, host_acts, rollout.counting_offset, options.horizon * options.window_count);
            uploadActsRegion(M, pipe, host_acts, rollout.mean_factors_offset, options.horizon);
        }

        /// Which windows still count at step `step`: [window_count] in acts.
        pub fn countingAt(rollout: Self, step: usize) u32 {
            const step_rows: u32 = @as(u32, @intCast(step)) * rollout.options.window_count;
            return rollout.counting_offset + step_rows;
        }

        /// Step `step`'s mean factor: one value in acts.
        pub fn meanFactorAt(rollout: Self, step: usize) u32 {
            return rollout.mean_factors_offset + @as(u32, @intCast(step));
        }

        /// The windows that have FINISHED by each step, written into the host's copy of acts - a replay batch's flags
        /// as `SequenceReplay.sample` gives them (step-major, `horizon x window_count`, 1 where an earlier step of the
        /// window ended its episode, 0 where none has), as `LatentRollout.setFinished` takes them: each window's
        /// counting flag, 1 - finished, and each step's mean factor, window_count / the windows still counting (0
        /// when none is), formed as the CPU agent forms it. Every flag must be exactly 0 or 1.
        pub fn writeFinished(rollout: Self, acts: []f32, finished: []const f32) void {
            const options: Options = rollout.options;
            const window_count_value: f32 = @floatFromInt(options.window_count);
            for (0..options.horizon) |step| {
                const step_flags: []const f32 = finished[step * options.window_count ..][0..options.window_count];
                const counting: []f32 = acts[rollout.countingAt(step)..][0..options.window_count];
                var still_counting: usize = 0;
                for (counting, step_flags) |*window_counting, flag| {
                    const is_flag: bool = flag == 0 or flag == 1;
                    assertf(is_flag, @src(), "KitRollout.writeFinished: a flag of {d}, not 0 or 1", .{flag});
                    window_counting.* = 1 - flag;
                    if (flag == 0) {
                        still_counting += 1;
                    }
                }
                const still_counting_value: f32 = @floatFromInt(still_counting);
                const mean_factor: f32 = if (still_counting == 0) 0 else window_count_value / still_counting_value;
                acts[rollout.meanFactorAt(step)] = mean_factor;
            }
        }

        /// The forward (this type's head): the encoder over the whole window, then every head rolled through it.
        pub fn forward(rollout: Self, pipe: *Pipe) void {
            const wide_row_width: u32 = rollout.wideRowWidth();
            rollout.encoder_pass.forward(pipe, rollout.observations_offset, 0);
            const first_latents_offset: u32 = rollout.encodedLatentsOffset(0);
            for (rollout.dynamics_heads) |dynamics_head| {
                rollout.placeLatents(pipe, first_latents_offset, dynamics_head.wide_row_offsets[0]);
                for (dynamics_head.step_applications, 0..) |step_application, step| {
                    step_application.forward(pipe, dynamics_head.wide_row_offsets[step], wide_row_width);
                    // The prediction becomes the next step's latent - unless this was the last step.
                    const is_last_step: bool = step + 1 == dynamics_head.step_applications.len;
                    if (!is_last_step) {
                        const prediction_offset: u32 = step_application.outputsOffset();
                        const next_wide_row_offset: u32 = dynamics_head.wide_row_offsets[step + 1];
                        rollout.placeLatents(pipe, prediction_offset, next_wide_row_offset);
                    }
                }
            }
        }

        /// The window's latents, [window_count, latent] at `latents_offset`, copied into the z columns of the wide
        /// rows at `wide_row_offset` (`place_columns`).
        fn placeLatents(
            rollout: Self,
            pipe: *Pipe,
            latents_offset: u32,
            wide_row_offset: u32,
        ) void {
            placeColumns(M, pipe, .{
                .rows = rollout.options.window_count,
                .count = rollout.latent_width,
                .source_offset = latents_offset,
                .destination_offset = wide_row_offset,
                .row_stride = rollout.wideRowWidth(),
                .first_column = 0,
            });
        }

        /// The consistency loss's backward, scaled by `loss_scale` (EfficientTDMPC's 20 in its world model's total
        /// loss; 1 for the consistency alone): through time for every head, then into the encoder (this type's
        /// head). The parameters' gradients are written over what grads held: the encoder's, and every head's as
        /// the sum over its steps.
        pub fn backward(rollout: Self, pipe: *Pipe, loss_scale: f32) void {
            for (rollout.dynamics_heads, 0..) |dynamics_head, head_index| {
                rollout.headBackwardThroughTime(pipe, dynamics_head, loss_scale);
                const is_first_head: bool = head_index == 0;
                rollout.collectFirstLatentGradient(pipe, dynamics_head, is_first_head);
            }
            const window_count: u32 = rollout.options.window_count;
            rollout.encoder_pass.backward(
                pipe,
                window_count,
                rollout.observations_offset,
                0,
                rollout.first_latent_gradient_offset,
                .overwrite,
            );
        }

        /// One head's steps in reverse (this type's head, "the backward"): at each step, the gradient at the step's
        /// prediction from its two roads, then back through the head to the step's wide row.
        fn headBackwardThroughTime(
            rollout: Self,
            pipe: *Pipe,
            dynamics_head: DynamicsHead,
            loss_scale: f32,
        ) void {
            const window_count: u32 = rollout.options.window_count;
            const latent_width: u32 = rollout.latent_width;
            const wide_row_width: u32 = rollout.wideRowWidth();
            const horizon: u32 = rollout.options.horizon;
            const latent_value_count: u32 = window_count * latent_width;
            var step: usize = horizon;
            while (step > 0) {
                step -= 1;
                const step_application: Network.Application = dynamics_head.step_applications[step];
                const prediction_gradient_offset: u32 = dynamics_head.prediction_gradient_offsets[step];
                // 1. This step's own consistency error, as its share of the whole loss.
                pipe.params = .{
                    .rows = window_count,
                    .out_dim = latent_width,
                    .y_off = step_application.outputsOffset(),
                    .t_off = rollout.encodedLatentsOffset(@intCast(step + 1)),
                    .dy_off = prediction_gradient_offset,
                    .loss_weight = rollout.stepLossWeight(step, loss_scale),
                    // Only the windows still counting at this step, their mean over themselves.
                    .row_mask = @backingInt(M.RowMask.counting_column),
                    .mask_off = rollout.countingAt(step),
                    .mean_factor_off = rollout.meanFactorAt(step),
                };
                pipe.run("mse_bwd", latent_value_count);
                // 2. The road through the next step: what the next step's input took back through the network, its
                //    z columns added. The last step's prediction feeds nothing.
                const is_last_step: bool = step + 1 == horizon;
                if (!is_last_step) {
                    const next_step_application: Network.Application = dynamics_head.step_applications[step + 1];
                    const next_step_inputs_gradient: u32 = next_step_application.inputsGradientOffset();
                    pipe.params = .{
                        .rows = window_count,
                        .count = latent_width,
                        .stride = wide_row_width,
                        .dx_off = next_step_inputs_gradient,
                        .dy_off = prediction_gradient_offset,
                    };
                    pipe.run("lat_take", latent_value_count);
                }
                // 3. The other networks that read this prediction - the reward and value heads at step t + 1 - add
                //    theirs.
                const readers: []const LatentReader = dynamics_head.latent_readers[step + 1].items;
                rollout.addReadersGradients(pipe, readers, prediction_gradient_offset);
                // 4. Back through the head at this step, to its wide row. Its weights' gradients: the last step's
                //    backward (the first one run) overwrites, every earlier step's adds.
                const parameter_gradients: ParameterGradients = if (is_last_step) .overwrite else .add;
                const wide_row_offset: u32 = dynamics_head.wide_row_offsets[step];
                step_application.backward(
                    pipe,
                    window_count,
                    wide_row_offset,
                    wide_row_width,
                    prediction_gradient_offset,
                    parameter_gradients,
                );
            }
        }

        /// The weight of step `step`'s consistency error in the loss: `loss_scale` x rho^t / H / the head count - the
        /// same factors `LatentRollout` scales by.
        fn stepLossWeight(rollout: Self, step: usize, loss_scale: f32) f32 {
            const step_count: f32 = @floatFromInt(rollout.options.horizon);
            const head_count: f32 = @floatFromInt(rollout.dynamics_heads.len);
            const step_share: f32 = stepWeight(rollout.options.rho, step) / step_count;
            const head_share: f32 = step_share / head_count;
            return loss_scale * head_share;
        }

        /// The latent columns of each reader's input gradient added into the gradient at the latent they read.
        fn addReadersGradients(
            rollout: Self,
            pipe: *Pipe,
            readers: []const LatentReader,
            latent_gradient_offset: u32,
        ) void {
            const window_count: u32 = rollout.options.window_count;
            const latent_value_count: u32 = window_count * rollout.latent_width;
            for (readers) |reader| {
                pipe.params = .{
                    .rows = window_count,
                    .count = rollout.latent_width,
                    .stride = reader.inputs_row_stride,
                    .dx_off = reader.inputs_gradient_offset,
                    .dy_off = latent_gradient_offset,
                };
                pipe.run("lat_take", latent_value_count);
            }
        }

        /// A head's share of the gradient at z_0 - the z columns of its step-0 wide row's gradient - written into the
        /// sum by the first head (`take_columns`) and added to it by the others (`lat_take`), so the sum needs no
        /// zeroed region to start from; then what the head's readers of z_0 took back, added.
        fn collectFirstLatentGradient(
            rollout: Self,
            pipe: *Pipe,
            dynamics_head: DynamicsHead,
            is_first_head: bool,
        ) void {
            const window_count: u32 = rollout.options.window_count;
            const first_step_inputs_gradient: u32 = dynamics_head.step_applications[0].inputsGradientOffset();
            pipe.params = .{
                .rows = window_count,
                .count = rollout.latent_width,
                .stride = rollout.wideRowWidth(),
                .col = 0,
                .dx_off = first_step_inputs_gradient,
                .dy_off = rollout.first_latent_gradient_offset,
            };
            const latent_value_count: u32 = window_count * rollout.latent_width;
            // The kernel's name is the pipe's compile-time choice, so the two joins are two calls.
            if (is_first_head) {
                pipe.run("take_columns", latent_value_count);
            } else {
                pipe.run("lat_take", latent_value_count);
            }
            const readers: []const LatentReader = dynamics_head.latent_readers[0].items;
            rollout.addReadersGradients(pipe, readers, rollout.first_latent_gradient_offset);
        }

        /// rho^t, as `LatentRollout` computes it: a running product from 1, multiplied by rho once per step - the
        /// same multiplications in the same order, so the same bits (a power function could round differently).
        fn stepWeight(rho: f32, step: usize) f32 {
            var weight: f32 = 1;
            for (0..step) |_| {
                weight *= rho;
            }
            return weight;
        }
    };
}

// ============================================================================================================
// THE WORLD MODEL'S WHOLE LOSS
// ============================================================================================================

/// THE WORLD MODEL ON THE KIT - zimrrl's `WorldModelLoss` on a `KitRollout`, the same arithmetic laid out for the
/// kernels.
///
/// ---- WHAT IT ADDS TO THE ROLLOUT ----
///
/// Two more kinds of head, both trained on the ROLLED latents - the states the model actually reaches when it plans -
/// rather than on the encoded ones (value-equivalent, MuZero-style: the heads learn to read the model's own states,
/// its errors and all):
///
///     reward head    at every step t, on [ z_t | a_t ]: the reward received, as a two-hot over the bins
///     value heads    at every step t, each on z_t alone: the step's value target, as a two-hot over the bins
///
/// and the loss becomes BMPC's weighted sum, each term averaged over the dynamics heads:
///
///     total  = 20 x consistency  +  0.1 x reward  +  0.1 x value
///     reward = mean over dynamics heads of  sum over t of  rho^t / H         x CE(reward logits, two-hot r_t)
///     value  = mean over dynamics heads of  sum over t, value heads j of
///                                           rho^t / (H x value heads)       x CE(value logits, two-hot of V*_t)
///
/// CE is the two-hot cross-entropy (`twohot_fwd`), its mean over the window's rows.
///
/// ---- WHERE THE HEADS READ, AND WHERE THEIR GRADIENTS GO ----
///
/// The reward head's input at step t is exactly the dynamics head's input there, so it reads the same wide row X_t.
/// A value head reads the wide row's first latent-width columns through the same stride. Their input gradients'
/// latent columns are therefore more gradient at z_t - which the rollout's backward must add before it uses it -
/// so each head application is registered with the rollout as a READER of its z_t (`KitRollout.addLatentReader`):
///
///     d z_t  =  the rollout's own (consistency, the next step)  +  the reward head's at t  +  each value head's at t
///
/// The heads' own backwards run first, so their input gradients are ready when the backward through time reaches
/// them. Each head's parameter gradients are the sum over every dynamics head and step that applied it: the first
/// application's backward overwrites, every later one adds.
///
/// ---- THE UPDATE ----
///
/// After the backward, one step of the optimiser (`update`), as the CPU agent's world model takes it:
///
///     1. ONE CLIP of the global gradient norm over the whole world model - encoder, dynamics heads, reward head,
///        value heads - at 20: every gradient scaled by the same factor, so the step keeps its direction
///     2. Adam: the encoder at 0.3 x the learning rate, everything else at the rate - everything downstream reads
///        the encoder's latents, so a fast-moving encoder would shift the ground under all of it
///     3. the TARGET value heads follow their online twins 1% of the way (Polyak) - the value targets read them, and
///        a target must not chase the network it is training
///
/// The clip needs the world model's parameters in one contiguous region of params, which is how they are placed:
/// the encoder, the dynamics heads, the reward head and the value heads, one after another, with the target value
/// heads placed after them all.
///
/// ---- NOT YET HERE ----
///
/// BMPC drops out 1% of a value head's first hidden layer during training (`Config.value_dropout`); the kit has no
/// dropout yet, so this world model matches the CPU agent's with that dropout off.
pub fn KitWorldModel(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        const Rollout = KitRollout(M);
        pub const Pipe = Network.Pipe;

        /// The loss's settings: its weights (BMPC's) and the two-hot heads' bins.
        pub const LossOptions = struct {
            consistency_weight: f32 = 20,
            reward_weight: f32 = 0.1,
            value_weight: f32 = 0.1,
            /// The bins the reward and value heads predict over (`TwoHotBins`).
            bins: TwoHotBins(M) = .{},
            /// Whether the value heads drop out while they train (BMPC: 1% of a value head's first layer, its rate
            /// the network's own, `zimrnum.Mlp.Spec.first_dropout`). Each update's masks come from
            /// `writeValueDropoutMasks`.
            value_dropout: kit_mlp.Dropout = .off,
        };

        /// The optimiser's settings: BMPC's.
        pub const UpdateOptions = struct {
            learning_rate: f32 = 3e-4,
            /// The encoder's share of the learning rate.
            encoder_rate_scale: f32 = 0.3,
            /// The limit on the world model's global gradient norm.
            gradient_clip: f32 = 20,
            /// The fraction of the way the target value heads follow their online twins each update.
            target_follow: f32 = 0.01,
            beta1: f32 = 0.9,
            beta2: f32 = 0.999,
            epsilon: f32 = 1e-8,
        };

        /// One two-hot head applied to one latent: the application, and where its logits' gradient and its rows'
        /// losses go.
        pub const HeadApplication = struct {
            application: Network.Application,
            /// dacts: the gradient at the logits, [window_count, bins].
            logits_gradient_offset: u32,
            /// acts: each row's cross-entropy, [window_count] (`twohot_fwd`) - for reading the loss back.
            row_losses_offset: u32,
        };

        rollout: Rollout,
        reward_network: Network,
        value_networks: []const Network,
        /// The value heads' slow copies, placed after the world model's own networks (this type's head).
        target_value_networks: []const Network,
        loss_options: LossOptions,
        /// params: the world model's whole region - encoder, dynamics heads, reward head, value heads - and where the
        /// encoder's part of it ends.
        model_params_start: u32,
        encoder_params_end: u32,
        model_params_end: u32,
        /// The gradients one thread of the clip sums (`grad_square_partials`): enough chunks that a device spreads the
        /// first pass across its cores, few enough that the second, one-thread pass over their totals is short.
        clip_chunk_floats: u32,
        /// acts: the clip's partial sums of squares, one per chunk, and the norm with its factor (two floats).
        clip_partials_offset: u32,
        clip_norm_offset: u32,
        /// acts: the rewards received, [horizon x window_count], step-major - one scalar each.
        rewards_offset: u32,
        /// acts: the value targets, [horizon x window_count], step-major - one scalar each.
        value_targets_offset: u32,
        /// [dynamics head][step]: the reward head on [z_t | a_t].
        reward_applications: [][]HeadApplication,
        /// [dynamics head][step][value head]: each value head on z_t.
        value_applications: [][][]HeadApplication,

        /// The world model's regions reserved in `layout`, on `rollout` (already made) - every head application
        /// registered as a reader of the latent it reads. The networks must have been placed in the order this type's
        /// head gives - the rollout's encoder and dynamics heads, `reward_network`, `value_networks`, then
        /// `target_value_networks` - so the world model's own parameters are one region. Memory: the lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            rollout: Rollout,
            reward_network: Network,
            value_networks: []const Network,
            target_value_networks: []const Network,
            loss_options: LossOptions,
        ) !Self {
            const horizon: u32 = rollout.options.horizon;
            const window_count: u32 = rollout.options.window_count;
            const rewards_offset: u32 = layout.reserveActs(horizon * window_count);
            const value_targets_offset: u32 = layout.reserveActs(horizon * window_count);
            const dynamics_head_count: usize = rollout.dynamics_heads.len;
            const reward_applications: [][]HeadApplication = try arena.alloc([]HeadApplication, dynamics_head_count);
            const value_applications: [][][]HeadApplication = try arena.alloc([][]HeadApplication, dynamics_head_count);
            for (reward_applications, value_applications, 0..) |*head_rewards, *head_values, head_index| {
                head_rewards.* = try arena.alloc(HeadApplication, horizon);
                head_values.* = try arena.alloc([]HeadApplication, horizon);
                for (head_rewards.*, head_values.*, 0..) |*reward_at_step, *values_at_step, step| {
                    // The reward head reads the whole wide row [z_t | a_t]; its gradient's z columns are z_t's.
                    reward_at_step.* = try reserveHeadApplication(arena, layout, reward_network, window_count, .off);
                    try rollout.addLatentReader(arena, head_index, step, .{
                        .inputs_gradient_offset = reward_at_step.application.inputsGradientOffset(),
                        .inputs_row_stride = reward_network.layers[0].input_width,
                    });
                    // Each value head reads the wide row's z columns alone, through its stride.
                    values_at_step.* = try arena.alloc(HeadApplication, value_networks.len);
                    for (values_at_step.*, value_networks) |*value_at_step, value_network| {
                        value_at_step.* = try reserveHeadApplication(
                            arena,
                            layout,
                            value_network,
                            window_count,
                            loss_options.value_dropout,
                        );
                        try rollout.addLatentReader(arena, head_index, step, .{
                            .inputs_gradient_offset = value_at_step.application.inputsGradientOffset(),
                            .inputs_row_stride = value_network.layers[0].input_width,
                        });
                    }
                }
            }
            // The world model's own parameters: from the encoder's first layer to the end of the last value head -
            // one region, which the networks' order guarantees (checked here: the clip and Adam treat it as one
            // block, and a network placed out of order would be skipped or clipped twice); the targets after it.
            const has_value_heads: bool = value_networks.len > 0 and target_value_networks.len == value_networks.len;
            assertf(has_value_heads, @src(), "KitWorldModel: {d} value heads and {d} targets", .{
                value_networks.len,
                target_value_networks.len,
            });
            var expected_start: u32 = rollout.encoder_pass.network.paramsEnd();
            for (rollout.dynamics_heads) |dynamics_head| {
                requirePlacedAt(dynamics_head.network, expected_start, "a dynamics head");
                expected_start = dynamics_head.network.paramsEnd();
            }
            requirePlacedAt(reward_network, expected_start, "the reward head");
            expected_start = reward_network.paramsEnd();
            for (value_networks) |value_network| {
                requirePlacedAt(value_network, expected_start, "a value head");
                expected_start = value_network.paramsEnd();
            }
            const encoder_network: Network = rollout.encoder_pass.network;
            const model_params_start: u32 = encoder_network.paramsStart();
            const encoder_params_end: u32 = encoder_network.paramsEnd();
            const last_value_network: Network = value_networks[value_networks.len - 1];
            const model_params_end: u32 = last_value_network.paramsEnd();
            const model_floats: u32 = model_params_end - model_params_start;
            const clip_chunk_floats: u32 = 1024;
            const chunk_count: u32 = (model_floats + clip_chunk_floats - 1) / clip_chunk_floats;
            const clip_partials_offset: u32 = layout.reserveActs(chunk_count);
            const clip_norm_offset: u32 = layout.reserveActs(2);
            const world_model: Self = .{
                .rollout = rollout,
                .reward_network = reward_network,
                .value_networks = value_networks,
                .target_value_networks = target_value_networks,
                .loss_options = loss_options,
                .model_params_start = model_params_start,
                .encoder_params_end = encoder_params_end,
                .model_params_end = model_params_end,
                .clip_chunk_floats = clip_chunk_floats,
                .clip_partials_offset = clip_partials_offset,
                .clip_norm_offset = clip_norm_offset,
                .rewards_offset = rewards_offset,
                .value_targets_offset = value_targets_offset,
                .reward_applications = reward_applications,
                .value_applications = value_applications,
            };
            return world_model;
        }

        /// That `network`'s parameters begin where the world model's previous network's end (`init`).
        fn requirePlacedAt(
            network: Network,
            expected_start: u32,
            which: []const u8,
        ) void {
            const start: u32 = network.paramsStart();
            const message: []const u8 = "KitWorldModel: {s} begins at {d}, not at {d} where the one before ends";
            assertf(start == expected_start, @src(), message, .{
                which,
                start,
                expected_start,
            });
        }

        /// A two-hot head's application over `window_count` rows, with its logits' gradient and row losses -
        /// dropping out as `dropout` says.
        fn reserveHeadApplication(
            arena: Allocator,
            layout: *KitLayout,
            network: Network,
            window_count: u32,
            dropout: kit_mlp.Dropout,
        ) !HeadApplication {
            const application: Network.Application = try network.applicationDropping(
                arena,
                layout,
                window_count,
                dropout,
            );
            const bins: u32 = network.outputWidth();
            const head_application: HeadApplication = .{
                .application = application,
                .logits_gradient_offset = layout.reserveDacts(window_count * bins),
                .row_losses_offset = layout.reserveActs(window_count),
            };
            return head_application;
        }

        /// This update's dropout masks for every value head's application, written into the host's copy of acts: each
        /// drawn from `rng` split by dynamics head, then step, then value head - the CPU agent's `WorldModelLoss`
        /// splits its generator so, and the kit drops exactly its units. A null `rng` keeps every unit (no dropout,
        /// bit for bit). Nothing to write when the value heads do not drop out (`LossOptions.value_dropout`).
        pub fn writeValueDropoutMasks(
            world_model: Self,
            acts: []f32,
            rng: ?zn.Rng,
        ) !void {
            for (world_model.value_applications, 0..) |head_values, head_index| {
                for (head_values, 0..) |values_at_step, step| {
                    for (values_at_step, 0..) |value_at_step, value_index| {
                        const application: Network.Application = value_at_step.application;
                        if (rng) |dropout_rng| {
                            const head_rng: zn.Rng = dropout_rng.split(@intCast(head_index));
                            const step_rng: zn.Rng = head_rng.split(@intCast(step));
                            const value_rng: zn.Rng = step_rng.split(@intCast(value_index));
                            // The value head's network's generator, as the loss hands it to `Mlp.apply`.
                            try application.writeDropoutMasks(acts, value_rng, .network);
                        } else {
                            application.writeKeepEverything(acts);
                        }
                    }
                }
            }
        }

        /// This update's dropout masks for every value head's application, each drawn from its dropout LAYER's own
        /// generator in `application_rngs` - one per application, in the order the loss builds them: dynamics head,
        /// then step, then value head. The CPU agent's learner draws each update's masks so, from its graph's
        /// generator split by each dropout node's index (`zimrnum.Graph.resampleDropout`).
        pub fn writeValueDropoutMasksFrom(
            world_model: Self,
            acts: []f32,
            application_rngs: []const zn.Rng,
        ) !void {
            var application_index: usize = 0;
            for (world_model.value_applications) |head_values| {
                for (head_values) |values_at_step| {
                    for (values_at_step) |value_at_step| {
                        const application_rng: zn.Rng = application_rngs[application_index];
                        try value_at_step.application.writeDropoutMasks(acts, application_rng, .layer);
                        application_index += 1;
                    }
                }
            }
            assertf(application_index == application_rngs.len, @src(), "{d} generators for {d} applications", .{
                application_rngs.len,
                application_index,
            });
        }

        /// The window's rewards and value targets written into the host's copy of acts, each [horizon x
        /// window_count] step-major, before the upload (the observations and actions go through the rollout's
        /// `writeWindow`).
        pub fn writeTargets(
            world_model: Self,
            acts: []f32,
            rewards: []const f32,
            value_targets: []const f32,
        ) void {
            @memcpy(acts[world_model.rewards_offset..][0..rewards.len], rewards);
            @memcpy(acts[world_model.value_targets_offset..][0..value_targets.len], value_targets);
        }

        /// What `writeTargets` wrote, uploaded from the host's copy of acts: the rewards and the value targets.
        pub fn uploadTargets(
            world_model: Self,
            pipe: *Pipe,
            host_acts: []const f32,
        ) void {
            const rollout_options: Rollout.Options = world_model.rollout.options;
            const stored_rows: u32 = rollout_options.horizon * rollout_options.window_count;
            uploadActsRegion(M, pipe, host_acts, world_model.rewards_offset, stored_rows);
            uploadActsRegion(M, pipe, host_acts, world_model.value_targets_offset, stored_rows);
        }

        /// What the dropout-mask writers wrote, uploaded: every value head application's mask region.
        pub fn uploadValueDropoutMasks(
            world_model: Self,
            pipe: *Pipe,
            host_acts: []const f32,
        ) void {
            for (world_model.value_applications) |head_values| {
                for (head_values) |values_at_step| {
                    for (values_at_step) |value_at_step| {
                        value_at_step.application.uploadDropoutMasks(pipe, host_acts);
                    }
                }
            }
        }

        /// The forward: the rollout, then every head on every latent it reads.
        pub fn forward(world_model: Self, pipe: *Pipe) void {
            const rollout: Rollout = world_model.rollout;
            rollout.forward(pipe);
            const wide_row_width: u32 = rollout.wideRowWidth();
            for (rollout.dynamics_heads, 0..) |dynamics_head, head_index| {
                for (dynamics_head.wide_row_offsets, 0..) |wide_row_offset, step| {
                    const reward_at_step: HeadApplication = world_model.reward_applications[head_index][step];
                    reward_at_step.application.forward(pipe, wide_row_offset, wide_row_width);
                    for (world_model.value_applications[head_index][step]) |value_at_step| {
                        value_at_step.application.forward(pipe, wide_row_offset, wide_row_width);
                    }
                }
            }
        }

        /// Every head application's per-row cross-entropy into its `row_losses_offset` (`twohot_fwd`) - what a
        /// report reads back to form the loss's value; the backward does not need it.
        pub fn rowLosses(world_model: Self, pipe: *Pipe) void {
            const rollout: Rollout = world_model.rollout;
            for (rollout.dynamics_heads, 0..) |_, head_index| {
                for (0..rollout.options.horizon) |step| {
                    const reward_at_step: HeadApplication = world_model.reward_applications[head_index][step];
                    const rewards_at_step: u32 = world_model.stepTargets(world_model.rewards_offset, step);
                    world_model.twoHotLoss(pipe, reward_at_step, rewards_at_step, step);
                    const value_targets_at_step: u32 = world_model.stepTargets(world_model.value_targets_offset, step);
                    for (world_model.value_applications[head_index][step]) |value_at_step| {
                        world_model.twoHotLoss(pipe, value_at_step, value_targets_at_step, step);
                    }
                }
            }
        }

        /// Where step `step`'s scalar targets begin in a [horizon x window_count] step-major block.
        fn stepTargets(world_model: Self, block_offset: u32, step: usize) u32 {
            const window_count: u32 = world_model.rollout.options.window_count;
            const step_index: u32 = @intCast(step);
            return block_offset + step_index * window_count;
        }

        /// The two-hot kernels' shared settings for one head application at step `step`: its rows, its bins, its
        /// logits, its targets, and which of its rows still count (the rollout's column for the step).
        fn twoHotParams(
            world_model: Self,
            head_application: HeadApplication,
            targets_offset: u32,
            step: usize,
        ) M.Params {
            const window_count: u32 = world_model.rollout.options.window_count;
            const options: LossOptions = world_model.loss_options;
            const bins: u32 = head_application.application.network.outputWidth();
            const two_hot_params: M.Params = .{
                .rows = window_count,
                .out_dim = bins,
                .x_off = head_application.application.outputsOffset(),
                .t_off = targets_offset,
                .twohot_low = options.bins.low,
                .twohot_high = options.bins.high,
                .twohot_axis = @backingInt(options.bins.axis),
                .twohot_divisor = @floatFromInt(window_count),
                .row_mask = @backingInt(M.RowMask.counting_column),
                .mask_off = world_model.rollout.countingAt(step),
            };
            return two_hot_params;
        }

        /// One head application's per-row cross-entropy at step `step` (`twohot_fwd`).
        fn twoHotLoss(
            world_model: Self,
            pipe: *Pipe,
            head_application: HeadApplication,
            targets_offset: u32,
            step: usize,
        ) void {
            var loss_params: M.Params = world_model.twoHotParams(head_application, targets_offset, step);
            loss_params.y_off = head_application.row_losses_offset;
            pipe.params = loss_params;
            pipe.run("twohot_fwd", world_model.rollout.options.window_count);
        }

        /// The whole loss's backward (this type's head): every head application's two-hot gradient and its backward
        /// - the reward head's and each value head's parameter gradients summed over every dynamics head and step -
        /// then the rollout's, through time, with those heads' latent gradients merged in, scaled by the consistency
        /// weight. Every network's parameter gradients are written over what grads held.
        pub fn backward(world_model: Self, pipe: *Pipe) void {
            const rollout: Rollout = world_model.rollout;
            const options: LossOptions = world_model.loss_options;
            const horizon: u32 = rollout.options.horizon;
            const step_count: f32 = @floatFromInt(horizon);
            const dynamics_head_count: f32 = @floatFromInt(rollout.dynamics_heads.len);
            const value_head_count: f32 = @floatFromInt(world_model.value_networks.len);
            const wide_row_width: u32 = rollout.wideRowWidth();
            for (rollout.dynamics_heads, 0..) |dynamics_head, head_index| {
                for (dynamics_head.wide_row_offsets, 0..) |wide_row_offset, step| {
                    // rho^t, as the rollout's own weights are made (`KitRollout.stepWeight`).
                    const step_weight: f32 = Rollout.stepWeight(rollout.options.rho, step);
                    const is_first_application: bool = head_index == 0 and step == 0;
                    const parameter_gradients: ParameterGradients = if (is_first_application) .overwrite else .add;
                    // The reward head: its share is rho^t / H, then over the dynamics heads, then its weight.
                    const reward_share: f32 = step_weight / step_count;
                    const reward_weight: f32 = options.reward_weight * (reward_share / dynamics_head_count);
                    const reward_at_step: HeadApplication = world_model.reward_applications[head_index][step];
                    const rewards_at_step: u32 = world_model.stepTargets(world_model.rewards_offset, step);
                    world_model.headBackward(
                        pipe,
                        reward_at_step,
                        rewards_at_step,
                        step,
                        reward_weight,
                        wide_row_offset,
                        wide_row_width,
                        parameter_gradients,
                    );
                    // Each value head: rho^t / (H x value heads), then over the dynamics heads, then its weight.
                    const value_share: f32 = step_weight / (step_count * value_head_count);
                    const value_weight: f32 = options.value_weight * (value_share / dynamics_head_count);
                    const value_targets_at_step: u32 = world_model.stepTargets(world_model.value_targets_offset, step);
                    for (world_model.value_applications[head_index][step]) |value_at_step| {
                        world_model.headBackward(
                            pipe,
                            value_at_step,
                            value_targets_at_step,
                            step,
                            value_weight,
                            wide_row_offset,
                            wide_row_width,
                            parameter_gradients,
                        );
                    }
                }
            }
            rollout.backward(pipe, options.consistency_weight);
        }

        /// One step of the optimiser after `backward` (this type's head, "the update"): the clip, Adam - the encoder
        /// at its share of the rate - and the target value heads' follow. `update_count` counts the updates from 1, as
        /// Adam's bias corrections need (`zimrnum.adamCorrectionMultipliers`).
        pub fn update(
            world_model: Self,
            pipe: *Pipe,
            options: UpdateOptions,
            update_count: u32,
        ) void {
            // 1. The clip: each chunk's sum of squares, then the norm and the factor.
            const model_floats: u32 = world_model.model_params_end - world_model.model_params_start;
            const clip_chunk_floats: u32 = world_model.clip_chunk_floats;
            const chunk_count: u32 = (model_floats + clip_chunk_floats - 1) / clip_chunk_floats;
            pipe.params = .{
                .count = model_floats,
                .stride = clip_chunk_floats,
                .w_off = world_model.model_params_start,
                .y_off = world_model.clip_partials_offset,
            };
            pipe.run("grad_square_partials", chunk_count);
            pipe.params = .{
                .rows = chunk_count,
                .x_off = world_model.clip_partials_offset,
                .z_off = world_model.clip_norm_offset,
                .clip = options.gradient_clip,
            };
            pipe.run("clip_factor", 1);
            // 2. Adam on the clipped gradients: the encoder at its share of the rate, the rest at the rate.
            const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(
                f32,
                options.beta1,
                options.beta2,
                update_count,
            );
            const encoder_rate: f32 = options.learning_rate * options.encoder_rate_scale;
            const clip_factor_offset: u32 = world_model.clip_norm_offset + 1;
            const encoder_floats: u32 = world_model.encoder_params_end - world_model.model_params_start;
            const rest_floats: u32 = world_model.model_params_end - world_model.encoder_params_end;
            const regions = [_]struct { start: u32, floats: u32, rate: f32 }{
                .{ .start = world_model.model_params_start, .floats = encoder_floats, .rate = encoder_rate },
                .{ .start = world_model.encoder_params_end, .floats = rest_floats, .rate = options.learning_rate },
            };
            for (regions) |region| {
                pipe.params = .{
                    .count = region.floats,
                    .w_off = region.start,
                    .x_off = clip_factor_offset,
                    .rate = region.rate,
                    .beta1 = options.beta1,
                    .beta2 = options.beta2,
                    .epsilon = options.epsilon,
                    .correction1 = corrections.first,
                    .correction2 = corrections.second,
                };
                pipe.run("adam_clipped", region.floats);
            }
            // 3. The target value heads follow their online twins.
            for (world_model.target_value_networks, world_model.value_networks) |target_network, online_network| {
                const floats: u32 = target_network.paramsEnd() - target_network.paramsStart();
                pipe.params = .{
                    .count = floats,
                    .w_off = target_network.paramsStart(),
                    .v_off = online_network.paramsStart(),
                    .tau = options.target_follow,
                };
                pipe.run("polyak", floats);
            }
        }

        /// One head application's backward: its logits' two-hot gradient, as its share `loss_weight` of the loss,
        /// then back through the head to the wide row it read.
        fn headBackward(
            world_model: Self,
            pipe: *Pipe,
            head_application: HeadApplication,
            targets_offset: u32,
            step: usize,
            loss_weight: f32,
            wide_row_offset: u32,
            wide_row_width: u32,
            parameter_gradients: ParameterGradients,
        ) void {
            var gradient_params: M.Params = world_model.twoHotParams(head_application, targets_offset, step);
            gradient_params.dy_off = head_application.logits_gradient_offset;
            gradient_params.loss_weight = loss_weight;
            pipe.params = gradient_params;
            const window_count: u32 = world_model.rollout.options.window_count;
            pipe.run("twohot_bwd", window_count);
            head_application.application.backward(
                pipe,
                window_count,
                wide_row_offset,
                wide_row_width,
                head_application.logits_gradient_offset,
                parameter_gradients,
            );
        }
    };
}

// ============================================================================================================
// THE VALUE TARGETS
// ============================================================================================================

/// THE VALUE TARGETS ON THE KIT - zimrrl's `LatentValueTargets` at BMPC's one-step lookahead, laid out for the
/// kernels, written where the world model's value heads read their targets.
///
/// ---- WHAT A TARGET IS ----
///
/// A value head is trained toward what a stored step is worth under the agent's CURRENT behaviour, estimated by the
/// model itself (zimrrl's tutorial, "What a stored step is worth"): the policy draws an action at the step's true
/// latent, the reward head says what it earns, every dynamics head says where it leads, and the TARGET value heads -
/// the value heads' slow copies - say what that is worth:
///
///     a       = the policy's draw at z               (the policy's mean and spread, a standard normal's noise)
///     target  = R(z, a)  +  gamma x (1 / heads) x sum over dynamics heads i of  mean over target heads j of
///                                                                             V_j(f_i(z, a))
///
/// ---- THE LAYOUT ----
///
/// One row per stored step, horizon x window_count of them, step-major - the rows of the world model's value
/// targets. The true latents are the rollout's encoder pass: its first horizon blocks are the latents of the window's
/// observations o_0 .. o_(H-1), one per stored step, one contiguous run of rows. So nothing is encoded again:
///
///     encoder pass  [ z(o_0) | z(o_1) | ... | z(o_(H-1)) | z(o_H) ]       the first H blocks: every stored step
///                      |
///                      +--> the policy ---> its draw ---+
///                      v                                v
///     wide rows     Y = [ z | a ]  -- the reward head --> R(z, a), decoded
///                         |
///                         +-- dynamics head i --> f_i(z, a) -- target value head j --> V_ij, decoded
///                                                                              |
///     value_target_combine: R + gamma / heads x sum_i mean_j V_ij   -->   the world model's value targets
///
/// The noise is uploaded by the host - the CPU agent's counter-based draws, so a target is the CPU agent's to
/// rounding - and drawn on the device once its own noise is in place.
pub fn KitValueTargets(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        const Rollout = KitRollout(M);
        pub const Pipe = Network.Pipe;

        pub const Options = struct {
            /// The discount of the step's value, gamma (BMPC's for its episode length).
            discount: f32,
            /// The policy head's log spread bounds (`zimrrl.TanhMeanGaussian`).
            log_std_low: f32 = -3,
            log_std_high: f32 = 1,
            /// The bins the reward and value heads predict over (`TwoHotBins`).
            bins: TwoHotBins(M) = .{},
        };

        options: Options,
        rollout: Rollout,
        /// Where the targets go: the world model's value targets, [horizon x window_count] in acts.
        targets_offset: u32,
        /// acts: the wide rows Y = [ z | a ], one per stored step, and the policy's noise, [rows, action].
        wide_rows_offset: u32,
        noise_offset: u32,
        policy_pass: Network.Application,
        reward_pass: Network.Application,
        /// acts: each row's decoded reward.
        rewards_offset: u32,
        dynamics_passes: []Network.Application,
        /// [dynamics head][target value head]: the target head on that head's next latents.
        target_value_passes: [][]Network.Application,
        /// acts: the decoded target values, [dynamics head][target value head][rows].
        target_values_offset: u32,

        /// The targets' regions reserved in `layout`, on `rollout`, for the networks (all placed already) - writing
        /// into `targets_offset`, the world model's value targets. Memory: the lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            rollout: Rollout,
            policy: Network,
            reward: Network,
            target_values: []const Network,
            targets_offset: u32,
            options: Options,
        ) !Self {
            const row_count: u32 = rollout.options.horizon * rollout.options.window_count;
            const wide_row_width: u32 = rollout.wideRowWidth();
            const action_width: u32 = rollout.options.action_width;
            const wide_rows_offset: u32 = layout.reserveActs(row_count * wide_row_width);
            const noise_offset: u32 = layout.reserveActs(row_count * action_width);
            const policy_pass: Network.Application = try policy.forwardOnlyApplication(arena, layout, row_count);
            const reward_pass: Network.Application = try reward.forwardOnlyApplication(arena, layout, row_count);
            const rewards_offset: u32 = layout.reserveActs(row_count);
            const head_count: usize = rollout.dynamics_heads.len;
            const dynamics_passes: []Network.Application = try arena.alloc(Network.Application, head_count);
            const target_value_passes: [][]Network.Application = try arena.alloc([]Network.Application, head_count);
            for (dynamics_passes, target_value_passes, rollout.dynamics_heads) |*dynamics_pass, *head_targets, head| {
                dynamics_pass.* = try head.network.forwardOnlyApplication(arena, layout, row_count);
                head_targets.* = try arena.alloc(Network.Application, target_values.len);
                for (head_targets.*, target_values) |*target_pass, target_network| {
                    target_pass.* = try target_network.forwardOnlyApplication(arena, layout, row_count);
                }
            }
            const target_value_count: u32 = @intCast(head_count * target_values.len);
            const target_values_offset: u32 = layout.reserveActs(target_value_count * row_count);
            const value_targets: Self = .{
                .options = options,
                .rollout = rollout,
                .targets_offset = targets_offset,
                .wide_rows_offset = wide_rows_offset,
                .noise_offset = noise_offset,
                .policy_pass = policy_pass,
                .reward_pass = reward_pass,
                .rewards_offset = rewards_offset,
                .dynamics_passes = dynamics_passes,
                .target_value_passes = target_value_passes,
                .target_values_offset = target_values_offset,
            };
            return value_targets;
        }

        /// The policy's standard normal noise, [horizon x window_count, action], written into the host's copy of acts.
        pub fn writeNoise(value_targets: Self, acts: []f32, noise: []const f32) void {
            @memcpy(acts[value_targets.noise_offset..][0..noise.len], noise);
        }

        /// What `writeNoise` wrote, uploaded from the host's copy of acts.
        pub fn uploadNoise(
            value_targets: Self,
            pipe: *Pipe,
            host_acts: []const f32,
        ) void {
            const rollout_options: Rollout.Options = value_targets.rollout.options;
            const stored_rows: u32 = rollout_options.horizon * rollout_options.window_count;
            const noise_floats: u32 = stored_rows * rollout_options.action_width;
            uploadActsRegion(M, pipe, host_acts, value_targets.noise_offset, noise_floats);
        }

        /// Every stored step's target into the world model's value targets (this type's head), after the rollout's
        /// forward has encoded the window.
        pub fn compute(value_targets: Self, pipe: *Pipe) void {
            const rollout: Rollout = value_targets.rollout;
            const options: Options = value_targets.options;
            const row_count: u32 = rollout.options.horizon * rollout.options.window_count;
            const latent_width: u32 = rollout.latent_width;
            const action_width: u32 = rollout.options.action_width;
            const wide_row_width: u32 = rollout.wideRowWidth();
            const true_latents: u32 = rollout.encodedLatentsOffset(0);
            // 1. The true latents into the wide rows' latent columns.
            placeColumns(M, pipe, .{
                .rows = row_count,
                .count = latent_width,
                .source_offset = true_latents,
                .destination_offset = value_targets.wide_rows_offset,
                .row_stride = wide_row_width,
                .first_column = 0,
            });
            // 2. The policy's draw beside them.
            value_targets.policy_pass.forward(pipe, true_latents, 0);
            pipe.params = .{
                .rows = row_count,
                .out_dim = action_width,
                .x_off = value_targets.policy_pass.outputsOffset(),
                .u_off = value_targets.noise_offset,
                .y_off = value_targets.wide_rows_offset,
                .stride = wide_row_width,
                .col = latent_width,
                .distill_log_std_low = options.log_std_low,
                .distill_log_std_high = options.log_std_high,
            };
            pipe.run("policy_draw", row_count);
            // 3. The reward it earns, decoded.
            value_targets.reward_pass.forward(pipe, value_targets.wide_rows_offset, wide_row_width);
            decodeTwoHotRows(M, pipe, value_targets.reward_pass, options.bins, value_targets.rewards_offset);
            // 4. Where each dynamics head leads, and what every target head says that is worth.
            const dynamics_passes: []const Network.Application = value_targets.dynamics_passes;
            const target_value_passes: []const []Network.Application = value_targets.target_value_passes;
            for (dynamics_passes, target_value_passes, 0..) |dynamics_pass, head_targets, head_index| {
                dynamics_pass.forward(pipe, value_targets.wide_rows_offset, wide_row_width);
                const next_latents: u32 = dynamics_pass.outputsOffset();
                for (head_targets, 0..) |target_pass, target_index| {
                    target_pass.forward(pipe, next_latents, 0);
                    // [dynamics head][target value head][rows]: what `value_target_combine` reads.
                    const block: u32 = @intCast(head_index * head_targets.len + target_index);
                    const decoded_offset: u32 = value_targets.target_values_offset + block * row_count;
                    decodeTwoHotRows(M, pipe, target_pass, options.bins, decoded_offset);
                }
            }
            // 5. Each stored step's target, in the host's order of arithmetic.
            const target_heads_per_dynamics_head: usize = value_targets.target_value_passes[0].len;
            pipe.params = .{
                .rows = row_count,
                .x_off = value_targets.rewards_offset,
                .v_off = value_targets.target_values_offset,
                .y_off = value_targets.targets_offset,
                .gamma = options.discount,
                .target_dynamics_heads = @intCast(value_targets.dynamics_passes.len),
                .target_value_heads = @intCast(target_heads_per_dynamics_head),
            };
            pipe.run("value_target_combine", row_count);
        }
    };
}

// ============================================================================================================
// THE POLICY'S UPDATE
// ============================================================================================================

/// THE POLICY LEARNS ON THE KIT - the CPU agent's `PolicyLearner.update`, laid out for the kernels.
///
/// ---- WHAT IT LEARNS, AND FROM WHAT ----
///
/// The policy is taught to say in one network pass what the planner worked out slowly: at every stored step of the
/// window, toward the Gaussian the planner settled on there, by the distillation loss (`zn_mlp`'s
/// `policy_distill_bwd` explains it). It learns on the world model's ROLLED latents - the states the model reaches
/// when it plans - of EVERY dynamics head, the heads' copies of a window stacked into one batch (EfficientTDMPC's eq.
/// 16). The rolled latents are already on the kit, in the rollout's wide rows X_t = [ z_t | a_t ], so each head's
/// latents at each step are read where they are, through the wide row's stride - the policy reads them as data, and no
/// gradient flows from it into the world model:
///
///     the rollout's wide rows:    head 0: X_0 X_1 X_2      head 1: X_0 X_1 X_2      (the z columns of each)
///                                    |    |    |              |    |    |
///     the policy, per step and head: P    P    P              P    P    P          its gradients summed
///                                    |    |    |              |    |    |
///     the planner's targets:       step 0 1 2 (the same for every head's copy of a window)
///
/// ---- ONE UPDATE ----
///
///     1. the policy forward on every head's latents at every step
///     2. the FIRST step's divergences (`policy_divergence`), every head's - the running scale's batch
///     3. the running scale moved by them, and its reciprocal written (`running_scale_update`) - BMPC's order: the
///        scale moves with this batch before the gradient divides by it
///     4. every row's gradient (`policy_distill_bwd`) and the policy's backward, its gradients summed over every
///        step and head
///     5. the policy's own clip of its global gradient norm, and its Adam step (epsilon 1e-5, BMPC's for the policy)
///
/// Nothing in it reads back from the device: the scale lives in acts from one update to the next.
pub fn KitPolicyLearner(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        const Rollout = KitRollout(M);
        pub const Pipe = Network.Pipe;

        /// The policy's loss and optimiser: BMPC's.
        pub const Options = struct {
            /// The distillation's per-step weight, rho^t - the world model's rho.
            rho: f32 = 0.5,
            entropy_coefficient: f32 = 1e-4,
            /// The bounds the policy's log spread is held between (`zimrrl.TanhMeanGaussian`).
            log_std_low: f32 = -3,
            log_std_high: f32 = 1,
            /// How far the running scale moves toward each batch's spread (BMPC's tau).
            scale_rate: f32 = 0.01,
            learning_rate: f32 = 3e-4,
            /// Adam's epsilon for the policy: BMPC's 1e-5, where the world model's is 1e-8.
            epsilon: f32 = 1e-5,
            beta1: f32 = 0.9,
            beta2: f32 = 0.999,
            gradient_clip: f32 = 20,
        };

        options: Options,
        network: Network,
        rollout: Rollout,
        /// acts: the planner's means and the logs of its spreads, [horizon x window_count, action] each, step-major -
        /// one row per stored step, read by every head's copy of it.
        target_means_offset: u32,
        target_log_stds_offset: u32,
        /// acts: each stored step's weight, [horizon x window_count], step-major - rho^t / (H x stacked rows).
        weights_offset: u32,
        /// [step][dynamics head]: the policy applied to that head's latents at that step, and its raw outputs'
        /// gradient (dacts, [window_count, 2 x action]).
        step_applications: [][]Network.Application,
        gradient_offsets: [][]u32,
        /// acts: each stacked row's divergence and entropy, [horizon][dynamics head][window_count] - the first step's
        /// rows one block, the running scale's batch.
        divergences_offset: u32,
        entropies_offset: u32,
        /// acts: the running scale, its reciprocal, and the sort's scratch for its batch.
        scale_offset: u32,
        inverse_scale_offset: u32,
        sort_scratch_offset: u32,
        /// acts: the clip's partial sums of squares, and the norm with its factor; the gradients each thread sums.
        clip_chunk_floats: u32,
        clip_partials_offset: u32,
        clip_norm_offset: u32,

        /// The policy's regions reserved in `layout`, on `rollout` (whose wide rows it reads), for `network` (already
        /// placed - after the world model's networks, outside the world model's clip). Memory: the lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            network: Network,
            rollout: Rollout,
            options: Options,
        ) !Self {
            const horizon: u32 = rollout.options.horizon;
            const window_count: u32 = rollout.options.window_count;
            const action_width: u32 = rollout.options.action_width;
            const head_count: u32 = @intCast(rollout.dynamics_heads.len);
            const stored_rows: u32 = horizon * window_count;
            const stacked_rows: u32 = stored_rows * head_count;
            const target_means_offset: u32 = layout.reserveActs(stored_rows * action_width);
            const target_log_stds_offset: u32 = layout.reserveActs(stored_rows * action_width);
            const weights_offset: u32 = layout.reserveActs(stored_rows);
            const step_applications: [][]Network.Application = try arena.alloc([]Network.Application, horizon);
            const gradient_offsets: [][]u32 = try arena.alloc([]u32, horizon);
            for (step_applications, gradient_offsets) |*head_applications, *head_gradients| {
                head_applications.* = try arena.alloc(Network.Application, head_count);
                head_gradients.* = try arena.alloc(u32, head_count);
                for (head_applications.*, head_gradients.*) |*application, *gradient_offset| {
                    application.* = try network.application(arena, layout, window_count);
                    gradient_offset.* = layout.reserveDacts(window_count * 2 * action_width);
                }
            }
            const divergences_offset: u32 = layout.reserveActs(stacked_rows);
            const entropies_offset: u32 = layout.reserveActs(stacked_rows);
            const scale_offset: u32 = layout.reserveActs(1);
            const inverse_scale_offset: u32 = layout.reserveActs(1);
            const sort_scratch_offset: u32 = layout.reserveActs(head_count * window_count);
            const policy_floats: u32 = network.paramsEnd() - network.paramsStart();
            const clip_chunk_floats: u32 = 1024;
            const chunk_count: u32 = (policy_floats + clip_chunk_floats - 1) / clip_chunk_floats;
            const clip_partials_offset: u32 = layout.reserveActs(chunk_count);
            const clip_norm_offset: u32 = layout.reserveActs(2);
            const learner: Self = .{
                .options = options,
                .network = network,
                .rollout = rollout,
                .target_means_offset = target_means_offset,
                .target_log_stds_offset = target_log_stds_offset,
                .weights_offset = weights_offset,
                .step_applications = step_applications,
                .gradient_offsets = gradient_offsets,
                .divergences_offset = divergences_offset,
                .entropies_offset = entropies_offset,
                .scale_offset = scale_offset,
                .inverse_scale_offset = inverse_scale_offset,
                .sort_scratch_offset = sort_scratch_offset,
                .clip_chunk_floats = clip_chunk_floats,
                .clip_partials_offset = clip_partials_offset,
                .clip_norm_offset = clip_norm_offset,
            };
            return learner;
        }

        /// The running scale's first value, 1 (`zimrnum.RunningScale`'s), written into the host's copy of acts before
        /// the first upload.
        pub fn writeInitialState(learner: Self, acts: []f32) void {
            acts[learner.scale_offset] = 1;
            acts[learner.inverse_scale_offset] = 1;
        }

        /// The planner's targets for the window - its means, and the LOGS of its spreads, [horizon x window_count,
        /// action] each, step-major - and every stored step's weight, rho^t / (H x stacked rows) with rho^t a running
        /// product as the CPU loss keeps it, written into the host's copy of acts before the upload.
        pub fn writeTargets(
            learner: Self,
            acts: []f32,
            target_means: []const f32,
            target_log_stds: []const f32,
        ) void {
            @memcpy(acts[learner.target_means_offset..][0..target_means.len], target_means);
            @memcpy(acts[learner.target_log_stds_offset..][0..target_log_stds.len], target_log_stds);
            const rollout_options: Rollout.Options = learner.rollout.options;
            const head_count: u32 = @intCast(learner.rollout.dynamics_heads.len);
            const stacked_rows: u32 = rollout_options.horizon * rollout_options.window_count * head_count;
            const row_share: f32 = 1.0 / float(stacked_rows);
            var step_weight: f32 = 1;
            for (0..rollout_options.horizon) |step| {
                const step_weights_start: usize = learner.weights_offset + step * rollout_options.window_count;
                @memset(acts[step_weights_start..][0..rollout_options.window_count], step_weight * row_share);
                step_weight *= learner.options.rho;
            }
        }

        /// What `writeTargets` wrote, uploaded from the host's copy of acts: the planner's means and log spreads, and
        /// every stored step's weight.
        pub fn uploadTargets(learner: Self, pipe: *Pipe, host_acts: []const f32) void {
            const rollout_options: Rollout.Options = learner.rollout.options;
            const stored_rows: u32 = rollout_options.horizon * rollout_options.window_count;
            const target_floats: u32 = stored_rows * rollout_options.action_width;
            uploadActsRegion(M, pipe, host_acts, learner.target_means_offset, target_floats);
            uploadActsRegion(M, pipe, host_acts, learner.target_log_stds_offset, target_floats);
            uploadActsRegion(M, pipe, host_acts, learner.weights_offset, stored_rows);
        }

        /// Where one application's rows begin in a [horizon][dynamics head][window_count] block - the layout the
        /// divergences and the entropies share, the first step's heads' rows one after another (the running scale's
        /// batch).
        fn stackedRowsStart(learner: Self, step_index: usize, head_index: usize) u32 {
            const head_count: usize = learner.rollout.dynamics_heads.len;
            const block_index: usize = step_index * head_count + head_index;
            const block_start: usize = block_index * learner.rollout.options.window_count;
            return @intCast(block_start);
        }

        /// Where the divergences of step `step_index`, dynamics head `head_index` are: [window_count] in acts.
        fn divergencesAt(learner: Self, step_index: usize, head_index: usize) u32 {
            return learner.divergences_offset + learner.stackedRowsStart(step_index, head_index);
        }

        /// Where the entropies of step `step_index`, dynamics head `head_index` are: [window_count] in acts.
        fn entropiesAt(learner: Self, step_index: usize, head_index: usize) u32 {
            return learner.entropies_offset + learner.stackedRowsStart(step_index, head_index);
        }

        /// The distillation kernels' settings for one application - the policy at step `step_index` on dynamics head
        /// `head_index`'s latents: its rows, its raw outputs, the planner's targets for the step (the same for every
        /// head's copy), the step's weights, and where its divergences, entropies and gradients go.
        fn distillParams(learner: Self, step_index: usize, head_index: usize) M.Params {
            const rollout_options: Rollout.Options = learner.rollout.options;
            const window_count: u32 = rollout_options.window_count;
            const action_width: u32 = rollout_options.action_width;
            const stored_rows_before: u32 = @as(u32, @intCast(step_index)) * window_count;
            const stored_floats_before: u32 = stored_rows_before * action_width;
            const application: Network.Application = learner.step_applications[step_index][head_index];
            const distill_params: M.Params = .{
                .rows = window_count,
                .out_dim = action_width,
                .x_off = application.outputsOffset(),
                .t_off = learner.target_means_offset + stored_floats_before,
                .u_off = learner.target_log_stds_offset + stored_floats_before,
                .v_off = learner.weights_offset + stored_rows_before,
                .e_off = learner.inverse_scale_offset,
                .y_off = learner.divergencesAt(step_index, head_index),
                .z_off = learner.entropiesAt(step_index, head_index),
                .dy_off = learner.gradient_offsets[step_index][head_index],
                .distill_log_std_low = learner.options.log_std_low,
                .distill_log_std_high = learner.options.log_std_high,
                .distill_entropy_coefficient = learner.options.entropy_coefficient,
                // A finished row's weight is 0: the rollout's column for the step, every head's copy alike.
                .row_mask = @backingInt(M.RowMask.counting_column),
                .mask_off = learner.rollout.countingAt(step_index),
            };
            return distill_params;
        }

        /// One update (this type's head, "one update"), after the world model's forward has filled the rollout's
        /// wide rows. `update_count` counts the policy's updates from 1, for Adam's bias corrections.
        pub fn update(learner: Self, pipe: *Pipe, update_count: u32) void {
            const rollout: Rollout = learner.rollout;
            const window_count: u32 = rollout.options.window_count;
            const wide_row_width: u32 = rollout.wideRowWidth();
            const head_count: u32 = @intCast(rollout.dynamics_heads.len);
            // 1. The policy on every head's latents at every step, read in the wide rows.
            for (learner.step_applications, 0..) |head_applications, step_index| {
                for (head_applications, rollout.dynamics_heads) |application, dynamics_head| {
                    const wide_row_offset: u32 = dynamics_head.wide_row_offsets[step_index];
                    application.forward(pipe, wide_row_offset, wide_row_width);
                }
            }
            // 2. The first step's divergences, every head's.
            for (0..head_count) |head_index| {
                pipe.params = learner.distillParams(0, head_index);
                pipe.run("policy_divergence", window_count);
            }
            // 3. The running scale, moved by them.
            pipe.params = .{
                .count = head_count * window_count,
                .x_off = learner.divergencesAt(0, 0),
                .z_off = learner.sort_scratch_offset,
                .v_off = learner.scale_offset,
                .e_off = learner.inverse_scale_offset,
                .tau = learner.options.scale_rate,
            };
            pipe.run("running_scale_update", 1);
            // 4. Every row's gradient, and the policy's backward: the first overwrites, every later one adds.
            for (learner.step_applications, 0..) |head_applications, step_index| {
                for (head_applications, rollout.dynamics_heads, 0..) |application, dynamics_head, head_index| {
                    pipe.params = learner.distillParams(step_index, head_index);
                    pipe.run("policy_distill_bwd", window_count);
                    const is_first_application: bool = step_index == 0 and head_index == 0;
                    const parameter_gradients: ParameterGradients = if (is_first_application) .overwrite else .add;
                    const wide_row_offset: u32 = dynamics_head.wide_row_offsets[step_index];
                    const raw_outputs_gradient: u32 = learner.gradient_offsets[step_index][head_index];
                    application.backward(
                        pipe,
                        window_count,
                        wide_row_offset,
                        wide_row_width,
                        raw_outputs_gradient,
                        parameter_gradients,
                    );
                }
            }
            // 5. The policy's own clip and Adam.
            learner.clipAndStep(pipe, update_count);
        }

        /// The policy's clip of its global gradient norm and its Adam step (`KitWorldModel.update`'s first two parts,
        /// over the policy's region). `update_count` counts the updates from 1.
        fn clipAndStep(learner: Self, pipe: *Pipe, update_count: u32) void {
            const options: Options = learner.options;
            const policy_start: u32 = learner.network.paramsStart();
            const policy_floats: u32 = learner.network.paramsEnd() - policy_start;
            const chunk_count: u32 = (policy_floats + learner.clip_chunk_floats - 1) / learner.clip_chunk_floats;
            pipe.params = .{
                .count = policy_floats,
                .stride = learner.clip_chunk_floats,
                .w_off = policy_start,
                .y_off = learner.clip_partials_offset,
            };
            pipe.run("grad_square_partials", chunk_count);
            pipe.params = .{
                .rows = chunk_count,
                .x_off = learner.clip_partials_offset,
                .z_off = learner.clip_norm_offset,
                .clip = options.gradient_clip,
            };
            pipe.run("clip_factor", 1);
            const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(
                f32,
                options.beta1,
                options.beta2,
                update_count,
            );
            const clip_factor_offset: u32 = learner.clip_norm_offset + 1;
            pipe.params = .{
                .count = policy_floats,
                .w_off = policy_start,
                .x_off = clip_factor_offset,
                .rate = options.learning_rate,
                .beta1 = options.beta1,
                .beta2 = options.beta2,
                .epsilon = options.epsilon,
                .correction1 = corrections.first,
                .correction2 = corrections.second,
            };
            pipe.run("adam_clipped", policy_floats);
        }
    };
}

// ============================================================================================================
// THE PLANNER
// ============================================================================================================

/// What an MPPI search is over (`KitMppi`), whichever scorer fills it: its states, the candidates of each, the plans'
/// horizon and the action's width; where the candidates' actions are - packed STEP BY STEP, [step][state x
/// candidate][action] (all candidates' first actions, then all their second ones, and so on: the MPPI kernels'
/// layout), written by the search's sampling and read by the scorer - and where their scores are, [state x candidate],
/// higher better. EfficientTDMPC's scorer describes itself so (`KitPlanScorer.searchShape`), and SuperTrack's tracking
/// planner's (`robot_latent_kit.TrackingScorer.searchShape`): one search, two scorers.
pub const SearchShape = struct {
    states: u32,
    candidates: u32,
    horizon: u32,
    action_width: u32,
    candidate_actions_at: u32,
    scores_at: u32,

    /// Every candidate of every state: the rows the scorer rolls.
    pub fn rowCount(shape: SearchShape) u32 {
        return shape.states * shape.candidates;
    }

    /// Where step `step`'s block of the candidates' actions begins - every row's action at that step, row after row.
    /// The layout is the MPPI kernels', and the host reaches it only through this and `candidateActionAt`, so the
    /// host and the kernels cannot disagree about it.
    pub fn stepActionsAt(shape: SearchShape, step: u32) u32 {
        const step_block_floats: u32 = shape.rowCount() * shape.action_width;
        return shape.candidate_actions_at + step * step_block_floats;
    }

    /// Where row `row`'s action at step `step` begins.
    pub fn candidateActionAt(shape: SearchShape, step: u32, row: u32) u32 {
        return shape.stepActionsAt(step) + row * shape.action_width;
    }
};

/// SCORING PLANS ON THE KIT - zimrrl's `LatentPlanScorer`, laid out for the kernels: every candidate plan of every
/// state rolled through the world model's imagination and given one number, the planner's ranking.
///
/// ---- WHAT A SCORE IS ----
///
/// A candidate is `horizon` actions. Starting from its state's latent, every dynamics head rolls it forward; the
/// reward head reads each step's (latent, action) and every value head reads the latents at the depths the objective
/// weighs. Each pair of a dynamics head and a value head gives one estimate of the plan's worth; the score is their
/// mean, less `pessimism` standard deviations of that mean when the planner is pessimistic (`zn_mlp`'s
/// `plan_score_combine` gives the formula, the host's order of arithmetic throughout).
///
/// ---- THE LAYOUT ----
///
/// Rows are state x candidate, `states x candidates` of them. A score needs no gradient, so nothing is kept for a
/// backward: each network has ONE application over all the rows, reused at every step - its activations overwritten
/// as the rollout moves on - and each dynamics head two wide rows [ z | a ] it alternates between, the step's input and
/// the next step's. So the memory a plan takes does not grow with its length.
///
///     each state's latent  --broadcast_rows-->  wide rows A, every candidate's      (step 0's z columns)
///     step t:   the step's actions into the current wide rows' a columns           (place_columns)
///               the reward head on them --> decoded r_(i,t)
///               the dynamics head on them --> z_(t+1) --> the other wide rows' z columns
///               at a weighted depth: every value head on z_(t+1) --> decoded V_(i,t+1,j)
///     plan_score_combine:  every candidate's score and variance
///
/// The candidates' actions are [horizon][rows][action], step-major - one block per step, as the scorer's own and as
/// MPPI writes them.
pub fn KitPlanScorer(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        pub const Pipe = Network.Pipe;

        pub const Options = struct {
            /// The plan's length in decisions, the states planned for at once, and the candidates per state.
            horizon: u32,
            states: u32,
            candidates: u32,
            discount: f32,
            objective: zrl.PlanObjective = .final,
            /// beta: the score's price per standard deviation of the heads' disagreement.
            pessimism: f32 = 0,
            /// The bins the reward and value heads predict over (`TwoHotBins`).
            bins: TwoHotBins(M) = .{},
        };

        /// One dynamics head's rollout: its network's application and its two wide rows.
        pub const HeadRollout = struct {
            dynamics_pass: Network.Application,
            wide_rows_offsets: [2]u32,
        };

        options: Options,
        observation_width: u32,
        latent_width: u32,
        action_width: u32,
        /// acts: the states' observations, [states, observation].
        observations_offset: u32,
        encoder_pass: Network.Application,
        /// acts: the candidates' actions, [horizon][rows][action].
        actions_offset: u32,
        head_rollouts: []HeadRollout,
        reward_pass: Network.Application,
        value_passes: []Network.Application,
        /// The objective's weights (`zimrrl.planObjectiveWeights`, the host scorer's own): `horizon` reward weights,
        /// then `horizon` value weights - kept here, in arena memory, to know which depths the value heads read, and
        /// in acts at `weights_offset` for `plan_score_combine`.
        objective_weights: []const f32,
        weights_offset: u32,
        /// acts: the decoded rewards [dynamics head][step][rows], the decoded values [dynamics head][depth][value
        /// head][rows], and each candidate's score and variance [rows].
        rewards_offset: u32,
        values_offset: u32,
        scores_offset: u32,
        variances_offset: u32,

        /// The scorer's regions reserved in `layout`, for networks already placed. Memory: the lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            encoder: Network,
            dynamics_heads: []const Network,
            reward: Network,
            values: []const Network,
            observation_width: u32,
            action_width: u32,
            options: Options,
        ) !Self {
            const row_count: u32 = options.states * options.candidates;
            const latent_width: u32 = encoder.outputWidth();
            const wide_row_width: u32 = latent_width + action_width;
            const observations_offset: u32 = layout.reserveActs(options.states * observation_width);
            const encoder_pass: Network.Application = try encoder.forwardOnlyApplication(arena, layout, options.states);
            const actions_offset: u32 = layout.reserveActs(options.horizon * row_count * action_width);
            const head_rollouts: []HeadRollout = try arena.alloc(HeadRollout, dynamics_heads.len);
            for (head_rollouts, dynamics_heads) |*head_rollout, dynamics_head| {
                head_rollout.dynamics_pass = try dynamics_head.forwardOnlyApplication(arena, layout, row_count);
                for (&head_rollout.wide_rows_offsets) |*wide_rows_offset| {
                    wide_rows_offset.* = layout.reserveActs(row_count * wide_row_width);
                }
            }
            const reward_pass: Network.Application = try reward.forwardOnlyApplication(arena, layout, row_count);
            const value_passes: []Network.Application = try arena.alloc(Network.Application, values.len);
            for (value_passes, values) |*value_pass, value_network| {
                value_pass.* = try value_network.forwardOnlyApplication(arena, layout, row_count);
            }
            const objective_weights: []f32 = try arena.alloc(f32, 2 * options.horizon);
            const reward_weights: []f32 = objective_weights[0..options.horizon];
            const value_weights: []f32 = objective_weights[options.horizon..];
            try zrl.planObjectiveWeights(f32, options.objective, options.discount, reward_weights, value_weights);
            const weights_offset: u32 = layout.reserveActs(2 * options.horizon);
            const head_count: u32 = @intCast(dynamics_heads.len);
            const value_count: u32 = @intCast(values.len);
            const rewards_offset: u32 = layout.reserveActs(head_count * options.horizon * row_count);
            const values_offset: u32 = layout.reserveActs(head_count * options.horizon * value_count * row_count);
            const scores_offset: u32 = layout.reserveActs(row_count);
            const variances_offset: u32 = layout.reserveActs(row_count);
            const scorer: Self = .{
                .options = options,
                .observation_width = observation_width,
                .latent_width = latent_width,
                .action_width = action_width,
                .observations_offset = observations_offset,
                .encoder_pass = encoder_pass,
                .actions_offset = actions_offset,
                .head_rollouts = head_rollouts,
                .reward_pass = reward_pass,
                .value_passes = value_passes,
                .objective_weights = objective_weights,
                .weights_offset = weights_offset,
                .rewards_offset = rewards_offset,
                .values_offset = values_offset,
                .scores_offset = scores_offset,
                .variances_offset = variances_offset,
            };
            return scorer;
        }

        /// The objective's weights written into the host's copy of acts, once: they depend only on the objective,
        /// the discount and the plan's length.
        pub fn writeWeights(scorer: Self, acts: []f32) void {
            const weight_count: usize = scorer.objective_weights.len;
            @memcpy(acts[scorer.weights_offset..][0..weight_count], scorer.objective_weights);
        }

        /// Every candidate of every state scored into `scores_offset` (and its variance into `variances_offset`),
        /// after the states' observations and the candidates' actions are in acts (this type's head, "the layout").
        /// What a search over this scorer's candidates is over (`SearchShape`).
        pub fn searchShape(scorer: Self) SearchShape {
            const shape: SearchShape = .{
                .states = scorer.options.states,
                .candidates = scorer.options.candidates,
                .horizon = scorer.options.horizon,
                .action_width = scorer.action_width,
                .candidate_actions_at = scorer.actions_offset,
                .scores_at = scorer.scores_offset,
            };
            return shape;
        }

        pub fn score(scorer: Self, pipe: *Pipe) void {
            // 1. Every state's latent, once - the encoder over the states, not over the candidates.
            scorer.encoder_pass.forward(pipe, scorer.observations_offset, 0);
            const state_latents: u32 = scorer.encoder_pass.outputsOffset();
            // 2. Every candidate rolled under every dynamics head: its rewards and the values it reaches.
            for (scorer.head_rollouts, 0..) |head_rollout, head_index| {
                scorer.rollHead(pipe, head_rollout, @intCast(head_index), state_latents);
            }
            // 3. Every candidate's score and variance, from every head's rewards and values.
            scorer.combineScores(pipe);
        }

        /// One dynamics head's rollout of every candidate: each state's latent broadcast into its candidates' first
        /// wide rows, then step by step the actions placed beside the latents, the reward read, the latents moved on
        /// into the other wide rows, and the values read where the objective weighs the depth.
        fn rollHead(
            scorer: Self,
            pipe: *Pipe,
            head_rollout: HeadRollout,
            head_number: u32,
            state_latents: u32,
        ) void {
            const options: Options = scorer.options;
            const row_count: u32 = options.states * options.candidates;
            const latent_width: u32 = scorer.latent_width;
            const action_width: u32 = scorer.action_width;
            const wide_row_width: u32 = latent_width + action_width;
            const value_weights: []const f32 = scorer.objective_weights[options.horizon..];
            // Each state's latent into the z columns of every one of its candidates' first wide rows.
            pipe.params = .{
                .rows = options.states,
                .count = latent_width,
                .x_off = state_latents,
                .y_off = head_rollout.wide_rows_offsets[0],
                .stride = wide_row_width,
                .col = 0,
                .row_copies = options.candidates,
            };
            pipe.run("broadcast_rows", row_count * latent_width);
            for (0..options.horizon) |step| {
                const step_index: u32 = @intCast(step);
                // The two wide rows alternate: this step reads one and writes the next step's latents into the other.
                const current_rows: u32 = head_rollout.wide_rows_offsets[step % 2];
                const next_rows: u32 = head_rollout.wide_rows_offsets[(step + 1) % 2];
                // The step's actions beside the latents - the candidates' actions are [horizon][rows][action].
                const step_actions: u32 = scorer.actions_offset + step_index * row_count * action_width;
                placeColumns(M, pipe, .{
                    .rows = row_count,
                    .count = action_width,
                    .source_offset = step_actions,
                    .destination_offset = current_rows,
                    .row_stride = wide_row_width,
                    .first_column = latent_width,
                });
                // The reward the step earns: the reward head on the wide rows, decoded into [head][step][rows].
                scorer.reward_pass.forward(pipe, current_rows, wide_row_width);
                const reward_block: u32 = head_number * options.horizon + step_index;
                const step_rewards: u32 = scorer.rewards_offset + reward_block * row_count;
                decodeTwoHotRows(M, pipe, scorer.reward_pass, options.bins, step_rewards);
                // Where the step leads: the dynamics head on the same wide rows, its latents into the next ones.
                head_rollout.dynamics_pass.forward(pipe, current_rows, wide_row_width);
                const next_latents: u32 = head_rollout.dynamics_pass.outputsOffset();
                placeColumns(M, pipe, .{
                    .rows = row_count,
                    .count = latent_width,
                    .source_offset = next_latents,
                    .destination_offset = next_rows,
                    .row_stride = wide_row_width,
                    .first_column = 0,
                });
                // What it is worth there, by every value head - only at a depth the objective weighs (the plan's end
                // for the discounted sum, every depth for the mean over prefixes).
                const depth_is_weighed: bool = value_weights[step] != 0;
                if (depth_is_weighed) {
                    scorer.readValues(pipe, next_latents, reward_block);
                }
            }
        }

        /// Every value head on the latents at `next_latents`, decoded into the depth's block of
        /// [head][depth][value head][rows] (`reward_block` is the block's head and depth: head x horizon + step).
        fn readValues(
            scorer: Self,
            pipe: *Pipe,
            next_latents: u32,
            reward_block: u32,
        ) void {
            const options: Options = scorer.options;
            const row_count: u32 = options.states * options.candidates;
            const value_count: u32 = @intCast(scorer.value_passes.len);
            for (scorer.value_passes, 0..) |value_pass, value_index| {
                value_pass.forward(pipe, next_latents, 0);
                const value_number: u32 = @intCast(value_index);
                const value_block: u32 = reward_block * value_count + value_number;
                const depth_values: u32 = scorer.values_offset + value_block * row_count;
                decodeTwoHotRows(M, pipe, value_pass, options.bins, depth_values);
            }
        }

        /// Every candidate's score - the dynamics heads' mean, less the pessimism's price - and the variance of that
        /// mean (`plan_score_combine`).
        fn combineScores(scorer: Self, pipe: *Pipe) void {
            const options: Options = scorer.options;
            const row_count: u32 = options.states * options.candidates;
            pipe.params = .{
                .rows = row_count,
                .x_off = scorer.rewards_offset,
                .v_off = scorer.values_offset,
                .u_off = scorer.weights_offset,
                .y_off = scorer.scores_offset,
                .z_off = scorer.variances_offset,
                .plan_horizon = options.horizon,
                .plan_dynamics_heads = @intCast(scorer.head_rollouts.len),
                .plan_value_heads = @intCast(scorer.value_passes.len),
                .plan_pessimism = options.pessimism,
            };
            pipe.run("plan_score_combine", row_count);
        }
    };
}

/// THE POLICY'S OWN PLANS IN THE SEARCH, ON THE KIT - zimrrl's `LatentPolicyPlans`: for every state, `plans` plans the
/// policy itself proposes, rolled through the world model and written as the first candidates of the state's block,
/// where the planner scores them with every other candidate (and never moves them).
///
/// ---- ONE PLAN ----
///
///     z_0   = encoder(observation)
///     a_t   = clamp(tanh(m_t) + s_t eps_t, -1, 1)     the policy's draw at z_t (`policy_draw`)
///     z_t+1 = dynamics(z_t, a_t)                        the FIRST dynamics head, as the CPU actor plans; not after
///                                                       the last step - the scorer moves the latents itself
///
/// ---- THE LAYOUT ----
///
/// Rows are state x plan. A pair of wide rows [ z | a ] alternates as the plan moves on: the policy reads the latent
/// columns, its draw goes into the action columns beside them, the dynamics head reads the whole row, and its next
/// latent goes into the other wide rows. Each step's actions are then carried into the scorer's candidate actions,
/// each state's plans into the first rows of its block (`copy_row_blocks`). The states' latents are the scorer's own
/// encoder pass, over the same observations.
///
/// The noise is uploaded by the host - [horizon][rows][action], each (state, plan, step, dimension)'s draw the CPU
/// actor's counter-based one, so a plan is the CPU actor's to rounding - and drawn on the device once its own noise
/// is in place.
pub fn KitPolicyPlans(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = KitNetwork(M);
        const Scorer = KitPlanScorer(M);
        pub const Pipe = Network.Pipe;

        pub const Options = struct {
            /// The policy's plans per state: BMPC's 24 of its 512 candidates.
            plans: u32,
            /// The policy head's log spread bounds: acting's [-3, 1], reanalyze's wider [-2, 1].
            log_std_low: f32 = -3,
            log_std_high: f32 = 1,
        };

        options: Options,
        scorer: Scorer,
        policy_pass: Network.Application,
        dynamics_pass: Network.Application,
        /// acts: the alternating wide rows, [rows, latent + action] each, and the noise [horizon][rows][action].
        wide_rows_offsets: [2]u32,
        noise_offset: u32,

        /// The plans' regions reserved in `layout`, beside `scorer` (whose observations, encoder pass and candidate
        /// actions they use), for `policy` and the first dynamics head - both placed already.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            scorer: Scorer,
            policy: Network,
            dynamics: Network,
            options: Options,
        ) !Self {
            const row_count: u32 = scorer.options.states * options.plans;
            const wide_row_width: u32 = scorer.latent_width + scorer.action_width;
            const policy_pass: Network.Application = try policy.forwardOnlyApplication(arena, layout, row_count);
            const dynamics_pass: Network.Application = try dynamics.forwardOnlyApplication(arena, layout, row_count);
            var wide_rows_offsets: [2]u32 = undefined;
            for (&wide_rows_offsets) |*wide_rows_offset| {
                wide_rows_offset.* = layout.reserveActs(row_count * wide_row_width);
            }
            const noise_floats: u32 = scorer.options.horizon * row_count * scorer.action_width;
            const noise_offset: u32 = layout.reserveActs(noise_floats);
            const policy_plans: Self = .{
                .options = options,
                .scorer = scorer,
                .policy_pass = policy_pass,
                .dynamics_pass = dynamics_pass,
                .wide_rows_offsets = wide_rows_offsets,
                .noise_offset = noise_offset,
            };
            return policy_plans;
        }

        /// The plans' standard normal noise, [horizon][rows][action], written into the host's copy of acts.
        pub fn writeNoise(policy_plans: Self, acts: []f32, noise: []const f32) void {
            @memcpy(acts[policy_plans.noise_offset..][0..noise.len], noise);
        }

        /// Every state's plans drawn, rolled and written into the scorer's candidate actions (this type's head),
        /// after the states' observations are in acts.
        pub fn fill(policy_plans: Self, pipe: *Pipe) void {
            const scorer: Scorer = policy_plans.scorer;
            const options: Options = policy_plans.options;
            const states: u32 = scorer.options.states;
            const candidates: u32 = scorer.options.candidates;
            const row_count: u32 = states * options.plans;
            const candidate_rows: u32 = states * candidates;
            const latent_width: u32 = scorer.latent_width;
            const action_width: u32 = scorer.action_width;
            const wide_row_width: u32 = latent_width + action_width;
            // 1. Every state's latent, into each of its plans' first wide row.
            scorer.encoder_pass.forward(pipe, scorer.observations_offset, 0);
            pipe.params = .{
                .rows = states,
                .count = latent_width,
                .x_off = scorer.encoder_pass.outputsOffset(),
                .y_off = policy_plans.wide_rows_offsets[0],
                .stride = wide_row_width,
                .col = 0,
                .row_copies = options.plans,
            };
            pipe.run("broadcast_rows", row_count * latent_width);
            for (0..scorer.options.horizon) |step| {
                const step_index: u32 = @intCast(step);
                const current_rows: u32 = policy_plans.wide_rows_offsets[step % 2];
                const next_rows: u32 = policy_plans.wide_rows_offsets[(step + 1) % 2];
                // 2. The policy at the latents, and its draw beside them.
                policy_plans.policy_pass.forward(pipe, current_rows, wide_row_width);
                const step_noise: u32 = policy_plans.noise_offset + step_index * row_count * action_width;
                pipe.params = .{
                    .rows = row_count,
                    .out_dim = action_width,
                    .x_off = policy_plans.policy_pass.outputsOffset(),
                    .u_off = step_noise,
                    .y_off = current_rows,
                    .stride = wide_row_width,
                    .col = latent_width,
                    .distill_log_std_low = options.log_std_low,
                    .distill_log_std_high = options.log_std_high,
                };
                pipe.run("policy_draw", row_count);
                // 3. The step's actions into each state's first candidates.
                const step_candidates: u32 = scorer.actions_offset + step_index * candidate_rows * action_width;
                pipe.params = .{
                    .rows = row_count,
                    .count = action_width,
                    .x_off = current_rows,
                    .y_off = step_candidates,
                    .stride = wide_row_width,
                    .col = latent_width,
                    .plan_candidates = candidates,
                    .plan_policy_plans = options.plans,
                };
                pipe.run("copy_row_blocks", row_count * action_width);
                // 4. The latents one step on - not after the last step.
                const is_last_step: bool = step + 1 == scorer.options.horizon;
                if (!is_last_step) {
                    policy_plans.dynamics_pass.forward(pipe, current_rows, wide_row_width);
                    placeColumns(M, pipe, .{
                        .rows = row_count,
                        .count = latent_width,
                        .source_offset = policy_plans.dynamics_pass.outputsOffset(),
                        .destination_offset = next_rows,
                        .row_stride = wide_row_width,
                        .first_column = 0,
                    });
                }
            }
        }
    };
}

/// MPPI ON THE KIT - zimrrl's `Mppi`: each state's Gaussian over plans, the round's candidates drawn from it into the
/// scorer's candidate actions, and the Gaussian refitted to the elites the scores pick (`zn_mlp`'s MPPI section gives
/// the rule).
///
/// ---- ONE ROUND ----
///
///     sample:  every candidate past the policy's own   <--  mean + spread x noise, clamped   (`mppi_sample`)
///     score:   every candidate                         (`KitPlanScorer.score`)
///     refit:   each state's elites and their weights   (`mppi_elites`), then the Gaussian    (`mppi_refit`)
///
/// The Gaussian is [states][horizon][action] in acts, a mean and a spread, kept there from round to round; the
/// elites' candidate numbers and weights are [states][elites]. The noise is uploaded by the host -
/// [states][candidates][horizon][action] per round, the CPU planner's counter-based draws, so a round is the CPU
/// planner's to rounding - and drawn on the device once its own noise is in place.
/// Whether a plan's knots - `fine_steps` each a knot, then one every `knot_span` steps (`zn_mlp.planKnots`) - end
/// exactly on a `horizon`-step plan's last step. 0 fine steps (every step a knot) always do.
pub fn planKnotsFit(fine_steps: u32, knot_span: u32, horizon: u32) bool {
    if (fine_steps == 0) {
        return true;
    }
    const in_plan: bool = fine_steps <= horizon and knot_span >= 1;
    return in_plan and (horizon - fine_steps) % knot_span == 0;
}

pub fn KitMppi(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Pipe = KitPlanScorer(M).Pipe;

        /// The search's settings: BMPC's.
        pub const Options = struct {
            /// The candidates of each state's block that are the policy's own plans, left alone by the sampling.
            policy_candidates: u32 = 24,
            elites: u32 = 64,
            temperature: f32 = 0.5,
            /// How the temperature reads a score difference (`zn_mlp.MppiTemperature`): absolute - TD-MPC2's rule,
            /// EfficientTDMPC's planner - or relative to the elites' own spread, for scores of any scale (SuperTrack's
            /// tracking planner, whose costs are hundredths).
            temperature_mode: M.MppiTemperature = .absolute,
            min_spread: f32 = 0.05,
            max_spread: f32 = 2,
            /// The rounds of sample, score and refit in one decision (`PlannerConfig.iterationsFor`: BMPC's 6, two more
            /// from 20 action dimensions up) - and the rounds of noise acts holds.
            rounds: u32 = 6,
            /// THE PLAN'S KNOTS (`zn_mlp.planKnots`), the points of a plan the search draws, the steps between two
            /// knots a straight line: its first `fine_steps` steps each a knot, then a knot every `knot_span` steps to
            /// the horizon's last. 0 fine steps: every step a knot. (horizon - fine steps) must divide by the span -
            /// over 16 steps, fine 1 and span 5 put knots at 0, 5, 10, 15; over 20, fine 4 and span 4 at 0, 1, 2, 3,
            /// 7, 11, 15, 19.
            fine_steps: u32 = 0,
            knot_span: u32 = 1,
        };

        options: Options,
        /// What the search is over: its states, candidates, horizon and actions, and where the candidates' actions
        /// and scores are - whichever scorer fills them.
        shape: SearchShape,
        /// acts: each state's Gaussian, [states][knots][action] - its mean and its spread (`knotCount`).
        mean_offset: u32,
        spread_offset: u32,
        /// acts: every round's noise, [round][states][candidates][horizon][action].
        noise_offset: u32,
        round_noise_floats: u32,
        /// acts: each state's elites - their candidate numbers and their weights, [states][elites] each.
        elites_offset: u32,
        weights_offset: u32,
        /// acts: the decision's inputs - each state's warm-start flag (1 warm, 0 at an episode's start), its uniform
        /// draw for the choice, and its exploration noise [states][action].
        warm_flags_offset: u32,
        choice_draws_offset: u32,
        exploration_noise_offset: u32,
        /// acts: the decision's outputs - the targets [states][action] and the first spreads after them (as
        /// `mppi_choose` writes them), each chosen candidate's number [states], and the actions acted on
        /// [states][action].
        targets_offset: u32,
        chosen_offset: u32,
        actions_offset: u32,

        /// The search's regions reserved in `layout`, beside `scorer`, whose candidate actions it draws and whose
        /// scores it reads.
        pub fn init(layout: *KitLayout, shape: SearchShape, options: Options) Self {
            const knots_fit: bool = planKnotsFit(options.fine_steps, options.knot_span, shape.horizon);
            const knots_message: []const u8 = "fine steps {d}, a knot every {d} steps: not ending a {d}-step plan";
            assertf(knots_fit, @src(), knots_message, .{ options.fine_steps, options.knot_span, shape.horizon });
            const knots: u32 = knotsOf(options, shape);
            const gaussian_floats: u32 = shape.states * knots * shape.action_width;
            const candidate_rows: u32 = shape.states * shape.candidates;
            const noise_floats: u32 = candidate_rows * knots * shape.action_width;
            const elite_floats: u32 = shape.states * options.elites;
            const action_floats: u32 = shape.states * shape.action_width;
            const mppi: Self = .{
                .options = options,
                .shape = shape,
                .mean_offset = layout.reserveActs(gaussian_floats),
                .spread_offset = layout.reserveActs(gaussian_floats),
                .noise_offset = layout.reserveActs(options.rounds * noise_floats),
                .round_noise_floats = noise_floats,
                .elites_offset = layout.reserveActs(elite_floats),
                .weights_offset = layout.reserveActs(elite_floats),
                .warm_flags_offset = layout.reserveActs(shape.states),
                .choice_draws_offset = layout.reserveActs(shape.states),
                .exploration_noise_offset = layout.reserveActs(action_floats),
                .targets_offset = layout.reserveActs(2 * action_floats),
                .chosen_offset = layout.reserveActs(shape.states),
                .actions_offset = layout.reserveActs(action_floats),
            };
            return mppi;
        }

        /// Every state's Gaussian at a cold start, written into the host's copy of acts: the mean 0, the spread at
        /// its ceiling (`Mppi.begin` without a warm start).
        /// The knots a search with `options` draws over `shape`'s horizon: its fine steps, then one every span steps
        /// (`zn_mlp.planKnots`).
        pub fn knotsOf(options: Options, shape: SearchShape) u32 {
            const fine_steps: u32 = if (options.fine_steps == 0) shape.horizon else options.fine_steps;
            return fine_steps + (shape.horizon - fine_steps) / options.knot_span;
        }

        /// This search's knots (`knotsOf`).
        pub fn knotCount(mppi: Self) u32 {
            return knotsOf(mppi.options, mppi.shape);
        }

        pub fn writeColdStart(mppi: Self, acts: []f32) void {
            const shape: SearchShape = mppi.shape;
            const gaussian_floats: usize = shape.states * mppi.knotCount() * mppi.shape.action_width;
            @memset(acts[mppi.mean_offset..][0..gaussian_floats], 0);
            @memset(acts[mppi.spread_offset..][0..gaussian_floats], mppi.options.max_spread);
        }

        /// Round `round`'s noise, [states][candidates][horizon][action], written into the host's copy of acts.
        pub fn writeNoise(mppi: Self, acts: []f32, round: u32, noise: []const f32) void {
            const round_start: u32 = mppi.noise_offset + round * mppi.round_noise_floats;
            @memcpy(acts[round_start..][0..noise.len], noise);
        }

        /// The settings every MPPI kernel shares: the states, their candidates and the policy's, the plan's shape.
        fn baseParams(mppi: Self) M.Params {
            const shape: SearchShape = mppi.shape;
            const base_params: M.Params = .{
                .rows = shape.states,
                .out_dim = mppi.shape.action_width,
                .plan_candidates = shape.candidates,
                .plan_horizon = shape.horizon,
                .plan_policy_plans = mppi.options.policy_candidates,
                .plan_fine_steps = mppi.options.fine_steps,
                .plan_knot_span = mppi.options.knot_span,
                .mppi_elites = mppi.options.elites,
                .mppi_temperature = mppi.options.temperature,
                .mppi_temperature_mode = @backingInt(mppi.options.temperature_mode),
                .mppi_min_spread = mppi.options.min_spread,
                .mppi_max_spread = mppi.options.max_spread,
            };
            return base_params;
        }

        /// Every state's Gaussian at the decision's start (`mppi_begin`): its last plan shifted forward by
        /// `plan_age_steps` - the steps since it was decided - where it is warm, zero at an episode's start, every
        /// spread at its ceiling.
        pub fn begin(mppi: Self, pipe: *Pipe, plan_age_steps: u32) void {
            var begin_params: M.Params = mppi.baseParams();
            begin_params.mppi_warm_shift = plan_age_steps;
            begin_params.x_off = mppi.warm_flags_offset;
            begin_params.t_off = mppi.mean_offset;
            begin_params.u_off = mppi.spread_offset;
            pipe.params = begin_params;
            const shape: SearchShape = mppi.shape;
            pipe.run("mppi_begin", shape.states * mppi.shape.action_width);
        }

        /// Round `round`'s candidates drawn from every state's Gaussian, into the scorer's candidate actions - every
        /// row but the policy's own.
        pub fn sample(mppi: Self, pipe: *Pipe, round: u32) void {
            const shape: SearchShape = mppi.shape;
            var sample_params: M.Params = mppi.baseParams();
            sample_params.t_off = mppi.mean_offset;
            sample_params.u_off = mppi.spread_offset;
            sample_params.v_off = mppi.noise_offset + round * mppi.round_noise_floats;
            sample_params.y_off = mppi.shape.candidate_actions_at;
            pipe.params = sample_params;
            const candidate_rows: u32 = shape.states * shape.candidates;
            const value_count: u32 = candidate_rows * shape.horizon * mppi.shape.action_width;
            pipe.run("mppi_sample", value_count);
        }

        /// Every state's Gaussian refitted to the elites of the scorer's scores.
        pub fn refit(mppi: Self, pipe: *Pipe) void {
            const shape: SearchShape = mppi.shape;
            var elites_params: M.Params = mppi.baseParams();
            elites_params.x_off = mppi.shape.scores_at;
            elites_params.y_off = mppi.elites_offset;
            elites_params.z_off = mppi.weights_offset;
            pipe.params = elites_params;
            pipe.run("mppi_elites", shape.states);
            var refit_params: M.Params = mppi.baseParams();
            refit_params.x_off = mppi.shape.candidate_actions_at;
            refit_params.y_off = mppi.elites_offset;
            refit_params.z_off = mppi.weights_offset;
            refit_params.t_off = mppi.mean_offset;
            refit_params.u_off = mppi.spread_offset;
            pipe.params = refit_params;
            const gaussian_floats: u32 = shape.states * mppi.knotCount() * mppi.shape.action_width;
            pipe.run("mppi_refit", gaussian_floats);
        }

        /// The decision's target for every state (`mppi_choose`): one elite drawn by the refit's weights, its first
        /// action and the first step's spread.
        pub fn choose(mppi: Self, pipe: *Pipe) void {
            var choose_params: M.Params = mppi.baseParams();
            choose_params.x_off = mppi.shape.candidate_actions_at;
            choose_params.y_off = mppi.elites_offset;
            choose_params.z_off = mppi.weights_offset;
            choose_params.u_off = mppi.spread_offset;
            choose_params.v_off = mppi.choice_draws_offset;
            choose_params.t_off = mppi.targets_offset;
            choose_params.e_off = mppi.chosen_offset;
            pipe.params = choose_params;
            pipe.run("mppi_choose", mppi.shape.states);
        }

        /// The actions acted on while training (`mppi_explore`): each target jittered by its spread, clamped.
        pub fn explore(mppi: Self, pipe: *Pipe) void {
            var explore_params: M.Params = mppi.baseParams();
            explore_params.t_off = mppi.targets_offset;
            explore_params.v_off = mppi.exploration_noise_offset;
            explore_params.y_off = mppi.actions_offset;
            pipe.params = explore_params;
            pipe.run("mppi_explore", mppi.shape.states * mppi.shape.action_width);
        }

        /// The actions acted on while evaluating: the targets themselves.
        pub fn takeTargets(mppi: Self, pipe: *Pipe) void {
            const action_width: u32 = mppi.shape.action_width;
            placeColumns(M, pipe, .{
                .rows = mppi.shape.states,
                .count = action_width,
                .source_offset = mppi.targets_offset,
                .destination_offset = mppi.actions_offset,
                .row_stride = action_width,
                .first_column = 0,
            });
        }
    };
}

/// ONE DECISION ON THE KIT - the CPU actor's `act`: the policy's own plans, MPPI's rounds around the scorer, the
/// chosen elite's first action, and - while training - its jitter. Every piece is the kit's own (`KitPolicyPlans`,
/// `KitPlanScorer`, `KitMppi`), and between them nothing goes back to the host:
///
///     the policy's plans        into the first candidates of each state's block          (once per decision)
///     the warm start            each state's Gaussian: its last plan shifted, or zero
///     rounds x ( sample  -->  score  -->  refit )
///     the choice                one elite drawn by its weight: the target and its spread
///     the action                the target jittered (`explore`), or the target itself (`evaluate`)
///
/// The host writes each decision's inputs (`writeDecisionInputs`): the observations, the warm-start flags, and - for
/// now - every piece's noise, drawn exactly as the CPU actor's `act` draws it from the decision's generator:
///
///     the policy's plans      split 0, then the state     (index: (plan x horizon + step) x action + dimension)
///     round r's samples       split 1, then r, the state  (index: (candidate x horizon + step) x action + dimension)
///     the choice's draw       split 1, then the rounds, the state - one uniform in [0, 1)
///     the exploration         split 2, then the state     (index: the dimension)
pub fn KitPlanner(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Pipe = KitPlanScorer(M).Pipe;

        /// What a decision does with its target: jitters it while training, takes it as it is when evaluating.
        pub const Mode = enum { explore, evaluate };

        scorer: KitPlanScorer(M),
        policy_plans: KitPolicyPlans(M),
        mppi: KitMppi(M),

        /// One decision's inputs for every state, written into the host's copy of acts: the states' observations,
        /// whether each starts an episode (`first_steps`: its search starts from zero), and every piece's noise from
        /// `rng`, split as the CPU actor splits it (this type's head). `first_state` is the planner's first state's
        /// number among all the states the CPU actor would plan at once - 0 unless the states are planned in chunks,
        /// where each chunk's states take their noise from their own numbers, so the chunks together decide exactly
        /// as one decision over all of them (each state's search is its own).
        ///
        /// WHY THE INDICES ARE COMPUTED. zimrnum's generator is counter-based: `rng.normal(index)` is a pure function
        /// of the generator and the index, so a value is the same wherever and whenever it is drawn. The CPU actor
        /// draws each value at the index it has in ITS array; the kit's buffers lay the same values out differently
        /// (by step first, for instance, where the CPU's are by plan first). So each value is drawn at its CPU index
        /// and written at its kit position - the two layouts meet value by value, and the kit decides exactly as the
        /// CPU actor does from the same generator.
        pub fn writeDecisionInputs(
            planner: Self,
            host_acts: []f32,
            observations: []const f32,
            first_steps: []const bool,
            rng: zn.Rng,
            first_state: u32,
        ) void {
            const scorer: KitPlanScorer(M) = planner.scorer;
            @memcpy(host_acts[scorer.observations_offset..][0..observations.len], observations);
            planner.writePolicyPlansNoise(host_acts, rng.split(0), first_state);
            planner.writeRoundsNoise(host_acts, rng.split(1), first_state);
            planner.writeChoiceAndExploration(host_acts, rng.split(1), rng.split(2), first_steps, first_state);
        }

        /// The policy's plans' noise, from `plans_rng` (the decision's split 0): each state's own stream, the CPU
        /// index (plan x horizon + step) x action + dimension, written at the kit's [step][state x plan][dimension].
        fn writePolicyPlansNoise(
            planner: Self,
            host_acts: []f32,
            plans_rng: zn.Rng,
            first_state: u32,
        ) void {
            const scorer: KitPlanScorer(M) = planner.scorer;
            const state_count: usize = scorer.options.states;
            const horizon: usize = scorer.options.horizon;
            const action_width: usize = scorer.action_width;
            const plans_per_state: usize = planner.policy_plans.options.plans;
            const plan_rows: usize = state_count * plans_per_state;
            const plans_noise_floats: usize = horizon * plan_rows * action_width;
            const plans_noise: []f32 = host_acts[planner.policy_plans.noise_offset..][0..plans_noise_floats];
            for (0..state_count) |state| {
                const state_number: u32 = first_state + @as(u32, @intCast(state));
                const state_stream: zn.Rng = plans_rng.split(state_number);
                for (0..plans_per_state) |plan| {
                    const plan_row: usize = state * plans_per_state + plan;
                    for (0..horizon) |step| {
                        for (0..action_width) |dimension| {
                            const cpu_index: u32 = @intCast((plan * horizon + step) * action_width + dimension);
                            const kit_position: usize = (step * plan_rows + plan_row) * action_width + dimension;
                            plans_noise[kit_position] = state_stream.normal(f32, cpu_index);
                        }
                    }
                }
            }
        }

        /// Every MPPI round's sampling noise, from `search_rng` (the decision's split 1): round r's stream for each
        /// state is split r, then the state; the CPU index (candidate x horizon + step) x action + dimension, written
        /// at the kit's [state x candidate][step][dimension] within the round's block. The policy's own candidates -
        /// the first of each state's - take their actions from the policy's plans, not from noise, so their slots
        /// stay zero.
        fn writeRoundsNoise(
            planner: Self,
            host_acts: []f32,
            search_rng: zn.Rng,
            first_state: u32,
        ) void {
            const scorer: KitPlanScorer(M) = planner.scorer;
            const state_count: usize = scorer.options.states;
            const candidates_per_state: usize = scorer.options.candidates;
            const horizon: usize = scorer.options.horizon;
            const action_width: usize = scorer.action_width;
            const mppi: KitMppi(M) = planner.mppi;
            const first_sampled_candidate: usize = mppi.options.policy_candidates;
            for (0..mppi.options.rounds) |round| {
                const round_number: u32 = @intCast(round);
                const round_start: u32 = mppi.noise_offset + round_number * mppi.round_noise_floats;
                const round_noise: []f32 = host_acts[round_start..][0..mppi.round_noise_floats];
                @memset(round_noise, 0);
                for (0..state_count) |state| {
                    const state_number: u32 = first_state + @as(u32, @intCast(state));
                    const state_stream: zn.Rng = search_rng.split(round_number).split(state_number);
                    for (first_sampled_candidate..candidates_per_state) |candidate| {
                        const candidate_row: usize = state * candidates_per_state + candidate;
                        for (0..horizon) |step| {
                            for (0..action_width) |dimension| {
                                const candidate_step: usize = candidate * horizon + step;
                                const cpu_index: u32 = @intCast(candidate_step * action_width + dimension);
                                const kit_position: usize = (candidate_row * horizon + step) * action_width + dimension;
                                round_noise[kit_position] = state_stream.normal(f32, cpu_index);
                            }
                        }
                    }
                }
            }
        }

        /// Each state's draw for the choice among its elites - from `search_rng` split by the round count, then the
        /// state: the stream right after the last round's, as the CPU actor takes it - its exploration noise from
        /// `explore_rng` (the decision's split 2) split by the state, and whether its search starts warm.
        fn writeChoiceAndExploration(
            planner: Self,
            host_acts: []f32,
            search_rng: zn.Rng,
            explore_rng: zn.Rng,
            first_steps: []const bool,
            first_state: u32,
        ) void {
            const state_count: usize = planner.scorer.options.states;
            const action_width: usize = planner.scorer.action_width;
            const mppi: KitMppi(M) = planner.mppi;
            const choice_rng: zn.Rng = search_rng.split(mppi.options.rounds);
            const choice_draws: []f32 = host_acts[mppi.choice_draws_offset..][0..state_count];
            const exploration_floats: usize = state_count * action_width;
            const exploration_noise: []f32 = host_acts[mppi.exploration_noise_offset..][0..exploration_floats];
            for (0..state_count) |state| {
                const state_number: u32 = first_state + @as(u32, @intCast(state));
                choice_draws[state] = choice_rng.split(state_number).unitFloat(f32, 0);
                const exploration_stream: zn.Rng = explore_rng.split(state_number);
                for (0..action_width) |dimension| {
                    const dimension_number: u32 = @intCast(dimension);
                    const exploration_value: f32 = exploration_stream.normal(f32, dimension_number);
                    exploration_noise[state * action_width + dimension] = exploration_value;
                }
                // A first step starts its search from zero (cold); any other from its last plan, shifted (warm).
                const starts_warm: bool = !first_steps[state];
                host_acts[mppi.warm_flags_offset + state] = if (starts_warm) 1 else 0;
            }
        }

        /// What `writeDecisionInputs` wrote, uploaded from the host's copy of acts - and nothing else, so each state's
        /// Gaussian, kept in acts between decisions, stays where it is.
        pub fn uploadDecisionInputs(
            planner: Self,
            pipe: *Pipe,
            host_acts: []const f32,
        ) void {
            const scorer: KitPlanScorer(M) = planner.scorer;
            const states: u32 = scorer.options.states;
            const action_width: u32 = scorer.action_width;
            const observation_floats: u32 = states * scorer.observation_width;
            uploadActsRegion(M, pipe, host_acts, scorer.observations_offset, observation_floats);
            const plan_rows: u32 = states * planner.policy_plans.options.plans;
            const plans_noise_floats: u32 = scorer.options.horizon * plan_rows * action_width;
            uploadActsRegion(M, pipe, host_acts, planner.policy_plans.noise_offset, plans_noise_floats);
            const mppi: KitMppi(M) = planner.mppi;
            const all_rounds_floats: u32 = mppi.options.rounds * mppi.round_noise_floats;
            uploadActsRegion(M, pipe, host_acts, mppi.noise_offset, all_rounds_floats);
            uploadActsRegion(M, pipe, host_acts, mppi.choice_draws_offset, states);
            uploadActsRegion(M, pipe, host_acts, mppi.exploration_noise_offset, states * action_width);
            uploadActsRegion(M, pipe, host_acts, mppi.warm_flags_offset, states);
        }

        /// What the agent's own networks say about how sure they are, at one state just after a decision - every
        /// number one the decision's forward passes computed, read back from acts (`readSignals`). A record for
        /// watching, not a claim: what each looks like on a task the agent masters is what a harder task is compared
        /// against.
        pub const Signals = struct {
            /// The chosen plan's score - the model's estimate of what the plan is worth - and the standard deviation
            /// of that estimate across the pairs of dynamics and value heads: how much the heads disagree.
            plan_score: f32,
            heads_disagreement: f32,
            /// How wide the reward head's predicted distribution is at the chosen plan's last step, and the first
            /// value head's where the plan ends - both under the LAST dynamics head the scorer rolled: the standard
            /// deviation of the bins' positions under the head's softmax, on the bins' axis (symlog units). A head
            /// that is sure puts its mass on a bin or two.
            reward_width: f32,
            value_width: f32,
            /// The encoder's latent: the mean entropy of its SimNorm groups, in nats - ln(group) for a group spread
            /// evenly, 0 for a group on one entry.
            latent_entropy: f32,
            /// The encoder's first layer: the inverse of its linear outputs' standard deviation across the row - large
            /// where the layer's outputs are flat for this observation.
            first_layer_inverse_spread: f32,
        };

        /// `Signals` for `state` from the device's acts after a decision; `simnorm_group` is the latent's group size.
        pub fn readSignals(
            planner: Self,
            device_acts: []const f32,
            state: u32,
            simnorm_group: u32,
        ) Signals {
            const scorer: KitPlanScorer(M) = planner.scorer;
            // The chosen plan: the elite the decision drew, kept as a float in acts like every other number there.
            const candidates_per_state: u32 = scorer.options.candidates;
            const chosen_candidate: u32 = @trunc(device_acts[planner.mppi.chosen_offset + state]);
            const chosen_row: u32 = state * candidates_per_state + chosen_candidate;
            // The scorer kept each candidate's score's variance across the heads' pairs; its root is their spread.
            const score_variance: f32 = device_acts[scorer.variances_offset + chosen_row];
            // The reward and value heads' logits at the chosen row: the last step the scorer decoded, under the last
            // dynamics head it rolled.
            const bins: TwoHotBins(M) = scorer.options.bins;
            const reward_logits: []const f32 = headLogits(device_acts, scorer.reward_pass, chosen_row);
            const value_logits: []const f32 = headLogits(device_acts, scorer.value_passes[0], chosen_row);
            // The state's latent - the encoder's output - and its first layer's inverse spread, which that layer's
            // normalisation keeps for its backward.
            const latent_width: u32 = scorer.latent_width;
            const latent_start: u32 = scorer.encoder_pass.outputsOffset() + state * latent_width;
            const latent: []const f32 = device_acts[latent_start..][0..latent_width];
            const first_layer: LayerRegions = scorer.encoder_pass.layer_regions[0];
            const signals: Signals = .{
                .plan_score = device_acts[scorer.scores_offset + chosen_row],
                .heads_disagreement = @sqrt(score_variance),
                .reward_width = zm.binsSpreadUnderSoftmax(f32, reward_logits, bins.low, bins.high),
                .value_width = zm.binsSpreadUnderSoftmax(f32, value_logits, bins.low, bins.high),
                .latent_entropy = zm.meanGroupEntropy(f32, latent, simnorm_group),
                .first_layer_inverse_spread = device_acts[first_layer.inverse_spreads + state],
            };
            return signals;
        }

        /// One row of a two-hot head's logits, from the device's acts.
        fn headLogits(
            device_acts: []const f32,
            head_pass: KitNetwork(M).Application,
            row: u32,
        ) []const f32 {
            const bin_count: u32 = head_pass.network.outputWidth();
            const row_start: u32 = head_pass.outputsOffset() + row * bin_count;
            return device_acts[row_start..][0..bin_count];
        }

        /// One decision for every state (this type's head), after the decision's inputs are in acts.
        pub fn decide(planner: Self, pipe: *Pipe, mode: Mode) void {
            planner.policy_plans.fill(pipe);
            // EfficientTDMPC decides every step: a warm plan has aged one step.
            planner.mppi.begin(pipe, 1);
            for (0..planner.mppi.options.rounds) |round| {
                planner.mppi.sample(pipe, @intCast(round));
                planner.scorer.score(pipe);
                planner.mppi.refit(pipe);
            }
            planner.mppi.choose(pipe);
            switch (mode) {
                .explore => planner.mppi.explore(pipe),
                .evaluate => planner.mppi.takeTargets(pipe),
            }
        }
    };
}

// ============================================================================================================
// THE LEARNER
// ============================================================================================================

/// ONE UPDATE OF EFFICIENTTDMPC ON THE KIT - the CPU agent's `Learner.update`: a batch of windows sampled from the
/// replay, the world model's update, and (outside pretraining) the policy's, on the kit's pieces - `KitRollout`,
/// `KitWorldModel`, `KitValueTargets`, `KitPolicyLearner` - over networks its caller placed (and shares with the
/// planner).
///
/// ---- ONE UPDATE ----
///
///     sample     W windows of H stored steps from the replay - the CPU learner's own `SequenceReplay.sample` call,
///                so the same replay and generator give the same batch
///     lay out    the windows as the CPU learner's `loadWindows` lays them out: block 0 the windows' first
///                observations, block t + 1 what followed step t; each step's actions, rewards and finished flags;
///                the targets' noise and the value heads' dropout masks; the planner's stored targets for the policy
///     upload     each region the layout wrote, and only those - the rest of acts holds what the device keeps
///     the world model:  forward, value targets, backward, update                  (`KitWorldModel`, C2)
///     the policy:       on every head's rolled latents, unless pretraining          (`KitPolicyLearner`)
///
/// ---- NOT A DESCRIPTOR ----
///
/// Unlike its pieces, a learner keeps state that changes - its Adam step counts, its count of real updates, the host's
/// copy of acts it writes the batch into - so it is used through a pointer.
///
/// ---- THE GENERATORS ----
///
/// The update's generator is split as the CPU learner splits it: 0 for the sampling, 1 for the targets' noise. The
/// value heads' dropout masks come from a generator per value application: the caller's when it passes them (the CPU
/// learner draws each from its graph's split by the dropout node's index, which only its graph knows), else the
/// learner's own - split 2, then the application's index - equally valid, but not the CPU learner's masks.
///
/// ---- REANALYZE ----
///
/// Every `reanalyze_interval`-th update outside pretraining, the first windows of the batch are planned again - the
/// CPU learner's `Reanalyzer`: every stored state of the first `reanalyze_windows` windows, H x R of them, planned from
/// scratch (`first_steps` all true) and evaluated, by a second planner on the same networks - the reanalyzing
/// planner's settings, the policy's plans drawn with the exploration's wider spread - before the world model learns,
/// so the planner reads the networks as the update found them. The new targets replace the batch's (the policy
/// learns from them) and are written back to the replay's stored rows. Its generator is the update's split 3.
///
/// The stored states are planned a CHUNK at a time (`Options.reanalyze_chunk_states`): a planner over all of them
/// would need hundreds of candidates for each, more activations than the kit's buffer holds. Each state's search is
/// its own - its own Gaussian, its own candidates' scores, its noise drawn from its own number - so the chunks decide
/// exactly as one decision over every state would.
pub fn KitLearner(comptime M: type) type {
    return struct {
        const Self = @This();
        const Tdmpc = bmpc.Bmpc(f32);
        const Network = KitNetwork(M);
        pub const Pipe = Network.Pipe;
        const Replay = zrl.SequenceReplay(f32);

        /// How the learner fits its work into the kit's buffers.
        pub const Options = struct {
            /// The stored states reanalyze plans at once (this type's head, "reanalyze").
            reanalyze_chunk_states: u32 = 12,
        };

        /// The networks a learner trains and reads, placed by its caller in the world model's order - the encoder,
        /// every dynamics head, the reward head, every value head, every target value head - then the policy.
        pub const Networks = struct {
            encoder: Network,
            dynamics: []const Network,
            reward: Network,
            values: []const Network,
            target_values: []const Network,
            policy: Network,
        };

        config: Tdmpc.Config,
        row: Tdmpc.Row,
        rollout: KitRollout(M),
        world_model: KitWorldModel(M),
        value_targets: KitValueTargets(M),
        policy_learner: KitPolicyLearner(M),
        /// The reanalyze planner over one chunk of the H x R stored states, when the configuration reanalyzes; the
        /// stored states' observations (state = step x R + window), every one an episode's start, and the new targets
        /// as the replay's write-back takes them (one row per state: its means, then its spreads).
        reanalyzer: ?KitPlanner(M),
        reanalyze_chunk_states: u32,
        reanalyzed_windows: usize,
        reanalyze_observations: []f32,
        /// One chunk's observations, and every stored state's new target and first spread, [states][action].
        reanalyze_chunk_observations: []f32,
        reanalyze_targets: []f32,
        reanalyze_spreads: []f32,
        reanalyze_first_steps: []bool,
        reanalyze_target_rows: []f32,
        /// The sampled batch, as `SequenceReplay.sample` writes it: each window's origin, its rows (step-major,
        /// [horizon x windows, row]) and each stored step's finished flag.
        origins: []Replay.WindowOrigin,
        window_rows: []f32,
        finished: []f32,
        /// The batch laid out for the kit (`loadWindows`' layout), and the policy's targets.
        observations: []f32,
        actions: []f32,
        rewards: []f32,
        target_means: []f32,
        target_log_stds: []f32,
        target_noise: []f32,
        dropout_rngs: []zn.Rng,
        /// The host's copy of acts the batch is written into, region by region.
        host_acts: []f32,
        /// The updates made outside pretraining, and each optimiser's step count (Adam's bias corrections).
        updates: usize = 0,
        world_model_steps: u32 = 0,
        policy_steps: u32 = 0,

        /// The learner's pieces reserved in `layout` over `networks`, for `config`'s shape. `acts_floats` is the size
        /// the caller's acts will have once every region is reserved (the host copy is that long). Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *KitLayout,
            networks: Networks,
            observation_width: u32,
            action_width: u32,
            config: Tdmpc.Config,
            options: Options,
        ) !Self {
            const horizon: u32 = @intCast(config.horizon);
            const window_count: u32 = @intCast(config.windows);
            const rollout: KitRollout(M) = try .init(arena, layout, networks.encoder, networks.dynamics, .{
                .horizon = horizon,
                .window_count = window_count,
                .observation_width = observation_width,
                .action_width = action_width,
                .rho = config.rho,
            });
            const world_model: KitWorldModel(M) = try .init(
                arena,
                layout,
                rollout,
                networks.reward,
                networks.values,
                networks.target_values,
                .{
                    .consistency_weight = config.consistency_weight,
                    .reward_weight = config.reward_weight,
                    .value_weight = config.value_weight,
                    .value_dropout = .on,
                },
            );
            const value_targets: KitValueTargets(M) = try .init(
                arena,
                layout,
                rollout,
                networks.policy,
                networks.reward,
                networks.target_values,
                world_model.value_targets_offset,
                .{
                    .discount = config.discount,
                    .log_std_low = config.spread.log_std_low,
                    .log_std_high = config.spread.log_std_high,
                },
            );
            const policy_learner: KitPolicyLearner(M) = try .init(arena, layout, networks.policy, rollout, .{
                .rho = config.rho,
                .entropy_coefficient = config.entropy_coefficient,
                .log_std_low = config.spread.log_std_low,
                .log_std_high = config.spread.log_std_high,
                .learning_rate = config.learning_rate,
                .epsilon = config.policy_epsilon,
                .gradient_clip = config.gradient_clip,
            });
            // The reanalyze planner, when the configuration reanalyzes.
            const reanalyzed_windows: usize = @min(config.reanalyze_windows, config.windows);
            const reanalyzed_states: usize = config.horizon * reanalyzed_windows;
            const reanalyzes: bool = config.reanalyze_interval > 0 and reanalyzed_states > 0;
            const chunk_states: u32 = @intCast(@min(reanalyzed_states, options.reanalyze_chunk_states));
            const reanalyzer: ?KitPlanner(M) = if (reanalyzes) try reanalyzePlanner(
                arena,
                layout,
                networks,
                observation_width,
                action_width,
                config,
                chunk_states,
            ) else null;
            const reanalyze_first_steps: []bool = try arena.alloc(bool, reanalyzed_states);
            @memset(reanalyze_first_steps, true);
            const stored_rows: usize = config.horizon * config.windows;
            const row: Tdmpc.Row = .{ .observation_width = observation_width, .action_width = action_width };
            var value_application_count: usize = 0;
            for (world_model.value_applications) |head_values| {
                for (head_values) |values_at_step| {
                    value_application_count += values_at_step.len;
                }
            }
            const learner: Self = .{
                .config = config,
                .row = row,
                .rollout = rollout,
                .world_model = world_model,
                .value_targets = value_targets,
                .policy_learner = policy_learner,
                .reanalyzer = reanalyzer,
                .reanalyze_chunk_states = chunk_states,
                .reanalyzed_windows = reanalyzed_windows,
                .reanalyze_observations = try arena.alloc(f32, reanalyzed_states * observation_width),
                .reanalyze_chunk_observations = try arena.alloc(f32, chunk_states * observation_width),
                .reanalyze_targets = try arena.alloc(f32, reanalyzed_states * action_width),
                .reanalyze_spreads = try arena.alloc(f32, reanalyzed_states * action_width),
                .reanalyze_first_steps = reanalyze_first_steps,
                .reanalyze_target_rows = try arena.alloc(f32, reanalyzed_states * 2 * action_width),
                .origins = try arena.alloc(Replay.WindowOrigin, config.windows),
                .window_rows = try arena.alloc(f32, stored_rows * row.width()),
                .finished = try arena.alloc(f32, stored_rows),
                .observations = try arena.alloc(f32, (config.horizon + 1) * config.windows * observation_width),
                .actions = try arena.alloc(f32, stored_rows * action_width),
                .rewards = try arena.alloc(f32, stored_rows),
                .target_means = try arena.alloc(f32, stored_rows * action_width),
                .target_log_stds = try arena.alloc(f32, stored_rows * action_width),
                .target_noise = try arena.alloc(f32, stored_rows * action_width),
                .dropout_rngs = try arena.alloc(zn.Rng, value_application_count),
                .host_acts = &.{},
            };
            return learner;
        }

        /// The reanalyze planner (this type's head, "reanalyze"): a scorer, the policy's plans and MPPI over
        /// `states` stored states, with the reanalyzing planner's settings and the policy's plans drawn with the
        /// exploration's spread - on the learner's own networks.
        fn reanalyzePlanner(
            arena: Allocator,
            layout: *KitLayout,
            networks: Networks,
            observation_width: u32,
            action_width: u32,
            config: Tdmpc.Config,
            states: u32,
        ) !KitPlanner(M) {
            const planner_config: Tdmpc.PlannerConfig = config.reanalyzing;
            const scorer: KitPlanScorer(M) = try .init(
                arena,
                layout,
                networks.encoder,
                networks.dynamics,
                networks.reward,
                networks.values,
                observation_width,
                action_width,
                .{
                    .horizon = @intCast(planner_config.horizon),
                    .states = states,
                    .candidates = @intCast(planner_config.candidates),
                    .discount = config.discount,
                    .objective = planner_config.objective,
                    .pessimism = planner_config.pessimism,
                },
            );
            const plans_options: KitPolicyPlans(M).Options = .{
                .plans = @intCast(planner_config.policy_candidates),
                .log_std_low = config.exploration_spread.log_std_low,
                .log_std_high = config.exploration_spread.log_std_high,
            };
            const policy_plans: KitPolicyPlans(M) = try .init(
                arena,
                layout,
                scorer,
                networks.policy,
                networks.dynamics[0],
                plans_options,
            );
            const mppi: KitMppi(M) = .init(layout, scorer.searchShape(), .{
                .policy_candidates = @intCast(planner_config.policy_candidates),
                .elites = @intCast(planner_config.elites),
                .temperature = config.temperature,
                .min_spread = config.min_spread,
                .max_spread = config.max_spread,
                .rounds = @intCast(planner_config.iterationsFor(action_width)),
            });
            const planner: KitPlanner(M) = .{ .scorer = scorer, .policy_plans = policy_plans, .mppi = mppi };
            return planner;
        }

        /// The host's copy of acts, once the caller's layout is complete (`layout.acts_floats` floats, zeroed), with
        /// the learner's starting state in it: every window counting, the running scale at 1. The caller uploads
        /// the whole of it once, before the first update. Memory: `arena`.
        pub fn allocateHostActs(
            learner: *Self,
            arena: Allocator,
            acts_floats: u32,
        ) ![]f32 {
            learner.host_acts = try arena.alloc(f32, acts_floats);
            @memset(learner.host_acts, 0);
            learner.policy_learner.writeInitialState(learner.host_acts);
            if (learner.reanalyzer) |reanalyzer| {
                reanalyzer.scorer.writeWeights(learner.host_acts);
            }
            return learner.host_acts;
        }

        /// One update (this type's head): sample, lay out, upload, the world model's update, then the policy's unless
        /// `pretraining`. `dropout_rngs`: the value heads' mask generators, one per value application in the loss's
        /// order - or null for the learner's own.
        pub fn update(
            learner: *Self,
            pipe: *Pipe,
            replay: *Replay,
            rng: zn.Rng,
            update_index: u32,
            pretraining: bool,
            dropout_rngs: ?[]const zn.Rng,
        ) !void {
            const config: Tdmpc.Config = learner.config;
            // 1. The batch - the CPU learner's very call.
            try replay.sample(
                rng.split(0),
                update_index,
                config.horizon,
                learner.origins,
                learner.window_rows,
                learner.finished,
            );
            if (!pretraining) {
                learner.updates += 1;
            }
            // Reanalyze on every interval-th real update - the real updates counted from 1, so the 10th, the 20th.
            const reanalyze_interval: usize = config.reanalyze_interval;
            const interval_reached: bool = reanalyze_interval > 0 and learner.updates % reanalyze_interval == 0;
            if (!pretraining and interval_reached) {
                try learner.reanalyze(pipe, replay, rng.split(3));
            }
            // 2. Laid out, and uploaded region by region.
            learner.layOutBatch();
            learner.writeTargetNoise(rng.split(1));
            const mask_rngs: []const zn.Rng = dropout_rngs orelse learner.ownDropoutRngs(rng.split(2));
            const host_acts: []f32 = learner.host_acts;
            learner.rollout.writeWindow(host_acts, learner.observations, learner.actions);
            learner.rollout.writeFinished(host_acts, learner.finished);
            learner.world_model.writeTargets(host_acts, learner.rewards, learner.rewards);
            learner.value_targets.writeNoise(host_acts, learner.target_noise);
            try learner.world_model.writeValueDropoutMasksFrom(host_acts, mask_rngs);
            learner.rollout.uploadWindow(pipe, host_acts);
            learner.world_model.uploadTargets(pipe, host_acts);
            learner.value_targets.uploadNoise(pipe, host_acts);
            learner.world_model.uploadValueDropoutMasks(pipe, host_acts);
            // 3. The world model: its forward, the value targets its loss reads, its backward and its step.
            learner.world_model.forward(pipe);
            learner.value_targets.compute(pipe);
            learner.world_model.backward(pipe);
            learner.world_model_steps += 1;
            learner.world_model.update(pipe, .{
                .learning_rate = config.learning_rate,
                .encoder_rate_scale = config.encoder_rate_scale,
                .gradient_clip = config.gradient_clip,
                .target_follow = config.target_follow,
            }, learner.world_model_steps);
            // 4. The policy, on the rolled latents the world model's forward left in place - unless pretraining.
            if (!pretraining) {
                learner.policy_learner.writeTargets(host_acts, learner.target_means, learner.target_log_stds);
                learner.policy_learner.uploadTargets(pipe, host_acts);
                learner.policy_steps += 1;
                learner.policy_learner.update(pipe, learner.policy_steps);
            }
        }

        /// One chunk of the stored states planned, from stored state `chunk_start`: as many as the planner holds, and
        /// each one's target and first spread into `new_target_means` and `new_target_spreads`, [stored state][action].
        ///
        /// The planner always plans its full number of states. A last chunk with fewer stored states left fills the
        /// rest of the planner's states with copies of its last one - planned, their answers discarded - which costs
        /// a little search and saves a second planner of another size.
        fn reanalyzeChunk(
            learner: *Self,
            pipe: *Pipe,
            reanalyzer: KitPlanner(M),
            rng: zn.Rng,
            chunk_start: usize,
            new_target_means: []f32,
            new_target_spreads: []f32,
        ) !void {
            const observation_width: usize = learner.row.observation_width;
            const action_width: usize = learner.row.action_width;
            const stored_state_count: usize = learner.config.horizon * learner.reanalyzed_windows;
            const planner_states: usize = learner.reanalyze_chunk_states;
            const stored_states_in_chunk: usize = @min(planner_states, stored_state_count - chunk_start);
            const last_stored_state_in_chunk: usize = stored_states_in_chunk - 1;
            // The chunk's observations, one per planner state - the chunk's last stored state repeated where the chunk
            // runs out.
            const chunk_observations: []f32 = learner.reanalyze_chunk_observations;
            const stored_observations: []const f32 = learner.reanalyze_observations;
            for (0..planner_states) |planner_state| {
                const stored_state: usize = chunk_start + @min(planner_state, last_stored_state_in_chunk);
                const stored_observation: []const f32 =
                    stored_observations[stored_state * observation_width ..][0..observation_width];
                const planner_observation_start: usize = planner_state * observation_width;
                const planner_observation: []f32 =
                    chunk_observations[planner_observation_start..][0..observation_width];
                @memcpy(planner_observation, stored_observation);
            }
            // Every stored state is planned from scratch, and draws its noise by its own number among all the stored
            // states - so the chunks decide as one decision over all of them would.
            const first_steps: []const bool = learner.reanalyze_first_steps[0..planner_states];
            const first_stored_state: u32 = @intCast(chunk_start);
            const host_acts: []f32 = learner.host_acts;
            reanalyzer.writeDecisionInputs(host_acts, chunk_observations, first_steps, rng, first_stored_state);
            reanalyzer.uploadDecisionInputs(pipe, host_acts);
            reanalyzer.decide(pipe, .evaluate);
            // The targets read back, the chunk's own rows only.
            const device_acts: []const f32 = try readCurrentActs(M, pipe, "reanalyze");
            const chunk_floats: usize = stored_states_in_chunk * action_width;
            const planner_floats: usize = planner_states * action_width;
            const targets_offset: usize = reanalyzer.mppi.targets_offset;
            const spreads_offset: usize = targets_offset + planner_floats;
            const chunk_target_means: []const f32 = device_acts[targets_offset..][0..chunk_floats];
            const chunk_target_spreads: []const f32 = device_acts[spreads_offset..][0..chunk_floats];
            const chunk_output_start: usize = chunk_start * action_width;
            @memcpy(new_target_means[chunk_output_start..][0..chunk_floats], chunk_target_means);
            @memcpy(new_target_spreads[chunk_output_start..][0..chunk_floats], chunk_target_spreads);
        }

        /// The first windows of the batch planned again (this type's head, "reanalyze"), their new targets written into
        /// the batch's rows and back to the replay's.
        fn reanalyze(learner: *Self, pipe: *Pipe, replay: *Replay, rng: zn.Rng) !void {
            const reanalyzer: KitPlanner(M) = learner.reanalyzer orelse return;
            const config: Tdmpc.Config = learner.config;
            const row: Tdmpc.Row = learner.row;
            const row_width: usize = row.width();
            const observation_width: usize = row.observation_width;
            const action_width: usize = row.action_width;
            const reanalyzed_windows: usize = learner.reanalyzed_windows;
            // Two step-major layouts meet here: the batch's rows hold W windows per step (row = step x W + window),
            // the planned states only the first R (state = step x R + window).
            for (0..config.horizon) |step| {
                for (0..reanalyzed_windows) |window| {
                    const batch_row: usize = step * config.windows + window;
                    const state: usize = step * reanalyzed_windows + window;
                    const stored: []const f32 = learner.window_rows[batch_row * row_width ..][0..row_width];
                    const state_start: usize = state * observation_width;
                    const observations: []f32 = learner.reanalyze_observations;
                    const state_observation: []f32 = observations[state_start..][0..observation_width];
                    @memcpy(state_observation, stored[0..observation_width]);
                }
            }
            // One decision over every stored state, from scratch, evaluated - a chunk at a time, each chunk's states
            // drawing their noise by their own numbers, so the chunks decide as one decision would.
            const states: usize = config.horizon * reanalyzed_windows;
            const targets: []f32 = learner.reanalyze_targets;
            const spreads: []f32 = learner.reanalyze_spreads;
            var chunk_start: usize = 0;
            while (chunk_start < states) : (chunk_start += learner.reanalyze_chunk_states) {
                try learner.reanalyzeChunk(pipe, reanalyzer, rng, chunk_start, targets, spreads);
            }
            // Into the batch's rows, and laid out for the replay's write-back.
            const target_columns: usize = 2 * action_width;
            for (0..config.horizon) |step| {
                for (0..reanalyzed_windows) |window| {
                    const batch_row: usize = step * config.windows + window;
                    const state: usize = step * reanalyzed_windows + window;
                    const new_means: []const f32 = targets[state * action_width ..][0..action_width];
                    const new_spreads: []const f32 = spreads[state * action_width ..][0..action_width];
                    const target_rows: []f32 = learner.reanalyze_target_rows;
                    const target_row: []f32 = target_rows[state * target_columns ..][0..target_columns];
                    @memcpy(target_row[0..action_width], new_means);
                    @memcpy(target_row[action_width..], new_spreads);
                    const stored: []f32 = learner.window_rows[batch_row * row_width ..][0..row_width];
                    @memcpy(stored[row.targetMeanStart()..][0..target_columns], target_row);
                }
            }
            const reanalyzed_origins: []const Replay.WindowOrigin = learner.origins[0..reanalyzed_windows];
            const target_rows: []const f32 = learner.reanalyze_target_rows;
            try replay.writeBack(reanalyzed_origins, 0, config.horizon, row.targetMeanStart(), target_rows);
        }

        /// The sampled rows laid out as the CPU learner's `loadWindows` lays them out - block 0 the windows' first
        /// observations, block t + 1 what followed step t; each step's actions and rewards - and the planner's stored
        /// targets for the policy: the means as stored, the spreads as logarithms (every stored spread is at least
        /// the planner's floor, or exactly 1 for a step acted at random, so the logarithm is finite).
        fn layOutBatch(learner: *Self) void {
            const config: Tdmpc.Config = learner.config;
            const row: Tdmpc.Row = learner.row;
            const row_width: usize = row.width();
            const observation_width: usize = row.observation_width;
            const action_width: usize = row.action_width;
            // The sampled rows are step-major: row (step x windows + window) is the window's step `step`. Each row
            // holds a whole stored step - its observation, the action taken, the reward, the observation that
            // followed, the planner's target. The rollout wants the observations as H + 1 blocks instead: block 0
            // the windows' first observations, block t + 1 the observation after step t - so a step's "next"
            // observation is the following block's row, and the observations of steps 1 .. H - 1 are never read from
            // their own rows (they are the previous row's next observation, the same numbers).
            for (0..config.horizon) |step| {
                for (0..config.windows) |window| {
                    const stored_row_index: usize = step * config.windows + window;
                    const stored_step: []const f32 = learner.window_rows[stored_row_index * row_width ..][0..row_width];
                    if (step == 0) {
                        const first_observation: []const f32 = stored_step[0..observation_width];
                        const first_block_start: usize = window * observation_width;
                        const first_block_row: []f32 = learner.observations[first_block_start..][0..observation_width];
                        @memcpy(first_block_row, first_observation);
                    }
                    const next_block_row_index: usize = (step + 1) * config.windows + window;
                    const next_observation_start: usize = row.nextObservationStart();
                    const next_observation: []const f32 = stored_step[next_observation_start..][0..observation_width];
                    const next_block_row: []f32 =
                        learner.observations[next_block_row_index * observation_width ..][0..observation_width];
                    @memcpy(next_block_row, next_observation);
                    const action: []const f32 = stored_step[row.actionStart()..][0..action_width];
                    @memcpy(learner.actions[stored_row_index * action_width ..][0..action_width], action);
                    learner.rewards[stored_row_index] = stored_step[row.rewardColumn()];
                    // The policy's targets: the planner's Gaussian at this step, its spreads as logarithms - the policy
                    // head predicts log spreads. Every stored spread is at least the planner's floor, or exactly 1 for
                    // a step acted at random, so every logarithm is finite.
                    const stored_target_means: []const f32 = stored_step[row.targetMeanStart()..][0..action_width];
                    const stored_target_spreads: []const f32 = stored_step[row.targetSpreadStart()..][0..action_width];
                    const target_start: usize = stored_row_index * action_width;
                    @memcpy(learner.target_means[target_start..][0..action_width], stored_target_means);
                    const target_log_spreads: []f32 = learner.target_log_stds[target_start..][0..action_width];
                    for (target_log_spreads, stored_target_spreads) |*log_spread, spread| {
                        log_spread.* = @log(spread);
                    }
                }
            }
        }

        /// The value targets' noise, as the CPU learner's `LatentValueTargets` draws it: each stored row's own stream
        /// of `targets_rng`, indexed by the action's dimension.
        fn writeTargetNoise(learner: *Self, targets_rng: zn.Rng) void {
            const action_width: usize = learner.row.action_width;
            const stored_rows: usize = learner.config.horizon * learner.config.windows;
            for (0..stored_rows) |stored_row| {
                const row_rng: zn.Rng = targets_rng.split(@intCast(stored_row));
                for (0..action_width) |dimension| {
                    const noise: f32 = row_rng.normal(f32, @intCast(dimension));
                    learner.target_noise[stored_row * action_width + dimension] = noise;
                }
            }
        }

        /// The learner's own dropout generators: `dropout_rng` split by each value application's index.
        fn ownDropoutRngs(learner: *Self, dropout_rng: zn.Rng) []const zn.Rng {
            for (learner.dropout_rngs, 0..) |*application_rng, application_index| {
                application_rng.* = dropout_rng.split(@intCast(application_index));
            }
            return learner.dropout_rngs;
        }
    };
}

// ============================================================================================================
// THE TRAINER
// ============================================================================================================

/// Every network of an agent placed in `layout` in the world model's order - the encoder, every dynamics head, the
/// reward head, every value head, every target value head - then the policy (the order `KitWorldModel`'s clip and
/// `KitLearner` assume). Memory: the lists in `arena`.
pub fn placeAgentNetworks(
    comptime M: type,
    arena: Allocator,
    layout: *KitLayout,
    networks: bmpc.Bmpc(f32).Networks,
) !KitLearner(M).Networks {
    const Network = KitNetwork(M);
    const encoder: Network = try .init(arena, layout, networks.encoder);
    const dynamics: []Network = try arena.alloc(Network, networks.dynamics.len);
    for (dynamics, networks.dynamics) |*kit_head, head| {
        kit_head.* = try Network.init(arena, layout, head);
    }
    const reward: Network = try .init(arena, layout, networks.reward);
    const values: []Network = try arena.alloc(Network, networks.values.len);
    for (values, networks.values) |*kit_value, value_head| {
        kit_value.* = try Network.init(arena, layout, value_head);
    }
    const target_values: []Network = try arena.alloc(Network, networks.target_values.len);
    for (target_values, networks.target_values) |*kit_target, target_head| {
        kit_target.* = try Network.init(arena, layout, target_head);
    }
    const policy: Network = try .init(arena, layout, networks.policy);
    const placed: KitLearner(M).Networks = .{
        .encoder = encoder,
        .dynamics = dynamics,
        .reward = reward,
        .values = values,
        .target_values = target_values,
        .policy = policy,
    };
    return placed;
}

/// Every network's numbers written into `params`, the layout's parameter block, where `placeAgentNetworks` placed it.
pub fn writeAgentParams(
    comptime M: type,
    placed: KitLearner(M).Networks,
    networks: bmpc.Bmpc(f32).Networks,
    params: []f32,
) void {
    placed.encoder.writeParams(networks.encoder, params);
    for (placed.dynamics, networks.dynamics) |kit_head, head| {
        kit_head.writeParams(head, params);
    }
    placed.reward.writeParams(networks.reward, params);
    for (placed.values, networks.values) |kit_value, value_head| {
        kit_value.writeParams(value_head, params);
    }
    for (placed.target_values, networks.target_values) |kit_target, target_head| {
        kit_target.writeParams(target_head, params);
    }
    placed.policy.writeParams(networks.policy, params);
}

/// EFFICIENTTDMPC TRAINED ON THE KIT - the CPU agent's `Trainer`, frame for frame: the kit's planner acts for every
/// environment, the host steps the environments and stores every step in the replay with the planner's target, and
/// the kit's learner makes the schedule's updates.
///
/// ---- ONE FRAME ----
///
///     act        the kit's planner for every environment, exploring (`KitPlanner`) - or uniform random actions while
///                the schedule seeds the replay
///     step       every environment, on the host; the rows stored with the planner's targets (`Row.fill`)
///     advance    each environment's next observation, or a fresh episode where one ended
///     learn      the schedule's updates (`KitLearner.update`) - once the replay holds a whole window
///
/// The random streams are the CPU trainer's (acting 1, reset 2, update 3, each split by frame, environment or
/// update), so the two draw from the same generators; what they draw differs only where the kit's learner draws its
/// own dropout masks. Acting reads the planner's actions back every frame: on the CPU twin at once, on a device once
/// the readback reflects the frame's dispatches.
///
/// Like `KitLearner`, a trainer keeps state that changes - counters, the environments, the replay - so it is used
/// through a pointer.
pub fn KitTrainer(comptime M: type, comptime Environment: type) type {
    return struct {
        const Self = @This();
        const Tdmpc = bmpc.Bmpc(f32);
        const Network = KitNetwork(M);
        pub const Pipe = Network.Pipe;
        const Replay = zrl.SequenceReplay(f32);
        /// The random streams, the CPU trainer's own numbers.
        const acting_stream: u32 = 1;
        const reset_stream: u32 = 2;
        const update_stream: u32 = 3;

        environments: []Environment,
        schedule: Tdmpc.Schedule,
        episode_length: usize,
        config: Tdmpc.Config,
        row: Tdmpc.Row,
        layout: KitLayout,
        placed: KitLearner(M).Networks,
        learner: KitLearner(M),
        actor: KitPlanner(M),
        replay: Replay,
        rng: zn.Rng,
        /// The starting contents of the kit's buffers, uploaded once (`uploadStart`).
        params: []f32,
        zero_moments: []f32,
        /// Every environment's current observation and the one its step led to, whether its episode has just begun,
        /// its steps so far, whether its episode just ended, and how many episodes it has begun.
        observations: []f32,
        next_observations: []f32,
        first_steps: []bool,
        episode_steps: []usize,
        episode_ended: []bool,
        episodes: []u32,
        /// The frame's actions and the planner's targets, [environments][action] each.
        actions: []f32,
        target_means: []f32,
        target_spreads: []f32,
        /// The frame's rows for the replay, and which environments are active (all).
        rows: []f32,
        active: []bool,
        frame: usize,
        update_index: u32,

        /// A trainer over `environments`, with `networks` its starting weights - placed on a kit layout of its own
        /// (the learner's pieces and the actor's planner over the same networks), the replay and every host buffer
        /// in `arena`, and every environment's first episode begun. The discount comes from the episode's length,
        /// as the CPU trainer sets it.
        pub fn init(
            arena: Allocator,
            environments: []Environment,
            networks: Tdmpc.Networks,
            observation_width: u32,
            action_width: u32,
            config: Tdmpc.Config,
            schedule: Tdmpc.Schedule,
            episode_length: usize,
            replay_capacity: usize,
            rng: zn.Rng,
            learner_options: KitLearner(M).Options,
        ) !Self {
            var learning: Tdmpc.Config = config;
            learning.discount = Tdmpc.discountFor(episode_length);
            const environment_count: usize = environments.len;
            var layout: KitLayout = .{};
            const placed: KitLearner(M).Networks = try placeAgentNetworks(M, arena, &layout, networks);
            var learner: KitLearner(M) = try .init(
                arena,
                &layout,
                placed,
                observation_width,
                action_width,
                learning,
                learner_options,
            );
            const actor: KitPlanner(M) = try actingPlanner(
                arena,
                &layout,
                placed,
                observation_width,
                action_width,
                learning,
                @intCast(environment_count),
            );
            layout.requireFitsKit(M);
            const params: []f32 = try arena.alloc(f32, layout.params_floats);
            writeAgentParams(M, placed, networks, params);
            const zero_moments: []f32 = try arena.alloc(f32, layout.params_floats);
            @memset(zero_moments, 0);
            const host_acts: []f32 = try learner.allocateHostActs(arena, layout.acts_floats);
            actor.scorer.writeWeights(host_acts);
            const row: Tdmpc.Row = .{ .observation_width = observation_width, .action_width = action_width };
            const replay: Replay = try .init(arena, environment_count, replay_capacity, row.width(), row.doneColumn());
            const decided: usize = environment_count * action_width;
            var trainer: Self = .{
                .environments = environments,
                .schedule = schedule,
                .episode_length = episode_length,
                .config = learning,
                .row = row,
                .layout = layout,
                .placed = placed,
                .learner = learner,
                .actor = actor,
                .replay = replay,
                .rng = rng,
                .params = params,
                .zero_moments = zero_moments,
                .observations = try arena.alloc(f32, environment_count * observation_width),
                .next_observations = try arena.alloc(f32, environment_count * observation_width),
                .first_steps = try arena.alloc(bool, environment_count),
                .episode_steps = try arena.alloc(usize, environment_count),
                .episode_ended = try arena.alloc(bool, environment_count),
                .episodes = try arena.alloc(u32, environment_count),
                .actions = try arena.alloc(f32, decided),
                .target_means = try arena.alloc(f32, decided),
                .target_spreads = try arena.alloc(f32, decided),
                .rows = try arena.alloc(f32, environment_count * row.width()),
                .active = try arena.alloc(bool, environment_count),
                .frame = 0,
                .update_index = 0,
            };
            @memset(trainer.active, true);
            @memset(trainer.episodes, 0);
            @memset(trainer.episode_ended, false);
            for (trainer.environments, 0..) |*environment, index| {
                trainer.beginEpisode(environment, index);
            }
            return trainer;
        }

        /// The acting planner: a scorer, the policy's plans and MPPI over `states` environments, with the acting
        /// planner's settings and the policy's acting spread - on the trainer's own networks.
        fn actingPlanner(
            arena: Allocator,
            layout: *KitLayout,
            placed: KitLearner(M).Networks,
            observation_width: u32,
            action_width: u32,
            config: Tdmpc.Config,
            states: u32,
        ) !KitPlanner(M) {
            const planner_config: Tdmpc.PlannerConfig = config.acting;
            const scorer: KitPlanScorer(M) = try .init(
                arena,
                layout,
                placed.encoder,
                placed.dynamics,
                placed.reward,
                placed.values,
                observation_width,
                action_width,
                .{
                    .horizon = @intCast(planner_config.horizon),
                    .states = states,
                    .candidates = @intCast(planner_config.candidates),
                    .discount = config.discount,
                    .objective = planner_config.objective,
                    .pessimism = planner_config.pessimism,
                },
            );
            const plans_options: KitPolicyPlans(M).Options = .{
                .plans = @intCast(planner_config.policy_candidates),
                .log_std_low = config.spread.log_std_low,
                .log_std_high = config.spread.log_std_high,
            };
            const policy_plans: KitPolicyPlans(M) = try .init(
                arena,
                layout,
                scorer,
                placed.policy,
                placed.dynamics[0],
                plans_options,
            );
            const mppi: KitMppi(M) = .init(layout, scorer.searchShape(), .{
                .policy_candidates = @intCast(planner_config.policy_candidates),
                .elites = @intCast(planner_config.elites),
                .temperature = config.temperature,
                .min_spread = config.min_spread,
                .max_spread = config.max_spread,
                .rounds = @intCast(planner_config.iterationsFor(action_width)),
            });
            const planner: KitPlanner(M) = .{ .scorer = scorer, .policy_plans = policy_plans, .mppi = mppi };
            return planner;
        }

        /// Every buffer's starting contents uploaded: the networks' numbers, Adam's zero moments, the host's copy of
        /// acts (every window counting, the running scale at 1, the planners' objective weights).
        pub fn uploadStart(trainer: *const Self, pipe: *Pipe) void {
            pipe.element_count = trainer.layout.largestBuffer();
            pipe.upload(.params, trainer.params);
            pipe.upload(.adam_m, trainer.zero_moments);
            pipe.upload(.adam_v, trainer.zero_moments);
            pipe.upload(.acts, trainer.learner.host_acts);
        }

        /// A fresh episode for environment `index`: its reset drawn from its own stream, split by its episode count.
        fn beginEpisode(trainer: *Self, environment: *Environment, index: usize) void {
            const observation_width: usize = trainer.row.observation_width;
            const environment_rng: zn.Rng = trainer.rng.split(reset_stream).split(@intCast(index));
            const reset_rng: zn.Rng = environment_rng.split(trainer.episodes[index]);
            environment.reset(reset_rng, trainer.observations[index * observation_width ..][0..observation_width]);
            trainer.episodes[index] += 1;
            trainer.episode_steps[index] = 0;
            trainer.first_steps[index] = true;
        }

        /// One decision of the acting planner for `observations`, one row per environment - exploring or evaluating
        /// - its actions and targets read back into `actions`, `target_means` and `target_spreads`.
        pub fn decide(
            trainer: *Self,
            pipe: *Pipe,
            observations: []const f32,
            first_steps: []const bool,
            mode: KitPlanner(M).Mode,
            rng: zn.Rng,
        ) !void {
            const actor: KitPlanner(M) = trainer.actor;
            const host_acts: []f32 = trainer.learner.host_acts;
            actor.writeDecisionInputs(host_acts, observations, first_steps, rng, 0);
            actor.uploadDecisionInputs(pipe, host_acts);
            actor.decide(pipe, mode);
            const device_acts: []const f32 = try readCurrentActs(M, pipe, "acting");
            const decided: usize = trainer.actions.len;
            const mppi: KitMppi(M) = actor.mppi;
            @memcpy(trainer.actions, device_acts[mppi.actions_offset..][0..decided]);
            @memcpy(trainer.target_means, device_acts[mppi.targets_offset..][0..decided]);
            @memcpy(trainer.target_spreads, device_acts[mppi.targets_offset + decided ..][0..decided]);
        }

        /// One frame (this type's head) - act, step every environment, store the rows, advance, then the schedule's
        /// updates. Returns what the schedule asked of the frame.
        pub fn runFrame(trainer: *Self, pipe: *Pipe) !Tdmpc.Schedule.Frame {
            const frame_plan: Tdmpc.Schedule.Frame = trainer.schedule.at(trainer.frame);
            // This frame's acting generator: the acting stream, split by the frame - the CPU trainer's own, so both
            // trainers act from the same numbers.
            const frame_rng: zn.Rng = trainer.rng.split(acting_stream).split(@intCast(trainer.frame));
            // ACT: the planner for every environment, exploring - or, while the schedule seeds the replay, uniform
            // random actions, which store no planner target (the policy then learns toward the empty target there).
            if (frame_plan.planned) {
                try trainer.decide(pipe, trainer.observations, trainer.first_steps, .explore, frame_rng);
            } else {
                for (trainer.actions, 0..) |*action, action_index| {
                    action.* = frame_rng.uniform(f32, @intCast(action_index), -1, 1);
                }
            }
            // STEP every environment, and STORE what happened as a replay row.
            const observation_width: usize = trainer.row.observation_width;
            const action_width: usize = trainer.row.action_width;
            const row_width: usize = trainer.row.width();
            for (trainer.environments, 0..) |*environment, environment_index| {
                const observation_start: usize = environment_index * observation_width;
                const observation: []const f32 = trainer.observations[observation_start..][0..observation_width];
                const next_observation: []f32 = trainer.next_observations[observation_start..][0..observation_width];
                const action: []const f32 = trainer.actions[environment_index * action_width ..][0..action_width];
                const outcome: Tdmpc.StepOutcome = environment.step(action, next_observation);
                // The agent's value targets are model-based and never read a terminal flag, so an environment that
                // terminates episodes cannot be learned correctly by it - refused rather than learned wrong.
                if (outcome.ending == .terminated) {
                    return error.TerminationNotModelled;
                }
                trainer.episode_steps[environment_index] += 1;
                // How the episode ended here, if it did: the environment's word first, then the loop's length. A
                // truncation is an episode cut short, not a state with no future, so the row is stored as truncated.
                const reached_episode_length: bool = trainer.episode_steps[environment_index] == trainer.episode_length;
                const is_truncated: bool = outcome.ending == .truncated or reached_episode_length;
                trainer.episode_ended[environment_index] = is_truncated;
                const target_start: usize = environment_index * action_width;
                const planner_target: ?Tdmpc.Target = if (frame_plan.planned) .{
                    .means = trainer.target_means[target_start..][0..action_width],
                    .spreads = trainer.target_spreads[target_start..][0..action_width],
                } else null;
                const environment_row: []f32 = trainer.rows[environment_index * row_width ..][0..row_width];
                try trainer.row.fill(environment_row, .{
                    .observation = observation,
                    .action = action,
                    .reward = outcome.reward,
                    .next_observation = next_observation,
                    .terminated = false,
                    .truncated = is_truncated,
                    .target = planner_target,
                });
            }
            try trainer.replay.push(trainer.rows, trainer.active);
            // ADVANCE: each environment's next observation becomes its observation, or a fresh episode begins.
            for (trainer.environments, 0..) |*environment, environment_index| {
                if (trainer.episode_ended[environment_index]) {
                    trainer.beginEpisode(environment, environment_index);
                } else {
                    const observation_start: usize = environment_index * observation_width;
                    const next_observation: []const f32 =
                        trainer.next_observations[observation_start..][0..observation_width];
                    @memcpy(trainer.observations[observation_start..][0..observation_width], next_observation);
                    trainer.first_steps[environment_index] = false;
                }
            }
            // LEARN: the schedule's updates, once the replay holds a whole window to sample. Each update draws from the
            // update stream split by its own index, as the CPU trainer's.
            const replay_has_a_window: bool = trainer.replay.holdsWindow(trainer.config.horizon);
            const updates_this_frame: usize = if (replay_has_a_window) frame_plan.updates else 0;
            for (0..updates_this_frame) |_| {
                const update_rng: zn.Rng = trainer.rng.split(update_stream).split(trainer.update_index);
                const pretraining: bool = frame_plan.pretraining;
                try trainer.learner.update(pipe, &trainer.replay, update_rng, trainer.update_index, pretraining, null);
                trainer.update_index += 1;
            }
            trainer.frame += 1;
            return frame_plan;
        }
    };
}
