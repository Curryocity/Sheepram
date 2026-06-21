package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

APP_NAME :: "Sheepram"
PREFERENCE_FILE :: "preference.json"
PRESET_FOLDER :: "presets/saves"

Saved_Post :: struct {
	x_tick:             string   `json:"xTick"`,
	x_add:              string   `json:"xAdd"`,
	z_tick:             string   `json:"zTick"`,
	z_add:              string   `json:"zAdd"`,
	copy_separator:     int      `json:"copySeparator"`,
	position_precision: int      `json:"positionPrecision"`,
}

Saved_Tab :: struct {
	title:             string     `json:"title"`,
	maximize:          bool       `json:"maximize"`,
	curr_obj:          int        `json:"currObj"`,
	movement_script:   string     `json:"movementScript"`,
	global_names:      []string   `json:"globalNames"`,
	global_values:     []string   `json:"globalValues"`,
	obj_script:        string     `json:"objScript"`,
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
	delete(saved.obj_script)
	delete(saved.constraint_script)
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
		curr_obj          = int(env.curr_obj),
		movement_script   = buffer_string(env.movement_script[:]),
		global_names      = make([]string, env.var_capacity),
		global_values     = make([]string, env.var_capacity),
		obj_script        = buffer_string(env.obj_script[:]),
		constraint_script = buffer_string(env.constraint_script[:]),
		post = {
			x_tick             = buffer_string(env.post.x_tick[:]),
			x_add              = buffer_string(env.post.x_add[:]),
			z_tick             = buffer_string(env.post.z_tick[:]),
			z_add              = buffer_string(env.post.z_add[:]),
			copy_separator     = int(env.post.copy_separator),
			position_precision = env.post.position_precision,
		},
	}
	for i in 0..<env.var_capacity {
		saved.global_names[i] = buffer_string(env.global_names[i][:])
		saved.global_values[i] = buffer_string(env.global_values[i][:])
	}
	return saved
}

free_saved_view :: proc(saved: ^Saved_Tab) {
	// saved_from_tab only owns its slice containers; strings point into Tab_State.
	delete(saved.global_names)
	delete(saved.global_values)
	saved^ = {}
}

build_tab_json :: proc(tab: ^Tab_State, pretty := false) -> ([]byte, string) {
	saved := saved_from_tab(tab)
	defer free_saved_view(&saved)
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
	saved: Saved_Tab
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

	if saved.curr_obj < int(Objective_Type.X) || saved.curr_obj > int(Objective_Type.Custom) {
		return strings.clone("Invalid field: currObj")
	}
	if strings.trim_space(saved.movement_script) == "" {
		return strings.clone("movementScript cannot be empty")
	}
	if len(saved.global_names) != len(saved.global_values) {
		return strings.clone("globalNames/globalValues size mismatch")
	}
	if saved.post.copy_separator < int(Separator_Type.Comma) ||
	   saved.post.copy_separator > int(Separator_Type.Newline) {
		return strings.clone("Invalid field: post.copySeparator")
	}

	clear_solution(&tab.env)
	env := &tab.env
	env.maximize = saved.maximize
	env.curr_obj = Objective_Type(saved.curr_obj)
	buffer_set(env.movement_script[:], saved.movement_script)
	buffer_set(env.obj_script[:], saved.obj_script)
	buffer_set(env.constraint_script[:], saved.constraint_script)

	env.var_capacity = clamp(len(saved.global_names), 1, MAX_GLOBALS)
	for i in 0..<env.var_capacity {
		buffer_set(env.global_names[i][:], saved.global_names[i])
		buffer_set(env.global_values[i][:], saved.global_values[i])
	}
	if len(saved.global_names) == 0 {
		buffer_clear(env.global_names[0][:])
		buffer_clear(env.global_values[0][:])
	}

	buffer_set(env.post.x_tick[:], saved.post.x_tick)
	buffer_set(env.post.x_add[:], saved.post.x_add)
	buffer_set(env.post.z_tick[:], saved.post.z_tick)
	buffer_set(env.post.z_add[:], saved.post.z_add)
	env.post.copy_separator = Separator_Type(saved.post.copy_separator)
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
