package app

import "core:strings"
import "core:testing"

@(test)
test_optimizer_material_is_independent_and_result_applies :: proc(t: ^testing.T) {
	tab := make_default_tab(1)
	defer destroy_tab(tab)
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1][:], "1")

	material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&material)
	original_script := material.movement_script
	buffer_set(tab.env.movement_script[:], "invalid live edit")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1][:], "2")
	testing.expect_value(t, material.movement_script, original_script)
	testing.expect_value(t, material.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1], "1")

	result := optimize(&material)
	defer destroy_optimizer_result(&result)
	testing.expect_value(t, result.error, "")
	testing.expect(t, result.solution != nil)

	apply_optimizer_result(&tab.env, &result)
	testing.expect(t, tab.env.last_solution != nil)
	testing.expect(t, result.solution == nil)
}

@(test)
test_optimizer_reports_conflicting_inertia_assignments :: proc(t: ^testing.T) {
	tab := make_default_tab(2)
	defer destroy_tab(tab)
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1][:], "1")
	buffer_set(tab.env.inertia_tick_lists[int(Inertia_Axis.X)][int(Inertia_Choice.Avoid_Plus)-1][:], "1")

	material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&material)
	result := optimize(&material)
	defer destroy_optimizer_result(&result)
	testing.expect(t, strings.contains(result.error, "Inertia Manager"))
	testing.expect(t, strings.contains(result.error, "assigned to both X Hit and X Avoid+"))
}
