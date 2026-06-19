package app

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"

import nfd "../nfd"
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

ui_px :: proc(value: f32) -> f32 {
	return value*ui_scale
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
	style.WindowBorderHoverPadding = max(style.WindowBorderHoverPadding, f32(1))
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
	style.FrameBorderSize = 0
	style.WindowPadding = {ui_px(12), ui_px(10)}
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

draw_selection_rect :: proc(minimum, maximum: im.Vec2) {
	draw_list := im.GetForegroundDrawList()
	im.DrawList_AddRect(draw_list, minimum, maximum, im.GetColorU32ImVec4({1, 1, 1, 0.4}), 3, {}, 2)
}

draw_model_table :: proc(tab: ^Tab_State) {
	state := &tab.env
	if state.n < N_MIN || state.n > N_MAX {
		im.TextColored({0.95, 0.35, 0.35, 1}, "Refused to render the table: n must be in range [%d, %d].", N_MIN, N_MAX)
		return
	}
	if state.n != tab.prev_n {
		state.n = clamp(state.n, N_MIN, N_MAX)
		start := max(0, tab.prev_n)
		for i in start..<state.n {
			source := max(0, i-1)
			buffer_set(state.drag_x[i][:], buffer_string(state.drag_x[source][:]))
			buffer_set(state.drag_z[i][:], buffer_string(state.drag_z[source][:]))
			buffer_set(state.accel[i][:], buffer_string(state.accel[source][:]))
			buffer_set(
				state.post.angle_offset[i][:],
				buffer_string(state.post.angle_offset[source][:]),
			)
		}
		buffer_set(state.accel[0][:], "initV")
		tab.prev_n = state.n
	}

	im.BeginChild("model_region", {0, ui_px(145)})
	region_pos := im.GetWindowPos()
	region_size := im.GetWindowSize()
	tab.model_region_min = {region_pos.x, region_pos.y}
	tab.model_region_max = {region_pos.x+region_size.x, region_pos.y+region_size.y}
	flags := im.TableFlags_Borders | im.TableFlags_RowBg |
	         im.TableFlags_ScrollX | im.TableFlags_ScrollY |
	         im.TableFlags_SizingFixedFit
	if im.BeginTable("model_table", c.int(state.n+1), flags) {
		im.TableSetupScrollFreeze(1, 0)
		for i in 0..<state.n+1 do im.TableSetupColumn("", {.WidthFixed}, 65)
		im.TableNextRow({.Headers})
		im.TableSetColumnIndex(0)
		center_text("Tick")
		for i in 0..<state.n {im.TableSetColumnIndex(c.int(i+1)); center_text(fmt.tprintf("%d", i))}
		rows := [?]cstring{"DragX", "DragZ", "Accel"}
		for row in 0..<3 {
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			center_text(string(rows[row]))
			for tick in 0..<state.n {
				im.TableSetColumnIndex(c.int(tick+1))
				if row == 2 && tick == 0 {
					center_text("initV")
					continue
				}
				im.PushIDInt(c.int(row*1000+tick))
				im.SetNextItemWidth(65)
				switch row {
				case 0: _ = input_text("##drag_x", state.drag_x[tick][:])
				case 1: _ = input_text("##drag_z", state.drag_z[tick][:])
				case 2: _ = input_text("##accel", state.accel[tick][:])
				}
				if im.IsItemActivated() || im.IsItemClicked() do tab.selected_model_tick_index = tick
				if tab.selected_model_tick_index == tick do draw_selection_rect(im.GetItemRectMin(), im.GetItemRectMax())
				im.PopID()
			}
		}
		im.EndTable()
	}
	im.EndChild()
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
	if im.Button("+", {26, im.GetFrameHeight()}) && state.var_capacity < MAX_GLOBALS {
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
	if im.Button("-", {26, im.GetFrameHeight()}) && state.var_capacity > 1 {
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
		im.TableSetupColumn("", {.WidthFixed}, 60)
		for i in 0..<state.var_capacity {
			im.TableSetupColumn("", {.WidthFixed}, 70)
		}
		for row in 0..<2 {
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			center_text("Name" if row == 0 else "Value")
			for i in 0..<state.var_capacity {
				im.TableSetColumnIndex(c.int(i+1))
				im.PushIDInt(c.int(row*1000+i))
				im.SetNextItemWidth(70)
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

input_text_auto_width :: proc(label: cstring, buffer: []byte, minimum: f32 = 10) {
	text := buffer_string(buffer)
	text_c := strings.clone_to_cstring(text); defer delete(text_c)
	width := max(minimum, im.CalcTextSize(text_c).x+im.GetStyle().FramePadding.x*2)
	im.SetNextItemWidth(width)
	_ = input_text(label, buffer)
}

draw_postprocessor :: proc(state: ^Environment) {
	if !im.CollapsingHeader("Postprocessor", {.DefaultOpen}) do return
	im.PushStyleVarImVec2(.FramePadding, {ui_px(4), ui_px(2)})
	im.PushStyleVar(.FrameBorderSize, 0)
	im.PushStyleVar(.FrameRounding, 2)

	im.AlignTextToFramePadding(); im.Text("X Origin:"); im.SameLine(0, 0)
	pushed := push_font(code_font)
	im.Text(" X["); im.SameLine(0, 0); input_text_auto_width("##xTick", state.post.x_tick[:])
	im.SameLine(0, 0); im.Text("] + "); im.SameLine(0, 0); input_text_auto_width("##xAdd", state.post.x_add[:])
	pop_font(pushed)

	im.AlignTextToFramePadding(); im.Text("Z Origin:"); im.SameLine(0, 0)
	pushed = push_font(code_font)
	im.Text(" Z["); im.SameLine(0, 0); input_text_auto_width("##zTick", state.post.z_tick[:])
	im.SameLine(0, 0); im.Text("] + "); im.SameLine(0, 0); input_text_auto_width("##zAdd", state.post.z_add[:])
	pop_font(pushed)

	im.AlignTextToFramePadding(); im.Text("X/Z precision:"); im.SameLine(0, 8)
	precision := c.int(state.post.position_precision)
	im.SetNextItemWidth(80)
	pushed = push_font(code_font)
	_ = im.InputInt("##positionPrecision", &precision)
	pop_font(pushed)
	state.post.position_precision = clamp(int(precision), 3, 10)

	im.AlignTextToFramePadding(); im.Text("Angle Offset (Manual copying section):"); im.SameLine(0, 8)
	offset_mode := c.int(state.post.offset_mode)
	im.SetNextItemWidth(90)
	items := [?]cstring{"Facing", "Turn"}
	if combo_select("##offsetMode", &offset_mode, items[:]) do state.post.offset_mode = Offset_Type(offset_mode)
	im.SameLine(0, 8)
	if im.Button("Reset") {
		for i in 0..<state.n do buffer_set(state.post.angle_offset[i][:], "0")
	}

	im.BeginChild("angle_offset_region", {0, ui_px(63)})
	flags := im.TableFlags_Borders | im.TableFlags_RowBg | im.TableFlags_ScrollX | im.TableFlags_SizingFixedFit
	if im.BeginTable("angle_offset_table", c.int(state.n+1), flags) {
		im.TableSetupScrollFreeze(1, 0)
		im.TableNextRow()
		im.TableSetColumnIndex(0); center_text("Tick")
		for i in 0..<state.n {im.TableSetColumnIndex(c.int(i+1)); center_text(fmt.tprintf("%d", i))}
		im.TableNextRow()
		im.TableSetColumnIndex(0); center_text("Offset")
		for i in 0..<state.n {
			im.TableSetColumnIndex(c.int(i+1))
			im.PushIDInt(c.int(4000+i))
			im.SetNextItemWidth(50)
			_ = input_text("##angle_offset", state.post.angle_offset[i][:])
			im.PopID()
		}
		im.EndTable()
	}
	im.EndChild()
	im.PopStyleVar(3)
}

draw_input_panel :: proc(app_state: ^App_State, tab: ^Tab_State) {
	state := &tab.env
	im.PushStyleVarImVec2(.WindowPadding, {ui_px(24), ui_px(10)})
	im.BeginChild("InputPanel", {0, 0}, {.Borders})
	im.PopStyleVar()
	im.Spacing()

	im.AlignTextToFramePadding(); im.Text("Theme:"); im.SameLine()
	theme := c.int(app_state.theme)
	im.SetNextItemWidth(180)
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
	im.SetNextItemWidth(220)
	pressed_enter := input_text("##tab_name", tab.name_draft[:], {.EnterReturnsTrue})
	if pressed_enter || im.IsItemDeactivatedAfterEdit() {
		name := strings.trim_space(buffer_string(tab.name_draft[:]))
		if name == "" do name = fmt.tprintf("Untitled %d", tab.id)
		buffer_set(tab.name_draft[:], name)
		buffer_set(tab.name[:], name)
	}
	im.SameLine()
	if im.Button("Save") {
		name := strings.trim_space(buffer_string(tab.name_draft[:]))
		if name == "" do name = fmt.tprintf("Untitled %d", tab.id)
		buffer_set(tab.name_draft[:], name)
		buffer_set(tab.name[:], name)
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

	// === Model ===
	im.SeparatorText("Model")
	im.AlignTextToFramePadding(); im.Text("n ="); im.SameLine()
	n_value := c.int(state.edit_n)
	im.SetNextItemWidth(60)
	_ = im.InputInt("##n", &n_value, 0, 0)
	state.edit_n = int(n_value)
	model_controls_min := im.GetItemRectMin()
	model_controls_max := im.GetItemRectMax()
	if im.IsItemDeactivatedAfterEdit() do state.n = state.edit_n
	active_tick := state.n-1
	if tab.selected_model_tick_index >= 0 && tab.selected_model_tick_index < state.n {
		active_tick = tab.selected_model_tick_index
	}
	im.SameLine()
	if im.Button("-", {30, im.GetFrameHeight()}) && state.n > 1 && active_tick > 0 {
		for i in active_tick..<state.n-1 {
			state.drag_x[i] = state.drag_x[i+1]
			state.drag_z[i] = state.drag_z[i+1]
			state.accel[i] = state.accel[i+1]
			state.post.angle_offset[i] = state.post.angle_offset[i+1]
		}
		state.n -= 1; state.edit_n = state.n
		buffer_set(state.accel[0][:], "initV")
		tab.prev_n = state.n
		tab.selected_model_tick_index = max(0, active_tick-1)
	}
	item_min, item_max := im.GetItemRectMin(), im.GetItemRectMax()
	model_controls_min = {min(model_controls_min.x, item_min.x), min(model_controls_min.y, item_min.y)}
	model_controls_max = {max(model_controls_max.x, item_max.x), max(model_controls_max.y, item_max.y)}
	im.SameLine()
	if im.Button("+", {30, im.GetFrameHeight()}) && state.n < N_MAX {
		insert_index := active_tick+1
		for i := state.n; i > insert_index; i -= 1 {
			state.drag_x[i] = state.drag_x[i-1]
			state.drag_z[i] = state.drag_z[i-1]
			state.accel[i] = state.accel[i-1]
			state.post.angle_offset[i] = state.post.angle_offset[i-1]
		}
		state.drag_x[insert_index] = state.drag_x[active_tick]
		state.drag_z[insert_index] = state.drag_z[active_tick]
		state.accel[insert_index] = state.accel[active_tick]
		state.post.angle_offset[insert_index] = state.post.angle_offset[active_tick]
		state.n += 1; state.edit_n = state.n
		buffer_set(state.accel[0][:], "initV")
		tab.prev_n = state.n
		tab.selected_model_tick_index = insert_index
	}
	item_min, item_max = im.GetItemRectMin(), im.GetItemRectMax()
	model_controls_min = {min(model_controls_min.x, item_min.x), min(model_controls_min.y, item_min.y)}
	model_controls_max = {max(model_controls_max.x, item_max.x), max(model_controls_max.y, item_max.y)}

	im.AlignTextToFramePadding(); im.Text("initV ="); im.SameLine()
	im.SetNextItemWidth(160)
	_ = input_text("##model_initV", state.init_v[:])
	im.Spacing()
	draw_model_table(tab)
	mouse := im.GetMousePos()
	inside_controls := mouse.x >= model_controls_min.x && mouse.x <= model_controls_max.x &&
	                   mouse.y >= model_controls_min.y && mouse.y <= model_controls_max.y
	inside_model := mouse.x >= tab.model_region_min[0] && mouse.x <= tab.model_region_max[0] &&
	                mouse.y >= tab.model_region_min[1] && mouse.y <= tab.model_region_max[1]
	if im.IsMouseClicked(.Left) && !inside_controls && !inside_model do tab.selected_model_tick_index = -1
	im.Spacing()

	// === Core ===
	im.SeparatorText("Core")
	im.AlignTextToFramePadding(); im.Text("Objective Function: "); im.SameLine()
	objective := c.int(state.curr_obj)
	im.SetNextItemWidth(120)
	objective_items := [?]cstring{"X[n]", "Z[n]", "Custom"}
	if combo_select("##obj", &objective, objective_items[:]) do state.curr_obj = Objective_Type(objective)
	im.SameLine(0, 15)
	if im.Button("Maximize" if state.maximize else "Minimize") do state.maximize = !state.maximize
	if state.curr_obj == .Custom {
		im.SetNextItemWidth(-1)
		pushed := push_font(code_font)
		_ = input_text("##custom_objective_script", state.obj_script[:])
		pop_font(pushed)
	}
	draw_global_table(tab)

	// === Constraints ===
	im.SeparatorText("Constraints")
	tab.cons_editor_height = clamp(tab.cons_editor_height, 80, 360)
	pushed := push_font(code_font)
	_ = input_multiline("##constraint_script", state.constraint_script[:], {-1, tab.cons_editor_height}, {.AllowTabInput})
	pop_font(pushed)
	divider_pos := im.GetCursorScreenPos()
	divider_height := ui_px(8)
	im.InvisibleButton("##constraint_divider", {im.GetContentRegionAvail().x, divider_height}, {.MouseButtonLeft})
	divider_hovered := im.IsItemHovered()
	divider_active := im.IsItemActive()
	if divider_hovered || divider_active do im.SetMouseCursor(.ResizeNS)
	if divider_active do tab.cons_editor_height = clamp(tab.cons_editor_height+im.GetIO().MouseDelta.y, 80, 360)
	divider_color := im.GetColorU32(.Separator)
	if divider_active do divider_color = im.GetColorU32(.SeparatorActive)
	else if divider_hovered do divider_color = im.GetColorU32(.SeparatorHovered)
	divider_y := divider_pos.y+divider_height*0.5
	im.DrawList_AddLine(
		im.GetWindowDrawList(),
		{divider_pos.x, divider_y},
		{divider_pos.x+im.GetItemRectSize().x, divider_y},
		divider_color,
		2,
	)

	// === Postprocessing ===
	draw_postprocessor(state)

	// === Optimize Button ===
	if tab.optimizer_job != nil {
		im.BeginDisabled()
		_ = im.Button("Optimizing...", {-1, ui_px(35)})
		im.EndDisabled()
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
		if plot_hovered {
			dx, dy := point.x-mouse.x, point.y-mouse.y
			dist_sq := dx*dx+dy*dy
			if dist_sq <= best_dist_sq {
				best_dist_sq = dist_sq
				hovered_index = i
			}
		}
		im.DrawList_AddCircleFilled(draw_list, point, 3.5, 0xfff0f0f0)
	}
	if hovered_index >= 0 {
		point := to_screen(xs[hovered_index], zs[hovered_index], center, layout)
		im.DrawList_AddCircle(draw_list, point, 7, 0xdcffffff, 0, 1.8)
	}
	im.DrawList_PopClipRect(draw_list)

	if hovered_index >= 0 && im.BeginTooltip() {
		im.Text("Tick %d", hovered_index)
		im.Separator()
		im.Text("Facing:  %.*f", angle_precision, facings[hovered_index])
		im.Text("Pos:  (%.*f, %.*f)", position_precision, xs[hovered_index], position_precision, zs[hovered_index])
		vx_c := strings.clone_to_cstring(vxs[hovered_index]); defer delete(vx_c)
		vz_c := strings.clone_to_cstring(vzs[hovered_index]); defer delete(vz_c)
		im.Text("Vel: (%s, %s)", vx_c, vz_c)
		if hovered_index < len(xs)-1 {
			vx := xs[hovered_index+1]-xs[hovered_index]
			vz := zs[hovered_index+1]-zs[hovered_index]
			magnitude := math.sqrt(vx*vx+vz*vz)
			direction := math.atan2(vx, vz)*180/math.PI
			im.Text("SpeedVec: (%.*f, %.*f°)", position_precision, magnitude, position_precision, direction)
		}
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

format_angle_list :: proc(facings: []f64, offsets: []f64, turns: bool, separator: string) -> string {
	builder := strings.builder_make()
	count := len(facings)-1
	if turns do count -= 1
	for i in 0..<max(0, count) {
		if i > 0 do strings.write_string(&builder, separator)
		value := facings[i]+offsets[i]
		if turns {
			value = wrap_degrees_180(facings[i+1]+offsets[i+1]-value)
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

draw_output_panel :: proc(tab: ^Tab_State) {
	state := &tab.env
	im.BeginChild("OutputPanel", {0, 0}, {.Borders})
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
			im.TextDisabled("Optimizing...")
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
	im.TextDisabled(
		"Compile: %.3f ms | Optimize: %.3f ms",
		state.compile_time_seconds*1000,
		state.optimize_time_seconds*1000,
	)
	im.Spacing(); im.Spacing()

	count := len(solution.xs)
	facings := make([dynamic]f64, count); defer delete(facings)
	for i in 0..<len(solution.thetas) {
		wrapped := wrap_degrees_180(solution.thetas[i]*180/math.PI)
		facings[i] = math.round(200*wrapped)*0.005
	}
	turns := make([dynamic]string, count); defer delete(turns)
	xvals := make([dynamic]f64, count); defer delete(xvals)
	zvals := make([dynamic]f64, count); defer delete(zvals)
	vxvals := make([dynamic]string, count); defer delete(vxvals)
	vzvals := make([dynamic]string, count); defer delete(vzvals)
	for i in 0..<count {
		turns[i] = "-"
		vxvals[i] = "-"
		vzvals[i] = "-"
		xvals[i] = solution.xs[i]-solution.xs[state.x_index]-state.x_add
		zvals[i] = solution.zs[i]-solution.zs[state.z_index]-state.z_add
	}
	for i in 0..<count-2 {
		turns[i] = fmt.aprintf("%.3f", wrap_degrees_180(facings[i+1]-facings[i]))
	}
	defer for i in 0..<count-2 do delete(turns[i])
	for i in 0..<count-1 {
		vxvals[i] = fmt.aprintf("%.*f", position_precision, xvals[i+1]-xvals[i])
		vzvals[i] = fmt.aprintf("%.*f", position_precision, zvals[i+1]-zvals[i])
	}
	defer for i in 0..<count-1 {delete(vxvals[i]); delete(vzvals[i])}

	im.PushStyleVarImVec2(.CellPadding, {ui_px(10), ui_px(3)})
	available := im.GetContentRegionAvail()
	table_width := min(f32(877), available.x)
	visible_rows := min(count, 13)
	table_height := min(f32(visible_rows)*34+50, available.y)
	table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersV |
	               im.TableFlags_ScrollY | im.TableFlags_ScrollX | im.TableFlags_SizingFixedFit |
	               im.TableFlags_NoHostExtendX
	if im.BeginTable("ResultTable", 7, table_flags, {table_width, table_height}) {
		im.TableSetupScrollFreeze(0, 1)
		headers := [?]cstring{"Tick", "Facing", "Turn", "X", "Z", "Vx", "Vz"}
		widths := [?]f32{50, 100, 100, 120, 120, 120, 120}
		for i in 0..<7 do im.TableSetupColumn(headers[i], {.WidthFixed}, widths[i])
		im.TableNextRow({.Headers}, 20)
		for i in 0..<7 {im.TableSetColumnIndex(c.int(i)); center_text(string(headers[i]))}
		for tick in 0..<count {
			im.TableNextRow({}, 20)
			angle := "-" if tick >= count-1 else fmt.tprintf("%.3f", facings[tick])
			values := [?]string{
				fmt.tprintf("%d", tick),
				angle,
				turns[tick],
				fmt.tprintf("%.*f", position_precision, xvals[tick]),
				fmt.tprintf("%.*f", position_precision, zvals[tick]),
				vxvals[tick],
				vzvals[tick],
			}
			for column in 0..<7 {
				im.TableSetColumnIndex(c.int(column))
				center_text(values[column])
			}
		}
		im.EndTable()
	}
	im.PopStyleVar()
	im.Spacing(); im.Spacing()

	solution_n := clamp(state.solution_n, 0, N_MAX)
	display_facings := format_angle_list(facings[:], state.angle_offset[:solution_n], false, ", ")
	defer delete(display_facings)
	display_turns := format_angle_list(facings[:], state.angle_offset[:solution_n], true, ", ")
	defer delete(display_turns)
	copied_facings := format_angle_list(facings[:], state.angle_offset[:solution_n], false, copy_separator(state.post.copy_separator))
	defer delete(copied_facings)
	copied_turns := format_angle_list(facings[:], state.angle_offset[:solution_n], true, copy_separator(state.post.copy_separator))
	defer delete(copied_turns)
	read_only_block("Facing", display_facings, copied_facings)
	im.Spacing()
	read_only_block("Turn", display_turns, copied_turns)

	im.AlignTextToFramePadding()
	pushed_ui := push_font(ui_font)
	im.Text("Separator for copied angles:")
	im.SameLine(0, 8)
	separator := c.int(state.post.copy_separator)
	im.SetNextItemWidth(90)
	items := [?]cstring{"comma", "space", "\\n"}
	if combo_select("##copySeparator", &separator, items[:]) do state.post.copy_separator = Separator_Type(separator)
	pop_font(pushed_ui)

	im.Spacing(); im.Spacing()
	pushed_ui = push_font(ui_font)
	im.Text("Visualization")
	pop_font(pushed_ui)
	viewport_size := compute_plot_viewport_size(xvals[:], zvals[:])
	layout := compute_xz_plot_layout(xvals[:], zvals[:], viewport_size)
	canvas_width := max(viewport_size.x, layout.content_width)
	viewport_size.x += 25
	viewport_size.y += 50
	im.BeginChild("PlotScroll", {viewport_size.x, viewport_size.y+20}, {.Borders}, {.HorizontalScrollbar})
	if im.IsWindowAppearing() do im.SetScrollX(max(0, 0.5*(canvas_width-viewport_size.x)))
	draw_xz_plot(xvals[:], zvals[:], facings[:], vxvals[:], vzvals[:], {canvas_width, viewport_size.y}, position_precision, angle_precision)
	im.EndChild()
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
		if im.Button("Save", {110, 0}) {
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
		if im.Button("Don't Save", {110, 0}) {
			close_tab(app_state, index)
			app_state.pending_close_tab_id = -1
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {110, 0}) {
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
		if im.Button("Save All", {120, 0}) {
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
		if im.Button("Discard All", {120, 0}) {
			request_exit = true
			show_exit_prompt = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {120, 0}) {
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
		draw_output_panel(tab)
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
