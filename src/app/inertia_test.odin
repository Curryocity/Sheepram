package app

import "core:strings"
import "core:testing"

import opt "../optimizer"

// Future second-pass Avoid constraint fixtures found in saved presets:
// - low Z h2h / low Zmm h2h: Z Avoid+ at tick 6
// - 1xbmm nix: X Avoid- at tick 46
// - 2.875bm 4.125+0.5: Z Avoid+ at ticks 8 and 30
// - stair2cake inv nix -0.5: Z Avoid+ at tick 1

@(test)
test_parse_and_apply_inertia_hits :: proc(t: ^testing.T) {
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "2, 0, 2"
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Plus)-1] = "3"
	texts[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1] = "1"

	assignments, err := parse_inertia_assignments(&texts, 4)
	defer destroy_inertia_assignments(&assignments)
	defer delete(err)
	testing.expect_value(t, err, "")
	if err != "" do return
	testing.expect_value(t, len(assignments.ticks[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1]), 2)

	drag_x := [?]f64{1, 1, 1, 1}
	drag_z := [?]f64{1, 1, 1, 1}
	exact := [?]opt.Exact_Movement{
		{drag_x = 1, drag_z = 1},
		{drag_x = 1, drag_z = 1},
		{drag_x = 1, drag_z = 1},
	}
	initial_drag_x, initial_drag_z := apply_inertia_hits(&assignments, drag_x[:], drag_z[:], exact[:], 1)
	testing.expect_value(t, initial_drag_x, 0)
	testing.expect_value(t, initial_drag_z, 1)
	testing.expect_value(t, drag_x[0], 0)
	testing.expect_value(t, drag_x[2], 0)
	testing.expect_value(t, drag_z[1], 0)
	testing.expect_value(t, exact[1].drag_x, 0)
	testing.expect_value(t, exact[0].drag_z, 0)
	testing.expect_value(t, drag_x[3], 1)

	custom_drag_x := [?]f64{1, 1, 1, 1}
	custom_drag_z := [?]f64{1, 1, 1, 1}
	_, _ = apply_inertia_hits(&assignments, custom_drag_x[:], custom_drag_z[:], nil, 1)
	testing.expect_value(t, custom_drag_x[2], 0)
	testing.expect_value(t, custom_drag_z[1], 0)
}

@(test)
test_inertia_assignment_conflict_is_an_error :: proc(t: ^testing.T) {
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "2"
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Plus)-1] = "2"
	assignments, err := parse_inertia_assignments(&texts, 4)
	defer destroy_inertia_assignments(&assignments)
	defer delete(err)
	testing.expect(t, strings.contains(err, "assigned to both X Hit and X Avoid+"))
}

@(test)
test_invalid_inertia_ticks_are_errors :: proc(t: ^testing.T) {
	texts: [2][3]string
	texts[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Minus)-1] = "4"
	assignments, err := parse_inertia_assignments(&texts, 4)
	defer destroy_inertia_assignments(&assignments)
	defer delete(err)
	testing.expect(t, strings.contains(err, "outside [0, 4)"))
}

@(test)
test_inertia_constraints_use_velocity_drag_and_requested_sign :: proc(t: ^testing.T) {
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "1"
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Minus)-1] = "2"
	texts[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Plus)-1] = "0"
	assignments, parse_err := parse_inertia_assignments(&texts, 4)
	defer destroy_inertia_assignments(&assignments)
	defer delete(parse_err)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	problem := opt.Raw_Problem {n = 4, objective = opt.make_raw_expr(4)}
	defer opt.destroy_raw_problem(&problem)
	drags := [?]f64{0.5, 0.6, 0.7, 0}
	err := add_inertia_constraints(&problem, &assignments, drags[:], 0.005)
	defer delete(err)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(problem.ineq_cons), 4)
	if len(problem.ineq_cons) != 4 do return

	// X Hit at t=1: +/-0.6 * (X[2] - X[1]) - 0.005 <= 0.
	testing.expect_value(t, problem.ineq_cons[0].constant, -0.005)
	testing.expect_value(t, problem.ineq_cons[0].x_coeff[1], -0.6)
	testing.expect_value(t, problem.ineq_cons[0].x_coeff[2], 0.6)
	testing.expect_value(t, problem.ineq_cons[1].constant, -0.005)
	testing.expect_value(t, problem.ineq_cons[1].x_coeff[1], 0.6)
	testing.expect_value(t, problem.ineq_cons[1].x_coeff[2], -0.6)

	// X Avoid- at t=2: 0.7 * (X[3] - X[2]) + 0.005 <= 0.
	testing.expect_value(t, problem.ineq_cons[2].constant, 0.005)
	testing.expect_value(t, problem.ineq_cons[2].x_coeff[2], -0.7)
	testing.expect_value(t, problem.ineq_cons[2].x_coeff[3], 0.7)

	// Z Avoid+ at t=0: -0.5 * (Z[1] - Z[0]) + 0.005 <= 0.
	testing.expect_value(t, problem.ineq_cons[3].constant, 0.005)
	testing.expect_value(t, problem.ineq_cons[3].z_coeff[0], 0.5)
	testing.expect_value(t, problem.ineq_cons[3].z_coeff[1], -0.5)
}

@(test)
test_terminal_inertia_assignment_is_rejected_when_constraints_are_added :: proc(t: ^testing.T) {
	texts: [2][3]string
	texts[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1] = "3"
	assignments, parse_err := parse_inertia_assignments(&texts, 4)
	defer destroy_inertia_assignments(&assignments)
	defer delete(parse_err)
	testing.expect_value(t, parse_err, "")

	problem := opt.Raw_Problem {n = 4, objective = opt.make_raw_expr(4)}
	defer opt.destroy_raw_problem(&problem)
	drags := [?]f64{0.5, 0.5, 0.5, 0}
	err := add_inertia_constraints(&problem, &assignments, drags[:], 0.005)
	defer delete(err)
	testing.expect(t, strings.contains(err, ">= n-1"))
}
