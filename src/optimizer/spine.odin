package optimizer

import "core:math"

STRUCTURED_MAX_INNER        :: 64
STRUCTURED_MAX_DAMPING_TRIES :: 8
STRUCTURED_MAX_LINE_SEARCH  :: 16
STRUCTURED_GRADIENT_TOL     :: 1e-6
STRUCTURED_MAX_ANGLE_STEP   :: math.PI / 9
STRUCTURED_BFGS_WARMUP_STEPS        :: 10
SPINE_KKT_TOL               :: ACCEPT_TOL
SPINE_OBJECTIVE_CHANGE_TOL  :: 1e-9

Structured_Workspace :: struct {
	gradient: [dynamic]f64,
	diagonal: [dynamic]f64,
	jacobian: [dynamic]f64,
	active:   [dynamic]bool,
	step:     [dynamic]f64,
	trial:    [dynamic]f64,
}

Schur_Workspace :: struct {
	inverse_diagonal: [dynamic]f64,
	active_rows:      [dynamic]int,
	factor:           [dynamic]f64,
	rhs:              [dynamic]f64,
	solution:         [dynamic]f64,
}

make_spine_workspace :: proc(
	n, constraint_count: int,
) -> Structured_Workspace {
	return {
		gradient = make([dynamic]f64, n),
		diagonal = make([dynamic]f64, n),
		jacobian = make([dynamic]f64, constraint_count * n),
		active   = make([dynamic]bool, constraint_count),
		step     = make([dynamic]f64, n),
		trial    = make([dynamic]f64, n),
	}
}

destroy_spine_workspace :: proc(work: ^Structured_Workspace) {
	delete(work.gradient)
	delete(work.diagonal)
	delete(work.jacobian)
	delete(work.active)
	delete(work.step)
	delete(work.trial)
	work^ = {}
}

make_schur_workspace :: proc(n, constraint_count: int) -> Schur_Workspace {
	return {
		inverse_diagonal = make([dynamic]f64, n),
		active_rows      = make([dynamic]int, constraint_count),
		factor           = make([dynamic]f64, constraint_count * constraint_count),
		rhs              = make([dynamic]f64, constraint_count),
		solution         = make([dynamic]f64, constraint_count),
	}
}

destroy_schur_workspace :: proc(work: ^Schur_Workspace) {
	delete(work.inverse_diagonal)
	delete(work.active_rows)
	delete(work.factor)
	delete(work.rhs)
	delete(work.solution)
	work^ = {}
}

spine_second_derivative :: proc(
	expr: Compiled_Expr,
	tick: int,
	work: ^Workspace,
) -> f64 {
	return -expr.sin_coeff[tick] * work.sin_cache[tick] -
	        expr.cos_coeff[tick] * work.cos_cache[tick]
}

spine_evaluate :: proc(
	gradient, diagonal, jacobian: []f64,
	active: []bool,
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	work: ^Workspace,
) -> f64 {
	n := problem.n
	ineq_count := len(problem.ineq_cons)
	assert(len(gradient) == n)
	assert(len(diagonal) == n)
	assert(len(jacobian) == (ineq_count + len(problem.eq_cons)) * n)
	assert(len(active) == ineq_count + len(problem.eq_cons))

	update_trig_cache(work, thetas)
	value := eval(problem.objective, thetas, work)
	grad(problem.objective, thetas, gradient, work)
	for tick in 0..<n {
		diagonal[tick] =
			spine_second_derivative(problem.objective, tick, work)
	}

	for constraint, row in problem.ineq_cons {
		constraint_value := eval(constraint, thetas, work)
		effective := max(0.0, lamb[row] + pen * constraint_value)
		value += 0.5 / pen *
			(effective * effective - lamb[row] * lamb[row])
		active[row] = effective > 0
		if !active[row] do continue

		for tick in 0..<n {
			derivative :=
				constraint.theta_coeff[tick] +
				constraint.sin_coeff[tick] * work.cos_cache[tick] -
				constraint.cos_coeff[tick] * work.sin_cache[tick]
			jacobian[row * n + tick] = derivative
			gradient[tick] += effective * derivative
			diagonal[tick] += effective *
				spine_second_derivative(constraint, tick, work)
		}
	}

	for constraint, equality_index in problem.eq_cons {
		row := ineq_count + equality_index
		constraint_value := eval(constraint, thetas, work)
		effective := nu[equality_index] + pen * constraint_value
		value += nu[equality_index] * constraint_value
		value += 0.5 * pen * constraint_value * constraint_value
		active[row] = true

		for tick in 0..<n {
			derivative :=
				constraint.theta_coeff[tick] +
				constraint.sin_coeff[tick] * work.cos_cache[tick] -
				constraint.cos_coeff[tick] * work.sin_cache[tick]
			jacobian[row * n + tick] = derivative
			gradient[tick] += effective * derivative
			diagonal[tick] += effective *
				spine_second_derivative(constraint, tick, work)
		}
	}
	return value
}

