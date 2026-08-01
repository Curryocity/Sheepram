package app

import "core:strings"
import "core:testing"

import dsl "../dsl"
import opt "../optimizer"

// Future second-pass Avoid constraint fixtures found in saved presets:
// - low Z h2h / low Zmm h2h: Z Avoid+ at tick 6
// - 1xbmm nix: X Avoid- at tick 46
// - 2.875bm 4.125+0.5: Z Avoid+ at ticks 8 and 30
// - stair2cake inv nix -0.5: Z Avoid+ at tick 1

expect_legacy_inertia_matches_lists :: proc(
	t: ^testing.T,
	legacy_script, replacement_script: string,
	texts: ^[2][3]string,
) {
	legacy_code, legacy_parse_err := dsl.parse_mothball(legacy_script)
	defer dsl.destroy_moth_code(&legacy_code)
	testing.expect_value(t, legacy_parse_err, "")
	if legacy_parse_err != "" do return
	legacy := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&legacy)
	dsl.compile_mothball(&legacy, legacy_code[:])
	testing.expect(t, legacy.ok)
	if !legacy.ok do return

	replacement_code, replacement_parse_err := dsl.parse_mothball(replacement_script)
	defer dsl.destroy_moth_code(&replacement_code)
	testing.expect_value(t, replacement_parse_err, "")
	if replacement_parse_err != "" do return
	replacement := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&replacement)
	dsl.compile_mothball(&replacement, replacement_code[:])
	testing.expect(t, replacement.ok)
	if !replacement.ok do return

	testing.expect_value(t, replacement.n, legacy.n)
	assignments, assignment_err := parse_inertia_assignments(texts, replacement.n)
	defer destroy_inertia_assignments(&assignments)
	defer delete(assignment_err)
	testing.expect_value(t, assignment_err, "")
	if assignment_err != "" do return
	initial_drag_x, initial_drag_z := apply_inertia_hits(&assignments, replacement.drag_x[:replacement.n], replacement.drag_z[:replacement.n], replacement.exact_movement[:], replacement.init_drag)
	testing.expect_value(t, initial_drag_x, legacy.init_drag)
	testing.expect_value(t, initial_drag_z, legacy.init_drag)
	for tick in 0..<legacy.n {
		testing.expect_value(t, replacement.drag_x[tick], legacy.drag_x[tick])
		testing.expect_value(t, replacement.drag_z[tick], legacy.drag_z[tick])
	}
	for movement, tick in legacy.exact_movement {
		testing.expect_value(t, replacement.exact_movement[tick].drag_x, movement.drag_x)
		testing.expect_value(t, replacement.exact_movement[tick].drag_z, movement.drag_z)
	}
}

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

@(test)
test_low_zmm_legacy_inertia_matches_hit_lists :: proc(t: ^testing.T) {
	legacy := "initAir(0.31749) sj sa.wa(3) iz sa.wa(8) sj sa.wa(11) s.wa sj sa.wa(2) ix sa.wa(9)"
	replacement := "initAir(0.31749) sj sa.wa(3) sa.wa(8) sj sa.wa(11) s.wa sj sa.wa(2) sa.wa(9)"
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "29"
	texts[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1] = "5"
	expect_legacy_inertia_matches_lists(t, legacy, replacement, &texts)
}

@(test)
test_1xbmm_legacy_inertia_matches_hit_lists :: proc(t: ^testing.T) {
	legacy := "initGnd(0) sj.w sa.wa(11) s.wa ix(12) sj.w sa.wa(11) sj.w sa.wd(11) s.wd sj sa.wa(11)"
	replacement := "initGnd(0) sj.w sa.wa(11) s.wa sj.w sa.wa(11) sj.w sa.wd(11) s.wd sj sa.wa(11)"
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25"
	expect_legacy_inertia_matches_lists(t, legacy, replacement, &texts)
}

@(test)
test_untitled_123414_legacy_inertia_matches_hit_lists :: proc(t: ^testing.T) {
	legacy := "initGnd(0.3128494527459194, -90) sj.wd sa.wd(3) sa.wd(2) sa.wd(6) s.wd sj.w sa.wa(2) ix sa.wa(9)"
	replacement := "initGnd(0.3128494527459194, -90) sj.wd sa.wd(3) sa.wd(2) sa.wd(6) s.wd sj.w sa.wa(2) sa.wa(9)"
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "17"
	expect_legacy_inertia_matches_lists(t, legacy, replacement, &texts)
}

@(test)
test_crosspane_legacy_inertia_matches_hit_lists :: proc(t: ^testing.T) {
	legacy := "initGnd(0.2663692071789169, 26.38621492714507) sj.wa sa.wa(10) s.wa sj sa.wa(10) s.wa ix sj sa.wa(12)"
	replacement := "initGnd(0.2663692071789169, 26.38621492714507) sj.wa sa.wa(10) s.wa sj sa.wa(10) s.wa sj sa.wa(12)"
	texts: [2][3]string
	texts[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] = "25"
	expect_legacy_inertia_matches_lists(t, legacy, replacement, &texts)
}
