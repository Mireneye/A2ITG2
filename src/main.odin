/*
A2ITG2: copy songs from StepMania packs onto an ITG2 cabinet's USB stick.

The screen, top to bottom (screen.odin draws it):
	a strip whose colour says how the last step went (blue busy, green done, red failed)
	the last status lines
	PACKS | SONGS tabs

	PACKS page: find a pack on the site
	SEARCH BY row  pack name, song title, artist or chart author; tap to cycle
	the search text: tap it to type, with Android's keyboard (text_input.odin); pack names are
	               searched as you type, the others on Search
	the packs found (the newest packs when nothing is typed); tap one to open it on the SONGS page

	SONGS page: copy songs from the open pack
	STICK row   the folder songs are copied into; tap to pick another
	AUDIO row   the most an Ogg may take (MP3s are converted to fit); tap - or + to change it
	PATCH row   whether Oggs over 1:45 are length patched to read as 1:45; tap to switch
	PACK row    the open pack; tap to read it again
	the pack's songs; tap one to copy it into the stick folder (videos are left out). Songs already on
	the stick say ON STICK; copying one again asks first, then replaces it. The button at a
	song's right plays it from its preview point (#SAMPLESTART), and pauses it; its audio is kept in
	the app, so copying it afterwards doesn't download it again. A copied song
	whose notes sit off its music carries a sync mark at the right (SYNC +9 MS, or SYNC ? when it
	couldn't be measured); tap the mark to fold out what was measured and the #OFFSET that would fit.
	Nothing is changed: the sync is the user's to set (on SYNC).

	SYNC page: change the sync of songs already on the stick (stick.odin)
	STICK row   how many song folders the stick folder has and the space left; tap to read it again
	CLICKS row  the metronome while a song plays here: how loud (- and +, heard at once), and
	            OFF / BEATS (the chart's beats) / NOTES (every note: hears the chart's own timing,
	            even when its BPM is wrong)
	the stick's songs; the button at the right plays one from the stick (with the metronome, if on,
	following the nudges as they're made); tap a song to open it:
	            its #OFFSET now and the original, and how far the notes moved
	            STEP     0.1 / 1 / 10 / 100 ms
	            NOTES EARLIER / NOTES LATER   move the notes by a step (written to the stick at once)
	            MEASURE  how its notes sit on its music; RESET  the original chart back;
	            DELETE   the song off the stick, after Android's own "are you sure" dialog
	            Before a chart is first changed, the original is kept in the app (stick.odin).

The screen keeps clear of the phone's status and navigation bars (insets.odin).
Everything slow runs on the worker thread (worker.odin); this loop only draws and handles touches.
Touches and messages only ask for a redraw; the loop draws once after taking everything waiting, so
a fast finger never queues up frames behind it.
Everything is also logged to logcat under "A2ITG2".
*/
package a2itg2

import "core:fmt"
import "core:log"
import "core:math"
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

// Sync marks: within SYNC_MILD_MS no mark (all four cab-perfect test songs are); up to SYNC_STRONG_MS
// a quiet mark (often the ~9 ms some charters add); past it a loud one.
// The metronome's loudness, in percent of its default (src/metronome: CLICK_LOUDNESS).
CLICK_VOLUME_STEP :: 10
CLICK_VOLUME_MIN  :: 10
CLICK_VOLUME_MAX  :: 200

SYNC_MILD_MS   :: 6.0
SYNC_STRONG_MS :: 15.0

Screen_Mood :: enum {
	Waiting,
	Good,
	Bad,
}

Page :: enum u8 {
	Packs,
	Songs,
	Sync,
}

// The SYNC page's steps, in seconds of #OFFSET.
@(rodata)
SYNC_STEPS := [4]f64{0.0001, 0.001, 0.01, 0.1}
@(rodata)
SYNC_STEP_LABELS := [4]string{"0.1 MS", "1 MS", "10 MS", "100 MS"}

