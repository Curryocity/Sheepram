package app

import "core:strings"
import "core:testing"

@(test)
test_optimizer_material_is_independent_and_result_applies :: proc(t: ^testing.T) {
	tab := make_default_tab(1)
	defer destroy_tab(tab)
	axis := int(Inertia_Axis.X)
	mode := int(Inertia_Choice.Hit)-1
	buffer_set(tab.env.inertia_tick_lists[axis][mode][:], "1")
	tab.env.inertia_tick_list_visible[axis][mode] = true

	material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&material)
	original_script := material.movement_script
	buffer_set(tab.env.movement_script[:], "invalid live edit")
	buffer_set(tab.env.inertia_tick_lists[axis][mode][:], "2")
	testing.expect_value(t, material.movement_script, original_script)
	testing.expect_value(t, material.inertia_tick_lists[axis][mode], "1")

	result := optimize(&material)
	defer destroy_optimizer_result(&result)
	testing.expect_value(t, result.error, "")
	testing.expect(t, result.solution != nil)
	if result.solution != nil {
		testing.expect(t, result.solution.pancake_used)
	}

	apply_optimizer_result(&tab.env, &result)
	testing.expect(t, tab.env.last_solution != nil)
	testing.expect(t, result.solution == nil)
}

@(test)
test_hidden_inertia_list_is_not_sent_to_optimizer :: proc(t: ^testing.T) {
	tab := make_default_tab(2)
	defer destroy_tab(tab)
	axis := int(Inertia_Axis.X)
	mode := int(Inertia_Choice.Hit)-1
	buffer_set(tab.env.inertia_tick_lists[axis][mode][:], "1, 3")

	hidden_material := make_optimizer_material(&tab.env)
	testing.expect_value(t, hidden_material.inertia_tick_lists[axis][mode], "")
	testing.expect_value(t, buffer_string(tab.env.inertia_tick_lists[axis][mode][:]), "1, 3")
	destroy_optimizer_material(&hidden_material)

	tab.env.inertia_tick_list_visible[axis][mode] = true
	visible_material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&visible_material)
	testing.expect_value(t, visible_material.inertia_tick_lists[axis][mode], "1, 3")
}

@(test)
test_optimizer_reports_conflicting_inertia_assignments :: proc(t: ^testing.T) {
	tab := make_default_tab(3)
	defer destroy_tab(tab)
	axis := int(Inertia_Axis.X)
	hit := int(Inertia_Choice.Hit)-1
	avoid_plus := int(Inertia_Choice.Avoid_Plus)-1
	buffer_set(tab.env.inertia_tick_lists[axis][hit][:], "1")
	buffer_set(tab.env.inertia_tick_lists[axis][avoid_plus][:], "1")
	tab.env.inertia_tick_list_visible[axis][hit] = true
	tab.env.inertia_tick_list_visible[axis][avoid_plus] = true

	material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&material)
	result := optimize(&material)
	defer destroy_optimizer_result(&result)
	testing.expect(t, strings.contains(result.error, "Inertia Manager"))
	testing.expect(t, strings.contains(result.error, "assigned to both X Hit and X Avoid+"))
}
