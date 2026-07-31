package app

import "core:fmt"
import opt "../optimizer"

N_MIN :: 1
MAX_TABS :: 16

NAME_CAPACITY :: 128
SCRIPT_CAPACITY :: 8192
MOVEMENT_SCRIPT_CAPACITY :: 32768
ERROR_CAPACITY :: 8192
STATUS_CAPACITY :: 512
FINGERPRINT_CAPACITY :: 131072
INERTIA_TICK_LIST_CAPACITY :: 512

Objective_Type :: enum {
	X,
	Z,
	Custom,
}

Continuous_Optimizer :: enum {
	BFGS,
	Spine,
	Pancake,
}

Pancake_Recovery :: enum {
	Spine,
	BFGS,
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
	x_origin:           [SCRIPT_CAPACITY]byte,
	z_origin:           [SCRIPT_CAPACITY]byte,
	copy_separator:     Separator_Type,
	include_initial_angle: bool,
	position_precision: int,
}

Inertia_Axis :: enum {
	X,
	Z,
}

Inertia_Choice :: enum {
	Lazy,
	Hit,
	Avoid_Minus,
	Avoid_Plus,
}

Environment :: struct {
	maximize: bool,
	discrete_search: bool,
	cook: bool,
	chefs: int,
	seed: f64,
	multistart_on: bool,
	seed_samples: int,
	continuous_optimizer: Continuous_Optimizer,
	pancake_recovery:     Pancake_Recovery,

	obj_type:         Objective_Type,
	objective_script: [SCRIPT_CAPACITY]byte,

	movement_script: [MOVEMENT_SCRIPT_CAPACITY]byte,

	constraint_script: [SCRIPT_CAPACITY]byte,
	post:              Post_State,

	last_solution: ^opt.Solution,
	last_solution_discrete: bool,
	last_solution_cooking: bool,
	last_solution_chefs_completed: int,
	last_solution_chefs_total: int,
	compile_time_seconds:  f64,
	continuous_time_seconds: f64,
	discrete_time_seconds:   f64,
	x_origin:      f64,
	z_origin:      f64,
	angle_offset:  [dynamic]f64,
	last_jump_ticks: [dynamic]bool,
	inertia_suspicious_factor: f64,
	inertia_threshold: f64,
	inertia_drag: [dynamic]f64,
	inertia_tick_lists: [2][3][INERTIA_TICK_LIST_CAPACITY]byte,
	inertia_tick_list_visible: [2][3]bool,
	inertia_mismatches_only: bool,
	color_jump_ticks: bool,
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
	state.last_solution_discrete = false
	state.last_solution_cooking = false
	state.last_solution_chefs_completed = 0
	state.last_solution_chefs_total = 0
	state.compile_time_seconds = 0
	state.continuous_time_seconds = 0
	state.discrete_time_seconds = 0
	delete(state.angle_offset)
	state.angle_offset = nil
	delete(state.last_jump_ticks)
	state.last_jump_ticks = nil
	delete(state.inertia_drag)
	state.inertia_drag = nil
	state.inertia_threshold = 0
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

make_default_tab :: proc(tab_id: int) -> ^Tab_State {
	tab := new(Tab_State)
	tab.id = tab_id
	buffer_set(tab.name[:], fmt.tprintf("Untitled %d", tab_id))
	buffer_set(tab.name_draft[:], buffer_string(tab.name[:]))
	tab.env.obj_type = .X
	tab.env.continuous_optimizer = .Pancake
	tab.env.chefs = 5
	tab.env.seed = 45
	tab.env.seed_samples = 8
	tab.env.inertia_suspicious_factor = 2
	tab.env.color_jump_ticks = true
	tab.env.post.position_precision = 6
	buffer_set(
		tab.env.objective_script[:],
		"X[n] - X[0]",
	)
	buffer_set(
		tab.env.movement_script[:],
		"initGnd(0.3169516131491288) sj.w sa.wa(11)\n" +
		"set(m, 2) set(m2, 8)\n" +
		"\n" +
		"// (>_<)",
	)
	buffer_set(
		tab.env.constraint_script[:],
		"// c4.5 p2p\n" +
		"X[m] - X[0] > 7/16\n" +
		"X[m2] - X[0] > 7/16\n" +
		"Z[m2] - Z[m-1] > 1 + bx\n",
	)
	buffer_set(tab.env.post.x_origin[:], "X[0]")
	buffer_set(tab.env.post.z_origin[:], "Z[m-1]")
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
