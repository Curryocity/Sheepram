package optimizer

import "core:math"

Raw_Expr :: struct {
	constant: f64,
	x_coeff: [dynamic]f64,
	z_coeff: [dynamic]f64,
	f_coeff: [dynamic]f64,
	// Unit: degree
}

Raw_Problem :: struct {
	n: int,
	objective: Raw_Expr,
	ineq_cons: [dynamic]Raw_Expr,
	eq_cons:   [dynamic]Raw_Expr,
}

Raw_Constraint :: struct {
	// Enforce lhs < 0 or lhs = 0
	lhs:    Raw_Expr,
	cmp:    Cmp,
	source: string,
}

make_raw_expr :: proc(n: int) -> Raw_Expr {
	return Raw_Expr {
		x_coeff = make([dynamic]f64, n),
		z_coeff = make([dynamic]f64, n),
		f_coeff = make([dynamic]f64, n),
	}
}

clone_raw_expr :: proc(expr: Raw_Expr) -> Raw_Expr {
	out := make_raw_expr(len(expr.x_coeff))
	out.constant = expr.constant
	copy(out.x_coeff[:], expr.x_coeff[:])
	copy(out.z_coeff[:], expr.z_coeff[:])
	copy(out.f_coeff[:], expr.f_coeff[:])
	return out
}

destroy_raw_expr :: proc(expr: ^Raw_Expr) {
	delete(expr.x_coeff)
	delete(expr.z_coeff)
	delete(expr.f_coeff)
	expr^ = {}
}

destroy_raw_expr_array :: proc(exprs: ^[dynamic]Raw_Expr) {
	for i in 0..<len(exprs^) do destroy_raw_expr(&exprs^[i])
	delete(exprs^)
	exprs^ = nil
}

destroy_raw_problem :: proc(problem: ^Raw_Problem) {
	destroy_raw_expr(&problem.objective)
	destroy_raw_expr_array(&problem.ineq_cons)
	destroy_raw_expr_array(&problem.eq_cons)
	problem^ = {}
}

add_scaled_raw_expr :: proc(out: ^Raw_Expr, source: Raw_Expr, s: f64) {
	assert(len(out.x_coeff) == len(source.x_coeff))
	assert(len(out.z_coeff) == len(source.z_coeff))
	assert(len(out.f_coeff) == len(source.f_coeff))

	out.constant += s*source.constant
	for i in 0..<len(out.x_coeff) {
		out.x_coeff[i] += s*source.x_coeff[i]
		out.z_coeff[i] += s*source.z_coeff[i]
		out.f_coeff[i] += s*source.f_coeff[i]
	}
}

scale_raw_expr :: proc(expr: Raw_Expr, scalar: f64) -> Raw_Expr {
	out := clone_raw_expr(expr)
	out.constant *= scalar
	for i in 0..<len(out.x_coeff) {
		out.x_coeff[i] *= scalar
		out.z_coeff[i] *= scalar
		out.f_coeff[i] *= scalar
	}
	return out
}

is_constant :: proc(expr: Raw_Expr) -> bool {
	for i in 0..<len(expr.f_coeff) {
		if math.abs(expr.f_coeff[i]) > EPS do return false
		if math.abs(expr.x_coeff[i])   > EPS do return false
		if math.abs(expr.z_coeff[i])   > EPS do return false
	}
	return true
}

combine_raw_expr :: proc(lhs, rhs: Raw_Expr, operator: string) -> (Raw_Expr, string) {
	assert(len(lhs.x_coeff) == len(rhs.x_coeff))
	assert(len(lhs.z_coeff) == len(rhs.z_coeff))
	assert(len(lhs.f_coeff) == len(rhs.f_coeff))

	if operator == "+" || operator == "-" {
		sign_rhs := 1.0 if operator == "+" else -1.0
		out := clone_raw_expr(lhs)
		out.constant += sign_rhs*rhs.constant
		for i in 0..<len(out.x_coeff) {
			out.x_coeff[i] += sign_rhs*rhs.x_coeff[i]
			out.z_coeff[i] += sign_rhs*rhs.z_coeff[i]
			out.f_coeff[i] += sign_rhs*rhs.f_coeff[i]
		}
		for i in 0..<len(out.x_coeff) {
			if math.abs(out.x_coeff[i]) < EPS do out.x_coeff[i] = 0
			if math.abs(out.z_coeff[i]) < EPS do out.z_coeff[i] = 0
			if math.abs(out.f_coeff[i]) < EPS do out.f_coeff[i] = 0
		}
		if math.abs(out.constant) < EPS do out.constant = 0
		return out, ""
	}

	if operator == "*" {
		lhs_constant := is_constant(lhs)
		rhs_constant := is_constant(rhs)
		if lhs_constant && rhs_constant {
			out := make_raw_expr(len(lhs.x_coeff))
			out.constant = lhs.constant*rhs.constant
			return out, ""
		}
		if lhs_constant do return scale_raw_expr(rhs, lhs.constant), ""
		if rhs_constant do return scale_raw_expr(lhs, rhs.constant), ""
		return {}, "Nonlinear multiplication is not allowed"
	}

	if operator == "/" {
		if !is_constant(rhs) {
			return {}, "Division by non-constant is not allowed"
		}
		if rhs.constant == 0 {
			return {}, "Division by zero"
		}
		return scale_raw_expr(lhs, 1/rhs.constant), ""
	}

	return {}, "Unknown operator"
}


