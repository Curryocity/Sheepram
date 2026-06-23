package app

import "core:thread"

Optimizer_Job :: struct {
	worker:      ^thread.Thread,
	environment: Environment,
}

optimizer_job_worker :: proc(data: rawptr) {
	job := cast(^Optimizer_Job)data
	run_optimizer(&job.environment)
}

start_optimizer_job :: proc(tab: ^Tab_State) -> bool {
	if tab.optimizer_job != nil do return false

	// The worker owns a value-copy of every optimizer input. Never let it
	// access the live Environment while ImGui may be editing that state.
	clear_solution(&tab.env)
	buffer_clear(tab.env.last_error[:])
	buffer_clear(tab.inline_save_message[:])
	job := new(Optimizer_Job)
	job.environment = tab.env
	job.environment.last_solution = nil
	job.worker = thread.create_and_start_with_data(
		rawptr(job),
		optimizer_job_worker,
	)
	if job.worker == nil {
		free(job)
		buffer_set(tab.env.last_error[:], "Error:\nFailed to start optimizer thread.")
		return false
	}
	tab.optimizer_job = job
	return true
}

poll_optimizer_job :: proc(tab: ^Tab_State) -> bool {
	job := tab.optimizer_job
	if job == nil || !thread.is_done(job.worker) do return false

	thread.destroy(job.worker)
	result := &job.environment
	state := &tab.env
	clear_solution(state)
	state.last_solution = result.last_solution
	result.last_solution = nil
	state.compile_time_seconds = result.compile_time_seconds
	state.optimize_time_seconds = result.optimize_time_seconds
	state.x_origin = result.x_origin
	state.z_origin = result.z_origin
	state.angle_offset = result.angle_offset
	state.last_error = result.last_error

	free(job)
	tab.optimizer_job = nil
	return true
}

destroy_optimizer_job :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil do return
	thread.destroy(job.worker)
	clear_solution(&job.environment)
	free(job)
	tab.optimizer_job = nil
}

poll_optimizer_jobs :: proc(app: ^App_State) {
	for i in 0..<app.tab_count {
		if app.tabs[i] != nil do poll_optimizer_job(app.tabs[i])
	}
}

has_running_optimizer_jobs :: proc(app: ^App_State) -> bool {
	for i in 0..<app.tab_count {
		if app.tabs[i] != nil && app.tabs[i].optimizer_job != nil do return true
	}
	return false
}
