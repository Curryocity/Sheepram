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
	if state.n < N_MIN || state.n > N_MAX {
		set_error(
			state,
			fmt.tprintf("Error:\nInvalid n: %d (expected range: %d to %d)", state.n, N_MIN, N_MAX),
		)
		return
	}
	compile_start := time.tick_now()

	// The UI stores one row per movement tick. The optimizer also stores the
	// final position after those ticks, so its state-vector length is one larger.
	n := state.n+1
	model := opt.Model {
		n      = n,
		drag_x = make([dynamic]f64, n),
		drag_z = make([dynamic]f64, n),
		accel  = make([dynamic]f64, n),
	}
	defer opt.destroy_model(&model)

	// 2. Initialize parser(varTables, Expr sizes)
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	init_v, err := dsl.parse_constant(&parser, buffer_string(state.init_v[:]))
	if err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", err))
		delete(err)
		return
	}
	dsl.define_init_v(&parser, init_v)
	for i in 0..<state.var_capacity {
		err = dsl.add_variable(
			&parser,
			buffer_string(state.global_names[i][:]),
			buffer_string(state.global_values[i][:]),
		)
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}

	// 3. Evaluate drag/accel scripts to constants
	for i in 0..<model.n-1 {
		model.drag_x[i], err = dsl.parse_constant(&parser, buffer_string(state.drag_x[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
		model.drag_z[i], err = dsl.parse_constant(&parser, buffer_string(state.drag_z[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}
	// accel[0] is initV
	// accel[model.n - 1] doesn't contribute to the final state
	for i in 0..<model.n-1 {
		model.accel[i], err = dsl.parse_constant(&parser, buffer_string(state.accel[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}

	// 4. Compile movement formulas
	opt.compile_model(&model)

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

	// 9. PostProcessor settings
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
	if post_err == "" {
		for i in 0..<state.n {
			state.angle_offset[i], post_err = dsl.parse_constant(
				&parser,
				buffer_string(state.post.angle_offset[i][:]),
			)
			if post_err != "" do break
		}
	}
	if post_err == "" && state.post.offset_mode == .Turn {
		accumulation := 0.0
		for i in 0..<state.n {
			accumulation += state.angle_offset[i]
			state.angle_offset[i] = accumulation
		}
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
	state.solution_n = state.n
}
