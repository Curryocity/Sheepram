package dsl

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
