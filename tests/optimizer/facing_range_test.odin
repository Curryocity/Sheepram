package optimizer_test

import "core:math"
import "core:testing"
import opt "../../src/optimizer"

@(test)
facing_tables_match_actual_yaw_in_each_range :: proc(t: ^testing.T) {
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for midpoint in ([5]f64{0, 180, 37.12345, 1800, -1800}) {
			table := opt.make_facing_table(midpoint, version)
			for i in 0..<opt.SINE_TABLE_SIZE {
				idx := u16(i)
				facing := opt.index_to_facing(idx, table)
				testing.expect(t, facing >= midpoint-180 && facing < midpoint+180)
				yaw := f32(facing)
				testing.expect(t, f64(yaw) >= midpoint-180 && f64(yaw) < midpoint+180)
				rad := yaw*f32(0.017453292) if version == .V1_21_3 else yaw*f32(math.PI)/f32(180)
				s := int(rad*f32(10430.378))&65535
				c := int(rad*f32(10430.378)+f32(16384))&65535
				testing.expect_value(t, opt.sin_index(idx, version, table), f32(math.sin(f64(s)*2*math.PI/65536)))
				testing.expect_value(t, opt.cos_index(idx, version, table), f32(math.sin(f64(c)*2*math.PI/65536)))
			}
			free(table)
		}
	}
}

@(test)
range_bounds_only_limit_facings_referenced_by_constraints :: proc(t: ^testing.T) {
	model := opt.Model {
		facing_range_midpoint = 180,
		n = 4,
		n_unique = 5,
		init_v_range = true,
		drag_x = make([dynamic]f64, 4),
		drag_z = make([dynamic]f64, 4),
		accel = make([dynamic]f64, 4),
		angle_offset = make([dynamic]f64, 4),
		facing_map = make([dynamic]int, 4),
	}
	defer opt.destroy_model(&model)
	copy(model.facing_map[:], []int{0, 2, 3, 4})
	opt.compile_model(&model)
	raw := opt.Raw_Problem{n = 4, objective = opt.make_raw_expr(4)}
	defer opt.destroy_raw_problem(&raw)
	turn := opt.make_raw_expr(4)
	turn.f_coeff[1], turn.f_coeff[2] = -1, 1
	append(&raw.ineq_cons, turn)
	problem := opt.reduce_problem(&raw, &model)
	defer opt.destroy_problem(&problem)
	testing.expect_value(t, len(problem.ineq_cons), 5)
	testing.expect(t, opt.facing_variable_constrained(&problem, 2) && opt.facing_variable_constrained(&problem, 3))
	for i in ([3]int{0, 1, 4}) do testing.expect(t, !opt.facing_variable_constrained(&problem, i))
	for midpoint in ([3]f64{0, 180, 37.12345}) {
		lower := (midpoint-180)*math.PI/180
		upper := (midpoint+180)*math.PI/180
		testing.expect_value(t, opt.wrap_radians(upper, midpoint), lower)
		testing.expect_value(t, opt.wrap_radians(lower, midpoint), lower)
	}
	testing.expect_value(t, opt.wrap_facing(-179, 180), 181)
	testing.expect_value(t, opt.wrap_facing(181, 0), -179)
}

@(test)
custom_range_fast_grades_and_exact_replay_use_the_same_facings :: proc(t: ^testing.T) {
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		model := opt.Discrete_Model {
			minecraft_version = version,
			facing_table = opt.make_facing_table(180, version),
			n = 4,
			n_unique = 3,
			facing_map = make([dynamic]int, 4),
			exact_movement = make([dynamic]opt.Exact_Movement, 2),
		}
		defer opt.destroy_discrete_model(&model)
		copy(model.facing_map[:], []int{0, 1, 2, 2})
		model.exact_movement[0] = opt.get_exact_movement(1, 1, 0.6, false, true, false, true, false, 0, 0, version)
		state := opt.Discrete_State{indices = make([dynamic]u16, 2)}
		defer opt.destroy_discrete_state(&state)
		state.indices[0], state.indices[1] = 65535, 0
		problem := opt.Problem{n = 2, objective = opt.make_compiled_expr(2)}
		defer opt.destroy_problem(&problem)
		problem.objective.theta_coeff[0], problem.objective.theta_coeff[1] = -1, 1
		problem.objective.sin_coeff[0], problem.objective.cos_coeff[1] = 0.7, -0.3
		constraint := opt.clone_compiled_expr(problem.objective)
		append(&problem.eq_cons, constraint)
		work := opt.make_workspace(2)
		defer opt.destroy_workspace(&work)
		baseline := opt.make_discrete_baseline(&model, &problem)
		defer opt.destroy_discrete_baseline(&baseline)
		opt.rebuild_discrete_baseline(&baseline, &model, &problem, state, &work, .Polish)
		move := opt.Two_Opt_Move{uticks = {0, 1}, deltas = {1, -1}}
		grade: opt.Two_Opt_Grade
		opt.grade_two_opt(&grade, &baseline, &model, &problem, &move, .Polish)
		state.indices[0], state.indices[1] = 0, 65535
		opt.update_discrete_trig_cache(&work, state, version, model.facing_table)
		expected := opt.eval_discrete_expr(problem.objective, state, &work, model.facing_table)
		testing.expect(t, math.abs(baseline.objective+grade.objective_delta-expected) < 1e-12)
		testing.expect(t, math.abs(grade.violation_sqr-expected*expected) < 1e-12)
		solution := opt.create_exact_solution(&model, state)
		defer opt.destroy_solution(&solution)
		testing.expect_value(t, solution.thetas[1], opt.index_to_facing(0, model.facing_table))
		sine := opt.sin_index(0, version, model.facing_table)
		cosine := opt.cos_index(0, version, model.facing_table)
		m := model.exact_movement[0]
		vx := f64(sine)*0.2+m.forward*f64(sine)-m.strafe*f64(cosine)
		vz := f64(cosine)*0.2+m.forward*f64(cosine)+m.strafe*f64(sine)
		if version == .V1_8_9 {
			vx = f64(sine*f32(0.2))+f64(f32(m.forward)*sine-f32(m.strafe)*cosine)
			vz = f64(cosine*f32(0.2))+f64(f32(m.forward)*cosine+f32(m.strafe)*sine)
		}
		testing.expect(t, math.abs(solution.xs[2]-vx) < 1e-15)
		testing.expect(t, math.abs(solution.zs[2]-vz) < 1e-15)
	}
}
