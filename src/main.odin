/*
A2ITG2: copy songs from StepMania packs onto an ITG2 cabinet's USB stick.

The screen, top to bottom (screen.odin draws it):
	a strip whose colour says how the last step went (blue busy, green done, red failed)
	the last status lines
	PACKS | SONGS tabs

	PACKS page: find a pack on the site
	SEARCH BY row  pack name, song title, artist or chart author; tap to cycle
	the search text
	the packs found (the newest packs when nothing is typed); tap one to open it on the SONGS page
	a keyboard: pack names are searched as you type, the others on SEARCH

	SONGS page: copy songs from the open pack
	STICK row   the folder songs are copied into; tap to pick another
	AUDIO row   the most an Ogg may take (MP3s are converted to fit); tap - or + to change it
	PATCH row   whether Oggs over 1:45 are length patched to read as 1:45; tap to switch
	PACK row    the open pack; tap to read it again
	the pack's songs; tap one to copy it into the stick folder (videos are left out)

Everything slow runs on the worker thread (worker.odin); this loop only draws and handles touches.
Everything is also logged to logcat under "A2ITG2".
*/
package a2itg2

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

LOG_TAG :: "A2ITG2"

// The app's own private folder holds the picked folder's address and the settings between runs.
SAVED_FOLDER_FILE :: "picked_folder.txt"
SETTINGS_FILE     :: "settings.txt"

// The audio limit, in bytes (decimal MB on screen). Players report the stock cabinet takes audio
// under 5 MB, so the default stays a little under. ZZ-Attention: confirm on the cabinet.
DEFAULT_AUDIO_LIMIT :: 4_800_000
AUDIO_LIMIT_STEP    :: 100_000
AUDIO_LIMIT_MIN     :: 1_000_000
AUDIO_LIMIT_MAX     :: 20_000_000


STATUS_ROWS :: 4 // the status area keeps its size; older lines scroll off

Screen_Mood :: enum {
	Waiting,
	Good,
	Bad,
}

Page :: enum u8 {
	Packs,
	Songs,
}

Tap_Target :: union {
	Show_Page,
	Cycle_Search_Kind,
	Key,
	Pack_Tap,
	Change_Folder,
	Audio_Limit_Down,
	Audio_Limit_Up,
	Toggle_Length_Patch,
	Reload_Pack,
	Song_Tap,
}
Show_Page         :: struct { page: Page }
Cycle_Search_Kind :: struct {}
Pack_Tap          :: struct { index: int }
// A keyboard key: a character, or one of the special keys.
Key :: struct { char: u8, special: Special_Key }
Special_Key :: enum u8 { None, Delete, Search }
Change_Folder    :: struct {}
Audio_Limit_Down :: struct {}
Audio_Limit_Up   :: struct {}
Toggle_Length_Patch :: struct {}
Reload_Pack      :: struct {}
Song_Tap         :: struct { index: int }

// A tap target's area. left/right 0/0 means the whole width.
Hit :: struct {
	top, bottom: int,
	left, right: int,
	target:      Tap_Target,
}

App_State :: struct {
	mood:          Screen_Mood,
	lines:         [dynamic]string, // status text, newest last

	private_dir:   string,
	folder:        string, // the picked folder's address ("" until picked)
	folder_ok:     bool,
	audio_limit:   int, // bytes
	length_patch:  int, // 1 on, 0 off (an int so it sits in the settings table like the rest)
	picker_open:   bool,
	listener_set:  bool,

	page:          Page,
	search_kind:   Search_Kind,
	query:         [dynamic]u8, // upper-case letters, digits and spaces
	results:       []Pack_Row,
	results_scroll: int,
	search_stamp:  int, // the latest search sent; older answers are dropped

	pack_id:       int, // 0: none opened yet
	pack_name:     string,
	songs:         []Song_Row,
	copying:       int, // the song being copied, or -1
	progress:      Copy_Progress,

	scroll:        int, // pixels the song list is scrolled down (results_scroll for the pack list)
	hits:          [dynamic]Hit,
	touch_x:       f32,
	touch_start_y: f32,
	touch_last_y:  f32,
	dragging:      bool,
}

state: App_State

main :: proc() {
	context.logger = log.create_console_logger(ident = LOG_TAG)

	app := glue.app()
	app.onAppCmd     = on_app_cmd
	app.onInputEvent = on_input_event

	state.private_dir = strings.clone_from_cstring(app.activity.internalDataPath)
	state.copying = -1
	load_settings()

	listen_for_picker_result(app)
	worker_start()
	check_saved_folder()
	worker_ask(Load_Catalog{private_dir = strings.clone(state.private_dir)})
	search_now()
	if state.pack_id > 0 {
		state.page = .Songs
		worker_ask(Open_Pack{id = state.pack_id})
	}

	for app.destroyRequested == 0 {
		source: ^glue.android_poll_source
		if android.ALooper_pollOnce(-1, nil, nil, (^rawptr)(&source)) >= 0 && source != nil {
			source.process(app, source)
		}
		// The picker answers on Android's UI thread and the worker on its own; both wake this loop.
		if result, ok := take_picker_result(); ok {
			handle_picker_result(result)
		}
		handle_worker_messages()
		free_all(context.temp_allocator)
	}
}