eval_raw_expr :: proc(
	expr: Raw_Expr,
	state: Discrete_State,
	xs, zs: []f64,
) -> f64 {
	n := len(expr.x_coeff)
	assert(len(expr.z_coeff) == n)
	assert(len(expr.f_coeff) == n)
	assert(len(xs) >= n)
	assert(len(zs) >= n)
	assert(len(state.indices)+2 == n)

	if n > 0 {
		terminal := n-1
		assert(
			math.abs(expr.f_coeff[terminal]) <= EPS,
			"Exact expression depends on terminal F",
		)
	}

	value := expr.constant
	for t in 0..<n {
		value += expr.x_coeff[t]*xs[t] +
		         expr.z_coeff[t]*zs[t]

		if t != n-1 {
			value += expr.f_coeff[t]*discrete_state_deg(state, t)
		}
	}
	return value
}

make_raw_problem :: proc(objective: Raw_Expr, constraints: []Raw_Constraint, n: int) -> Raw_Problem {

	problem := Raw_Problem {
		n         = n,
		objective = clone_raw_expr(objective),
		ineq_cons = make([dynamic]Raw_Expr, 0, len(constraints)),
		eq_cons   = make([dynamic]Raw_Expr, 0, len(constraints)),
	}

	for constraint in constraints {

		if constraint.cmp == .Equal {
			append(&problem.eq_cons, clone_raw_expr(constraint.lhs))
		} else {
			append(&problem.ineq_cons, clone_raw_expr(constraint.lhs))
		}
	}

	return problem
}

reduce_problem :: proc(rp: ^Raw_Problem, model: Model, angle_offset: []f64) -> Problem {
	assert(rp.n == model.n, "Raw problem/model dimension mismatch")
	assert(len(angle_offset) >= model.n, "Angle offset dimension mismatch")

	problem := Problem {
		n         = model.n,
		objective = reduce_expr(rp.objective, model, angle_offset),
		ineq_cons = make([dynamic]Compiled_Expr, 0, len(rp.ineq_cons)),
		eq_cons   = make([dynamic]Compiled_Expr, 0, len(rp.eq_cons)),
	}

	for con in rp.ineq_cons {
		append(&problem.ineq_cons, reduce_expr(con, model, angle_offset))
	}
	for con in rp.eq_cons {
		append(&problem.eq_cons, reduce_expr(con, model, angle_offset))
	}

	return problem
}

reduce_expr :: proc(expr: Raw_Expr, model: Model, angle_offset: []f64) -> Compiled_Expr {
	assert(len(expr.x_coeff) == model.n, "Raw expression X dimension mismatch")
	assert(len(expr.z_coeff) == model.n, "Raw expression Z dimension mismatch")
	assert(len(expr.f_coeff) == model.n, "Raw expression F dimension mismatch")
	assert(len(model.x) == model.n, "Model X expressions are not compiled")
	assert(len(model.z) == model.n, "Model Z expressions are not compiled")
	assert(len(angle_offset) >= model.n, "Angle offset dimension mismatch")

	out := make_compiled_expr(model.n)
	out.constant = expr.constant

	for t in 0..<model.n {
		if expr.x_coeff[t] != 0 do add_scaled_expr(&out, model.x[t], expr.x_coeff[t])
		if expr.z_coeff[t] != 0 do add_scaled_expr(&out, model.z[t], expr.z_coeff[t])

		// Raw F is player facing in degrees:
		//   facing = movement_theta*180/pi - angle_offset
		out.theta_coeff[t] += expr.f_coeff[t] * 180.0 / math.PI
		out.constant -= expr.f_coeff[t] * angle_offset[t]
	}

	return out
}
