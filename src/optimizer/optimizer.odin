package optimizer

import "core:math"

EPS :: 1e-12
ACCEPT_TOL :: 1e-5
CONTINUOUS_TOL :: 5e-7
CONTINUOUS_MAX_OUTER :: 50

Cmp :: enum {
	Less,
	Equal,
}

Constraint_Result :: struct {
	source: string,
	margin: f64,
	cmp:    Cmp,
}

Model :: struct {
	// Require initialization
	n:      int,
	drag_x: [dynamic]f64,
	drag_z: [dynamic]f64,
	accel:  [dynamic]f64,

	// Compile later
	vx: [dynamic]Compiled_Expr,
	vz: [dynamic]Compiled_Expr,
	x:  [dynamic]Compiled_Expr,
	z:  [dynamic]Compiled_Expr,
}

Problem :: struct {
	n: int,
	// Assuming minimize
	objective: Compiled_Expr,
	// Constraints
	ineq_cons: [dynamic]Compiled_Expr,
	eq_cons:   [dynamic]Compiled_Expr,
}

assert_valid_objective :: proc(problem: ^Problem) {
	assert(
		pure_position_expr(problem.objective),
		"Optimization objective cannot contain theta terms",
	)
}

Solution :: struct {
	optimum:                       f64,
	continuous_globally_optimal: bool,
	pancake_used:                  bool,
	pancake_used_recovery:         bool,
	pancake_recovery_reasons:      Pancake_Recovery_Reasons,
	pancake_dual_bound:            f64,
	thetas:                        [dynamic]f64,
	xs:                            [dynamic]f64,
	zs:                            [dynamic]f64,
	constraints:                   [dynamic]Constraint_Result,
}

Workspace :: struct {
	temp_g:    [dynamic]f64,
	sin_cache: [dynamic]f64,
	cos_cache: [dynamic]f64,
}

make_workspace :: proc(n: int) -> Workspace {
	work := Workspace {
		temp_g    = make([dynamic]f64, n),
		sin_cache = make([dynamic]f64, n),
		cos_cache = make([dynamic]f64, n),
	}
	return work
}

destroy_workspace :: proc(work: ^Workspace) {
	delete(work.temp_g)
	delete(work.sin_cache)
	delete(work.cos_cache)
	work^ = {}
}

destroy_model :: proc(model: ^Model) {
	delete(model.drag_x)
	delete(model.drag_z)
	delete(model.accel)
	destroy_compiled_expr_array(&model.vx)
	destroy_compiled_expr_array(&model.vz)
	destroy_compiled_expr_array(&model.x)
	destroy_compiled_expr_array(&model.z)
	model^ = {}
}

destroy_problem :: proc(problem: ^Problem) {
	destroy_compiled_expr(&problem.objective)
	for i in 0..<len(problem.ineq_cons) do destroy_compiled_expr(&problem.ineq_cons[i])
	for i in 0..<len(problem.eq_cons) do destroy_compiled_expr(&problem.eq_cons[i])
	delete(problem.ineq_cons)
	delete(problem.eq_cons)
	problem^ = {}
}

destroy_solution :: proc(solution: ^Solution) {
	delete(solution.thetas)
	delete(solution.xs)
	delete(solution.zs)
	for result in solution.constraints do delete(result.source)
	delete(solution.constraints)
	solution^ = {}
}

compile_model :: proc(model: ^Model) {
	n := model.n
	destroy_compiled_expr_array(&model.vx)
	destroy_compiled_expr_array(&model.vz)
	destroy_compiled_expr_array(&model.x)
	destroy_compiled_expr_array(&model.z)
	model.vx = make([dynamic]Compiled_Expr, n)
	model.vz = make([dynamic]Compiled_Expr, n)
	model.x  = make([dynamic]Compiled_Expr, n)
	model.z  = make([dynamic]Compiled_Expr, n)
	for i in 0..<n {
		model.vx[i] = make_compiled_expr(n)
		model.vz[i] = make_compiled_expr(n)
		model.x[i]  = make_compiled_expr(n)
		model.z[i]  = make_compiled_expr(n)
	}

	// Generate Vx, Vz
	// Initial velocity is stored in accel[0].
	model.vx[0].sin_coeff[0] = model.accel[0]
	model.vz[0].cos_coeff[0] = model.accel[0]
	for t in 1..<n {
		// v[t] = drag[t-1] * v[t-1] + accel[t] * trig(F[t])
		add_scaled_expr(&model.vx[t], model.vx[t-1], model.drag_x[t-1])
		add_scaled_expr(&model.vz[t], model.vz[t-1], model.drag_z[t-1])
		model.vx[t].sin_coeff[t] = model.accel[t]
		model.vz[t].cos_coeff[t] = model.accel[t]
	}

	// Generate X, Z
	// pos[0] = 0, pos[t] = pos[t-1] + v[t-1]
	for t in 1..<n {
		add_scaled_expr(&model.x[t], model.x[t-1], 1)
		add_scaled_expr(&model.x[t], model.vx[t-1], 1)
		add_scaled_expr(&model.z[t], model.z[t-1], 1)
		add_scaled_expr(&model.z[t], model.vz[t-1], 1)
	}
}

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

