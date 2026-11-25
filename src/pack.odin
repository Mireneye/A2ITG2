/*
A pack on stepmaniaonline.net, read a few byte ranges at a time: its table of contents, its songs,
and copying one song's files onto the stick.

Runs on the worker thread (worker.odin); everything here blocks on the network.
*/
package a2itg2

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "tls"
import "audio"
import "chart"
import "web"
import "zip"

PACK_DOWNLOAD_URL :: "https://stepmaniaonline.net/download/pack/%d/"

// Files a song folder can do without. Background videos often dwarf the rest of the song.
@(rodata)
SKIPPED_EXTENSIONS := [?]string{".avi", ".mp4", ".mpg", ".mpeg", ".m1v", ".m2v", ".mkv", ".webm", ".flv", ".wmv", ".mov", ".m4v", ".ogv"}

// A folder holding one of these is a song.
@(rodata)
CHART_EXTENSIONS := [?]string{".sm", ".ssc", ".dwi", ".sma"}

Pack :: struct {
	id:        int,
	name:      string, // the zip's top folder
	url:       string, // after redirects
	size:      i64,    // the whole zip
	entries:   [dynamic]zip.Entry,
	directory: []u8,   // the central directory; entry names point into it
	songs:     [dynamic]Song,
}

Song :: struct {
	name:  string,  // the song's folder name
	files: [dynamic]int, // indexes into Pack.entries, videos left out
	bytes: i64,     // what copying it writes
}

Pack_Problem :: struct {
	what: string,
	why:  string,
}

open_pack :: proc(anchors: ^tls.Trust_Anchors, id: int) -> (pack: Pack, problem: Pack_Problem) {
	pack.id = id
	url := fmt.tprintf(PACK_DOWNLOAD_URL, id)

	// Byte 0 first: the answer carries the file's size (Content-Range) and the final address.
	first, info := get_range(anchors, url, 0, 0, &problem)
	if problem.what != "" do return
	delete(first)
	if info.total_size <= 0 do return pack, {"THE SITE DID NOT SAY THE PACK'S SIZE", "IT MAY NOT SUPPORT PARTIAL DOWNLOADS"}
	pack.size = info.total_size
	pack.url = strings.clone(info.final_url)

	tail_start := max(pack.size - zip.TAIL_SIZE, 0)
	tail, _ := get_range(anchors, pack.url, tail_start, pack.size - 1, &problem)
	if problem.what != "" do return
	defer delete(tail)
	directory, need, failure := zip.directory_location(tail)
	if failure != .None do return pack, {"THE PACK'S TABLE OF CONTENTS IS UNREADABLE", fmt.tprint(failure)}
	if need.size > 0 {
		record, _ := get_range(anchors, pack.url, need.offset, need.offset + need.size - 1, &problem)
		if problem.what != "" do return
		defer delete(record)
		directory, failure = zip.zip64_directory_location(record)
		if failure != .None do return pack, {"THE PACK'S ZIP64 RECORD IS UNREADABLE", fmt.tprint(failure)}
	}

	pack.directory, _ = get_range(anchors, pack.url, directory.offset, directory.offset + directory.size - 1, &problem)
	if problem.what != "" do return
	pack.entries, failure = zip.read_directory(pack.directory)
	if failure != .None do return pack, {"THE PACK'S FILE LIST IS UNREADABLE", fmt.tprint(failure)}

	find_songs(&pack)
	return pack, {}
}

pack_destroy :: proc(pack: ^Pack) {
	for &song in pack.songs do delete(song.files)
	delete(pack.songs)
	delete(pack.entries)
	delete(pack.directory)
	delete(pack.url)
	pack^ = {}
}

