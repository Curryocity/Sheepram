package app

import "core:sync"
import "core:thread"
import "core:time"

Optimizer_Progress :: struct {
	mutex: sync.Atomic_Mutex,
	has_best: bool,
	best_objective: f64,
	angles: [dynamic]f64,
	completed_chefs: int,
	total_chefs: int,
}

Optimizer_Control :: struct {
	cancel_requested: bool,
	progress: Optimizer_Progress,
}

Optimizer_Job :: struct {
	worker:     ^thread.Thread,
	material:   Optimizer_Material,
	result:     Optimizer_Result,
	control:    ^Optimizer_Control,
	started_at: time.Tick,
}

destroy_optimizer_control :: proc(control: ^Optimizer_Control) {
	if control == nil do return
	delete(control.progress.angles)
	free(control)
}

optimizer_job_worker :: proc(data: rawptr) {
	job := cast(^Optimizer_Job)data
	job.result = optimize(&job.material, job.control)
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
	resize(&progress.angles, len(angles))
	copy(progress.angles[:], angles)
	progress.completed_chefs = completed_chefs
	progress.total_chefs = total_chefs
}

start_optimizer_job :: proc(tab: ^Tab_State) -> bool {
	if tab.optimizer_job != nil do return false

	// The worker owns an immutable snapshot of every optimizer input. Never
	// let it access the live Environment while ImGui may be editing that state.
	clear_solution(&tab.env)
	buffer_clear(tab.env.last_error[:])
	buffer_clear(tab.inline_save_message[:])
	job := new(Optimizer_Job)
	job.material = make_optimizer_material(&tab.env)
	job.control = new(Optimizer_Control)
	job.started_at = time.tick_now()
	job.worker = thread.create_and_start_with_data(
		rawptr(job),
		optimizer_job_worker,
	)
	if job.worker == nil {
		destroy_optimizer_material(&job.material)
		destroy_optimizer_control(job.control)
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
	apply_optimizer_result(&tab.env, &job.result)
	destroy_optimizer_result(&job.result)
	destroy_optimizer_material(&job.material)
	destroy_optimizer_control(job.control)
	free(job)
	tab.optimizer_job = nil
	return true
}

destroy_optimizer_job :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil do return
	request_optimizer_cancel(tab)
	thread.destroy(job.worker)
	destroy_optimizer_result(&job.result)
	destroy_optimizer_material(&job.material)
	destroy_optimizer_control(job.control)
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
