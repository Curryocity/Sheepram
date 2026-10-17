package app_test

import "base:runtime"
import "core:math"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import app "../../src/app"

@(test)
cooking_completes_ils_iterations_with_fixed_initial_velocity :: proc(t: ^testing.T) {
	tab := app.make_default_tab(503)
	defer app.destroy_tab(tab)
	material := app.make_optimizer_material(&tab.env)
	defer app.destroy_optimizer_material(&material)
	material.discrete_search = true
	material.cook = true
	material.chefs = 3
	result := app.optimize(&material)
	defer app.destroy_optimizer_result(&result)
	testing.expect_value(t, result.error, "")
	testing.expect_value(t, result.chefs_completed, 3)
	testing.expect_value(t, result.chefs_total, 3)
	testing.expect(t, result.discrete && result.cooking && result.solution != nil)
	if result.solution == nil do return
	for constraint in result.solution.constraints do testing.expect(t, app.constraint_result_status(constraint, true) != .Violated)
	vx, vz := result.solution.xs[1], result.solution.zs[1]
	testing.expect(t, math.abs(vx*vx+vz*vz-0.3169516131491288*0.3169516131491288) < 1e-12)
}

cooking_test_worker :: proc(data: rawptr) {
	context.temp_allocator = runtime.default_context().temp_allocator
	defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	app.optimizer_job_worker(data)
}

@(test)
cooking_cancellation_keeps_feasible_standard_baseline :: proc(t: ^testing.T) {
	material := app.Optimizer_Material {
		continuous_optimizer = .Pancake,
		pancake_recovery = .Spine,
		obj_type = .Custom,
		obj_script = "X[n] - X[mm] - 6/16",
		discrete_search = true,
		cook = true,
		chefs = 50,
		seed = 45,
		movement_script = "initGndRange(0,0) [t(mm2) wj.s(12) w.sa t(mm1) sj.wa] [sa.wd(11) s.wd] t(mm) sj.w sa.wa(11) set(m,mm+2) set(m2,mm+11) set(zmm,2.4375-bx)",
		cons_script = "X[mm2]-X[mm1] < 0.125+bx\nZ[m-1]-Z[mm1] < zmm\nZ[m-1]-Z[mm1+1] < zmm\nX[mm]-X[mm1] < 2/16+bx\nX[m]-X[mm] > 7/16\nX[m2]-X[mm] > 7/16\nZ[m2]-Z[m-1] > 2+bx",
		x_origin_script = "X[mm]",
		z_origin_script = "Z[m-1]",
		inertia_tick_lists = {{"mm+6", "mm1+2", ""}, {}},
	}
	control: app.Optimizer_Control
	defer delete(control.progress.angles)
	job := app.Optimizer_Job{material = material, control = &control}
	defer app.destroy_optimizer_result(&job.result)
	worker_context := context
	worker_context.temp_allocator = {}
	worker := thread.create_and_start_with_data(rawptr(&job), cooking_test_worker, init_context = worker_context)
	testing.expect(t, worker != nil)
	if worker == nil do return
	start := time.tick_now()
	saw_baseline := false
	baseline_feasible := false
	baseline_objective := f64(0)
	for !thread.is_done(worker) {
		sync.atomic_mutex_lock(&control.progress.mutex)
		has_best := control.progress.has_best
		if has_best && !saw_baseline {
			saw_baseline = true
			baseline_feasible = control.progress.has_feasible
			baseline_objective = control.progress.best_objective
		}
		completed := control.progress.completed_chefs
		sync.atomic_mutex_unlock(&control.progress.mutex)
		if completed >= 1 || time.duration_seconds(time.tick_since(start)) > 20 {
			sync.atomic_store(&control.cancel_requested, true)
			break
		}
		time.sleep(time.Millisecond)
	}
	thread.destroy(worker)
	testing.expect(t, saw_baseline && baseline_feasible)
	testing.expect_value(t, job.result.error, "")
	testing.expect(t, job.result.tightening_retries > 0)
	testing.expect(t, job.result.chefs_completed >= 1 && job.result.chefs_completed < 50)
	testing.expect_value(t, job.result.chefs_total, 50)
	testing.expect(t, job.result.solution != nil)
	if job.result.solution == nil do return
	testing.expect(t, job.result.solution.optimum <= baseline_objective)
	for constraint in job.result.solution.constraints do testing.expect(t, app.constraint_result_status(constraint, true) != .Violated)
	env := app.Environment{last_solution = job.result.solution, inertia_drag = job.result.inertia_drag}
	for axis in 0..<2 {
		for mode in 0..<3 {
			for tick in job.result.inertia_assignments.ticks[axis][mode] {
				row := app.get_inertia_detector_row(&env, tick, app.Inertia_Axis(axis), job.result.inertia_threshold, 0, 0)
				testing.expect(t, !app.inertia_detector_row_incorrect(row, app.Inertia_Choice(mode+1)))
			}
		}
	}
}
