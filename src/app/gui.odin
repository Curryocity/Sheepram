package app

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"

import nfd "../nfd"
import opt "../optimizer"
import im "../../third_party/odin-imgui"

code_font: ^im.Font
big_code_font: ^im.Font
ui_font: ^im.Font
code_fonts: [3]^im.Font
big_code_fonts: [3]^im.Font
ui_fonts: [3]^im.Font
code_font_size: f32 = 16
big_code_font_size: f32 = 22
ui_font_size: f32 = 16
ui_scale: f32 = 1
applied_ui_size_level: int = 2
base_style: im.Style
base_style_ready: bool
nfd_ready: bool
show_exit_prompt: bool
request_exit: bool
exit_error: [ERROR_CAPACITY]byte

input_text :: proc(label: cstring, buffer: []byte, flags: im.InputTextFlags = {}) -> bool {
	return im.InputText(label, cstring(&buffer[0]), c.size_t(len(buffer)), flags)
}

input_multiline :: proc(
	label: cstring,
	buffer: []byte,
	size: im.Vec2,
	flags: im.InputTextFlags = {},
) -> bool {
	return im.InputTextMultiline(
		label,
		cstring(&buffer[0]),
		c.size_t(len(buffer)),
		size,
		flags,
	)
}

push_font :: proc(font: ^im.Font, size: f32 = 0) -> bool {
	if font == nil do return false
	font_size := size
	if font_size <= 0 {
		if font == code_font {
			font_size = code_font_size
		} else if font == big_code_font {
			font_size = big_code_font_size
		} else if font == ui_font {
			font_size = ui_font_size
		}
	}
	im.PushFontFloat(font, font_size)
	return true
}

pop_font :: proc(pushed: bool) {
	if pushed do im.PopFont()
}

ui_scale_for_level :: proc(level: int) -> f32 {
	scales := [?]f32{0.90, 1.00, 1.15}
	return scales[clamp(level, 1, 3)-1]
}

ui_px :: proc(value: f32, min_px: f32 = 1) -> f32 {
	return max(value*ui_scale, min_px)
}

ui_pad :: proc(value: f32) -> f32 {
	return value*max(ui_scale, f32(1))
}

apply_ui_size :: proc(level: int, theme: Theme) {
	clamped_level := clamp(level, 1, 3)
	new_scale := ui_scale_for_level(clamped_level)
	style := im.GetStyle()
	if base_style_ready {
		// Always scale from ImGui's pristine style. Incremental down-scaling
		// rounds small pixel values toward zero and can make the style invalid.
		style^ = base_style
		im.Style_ScaleAllSizes(style, new_scale)
	}
	ui_scale = new_scale
	font_index := clamped_level-1
	code_font = code_fonts[font_index]
	big_code_font = big_code_fonts[font_index]
	ui_font = ui_fonts[font_index]
	code_font_size = 16*new_scale
	big_code_font_size = 22*new_scale
	ui_font_size = 16*new_scale
	applied_ui_size_level = clamped_level
	// ScaleAllSizes mutates the live ImGui style, so restore all app-owned
	// dimensions and colors after it runs.
	apply_theme(theme)
}

combo_select :: proc(label: cstring, current: ^c.int, items: []cstring) -> bool {
	changed := false
	preview := items[clamp(int(current^), 0, len(items)-1)]
	if im.BeginCombo(label, preview) {
		for i in 0..<len(items) {
			selected := int(current^) == i
			if im.Selectable(items[i], selected) {
				current^ = c.int(i)
				changed = true
			}
			if selected do im.SetItemDefaultFocus()
		}
		im.EndCombo()
	}
	return changed
}

load_fonts :: proc() {
	io := im.GetIO()
	for i in 0..<3 {
		scale := ui_scale_for_level(i+1)
		code_fonts[i] = im.FontAtlas_AddFontFromFileTTF(
			io.Fonts,
			"asset/fonts/JetBrainsMono-Regular.ttf",
			16*scale,
		)
		big_code_fonts[i] = im.FontAtlas_AddFontFromFileTTF(
			io.Fonts,
			"asset/fonts/JetBrainsMono-Regular.ttf",
			22*scale,
		)
		ui_fonts[i] = im.FontAtlas_AddFontFromFileTTF(
			io.Fonts,
			"asset/fonts/MinecraftRegular.otf",
			16*scale,
		)
	}
}

RGB :: struct {r, g, b: f32}

rgba :: proc(color: RGB, alpha: f32 = 1) -> im.Vec4 {
	return {color.r, color.g, color.b, alpha}
}

scale_color :: proc(color: RGB, factor: f32, alpha: f32 = 1) -> im.Vec4 {
	return {color.r*factor, color.g*factor, color.b*factor, alpha}
}

mix_color :: proc(a, b: RGB, t: f32) -> RGB {
	return {
		a.r*(1-t)+b.r*t,
		a.g*(1-t)+b.g*t,
		a.b*(1-t)+b.b*t,
	}
}

apply_accent :: proc(accent: RGB) {
	colors := &im.GetStyle().Colors
	dark := RGB{0.10, 0.10, 0.10}
	mid := mix_color(dark, accent, 0.35)
	soft := mix_color(dark, accent, 0.20)
	tab_bg := mix_color(dark, accent, 0.28)
	tab_active := mix_color(dark, accent, 0.52)

	colors[im.Col.Button] = scale_color(accent, 0.85, 0.85)
	colors[im.Col.ButtonHovered] = scale_color(accent, 1.00, 0.95)
	colors[im.Col.ButtonActive] = scale_color(accent, 1.15, 1.00)
	colors[im.Col.Header] = scale_color(accent, 0.70, 0.85)
	colors[im.Col.HeaderHovered] = scale_color(accent, 0.85, 0.90)
	colors[im.Col.HeaderActive] = scale_color(accent, 1.00, 0.95)
	colors[im.Col.SliderGrab] = scale_color(accent, 1.10)
	colors[im.Col.SliderGrabActive] = scale_color(accent, 1.25)
	colors[im.Col.CheckMark] = scale_color(accent, 1.30)
	colors[im.Col.Border] = scale_color(accent, 0.75, 0.80)
	colors[im.Col.Separator] = scale_color(accent, 0.75, 0.90)
	colors[im.Col.TableBorderLight] = rgba(soft, 0.65)
	colors[im.Col.TableBorderStrong] = rgba(mid, 0.85)
	colors[im.Col.TableRowBg] = rgba(soft, 0.60)
	colors[im.Col.TableRowBgAlt] = rgba(mid, 0.60)
	colors[im.Col.Tab] = rgba(tab_bg, 0.90)
	colors[im.Col.TabHovered] = rgba(tab_active, 0.95)
	colors[im.Col.TabSelected] = rgba(tab_active, 1.00)
	colors[im.Col.TabDimmed] = rgba(tab_bg, 0.70)
	colors[im.Col.TabDimmedSelected] = rgba(tab_active, 0.80)
}

