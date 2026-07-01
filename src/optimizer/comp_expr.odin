package optimizer

import "core:math"

Compiled_Expr :: struct {
	constant:    f64,
	theta_coeff: [dynamic]f64,
	sin_coeff:   [dynamic]f64,
	cos_coeff:   [dynamic]f64,
}

make_compiled_expr :: proc(n: int) -> Compiled_Expr {
	return Compiled_Expr {
		theta_coeff = make([dynamic]f64, n),
		sin_coeff   = make([dynamic]f64, n),
		cos_coeff   = make([dynamic]f64, n),
	}
}

clone_compiled_expr :: proc(expr: Compiled_Expr) -> Compiled_Expr {
	out := make_compiled_expr(len(expr.theta_coeff))
	out.constant = expr.constant
	copy(out.theta_coeff[:], expr.theta_coeff[:])
	copy(out.sin_coeff[:], expr.sin_coeff[:])
	copy(out.cos_coeff[:], expr.cos_coeff[:])
	return out
}

destroy_compiled_expr :: proc(expr: ^Compiled_Expr) {
	delete(expr.theta_coeff)
	delete(expr.sin_coeff)
	delete(expr.cos_coeff)
	expr^ = {}
}

destroy_compiled_expr_array :: proc(exprs: ^[dynamic]Compiled_Expr) {
	for i in 0..<len(exprs^) do destroy_compiled_expr(&exprs^[i])
	delete(exprs^)
	exprs^ = nil
}

clone_compiled_expr_array :: proc(source: []Compiled_Expr) -> [dynamic]Compiled_Expr {
	out := make([dynamic]Compiled_Expr, len(source))
	for expr, i in source {
		out[i] = clone_compiled_expr(expr)
	}
	return out
}

zero_expr :: proc(expr: ^Compiled_Expr, n: int) {
	destroy_compiled_expr(expr)
	expr^ = make_compiled_expr(n)
}

update_trig_cache :: proc(work: ^Workspace, thetas: []f64) {
	for i in 0..<len(thetas) {
		work.sin_cache[i] = math.sin(thetas[i])
		work.cos_cache[i] = math.cos(thetas[i])
	}
}

add_scaled_expr :: proc(out: ^Compiled_Expr, source: Compiled_Expr, s: f64) {
	// out += s * in
	out.constant += s*source.constant
	for i in 0..<len(out.theta_coeff) {
		out.theta_coeff[i] += s*source.theta_coeff[i]
		out.sin_coeff[i]   += s*source.sin_coeff[i]
		out.cos_coeff[i]   += s*source.cos_coeff[i]
	}
}

eval :: proc(expr: Compiled_Expr, thetas: []f64, work: ^Workspace) -> f64 {
	val := expr.constant
	for i in 0..<len(thetas) {
		val += expr.theta_coeff[i]*thetas[i] +
		       expr.sin_coeff[i]*work.sin_cache[i] +
		       expr.cos_coeff[i]*work.cos_cache[i]
	}
	return val
}

eval_compiled_expr :: proc(expr: Compiled_Expr, thetas: []f64) -> f64 {
	work := Workspace {
		sin_cache = make([dynamic]f64, len(thetas)),
		cos_cache = make([dynamic]f64, len(thetas)),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	update_trig_cache(&work, thetas)
	return eval(expr, thetas, &work)
}

grad :: proc(expr: Compiled_Expr, thetas: []f64, out: []f64, work: ^Workspace) {
	for &value in out do value = 0
	for i in 0..<len(thetas) {
		out[i] = expr.theta_coeff[i] +
		         expr.sin_coeff[i]*work.cos_cache[i] -
		         expr.cos_coeff[i]*work.sin_cache[i]
	}
}
