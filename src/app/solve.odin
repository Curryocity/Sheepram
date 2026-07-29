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

solution_is_finite :: proc(solution: ^opt.Solution) -> bool {
	if math.is_nan(solution.optimum) || math.is_inf(solution.optimum, 0) do return false
	for theta in solution.thetas {
		if math.is_nan(theta) || math.is_inf(theta, 0) do return false
	}
	for x in solution.xs {
		if math.is_nan(x) || math.is_inf(x, 0) do return false
	}
	for z in solution.zs {
		if math.is_nan(z) || math.is_inf(z, 0) do return false
	}
	return true
}

run_optimizer :: proc(state: ^Environment, control: ^Optimizer_Control = nil) {
	// 0. Reset optimizer
	clear_solution(state)
	buffer_clear(state.last_error[:])
	compile_start := time.tick_now()

	// 1. Initialize the sequential Mothball compiler
	m := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&m)

	// 2. Parse Mothball into a command tree
	code, movement_err := dsl.parse_mothball(buffer_string(state.movement_script[:]))
	defer dsl.destroy_moth_code(&code)
	if movement_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", movement_err))
		return
	}

	// 3. Convert movement script into optimizer model arrays
	dsl.compile_mothball(&m, code[:])
	if !m.ok {
		set_error(state, fmt.tprintf("Error:\nMovement script:\n%s", m.err))
		return
	}
	if m.n < N_MIN {
		set_error(
			state,
			fmt.tprintf(
				"Error:\nMovement script generated %d states; expected at least %d",
				m.n,
				N_MIN,
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

	delete(state.angle_offset)
	state.angle_offset = make([dynamic]f64, n)
	copy(state.angle_offset[:], m.angle_offset[:n])
	delete(state.last_jump_ticks)
	state.last_jump_ticks = make([dynamic]bool, n)
	for jump_tick, tick in m.jump_ticks {
		if tick >= n do break
		state.last_jump_ticks[tick] = jump_tick
	}

	// 4. Compile the continuous movement recurrence
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	dsl.add_resolved_variables(&parser, m.variables)
	err: string

	opt.compile_model(&model)

	// 5. Resolve markers against the compiled movement expressions
	if marker_err := dsl.resolve_markers(&parser, m.markers[:]); marker_err != "" {
		set_error(state, fmt.tprintf("Error:\nMovement markers:\n%s", marker_err))
		delete(marker_err)
		return
	}

	// 6. Parse objective expression
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

	// 7. Parse constraints
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

	// 8. Parse postprocessor origin expressions
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

	// 9. Build the raw problem and reduce it to the continuous optimizer problem
	raw_problem := opt.make_raw_problem(objective, constraints[:], n)
	defer opt.destroy_raw_problem(&raw_problem)
	if m.has_init_angle {
		init_angle_constraint := opt.make_raw_expr(n)
		init_angle_constraint.f_coeff[0] = 1
		init_angle_constraint.constant = -m.init_angle
		append(&raw_problem.eq_cons, init_angle_constraint)
	}

	problem := opt.reduce_problem(&raw_problem, model, m.angle_offset[:])
	defer opt.destroy_problem(&problem)
	if !opt.pure_position_expr(problem.objective) {
		set_error(state, "Error:\nFacing and turn expressions (F and T) are not allowed in the objective.")
		return
	}
	state.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 10. Phase I: solve the continuous problem
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	initial_theta := f64(state.continuous_initial_angle_degrees) * math.PI / 180
	pancake_fallback := opt.Pancake_Fallback.Spine
	if state.pancake_secondary == .BFGS {
		pancake_fallback = .BFGS
	}
	if state.continuous_optimizer == .Pancake {
		state.continuous_scan_initial_angles = false
	}
	if state.continuous_scan_initial_angles {
		sample_count := clamp(state.continuous_initial_angle_samples, 8, 256)
			seeds := make([dynamic]f64, sample_count)
			defer delete(seeds)
			for i in 0..<sample_count {
				seed_degrees := 360 * f64(i) / f64(sample_count)
				seeds[i] = seed_degrees * math.PI / 180
			}
		best_seed_index: int
		switch state.continuous_optimizer {
		case .Pancake:
			solution^ = opt.pancake_optimize(
				&model,
				&problem,
				pancake_fallback,
			)
			best_seed_index = -1
		case .Spine:
			solution^, best_seed_index = opt.spine_optimize_multistart(&model, &problem, seeds[:])
		case .BFGS:
			solution^, best_seed_index = opt.optimize_multistart(&model, &problem, seeds[:])
		}
		if best_seed_index >= 0 && best_seed_index < sample_count {
			state.continuous_initial_angle_degrees = 360 * f64(best_seed_index) / f64(sample_count)
		}
		state.continuous_scan_initial_angles = false
	} else {
		switch state.continuous_optimizer {
		case .Pancake:
			solution^ = opt.pancake_optimize(
				&model,
				&problem,
				pancake_fallback,
			)
		case .Spine:
			solution^ = opt.spine_optimize_1seed(&model, &problem, initial_theta)
		case .BFGS:
			solution^ = opt.optimize_1seed(&model, &problem, initial_theta)
		}
	}
	if !solution_is_finite(solution) {
		opt.destroy_solution(solution)
		free(solution)
		set_error(state, "Error:\nThe continuous optimizer returned a non-finite solution.")
		return
	}
	for &theta in solution.thetas do theta = wrap_radians_pi(theta)
	state.continuous_time_seconds = time.duration_seconds(time.tick_since(optimize_start))
	continuous_globally_certified := solution.continuous_globally_optimal
	continuous_pancake_used := solution.pancake_used
	continuous_pancake_used_recovery := solution.pancake_used_recovery
	continuous_pancake_recovery_reasons :=
		solution.pancake_recovery_reasons
	continuous_pancake_dual_bound := solution.pancake_dual_bound

	// 11. Phase II: optimize the discrete/exact model when requested
	if state.discrete_search {
		discrete_start := time.tick_now()
		discrete_model := opt.Discrete_Model {
			n = n,
			init_v = m.init_v,
			has_init_theta = m.has_init_angle,
			init_theta = m.init_angle*math.PI/180,
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
			starts = clamp(state.chefs, 1, 1000)
		}

		exact_work := opt.make_exact_workspace(n)
		defer opt.destroy_exact_workspace(&exact_work)

		best_discrete_state: opt.Discrete_State
		defer opt.destroy_discrete_state(&best_discrete_state)
		best_grade: opt.Grade
		has_best := false
		completed_starts := 0

		cancelled := false
		for start in 0..<starts {
			if optimizer_cancel_requested(control) {
				cancelled = true
				break
			}

			local_search_cancelled := false
			local_search_control := opt.LS_Control {
				cancel_check = optimizer_cancel_check,
				cancel_data  = rawptr(control),
				cancelled    = &local_search_cancelled,
			}
			candidate_state := opt.local_search(
				&discrete_model,
				&problem,
				&raw_problem,
				solution,
				search_mode,
				&local_search_control,
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
			completed_starts = start+1

			if has_best {
				progress_solution := opt.create_exact_solution(&discrete_model, best_discrete_state)
				progress_solution.optimum = eval_raw_solution(raw_problem.objective, &progress_solution, true)
				progress_objective := progress_solution.optimum
				if state.maximize do progress_objective *= -1
				publish_optimizer_progress(
					control,
					progress_objective,
					progress_solution.thetas[:],
					start+1,
					starts,
				)
				opt.destroy_solution(&progress_solution)
			}

			if local_search_cancelled || optimizer_cancel_requested(control) {
				cancelled = true
				break
			}
		}

		if cancelled && !has_best {
			buffer_set(state.last_error[:], "Optimization cancelled before a discrete result was found.")
			return
		}

		exact_solution := opt.create_exact_solution(&discrete_model, best_discrete_state)
		exact_solution.optimum = eval_raw_solution(raw_problem.objective, &exact_solution, true)
		exact_solution.continuous_globally_optimal = continuous_globally_certified
		exact_solution.pancake_used = continuous_pancake_used
		exact_solution.pancake_used_recovery =
			continuous_pancake_used_recovery
		exact_solution.pancake_recovery_reasons =
			continuous_pancake_recovery_reasons
		exact_solution.pancake_dual_bound =
			continuous_pancake_dual_bound

		opt.destroy_solution(solution)
		solution^ = exact_solution
		state.last_solution_discrete = true
		state.last_solution_cooking = state.cook
		state.last_solution_chefs_completed = completed_starts if state.cook else 0
		state.last_solution_chefs_total = starts if state.cook else 0
		state.discrete_time_seconds = time.duration_seconds(time.tick_since(discrete_start))
	}

	// 12. Convert optimizer-space results back into UI/reporting-space results
	if state.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
		if solution.pancake_used do solution.pancake_dual_bound *= -1
	}

	if !state.last_solution_discrete {
		for &theta, i in solution.thetas {
			theta -= m.angle_offset[i]*math.PI/180
		}
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
