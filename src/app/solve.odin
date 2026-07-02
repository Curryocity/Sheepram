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

eval_raw_solution :: proc(expr: opt.Raw_Expr, solution: ^opt.Solution, facings_are_degrees: bool) -> f64 {
	n := len(expr.x_coeff)
	assert(len(expr.z_coeff) == n)
	assert(len(expr.f_coeff) == n)
	assert(len(solution.xs) >= n)
	assert(len(solution.zs) >= n)
	assert(len(solution.thetas) >= n)

	value := expr.constant
	for t in 0..<n {
		facing := solution.thetas[t]
		if !facings_are_degrees do facing *= 180.0/math.PI

		value += expr.x_coeff[t]*solution.xs[t] +
		         expr.z_coeff[t]*solution.zs[t] +
		         expr.f_coeff[t]*facing
	}
	return value
}

wrap_radians_pi :: proc(rad: f64) -> f64 {
	wrapped := math.mod(rad+math.PI, 2*math.PI)
	if wrapped < 0 do wrapped += 2*math.PI
	return wrapped-math.PI
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
	if state.discrete_search && !m.discrete_supported {
		set_error(
			state,
			"Error:\nDiscrete Local Search is not supported by this movement model.",
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
	objective: opt.Raw_Expr
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
	defer opt.destroy_raw_expr(&objective)

	// The optimizer minimizes, so maximizing "obj" is represented by minimizing "-obj".
	if state.maximize {
		inverted := opt.scale_raw_expr(objective, -1)
		opt.destroy_raw_expr(&objective)
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
	defer opt.destroy_raw_expr(&x_origin_expr)

	z_origin_expr: opt.Raw_Expr
	z_origin_expr, post_err = dsl.parse_expr(
		&parser,
		buffer_string(state.post.z_origin[:]),
	)
	if post_err != "" {
		set_error(state, fmt.tprintf("Error:\nPostprocessor Z Origin:\n%s", post_err))
		delete(post_err)
		return
	}
	defer opt.destroy_raw_expr(&z_origin_expr)

	// 10. Build the raw problem and reduce it to the continuous optimizer problem
	raw_problem := opt.make_raw_problem(objective, constraints[:], n)
	defer opt.destroy_raw_problem(&raw_problem)

	problem := opt.reduce_problem(&raw_problem, model, m.angle_offset[:])
	defer opt.destroy_problem(&problem)
	state.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 11. Phase I: solve the continuous problem
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	solution^ = opt.optimize(&model, &problem)
	for &theta in solution.thetas do theta = wrap_radians_pi(theta)
	state.continuous_time_seconds = time.duration_seconds(time.tick_since(optimize_start))

	// 12. Phase II: optimize the discrete/exact model when requested
	if state.discrete_search {
		discrete_start := time.tick_now()
		discrete_model := opt.Discrete_Model {
			n = n,
			init_v = m.init_v,
			init_drag = m.init_drag,
			angle_offset = make([dynamic]f64, n),
			exact_movement = m.exact_movement,
		}
		for i in 0..<n {
			discrete_model.angle_offset[i] = m.angle_offset[i]*math.PI/180
		}
		m.exact_movement = nil
		defer opt.destroy_discrete_model(&discrete_model)
		opt.copy_discrete_exprs(&discrete_model, &model)

		search_mode := opt.Local_Search_Mode.Regular
		starts := 1
		if state.cook {
			search_mode = .Cooking
			starts = clamp(state.chefs, 1, 100)
		}

		exact_work := opt.make_exact_workspace(n)
		defer opt.destroy_exact_workspace(&exact_work)

		best_discrete_state: opt.Discrete_State
		defer opt.destroy_discrete_state(&best_discrete_state)
		best_grade: opt.Grade
		has_best := false

		for start in 0..<starts {
			candidate_state := opt.local_search(
				&discrete_model,
				&problem,
				&raw_problem,
				solution,
				search_mode,
			)

			candidate_grade: opt.Grade
			opt.exact_grading(
				&candidate_grade,
				&discrete_model,
				&raw_problem,
				candidate_state,
				&exact_work,
			)

			accept_candidate := !has_best
			if has_best {
				if candidate_grade.feasible != best_grade.feasible {
					accept_candidate = candidate_grade.feasible
				} else if candidate_grade.feasible {
					accept_candidate = candidate_grade.objective < best_grade.objective
				} else {
					accept_candidate = candidate_grade.violation_sqr < best_grade.violation_sqr
				}
			}

			if accept_candidate {
				if has_best do opt.destroy_discrete_state(&best_discrete_state)
				best_discrete_state = candidate_state
				best_grade = candidate_grade
				has_best = true
			} else {
				opt.destroy_discrete_state(&candidate_state)
			}
		}

		exact_solution := opt.create_exact_solution(&discrete_model, best_discrete_state)
		exact_solution.optimum = eval_raw_solution(raw_problem.objective, &exact_solution, true)

		opt.destroy_solution(solution)
		solution^ = exact_solution
		state.last_solution_discrete = true
		state.last_solution_cooking = state.cook
		state.discrete_time_seconds = time.duration_seconds(time.tick_since(discrete_start))
	}

	// 13. Convert optimizer-space results back into UI/reporting-space results
	if state.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
	}

	for constraint in constraints {
		residual := eval_raw_solution(constraint.lhs, solution, state.last_solution_discrete)
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

	state.x_origin = eval_raw_solution(x_origin_expr, solution, state.last_solution_discrete)
	state.z_origin = eval_raw_solution(z_origin_expr, solution, state.last_solution_discrete)

	state.last_solution = solution
}
