package optimizer

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
