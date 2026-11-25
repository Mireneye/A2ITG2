/*
Drawing the screen (layout in main.odin's header) and remembering where the tap targets are.
Every area has a fixed size from the top: nothing grows or shrinks with its content. List rows are
two lines (a name on top, its details under it), so names get the whole width; header rows keep
their words short or are buttons, so nothing has to be cut. A song's sync foldout adds SYNC_FOLD_LINES
under its row, only while the user has it open. The phone's bars are kept clear: the coloured strip
reaches under the status bar, and nothing is drawn or tappable under the navigation bar. Fixed texts are kept to 26 letters, what
a 1080-pixel-wide screen fits on one line.
ZZ-Replace: a functional stand-in UI drawn straight into the window's pixels.
*/
package a2itg2

import "core:fmt"
import "core:math"
import "core:net"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

// RGBA in memory: red in the low byte, alpha in the high byte. Navy theme.
COLOR_BACKGROUND :: 0xff_3a_1e_10 // #101e3a
COLOR_ROW_ALT    :: 0xff_50_26_14 // #142650
COLOR_HEADER     :: 0xff_64_32_1c // #1c3264
COLOR_ACTIVE     :: 0xff_8a_4a_2a // #2a4a8a
COLOR_HIGHLIGHT  :: 0xff_6a_5a_1e // #1e5a6a, a song picked in the search results
COLOR_KEY        :: 0xff_78_40_24 // #244078
COLOR_TEXT       :: 0xff_f4_e6_d8 // #d8e6f4
COLOR_DIM        :: 0xff_c0_a0_8a // #8aa0c0
COLOR_WAITING    :: 0xff_b0_6a_2a // #2a6ab0
COLOR_GOOD       :: 0xff_6a_b8_3c // #3cb86a
COLOR_BAD        :: 0xff_3c_44_d0 // #d0443c

@(rodata)
SEARCH_BUTTON_LABEL := [Search_Kind]string{
	.Pack_Name    = "PACK",
	.Song_Title   = "TITLE",
	.Artist       = "ARTIST",
	.Chart_Author = "AUTHOR",
}

text_scale :: proc(app: ^glue.android_app) -> int {
	if app == nil || app.window == nil do return 2
	return max(int(android.ANativeWindow_getWidth(app.window)) / 180, 2)
}

// A one-line row (headers, buttons).
row_height :: proc(app: ^glue.android_app) -> int {
	scale := text_scale(app)
	return CELL_HEIGHT * scale + 6 * scale
}

// A two-line list row.
song_row_height :: proc(app: ^glue.android_app) -> int {
	scale := text_scale(app)
	return 2 * CELL_HEIGHT * scale + 6 * scale
}

// What every page shares, and the measurements its rows use.
Layout :: struct {
	canvas:   Canvas,
	scale:    int,
	row:      int, // one-line rows
	list_row: int, // two-line rows
	columns:  int, // text cells across a row
	top:      int, // where the page's own area starts
	bottom:   int, // where it ends: the navigation bar's top
}

SYNC_FOLD_LINES :: 3

@(private = "file") geometry_window: ^android.ANativeWindow // the window the buffer format was set for

