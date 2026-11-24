// F1 controls list: every input action that has keys, drawn at the top-left
// while stats.visible is on. Built in stats_tick into the stats mesh, so it
// shares the stats pass, font and background. Columns split when the window
// cannot hold one row per action.
package engine

import gfx "gfx"
import input "input"

HELP_TITLE :: "Controls (F1 to hide)"
HELP_KEY_COLOR :: [4]f32{1, 0.85, 0.3, 1}
HELP_GAP :: "    " // between keys and description, and between columns

help_panel_draw :: proc(gfx_ctx: ^gfx.Device, system: ^input.System, screen_width, screen_height: f32) {
	entries: [dynamic]input.Action_Info
	entries.allocator = context.temp_allocator
	for action in input.system_actions(system) {
		if action.keys != "" do append(&entries, action)
	}

	line_height := f32(stats.font.line_height)
	gap := gfx.font_text_width(&stats.font, HELP_GAP)
	title_width := gfx.font_text_width(&stats.font, HELP_TITLE)
	// One row is the title; the rest of the window height bounds the rows per column.
	rows := max(1, int((screen_height - 2 * STATS_MARGIN - 2 * STATS_PADDING) / line_height) - 1)
	count := len(entries)
	columns := (count + rows - 1) / rows

	key_widths := make([]f32, columns, context.temp_allocator)
	desc_widths := make([]f32, columns, context.temp_allocator)
	for action, index in entries {
		column := index / rows
		key_widths[column] = max(key_widths[column], gfx.font_text_width(&stats.font, action.keys))
		desc_widths[column] = max(desc_widths[column], gfx.font_text_width(&stats.font, help_description(action)))
	}

	left, top := f32(STATS_MARGIN), f32(STATS_MARGIN)
	inner_left := left + STATS_PADDING
	column_x := make([]f32, columns, context.temp_allocator)
	inner_width: f32
	for column in 0 ..< columns {
		column_x[column] = inner_left + inner_width
		inner_width = column_x[column] - inner_left + key_widths[column] + gap + desc_widths[column] + gap
	}
	inner_width = max(inner_width - gap, title_width) // no trailing gap after the last column

	shown := min(rows, count)
	panel_width := inner_width + 2 * STATS_PADDING
	panel_height := line_height * f32(1 + shown) + 2 * STATS_PADDING
	solid := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	overlay_push_rect(gfx_ctx, &stats.vertices, left, top, left + panel_width, top + panel_height, solid, STATS_BACKGROUND)
	overlay_push_text(gfx_ctx, &stats.vertices, &stats.font, inner_left, top + STATS_PADDING, HELP_TITLE, {1, 1, 1, 1})
	for action, index in entries {
		column, row := index / rows, index % rows
		y := top + STATS_PADDING + line_height * f32(1 + row)
		overlay_push_text(gfx_ctx, &stats.vertices, &stats.font, column_x[column], y, action.keys, HELP_KEY_COLOR)
		overlay_push_text(gfx_ctx, &stats.vertices, &stats.font, column_x[column] + key_widths[column] + gap, y, help_description(action), {1, 1, 1, 1})
	}
}

help_description :: proc(action: input.Action_Info) -> string {
	return action.description if action.description != "" else action.name
}
