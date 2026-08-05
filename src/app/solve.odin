package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import dsl "../dsl"
import opt "../optimizer"

Optimizer_Material :: struct {
	maximize:             bool,
	discrete_search:      bool,
	cook:                 bool,
	chefs:                int,
	seed:                  f64,
	multistart_on:         bool,
	seed_samples:          int,
	continuous_optimizer: Continuous_Optimizer,
	pancake_recovery:     Pancake_Recovery,
	obj_type:             Objective_Type,
	movement_script:      string,
	obj_script:     string,
	cons_script:    string,
	x_origin_script:      string,
	z_origin_script:      string,
	inertia_tick_lists:   [2][3]string,
}

Optimizer_Result :: struct {
	solution:                 ^opt.Solution,
	discrete:                 bool,
	cooking:                  bool,
	chefs_completed:          int,
	chefs_total:              int,
	compile_time_seconds:     f64,
	continuous_time_seconds:  f64,
	discrete_time_seconds:    f64,
	winner_seed:              f64,
	multistart_consumed:      bool,
	x_origin:                 f64,
	z_origin:                 f64,
	angle_offset:             [dynamic]f64,
	jump_ticks:               [dynamic]bool,
	inertia_threshold:        f64,
	inertia_drag:             [dynamic]f64,
	error:                    string,
}

make_optimizer_material :: proc(state: ^Environment) -> Optimizer_Material {
	material := Optimizer_Material {
		maximize             = state.maximize,
		discrete_search      = state.discrete_search,
		cook                 = state.cook,
		chefs                = state.chefs,
		seed                  = state.seed,
		multistart_on         = state.multistart_on,
		seed_samples          = state.seed_samples,
		continuous_optimizer = state.continuous_optimizer,
		pancake_recovery     = state.pancake_recovery,
		obj_type             = state.obj_type,
		movement_script      = strings.clone(buffer_string(state.movement_script[:])),
		obj_script     = strings.clone(buffer_string(state.objective_script[:])),
		cons_script    = strings.clone(buffer_string(state.constraint_script[:])),
		x_origin_script      = strings.clone(buffer_string(state.post.x_origin[:])),
		z_origin_script      = strings.clone(buffer_string(state.post.z_origin[:])),
	}
	for axis in 0..<2 {
		for mode in 0..<3 {
			material.inertia_tick_lists[axis][mode] = strings.clone(buffer_string(state.inertia_tick_lists[axis][mode][:]))
		}
	}
	return material
}

destroy_optimizer_material :: proc(material: ^Optimizer_Material) {
	delete(material.movement_script)
	delete(material.obj_script)
	delete(material.cons_script)
	delete(material.x_origin_script)
	delete(material.z_origin_script)
	for axis in 0..<2 {
		for mode in 0..<3 do delete(material.inertia_tick_lists[axis][mode])
	}
	material^ = {}
}

destroy_optimizer_result :: proc(result: ^Optimizer_Result) {
	if result.solution != nil {
		opt.destroy_solution(result.solution)
		free(result.solution)
	}
	delete(result.angle_offset)
	delete(result.jump_ticks)
	delete(result.inertia_drag)
	delete(result.error)
	result^ = {}
}

set_optimizer_error :: proc(result: ^Optimizer_Result, message: string) {
	seed := result.winner_seed
	multistart_consumed := result.multistart_consumed
	destroy_optimizer_result(result)
	result.winner_seed = seed
	result.multistart_consumed = multistart_consumed
	result.error = strings.clone(message)
}

