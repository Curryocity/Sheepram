package dsl

import "core:math"
import "core:testing"

@(test)
math_test :: proc(t: ^testing.T) {
	testing.expect_value(t, 1 + 1, 2)
}

@(test)
lexer_skips_line_comments :: proc(t: ^testing.T) {
	lexer := Lexer{data = "// leading comment\nX[n] // trailing comment\n- X[0]"}
	expected_types := [?]Token_Type {
		.Identifier,
		.L_Bracket,
		.Identifier,
		.R_Bracket,
		.Operator,
		.Identifier,
		.L_Bracket,
		.Number,
		.R_Bracket,
		.End,
	}
	expected_text := [?]string{"X", "[", "n", "]", "-", "X", "[", "0", "]", ""}

	for i in 0..<len(expected_types) {
		token := lexer_next(&lexer)
		testing.expect_value(t, token.type, expected_types[i])
		testing.expect_value(t, token.text, expected_text[i])
	}
}

@(test)
lexer_preserves_division_operator :: proc(t: ^testing.T) {
	lexer := Lexer{data = "1 / 2"}
	testing.expect_value(t, lexer_next(&lexer).type, Token_Type.Number)
	operator := lexer_next(&lexer)
	testing.expect_value(t, operator.type, Token_Type.Operator)
	testing.expect_value(t, operator.text, "/")
	testing.expect_value(t, lexer_next(&lexer).type, Token_Type.Number)
	testing.expect_value(t, lexer_next(&lexer).type, Token_Type.End)
}

@(test)
mothball_inertia_defaults_to_point_zero_zero_five :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	testing.expect_value(t, compiler.inertia_threshold, 0.005)
}

@(test)
mothball_inertia_can_be_set_once :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) inertia(0.0125)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	testing.expect_value(t, compiler.inertia_threshold, 0.0125)
}

@(test)
mothball_inertia_rejects_a_second_call :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball(
		"initGnd(0.3) inertia(0.01) repeat(2) { inertia(0.02) }",
	)
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, !compiler.ok)
	testing.expect_value(t, compiler.err, "Error: inertia(...) can only be called once")
	testing.expect_value(t, compiler.inertia_threshold, 0.01)
}

@(test)
mothball_tracks_nominal_inertia_drag :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) w w")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	testing.expect(t, compiler.inertia_drag[0] > 0)
	testing.expect(t, compiler.inertia_drag[1] > 0)
	testing.expect(t, compiler.inertia_drag[2] > 0)
}

@(test)
mothball_builtin_movement_uses_minecraft_rounded_coefficients :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) s.w sa.wa")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	for tick in 1..=2 {
		movement := compiler.exact_movement[tick-1]
		forward := f64(movement.forward)
		strafe := f64(movement.strafe)
		if movement.sprint_jump do forward += f64(f32(0.2))
		testing.expect_value(t, compiler.drag_x[tick], movement.drag_x)
		testing.expect_value(t, compiler.drag_z[tick], movement.drag_z)
		testing.expect_value(t, compiler.accel[tick], math.sqrt(forward*forward+strafe*strafe))
		testing.expect_value(t, compiler.angle_offset[tick], math.atan2(-strafe, forward)*180/math.PI)
	}
}

