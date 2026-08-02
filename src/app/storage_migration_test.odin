package app

import "core:strings"
import "core:testing"
import dsl "../dsl"

@(test)
test_legacy_number_is_rounded :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	write_legacy_number(&builder, 0.123456)

	testing.expect_value(t, strings.to_string(builder), "0.12346")
}

@(test)
test_commit_tab_title_uses_draft :: proc(t: ^testing.T) {
	tab := make_default_tab(98)
	defer destroy_tab(tab)

	buffer_set(tab.name[:], "")
	buffer_set(tab.name_draft[:], "  My Preset  ")
	commit_tab_title(tab)

	testing.expect_value(t, buffer_string(tab.name[:]), "My Preset")
	testing.expect_value(t, buffer_string(tab.name_draft[:]), "My Preset")

	data, err := build_tab_json(tab)
	defer delete(data)
	defer delete(err)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(string(data), `"title":"My Preset"`))
	testing.expect(t, !strings.contains(string(data), `"globalNames"`))
	testing.expect(t, !strings.contains(string(data), `"globalValues"`))
}

@(test)
test_legacy_preset_migration :: proc(t: ^testing.T) {
	tab := make_default_tab(99)
	defer destroy_tab(tab)

	legacy := `{
		"title":"legacy",
		"maximize":false,
		"currObj":0,
		"n":4,
		"initV":"0.3",
		"dragX":["gnd","air","air","0"],
		"dragZ":["gnd","air","air","air"],
		"accel":["initV","a","a","a"],
		"globalNames":["gnd","air","a"],
		"globalValues":["0.546","0.91","0.02"],
		"objScript":"",
		"constraintScript":"",
		"post":{"xTick":"0","xAdd":"0","zTick":"0","zAdd":"0","copySeparator":0,"positionPrecision":6}
	}`

	err := load_tab_from_json(tab, transmute([]byte)legacy)
	testing.expect_value(t, err, "")
	if err != "" {
		delete(err)
		return
	}
	script := buffer_string(tab.env.movement_script[:])
	testing.expect(
		t,
		strings.has_prefix(
			script,
			"set(gnd, 0.546) set(air, 0.91) set(a, 0.02)\n\n",
		),
	)
	testing.expect(t, strings.contains(script, "initGnd"))
	testing.expect(t, !strings.contains(script, "slip("))
	testing.expect(t, strings.contains(script, "mv(air, a, 2)"))
	testing.expect(t, strings.contains(script, "mv(air, a)"))
	testing.expect(t, !strings.contains(script, "wx"))
	testing.expect(t, !strings.contains(script, "wz"))
	testing.expect(t, strings.has_suffix(script, " st"))
	testing.expect_value(t, buffer_string(tab.env.post.x_origin[:]), "X[0] + (0)")
	testing.expect_value(t, buffer_string(tab.env.post.z_origin[:]), "Z[0] + (0)")

	state := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&state)
	code, parse_err := dsl.parse_mothball(script)
	defer dsl.destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	dsl.compile_mothball(&state, code[:])
	testing.expect(t, state.ok)
	testing.expect_value(t, state.n, 5)
	testing.expect_value(t, state.drag_x[3], 0.91)
	testing.expect_value(t, state.drag_z[3], 0.91)
	testing.expect_value(t, state.accel[4], 0.0)
}

@(test)
test_current_global_table_migrates_to_set_commands :: proc(t: ^testing.T) {
	tab := make_default_tab(105)
	defer destroy_tab(tab)

	current_with_table := `{
		"title":"table migration",
		"maximize":false,
		"currObj":0,
		"movementScript":"initGnd(0.3) w(m2)",
		"globalNames":["loop","m2","bx",""],
		"globalValues":["2","loop + 6","0.6000000238418579",""],
		"objScript":"",
		"constraintScript":"X[m2] > 0",
		"post":{"xOrigin":"X[0]","zOrigin":"Z[0]","copySeparator":0,"positionPrecision":6}
	}`

	err := load_tab_from_json(tab, transmute([]byte)current_with_table)
	defer delete(err)
	testing.expect_value(t, err, "")
	if err != "" do return

	script := buffer_string(tab.env.movement_script[:])
	testing.expect_value(
		t,
		script,
		"set(loop, 2) set(m2, loop + 6)\n\ninitGnd(0.3) w(m2)",
	)
	testing.expect(t, !strings.contains(script, "set(bx"))

	code, parse_err := dsl.parse_mothball(script)
	defer dsl.destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return
	compiler := dsl.Moth_Compiler{}
	defer dsl.destroy_moth_compiler(&compiler)
	dsl.compile_mothball(&compiler, code[:])
	testing.expect(t, compiler.ok)
	testing.expect_value(t, compiler.n, 9)

	data, save_err := build_tab_json(tab)
	defer delete(data)
	defer delete(save_err)
	testing.expect_value(t, save_err, "")
	testing.expect(t, !strings.contains(string(data), `"globalNames"`))
	testing.expect(t, !strings.contains(string(data), `"globalValues"`))
}

