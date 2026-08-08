package app

import "core:c"
import "core:fmt"
import "core:strings"

import im "../../third_party/odin-imgui"

draw_postprocessor :: proc(state: ^Environment) {
	if !im.CollapsingHeader("Postprocessor", {}) do return
	im.PushStyleVarImVec2(.FramePadding, {ui_px(4), ui_px(2)})
	im.PushStyleVar(.FrameBorderSize, 0)
	im.PushStyleVar(.FrameRounding, ui_px(2))

	row_y := im.GetCursorPosY()
	pushed := push_font(code_font)
	field_height := im.GetFrameHeight()
	pop_font(pushed)
	im.SetCursorPosY(row_y+(field_height-im.GetTextLineHeight())/2)
	im.Text("X Origin:")
	im.SameLine(0, ui_px(8))
	im.SetCursorPosY(row_y)
	pushed = push_font(code_font)
	im.SetNextItemWidth(-1)
	_ = input_text("##xOrigin", state.post.x_origin[:])
	pop_font(pushed)

	row_y = im.GetCursorPosY()
	pushed = push_font(code_font)
	field_height = im.GetFrameHeight()
	pop_font(pushed)
	im.SetCursorPosY(row_y+(field_height-im.GetTextLineHeight())/2)
	im.Text("Z Origin:")
	im.SameLine(0, ui_px(8))
	im.SetCursorPosY(row_y)
	pushed = push_font(code_font)
	im.SetNextItemWidth(-1)
	_ = input_text("##zOrigin", state.post.z_origin[:])
	pop_font(pushed)

	im.AlignTextToFramePadding(); im.Text("X/Z precision:"); im.SameLine(0, ui_px(8))
	precision := c.int(state.post.position_precision)
	im.SetNextItemWidth(ui_px(80))
	pushed = push_font(code_font)
	_ = im.InputInt("##positionPrecision", &precision)
	pop_font(pushed)
	state.post.position_precision = clamp(int(precision), 3, 10)

	im.PopStyleVar(3)
}

draw_discrete_search_options :: proc(state: ^Environment) {
	im.SeparatorText("Discrete Local Search")

	_ = im.Checkbox(" Enable", &state.discrete_search)

	im.AlignTextToFramePadding()
	im.Text("Mode:")
	im.SameLine(0, ui_px(8))
	mode := c.int(1 if state.cook else 0)
	mode_items := [?]cstring{"Standard", "Intense Cooking"}
	im.SetNextItemWidth(ui_px(160))
	if combo_select("##discrete_search_mode", &mode, mode_items[:]) {
		state.cook = mode == 1
	}

	if state.cook {
		im.AlignTextToFramePadding()
		im.Text("Chef(s):")
		im.SameLine(0, ui_px(4))
		im.SetNextItemWidth(ui_px(120))
		chefs := c.int(state.chefs)
		_ = im.InputInt("##chefs", &chefs, 0, 0)
		state.chefs = clamp(int(chefs), 1, 1000)
	}
}

