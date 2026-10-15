package app_test

import "core:math"
import "core:testing"
import app "../../src/app"

@(test)
default_initialization_solves_and_notice_tracks_last_result :: proc(t: ^testing.T) {
	optimizers := [?]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}
	search_modes := [?]bool{false, true}
	for optimizer in optimizers {
		for discrete in search_modes {
			material := app.Optimizer_Material {
				continuous_optimizer = optimizer,
				pancake_recovery = .BFGS,
				obj_type = .Custom,
				obj_script = "Z[n]",
				maximize = true,
				seed = 30,
				discrete_search = discrete,
				movement_script = "[w(2)] w",
				x_origin_script = "0",
				z_origin_script = "0",
			}
			implicit := app.optimize(&material)
			defer app.destroy_optimizer_result(&implicit)
			material.movement_script = "initGnd(0) [w(2)] w"
			explicit := app.optimize(&material)
			defer app.destroy_optimizer_result(&explicit)
			testing.expect_value(t, implicit.error, "")
			testing.expect_value(t, explicit.error, "")
			testing.expect(t, implicit.init_v_defaulted && !explicit.init_v_defaulted)
			if implicit.solution != nil && explicit.solution != nil {
				testing.expect(t, math.abs(implicit.solution.optimum-explicit.solution.optimum) < 1e-12)
				testing.expect_value(t, implicit.solution.xs[1]-implicit.solution.xs[0], f64(0))
				testing.expect_value(t, implicit.solution.zs[1]-implicit.solution.zs[0], f64(0))
			} else {
				testing.expect(t, false)
			}
			state: app.Environment
			defer app.clear_solution(&state)
			app.apply_optimizer_result(&state, &implicit)
			testing.expect(t, state.last_init_v_defaulted)
			app.apply_optimizer_result(&state, &explicit)
			testing.expect(t, !state.last_init_v_defaulted)
			state.last_init_v_defaulted = true
			app.clear_solution(&state)
			testing.expect(t, !state.last_init_v_defaulted)
		}
	}
}
