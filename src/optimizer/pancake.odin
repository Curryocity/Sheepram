package optimizer

import "core:math"

PANCAKE_MAX_ITERATIONS        :: 10_000
PANCAKE_CHECK_INTERVAL        :: 25
PANCAKE_FEASIBILITY_TOL       :: 1e-7
PANCAKE_GAP_TOL               :: 1e-7
PANCAKE_CHANGE_TOL            :: 1e-9
PANCAKE_BOUNDARY_TOL          :: 1e-6

Pancake_Fallback :: enum {
	Spine,
	BFGS,
}

Pancake_Result :: struct {
	nonreduced: bool,
	converged:           bool,
	certified:           bool,
	iterations:          int,
	objective:           f64,
	dual_bound:          f64,
	gap:                 f64,
	max_violation:       f64,
	max_radius_deficit:  f64,
	thetas:              [dynamic]f64,
}

Pancake_Recovery_Reason :: enum {
	Facing_Constraint,
	Non_Unit_Vector_Strength,
	Large_Dual_Gap,
	Infeasible_Solution,
}

Pancake_Recovery_Reasons :: bit_set[Pancake_Recovery_Reason]

destroy_pancake_result :: proc(result: ^Pancake_Result) {
	delete(result.thetas)
	result^ = {}
}

pure_position_problem :: proc(problem: ^Problem) -> bool {
	for constraint in problem.ineq_cons {
		if !pure_position_expr(constraint) do return false
	}
	for constraint in problem.eq_cons {
		if !pure_position_expr(constraint) do return false
	}
	return true
}

pancake_fill_row :: proc(coefficients: []f64, row, width: int, expr: Compiled_Expr) {
	for tick in 0..<len(expr.sin_coeff) {
		coefficients[row * width + 2 * tick] = expr.sin_coeff[tick]
		coefficients[row * width + 2 * tick + 1] = expr.cos_coeff[tick]
	}
}

eval_constraint_residuals :: proc(
	out, coefficients, constants, vector: []f64,
	rows, columns: int,
) {
	for row in 0..<rows {
		residual := constants[row]
		for column in 0..<columns {
			residual += coefficients[row * columns + column] * vector[column]
		}
		out[row] = residual
	}
}

eval_primal_gradient :: proc(
	out, objective, coefficients, dual: []f64,
	rows, columns: int,
) {
	copy(out[:columns], objective[:columns])
	for row in 0..<rows {
		row_start := row * columns
		scale := dual[row]
		for column in 0..<columns {
			out[column] +=
				coefficients[row_start + column] * scale
		}
	}
}

has_constraint_coefficient :: proc(
	coefficients: []f64,
	rows, width, tick: int,
) -> bool {
	for row in 0..<rows {
		if math.abs(coefficients[row * width + 2 * tick]) > EPS ||
		   math.abs(coefficients[row * width + 2 * tick + 1]) > EPS {
			return true
		}
	}
	return false
}

pancake_measurements :: proc(
	primal, objective, coefficients, constants: []f64,
	ineq_count, row_count, width: int,
) -> ( objective_value, max_violation, max_radius_deficit: f64) {
	
	objective_value = objective[width]
	for column in 0..<width {
		objective_value += objective[column] * primal[column]
	}

	max_violation = 0
	for row in 0..<row_count {
		residual := constants[row]
		for column in 0..<width {
			residual += coefficients[row * width + column] * primal[column]
		}
		if row < ineq_count {
			max_violation = max(max_violation, max(0.0, residual))
		} else {
			max_violation = max(max_violation, math.abs(residual))
		}
	}

	max_radius_deficit = 0
	for tick in 0..<width / 2 {
		relevant :=
			math.abs(objective[2 * tick]) > EPS ||
			math.abs(objective[2 * tick + 1]) > EPS ||
			has_constraint_coefficient(coefficients, row_count, width, tick)

		if !relevant do continue
		sine := primal[2 * tick]
		cosine := primal[2 * tick + 1]
		radius := math.sqrt(sine * sine + cosine * cosine)
		max_radius_deficit = max(max_radius_deficit, max(0.0, 1 - radius))
	}
	return
}

pancake_dual_bound :: proc(
	objective, coefficients, constants, dual, gradient_work: []f64,
	rows, width: int,
) -> f64 {
	// q(y) = objective_constant + constants^T y
	//        - sum_tick ||objective_tick + K_tick^T y||_2.
	eval_primal_gradient(gradient_work, objective, coefficients, dual, rows, width)
	bound := objective[width]
	for row in 0..<rows do bound += constants[row] * dual[row]
	for tick in 0..<width / 2 {
		sine := gradient_work[2 * tick]
		cosine := gradient_work[2 * tick + 1]
		bound -= math.sqrt(sine * sine + cosine * cosine)
	}
	return bound
}