draw_continuous_optimizer_options :: proc(state: ^Environment) {
	im.SeparatorText("Continuous Optimizer")
	im.AlignTextToFramePadding()
	im.Text("Engine:")
	im.SameLine(0, ui_px(8))
	engine := c.int(state.continuous_optimizer)
	engine_items := [?]cstring{
		"Classic",
		"Spine",
		"Pancake",
	}
	im.SetNextItemWidth(ui_px(230))
	if combo_select("##continuous_optimizer", &engine, engine_items[:]) {
			state.continuous_optimizer = Continuous_Optimizer(engine)
			if state.continuous_optimizer == .Pancake {
				state.multistart_on = false
			}
		}
		if state.continuous_optimizer == .Pancake {
			state.multistart_on = false
	} else {
		im.AlignTextToFramePadding()
		im.Text("Initial Guess:")
		im.SameLine()
		initial_angle := state.seed
		im.SetNextItemWidth(ui_px(90))
		if im.InputDouble(
			"deg##seed",
			&initial_angle,
			0,
			0,
			"%.9g",
		) {
			state.seed = initial_angle
		}

			_ = im.Checkbox("##multistart_on", &state.multistart_on)
		im.SameLine(0, ui_px(8))
		im.AlignTextToFramePadding()
		im.Text("Multistart")
		im.SameLine(0, ui_px(8))
		im.AlignTextToFramePadding()
		im.Text("|")
		im.SameLine(0, ui_px(8))
		im.AlignTextToFramePadding()
		im.Text("Uniform Samples:")
		im.SameLine(0, ui_px(8))
			sample_index := c.int(0)
			sample_values := [?]int{8, 16, 32, 64, 128, 256}
			for value, i in sample_values {
				if state.seed_samples == value {
					sample_index = c.int(i)
					break
				}
		}
		sample_items := [?]cstring{"8", "16", "32 (Recommended)", "64", "128", "256"}
			im.SetNextItemWidth(ui_px(155))
			if combo_select("##seed_samples", &sample_index, sample_items[:]) {
				state.seed_samples = sample_values[sample_index]
			}
		im.TextDisabled("(Slower) Use when it seems stuck at a local optimum.")
	}

	if state.continuous_optimizer == .Pancake {
		im.AlignTextToFramePadding()
		im.Text("Recovery Engine:")
		im.SameLine(0, ui_px(8))
		secondary := c.int(state.pancake_recovery)
		secondary_items := [?]cstring{"Spine", "Classic"}
		im.SetNextItemWidth(ui_px(180))
		if combo_select(
			"##pancake_recovery",
			&secondary,
			secondary_items[:],
		) {
			state.pancake_recovery = Pancake_Recovery(secondary)
		}
	}
}

