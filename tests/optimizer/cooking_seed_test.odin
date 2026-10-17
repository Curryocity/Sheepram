package optimizer_test

import "core:math"
import "core:math/rand"
import "core:testing"
import opt "../../src/optimizer"

@(test)
cooking_uses_exact_incumbent_indices_without_mutating_them :: proc(t: ^testing.T) {
	for range_mode in 0..<2 {
		range_init := range_mode == 1
		n_initial := 2 if range_init else 1
		model := opt.Discrete_Model {
			n = 5, n_unique = n_initial+2, init_v_range = range_init,
			init_vx = 0.125, init_vz = 0.25, init_facing = 0.3,
			exact_movement = make([dynamic]opt.Exact_Movement, 5),
			facing_map = make([dynamic]int, 5),
		}
		defer opt.destroy_discrete_model(&model)
		copy(model.facing_map[:], []int{0, n_initial, n_initial, n_initial+1, n_initial+1})
		problem := opt.Problem{n = 2, objective = opt.make_compiled_expr(2)}
		defer opt.destroy_problem(&problem)
		raw := opt.Raw_Problem{objective = opt.make_raw_expr(model.n)}
		defer opt.destroy_raw_problem(&raw)
		incumbent := opt.Discrete_State{indices = make([dynamic]u16, 2)}
		defer opt.destroy_discrete_state(&incumbent)
		bases := [?]u16{0, 65535, 30000}
		for base in bases {
			for &idx in incumbent.indices do idx = base
			trial := opt.local_search_from_state(&model, &problem, &raw, incumbent, .Cooking)
			for idx, i in trial.indices {
				delta := int(idx)-int(base)
				if delta > 32767 do delta -= 65536
				if delta < -32768 do delta += 65536
				testing.expect(t, delta >= -4 && delta <= 4)
				testing.expect_value(t, incumbent.indices[i], base)
			}
			testing.expect_value(t, opt.discrete_state_deg(trial, 1, &model), opt.discrete_state_deg(trial, 2, &model))
			testing.expect_value(t, model.init_vx, f64(0.125))
			testing.expect_value(t, model.init_vz, f64(0.25))
			testing.expect_value(t, model.init_facing, f64(0.3))
			opt.destroy_discrete_state(&trial)
		}
	}
}

@(test)
cooking_seed_offsets_are_bounded_wrap_and_favor_zero :: proc(t: ^testing.T) {
	state := opt.Discrete_State{indices = make([dynamic]u16, 10000)}
	defer opt.destroy_discrete_state(&state)
	for &idx, i in state.indices do idx = 0 if i%2 == 0 else 65535
	rng_state: rand.Xoshiro256_Random_State
	rng := rand.xoshiro256_random_generator(&rng_state)
	rand.reset(12345, rng)
	opt.perturb_discrete_state(&state, rng)
	opt.perturb_discrete_state(&state, rng)
	counts: [9]int
	for idx, i in state.indices {
		base := 0 if i%2 == 0 else 65535
		delta := int(idx)-base
		if delta > 32767 do delta -= 65536
		if delta < -32768 do delta += 65536
		testing.expect(t, delta >= -4 && delta <= 4)
		if delta >= -4 && delta <= 4 do counts[delta+4] += 1
	}
	expected := [?]f64{0.01, 0.04, 0.12, 0.20, 0.26, 0.20, 0.12, 0.04, 0.01}
	for count, i in counts do testing.expect(t, math.abs(f64(count)/10000-expected[i]) < 0.015)
}