Line_Search_Ctx :: struct {
	thetas:    []f64,
	problem:   ^Problem,
	lamb:      []f64,
	nu:        []f64,
	pen:       f64,
	step:      []f64,
	val:       f64,
	deri:      f64,
	work:      ^Workspace,
	temp_grad: []f64,
	trial:     []f64,
}

line_search_phi :: proc(ctx: ^Line_Search_Ctx, alpha: f64, grad_out: []f64) -> f64 {
	for i in 0..<ctx.problem.n {
		ctx.trial[i] = ctx.thetas[i]+alpha*ctx.step[i]
	}
	return compute_aug_l(grad_out, ctx.trial[:], ctx.problem, ctx.lamb, ctx.nu, ctx.pen, ctx.work)
}

polynomial_zoom_trial :: proc(
	lo, hi: f64,
	val_lo, val_hi: f64,
	deri_lo, deri_hi: f64,
) -> f64 {
	lower := min(lo, hi)
	upper := max(lo, hi)
	width := upper-lower
	safe_lower := lower+0.1*width
	safe_upper := upper-0.1*width
	if width <= 0 do return lo

	// Cubic Hermite interpolation from the values and derivatives at both
	// bracket endpoints.
	delta := hi-lo
	d1 := deri_lo+deri_hi-3*(val_lo-val_hi)/(lo-hi)
	radicand := d1*d1-deri_lo*deri_hi
	if radicand >= 0 {
		d2 := math.copy_sign(math.sqrt(radicand), delta)
		denominator := deri_hi-deri_lo+2*d2
		if math.abs(denominator) > EPS {
			trial := hi-delta*(deri_hi+d2-d1)/denominator
			if !math.is_nan(trial) &&
			   !math.is_inf(trial, 0) &&
			   trial >= safe_lower &&
			   trial <= safe_upper {
				return trial
			}
		}
	}

	// Quadratic interpolation using the low endpoint's derivative.
	denominator := 2*(val_hi-val_lo-deri_lo*delta)
	if math.abs(denominator) > EPS {
		trial := lo-deri_lo*delta*delta/denominator
		if !math.is_nan(trial) &&
		   !math.is_inf(trial, 0) &&
		   trial >= safe_lower &&
		   trial <= safe_upper {
			return trial
		}
	}

	return 0.5*(lo+hi)
}

line_search_zoom :: proc(
	ctx: ^Line_Search_Ctx,
	lo_in, hi_in: f64,
	val_hi_in, deri_hi_in: f64,
) -> f64 {
	c1 :: 1e-4
	c2 :: 0.9
	lo, hi := lo_in, hi_in
	val_lo := line_search_phi(ctx, lo, ctx.temp_grad[:])
	deri_lo := dot(ctx.temp_grad[:], ctx.step)
	val_hi := val_hi_in
	deri_hi := deri_hi_in
	max_zoom_iter :: 20
	for _ in 0..<max_zoom_iter {
		trial_alpha := polynomial_zoom_trial(
			lo,
			hi,
			val_lo,
			val_hi,
			deri_lo,
			deri_hi,
		)
		val_trial := line_search_phi(ctx, trial_alpha, ctx.temp_grad[:])
		deri_trial := dot(ctx.temp_grad[:], ctx.step)

		// Armijo fail or value increase: keep the low side of the bracket.
		if val_trial > ctx.val+c1*trial_alpha*ctx.deri ||
		   val_trial >= val_lo {
			hi = trial_alpha
			val_hi = val_trial
			deri_hi = deri_trial
		} else {
			if math.abs(deri_trial) <= -c2*ctx.deri {
				return trial_alpha
			}
			// Sufficient decrease but not curvature: advance the low side.
			lo = trial_alpha
			val_lo = val_trial
			deri_lo = deri_trial
		}
	}
	return 0.5*(lo+hi)
}

