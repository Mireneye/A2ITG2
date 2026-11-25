/*
The worker thread: everything that waits on the network or the stick runs here, so the app's own
loop keeps answering touches (Android closes apps that leave input unanswered for ~5 s).

	worker_start()               once
	worker_ask(Job)              from the app's loop
	take_messages()              from the app's loop, after the worker woke it

The worker owns the open pack; the screen gets copies of what it shows (Song_Row).
*/
package a2itg2

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import "tls"

Open_Pack :: struct {
	id: int,
}

Copy_Song :: struct {
	index:   int,
	tree:    string, // the picked folder's address (heap; the worker frees it)
	options: Copy_Options,
}

Load_Catalog :: struct {
	private_dir: string, // heap; the worker frees it
}

Search_Packs :: struct {
	kind:  Search_Kind,
	query: string, // heap; the worker frees it
	stamp: int,    // the screen keeps only the answer to its latest search
}

Job :: union {
	Open_Pack,
	Copy_Song,
	Load_Catalog,
	Search_Packs,
}

Song_Row :: struct {
	name:  string, // heap
	bytes: i64,
	files: int,
	sync:  Song_Sync, // after a copy: how its notes sit on the music
}

// What the worker tells the screen.
Say :: struct {
	mood:  Screen_Mood,
	lines: [2]string, // heap; "" for none
}

Pack_Ready :: struct {
	id:   int,
	name: string,     // heap
	rows: []Song_Row, // heap
}

Copy_Progress :: struct {
	song:     int,
	status:   Copy_Status,
	finished: bool,
	sync:     Song_Sync, // when finished
}

Search_Results :: struct {
	stamp: int,
	rows:  []Pack_Row, // heap
}

Message :: union {
	Say,
	Pack_Ready,
	Copy_Progress,
	Search_Results,
}

@(private = "file") jobs_lock:     sync.Mutex
@(private = "file") jobs:          [dynamic]Job
@(private = "file") jobs_waiting:  sync.Sema
@(private = "file") messages_lock: sync.Mutex
@(private = "file") messages:      [dynamic]Message

// Worker-side state.
@(private = "file") anchors:      tls.Trust_Anchors
@(private = "file") pack:         Pack
@(private = "file") catalog:      Catalog
@(private = "file") copying_song: int

worker_start :: proc() {
	thread.create_and_start(worker_main)
}

worker_ask :: proc(job: Job) {
	sync.mutex_lock(&jobs_lock)
	append(&jobs, job)
	sync.mutex_unlock(&jobs_lock)
	sync.sema_post(&jobs_waiting)
}

take_messages :: proc(allocator := context.allocator) -> []Message {
	sync.mutex_lock(&messages_lock)
	defer sync.mutex_unlock(&messages_lock)
	taken := make([]Message, len(messages), allocator)
	copy(taken, messages[:])
	clear(&messages)
	return taken
}

@(private = "file")
tell :: proc(message: Message) {
	sync.mutex_lock(&messages_lock)
	append(&messages, message)
	sync.mutex_unlock(&messages_lock)
	android.ALooper_wake(glue.app().looper)
}

@(private = "file")
say_from_worker :: proc(mood: Screen_Mood, first: string, second := "") {
	tell(Say{mood = mood, lines = {strings.clone(first), strings.clone(second)}})
}