spine_kkt_stationarity :: proc(
	gradient: []f64,
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	work: ^Workspace,
) -> f64 {
	grad(problem.objective, thetas, gradient, work)
	for constraint, i in problem.ineq_cons {
		if lamb[i] == 0 do continue
		grad(constraint, thetas, work.temp_g[:], work)
		for tick in 0..<problem.n {
			gradient[tick] += lamb[i] * work.temp_g[tick]
		}
	}
	for constraint, j in problem.eq_cons {
		if nu[j] == 0 do continue
		grad(constraint, thetas, work.temp_g[:], work)
		for tick in 0..<problem.n {
			gradient[tick] += nu[j] * work.temp_g[tick]
		}
	}

	max_stationarity := 0.0
	for component in gradient {
		max_stationarity = max(max_stationarity, math.abs(component))
	}
	return max_stationarity
}

spine_prepare_schur :: proc(
	step, inverse_diagonal, rhs: []f64,
	active_rows: []int,
	gradient, diagonal, jacobian: []f64,
	active: []bool,
	damping: f64,
) -> (int, bool) {
	n := len(gradient)
	active_count := 0
	for enabled, row in active {
		if enabled {
			active_rows[active_count] = row
			active_count += 1
		}
	}

	for tick in 0..<n {
		entry := diagonal[tick] + damping
		if entry <= 0 || math.is_nan(entry) || math.is_inf(entry, 0) {
			return active_count, false
		}
		inverse_diagonal[tick] = 1 / entry
		step[tick] = -gradient[tick] * inverse_diagonal[tick]
	}

	for active_index in 0..<active_count {
		row := active_rows[active_index]
		value := 0.0
		for tick in 0..<n {
			value += jacobian[row * n + tick] * step[tick]
		}
		rhs[active_index] = value
	}
	return active_count, true
}

spine_recover_schur_step :: proc(
	step, inverse_diagonal, solution, jacobian: []f64,
	active_rows: []int,
	active_count: int,
) {
	n := len(step)
	for tick in 0..<n {
		correction := 0.0
		for active_index in 0..<active_count {
			row := active_rows[active_index]
			correction += jacobian[row * n + tick] * solution[active_index]
		}
		step[tick] -= inverse_diagonal[tick] * correction
	}
}

spine_cholesky_solve :: proc(
	factor, rhs, solution: []f64,
	n: int,
) -> bool {
	for row in 0..<n {
		for column in 0..=row {
			value := factor[row * n + column]
			for k in 0..<column {
				value -=
					factor[row * n + k] *
					factor[column * n + k]
			}
			if row == column {
				if value <= 1e-14 ||
				   math.is_nan(value) ||
				   math.is_inf(value, 0) {
					return false
				}
				factor[row * n + column] = math.sqrt(value)
			} else {
				factor[row * n + column] =
					value / factor[column * n + column]
			}
		}
	}

	// Forward solve Lz = rhs.
	for row in 0..<n {
		value := rhs[row]
		for column in 0..<row {
			value -= factor[row * n + column] * solution[column]
		}
		solution[row] = value / factor[row * n + row]
	}

	// Backward solve L^T y = z.
	for reverse_row in 0..<n {
		row := n - 1 - reverse_row
		value := solution[row]
		for column in row + 1..<n {
			value -= factor[column * n + row] * solution[column]
		}
		solution[row] = value / factor[row * n + row]
	}
	return true
}