pancake_solve :: proc(problem: ^Problem) -> Pancake_Result {
	assert_valid_objective(problem)
	result := Pancake_Result {
		nonreduced = pure_position_problem(problem),
		thetas = make([dynamic]f64, problem.n),
	}

	n := problem.n
	width := 2 * n
	ineq_count := 0
	for constraint in problem.ineq_cons {
		if pure_position_expr(constraint) do ineq_count += 1
	}
	eq_count := 0
	for constraint in problem.eq_cons {
		if pure_position_expr(constraint) do eq_count += 1
	}
	row_count := ineq_count + eq_count
	coeffs := make([dynamic]f64, row_count * width)
	defer delete(coeffs)
	constants := make([dynamic]f64, row_count)
	defer delete(constants)
	objective := make([dynamic]f64, width + 1)
	defer delete(objective)

	// Fill in the coefficients
	objective[width] = problem.objective.constant
	for tick in 0..<n {
		objective[2 * tick] = problem.objective.sin_coeff[tick]
		objective[2 * tick + 1] = problem.objective.cos_coeff[tick]
	}
	row := 0
	for constraint in problem.ineq_cons {
		if !pure_position_expr(constraint) do continue
		constants[row] = constraint.constant
		pancake_fill_row(coeffs[:], row, width, constraint)
		row += 1
	}
	for constraint in problem.eq_cons {
		if !pure_position_expr(constraint) do continue
		constants[row] = constraint.constant
		pancake_fill_row(coeffs[:], row, width, constraint)
		row += 1
	}

	// Initialize at the center of pancake (s, c) = (0, 0)
	primal := make([dynamic]f64, width)
	defer delete(primal)
	extrapolated := make([dynamic]f64, width)
	defer delete(extrapolated)
	primal_gradient := make([dynamic]f64, width)
	defer delete(primal_gradient)
	dual := make([dynamic]f64, row_count)
	defer delete(dual)
	residuals := make([dynamic]f64, row_count)
	defer delete(residuals)
	column_work := make([dynamic]f64, width)
	defer delete(column_work)
	primal_steps := make([dynamic]f64, width)
	defer delete(primal_steps)
	dual_steps := make([dynamic]f64, row_count)
	defer delete(dual_steps)

	copy(extrapolated[:], primal[:])

	for tick in 0..<n {
		sine_sum := 0.0
		cosine_sum := 0.0
		for row in 0..<row_count {
			sine_sum += math.abs(coeffs[row * width + 2 * tick])
			cosine_sum += math.abs(coeffs[row * width + 2 * tick + 1])
		}
		max_sum := max(sine_sum, cosine_sum)
		step := 1.0
		if max_sum > EPS do step = 0.9 / max_sum
		primal_steps[2 * tick] = step
		primal_steps[2 * tick + 1] = step
	}
	for row in 0..<row_count {
		row_sum := 0.0
		for column in 0..<width {
			row_sum += math.abs(coeffs[row * width + column])
		}
		dual_steps[row] = 1.0
		if row_sum > EPS do dual_steps[row] = 0.9 / row_sum
	}

	iter := 0

	for iter in 1..=PANCAKE_MAX_ITERATIONS {

		// Dual ascent
		max_dual_change := 0.0
		eval_constraint_residuals(residuals[:], coeffs[:], constants[:], extrapolated[:], row_count, width)
		for row in 0..<row_count {
			old := dual[row]
			dual[row] += dual_steps[row] * residuals[row]
			if row < ineq_count do dual[row] = max(0.0, dual[row])
			change := math.abs(dual[row] - old)
			max_dual_change = max(max_dual_change, change)
		}

		// Primal descent
		eval_primal_gradient(primal_gradient[:], objective[:], coeffs[:], dual[:], row_count, width)
		max_primal_change := 0.0
		for tick in 0..<n {

			sine_index := 2 * tick
			cosine_index := sine_index + 1
			old_sine := primal[sine_index]
			old_cosine := primal[cosine_index]

			sine := old_sine - primal_steps[sine_index] * primal_gradient[sine_index]
			cosine := old_cosine - primal_steps[cosine_index] * primal_gradient[cosine_index]
			radius := math.sqrt(sine * sine + cosine * cosine)
			if radius > 1 {
				sine /= radius
				cosine /= radius
			} // clamp

			primal[sine_index] = sine
			primal[cosine_index] = cosine
			max_primal_change = max(max_primal_change, math.abs(sine - old_sine), math.abs(cosine - old_cosine))

			extrapolated[sine_index] = 2 * sine - old_sine
			extrapolated[cosine_index] = 2 * cosine - old_cosine
		}
		
		// Every PANCAKE_CHECK_INTERVAL(=25) iterations, check if the result converges.
		if iter % PANCAKE_CHECK_INTERVAL != 0 do continue
		result.objective, result.max_violation, result.max_radius_deficit = pancake_measurements(primal[:], objective[:], coeffs[:], constants[:], ineq_count, row_count, width)
		result.dual_bound = pancake_dual_bound(objective[:], coeffs[:], constants[:], dual[:], column_work[:], row_count, width)
		result.gap = math.abs(result.objective - result.dual_bound)
		gap_tolerance := PANCAKE_GAP_TOL * max(1.0, math.abs(result.objective))

		if result.max_violation <= PANCAKE_FEASIBILITY_TOL && 
		   result.gap <= gap_tolerance && 
		   max(max_primal_change, max_dual_change) <= PANCAKE_CHANGE_TOL {

			result.converged = true
			break
		}
	}

	result.iterations = iter
	result.objective, result.max_violation, result.max_radius_deficit = pancake_measurements(primal[:], objective[:], coeffs[:], constants[:], ineq_count, row_count, width)
	result.dual_bound = pancake_dual_bound(objective[:], coeffs[:], constants[:], dual[:], column_work[:], row_count, width)
	result.gap = math.abs(result.objective - result.dual_bound)

	// Neutralize the angle toward 45 deg as the primal radius approach 0
	neutral_component := math.sqrt(f64(0.5))
	for tick in 0..<n {
		sine := primal[2 * tick]
		cosine := primal[2 * tick + 1]
		radius := math.sqrt(sine * sine + cosine * cosine)
		interior_weight := max(0.0, 1.0 - radius)
		sine += interior_weight * neutral_component
		cosine += interior_weight * neutral_component
		result.thetas[tick] = math.atan2(sine, cosine)
	}


	// Checking if the result is certified
	gap_tolerance := PANCAKE_GAP_TOL * max(1.0, math.abs(result.objective))
	result.certified =
		result.nonreduced &&
		result.max_violation <= PANCAKE_FEASIBILITY_TOL &&
		result.gap <= gap_tolerance &&
		result.max_radius_deficit <= PANCAKE_BOUNDARY_TOL
	return result
}

