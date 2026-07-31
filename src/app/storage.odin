package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import dsl "../dsl"

APP_NAME :: "Sheepram"
PREFERENCE_FILE :: "preference.json"
PRESET_FOLDER :: "presets/saves"

Saved_Post :: struct {
	x_origin:           string   `json:"xOrigin"`,
	z_origin:           string   `json:"zOrigin"`,
	x_tick:             string   `json:"xTick,omitempty"`,
	x_add:              string   `json:"xAdd,omitempty"`,
	z_tick:             string   `json:"zTick,omitempty"`,
	z_add:              string   `json:"zAdd,omitempty"`,
	copy_separator:     int      `json:"copySeparator"`,
	include_initial_angle: bool  `json:"includeInitialAngle,omitempty"`,
	position_precision: int      `json:"positionPrecision"`,
}

Saved_Tab :: struct {
	title:             string     `json:"title"`,
	maximize:          bool       `json:"maximize"`,
	discrete_search:   bool       `json:"discreteSearch"`,
	cook:              bool       `json:"cook"`,
	chefs:             int        `json:"chefs"`,
	seed:              f64       `json:"initialAngleDeg"`,
	multistart:        bool       `json:"multistart"`,
	try_preset_initial_angles: bool `json:"tryPresetInitialAngles,omitempty"`,
	initial_angle_samples: int    `json:"initialAngleSamples"`,
	continuous_optimizer: int     `json:"continuousOptimizer,omitempty"`,
	pancake_recovery:     int     `json:"pancakeSecondary,omitempty"`,
	obj_type:             int     `json:"currObj"`,
	movement_script:   string     `json:"movementScript"`,
	global_names:      []string   `json:"globalNames,omitempty"`,
	global_values:     []string   `json:"globalValues,omitempty"`,
	objective_script:  string     `json:"objScript"`,
	constraint_script: string     `json:"constraintScript"`,
	post:              Saved_Post `json:"post"`,
}

Preferences :: struct {
	theme_index: int `json:"themeIndex"`,
	ui_size_level: int `json:"uiSizeLevel"`,
}

free_saved_tab :: proc(saved: ^Saved_Tab) {
	for value in saved.global_names do delete(value)
	for value in saved.global_values do delete(value)
	delete(saved.title)
	delete(saved.movement_script)
	delete(saved.global_names)
	delete(saved.global_values)
	delete(saved.objective_script)
	delete(saved.constraint_script)
	delete(saved.post.x_origin)
	delete(saved.post.z_origin)
	delete(saved.post.x_tick)
	delete(saved.post.x_add)
	delete(saved.post.z_tick)
	delete(saved.post.z_add)
	saved^ = {}
}

saved_from_tab :: proc(tab: ^Tab_State) -> Saved_Tab {
	env := &tab.env
	saved := Saved_Tab {
		title             = buffer_string(tab.name[:]),
		maximize          = env.maximize,
		discrete_search   = env.discrete_search,
		cook              = env.cook,
		chefs             = env.chefs,
		seed              = env.seed,
		multistart        = env.multistart_on,
		initial_angle_samples = env.seed_samples,
		continuous_optimizer = int(env.continuous_optimizer),
		pancake_recovery     = int(env.pancake_recovery),
		obj_type             = int(env.obj_type),
		movement_script   = buffer_string(env.movement_script[:]),
		objective_script  = buffer_string(env.objective_script[:]),
		constraint_script = buffer_string(env.constraint_script[:]),
		post = {
			x_origin           = buffer_string(env.post.x_origin[:]),
			z_origin           = buffer_string(env.post.z_origin[:]),
			copy_separator     = int(env.post.copy_separator),
			include_initial_angle = env.post.include_initial_angle,
			position_precision = env.post.position_precision,
		},
	}
	return saved
}

build_tab_json :: proc(tab: ^Tab_State, pretty := false) -> ([]byte, string) {
	saved := saved_from_tab(tab)
	data, err := json.marshal(
		saved,
		{pretty = pretty, use_spaces = true, spaces = 2},
		context.allocator,
	)
	if err != nil do return nil, fmt.aprintf("Failed to encode preset: %v", err)
	return data, ""
}

