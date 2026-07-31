package app

import "core:testing"

@(test)
test_optimizer_material_is_independent_and_result_applies :: proc(t: ^testing.T) {
	tab := make_default_tab(1)
	defer destroy_tab(tab)

	material := make_optimizer_material(&tab.env)
	defer destroy_optimizer_material(&material)
	original_script := material.movement_script
	buffer_set(tab.env.movement_script[:], "invalid live edit")
	testing.expect_value(t, material.movement_script, original_script)

	result := optimize(&material)
	defer destroy_optimizer_result(&result)
	testing.expect_value(t, result.error, "")
	testing.expect(t, result.solution != nil)

	apply_optimizer_result(&tab.env, &result)
	testing.expect(t, tab.env.last_solution != nil)
	testing.expect(t, result.solution == nil)
}