draw :: proc(app: ^glue.android_app) {
	if app == nil || app.window == nil do return
	if geometry_window != app.window {
		android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
		geometry_window = app.window
	}
	if !state.bars_known do state.bars, state.bars_known = read_bar_insets(app)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 do return
	defer android.ANativeWindow_unlockAndPost(app.window)

	l: Layout
	l.canvas = Canvas{pixels = ([^]u32)(buffer.bits), width = int(buffer.width), height = int(buffer.height), stride = int(buffer.stride)}
	l.scale = text_scale(app)
	l.row = row_height(app)
	l.list_row = song_row_height(app)
	l.columns = l.canvas.width / (CELL_WIDTH * l.scale) - 2 * MARGIN_CELLS
	l.bottom = l.canvas.height - clamp(state.bars.bottom, 0, l.canvas.height / 4)
	clear(&state.hits)
	fill(l.canvas, COLOR_BACKGROUND)

	strip_height := max(l.canvas.height / 14, state.bars.top + 4 * l.scale)
	status_top := strip_height + 2 * l.scale
	tabs_top := status_top + STATUS_ROWS * CELL_HEIGHT * l.scale + 2 * l.scale
	l.top = tabs_top + l.row

	// The page first: the shared rows above are drawn after, over anything scrolled under them.
	switch state.page {
	case .Packs: draw_packs_page(l)
	case .Songs: draw_songs_page(l)
	case .Sync:  draw_sync_page(l)
	}
	fill_rect(l.canvas, 0, l.bottom, l.canvas.width, l.canvas.height - l.bottom, COLOR_BACKGROUND) // under the navigation bar

	fill_rect(l.canvas, 0, 0, l.canvas.width, l.top, COLOR_BACKGROUND)
	strip_color := [Screen_Mood]u32{.Waiting = COLOR_WAITING, .Good = COLOR_GOOD, .Bad = COLOR_BAD}
	fill_rect(l.canvas, 0, 0, l.canvas.width, strip_height, strip_color[state.mood])
	draw_lines(l.canvas, state.lines[:], l.scale, status_top, STATUS_ROWS)

	tab_labels := [len(Page)]string{"PACKS", "SONGS", "SYNC"}
	draw_buttons(l, tabs_top, tab_labels[:], int(state.page), proc(i: int) -> Tap_Target { return Show_Page{page = Page(i)} })
}

@(private = "file")
draw_packs_page :: proc(l: Layout) {
	canvas, scale := l.canvas, l.scale
	kind_top := l.top
	query_top := kind_top + l.row
	list_top := query_top + l.row + scale

	// The results: for song searches one row per song (its pack above it), else one per pack.
	list_height := len(state.results) * l.list_row
	state.results_scroll = clamp(state.results_scroll, 0, max(list_height - (l.bottom - list_top), 0))
	for result, i in state.results {
		top := list_top + i * l.list_row - state.results_scroll
		if top + l.list_row <= list_top || top >= l.bottom do continue
		fill_rect(canvas, 0, top, canvas.width, l.list_row, u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND))
		name := strings.to_upper(result.name, context.temp_allocator)
		if result.matched != "" {
			// PACK NAME
			// -- SONG TITLE
			draw_two_lines(l, top, name, fmt.tprintf("-- %s", strings.to_upper(result.matched, context.temp_allocator)), COLOR_DIM, COLOR_TEXT)
		} else {
			details := fmt.tprintf("%s  %d SONGS%s", size_text(result.bytes), result.songs, "  SM5" if result.needs_sm5 else "")
			draw_two_lines(l, top, name, details, COLOR_TEXT, COLOR_DIM)
		}
		append(&state.hits, Hit{top = max(top, list_top), bottom = min(top + l.list_row, l.bottom), target = Pack_Tap{index = i}})
	}
	if len(state.results) == 0 {
		draw_text(canvas, "NO PACKS FOUND YET.", MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}
	fill_rect(canvas, 0, kind_top, canvas.width, list_top - kind_top, COLOR_BACKGROUND)

	// What to search by: four buttons, the chosen one lit.
	labels: [len(Search_Kind)]string
	for kind in Search_Kind do labels[int(kind)] = SEARCH_BUTTON_LABEL[kind]
	draw_buttons(l, kind_top, labels[:], int(state.search_kind), proc(i: int) -> Tap_Target { return Pick_Search_Kind{kind = Search_Kind(i)} })

	// The search text: tap to type (Android's keyboard, in a dialog).
	fill_rect(canvas, 0, query_top, canvas.width, l.row - scale, COLOR_KEY)
	typed := strings.to_upper(state.query, context.temp_allocator)
	shown := fmt.tprintf("> %s", typed) if typed != "" else "> TAP HERE TO SEARCH"
	draw_line(l, query_top, l.row - scale, shown, COLOR_TEXT if typed != "" else COLOR_DIM)
	append(&state.hits, Hit{top = query_top, bottom = query_top + l.row, target = Edit_Query{}})
}

