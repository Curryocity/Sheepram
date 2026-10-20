package app_test

import "core:math"
import "core:strings"
import "core:testing"
import app "../../src/app"

@(test)
minecraft_version_round_trips_and_rejects_unsupported_versions :: proc(t: ^testing.T) {
	tab := app.make_default_tab(501)
	defer app.destroy_tab(tab)
	loaded := app.make_default_tab(502)
	defer app.destroy_tab(loaded)
	testing.expect_value(t, tab.env.minecraft_version, app.Minecraft_Version.V1_8_9)
	for version in ([2]app.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		tab.env.minecraft_version = version
		data, err := app.build_tab_json(tab)
		testing.expect_value(t, err, "")
		load_err := app.load_tab_from_json(loaded, data)
		testing.expect_value(t, load_err, "")
		testing.expect_value(t, loaded.env.minecraft_version, version)
		material := app.make_optimizer_material(&loaded.env)
		testing.expect_value(t, material.minecraft_version, version)
		app.destroy_optimizer_material(&material)
		delete(load_err)
		delete(err)
		delete(data)
	}
	data, err := app.build_tab_json(tab)
	defer delete(data)
	defer delete(err)
	legacy, _ := strings.replace_all(string(data), `"minecraftVersion":"1.21.3",`, "")
	defer delete(legacy)
	load_err := app.load_tab_from_json(loaded, transmute([]byte)legacy)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	testing.expect_value(t, loaded.env.minecraft_version, app.Minecraft_Version.V1_8_9)
	invalid, _ := strings.replace_all(string(data), `"minecraftVersion":"1.21.3"`, `"minecraftVersion":"1.20.1"`)
	defer delete(invalid)
	invalid_err := app.load_tab_from_json(loaded, transmute([]byte)invalid)
	defer delete(invalid_err)
	testing.expect(t, strings.contains(invalid_err, "Invalid field: minecraftVersion"))
	testing.expect_value(t, loaded.env.minecraft_version, app.Minecraft_Version.V1_8_9)
}

@(test)
modern_physics_and_auto_delays_work_across_solvers :: proc(t: ^testing.T) {
	for optimizer in ([3]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}) {
		for discrete in ([2]bool{false, true}) {
			material := app.Optimizer_Material {
				minecraft_version = .V1_21_3,
				auto_delays = true,
				continuous_optimizer = optimizer,
				obj_type = .Z,
				maximize = true,
				seed = 0,
				discrete_search = discrete,
				cook = discrete,
				chefs = 2,
				movement_script = "initAirRange(0.1, 0.3) [sn.w w sn.w]",
				cons_script = "F[1] = 0",
				x_origin_script = "0",
				z_origin_script = "0",
			}
			actual := app.optimize(&material)
			defer app.destroy_optimizer_result(&actual)
			material.auto_delays = false
			material.movement_script = "initAirRange(0.1, 0.3) [w sn.w w]"
			expected := app.optimize(&material)
			defer app.destroy_optimizer_result(&expected)
			testing.expect_value(t, actual.error, "")
			testing.expect_value(t, expected.error, "")
			testing.expect_value(t, actual.inertia_threshold, 0.003)
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
