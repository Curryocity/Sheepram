package dsl_test

import "core:testing"
import dsl "../../src/dsl"
import opt "../../src/optimizer"

expect_delayed_movement :: proc(t: ^testing.T, script, manual_script: string, auto_delays: bool, version := opt.Minecraft_Version.V1_8_9) {
	code, err := dsl.parse_mothball(script)
	defer dsl.destroy_moth_code(&code)
	defer delete(err)
	manual_code, manual_err := dsl.parse_mothball(manual_script)
	defer dsl.destroy_moth_code(&manual_code)
	defer delete(manual_err)
	testing.expect_value(t, err, "")
	testing.expect_value(t, manual_err, "")
	if err != "" || manual_err != "" do return
	actual, expected: dsl.Moth_Compiler
	actual.auto_delays = auto_delays
	actual.minecraft_version = version
	expected.minecraft_version = version
	defer dsl.destroy_moth_compiler(&actual)
	defer dsl.destroy_moth_compiler(&expected)
	dsl.compile_mothball(&actual, code[:])
	dsl.compile_mothball(&expected, manual_code[:])
	testing.expect(t, actual.ok)
	testing.expect(t, expected.ok)
	testing.expect_value(t, actual.n, expected.n)
	testing.expect_value(t, len(actual.exact_movement), len(expected.exact_movement))
	if len(actual.exact_movement) != len(expected.exact_movement) do return
	for want, i in expected.exact_movement {
		got := actual.exact_movement[i]
		testing.expect_value(t, got.forward, want.forward)
		testing.expect_value(t, got.strafe, want.strafe)
		testing.expect_value(t, got.sprint_jump, want.sprint_jump)
		testing.expect_value(t, got.drag_x, want.drag_x)
		testing.expect_value(t, got.drag_z, want.drag_z)
		testing.expect_value(t, actual.accel[i+1], expected.accel[i+1])
		testing.expect_value(t, actual.angle_offset[i+1], expected.angle_offset[i+1])
	}
}

@(test)
sprint_delay_tracks_start_stop_and_initial_airborne_state :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "initAir(0.3) sa(2) wa(2)", "initAir(0.3) wa sa(2) wa", true)
	expect_delayed_movement(t, "s.wa wa.wd sa.wa wa.wd sa.wa", "s.wa sa.wd wa.wa sa.wd wa.wa", true)
}

@(test)
sprint_delay_crosses_repeat_boundaries_and_ignores_zero_ticks :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "r(2){sa wa}", "wa sa wa sa", true)
	expect_delayed_movement(t, "s sa(0) r(0){wa} set(a, 1) mv(0.91, 0, 0) wa", "s sa", true)
	expect_delayed_movement(t, "s mv(0.91, 0.02) wa", "s mv(0.91, 0.02) wa", true)
}

@(test)
sprint_delay_keeps_ground_acceleration_and_jump_boost_immediate :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "w sj.wd sa.wa", "w sj.wd sa.wa", true)
}

@(test)
automatic_delay_keeps_current_sneak_input_for_1_8_9 :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "sn.w w sn.w", "sn.w w sn.w", true)
}

@(test)
manual_delay_mode_keeps_current_input_behavior :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "sa sn.w sa.wd", "sa sn.w sa.wd", false)
}

@(test)
modern_auto_delay_delays_sneak_without_delaying_sprint :: proc(t: ^testing.T) {
	expect_delayed_movement(t, "sn.w w sn.w", "w sn.w w", true, .V1_21_3)
	expect_delayed_movement(t, "initAir(0.3) sa(2) wa(2)", "initAir(0.3) sa(2) wa(2)", true, .V1_21_3)
	expect_delayed_movement(t, "r(2){sn.w w}", "w sn.w w sn.w", true, .V1_21_3)
}

@(test)
minecraft_version_sets_inertia_defaults_and_keeps_explicit_override :: proc(t: ^testing.T) {
	for version in ([2]opt.Minecraft_Version{.V1_8_9, .V1_21_3}) {
		for overridden in ([2]bool{false, true}) {
			code, err := dsl.parse_mothball("inertia(0.004) w" if overridden else "w")
			testing.expect_value(t, err, "")
			compiler := dsl.Moth_Compiler{minecraft_version = version, auto_delays = true}
			dsl.compile_mothball(&compiler, code[:])
			testing.expect(t, compiler.ok)
			expected := 0.003 if version == .V1_21_3 else 0.005
			if overridden do expected = 0.004
			testing.expect_value(t, compiler.inertia_threshold, expected)
			testing.expect_value(t, compiler.sprint_delay, version == .V1_8_9)
			testing.expect_value(t, compiler.sneak_delay, version == .V1_21_3)
			dsl.destroy_moth_compiler(&compiler)
			dsl.destroy_moth_code(&code)
			delete(err)
		}
	}
}
