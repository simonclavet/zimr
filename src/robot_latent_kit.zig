//! robot_latent_kit - the latent world model on the kit: the GPU, or its CPU twin.
//!
//! `robot_latent` is the CPU reference: zimrnum's autodiff, clear and slow. This is the same model
//! laid out for the kit's kernels, so it can run - and, next, train - where the phone has compute
//! to spare. The plan's T9a design, in code:
//!
//!   * **One wide row per step.** Block `X_k` holds `rows` rows of `[z | reference | action]`,
//!     `width` floats apart. The dense layers read their input with a stride, so the first layer
//!     sees the three as one input and the concatenation is only this layout.
//!   * **The first layer, stacked.** The CPU model's first layer is three weight blocks summed
//!     (`W_z`, `W_r`, `W_a`); stacked in that order they ARE one layer over the wide row - and the
//!     kit adds its inputs in the same order the CPU model does, bias first.
//!   * **Steps joined by `lat_advance`**, which writes z + change into the next block's z columns
//!     and into a contiguous copy `Z_{k+1}` for the loss kernels.
//!
//! It holds the whole training step - `forward`, `backward` (weight gradients accumulated across the
//! rollout's steps; the loss SUMMED over steps), `adamStep` (epsilon scaled so the sum takes the CPU
//! model's exact step) and `trainStep`, all three - each checked against the CPU reference: the
//! rollout bitwise, every gradient to rounding, Adam to half an ulp.
//!
//! What it does NOT have yet is its data. Today the caller stages every window's inputs and targets
//! from the host - fine for tests, wrong for a phone: on one wasm core, computing features for every
//! record of every sampled window, every training step, is the most expensive thing training would
//! do, on the wrong processor. The plan's T9b replaces it: the replay of features lives on the GPU,
//! appended once per simulation step; the reference's goals are a table uploaded once per clip; and a
//! gather kernel builds each window on the GPU, normalising as it goes.

const std = @import("std");
const zn = @import("zn");
const compute_host = @import("compute_host.zig");
const latent = @import("robot_latent.zig");

const rbt = @import("robot.zig");
const track = @import("robot_track.zig");

const Allocator = std.mem.Allocator;
const zm = @import("zm");
const float = zm.float;
const assertf = zm.assertf;
const Tensor = zn.Tensor(f32);

