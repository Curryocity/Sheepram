package optimizer

import "core:math"

SINE_TABLE_SIZE :: 65536
SINE_TABLE_MASK :: 0xffff
REGULAR_FACING_MIDPOINT_LIMIT :: 1800.0

INDEX_PER_RAD: f32 = 10430.378
RIGHT_ANGLE: f32 = 16384.0

sine_table: [SINE_TABLE_SIZE]f32
facing_table: [SINE_TABLE_SIZE]f64
sin_value_table: [SINE_TABLE_SIZE]f32
cos_value_table: [SINE_TABLE_SIZE]f32
modern_sin_value_table: [SINE_TABLE_SIZE]f32
modern_cos_value_table: [SINE_TABLE_SIZE]f32

Facing_Table :: struct {
	midpoint: f64,
	facings: [SINE_TABLE_SIZE]f64,
	sines: [SINE_TABLE_SIZE]f32,
	cosines: [SINE_TABLE_SIZE]f32,
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

make_facing_table :: proc(midpoint: f64, version: Minecraft_Version) -> ^Facing_Table {
	if midpoint == 0 do return nil
	assert(valid_facing_range(midpoint))
	table := new(Facing_Table)
	table.midpoint = midpoint
	for i in 0..<SINE_TABLE_SIZE {
		facing := compute_index_facing(u16(i), midpoint, version)
		table.facings[i] = facing
		table.sines[i] = sine_table[int(facing_sin_index(f32(facing), version))]
		table.cosines[i] = sine_table[int(facing_cos_index(f32(facing), version))]
	}
	return table
}

nearest_facing_index :: proc(angle: f64, table: ^Facing_Table = nil) -> u16 {
	if table == nil do return index(f32(angle))
	facing := wrap_radians(angle, table.midpoint)*180/math.PI
	best := 0
	distance := math.abs(table.facings[0]-facing)
	for candidate, i in table.facings {
		candidate_distance := math.abs(candidate-facing)
		if candidate_distance < distance {
			best, distance = i, candidate_distance
		}
	}
	return u16(best)
}

@(init)
init_sine_table :: proc "contextless" () {
	for i in 0..<SINE_TABLE_SIZE {
		sine_table[i] = f32(
			math.sin(f64(i) * math.PI *2.0 /f64(SINE_TABLE_SIZE)),
		)
	}
	for i in 0..<SINE_TABLE_SIZE {
		facing := compute_index_facing(u16(i))
		facing_table[i] = facing
		sin_value_table[i] = sin(f32(facing))
		cos_value_table[i] = cos(f32(facing))
		rad := f32(facing)*f32(0.017453292)
		modern_sin_value_table[i] = sine_table[int(rad*INDEX_PER_RAD)&SINE_TABLE_MASK]
		modern_cos_value_table[i] = sine_table[int(rad*INDEX_PER_RAD+RIGHT_ANGLE)&SINE_TABLE_MASK]
	}
}

index :: proc "contextless" (rad: f32) -> u16 {
	index := int(rad * INDEX_PER_RAD)
	return u16(index & SINE_TABLE_MASK)
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

sin_index :: proc "contextless" (index: u16, version := Minecraft_Version.V1_8_9, table: ^Facing_Table = nil) -> f32 {
	if table != nil do return table.sines[int(index)]
	if version == .V1_21_3 do return modern_sin_value_table[int(index)]
	return sin_value_table[int(index)]
}

cos_index :: proc "contextless" (index: u16, version := Minecraft_Version.V1_8_9, table: ^Facing_Table = nil) -> f32 {
	if table != nil do return table.cosines[int(index)]
	if version == .V1_21_3 do return modern_cos_value_table[int(index)]
	return cos_value_table[int(index)]
}

update_discrete_trig_cache :: proc(work: ^Workspace, state: Discrete_State, version := Minecraft_Version.V1_8_9, table: ^Facing_Table = nil) {
	assert(len(work.sin_cache) == len(state.indices))
	assert(len(work.cos_cache) == len(state.indices))
	for index, i in state.indices {
		ut := i
		work.sin_cache[ut] = f64(sin_index(index, version, table))
		work.cos_cache[ut] = f64(cos_index(index, version, table))
	}
}

index_to_radians :: proc "contextless" (index: u16, table: ^Facing_Table = nil) -> f64 {
	return index_to_facing(index, table)*math.PI/180.0
}

index_to_facing :: proc "contextless" (idx: u16, table: ^Facing_Table = nil) -> f64 {
	if table != nil do return table.facings[int(idx)]
	return facing_table[int(idx)]
}

compute_index_facing :: proc "contextless" (idx: u16, midpoint: f64 = 0, version: Minecraft_Version = .V1_8_9) -> f64 {
	step :: 0.005
	center := (f64(idx)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)
	center = wrap_facing(center, midpoint)

	base := int(math.round(center / step))
	fallback := f64(f32(midpoint))
	has_fallback := false
	for radius in 0..=2 {
		for sign in 0..=1 {
			if radius == 0 && sign == 1 do continue
			offset := radius if sign == 0 else -radius
			deg := f64(base+offset) * step
			if deg < midpoint-180 || deg >= midpoint+180 do continue
			if f64(f32(deg)) < midpoint-180 || f64(f32(deg)) >= midpoint+180 do continue
			if !has_fallback {
				fallback, has_fallback = deg, true
			}
			if facing_sin_index(f32(deg), version) == idx do return deg
		}
	}

	return fallback
}
