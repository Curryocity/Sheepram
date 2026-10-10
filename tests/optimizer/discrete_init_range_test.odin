package optimizer_test

import optimizer "../../src/optimizer"

import "core:math"
import "core:testing"

@(test)
discrete_indices_skip_all_initial_angles :: proc(t: ^testing.T) {
	for mode in 0..<2 {
		range_init := mode == 1
		n_init_angles := 2 if range_init else 1
		model := optimizer.Discrete_Model{n = 5, n_unique = n_init_angles+2, init_v_range = range_init}
		solution := optimizer.Solution{thetas = make([dynamic]f64, model.n_unique)}
		solution.thetas[0] = 0.15
		if range_init do solution.thetas[1] = 1.25
		solution.thetas[n_init_angles] = 0.4
		solution.thetas[n_init_angles+1] = -0.7
		state := optimizer.make_discrete_state(&model, &solution)
		testing.expect_value(t, len(state.indices), 2)
		testing.expect_value(t, state.indices[0], optimizer.index(f32(0.4)))
		testing.expect_value(t, state.indices[1], optimizer.index(f32(-0.7)))
		clone := optimizer.clone_discrete_state(state)
		optimizer.copy_discrete_state(&clone, state)
		for angle_index, i in state.indices do testing.expect_value(t, clone.indices[i], angle_index)
		facing_map := make([dynamic]int, 5)
		copy(facing_map[:], []int{0, n_init_angles, n_init_angles, n_init_angles+1, n_init_angles+1})
		model.facing_map = facing_map
		testing.expect_value(t, optimizer.discrete_state_deg(state, 1, &model), optimizer.discrete_state_deg(state, 2, &model))
		raw := optimizer.make_raw_expr(model.n)
		raw.f_coeff[3] = 1
		xs, zs: [5]f64
		testing.expect_value(t, optimizer.eval_raw_expr(raw, state, xs[:], zs[:], &model), optimizer.index_to_facing(state.indices[1]))
		optimizer.destroy_raw_expr(&raw)
		delete(facing_map)
		optimizer.destroy_discrete_state(&clone)
		optimizer.destroy_discrete_state(&state)
		optimizer.destroy_solution(&solution)
	}
}

@(test)
discrete_fast_estimates_keep_initial_angles_fixed :: proc(t: ^testing.T) {
	for mode in 0..<2 {
		range_init := mode == 1
		n_init_angles := 2 if range_init else 1
		model := optimizer.Discrete_Model{n = 5, n_unique = n_init_angles+2, init_v_range = range_init}
		original := optimizer.Problem{n = model.n_unique, objective = optimizer.make_compiled_expr(model.n_unique)}
		original.objective.constant = 0.3
		for i in 0..<model.n_unique {
			original.objective.theta_coeff[i] = 0.1*f64(i+1)
			original.objective.sin_coeff[i] = 0.2*f64(i+1)
			original.objective.cos_coeff[i] = -0.3*f64(i+1)
		}
		constraint := optimizer.clone_compiled_expr(original.objective)
		append(&original.eq_cons, constraint)
		initial := [?]f64{0.15, 1.25}
		problem := optimizer.freeze_initial_problem(&original, initial[:n_init_angles])
		state := optimizer.Discrete_State {
			indices = make([dynamic]u16, 2),
		}
		copy(state.indices[:], []u16{65535, 0})
		work := optimizer.make_workspace(problem.n)
		baseline := optimizer.make_discrete_baseline(&model, &problem)
		optimizer.rebuild_discrete_baseline(&baseline, &model, &problem, state, &work, .Polish)
		thetas := make([]f64, model.n_unique)
		copy(thetas[:n_init_angles], initial[:n_init_angles])
		for angle_index, i in state.indices do thetas[i+n_init_angles] = optimizer.index_to_radians(angle_index)
		original_work := optimizer.make_workspace(original.n)
		optimizer.update_trig_cache(&original_work, thetas)
		for angle_index, i in state.indices {
			original_work.sin_cache[i+n_init_angles] = f64(optimizer.sin_index(angle_index))
			original_work.cos_cache[i+n_init_angles] = f64(optimizer.cos_index(angle_index))
		}
		testing.expect(t, math.abs(baseline.objective-optimizer.eval(original.objective, thetas, &original_work)) < 1e-12)
		for delta in optimizer.TWO_OPT_DELTAS {
			move := optimizer.Two_Opt_Move{uticks = {0, 1}, deltas = delta}
			grade: optimizer.Two_Opt_Grade
			optimizer.grade_two_opt(&grade, &baseline, &model, &problem, &move, .Polish)
			trial := optimizer.clone_discrete_state(state)
			trial.indices[0] = optimizer.offset_index(trial.indices[0], delta[0])
			trial.indices[1] = optimizer.offset_index(trial.indices[1], delta[1])
			optimizer.update_discrete_trig_cache(&work, trial)
			value := optimizer.eval_discrete_expr(problem.objective, trial, &work)
			testing.expect(t, math.abs(value-baseline.objective-grade.objective_delta) < 1e-12)
			testing.expect(t, math.abs(value*value-grade.violation_sqr) < 1e-12)
			optimizer.destroy_discrete_state(&trial)
		}
		delete(thetas)
		optimizer.destroy_discrete_baseline(&baseline)
		optimizer.destroy_workspace(&work)
		optimizer.destroy_workspace(&original_work)
		optimizer.destroy_discrete_state(&state)
		optimizer.destroy_problem(&problem)
		optimizer.destroy_problem(&original)
	}
}