@(private = "file")
worker_main :: proc() {
	roots := tls.trust_anchors_add_os(&anchors)
	tls.trust_anchors_seal(&anchors)
	if roots == 0 do say_from_worker(.Bad, "NO TRUSTED CERTIFICATES FOUND ON THIS PHONE", "SECURE DOWNLOADS WILL FAIL")

	for {
		sync.sema_wait(&jobs_waiting)
		sync.mutex_lock(&jobs_lock)
		job := pop_front(&jobs)
		sync.mutex_unlock(&jobs_lock)

		switch j in job {
		case Open_Pack:    do_open_pack(j)
		case Copy_Song:    do_copy_song(j)
		case Load_Catalog: do_load_catalog(j)
		case Search_Packs: do_search(j)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
do_open_pack :: proc(job: Open_Pack) {
	say_from_worker(.Waiting, fmt.tprintf("READING PACK #%d ...", job.id))
	pack_destroy(&pack)
	problem: Pack_Problem
	pack, problem = open_pack(&anchors, job.id)
	if problem.what != "" {
		say_from_worker(.Bad, problem.what, problem.why)
		return
	}
	rows := make([]Song_Row, len(pack.songs))
	for song, i in pack.songs do rows[i] = {name = strings.clone(song.name), bytes = song.bytes, files = len(song.files)}
	tell(Pack_Ready{id = pack.id, name = strings.clone(pack.name), rows = rows})
	say_from_worker(.Good, fmt.tprintf("PACK READ: %d SONGS, %s TO DOWNLOAD IN ALL", len(rows), megabytes(pack.size)), "TAP A SONG TO COPY IT TO THE STICK.")
}

@(private = "file")
do_load_catalog :: proc(job: Load_Catalog) {
	defer delete(job.private_dir)
	say_from_worker(.Waiting, "GETTING THE SITE'S PACK LIST ...")
	from_site, problem := load_catalog(&anchors, &catalog, job.private_dir)
	if problem.what != "" {
		say_from_worker(.Bad, problem.what, problem.why)
		return
	}
	say_from_worker(.Good, fmt.tprintf("%d PACKS ON THE SITE%s. TYPE TO SEARCH.", len(catalog.packs), "" if from_site else " (LIST FROM TODAY)"))
}

@(private = "file")
do_search :: proc(job: Search_Packs) {
	defer delete(job.query)
	// Typing sends a search per letter: skip to the newest one waiting, if any.
	sync.mutex_lock(&jobs_lock)
	for queued in jobs {
		if _, is_search := queued.(Search_Packs); is_search {
			sync.mutex_unlock(&jobs_lock)
			return
		}
	}
	sync.mutex_unlock(&jobs_lock)

	if job.kind != .Pack_Name && strings.trim_space(job.query) != "" do say_from_worker(.Waiting, fmt.tprintf("SEARCHING %sS FOR \"%s\" ...", SEARCH_KIND_LABEL[job.kind], strings.to_upper(job.query, context.temp_allocator)))
	rows, problem := search_packs(&anchors, &catalog, job.kind, job.query)
	tell(Search_Results{stamp = job.stamp, rows = rows})
	if problem.what != "" {
		say_from_worker(.Bad, problem.what, problem.why)
		return
	}
	if job.kind != .Pack_Name && strings.trim_space(job.query) != "" do say_from_worker(.Good, fmt.tprintf("%d SONGS FOUND%s. TAP ONE TO OPEN ITS PACK.", len(rows), " (THE FIRST 200)" if len(rows) == MAX_RESULTS else ""))
}

@(private = "file")
do_copy_song :: proc(job: Copy_Song) {
	defer delete(job.tree)
	if job.index < 0 || job.index >= len(pack.songs) do return
	song := pack.songs[job.index]
	say_from_worker(.Waiting, fmt.tprintf("COPYING %s ...", song.name), "DON'T UNPLUG THE STICK.")

	destination, problem := root_folder(job.tree)
	if problem != "" {
		say_from_worker(.Bad, "COULD NOT OPEN THE STICK'S FOLDER", problem)
		tell(Copy_Progress{song = job.index, finished = true})
		return
	}
	defer delete(destination.document_id)

	copying_song = job.index
	notes, copy_problem := copy_song(&anchors, &pack, job.index, destination, job.options, proc(status: Copy_Status) {
		tell(Copy_Progress{song = copying_song, status = status})
	})
	tell(Copy_Progress{song = job.index, finished = true, sync = notes.sync})
	if copy_problem.what != "" {
		say_from_worker(.Bad, copy_problem.what, copy_problem.why)
		return
	}
	done_line := fmt.tprintf("COPIED %s (%d FILES). SAFE TO UNPLUG THE STICK.", song.name, notes.files)
	if notes.videos_left_out > 0 do done_line = fmt.tprintf("%s %d VIDEO(S) LEFT OUT.", done_line, notes.videos_left_out)
	if notes.length_patched do done_line = fmt.tprintf("%s LENGTH PATCHED: %s NOW READS AS 1:45.", done_line, minutes(notes.real_seconds))
	if notes.patch_failed do done_line = fmt.tprintf("%s ITS OGG COULDN'T BE LENGTH PATCHED.", done_line)
	switch {
	case notes.converted:
		say_from_worker(.Good, done_line, fmt.tprintf("MP3 CONVERTED TO OGG: %s AT %d KBPS.", megabytes(i64(notes.ogg_bytes)), notes.ogg_bitrate / 1000))
	case notes.shrunk:
		say_from_worker(.Good, done_line, fmt.tprintf("ITS OGG WAS OVER THE LIMIT: SHRUNK FROM %s TO %s AT %d KBPS.", megabytes(i64(notes.original_bytes)), megabytes(i64(notes.ogg_bytes)), notes.ogg_bitrate / 1000))
	case notes.missing > 0:
		say_from_worker(.Good, done_line, fmt.tprintf("%d PICTURE(S) THE CHART NAMES WERE NOT IN THE PACK.", notes.missing))
	case:
		say_from_worker(.Good, done_line)
	}
}

// Sizes are shown in decimal megabytes (1 MB = 1,000,000 bytes) everywhere, the audio limit included.
BYTES_PER_MB :: 1_000_000

megabytes :: proc(bytes: i64) -> string {
	return fmt.tprintf("%.1f MB", f64(bytes) / BYTES_PER_MB)
}

// 151.4 -> "2:31"
minutes :: proc(seconds: f64) -> string {
	whole := int(seconds)
	return fmt.tprintf("%d:%02d", whole / 60, whole % 60)
}

megabytes_decimal :: proc(bytes: int) -> string {
	return megabytes(i64(bytes))
}