build_pancake_solution :: proc(model: ^Model, problem: ^Problem, thetas: []f64, work: ^Workspace) -> Solution {
	solution := Solution {
		continuous_globally_optimal = true,
		thetas                        = make([dynamic]f64, model.n),
		xs                            = make([dynamic]f64, model.n),
		zs                            = make([dynamic]f64, model.n),
	}
	copy(solution.thetas[:], thetas)
	update_trig_cache(work, solution.thetas[:])
	solution.optimum = eval(problem.objective, solution.thetas[:], work)
	for tick in 0..<model.n {
		solution.xs[tick] = eval(model.x[tick], solution.thetas[:], work)
		solution.zs[tick] = eval(model.z[tick], solution.thetas[:], work)
	}
	return solution
}

pancake_collect_recovery_reasons :: proc(
	result: ^Pancake_Result,
) -> Pancake_Recovery_Reasons {
	reasons: Pancake_Recovery_Reasons
	if !result.nonreduced {
		reasons += {.Facing_Constraint}
	}
	if result.max_violation > PANCAKE_FEASIBILITY_TOL {
		reasons += {.Infeasible_Solution}
	}
	relaxation_gap_tolerance :=
		PANCAKE_GAP_TOL * max(1.0, math.abs(result.objective))
	if result.gap > relaxation_gap_tolerance {
		reasons += {.Large_Dual_Gap}
	}
	if result.max_radius_deficit > PANCAKE_BOUNDARY_TOL {
		reasons += {.Non_Unit_Vector_Strength}
	}
	return reasons
}

pancake_optimize :: proc(
	model: ^Model,
	problem: ^Problem,
	fallback: Pancake_Fallback = .Spine,
	workspace: ^Workspace = nil,
) -> Solution {
	owned_workspace: Workspace
	work := workspace
	if work == nil {
		owned_workspace = make_workspace(model.n)
		work = &owned_workspace
	}
	defer {
		if workspace == nil do destroy_workspace(&owned_workspace)
	}

	relaxation := pancake_solve(problem)
	defer destroy_pancake_result(&relaxation)

	recovery_reasons :=
		pancake_collect_recovery_reasons(&relaxation)
	used_recovery := recovery_reasons != {}
	solution: Solution
	if !used_recovery {
		solution =
			build_pancake_solution(
				model,
				problem,
				relaxation.thetas[:],
				work,
			)
	} else {
		switch fallback {
		case .Spine:
			// Pancake has already selected the basin, so use the faster exact
			// structured solve for local recovery.
			solution =
				spine_optimize_from_thetas(
					model,
					problem,
					relaxation.thetas[:],
					work,
				)
		case .BFGS:
			solution =
				optimize_from_thetas_with_workspace(
					model,
					problem,
					relaxation.thetas[:],
					work,
				)
		case:
			solution =
				spine_optimize_from_thetas(
					model,
					problem,
					relaxation.thetas[:],
					work,
				)
		}
	}
	solution.pancake_used = true
	solution.pancake_used_recovery = used_recovery
	solution.pancake_recovery_reasons = recovery_reasons
	solution.pancake_dual_bound = relaxation.dual_bound
	return solution
}
