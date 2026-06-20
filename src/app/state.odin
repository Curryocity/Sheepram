package app

import "core:fmt"
import "core:math"
import "core:time"
import opt "../optimizer"
import dsl "../dsl"

N_MIN :: 1
N_MAX :: 256
MAX_TABS :: 16
MAX_GLOBALS :: 128

CELL_CAPACITY :: 64
NAME_CAPACITY :: 128
SCRIPT_CAPACITY :: 8192
ERROR_CAPACITY :: 8192
STATUS_CAPACITY :: 512
FINGERPRINT_CAPACITY :: 131072

Objective_Type :: enum {
	X,
	Z,
	Custom,
}

Offset_Type :: enum {
	Facing,
	Turn,
}

Separator_Type :: enum {
	Comma,
	Space,
	Newline,
}

Theme :: enum {
	Obsidian,
	Curry,
	Luminous_Abyss,
	Cherry_Blossom,
	Crimson_Forest,
}

Post_State :: struct {
	x_tick:             [CELL_CAPACITY]byte,
	x_add:              [CELL_CAPACITY]byte,
	z_tick:             [CELL_CAPACITY]byte,
	z_add:              [CELL_CAPACITY]byte,
	angle_offset:       [N_MAX][CELL_CAPACITY]byte,
	offset_mode:        Offset_Type,
	copy_separator:     Separator_Type,
	position_precision: int,
}

Environment :: struct {
	maximize: bool,

	curr_obj:  Objective_Type,
	dir_x:     [CELL_CAPACITY]byte,
	dir_z:     [CELL_CAPACITY]byte,
	obj_script:[SCRIPT_CAPACITY]byte,

	n:      int,
	edit_n: int,

	init_v: [CELL_CAPACITY]byte,
	drag_x: [N_MAX][CELL_CAPACITY]byte,
	drag_z: [N_MAX][CELL_CAPACITY]byte,
	accel:  [N_MAX][CELL_CAPACITY]byte,

	var_capacity: int,
	global_names:  [MAX_GLOBALS][CELL_CAPACITY]byte,
	global_values: [MAX_GLOBALS][CELL_CAPACITY]byte,

	constraint_script: [SCRIPT_CAPACITY]byte,
	post:              Post_State,

	last_solution: ^opt.Solution,
	solution_n:    int,
	compile_time_seconds:  f64,
	optimize_time_seconds: f64,
	x_index:       int,
	z_index:       int,
	x_add:         f64,
	z_add:         f64,
	angle_offset:  [N_MAX]f64,
	last_error:    [ERROR_CAPACITY]byte,
}

Tab_State :: struct {
	id:                  int,
	name:                [NAME_CAPACITY]byte,
	name_draft:          [NAME_CAPACITY]byte,
	saved_fingerprint:   [FINGERPRINT_CAPACITY]byte,
	saved_file_name:     [NAME_CAPACITY]byte,
	inline_save_message: [STATUS_CAPACITY]byte,
	inline_save_is_error:bool,
	env:                 Environment,
	left_width:          f32,
	cons_editor_height:  f32,
	prev_n:              int, // Exist to prevent table resize on every frame.
	selected_model_tick_index: int,
	selected_global_var_index: int,
	model_region_min: [2]f32,
	model_region_max: [2]f32,
	optimizer_job: ^Optimizer_Job,
}

App_State :: struct {
	theme:                Theme,
	ui_size_level:        int,
	tabs:                 [MAX_TABS]^Tab_State,
	tab_count:            int,
	active_tab:           int,
	next_tab_id:          int,
	pending_close_tab_id: int,
	close_popup_error:    [ERROR_CAPACITY]byte,
}

clear_solution :: proc(state: ^Environment) {
	if state.last_solution != nil {
		opt.destroy_solution(state.last_solution)
		free(state.last_solution)
		state.last_solution = nil
	}
	state.solution_n = 0
	state.compile_time_seconds = 0
	state.optimize_time_seconds = 0
}

destroy_tab :: proc(tab: ^Tab_State) {
	destroy_optimizer_job(tab)
	clear_solution(&tab.env)
	free(tab)
}

destroy_app :: proc(app: ^App_State) {
	for i in 0..<app.tab_count {
		if app.tabs[i] != nil do destroy_tab(app.tabs[i])
	}
	app^ = {}
}

