package optimizer

import "core:math"

EPS :: 1e-12
ACCEPT_TOL :: 1e-5

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

Solution :: struct {
	optimum: f64,
	thetas:  [dynamic]f64,
	xs:      [dynamic]f64,
	zs:      [dynamic]f64,
	constraints: [dynamic]Constraint_Result,
}

Workspace :: struct {
	temp_g:    [dynamic]f64,
	sin_cache: [dynamic]f64,
	cos_cache: [dynamic]f64,
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
	// Evaluates Augmented Lagrangian's value & gradient
	update_trig_cache(work, thetas)

	value := eval(problem.objective, thetas, work)
	grad(problem.objective, thetas, g_out, work)

	for i in 0..<len(problem.ineq_cons) {
		ineq := problem.ineq_cons[i]
		v_ineq := eval(ineq, thetas, work)
		grad(ineq, thetas, work.temp_g[:], work)

		t := max(0.0, lamb[i]+v_ineq*pen)
		value += 0.5/pen*(t*t-lamb[i]*lamb[i])
		add_scaled(g_out, work.temp_g[:], t)
	}

	for j in 0..<len(problem.eq_cons) {
		eq := problem.eq_cons[j]
		v_eq := eval(eq, thetas, work)
		grad(eq, thetas, work.temp_g[:], work)

		value += nu[j]*v_eq
		value += 0.5*pen*v_eq*v_eq
		add_scaled(g_out, work.temp_g[:], nu[j]+pen*v_eq)
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
	temp_grad: [dynamic]f64,
	trial:     [dynamic]f64,
}

line_search_phi :: proc(ctx: ^Line_Search_Ctx, alpha: f64, grad_out: []f64) -> f64 {
	for i in 0..<ctx.problem.n {
		ctx.trial[i] = ctx.thetas[i]+alpha*ctx.step[i]
	}
	return compute_aug_l(
		grad_out,
		ctx.trial[:],
		ctx.problem,
		ctx.lamb,
		ctx.nu,
		ctx.pen,
		ctx.work,
	)
}

line_search_zoom :: proc(ctx: ^Line_Search_Ctx, lo_in, hi_in: f64) -> f64 {
	c1 :: 1e-4
	c2 :: 0.9
	lo, hi := lo_in, hi_in
	val_lo := line_search_phi(ctx, lo, ctx.temp_grad[:])
	max_zoom_iter :: 20
	for _ in 0..<max_zoom_iter {
		mid := 0.5*(lo+hi)
		val_mid := line_search_phi(ctx, mid, ctx.temp_grad[:])

		// Armijo fail or Value increase -> Step too large -> zoom(lo, mid)
		if val_mid > ctx.val+c1*mid*ctx.deri || val_mid >= val_lo {
			hi = mid
		} else {
			// Curvature satisfied -> accept mid
			deri_mid := dot(ctx.temp_grad[:], ctx.step)
			if math.abs(deri_mid) <= -c2*ctx.deri do return mid
			// zoom(mid, hi)
			lo = mid
			val_lo = val_mid
		}
	}
	return 0.5*(lo+hi)
}

// Strong Wolfe, weaker version of scipy/optimize/_line_search: "scalar_search_wolfe2()"
line_search :: proc(
	thetas: []f64,
	problem: ^Problem,
	lamb, nu: []f64,
	pen: f64,
	step: []f64,
	val, deri: f64,
	work: ^Workspace,
) -> f64 {
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
		temp_grad = make([dynamic]f64, problem.n),
		trial     = make([dynamic]f64, problem.n),
	}
	defer delete(ctx.temp_grad)
	defer delete(ctx.trial)

	base := 0.0
	alpha := 1.0
	c1 :: 1e-4
	c2 :: 0.9
	val_prev := val

	max_bracket_iter :: 20
	for _ in 0..<max_bracket_iter {
		// Armijo fail -> zoom
		val_alpha := line_search_phi(&ctx, alpha, ctx.temp_grad[:])
		if val_alpha > val+c1*alpha*deri do return line_search_zoom(&ctx, base, alpha)

		// Value increase -> zoom
		if base > 0 && val_alpha >= val_prev do return line_search_zoom(&ctx, base, alpha)

		// Curvature satisfied -> accept alpha
		deri_alpha := dot(ctx.temp_grad[:], step)
		if math.abs(deri_alpha) <= -c2*deri do return alpha

		// Derivative became positive -> zoom
		if deri_alpha >= 0 do return line_search_zoom(&ctx, base, alpha)

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
) {
	n := problem.n
	h := matrix_make(n)
	defer matrix_destroy(&h)
	matrix_set_identity(&h)

	grad_vec := make([dynamic]f64, n)
	defer delete(grad_vec)
	grad_new := make([dynamic]f64, n)
	defer delete(grad_new)
	val := compute_aug_l(grad_vec[:], thetas, problem, lamb, nu, pen, work)

	tar_grad :: 1e-6 // Gradient norm threshold; below? -> Leave Inner Loop
	max_inner :: 80
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

		alpha := line_search(thetas, problem, lamb, nu, pen, step[:], val, deri, work)
		scale_vector(step[:], alpha)
		// Modify/update thetas by step
		add_scaled(thetas, step[:], 1)

		val_new := compute_aug_l(grad_new[:], thetas, problem, lamb, nu, pen, work)
		curv := make([dynamic]f64, n)
		for i in 0..<n do curv[i] = grad_new[i]-grad_vec[i]

		a := dot(step[:], curv[:])
		ss := dot(step[:], step[:])
		cc := dot(curv[:], curv[:])
		// a < 0 -> violate positive definiteness
		// cos(angle between step and curv) <= 1e-12 -> curvature information is unreliable
		eps :: 1e-12
		if a*a <= (eps*eps)*ss*cc {
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

solution_violation :: proc(problem: ^Problem, solution: ^Solution) -> f64 {
	work := Workspace {
		temp_g    = make([dynamic]f64, problem.n),
		sin_cache = make([dynamic]f64, problem.n),
		cos_cache = make([dynamic]f64, problem.n),
	}
	defer delete(work.temp_g)
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)
	return constraint_violation(problem, solution.thetas[:], &work)
}

optimize :: proc(model: ^Model, problem: ^Problem, seed: f64 = math.PI/4) -> Solution {
	n := model.n
	work := Workspace {
		temp_g    = make([dynamic]f64, n),
		sin_cache = make([dynamic]f64, n),
		cos_cache = make([dynamic]f64, n),
	}
	defer delete(work.temp_g)
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	thetas := make([dynamic]f64, n)
	for &theta in thetas do theta = seed
	lamb := make([dynamic]f64, len(problem.ineq_cons)) // "lambda" in inequality
	defer delete(lamb)
	nu := make([dynamic]f64, len(problem.eq_cons)) // "nu" in equality
	defer delete(nu)
	pen := 1.0 // Penalty for "A" in "ALM"

	max_vio := math.INF_F64
	prev_max_vio := max_vio

	max_outer :: 25
	for _ in 0..<max_outer {
		// [Outer Loop]: Augmented Lagrangian Method
		bfgs(thetas[:], problem, lamb[:], nu[:], pen, &work)

		// Update multipliers
		max_gi := 0.0
		max_hj := 0.0
		update_trig_cache(&work, thetas[:])

		for i in 0..<len(problem.ineq_cons) {
			gi := eval(problem.ineq_cons[i], thetas[:], &work)
			lamb[i] = max(0.0, lamb[i]+pen*gi)
			max_gi = max(max_gi, max(0.0, gi))
		}
		for j in 0..<len(problem.eq_cons) {
			hj := eval(problem.eq_cons[j], thetas[:], &work)
			nu[j] += pen*hj
			max_hj = max(max_hj, math.abs(hj))
		}
		max_vio = max(max_gi, max_hj)

		// Check Feasibility
		if max_vio < ACCEPT_TOL do break

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
	update_trig_cache(&work, thetas[:])
	solution.optimum = eval(problem.objective, thetas[:], &work)
	for i in 0..<n {
		solution.xs[i] = eval(model.x[i], thetas[:], &work)
		solution.zs[i] = eval(model.z[i], thetas[:], &work)
	}

	return solution
}

optimize_best_of :: proc(model: ^Model, problem: ^Problem, seeds: []f64) -> (Solution, int) {
	if len(seeds) == 0 do return optimize(model, problem, 0), -1

	best := optimize(model, problem, seeds[0])
	best_violation := solution_violation(problem, &best)
	best_index := 0

	for seed, index in seeds[1:] {
		candidate := optimize(model, problem, seed)
		candidate_violation := solution_violation(problem, &candidate)

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