spine_schur :: proc(
	step, gradient, diagonal, jacobian: []f64,
	active: []bool,
	pen, damping: f64,
	work: ^Schur_Workspace,
) -> bool {
	active_count, prepared := spine_prepare_schur(
		step,
		work.inverse_diagonal[:],
		work.rhs[:],
		work.active_rows[:],
		gradient,
		diagonal,
		jacobian,
		active,
		damping,
	)
	if !prepared do return false
	if active_count == 0 do return true

	n := len(gradient)
	for row_index in 0..<active_count {
		row := work.active_rows[row_index]
		for column_index in 0..=row_index {
			column := work.active_rows[column_index]
			value := 0.0
			if row_index == column_index do value = 1 / pen
			for tick in 0..<n {
				value +=
					jacobian[row * n + tick] *
					work.inverse_diagonal[tick] *
					jacobian[column * n + tick]
			}
			work.factor[row_index * active_count + column_index] = value
			work.factor[column_index * active_count + row_index] = value
		}
	}

	if !spine_cholesky_solve(
		work.factor[:],
		work.rhs[:],
		work.solution[:],
		active_count,
	) {
		return false
	}
	spine_recover_schur_step(
		step,
		work.inverse_diagonal[:],
		work.solution[:],
		jacobian,
		work.active_rows[:],
		active_count,
	)
	return true
}

spine_inner_solve :: proc(
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	work: ^Workspace,
	structured_work: ^Structured_Workspace,
	schur_work: ^Schur_Workspace,
) {
	n := problem.n
	constraint_count := len(problem.ineq_cons) + len(problem.eq_cons)
	gradient := structured_work.gradient[:]
	diagonal := structured_work.diagonal[:]
	jacobian := structured_work.jacobian[:]
	active := structured_work.active[:]
	step := structured_work.step[:]
	trial := structured_work.trial[:]
	assert(len(gradient) == n)
	assert(len(jacobian) == constraint_count * n)
	assert(len(active) == constraint_count)

	bfgs(thetas, problem, lamb, nu, pen, work, STRUCTURED_BFGS_WARMUP_STEPS)

	damping := 1e-4
	for _ in 0..<STRUCTURED_MAX_INNER {
		value := spine_evaluate(gradient[:], diagonal[:], jacobian[:], active[:], thetas, problem, lamb, nu, pen, work)
		if dot(gradient[:], gradient[:]) <
		   STRUCTURED_GRADIENT_TOL * STRUCTURED_GRADIENT_TOL {
			break
		}

		minimum_diagonal := diagonal[0]
		for entry in diagonal[1:] do minimum_diagonal = min(minimum_diagonal, entry)
		local_damping := max(damping, -minimum_diagonal + 1e-6)

		accepted := false
		for _ in 0..<STRUCTURED_MAX_DAMPING_TRIES {
			solved := spine_schur(
				step[:],
				gradient[:],
				diagonal[:],
				jacobian[:],
				active[:],
				pen,
				local_damping,
				schur_work,
			)
			if !solved || dot(gradient[:], step[:]) >= -EPS {
				local_damping *= 10
				continue
			}

			max_component := 0.0
			for component in step {
				max_component = max(max_component, math.abs(component))
			}
			if max_component > STRUCTURED_MAX_ANGLE_STEP {
				scale_vector(step[:], STRUCTURED_MAX_ANGLE_STEP / max_component)
			}

			alpha := 1.0
			directional_derivative := dot(gradient[:], step[:])
			for _ in 0..<STRUCTURED_MAX_LINE_SEARCH {
				for tick in 0..<n {
					trial[tick] = thetas[tick] + alpha * step[tick]
				}
				derivative := alpha * directional_derivative
				if derivative >= -EPS {
					alpha *= 0.5
					continue
				}
				trial_value := compute_aug_l(nil, trial[:], problem, lamb, nu, pen, work)
				if trial_value <= value + 1e-4 * derivative {
					copy(thetas, trial[:])
					accepted = true
					damping = max(1e-8, local_damping * 0.25)
					break
				}
				alpha *= 0.5
			}
			if accepted do break
			local_damping *= 10
		}
		if !accepted do break
	}
}

