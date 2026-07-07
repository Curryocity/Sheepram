package app

import "core:fmt"
import "core:math"
import "core:strings"
import dsl "../dsl"
import opt "../optimizer"

Legacy_Saved_Post :: struct {
	x_tick:             string   `json:"xTick"`,
	x_add:              string   `json:"xAdd"`,
	z_tick:             string   `json:"zTick"`,
	z_add:              string   `json:"zAdd"`,
	angle_offset:       []string `json:"angleOffset"`,
	offset_mode:        int      `json:"offsetMode"`,
	copy_separator:     int      `json:"copySeparator"`,
	position_precision: int      `json:"positionPrecision"`,
}

Legacy_Saved_Tab :: struct {
	title:             string            `json:"title"`,
	maximize:          bool              `json:"maximize"`,
	curr_obj:          int               `json:"currObj"`,
	n:                 int               `json:"n"`,
	init_v:            string            `json:"initV"`,
	drag_x:            []string          `json:"dragX"`,
	drag_z:            []string          `json:"dragZ"`,
	accel:             []string          `json:"accel"`,
	global_names:      []string          `json:"globalNames"`,
	global_values:     []string          `json:"globalValues"`,
	obj_script:        string            `json:"objScript"`,
	constraint_script: string            `json:"constraintScript"`,
	post:              Legacy_Saved_Post `json:"post"`,
}

free_legacy_saved_tab :: proc(saved: ^Legacy_Saved_Tab) {
	for value in saved.drag_x do delete(value)
	for value in saved.drag_z do delete(value)
	for value in saved.accel do delete(value)
	for value in saved.global_names do delete(value)
	for value in saved.global_values do delete(value)
	for value in saved.post.angle_offset do delete(value)
	delete(saved.title)
	delete(saved.init_v)
	delete(saved.drag_x)
	delete(saved.drag_z)
	delete(saved.accel)
	delete(saved.global_names)
	delete(saved.global_values)
	delete(saved.obj_script)
	delete(saved.constraint_script)
	delete(saved.post.x_tick)
	delete(saved.post.x_add)
	delete(saved.post.z_tick)
	delete(saved.post.z_add)
	delete(saved.post.angle_offset)
	saved^ = {}
}

legacy_values_equal :: proc(a, b: f64) -> bool {
	return math.abs(a-b) <= 1e-12
}

legacy_origin_expr :: proc(axis, tick, add: string) -> string {
	clean_tick := strings.trim_space(tick)
	clean_add := strings.trim_space(add)
	if clean_tick == "" do clean_tick = "0"
	if clean_add == "" do clean_add = "0"
	return fmt.aprintf("%s[%s] + (%s)", axis, clean_tick, clean_add)
}

write_legacy_number :: proc(builder: ^strings.Builder, value: f64) {
	rounded := math.round(value*100000)/100000
	fmt.sbprintf(builder, "%.5f", rounded)
	for len(builder.buf) > 0 && builder.buf[len(builder.buf)-1] == '0' {
		resize(&builder.buf, len(builder.buf)-1)
	}
	if len(builder.buf) > 0 && builder.buf[len(builder.buf)-1] == '.' {
		resize(&builder.buf, len(builder.buf)-1)
	}
}

legacy_expr_uses_variable :: proc(text: string) -> bool {
	for c in text {
		if c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' {
			return true
		}
	}
	return false
}

write_legacy_expr :: proc(
	builder: ^strings.Builder,
	source: string,
	value: f64,
) {
	trimmed := strings.trim_space(source)
	if legacy_expr_uses_variable(trimmed) {
		strings.write_string(builder, trimmed)
	} else {
		write_legacy_number(builder, value)
	}
}