// Groups the files by folder; a folder with a chart file is a song.
@(private = "file")
find_songs :: proc(pack: ^Pack) {
	by_folder := make(map[string]int, context.temp_allocator) // folder path -> index in pack.songs
	has_chart := make(map[string]bool, context.temp_allocator)

	for entry, i in pack.entries {
		if zip.is_folder(entry) do continue
		folder := folder_of(entry.name)
		if pack.name == "" {
			top, _, _ := strings.partition(entry.name, "/")
			pack.name = top
		}
		extension := strings.to_lower(extension_of(entry.name), context.temp_allocator)
		if slice.contains(CHART_EXTENSIONS[:], extension) do has_chart[folder] = true
		if slice.contains(SKIPPED_EXTENSIONS[:], extension) do continue

		index, known := by_folder[folder]
		if !known {
			index = len(pack.songs)
			by_folder[folder] = index
			append(&pack.songs, Song{name = last_part(folder)})
		}
		append(&pack.songs[index].files, i)
		pack.songs[index].bytes += entry.uncompressed_size
	}

	// Folders without a chart (the pack's own banner folder and the like) are not songs.
	kept := 0
	for song in pack.songs {
		folder_has_chart := false
		for i in song.files {
			if has_chart[folder_of(pack.entries[i].name)] {
				folder_has_chart = true
				break
			}
		}
		if folder_has_chart {
			pack.songs[kept] = song
			kept += 1
		} else {
			delete(song.files)
		}
	}
	resize(&pack.songs, kept)
	slice.sort_by(pack.songs[:], proc(a, b: Song) -> bool { return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator) })
}

