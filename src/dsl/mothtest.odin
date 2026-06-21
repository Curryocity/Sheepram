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
