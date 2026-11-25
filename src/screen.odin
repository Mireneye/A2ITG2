/*
Drawing the screen (layout in main.odin's header) and remembering where the tap targets are.
Every area has a fixed size from the top or the bottom: nothing grows or shrinks with its content.
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
COLOR_KEY        :: 0xff_78_40_24 // #244078
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

// What every page shares, and the measurements its rows use.
Layout :: struct {
	canvas:  Canvas,
	scale:   int,
	row:     int,
	columns: int, // text cells across a row
	top:     int, // where the page's own area starts
}

draw :: proc(app: ^glue.android_app) {
	if app == nil || app.window == nil do return
	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 do return
	defer android.ANativeWindow_unlockAndPost(app.window)

	l: Layout
	l.canvas = Canvas{pixels = ([^]u32)(buffer.bits), width = int(buffer.width), height = int(buffer.height), stride = int(buffer.stride)}
	l.scale = text_scale(app)
	l.row = row_height(app)
	l.columns = l.canvas.width / (CELL_WIDTH * l.scale) - 2 * MARGIN_CELLS
	clear(&state.hits)
	fill(l.canvas, COLOR_BACKGROUND)

	strip_height := l.canvas.height / 14
	status_top := strip_height + 2 * l.scale
	tabs_top := status_top + STATUS_ROWS * CELL_HEIGHT * l.scale + 2 * l.scale
	l.top = tabs_top + l.row

	// The page first: the shared rows above are drawn after, over anything scrolled under them.
	switch state.page {
	case .Packs: draw_packs_page(l)
	case .Songs: draw_songs_page(l)
	}

	fill_rect(l.canvas, 0, 0, l.canvas.width, l.top, COLOR_BACKGROUND)
	strip_color := [Screen_Mood]u32{.Waiting = COLOR_WAITING, .Good = COLOR_GOOD, .Bad = COLOR_BAD}
	fill_rect(l.canvas, 0, 0, l.canvas.width, strip_height, strip_color[state.mood])
	draw_lines(l.canvas, state.lines[:], l.scale, status_top, STATUS_ROWS)

	half := l.canvas.width / 2
	for page, i in ([2]Page{.Packs, .Songs}) {
		left := i * half
		active := state.page == page
		fill_rect(l.canvas, left + l.scale, tabs_top, half - 2 * l.scale, l.row - l.scale, COLOR_ACTIVE if active else COLOR_HEADER)
		label := "PACKS" if page == .Packs else "SONGS"
		label_y := tabs_top + (l.row - l.scale - GLYPH_HEIGHT * l.scale) / 2
		draw_text(l.canvas, label, left + (half - len(label) * CELL_WIDTH * l.scale) / 2, label_y, l.scale, COLOR_TEXT if active else COLOR_DIM)
		append(&state.hits, Hit{top = tabs_top, bottom = tabs_top + l.row, left = left, right = left + half, target = Show_Page{page = page}})
	}
}

@(private = "file")
draw_packs_page :: proc(l: Layout) {
	canvas, row, scale := l.canvas, l.row, l.scale
	kind_top := l.top
	query_top := kind_top + row
	list_top := query_top + row + scale

	list_bottom := canvas.height

	// The packs found.
	list_height := len(state.results) * row
	state.results_scroll = clamp(state.results_scroll, 0, max(list_height - (list_bottom - list_top), 0))
	for result, i in state.results {
		top := list_top + i * row - state.results_scroll
		if top + row <= list_top || top >= list_bottom do continue
		fill_rect(canvas, 0, top, canvas.width, row, u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND))
		name := strings.to_upper(result.name, context.temp_allocator)
		if result.matched != "" do name = fmt.tprintf("%s - %s", name, strings.to_upper(result.matched, context.temp_allocator))
		right := size_text(result.bytes)
		if result.needs_sm5 do right = fmt.tprintf("SM5 %s", right)
		draw_row_text(canvas, name, right, top, row, scale, l.columns, COLOR_TEXT)
		append(&state.hits, Hit{top = max(top, list_top), bottom = min(top + row, list_bottom), target = Pack_Tap{index = i}})
	}
	if len(state.results) == 0 {
		draw_text(canvas, "NO PACKS FOUND YET.", MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}
	fill_rect(canvas, 0, kind_top, canvas.width, list_top - kind_top, COLOR_BACKGROUND)

	// SEARCH BY and the search text.
	fill_rect(canvas, 0, kind_top, canvas.width, row - scale, COLOR_HEADER)
	draw_row_text(canvas, fmt.tprintf("SEARCH BY: %s", SEARCH_KIND_LABEL[state.search_kind]), "CHANGE", kind_top, row - scale, scale, l.columns, COLOR_TEXT)
	append(&state.hits, Hit{top = kind_top, bottom = kind_top + row, target = Cycle_Search_Kind{}})
	// The search text: tap to type (Android's keyboard, in a dialog).
	fill_rect(canvas, 0, query_top, canvas.width, row - scale, COLOR_KEY)
	typed := strings.to_upper(state.query, context.temp_allocator)
	shown := typed if typed != "" else "NEWEST PACKS"
	draw_row_text(canvas, fmt.tprintf("> %s", shown), "TAP TO TYPE", query_top, row - scale, scale, l.columns, COLOR_TEXT if typed != "" else COLOR_DIM)
	append(&state.hits, Hit{top = query_top, bottom = query_top + row, target = Edit_Query{}})
}

@(private = "file")
draw_songs_page :: proc(l: Layout) {
	canvas, row, scale := l.canvas, l.row, l.scale
	folder_top := l.top
	limit_top := folder_top + row
	patch_top := limit_top + row
	pack_top := patch_top + row
	list_top := pack_top + row + scale

	// The song list first, so the rows above cover any part scrolled under them.
	list_height := len(state.songs) * row
	state.scroll = clamp(state.scroll, 0, max(list_height - (canvas.height - list_top), 0))
	for song, i in state.songs {
		top := list_top + i * row - state.scroll
		if top + row <= list_top || top >= canvas.height do continue
		fill_rect(canvas, 0, top, canvas.width, row, u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND))

		right := megabytes(song.bytes)
		if i == state.copying {
			// The row fills as the copy goes: by files, and while converting by the encoding's percent.
			status := state.progress.status
			fraction := f32(status.done) / f32(max(status.total, 1))
			right = fmt.tprintf("%d/%d FILES", status.done, status.total)
			if status.step == .Converting || status.step == .Shrinking {
				fraction = f32(status.percent) / 100
				right = fmt.tprintf("%s %d%%", "CONVERTING" if status.step == .Converting else "SHRINKING", status.percent)
				if status.pass > 1 do right = fmt.tprintf("SMALLER %d%% (TRY %d)", status.percent, status.pass)
			}
			fill_rect(canvas, 0, top, int(f32(canvas.width) * fraction), row, COLOR_ACTIVE)
		}
		draw_row_text(canvas, strings.to_upper(song.name, context.temp_allocator), right, top, row, scale, l.columns, COLOR_TEXT)
		append(&state.hits, Hit{top = max(top, list_top), bottom = top + row, target = Song_Tap{index = i}})
	}
	if len(state.songs) == 0 {
		message := "PICK A PACK ON THE PACKS PAGE." if state.pack_id == 0 else "READING THE PACK ..."
		draw_text(canvas, message, MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}
	fill_rect(canvas, 0, l.top, canvas.width, list_top - l.top, COLOR_BACKGROUND)

	fill_rect(canvas, 0, folder_top, canvas.width, row - scale, COLOR_HEADER)
	folder_text := fmt.tprintf("STICK: %s", folder_label(state.folder) if state.folder_ok else "NOT PICKED")
	draw_row_text(canvas, folder_text, "CHANGE", folder_top, row - scale, scale, l.columns, COLOR_TEXT)
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

	fill_rect(canvas, 0, patch_top, canvas.width, row - scale, COLOR_HEADER)
	patch_text := "LENGTH PATCH: ON (OVER 1:45)" if state.length_patch == 1 else "LENGTH PATCH: OFF"
	draw_row_text(canvas, patch_text, "SWITCH", patch_top, row - scale, scale, l.columns, COLOR_TEXT)
	append(&state.hits, Hit{top = patch_top, bottom = patch_top + row, target = Toggle_Length_Patch{}})

	fill_rect(canvas, 0, pack_top, canvas.width, row - scale, COLOR_HEADER)
	pack_text := "PACK: NONE OPEN" if state.pack_id == 0 else fmt.tprintf("PACK #%d: %s", state.pack_id, strings.to_upper(state.pack_name, context.temp_allocator))
	draw_row_text(canvas, pack_text, "RELOAD", pack_top, row - scale, scale, l.columns, COLOR_TEXT)
	append(&state.hits, Hit{top = pack_top, bottom = pack_top + row, target = Reload_Pack{}})
}

// "57.7 MB", "1.1 GB"; "?" when unknown.
@(private = "file")
size_text :: proc(bytes: i64) -> string {
	if bytes < 0 do return "?"
	if bytes >= 1000 * BYTES_PER_MB do return fmt.tprintf("%.1f GB", f64(bytes) / (1000 * BYTES_PER_MB))
	return megabytes(bytes)
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
