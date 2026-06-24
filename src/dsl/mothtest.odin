package dsl

import "core:testing"
import "core:fmt"
import "core:math"

import opt "../optimizer"
import dsl "../dsl"

print_f64_array :: proc(name: string, values: []f64) {
	fmt.printf("%s: [", name)
	for value, i in values {
		if i > 0 do fmt.print(", ")
		fmt.printf("%.5f", value)
	}
	fmt.println("]")
}

wrap_degrees_180 :: proc(degrees: f64) -> f64 {
	wrapped := math.mod(degrees+180, 360)
	if wrapped < 0 do wrapped += 360
	return wrapped-180
}

@(test)
global_variables_in_mothball :: proc(t: ^testing.T) {
	state := Model_State{}
	defer destroy_moth_execution_state(&state)
	variable_err := add_moth_variables(
		&state,
		[]string{"v", "drag", "accel", "ticks"},
		[]string{"0.3", "0.91", "0.02", "2"},
	)
	testing.expect_value(t, variable_err, "")
	if variable_err != "" {
		delete(variable_err)
		return
	}

	code, err := parse_mothball(
		"initGnd(v) mv(drag, accel, ticks) st(ticks+1)",
		state.variables,
	)
	defer destroy_moth_code(&code)
	testing.expect_value(t, err, "")
	if err != "" do return

	moth_to_model(&state, code[:])
	testing.expect(t, state.ok)
	testing.expect_value(t, state.n, 6)
	testing.expect_value(t, state.init_v, 0.3)
	testing.expect_value(t, state.drag_x[1], 0.91)
	testing.expect_value(t, state.accel[1], 0.02)
}

@(test)
global_variables_cannot_use_n :: proc(t: ^testing.T) {
	state := Model_State{}
	defer destroy_moth_execution_state(&state)

	err := add_moth_variables(
		&state,
		[]string{"bad"},
		[]string{"n+1"},
	)
	defer delete(err)
	testing.expect(t, err != "")
}

@(test)
constraint_keeps_source_and_normalized_margin :: proc(t: ^testing.T) {
	model := opt.Model{n = 1}
	parser := init_parser(&model)
	defer destroy(&parser)

	constraint, err := parse_constraint(&parser, "1 + 2 < 4")
	constraints: [dynamic]opt.Constraint
	append(&constraints, constraint)
	defer destroy_constraints(&constraints)
	defer delete(err)
	testing.expect_value(t, err, "")
	if err != "" do return

	thetas := []f64{0}
	testing.expect_value(t, constraint.source, "1 + 2 < 4")
	testing.expect_value(t, constraint.cmp, opt.Constraint_Comparison.Less)
	testing.expect_value(t, -opt.eval_compiled_expr(constraint.lhs, thetas), 1.0)
}