spine_solve_from_thetas :: proc(
	model: ^Model,
	problem: ^Problem,
	initial_thetas: []f64,
	workspace: ^Workspace = nil,
	stop_at_first_feasible: bool = false,
	kkt_converged_out: ^bool = nil,
) -> Solution {
	assert_valid_objective(problem)
	if kkt_converged_out != nil do kkt_converged_out^ = false
	n := model.n
	assert(len(initial_thetas) == n)
	owned_workspace: Workspace
	work := workspace
	if work == nil {
		owned_workspace = make_workspace(n)
		work = &owned_workspace
	}
	defer {
		if workspace == nil do destroy_workspace(&owned_workspace)
	}

	thetas := make([dynamic]f64, n)
	copy(thetas[:], initial_thetas)
	lamb := make([dynamic]f64, len(problem.ineq_cons))
	defer delete(lamb)
	nu := make([dynamic]f64, len(problem.eq_cons))
	defer delete(nu)
	structured_work := make_spine_workspace(n, len(problem.ineq_cons) + len(problem.eq_cons))
	defer destroy_spine_workspace(&structured_work)
	schur_work := make_schur_workspace(
		n,
		len(problem.ineq_cons) + len(problem.eq_cons),
	)
	defer destroy_schur_workspace(&schur_work)

	// ALM stuffs
	pen := 1.0
	max_vio := math.INF_F64
	prev_max_vio := max_vio
	best_feasible_thetas := make([dynamic]f64, n)
	defer delete(best_feasible_thetas)
	best_feasible_value := math.INF_F64
	has_feasible := false
	previous_feasible_value := math.INF_F64
	for _ in 0..<CONTINUOUS_MAX_OUTER {
		spine_inner_solve(
			thetas[:],
			problem,
			lamb[:],
			nu[:],
			pen,
			work,
			&structured_work,
			&schur_work,
		)

		max_gi := 0.0
		max_hj := 0.0
		max_complementarity := 0.0
		update_trig_cache(work, thetas[:])
		for constraint, i in problem.ineq_cons {
			gi := eval(constraint, thetas[:], work)
			max_gi = max(max_gi, max(0.0, gi))

			lamb[i] = max(0.0, lamb[i] + pen * gi)
			max_complementarity = max(max_complementarity, math.abs(lamb[i] * gi))
		}
		for constraint, j in problem.eq_cons {
			hj := eval(constraint, thetas[:], work)
			max_hj = max(max_hj, math.abs(hj))
			nu[j] += pen * hj
		}
		max_vio = max(max_gi, max_hj)
		if max_vio < CONTINUOUS_TOL {
			objective_value := eval(problem.objective, thetas[:], work)
			objective_stalled := false
			if has_feasible {
				objective_scale := max(1.0, max(math.abs(objective_value), math.abs(previous_feasible_value)))
				objective_stalled =
					math.abs(objective_value - previous_feasible_value) <=
						SPINE_OBJECTIVE_CHANGE_TOL * objective_scale
			}

			if !has_feasible || objective_value < best_feasible_value {
				copy(best_feasible_thetas[:], thetas[:])
				best_feasible_value = objective_value
			}
			has_feasible = true
			previous_feasible_value = objective_value
			if objective_stalled do break

			if max_complementarity < SPINE_KKT_TOL {
				max_stationarity := spine_kkt_stationarity(
					structured_work.gradient[:],
					thetas[:],
					problem,
					lamb[:],
					nu[:],
					work,
				)
				if max_stationarity < SPINE_KKT_TOL {
					if kkt_converged_out != nil {
						kkt_converged_out^ = true
					}
					break
				}
			}
			if stop_at_first_feasible do break
		}

		if max_vio > 0.5 * prev_max_vio do pen *= 2
		prev_max_vio = max_vio
	}
	if has_feasible do copy(thetas[:], best_feasible_thetas[:])

	solution := Solution {
		thetas = thetas,
		xs     = make([dynamic]f64, n),
		zs     = make([dynamic]f64, n),
	}
	update_trig_cache(work, thetas[:])
	solution.optimum = eval(problem.objective, thetas[:], work)
	for i in 0..<n {
		solution.xs[i] = eval(model.x[i], thetas[:], work)
		solution.zs[i] = eval(model.z[i], thetas[:], work)
	}
	return solution
}

