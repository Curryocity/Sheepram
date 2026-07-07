package app

import "core:sync"
import "core:thread"
import "core:time"

Optimizer_Progress :: struct {
	mutex: sync.Atomic_Mutex,
	has_best: bool,
	best_objective: f64,
	angle_count: int,
	angles: [N_MAX]f64,
	completed_chefs: int,
	total_chefs: int,
}

Optimizer_Control :: struct {
	cancel_requested: bool,
	progress: Optimizer_Progress,
}

Optimizer_Job :: struct {
	worker:      ^thread.Thread,
	environment: Environment,
	control:     ^Optimizer_Control,
	started_at:  time.Tick,
}

optimizer_job_worker :: proc(data: rawptr) {
	job := cast(^Optimizer_Job)data
	run_optimizer(&job.environment, job.control)
}

request_optimizer_cancel :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil || job.control == nil do return
	sync.atomic_store(&job.control.cancel_requested, true)
}

optimizer_cancel_requested :: proc(control: ^Optimizer_Control) -> bool {
	if control == nil do return false
	return sync.atomic_load(&control.cancel_requested)
}

optimizer_cancel_check :: proc(data: rawptr) -> bool {
	return optimizer_cancel_requested(cast(^Optimizer_Control)data)
}

publish_optimizer_progress :: proc(
	control: ^Optimizer_Control,
	objective: f64,
	angles: []f64,
	completed_chefs, total_chefs: int,
) {
	if control == nil do return
	progress := &control.progress
	sync.atomic_mutex_lock(&progress.mutex)
	defer sync.atomic_mutex_unlock(&progress.mutex)

	progress.has_best = true
	progress.best_objective = objective
	progress.angle_count = min(len(angles), N_MAX)
	copy(progress.angles[:progress.angle_count], angles[:progress.angle_count])
	progress.completed_chefs = completed_chefs
	progress.total_chefs = total_chefs
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
	job.control = new(Optimizer_Control)
	job.started_at = time.tick_now()
	job.worker = thread.create_and_start_with_data(
		rawptr(job),
		optimizer_job_worker,
	)
	if job.worker == nil {
		free(job.control)
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
	state.last_solution_discrete = result.last_solution_discrete
	state.last_solution_cooking = result.last_solution_cooking
	state.last_solution_chefs_completed = result.last_solution_chefs_completed
	state.last_solution_chefs_total = result.last_solution_chefs_total
	state.compile_time_seconds = result.compile_time_seconds
	state.continuous_time_seconds = result.continuous_time_seconds
	state.discrete_time_seconds = result.discrete_time_seconds
	state.x_origin = result.x_origin
	state.z_origin = result.z_origin
	state.angle_offset = result.angle_offset
	state.last_jump_ticks = result.last_jump_ticks
	state.last_error = result.last_error

	free(job.control)
	free(job)
	tab.optimizer_job = nil
	return true
}

destroy_optimizer_job :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil do return
	request_optimizer_cancel(tab)
	thread.destroy(job.worker)
	clear_solution(&job.environment)
	free(job.control)
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