// Copies song `index` into a new folder of its name inside `destination`: the song's .sm chart and
// the files it names (#MUSIC, #BANNER, #BACKGROUND, #CDTITLE, #LYRICSPATH). That leaves out videos,
// other chart formats and leftovers (".old" files) without guessing from names. A folder without
// an .sm (ITG2 reads no other format) copies nothing.
//
// MP3 audio is converted to Ogg Vorbis within the audio limit (src/audio: sample-exact, so the chart's
// sync holds) and the chart's #MUSIC is rewritten to the new name. An Ogg over the limit is re-encoded
// smaller under its own name; Oggs that fit are copied untouched. With the length patch on, an Ogg
// longer than 1:45 (converted or copied) is patched to read as 1:45. The Ogg that goes onto the stick
// is measured against the chart's notes (measure_sync), before any length patch. The chart is written
// last: a song folder is complete once its chart is there.
copy_song :: proc(anchors: ^tls.Trust_Anchors, pack: ^Pack, index: int, destination: Folder_Ref, options: Copy_Options, progress: Copy_Progress_Proc) -> (notes: Copy_Notes, problem: Pack_Problem) {
	audio_limit := options.audio_limit
	song := pack.songs[index]

	chart := -1
	for entry_index in song.files {
		if strings.to_lower(extension_of(pack.entries[entry_index].name), context.temp_allocator) == ".sm" {
			chart = entry_index
			break
		}
	}
	if chart < 0 do return notes, {"THIS SONG HAS NO .SM CHART", "ITG2 READS ONLY .SM (THIS ONE HAS .SSC OR .DWI)"}

	chart_bytes, chart_problem := fetch_entry(anchors, pack, chart)
	if chart_problem.what != "" do return notes, chart_problem
	defer delete(chart_bytes)
	chart_text := string(chart_bytes)

	// Each file the chart names that is in the song's folder.
	wanted := make([dynamic]int, context.temp_allocator)
	music := -1
	for reference in chart_references(chart_text) {
		if reference.name == "" do continue
		if slice.contains(SKIPPED_EXTENSIONS[:], strings.to_lower(extension_of(reference.name), context.temp_allocator)) {
			notes.videos_left_out += 1 // a banner or background movie: the cabinet does fine without
			continue
		}
		found := find_in_song(pack, song, reference.name)
		if found < 0 {
			if reference.tag == "MUSIC" do return notes, {"THE CHART'S AUDIO FILE IS MISSING", strings.to_upper(reference.name, context.temp_allocator)}
			notes.missing += 1 // a missing picture only costs the picture
			continue
		}
		if reference.tag == "MUSIC" do music = found
		if found != chart && !slice.contains(wanted[:], found) do append(&wanted, found)
	}
	total := len(wanted) + 1 // and the chart

	folder, folder_problem := create_folder(destination, song.name)
	if folder_problem != "" do return notes, {"COULD NOT MAKE THE SONG'S FOLDER", folder_problem}
	defer delete(folder.document_id)

	for entry_index, done in wanted {
		entry := pack.entries[entry_index]
		file_name := last_part(entry.name)
		progress({step = .Fetching, done = done, total = total})
		data, fetch_problem := fetch_entry_cached(anchors, pack, entry_index) // a previewed song's audio is already here
		if fetch_problem.what != "" do return notes, fetch_problem
		defer delete(data)

		if entry_index == music && strings.to_lower(extension_of(file_name), context.temp_allocator) == ".mp3" {
			progress({step = .Converting, done = done, total = total, pass = 1})
			conversion_status := Copy_Status{step = .Converting, done = done, total = total}
			conversion_progress := Conversion_Progress{progress = progress, status = &conversion_status}
			conversion, convert_problem := audio.mp3_to_ogg(data, audio_limit, proc(data: rawptr, percent, pass: int) {
				p := (^Conversion_Progress)(data)
				p.status.percent, p.status.pass = percent, pass
				p.progress(p.status^)
			}, &conversion_progress)
			if convert_problem != .None do return notes, convert_problem_text(convert_problem, audio_limit)
			defer delete(conversion.ogg)
			progress({step = .Measuring, done = done, total = total})
			notes.sync = measure_sync(chart_text, conversion.ogg)
			if options.length_patch do apply_length_patch(conversion.ogg, &notes)
			ogg_name := ogg_name_for(pack, song, file_name)
			if write_problem := write_file(folder, ogg_name, conversion.ogg, "audio/ogg"); write_problem != "" {
				return notes, {fmt.tprintf("COULD NOT WRITE %s", strings.to_upper(ogg_name, context.temp_allocator)), write_problem}
			}
			chart_text = replace_tag_value(chart_text, "MUSIC", ogg_name)
			notes.converted = true
			notes.ogg_bytes = len(conversion.ogg)
			notes.ogg_bitrate = conversion.bitrate
			notes.files += 1
			continue
		}
		is_ogg := strings.to_lower(extension_of(file_name), context.temp_allocator) == ".ogg"
		if entry_index == music && is_ogg && len(data) > audio_limit {
			// Too big for the cabinet: re-encode it smaller under the same name (the chart stays as is).
			progress({step = .Shrinking, done = done, total = total, pass = 1})
			shrink_status := Copy_Status{step = .Shrinking, done = done, total = total}
			shrink_progress := Conversion_Progress{progress = progress, status = &shrink_status}
			shrunk, shrink_problem := audio.ogg_shrink(data, audio_limit, proc(data: rawptr, percent, pass: int) {
				p := (^Conversion_Progress)(data)
				p.status.percent, p.status.pass = percent, pass
				p.progress(p.status^)
			}, &shrink_progress)
			if shrink_problem != .None do return notes, convert_problem_text(shrink_problem, audio_limit)
			delete(data)
			data = shrunk.ogg
			notes.shrunk = true
			notes.original_bytes = int(entry.uncompressed_size)
			notes.ogg_bytes, notes.ogg_bitrate = len(shrunk.ogg), shrunk.bitrate
		}
		if entry_index == music && is_ogg {
			progress({step = .Measuring, done = done, total = total})
			notes.sync = measure_sync(chart_text, data)
		}
		if entry_index == music && is_ogg && options.length_patch do apply_length_patch(data, &notes)

		if write_problem := write_file(folder, file_name, data); write_problem != "" {
			return notes, {fmt.tprintf("COULD NOT WRITE %s", strings.to_upper(file_name, context.temp_allocator)), write_problem}
		}
		notes.files += 1
	}

	progress({step = .Fetching, done = total - 1, total = total})
	chart_name := last_part(pack.entries[chart].name)
	if write_problem := write_file(folder, chart_name, transmute([]u8)chart_text); write_problem != "" {
		return notes, {fmt.tprintf("COULD NOT WRITE %s", strings.to_upper(chart_name, context.temp_allocator)), write_problem}
	}
	notes.files += 1
	progress({step = .Fetching, done = total, total = total})
	return notes, {}
}

Copy_Options :: struct {
	audio_limit:  int,  // bytes an Ogg may take
	length_patch: bool, // make Oggs over 1:45 read as 1:45
}

@(private = "file")
apply_length_patch :: proc(ogg: []u8, notes: ^Copy_Notes) {
	patch := audio.ogg_length_patch(ogg)
	notes.real_seconds = patch.reported_seconds
	notes.length_patched = patch.patched
	notes.patch_failed = patch.problem != .None
}