Tap_Target :: union {
	Show_Page,
	Pick_Search_Kind,
	Edit_Query,
	Pack_Tap,
	Change_Folder,
	Audio_Limit_Down,
	Audio_Limit_Up,
	Toggle_Length_Patch,
	Reload_Pack,
	Song_Tap,
	Sync_Fold,
	Preview_Tap,
	Toggle_Clicks,
	Click_Volume,
	Reload_Stick,
	Stick_Song_Tap,
	Pick_Sync_Step,
	Nudge_Notes,
	Measure_Stick,
	Reset_Stick,
	Delete_Stick,
}
Show_Page         :: struct { page: Page }
Pick_Search_Kind  :: struct { kind: Search_Kind }
Pack_Tap          :: struct { index: int }
Edit_Query        :: struct {}
Change_Folder    :: struct {}
Audio_Limit_Down :: struct {}
Audio_Limit_Up   :: struct {}
Toggle_Length_Patch :: struct {}
Reload_Pack      :: struct {}
Song_Tap         :: struct { index: int }
Sync_Fold        :: struct { index: int }
Preview_Tap      :: struct { index: int, page: Page }
Toggle_Clicks    :: struct {}
Click_Volume     :: struct { up: bool }

Preview_State :: enum u8 {
	Idle,
	Fetching,
	Playing,
	Paused,
}
Reload_Stick     :: struct {}
Stick_Song_Tap   :: struct { index: int }
Pick_Sync_Step   :: struct { step: int }
Nudge_Notes      :: struct { earlier: bool }
Measure_Stick    :: struct {}
Reset_Stick      :: struct {}
Delete_Stick     :: struct {}

// What a yes in the confirmation dialog (confirm.odin) does. One question at a time.
Confirm_Action :: union {
	Confirm_Delete,
	Confirm_Replace,
}
Confirm_Delete  :: struct { stamp: int, folder_id: string, name: string } // heap strings
Confirm_Replace :: struct { index: int, pack_id: int }

// A song on the stick, as the SYNC page knows it.
Stick_Row :: struct {
	song:      Stick_Song,  // heap
	chart:     Stick_Chart, // heap ids, once opened
	opened:    bool,
	opening:   bool,
	wanted:    f64, // the #OFFSET shown: written to the stick, or on its way
	sync:      Song_Sync,
	measuring: bool,
}

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
	query:         string, // as typed (heap)
	typing:        bool,   // the text dialog is open
	results:       []Pack_Row,
	results_scroll: int,
	search_stamp:  int, // the latest search sent; older answers are dropped

	pack_id:       int, // 0: none opened yet
	pack_name:     string,
	wanted_song:   string, // a song picked in the search results: highlighted once its pack is read (heap)
	highlight:     int,    // the song row to highlight, or -1
	songs:         []Song_Row,
	copying:       int, // the song being copied, or -1
	fold_open:     int, // the song row whose sync foldout is open, or -1
	preview:       Preview_State,
	preview_song:  int, // the song row playing, paused or being fetched, or -1
	preview_page:  Page, // which list that row is in (.Songs or .Sync)
	metronome:     int,  // a Click_Mode: 0 off, 1 beats, 2 notes (a saved setting)
	click_volume:  int,  // percent of the metronome's default loudness (a saved setting)
	preview_start: f64, // where it started, seconds
	progress:      Copy_Progress,

	scroll:        int, // pixels the song list is scrolled down (results_scroll for the pack list)
	hits:          [dynamic]Hit,
	touch_x:       f32,
	touch_start_y: f32,
	touch_last_y:  f32,
	dragging:      bool,

	stick_rows:    []Stick_Row,
	stick_stamp:   int,  // bumped on every new list; answers about an older one are dropped
	stick_listing: bool,
	stick_free:    i64,  // bytes free on the stick, -1 unknown
	stick_names:   map[string]bool, // the stick's song folders (stick_name_key), for ON STICK on SONGS
	confirming:    Confirm_Action,  // waiting for the dialog's answer (nil: no dialog open)
	sync_open:     int,  // the open stick song, or -1
	sync_step:     int,  // index into SYNC_STEPS (a saved setting)
	sync_scroll:   int,

	redraw:        bool, // draw when the loop has taken everything waiting
	bars:          Bar_Insets,
	bars_known:    bool,
}

state: App_State

