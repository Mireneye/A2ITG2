/*
A2ITG2: copy songs from StepMania packs onto an ITG2 cabinet's USB stick.

The screen, top to bottom:
	a strip whose colour says how the last step went (blue busy, green done, red failed)
	the last status lines
	STICK row   the folder songs are copied into; tap to pick another
	AUDIO row   the most an Ogg may take (MP3s are converted to fit); tap - or + to change it
	PACK row    the pack being browsed; tap to read it again
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

// ZZ-Replace: a fixed pack to browse until picking packs is built (OPS Anime Mix 2, 57.7 MB).
DEFAULT_PACK_ID :: 10850

STATUS_ROWS :: 4 // the status area keeps its size; older lines scroll off

Screen_Mood :: enum {
	Waiting,
	Good,
	Bad,
}

Tap_Target :: union {
	Change_Folder,
	Audio_Limit_Down,
	Audio_Limit_Up,
	Reload_Pack,
	Song_Tap,
}
Change_Folder    :: struct {}
Audio_Limit_Down :: struct {}
Audio_Limit_Up   :: struct {}
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
	picker_open:   bool,
	listener_set:  bool,

	pack_id:       int,
	pack_name:     string,
	songs:         []Song_Row,
	copying:       int, // the song being copied, or -1
	progress:      Copy_Progress,

	scroll:        int, // pixels the song list is scrolled down
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
	state.pack_id = DEFAULT_PACK_ID
	state.copying = -1
	load_settings()

	listen_for_picker_result(app)
	worker_start()
	check_saved_folder()
	worker_ask(Open_Pack{id = state.pack_id})

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
			for row in state.songs do delete(row.name)
			delete(state.songs)
			delete(state.pack_name)
			state.pack_id, state.pack_name, state.songs = m.id, m.name, m.rows
			state.scroll = 0
		case Copy_Progress:
			state.progress = m
			state.copying = -1 if m.finished else m.song
		}
	}
	draw(glue.app())
}

on_tap :: proc(app: ^glue.android_app, x, y: int) {
	for hit in state.hits {
		if y < hit.top || y >= hit.bottom do continue
		if hit.right > 0 && (x < hit.left || x >= hit.right) do continue
		switch target in hit.target {
		case Audio_Limit_Down:
			set_audio_limit(state.audio_limit - AUDIO_LIMIT_STEP)
		case Audio_Limit_Up:
			set_audio_limit(state.audio_limit + AUDIO_LIMIT_STEP)
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
				worker_ask(Copy_Song{index = target.index, tree = strings.clone(state.folder), audio_limit = state.audio_limit})
			}
		}
		draw(app)
		return
	}
}

set_audio_limit :: proc(bytes: int) {
	state.audio_limit = clamp(bytes, AUDIO_LIMIT_MIN, AUDIO_LIMIT_MAX)
	save_settings()
}

// settings.txt: one "name=value" per line.
load_settings :: proc() {
	state.audio_limit = DEFAULT_AUDIO_LIMIT
	text, err := os.read_entire_file(fmt.tprintf("%s/%s", state.private_dir, SETTINGS_FILE), context.temp_allocator)
	if err != nil do return
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		name, _, value := strings.partition(strings.trim_space(line), "=")
		if name == "audio_limit_bytes" {
			if bytes, ok := strconv.parse_int(value); ok do state.audio_limit = clamp(bytes, AUDIO_LIMIT_MIN, AUDIO_LIMIT_MAX)
		}
	}
}

save_settings :: proc() {
	text := fmt.tprintf("audio_limit_bytes=%d\n", state.audio_limit)
	if err := os.write_entire_file(fmt.tprintf("%s/%s", state.private_dir, SETTINGS_FILE), transmute([]u8)text); err != nil {
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
			state.scroll -= int(y - state.touch_last_y)
			state.touch_last_y = y
			draw(app)
		}
	case .UP:
		if !state.dragging do on_tap(app, int(state.touch_x), int(y))
	}
	return 1
}
