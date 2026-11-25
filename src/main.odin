/*
A2ITG2 - first test: can the app reach the USB stick through Android's folder picker?

Tap the screen to pick a folder. The app keeps access to it (a "persisted" permission) and writes
a small test file into it. Started again later, it writes another file without asking, which proves
access survives a restart.

The screen shows what happened in plain text. Everything is also logged to logcat under "A2ITG2".
*/
package a2itg2

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

LOG_TAG :: "A2ITG2"

// The app's own private folder holds the chosen folder's address between runs.
SAVED_FOLDER_FILE :: "picked_folder.txt"

Screen_Mood :: enum {
	Waiting, // nothing done yet, or the picker is open
	Good,
	Bad,
}

App_State :: struct {
	mood:          Screen_Mood,
	lines:         [dynamic]string, // status text, newest last
	private_dir:   string,          // the app's private files folder
	picker_open:   bool,
	listener_set:  bool,
}

state: App_State

main :: proc() {
	context.logger = log.create_console_logger(ident = LOG_TAG)

	app := glue.app()
	app.onAppCmd     = on_app_cmd
	app.onInputEvent = on_input_event

	state.private_dir = strings.clone_from_cstring(app.activity.internalDataPath)
	say(.Waiting, "A2ITG2 USB TEST")

	listen_for_picker_result(app)
	check_saved_folder()

	for app.destroyRequested == 0 {
		source: ^glue.android_poll_source
		if android.ALooper_pollOnce(-1, nil, nil, (^rawptr)(&source)) >= 0 && source != nil {
			source.process(app, source)
		}
		// The picker's answer arrives on Android's UI thread; it wakes this loop to handle it here.
		if result, ok := take_picker_result(); ok {
			handle_picker_result(result)
		}
	}
}

// On start: if a folder was picked before, check access is still held and write a file without asking.
check_saved_folder :: proc() {
	saved, err := os.read_entire_file(saved_folder_path(), context.allocator)
	if err != nil {
		say(.Waiting, "NO FOLDER PICKED YET.", "TAP THE SCREEN TO PICK THE USB STICK.")
		return
	}
	defer delete(saved)
	address := strings.trim_space(string(saved))

	if !folder_access_kept(address) {
		say(.Bad, "ACCESS TO THE SAVED FOLDER WAS LOST.", "TAP THE SCREEN TO PICK IT AGAIN.")
		return
	}
	say(.Waiting, "REOPENED: ACCESS KEPT WITHOUT ASKING.")
	write_test_file(address, "a2itg2_reopen.txt", "written on restart, without asking again")
}

handle_picker_result :: proc(result: Picker_Result) {
	state.picker_open = false
	if !result.chosen {
		say(.Bad, "PICKER CLOSED WITHOUT A FOLDER.", "TAP TO TRY AGAIN.")
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
	say(.Waiting, "FOLDER PICKED. ACCESS KEPT.")
	write_test_file(result.address, "a2itg2_pick.txt", "written right after picking the folder")
}

write_test_file :: proc(address, name, why: string) {
	text := fmt.tprintf("A2ITG2 test file: %s.\n", why)
	if err := write_file_in_folder(address, name, transmute([]byte)text); err != "" {
		say(.Bad, "WRITE FAILED:", err)
		return
	}
	say(.Good, fmt.tprintf("WROTE %s", name), "CLOSE THE APP AND OPEN IT AGAIN TO TEST A RESTART.")
}

saved_folder_path :: proc() -> string {
	return fmt.tprintf("%s/%s", state.private_dir, SAVED_FOLDER_FILE)
}

// Show a status (and log it). The newest lines stay on screen.
say :: proc(mood: Screen_Mood, lines: ..string) {
	MAX_LINES :: 24
	state.mood = mood
	for line in lines {
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
	if android.AInputEvent_getType(event) != .MOTION {
		return 0 // Back and other keys keep their usual behaviour.
	}
	if android.AMotionEvent_getAction(event).action == .UP && !state.picker_open {
		if err := open_folder_picker(app); err != "" {
			say(.Bad, "COULD NOT OPEN THE PICKER:", err)
		} else {
			state.picker_open = true
			say(.Waiting, "PICKER OPEN: CHOOSE THE USB STICK (OR A FOLDER ON IT).")
		}
	}
	return 1
}

draw :: proc(app: ^glue.android_app) {
	if app == nil || app.window == nil {
		return
	}
	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 {
		return
	}
	defer android.ANativeWindow_unlockAndPost(app.window)

	canvas := Canvas{
		pixels = ([^]u32)(buffer.bits),
		width  = int(buffer.width),
		height = int(buffer.height),
		stride = int(buffer.stride),
	}
	fill(canvas, COLOR_BACKGROUND)

	// A strip along the top says the overall result at a glance.
	strip_color := [Screen_Mood]u32{.Waiting = COLOR_WAITING, .Good = COLOR_GOOD, .Bad = COLOR_BAD}
	fill_rect(canvas, 0, 0, canvas.width, canvas.height / 12, strip_color[state.mood])

	scale := max(canvas.width / 180, 2)
	draw_lines(canvas, state.lines[:], scale, canvas.height / 12 + scale * 8)
}

// RGBA in memory: red in the low byte, alpha in the high byte. Navy theme.
COLOR_BACKGROUND :: 0xff_3a_1e_10 // #101e3a
COLOR_TEXT       :: 0xff_f4_e6_d8 // #d8e6f4
COLOR_WAITING    :: 0xff_b0_6a_2a // #2a6ab0
COLOR_GOOD       :: 0xff_6a_b8_3c // #3cb86a
COLOR_BAD        :: 0xff_3c_44_d0 // #d0443c