@(test)
mothball_markers_capture_current_tick :: proc(t: ^testing.T) {
	code, err := parse_mothball("initGnd(0.3) sj.w X(x1) sa.w(5) X(x2)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, err, "")
	if err != "" do return

	state := Model_State{}
	defer destroy_moth_execution_state(&state)
	moth_to_model(&state, code[:])

	testing.expect(t, state.ok)
	testing.expect_value(t, len(state.markers), 2)
	if len(state.markers) != 2 do return
	testing.expect_value(t, state.markers[0].name, "x1")
	testing.expect_value(t, state.markers[0].type, Marker_Type.X)
	testing.expect_value(t, state.markers[0].tick, 1)
	testing.expect_value(t, state.markers[1].name, "x2")
	testing.expect_value(t, state.markers[1].type, Marker_Type.X)
	testing.expect_value(t, state.markers[1].tick, 6)
}

@(test)
mothball_markers_resolve_to_expressions :: proc(t: ^testing.T) {
	code, err := parse_mothball("initGnd(0.3) sj.w X(x1)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, err, "")
	if err != "" do return

	state := Model_State{}
	defer destroy_moth_execution_state(&state)
	moth_to_model(&state, code[:])
	testing.expect(t, state.ok)
	if !state.ok do return

	model := opt.Model {
		n = state.n,
		drag_x = state.drag_x,
		drag_z = state.drag_z,
		accel = state.accel,
	}
	state.drag_x = nil
	state.drag_z = nil
	state.accel = nil
	defer opt.destroy_model(&model)
	opt.compile_model(&model)

	parser := init_parser(&model)
	defer destroy(&parser)
	marker_err := resolve_markers(&parser, state.markers[:])
	defer delete(marker_err)
	testing.expect_value(t, marker_err, "")
	if marker_err != "" do return

	marked, parse_err := parse_expr(&parser, "x1 + 0.3")
	defer opt.destroy_compiled_expr(&marked)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" {
		delete(parse_err)
		return
	}
	testing.expect_value(t, marked.constant, model.x[1].constant+0.3)
	testing.expect_value(t, marked.sin_coeff[0], model.x[1].sin_coeff[0])
	testing.expect_value(t, marked.cos_coeff[0], model.x[1].cos_coeff[0])
}

@(test)
terminal_turn_marker_is_rejected :: proc(t: ^testing.T) {
	code, err := parse_mothball("initGnd(0.3) st T(last)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, err, "")
	if err != "" do return

	state := Model_State{}
	defer destroy_moth_execution_state(&state)
	moth_to_model(&state, code[:])
	testing.expect(t, state.ok)
	if !state.ok do return

	model := opt.Model {
		n = state.n,
		drag_x = state.drag_x,
		drag_z = state.drag_z,
		accel = state.accel,
	}
	state.drag_x = nil
	state.drag_z = nil
	state.accel = nil
	defer opt.destroy_model(&model)
	opt.compile_model(&model)

	parser := init_parser(&model)
	defer destroy(&parser)
	marker_err := resolve_markers(&parser, state.markers[:])
	defer delete(marker_err)
	testing.expect(t, marker_err != "")
}

@(test)
marker_names_cannot_conflict_with_globals :: proc(t: ^testing.T) {
	code, err := parse_mothball("initGnd(0.3) X(place)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, err, "")
	if err != "" do return

	state := Model_State{}
	defer destroy_moth_execution_state(&state)
	variable_err := add_moth_variables(
		&state,
		[]string{"place"},
		[]string{"1"},
	)
	testing.expect_value(t, variable_err, "")
	if variable_err != "" {
		delete(variable_err)
		return
	}

	moth_to_model(&state, code[:])
	testing.expect(t, !state.ok)
}

@(test)
c4_5p2p :: proc(t: ^testing.T) {
    code, err := parse_mothball(" initGnd(0.3169516131491288) sj.w sa.wa(11)")
	defer destroy_moth_code(&code)

	if err != "" {
		fmt.printf("Parse error: %s\n", err)
		testing.expect(t, false)
		return
	}

    state := dsl.Model_State{}
	defer destroy_moth_execution_state(&state)


    moth_to_model(&state, code[:])
	if !state.ok {
		fmt.printf("Model error: %s\n", state.err)
		testing.expect(t, false)
		return
	}

    fmt.println("n: ", state.n)
    fmt.println("init_v: ", state.init_v)
	print_f64_array("drag_x", state.drag_x[:])
	print_f64_array("drag_z", state.drag_z[:])
	print_f64_array("accel", state.accel[:])
	print_f64_array("angle_offset", state.angle_offset[:])

    model := opt.Model {
        n = state.n,
        drag_x = state.drag_x,
        drag_z = state.drag_z,
        accel = state.accel,
    }
	state.drag_x = nil
	state.drag_z = nil
	state.accel = nil
	defer opt.destroy_model(&model)

    opt.compile_model(&model)

    parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)

	dsl.add_variable(&parser, "m", "2")
    dsl.add_variable(&parser, "m2", "8")
    dsl.add_variable(&parser, "bx", "0.6000000238418579")

	objective, _ := dsl.parse_expr(&parser, "X[n]")
    defer opt.destroy_compiled_expr(&objective)

    constraints, _ := dsl.parse_multi_constraints(
		&parser,
		"// c4.5 p2p\n" +
		"X[m] - X[0] > 7/16\n" +
		"X[m2] - X[0] > 7/16\n" +
		"Z[m2] - Z[m-1] > 1 + bx\n",
	)
    defer dsl.destroy_constraints(&constraints)

    problem := opt.build_problem(&model, objective, constraints[:])
	defer opt.destroy_problem(&problem)

	solution := opt.optimize(&model, &problem)
	defer opt.destroy_solution(&solution)

	adjusted_facings := make([dynamic]f64, len(solution.thetas))
	defer delete(adjusted_facings)
	for theta, i in solution.thetas {
		offset := 0.0
		if i < len(state.angle_offset) do offset = state.angle_offset[i]
		adjusted_facings[i] = wrap_degrees_180(theta*180/math.PI-offset)
	}

	fmt.printf("optimum: %.6f\n", solution.optimum)
	print_f64_array("facing", adjusted_facings[:])

}
