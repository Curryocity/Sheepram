package app

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import dsl "../dsl"
import opt "../optimizer"

duplicate_save_name :: proc(source: string, rotation: int) -> string {
	base := source
	total := rotation
	open := strings.last_index(source, "(")
	if open >= 0 && len(source)-open >= 4 && source[len(source)-1] == ')' {
		suffix := source[open+1:len(source)-1]
		signed_number := suffix[0] == '+' || suffix[0] == '-'
		for ch in suffix[1:] {
			if ch < '0' || ch > '9' do signed_number = false
		}
		if signed_number {
			previous, ok := strconv.parse_int(suffix, 10)
			if ok && ((rotation >= 0 && previous <= max(int)-rotation) || (rotation < 0 && previous >= min(int)-rotation)) {
				base = strings.trim_right_space(source[:open])
				total += previous
			}
		}
	}
	if base == "" do return fmt.aprintf("(%+d)", total)
	return fmt.aprintf("%s (%+d)", base, total)
}

// Returns the old axis expressed in the rotated coordinate system.
rotated_axis :: proc(axis: string, turns: int) -> (string, bool) {
	orientation := (turns%4+4)%4
	is_x := axis == "X" || axis == "Vx"
	negative := (is_x && (orientation == 1 || orientation == 2)) || (!is_x && (orientation == 2 || orientation == 3))
	if orientation%2 == 0 do return axis, negative
	switch axis {
	case "X": return "Z", negative
	case "Z": return "X", negative
	case "Vx": return "Vz", negative
	case "Vz": return "Vx", negative
	}
	return axis, negative
}

step_duplicate_rotation :: proc(rotation, direction: int) -> int {
	rounded := int(math.round(f64(rotation)/90))*90
	// Keep stepped values within ImGui's signed 32-bit input.
	return clamp(rounded+direction*90, -2147483610, 2147483610)
}

rotation_comment_newline :: proc(text: string) -> string {
	last_line := text[strings.last_index(text, "\n")+1:]
	return "\n" if strings.contains(last_line, "//") else ""
}

rotate_save_text :: proc(source: string, turns: int, movement := false) -> (string, string) {
	if turns == 0 do return strings.clone(source), ""
	orientation := (turns%4+4)%4
	shift := turns*90
	magnitude := shift if shift >= 0 else -shift
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	lexer := dsl.Lexer{data = source}
	copied := 0
	for {
		token := dsl.lexer_next(&lexer)
		if token.type == .End do break
		if token.type == .Invalid do return "", fmt.aprintf("Cannot rotate invalid token: %s", token.text)
		if token.type != .Identifier do continue
		start := lexer.pos-len(token.text)
		name := token.text
		look := lexer
		next := dsl.lexer_next(&look)
		if !movement && next.type == .L_Bracket && (name == "X" || name == "Z" || name == "Vx" || name == "Vz" || name == "F") {
			depth := 1
			for depth > 0 {
				part := dsl.lexer_next(&look)
				if part.type == .End || part.type == .Invalid do return "", strings.clone("Cannot rotate an incomplete indexed expression.")
				if part.type == .L_Bracket do depth += 1
				if part.type == .R_Bracket do depth -= 1
			}
			strings.write_string(&builder, source[copied:start])
			suffix := source[start+len(name):look.pos]
			if name == "F" {
				fmt.sbprintf(&builder, "(F%s %s %d)", suffix, "-" if shift > 0 else "+", magnitude)
			} else {
				axis, negative := rotated_axis(name, turns)
				if negative do strings.write_string(&builder, "(-")
				strings.write_string(&builder, axis)
				strings.write_string(&builder, suffix)
				if negative do strings.write_byte(&builder, ')')
			}
			copied = look.pos
			lexer = look
		} else if movement && orientation%2 == 1 && (name == "wx" || name == "wz") {
			strings.write_string(&builder, source[copied:start])
			strings.write_string(&builder, "wz" if name == "wx" else "wx")
			copied = lexer.pos
		} else if movement && (name == "initGnd" || name == "initAir") && next.type == .L_Paren {
			depth := 1
			angle_start := -1
			for depth > 0 {
				part := dsl.lexer_next(&look)
				if part.type == .End || part.type == .Invalid do return "", strings.clone("Cannot rotate an incomplete initialization command.")
				if part.type == .L_Paren do depth += 1
				if part.type == .R_Paren do depth -= 1
				if part.type == .Comma && depth == 1 {
					if angle_start >= 0 do return "", strings.clone("Initialization expects at most two arguments.")
					angle_start = look.pos
				}
			}
			if angle_start >= 0 {
				angle := source[angle_start:look.pos-1]
				strings.write_string(&builder, source[copied:angle_start])
				fmt.sbprintf(&builder, "(%s%s %s %d))", angle, rotation_comment_newline(angle), "+" if shift > 0 else "-", magnitude)
				copied = look.pos
			}
			lexer = look
		}
	}
	strings.write_string(&builder, source[copied:])
	return strings.clone(strings.to_string(builder)), ""
}