legacy_table_to_movement_script :: proc(saved: ^Legacy_Saved_Tab) -> (string, string) {
	if saved.n < N_MIN {
		return "", fmt.aprintf("Legacy preset has invalid n: %d", saved.n)
	}
	if len(saved.drag_x) != saved.n ||
	   len(saved.drag_z) != saved.n ||
	   len(saved.accel) != saved.n {
		return "", strings.clone("Legacy dragX/dragZ/accel sizes must match n")
	}
	if len(saved.global_names) != len(saved.global_values) {
		return "", strings.clone("Legacy globalNames/globalValues size mismatch")
	}
	model := opt.Model{n = saved.n+1}
	parser := dsl.init_parser_without_n(&model)
	defer dsl.destroy(&parser)

	if err := dsl.add_variable(&parser, "initV", saved.init_v); err != "" {
		return "", fmt.aprintf("Legacy initV: %s", err)
	}
	for i in 0..<len(saved.global_names) {
		if err := dsl.add_variable(
			&parser,
			saved.global_names[i],
			saved.global_values[i],
		); err != "" {
			return "", fmt.aprintf("Legacy global variable %d: %s", i, err)
		}
	}
	for value, i in saved.post.angle_offset {
		trimmed := strings.trim_space(value)
		if trimmed == "" do continue
		offset, offset_err := dsl.parse_constant(&parser, trimmed)
		if offset_err != "" {
			return "", fmt.aprintf("Legacy angleOffset[%d]: %s", i, offset_err)
		}
		if !legacy_values_equal(offset, 0) {
			return "", strings.clone(
				"Legacy preset uses manual angle offsets, which cannot be migrated automatically",
			)
		}
	}

	_, err := dsl.parse_constant(&parser, saved.init_v)
	if err != "" do return "", fmt.aprintf("Legacy initV: %s", err)

	drag_x := make([dynamic]f64, saved.n)
	drag_z := make([dynamic]f64, saved.n)
	accel := make([dynamic]f64, saved.n)
	defer delete(drag_x)
	defer delete(drag_z)
	defer delete(accel)

	for i in 0..<saved.n {
		drag_x[i], err = dsl.parse_constant(&parser, saved.drag_x[i])
		if err != "" do return "", fmt.aprintf("Legacy dragX[%d]: %s", i, err)
		drag_z[i], err = dsl.parse_constant(&parser, saved.drag_z[i])
		if err != "" do return "", fmt.aprintf("Legacy dragZ[%d]: %s", i, err)
		accel[i], err = dsl.parse_constant(&parser, saved.accel[i])
		if err != "" do return "", fmt.aprintf("Legacy accel[%d]: %s", i, err)
	}

	if !legacy_values_equal(drag_x[0], drag_z[0]) {
		return "", strings.clone(
			"Legacy first tick has unequal X/Z drag and cannot be migrated automatically",
		)
	}
	if drag_x[0] < 0 {
		return "", strings.clone("Legacy first-tick drag cannot be negative")
	}

	builder := strings.builder_make()
	if legacy_values_equal(drag_x[0], 0.91) {
		strings.write_string(&builder, "initAir(")
		write_legacy_expr(&builder, saved.init_v, accel[0])
		strings.write_byte(&builder, ')')
	} else {
		init_slip := drag_x[0]/0.91
		if math.abs(init_slip-0.6) > 1e-7 {
			strings.write_string(&builder, "slip(")
			if legacy_expr_uses_variable(saved.drag_x[0]) {
				strings.write_byte(&builder, '(')
				strings.write_string(&builder, strings.trim_space(saved.drag_x[0]))
				strings.write_string(&builder, ")/0.91")
			} else {
				write_legacy_number(&builder, init_slip)
			}
			strings.write_string(&builder, ") ")
		}
		strings.write_string(&builder, "initGnd(")
		write_legacy_expr(&builder, saved.init_v, accel[0])
		strings.write_byte(&builder, ')')
	}

	i := 1
	for i < saved.n {
		if !legacy_values_equal(drag_x[i], drag_z[i]) &&
		   !legacy_values_equal(drag_x[i], 0) &&
		   !legacy_values_equal(drag_z[i], 0) {
			strings.builder_destroy(&builder)
			return "", fmt.aprintf(
				"Legacy tick %d has unequal nonzero X/Z drag and cannot be migrated automatically",
				i,
			)
		}

		base_drag := drag_x[i]
		base_drag_source := saved.drag_x[i]
		force_x := false
		force_z := false
		if legacy_values_equal(drag_x[i], 0) &&
		   !legacy_values_equal(drag_z[i], 0) {
			base_drag = drag_z[i]
			base_drag_source = saved.drag_z[i]
			force_x = true
		} else if legacy_values_equal(drag_z[i], 0) &&
		          !legacy_values_equal(drag_x[i], 0) {
			base_drag = drag_x[i]
			base_drag_source = saved.drag_x[i]
			force_z = true
		}

		duration := 1
		for i+duration < saved.n {
			next := i+duration
			if !legacy_values_equal(drag_x[next], base_drag) ||
			   !legacy_values_equal(drag_z[next], base_drag) ||
			   !legacy_values_equal(accel[next], accel[i]) ||
			   strings.trim_space(saved.drag_x[next]) != strings.trim_space(base_drag_source) ||
			   strings.trim_space(saved.drag_z[next]) != strings.trim_space(base_drag_source) ||
			   strings.trim_space(saved.accel[next]) != strings.trim_space(saved.accel[i]) {
				break
			}
			duration += 1
		}

		strings.write_byte(&builder, ' ')
		if force_x do strings.write_string(&builder, "ix ")
		if force_z do strings.write_string(&builder, "iz ")
		strings.write_string(&builder, "mv(")
		write_legacy_expr(&builder, base_drag_source, base_drag)
		strings.write_string(&builder, ", ")
		write_legacy_expr(&builder, saved.accel[i], accel[i])
		if duration > 1 do fmt.sbprintf(&builder, ", %d", duration)
		strings.write_byte(&builder, ')')
		i += duration
	}
	strings.write_string(&builder, " st")

	script := strings.to_string(builder)
	if len(script) >= MOVEMENT_SCRIPT_CAPACITY {
		delete(script)
		return "", strings.clone("Migrated movement script is too large")
	}
	return script, ""
}

legacy_to_saved_tab :: proc(legacy: ^Legacy_Saved_Tab, movement_script: string) -> Saved_Tab {
	saved := Saved_Tab {
		title             = strings.clone(legacy.title),
		maximize          = legacy.maximize,
		initial_angle_deg = 45,
		initial_angle_samples = 8,
		curr_obj          = legacy.curr_obj,
		movement_script   = strings.clone(movement_script),
		global_names      = make([]string, len(legacy.global_names)),
		global_values     = make([]string, len(legacy.global_values)),
		obj_script        = strings.clone(legacy.obj_script),
		constraint_script = strings.clone(legacy.constraint_script),
		post = {
			x_origin           = legacy_origin_expr(
				"X",
				legacy.post.x_tick,
				legacy.post.x_add,
			),
			z_origin           = legacy_origin_expr(
				"Z",
				legacy.post.z_tick,
				legacy.post.z_add,
			),
			copy_separator     = legacy.post.copy_separator,
			position_precision = legacy.post.position_precision,
		},
	}
	for i in 0..<len(legacy.global_names) {
		saved.global_names[i] = strings.clone(legacy.global_names[i])
		saved.global_values[i] = strings.clone(legacy.global_values[i])
	}
	return saved
}
