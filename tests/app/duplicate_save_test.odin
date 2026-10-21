package app_test

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src/app"
import dsl "../../src/dsl"
import opt "../../src/optimizer"

@(test)
duplicate_names_accumulate_only_trailing_signed_offsets :: proc(t: ^testing.T) {
	cases := [?]struct{source: string, rotation: int, expected: string}{
		{"Example", 0, "Example (+0)"},
		{"Example (+90)", 90, "Example (+180)"},
		{"Example (+90)", -90, "Example (+0)"},
		{"Example (-180)", 90, "Example (-90)"},
		{"Example (-90)", 450, "Example (+360)"},
		{"Example (+90)", 0, "Example (+90)"},
		{"Example(+0090)", 90, "Example (+180)"},
		{"Example (+abc)", 90, "Example (+abc) (+90)"},
		{"Example (90)", 90, "Example (90) (+90)"},
		{"Example (+90.5)", 90, "Example (+90.5) (+90)"},
		{"Example (+90) notes", 90, "Example (+90) notes (+90)"},
		{"Example (+9223372036854775807)", 90, "Example (+9223372036854775807) (+90)"},
	}
	for item in cases {
		name := app.duplicate_save_name(item.source, item.rotation)
		testing.expect_value(t, name, item.expected)
		delete(name)
	}
}

rotation_expression_value :: proc(t: ^testing.T, script, expression: string, turns: int, version: opt.Minecraft_Version) -> f64 {
	code, parse_err := dsl.parse_mothball(script)
	defer dsl.destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return 0
	m := dsl.Moth_Compiler{minecraft_version = version, auto_delays = true}
	defer dsl.destroy_moth_compiler(&m)
	dsl.compile_mothball(&m, code[:])
	testing.expect(t, m.ok, m.err)
	if !m.ok do return 0
	if m.has_init_angle do testing.expect(t, math.abs(m.init_angle-(6+f64(turns*90))) < 1e-10)
	model := opt.Model{
		n = m.n, n_unique = m.unique_facing_counts,
		drag_x = m.drag_x, drag_z = m.drag_z, accel = m.accel,
		facing_map = m.facing_map, angle_offset = m.angle_offset,
		init_v_range = m.init_v_range, init_v_extra = m.init_v_extra,
	}
	m.drag_x, m.drag_z, m.accel, m.facing_map, m.angle_offset = nil, nil, nil, nil, nil
	defer opt.destroy_model(&model)
	opt.compile_model(&model)
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	dsl.add_resolved_variables(&parser, m.variables)
	raw, expr_err := dsl.parse_expr(&parser, expression)
	testing.expect_value(t, expr_err, "")
	if expr_err != "" {
		delete(expr_err)
		return 0
	}
	defer opt.destroy_raw_expr(&raw)
	compiled := opt.reduce_expr(raw, &model)
	defer opt.destroy_compiled_expr(&compiled)
	thetas := make([]f64, model.n_unique)
	defer delete(thetas)
	for &theta, i in thetas do theta = (20+7*f64(i)+f64(turns*90))*math.PI/180
	work := opt.make_workspace(model.n_unique)
	defer opt.destroy_workspace(&work)
	opt.update_trig_cache(&work, thetas)
	return opt.eval(compiled, thetas, &work)
}