Copy_Step :: enum u8 {
	Fetching,
	Converting, // an MP3 becoming an Ogg
	Shrinking,  // an Ogg over the audio limit being re-encoded smaller
	Measuring,  // the Ogg measured against the chart's notes
}

// Where a copy is: `done` of `total` files, and while converting, `percent` of encoding `pass`
// (a pass after the first means the first came out over the audio limit).
Copy_Status :: struct {
	step:        Copy_Step,
	done, total: int,
	percent:     int,
	pass:        int,
}

Copy_Progress_Proc :: #type proc(status: Copy_Status)

@(private = "file")
Conversion_Progress :: struct {
	progress: Copy_Progress_Proc,
	status:   ^Copy_Status,
}

// What a copy found worth telling.
Copy_Notes :: struct {
	files:            int,
	missing:          int,  // pictures the chart names that aren't in the folder
	videos_left_out:  int,  // banner or background movies the chart names
	converted:        bool, // the MP3 became an Ogg
	ogg_bytes:        int,
	ogg_bitrate:      int,
	shrunk:           bool, // an Ogg over the limit, re-encoded smaller
	original_bytes:   int,  // its size before
	length_patched:   bool, // the Ogg now reads as 1:45
	patch_failed:     bool, // the Ogg couldn't be read for patching (copied unpatched)
	real_seconds:     f64,
	sync:             Song_Sync,
}

// How the chart's notes sit on its music (audio/sync_match.odin), and the #OFFSET that would put them
// on it. Only shown: changing the sync is the user's to do.
Song_Sync :: struct {
	state:     audio.Match_State,
	shift_ms:  f64, // the music after the notes (+: the notes are early)
	offset:    f64, // the chart's #OFFSET
	suggested: f64, // the #OFFSET with the notes on the music, to the millisecond (StepMania writes 3 decimals)
}

measure_sync :: proc(chart_text: string, ogg: []u8) -> (sync: Song_Sync) {
	timing, timing_ok := chart.read_timing(chart_text)
	if !timing_ok do return
	defer chart.timing_destroy(&timing)
	attacks, attacks_ok := audio.ogg_attacks(ogg)
	if !attacks_ok do return
	defer audio.attacks_destroy(&attacks)
	notes := chart.note_seconds(chart_text, timing)
	defer delete(notes)
	match := audio.match_notes(attacks, notes)
	sync.state = match.state
	sync.shift_ms = match.shift * 1000
	sync.offset = timing.offset
	// A note's time is its beat's time minus #OFFSET: notes that are early need a smaller #OFFSET.
	sync.suggested = math.round((timing.offset - match.shift) * 1000) / 1000
	return
}

@(private = "file")
convert_problem_text :: proc(problem: audio.Convert_Problem, limit: int) -> Pack_Problem {
	switch problem {
	case .None:            return {}
	case .Not_Mp3:         return {"THE AUDIO ISN'T A READABLE MP3", ""}
	case .Decode_Error:    return {"THE MP3 IS DAMAGED PART-WAY", "IT DECODES ONLY IN PART"}
	case .Too_Long:        return {"THE SONG IS TOO LONG FOR THE AUDIO LIMIT", fmt.tprintf("RAISE THE LIMIT ABOVE %s", megabytes_decimal(limit))}
	case .Encoder_Refused: return {"THE OGG ENCODER REFUSED THIS AUDIO", "ODD SAMPLE RATE OR CHANNEL COUNT?"}
	}
	return {}
}

// The converted file's name: the MP3's with .ogg, unless the song folder already has a file by that name.
@(private = "file")
ogg_name_for :: proc(pack: ^Pack, song: Song, mp3_name: string) -> string {
	stem := mp3_name[:len(mp3_name) - len(extension_of(mp3_name))]
	name := fmt.tprintf("%s.ogg", stem)
	if find_in_song(pack, song, name) >= 0 do name = fmt.tprintf("%s (a2itg2).ogg", stem)
	return name
}

