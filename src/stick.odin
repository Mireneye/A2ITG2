/*
The songs already on the stick, for the SYNC page: listing them, reading a song's #OFFSET, changing
it, putting the original back, and measuring the song's sync. Runs on the worker thread.

Before a song's chart is first changed, the whole original .sm goes into the app's private folder
(SYNC_BACKUP_FOLDER, one file per chart). RESET writes it back and drops the backup; the backup also
says what the original #OFFSET was. A chart that already has a backup keeps the first one, so the
original is never overwritten by a changed version.
*/
package a2itg2

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "chart"

SYNC_BACKUP_FOLDER :: "sync_backups"

Stick_Song :: struct {
	name:      string, // heap
	folder_id: string, // heap
}

stick_songs_destroy :: proc(songs: []Stick_Song) {
	for song in songs {
		delete(song.name)
		delete(song.folder_id)
	}
	delete(songs)
}

// The song folders in the picked folder, by name.
stick_list :: proc(tree: string) -> (songs: []Stick_Song, problem: string) {
	root, root_problem := root_folder(tree, context.temp_allocator)
	if root_problem != "" do return nil, root_problem
	children, list_problem := list_children(root)
	if list_problem != "" do return nil, list_problem
	defer children_destroy(children)
	out := make([dynamic]Stick_Song)
	for child in children {
		if child.is_folder do append(&out, Stick_Song{name = strings.clone(child.name), folder_id = strings.clone(child.id)})
	}
	slice.sort_by(out[:], proc(a, b: Stick_Song) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
	return out[:], ""
}

// A song's chart as found on the stick.
Stick_Chart :: struct {
	sm_id:      string, // heap
	music_id:   string, // heap; "" when the chart's #MUSIC isn't in the folder
	music_ogg:  bool,
	offset:     f64,    // as the chart on the stick has it
	original:   f64,    // before the app first changed it (= offset without a backup)
	has_backup: bool,
}

stick_chart_destroy :: proc(c: ^Stick_Chart) {
	delete(c.sm_id)
	delete(c.music_id)
	c^ = {}
}

stick_open :: proc(tree, folder_id: string) -> (result: Stick_Chart, problem: string) {
	children, list_problem := list_children(Folder_Ref{tree = tree, document_id = folder_id})
	if list_problem != "" do return {}, list_problem
	defer children_destroy(children)
	sm_index := -1
	for child, i in children {
		if !child.is_folder && strings.has_suffix(strings.to_lower(child.name, context.temp_allocator), ".sm") {
			sm_index = i
			break
		}
	}
	if sm_index < 0 do return {}, "NO .SM CHART IN THIS FOLDER"
	text, read_problem := read_document(tree, children[sm_index].id)
	if read_problem != "" do return {}, read_problem
	defer delete(text)
	offset, has_offset := chart_offset(string(text))
	if !has_offset do return {}, "THE CHART HAS NO #OFFSET"

	result.sm_id = strings.clone(children[sm_index].id)
	result.offset, result.original = offset, offset
	music, _ := chart.tag_value(string(text), "MUSIC")
	music = strings.to_lower(strings.trim_space(music), context.temp_allocator)
	for child in children {
		if music != "" && strings.to_lower(child.name, context.temp_allocator) == music {
			result.music_id = strings.clone(child.id)
			result.music_ogg = strings.has_suffix(music, ".ogg")
		}
	}
	if backup, ok := read_backup(tree, result.sm_id); ok {
		defer delete(backup)
		if original, found := chart_offset(string(backup)); found {
			result.original, result.has_backup = original, true
		}
	}
	return result, ""
}

// Writes `offset` into the chart on the stick, backing the original up first.
stick_set_offset :: proc(tree, sm_id: string, offset: f64) -> (problem: string) {
	text, read_problem := read_document(tree, sm_id)
	if read_problem != "" do return read_problem
	defer delete(text)
	if _, has_offset := chart_offset(string(text)); !has_offset do return "THE CHART HAS NO #OFFSET"
	if !has_backup(tree, sm_id) {
		if write_problem := write_backup(tree, sm_id, text); write_problem != "" do return write_problem
	}
	changed := replace_tag_value(string(text), "OFFSET", format_offset(offset))
	return overwrite_document(tree, sm_id, transmute([]u8)changed)
}

// Puts the original chart back and forgets the backup.
stick_reset :: proc(tree, sm_id: string) -> (original: f64, problem: string) {
	backup, ok := read_backup(tree, sm_id)
	if !ok do return 0, "NO BACKUP: THIS CHART WAS NOT CHANGED HERE"
	defer delete(backup)
	if write_problem := overwrite_document(tree, sm_id, backup); write_problem != "" do return 0, write_problem
	os.remove(backup_path(tree, sm_id))
	original, _ = chart_offset(string(backup))
	return original, ""
}

// A stick song's chart and audio, to play.
stick_preview :: proc(tree, folder_id: string) -> (preview: Preview, problem: string) {
	children, list_problem := list_children(Folder_Ref{tree = tree, document_id = folder_id})
	if list_problem != "" do return {}, list_problem
	defer children_destroy(children)
	sm_id := ""
	for child in children {
		if sm_id == "" && !child.is_folder && strings.has_suffix(strings.to_lower(child.name, context.temp_allocator), ".sm") do sm_id = child.id
	}
	if sm_id == "" do return {}, "NO .SM CHART IN THIS FOLDER"
	text, read_problem := read_document(tree, sm_id)
	if read_problem != "" do return {}, read_problem
	defer delete(text)
	music, _ := chart.tag_value(string(text), "MUSIC")
	music = strings.trim_space(music)
	for child in children {
		if music == "" || strings.to_lower(child.name, context.temp_allocator) != strings.to_lower(music, context.temp_allocator) do continue
		sound, sound_problem := read_document(tree, child.id)
		if sound_problem != "" do return {}, sound_problem
		built, build_problem := preview_from_chart(string(text), music, sound)
		return built, build_problem.what
	}
	return {}, "THE CHART'S AUDIO FILE IS NOT IN THE FOLDER"
}

stick_measure :: proc(tree, sm_id, music_id: string) -> (sync: Song_Sync, problem: string) {
	text, read_problem := read_document(tree, sm_id)
	if read_problem != "" do return {}, read_problem
	defer delete(text)
	ogg, ogg_problem := read_document(tree, music_id)
	if ogg_problem != "" do return {}, ogg_problem
	defer delete(ogg)
	return measure_sync(string(text), ogg), ""
}

format_offset :: chart.format_offset

@(private = "file")
chart_offset :: proc(sm: string) -> (offset: f64, found: bool) {
	text := chart.tag_value(sm, "OFFSET") or_return
	return strconv.parse_f64(strings.trim_space(text))
}

// One backup file per chart, named by a hash of the stick folder and the chart's document id.
@(private = "file")
backup_path :: proc(tree, sm_id: string) -> string {
	key := hash.fnv64a(transmute([]u8)fmt.tprintf("%s\n%s", tree, sm_id))
	return fmt.tprintf("%s/%s/%016x.sm", state.private_dir, SYNC_BACKUP_FOLDER, key)
}

@(private = "file")
has_backup :: proc(tree, sm_id: string) -> bool {
	return os.exists(backup_path(tree, sm_id))
}

@(private = "file")
read_backup :: proc(tree, sm_id: string) -> (bytes: []u8, ok: bool) {
	data, err := os.read_entire_file(backup_path(tree, sm_id), context.allocator)
	return data, err == nil
}

@(private = "file")
write_backup :: proc(tree, sm_id: string, bytes: []u8) -> string {
	folder := fmt.tprintf("%s/%s", state.private_dir, SYNC_BACKUP_FOLDER)
	if !os.exists(folder) do os.make_directory(folder)
	if err := os.write_entire_file(backup_path(tree, sm_id), bytes); err != nil do return "COULD NOT BACK THE CHART UP: NOTHING CHANGED"
	return ""
}
