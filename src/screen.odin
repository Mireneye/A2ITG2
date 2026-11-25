/*
Drawing the screen (layout in main.odin's header) and remembering where the tap targets are.
ZZ-Replace: a functional stand-in UI drawn straight into the window's pixels.
*/
package a2itg2

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

// RGBA in memory: red in the low byte, alpha in the high byte. Navy theme.
COLOR_BACKGROUND :: 0xff_3a_1e_10 // #101e3a
COLOR_ROW_ALT    :: 0xff_50_26_14 // #142650
COLOR_HEADER     :: 0xff_64_32_1c // #1c3264
COLOR_ACTIVE     :: 0xff_8a_4a_2a // #2a4a8a
COLOR_TEXT       :: 0xff_f4_e6_d8 // #d8e6f4
COLOR_DIM        :: 0xff_c0_a0_8a // #8aa0c0
COLOR_WAITING    :: 0xff_b0_6a_2a // #2a6ab0
COLOR_GOOD       :: 0xff_6a_b8_3c // #3cb86a
COLOR_BAD        :: 0xff_3c_44_d0 // #d0443c

text_scale :: proc(app: ^glue.android_app) -> int {
	if app == nil || app.window == nil do return 2
	return max(int(android.ANativeWindow_getWidth(app.window)) / 180, 2)
}

row_height :: proc(app: ^glue.android_app) -> int {
	scale := text_scale(app)
	return CELL_HEIGHT * scale + 6 * scale
}