@(private = "file")
draw_songs_page :: proc(l: Layout) {
	canvas, row, scale := l.canvas, l.row, l.scale
	folder_top := l.top
	limit_top := folder_top + row
	patch_top := limit_top + row
	metronome_top := patch_top + row
	pack_top := metronome_top + row
	list_top := pack_top + l.list_row + scale

	// The song list first, so the rows above cover any part scrolled under them.
	fold_height := SYNC_FOLD_LINES * CELL_HEIGHT * scale + 3 * scale
	list_height := len(state.songs) * l.list_row
	if state.fold_open >= 0 && state.fold_open < len(state.songs) do list_height += fold_height
	state.scroll = clamp(state.scroll, 0, max(list_height - (l.bottom - list_top), 0))
	row_top := list_top - state.scroll
	for song, i in state.songs {
		top := row_top
		height := l.list_row + (fold_height if i == state.fold_open else 0)
		row_top += height
		if top + height <= list_top || top >= l.bottom do continue
		background := u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND)
		if i == state.highlight do background = COLOR_HIGHLIGHT
		fill_rect(canvas, 0, top, canvas.width, height, background)

		details := fmt.tprintf("%s  %d FILES", megabytes(song.bytes), song.files)
		if i == state.copying {
			// The row fills as the copy goes: by files, and while converting by the encoding's percent.
			status := state.progress.status
			fraction := f32(status.done) / f32(max(status.total, 1))
			details = fmt.tprintf("COPYING: %d OF %d FILES", status.done, status.total)
			if status.step == .Converting || status.step == .Shrinking {
				fraction = f32(status.percent) / 100
				details = fmt.tprintf("%s %d%%", "CONVERTING TO OGG" if status.step == .Converting else "SHRINKING THE OGG", status.percent)
				if status.pass > 1 do details = fmt.tprintf("SMALLER %d%% (TRY %d)", status.percent, status.pass)
			}
			if status.step == .Measuring do details = "CHECKING THE SYNC ..."
			fill_rect(canvas, 0, top, int(f32(canvas.width) * fraction), l.list_row, COLOR_ACTIVE)
		}
		if i == state.preview_song && state.preview_page == .Songs {
			#partial switch state.preview {
			case .Fetching: details = "GETTING THE AUDIO ..."
			case .Playing:  details = fmt.tprintf("PLAYING FROM %s", minutes(state.preview_start))
			case .Paused:   details = "PAUSED"
			}
		}

		button_left := draw_play_button(l, top, list_top, i, .Songs)
		button_columns := (canvas.width - button_left) / (CELL_WIDTH * scale)

		mark := sync_mark(song.sync) if i != state.copying else ""
		mark_width := (len(mark) + 2) * CELL_WIDTH * scale if mark != "" else 0
		name_columns := l.columns + MARGIN_CELLS - button_columns - 1
		draw_two_lines(l, top, strings.to_upper(song.name, context.temp_allocator), details, COLOR_TEXT, COLOR_DIM, name_columns - (len(mark) + 2 if mark != "" else 0), name_columns)
		row_bottom := min(top + l.list_row, l.bottom)
		if mark != "" {
			// The mark at the second line's right end, by the play button; tapping it opens or closes the foldout.
			mark_left := button_left - mark_width - CELL_WIDTH * scale
			mark_y := top + 3 * scale + CELL_HEIGHT * scale
			loud := song.sync.state == .Measured && abs(song.sync.shift_ms) > SYNC_STRONG_MS
			fill_rect(canvas, mark_left, mark_y - scale, mark_width, CELL_HEIGHT * scale, COLOR_BAD if loud else COLOR_KEY)
			draw_text(canvas, mark, mark_left + CELL_WIDTH * scale, mark_y, scale, COLOR_TEXT if loud || song.sync.state == .Measured else COLOR_DIM)
			append(&state.hits, Hit{top = max(top, list_top), bottom = row_bottom, left = mark_left - CELL_WIDTH * scale, right = button_left, target = Sync_Fold{index = i}})
		}
		if i == state.fold_open do draw_sync_fold(l, top + l.list_row, song.sync)
		append(&state.hits, Hit{top = max(top, list_top), bottom = row_bottom, target = Song_Tap{index = i}})
	}
	if len(state.songs) == 0 {
		message := "FIND A PACK ON PACKS." if state.pack_id == 0 else "READING THE PACK ..."
		draw_text(canvas, message, MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}
	fill_rect(canvas, 0, l.top, canvas.width, list_top - l.top, COLOR_BACKGROUND)

	// The stick folder: tap to pick another.
	fill_rect(canvas, 0, folder_top, canvas.width, row - scale, COLOR_HEADER)
	draw_line(l, folder_top, row - scale, fmt.tprintf("STICK: %s", folder_label(state.folder) if state.folder_ok else "TAP TO PICK"), COLOR_TEXT)
	append(&state.hits, Hit{top = folder_top, bottom = folder_top + row, target = Change_Folder{}})

	// The audio limit, with - and + buttons at the right.
	fill_rect(canvas, 0, limit_top, canvas.width, row - scale, COLOR_HEADER)
	button_width := canvas.width / 5
	minus_left, plus_left := canvas.width - 2 * button_width, canvas.width - button_width
	draw_line(l, limit_top, row - scale, fmt.tprintf("MAX AUDIO %s", megabytes_decimal(state.audio_limit)), COLOR_TEXT)
	draw_small_button(l, minus_left, limit_top, button_width, "-", true, Audio_Limit_Down{})
	draw_small_button(l, plus_left, limit_top, button_width, "+", true, Audio_Limit_Up{})

	// The length patch, with an ON/OFF button at the right.
	fill_rect(canvas, 0, patch_top, canvas.width, row - scale, COLOR_HEADER)
	draw_line(l, patch_top, row - scale, "LENGTH PATCH", COLOR_TEXT)
	draw_small_button(l, canvas.width - 2 * button_width, patch_top, 2 * button_width, "ON" if state.length_patch == 1 else "OFF", state.length_patch == 1, Toggle_Length_Patch{})

	// The metronome: its volume with - and +, and ON/OFF.
	fill_rect(canvas, 0, metronome_top, canvas.width, row - scale, COLOR_HEADER)
	draw_line(l, metronome_top, row - scale, fmt.tprintf("CLICKS %d%%", state.click_volume), COLOR_TEXT)
	draw_small_button(l, canvas.width - 3 * button_width, metronome_top, button_width, "-", true, Click_Volume{up = false})
	draw_small_button(l, canvas.width - 2 * button_width, metronome_top, button_width, "+", true, Click_Volume{up = true})
	draw_small_button(l, canvas.width - button_width, metronome_top, button_width, "ON" if state.metronome == 1 else "OFF", state.metronome == 1, Toggle_Clicks{})

	// The open pack: its name in full, and what tapping does.
	fill_rect(canvas, 0, pack_top, canvas.width, l.list_row - scale, COLOR_HEADER)
	if state.pack_id == 0 {
		draw_two_lines(l, pack_top, "NO PACK OPEN", "FIND ONE ON PACKS", COLOR_TEXT, COLOR_DIM)
	} else {
		draw_two_lines(l, pack_top, strings.to_upper(state.pack_name, context.temp_allocator), fmt.tprintf("#%d  TAP TO RELOAD", state.pack_id), COLOR_TEXT, COLOR_DIM)
		append(&state.hits, Hit{top = pack_top, bottom = pack_top + l.list_row, target = Reload_Pack{}})
	}
}

