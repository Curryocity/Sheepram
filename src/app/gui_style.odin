package app

import "core:c"
import "core:strings"

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