@(test)
rotation_preserves_expressions_and_comments :: proc(t: ^testing.T) {
	expression := "2*X[3] - Z[2]/3 + Vx[4] - 2*Vz[1] + 2*F[1] - F[2] + T[2] + 7 // X[1], F[1]\n"
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for initial in ([2]string{"initAir(0.3, a0/2)", "initAirRange(0.1, 0.3)"}) {
			script := fmt.aprintf("set(a0, 12) %s %s", initial, "r(1){[wa(2)]} wx wa wz wa wa // initAir(1, 90) wx")
			defer delete(script)
			expected := rotation_expression_value(t, script, expression, 0, version)
			for turns in ([13]int{-9, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 9}) {
				rotated_script, script_err := app.rotate_save_text(script, turns, true)
				rotated_expr, expr_err := app.rotate_save_text(expression, turns)
				testing.expect_value(t, script_err, "")
				testing.expect_value(t, expr_err, "")
				testing.expect(t, strings.has_suffix(rotated_script, "// initAir(1, 90) wx"))
				testing.expect(t, strings.has_suffix(rotated_expr, "// X[1], F[1]\n"))
				actual := rotation_expression_value(t, rotated_script, rotated_expr, turns, version)
				testing.expect(t, math.abs(actual-expected) < 1e-9)
				delete(rotated_script)
				delete(rotated_expr)
				delete(script_err)
				delete(expr_err)
			}
		}
	}
	text, err := app.rotate_save_text("Xoffset + Zed + Fname + X [1] + Z[2] + F[3] + T[1]", 1)
	defer delete(text)
	defer delete(err)
	testing.expect_value(t, err, "")
	testing.expect_value(t, text, "Xoffset + Zed + Fname + (-Z [1]) + X[2] + (F[3] - 90) + T[1]")
	comment_script, comment_err := app.rotate_save_text("initAir(0.3, 6 // yaw\n) wa(5)", 1, true)
	defer delete(comment_script)
	defer delete(comment_err)
	testing.expect_value(t, comment_err, "")
	_ = rotation_expression_value(t, comment_script, "X[1]", 1, .V1_8_9)
	cycled_script := strings.clone("set(a0, 12) initAir(0.3, a0/2) [wa(2)] wx wa wz wa wa")
	cycled_expr := strings.clone(expression)
	defer delete(cycled_script)
	defer delete(cycled_expr)
	expected := rotation_expression_value(t, cycled_script, cycled_expr, 0, .V1_8_9)
	for _ in 0..<4 {
		next_script, cycle_err := app.rotate_save_text(cycled_script, 1, true)
		testing.expect_value(t, cycle_err, "")
		delete(cycle_err)
		next_expr, cycle_expr_err := app.rotate_save_text(cycled_expr, 1)
		testing.expect_value(t, cycle_expr_err, "")
		delete(cycle_expr_err)
		delete(cycled_script)
		delete(cycled_expr)
		cycled_script, cycled_expr = next_script, next_expr
	}
	actual := rotation_expression_value(t, cycled_script, cycled_expr, 4, .V1_8_9)
	testing.expect(t, math.abs(actual-expected) < 1e-9)
}

@(test)
signed_rotation_keeps_full_yaw_turns_and_steps_from_nearest_multiple :: proc(t: ^testing.T) {
	source := app.make_default_tab(708)
	defer app.destroy_tab(source)
	for rotation in ([6]int{-450, -360, -90, 90, 360, 450}) {
		copy, err := app.prepare_duplicate_tab(source, "Signed rotation", rotation, 709)
		testing.expect_value(t, err, "")
		delete(err)
		if copy == nil do continue
		defer app.destroy_tab(copy)
		testing.expect_value(t, copy.env.seed, 45+f64(rotation))
		testing.expect_value(t, copy.env.facing_range_midpoint, f64(rotation))
		orientation := (rotation/90%4+4)%4
		testing.expect_value(t, copy.env.obj_type, app.Objective_Type(.X if orientation%2 == 0 else .Z))
		testing.expect_value(t, copy.env.maximize, orientation == 1 || orientation == 2)
	}
	copy, invalid_err := app.prepare_duplicate_tab(source, "Invalid", 73, 709)
	testing.expect(t, copy == nil)
	testing.expect_value(t, invalid_err, "Rotation must be a multiple of 90.")
	delete(invalid_err)
	testing.expect_value(t, source.env.seed, 45)
	testing.expect_value(t, source.env.facing_range_midpoint, 0)
	inputs := [9]int{73, -73, 90, -90, 44, -44, 45, -45, 0}
	plus := [9]int{180, 0, 180, 0, 90, 90, 180, 0, 90}
	minus := [9]int{0, -180, 0, -180, -90, -90, 0, -180, -90}
	for input, i in inputs {
		testing.expect_value(t, app.step_duplicate_rotation(input, 1), plus[i])
		testing.expect_value(t, app.step_duplicate_rotation(input, -1), minus[i])
	}
	testing.expect_value(t, app.step_duplicate_rotation(2147483647, 1), 2147483610)
	testing.expect_value(t, app.step_duplicate_rotation(-2147483648, -1), -2147483610)
}

