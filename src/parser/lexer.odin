package parser

import "core:fmt"
import "core:strings"

Token_Type :: enum {
	Number,
	Identifier,
	Text,
	Operator,
	Cmp,
	Dot,
	Comma,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	L_Brace,
	R_Brace,
	At,
	Pipe,
	Double_Pipe,
	End,
}

Token :: struct {
	type: Token_Type,
	text: string,
}

Lexer :: struct {
	input:       string,
	pos:         int,
	next_cache:  Token,
	cache_valid: bool,
}

is_space :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' ||
	       ch == '\f' || ch == '\v'
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_alpha :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_alnum :: proc(ch: u8) -> bool {
	return is_alpha(ch) || is_digit(ch)
}

lexer_skip_space :: proc(lexer: ^Lexer) {
	for lexer.pos < len(lexer.input) && is_space(lexer.input[lexer.pos]) {
		lexer.pos += 1
	}
}

lexer_number :: proc(lexer: ^Lexer) -> (Token, string) {
	start := lexer.pos
	for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
		lexer.pos += 1
	}

	if lexer.pos < len(lexer.input) && lexer.input[lexer.pos] == '.' {
		lexer.pos += 1
		for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
			lexer.pos += 1
		}
	}

	// Scientific notation
	if lexer.pos < len(lexer.input) &&
	   (lexer.input[lexer.pos] == 'e' || lexer.input[lexer.pos] == 'E') {
		lexer.pos += 1
		if lexer.pos < len(lexer.input) &&
		   (lexer.input[lexer.pos] == '+' || lexer.input[lexer.pos] == '-') {
			lexer.pos += 1
		}
		if lexer.pos >= len(lexer.input) || !is_digit(lexer.input[lexer.pos]) {
			return {}, strings.clone("Invalid scientific notation")
		}
		for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
			lexer.pos += 1
		}
	}
	return Token{type = .Number, text = lexer.input[start:lexer.pos]}, ""
}

lexer_identifier :: proc(lexer: ^Lexer) -> Token {
	start := lexer.pos
	for lexer.pos < len(lexer.input) &&
	    (is_alnum(lexer.input[lexer.pos]) || lexer.input[lexer.pos] == '_') {
		lexer.pos += 1
	}
	return Token{type = .Identifier, text = lexer.input[start:lexer.pos]}
}

lexer_update_next :: proc(lexer: ^Lexer) -> string {
	lexer_skip_space(lexer)
	if lexer.pos >= len(lexer.input) {
		lexer.next_cache = Token{type = .End}
		lexer.cache_valid = true
		return ""
	}

	ch := lexer.input[lexer.pos]
	if is_digit(ch) {
		token, err := lexer_number(lexer)
		if err != "" do return err
		lexer.next_cache = token
		lexer.cache_valid = true
		return ""
	}
	if is_alpha(ch) || ch == '_' {
		lexer.next_cache = lexer_identifier(lexer)
		lexer.cache_valid = true
		return ""
	}
	if ch == '"' {
		lexer.pos += 1
		start := lexer.pos
		for lexer.pos < len(lexer.input) && lexer.input[lexer.pos] != '"' {
			lexer.pos += 1
		}
		if lexer.pos >= len(lexer.input) {
			return strings.clone("Unterminated string")
		}
		lexer.next_cache = Token {
			type = .Text,
			text = lexer.input[start:lexer.pos],
		}
		lexer.pos += 1
		lexer.cache_valid = true
		return ""
	}
	if ch == '|' {
		if lexer.pos+1 < len(lexer.input) && lexer.input[lexer.pos+1] == '|' {
			lexer.next_cache = Token {
				type = .Double_Pipe,
				text = lexer.input[lexer.pos:lexer.pos+2],
			}
			lexer.pos += 2
		} else {
			lexer.next_cache = Token {
				type = .Pipe,
				text = lexer.input[lexer.pos:lexer.pos+1],
			}
			lexer.pos += 1
		}
		lexer.cache_valid = true
		return ""
	}

	lexer.pos += 1
	token_type: Token_Type
	switch ch {
	case '+', '-', '*', '/':
		token_type = .Operator
	case '<', '=', '>':
		token_type = .Cmp
	case '.':
		token_type = .Dot
	case ',':
		token_type = .Comma
	case '(':
		token_type = .L_Paren
	case ')':
		token_type = .R_Paren
	case '[':
		token_type = .L_Bracket
	case ']':
		token_type = .R_Bracket
	case '{':
		token_type = .L_Brace
	case '}':
		token_type = .R_Brace
	case '@':
		token_type = .At
	case:
		return fmt.aprintf("Invalid Token '%c'", ch)
	}
	lexer.next_cache = Token {
		type = token_type,
		text = lexer.input[lexer.pos-1:lexer.pos],
	}
	lexer.cache_valid = true
	return ""
}

lexer_next :: proc(lexer: ^Lexer) -> (Token, string) {
	if !lexer.cache_valid {
		if err := lexer_update_next(lexer); err != "" do return {}, err
	}
	token := lexer.next_cache
	lexer.cache_valid = false
	return token, ""
}

lexer_peek :: proc(lexer: ^Lexer) -> (Token, string) {
	if !lexer.cache_valid {
		if err := lexer_update_next(lexer); err != "" do return {}, err
	}
	return lexer.next_cache, ""
}