// Strong Wolfe
line_search :: proc(
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	step: []f64,
	val, deri: f64,
	work: ^Workspace,
	temp_grad, trial: []f64,
) -> f64 {
	assert(len(temp_grad) == problem.n)
	assert(len(trial) == problem.n)
	ctx := Line_Search_Ctx {
		thetas    = thetas,
		problem   = problem,
		lamb      = lamb,
		nu        = nu,
		pen       = pen,
		step      = step,
		val       = val,
		deri      = deri,
		work      = work,
		temp_grad = temp_grad,
		trial     = trial,
	}

	base := 0.0
	alpha := 1.0
	c1 :: 1e-4
	c2 :: 0.9
	val_prev := val

	max_bracket_iter :: 20
	for _ in 0..<max_bracket_iter {
		// Armijo fail -> zoom
		val_alpha := line_search_phi(&ctx, alpha, ctx.temp_grad[:])
		deri_alpha := dot(ctx.temp_grad[:], step)
		if val_alpha > val+c1*alpha*deri {
			return line_search_zoom(
				&ctx,
				base,
				alpha,
				val_alpha,
				deri_alpha,
			)
		}

		// Value increase -> zoom
		if base > 0 && val_alpha >= val_prev {
			return line_search_zoom(
				&ctx,
				base,
				alpha,
				val_alpha,
				deri_alpha,
			)
		}

		// Curvature satisfied -> accept alpha
		if math.abs(deri_alpha) <= -c2*deri {
			return alpha
		}

		// Derivative became positive -> zoom
		if deri_alpha >= 0 {
			return line_search_zoom(
				&ctx,
				base,
				alpha,
				val_alpha,
				deri_alpha,
			)
		}

		val_prev = val_alpha
		base = alpha
		alpha *= 2
	}
	return alpha
}

bfgs :: proc(
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	work: ^Workspace,
	max_inner: int = 80,
) {
	n := problem.n
	h := matrix_make(n)
	defer matrix_destroy(&h)
	matrix_set_identity(&h)

	grad_vec := make([dynamic]f64, n)
	defer delete(grad_vec)
	grad_new := make([dynamic]f64, n)
	defer delete(grad_new)
	line_search_grad := make([dynamic]f64, n)
	defer delete(line_search_grad)
	line_search_trial := make([dynamic]f64, n)
	defer delete(line_search_trial)
	val := compute_aug_l(grad_vec[:], thetas, problem, lamb, nu, pen, work)

	tar_grad :: 1e-6 // Gradient norm threshold; below? -> Leave Inner Loop
	for _ in 0..<max_inner {
		// [Inner Loop]: Optimize Augmented Lagrangian via BFGS
		if dot(grad_vec[:], grad_vec[:]) < tar_grad*tar_grad do break

		step := matrix_mul(&h, grad_vec[:])
		scale_vector(step[:], -1)

		deri := dot(grad_vec[:], step[:])
		if deri >= 0 {
			// Fallback to gradient descent
			set_scaled(step[:], grad_vec[:], -1)
			deri = dot(grad_vec[:], step[:])
		}

		alpha := line_search(thetas, problem, lamb, nu, pen, step[:], val, deri, work, line_search_grad[:], line_search_trial[:])
		scale_vector(step[:], alpha)
		// Modify/update thetas by step
		add_scaled(thetas, step[:], 1)

		val_new := compute_aug_l(grad_new[:], thetas, problem, lamb, nu, pen, work)
		curv := make([dynamic]f64, n)
		for i in 0..<n do curv[i] = grad_new[i]-grad_vec[i]

		a := dot(step[:], curv[:])
		ss := dot(step[:], step[:])
		cc := dot(curv[:], curv[:])
		// Reject non-positive curvature to preserve positive definiteness.
		// Tiny positive curvature is also too unreliable to use.
		eps :: 1e-12
		if a <= eps*math.sqrt(ss*cc) {
			copy(grad_vec[:], grad_new[:])
			val = val_new
			delete(curv)
			delete(step)
			continue
		}

		a = 1/a
		step_approx := matrix_mul(&h, curv[:])
		matrix_add_symmetrical_outer(&h, step[:], step_approx[:], -a)
		b := a*(1+a*dot(step_approx[:], curv[:]))
		matrix_add_outer_product(&h, step[:], step[:], b)

		copy(grad_vec[:], grad_new[:])
		val = val_new
		delete(step_approx)
		delete(curv)
		delete(step)
	}
}