@(test)
duplicate_copies_inputs_without_runtime_ownership :: proc(t: ^testing.T) {
	source := app.make_default_tab(701)
	defer app.destroy_tab(source)
	source.env.last_solution = new(opt.Solution)
	source.env.last_solution.thetas = make([dynamic]f64, 1)
	source.env.last_solution.thetas[0] = 123
	source.env.last_solution.optimum = 456
	app.buffer_set(source.saved_file_name[:], "Original.json")
	app.buffer_set(source.env.constraint_script[:], "X[1] > 0 // unsaved edit")
	before := app.build_tab_fingerprint(source)
	defer delete(before)
	copy, err := app.prepare_duplicate_tab(source, "Copy.json", 0, 702)
	testing.expect_value(t, err, "")
	defer delete(err)
	if copy == nil do return
	defer app.destroy_tab(copy)
	testing.expect_value(t, app.buffer_string(copy.name[:]), "Copy")
	testing.expect_value(t, app.buffer_string(copy.saved_file_name[:]), "")
	testing.expect(t, copy.env.last_solution == nil)
	testing.expect_value(t, app.buffer_string(copy.env.constraint_script[:]), "X[1] > 0 // unsaved edit")
	app.buffer_set(copy.env.movement_script[:], "wa(2)")
	after := app.build_tab_fingerprint(source)
	defer delete(after)
	testing.expect_value(t, after, before)
	testing.expect_value(t, source.env.last_solution.thetas[0], 123)
	testing.expect_value(t, app.buffer_string(source.saved_file_name[:]), "Original.json")
}

@(test)
rotation_maps_origins_inertia_and_builtin_objectives :: proc(t: ^testing.T) {
	source := app.make_default_tab(703)
	defer app.destroy_tab(source)
	app.buffer_set(source.env.post.x_origin[:], "X[0] + 2")
	app.buffer_set(source.env.post.z_origin[:], "Z[0] - 3")
	for axis in 0..<2 {
		for mode in 0..<3 {
			app.buffer_set(source.env.inertia_tick_lists[axis][mode][:], fmt.tprintf("%d", 1+axis*3+mode))
			source.env.inertia_tick_list_visible[axis][mode] = (axis*3+mode)%2 == 0
		}
	}
	expected_lists := [4][2][3]string{
		{{"1", "2", "3"}, {"4", "5", "6"}},
		{{"4", "5", "6"}, {"1", "3", "2"}},
		{{"1", "3", "2"}, {"4", "6", "5"}},
		{{"4", "6", "5"}, {"1", "2", "3"}},
	}
	expected_x := [4]f64{2, -3, -2, 3}
	expected_z := [4]f64{-3, -2, 3, 2}
	for turns in 0..<4 {
		copy, err := app.prepare_duplicate_tab(source, "Rotated", turns*90, 704)
		testing.expect_value(t, err, "")
		defer delete(err)
		if copy == nil do continue
		defer app.destroy_tab(copy)
		testing.expect_value(t, copy.env.seed, 45+f64(turns*90))
		testing.expect_value(t, copy.env.facing_range_midpoint, f64(turns*90))
		testing.expect_value(t, copy.env.obj_type, app.Objective_Type(.X if turns%2 == 0 else .Z))
		testing.expect_value(t, copy.env.maximize, turns == 1 || turns == 2)
		for axis in 0..<2 {
			for mode in 0..<3 {
				value := app.buffer_string(copy.env.inertia_tick_lists[axis][mode][:])
				testing.expect_value(t, value, expected_lists[turns][axis][mode])
				testing.expect_value(t, copy.env.inertia_tick_list_visible[axis][mode], value == "1" || value == "3" || value == "5")
			}
		}
		// At tick zero the rotated origins are just the rotated constant offsets.
		x := rotation_expression_value(t, "wa(5)", app.buffer_string(copy.env.post.x_origin[:]), turns, .V1_8_9)
		z := rotation_expression_value(t, "wa(5)", app.buffer_string(copy.env.post.z_origin[:]), turns, .V1_8_9)
		testing.expect(t, math.abs(x-expected_x[turns]) < 1e-10)
		testing.expect(t, math.abs(z-expected_z[turns]) < 1e-10)
	}
	for _ in 0..<4 do testing.expect_value(t, app.rotate_save_environment(&source.env, 90), "")
	testing.expect_value(t, source.env.obj_type, app.Objective_Type.X)
	testing.expect_value(t, source.env.maximize, false)
	for axis in 0..<2 {
		for mode in 0..<3 do testing.expect_value(t, app.buffer_string(source.env.inertia_tick_lists[axis][mode][:]), expected_lists[0][axis][mode])
	}
}

