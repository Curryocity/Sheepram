package optimizer_test

import "core:testing"
import opt "../../src/optimizer"

@(test)
half_angle_tables_preserve_fractional_yaw_range_endpoints :: proc(t: ^testing.T) {
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for midpoint in ([5]f64{0, 1e-9, -1e-9, 37.12345, -37.12345}) {
			table := opt.half_angle_facing_table(midpoint, version)
			defer {
				opt.destroy_facing_table(table)
				free(table)
			}
			testing.expect(t, len(table.facings) > 0)
			testing.expect_value(t, len(table.facings), len(table.sines))
			testing.expect_value(t, len(table.facings), len(table.cosines))
			for facing, i in table.facings {
				yaw := f32(facing)
				testing.expect(t, f64(yaw) >= midpoint-180 && f64(yaw) < midpoint+180)
				testing.expect_value(t, table.sines[i], opt.sine_table[int(opt.facing_sin_index(yaw, version))])
				testing.expect_value(t, table.cosines[i], opt.sine_table[int(opt.facing_cos_index(yaw, version))])
			}
			if midpoint == 1e-9 && len(table.facings) > 0 {
				testing.expect(t, f32(table.facings[0]) > -180)
				testing.expect_value(t, f32(table.facings[len(table.facings)-1]), f32(180))
			}
		}
	}
}