draw :: proc(app: ^glue.android_app) {
	if app == nil || app.window == nil do return
	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 do return
	defer android.ANativeWindow_unlockAndPost(app.window)

	canvas := Canvas{pixels = ([^]u32)(buffer.bits), width = int(buffer.width), height = int(buffer.height), stride = int(buffer.stride)}
	scale := text_scale(app)
	row := row_height(app)
	columns := canvas.width / (CELL_WIDTH * scale) - 2 * MARGIN_CELLS
	clear(&state.hits)
	fill(canvas, COLOR_BACKGROUND)

	// Fixed sizes from the top: nothing grows or shrinks when the content changes.
	strip_height := canvas.height / 14
	status_top := strip_height + 2 * scale
	status_height := STATUS_ROWS * CELL_HEIGHT * scale
	folder_top := status_top + status_height + 2 * scale
	limit_top := folder_top + row
	pack_top := limit_top + row
	list_top := pack_top + row + scale

	// The song list first, so the rows above cover any part scrolled under them.
	list_height := len(state.songs) * row
	state.scroll = clamp(state.scroll, 0, max(list_height - (canvas.height - list_top), 0))
	for song, i in state.songs {
		top := list_top + i * row - state.scroll
		if top + row <= list_top || top >= canvas.height do continue
		background := u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND)
		if i == state.copying do background = COLOR_ACTIVE
		fill_rect(canvas, 0, top, canvas.width, row, background)

		right := megabytes(song.bytes)
		if i == state.copying {
			right = fmt.tprintf("%d/%d FILES", state.progress.done, state.progress.total)
			if state.progress.step == .Converting do right = "CONVERTING"
		}
		draw_row_text(canvas, strings.to_upper(song.name, context.temp_allocator), right, top, row, scale, columns, COLOR_TEXT)
		visible_top := max(top, list_top)
		append(&state.hits, Hit{top = visible_top, bottom = top + row, target = Song_Tap{index = i}})
	}
	if len(state.songs) == 0 {
		draw_text(canvas, "NO SONGS LISTED YET.", MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}

	fill_rect(canvas, 0, 0, canvas.width, list_top, COLOR_BACKGROUND)
	strip_color := [Screen_Mood]u32{.Waiting = COLOR_WAITING, .Good = COLOR_GOOD, .Bad = COLOR_BAD}
	fill_rect(canvas, 0, 0, canvas.width, strip_height, strip_color[state.mood])
	draw_lines(canvas, state.lines[:], scale, status_top, STATUS_ROWS)

	fill_rect(canvas, 0, folder_top, canvas.width, row - scale, COLOR_HEADER)
	folder_text := fmt.tprintf("STICK: %s", folder_label(state.folder) if state.folder_ok else "NOT PICKED")
	draw_row_text(canvas, folder_text, "CHANGE", folder_top, row - scale, scale, columns, COLOR_TEXT)
	append(&state.hits, Hit{top = folder_top, bottom = folder_top + row, target = Change_Folder{}})

	// The audio limit: "-" and "+" buttons at the right end, each a quarter of the width.
	fill_rect(canvas, 0, limit_top, canvas.width, row - scale, COLOR_HEADER)
	button_width := canvas.width / 4
	minus_left, plus_left := canvas.width - 2 * button_width, canvas.width - button_width
	fill_rect(canvas, minus_left + scale, limit_top + scale, button_width - 2 * scale, row - 3 * scale, COLOR_ACTIVE)
	fill_rect(canvas, plus_left + scale, limit_top + scale, button_width - 2 * scale, row - 3 * scale, COLOR_ACTIVE)
	label_y := limit_top + (row - scale - GLYPH_HEIGHT * scale) / 2
	draw_text(canvas, fmt.tprintf("AUDIO LIMIT: %s", megabytes_decimal(state.audio_limit)), MARGIN_CELLS * CELL_WIDTH * scale, label_y, scale)
	draw_text(canvas, "-", minus_left + (button_width - GLYPH_WIDTH * scale) / 2, label_y, scale)
	draw_text(canvas, "+", plus_left + (button_width - GLYPH_WIDTH * scale) / 2, label_y, scale)
	append(&state.hits, Hit{top = limit_top, bottom = limit_top + row, left = minus_left, right = plus_left, target = Audio_Limit_Down{}})
	append(&state.hits, Hit{top = limit_top, bottom = limit_top + row, left = plus_left, right = canvas.width, target = Audio_Limit_Up{}})

	fill_rect(canvas, 0, pack_top, canvas.width, row - scale, COLOR_HEADER)
	pack_text := fmt.tprintf("PACK #%d: %s", state.pack_id, strings.to_upper(state.pack_name, context.temp_allocator))
	draw_row_text(canvas, pack_text, "RELOAD", pack_top, row - scale, scale, columns, COLOR_TEXT)
	append(&state.hits, Hit{top = pack_top, bottom = pack_top + row, target = Reload_Pack{}})
}

// `left` cut to fit, `right` aligned to the right edge, both centred in the row.
@(private = "file")
draw_row_text :: proc(canvas: Canvas, left, right: string, top, height, scale, columns: int, color: u32) {
	room := columns - len(right) - 1
	shown := left
	if len(shown) > room && room > 2 do shown = fmt.tprintf("%s..", shown[:room - 2])
	y := top + (height - GLYPH_HEIGHT * scale) / 2
	margin := MARGIN_CELLS * CELL_WIDTH * scale
	draw_text(canvas, shown, margin, y, scale, color)
	draw_text(canvas, right, margin + (columns - len(right)) * CELL_WIDTH * scale, y, scale, COLOR_DIM)
}

// A readable name for a picked folder: its path on the stick, from the address's end
// ("content://.../tree/1234-ABCD%3AITG%202%2FSongs" reads "ITG 2/SONGS").
@(private = "file")
folder_label :: proc(address: string) -> string {
	TREE :: "/tree/"
	at := strings.last_index(address, TREE)
	if at < 0 do return "?"
	decoded, ok := net.percent_decode(address[at + len(TREE):], context.temp_allocator)
	if !ok do return "?"
	volume, _, path := strings.partition(decoded, ":")
	if path == "" do return fmt.tprintf("%s (TOP)", volume)
	return strings.to_upper(path, context.temp_allocator)
}