pub fn LatentKit(comptime M: type) type {
    return struct {
        const Self = @This();

        pipe: *compute_host.Compute(M),
        features: u32,
        references: u32,
        actions: u32,
        hidden: u32,
        rows: u32,
        steps: u32,
        /// Columns in front of the state in every wide row - the policy's goal, when the policy
        /// trains through this rollout (0 when only the world model trains). The rows then read
        /// `[goal | z | reference | action]`: the policy's input is the first `lead + features`
        /// columns, the world model's the rest - both contiguous slices of the same row.
        lead: u32,
        /// The world model's input width: features + references + actions.
        inputs: u32,
        /// Floats per wide row - its STRIDE: `lead + inputs`. Not the same as `inputs` once there is a
        /// lead, and the two must never be mixed up: the layers read their slice of a row with this
        /// stride, but the input-gradient block they write back (`dx_at`) is `inputs` wide.
        width: u32,
        // Where things live in the kit's activation buffer, in floats.
        /// `steps + 1` wide blocks.
        x_at: u32,
        /// Per step: the two hidden layers and the predicted change.
        h1_at: u32,
        h2_at: u32,
        change_at: u32,
        /// `steps` contiguous states, Z_1 .. Z_steps.
        z_at: u32,
        /// `steps` targets, T_1 .. T_steps: where the simulator actually went.
        t_at: u32,
        /// `steps` goals, G_1 .. G_steps, when there is a lead: where the reference is - the policy's
        /// tracking target. Empty without a lead.
        g_at: u32,
        // In the gradient buffer: every state's gradient dZ_1 .. dZ_steps, then one slot each for
        // the two hidden layers' and the wide block's gradients, reused step after step.
        dz_at: u32,
        dh1_at: u32,
        dh2_at: u32,
        dx_at: u32,
        /// Floats of gradient buffer the backward pass uses.
        dtotal: u32,
        /// THE POLICY, when one acts in the rollout (`policy_hidden` > 0; it needs the goal lead). Its
        /// weights follow the world model's in the parameter buffer (from `p_at`, `policy_count`
        /// floats); its layers' blocks follow the rollout's (`ph1_at`, `ph2_at`, `raw_at`, a block per
        /// step each). Its actions are written into the rows scaled by `action_scale`.
        policy_hidden: u32,
        p_at: u32,
        policy_count: u32,
        ph1_at: u32,
        ph2_at: u32,
        raw_at: u32,
        action_scale: f32 = 1.0,
        /// The price on the size of the raw action, beside the tracking loss (the CPU learner's).
        w_action: f32 = 0.0,
        /// The smoothness price (CAPS): `w_smooth * |a_k - a_(k-1)|^2` along the window - see `lat_act_bwd`.
        w_smooth: f32 = 0.0,
        // The policy's gradient slots, one each, reused step after step: the raw action, its two
        // hidden layers, and its input [goal | state] (`lead + features` wide).
        draw_at: u32,
        dph1_at: u32,
        dph2_at: u32,
        dp_at: u32,
        /// Exploration noise on the policy's actions, in units of its raw output (0: none), and the
        /// seed this rollout's noise comes from - one per training step, mixed per step by the kit.
        sigma: f32 = 0.0,
        seed: u32 = 0,
        /// Floats of activation buffer the rollout uses.
        total: u32,
        // Where each layer's weights (then its bias) live in the parameter buffer.
        w1: u32,
        w2: u32,
        w3: u32,
        param_count: u32,

        /// Lay the rollout out in the kit's buffers - or refuse, by name, if it does not fit. Each
        /// kit buffer has its own size (the activation buffer is the large one), and on a GPU a
        /// layout past a buffer's end is not an error anywhere: the dispatches write past it
        /// SILENTLY. So every region is checked against the buffer it lives in.
        pub fn init(
            pipe: *compute_host.Compute(M),
            features: u32,
            references: u32,
            actions: u32,
            hidden: u32,
            rows: u32,
            steps: u32,
            lead: u32,
            policy_hidden: u32,
        ) error{ KitTooSmall, PolicyWithoutGoals }!Self {
            // A policy acts on [goal | state], so it needs the goal columns in front.
            if (policy_hidden > 0 and lead != features) {
                return error.PolicyWithoutGoals;
            }
            const inputs: u32 = features + references + actions;
            const width: u32 = lead + inputs;
            const x_at: u32 = 0;
            const h1_at: u32 = x_at + (steps + 1) * rows * width;
            const h2_at: u32 = h1_at + steps * rows * hidden;
            const change_at: u32 = h2_at + steps * rows * hidden;
            const z_at: u32 = change_at + steps * rows * features;
            const t_at: u32 = z_at + steps * rows * features;
            const dh1_at: u32 = steps * rows * features;
            const dh2_at: u32 = dh1_at + rows * hidden;
            const dx_at: u32 = dh2_at + rows * hidden;
            // (The input-gradient block is `inputs` wide - see `width`.)
            // The policy's blocks come after the targets and the goals.
            const policy_blocks: u32 = t_at + steps * rows * features + (if (lead > 0) steps * rows * features else 0);
            const w1: u32 = 0;
            const w2: u32 = w1 + inputs * hidden + hidden;
            const w3: u32 = w2 + hidden * hidden + hidden;
            const layout: Self = .{
                .pipe = pipe,
                .features = features,
                .references = references,
                .actions = actions,
                .hidden = hidden,
                .rows = rows,
                .steps = steps,
                .lead = lead,
                .inputs = inputs,
                .width = width,
                .x_at = x_at,
                .h1_at = h1_at,
                .h2_at = h2_at,
                .change_at = change_at,
                .z_at = z_at,
                .t_at = t_at,
                .g_at = t_at + steps * rows * features,
                .policy_hidden = policy_hidden,
                .p_at = w3 + hidden * features + features,
                .policy_count = if (policy_hidden == 0)
                    0
                else
                    (lead + features) * policy_hidden + policy_hidden + policy_hidden * policy_hidden +
                        policy_hidden + policy_hidden * actions + actions,
                .ph1_at = policy_blocks,
                .ph2_at = policy_blocks + steps * rows * policy_hidden,
                .raw_at = policy_blocks + 2 * steps * rows * policy_hidden,
                .total = policy_blocks + steps * rows * (2 * policy_hidden + (if (policy_hidden > 0) actions else 0)),
                .dz_at = 0,
                .dh1_at = dh1_at,
                .dh2_at = dh2_at,
                .dx_at = dx_at,
                .draw_at = dx_at + rows * inputs,
                .dph1_at = dx_at + rows * inputs + rows * actions,
                .dph2_at = dx_at + rows * inputs + rows * actions + rows * policy_hidden,
                .dp_at = dx_at + rows * inputs + rows * actions + 2 * rows * policy_hidden,
                .dtotal = dx_at + rows * inputs +
                    (if (policy_hidden > 0) rows * (actions + 2 * policy_hidden + lead + features) else 0),
                .w1 = w1,
                .w2 = w2,
                .w3 = w3,
                .param_count = w3 + hidden * features + features,
            };
            const fits: bool = layout.total <= floatsIn(M, "acts") and
                layout.dtotal <= floatsIn(M, "dacts") and
                layout.param_count + layout.policy_count <= floatsIn(M, "params");
            if (!fits) {
                return error.KitTooSmall;
            }
            return layout;
        }

        /// Where step k's wide block starts (k = 0 .. steps).
        pub fn blockX(self: Self, k: u32) u32 {
            return self.x_at + k * self.rows * self.width;
        }

        /// Where the contiguous state after step k starts (k = 1 .. steps).
        pub fn blockZ(self: Self, k: u32) u32 {
            return self.z_at + (k - 1) * self.rows * self.features;
        }

        /// Where step k's target starts (k = 1 .. steps), and its state's gradient.
        pub fn blockT(self: Self, k: u32) u32 {
            return self.t_at + (k - 1) * self.rows * self.features;
        }

        /// Where step k's goal starts (k = 1 .. steps), when there is a lead.
        pub fn blockG(self: Self, k: u32) u32 {
            return self.g_at + (k - 1) * self.rows * self.features;
        }

        fn blockDZ(self: Self, k: u32) u32 {
            return self.dz_at + (k - 1) * self.rows * self.features;
        }

        /// The rollout, backward: the gradient of the rollout's loss with respect to every weight,
        /// into the kit's gradient buffer (in `packWeights`' layout). `forward` must have run, and
        /// the targets be staged at `blockT`.
        ///
        /// THE LOSS IS THE SUM over steps of each step's mean squared error - `steps` times the CPU
        /// model's, which averages over steps. The kit has no kernel to divide by a constant, and
        /// needs none: Adam divides every gradient by its own running size, so a constant factor
        /// cancels (bar the epsilon). Stated here so nobody mistakes the factor for a bug.
        ///
        /// Walking back from the last step: a step's change has exactly the next state's gradient
        /// (z' = z + change), so layer 3 reads dZ_{k+1} directly. Through the three layers, weight
        /// gradients ACCUMULATED across steps; then a state's own gradient is its loss term, plus
        /// the next state's (the residual path, `add_block`), plus what came back through the
        /// network into its block's z columns (`lat_take`).
        pub fn backward(self: Self) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            var step: u32 = self.steps;
            self.mse(step);
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                const accumulate: u32 = if (first) 0 else 1;
                first = false;
                // Layer 3: into the change, whose gradient is the next state's.
                self.weightGrads(h2, 0, self.hidden, self.features, self.blockDZ(k + 1), self.w3, accumulate);
                self.inputGrads(self.hidden, self.features, self.blockDZ(k + 1), self.w3, self.dh2_at);
                self.activationGrads(h2, self.dh2_at, tanh, self.hidden);
                // Layer 2.
                self.weightGrads(h1, 0, self.hidden, self.hidden, self.dh2_at, self.w2, accumulate);
                self.inputGrads(self.hidden, self.hidden, self.dh2_at, self.w2, self.dh1_at);
                self.activationGrads(h1, self.dh1_at, tanh, self.hidden);
                // Layer 1, over the wide block.
                self.weightGrads(
                    self.blockX(k) + self.lead,
                    self.width,
                    self.inputs,
                    self.hidden,
                    self.dh1_at,
                    self.w1,
                    accumulate,
                );
                if (k == 0) {
                    break;
                }
                self.inputGrads(self.inputs, self.hidden, self.dh1_at, self.w1, self.dx_at);
                // State k's gradient: its own loss term, the residual path, and the network path.
                self.mse(k);
                self.pipe.params = .{
                    .count = self.rows * self.features,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.blockDZ(k + 1),
                };
                self.pipe.run("add_block", self.rows * self.features);
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.features,
                    // The input-gradient block's rows are `inputs` apart, not `width`.
                    .stride = self.inputs,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.dx_at,
                };
                self.pipe.run("lat_take", self.rows * self.features);
            }
        }

        /// Adam's hyperparameters: zimrnum's defaults, which the CPU model trains with.
        pub const beta1: f32 = 0.9;
        pub const beta2: f32 = 0.999;
        pub const epsilon: f32 = 1.0e-8;

        /// One Adam step over every weight, from the gradient buffer. `t` counts steps from 1, for
        /// the bias corrections (computed here, in f32, the way zimrnum does). `epsilon_scale` is
        /// the constant this gradient carries relative to the CPU model's: Adam cancels a constant
        /// factor in the gradient EXACTLY when epsilon carries the same factor - 8m / (8 sqrt(v) + 8e)
        /// is m / (sqrt(v) + e) - so a kit step on `backward`'s summed loss, with `steps` here, is
        /// the CPU model's step on its averaged one.
        pub fn adamStep(self: Self, rate: f32, t: u32, epsilon_scale: f32) void {
            self.adamOver(self.w1, self.param_count, rate, t, epsilon_scale);
        }

        /// The same step for the POLICY's weights only - its own region of the parameter buffer, from
        /// `p_at`. The kit's `adam` offsets all four of its buffers (weights, gradients, both moments)
        /// by the same `w_off`, so the world model's weights and optimiser state are never touched.
        pub fn adamPolicy(self: Self, rate: f32, t: u32, epsilon_scale: f32) void {
            self.adamOver(self.p_at, self.policy_count, rate, t, epsilon_scale);
        }

        /// One Adam step over `count` weights from `offset`, `t` counting from 1.
        fn adamOver(self: Self, offset: u32, count: u32, rate: f32, t: u32, epsilon_scale: f32) void {
            var power1: f32 = 1.0;
            var power2: f32 = 1.0;
            for (0..t) |_| {
                power1 *= beta1;
                power2 *= beta2;
            }
            self.pipe.params = .{
                .count = count,
                .w_off = offset,
                .rate = rate,
                .beta1 = beta1,
                .beta2 = beta2,
                .epsilon = epsilon * epsilon_scale,
                .correction1 = 1.0 / (1.0 - power1),
                .correction2 = 1.0 / (1.0 - power2),
            };
            self.pipe.run("adam", count);
        }

        /// One training step of the POLICY on the kit, its windows staged (goals, references, the
        /// first state): the rollout with the policy acting, backward through the fixed world model,
        /// and Adam on the policy's weights - epsilon carrying the steps, as for the world model.
        pub fn policyTrainStep(self: Self, rate: f32, t: u32) void {
            self.forward();
            self.policyBackward();
            self.adamPolicy(rate, t, @floatFromInt(self.steps));
        }

        /// The rollout's loss into the kit's loss buffer (`loss[0]`), for the page to show. The
        /// predictions `Z_1 .. Z_steps` are contiguous and so are their targets, so ONE mean over
        /// the lot is the mean over steps of each step's mean - exactly the CPU model's loss, with
        /// no kernel of its own. Call it after `forward`.
        ///
        /// Two things to know. `mse_value` is ONE thread summing every number - fine for a value the
        /// page shows (tens of thousands of floats), wrong for anything on the training's hot path.
        /// And on a GPU the value arrives by readback, a frame or so later; only the CPU twin (the
        /// tests) can read it straight after the dispatch.
        pub fn loss(self: Self) void {
            self.pipe.params = .{
                .rows = self.steps * self.rows,
                .out_dim = self.features,
                .y_off = self.z_at,
                .t_off = self.t_at,
            };
            self.pipe.run("mse_value", 1);
        }

        /// One training step of the latent model on the kit, inputs and targets staged: the
        /// rollout forward, backward through it, and Adam - `t` counting from 1.
        pub fn trainStep(self: Self, rate: f32, t: u32) void {
            // The RECORDED actions: see `forwardRecorded`.
            self.forwardRecorded();
            self.backward();
            self.adamStep(rate, t, @floatFromInt(self.steps));
        }

        /// The rollout, backward, for the POLICY: the gradient of its loss - every step's mean squared
        /// distance from the reference's GOAL, plus the price on the raw action's size - with respect
        /// to the policy's weights, into the gradient buffer at `p_at`, through the world model held
        /// FIXED (its layers pass input gradients only; its weights get none). Summed over steps, like
        /// `backward`: `steps` times the CPU learner's mean. `forward` must have run with the policy.
        ///
        /// A state's gradient now gathers from FOUR places: its own tracking term; the next state's
        /// (the residual); the world model's input gradient in its state columns; and the POLICY's -
        /// the policy reads the state too - which sits at offset `lead` of the policy's input block,
        /// a block `lead + features` wide (a third width, beside `width` and `inputs`).
        pub fn policyBackward(self: Self) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const hp: u32 = self.policy_hidden;
            const policy_inputs: u32 = self.lead + self.features;
            const w2p: u32 = self.p_at + policy_inputs * hp + hp;
            const w3p: u32 = w2p + hp * hp + hp;
            var step: u32 = self.steps;
            self.trackingGrad(step);
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                // The world model, frozen: input gradients only, down to its wide-row slice.
                self.inputGrads(self.hidden, self.features, self.blockDZ(k + 1), self.w3, self.dh2_at);
                self.activationGrads(h2, self.dh2_at, tanh, self.hidden);
                self.inputGrads(self.hidden, self.hidden, self.dh2_at, self.w2, self.dh1_at);
                self.activationGrads(h1, self.dh1_at, tanh, self.hidden);
                self.inputGrads(self.inputs, self.hidden, self.dh1_at, self.w1, self.dx_at);
                // The action columns' gradient, back to the policy's raw output - plus the price.
                const raw: u32 = self.raw_at + k * self.rows * self.actions;
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.actions,
                    .stride = self.inputs,
                    .dx_off = self.dx_at + self.features + self.references,
                    .x_off = raw,
                    .dy_off = self.draw_at,
                    .lat_scale = self.action_scale,
                    .lat_penalty = 2.0 * self.w_action / float(self.rows * self.actions),
                    .lat_smooth = 2.0 * self.w_smooth / float(self.rows * self.actions),
                    // A missing neighbour is this step itself: raw - raw, exactly zero.
                    .lat_prev = if (k > 0) raw - self.rows * self.actions else raw,
                    .lat_next = if (k + 1 < self.steps) raw + self.rows * self.actions else raw,
                };
                self.pipe.run("lat_act_bwd", self.rows * self.actions);
                // The policy: weight gradients accumulated across the steps, input gradients down.
                const accumulate: u32 = if (first) 0 else 1;
                first = false;
                const ph1: u32 = self.ph1_at + k * self.rows * hp;
                const ph2: u32 = self.ph2_at + k * self.rows * hp;
                self.weightGrads(ph2, 0, hp, self.actions, self.draw_at, w3p, accumulate);
                self.inputGrads(hp, self.actions, self.draw_at, w3p, self.dph2_at);
                self.activationGrads(ph2, self.dph2_at, tanh, hp);
                self.weightGrads(ph1, 0, hp, hp, self.dph2_at, w2p, accumulate);
                self.inputGrads(hp, hp, self.dph2_at, w2p, self.dph1_at);
                self.activationGrads(ph1, self.dph1_at, tanh, hp);
                self.weightGrads(self.blockX(k), self.width, policy_inputs, hp, self.dph1_at, self.p_at, accumulate);
                if (k == 0) {
                    break;
                }
                self.inputGrads(policy_inputs, hp, self.dph1_at, self.p_at, self.dp_at);
                // State k's gradient, from all four places.
                self.trackingGrad(k);
                self.pipe.params = .{
                    .count = self.rows * self.features,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.blockDZ(k + 1),
                };
                self.pipe.run("add_block", self.rows * self.features);
                self.take(self.dx_at, self.inputs, k);
                self.take(self.dp_at + self.lead, policy_inputs, k);
            }
        }

        /// dZ_k = 2 (Z_k - G_k) / (rows x features): step k's TRACKING term - distance from the goal.
        fn trackingGrad(self: Self, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = self.features,
                .y_off = self.blockZ(k),
                .t_off = self.blockG(k),
                .dy_off = self.blockDZ(k),
            };
            self.pipe.run("mse_bwd", self.rows * self.features);
        }

        /// The state columns of an input-gradient block (starting at `from`, rows `stride` apart)
        /// added into state k's gradient.
        fn take(self: Self, from: u32, stride: u32, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.features,
                .stride = stride,
                .dy_off = self.blockDZ(k),
                .dx_off = from,
            };
            self.pipe.run("lat_take", self.rows * self.features);
        }

        /// dZ_k = 2 (Z_k - T_k) / (rows x features): one step's loss term, written fresh.
        fn mse(self: Self, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = self.features,
                .y_off = self.blockZ(k),
                .t_off = self.blockT(k),
                .dy_off = self.blockDZ(k),
            };
            self.pipe.run("mse_bwd", self.rows * self.features);
        }

        fn weightGrads(
            self: Self,
            x: u32,
            stride: u32,
            in_dim: u32,
            out_dim: u32,
            dy: u32,
            w: u32,
            accumulate: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .x_off = x,
                .stride = stride,
                .dy_off = dy,
                .w_off = w,
                .accumulate = accumulate,
            };
            self.pipe.run("dense_bwd_w", in_dim * out_dim + out_dim);
        }

        fn inputGrads(
            self: Self,
            in_dim: u32,
            out_dim: u32,
            dy: u32,
            w: u32,
            dx: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .dy_off = dy,
                .w_off = w,
                .dx_off = dx,
            };
            self.pipe.run("dense_bwd_x", self.rows * in_dim);
        }

        fn activationGrads(
            self: Self,
            y: u32,
            dy: u32,
            act: u32,
            width: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = width,
                .y_off = y,
                .dy_off = dy,
                .act = act,
            };
            self.pipe.run("act_bwd", self.rows * width);
        }

        /// The CPU model's eight parameter tensors in the kit's layout: the first layer's three
        /// blocks stacked (features, reference, action - the order of the wide row) then its bias;
        /// then each later layer's weights and bias. `out` holds `param_count` floats.
        pub fn packWeights(self: Self, params: [8]Tensor, out: []f32) void {
            assertf(out.len == self.param_count, @src(), "packWeights: {d} floats given, the layout holds {d}", .{
                out.len,
                self.param_count,
            });
            var at: usize = 0;
            for (params) |p| {
                @memcpy(out[at..][0..p.data.len], p.data);
                at += p.data.len;
            }
            // The eight tensors must fill the layout exactly - a model of another width would not.
            assertf(at == self.param_count, @src(), "packWeights: tensors hold {d} floats, layout {d}", .{
                at,
                self.param_count,
            });
        }

        /// The CPU learner's seven policy tensors in the kit's layout, `policy_count` floats, uploaded
        /// at `p_at`. The CPU's first layer is two blocks - state (`params[0]`), goal (`params[1]`) -
        /// and the row puts the GOAL first, so they are stacked goal block, then state block.
        pub fn packPolicy(self: Self, params: [7]Tensor, out: []f32) void {
            assertf(out.len == self.policy_count, @src(), "packPolicy: {d} floats given, the layout holds {d}", .{
                out.len,
                self.policy_count,
            });
            var at: usize = 0;
            for ([_]usize{ 1, 0, 2, 3, 4, 5, 6 }) |i| {
                @memcpy(out[at..][0..params[i].data.len], params[i].data);
                at += params[i].data.len;
            }
            assertf(at == self.policy_count, @src(), "packPolicy: tensors hold {d} floats, layout {d}", .{
                at,
                self.policy_count,
            });
        }

        /// The policy's turn at step k: its three layers over the row's [goal | state] slice, and
        /// its action written into the row's action columns - before the world model reads the row.
        fn policyStep(self: Self, k: u32) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            const hp: u32 = self.policy_hidden;
            const h1: u32 = self.ph1_at + k * self.rows * hp;
            const h2: u32 = self.ph2_at + k * self.rows * hp;
            const raw: u32 = self.raw_at + k * self.rows * self.actions;
            const w1: u32 = self.p_at;
            const w2: u32 = w1 + (self.lead + self.features) * hp + hp;
            const w3: u32 = w2 + hp * hp + hp;
            // The policy's slice: the row's first `lead + features` columns - the goal and the state -
            // read with the row's full stride, so the reference and action columns beyond them are
            // simply not part of this layer's input. Its weights are stacked in that same order
            // (`packPolicy`), which is what makes one matrix multiply do the work of two.
            self.dense(self.blockX(k), self.width, self.lead + self.features, hp, w1, h1, tanh);
            self.dense(h1, 0, hp, hp, w2, h2, tanh);
            self.dense(h2, 0, hp, self.actions, w3, raw, linear);
            // And the action into the row: `lat_act` scales the raw output (and adds this step's noise)
            // straight into the action columns the world model's layers will read next - the two
            // networks never exchange a buffer, only columns of one row.
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.actions,
                .stride = self.width,
                .x_off = raw,
                .y_off = self.blockX(k) + self.lead + self.features + self.references,
                .lat_scale = self.action_scale,
                .lat_sigma = self.sigma,
                .lat_seed = M.latStepSeed(self.seed, k),
            };
            self.pipe.run("lat_act", self.rows * self.actions);
        }

        /// The rollout, forward: for every step, three dense layers over the wide block and the
        /// join into the next. The caller has staged every block's reference and action columns
        /// and block 0's features; the kit fills the rest.
        pub fn forward(self: Self) void {
            self.rollout(self.policy_hidden > 0);
        }

        /// The same rollout on the actions AS GATHERED - the ones the simulator really took - with no
        /// policy acting. This is the rollout the world model is trained through: trained through the
        /// acting one, it would learn to match the simulator's outcomes to actions the simulator never
        /// took, which is a world that does not exist.
        pub fn forwardRecorded(self: Self) void {
            self.rollout(false);
        }

        fn rollout(self: Self, acting: bool) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            for (0..self.steps) |step| {
                const k: u32 = @intCast(step);
                // When acting, the policy goes first: its action is what the world model's step reads.
                if (acting) {
                    self.policyStep(k);
                }
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                const change: u32 = self.change_at + k * self.rows * self.features;
                // The world model's slice of the row: from `lead` on, `inputs` wide, rows `width` apart.
                self.dense(self.blockX(k) + self.lead, self.width, self.inputs, self.hidden, self.w1, h1, tanh);
                self.dense(h1, 0, self.hidden, self.hidden, self.w2, h2, tanh);
                self.dense(h2, 0, self.hidden, self.features, self.w3, change, linear);
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.features,
                    .stride = self.width,
                    .x_off = self.blockX(k) + self.lead,
                    .t_off = change,
                    .y_off = self.blockX(k + 1) + self.lead,
                    .z_off = self.blockZ(k + 1),
                };
                self.pipe.run("lat_advance", self.rows * self.features);
            }
        }

        fn dense(
            self: Self,
            x: u32,
            stride: u32,
            in_dim: u32,
            out_dim: u32,
            w: u32,
            y: u32,
            act: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .act = act,
                .x_off = x,
                .stride = stride,
                .w_off = w,
                .y_off = y,
            };
            self.pipe.run("dense_fwd", self.rows * out_dim);
        }
    };
}

