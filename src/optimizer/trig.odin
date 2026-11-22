package optimizer

import "core:math"

SINE_TABLE_SIZE :: 65536
SINE_TABLE_MASK :: 0xffff
REGULAR_FACING_MIDPOINT_LIMIT :: 1800.0

INDEX_PER_RAD: f32 = 10430.378
RIGHT_ANGLE: f32 = 16384.0

sine_table: [SINE_TABLE_SIZE]f32

Facing_Table :: struct {
	midpoint: f64,
	half_angle: bool,
	angles_count: int,
	facings: [dynamic]f64,
	sines: [dynamic]f32,
	cosines: [dynamic]f32,
}

destroy_facing_table :: proc(table: ^Facing_Table) {
	if table == nil do return
	delete(table.facings)
	delete(table.sines)
	delete(table.cosines)
	table^ = {}
}

valid_facing_range :: proc(midpoint: f64) -> bool {
	if math.is_nan(midpoint) || math.is_inf(midpoint, 0) || math.abs(midpoint) >= f64(1<<62)/200 do return false
	facing := f64(f32(midpoint))
	return facing >= midpoint-180 && facing < midpoint+180
}

wrap_facing :: proc "contextless" (facing: f64, midpoint: f64 = 0) -> f64 {
	lower := midpoint-180
	if facing >= lower && facing < midpoint+180 do return facing
	wrapped := math.mod(facing-lower, 360)
	if wrapped < 0 do wrapped += 360
	return lower+wrapped
}

wrap_radians :: proc "contextless" (angle: f64, midpoint: f64 = 0) -> f64 {
	lower := (midpoint-180)*math.PI/180
	upper := (midpoint+180)*math.PI/180
	if angle >= lower && angle < upper do return angle
	if angle == upper do return lower
	wrapped := math.mod(angle-lower, 2*math.PI)
	if wrapped < 0 do wrapped += 2*math.PI
	result := lower+wrapped
	return lower if result >= upper else result
}

regular_facing_table :: proc(midpoint: f64, version: Minecraft_Version) -> ^Facing_Table {
	assert(valid_facing_range(midpoint))
	table := new(Facing_Table)
	table.midpoint = midpoint
	table.facings = make([dynamic]f64, SINE_TABLE_SIZE)
	table.sines = make([dynamic]f32, SINE_TABLE_SIZE)
	table.cosines = make([dynamic]f32, SINE_TABLE_SIZE)
	for i in 0..<SINE_TABLE_SIZE {
		facing, ok := compute_index_facing(u16(i), midpoint, version)
		if !ok {
			destroy_facing_table(table)
			free(table)
			return nil
		}
		table.facings[i] = facing
		table.sines[i] = sine_table[int(facing_sin_index(f32(facing), version))]
		table.cosines[i] = sine_table[int(facing_cos_index(f32(facing), version))]
	}
	table.angles_count = SINE_TABLE_SIZE
	return table
}

nearest_facing_index :: proc(angle: f64, table: ^Facing_Table) -> u32 {
	facing := wrap_radians(angle, table.midpoint)*180/math.PI
	best := 0
	distance := math.abs(table.facings[0]-facing)
	for candidate, i in table.facings {
		candidate_distance := math.abs(candidate-facing)
		if candidate_distance < distance {
			best, distance = i, candidate_distance
		}
	}
	return u32(best)
}

@(init)
init_sine_table :: proc "contextless" () {
	for i in 0..<SINE_TABLE_SIZE {
		sine_table[i] = f32(
			math.sin(f64(i) * math.PI *2.0 /f64(SINE_TABLE_SIZE)),
		)
	}
}

index :: proc "contextless" (rad: f32, angle_counts: int) -> u32 {
	index := int(rad * INDEX_PER_RAD)
	if angle_counts != SINE_TABLE_MASK {
		return u32(index %% angle_counts)
	}

	return u32(index & SINE_TABLE_MASK)
}

sin :: proc "contextless" (deg: f32) -> f32 {
	rad := deg * f32(math.PI) / f32(180.0)
	return sine_table[int(rad * INDEX_PER_RAD) & SINE_TABLE_MASK]
}

cos :: proc "contextless" (deg: f32) -> f32 {
	rad := deg * f32(math.PI) / f32(180.0)
	return sine_table[int(rad * INDEX_PER_RAD + RIGHT_ANGLE) & SINE_TABLE_MASK]
}

facing_sin_index :: proc "contextless" (deg: f32, version: Minecraft_Version = .V1_8_9) -> u16 {
	rad := deg*f32(0.017453292) if version == .V1_21_3 else deg*f32(math.PI)/f32(180.0)
	return u16(int(rad * INDEX_PER_RAD) & SINE_TABLE_MASK)
}

facing_cos_index :: proc "contextless" (deg: f32, version: Minecraft_Version = .V1_8_9) -> u16 {
	rad := deg*f32(0.017453292) if version == .V1_21_3 else deg*f32(math.PI)/f32(180.0)
	return u16(int(rad * INDEX_PER_RAD + RIGHT_ANGLE) & SINE_TABLE_MASK)
}

sin_index :: proc "contextless" (index: u32, table: ^Facing_Table) -> f32 {
	return table.sines[int(index)]
}

cos_index :: proc "contextless" (index: u32, table: ^Facing_Table) -> f32 {
	return table.cosines[int(index)]
}

update_discrete_trig_cache :: proc(work: ^Workspace, state: Discrete_State, table: ^Facing_Table) {
	assert(len(work.sin_cache) == len(state.indices))
	assert(len(work.cos_cache) == len(state.indices))
	for index, i in state.indices {
		ut := i
		work.sin_cache[ut] = f64(sin_index(index, table))
		work.cos_cache[ut] = f64(cos_index(index, table))
	}
}

index_to_radians :: proc "contextless" (index: u32, table: ^Facing_Table) -> f64 {
	return index_to_facing(index, table)*math.PI/180.0
}

index_to_facing :: proc "contextless" (idx: u32, table: ^Facing_Table) -> f64 {
	return table.facings[int(idx)]
}

compute_index_facing :: proc "contextless" (idx: u16, midpoint: f64 = 0, version: Minecraft_Version = .V1_8_9) -> (f64, bool) {
	step :: 0.005
	center := (f64(idx)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)
	center = wrap_facing(center, midpoint)

	best := f64(0)
	best_norm_sqr := f64(0)
	found := false

	base := int(math.round(center / step))
	for radius in 0..=2 {
		for sign in 0..=1 {
			if radius == 0 && sign == 1 do continue
			offset := radius if sign == 0 else -radius
			deg := f64(base + offset) * step
			if deg < midpoint - 180 || deg >= midpoint + 180 do continue
			if f64(f32(deg)) < midpoint - 180 || f64(f32(deg)) >= midpoint + 180 do continue
			if facing_sin_index(f32(deg), version) == idx {
				sine := sine_table[int(idx)]
				cosine := sine_table[int(facing_cos_index(f32(deg), version))]
				norm_sqr := f64(sine)*f64(sine) + f64(cosine)*f64(cosine)
				if !found || norm_sqr > best_norm_sqr {
					found = true
					best = deg
					best_norm_sqr = norm_sqr
				}
			}
		}
	}

	return best, found
}