// The chart with `#TAG:value;` given a new value (the first one; tags in any letter case).
replace_tag_value :: proc(chart, tag, value: string) -> string {
	upper := strings.to_upper(chart, context.temp_allocator)
	marker := fmt.tprintf("#%s:", tag)
	at := strings.index(upper, marker)
	if at < 0 do return chart
	start := at + len(marker)
	end := strings.index_byte(chart[start:], ';')
	if end < 0 do return chart
	return strings.concatenate({chart[:start], value, chart[start + end:]}, context.temp_allocator)
}

Chart_Reference :: struct {
	tag:  string, // upper case
	name: string,
}

// The file names an .sm chart refers to. Tags are "#NAME:value;" in any letter case.
chart_references :: proc(chart: string) -> [5]Chart_Reference {
	TAGS :: [5]string{"MUSIC", "BANNER", "BACKGROUND", "CDTITLE", "LYRICSPATH"}
	found: [5]Chart_Reference
	upper := strings.to_upper(chart, context.temp_allocator) // same length: ASCII tags, offsets line up
	for tag, i in TAGS {
		found[i].tag = tag
		marker := fmt.tprintf("#%s:", tag)
		at := strings.index(upper, marker)
		if at < 0 do continue
		value := chart[at + len(marker):]
		end := strings.index_byte(value, ';')
		if end < 0 do continue
		found[i].name = strings.trim_space(value[:end])
	}
	return found
}

// The entry in the song's folder named `name` (FAT and Windows ignore letter case), or -1.
// Names reaching outside the folder ("../banner.png", a pack-wide picture) are not followed.
@(private = "file")
find_in_song :: proc(pack: ^Pack, song: Song, name: string) -> int {
	if strings.contains(name, "..") do return -1
	wanted := strings.to_lower(strings.trim_prefix(name, "./"), context.temp_allocator)
	song_folder := folder_of(pack.entries[song.files[0]].name)
	for entry_index in song.files {
		entry_name := pack.entries[entry_index].name
		inside := entry_name[min(len(song_folder) + 1, len(entry_name)):]
		if strings.to_lower(inside, context.temp_allocator) == wanted do return entry_index
	}
	return -1
}

// Previews keep the songs' audio in the app (PREVIEW_CACHE_FOLDER), so copying a previewed song
// doesn't download it again. The oldest files go once the folder is over PREVIEW_CACHE_BYTES.
PREVIEW_CACHE_FOLDER :: "preview_cache"
PREVIEW_CACHE_BYTES  :: 60_000_000

@(private = "file")
cache_path :: proc(pack: ^Pack, entry_index: int) -> string {
	return fmt.tprintf("%s/%s/%d_%d.bin", state.private_dir, PREVIEW_CACHE_FOLDER, pack.id, entry_index)
}

// An entry from the preview cache if it's there whole, else fetched; `keep` puts a fetched one in it.
fetch_entry_cached :: proc(anchors: ^tls.Trust_Anchors, pack: ^Pack, entry_index: int, keep := false) -> (data: []u8, problem: Pack_Problem) {
	path := cache_path(pack, entry_index)
	if cached, err := os.read_entire_file(path, context.allocator); err == nil {
		if i64(len(cached)) == pack.entries[entry_index].uncompressed_size do return cached, {}
		delete(cached)
	}
	data, problem = fetch_entry(anchors, pack, entry_index)
	if problem.what != "" do return nil, problem
	if keep {
		folder := fmt.tprintf("%s/%s", state.private_dir, PREVIEW_CACHE_FOLDER)
		if !os.exists(folder) do os.make_directory(folder)
		if os.write_entire_file(path, data) == nil do trim_preview_cache(folder)
	}
	return data, {}
}

@(private = "file")
trim_preview_cache :: proc(folder: string) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil do return
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return time.diff(a.modification_time, b.modification_time) > 0 }) // newest first
	total: i64
	for entry in entries {
		total += entry.size
		if total > PREVIEW_CACHE_BYTES do os.remove(entry.fullpath)
	}
}

// What a preview plays: the song's audio and where its preview starts.
Preview :: struct {
	sound:         []u8, // heap
	format:        audio.Source_Format,
	start_seconds: f64,
}

