package optimizer

import "core:math"


Exact_Movement :: struct {
	drag_x: f64,
	drag_z: f64,
	forward: f32,
	strafe: f32,
	sprint_jump: bool,
}

Exact_Workspace :: struct {
	xs: [dynamic]f64,
	zs: [dynamic]f64,
}

make_exact_workspace :: proc(n: int) -> Exact_Workspace {
	return Exact_Workspace {
		xs = make([dynamic]f64, n),
		zs = make([dynamic]f64, n),
	}
}

destroy_exact_workspace :: proc(work: ^Exact_Workspace) {
	delete(work.xs)
	delete(work.zs)
	work^ = {}
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
	model: ^Discrete_Model,
	state: Discrete_State,
	xs, zs: []f64,
) {
	assert_discrete_state(model, state)
	assert(len(model.exact_movement) >= discrete_angle_len(model))
	assert(len(xs) >= model.n)
	assert(len(zs) >= model.n)
	if model.n == 0 do return

	xs[0] = 0
	zs[0] = 0

	// Initial velocity remains continuous and is not part of the bucket search.
	vx := model.init_v * math.sin(state.init_theta)
	vz := model.init_v * math.cos(state.init_theta)

	for t in 1..<model.n {
		xs[t] = xs[t-1]+vx
		zs[t] = zs[t-1]+vz

		// Updating the outgoing terminal velocity cannot affect any recorded
		// position, so the final movement angle is deliberately not a search
		// variable.
		if t == model.n-1 do break

		if t == 1 {
			vx *= model.init_drag
			vz *= model.init_drag
		} else {
			previous := model.exact_movement[t-2]
			vx *= previous.drag_x
			vz *= previous.drag_z
		}

		m := model.exact_movement[t-1]
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

exact_grading :: proc(
	out: ^Grade,
	model: ^Discrete_Model,
	p: ^Raw_Problem,
	state: Discrete_State,
	work: ^Exact_Workspace,
) {
	assert(len(work.xs) >= model.n)
	assert(len(work.zs) >= model.n)

	exact_simulation(model, state, work.xs[:], work.zs[:])

	out.objective = eval_raw_expr(p.objective, state, work.xs[:], work.zs[:])

	out.violation_sqr = 0
	out.feasible = true

	for con in p.ineq_cons {
		value := eval_raw_expr(con, state, work.xs[:], work.zs[:])

		violation := max(0, value)
		out.violation_sqr += violation*violation
		if violation > CONSTRAINT_TOLERANCE do out.feasible = false
	}

	for con in p.eq_cons {
		value := eval_raw_expr(con, state, work.xs[:], work.zs[:])

		violation := math.abs(value)
		out.violation_sqr += violation*violation
		if violation > CONSTRAINT_TOLERANCE do out.feasible = false
	}
}