check_saved_folder :: proc() {
	saved, err := os.read_entire_file(saved_folder_path(), context.allocator)
	if err != nil {
		say(.Waiting, "NO STICK FOLDER PICKED YET.", "TAP THE STICK ROW TO PICK WHERE SONGS GO (E.G. THE CABINET'S SONGS FOLDER).")
		return
	}
	defer delete(saved)
	address := strings.trim_space(string(saved))
	if !folder_access_kept(address) {
		say(.Bad, "ACCESS TO THE STICK FOLDER WAS LOST.", "TAP THE STICK ROW TO PICK IT AGAIN.")
		return
	}
	set_folder(address)
}

handle_picker_result :: proc(result: Picker_Result) {
	state.picker_open = false
	if !result.chosen {
		say(.Bad, "PICKER CLOSED WITHOUT A FOLDER.")
		return
	}
	defer delete(result.address)
	if err := keep_folder_access(result.address); err != "" {
		say(.Bad, "COULD NOT KEEP ACCESS:", err)
		return
	}
	if err := os.write_entire_file(saved_folder_path(), transmute([]byte)result.address); err != nil {
		say(.Bad, "COULD NOT SAVE THE FOLDER ADDRESS.")
		return
	}
	set_folder(result.address)
	say(.Good, "STICK FOLDER SET.", "TAP A SONG TO COPY IT THERE.")
}

set_folder :: proc(address: string) {
	delete(state.folder)
	state.folder = strings.clone(address)
	state.folder_ok = true
	draw(glue.app())
}

handle_worker_messages :: proc() {
	messages := take_messages(context.temp_allocator)
	if len(messages) == 0 do return
	for message in messages {
		switch m in message {
		case Say:
			say(m.mood, m.lines[0], m.lines[1])
			delete(m.lines[0])
			delete(m.lines[1])
		case Pack_Ready:
			free_song_rows()
			state.pack_id, state.pack_name, state.songs = m.id, m.name, m.rows
			state.scroll = 0
		case Copy_Progress:
			state.progress = m
			state.copying = -1 if m.finished else m.song
		case Search_Results:
			if m.stamp != state.search_stamp {
				free_pack_rows(m.rows) // an answer to an older search
				continue
			}
			free_pack_rows(state.results)
			state.results, state.results_scroll = m.rows, 0
		}
	}
	draw(glue.app())
}

on_tap :: proc(app: ^glue.android_app, x, y: int) {
	for hit in state.hits {
		if y < hit.top || y >= hit.bottom do continue
		if hit.right > 0 && (x < hit.left || x >= hit.right) do continue
		switch target in hit.target {
		case Show_Page:
			state.page = target.page
		case Cycle_Search_Kind:
			state.search_kind = Search_Kind((int(state.search_kind) + 1) % len(Search_Kind))
			if state.search_kind == .Pack_Name do search_now()
		case Key:
			type_key(target)
		case Pack_Tap:
			if state.copying >= 0 {
				say(.Waiting, "WAIT FOR THE COPY TO FINISH BEFORE OPENING ANOTHER PACK.")
				return
			}
			row := state.results[target.index]
			state.pack_id = row.id
			save_settings()
			free_song_rows()
			state.pack_name = strings.clone(row.name)
			state.page = .Songs
			worker_ask(Open_Pack{id = row.id})
		case Audio_Limit_Down:
			set_audio_limit(state.audio_limit - AUDIO_LIMIT_STEP)
		case Audio_Limit_Up:
			set_audio_limit(state.audio_limit + AUDIO_LIMIT_STEP)
		case Toggle_Length_Patch:
			state.length_patch = 1 - state.length_patch
			save_settings()
		case Change_Folder:
			if state.picker_open do return
			if err := open_folder_picker(app); err != "" {
				say(.Bad, "COULD NOT OPEN THE PICKER:", err)
				return
			}
			state.picker_open = true
			say(.Waiting, "PICKER OPEN: CHOOSE THE FOLDER ON THE STICK WHERE SONGS GO.")
		case Reload_Pack:
			if state.copying >= 0 do return
			worker_ask(Open_Pack{id = state.pack_id})
		case Song_Tap:
			switch {
			case !state.folder_ok:
				say(.Bad, "PICK THE STICK FOLDER FIRST (THE STICK ROW).")
			case state.copying >= 0:
				say(.Waiting, "ONE SONG AT A TIME: WAIT FOR THIS COPY TO FINISH.")
			case:
				state.copying = target.index
				state.progress = {song = target.index}
				options := Copy_Options{audio_limit = state.audio_limit, length_patch = state.length_patch == 1}
				worker_ask(Copy_Song{index = target.index, tree = strings.clone(state.folder), options = options})
			}
		}
		draw(app)
		return
	}
}

