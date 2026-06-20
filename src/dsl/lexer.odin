package dsl

Token_Type :: enum {
	Invalid,
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
	End,
}

Token :: struct {
	type: Token_Type,
	text: string,
}

Lexer :: struct {
	data:       string,
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
	for lexer.pos < len(lexer.data) && is_space(lexer.data[lexer.pos]) {
		lexer.pos += 1
	}
}

lexer_number :: proc(lexer: ^Lexer) -> Token {
	start := lexer.pos
	for lexer.pos < len(lexer.data) && is_digit(lexer.data[lexer.pos]) {
		lexer.pos += 1
	}

	if lexer.pos < len(lexer.data) && lexer.data[lexer.pos] == '.' {
		lexer.pos += 1
		for lexer.pos < len(lexer.data) && is_digit(lexer.data[lexer.pos]) {
			lexer.pos += 1
		}
	}

	// Scientific notation
	if lexer.pos < len(lexer.data) &&
	   (lexer.data[lexer.pos] == 'e' || lexer.data[lexer.pos] == 'E') {
		lexer.pos += 1
		if lexer.pos < len(lexer.data) &&
		   (lexer.data[lexer.pos] == '+' || lexer.data[lexer.pos] == '-') {
			lexer.pos += 1
		}
		if lexer.pos >= len(lexer.data) || !is_digit(lexer.data[lexer.pos]) {
			return Token{type = .Invalid, text = "invalid scientific notation"}
		}
		for lexer.pos < len(lexer.data) && is_digit(lexer.data[lexer.pos]) {
			lexer.pos += 1
		}
	}
	return Token{type = .Number, text = lexer.data[start:lexer.pos]}
}

lexer_identifier :: proc(lexer: ^Lexer) -> Token {
	start := lexer.pos
	for lexer.pos < len(lexer.data) &&
	    (is_alnum(lexer.data[lexer.pos]) || lexer.data[lexer.pos] == '_') {
		lexer.pos += 1
	}
	return Token{type = .Identifier, text = lexer.data[start:lexer.pos]}
}

lexer_update_next :: proc(lexer: ^Lexer) {
	lexer_skip_space(lexer)
	if lexer.pos >= len(lexer.data) {
		lexer.next_cache = Token{type = .End}
		lexer.cache_valid = true
		return
	}

	ch := lexer.data[lexer.pos]
	if is_digit(ch) {
		lexer.next_cache = lexer_number(lexer)
		lexer.cache_valid = true
		return
	}
	if is_alpha(ch) || ch == '_' {
		lexer.next_cache = lexer_identifier(lexer)
		lexer.cache_valid = true
		return
	}
	if ch == '"' {
		lexer.pos += 1
		start := lexer.pos
		for lexer.pos < len(lexer.data) && lexer.data[lexer.pos] != '"' {
			lexer.pos += 1
		}
		if lexer.pos >= len(lexer.data) {
			lexer.next_cache = Token{type = .Invalid, text = "unterminated string"}
			lexer.cache_valid = true
			return
		}
		lexer.next_cache = Token {
			type = .Text,
			text = lexer.data[start:lexer.pos],
		}
		lexer.pos += 1
		lexer.cache_valid = true
		return
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
	case:
		token_type = .Invalid
	}
	lexer.next_cache = Token {
		type = token_type,
		text = lexer.data[lexer.pos-1:lexer.pos],
	}
	lexer.cache_valid = true
}

lexer_next :: proc(lexer: ^Lexer) -> Token {
	if !lexer.cache_valid do lexer_update_next(lexer)
	token := lexer.next_cache
	lexer.cache_valid = false
	return token
}

lexer_peek :: proc(lexer: ^Lexer) -> Token {
	if !lexer.cache_valid do lexer_update_next(lexer)
	return lexer.next_cache
}