spine_optimize_from_thetas :: proc(
	model: ^Model,
	problem: ^Problem,
	initial_thetas: []f64,
	workspace: ^Workspace = nil,
) -> Solution {
	return spine_solve_from_thetas(
		model,
		problem,
		initial_thetas,
		workspace,
	)
}

spine_optimize :: proc(
	model: ^Model,
	problem: ^Problem,
	seed: f64 = math.PI / 4,
	workspace: ^Workspace = nil,
) -> Solution {
	initial_thetas := make([dynamic]f64, model.n)
	defer delete(initial_thetas)
	for &theta in initial_thetas do theta = seed
	return spine_solve_from_thetas(
		model,
		problem,
		initial_thetas[:],
		workspace,
	)
}

spine_optimize_best_of :: proc(
	model: ^Model,
	problem: ^Problem,
	seeds: []f64,
) -> (Solution, int) {
	work := make_workspace(model.n)
	defer destroy_workspace(&work)
	if len(seeds) == 0 {
		return spine_optimize(model, problem, 0, &work), -1
	}

	seed_thetas := make([dynamic]f64, model.n)
	defer delete(seed_thetas)
	for &theta in seed_thetas do theta = seeds[0]
	best_kkt_converged := false
	best := spine_solve_from_thetas(
		model,
		problem,
		seed_thetas[:],
		&work,
		true,
		&best_kkt_converged,
	)
	best_violation := constraint_violation(problem, best.thetas[:], &work)
	best_index := 0

	for seed, index in seeds[1:] {
		for &theta in seed_thetas do theta = seed
		candidate_kkt_converged := false
		candidate := spine_solve_from_thetas(
			model,
			problem,
			seed_thetas[:],
			&work,
			true,
			&candidate_kkt_converged,
		)
		candidate_violation := constraint_violation(problem, candidate.thetas[:], &work)

		if solution_better(&candidate, candidate_violation, &best, best_violation) {
			destroy_solution(&best)
			best = candidate
			best_violation = candidate_violation
			best_index = index + 1
			best_kkt_converged = candidate_kkt_converged
		} else {
			destroy_solution(&candidate)
		}
	}

	// Compare basins cheaply at first feasibility. Only the winning basin
	// needs a full convergence solve when it does not already satisfy KKT.
	if best_violation >= ACCEPT_TOL || best_kkt_converged {
		return best, best_index
	}
	refined_kkt_converged := false
	refined := spine_solve_from_thetas(
		model,
		problem,
		best.thetas[:],
		&work,
		kkt_converged_out = &refined_kkt_converged,
	)
	refined_violation :=
		constraint_violation(problem, refined.thetas[:], &work)
	if refined_kkt_converged ||
	   solution_better(
		&refined,
		refined_violation,
		&best,
		best_violation,
	   ) {
		destroy_solution(&best)
		return refined, best_index
	}
	destroy_solution(&refined)
	return best, best_index
}