draw_input_panel :: proc(app_state: ^App_State, tab: ^Tab_State) {
	state := &tab.env
	im.PushStyleVarImVec2(.WindowPadding, {ui_pad(24), ui_pad(10)})
	im.BeginChild("InputPanel", {0, 0}, {.Borders})
	im.PopStyleVar()
	im.Spacing()

	im.AlignTextToFramePadding(); im.Text("Theme:"); im.SameLine()
	theme := c.int(app_state.theme)
	im.SetNextItemWidth(ui_px(180))
	theme_items := [?]cstring{"Obsidian", "Curry", "Luminous Abyss", "Cherry Blossom", "Crimson Forest"}
	if combo_select("##theme_bottom", &theme, theme_items[:]) {
		app_state.theme = Theme(theme)
		apply_theme(app_state.theme)
		save_preferences(app_state)
	}
	im.SameLine(0, ui_px(14))
	im.AlignTextToFramePadding(); im.Text("UI Size:"); im.SameLine()
	ui_level := c.int(app_state.ui_size_level-1)
	im.SetNextItemWidth(ui_px(80))
	ui_size_items := [?]cstring{"1", "2", "3"}
	if combo_select("##ui_size", &ui_level, ui_size_items[:]) {
		app_state.ui_size_level = int(ui_level)+1
		save_preferences(app_state)
	}

	im.AlignTextToFramePadding(); im.Text("Title:"); im.SameLine()
	im.SetNextItemWidth(ui_px(220))
	_ = input_text("##tab_name", tab.name_draft[:])
	if im.IsItemDeactivatedAfterEdit() do commit_tab_title(tab)
	im.SameLine()
	if im.Button("Save") {
		err := save_tab_to_file(tab)
		if err != "" {
			buffer_set(tab.inline_save_message[:], err)
			tab.inline_save_is_error = true
			delete(err)
		} else {
			buffer_set(tab.inline_save_message[:], fmt.tprintf("Saved as '%s'", buffer_string(tab.saved_file_name[:])))
			tab.inline_save_is_error = false
		}
	}
	status := buffer_string(tab.inline_save_message[:])
	if status != "" {
		color: im.Vec4 = {1, 0.45, 0.45, 1} if tab.inline_save_is_error else {0.45, 1, 0.55, 1}
		status_c := strings.clone_to_cstring(status); defer delete(status_c)
		im.TextColored(color, "%s", status_c)
	}
	im.Spacing()

	// === Movement Model ===
	im.SeparatorText("Mothball Model")
	tab.movement_editor_height = clamp(tab.movement_editor_height, ui_px(80), ui_px(360))
	model_font_pushed := push_font(code_font)
	_ = input_multiline(
		"##movement_script",
		state.movement_script[:],
		{-1, tab.movement_editor_height},
		{.AllowTabInput, .WordWrap},
	)
	pop_font(model_font_pushed)
	movement_divider_pos := im.GetCursorScreenPos()
	movement_divider_height := ui_px(8)
	im.InvisibleButton(
		"##movement_script_divider",
		{im.GetContentRegionAvail().x, movement_divider_height},
		{.MouseButtonLeft},
	)
	movement_divider_hovered := im.IsItemHovered()
	movement_divider_active := im.IsItemActive()
	if movement_divider_hovered || movement_divider_active do im.SetMouseCursor(.ResizeNS)
	if movement_divider_active {
		tab.movement_editor_height = clamp(
			tab.movement_editor_height+im.GetIO().MouseDelta.y,
			ui_px(80),
			ui_px(360),
		)
	}
	movement_divider_color := im.GetColorU32(.Separator)
	if movement_divider_active do movement_divider_color = im.GetColorU32(.SeparatorActive)
	else if movement_divider_hovered do movement_divider_color = im.GetColorU32(.SeparatorHovered)
	movement_divider_y := movement_divider_pos.y+movement_divider_height*0.5
	im.DrawList_AddLine(
		im.GetWindowDrawList(),
		{movement_divider_pos.x, movement_divider_y},
		{movement_divider_pos.x+im.GetItemRectSize().x, movement_divider_y},
		movement_divider_color,
		ui_px(2),
	)
	im.Spacing()

	// === Objective ===
	im.SeparatorText("Objective")
	objective := c.int(state.obj_type)
	im.SetNextItemWidth(ui_px(120))
	objective_items := [?]cstring{"X[n]", "Z[n]", "Custom"}
	if combo_select("##obj", &objective, objective_items[:]) do state.obj_type = Objective_Type(objective)
	im.SameLine(0, ui_px(15))
	if im.Button("Maximize" if state.maximize else "Minimize") do state.maximize = !state.maximize
	if state.obj_type == .Custom {
		im.SetNextItemWidth(-1)
			objective_font_pushed := push_font(code_font)
			_ = input_text("##custom_objective_script", state.objective_script[:])
			pop_font(objective_font_pushed)
	}
	// === Constraints ===
	im.SeparatorText("Constraints")
	tab.cons_editor_height = clamp(tab.cons_editor_height, ui_px(80), ui_px(360))
	constraint_font_pushed := push_font(code_font)
	_ = input_multiline("##constraint_script", state.constraint_script[:], {-1, tab.cons_editor_height}, {.AllowTabInput})
	pop_font(constraint_font_pushed)
	divider_pos := im.GetCursorScreenPos()
	divider_height := ui_px(8)
	im.InvisibleButton("##constraint_divider", {im.GetContentRegionAvail().x, divider_height}, {.MouseButtonLeft})
	divider_hovered := im.IsItemHovered()
	divider_active := im.IsItemActive()
	if divider_hovered || divider_active do im.SetMouseCursor(.ResizeNS)
	if divider_active do tab.cons_editor_height = clamp(tab.cons_editor_height+im.GetIO().MouseDelta.y, ui_px(80), ui_px(360))
	divider_color := im.GetColorU32(.Separator)
	if divider_active do divider_color = im.GetColorU32(.SeparatorActive)
	else if divider_hovered do divider_color = im.GetColorU32(.SeparatorHovered)
	divider_y := divider_pos.y+divider_height*0.5
	im.DrawList_AddLine(
		im.GetWindowDrawList(),
		{divider_pos.x, divider_y},
		{divider_pos.x+im.GetItemRectSize().x, divider_y},
		divider_color,
		ui_px(2),
	)

	// === Inertia ===
	draw_inertia_hut(state)

	// === Postprocessing ===
	draw_postprocessor(state)

	// === Engine Settings ===
	if im.CollapsingHeader("Engine Settings", {}) {
		draw_continuous_optimizer_options(state)
		draw_discrete_search_options(state)
	}

	// === Optimize Button ===
	if tab.optimizer_job != nil {
		cancel_requested := optimizer_cancel_requested(tab.optimizer_job.control)
		label: cstring = "Cancelling..." if cancel_requested else "Cancel Optimization"
		if im.Button(label, {-1, ui_px(35)}) && !cancel_requested {
			request_optimizer_cancel(tab)
		}
	} else if im.Button("Optimize!!", {-1, ui_px(35)}) {
		start_optimizer_job(tab)
	}
	im.EndChild()
}
