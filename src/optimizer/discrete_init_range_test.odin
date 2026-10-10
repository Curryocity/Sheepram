package optimizer

import "core:math"
import "core:testing"

@(test)
discrete_indices_skip_all_initial_angles :: proc(t: ^testing.T) {
	for mode in 0..<2 {
		range_init := mode == 1
		n_init_angles := 2 if range_init else 1
		model := Discrete_Model{n = 5, n_unique = n_init_angles+2, init_v_range = range_init}
		solution := Solution{thetas = make([dynamic]f64, model.n_unique)}
		solution.thetas[0] = 0.15
		if range_init do solution.thetas[1] = 1.25
		solution.thetas[n_init_angles] = 0.4
		solution.thetas[n_init_angles+1] = -0.7
		state := make_discrete_state(&model, &solution)
		testing.expect_value(t, len(state.indices), 2)
		testing.expect_value(t, state.indices[0], index(f32(0.4)))
		testing.expect_value(t, state.indices[1], index(f32(-0.7)))
		clone := clone_discrete_state(state)
		copy_discrete_state(&clone, state)
		for angle_index, i in state.indices do testing.expect_value(t, clone.indices[i], angle_index)
		facing_map := make([dynamic]int, 5)
		copy(facing_map[:], []int{0, n_init_angles, n_init_angles, n_init_angles+1, n_init_angles+1})
		model.facing_map = facing_map
		testing.expect_value(t, discrete_state_deg(state, 1, &model), discrete_state_deg(state, 2, &model))
		raw := make_raw_expr(model.n)
		raw.f_coeff[3] = 1
		xs, zs: [5]f64
		testing.expect_value(t, eval_raw_expr(raw, state, xs[:], zs[:], &model), index_to_facing(state.indices[1]))
		destroy_raw_expr(&raw)
		delete(facing_map)
		destroy_discrete_state(&clone)
		destroy_discrete_state(&state)
		destroy_solution(&solution)
	}
}

@(test)
discrete_fast_estimates_keep_initial_angles_fixed :: proc(t: ^testing.T) {
	for mode in 0..<2 {
		range_init := mode == 1
		n_init_angles := 2 if range_init else 1
		model := Discrete_Model{n = 5, n_unique = n_init_angles+2, init_v_range = range_init}
		original := Problem{n = model.n_unique, objective = make_compiled_expr(model.n_unique)}
		original.objective.constant = 0.3
		for i in 0..<model.n_unique {
			original.objective.theta_coeff[i] = 0.1*f64(i+1)
			original.objective.sin_coeff[i] = 0.2*f64(i+1)
			original.objective.cos_coeff[i] = -0.3*f64(i+1)
		}
		constraint := clone_compiled_expr(original.objective)
		append(&original.eq_cons, constraint)
		initial := [?]f64{0.15, 1.25}
		problem := freeze_initial_problem(&original, initial[:n_init_angles])
		state := Discrete_State {
			indices = make([dynamic]u16, 2),
		}
		copy(state.indices[:], []u16{65535, 0})
		work := make_workspace(problem.n)
		baseline := make_discrete_baseline(&model, &problem)
		rebuild_discrete_baseline(&baseline, &model, &problem, state, &work, .Polish)
		thetas := make([]f64, model.n_unique)
		copy(thetas[:n_init_angles], initial[:n_init_angles])
		for angle_index, i in state.indices do thetas[i+n_init_angles] = index_to_radians(angle_index)
		original_work := make_workspace(original.n)
		update_trig_cache(&original_work, thetas)
		for angle_index, i in state.indices {
			original_work.sin_cache[i+n_init_angles] = f64(sin_index(angle_index))
			original_work.cos_cache[i+n_init_angles] = f64(cos_index(angle_index))
		}
		testing.expect(t, math.abs(baseline.objective-eval(original.objective, thetas, &original_work)) < 1e-12)
		for delta in TWO_OPT_DELTAS {
			move := Two_Opt_Move{uticks = {0, 1}, deltas = delta}
			grade: Two_Opt_Grade
			grade_two_opt(&grade, &baseline, &model, &problem, &move, .Polish)
			trial := clone_discrete_state(state)
			trial.indices[0] = offset_index(trial.indices[0], delta[0])
			trial.indices[1] = offset_index(trial.indices[1], delta[1])
			update_discrete_trig_cache(&work, trial)
			value := eval_discrete_expr(problem.objective, trial, &work)
			testing.expect(t, math.abs(value-baseline.objective-grade.objective_delta) < 1e-12)
			testing.expect(t, math.abs(value*value-grade.violation_sqr) < 1e-12)
			destroy_discrete_state(&trial)
		}
		delete(thetas)
		destroy_discrete_baseline(&baseline)
		destroy_workspace(&work)
		destroy_workspace(&original_work)
		destroy_discrete_state(&state)
		destroy_problem(&problem)
		destroy_problem(&original)
	}
}
