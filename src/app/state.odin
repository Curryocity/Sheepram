package app

import "core:fmt"
import opt "../optimizer"

N_MIN :: 1
N_MAX :: 256
MAX_TABS :: 16
MAX_GLOBALS :: 128

CELL_CAPACITY :: 64
NAME_CAPACITY :: 128
SCRIPT_CAPACITY :: 8192
MOVEMENT_SCRIPT_CAPACITY :: 32768
ERROR_CAPACITY :: 8192
STATUS_CAPACITY :: 512
FINGERPRINT_CAPACITY :: 131072

Objective_Type :: enum {
	X,
	Z,
	Custom,
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
	copy_separator:     Separator_Type,
	position_precision: int,
}

Environment :: struct {
	maximize: bool,

	curr_obj:  Objective_Type,
	dir_x:     [CELL_CAPACITY]byte,
	dir_z:     [CELL_CAPACITY]byte,
	obj_script:[SCRIPT_CAPACITY]byte,

	movement_script: [MOVEMENT_SCRIPT_CAPACITY]byte,

	var_capacity: int,
	global_names:  [MAX_GLOBALS][CELL_CAPACITY]byte,
	global_values: [MAX_GLOBALS][CELL_CAPACITY]byte,

	constraint_script: [SCRIPT_CAPACITY]byte,
	post:              Post_State,

	last_solution: ^opt.Solution,
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
	movement_editor_height: f32,
	cons_editor_height:  f32,
	selected_global_var_index: int,
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

init_globals :: proc(state: ^Environment) {
	state.var_capacity = 4
	default_names := [?]string{"m", "m2", "bx", ""}
	default_values := [?]string{
		"2",
		"8",
		"0.6000000238418579",
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
	tab.env.post.position_precision = 6
	buffer_set(tab.env.dir_x[:], "0")
	buffer_set(tab.env.dir_z[:], "0")
	buffer_set(
		tab.env.obj_script[:],
		"Optimize along vec(a, b) := a * (X[t1] - X[t0]) + b * (Z[t1] - Z[t0])",
	)
	buffer_set(
		tab.env.movement_script[:],
		"initGnd(0.3169516131491288) sj.w sa.wa(11)",
	)
	buffer_set(
		tab.env.constraint_script[:],
		"// c4.5 p2p\n" +
		"X[m] - X[0] > 7/16\n" +
		"X[m2] - X[0] > 7/16\n" +
		"Z[m2] - Z[m-1] > 1 + bx\n",
	)
	buffer_set(tab.env.post.x_tick[:], "0")
	buffer_set(tab.env.post.x_add[:], "0")
	buffer_set(tab.env.post.z_tick[:], "m-1")
	buffer_set(tab.env.post.z_add[:], "0")
	init_globals(&tab.env)
	tab.selected_global_var_index = -1
	tab.movement_editor_height = 86
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