// The SYNC page: the stick's songs; the open one shows its #OFFSET and the controls under it.
@(private = "file")
draw_sync_page :: proc(l: Layout) {
	canvas, row, scale := l.canvas, l.row, l.scale
	header_top := l.top
	list_top := header_top + row + scale
	text_height := CELL_HEIGHT * scale
	panel_height := 3 * text_height + 3 * row + 2 * scale

	list_height := len(state.stick_rows) * l.list_row
	if state.sync_open >= 0 do list_height += panel_height
	state.sync_scroll = clamp(state.sync_scroll, 0, max(list_height - (l.bottom - list_top), 0))
	row_top := list_top - state.sync_scroll
	for &song, i in state.stick_rows {
		top := row_top
		open := i == state.sync_open
		height := l.list_row + (panel_height if open else 0)
		row_top += height
		if top + height <= list_top || top >= l.bottom do continue
		fill_rect(canvas, 0, top, canvas.width, height, u32(COLOR_ROW_ALT) if i % 2 == 1 else u32(COLOR_BACKGROUND))
		if open do fill_rect(canvas, 0, top, canvas.width, l.list_row, COLOR_HIGHLIGHT)

		details: string
		switch {
		case song.opening:   details = "READING THE CHART ..."
		case !song.opened:   details = "TAP TO OPEN"
		case:                details = fmt.tprintf("%s  %s", format_offset(song.wanted), moved_text(&song))
		}
		if i == state.preview_song && state.preview_page == .Sync && state.preview == .Fetching do details = "READING THE SONG ..."
		button_left := draw_play_button(l, top, list_top, i, .Sync)
		columns := l.columns + MARGIN_CELLS - (canvas.width - button_left) / (CELL_WIDTH * scale) - 1
		draw_two_lines(l, top, strings.to_upper(song.song.name, context.temp_allocator), details, COLOR_TEXT, COLOR_DIM, columns, columns)
		append(&state.hits, Hit{top = max(top, list_top), bottom = min(top + l.list_row, l.bottom), target = Stick_Song_Tap{index = i}})
		if open && song.opened do draw_sync_panel(l, top + l.list_row + scale, list_top, &song)
	}
	if len(state.stick_rows) == 0 {
		message := "READING THE STICK ..." if state.stick_listing else "NO SONG FOLDERS HERE." if state.folder_ok else "PICK THE STICK ON SONGS."
		draw_text(canvas, message, MARGIN_CELLS * CELL_WIDTH * scale, list_top + 3 * scale, scale, COLOR_DIM)
	}
	fill_rect(canvas, 0, l.top, canvas.width, list_top - l.top, COLOR_BACKGROUND)

	fill_rect(canvas, 0, header_top, canvas.width, row - scale, COLOR_HEADER)
	draw_line(l, header_top, row - scale, fmt.tprintf("%d SONGS  TAP TO RELOAD", len(state.stick_rows)), COLOR_TEXT)
	append(&state.hits, Hit{top = header_top, bottom = header_top + row, target = Reload_Stick{}})
}

