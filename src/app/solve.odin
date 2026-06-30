package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import dsl "../dsl"
import opt "../optimizer"

set_error :: proc(state: ^Environment, message: string) {
	clear_solution(state)
	buffer_set(state.last_error[:], message)
}

run_optimizer :: proc(state: ^Environment) {
	// 0. Reset optimizer
	clear_solution(state)
	buffer_clear(state.last_error[:])
	compile_start := time.tick_now()

	// 1. Collect global variable from table
	global_names := make([dynamic]string, 0, state.var_capacity)
	global_values := make([dynamic]string, 0, state.var_capacity)
	defer delete(global_names)
	defer delete(global_values)
	for i in 0..<state.var_capacity {
		append(&global_names, buffer_string(state.global_names[i][:]))
		append(&global_values, buffer_string(state.global_values[i][:]))
	}

	// 2. Resolve globals
	m := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&m)
	if globals_err := dsl.add_moth_variables(
		&m,
		global_names[:],
		global_values[:],
	); globals_err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", globals_err))
		delete(globals_err)
		return
	}

	// 3. Parse Mothball into a command tree
	code, movement_err := dsl.parse_mothball(
		buffer_string(state.movement_script[:]),
		m.variables,
	)
	defer dsl.destroy_moth_code(&code)
	if movement_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", movement_err))
		return
	}

	// 4. Convert movement script into optimizer model arrays
	dsl.compile_mothball(&m, code[:])
	if !m.ok {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", m.err))
		return
	}
	if m.n < N_MIN || m.n > N_MAX {
		set_error(
			state,
			fmt.tprintf(
				"Error:\nMovement script generated %d states; expected range: %d to %d",
				m.n,
				N_MIN,
				N_MAX,
			),
		)
		return
	}

	n := m.n
	model := opt.Model {
		n      = n,
		drag_x = m.drag_x,
		drag_z = m.drag_z,
		accel  = m.accel,
	}
	m.drag_x = nil
	m.drag_z = nil
	m.accel = nil
	defer opt.destroy_model(&model)

	for &offset in state.angle_offset do offset = 0
	copy(state.angle_offset[:], m.angle_offset[:])

	// 5. Compile the continuous movement recurrence
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	dsl.add_resolved_variables(&parser, m.variables)
	err: string

	opt.compile_model(&model)

	// 6. Resolve markers against the compiled movement expressions
	if marker_err := dsl.resolve_markers(&parser, m.markers[:]); marker_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement markers:\n%s", marker_err))
		delete(marker_err)
		return
	}

	// 7. Parse objective expression
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

	// The optimizer minimizes, so maximizing is represented by minimizing -f.
	if state.maximize {
		inverted := dsl.scale_expr(objective, -1)
		opt.destroy_compiled_expr(&objective)
		objective = inverted
	}

	// 8. Parse constraints
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

	// 9. Parse postprocessor origin expressions
	// Compile postprocessor origins. These may reference globals, markers,
	// model expressions, and n just like the objective and constraints.
	x_origin_expr, post_err := dsl.parse_expr(
		&parser,
		buffer_string(state.post.x_origin[:]),
	)
	if post_err != "" {
		set_error(state, fmt.tprintf("Error:\nPostprocessor X Origin:\n%s", post_err))
		delete(post_err)
		return
	}
	defer opt.destroy_compiled_expr(&x_origin_expr)

	z_origin_expr: opt.Compiled_Expr
	z_origin_expr, post_err = dsl.parse_expr(
		&parser,
		buffer_string(state.post.z_origin[:]),
	)
	if post_err != "" {
		set_error(state, fmt.tprintf("Error:\nPostprocessor Z Origin:\n%s", post_err))
		delete(post_err)
		return
	}
	defer opt.destroy_compiled_expr(&z_origin_expr)

	// 10. Build the continuous constrained optimization problem
	problem := opt.build_problem(&model, objective, constraints[:])
	defer opt.destroy_problem(&problem)
	state.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 11. Phase I: solve the continuous problem
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	solution^ = opt.optimize(&model, &problem)
	state.optimize_time_seconds = time.duration_seconds(time.tick_since(optimize_start))

	// 12. Phase II: optimize the discrete/exact model when supported
	if m.discrete_supported {
		discrete_model := opt.Discrete_Model {
			n = n,
			init_v = m.init_v,
			init_drag = m.init_drag,
			exact_movement = m.exact_movement,
		}
		m.exact_movement = nil
		defer opt.destroy_discrete_model(&discrete_model)
		opt.copy_discrete_exprs(&discrete_model, &model)

		exact_problem := opt.Raw_Problem{n = n}
		defer opt.destroy_raw_problem(&exact_problem)

		discrete_state := opt.local_search(&discrete_model, &problem, &exact_problem, solution)
		defer opt.destroy_discrete_state(&discrete_state)
	}

	// 13. Convert optimizer-space results back into UI/reporting-space results
	if state.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
	}

	for constraint in constraints {
		residual := opt.eval_compiled_expr(constraint.lhs, solution.thetas[:])
		margin := math.abs(residual) if constraint.cmp == .Equal else -residual
		append(
			&solution.constraints,
			opt.Constraint_Result {
				source = strings.clone(constraint.source),
				margin = margin,
				cmp    = constraint.cmp,
			},
		)
	}

	state.x_origin = opt.eval_compiled_expr(x_origin_expr, solution.thetas[:])
	state.z_origin = opt.eval_compiled_expr(z_origin_expr, solution.thetas[:])

	state.last_solution = solution
}
