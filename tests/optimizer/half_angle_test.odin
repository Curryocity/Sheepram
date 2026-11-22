package optimizer_test

import "core:math"
import "core:testing"
import opt "../../src/optimizer"

@(test)
half_angle_midpoints_require_every_trig_index_to_fit_i32 :: proc(t: ^testing.T) {
	valid_midpoints := [?]f64{0, 37.12345, 184275, -184275, 368510.90625, -368510.90625, 1e6, -1e6, 11796200, -11796200}
	invalid_midpoints := [?]f64{11796220, -11796400, 12e6, -12e6, 1e30, math.INF_F64, -math.INF_F64, math.QNAN_F64}
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for midpoint in valid_midpoints do testing.expect(t, opt.valid_half_angle_range(midpoint, version))
		for midpoint in invalid_midpoints do testing.expect(t, !opt.valid_half_angle_range(midpoint, version))
		// Cosine can overflow while the sine index still fits.
		_, upper := opt.half_angle_key_bounds(11796220)
		yaw := opt.key_f32(upper-1)
		rad := yaw*f32(0.017453292) if version == .V1_21_3 else yaw*f32(math.PI)/f32(180)
		testing.expect(t, f64(rad*f32(10430.378)) <= f64(max(i32)))
		testing.expect(t, f64(rad*f32(10430.378)+f32(16384)) > f64(max(i32)))
		for midpoint in ([6]f64{11796200, 11796210.25, 11796220, -11796200, -11796300.25, -11796400}) {
			lower, upper := midpoint-180, midpoint+180
			fits := true
			// Independently inspect every representable yaw in these small ranges.
			for key := opt.f32_key(f32(lower)); ; key += 1 {
				yaw := opt.key_f32(key)
				if f64(yaw) >= upper do break
				if f64(yaw) < lower do continue
				rad := yaw*f32(0.017453292) if version == .V1_21_3 else yaw*f32(math.PI)/f32(180)
				s, c := f64(rad*f32(10430.378)), f64(rad*f32(10430.378)+f32(16384))
				if s < f64(min(i32)) || s > f64(max(i32)) || c < f64(min(i32)) || c > f64(max(i32)) do fits = false
			}
			testing.expect_value(t, opt.valid_half_angle_range(midpoint, version), fits)
		}
	}
}

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
