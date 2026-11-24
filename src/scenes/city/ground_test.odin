package city

import "core:testing"

@(test)
test_ground_pack_roads :: proc(t: ^testing.T) {
	claimed := make([]u8, CITY_CELLS)
	defer delete(claimed)
	for i in 0 ..< len(claimed) do claimed[i] = u8((i * 7) % 3) // 0 free, 1 road, 2 building: all three appear
	packed := ground_pack_roads(claimed)
	defer delete(packed)
	testing.expect_value(t, len(packed), GROUND_MASK_WORDS)
	for c, i in claimed {
		bit := (packed[i >> 5] >> u32(i & 31)) & 1
		testing.expect_value(t, bit == 1, c == CLAIM_ROAD)
	}
}
