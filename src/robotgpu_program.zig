//! robotgpu's PROGRAMS, as data: every dispatch of one step, in order - a kernel of robotgpu's by its entry name, and
//! how many invocations it runs, as a rule the model's counts turn into a number. A step is three parts: the smooth
//! dynamics up to the free acceleration, the CONSTRAINT PROGRAM (the rows each world's limits make, their projection,
//! and the accelerations Newton finds for them), and the integration.
//!
//! THE PROGRAMS, in the order a decision runs them: `before_step_program` (the action filtered, the servo's targets
//! from the clip), `step_program`, `after_step_program` (each world's clip frame advanced) - those three once per
//! physics step, the decision program (`robotgpu_host`'s `submitDecision`) - then `observe_program` once the
//! decision's steps are done, and `judge_program` after it - both through `submitDecisionEnd`.
//!
//! A file of its own, depending on nothing, for one reason: the build script reads it, to compile and translate
//! exactly robotgpu's kernels (`kernel_names`), and a build script cannot import robotgpu.zig itself, which needs
//! robot.zig and the engine's modules. robotgpu.zig re-exports what is here, takes its entry points from it
//! (`robotgpu.kernels`), and turns a dispatch's rule into a number (`robotgpu.invocationCount`).

/// HOW MANY INVOCATIONS A DISPATCH RUNS, as a rule the counts turn into a number.
pub const Invocations = enum {
    /// One per world.
    per_world,
    /// One per world and body.
    per_world_and_body,
    /// One per world and branch of the kinematic tree (MuJoCo Warp's kinematics shape).
    per_world_and_branch,
    /// One per world and geom.
    per_world_and_geom,
    /// One per world and site.
    per_world_and_site,
    /// One per world and degree of freedom.
    per_world_and_dof,
    /// One per world and actuator.
    per_world_and_actuator,
    /// One per world and activation.
    per_world_and_activation,
    /// One per world and joint.
    per_world_and_joint,
    /// One per world and number of the tracking task's action.
    per_world_and_action,
    /// One per world and limit candidate - both ends of every limited joint.
    per_world_and_limit_candidate,
    /// One per world and constraint row the world can hold.
    per_world_and_constraint_row,
    /// A whole WORKGROUP per world - robotgpu's workgroup size of invocations each - for a kernel whose invocations
    /// solve one world's problem together.
    per_world_workgroup,
};

/// One dispatch of the step program: a kernel of robotgpu's, by its entry name, and how many invocations it runs.
pub const Dispatch = struct {
    kernel: [:0]const u8,
    invocations: Invocations,
};