apply_theme :: proc(theme: Theme) {
	style := im.GetStyle()
	style.WindowRounding = ui_px(7)
	style.ChildRounding = ui_px(6)
	style.FrameRounding = ui_px(5)
	style.GrabRounding = ui_px(4)
	style.ScrollbarRounding = ui_px(6)
	style.WindowBorderSize = ui_px(1)
	style.ChildBorderSize = ui_px(1)
	style.WindowBorderHoverPadding = ui_px(4)
	style.SeparatorSize = ui_px(1)
	style.SeparatorTextBorderSize = ui_px(3)
	style.FrameBorderSize = 0
	style.WindowPadding = {ui_pad(12), ui_pad(10)}
	style.FramePadding = {ui_px(9), ui_px(6)}
	style.ItemSpacing = {ui_px(9), ui_px(8)}

	colors := &style.Colors
	colors[im.Col.Text] = {0.95, 0.95, 0.95, 1}
	colors[im.Col.TextDisabled] = {0.6, 0.6, 0.6, 1}
	colors[im.Col.TextSelectedBg] = {0.8, 0.8, 0.8, 0.30}
	colors[im.Col.WindowBg] = {0.04, 0.04, 0.04, 1}
	colors[im.Col.ChildBg] = {0.06, 0.06, 0.06, 1}
	colors[im.Col.PopupBg] = {0.1, 0.1, 0.1, 1}
	colors[im.Col.FrameBg] = {0.25, 0.25, 0.25, 1}
	colors[im.Col.FrameBgHovered] = {0.25, 0.25, 0.25, 1}
	colors[im.Col.FrameBgActive] = {0.3, 0.3, 0.3, 1}
	colors[im.Col.TitleBg] = {0.1, 0.1, 0.1, 1}
	colors[im.Col.TitleBgActive] = {0.15, 0.15, 0.15, 1}

	switch theme {
	case .Obsidian: apply_accent({0.45, 0.39, 0.60})
	case .Curry: apply_accent({0.92, 0.69, 0.22})
	case .Luminous_Abyss: apply_accent({0.38, 0.74, 0.80})
	case .Cherry_Blossom: apply_accent({0.86, 0.57, 0.75})
	case .Crimson_Forest: apply_accent({0.85, 0.32, 0.36})
	}
}

center_text :: proc(text: string) {
	c_text := strings.clone_to_cstring(text)
	defer delete(c_text)
	width := im.GetColumnWidth()
	text_width := im.CalcTextSize(c_text).x
	im.SetCursorPosX(im.GetCursorPosX()+(width-text_width)*0.5)
	im.AlignTextToFramePadding()
	im.TextUnformatted(c_text)
}

center_text_colored :: proc(text: string, color: im.Vec4) {
	c_text := strings.clone_to_cstring(text)
	defer delete(c_text)
	width := im.GetColumnWidth()
	text_width := im.CalcTextSize(c_text).x
	im.SetCursorPosX(im.GetCursorPosX()+(width-text_width)*0.5)
	im.AlignTextToFramePadding()
	im.TextColored(color, "%s", c_text)
}

format_duration :: proc(seconds: f64) -> string {
	whole_seconds := int(seconds)
	milliseconds := (seconds-f64(whole_seconds))*1000
	if whole_seconds == 0 {
		return fmt.aprintf("%.3fms", milliseconds)
	}
	return fmt.aprintf("%ds %.3fms", whole_seconds, milliseconds)
}

draw_selection_rect :: proc(minimum, maximum: im.Vec2) {
	draw_list := im.GetForegroundDrawList()
	im.DrawList_AddRect(draw_list, minimum, maximum, im.GetColorU32ImVec4({1, 1, 1, 0.4}), ui_px(3), {}, ui_px(2))
}

draw_global_table :: proc(tab: ^Tab_State) {
	state := &tab.env
	im.SeparatorText("Global Variables")
	im.BeginChild("var_region", {0, ui_px(80)})
	region_min := im.GetWindowPos()
	region_size := im.GetWindowSize()
	region_max := im.Vec2{region_min.x+region_size.x, region_min.y+region_size.y}
	active_index := state.var_capacity-1
	if tab.selected_global_var_index >= 0 && tab.selected_global_var_index < state.var_capacity {
		active_index = tab.selected_global_var_index
	}
	im.BeginGroup()
	if im.Button("+", {ui_px(26), im.GetFrameHeight()}) && state.var_capacity < MAX_GLOBALS {
		insert_index := active_index+1
		for i := state.var_capacity; i > insert_index; i -= 1 {
			state.global_names[i] = state.global_names[i-1]
			state.global_values[i] = state.global_values[i-1]
		}
		buffer_clear(state.global_names[insert_index][:])
		buffer_clear(state.global_values[insert_index][:])
		state.var_capacity += 1
		tab.selected_global_var_index = insert_index
	}
	if im.Button("-", {ui_px(26), im.GetFrameHeight()}) && state.var_capacity > 1 {
		for i in active_index..<state.var_capacity-1 {
			state.global_names[i] = state.global_names[i+1]
			state.global_values[i] = state.global_values[i+1]
		}
		state.var_capacity -= 1
		tab.selected_global_var_index = max(0, active_index-1)
	}
	im.EndGroup()
	im.SameLine()
	flags := im.TableFlags_Borders | im.TableFlags_RowBg |
	         im.TableFlags_ScrollX | im.TableFlags_ScrollY | im.TableFlags_SizingFixedFit
	if im.BeginTable("global_table", c.int(state.var_capacity+1), flags) {
		im.TableSetupColumn("", {.WidthFixed}, ui_px(60))
		for i in 0..<state.var_capacity {
			im.TableSetupColumn("", {.WidthFixed}, ui_px(70))
		}
		for row in 0..<2 {
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			center_text("Name" if row == 0 else "Value")
			for i in 0..<state.var_capacity {
				im.TableSetColumnIndex(c.int(i+1))
				im.PushIDInt(c.int(row*1000+i))
				im.SetNextItemWidth(ui_px(70))
				if row == 0 {
					_ = input_text("##name", state.global_names[i][:])
				} else {
					_ = input_text("##value", state.global_values[i][:])
				}
				if im.IsItemActivated() || im.IsItemClicked() do tab.selected_global_var_index = i
				if tab.selected_global_var_index == i do draw_selection_rect(im.GetItemRectMin(), im.GetItemRectMax())
				im.PopID()
			}
		}
		im.EndTable()
	}
	mouse := im.GetMousePos()
	inside := mouse.x >= region_min.x && mouse.x <= region_max.x &&
	          mouse.y >= region_min.y && mouse.y <= region_max.y
	if im.IsMouseClicked(.Left) && !inside do tab.selected_global_var_index = -1
	im.EndChild()
}

