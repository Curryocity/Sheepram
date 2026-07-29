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
