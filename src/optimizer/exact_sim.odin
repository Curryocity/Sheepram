package optimizer

import "core:math"

Minecraft_Version :: enum {
	V1_8_9,
	V1_21_3,
}

minecraft_version_name :: proc(version: Minecraft_Version) -> string {
	return "1.21.3" if version == .V1_21_3 else "1.8.9"
}

Exact_Movement :: struct {
	drag_x: f64,
	drag_z: f64,
	forward: f64,
	strafe: f64,
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
	version := Minecraft_Version.V1_8_9,
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

	// Sprint delays are resolved by the movement compiler
	if sprint {
		if airborne {
			accel += accel*0.3
		} else {
			accel *= 1+f64(f32(0.3))
		}
	}

	accel_f := f32(accel)
	if version == .V1_21_3 {
		if airborne {
			accel_f = f32(0.025999999) if sprint else f32(0.02)
		} else {
			accel_f *= f32(0.21600002)/(slip*slip*slip)
		}
	} else if !airborne {
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

	if version == .V1_21_3 {
		forward_d, strafe_d := f64(forward), f64(strafe)
		dist2 := forward_d*forward_d+strafe_d*strafe_d
		if dist2 < 1.0e-7 {
			forward_d, strafe_d = 0, 0
		} else {
			if dist2 > 1 {
				distance := math.sqrt(dist2)
				forward_d /= distance
				strafe_d /= distance
			}
			forward_d *= f64(accel_f)
			strafe_d *= f64(accel_f)
		}
		return {drag_x = f64(drag), drag_z = f64(drag), forward = forward_d, strafe = strafe_d, sprint_jump = sprint && jump}
	}

	dist2 := forward*forward+strafe*strafe
	if dist2 > 1 {
		accel_f /= f32(math.sqrt(f64(dist2)))
	}
	forward *= accel_f
	strafe *= accel_f

	return Exact_Movement {
		drag_x = f64(drag),
		drag_z = f64(drag),
		forward = f64(forward),
		strafe = f64(strafe),
		sprint_jump = sprint && jump,
	}
}

exact_simulation :: proc(
	model: ^Discrete_Model,
	state: Discrete_State,
	xs, zs: []f64,
) {
	assert_discrete_state(model, state)
	assert(len(model.exact_movement) >= model.n-2)
	assert(len(xs) >= model.n)
	assert(len(zs) >= model.n)
	if model.n == 0 do return
	n_init_angles := 2 if model.init_v_range else 1

	xs[0] = 0
	zs[0] = 0

	// Initial velocity remains continuous and is not part of the bucket search.
	vx := model.init_vx
	vz := model.init_vz

	for t in 1..<model.n {
		ut := model.facing_map[t]-n_init_angles

		xs[t] = xs[t-1]+vx
		zs[t] = zs[t-1]+vz

		// Terimal velocity doesn't affect the result
		if t == model.n-1 do break

		if t == 1 {
			vx *= model.init_drag_x
			vz *= model.init_drag_z
		} else {
			previous := model.exact_movement[t-2]
			vx *= previous.drag_x
			vz *= previous.drag_z
		}

		m := model.exact_movement[t-1]
		angle_index := state.indices[ut]
		sin_value := sin_index(angle_index, model.minecraft_version)
		cos_value := cos_index(angle_index, model.minecraft_version)

		if model.minecraft_version == .V1_21_3 {
			if m.sprint_jump {
				vx += f64(sin_value)*0.2
				vz += f64(cos_value)*0.2
			}
			vx += m.forward*f64(sin_value)-m.strafe*f64(cos_value)
			vz += m.forward*f64(cos_value)+m.strafe*f64(sin_value)
		} else {
			if m.sprint_jump {
				vx += f64(sin_value*f32(0.2))
				vz += f64(cos_value*f32(0.2))
			}
			vx += f64(f32(m.forward)*sin_value-f32(m.strafe)*cos_value)
			vz += f64(f32(m.forward)*cos_value+f32(m.strafe)*sin_value)
		}
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

	out.objective = eval_raw_expr(p.objective, state, work.xs[:], work.zs[:], model)

	out.violation_sqr = 0
	out.feasible = true

	for con in p.ineq_cons {
		value := eval_raw_expr(con, state, work.xs[:], work.zs[:], model)

		violation := max(0, value)
		out.violation_sqr += violation*violation
		if violation > 0 do out.feasible = false
	}

	for con in p.eq_cons {
		value := eval_raw_expr(con, state, work.xs[:], work.zs[:], model)

		violation := math.abs(value)
		out.violation_sqr += violation*violation
		if violation > ACCEPT_TOL do out.feasible = false
	}
}