// The song's #MUSIC and #SAMPLESTART, from its .sm (or .ssc, which has the same tags).
preview_song :: proc(anchors: ^tls.Trust_Anchors, pack: ^Pack, index: int) -> (preview: Preview, problem: Pack_Problem) {
	song := pack.songs[index]
	chart_entry := -1
	for wanted in ([?]string{".sm", ".ssc"}) {
		for entry_index in song.files {
			if chart_entry < 0 && strings.to_lower(extension_of(pack.entries[entry_index].name), context.temp_allocator) == wanted do chart_entry = entry_index
		}
	}
	if chart_entry < 0 do return {}, {"THIS SONG HAS NO .SM OR .SSC CHART", ""}
	chart_bytes, chart_problem := fetch_entry_cached(anchors, pack, chart_entry, keep = true)
	if chart_problem.what != "" do return {}, chart_problem
	defer delete(chart_bytes)
	chart_text := string(chart_bytes)

	music_name := ""
	for reference in chart_references(chart_text) do if reference.tag == "MUSIC" do music_name = reference.name
	music := find_in_song(pack, song, music_name) if music_name != "" else -1
	if music < 0 do return {}, {"THE CHART'S AUDIO FILE IS MISSING", strings.to_upper(music_name, context.temp_allocator)}
	switch strings.to_lower(extension_of(music_name), context.temp_allocator) {
	case ".ogg": preview.format = .Ogg
	case ".mp3": preview.format = .Mp3
	case:        return {}, {"ONLY OGG AND MP3 AUDIO CAN BE PLAYED", ""}
	}
	if start, found := chart.tag_value(chart_text, "SAMPLESTART"); found {
		preview.start_seconds, _ = strconv.parse_f64(strings.trim_space(start))
	}
	preview.sound, problem = fetch_entry_cached(anchors, pack, music, keep = true)
	return preview, problem
}

// One file of the pack, fetched and unpacked.
@(private = "file")
fetch_entry :: proc(anchors: ^tls.Trust_Anchors, pack: ^Pack, entry_index: int) -> (data: []u8, problem: Pack_Problem) {
	entry := pack.entries[entry_index]
	span := zip.entry_span(entry)
	last := min(span.offset + span.size, pack.size) - 1
	bytes, _ := get_range(anchors, pack.url, span.offset, last, &problem)
	if problem.what != "" do return nil, problem
	defer delete(bytes)
	failure: zip.Failure
	data, failure = zip.extract(entry, bytes)
	if failure != .None do return nil, {fmt.tprintf("COULD NOT UNPACK %s", strings.to_upper(last_part(entry.name), context.temp_allocator)), fmt.tprint(failure)}
	return data, {}
}

// One range request; on failure fills `problem` (and returns no body).
@(private = "file")
get_range :: proc(anchors: ^tls.Trust_Anchors, url: string, first, last: i64, problem: ^Pack_Problem) -> (body: []u8, info: web.Info) {
	failure: web.Failure
	tls_failure: tls.Failure
	body, info, failure, tls_failure = web.get(anchors, url, web.Range{first = first, last = last})
	switch failure {
	case .None:
		if info.status != 206 {
			delete(body)
			problem^ = {"THE SITE SENT THE WHOLE FILE, NOT A PART", "IT DOES NOT SUPPORT PARTIAL DOWNLOADS HERE"}
			return nil, info
		}
		return body, info
	case .Tls:
		problem^ = {"SECURE CONNECTION FAILED", fmt.tprint(tls_failure)}
	case .Http_Error:
		problem^ = {"THE SITE ANSWERED WITH AN ERROR", fmt.tprintf("HTTP %d", info.status)}
	case .Resolve, .Connect:
		problem^ = {"COULD NOT REACH THE SITE", "IS THE PHONE ONLINE?"}
	case .Bad_Url, .Send, .Receive, .Bad_Response, .Too_Many_Redirects:
		problem^ = {"DOWNLOAD FAILED", fmt.tprint(failure)}
	}
	return nil, info
}

// Path helpers that return parts of the name itself (no copies): names live in Pack.directory.
@(private = "file")
folder_of :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	return path[:slash] if slash >= 0 else ""
}

@(private = "file")
last_part :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

@(private = "file")
extension_of :: proc(path: string) -> string {
	name := last_part(path)
	dot := strings.last_index_byte(name, '.')
	return name[dot:] if dot > 0 else ""
}
