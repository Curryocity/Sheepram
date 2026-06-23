package app

import "core:fmt"
import "core:math"
import "core:time"
import dsl "../dsl"
import opt "../optimizer"

set_error :: proc(state: ^Environment, message: string) {
	clear_solution(state)
	buffer_set(state.last_error[:], message)
}

run_optimizer :: proc(state: ^Environment) {
	clear_solution(state)
	buffer_clear(state.last_error[:])
	compile_start := time.tick_now()

	// Parse mothball script into a list of commands
	code, movement_err := dsl.parse_mothball(buffer_string(state.movement_script[:]))
	defer dsl.destroy_moth_code(&code)
	if movement_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", movement_err))
		return
	}

	// Create global variables table
	global_names := make([dynamic]string, 0, state.var_capacity)
	global_values := make([dynamic]string, 0, state.var_capacity)
	defer delete(global_names)
	defer delete(global_values)
	for i in 0..<state.var_capacity {
		append(&global_names, buffer_string(state.global_names[i][:]))
		append(&global_values, buffer_string(state.global_values[i][:]))
	}

	// Add globals context to mothball_to_model converter
	movement := dsl.Model_State{}
	defer dsl.destroy_moth_execution_state(&movement)
	if globals_err := dsl.add_moth_variables(
		&movement,
		global_names[:],
		global_values[:],
	); globals_err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", globals_err))
		delete(globals_err)
		return
	}

	// Convert parsed mothball to opt.model
	dsl.moth_to_model(&movement, code[:])
	if !movement.ok {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", movement.err))
		return
	}
	if movement.n < N_MIN || movement.n > N_MAX {
		set_error(
			state,
			fmt.tprintf(
				"Error:\nMovement script generated %d states; expected range: %d to %d",
				movement.n,
				N_MIN,
				N_MAX,
			),
		)
		return
	}

	n := movement.n
	model := opt.Model {
		n      = n,
		drag_x = movement.drag_x,
		drag_z = movement.drag_z,
		accel  = movement.accel,
	}
	movement.drag_x = nil
	movement.drag_z = nil
	movement.accel = nil
	defer opt.destroy_model(&model)

	for &offset in state.angle_offset do offset = 0
	copy(state.angle_offset[:], movement.angle_offset[:])

	// Initialize the optimization DSL parser and global variables.
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	dsl.add_resolved_variables(&parser, movement.variables)
	err: string

	// Compile movement formulas.
	opt.compile_model(&model)

	// Resolve Markers
	if marker_err := dsl.resolve_markers(&parser, movement.markers[:]); marker_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement markers:\n%s", marker_err))
		delete(marker_err)
		return
	}

	// 5. Parse objective
	objective: opt.Compiled_Expr
	switch state.curr_obj {
	case .X:
		objective, err = dsl.parse_expr(&parser, "X[n]")
	case .Z:
		objective, err = dsl.parse_expr(&parser, "Z[n]")
	case .Custom:
		objective, err = dsl.parse_expr(&parser, buffer_string(state.obj_script[:]))
	}
	if err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", err))
		delete(err)
		return
	}
	defer opt.destroy_compiled_expr(&objective)

	// Invert objective when maximizing
	if state.maximize {
		inverted := dsl.scale_expr(objective, -1)
		opt.destroy_compiled_expr(&objective)
		objective = inverted
	}

	// 6. Parse constraints
	constraints, constraint_err := dsl.parse_multi_constraints(
		&parser,
		buffer_string(state.constraint_script[:]),
	)
	if constraint_err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", constraint_err))
		delete(constraint_err)
		return
	}
	defer dsl.destroy_constraints(&constraints)

	// 7. Build problem
	problem := opt.build_problem(&model, objective, constraints[:])
	defer opt.destroy_problem(&problem)
	state.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 8. Optimize
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	solution^ = opt.optimize(&model, &problem)
	state.optimize_time_seconds = time.duration_seconds(time.tick_since(optimize_start))
	if state.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
	}

	// Postprocessor settings.
	x_tick, post_err := dsl.parse_constant(&parser, buffer_string(state.post.x_tick[:]))
	if post_err == "" {
		state.x_index = int(math.round(x_tick))
		state.x_add, post_err = dsl.parse_constant(&parser, buffer_string(state.post.x_add[:]))
	}
	if post_err == "" {
		z_tick: f64
		z_tick, post_err = dsl.parse_constant(&parser, buffer_string(state.post.z_tick[:]))
		state.z_index = int(math.round(z_tick))
	}
	if post_err == "" {
		state.z_add, post_err = dsl.parse_constant(&parser, buffer_string(state.post.z_add[:]))
	}
	if post_err == "" &&
	   (state.x_index < 0 || state.x_index >= n || state.z_index < 0 || state.z_index >= n) {
		post_err = fmt.aprintf("Out of bound access")
	}
	if post_err != "" {
		opt.destroy_solution(solution)
		free(solution)
		set_error(state, fmt.tprintf("Error:\nPostprocessor:\n%s", post_err))
		delete(post_err)
		return
	}

	state.last_solution = solution
}