// Pack names are searched as you type; the other searches ask the site, so they wait for SEARCH.
type_key :: proc(key: Key) {
	MAX_QUERY :: 40
	switch key.special {
	case .None:
		if len(state.query) < MAX_QUERY do append(&state.query, key.char)
		if state.search_kind == .Pack_Name do search_now()
	case .Delete:
		if len(state.query) > 0 do pop(&state.query)
		if state.search_kind == .Pack_Name do search_now()
	case .Search:
		search_now()
	}
}

search_now :: proc() {
	state.search_stamp += 1
	worker_ask(Search_Packs{kind = state.search_kind, query = strings.clone(string(state.query[:])), stamp = state.search_stamp})
}

free_pack_rows :: proc(rows: []Pack_Row) {
	for row in rows {
		delete(row.name)
		delete(row.matched)
	}
	delete(rows)
}

free_song_rows :: proc() {
	for row in state.songs do delete(row.name)
	delete(state.songs)
	delete(state.pack_name)
	state.songs, state.pack_name = nil, ""
}

set_audio_limit :: proc(bytes: int) {
	state.audio_limit = clamp(bytes, AUDIO_LIMIT_MIN, AUDIO_LIMIT_MAX)
	save_settings()
}

// The saved settings: one entry each. Saved in settings.txt as "key=value" lines.
Setting :: struct {
	key:      string,
	value:    ^int,
	default:  int,
	min, max: int,
}

settings_table :: proc() -> [3]Setting {
	return {
		{key = "audio_limit_bytes", value = &state.audio_limit,  default = DEFAULT_AUDIO_LIMIT, min = AUDIO_LIMIT_MIN, max = AUDIO_LIMIT_MAX},
		{key = "length_patch",      value = &state.length_patch, default = 1,                   min = 0,               max = 1},
		{key = "pack_id",           value = &state.pack_id,      default = 0,                   min = 0,               max = max(int)},
	}
}

load_settings :: proc() {
	table := settings_table()
	for setting in table do setting.value^ = setting.default
	text, err := os.read_entire_file(fmt.tprintf("%s/%s", state.private_dir, SETTINGS_FILE), context.temp_allocator)
	if err != nil do return
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		key, _, value := strings.partition(strings.trim_space(line), "=")
		for setting in table {
			if setting.key != key do continue
			if number, ok := strconv.parse_int(value); ok do setting.value^ = clamp(number, setting.min, setting.max)
		}
	}
}

save_settings :: proc() {
	text := strings.builder_make(context.temp_allocator)
	for setting in settings_table() do fmt.sbprintf(&text, "%s=%d\n", setting.key, setting.value^)
	if err := os.write_entire_file(fmt.tprintf("%s/%s", state.private_dir, SETTINGS_FILE), text.buf[:]); err != nil {
		say(.Bad, "COULD NOT SAVE THE SETTINGS.")
	}
}

saved_folder_path :: proc() -> string {
	return fmt.tprintf("%s/%s", state.private_dir, SAVED_FOLDER_FILE)
}

// Show a status (and log it). The newest lines stay on screen.
say :: proc(mood: Screen_Mood, lines: ..string) {
	MAX_LINES :: 16
	state.mood = mood
	for line in lines {
		if line == "" do continue
		log.info(line)
		if len(state.lines) == MAX_LINES {
			delete(state.lines[0])
			ordered_remove(&state.lines, 0)
		}
		append(&state.lines, strings.to_upper(line))
	}
	draw(glue.app())
}

on_app_cmd :: proc(app: ^glue.android_app, cmd: i32) {
	switch cmd {
	case glue.APP_CMD_INIT_WINDOW, glue.APP_CMD_WINDOW_RESIZED, glue.APP_CMD_WINDOW_REDRAW_NEEDED:
		draw(app)
	case glue.APP_CMD_ACTIVITY_CHANGED:
		// A new activity object replaced the old one, so the listener has to be added again.
		state.listener_set = false
		listen_for_picker_result(app)
	}
}

on_input_event :: proc(app: ^glue.android_app, event: ^android.AInputEvent) -> i32 {
	if android.AInputEvent_getType(event) != .MOTION || app.window == nil {
		return 0 // Back and other keys keep their usual behaviour.
	}
	y := android.AMotionEvent_getY(event, 0)
	drag_threshold := f32(row_height(app)) / 3

	#partial switch android.AMotionEvent_getAction(event).action {
	case .DOWN:
		state.touch_x = android.AMotionEvent_getX(event, 0)
		state.touch_start_y, state.touch_last_y, state.dragging = y, y, false
	case .MOVE:
		if abs(y - state.touch_start_y) > drag_threshold do state.dragging = true
		if state.dragging {
			list_scroll := &state.scroll if state.page == .Songs else &state.results_scroll
			list_scroll^ -= int(y - state.touch_last_y)
			state.touch_last_y = y
			draw(app)
		}
	case .UP:
		if !state.dragging do on_tap(app, int(state.touch_x), int(y))
	}
	return 1
}