apply_optimizer_result :: proc(state: ^Environment, result: ^Optimizer_Result) {
	clear_solution(state)
	buffer_clear(state.last_error[:])

	state.last_solution = result.solution
	result.solution = nil
	state.last_solution_discrete = result.discrete
	state.last_solution_cooking = result.cooking
	state.last_solution_chefs_completed = result.chefs_completed
	state.last_solution_chefs_total = result.chefs_total
	state.compile_time_seconds = result.compile_time_seconds
	state.continuous_time_seconds = result.continuous_time_seconds
	state.discrete_time_seconds = result.discrete_time_seconds
	if result.multistart_consumed {
		state.seed = result.winner_seed
		state.multistart_on = false
	}
	state.x_origin = result.x_origin
	state.z_origin = result.z_origin
	state.angle_offset = result.angle_offset
	result.angle_offset = nil
	state.last_jump_ticks = result.jump_ticks
	result.jump_ticks = nil
	state.inertia_threshold = result.inertia_threshold
	state.inertia_drag = result.inertia_drag
	result.inertia_drag = nil
	buffer_set(state.last_error[:], result.error)
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

inertia_recovery_optimize :: proc(
	model: ^opt.Model,
	problem: ^opt.Problem,
	initial_thetas: []f64,
	optimizer: Continuous_Optimizer,
) -> opt.Solution {
	switch optimizer {
	case .Pancake:
		unreachable()
	case .Spine:
		return opt.spine_optimize_thetas_slice(model, problem, initial_thetas)
	case .BFGS:
		return opt.optimize_thetas_slice(model, problem, initial_thetas)
	}
	unreachable()
}

optimize :: proc(material: ^Optimizer_Material, control: ^Optimizer_Control = nil) -> Optimizer_Result {
	result := Optimizer_Result {
		winner_seed         = material.seed,
		multistart_consumed = material.multistart_on,
	}

	// 0. Initialize result
	compile_start := time.tick_now()

	// 1. Initialize the sequential Mothball compiler
	m := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&m)

	// 2. Parse Mothball into a command tree
	code, movement_err := dsl.parse_mothball(material.movement_script)
	defer dsl.destroy_moth_code(&code)
	if movement_err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\nMovement script:\n%s", movement_err))
		return result
	}

	// 3. Convert movement script into optimizer model arrays
	dsl.compile_mothball(&m, code[:])
	if !m.ok {
		set_optimizer_error(&result, fmt.tprintf("Error:\nMovement script:\n%s", m.err))
		return result
	}
	if m.n < N_MIN {
		set_optimizer_error(
			&result,
			fmt.tprintf(
				"Error:\nMovement script generated %d states; expected at least %d",
				m.n,
				N_MIN,
			),
		)
		return result
	}
	if material.discrete_search && !m.discrete_supported {
		set_optimizer_error(
			&result,
			"Error:\nDiscrete Local Search is not supported by this movement model.",
		)
		return result
	}

	n := m.n
	assignments, inertia_err := parse_inertia_assignments(&material.inertia_tick_lists, n)
	defer destroy_inertia_assignments(&assignments)
	if inertia_err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\nInertia Manager:\n%s", inertia_err))
		delete(inertia_err)
		return result
	}
	initial_drag_x, initial_drag_z := apply_inertia_hits(&assignments, m.drag_x[:n], m.drag_z[:n], m.exact_movement[:])

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

	result.angle_offset = make([dynamic]f64, n)
	copy(result.angle_offset[:], m.angle_offset[:n])
	result.jump_ticks = make([dynamic]bool, n)
	for jump_tick, tick in m.jump_ticks {
		if tick >= n do break
		result.jump_ticks[tick] = jump_tick
	}

	// 4. Compile the continuous movement recurrence
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	dsl.add_resolved_variables(&parser, m.variables)
	err: string

	opt.compile_model(&model)

	// 5. Parse objective expression
	objective: opt.Raw_Expr
	switch material.obj_type {
	case .X:
		objective, err = dsl.parse_expr(&parser, "X[n]")
	case .Z:
		objective, err = dsl.parse_expr(&parser, "Z[n]")
	case .Custom:
		objective, err = dsl.parse_expr(&parser, material.obj_script)
	}
	if err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\n%s", err))
		delete(err)
		return result
	}
	defer opt.destroy_raw_expr(&objective)

	// The optimizer minimizes, so maximizing "obj" is represented by minimizing "-obj".
	if material.maximize {
		inverted := opt.scale_raw_expr(objective, -1)
		opt.destroy_raw_expr(&objective)
		objective = inverted
	}

	// 6. Parse constraints
	constraints, constraint_err := dsl.parse_multi_constraints(
		&parser,
		material.cons_script,
	)
	if constraint_err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\n%s", constraint_err))
		delete(constraint_err)
		return result
	}
	defer dsl.destroy_constraints(&constraints)

	// 7. Parse postprocessor origin expressions
	// Compile postprocessor origins. These may reference script variables,
	// model expressions, and n just like the objective and constraints.
	x_origin_expr, post_err := dsl.parse_expr(
		&parser,
		material.x_origin_script,
	)
	if post_err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\nPostprocessor X Origin:\n%s", post_err))
		delete(post_err)
		return result
	}
	defer opt.destroy_raw_expr(&x_origin_expr)

	z_origin_expr: opt.Raw_Expr
	z_origin_expr, post_err = dsl.parse_expr(
		&parser,
		material.z_origin_script,
	)
	if post_err != "" {
		set_optimizer_error(&result, fmt.tprintf("Error:\nPostprocessor Z Origin:\n%s", post_err))
		delete(post_err)
		return result
	}
	defer opt.destroy_raw_expr(&z_origin_expr)

	// 8. Build the raw problem and reduce it to the continuous optimizer problem
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
		set_optimizer_error(&result, "Error:\nFacing and turn expressions (F and T) are not allowed in the objective.")
		return result
	}
	result.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 9. Phase I: solve the continuous problem
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	initial_theta := material.seed * math.PI / 180
	pancake_fallback := opt.Pancake_Fallback.Spine
	if material.pancake_recovery == .BFGS {
		pancake_fallback = .BFGS
	}
	has_inertia := has_inertia_assignments(&assignments)
	pancake_seed: opt.Pancake_Result
	defer opt.destroy_pancake_result(&pancake_seed)
	multistart_on := material.multistart_on
	if material.continuous_optimizer == .Pancake {
		multistart_on = false
	}
	if material.continuous_optimizer == .Pancake && has_inertia {
		// Solve the easier relaxation first and preserve its disk vectors and
		// multipliers as the seed for the full inertia problem.
		pancake_seed = opt.pancake_solve(&problem)
	} else if multistart_on {
		sample_count := clamp(material.seed_samples, 8, 256)
		seeds := make([dynamic]f64, sample_count)
		defer delete(seeds)
		for i in 0..<sample_count {
			seed_degrees := 360 * f64(i) / f64(sample_count)
			seeds[i] = seed_degrees * math.PI / 180
		}
		best_seed_index: int
		switch material.continuous_optimizer {
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
			result.winner_seed = 360 * f64(best_seed_index) / f64(sample_count)
		}
	} else {
		switch material.continuous_optimizer {
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
	if !(material.continuous_optimizer == .Pancake && has_inertia) && !solution_is_finite(solution) {
		opt.destroy_solution(solution)
		free(solution)
		set_optimizer_error(&result, "Error:\nThe continuous optimizer returned a non-finite solution.")
		return result
	}
	if !(material.continuous_optimizer == .Pancake && has_inertia) {
		for &theta in solution.thetas do theta = wrap_radians_pi(theta)
	}

	// Solve again with inertia constraint added on
	// Solving with narrow inertia band from scratch could be numerically unstable
	if has_inertia {
		inertia_constraint_err := add_inertia_constraints(&raw_problem, &assignments, m.inertia_drag[:], m.inertia_threshold)
		if inertia_constraint_err != "" {
			opt.destroy_solution(solution)
			free(solution)
			set_optimizer_error(&result, fmt.tprintf("Error:\nInertia Manager:\n%s", inertia_constraint_err))
			delete(inertia_constraint_err)
			return result
		}

		opt.destroy_problem(&problem)
		problem = opt.reduce_problem(&raw_problem, model, m.angle_offset[:])

		recovered: opt.Solution
		if material.continuous_optimizer == .Pancake {
			recovered = opt.pancake_optimize_seeded(&model, &problem, &pancake_seed, pancake_fallback)
		} else {
			recovered = inertia_recovery_optimize(&model, &problem, solution.thetas[:], material.continuous_optimizer)
		}
		if !solution_is_finite(&recovered) {
			opt.destroy_solution(&recovered)
			opt.destroy_solution(solution)
			free(solution)
			set_optimizer_error(&result, "Error:\nThe inertia recovery pass returned a non-finite solution.")
			return result
		}
		for &theta in recovered.thetas do theta = wrap_radians_pi(theta)

		opt.destroy_solution(solution)
		solution^ = recovered
	}
	result.continuous_time_seconds = time.duration_seconds(time.tick_since(optimize_start))
	continuous_globally_certified := solution.continuous_globally_optimal
	continuous_pancake_used := solution.pancake_used
	continuous_pancake_used_recovery := solution.pancake_used_recovery
	continuous_pancake_recovery_reasons := solution.pancake_recovery_reasons
	continuous_pancake_dual_bound := solution.pancake_dual_bound

	// 10. Phase II: optimize the discrete/exact model when requested
	if material.discrete_search {
		discrete_start := time.tick_now()
		discrete_model := opt.Discrete_Model {
			n = n,
			init_v = m.init_v,
			has_init_theta = m.has_init_angle,
			init_theta = m.init_angle*math.PI/180,
			init_drag_x = initial_drag_x,
			init_drag_z = initial_drag_z,
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
		if material.cook {
			search_mode = .Cooking
			starts = clamp(material.chefs, 1, 1000)
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
				if material.maximize do progress_objective *= -1
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
			opt.destroy_solution(solution)
			free(solution)
			set_optimizer_error(&result, "Optimization cancelled before a discrete result was found.")
			return result
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
		result.discrete = true
		result.cooking = material.cook
		result.chefs_completed = completed_starts if material.cook else 0
		result.chefs_total = starts if material.cook else 0
		result.discrete_time_seconds = time.duration_seconds(time.tick_since(discrete_start))
	}

	// 11. Convert optimizer-space results back into UI/reporting-space results
	if material.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
		if solution.pancake_used do solution.pancake_dual_bound *= -1
	}

	if !result.discrete {
		for &theta, i in solution.thetas {
			theta -= m.angle_offset[i]*math.PI/180
		}
	}

	for constraint in constraints {
		residual := eval_raw_solution(constraint.lhs, solution, result.discrete)
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

	result.x_origin = eval_raw_solution(x_origin_expr, solution, result.discrete)
	result.z_origin = eval_raw_solution(z_origin_expr, solution, result.discrete)
	result.inertia_threshold = m.inertia_threshold
	result.inertia_drag = m.inertia_drag
	m.inertia_drag = nil

	result.solution = solution
	return result
}