main :: proc() {
	context.logger = log.create_console_logger(ident = LOG_TAG)

	app := glue.app()
	app.onAppCmd     = on_app_cmd
	app.onInputEvent = on_input_event

	state.private_dir = strings.clone_from_cstring(app.activity.internalDataPath)
	state.copying = -1
	state.highlight = -1
	state.fold_open = -1
	state.sync_open = -1
	state.preview_song = -1
	state.stick_free = -1
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
		// Wait for something, then take everything else already waiting without waiting again.
		timeout: i32 = -1
		for app.destroyRequested == 0 {
			source: ^glue.android_poll_source
			if android.ALooper_pollOnce(timeout, nil, nil, (^rawptr)(&source)) < 0 do break
			if source != nil do source.process(app, source)
			timeout = 0
		}
		// The picker answers on Android's UI thread and the worker on its own; both wake this loop.
		if result, ok := take_picker_result(); ok {
			handle_picker_result(result)
		}
		handle_worker_messages()
		handle_text_events()
		if yes, answered := take_confirm_answer(); answered do handle_confirm_answer(yes)
		if player_finished() {
			stop_preview() // played to the end
			request_draw()
		}
		if state.redraw {
			state.redraw = false
			draw(app)
		}
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
	ask_stick_names()
	request_draw()
}

handle_worker_messages :: proc() {
	messages := take_messages(context.temp_allocator)
	if len(messages) == 0 do return
	for message in messages {
		switch m in message {
		case Preview_Ready:
			preview := m.preview
			list_id := state.pack_id if m.page == .Songs else state.stick_stamp
			if m.page != state.preview_page || m.pack_id != list_id || m.index != state.preview_song || state.preview != .Fetching {
				preview_destroy(&preview) // asked for something else since
				continue
			}
			if preview.sound == nil {
				preview_destroy(&preview)
				stop_preview()
				continue
			}
			// On SYNC the metronome follows the offset as shown, which may be ahead of the stick.
			if row := stick_row(m.index, m.pack_id); m.page == .Sync && row != nil && row.opened do preview.offset = row.wanted
			// Clicks are for syncing: only on SYNC.
			if problem := player_play(preview, click_mode(m.page), f32(state.click_volume) / 100); problem != "" {
				say(.Bad, "COULD NOT PLAY THE SONG:", problem)
				stop_preview()
				continue
			}
			state.preview, state.preview_start = .Playing, preview.start_seconds
		case Say:
			say(m.mood, m.lines[0], m.lines[1])
			delete(m.lines[0])
			delete(m.lines[1])
		case Pack_Ready:
			if state.preview_page == .Songs do stop_preview()
			ask_stick_names()
			free_song_rows()
			state.pack_id, state.pack_name, state.songs = m.id, m.name, m.rows
			state.fold_open = -1
			find_wanted_song()
			state.scroll = 0
		case Copy_Progress:
			state.progress = m
			state.copying = -1 if m.finished else m.song
			if m.finished do ask_stick_names()
			if m.finished && m.song < len(state.songs) do state.songs[m.song].sync = m.sync
		case Search_Results:
			if m.stamp != state.search_stamp {
				free_pack_rows(m.rows) // an answer to an older search
				continue
			}
			free_pack_rows(state.results)
			state.results, state.results_scroll = m.rows, 0
		case Stick_Names:
			for name in state.stick_names do delete(name)
			clear(&state.stick_names)
			for name in m.names do state.stick_names[name] = true
			delete(m.names) // the map keeps the strings
		case Stick_Deleted:
			if m.ok {
				list_stick()
				ask_stick_names()
			}
		case Stick_Listed:
			if m.stamp != state.stick_stamp {
				stick_songs_destroy(m.songs)
				continue
			}
			state.stick_listing = false
			state.stick_free = m.free
			if state.preview_page == .Sync do stop_preview()
			free_stick_rows()
			state.stick_rows = make([]Stick_Row, len(m.songs))
			for song, i in m.songs do state.stick_rows[i].song = song
			delete(m.songs)
			state.sync_open, state.sync_scroll = -1, 0
		case Stick_Opened:
			chart := m.chart
			row := stick_row(m.index, m.stamp)
			if row == nil {
				stick_chart_destroy(&chart)
				continue
			}
			row.opening = false
			if chart.sm_id == "" do continue
			row.chart, row.opened, row.wanted = chart, true, chart.offset
			if state.preview_page == .Sync && state.preview_song == m.index do player_set_offset(row.wanted)
		case Stick_Offset_Written:
			row := stick_row(m.index, m.stamp)
			if row == nil do continue
			if m.ok {
				row.chart.offset = m.offset
				row.chart.has_backup = true
			} else {
				row.wanted = row.chart.offset // show what the stick really has
				if state.preview_page == .Sync && state.preview_song == m.index do player_set_offset(row.wanted)
			}
		case Stick_Reset_Done:
			row := stick_row(m.index, m.stamp)
			if row == nil || !m.ok do continue
			row.chart.offset, row.chart.original, row.wanted = m.original, m.original, m.original
			row.chart.has_backup = false
			if state.preview_page == .Sync && state.preview_song == m.index do player_set_offset(row.wanted)
		case Stick_Measured:
			row := stick_row(m.index, m.stamp)
			if row == nil do continue
			row.measuring = false
			row.sync = m.sync
		}
	}
	request_draw()
}

