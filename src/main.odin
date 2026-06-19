package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"

import app "./app"
import nfd "./nfd"
import im "../third_party/odin-imgui"
import "../third_party/odin-imgui/imgui_impl_glfw"
import "../third_party/odin-imgui/imgui_impl_opengl3"
import gl "vendor:OpenGL"
import "vendor:glfw"

TITLE :: "Wolfram? No. Sheepram."

glfw_error_callback :: proc "c" (error_code: c.int, description: cstring) {
	context = runtime.default_context()
	fmt.eprintf("GLFW Error %d: %s\n", error_code, description)
}

initialize_resource_directory :: proc() {
	if os.is_file("asset/fonts/JetBrainsMono-Regular.ttf") do return
	executable_dir, err := os.get_executable_directory(context.allocator)
	if err != nil do return
	defer delete(executable_dir)

	parent_resources, parent_err := os.join_path(
		{executable_dir, "..", "Resources"},
		context.allocator,
	)
	if parent_err != nil do return
	defer delete(parent_resources)
	child_resources, child_err := os.join_path(
		{executable_dir, "Resources"},
		context.allocator,
	)
	if child_err != nil do return
	defer delete(child_resources)
	candidates := [?]string{executable_dir, parent_resources, child_resources}
	for candidate in candidates {
		font_path, path_err := os.join_path(
			{candidate, "asset/fonts/JetBrainsMono-Regular.ttf"},
			context.allocator,
		)
		if path_err != nil do continue
		found := os.is_file(font_path)
		delete(font_path)
		if found {
			_ = os.set_working_directory(candidate)
			return
		}
	}
}

try_create_window :: proc(major, minor: int, request_profile: bool) -> glfw.WindowHandle {
	glfw.DefaultWindowHints()
	if major > 0 && minor > 0 {
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, c.int(major))
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, c.int(minor))
	}
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
	} else {
		if request_profile do glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	}
	window := glfw.CreateWindow(1100, 720, TITLE, nil, nil)
	if window == nil do return nil
	glfw.MakeContextCurrent(window)
	if glfw.GetCurrentContext() != window {
		glfw.DestroyWindow(window)
		return nil
	}
	return window
}

main :: proc() {
	initialize_resource_directory()
	glfw.SetErrorCallback(glfw_error_callback)
	assert(cast(bool)glfw.Init())
	defer glfw.Terminate()

	window: glfw.WindowHandle
	glsl_version: cstring = "#version 330 core"
	when ODIN_OS == .Darwin {
		window = try_create_window(3, 3, true)
	} else {
		window = try_create_window(3, 3, false)
		glsl_version = "#version 130"
		if window == nil do window = try_create_window(3, 0, false)
		if window == nil do window = try_create_window(0, 0, false)
	}
	assert(window != nil)
	defer glfw.DestroyWindow(window)
	glfw.SwapInterval(1)

	gl.load_up_to(3, 3, proc(pointer: rawptr, name: cstring) {
		(cast(^rawptr)pointer)^ = glfw.GetProcAddress(name)
	})

	im.CHECKVERSION()
	im.CreateContext()
	defer im.DestroyContext()

	app_state := app.init_app()
	defer app.destroy_app(app_state)
	app.seed_bundled_presets()
	app.load_preferences(app_state)
	nfd_ready := nfd.init() == .Okay
	defer if nfd_ready do nfd.quit()
	app.Initialize_GUI(app_state.theme, app_state.ui_size_level, nfd_ready)

	imgui_impl_glfw.InitForOpenGL(window, true)
	defer imgui_impl_glfw.Shutdown()
	imgui_impl_opengl3.Init(glsl_version)
	defer imgui_impl_opengl3.Shutdown()

	for !app.GUI_Should_Exit() {
		glfw.PollEvents()
		if glfw.WindowShouldClose(window) {
			glfw.SetWindowShouldClose(window, false)
			app.GUI_Handle_Window_Close(app_state)
		}
		app.GUI_Prepare_Frame(app_state)
		imgui_impl_opengl3.NewFrame()
		imgui_impl_glfw.NewFrame()
		im.NewFrame()
		app.Draw_GUI(app_state)

		im.Render()
		width, height := glfw.GetFramebufferSize(window)
		gl.Viewport(0, 0, width, height)
		gl.ClearColor(0.05, 0.05, 0.05, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		imgui_impl_opengl3.RenderDrawData(im.GetDrawData())
		glfw.SwapBuffers(window)
	}
	app.save_preferences(app_state)
}
