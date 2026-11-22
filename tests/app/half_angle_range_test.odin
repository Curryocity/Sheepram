package app_test

import "core:math"
import "core:strings"
import "core:testing"
import app "../../src/app"

@(test)
half_angle_search_accepts_large_ranges_and_rejects_index_overflow :: proc(t: ^testing.T) {
	for version in ([2]app.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for midpoint in ([2]f64{184275, -184275}) {
			for cooking in ([2]bool{false, true}) {
				material := app.Optimizer_Material{
					minecraft_version = version, discrete_search = true, half_angle = true,
					cook = cooking, chefs = 2, facing_range_midpoint = midpoint, seed = midpoint,
					movement_script = "initAir(0) wa(2)", x_origin_script = "0", z_origin_script = "0",
				}
				result := app.optimize(&material)
				defer app.destroy_optimizer_result(&result)
				testing.expect_value(t, result.error, "")
				testing.expect(t, result.solution != nil)
				testing.expect(t, result.discrete)
				if result.solution != nil {
					testing.expect(t, app.solution_is_finite(result.solution))
					for yaw in result.solution.thetas do testing.expect(t, yaw >= midpoint-180 && yaw < midpoint+180)
				}
			}
		}
		for midpoint in ([4]f64{11796220, -11796400, math.INF_F64, math.QNAN_F64}) {
			material := app.Optimizer_Material{minecraft_version = version, discrete_search = true, half_angle = true, facing_range_midpoint = midpoint}
			result := app.optimize(&material)
			defer app.destroy_optimizer_result(&result)
			testing.expect(t, result.solution == nil)
			testing.expect(t, strings.contains(result.error, "32-bit trig index range"))
		}
	}
}

@(test)
rotated_half_angle_copies_validate_the_entire_shifted_range :: proc(t: ^testing.T) {
	source := app.make_default_tab(710)
	defer app.destroy_tab(source)
	source.env.discrete_search = true
	source.env.half_angle_search = true
	for version in ([2]app.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		source.env.minecraft_version = version
		source.env.facing_range_midpoint = 184275
		source.env.seed = 184275
		copy, err := app.prepare_duplicate_tab(source, "Large rotated copy", 90, 711)
		testing.expect_value(t, err, "")
		delete(err)
		if copy != nil {
			testing.expect_value(t, copy.env.facing_range_midpoint, 184365)
			testing.expect_value(t, copy.env.seed, 184365)
			app.destroy_tab(copy)
		}
		source.env.facing_range_midpoint = 11796100
		rejected, range_err := app.prepare_duplicate_tab(source, "Overflowing copy", 180, 711)
		testing.expect(t, rejected == nil)
		testing.expect(t, strings.contains(range_err, "32-bit trig index range"))
		delete(range_err)
		if rejected != nil do app.destroy_tab(rejected)
		testing.expect_value(t, source.env.facing_range_midpoint, 11796100)
	}
}