on_tap :: proc(app: ^glue.android_app, x, y: int) {
	for hit in state.hits {
		if y < hit.top || y >= hit.bottom do continue
		if hit.right > 0 && (x < hit.left || x >= hit.right) do continue
		switch target in hit.target {
		case Show_Page:
			state.page = target.page
			if state.page == .Sync do list_stick() // the stick may have changed (copies, the PC)
		case Reload_Stick:
			list_stick()
		case Stick_Song_Tap:
			state.sync_open = -1 if state.sync_open == target.index else target.index
			row := &state.stick_rows[target.index]
			if state.sync_open >= 0 && !row.opened && !row.opening {
				row.opening = true
				worker_ask(Open_Stick_Song{index = target.index, stamp = state.stick_stamp, tree = strings.clone(state.folder), folder_id = strings.clone(row.song.folder_id)})
			}
		case Pick_Sync_Step:
			state.sync_step = target.step
			save_settings()
		case Nudge_Notes:
			row := open_stick_row()
			if row == nil do return
			// A note's time is its beat's time minus #OFFSET: a bigger #OFFSET brings the notes earlier.
			step := SYNC_STEPS[state.sync_step]
			row.wanted = math.round((row.wanted + (step if target.earlier else -step)) * 10_000) / 10_000
			if state.preview_page == .Sync && state.preview_song == state.sync_open do player_set_offset(row.wanted)
			worker_ask(Set_Stick_Offset{index = state.sync_open, stamp = state.stick_stamp, tree = strings.clone(state.folder), sm_id = strings.clone(row.chart.sm_id), offset = row.wanted})
		case Measure_Stick:
			row := open_stick_row()
			if row == nil || row.measuring do return
			if !row.chart.music_ogg {
				say(.Bad, "ONLY OGG AUDIO CAN BE MEASURED.", "THIS SONG'S AUDIO IS MISSING OR NOT AN OGG.")
				return
			}
			row.measuring = true
			say(.Waiting, "MEASURING THE SYNC ...", "READING THE SONG FROM THE STICK TAKES A FEW SECONDS.")
			worker_ask(Measure_Stick_Song{index = state.sync_open, stamp = state.stick_stamp, tree = strings.clone(state.folder), sm_id = strings.clone(row.chart.sm_id), music_id = strings.clone(row.chart.music_id)})
		case Delete_Stick:
			row := open_stick_row()
			if row == nil do return
			ask(app, Confirm_Delete{stamp = state.stick_stamp, folder_id = strings.clone(row.song.folder_id), name = strings.clone(row.song.name)}, "Delete from the stick?",
				fmt.tprintf("%s will be deleted from the stick, with all its files. This can't be undone.", row.song.name), "Delete")
		case Reset_Stick:
			row := open_stick_row()
			if row == nil || !row.chart.has_backup do return
			worker_ask(Reset_Stick_Song{index = state.sync_open, stamp = state.stick_stamp, tree = strings.clone(state.folder), sm_id = strings.clone(row.chart.sm_id)})
		case Pick_Search_Kind:
			state.search_kind = target.kind
			if state.search_kind == .Pack_Name || state.query != "" do search_now()
		case Edit_Query:
			if state.typing do return
			if err := open_text_input(app, fmt.tprintf("Search by %s", strings.to_lower(SEARCH_KIND_LABEL[state.search_kind], context.temp_allocator)), state.query); err != "" {
				say(.Bad, "COULD NOT OPEN THE TEXT BOX:", err)
				return
			}
			state.typing = true
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
			delete(state.wanted_song)
			state.wanted_song = strings.clone(row.matched)
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
		case Click_Volume:
			state.click_volume = clamp(state.click_volume + (CLICK_VOLUME_STEP if target.up else -CLICK_VOLUME_STEP), CLICK_VOLUME_MIN, CLICK_VOLUME_MAX)
			player_set_click_volume(f32(state.click_volume) / 100)
			save_settings()
		case Toggle_Clicks:
			state.metronome = (state.metronome + 1) % len(Click_Mode) // OFF -> BEATS -> NOTES
			player_set_clicks(click_mode(state.preview_page))
			save_settings()
		case Preview_Tap:
			if target.index == state.preview_song && target.page == state.preview_page {
				#partial switch state.preview {
				case .Playing:
					player_pause()
					state.preview = .Paused
				case .Paused:
					player_resume()
					state.preview = .Playing
				}
			} else {
				stop_preview()
				state.preview, state.preview_song, state.preview_page = .Fetching, target.index, target.page
				if state.copying >= 0 do say(.Waiting, "THE SONG PLAYS ONCE THE COPY IS DONE.")
				if target.page == .Sync {
					song := state.stick_rows[target.index].song
					worker_ask(Preview_Stick{index = target.index, stamp = state.stick_stamp, tree = strings.clone(state.folder), folder_id = strings.clone(song.folder_id)})
				} else {
					worker_ask(Preview_Song{index = target.index, pack_id = state.pack_id})
				}
			}
		case Sync_Fold:
			state.fold_open = -1 if state.fold_open == target.index else target.index
		case Song_Tap:
			switch {
			case !state.folder_ok:
				say(.Bad, "PICK THE STICK FOLDER FIRST (THE STICK ROW).")
			case state.copying >= 0:
				say(.Waiting, "ONE SONG AT A TIME: WAIT FOR THIS COPY TO FINISH.")
			case song_on_stick(target.index):
				ask(app, Confirm_Replace{index = target.index, pack_id = state.pack_id}, "Already on the stick",
					fmt.tprintf("%s is already on the stick. Replace it with a fresh copy? The copy on the stick, sync changes included, will be deleted.", state.songs[target.index].name), "Replace")
			case:
				start_copy(target.index, replace = false)
			}
		}
		request_draw()
		return
	}
}