rotate_save_buffer :: proc(buffer: []byte, turns: int, movement := false) -> string {
	text, err := rotate_save_text(buffer_string(buffer), turns, movement)
	if err != "" do return err
	defer delete(text)
	if len(text) >= len(buffer) do return strings.clone("Rotated text exceeds the editor capacity.")
	buffer_set(buffer, text)
	return ""
}

rotate_save_environment :: proc(env: ^Environment, rotation: int) -> string {
	if rotation%90 != 0 do return strings.clone("Rotation must be a multiple of 90.")
	if rotation == 0 do return ""
	turns := rotation/90
	orientation := (turns%4+4)%4
	midpoint := env.facing_range_midpoint+f64(rotation)
	if !opt.valid_facing_range(midpoint) || midpoint < -opt.REGULAR_FACING_MIDPOINT_LIMIT || midpoint > opt.REGULAR_FACING_MIDPOINT_LIMIT {
		return strings.clone("Rotated yaw range midpoint must be between -1800 and 1800.")
	}
	if err := rotate_save_buffer(env.movement_script[:], turns, true); err != "" do return err
	if err := rotate_save_buffer(env.constraint_script[:], turns); err != "" do return err
	if err := rotate_save_buffer(env.objective_script[:], turns); err != "" do return err
	if env.obj_type != .Custom {
		axis := "X" if env.obj_type == .X else "Z"
		rotated, negative := rotated_axis(axis, turns)
		env.obj_type = .X if rotated == "X" else .Z
		if negative do env.maximize = !env.maximize
	}
	if err := rotate_save_buffer(env.post.x_origin[:], turns); err != "" do return err
	if err := rotate_save_buffer(env.post.z_origin[:], turns); err != "" do return err
	old_x, old_z := env.post.x_origin, env.post.z_origin
	x_origin := buffer_string(old_x[:])
	z_origin := buffer_string(old_z[:])
	if orientation%2 == 1 do x_origin, z_origin = z_origin, x_origin
	if orientation == 2 || orientation == 3 {
		x_origin = fmt.tprintf("(-(%s%s))", x_origin, rotation_comment_newline(x_origin))
	}
	if orientation == 1 || orientation == 2 {
		z_origin = fmt.tprintf("(-(%s%s))", z_origin, rotation_comment_newline(z_origin))
	}
	if len(x_origin) >= SCRIPT_CAPACITY || len(z_origin) >= SCRIPT_CAPACITY do return strings.clone("Rotated origin exceeds the editor capacity.")
	buffer_set(env.post.x_origin[:], x_origin)
	buffer_set(env.post.z_origin[:], z_origin)
	for _ in 0..<orientation {
		old := env.inertia_tick_lists
		env.inertia_tick_lists = {{old[1][0], old[1][1], old[1][2]}, {old[0][0], old[0][2], old[0][1]}}
		visible := env.inertia_tick_list_visible
		env.inertia_tick_list_visible = {{visible[1][0], visible[1][1], visible[1][2]}, {visible[0][0], visible[0][2], visible[0][1]}}
	}
	env.seed += f64(rotation)
	env.facing_range_midpoint = midpoint
	return ""
}