@(test)
mothball_jump_durations_match_explicit_air_ticks :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"initGnd(0.3) sj(4)", "initGnd(0.3) sj sa(3)"},
		{"initGnd(0.3) wj.wd(4)", "initGnd(0.3) wj.wd wa.wd(3)"},
		{"initGnd(0.3) snj.s(3)", "initGnd(0.3) snj.s sna.s(2)"},
	}
	for scripts in cases {
		compact_code, compact_parse_err := parse_mothball(scripts[0])
		expanded_code, expanded_parse_err := parse_mothball(scripts[1])
		testing.expect_value(t, compact_parse_err, "")
		testing.expect_value(t, expanded_parse_err, "")
		if compact_parse_err != "" || expanded_parse_err != "" {
			destroy_moth_code(&compact_code)
			destroy_moth_code(&expanded_code)
			continue
		}

		compact, expanded: Moth_Compiler
		compile_mothball(&compact, compact_code[:])
		compile_mothball(&expanded, expanded_code[:])
		testing.expect(t, compact.ok)
		testing.expect(t, expanded.ok)
		testing.expect_value(t, compact.n, expanded.n)
		for tick in 0..<len(compact.drag_x) {
			testing.expect_value(t, compact.drag_x[tick], expanded.drag_x[tick])
			testing.expect_value(t, compact.drag_z[tick], expanded.drag_z[tick])
			testing.expect_value(t, compact.accel[tick], expanded.accel[tick])
			testing.expect_value(t, compact.angle_offset[tick], expanded.angle_offset[tick])
			testing.expect_value(t, compact.inertia_drag[tick], expanded.inertia_drag[tick])
		}
		for tick in 0..<len(compact.jump_ticks) {
			testing.expect_value(t, compact.jump_ticks[tick], expanded.jump_ticks[tick])
		}
		for tick in 0..<len(compact.exact_movement) {
			compact_movement := compact.exact_movement[tick]
			expanded_movement := expanded.exact_movement[tick]
			testing.expect_value(t, compact_movement.drag_x, expanded_movement.drag_x)
			testing.expect_value(t, compact_movement.drag_z, expanded_movement.drag_z)
			testing.expect_value(t, compact_movement.forward, expanded_movement.forward)
			testing.expect_value(t, compact_movement.strafe, expanded_movement.strafe)
			testing.expect_value(t, compact_movement.sprint_jump, expanded_movement.sprint_jump)
		}

		destroy_moth_compiler(&compact)
		destroy_moth_compiler(&expanded)
		destroy_moth_code(&compact_code)
		destroy_moth_code(&expanded_code)
	}
}

@(test)
mothball_wall_hits_zero_drag_before_the_next_movement :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) wx w wz w")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	expected_initial_drag := f64(f32(0.91)*f32(0.6))
	testing.expect_value(t, compiler.drag_x[0], 0.0)
	testing.expect_value(t, compiler.drag_z[0], expected_initial_drag)
	testing.expect_value(t, compiler.init_drag, expected_initial_drag)
	testing.expect(t, compiler.drag_x[1] > 0)
	testing.expect_value(t, compiler.drag_z[1], 0.0)
	testing.expect(t, compiler.exact_movement[0].drag_x > 0)
	testing.expect_value(t, compiler.exact_movement[0].drag_z, 0.0)
	testing.expect(t, compiler.drag_x[2] > 0)
	testing.expect(t, compiler.drag_z[2] > 0)
}

@(test)
mothball_wall_hit_counts_apply_to_jump_duration_ticks :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) wx(2) wz(2) sj(3)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	for tick in 0..=1 {
		testing.expect_value(t, compiler.drag_x[tick], 0.0)
		testing.expect_value(t, compiler.drag_z[tick], 0.0)
	}
	testing.expect(t, compiler.drag_x[2] > 0)
	testing.expect(t, compiler.drag_z[2] > 0)
	testing.expect_value(t, compiler.exact_movement[0].drag_x, 0.0)
	testing.expect_value(t, compiler.exact_movement[0].drag_z, 0.0)
	testing.expect(t, compiler.exact_movement[1].drag_x > 0)
	testing.expect(t, compiler.exact_movement[1].drag_z > 0)
}

@(test)
mothball_wall_hits_apply_to_custom_movements :: proc(t: ^testing.T) {
	code, parse_err := parse_mothball("initGnd(0.3) wx set(d, 0.8) wz mv(d, 0.1)")
	defer destroy_moth_code(&code)
	testing.expect_value(t, parse_err, "")
	if parse_err != "" do return

	compiler := Moth_Compiler{}
	defer destroy_moth_compiler(&compiler)
	compile_mothball(&compiler, code[:])

	testing.expect(t, compiler.ok)
	testing.expect_value(t, compiler.drag_x[0], 0.0)
	testing.expect_value(t, compiler.drag_z[0], 0.0)
	testing.expect(t, compiler.drag_x[1] > 0)
	testing.expect(t, compiler.drag_z[1] > 0)
	testing.expect_value(t, compiler.inertia_drag[1], 0.8)
}