init_model :: proc(state: ^Environment) {
	state.n = clamp(state.n, N_MIN, N_MAX)
	// Defaults to delayed WAD
	for i in 0..<state.n {
		if i < 2 {
			buffer_set(state.drag_x[i][:], "gnd")
			buffer_set(state.drag_z[i][:], "gnd")
		} else {
			buffer_set(state.drag_x[i][:], "air")
			buffer_set(state.drag_z[i][:], "air")
		}

		if i == 0 {
			buffer_set(state.accel[i][:], "initV")
		} else if i == 1 {
			buffer_set(state.accel[i][:], "WAD")
		} else {
			buffer_set(state.accel[i][:], "sa45")
		}
	}
}

init_globals :: proc(state: ^Environment) {
	// varCapacity defaults to 9
	state.var_capacity = 9
	default_names := [?]string{"gnd", "air", "s45", "sa45", "WAD", "WAWD", "m", "m2", ""}
	default_values := [?]string{
		"0.546",
		"0.91",
		"0.13",
		"0.026",
		"0.3274",
		"0.3060547988254277",
		"2",
		"8",
		"",
	}
	for i in 0..<state.var_capacity {
		buffer_set(state.global_names[i][:], default_names[i])
		buffer_set(state.global_values[i][:], default_values[i])
	}
}

make_default_tab :: proc(tab_id: int) -> ^Tab_State {
	tab := new(Tab_State)
	tab.id = tab_id
	buffer_set(tab.name[:], fmt.tprintf("Untitled %d", tab_id))
	buffer_set(tab.name_draft[:], buffer_string(tab.name[:]))
	tab.env.curr_obj = .X
	tab.env.n = 12
	tab.env.edit_n = 12
	tab.env.var_capacity = 9
	tab.env.post.position_precision = 6
	buffer_set(tab.env.dir_x[:], "0")
	buffer_set(tab.env.dir_z[:], "0")
	buffer_set(
		tab.env.obj_script[:],
		"Optimize along vec(a, b) := a * (X[t1] - X[t0]) + b * (Z[t1] - Z[t0])",
	)
	buffer_set(tab.env.init_v[:], "0.3169516131491288")
	buffer_set(
		tab.env.constraint_script[:],
		"// c4.5 p2p\n" +
		"X[m] - X[0] > 7/16\n" +
		"X[m2] - X[0] > 7/16\n" +
		"Z[m2] - Z[m-1] > 1 + 0.6000000238418579\n",
	)
	buffer_set(tab.env.post.x_tick[:], "0")
	buffer_set(tab.env.post.x_add[:], "0")
	buffer_set(tab.env.post.z_tick[:], "m-1")
	buffer_set(tab.env.post.z_add[:], "0")
	for i in 0..<tab.env.n do buffer_set(tab.env.post.angle_offset[i][:], "0")
	init_model(&tab.env)
	init_globals(&tab.env)
	tab.prev_n = tab.env.n
	tab.selected_model_tick_index = -1
	tab.selected_global_var_index = -1
	tab.cons_editor_height = 120
	fingerprint := build_tab_fingerprint(tab)
	buffer_set(tab.saved_fingerprint[:], fingerprint)
	delete(fingerprint)
	return tab
}

init_app :: proc() -> ^App_State {
	app := new(App_State)
	app.theme = .Obsidian
	app.ui_size_level = 2
	app.next_tab_id = 1
	app.pending_close_tab_id = -1
	app.tabs[0] = make_default_tab(app.next_tab_id)
	app.next_tab_id += 1
	app.tab_count = 1
	return app
}

set_error :: proc(state: ^Environment, message: string) {
	clear_solution(state)
	buffer_set(state.last_error[:], message)
}

