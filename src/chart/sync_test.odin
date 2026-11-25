/*
Sync measurement tests.

A made-up song with drum hits at known times must measure 0 ms, and +9 ms when its chart is moved
9 ms early. The four cab-perfect songs (tests/fixtures/sync/, git-ignored: the user's own files,
skipped when missing) must measure within MATCH_OK_MS, and a chart measured against another song's
audio must come out Unsure.
*/
package chart

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:testing"
import "core:time"
import "../audio"

SYNC_FIXTURES :: #directory + "/../../tests/fixtures/sync/"
MATCH_OK_MS   :: 6.0 // what the app shows with no mark
SYNTH_TOLERANCE_MS :: 0.7

// Drum hits (a noise burst and a low thump) on every beat at 140 BPM from 0.5 s, with soft noise under.
@(private = "file")
synthetic_attacks :: proc() -> audio.Attacks {
	RATE :: 44100
	BPM  :: 140.0
	samples := make([]f32, 60 * RATE)
	defer delete(samples)
	generator := rand.create(1)
	random := rand.default_random_generator(&generator)
	for &s in samples do s = 0.05 * rand.float32_normal(0, 1, random)
	for beat in 0..<130 {
		start := int(math.round((0.5 + f64(beat) * 60 / BPM) * RATE))
		for i in 0..<4000 {
			if start + i >= len(samples) do break
			t := f32(i)
			noise := rand.float32_normal(0, 1, random) * math.exp(-t / 600)
			thump := math.sin(2 * math.PI * 60 * t / RATE) * math.exp(-t / 3000)
			samples[start + i] += 0.5 * (noise + thump)
		}
	}
	builder := audio.attack_builder_make(RATE)
	audio.attack_builder_add(&builder, samples, 1)
	return audio.attack_builder_finish(&builder)
}

@(private = "file")
synthetic_chart :: proc(offset: f64) -> string {
	rows := "1000\n0100\n0010\n0001\n"
	measures := ""
	for i in 0..<32 do measures = fmt.tprintf("%s%s%s", measures, "" if i == 0 else ",\n", rows)
	return fmt.tprintf("#OFFSET:%.4f;\n#BPMS:0.000=140.000;\n#STOPS:;\n#NOTES:\n dance-single:\n x:\n Hard:\n 9:\n 0,0,0,0,0:\n%s;\n", offset, measures)
}

@(private = "file")
measure_chart :: proc(sm: string, attacks: audio.Attacks) -> audio.Match {
	timing, ok := read_timing(sm)
	if !ok do return {}
	defer timing_destroy(&timing)
	notes := note_seconds(sm, timing)
	defer delete(notes)
	return audio.match_notes(attacks, notes)
}

@(test)
synthetic_on_time :: proc(t: ^testing.T) {
	attacks := synthetic_attacks()
	defer audio.attacks_destroy(&attacks)
	m := measure_chart(synthetic_chart(-0.5), attacks)
	fmt.printfln("synthetic: %.2f ms, contrast %.2f, rival %.2f", m.shift * 1000, m.contrast, m.rival)
	testing.expect_value(t, m.state, audio.Match_State.Measured)
	testing.expect(t, abs(m.shift * 1000) < SYNTH_TOLERANCE_MS, fmt.tprintf("on-time chart measured %.2f ms", m.shift * 1000))
}

@(test)
synthetic_notes_early :: proc(t: ^testing.T) {
	attacks := synthetic_attacks()
	defer audio.attacks_destroy(&attacks)
	// OFFSET 9 ms larger: every note 9 ms earlier than its hit.
	m := measure_chart(synthetic_chart(-0.491), attacks)
	testing.expect_value(t, m.state, audio.Match_State.Measured)
	testing.expect(t, abs(m.shift * 1000 - 9) < SYNTH_TOLERANCE_MS, fmt.tprintf("9 ms early chart measured %.2f ms", m.shift * 1000))
}

@(test)
timing_with_tempo_changes_and_stops :: proc(t: ^testing.T) {
	sm := "#OFFSET:0.5;\n#BPMS:0=120,4=60;\n#STOPS:2=0.25;\n"
	timing, ok := read_timing(sm)
	testing.expect(t, ok)
	defer timing_destroy(&timing)
	near :: proc(a, b: f64) -> bool { return abs(a - b) < 1e-9 }
	testing.expect(t, near(beat_seconds(timing, 0), -0.5))
	testing.expect(t, near(beat_seconds(timing, 2), 0.5))   // the stop's own beat: before the halt
	testing.expect(t, near(beat_seconds(timing, 3), 1.25))  // 0.5 s per beat, plus the stop
	testing.expect(t, near(beat_seconds(timing, 5), 2.75))  // 4 beats at 120, then 1 at 60
}

@(private = "file")
CAB_SONGS := [?]string{"doki", "arabian", "turii", "angels"}

@(private = "file")
load_song :: proc(name: string) -> (sm: string, attacks: audio.Attacks, ok: bool) {
	sm_bytes, sm_err := os.read_entire_file(fmt.tprintf("%s%s.sm", SYNC_FIXTURES, name), context.allocator)
	if sm_err != nil do return
	ogg, ogg_err := os.read_entire_file(fmt.tprintf("%s%s.ogg", SYNC_FIXTURES, name), context.allocator)
	if ogg_err != nil {
		delete(sm_bytes)
		return
	}
	defer delete(ogg)
	attacks, ok = audio.ogg_attacks(ogg)
	return string(sm_bytes), attacks, ok
}

@(test)
cab_perfect_songs_measure_in_sync :: proc(t: ^testing.T) {
	for name in CAB_SONGS {
		started := time.tick_now()
		sm, attacks, ok := load_song(name)
		if !ok {
			fmt.printfln("%s: not in tests/fixtures/sync, skipped", name)
			continue
		}
		defer delete(sm)
		defer audio.attacks_destroy(&attacks)
		m := measure_chart(sm, attacks)
		fmt.printfln("%s: %+.1f ms (%v, %d notes, contrast %.2f, rival %.2f) in %v", name, m.shift * 1000, m.state, m.notes, m.contrast, m.rival, time.tick_since(started))
		testing.expect_value(t, m.state, audio.Match_State.Measured)
		testing.expect(t, abs(m.shift * 1000) < MATCH_OK_MS, fmt.tprintf("%s measured %.1f ms", name, m.shift * 1000))
	}
}

@(test)
wrong_audio_is_unsure :: proc(t: ^testing.T) {
	for pair in ([?][2]string{{"turii", "doki"}, {"doki", "angels"}, {"angels", "arabian"}, {"arabian", "turii"}}) {
		sm, attacks, ok := load_song(pair[0])
		if !ok do continue
		defer delete(sm)
		audio.attacks_destroy(&attacks)
		other_sm, other, other_ok := load_song(pair[1])
		if !other_ok do continue
		delete(other_sm)
		defer audio.attacks_destroy(&other)
		m := measure_chart(sm, other)
		fmt.printfln("%s chart on %s audio: %+.1f ms (%v, contrast %.2f, rival %.2f)", pair[0], pair[1], m.shift * 1000, m.state, m.contrast, m.rival)
		testing.expect_value(t, m.state, audio.Match_State.Unsure)
	}
}
