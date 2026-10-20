package optimizer_test

import "core:math"
import "core:testing"
import opt "../../src/optimizer"

@(test)
modern_exact_movement_matches_mothmotica_reference :: proc(t: ^testing.T) {
	// Reference positions from Mothmotica's moveXZModern at yaw 67.815f.
	expected := [?][2]f64 {
		{0.090743791479860086, 0.037007635673048156},
		{0.050404451396312479, 0.11983068948750591},
		{0.023966134807011468, -0.010080888979308044},
		{0.30502209430699445, 0.025121333096180205},
	}
	model := opt.Discrete_Model {
		minecraft_version = .V1_21_3,
		n = 3,
		n_unique = 2,
		facing_map = make([dynamic]int, 3),
		exact_movement = make([dynamic]opt.Exact_Movement, 1),
	}
	defer opt.destroy_discrete_model(&model)
	model.facing_map[1], model.facing_map[2] = 1, 1
	state := opt.Discrete_State{indices = make([dynamic]u16, 1)}
	defer opt.destroy_discrete_state(&state)
	state.indices[0] = 12345
	work := opt.make_exact_workspace(3)
	defer opt.destroy_exact_workspace(&work)
	testing.expect_value(t, f32(opt.index_to_facing(12345)), f32(67.815))
	for want, i in expected {
		strafe: f32 = 0 if i == 0 else (1 if i == 1 else -1)
		model.exact_movement[0] = opt.get_exact_movement(1, strafe, 0.6, i == 2, i != 0, false, i == 3, false, 0, 0, .V1_21_3)
		opt.exact_simulation(&model, state, work.xs[:], work.zs[:])
		testing.expect(t, math.abs(work.xs[2]-want[0]) < 1e-15)
		testing.expect(t, math.abs(work.zs[2]-want[1]) < 1e-15)
	}
}

@(test)
modern_fast_grades_use_modern_yaw_conversion :: proc(t: ^testing.T) {
	first_difference := -1
	for i in 0..<opt.SINE_TABLE_SIZE {
		angle := u16(i)
		if opt.sin_index(angle, .V1_8_9) != opt.sin_index(angle, .V1_21_3) || opt.cos_index(angle, .V1_8_9) != opt.cos_index(angle, .V1_21_3) {
			first_difference = i
			break
		}
	}
	testing.expect(t, first_difference >= 0)
	if first_difference < 0 do return
	model := opt.Discrete_Model{minecraft_version = .V1_21_3, n = 4, n_unique = 3}
	problem := opt.Problem{n = 2, objective = opt.make_compiled_expr(2)}
	defer opt.destroy_problem(&problem)
	problem.objective.sin_coeff[0], problem.objective.cos_coeff[0] = 2, -0.4
	problem.objective.sin_coeff[1], problem.objective.cos_coeff[1] = -0.3, 0.7
	state := opt.Discrete_State{indices = make([dynamic]u16, 2)}
	defer opt.destroy_discrete_state(&state)
	state.indices[0], state.indices[1] = u16(first_difference), 32768
	work := opt.make_workspace(2)
	defer opt.destroy_workspace(&work)
	baseline := opt.make_discrete_baseline(&model, &problem)
	defer opt.destroy_discrete_baseline(&baseline)
	opt.rebuild_discrete_baseline(&baseline, &model, &problem, state, &work, .Polish)
	testing.expect_value(t, work.sin_cache[0], f64(opt.sin_index(state.indices[0], .V1_21_3)))
	testing.expect_value(t, work.cos_cache[0], f64(opt.cos_index(state.indices[0], .V1_21_3)))
	move := opt.Two_Opt_Move{uticks = {0, 1}, deltas = {1, -1}}
	grade: opt.Two_Opt_Grade
	opt.grade_two_opt(&grade, &baseline, &model, &problem, &move, .Polish)
	state.indices[0] = opt.offset_index(state.indices[0], 1)
	state.indices[1] = opt.offset_index(state.indices[1], -1)
	opt.update_discrete_trig_cache(&work, state, .V1_21_3)
	expected := opt.eval_discrete_expr(problem.objective, state, &work)
	testing.expect(t, math.abs(baseline.objective+grade.objective_delta-expected) < 1e-12)
}