// A song row's play button, a square at its right end; returns its left edge.
@(private = "file")
draw_play_button :: proc(l: Layout, top, list_top, index: int, page: Page) -> (left: int) {
	scale := l.scale
	width := l.list_row
	left = l.canvas.width - width
	this := index == state.preview_song && page == state.preview_page
	playing := this && state.preview == .Playing
	fill_rect(l.canvas, left + 2 * scale, top + 2 * scale, width - 4 * scale, l.list_row - 4 * scale, COLOR_ACTIVE if this else COLOR_KEY)
	symbol := "..." if this && state.preview == .Fetching else string([]u8{GLYPH_PAUSE if playing else GLYPH_PLAY})
	symbol_scale := scale * 2 if len(symbol) == 1 else scale
	draw_text(l.canvas, symbol, left + (width - len(symbol) * CELL_WIDTH * symbol_scale) / 2, top + (l.list_row - GLYPH_HEIGHT * symbol_scale) / 2, symbol_scale, COLOR_TEXT)
	append(&state.hits, Hit{top = max(top, list_top), bottom = min(top + l.list_row, l.bottom), left = left, right = l.canvas.width, target = Preview_Tap{index = index, page = page}})
	return left
}

// "AS ORIGINAL", or how far the notes have moved from the original chart.
@(private = "file")
moved_text :: proc(song: ^Stick_Row) -> string {
	moved_ms := (song.wanted - song.chart.original) * 1000
	if abs(moved_ms) < 0.05 do return "AS ORIGINAL"
	return fmt.tprintf("%.1f MS %s", abs(moved_ms), "EARLIER" if moved_ms > 0 else "LATER")
}

