package app_test

import "core:math"
import "core:strings"
import "core:testing"
import app "../../src/app"

@(test)
inertia_expressions_resolve_sort_and_deduplicate_without_rewriting :: proc(t: ^testing.T) {
	variables := make(map[string]f64)
	defer delete(variables)
	variables["t_mm"] = 2
	variables["offset"] = 1
	texts: [2][3]string
	texts[0][0] = "n - 1, t_mm, 1 + offset, (t_mm + 2) / 2, 0"
	assignments, err := app.parse_inertia_assignments(&texts, 6, variables)
	defer app.destroy_inertia_assignments(&assignments)
	defer delete(err)
	testing.expect_value(t, err, "")
	testing.expect_value(t, texts[0][0], "n - 1, t_mm, 1 + offset, (t_mm + 2) / 2, 0")
	testing.expect_value(t, len(assignments.ticks[0][0]), 3)
	if len(assignments.ticks[0][0]) == 3 {
		expected := [?]int{0, 2, 4}
		for value, i in expected do testing.expect_value(t, assignments.ticks[0][0][i], value)
	}
}

@(test)
inertia_expressions_check_conflicts_after_resolution :: proc(t: ^testing.T) {
	variables := make(map[string]f64)
	defer delete(variables)
	variables["t_mm"] = 2
	texts: [2][3]string
	texts[0][0] = "t_mm"
	texts[0][1] = "1 + 1"
	assignments, err := app.parse_inertia_assignments(&texts, 6, variables)
	defer app.destroy_inertia_assignments(&assignments)
	defer delete(err)
	testing.expect(t, strings.contains(err, "Tick 2 is assigned to both X Hit and X Avoid-"))
}

@(test)
inertia_expressions_reject_invalid_values :: proc(t: ^testing.T) {
	entries := [?]string{"missing", "1/2", "1e308*2", "1e308", "-1", "n+1", "F[1]", "X[0]", "1/0", "2,", ",2", "2,,3"}
	for entry in entries {
		texts: [2][3]string
		texts[1][2] = entry
		assignments, err := app.parse_inertia_assignments(&texts, 6)
		testing.expect(t, err != "")
		testing.expect(t, strings.contains(err, "Z Avoid+"))
		app.destroy_inertia_assignments(&assignments)
		delete(err)
	}
}

@(test)
inertia_expressions_match_numeric_solves_and_retain_detector_assignments :: proc(t: ^testing.T) {
	optimizers := [?]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}
	for optimizer in optimizers {
		for discrete in 0..<2 {
			material := app.Optimizer_Material {
				continuous_optimizer = optimizer,
				obj_type = .Z,
				maximize = true,
				discrete_search = discrete == 1,
				movement_script = "initAir(0, 0) wa(2) t(t_mm) wa(3)",
				x_origin_script = "0",
				z_origin_script = "0",
			}
			material.inertia_tick_lists[0][0] = "t_mm, 0, t_mm - 2"
			result := app.optimize(&material)
			testing.expect_value(t, result.error, "")
			testing.expect(t, result.solution != nil)
			material.inertia_tick_lists[0][0] = "0, 2"
			numeric := app.optimize(&material)
			testing.expect_value(t, numeric.error, "")
			testing.expect(t, numeric.solution != nil)
			if result.solution != nil && numeric.solution != nil {
				testing.expect(t, math.abs(result.solution.optimum-numeric.solution.optimum) < 1e-12)
				for x, tick in result.solution.xs do testing.expect(t, math.abs(x-numeric.solution.xs[tick]) < 1e-12)
				for z, tick in result.solution.zs do testing.expect(t, math.abs(z-numeric.solution.zs[tick]) < 1e-12)
			}
			state: app.Environment
			app.buffer_set(state.inertia_tick_lists[0][0][:], "t_mm, 0, t_mm - 2")
			app.apply_optimizer_result(&state, &result)
			testing.expect_value(t, app.buffer_string(state.inertia_tick_lists[0][0][:]), "t_mm, 0, t_mm - 2")
			testing.expect_value(t, len(state.last_inertia_assignments.ticks[0][0]), 2)
			testing.expect_value(t, len(result.inertia_assignments.ticks[0][0]), 0)
			testing.expect_value(t, app.inertia_choice_for_tick(&state.last_inertia_assignments.ticks, 2, .X), app.Inertia_Choice.Hit)
			app.buffer_set(state.inertia_tick_lists[0][0][:], "n - 1")
			testing.expect_value(t, app.inertia_choice_for_tick(&state.last_inertia_assignments.ticks, 2, .X), app.Inertia_Choice.Hit)
			app.clear_solution(&state)
			app.destroy_optimizer_result(&result)
			app.destroy_optimizer_result(&numeric)
		}
	}
}
