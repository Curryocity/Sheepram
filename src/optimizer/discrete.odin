package optimizer

import "core:math"

Discrete_Model :: struct {
	// Part II optimization
	n: int,
	init_v: f64,
	init_drag: f64,
	exact_movement: [dynamic]Exact_Movement,
	supported: bool,

	vx: [dynamic]Compiled_Expr,
	vz: [dynamic]Compiled_Expr,
	x:  [dynamic]Compiled_Expr,
	z:  [dynamic]Compiled_Expr,
}

Discrete_State :: struct {
	initial_theta: f64,
	angle_indices: []u16,
}

destroy_discrete_model :: proc(model: ^Discrete_Model) {
	delete(model.exact_movement)
	destroy_compiled_expr_array(&model.vx)
	destroy_compiled_expr_array(&model.vz)
	destroy_compiled_expr_array(&model.x)
	destroy_compiled_expr_array(&model.z)
	model^ = {}
}

copy_discrete_exprs :: proc(discrete: ^Discrete_Model, model: ^Model) {
	assert(discrete.n == model.n)
	destroy_compiled_expr_array(&discrete.vx)
	destroy_compiled_expr_array(&discrete.vz)
	destroy_compiled_expr_array(&discrete.x)
	destroy_compiled_expr_array(&discrete.z)
	discrete.vx = clone_compiled_expr_array(model.vx[:])
	discrete.vz = clone_compiled_expr_array(model.vz[:])
	discrete.x  = clone_compiled_expr_array(model.x[:])
	discrete.z  = clone_compiled_expr_array(model.z[:])
}

discrete_angle_count :: proc(model: ^Discrete_Model) -> int {
	if model.n <= 2 do return 0
	return model.n-2
}

assert_discrete_state :: proc(model: ^Discrete_Model, state: Discrete_State) {
	assert(model.supported, "Discrete optimization does not support mv(...)")
	assert(len(state.angle_indices) == discrete_angle_count(model))
}

assert_no_terminal_angle_dependency :: proc(expr: Compiled_Expr) {
	assert(len(expr.theta_coeff) == len(expr.sin_coeff))
	assert(len(expr.theta_coeff) == len(expr.cos_coeff))
	if len(expr.theta_coeff) == 0 do return

	last := len(expr.theta_coeff)-1
	assert(math.abs(expr.theta_coeff[last]) <= EPS, "Discrete expression depends on terminal theta")
	assert(math.abs(expr.sin_coeff[last]) <= EPS, "Discrete expression depends on terminal sin(theta)")
	assert(math.abs(expr.cos_coeff[last]) <= EPS, "Discrete expression depends on terminal cos(theta)")
}

eval_discrete_expr :: proc(
	expr: Compiled_Expr,
	state: Discrete_State,
) -> f64 {
	n := len(state.angle_indices)+2
	assert(len(expr.theta_coeff) == n)
	assert_no_terminal_angle_dependency(expr)
	work := Workspace {
		sin_cache = make([dynamic]f64, n),
		cos_cache = make([dynamic]f64, n),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	update_discrete_trig_cache(&work, state)

	value := expr.constant +
	         expr.theta_coeff[0]*state.initial_theta +
	         expr.sin_coeff[0]*work.sin_cache[0] +
	         expr.cos_coeff[0]*work.cos_cache[0]
	for index, i in state.angle_indices {
		t := i+1
		value += expr.theta_coeff[t]*index_radians(index) +
		         expr.sin_coeff[t]*work.sin_cache[t] +
		         expr.cos_coeff[t]*work.cos_cache[t]
	}
	return value
}

polish :: proc(discrete: ^Discrete_Model) {

}