/// The training data, RESIDENT in the kit's activation buffer: the reference TABLES, uploaded once per
/// clip, and the replay of FEATURES, appended once per simulation step. What the CPU would otherwise
/// recompute for every record of every window, every training step - forward kinematics, the feature
/// map, the reference's too - is computed once, when a state is new, and never again.
///
///   * **A table row per clip frame:** the reference's RAW features at that frame (the policy's goal)
///     and its encoded targets (the world model's reference input). Raw, not normalised: the gather
///     normalises as it reads, so the normaliser can change without rewriting anything.
/// WHY EVERYTHING SHARES ONE BUFFER: a compute stage is guaranteed only eight storage buffers on
/// WebGPU, and the networks already spend most of them. So the tables and the ring live inside the
/// activations buffer, at offsets past the kit's blocks, rather than in buffers of their own. That is
/// a WEB limit, not a physical one - a native backend allows far more, and this packing could relax
/// there. Nothing above this line depends on the packing: regions are found through named offsets.
///
///   * **A record per character per step:** its raw features, the action it took, and the table row
///     of the frame it was at - `features + actions + 1` floats. The ring has the fleet's replay's
///     capacity, so it holds exactly the records the CPU replay can still sample windows from; the
///     CPU keeps sampling (it knows where episodes break), and only the chosen starts go up.
///   * **Step-major:** all characters' records for one step sit side by side. Every character
///     appends at every step, in lockstep, so a step is ONE upload - not one per character.
///
/// The whole activation buffer, then, from the start:
///
///     [ rollout blocks (LatentKit) | tables | ring | normaliser | window starts | ... free ]
///       0                          ^ table_at      ^ ring_at     ^ norm_at        ^ starts_at
///
/// Nothing here is checked by the GPU - it would happily read a ring slot nobody wrote, or gather a
/// window over a step that was never appended - so the host keeps the books: which replay indices
/// the ring has actually received (`first_appended` .. `appended`), checked on every append (no gaps)
/// and on every gather (every window inside what the ring still holds).
pub fn Resident(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        pipe: *compute_host.Compute(M),
        features: u32,
        references: u32,
        actions: u32,
        envs: u32,
        capacity: u32,
        /// Floats per ring record, and per table row.
        record: u32,
        row: u32,
        /// Where the tables start, and where each clip's first frame sits among the rows.
        table_at: u32,
        clip_rows: []u32,
        /// Where the ring starts; then the normaliser (means, then spreads); then the window starts -
        /// `slots` regions of `rows` windows (two floats each), one per update of a frame; then the end.
        ring_at: u32,
        norm_at: u32,
        starts_at: u32,
        rows: u32,
        /// How many updates of one frame can have their starts staged at once.
        slots: u32,
        end: u32,
        /// The replay indices the ring has received: the first ever, and the latest. Null until the
        /// first append. The ring holds the last `capacity` of them.
        first_appended: ?u64 = null,
        appended: ?u64 = null,
        // Host scratch, for computing features once.
        state: track.State,
        data: rbt.Data,
        staging: []f32,

        /// Lay the tables and the ring out from `start` in the activation buffer (after whatever
        /// else lives there, the rollout's blocks for one) - or refuse, by name, if they do not fit.
        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *const track.Fleet,
            start: u32,
            rows: u32,
            slots: u32,
        ) !Self {
            const m: *const rbt.Model = fleet.m;
            const features: u32 = @intCast(track.localSize(m.nbody));
            const references: u32 = @intCast(track.targetSize(m));
            const actions: u32 = @intCast(track.actionSize(m));
            const envs: u32 = @intCast(fleet.options.envs);
            const capacity: u32 = @intCast(fleet.replay.capacity);
            const clip_rows: []u32 = try gpa.alloc(u32, fleet.clips.len);
            errdefer gpa.free(clip_rows);
            var table_rows: u32 = 0;
            for (fleet.clips, clip_rows) |clip, *first| {
                first.* = table_rows;
                table_rows += @intCast(clip.frame_count);
            }
            // Both shapes come from the kernel module, not from arithmetic repeated here: the gather
            // reads records and table rows with the same functions, and a future kernel writing the
            // records will too.
            const row: u32 = M.latTableWidth(features, references);
            const record: u32 = M.latRecordWidth(features, actions);
            const ring_at: u32 = start + table_rows * row;
            const norm_at: u32 = ring_at + capacity * envs * record;
            const starts_at: u32 = norm_at + 2 * features;
            const end: u32 = starts_at + slots * 2 * rows;
            if (end > floatsIn(M, "acts")) {
                return error.KitTooSmall;
            }
            var data: rbt.Data = try rbt.Data.init(gpa, m);
            errdefer data.deinit();
            var state: track.State = try track.State.init(gpa, m.nbody);
            errdefer state.deinit(gpa);
            return .{
                .gpa = gpa,
                .pipe = pipe,
                .features = features,
                .references = references,
                .actions = actions,
                .envs = envs,
                .capacity = capacity,
                .record = record,
                .row = row,
                .table_at = start,
                .clip_rows = clip_rows,
                .ring_at = ring_at,
                .norm_at = norm_at,
                .starts_at = starts_at,
                .rows = rows,
                .slots = slots,
                .end = end,
                .state = state,
                .data = data,
                .staging = try gpa.alloc(f32, @max(table_rows * row, @max(envs * record, 2 * rows))),
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.staging);
            self.state.deinit(self.gpa);
            self.data.deinit();
            self.gpa.free(self.clip_rows);
        }

        /// Where a clip frame's table row starts.
        pub fn rowAt(self: Self, clip: usize, frame: usize) u32 {
            return self.table_at + (self.clip_rows[clip] + @as(u32, @intCast(frame))) * self.row;
        }

        /// Where a character's record for replay index `index` starts: step-major, so the index
        /// picks a block of `envs` records and the character one record within it.
        pub fn recordAt(self: Self, env: usize, index: u64) u32 {
            const slot: u32 = @intCast(index % self.capacity);
            return self.ring_at + (slot * self.envs + @as(u32, @intCast(env))) * self.record;
        }

        /// Every clip's table, computed and uploaded once: per frame, the reference's raw features
        /// and its encoded targets.
        pub fn uploadTables(self: *Self, fleet: *track.Fleet) void {
            const m: *const rbt.Model = fleet.m;
            var at: usize = 0;
            for (fleet.clips) |clip| {
                const root_len: usize = clip.nq - m.nq;
                for (0..clip.frame_count) |frame| {
                    const out: []f32 = self.staging[at..][0..self.row];
                    fleet.referenceStateInto(clip, @intCast(frame), &self.data, &self.state);
                    track.local(self.state, fleet.root, out[0..self.features]);
                    track.encodeTargets(m, clip.pose(frame)[root_len..], out[self.features..]);
                    at += self.row;
                }
            }
            self.pipe.uploadAt(.acts, self.table_at, self.staging[0..at]);
        }

        /// The normaliser the gather applies, from a CPU `Normalizer`'s means and spreads.
        pub fn uploadNormalizer(self: *Self, norm: latent.Normalizer) void {
            self.pipe.uploadAt(.acts, self.norm_at, norm.mean);
            self.pipe.uploadAt(.acts, self.norm_at + self.features, norm.spread);
        }

        /// A batch of windows into `kit`'s blocks - its first wide row and its targets filled, and
        /// every wide row's reference and action - assembled on the GPU from the ring and tables.
        /// `starts` holds each window's character and first replay index (windows the CPU replay
        /// sampled, so none crosses an episode's end); only they travel, two floats a window.
        ///
        /// ONE START REGION: two gathers in the same frame would both upload their starts to the same
        /// place, and WebGPU lands every upload of a frame before any of its work runs - so both
        /// dispatches would see the second batch's starts. One gather per frame, or give this a
        /// region per step (the training driver's job, when it runs several steps a frame).
        pub fn stageStarts(self: *Self, starts: []const Start, slot: u32, steps: u32) void {
            assertf(slot < self.slots, @src(), "stageStarts: slot {d} of {d}", .{ slot, self.slots });
            // A FULL batch: a slot holds `rows` windows, and a partial staging would leave the rest of
            // them as they were - the previous update's windows, gathered again as if they were this
            // update's.
            assertf(starts.len == self.rows, @src(), "stageStarts: {d} starts, the slot holds {d}", .{
                starts.len,
                self.rows,
            });
            // Every window must lie inside what the ring has received AND still holds: from the later
            // of its first append and `capacity` behind its latest, through its latest.
            assertf(self.appended != null, @src(), "stageStarts: the ring has received nothing yet", .{});
            const latest: u64 = self.appended.?;
            const oldest: u64 = @max(self.first_appended.?, (latest + 1) -| self.capacity);
            for (starts, 0..) |start, i| {
                // The window's LAST record (its final target) must be in the ring as well.
                const inside: bool = start.index >= oldest and start.index + steps <= latest;
                assertf(inside, @src(), "stageStarts: window at {d} is outside the ring's {d}..{d}", .{
                    start.index,
                    oldest,
                    latest,
                });
                self.staging[2 * i] = float(start.env);
                self.staging[2 * i + 1] = float(@as(u32, @intCast(start.index % self.capacity)));
            }
            // Staging is shared with the appends and the tables. Safe: an upload copies its data when
            // it is made (WebGPU's writeBuffer), so the buffer is free again the moment it returns.
            self.pipe.uploadAt(.acts, self.startsAt(slot), self.staging[0 .. 2 * starts.len]);
        }

        /// The replay indices the ring actually carries right now: from the later of its first append
        /// and `capacity` behind its latest, through its latest. Null while it has received nothing.
        ///
        /// Worth asking before sampling windows, because the CPU's replay is NOT the ring: the replay
        /// may hold steps taken before the learner existed (a warm-up the ring never saw), and it may
        /// hold more of them than the ring has room for.
        pub fn held(self: Self) ?struct { first: u64, last: u64 } {
            const latest: u64 = self.appended orelse return null;
            const oldest: u64 = @max(self.first_appended.?, (latest + 1) -| self.capacity);
            return .{ .first = oldest, .last = latest };
        }

        /// Where a slot's window starts live.
        fn startsAt(self: Self, slot: u32) u32 {
            return self.starts_at + slot * 2 * self.rows;
        }

        /// A batch of windows into `kit`'s blocks - its first wide row and its targets filled, its rows'
        /// goals, references and recorded actions - assembled on the GPU from the ring and the tables,
        /// for the windows staged in `slot`.
        ///
        /// WHY A SLOT PER UPDATE: in a frame, every upload lands before any of the frame's work runs,
        /// while dispatches run in order. So two updates may share the rollout's blocks - each one's
        /// dispatches read them before the next gather overwrites them - but NOT one place for their
        /// window starts: the second upload would overwrite the first before either gather ran, and both
        /// updates would train on the same windows.
        pub fn gather(self: *Self, kit: anytype, slot: u32) void {
            assertf(slot < self.slots, @src(), "gather: slot {d} of {d}", .{ slot, self.slots });
            const fits: bool = kit.rows <= self.rows;
            assertf(fits, @src(), "gather: {d} rows, room for {d}", .{ kit.rows, self.rows });
            // The kit's blocks are written by this gather; the tables and ring are read by it. They
            // must not overlap, or the gather would overwrite its own sources mid-dispatch.
            const apart: bool = kit.total <= self.table_at;
            assertf(apart, @src(), "gather: the kit's blocks end at {d}, past the tables at {d}", .{
                kit.total,
                self.table_at,
            });
            // A goal IS a feature vector, so the lead is either nothing or exactly the features.
            const lead_ok: bool = kit.lead == 0 or kit.lead == self.features;
            assertf(lead_ok, @src(), "gather: a lead of {d} columns - it must be 0 or {d}", .{
                kit.lead,
                self.features,
            });
            self.pipe.params = .{
                .rows = kit.rows,
                .lat_features = self.features,
                .lat_references = self.references,
                .lat_actions = self.actions,
                .lat_steps = kit.steps,
                .lat_envs = self.envs,
                .lat_capacity = self.capacity,
                .ring_off = self.ring_at,
                .table_off = self.table_at,
                .norm_off = self.norm_at,
                .starts_off = self.startsAt(slot),
                .blocks_off = kit.x_at,
                .targets_off = kit.t_at,
                .lat_lead = kit.lead,
                .goals_off = kit.g_at,
            };
            self.pipe.run("lat_gather", kit.rows * (kit.steps + 1) * kit.width);
        }

        /// The step the fleet just took, into the ring - one upload for every character. Call it
        /// after every `Fleet.step`: the replay's newest record is the state that step started from.
        pub fn appendLatest(self: *Self, fleet: *track.Fleet) void {
            const index: u64 = fleet.replay.written[0] - 1;
            for (0..self.envs) |env| {
                // Lockstep: every character appends every step, which is what makes a step one
                // contiguous upload.
                const lockstep: bool = fleet.replay.written[env] - 1 == index;
                assertf(lockstep, @src(), "appendLatest: character {d} at {d}, character 0 at {d}", .{
                    env,
                    fleet.replay.written[env] - 1,
                    index,
                });
                const out: []f32 = self.staging[env * self.record ..][0..self.record];
                fleet.stateAt(env, index, &self.data, &self.state);
                track.local(self.state, fleet.root, out[0..self.features]);
                @memcpy(
                    out[M.latRecordAction(self.features)..][0..self.actions],
                    fleet.replay.actionAt(env, index),
                );
                const clip: usize = fleet.replay.clipAt(env, index);
                const last_frame: usize = fleet.clips[clip].frame_count - 1;
                const frame: usize = @min(@as(usize, fleet.replay.frameAt(env, index)), last_frame);
                out[M.latRecordTableRow(self.features, self.actions)] =
                    float(self.clip_rows[clip] + @as(u32, @intCast(frame)));
            }
            // No gaps: a step the ring missed would still be sampled by the CPU replay, and the gather
            // would read whatever that slot held before - wrong data, with no error anywhere.
            if (self.appended) |previous| {
                assertf(index == previous + 1, @src(), "appendLatest: index {d} after {d} - a step was not appended", .{
                    index,
                    previous,
                });
            } else {
                self.first_appended = index;
            }
            self.appended = index;
            self.pipe.uploadAt(.acts, self.recordAt(0, index), self.staging[0 .. self.envs * self.record]);
        }
    };
}

/// Where a training window starts: a character, and its first record's replay index.
pub const Start = struct {
    env: u32,
    index: u64,
};

/// How many floats a kit buffer holds: its field's own array length.
fn floatsIn(comptime M: type, comptime field: []const u8) u32 {
    return @typeInfo(@FieldType(M.Buffers, field)).array.len;
}