@(private = "file")
draw_sync_panel :: proc(l: Layout, top, list_top: int, song: ^Stick_Row) {
	canvas, row, scale := l.canvas, l.row, l.scale
	text_height := CELL_HEIGHT * scale
	margin := (MARGIN_CELLS + 2) * CELL_WIDTH * scale

	draw_text(canvas, fit(fmt.tprintf("ORIGINAL %s", format_offset(song.chart.original)), l.columns - 2), margin, top, scale, COLOR_DIM)
	measured: string
	color := u32(COLOR_DIM)
	switch {
	case song.measuring:                        measured = "MEASURING ..."
	case song.sync.state == .Unsure:            measured = "MEASURED: UNSURE"
	case song.sync.state == .Measured:
		// What's left of the measured shift after the nudges since.
		left := song.sync.shift_ms + (song.wanted - song.sync.offset) * 1000
		measured = "MEASURED: ON THE MUSIC" if abs(left) < 0.5 else fmt.tprintf("MEASURED: %.1f MS %s", abs(left), "EARLY" if left > 0 else "LATE")
		color = COLOR_TEXT
	case:                                       measured = "NOT MEASURED YET"
	}
	draw_text(canvas, fit(measured, l.columns - 2), margin, top + text_height, scale, color)

	buttons_top := top + 3 * text_height
	step_labels: [len(SYNC_STEPS)]string
	for label, i in SYNC_STEP_LABELS do step_labels[i] = label
	panel_buttons(l, buttons_top, list_top, step_labels[:], state.sync_step, proc(i: int) -> Tap_Target { return Pick_Sync_Step{step = i} })
	nudge_labels := [2]string{"NOTES EARLIER", "NOTES LATER"}
	panel_buttons(l, buttons_top + row, list_top, nudge_labels[:], -1, proc(i: int) -> Tap_Target { return Nudge_Notes{earlier = i == 0} })
	// Short labels: three to a row fit 9 letters. RESET is dim with nothing to undo, CLICKS lit when on.
	tool_labels := [3]string{"MEASURE", "RESET", "CLICKS"}
	panel_buttons(l, buttons_top + 2 * row, list_top, tool_labels[:], 2 if state.metronome == 1 else -1, dim = -1 if song.chart.has_backup else 1, target_of = proc(i: int) -> Tap_Target {
		switch i {
		case 0: return Measure_Stick{}
		case 1: return Reset_Stick{}
		}
		return Toggle_Clicks{}
	})
}

// Buttons inside the scrolling list: tappable only while wholly in view.
@(private = "file")
panel_buttons :: proc(l: Layout, top, list_top: int, labels: []string, chosen: int, target_of: proc(i: int) -> Tap_Target, dim := -1) {
	width := l.canvas.width / len(labels)
	visible := top >= list_top && top + l.row <= l.bottom
	for label, i in labels {
		left := i * width
		lit := i == chosen
		fill_rect(l.canvas, left + 2 * l.scale, top + l.scale, width - 4 * l.scale, l.row - 3 * l.scale, COLOR_ACTIVE if lit else COLOR_KEY)
		label_y := top + (l.row - l.scale - GLYPH_HEIGHT * l.scale) / 2
		draw_text(l.canvas, label, left + (width - len(label) * CELL_WIDTH * l.scale) / 2, label_y, l.scale, COLOR_DIM if i == dim else COLOR_TEXT)
		if visible do append(&state.hits, Hit{top = top, bottom = top + l.row, left = left, right = left + width, target = target_of(i)})
	}
}

// A row of equal buttons across the width; `chosen` is lit.
@(private = "file")
draw_buttons :: proc(l: Layout, top: int, labels: []string, chosen: int, target_of: proc(i: int) -> Tap_Target) {
	width := l.canvas.width / len(labels)
	for label, i in labels {
		left := i * width
		lit := i == chosen
		fill_rect(l.canvas, left + l.scale, top, width - 2 * l.scale, l.row - l.scale, COLOR_ACTIVE if lit else COLOR_HEADER)
		label_y := top + (l.row - l.scale - GLYPH_HEIGHT * l.scale) / 2
		draw_text(l.canvas, label, left + (width - len(label) * CELL_WIDTH * l.scale) / 2, label_y, l.scale, COLOR_TEXT if lit else COLOR_DIM)
		append(&state.hits, Hit{top = top, bottom = top + l.row, left = left, right = left + width, target = target_of(i)})
	}
}