prepare_duplicate_tab :: proc(source: ^Tab_State, raw_name: string, rotation, tab_id: int) -> (^Tab_State, string) {
	name := strings.trim_space(raw_name)
	if len(name) >= 5 && strings.equal_fold(name[len(name)-5:], ".json") do name = name[:len(name)-5]
	if name == "" do return nil, strings.clone("Enter a new filename.")
	safe := safe_file_name(name)
	defer delete(safe)
	if safe != name do return nil, strings.clone("Filename contains unsupported characters or ends with a dot or space.")
	stem := name
	if dot := strings.index_byte(stem, '.'); dot >= 0 do stem = stem[:dot]
	for reserved in ([4]string{"CON", "PRN", "AUX", "NUL"}) {
		if strings.equal_fold(stem, reserved) do return nil, strings.clone("Filename is reserved by Windows.")
	}
	if len(stem) == 4 && stem[3] >= '1' && stem[3] <= '9' && (strings.equal_fold(stem[:3], "COM") || strings.equal_fold(stem[:3], "LPT")) {
		return nil, strings.clone("Filename is reserved by Windows.")
	}
	if len(name)+5 >= NAME_CAPACITY do return nil, strings.clone("Filename is too long.")
	data, encode_err := build_tab_json(source)
	if encode_err != "" do return nil, encode_err
	defer delete(data)
	copy := make_default_tab(tab_id)
	if err := load_tab_from_json(copy, data); err != "" {
		destroy_tab(copy)
		return nil, err
	}
	if err := rotate_save_environment(&copy.env, rotation); err != "" {
		destroy_tab(copy)
		return nil, err
	}
	buffer_set(copy.name[:], name)
	buffer_set(copy.name_draft[:], name)
	buffer_clear(copy.saved_file_name[:])
	return copy, ""
}

create_duplicate_save :: proc(app_state: ^App_State, filename: string, rotation: int, directory := "") -> string {
	if app_state.tab_count >= MAX_TABS do return strings.clone("Close a tab before creating a copy.")
	source := app_state.tabs[app_state.active_tab]
	copy, err := prepare_duplicate_tab(source, filename, rotation, app_state.next_tab_id)
	if err != "" do return err
	keep := false
	defer if !keep do destroy_tab(copy)
	data, json_err := build_tab_json(copy, true)
	if json_err != "" do return json_err
	defer delete(data)
	dir := strings.clone(directory)
	if dir == "" {
		dir_err: os.Error
		dir, dir_err = tabs_directory()
		if dir_err != nil do return fmt.aprintf("Failed to find saves folder: %v", dir_err)
	}
	defer delete(dir)
	if make_err := os.make_directory_all(dir); make_err != nil && !os.is_dir(dir) do return fmt.aprintf("Failed to create saves folder: %v", make_err)
	file_name := fmt.aprintf("%s.json", buffer_string(copy.name[:]))
	defer delete(file_name)
	path, path_err := os.join_path({dir, file_name}, context.allocator)
	if path_err != nil do return fmt.aprintf("Failed to create save path: %v", path_err)
	defer delete(path)
	file, open_err := os.open(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL)
	if open_err != nil {
		if os.is_file(path) do return fmt.aprintf("Name already taken: %s. Choose another filename.", file_name)
		return fmt.aprintf("Failed to create %s: %v", file_name, open_err)
	}
	written, write_err := os.write(file, data)
	close_err := os.close(file)
	if write_err != nil || written != len(data) || close_err != nil {
		_ = os.remove(path)
		return fmt.aprintf("Failed to write %s.", file_name)
	}
	buffer_set(copy.saved_file_name[:], file_name)
	fingerprint := build_tab_fingerprint(copy)
	defer delete(fingerprint)
	buffer_set(copy.saved_fingerprint[:], fingerprint)
	buffer_set(copy.inline_save_message[:], fmt.tprintf("Created: %s", file_name))
	app_state.tabs[app_state.tab_count] = copy
	app_state.active_tab = app_state.tab_count
	app_state.tab_count += 1
	app_state.next_tab_id += 1
	app_state.pending_select_tab_id = copy.id
	keep = true
	return ""
}