@(test)
duplicate_rejects_invalid_names_ranges_and_oversized_text :: proc(t: ^testing.T) {
	source := app.make_default_tab(705)
	defer app.destroy_tab(source)
	for name in ([8]string{"", ".json", "../outside", "bad:name", ".", "CON", "nul.txt", "COM1"}) {
		copy, err := app.prepare_duplicate_tab(source, name, 0, 706)
		testing.expect(t, copy == nil)
		testing.expect(t, err != "")
		delete(err)
	}
	source.env.facing_range_midpoint = 1800
	copy, range_err := app.prepare_duplicate_tab(source, "Too far", 90, 706)
	testing.expect(t, copy == nil)
	testing.expect(t, range_err != "")
	delete(range_err)
	source.env.facing_range_midpoint = 0
	large := strings.repeat("X[1]+", (app.SCRIPT_CAPACITY-2)/5)
	defer delete(large)
	app.buffer_set(source.env.constraint_script[:], large)
	oversized, size_err := app.prepare_duplicate_tab(source, "Too large", 90, 706)
	testing.expect(t, oversized == nil)
	testing.expect(t, strings.contains(size_err, "capacity"))
	delete(size_err)
}

@(test)
create_duplicate_saves_and_opens_without_overwriting :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "sheepram-duplicate-*", context.allocator)
	testing.expect(t, root_err == nil)
	if root_err != nil do return
	defer delete(root)
	defer os.remove(root)
	dir, _ := os.join_path({root, "saves"}, context.allocator)
	defer delete(dir)
	defer os.remove(dir)
	path, _ := os.join_path({dir, "Copy.json"}, context.allocator)
	defer delete(path)
	defer os.remove(path)
	state := app.init_app()
	defer {
		app.destroy_app(state)
		free(state)
	}
	source := state.tabs[0]
	app.buffer_set(source.saved_file_name[:], "Original.json")
	invalid_err := app.create_duplicate_save(state, "Copy", 73, dir)
	testing.expect_value(t, invalid_err, "Rotation must be a multiple of 90.")
	delete(invalid_err)
	testing.expect_value(t, state.tab_count, 1)
	testing.expect(t, !os.is_file(path))
	err := app.create_duplicate_save(state, "Copy", 90, dir)
	testing.expect_value(t, err, "")
	defer delete(err)
	testing.expect_value(t, state.tab_count, 2)
	testing.expect_value(t, state.active_tab, 1)
	if err != "" do return
	copy := state.tabs[1]
	testing.expect_value(t, state.pending_select_tab_id, copy.id)
	testing.expect(t, !app.is_tab_modified(copy))
	testing.expect_value(t, app.buffer_string(copy.saved_file_name[:]), "Copy.json")
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, read_err == nil)
	loaded := app.make_default_tab(707)
	defer app.destroy_tab(loaded)
	load_err := app.load_tab_from_file(loaded, path)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	testing.expect_value(t, loaded.env.facing_range_midpoint, 90)
	collision_err := app.create_duplicate_save(state, "Copy", 0, dir)
	defer delete(collision_err)
	testing.expect(t, strings.has_prefix(collision_err, "Name already taken:"))
	testing.expect_value(t, state.tab_count, 2)
	after, _ := os.read_entire_file(path, context.allocator)
	defer delete(after)
	testing.expect_value(t, string(after), string(data))
	testing.expect_value(t, app.buffer_string(source.saved_file_name[:]), "Original.json")
}
