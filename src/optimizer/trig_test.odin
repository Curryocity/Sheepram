package optimizer

import "core:fmt"
import "core:testing"

@(test)
index_to_facing_round_trips_buckets :: proc(t: ^testing.T) {
	for i in 0..<SINE_TABLE_SIZE {
		idx := u16(i)
		deg := index_to_facing(idx)
		if !same_trig_bucketQ(f32(deg), idx) {
			fmt.printf(
				"index_to_facing failed: idx=%d deg=%.12f\n",
				i,
				deg,
			)
			testing.expect(t, false)
			return
		}
	}
}