run_optimizer :: proc(state: ^Environment) {
	clear_solution(state)
	buffer_clear(state.last_error[:])
	if state.n < N_MIN || state.n > N_MAX {
		set_error(
			state,
			fmt.tprintf("Error:\nInvalid n: %d (expected range: %d to %d)", state.n, N_MIN, N_MAX),
		)
		return
	}
	compile_start := time.tick_now()

	// 1. Define the internal n
	n := state.n+1
	model := opt.Model {
		n      = n,
		drag_x = make([dynamic]f64, n),
		drag_z = make([dynamic]f64, n),
		accel  = make([dynamic]f64, n),
	}
	defer opt.destroy_model(&model)

	// 2. Initialize parser(varTables, Expr sizes)
	parser := dsl.init_parser(&model)
	defer dsl.destroy(&parser)
	init_v, err := dsl.parse_constant(&parser, buffer_string(state.init_v[:]))
	if err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", err))
		delete(err)
		return
	}
	model.init_v = init_v
	dsl.define_init_v(&parser, model.init_v)
	for i in 0..<state.var_capacity {
		err = dsl.add_variable(
			&parser,
			buffer_string(state.global_names[i][:]),
			buffer_string(state.global_values[i][:]),
		)
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}

	// 3. Evaluate drag/accel scripts to constants
	for i in 0..<model.n-1 {
		model.drag_x[i], err = dsl.parse_constant(&parser, buffer_string(state.drag_x[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
		model.drag_z[i], err = dsl.parse_constant(&parser, buffer_string(state.drag_z[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}
	for i in 1..<model.n-1 {
		model.accel[i], err = dsl.parse_constant(&parser, buffer_string(state.accel[i][:]))
		if err != "" {
			set_error(state, fmt.tprintf("Error:\n%s", err))
			delete(err)
			return
		}
	}

	// 4. Compile movement formulas
	opt.compile_model(&model)

	// 5. Parse objective
	objective: opt.Compiled_Expr
	switch state.curr_obj {
	case .X:
		objective, err = dsl.parse_expr(&parser, "X[n]")
	case .Z:
		objective, err = dsl.parse_expr(&parser, "Z[n]")
	case .Custom:
		objective, err = dsl.parse_expr(&parser, buffer_string(state.obj_script[:]))
	}
	if err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", err))
		delete(err)
		return
	}
	defer opt.destroy_compiled_expr(&objective)

	// Invert objective when maximizing
	if state.maximize {
		inverted := dsl.scale_expr(objective, -1)
		opt.destroy_compiled_expr(&objective)
		objective = inverted
	}

	// 6. Parse constraints
	constraints, constraint_err := dsl.parse_multi_constraints(
		&parser,
		buffer_string(state.constraint_script[:]),
	)
	if constraint_err != "" {
		set_error(state, fmt.tprintf("Error:\n%s", constraint_err))
		delete(constraint_err)
		return
	}
	defer dsl.destroy_constraints(&constraints)

	// 7. Build problem
	problem := opt.build_problem(&model, objective, constraints[:])
	defer opt.destroy_problem(&problem)
	state.compile_time_seconds = time.duration_seconds(time.tick_since(compile_start))

	// 8. Optimize
	solution := new(opt.Solution)
	optimize_start := time.tick_now()
	solution^ = opt.optimize(&model, &problem)
	state.optimize_time_seconds = time.duration_seconds(time.tick_since(optimize_start))
	if state.maximize {
		solution.optimum *= -1 // Invert solution again when maximizing
	}

	// 9. PostProcessor settings
	x_tick, post_err := dsl.parse_constant(&parser, buffer_string(state.post.x_tick[:]))
	if post_err == "" {
		state.x_index = int(math.round(x_tick))
		state.x_add, post_err = dsl.parse_constant(&parser, buffer_string(state.post.x_add[:]))
	}
	if post_err == "" {
		z_tick: f64
		z_tick, post_err = dsl.parse_constant(&parser, buffer_string(state.post.z_tick[:]))
		state.z_index = int(math.round(z_tick))
	}
	if post_err == "" {
		state.z_add, post_err = dsl.parse_constant(&parser, buffer_string(state.post.z_add[:]))
	}
	if post_err == "" {
		for i in 0..<state.n {
			state.angle_offset[i], post_err = dsl.parse_constant(
				&parser,
				buffer_string(state.post.angle_offset[i][:]),
			)
			if post_err != "" do break
		}
	}
	if post_err == "" && state.post.offset_mode == .Turn {
		accumulation := 0.0
		for i in 0..<state.n {
			accumulation += state.angle_offset[i]
			state.angle_offset[i] = accumulation
		}
	}
	if post_err == "" &&
	   (state.x_index < 0 || state.x_index >= n || state.z_index < 0 || state.z_index >= n) {
		post_err = fmt.aprintf("Out of bound access")
	}
	if post_err != "" {
		opt.destroy_solution(solution)
		free(solution)
		set_error(state, fmt.tprintf("Error:\nPostprocessor:\n%s", post_err))
		delete(post_err)
		return
	}

	state.last_solution = solution
	state.solution_n = state.n
}