draw_postprocessor :: proc(state: ^Environment) {
	if !im.CollapsingHeader("Postprocessor", {.DefaultOpen}) do return
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
	im.Text("Initial Guess:")
	im.SameLine()
	initial_angle := state.continuous_initial_angle_degrees
	im.SetNextItemWidth(ui_px(90))
	if im.InputDouble("deg##continuous_initial_angle", &initial_angle, 0, 0, "%.6g") {
		state.continuous_initial_angle_degrees = initial_angle
	}
	_ = im.Checkbox("##continuous_multistart", &state.continuous_scan_initial_angles)
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
		if state.continuous_initial_angle_samples == value {
			sample_index = c.int(i)
			break
		}
	}
	sample_items := [?]cstring{"8", "16", "32", "64", "128", "256"}
	im.SetNextItemWidth(ui_px(80))
	if combo_select("##continuous_initial_angle_samples", &sample_index, sample_items[:]) {
		state.continuous_initial_angle_samples = sample_values[sample_index]
	}
	im.TextDisabled("(Slower) Use when it seems stuck at a local optimum.")
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

	// === Core ===
	im.SeparatorText("Core")
	im.AlignTextToFramePadding(); im.Text("Objective Function: "); im.SameLine()
	objective := c.int(state.curr_obj)
	im.SetNextItemWidth(ui_px(120))
	objective_items := [?]cstring{"X[n]", "Z[n]", "Custom"}
	if combo_select("##obj", &objective, objective_items[:]) do state.curr_obj = Objective_Type(objective)
	im.SameLine(0, ui_px(15))
	if im.Button("Maximize" if state.maximize else "Minimize") do state.maximize = !state.maximize
	if state.curr_obj == .Custom {
		im.SetNextItemWidth(-1)
			objective_font_pushed := push_font(code_font)
			_ = input_text("##custom_objective_script", state.obj_script[:])
			pop_font(objective_font_pushed)
	}
	draw_global_table(tab)

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

	// === Postprocessing ===
	draw_postprocessor(state)

	// === Engine Settings ===
	if im.CollapsingHeader("Engine Settings", {.DefaultOpen}) {
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

format_number :: proc(value: f64, precision: int) -> string {
	return fmt.aprintf("%.*f", precision, value)
}

wrap_degrees_180 :: proc(degrees: f64) -> f64 {
	wrapped := math.mod(degrees+180, 360)
	if wrapped < 0 do wrapped += 360
	return wrapped-180
}

MIN_GRID_PX :: 67.0
MAX_GRID_PX :: 100.0
PLOT_PAD :: f32(30)

XZ_Plot_Layout :: struct {
	min_x, max_x, min_z, max_z: f64,
	range_x, range_z: f64,
	center_x, center_z: f64,
	scale: f64,
	content_width, content_height: f32,
}

compute_xz_plot_layout :: proc(xs, zs: []f64, size: im.Vec2) -> XZ_Plot_Layout {
	layout := XZ_Plot_Layout{scale = MIN_GRID_PX, content_width = 2*PLOT_PAD, content_height = 2*PLOT_PAD}
	if len(xs) == 0 || len(xs) != len(zs) do return layout
	layout.min_x, layout.max_x = xs[0], xs[0]
	layout.min_z, layout.max_z = zs[0], zs[0]
	for i in 1..<len(xs) {
		layout.min_x = min(layout.min_x, xs[i])
		layout.max_x = max(layout.max_x, xs[i])
		layout.min_z = min(layout.min_z, zs[i])
		layout.max_z = max(layout.max_z, zs[i])
	}
	if layout.min_x == layout.max_x {layout.min_x -= 0.5; layout.max_x += 0.5}
	if layout.min_z == layout.max_z {layout.min_z -= 0.5; layout.max_z += 0.5}
	layout.range_x = max(layout.max_x-layout.min_x, 1e-3)
	layout.range_z = max(layout.max_z-layout.min_z, 1e-3)
	layout.center_x = 0.5*(layout.min_x+layout.max_x)
	layout.center_z = 0.5*(layout.min_z+layout.max_z)
	plot_w := max(1, size.x-2*PLOT_PAD)
	plot_h := max(1, size.y-2*PLOT_PAD)
	layout.scale = clamp(min(f64(plot_w)/layout.range_x, f64(plot_h)/layout.range_z), MIN_GRID_PX, MAX_GRID_PX)
	layout.content_width = f32(layout.range_x*layout.scale)+2*PLOT_PAD
	layout.content_height = f32(layout.range_z*layout.scale)+2*PLOT_PAD
	return layout
}

draw_xz_plot :: proc(
	xs, zs, facings: []f64,
	vxs, vzs: []string,
	jump_ticks: []bool,
	color_jump_ticks: bool,
	size: im.Vec2,
	position_precision, angle_precision: int,
) {
	if len(xs) == 0 || len(xs) != len(zs) do return
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x+size.x, p0.y+size.y}
	im.InvisibleButton("##xzplot", size)
	draw_list := im.GetWindowDrawList()
	plot_hovered := im.IsItemHovered()
	im.DrawList_AddRectFilled(draw_list, p0, p1, 0xff141414, 6)
	im.DrawList_AddRect(draw_list, p0, p1, 0xff5a5a5a, 6)

	layout := compute_xz_plot_layout(xs, zs, size)
	center := im.Vec2{p0.x+size.x*0.5, p0.y+size.y*0.5}
	to_screen := proc(x, z: f64, center: im.Vec2, layout: XZ_Plot_Layout) -> im.Vec2 {
		return {
			center.x+f32((x-layout.center_x)*layout.scale),
			center.y-f32((z-layout.center_z)*layout.scale),
		}
	}

	im.DrawList_PushClipRect(draw_list, p0, p1, true)
	grid_color: u32 = 0x96969696
	axis_color: u32 = 0xb4c8c8c8
	canvas_min_x := layout.center_x-f64(size.x*0.5)/layout.scale
	canvas_max_x := layout.center_x+f64(size.x*0.5)/layout.scale
	canvas_min_z := layout.center_z-f64(size.y*0.5)/layout.scale
	canvas_max_z := layout.center_z+f64(size.y*0.5)/layout.scale
	mouse := im.GetMousePos()
	hover_radius_sq := f32(64)
	hovered_index := -1
	best_dist_sq := hover_radius_sq
	default_point_color: u32 = 0xfff0f0f0
	jump_point_color := im.GetColorU32ImVec4({0.72, 0.62, 0.95, 1})

	for gx := int(math.ceil(canvas_min_x)); gx <= int(math.floor(canvas_max_x)); gx += 1 {
		x := to_screen(f64(gx), layout.center_z, center, layout).x
		im.DrawList_AddLine(draw_list, {x, p0.y}, {x, p1.y}, axis_color if gx == 0 else grid_color, 1.6 if gx == 0 else 1)
	}
	for gz := int(math.ceil(canvas_min_z)); gz <= int(math.floor(canvas_max_z)); gz += 1 {
		y := to_screen(layout.center_x, f64(gz), center, layout).y
		im.DrawList_AddLine(draw_list, {p0.x, y}, {p1.x, y}, axis_color if gz == 0 else grid_color, 1.6 if gz == 0 else 1)
	}
	for i in 1..<len(xs) {
		im.DrawList_AddLine(
			draw_list,
			to_screen(xs[i-1], zs[i-1], center, layout),
			to_screen(xs[i], zs[i], center, layout),
			0xffc8c0c0,
			2,
		)
	}
	for i in 0..<len(xs) {
		point := to_screen(xs[i], zs[i], center, layout)
		jump_point := color_jump_ticks && i < len(jump_ticks) && jump_ticks[i]
		if plot_hovered {
			dx, dy := point.x-mouse.x, point.y-mouse.y
			dist_sq := dx*dx+dy*dy
			if dist_sq <= best_dist_sq {
				best_dist_sq = dist_sq
				hovered_index = i
			}
		}
		im.DrawList_AddCircleFilled(draw_list, point, 3.5, jump_point_color if jump_point else default_point_color)
	}
	if hovered_index >= 0 {
		point := to_screen(xs[hovered_index], zs[hovered_index], center, layout)
		jump_point := color_jump_ticks && hovered_index < len(jump_ticks) && jump_ticks[hovered_index]
		hover_color := jump_point_color if jump_point else 0xdcffffff
		im.DrawList_AddCircle(draw_list, point, 7, hover_color, 0, 1.8)
	}
	im.DrawList_PopClipRect(draw_list)

	if hovered_index >= 0 &&
	   hovered_index < len(facings) &&
	   hovered_index < len(vxs) &&
	   hovered_index < len(vzs) &&
	   im.BeginTooltip() {
		tick_text := fmt.aprintf("Tick %d", hovered_index)
		defer delete(tick_text)
		tick_c := strings.clone_to_cstring(tick_text)
		defer delete(tick_c)
		im.TextUnformatted(tick_c)
		im.Separator()

		tooltip := strings.builder_make()
		if hovered_index < len(xs)-1 {
			fmt.sbprintf(&tooltip, "Facing: %.*f\n", angle_precision, facings[hovered_index])
		} else {
			strings.write_string(&tooltip, "Facing: -\n")
		}
		fmt.sbprintf(
			&tooltip,
			"Pos: (%.*f, %.*f)",
			position_precision,
			xs[hovered_index],
			position_precision,
			zs[hovered_index],
		)
		if hovered_index < len(xs)-1 {
			fmt.sbprintf(&tooltip, "\nVel: (%s, %s)", vxs[hovered_index], vzs[hovered_index])
			vx := xs[hovered_index+1]-xs[hovered_index]
			vz := zs[hovered_index+1]-zs[hovered_index]
			magnitude := math.sqrt(vx*vx+vz*vz)
			direction := wrap_degrees_180(math.atan2(vx, vz)*180/math.PI)
			fmt.sbprintf(
				&tooltip,
				"\nSpeed: %.*f\nDirection: %.*f deg",
				position_precision,
				magnitude,
				angle_precision,
				direction,
			)
		}
		tooltip_text := strings.to_string(tooltip)
		defer delete(tooltip_text)
		tooltip_c := strings.clone_to_cstring(tooltip_text)
		defer delete(tooltip_c)
		im.TextUnformatted(tooltip_c)
		im.EndTooltip()
	}
}

