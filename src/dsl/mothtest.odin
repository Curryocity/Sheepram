package dsl

import "core:testing"

@(test)
math_test :: proc(t: ^testing.T) {
	testing.expect_value(t, 1 + 1, 2)
}