/// THE SMOOTH DYNAMICS, the first part of a step: each world's overflow word cleared; kinematics; the centre-of-mass
/// frame; the mass matrix and its factor; the velocities; the bias, passive and actuator forces; the servo's torques,
/// when it is on; the smooth forces and the free acceleration they give.
const smooth_program = [_]Dispatch{
    .{ .kernel = "clear_overflow", .invocations = .per_world },
    .{ .kernel = "kinematics_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "geom_poses", .invocations = .per_world_and_geom },
    .{ .kernel = "site_poses", .invocations = .per_world_and_site },
    .{ .kernel = "subtree_centres_of_mass", .invocations = .per_world },
    .{ .kernel = "body_inertias", .invocations = .per_world_and_body },
    .{ .kernel = "dof_axes", .invocations = .per_world_and_dof },
    .{ .kernel = "composite_inertias", .invocations = .per_world },
    .{ .kernel = "mass_matrix_rows", .invocations = .per_world_and_dof },
    .{ .kernel = "factor_mass_matrix", .invocations = .per_world },
    .{ .kernel = "body_velocities_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "bias_accelerations_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "body_bias_forces", .invocations = .per_world_and_body },
    .{ .kernel = "subtree_bias_forces", .invocations = .per_world },
    .{ .kernel = "bias_joint_forces", .invocations = .per_world_and_dof },
    .{ .kernel = "passive_joint_forces", .invocations = .per_world_and_dof },
    .{ .kernel = "actuator_forces", .invocations = .per_world_and_actuator },
    .{ .kernel = "actuator_joint_forces", .invocations = .per_world_and_dof },
    .{ .kernel = "servo_errors", .invocations = .per_world_and_joint },
    .{ .kernel = "servo_accelerations", .invocations = .per_world_and_dof },
    .{ .kernel = "servo_torques", .invocations = .per_world },
    .{ .kernel = "accumulate_effort", .invocations = .per_world },
    .{ .kernel = "smooth_joint_forces", .invocations = .per_world_and_dof },
    .{ .kernel = "solve_smooth_acceleration", .invocations = .per_world },
};

/// THE CONSTRAINT PROGRAM, the second part of a step: the rows each world's constraints make, in order - the floor's
/// contacts, each geom's slots filled or left empty; every limit candidate's distance and whether it is active; the
/// active candidates packed into rows in candidate order, then the floor contacts' four rows each, as robot.zig's
/// `makeConstraints` emits them; each row's
/// projection, as robot.zig's `projectConstraints` computes it; and the accelerations Newton finds for the rows, a
/// workgroup to a world - the step's acceleration, a world with no rows keeping its free one. A model whose options
/// disable its constraints makes no row.
pub const constraint_program = [_]Dispatch{
    .{ .kernel = "floor_contacts", .invocations = .per_world_and_geom },
    .{ .kernel = "limit_candidates", .invocations = .per_world_and_limit_candidate },
    .{ .kernel = "constraint_rows", .invocations = .per_world },
    .{ .kernel = "project_constraints", .invocations = .per_world_and_constraint_row },
    .{ .kernel = "newton_solve", .invocations = .per_world_workgroup },
};

/// THE INTEGRATION, the last part: the velocity update - a model's damping taken implicitly, from M times the step's
/// acceleration, which holds the constraint forces too - and the advance (activations, bounded velocities, positions).
const integration_program = [_]Dispatch{
    .{ .kernel = "damped_velocity_changes", .invocations = .per_world },
    .{ .kernel = "next_velocities", .invocations = .per_world_and_dof },
    .{ .kernel = "next_activations", .invocations = .per_world_and_activation },
    .{ .kernel = "bound_velocities", .invocations = .per_world_and_dof },
    .{ .kernel = "next_positions", .invocations = .per_world_and_joint },
};

/// THE STEP PROGRAM: every dispatch of one step, in order - the smooth dynamics, the constraint program, the
/// integration. The host runs it on a device (`robotgpu_host.Sim`), and the twin's tests run the same list, so neither
/// can drift from the other.
pub const step_program = smooth_program ++ constraint_program ++ integration_program;

/// THE TRACKING TASK's DISPATCHES around each physics step of a decision: before it, each world's applied action
/// filtered toward its policy's (`filter_actions`) and the servo's targets from the reference and the applied action
/// (`reference_targets`); after it, each world's frame advanced (`advance_frames`).
pub const before_step_program = [_]Dispatch{
    .{ .kernel = "filter_actions", .invocations = .per_world_and_action },
    .{ .kernel = "reference_targets", .invocations = .per_world_and_joint },
};
pub const after_step_program = [_]Dispatch{
    .{ .kernel = "advance_frames", .invocations = .per_world },
};

/// THE OBSERVATION, once a decision, after its last physics step: the derived quantities it reads brought forward to
/// the state the step left - the bodies' poses, the subtrees' centres of mass, the dofs' axes, the bodies' spatial
/// velocities, the step program's own kernels for them (the static form of Isaac Lab's lazy buffers) - then the
/// character's half of each world's observation (`observe_character`) and the reference's (`observe_reference`).
pub const observe_program = [_]Dispatch{
    .{ .kernel = "kinematics_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "subtree_centres_of_mass", .invocations = .per_world },
    .{ .kernel = "dof_axes", .invocations = .per_world_and_dof },
    .{ .kernel = "body_velocities_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "observe_character", .invocations = .per_world },
    .{ .kernel = "observe_reference", .invocations = .per_world },
};

/// A DECISION's START, before its first physics step: each world's effort zeroed for the decision's sums.
pub const decision_start_program = [_]Dispatch{
    .{ .kernel = "zero_effort", .invocations = .per_world },
};

/// THE POLICY's INPUTS: every world observed as it is now (`observe_program` - a reset or a step since the last
/// observation has moved its bodies), then its row of normalised goal and state features (`policy_inputs`) for the
/// learning kit's policy to read. The observation is part of the program, so inputs can never come from a stale one.
pub const policy_inputs_program = observe_program ++ [_]Dispatch{
    .{ .kernel = "policy_inputs", .invocations = .per_world },
};

/// THE DECISION's ACTION GIVEN, once the policy's raw output is in each world's choices (`chosen_actions`): the
/// exploration added to the numbers that are the action (`explore_actions`), at the clock of the decision about to be
/// stepped; then the choices blended into `actions` through the action filter at each decision (`filter_decision`) -
/// at a share of 1, the explored choice exactly.
pub const give_program = [_]Dispatch{
    .{ .kernel = "explore_actions", .invocations = .per_world },
    .{ .kernel = "filter_decision", .invocations = .per_world },
};

/// THE RESETS, once a decision after its judgement: every world whose episode ended begins another (`begin_reset`) at
/// its start frame's pose (`reset_pose`).
pub const reset_program = [_]Dispatch{
    // The decision's pushes, for the worlds still in their episode (`push_worlds`).
    .{ .kernel = "push_worlds", .invocations = .per_world },
    .{ .kernel = "begin_reset", .invocations = .per_world },
    .{ .kernel = "reset_pose", .invocations = .per_world_and_joint },
    // The new pose's kinematics and lowest points, then the rest on the floor (`rest_on_floor`); the observation
    // program that follows (`runResets`) runs the kinematics again for the rested pose.
    .{ .kernel = "kinematics_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "body_lowest_points", .invocations = .per_world_and_body },
    .{ .kernel = "rest_on_floor", .invocations = .per_world },
    // The start noise (`perturb_start`), then the rest again after it (`rest_after_noise`), on the turned pose.
    .{ .kernel = "perturb_start", .invocations = .per_world_and_joint },
    .{ .kernel = "kinematics_branch", .invocations = .per_world_and_branch },
    .{ .kernel = "body_lowest_points", .invocations = .per_world_and_body },
    .{ .kernel = "rest_after_noise", .invocations = .per_world },
    // A start in trouble's push (`start_in_trouble`): a velocity only, after the pose is settled.
    .{ .kernel = "start_in_trouble", .invocations = .per_world },
};

/// THE JUDGEMENT, once a decision, after the observation (which has brought the bodies' poses and velocities forward):
/// each body's lowest point, then each world's tracking error against its reference and its rewards - what the CPU
/// fleet's `step` measures and earns after its physics.
pub const judge_program = [_]Dispatch{
    .{ .kernel = "body_lowest_points", .invocations = .per_world_and_body },
    .{ .kernel = "judge_tracking", .invocations = .per_world },
    .{ .kernel = "judge_rewards", .invocations = .per_world },
    .{ .kernel = "judge_episode", .invocations = .per_world },
};

/// Whether two kernel names are the same name. This file imports nothing - the build script reads it too - so the
/// comparison is its own.
fn sameName(first: []const u8, second: []const u8) bool {
    if (first.len != second.len) {
        return false;
    }
    for (first, second) |first_byte, second_byte| {
        if (first_byte != second_byte) {
            return false;
        }
    }
    return true;
}

/// Whether a declaration's name marks it as a program: the name ends in `_program` ("reset_program" does,
/// "kernel_names" does not). A name no longer than the suffix itself cannot be one.
fn isProgramName(declaration_name: []const u8) bool {
    const program_suffix: []const u8 = "_program";
    if (declaration_name.len <= program_suffix.len) {
        return false;
    }
    const suffix_start: usize = declaration_name.len - program_suffix.len;
    const name_ending: []const u8 = declaration_name[suffix_start..];
    return sameName(name_ending, program_suffix);
}

/// EVERY DISPATCH OF EVERY PROGRAM - the step program's first, then those of every other public declaration of this
/// file named `..._program`, in the order they are declared. Found by reflection rather than listed by hand, so a
/// program is compiled for the device the moment it is declared: a list kept by hand once left three programs out, and
/// their kernels ran on the CPU twin alone. A program inside another (the constraint program inside the step's) adds
/// no kernel the list does not already hold.
const every_dispatch: []const Dispatch = collect: {
    // Comparing names letter by letter for every declaration takes more steps than Zig's default comptime budget.
    @setEvalBranchQuota(100_000);
    // This file seen as a type: its public declarations are what `@typeInfo` lists, by name, in the order they are
    // written - the programs among them, and everything else (`kernel_names`, `Dispatch`, ...).
    const this_file: type = @This();
    const this_file_as_struct = @typeInfo(this_file).@"struct";
    const declaration_names: []const [:0]const u8 = this_file_as_struct.decl_names;
    var dispatches_so_far: []const Dispatch = &step_program;
    for (declaration_names) |declaration_name| {
        const names_a_program: bool = isProgramName(declaration_name);
        const is_the_step_program: bool = sameName(declaration_name, "step_program");
        if (!names_a_program or is_the_step_program) {
            continue;
        }
        // The program's value, looked up by its name; `&` makes the array a slice to append.
        const program_dispatches: []const Dispatch = &@field(this_file, declaration_name);
        dispatches_so_far = dispatches_so_far ++ program_dispatches;
    }
    break :collect dispatches_so_far;
};

/// How many different kernels `every_dispatch` names - each once, as programs share kernels.
const kernel_count: usize = count: {
    // Every dispatch's name against every earlier one's, letter by letter: more than Zig's default budget.
    @setEvalBranchQuota(1_000_000);
    var distinct: usize = 0;
    for (every_dispatch, 0..) |dispatch, index| {
        const named_before: bool = for (every_dispatch[0..index]) |earlier| {
            if (sameName(earlier.kernel, dispatch.kernel)) {
                break true;
            }
        } else false;
        if (!named_before) {
            distinct += 1;
        }
    }
    break :count distinct;
};

/// EVERY KERNEL OF ROBOTGPU'S, by its entry name, each once: every program's, the step program's first in its order -
/// the one list the device's entry points and the build's compilation are both taken from.
pub const kernel_names: [kernel_count][:0]const u8 = names: {
    @setEvalBranchQuota(1_000_000);
    var names: [kernel_count][:0]const u8 = undefined;
    var named: usize = 0;
    for (every_dispatch, 0..) |dispatch, index| {
        const named_before: bool = for (every_dispatch[0..index]) |earlier| {
            if (sameName(earlier.kernel, dispatch.kernel)) {
                break true;
            }
        } else false;
        if (!named_before) {
            names[named] = dispatch.kernel;
            named += 1;
        }
    }
    break :names names;
};
