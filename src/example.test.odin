package main

import "core:testing"

@(test)
add_positive_integers :: proc(t: ^testing.T) {
	testing.expect(t, add(1, 2) == 3, "1 + 2 should equal 3")
}

@(test)
add_is_commutative :: proc(t: ^testing.T) {
	testing.expect_value(t, add(2, 3), add(3, 2))
}
