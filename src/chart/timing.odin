/*
A StepMania .sm chart's timing: where each beat falls in the song, and when its notes are.

	timing := read_timing(sm_text)            // #OFFSET, #BPMS, #STOPS
	defer timing_destroy(&timing)
	seconds := beat_seconds(timing, 16)
	notes := note_seconds(sm_text, timing)    // every note of every chart, once per moment (heap)
	ticks := metronome_ticks(sm_text, timing) // every beat up to the last note's, for a metronome (heap)

How StepMania reads it:
	- beat 0 is at -#OFFSET seconds in the song (a negative offset: the music plays first);
	- #BPMS is "beat=bpm" pairs, each tempo holding until the next;
	- #STOPS is "beat=seconds" pairs: at that beat the arrows halt for that long. A note on the stop's
	  own beat comes before the halt.
Measures are split by commas and hold 4 beats, their rows spread evenly over them.
*/
package chart

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

Beat_Value :: struct {
	beat:  f64,
	value: f64, // bpm or seconds
}

Timing :: struct {
	offset: f64,
	bpms:   []Beat_Value, // heap, by beat
	stops:  []Beat_Value, // heap, by beat
}

timing_destroy :: proc(t: ^Timing) {
	delete(t.bpms)
	delete(t.stops)
	t^ = {}
}

read_timing :: proc(sm: string) -> (t: Timing, ok: bool) {
	offset_text, has_offset := tag_value(sm, "OFFSET")
	if has_offset do t.offset, _ = strconv.parse_f64(strings.trim_space(offset_text))
	bpms_text, _ := tag_value(sm, "BPMS")
	stops_text, _ := tag_value(sm, "STOPS")
	t.bpms = beat_values(bpms_text)
	t.stops = beat_values(stops_text)
	if len(t.bpms) == 0 || t.bpms[0].value <= 0 {
		timing_destroy(&t)
		return {}, false
	}
	return t, true
}

beat_seconds :: proc(t: Timing, beat: f64) -> f64 {
	seconds := -t.offset
	for change, i in t.bpms {
		if beat <= change.beat && i > 0 do break
		end := t.bpms[i + 1].beat if i + 1 < len(t.bpms) else max(f64)
		start := change.beat if i > 0 else min(change.beat, 0) // the first tempo also covers beats before it
		seconds += (min(beat, end) - start) * 60 / change.value
	}
	for stop in t.stops {
		if stop.beat < beat - 1e-9 do seconds += stop.value
	}
	return seconds
}

// The moments with a note to step on in any chart (taps, hold and roll heads), in order, each
// moment once. Mines, hold ends and lifts don't count: nothing is stepped on there.
note_seconds :: proc(sm: string, t: Timing, allocator := context.allocator) -> []f64 {
	beats := make([dynamic]f64, context.temp_allocator)
	rest := sm
	for {
		at := index_of_tag(rest, "NOTES")
		if at < 0 do break
		rest = rest[at + len("#NOTES:"):]
		end := strings.index_byte(rest, ';')
		block := rest if end < 0 else rest[:end]
		// type : description : difficulty : meter : radar : notes
		fields := strings.split_n(block, ":", 6, context.temp_allocator)
		if len(fields) == 6 do add_note_beats(&beats, fields[5])
		if end < 0 do break
		rest = rest[end:]
	}
	slice.sort(beats[:])
	seconds := make([dynamic]f64, 0, len(beats), allocator)
	last := min(f64)
	for beat in beats {
		if beat - last < 1e-6 do continue
		last = beat
		append(&seconds, beat_seconds(t, beat))
	}
	return seconds[:]
}

// A metronome's beat: when it falls with #OFFSET 0 (the time with an offset is `seconds - offset`, so
// a player can follow a changing offset), and whether it starts a measure (every 4th beat).
Tick :: struct {
	seconds:  f64,
	downbeat: bool,
}