@(private = "file")
draw_small_button :: proc(l: Layout, left, top, width: int, label: string, lit: bool, target: Tap_Target) {
	fill_rect(l.canvas, left + l.scale, top + l.scale, width - 2 * l.scale, l.row - 3 * l.scale, COLOR_ACTIVE if lit else COLOR_KEY)
	label_y := top + (l.row - l.scale - GLYPH_HEIGHT * l.scale) / 2
	draw_text(l.canvas, label, left + (width - len(label) * CELL_WIDTH * l.scale) / 2, label_y, l.scale, COLOR_TEXT if lit else COLOR_DIM)
	append(&state.hits, Hit{top = top, bottom = top + l.row, left = left, right = left + width, target = target})
}

// Two lines of text in a list row, each cut to the width only if it truly doesn't fit (to
// `first_columns` / `second_columns` when something sits at their right).
@(private = "file")
draw_two_lines :: proc(l: Layout, top: int, first, second: string, first_color, second_color: u32, second_columns := -1, first_columns := -1) {
	margin := MARGIN_CELLS * CELL_WIDTH * l.scale
	y := top + 3 * l.scale
	draw_text(l.canvas, fit(first, first_columns if first_columns >= 0 else l.columns), margin, y, l.scale, first_color)
	draw_text(l.canvas, fit(second, second_columns if second_columns >= 0 else l.columns), margin, y + CELL_HEIGHT * l.scale, l.scale, second_color)
}

// "SYNC +9 MS", "SYNC ?", or "" when there's nothing to flag (in sync, or not measured).
@(private = "file")
sync_mark :: proc(sync: Song_Sync) -> string {
	switch sync.state {
	case .Unmeasured: return ""
	case .Unsure:     return "SYNC ?"
	case .Measured:
		if abs(sync.shift_ms) <= SYNC_MILD_MS do return ""
		return fmt.tprintf("SYNC %+d MS", int(math.round(sync.shift_ms)))
	}
	return ""
}

// What was measured, and the #OFFSET that would put the notes on the music. Only shown.
@(private = "file")
draw_sync_fold :: proc(l: Layout, top: int, sync: Song_Sync) {
	lines: [SYNC_FOLD_LINES]string
	if sync.state == .Measured {
		lines = {
			fmt.tprintf("NOTES %.1f MS %s", abs(sync.shift_ms), "EARLY" if sync.shift_ms > 0 else "LATE"),
			fmt.tprintf("NOW  #OFFSET:%.3f;", sync.offset),
			fmt.tprintf("TRY  #OFFSET:%.3f;", sync.suggested),
		}
	} else {
		lines = {"SYNC COULD NOT BE MEASURED", "TOO FEW CLEAR BEATS.", "CHECK IT ON THE CAB."}
	}
	margin := (MARGIN_CELLS + 2) * CELL_WIDTH * l.scale
	for line, i in lines {
		draw_text(l.canvas, fit(line, l.columns - 2), margin, top + i * CELL_HEIGHT * l.scale, l.scale, COLOR_TEXT if i == 2 else COLOR_DIM)
	}
}

// One line, centred in a row of `height`.
@(private = "file")
draw_line :: proc(l: Layout, top, height: int, text: string, color: u32) {
	y := top + (height - GLYPH_HEIGHT * l.scale) / 2
	draw_text(l.canvas, fit(text, l.columns), MARGIN_CELLS * CELL_WIDTH * l.scale, y, l.scale, color)
}

@(private = "file")
fit :: proc(text: string, columns: int) -> string {
	if len(text) <= columns || columns < 3 do return text
	return fmt.tprintf("%s..", text[:columns - 2])
}

// "57.7 MB", "1.1 GB"; "?" when unknown.
@(private = "file")
size_text :: proc(bytes: i64) -> string {
	if bytes < 0 do return "?"
	if bytes >= 1000 * BYTES_PER_MB do return fmt.tprintf("%.1f GB", f64(bytes) / (1000 * BYTES_PER_MB))
	return megabytes(bytes)
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
