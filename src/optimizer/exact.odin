package optimizer

import "core:math"

Raw_Expr :: struct {
	constant: f64,
	x_coeff: [dynamic]f64,
	z_coeff: [dynamic]f64,
	f_coeff: [dynamic]f64,
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

Exact_Movement :: struct {
	drag_x: f64,
	drag_z: f64,
	forward: f32,
	strafe: f32,
	sprint_jump: bool,
}

get_exact_movement :: proc(
	w, a: f32,
	slip: f32,
	airborne, sprint, sneak, jump, stop: bool,
	speed, slow: u8,
) -> Exact_Movement {
	drag: f32 = 0.91

	accel: f64
	if airborne {
		accel = f64(f32(0.02))
	} else {
		drag *= slip
		accel = f64(f32(0.1))
		if speed > 0 do accel *= 1+f64(f32(0.2))*f64(speed)
		if slow > 0 do accel *= 1+f64(f32(-0.15))*f64(slow)
		if accel < 0 do accel = 0
	}

	// Sheepram intentional has user to do sprint delay manually
	if sprint {
		if airborne {
			accel += accel*0.3
		} else {
			accel *= 1+f64(f32(0.3))
		}
	}

	accel_f := f32(accel)
	if !airborne {
		accel_f *= f32(0.16277136)/(drag*drag*drag)
	}

	forward := w
	strafe := a
	if sneak {
		forward *= f32(0.3)
		strafe *= f32(0.3)
	}
	if stop {
		forward = 0
		strafe = 0
	}
	forward *= f32(0.98)
	strafe *= f32(0.98)

	dist2 := forward*forward+strafe*strafe
	if dist2 > 1 {
		accel_f /= f32(math.sqrt(f64(dist2)))
	}
	forward *= accel_f
	strafe *= accel_f

	return Exact_Movement {
		drag_x = f64(drag),
		drag_z = f64(drag),
		forward = forward,
		strafe = strafe,
		sprint_jump = sprint && jump,
	}
}

exact_simulation :: proc(
	discrete: ^Discrete_Model,
	state: Discrete_State,
	xs, zs: []f64,
) {
	assert_discrete_state(discrete, state)
	assert(len(discrete.exact_movement) >= discrete_angle_len(discrete))
	assert(len(xs) >= discrete.n)
	assert(len(zs) >= discrete.n)
	if discrete.n == 0 do return

	xs[0] = 0
	zs[0] = 0

	// Initial velocity remains continuous and is not part of the bucket search.
	vx := discrete.init_v * math.sin(state.init_theta)
	vz := discrete.init_v * math.cos(state.init_theta)

	for t in 1..<discrete.n {
		xs[t] = xs[t-1]+vx
		zs[t] = zs[t-1]+vz

		// Updating the outgoing terminal velocity cannot affect any recorded
		// position, so the final movement angle is deliberately not a search
		// variable.
		if t == discrete.n-1 do break

		if t == 1 {
			vx *= discrete.init_drag
			vz *= discrete.init_drag
		} else {
			previous := discrete.exact_movement[t-2]
			vx *= previous.drag_x
			vz *= previous.drag_z
		}

		m := discrete.exact_movement[t-1]
		angle_index := state.indices[t-1]
		sin_value := sin_index(angle_index)
		cos_value := cos_index(angle_index)

		if m.sprint_jump {
			vx += f64(sin_value*f32(0.2))
			vz += f64(cos_value*f32(0.2))
		}

		vx += f64(
			m.forward*sin_value-m.strafe*cos_value,
		)
		vz += f64(
			m.forward*cos_value+m.strafe*sin_value,
		)
	}
}

// TODO
exact_grading :: proc(out: ^Grade, p: ^Raw_Problem, state: Discrete_State) {
	assert(false, "exact_grading is not implemented yet")
}



