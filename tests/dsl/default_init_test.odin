package dsl_test

import "core:testing"
import "core:fmt"
import dsl "../../src/dsl"

@(test)
omitted_initialization_matches_explicit_zero :: proc(t: ^testing.T) {
	scripts := [?]string{"w(3)", "slip(0.8) [sj.wa sa.wd(2)]", "r(0){initAir(1)} w", "wx w"}
	for script in scripts {
		code, err := dsl.parse_mothball(script)
		testing.expect_value(t, err, "")
		defer dsl.destroy_moth_code(&code)
		explicit_code, explicit_err := dsl.parse_mothball(fmt.tprintf("initGnd(0) %s", script))
		testing.expect_value(t, explicit_err, "")
		defer dsl.destroy_moth_code(&explicit_code)
		implicit, explicit: dsl.Moth_Compiler
		defer dsl.destroy_moth_compiler(&implicit)
		defer dsl.destroy_moth_compiler(&explicit)
		dsl.compile_mothball(&implicit, code[:])
		dsl.compile_mothball(&explicit, explicit_code[:])
		testing.expect(t, implicit.ok && explicit.ok)
		testing.expect(t, !implicit.has_init_v && explicit.has_init_v)
		testing.expect_value(t, implicit.init_v, explicit.init_v)
		testing.expect_value(t, implicit.init_drag, explicit.init_drag)
		testing.expect_value(t, implicit.n, explicit.n)
		for value, i in explicit.drag_x do testing.expect_value(t, implicit.drag_x[i], value)
		for value, i in explicit.drag_z do testing.expect_value(t, implicit.drag_z[i], value)
		for value, i in explicit.accel do testing.expect_value(t, implicit.accel[i], value)
		for value, i in explicit.facing_map do testing.expect_value(t, implicit.facing_map[i], value)
	}
}