build_tab_fingerprint :: proc(tab: ^Tab_State) -> string {
	data, err := build_tab_json(tab)
	if err != "" {
		delete(err)
		return ""
	}
	defer delete(data)
	return strings.clone(string(data))
}

is_tab_modified :: proc(tab: ^Tab_State) -> bool {
	fingerprint := build_tab_fingerprint(tab)
	defer delete(fingerprint)
	return fingerprint != buffer_string(tab.saved_fingerprint[:])
}

migrate_saved_global_table :: proc(saved: ^Saved_Tab) -> string {
	if len(saved.global_names) != len(saved.global_values) {
		return strings.clone("globalNames/globalValues size mismatch")
	}
	if len(saved.global_names) == 0 do return ""

	has_variables := false
	for raw_name in saved.global_names {
		name := strings.trim_space(raw_name)
		if name != "" && !dsl.builtin_moth_name(name) {
			has_variables = true
			break
		}
	}
	if !has_variables do return ""

	builder := strings.builder_make()
	wrote_variable := false
	for raw_name, i in saved.global_names {
		name := strings.trim_space(raw_name)
		if name == "" || dsl.builtin_moth_name(name) do continue
		if wrote_variable do strings.write_byte(&builder, ' ')
		fmt.sbprintf(
			&builder,
			"set(%s, %s)",
			name,
			strings.trim_space(saved.global_values[i]),
		)
		wrote_variable = true
	}
	strings.write_string(&builder, "\n\n")
	strings.write_string(&builder, saved.movement_script)
	migrated := strings.to_string(builder)
	if len(migrated) >= MOVEMENT_SCRIPT_CAPACITY {
		delete(migrated)
		return strings.clone("Migrated movement script is too large")
	}

	delete(saved.movement_script)
	saved.movement_script = migrated
	return ""
}

commit_tab_title :: proc(tab: ^Tab_State) {
	trimmed := strings.trim_space(buffer_string(tab.name_draft[:]))
	if trimmed == "" {
		title := fmt.tprintf("Untitled %d", tab.id)
		buffer_set(tab.name_draft[:], title)
		buffer_set(tab.name[:], title)
		return
	}
	title := strings.clone(trimmed)
	defer delete(title)
	buffer_set(tab.name_draft[:], title)
	buffer_set(tab.name[:], title)
}