@(test)
test_current_postprocessor_origins_round_trip :: proc(t: ^testing.T) {
	tab := make_default_tab(101)
	defer destroy_tab(tab)

	buffer_set(tab.env.post.x_origin[:], "x1 + 0.3")
	buffer_set(tab.env.post.z_origin[:], "Z[n] - 0.6")
	tab.env.continuous_optimizer = .Pancake
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1][:], "1, 4")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Minus)-1][:], "2")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Plus)-1][:], "3")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1][:], "5")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Minus)-1][:], "6")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Plus)-1][:], "7")

	data, save_err := build_tab_json(tab)
	defer delete(data)
	defer delete(save_err)
	testing.expect_value(t, save_err, "")
	if save_err != "" do return
	testing.expect(t, strings.contains(string(data), `"inertiaList"`))
	testing.expect(t, !strings.contains(string(data), `"inertiaTicks"`))

	loaded := make_default_tab(102)
	defer destroy_tab(loaded)
	load_err := load_tab_from_json(loaded, data)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	if load_err != "" do return

	testing.expect_value(t, buffer_string(loaded.env.post.x_origin[:]), "x1 + 0.3")
	testing.expect_value(t, buffer_string(loaded.env.post.z_origin[:]), "Z[n] - 0.6")
	testing.expect_value(t, loaded.env.continuous_optimizer, Continuous_Optimizer.Pancake)
	testing.expect_value(t, loaded.env.inertia_detection_range, 2.0)
	testing.expect_value(t, loaded.env.inertia_detector_filter, Inertia_Detector_Filter.Lazy_And_Incorrect)
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1][:]), "1, 4")
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Minus)-1][:]), "2")
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Plus)-1][:]), "3")
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1][:]), "5")
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Minus)-1][:]), "6")
	testing.expect_value(t, buffer_string(loaded.env.inertia_tick_lists[int(Inertia_Axis.Z)][int(Inertia_Choice.Avoid_Plus)-1][:]), "7")
	for axis in 0..<2 {
		for mode in 0..<3 do testing.expect(t, loaded.env.inertia_tick_list_visible[axis][mode])
	}
}

@(test)
test_pancake_bfgs_optimizer_round_trip :: proc(t: ^testing.T) {
	tab := make_default_tab(103)
	defer destroy_tab(tab)
	tab.env.continuous_optimizer = .Pancake
	tab.env.pancake_recovery = .BFGS

	data, save_err := build_tab_json(tab)
	defer delete(data)
	defer delete(save_err)
	testing.expect_value(t, save_err, "")
	if save_err != "" do return

	loaded := make_default_tab(104)
	defer destroy_tab(loaded)
	load_err := load_tab_from_json(loaded, data)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	if load_err != "" do return

	testing.expect_value(
		t,
		loaded.env.continuous_optimizer,
		Continuous_Optimizer.Pancake,
	)
	testing.expect_value(
		t,
		loaded.env.pancake_recovery,
		Pancake_Recovery.BFGS,
	)
}

@(test)
test_failed_legacy_migration_preserves_tab :: proc(t: ^testing.T) {
	tab := make_default_tab(100)
	defer destroy_tab(tab)
	original := strings.clone(buffer_string(tab.env.movement_script[:]))
	defer delete(original)

	legacy := `{
		"title":"bad legacy",
		"maximize":false,
		"currObj":0,
		"n":2,
		"initV":"0.3",
		"dragX":["0.546","0.8"],
		"dragZ":["0.546","0.7"],
		"accel":["0.3","0.02"],
		"globalNames":[],
		"globalValues":[],
		"objScript":"",
		"constraintScript":"",
		"post":{"xTick":"0","xAdd":"0","zTick":"0","zAdd":"0","copySeparator":0,"positionPrecision":6}
	}`

	err := load_tab_from_json(tab, transmute([]byte)legacy)
	defer delete(err)
	testing.expect(t, err != "")
	testing.expect_value(t, buffer_string(tab.env.movement_script[:]), original)
}
