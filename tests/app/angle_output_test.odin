package app_test

import "core:strconv"
import "core:strings"
import "core:testing"
import app "../../src/app"
import opt "../../src/optimizer"

@(test)
copied_half_angle_yaws_preserve_f32_yaws_and_trig_values :: proc(t: ^testing.T) {
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		table := opt.half_angle_facing_table(0, version)
		defer {
			opt.destroy_facing_table(table)
			free(table)
		}
		// The formatter excludes the terminal yaw.
		facings := make([]f64, len(table.facings)+1)
		defer delete(facings)
		copy(facings, table.facings[:])
		text := app.format_angle_list(facings, false, ",", true)
		defer delete(text)
		parts := strings.split(text, ",")
		defer delete(parts)
		testing.expect_value(t, len(parts), len(table.facings))
		for part, i in parts {
			value, ok := strconv.parse_f64(part)
			testing.expect(t, ok)
			testing.expect_value(t, f32(value), f32(table.facings[i]))
			yaw, yaw_ok := strconv.parse_f32(part)
			testing.expect(t, yaw_ok)
			testing.expect_value(t, yaw, f32(table.facings[i]))
			testing.expect_value(t, table.sines[i], opt.sine_table[int(opt.facing_sin_index(yaw, version))])
			testing.expect_value(t, table.cosines[i], opt.sine_table[int(opt.facing_cos_index(yaw, version))])
		}
	}
}

@(test)
copied_yaws_and_turns_preserve_f32_precision_for_each_separator :: proc(t: ^testing.T) {
	facings := [?]f64{12.345678901, 180.000000001, -0.00000000012345, 0}
	for separator in ([3]string{",", " ", "\n"}) {
		for turns in ([2]bool{false, true}) {
			text := app.format_angle_list(facings[:], turns, separator, true)
			defer delete(text)
			parts := strings.split(text, separator)
			defer delete(parts)
			testing.expect_value(t, len(parts), 2 if turns else 3)
			for part, i in parts {
				value, ok := strconv.parse_f32(part)
				testing.expect(t, ok)
				testing.expect_value(t, value, f32(facings[i+1]-facings[i] if turns else facings[i]))
				testing.expect(t, !strings.has_prefix(part, "+"))
			}
		}
	}
	noisy_facings := [?]f64{0, 8.079999999999998, 12.929999999999993, 0}
	clean_turns := app.format_angle_list(noisy_facings[:], true, ",", true)
	defer delete(clean_turns)
	testing.expect_value(t, clean_turns, "8.08,4.85")
}