load_tab_from_json :: proc(tab: ^Tab_State, data: []byte) -> string {
	saved := Saved_Tab{seed = 45, initial_angle_samples = 8}
	if err := json.unmarshal(data, &saved, allocator = context.allocator); err != nil {
		return strings.clone("Invalid JSON file.")
	}
	defer free_saved_tab(&saved)

	if strings.trim_space(saved.movement_script) == "" {
		legacy: Legacy_Saved_Tab
		if err := json.unmarshal(data, &legacy, allocator = context.allocator); err != nil {
			return strings.clone("Invalid legacy JSON file.")
		}
		defer free_legacy_saved_tab(&legacy)

		movement_script, migration_err := legacy_table_to_movement_script(&legacy)
		if migration_err != "" do return migration_err
		defer delete(movement_script)

		free_saved_tab(&saved)
		saved = legacy_to_saved_tab(&legacy, movement_script)
	}
	if globals_err := migrate_saved_global_table(&saved); globals_err != "" {
		return globals_err
	}

	if saved.obj_type < int(Objective_Type.X) || saved.obj_type > int(Objective_Type.Custom) {
		return strings.clone("Invalid field: currObj")
	}
	// Brief development builds stored Pancake + BFGS as engine value 3.
	if saved.continuous_optimizer == 3 {
		saved.continuous_optimizer = int(Continuous_Optimizer.Pancake)
		saved.pancake_recovery = int(Pancake_Recovery.BFGS)
	}
	if saved.continuous_optimizer < int(Continuous_Optimizer.BFGS) ||
	   saved.continuous_optimizer > int(Continuous_Optimizer.Pancake) {
		return strings.clone("Invalid field: continuousOptimizer")
	}
	if saved.pancake_recovery < int(Pancake_Recovery.Spine) ||
	   saved.pancake_recovery > int(Pancake_Recovery.BFGS) {
		return strings.clone("Invalid field: pancakeSecondary")
	}
	if strings.trim_space(saved.movement_script) == "" {
		return strings.clone("movementScript cannot be empty")
	}
	if saved.post.copy_separator < int(Separator_Type.Comma) ||
	   saved.post.copy_separator > int(Separator_Type.Newline) {
		return strings.clone("Invalid field: post.copySeparator")
	}
	if strings.trim_space(saved.post.x_origin) == "" {
		delete(saved.post.x_origin)
		saved.post.x_origin = legacy_origin_expr("X", saved.post.x_tick, saved.post.x_add)
	}
	if strings.trim_space(saved.post.z_origin) == "" {
		delete(saved.post.z_origin)
		saved.post.z_origin = legacy_origin_expr("Z", saved.post.z_tick, saved.post.z_add)
	}

	clear_solution(&tab.env)
	env := &tab.env
	env.maximize = saved.maximize
	env.discrete_search = saved.discrete_search
	env.cook = saved.cook
	env.chefs = clamp(saved.chefs, 1, 1000)
	env.seed = saved.seed
	env.multistart_on = saved.multistart || saved.try_preset_initial_angles
	env.seed_samples = clamp(saved.initial_angle_samples, 8, 256)
	env.continuous_optimizer = Continuous_Optimizer(saved.continuous_optimizer)
	env.pancake_recovery = Pancake_Recovery(saved.pancake_recovery)
	env.obj_type = Objective_Type(saved.obj_type)
	env.color_jump_ticks = true
	buffer_set(env.movement_script[:], saved.movement_script)
	buffer_set(env.objective_script[:], saved.objective_script)
	buffer_set(env.constraint_script[:], saved.constraint_script)

	buffer_set(env.post.x_origin[:], saved.post.x_origin)
	buffer_set(env.post.z_origin[:], saved.post.z_origin)
	env.post.copy_separator = Separator_Type(saved.post.copy_separator)
	env.post.include_initial_angle = saved.post.include_initial_angle
	env.post.position_precision = saved.post.position_precision

	title := strings.trim_space(saved.title)
	if title == "" {
		buffer_set(tab.name[:], fmt.tprintf("Untitled %d", tab.id))
	} else {
		buffer_set(tab.name[:], title)
	}
	buffer_set(tab.name_draft[:], buffer_string(tab.name[:]))
	buffer_clear(env.last_error[:])
	buffer_clear(tab.inline_save_message[:])
	tab.inline_save_is_error = false
	return ""
}

