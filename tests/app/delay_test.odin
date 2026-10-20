package app_test

import "core:math"
import "core:strings"
import "core:testing"
import app "../../src/app"

@(test)
delay_mode_round_trips_and_changes_saved_fingerprint :: proc(t: ^testing.T) {
	tab := app.make_default_tab(401)
	defer app.destroy_tab(tab)
	loaded := app.make_default_tab(402)
	defer app.destroy_tab(loaded)
	testing.expect(t, tab.env.auto_delays)
	for automatic in ([2]bool{true, false}) {
		tab.env.auto_delays = automatic
		data, err := app.build_tab_json(tab)
		testing.expect_value(t, err, "")
		load_err := app.load_tab_from_json(loaded, data)
		testing.expect_value(t, load_err, "")
		testing.expect_value(t, loaded.env.auto_delays, automatic)
		material := app.make_optimizer_material(&loaded.env)
		testing.expect_value(t, material.auto_delays, automatic)
		app.destroy_optimizer_material(&material)
		delete(load_err)
		delete(err)
		delete(data)
	}
	manual := app.build_tab_fingerprint(tab)
	defer delete(manual)
	tab.env.auto_delays = true
	automatic := app.build_tab_fingerprint(tab)
	defer delete(automatic)
	testing.expect(t, manual != automatic)
}

@(test)
old_saves_keep_manual_delay_mode :: proc(t: ^testing.T) {
	tab := app.make_default_tab(403)
	defer app.destroy_tab(tab)
	data, err := app.build_tab_json(tab)
	defer delete(data)
	defer delete(err)
	testing.expect_value(t, err, "")
	legacy, _ := strings.replace_all(string(data), `"autoDelays":true,`, "")
	defer delete(legacy)
	load_err := app.load_tab_from_json(tab, transmute([]byte)legacy)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	testing.expect(t, !tab.env.auto_delays)
}

@(test)
automatic_delay_matches_manual_timing_across_solvers :: proc(t: ^testing.T) {
	for optimizer in ([?]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}) {
		for discrete in ([2]bool{false, true}) {
			material := app.Optimizer_Material {
				auto_delays = true,
				continuous_optimizer = optimizer,
				obj_type = .Z,
				maximize = true,
				seed = 0,
				discrete_search = discrete,
				movement_script = "initAir(0) [sa(2) wa(2)]",
				cons_script = "F[1] = 0",
				x_origin_script = "0",
				z_origin_script = "0",
			}
			actual := app.optimize(&material)
			defer app.destroy_optimizer_result(&actual)
			material.auto_delays = false
			material.movement_script = "initAir(0) [wa sa(2) wa]"
			expected := app.optimize(&material)
			defer app.destroy_optimizer_result(&expected)
			testing.expect_value(t, actual.error, "")
			testing.expect_value(t, expected.error, "")
			testing.expect(t, actual.solution != nil && expected.solution != nil)
			if actual.solution == nil || expected.solution == nil do continue
			testing.expect(t, math.abs(actual.solution.optimum-expected.solution.optimum) < 1e-10)
			for x, tick in expected.solution.xs {
				testing.expect(t, math.abs(actual.solution.xs[tick]-x) < 1e-10)
				testing.expect(t, math.abs(actual.solution.zs[tick]-expected.solution.zs[tick]) < 1e-10)
			}
		}
	}
}