// Every beat from 0 to the measure after the last note, in any chart.
metronome_ticks :: proc(sm: string, t: Timing, allocator := context.allocator) -> []Tick {
	last := 0.0
	rest := sm
	for {
		at := index_of_tag(rest, "NOTES")
		if at < 0 do break
		rest = rest[at + len("#NOTES:"):]
		end := strings.index_byte(rest, ';')
		block := rest if end < 0 else rest[:end]
		fields := strings.split_n(block, ":", 6, context.temp_allocator)
		if len(fields) == 6 {
			beats := make([dynamic]f64, context.temp_allocator)
			add_note_beats(&beats, fields[5])
			for beat in beats do last = max(last, beat)
		}
		if end < 0 do break
		rest = rest[end:]
	}
	at_zero := t
	at_zero.offset = 0
	count := int(last) / 4 * 4 + 8 // through the next measure
	ticks := make([]Tick, count + 1, allocator)
	for &tick, beat in ticks do tick = {seconds = beat_seconds(at_zero, f64(beat)), downbeat = beat % 4 == 0}
	return ticks
}

@(private = "file")
add_note_beats :: proc(beats: ^[dynamic]f64, notes: string) {
	measure := 0
	rest := notes
	for part in strings.split_iterator(&rest, ",") {
		rows := make([dynamic]string, context.temp_allocator)
		lines := part
		for line in strings.split_lines_iterator(&lines) {
			row := strings.trim_space(strip_comment(line))
			if is_note_row(row) do append(&rows, row)
		}
		for row, i in rows {
			if strings.contains_any(row, "124") do append(beats, 4 * (f64(measure) + f64(i) / f64(len(rows))))
		}
		measure += 1
	}
}

@(private = "file")
is_note_row :: proc(row: string) -> bool {
	if len(row) < 4 do return false
	for c in row do if !strings.contains_rune("01234MLFK", c) do return false
	return true
}

@(private = "file")
strip_comment :: proc(line: string) -> string {
	at := strings.index(line, "//")
	return line if at < 0 else line[:at]
}

// "0.000=140.000,51.500=106.800" (spaces, line breaks and comments allowed), sorted by beat.
@(private = "file")
beat_values :: proc(text: string) -> []Beat_Value {
	out := make([dynamic]Beat_Value)
	rest := text
	for part in strings.split_iterator(&rest, ",") {
		beat_text, _, value_text := strings.partition(strip_comment(part), "=")
		beat, beat_ok := strconv.parse_f64(strings.trim_space(beat_text))
		value, value_ok := strconv.parse_f64(strings.trim_space(value_text))
		if beat_ok && value_ok do append(&out, Beat_Value{beat, value})
	}
	slice.sort_by(out[:], proc(a, b: Beat_Value) -> bool { return a.beat < b.beat })
	return out[:]
}

// A tag's value: the text between "#TAG:" and ";" (tags in any letter case).
tag_value :: proc(sm, tag: string) -> (value: string, found: bool) {
	at := index_of_tag(sm, tag)
	if at < 0 do return "", false
	start := at + len(tag) + 2
	end := strings.index_byte(sm[start:], ';')
	if end < 0 do return sm[start:], true
	return sm[start:][:end], true
}

@(private = "file")
index_of_tag :: proc(sm, tag: string) -> int {
	for i := 0; i + len(tag) + 1 < len(sm); i += 1 {
		if sm[i] != '#' do continue
		if strings.equal_fold(sm[i + 1:][:len(tag)], tag) && sm[i + 1 + len(tag)] == ':' do return i
	}
	return -1
}

// An #OFFSET as StepMania writes it: "0.161", "-4.888"; four decimals when the tenth of a millisecond
// is used ("0.1615"). In temp memory.
format_offset :: proc(offset: f64) -> string {
	text := fmt.tprintf("%.4f", offset)
	if strings.has_suffix(text, "0") do text = text[:len(text) - 1]
	if text == "-0.000" do text = "0.000"
	return text
}
