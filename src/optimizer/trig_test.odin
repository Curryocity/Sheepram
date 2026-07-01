package optimizer

import "core:fmt"
import "core:math"
import "core:testing"

@(test)
index_to_facing_drives_index_trig :: proc(t: ^testing.T) {
	step :: 0.005
	for i in 0..<SINE_TABLE_SIZE {
		idx := u16(i)
		deg := index_to_facing(idx)
		if deg < -180 || deg > 180 {
			fmt.printf(
				"index_to_facing out of range: idx=%d deg=%.12f\n",
				i,
				deg,
			)
			testing.expect(t, false)
			return
		}
		quantized := math.round(deg / step) * step
		if math.abs(deg-quantized) > 1e-9 {
			fmt.printf(
				"index_to_facing not .005 quantized: idx=%d deg=%.12f\n",
				i,
				deg,
			)
			testing.expect(t, false)
			return
		}
		if facing_sin_index(f32(deg)) != idx {
			fmt.printf(
				"index_to_facing failed sin bucket: idx=%d deg=%.12f sin_idx=%d\n",
				i,
				deg,
				facing_sin_index(f32(deg)),
			)
			testing.expect(t, false)
			return
		}
		if sin_index(idx) != sin(f32(deg)) || cos_index(idx) != cos(f32(deg)) {
			fmt.printf(
				"index trig mismatch: idx=%d deg=%.12f\n",
				i,
				deg,
			)
			testing.expect(t, false)
			return
		}
	}
}
