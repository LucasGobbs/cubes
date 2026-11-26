package city

import "core:math"
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

// uv must be world / city size on every corner, or the street texture lands transposed or scaled wrong.
@(test)
test_ground_uv_is_world_over_size :: proc(t: ^testing.T) {
	b := ground_build_mesh()
	defer builder_destroy(&b)
	testing.expect_value(t, len(b.vertices), 4)
	for v in b.vertices {
		testing.expect(t, math.abs(v.uv.x * f32(CITY_W) - v.position.x) < 1e-2, "uv.x not world x / CITY_W")
		testing.expect(t, math.abs(v.uv.y * f32(CITY_D) - v.position.z) < 1e-2, "uv.y not world z / CITY_D")
	}
}
