package optimizer

import "core:math"

snowpea_optimize :: proc(model: ^Model, problem: ^Problem, seed: f64 = math.PI / 4) -> Solution {
	n := model.n
	work := make_workspace(n)
	defer destroy_workspace(&work)

	thetas := make([dynamic]f64, n)
	for &theta in thetas do theta = seed


	lamb := make([dynamic]f64, len(problem.ineq_cons)) // "lambda" in inequality
	defer delete(lamb)
	nu := make([dynamic]f64, len(problem.eq_cons)) // "nu" in equality
	defer delete(nu)

	// effective multiplier
	eff_lamb := make([dynamic]f64, len(problem.ineq_cons))
	defer delete(eff_lamb)
	eff_nu := make([dynamic]f64, len(problem.eq_cons))
	defer delete(eff_nu)


	pen := 1.0 // Penalty for "A" in "ALM"

	max_vio := math.INF_F64
	prev_max_vio := max_vio
	update_effective_multipliers(thetas[:], problem, lamb[:], nu[:], pen, eff_lamb[:], eff_nu[:], &work)

	max_outer :: 100
	for _ in 0..<max_outer {
		// [Outer Loop]: Augmented Lagrangian Method
		frozen_solve(thetas[:], problem, eff_lamb[:], eff_nu[:], &work)

		// Update multipliers
		max_gi := 0.0
		max_hj := 0.0
		update_trig_cache(&work, thetas[:])

		for i in 0..<len(problem.ineq_cons) {
			gi := eval(problem.ineq_cons[i], thetas[:], &work)
			max_gi = max(max_gi, max(0.0, gi))

			lamb[i] = max(0.0, lamb[i] + pen * gi)
			eff_lamb[i] = max(0.0, lamb[i] + pen * gi)

		}
		for j in 0..<len(problem.eq_cons) {
			hj := eval(problem.eq_cons[j], thetas[:], &work)
			max_hj = max(max_hj, math.abs(hj))

			nu[j] += pen * hj
			eff_nu[j] = nu[j] + pen * hj

		}
		max_vio = max(max_gi, max_hj)

		// Check Feasibility
		if max_vio < ACCEPT_TOL do break

		// Increase penalty if violation didn't decrease enough
		// The exact parameters here are questionable but works fine at the moment
		if max_vio > 0.5 * prev_max_vio {
			pen *= 2
			update_effective_multipliers(thetas[:], problem, lamb[:], nu[:], pen, eff_lamb[:], eff_nu[:], &work)
		}
		prev_max_vio = max_vio
	}

	// Write solution
	solution := Solution {
		thetas = thetas,
		xs     = make([dynamic]f64, n),
		zs     = make([dynamic]f64, n),
	}
	update_trig_cache(&work, thetas[:])
	solution.optimum = eval(problem.objective, thetas[:], &work)
	for i in 0..<n {
		solution.xs[i] = eval(model.x[i], thetas[:], &work)
		solution.zs[i] = eval(model.z[i], thetas[:], &work)
	}

	return solution
}

update_effective_multipliers :: proc(
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	eff_lamb, eff_nu: []f64,
	work: ^Workspace,
) {
	assert(len(lamb) == len(problem.ineq_cons))
	assert(len(nu) == len(problem.eq_cons))
	assert(len(eff_lamb) == len(lamb))
	assert(len(eff_nu) == len(nu))

	update_trig_cache(work, thetas)
	for constraint, i in problem.ineq_cons {
		gi := eval(constraint, thetas, work)
		eff_lamb[i] = max(0.0, lamb[i] + pen * gi)
	}
	for constraint, j in problem.eq_cons {
		hj := eval(constraint, thetas, work)
		eff_nu[j] = nu[j] + pen * hj
	}
}

// Solving for ALM's gradient's zero while freezing the effective multiplier
// (the solution is closed form )
frozen_solve :: proc(
	thetas: []f64,
	problem: ^Problem,
    eff_lamb, eff_nu: []f64,
	work: ^Workspace,
) {
	n := problem.n

    resetGradient(work.gradient[:])
    addScaledGrad(work.gradient, problem.objective, 1)

    for i in 0..<len(problem.ineq_cons) {
        addScaledGrad(work.gradient, problem.ineq_cons[i], eff_lamb[i])
    }

    for i in 0..<len(problem.eq_cons) {
        addScaledGrad(work.gradient, problem.eq_cons[i], eff_nu[i])
    }

    for i in 0..<n {
        thetas[i] = solveTrigExpression(
            work.gradient[i].constant,
            work.gradient[i].sin_coeff[i],
            work.gradient[i].cos_coeff[i])
    }

}


addScaledGrad :: proc(out: [dynamic]Compiled_Expr, expr: Compiled_Expr, scalar: f64) {
	n := len(out)
	assert(len(expr.theta_coeff) == n)
	assert(len(expr.sin_coeff) == n)
	assert(len(expr.cos_coeff) == n)

	for i in 0..<n {
		assert(len(out[i].theta_coeff) == n)
		assert(len(out[i].sin_coeff) == n)
		assert(len(out[i].cos_coeff) == n)

		// d/dtheta_i (a * theta_i + b * sin(theta_i) + c * cos(theta_i))
		// = a + b * cos(theta_i) - c * sin(theta_i)
		out[i].constant     += scalar * expr.theta_coeff[i]
		out[i].cos_coeff[i] += scalar * expr.sin_coeff[i]
		out[i].sin_coeff[i] -= scalar * expr.cos_coeff[i]
	}
}

resetGradient :: proc(gradient: []Compiled_Expr) {
	for &expr in gradient {
		expr.constant = 0
		for &value in expr.theta_coeff do value = 0
		for &value in expr.sin_coeff do value = 0
		for &value in expr.cos_coeff do value = 0
	}
}


// Minimizing a * x - b * cos(x) + c * sin(x) on [-pi, pi].
// Stationary Equation: a + b * sin(x) + c * cos(x) = 0
solveTrigExpression :: proc(a, b, c: f64) -> f64 {

	eval_obj := proc(x, a, b, c: f64) -> f64 {
		return a * x - b * math.cos(x) + c * math.sin(x)
	}

	r := math.sqrt(b * b + c * c)
    // if expression is nearly constant
	if r <= EPS && math.abs(a) <= EPS do return 0

	// try -pi & pi boundaries, in case obj is monotonic
	best_x := -math.PI
	best_value := eval_obj(best_x, a, b, c)
	upper_value := eval_obj(math.PI, a, b, c)
	if upper_value < best_value {
		best_x = math.PI
		best_value = upper_value
	}

	// A real root of the stationary equation exists only when a^2 <= b^2 + c^2
    if r > EPS && math.abs(a) <= r + EPS {
		q := clamp(-a / r, -1.0, 1.0)
		phase := math.atan2(c, b)

		// math.asin() branch has second derivative >= 0 -> must be local-minimum
		root := math.asin(q) - phase
		root = math.mod(root + math.PI, 2 * math.PI)
		if root < 0 do root += 2 * math.PI
		root -= math.PI

		root_value := eval_obj(root, a, b, c)
		if root_value < best_value do best_x = root
	}

	return best_x
}