safe_file_name :: proc(raw_name: string) -> string {
	builder := strings.builder_make()
	name := strings.trim_space(raw_name)
	for ch in name {
		forbidden := ch == '/' || ch == '\\' || ch == ':' || ch == '*' ||
		             ch == '?' || ch == '"' || ch == '<' || ch == '>' || ch == '|'
		if forbidden || ch < 32 {
			strings.write_rune(&builder, '_')
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	result := strings.to_string(builder)
	for len(result) > 0 && (result[len(result)-1] == '.' || result[len(result)-1] == ' ') {
		result = result[:len(result)-1]
	}
	if result == "" do return strings.clone("Untitled")
	return strings.clone(result)
}

data_root :: proc() -> (string, os.Error) {
	custom, found := os.lookup_env("WOLFRAMMCPK_DATA_DIR", context.allocator)
	if found && custom != "" {
		return custom, nil
	}
	delete(custom)
	root, err := os.user_data_dir(context.allocator)
	if err != nil do return "", err
	defer delete(root)
	return os.join_path({root, APP_NAME}, context.allocator)
}

tabs_directory :: proc() -> (string, os.Error) {
	root, err := data_root()
	if err != nil do return "", err
	defer delete(root)
	return os.join_path({root, PRESET_FOLDER}, context.allocator)
}

preference_path :: proc() -> (string, os.Error) {
	root, err := data_root()
	if err != nil do return "", err
	defer delete(root)
	return os.join_path({root, PREFERENCE_FILE}, context.allocator)
}

save_tab_to_file :: proc(tab: ^Tab_State) -> string {
	commit_tab_title(tab)

	dir, dir_err := tabs_directory()
	if dir_err != nil do return fmt.aprintf("Failed to find data directory: %v", dir_err)
	defer delete(dir)
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		return fmt.aprintf("Failed to create %s", dir)
	}

	base_name := safe_file_name(buffer_string(tab.name[:]))
	defer delete(base_name)
	file_name := fmt.aprintf("%s.json", base_name)
	defer delete(file_name)
	path, path_err := os.join_path({dir, file_name}, context.allocator)
	if path_err != nil do return fmt.aprintf("Failed to create preset path: %v", path_err)
	defer delete(path)

	old_name := buffer_string(tab.saved_file_name[:])
	is_rename_target := old_name != file_name
	if is_rename_target && os.is_file(path) {
		return fmt.aprintf("Name already taken: %s. Choose another title.", file_name)
	}

	data, json_err := build_tab_json(tab, true)
	if json_err != "" do return json_err
	defer delete(data)
	if write_err := os.write_entire_file(path, data); write_err != nil {
		return fmt.aprintf("Failed to write %s", path)
	}

	if is_rename_target && old_name != "" {
		old_path, old_path_err := os.join_path({dir, old_name}, context.allocator)
		if old_path_err == nil {
			defer delete(old_path)
			if os.is_file(old_path) {
				if remove_err := os.remove(old_path); remove_err != nil {
					return fmt.aprintf(
						"Saved to %s, but failed to remove old file: %s",
						file_name,
						old_name,
					)
				}
			}
		}
	}
	buffer_set(tab.saved_file_name[:], file_name)
	fingerprint := build_tab_fingerprint(tab)
	defer delete(fingerprint)
	buffer_set(tab.saved_fingerprint[:], fingerprint)
	return ""
}

load_tab_from_file :: proc(tab: ^Tab_State, path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return strings.clone("Load failed: unable to open file.")
	defer delete(data)
	if load_err := load_tab_from_json(tab, data); load_err != "" do return load_err

	filename := filepath.base(path)
	buffer_set(tab.saved_file_name[:], filename)
	fingerprint := build_tab_fingerprint(tab)
	defer delete(fingerprint)
	buffer_set(tab.saved_fingerprint[:], fingerprint)
	return ""
}

seed_bundled_presets :: proc() {
	source := "presets/saves/c4.5 p2p.json"
	if !os.is_file(source) do return
	dir, dir_err := tabs_directory()
	if dir_err != nil do return
	defer delete(dir)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return
	destination, path_err := os.join_path({dir, "c4.5 p2p.json"}, context.allocator)
	if path_err != nil do return
	defer delete(destination)
	if os.is_file(destination) do return
	data, read_err := os.read_entire_file(source, context.allocator)
	if read_err != nil do return
	defer delete(data)
	_ = os.write_entire_file(destination, data)
}

save_preferences :: proc(app: ^App_State) {
	path, path_err := preference_path()
	if path_err != nil do return
	defer delete(path)
	root, root_err := data_root()
	if root_err != nil do return
	defer delete(root)
	if os.make_directory_all(root) != nil && !os.is_dir(root) do return

	data, err := json.marshal(
		Preferences{
			theme_index = int(app.theme),
			ui_size_level = app.ui_size_level,
		},
		{pretty = true, use_spaces = true, spaces = 2},
		context.allocator,
	)
	if err != nil do return
	defer delete(data)
	_ = os.write_entire_file(path, data)
}

load_preferences :: proc(app: ^App_State) {
	path, path_err := preference_path()
	if path_err != nil do return
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return
	defer delete(data)
	preferences: Preferences
	if json.unmarshal(data, &preferences, allocator = context.allocator) != nil do return
	app.theme = Theme(clamp(preferences.theme_index, int(Theme.Obsidian), int(Theme.Crimson_Forest)))
	if preferences.ui_size_level == 0 do preferences.ui_size_level = 2
	app.ui_size_level = clamp(preferences.ui_size_level, 1, 3)
}