constraint_violation :: proc(problem: ^Problem, thetas: []f64, work: ^Workspace) -> f64 {
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

solution_better :: proc(candidate: ^Solution, candidate_violation: f64, best: ^Solution, best_violation: f64) -> bool {
	candidate_feasible := candidate_violation < ACCEPT_TOL
	best_feasible := best_violation < ACCEPT_TOL
	if candidate_feasible != best_feasible do return candidate_feasible
	if candidate_feasible do return candidate.optimum < best.optimum
	if candidate_violation != best_violation do return candidate_violation < best_violation
	return candidate.optimum < best.optimum
}

optimize_thetas_with_workspace :: proc(
	model: ^Model,
	problem: ^Problem,
	thetas: [dynamic]f64,
	work: ^Workspace,
) -> Solution {
	assert_valid_objective(problem)
	n := model.n
	assert(len(thetas) == n)
	assert(len(work.temp_g) == n)
	assert(len(work.sin_cache) == n)
	assert(len(work.cos_cache) == n)
	lamb := make([dynamic]f64, len(problem.ineq_cons)) // "lambda" in inequality
	defer delete(lamb)
	nu := make([dynamic]f64, len(problem.eq_cons)) // "nu" in equality
	defer delete(nu)
	pen := 1.0 // Penalty for "A" in "ALM"

	max_vio := math.INF_F64
	prev_max_vio := max_vio

	for _ in 0..<CONTINUOUS_MAX_OUTER {
		// [Outer Loop]: Augmented Lagrangian Method
		bfgs(thetas[:], problem, lamb[:], nu[:], pen, work)

		// Update multipliers
		max_gi := 0.0
		max_hj := 0.0
		update_trig_cache(work, thetas[:])

		for i in 0..<len(problem.ineq_cons) {
			gi := eval(problem.ineq_cons[i], thetas[:], work)
			lamb[i] = max(0.0, lamb[i]+pen*gi)
			max_gi = max(max_gi, max(0.0, gi))
		}
		for j in 0..<len(problem.eq_cons) {
			hj := eval(problem.eq_cons[j], thetas[:], work)
			nu[j] += pen*hj
			max_hj = max(max_hj, math.abs(hj))
		}
		max_vio = max(max_gi, max_hj)

		// Check Feasibility
		if max_vio < CONTINUOUS_TOL do break

		// Increase penalty if violation didn't decrease enough
		// The exact parameters here are questionable but works fine at the moment
		if max_vio > 0.5 * prev_max_vio do pen *= 2
		prev_max_vio = max_vio
	}

	// Write solution
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

optimize_with_workspace :: proc(
	model: ^Model,
	problem: ^Problem,
	seed: f64,
	work: ^Workspace,
) -> Solution {
	thetas := make([dynamic]f64, model.n)
	for &theta in thetas do theta = seed
	return optimize_thetas_with_workspace(model, problem, thetas, work)
}

optimize_from_thetas_with_workspace :: proc(
	model: ^Model,
	problem: ^Problem,
	initial_thetas: []f64,
	work: ^Workspace,
) -> Solution {
	assert(len(initial_thetas) == model.n)
	thetas := make([dynamic]f64, model.n)
	copy(thetas[:], initial_thetas)
	return optimize_thetas_with_workspace(model, problem, thetas, work)
}

optimize :: proc(model: ^Model, problem: ^Problem, seed: f64 = math.PI/4) -> Solution {
	work := make_workspace(model.n)
	defer destroy_workspace(&work)
	return optimize_with_workspace(model, problem, seed, &work)
}

optimize_best_of :: proc(model: ^Model, problem: ^Problem, seeds: []f64) -> (Solution, int) {
	work := make_workspace(model.n)
	defer destroy_workspace(&work)
	if len(seeds) == 0 do return optimize_with_workspace(model, problem, 0, &work), -1

	best := optimize_with_workspace(model, problem, seeds[0], &work)
	best_violation := constraint_violation(problem, best.thetas[:], &work)
	best_index := 0

	for seed, index in seeds[1:] {
		candidate := optimize_with_workspace(model, problem, seed, &work)
		candidate_violation := constraint_violation(problem, candidate.thetas[:], &work)

		if solution_better(&candidate, candidate_violation, &best, best_violation) {
			destroy_solution(&best)
			best = candidate
			best_violation = candidate_violation
			best_index = index+1
		} else {
			destroy_solution(&candidate)
		}
	}

	return best, best_index
}