// What happened in the text dialog. Pack names are searched as you type; the other searches ask
// the site, so they wait for Search.
handle_text_events :: proc() {
	events := take_text_events(context.temp_allocator)
	if len(events) == 0 do return
	for event in events {
		switch event.kind {
		case .Changed:
			delete(state.query)
			state.query = event.text
			if state.search_kind == .Pack_Name do search_now()
		case .Submitted:
			delete(state.query)
			state.query = event.text
			search_now()
		case .Closed:
			delete(event.text)
			state.typing = false
		}
	}
	request_draw()
}

search_now :: proc() {
	state.search_stamp += 1
	worker_ask(Search_Packs{kind = state.search_kind, query = strings.clone(state.query), stamp = state.search_stamp})
}

free_pack_rows :: proc(rows: []Pack_Row) {
	for row in rows {
		delete(row.name)
		delete(row.matched)
	}
	delete(rows)
}

// After a song search: the picked song's row, if a folder is named like it (folders usually carry the
// song's title, though not always). Scrolled to the top of the list and highlighted.
find_wanted_song :: proc() {
	state.highlight = -1
	if state.wanted_song == "" do return
	wanted := strings.to_lower(state.wanted_song, context.temp_allocator)
	for row, i in state.songs {
		name := strings.to_lower(row.name, context.temp_allocator)
		if name == wanted || strings.contains(name, wanted) || strings.contains(wanted, name) {
			state.highlight = i
			state.scroll = i * song_row_height(glue.app())
			break
		}
	}
	delete(state.wanted_song)
	state.wanted_song = ""
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

settings_table :: proc() -> [6]Setting {
	return {
		{key = "click_volume",      value = &state.click_volume, default = 100,                 min = CLICK_VOLUME_MIN, max = CLICK_VOLUME_MAX},
		{key = "metronome",         value = &state.metronome,    default = 0,                   min = 0,               max = len(Click_Mode) - 1},
		{key = "sync_step",         value = &state.sync_step,    default = 1,                   min = 0,               max = len(SYNC_STEPS) - 1},
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

// Clicks are for syncing: only on SYNC.
click_mode :: proc(page: Page) -> Click_Mode {
	return Click_Mode(state.metronome) if page == .Sync else .Off
}

stop_preview :: proc() {
	player_stop()
	state.preview, state.preview_song = .Idle, -1
}

start_copy :: proc(index: int, replace: bool) {
	state.copying = index
	state.progress = {song = index}
	options := Copy_Options{audio_limit = state.audio_limit, length_patch = state.length_patch == 1}
	worker_ask(Copy_Song{index = index, tree = strings.clone(state.folder), options = options, replace = replace})
}

song_on_stick :: proc(index: int) -> bool {
	return index >= 0 && index < len(state.songs) && stick_name_key(state.songs[index].name) in state.stick_names
}

ask_stick_names :: proc() {
	if state.folder_ok do worker_ask(Name_Stick{tree = strings.clone(state.folder)})
}

// Opens the confirmation dialog; `action` happens on a yes (handle_confirm_answer).
ask :: proc(app: ^glue.android_app, action: Confirm_Action, title, message, button: string) {
	if state.confirming != nil {
		forget_confirm(action)
		return // one question at a time
	}
	if problem := open_confirm(app, title, message, button); problem != "" {
		say(.Bad, "COULD NOT ASK:", problem)
		forget_confirm(action)
		return
	}
	state.confirming = action
}

handle_confirm_answer :: proc(yes: bool) {
	action := state.confirming
	state.confirming = nil
	defer forget_confirm(action)
	if !yes do return
	switch a in action {
	case Confirm_Delete:
		if a.stamp != state.stick_stamp do return // the list changed meanwhile: ask again
		if state.preview_page == .Sync do stop_preview()
		state.sync_open = -1
		worker_ask(Delete_Stick_Song{stamp = a.stamp, tree = strings.clone(state.folder), folder_id = strings.clone(a.folder_id), name = strings.clone(a.name)})
	case Confirm_Replace:
		if a.pack_id != state.pack_id || state.copying >= 0 do return
		start_copy(a.index, replace = true)
	}
	request_draw()
}

@(private = "file")
forget_confirm :: proc(action: Confirm_Action) {
	if d, is_delete := action.(Confirm_Delete); is_delete {
		delete(d.folder_id)
		delete(d.name)
	}
}

list_stick :: proc() {
	if !state.folder_ok {
		say(.Bad, "PICK THE STICK FOLDER FIRST (THE STICK ROW ON SONGS).")
		return
	}
	state.stick_stamp += 1
	state.stick_listing = true
	worker_ask(List_Stick{tree = strings.clone(state.folder), stamp = state.stick_stamp})
}

// The stick row an answer is about, or nil when the list has changed since it was asked.
stick_row :: proc(index, stamp: int) -> ^Stick_Row {
	if stamp != state.stick_stamp || index < 0 || index >= len(state.stick_rows) do return nil
	return &state.stick_rows[index]
}

open_stick_row :: proc() -> ^Stick_Row {
	if state.sync_open < 0 || state.sync_open >= len(state.stick_rows) do return nil
	row := &state.stick_rows[state.sync_open]
	return row if row.opened else nil
}

free_stick_rows :: proc() {
	for &row in state.stick_rows {
		delete(row.song.name)
		delete(row.song.folder_id)
		stick_chart_destroy(&row.chart)
	}
	delete(state.stick_rows)
	state.stick_rows = nil
}

request_draw :: proc() {
	state.redraw = true
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
	request_draw()
}

on_app_cmd :: proc(app: ^glue.android_app, cmd: i32) {
	switch cmd {
	case glue.APP_CMD_INIT_WINDOW, glue.APP_CMD_WINDOW_RESIZED, glue.APP_CMD_CONTENT_RECT_CHANGED, glue.APP_CMD_CONFIG_CHANGED:
		state.bars, state.bars_known = read_bar_insets(app)
		request_draw()
	case glue.APP_CMD_PAUSE:
		// The app left the screen: the song shouldn't play on behind it.
		if state.preview == .Playing {
			player_pause()
			state.preview = .Paused
		}
	case glue.APP_CMD_WINDOW_REDRAW_NEEDED:
		draw(app) // Android waits for this frame
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
	drag_threshold := f32(row_height(app)) / 3 // a finger moving this far is dragging, not tapping

	#partial switch android.AMotionEvent_getAction(event).action {
	case .DOWN:
		state.touch_x = android.AMotionEvent_getX(event, 0)
		state.touch_start_y, state.touch_last_y, state.dragging = y, y, false
	case .MOVE:
		if abs(y - state.touch_start_y) > drag_threshold do state.dragging = true
		if state.dragging {
			scrolls := [Page]^int{.Packs = &state.results_scroll, .Songs = &state.scroll, .Sync = &state.sync_scroll}
			list_scroll := scrolls[state.page]
			list_scroll^ -= int(y - state.touch_last_y)
			state.touch_last_y = y
			request_draw()
		}
	case .UP:
		if !state.dragging do on_tap(app, int(state.touch_x), int(y))
	}
	return 1
}
