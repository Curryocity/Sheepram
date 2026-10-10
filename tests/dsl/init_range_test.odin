package dsl_test

import dsl "../../src/dsl"

import "core:math"
import "core:testing"

@(test)
mothball_range_reserves_initial_angles_without_extra_ticks :: proc(t: ^testing.T) {
	scripts := [?]string {
		"initGndRange(0.1, 0.3) w [wa.wd(2) sa.wa] w",
		"initAirRange(0.1, 0.3) w [wa.wd(2) sa.wa] w",
		"w [wa.wd(2) sa.wa] initGndRange(0.1, 0.3) w",
		"set(lo, 0.1) set(hi, 0.3) initGndRange(lo, hi) w [wa.wd(2) sa.wa] w",
	}
	for script, i in scripts {
		code, err := dsl.parse_mothball(script)
		testing.expect_value(t, err, "")
		if err != "" do continue
		compiler: dsl.Moth_Compiler
		dsl.compile_mothball(&compiler, code[:])
		testing.expect(t, compiler.ok)
		testing.expect(t, compiler.init_v_range)
		testing.expect(t, math.abs(compiler.init_v-0.2) < 1e-15)
		testing.expect(t, math.abs(compiler.init_v_extra-0.1) < 1e-15)
		testing.expect_value(t, compiler.n, 6)
		testing.expect_value(t, compiler.unique_facing_counts, 5)
		testing.expect_value(t, len(compiler.exact_movement), 5)
		expected_map := [?]int{0, 2, 3, 3, 3, 4}
		for expected, tick in expected_map do testing.expect_value(t, compiler.facing_map[tick], expected)
		expected_drag := f64(f32(0.91)) if i == 1 else f64(f32(0.91)*f32(0.6))
		testing.expect_value(t, compiler.init_drag, expected_drag)
		testing.expect(t, !compiler.has_init_angle)
		dsl.destroy_moth_compiler(&compiler)
		dsl.destroy_moth_code(&code)
	}
}

@(test)
mothball_range_rejects_invalid_arguments_and_duplicate_initialization :: proc(t: ^testing.T) {
	scripts := [?]string {
		"initGndRange(-0.1, 0.3)",
		"initAirRange(0.3, 0.1)",
		"initGndRange(0.1)",
		"initAirRange(0.1, 0.3, 20)",
		"initGndRange(missing, 0.3)",
		"initAirRange(0, 1e308*2)",
		"initGndRange(1e308*2, 1e308)",
		"initGnd(0.1) initAirRange(0.1, 0.3)",
		"initGndRange(0.1, 0.3) initAir(0.1)",
		"initAirRange(0.1, 0.3) initGndRange(0.1, 0.3)",
		"initGndRange(0.1, 0.3){w}",
	}
	for script in scripts {
		code, err := dsl.parse_mothball(script)
		testing.expect_value(t, err, "")
		if err != "" do continue
		compiler: dsl.Moth_Compiler
		dsl.compile_mothball(&compiler, code[:])
		testing.expect(t, !compiler.ok)
		dsl.destroy_moth_compiler(&compiler)
		dsl.destroy_moth_code(&code)
	}
}

@(test)
mothball_range_handles_equal_zero_and_large_bounds :: proc(t: ^testing.T) {
	scripts := [?]string{"initAirRange(0, 0) w", "initGndRange(0.2, 0.2) w", "initAirRange(1e308, 1e308) w"}
	for script in scripts {
		code, err := dsl.parse_mothball(script)
		testing.expect_value(t, err, "")
		if err != "" do continue
		compiler: dsl.Moth_Compiler
		dsl.compile_mothball(&compiler, code[:])
		testing.expect(t, compiler.ok)
		testing.expect_value(t, compiler.init_v_extra, 0.0)
		testing.expect(t, !math.is_inf(compiler.init_v, 0))
		testing.expect_value(t, compiler.facing_map[1], 2)
		dsl.destroy_moth_compiler(&compiler)
		dsl.destroy_moth_code(&code)
	}
}

@(test)
mothball_fixed_initialization_keeps_one_initial_angle :: proc(t: ^testing.T) {
	code, err := dsl.parse_mothball("initGnd(0.2, 30) w [wa.wd(2) sa.wa] w")
	testing.expect_value(t, err, "")
	defer dsl.destroy_moth_code(&code)
	compiler: dsl.Moth_Compiler
	defer dsl.destroy_moth_compiler(&compiler)
	dsl.compile_mothball(&compiler, code[:])
	testing.expect(t, compiler.ok)
	testing.expect(t, !compiler.init_v_range)
	testing.expect_value(t, compiler.init_angle, 30.0)
	testing.expect_value(t, compiler.unique_facing_counts, 4)
	expected_map := [?]int{0, 1, 2, 2, 2, 3}
	for expected, tick in expected_map do testing.expect_value(t, compiler.facing_map[tick], expected)
}
