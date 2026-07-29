package optimizer

import "core:math"

EPS :: 1e-12
ACCEPT_TOL :: 1e-5
CONTINUOUS_TOL :: 5e-7
CONTINUOUS_MAX_OUTER :: 50

compute_aug_l :: proc(
	g_out: []f64,
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	work: ^Workspace,
) -> f64 {
	// Evaluates the augmented Lagrangian and optionally gradient.
	compute_gradient := len(g_out) > 0
	assert(!compute_gradient || len(g_out) == problem.n)
	update_trig_cache(work, thetas)

	value := eval(problem.objective, thetas, work)
	if compute_gradient do grad(problem.objective, thetas, g_out, work)

	for i in 0..<len(problem.ineq_cons) {
		ineq := problem.ineq_cons[i]
		v_ineq := eval(ineq, thetas, work)

		t := max(0.0, lamb[i]+v_ineq*pen)
		value += 0.5/pen*(t*t-lamb[i]*lamb[i])
		if compute_gradient {
			grad(ineq, thetas, work.temp_g[:], work)
			add_scaled(g_out, work.temp_g[:], t)
		}
	}

	for j in 0..<len(problem.eq_cons) {
		eq := problem.eq_cons[j]
		v_eq := eval(eq, thetas, work)

		value += nu[j]*v_eq
		value += 0.5*pen*v_eq*v_eq
		if compute_gradient {
			grad(eq, thetas, work.temp_g[:], work)
			add_scaled(g_out, work.temp_g[:], nu[j]+pen*v_eq)
		}
	}
	return value
}

constraint_violation :: proc(
	problem: ^Problem,
	thetas: []f64,
	work: ^Workspace,
) -> f64 {
	update_trig_cache(work, thetas)

	max_gi := 0.0
	max_hj := 0.0
	for con in problem.ineq_cons {
		gi := eval(con, thetas, work)
		max_gi = max(max_gi, max(0.0, gi))
	}
	for con in problem.eq_cons {
		hj := eval(con, thetas, work)
		max_hj = max(max_hj, math.abs(hj))
	}
	return max(max_gi, max_hj)
}

solution_better :: proc(
	candidate: ^Solution,
	candidate_violation: f64,
	best: ^Solution,
	best_violation: f64,
) -> bool {
	candidate_feasible := candidate_violation < ACCEPT_TOL
	best_feasible := best_violation < ACCEPT_TOL
	if candidate_feasible != best_feasible do return candidate_feasible
	if candidate_feasible do return candidate.optimum < best.optimum
	if candidate_violation != best_violation {
		return candidate_violation < best_violation
	}
	return candidate.optimum < best.optimum
}