compute_plot_viewport_size :: proc(xs, zs: []f64) -> im.Vec2 {
	min_size :: f32(250)
	max_size :: f32(1000)
	if len(xs) == 0 || len(xs) != len(zs) do return {min_size, min_size}
	height_layout := compute_xz_plot_layout(xs, zs, {min_size, max_size})
	viewport_height := clamp(height_layout.content_height, min_size, max_size)
	width_layout := compute_xz_plot_layout(xs, zs, {0, viewport_height})
	content_width := max(f32(0), width_layout.content_width)
	return {clamp(content_width, min_size, max_size), viewport_height}
}

copy_separator :: proc(separator: Separator_Type) -> string {
	switch separator {
	case .Comma: return ","
	case .Space: return " "
	case .Newline: return "\n"
	}
	return ","
}

format_angle_list :: proc(facings: []f64, turns: bool, separator: string) -> string {
	builder := strings.builder_make()
	count := len(facings)-1
	if turns do count -= 1
	for i in 0..<max(0, count) {
		if i > 0 do strings.write_string(&builder, separator)
		value := facings[i]
		if turns {
			value = wrap_degrees_180(facings[i+1]-value)
		}
		part := fmt.tprintf("%.3f", value)
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

read_only_block :: proc(label: cstring, text: string, copy_text: string) {
	im.AlignTextToFramePadding()
	pushed_ui := push_font(ui_font)
	im.TextUnformatted(label)
	im.SameLine()
	copy_label := fmt.aprintf("Copy##%s", string(label)); defer delete(copy_label)
	copy_label_c := strings.clone_to_cstring(copy_label); defer delete(copy_label_c)
	if im.Button(copy_label_c) {
		copy_c := strings.clone_to_cstring(copy_text); defer delete(copy_c)
		im.SetClipboardText(copy_c)
	}
	pop_font(pushed_ui)
	pushed_code := push_font(code_font)
	text_c := strings.clone_to_cstring(text); defer delete(text_c)
	padding := im.GetStyle().FramePadding
	im.PushStyleVarImVec2(.FramePadding, {padding.x, padding.y+ui_px(2)})
	im.PushID(label)
	im.InputTextMultiline(
		"##readonly",
		text_c,
		c.size_t(len(text)+1),
		{-1, ui_px(30)},
		{.ReadOnly, .NoUndoRedo},
	)
	im.PopID()
	im.PopStyleVar()
	pop_font(pushed_code)
}

draw_constraint_results :: proc(solution: ^opt.Solution, discrete_solution: bool) {
	pushed_ui := push_font(ui_font)
	im.Text("Constraint Results")
	pop_font(pushed_ui)

	if len(solution.constraints) == 0 {
		im.TextDisabled("No constraints.")
		return
	}

	im.PushStyleVarImVec2(.CellPadding, {ui_px(10), ui_px(3)})
	table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter |
	               im.TableFlags_BordersV | im.TableFlags_SizingFixedFit |
	               im.TableFlags_NoHostExtendX
	if im.BeginTable("ConstraintResults", 3, table_flags) {
		im.TableSetupColumn("Constraint", {.WidthFixed}, ui_px(430))
		im.TableSetupColumn("Margin / Error", {.WidthFixed}, ui_px(130))
		im.TableSetupColumn("Status", {.WidthFixed}, ui_px(100))
		im.TableNextRow({.Headers}, ui_px(20))
		headers := [?]string{"Constraint", "Margin / Error", "Status"}
		for header, i in headers {
			im.TableSetColumnIndex(c.int(i))
			center_text(header)
		}

		for result in solution.constraints {
			metric_text := fmt.aprintf("%+.6g", result.margin)
			status := "Inactive"
			color := im.Vec4{0.45, 0.85, 0.55, 1}

			if result.cmp == .Equal {
				delete(metric_text)
				metric_text = fmt.aprintf("%.6g", result.margin)
				if result.margin > opt.ACCEPT_TOL {
					status = "Violated"
					color = {1, 0.4, 0.4, 1}
				} else {
					status = "Active"
					color = {1, 0.75, 0.3, 1}
				}
			} else {
				violation_limit := -opt.ACCEPT_TOL
				if discrete_solution do violation_limit = 0
				if result.margin < violation_limit {
					status = "Violated"
					color = {1, 0.4, 0.4, 1}
				} else if result.margin <= opt.ACCEPT_TOL {
					status = "Active"
					color = {1, 0.75, 0.3, 1}
				}
			}

			im.TableNextRow({}, ui_px(20))
			im.TableSetColumnIndex(0)
			source_c := strings.clone_to_cstring(result.source)
			im.TextUnformatted(source_c)
			delete(source_c)
			im.TableSetColumnIndex(1)
			center_text(metric_text)
			im.TableSetColumnIndex(2)
			status_c := strings.clone_to_cstring(status)
			im.TextColored(color, "%s", status_c)
			delete(status_c)
			delete(metric_text)
		}
		im.EndTable()
	}
	im.PopStyleVar()
}

draw_optimizer_progress :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil || job.control == nil {
		im.TextDisabled("Optimizing...")
		return
	}

	progress := &job.control.progress
	has_best: bool
	best_objective: f64
	completed_chefs, total_chefs: int

	sync.atomic_mutex_lock(&progress.mutex)
	has_best = progress.has_best
	best_objective = progress.best_objective
	angles := make([dynamic]f64, len(progress.angles))
	copy(angles[:], progress.angles[:])
	completed_chefs = progress.completed_chefs
	total_chefs = progress.total_chefs
	sync.atomic_mutex_unlock(&progress.mutex)
	defer delete(angles)

	cancel_requested := optimizer_cancel_requested(job.control)
	if cancel_requested {
		im.TextDisabled("Cancelling...")
	} else {
		im.TextDisabled("Optimizing...")
	}
	elapsed_text := format_duration(time.duration_seconds(time.tick_since(job.started_at)))
	defer delete(elapsed_text)
	elapsed_c := strings.clone_to_cstring(elapsed_text)
	defer delete(elapsed_c)
	im.TextDisabled("Elapsed Time: %s", elapsed_c)

	if !has_best {
		im.TextDisabled("Waiting...")
		return
	}

	im.Spacing()
	pushed_big := push_font(big_code_font)
	im.TextColored({0.8, 0.85, 1, 1}, "=> %.12f", best_objective)
	pop_font(pushed_big)

	if total_chefs > 0 {
		im.TextDisabled(
			"Mode: Intense Cooking (Chef(s): %d/%d)",
			completed_chefs,
			total_chefs,
		)
	}

	display_facings := format_angle_list(angles[:], false, ", ")
	defer delete(display_facings)
	copied_facings := format_angle_list(angles[:], false, copy_separator(tab.env.post.copy_separator))
	defer delete(copied_facings)
	read_only_block("Best Facing", display_facings, copied_facings)
}

draw_output_panel :: proc(tab: ^Tab_State, size: im.Vec2 = {0, 0}) {
	state := &tab.env
	im.PushStyleVarImVec2(.WindowPadding, {ui_pad(24), ui_pad(10)})
	im.BeginChild("OutputPanel", size, {.Borders})
	im.PopStyleVar()
	im.SeparatorText("Result")
	im.BeginChild("OutputScroll", {0, 0}, {}, {.HorizontalScrollbar})
	pushed_code := push_font(code_font)

	error_text := buffer_string(state.last_error[:])
	if error_text != "" {
		c_error := strings.clone_to_cstring(error_text); defer delete(c_error)
		im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
		pop_font(pushed_code)
		im.EndChild(); im.EndChild()
		return
	}
	if state.last_solution == nil {
		if tab.optimizer_job != nil {
			draw_optimizer_progress(tab)
		} else {
			im.TextDisabled("Press Optimize!!")
		}
		pop_font(pushed_code)
		im.EndChild(); im.EndChild()
		return
	}

	solution := state.last_solution
	angle_precision :: 3
	position_precision := clamp(state.post.position_precision, 3, 10)
	im.Spacing()
	pushed_big := push_font(big_code_font)
	im.TextColored({0.8, 0.85, 1, 1}, "=> %.12f", solution.optimum)
	pop_font(pushed_big)
	compile_time := format_duration(state.compile_time_seconds)
	defer delete(compile_time)
	optimize_time := format_duration(state.continuous_time_seconds)
	defer delete(optimize_time)
	if state.last_solution_discrete {
		local_search_time := format_duration(state.discrete_time_seconds)
		defer delete(local_search_time)
		compile_c := strings.clone_to_cstring(compile_time)
		defer delete(compile_c)
		optimize_c := strings.clone_to_cstring(optimize_time)
		defer delete(optimize_c)
		local_search_c := strings.clone_to_cstring(local_search_time)
		defer delete(local_search_c)
		im.TextDisabled(
			"Compile: %s | Optimize: %s | Local Search: %s",
			compile_c,
			optimize_c,
			local_search_c,
		)
	} else {
		compile_c := strings.clone_to_cstring(compile_time)
		defer delete(compile_c)
		optimize_c := strings.clone_to_cstring(optimize_time)
		defer delete(optimize_c)
		im.TextDisabled(
			"Compile: %s | Optimize: %s",
			compile_c,
			optimize_c,
		)
	}
	if state.last_solution_cooking {
		im.TextDisabled(
			"Mode: Intense Cooking (Chef(s): %d/%d)",
			state.last_solution_chefs_completed,
			state.last_solution_chefs_total,
		)
	} else {
		im.TextDisabled(
			"Mode: %s",
			"Discrete" if state.last_solution_discrete else "Continuous",
		)
	}
	im.Spacing(); im.Spacing()

	count := len(solution.xs)
	facings := make([dynamic]f64, count); defer delete(facings)
	for i in 0..<len(solution.thetas) {
		if state.last_solution_discrete {
			facings[i] = solution.thetas[i]
		} else {
			wrapped := wrap_degrees_180(solution.thetas[i]*180/math.PI)
			facings[i] = math.round(200*wrapped)*0.005
		}
	}
	turns := make([dynamic]string, count); defer delete(turns)
	xvals := make([dynamic]f64, count); defer delete(xvals)
	zvals := make([dynamic]f64, count); defer delete(zvals)
	vxvals := make([dynamic]string, count); defer delete(vxvals)
	vzvals := make([dynamic]string, count); defer delete(vzvals)
	speedvals := make([dynamic]string, count); defer delete(speedvals)
	directionvals := make([dynamic]string, count); defer delete(directionvals)
	for i in 0..<count {
		turns[i] = "-"
		vxvals[i] = "-"
		vzvals[i] = "-"
		speedvals[i] = "-"
		directionvals[i] = "-"
		xvals[i] = solution.xs[i]-state.x_origin
		zvals[i] = solution.zs[i]-state.z_origin
	}
	for i in 0..<count-2 {
		turns[i] = fmt.aprintf("%.3f", wrap_degrees_180(facings[i+1]-facings[i]))
	}
	defer for i in 0..<count-2 do delete(turns[i])
	for i in 0..<count-1 {
		vx := xvals[i+1]-xvals[i]
		vz := zvals[i+1]-zvals[i]
		vxvals[i] = fmt.aprintf("%.*f", position_precision, vx)
		vzvals[i] = fmt.aprintf("%.*f", position_precision, vz)
		speedvals[i] = fmt.aprintf("%.*f", position_precision, math.sqrt(vx*vx+vz*vz))
		directionvals[i] = fmt.aprintf(
			"%.3f",
			wrap_degrees_180(math.atan2(vx, vz)*180/math.PI),
		)
	}
	defer for i in 0..<count-1 {
		delete(vxvals[i])
		delete(vzvals[i])
		delete(speedvals[i])
		delete(directionvals[i])
	}

	pushed_ui := push_font(ui_font)
	im.Text("Visualization")
	pop_font(pushed_ui)
	viewport_size := compute_plot_viewport_size(xvals[:], zvals[:])
	layout := compute_xz_plot_layout(xvals[:], zvals[:], viewport_size)
	canvas_width := max(viewport_size.x, layout.content_width)
	viewport_size.x += ui_px(25)
	viewport_size.y += ui_px(50)
	im.BeginChild("PlotScroll", {viewport_size.x, viewport_size.y+ui_px(20)}, {.Borders}, {.HorizontalScrollbar})
	if im.IsWindowAppearing() do im.SetScrollX(max(0, 0.5*(canvas_width-viewport_size.x)))
	draw_xz_plot(xvals[:], zvals[:], facings[:], vxvals[:], vzvals[:], state.last_jump_ticks[:], state.color_jump_ticks, {canvas_width, viewport_size.y}, position_precision, angle_precision)
	im.EndChild()
	im.Spacing()
	_ = im.Checkbox(" Color jump ticks", &state.color_jump_ticks)
	im.Spacing(); im.Spacing()

	draw_constraint_results(solution, state.last_solution_discrete)
	im.Spacing(); im.Spacing()

	pushed_ui = push_font(ui_font)
	im.Text("Movement Log")
	pop_font(pushed_ui)

	im.PushStyleVarImVec2(.CellPadding, {ui_px(10), ui_px(3)})
	available := im.GetContentRegionAvail()
	table_width := min(ui_px(877), available.x)
	visible_rows := min(count, 13)
	table_height := ui_px(f32(visible_rows)*34+50)
	table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersV |
	               im.TableFlags_ScrollY | im.TableFlags_ScrollX | im.TableFlags_SizingFixedFit |
	               im.TableFlags_NoHostExtendX
	if im.BeginTable("ResultTable", 9, table_flags, {table_width, table_height}) {
		im.TableSetupScrollFreeze(1, 1)
		headers := [?]cstring{
			"Tick",
			"Facing",
			"Turn",
			"X",
			"Z",
			"Vx",
			"Vz",
			"Speed",
			"Direction",
		}
		widths := [?]f32{50, 100, 100, 120, 120, 120, 120, 120, 100}
		for i in 0..<9 do im.TableSetupColumn(headers[i], {.WidthFixed}, ui_px(widths[i]))
		im.TableNextRow({.Headers}, ui_px(20))
		for i in 0..<9 {
			im.TableSetColumnIndex(c.int(i))
			center_text(string(headers[i]))
		}
		jump_text_color := im.Vec4{0.72, 0.62, 0.95, 1}
		for tick in 0..<count {
			im.TableNextRow({}, ui_px(20))
			jump_row := state.color_jump_ticks && tick < len(state.last_jump_ticks) && state.last_jump_ticks[tick]
			angle := "-" if tick >= count-1 else fmt.tprintf("%.3f", facings[tick])
			values := [?]string{
				fmt.tprintf("%d", tick),
				angle,
				turns[tick],
				fmt.tprintf("%.*f", position_precision, xvals[tick]),
				fmt.tprintf("%.*f", position_precision, zvals[tick]),
				vxvals[tick],
				vzvals[tick],
				speedvals[tick],
				directionvals[tick],
			}
			for column in 0..<9 {
				im.TableSetColumnIndex(c.int(column))
				if jump_row {
					center_text_colored(values[column], jump_text_color)
				} else {
					center_text(values[column])
				}
			}
		}
		im.EndTable()
	}
	im.PopStyleVar()
	im.Spacing(); im.Spacing()

	display_facings := format_angle_list(facings[:], false, ", ")
	defer delete(display_facings)
	display_turns := format_angle_list(facings[:], true, ", ")
	defer delete(display_turns)
	copied_facings := format_angle_list(facings[:], false, copy_separator(state.post.copy_separator))
	defer delete(copied_facings)
	copied_turns := format_angle_list(facings[:], true, copy_separator(state.post.copy_separator))
	defer delete(copied_turns)
	read_only_block("Facing", display_facings, copied_facings)
	im.Spacing()
	read_only_block("Turn", display_turns, copied_turns)

	im.AlignTextToFramePadding()
	pushed_ui = push_font(ui_font)
	im.Text("Separator for copied angles:")
	im.SameLine(0, ui_px(8))
	separator := c.int(state.post.copy_separator)
	im.SetNextItemWidth(ui_px(90))
	items := [?]cstring{"comma", "space", "\\n"}
	if combo_select("##copySeparator", &separator, items[:]) do state.post.copy_separator = Separator_Type(separator)
	pop_font(pushed_ui)
	im.Spacing()

	pop_font(pushed_code)
	im.EndChild()
	im.EndChild()
}

close_tab :: proc(app_state: ^App_State, index: int) {
	if app_state.tab_count <= 1 {
		destroy_tab(app_state.tabs[0])
		app_state.tabs[0] = make_default_tab(app_state.next_tab_id)
		app_state.next_tab_id += 1
		app_state.active_tab = 0
		return
	}
	destroy_tab(app_state.tabs[index])
	for i in index..<app_state.tab_count-1 {
		app_state.tabs[i] = app_state.tabs[i+1]
	}
	app_state.tab_count -= 1
	app_state.tabs[app_state.tab_count] = nil
	app_state.active_tab = clamp(app_state.active_tab, 0, app_state.tab_count-1)
}

find_tab_index :: proc(app_state: ^App_State, id: int) -> int {
	for i in 0..<app_state.tab_count {
		if app_state.tabs[i].id == id do return i
	}
	return -1
}

has_modified_tabs :: proc(app_state: ^App_State) -> bool {
	for i in 0..<app_state.tab_count {
		if is_tab_modified(app_state.tabs[i]) do return true
	}
	return false
}

save_all_tabs :: proc(app_state: ^App_State) -> string {
	for i in 0..<app_state.tab_count {
		tab := app_state.tabs[i]
		if !is_tab_modified(tab) do continue
		if err := save_tab_to_file(tab); err != "" do return err
	}
	return ""
}

draw_close_tab_popup :: proc(app_state: ^App_State) {
	if app_state.pending_close_tab_id < 0 do return
	index := find_tab_index(app_state, app_state.pending_close_tab_id)
	if index < 0 {
		app_state.pending_close_tab_id = -1
		return
	}
	if im.BeginPopupModal("Save Tab Before Closing?", nil, {.AlwaysAutoResize}) {
		tab := app_state.tabs[index]
		im.Text(
			"Save changes to '%s' before closing?",
			cstring(&tab.name[0]),
		)
		error_text := buffer_string(app_state.close_popup_error[:])
		if error_text != "" {
			c_error := strings.clone_to_cstring(error_text)
			im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
			delete(c_error)
		}
		im.Spacing()
		if im.Button("Save", {ui_px(110), 0}) {
			save_err := save_tab_to_file(tab)
			if save_err == "" {
				close_tab(app_state, index)
				app_state.pending_close_tab_id = -1
				im.CloseCurrentPopup()
			} else {
				buffer_set(app_state.close_popup_error[:], save_err)
				delete(save_err)
			}
		}
		im.SameLine()
		if im.Button("Don't Save", {ui_px(110), 0}) {
			close_tab(app_state, index)
			app_state.pending_close_tab_id = -1
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {ui_px(110), 0}) {
			app_state.pending_close_tab_id = -1
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

draw_exit_popup :: proc(app_state: ^App_State) {
	if !show_exit_prompt do return
	im.OpenPopup("Save Changes Before Exit?")
	if im.BeginPopupModal("Save Changes Before Exit?", nil, {.AlwaysAutoResize}) {
		im.Text("There are unsaved tabs. Save before exiting?")
		error_text := buffer_string(exit_error[:])
		if error_text != "" {
			c_error := strings.clone_to_cstring(error_text)
			im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
			delete(c_error)
		}
		if im.Button("Save All", {ui_px(120), 0}) {
			err := save_all_tabs(app_state)
			if err == "" {
				request_exit = true
				show_exit_prompt = false
				im.CloseCurrentPopup()
			} else {
				buffer_set(exit_error[:], err)
				delete(err)
			}
		}
		im.SameLine()
		if im.Button("Discard All", {ui_px(120), 0}) {
			request_exit = true
			show_exit_prompt = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {ui_px(120), 0}) {
			show_exit_prompt = false
			buffer_clear(exit_error[:])
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

draw_split_app :: proc(app_state: ^App_State) {
	viewport := im.GetMainViewport()
	im.SetNextWindowPos(viewport.Pos)
	im.SetNextWindowSize(viewport.Size)
	flags := im.WindowFlags_NoDecoration | im.WindowFlags{.NoMove, .NoResize, .NoCollapse}
	if im.Begin("SheepramRoot", nil, flags) {
		close_index := -1
		just_created := -1
		if im.BeginTable("top_bar", 2, im.TableFlags_SizingStretchSame | im.TableFlags_NoBordersInBody) {
			im.TableSetupColumn("tabs", {.WidthStretch})
			im.TableSetupColumn("load", {.WidthFixed}, ui_px(120))
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			if im.BeginTabBar("optimizer_tabs") {
				can_add := app_state.tab_count < MAX_TABS
				if !can_add do im.BeginDisabled()
				if im.TabItemButton("+", {.Trailing}) && can_add {
					app_state.tabs[app_state.tab_count] = make_default_tab(app_state.next_tab_id)
					app_state.next_tab_id += 1
					just_created = app_state.tab_count
					app_state.active_tab = just_created
					app_state.tab_count += 1
				}
				if !can_add do im.EndDisabled()
				for i in 0..<app_state.tab_count {
					tab := app_state.tabs[i]
					label := fmt.aprintf("%s###tab_%d", buffer_string(tab.name[:]), tab.id)
					c_label := strings.clone_to_cstring(label)
					open := true
					tab_flags: im.TabItemFlags
					if i == just_created do tab_flags += {.SetSelected}
					if im.BeginTabItem(c_label, &open, tab_flags) {
						app_state.active_tab = i
						im.EndTabItem()
					}
					if !open {
						if tab.optimizer_job != nil {
							buffer_set(
								tab.inline_save_message[:],
								"Optimizer is still running; close the tab after it finishes.",
							)
							tab.inline_save_is_error = true
						} else if is_tab_modified(tab) {
							app_state.pending_close_tab_id = tab.id
							buffer_clear(app_state.close_popup_error[:])
						} else {
							close_index = i
						}
					}
					delete(c_label); delete(label)
				}
				im.EndTabBar()
			}
			im.TableSetColumnIndex(1)
			if im.Button("Load Preset", {-1, 0}) {
				tab := app_state.tabs[app_state.active_tab]
				if !nfd_ready {
					buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", nfd.get_error()))
					tab.inline_save_is_error = true
				} else {
					default_dir, _ := tabs_directory()
					selected, result := nfd.open_json(default_dir)
					delete(default_dir)
					if result == .Okay {
						load_err := load_tab_from_file(tab, selected)
						if load_err != "" {
							buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", load_err))
							tab.inline_save_is_error = true
							delete(load_err)
						} else {
							buffer_set(tab.inline_save_message[:], fmt.tprintf("Loaded: %s", buffer_string(tab.saved_file_name[:])))
							tab.inline_save_is_error = false
						}
						delete(selected)
					} else if result == .Error {
						buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", nfd.get_error()))
						tab.inline_save_is_error = true
					}
				}
			}
			im.EndTable()
		}
		if close_index >= 0 do close_tab(app_state, close_index)
		if app_state.pending_close_tab_id >= 0 {
			im.OpenPopup("Save Tab Before Closing?")
		}
		draw_close_tab_popup(app_state)
		draw_exit_popup(app_state)

		tab := app_state.tabs[app_state.active_tab]
		available := im.GetContentRegionAvail()
		divider := ui_px(8)
		min_panel_width := ui_px(250)
		if tab.left_width <= 0 do tab.left_width = available.x*0.7
		tab.left_width = clamp(tab.left_width, min_panel_width, available.x-min_panel_width-divider)
		right_width := available.x-tab.left_width-divider

		im.BeginChild("LeftRegion", {tab.left_width, available.y})
		draw_input_panel(app_state, tab)
		im.EndChild()
		im.SameLine(0, 0)
		divider_pos := im.GetCursorScreenPos()
		im.InvisibleButton("Divider", {divider, available.y}, {.MouseButtonLeft})
		divider_hovered := im.IsItemHovered()
		divider_active := im.IsItemActive()
		if divider_hovered || divider_active do im.SetMouseCursor(.ResizeEW)
		if im.IsItemActive() {
			tab.left_width += im.GetIO().MouseDelta.x
			tab.left_width = clamp(tab.left_width, min_panel_width, available.x-min_panel_width-divider)
			right_width = available.x-tab.left_width-divider
		}
		divider_color := im.GetColorU32(.Separator)
		if divider_active do divider_color = im.GetColorU32(.SeparatorActive)
		else if divider_hovered do divider_color = im.GetColorU32(.SeparatorHovered)
		im.DrawList_AddRectFilled(
			im.GetWindowDrawList(),
			divider_pos,
			{divider_pos.x+divider, divider_pos.y+available.y},
			divider_color,
		)
		im.SameLine(0, 0)
		im.BeginChild("RightRegion", {right_width, available.y})
		output_margin := ui_pad(10)
		output_size := im.GetContentRegionAvail()
		output_size.x = max(f32(0), output_size.x-2*output_margin)
		output_size.y = max(f32(0), output_size.y-2*output_margin)
		cursor := im.GetCursorPos()
		im.SetCursorPos({cursor.x+output_margin, cursor.y+output_margin})
		draw_output_panel(tab, output_size)
		im.EndChild()
	}
	im.End()
}

Initialize_GUI :: proc(theme: Theme, ui_size_level: int, native_file_dialog_ready: bool) {
	load_fonts()
	base_style = im.GetStyle()^
	base_style_ready = true
	apply_ui_size(ui_size_level, theme)
	nfd_ready = native_file_dialog_ready
	show_exit_prompt = false
	request_exit = false
	buffer_clear(exit_error[:])
}

GUI_Prepare_Frame :: proc(app_state: ^App_State) {
	// Switch the preloaded font set and global style before ImGui::NewFrame().
	if app_state.ui_size_level != applied_ui_size_level {
		apply_ui_size(app_state.ui_size_level, app_state.theme)
	}
}

Draw_GUI :: proc(app_state: ^App_State) {
	poll_optimizer_jobs(app_state)
	pushed := push_font(ui_font)
	draw_split_app(app_state)
	pop_font(pushed)
}

GUI_Handle_Window_Close :: proc(app_state: ^App_State) {
	if has_running_optimizer_jobs(app_state) {
		tab := app_state.tabs[app_state.active_tab]
		buffer_set(
			tab.inline_save_message[:],
			"Optimizer is still running; exit after it finishes.",
		)
		tab.inline_save_is_error = true
		return
	}
	if has_modified_tabs(app_state) {
		show_exit_prompt = true
		buffer_clear(exit_error[:])
	} else {
		request_exit = true
	}
}

GUI_Should_Exit :: proc() -> bool {
	return request_exit
}
