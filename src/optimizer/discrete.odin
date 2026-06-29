package optimizer

import "core:math"

Discrete_Model :: struct {
	// Part II optimization
	n: int,
	init_v: f64,
	init_drag: f64,
	exact_movement: [dynamic]Exact_Movement,

	vx: [dynamic]Compiled_Expr,
	vz: [dynamic]Compiled_Expr,
	x:  [dynamic]Compiled_Expr,
	z:  [dynamic]Compiled_Expr,
}

Discrete_State :: struct {
	init_theta: f64,
	indices: [dynamic]u16,
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

discrete_angle_len :: proc(model: ^Discrete_Model) -> int {
	if model.n <= 2 do return 0
	return model.n-2
}

assert_discrete_state :: proc(model: ^Discrete_Model, state: Discrete_State) {
	assert(len(state.indices) == discrete_angle_len(model))
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
	work: ^Workspace,
) -> f64 {
	n := len(state.indices)+2
	assert(len(expr.theta_coeff) == n)
	assert_no_terminal_angle_dependency(expr)
	assert(len(work.sin_cache) == n)
	assert(len(work.cos_cache) == n)

	value := expr.constant +
	         expr.theta_coeff[0]*state.init_theta +
	         expr.sin_coeff[0]*work.sin_cache[0] +
	         expr.cos_coeff[0]*work.cos_cache[0]
	for index, i in state.indices {
		t := i+1
		value += expr.theta_coeff[t]*index_radians(index) +
		         expr.sin_coeff[t]*work.sin_cache[t] +
		         expr.cos_coeff[t]*work.cos_cache[t]
	}
	return value
}

Grade :: struct {
	objective: f64,
	ineq: [dynamic]f64,
	eq: [dynamic]f64,
	violation_sqr: f64,
	max_violation: f64,
	feasible: bool,
}

make_grade :: proc(p: ^Problem) -> Grade {
	return Grade {
		ineq = make([dynamic]f64, len(p.ineq_cons)),
		eq   = make([dynamic]f64, len(p.eq_cons)),
	}
}

destroy_grade :: proc(g: ^Grade) {
	delete(g.ineq)
	delete(g.eq)
	g^ = {}
}

polish :: proc(model: ^Discrete_Model, p: ^Problem, sol: ^Solution) {

	ilen := discrete_angle_len(model)

	state := Discrete_State {
		init_theta = sol.thetas[0],
		indices    = make([dynamic]u16, ilen),
	}
	defer delete(state.indices)

	// 1. Clamp the solution down to the lattices
	for i in 0..<ilen {
		state.indices[i] = index(f32(sol.thetas[i+1]))
	}

	work := Workspace {
		sin_cache = make([dynamic]f64, model.n),
		cos_cache = make([dynamic]f64, model.n),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	// 2. Grade the current "solution"

	grade := make_grade(p)
	defer destroy_grade(&grade)

	update_discrete_trig_cache(&work, state)
	grading(&grade, p, state, &work)

	_ = grade

	// Two modes:
	// Repair: no exact-feasible solution yet.
	// Polish: an exact-feasible incumbent exists; improve objective only.

	// 3. Greedy full 1-opt ±1 rounds
	//
	// For each round, grade every single-index ±1 neighbor.
	//
	// Case A: Repair mode + no fast-feasible candidates
	// -> Accept the best repair-grade candidate:
	//    violation_sqr, then max_violation, then objective.
	//
	// Case B: Repair mode + fast-feasible candidates exist
	// -> Exact-check fast-feasible candidates from best to worst.
	// -> Once exact-feasible, store incumbent, switch to Polish,
	//    and continue next round.
	// -> If none exact-feasible, accept the best repair-grade candidate.
	//
	// Case C: Polish mode
	// -> Exact-check fast-feasible objective-improving candidates
	//    from best to worst.
	// -> Accept only exact-feasible objective improvement.
	//
	// End condition:
	// -> No accepted 1-opt move this round, go to 2-opt phase.

	// 4. Greedy random 2-opt
	//
	// Randomly pick a pair.
	// Try signed versions of:
	//     (1,1), (1,2), (1,3), (2,1), (3,1)
	//
	// Repair mode:
	// -> Prefer exact-feasible candidate if found.
	// -> Otherwise accept best violation-reducing pair move.
	//
	// Polish mode:
	// -> Exact-check candidates that are fast-feasible and
	//    objective-improving.
	// -> Accept only exact-feasible objective improvement.
	//
	// End condition:
	// -> No improvement this round, or max attempts reached.

}

grading :: proc(out: ^Grade, p: ^Problem, state: Discrete_State, work: ^Workspace) {
	assert(len(out.ineq) == len(p.ineq_cons))
	assert(len(out.eq) == len(p.eq_cons))

	out.objective = eval_discrete_expr(p.objective, state, work)
	out.violation_sqr = 0
	out.max_violation = 0
	out.feasible = true

	for con, i in p.ineq_cons {
		value := eval_discrete_expr(con, state, work)
		out.ineq[i] = value

		violation := max(0, value)
		out.violation_sqr += violation*violation
		out.max_violation = max(out.max_violation, violation)
	}

	for con, i in p.eq_cons {
		value := eval_discrete_expr(con, state, work)
		out.eq[i] = value

		violation := math.abs(value)
		out.violation_sqr += violation*violation
		out.max_violation = max(out.max_violation, violation)
	}

	out.feasible = out.max_violation <= CONSTRAINT_TOLERANCE
}
