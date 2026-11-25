// The clicks land on their frames, and also when mixed in small pieces as an audio callback does.
package metronome

import "core:testing"
import "../chart"

@(test)
clicks_start_on_their_frames :: proc(t: ^testing.T) {
	ticks := []chart.Tick{{seconds = 0.5, downbeat = true}, {seconds = 1.0}, {seconds = 1.5}}
	RATE :: 44100
	FRAMES :: 70000
	m := metronome_make(ticks, RATE)
	offset := 0.1 // clicks at 0.4, 0.9, 1.4 s
	whole := make([]f32, 2 * FRAMES)
	defer delete(whole)
	mix(&m, whole, 2, 0, offset)
	pieces := make([]f32, 2 * FRAMES)
	defer delete(pieces)
	for first := 0; first < FRAMES; first += 37 { // odd-sized pieces cross every click
		count := min(37, FRAMES - first)
		mix(&m, pieces[2 * first:][:2 * count], 2, i64(first), offset)
	}
	for start in ([?]int{17640, 39690, 61740}) {
		testing.expect(t, whole[2 * (start - 1)] == 0, "silent before the click")
		testing.expect(t, whole[2 * (start + 1)] != 0, "sounding just after its start")
	}
	for v, i in whole do if v != pieces[i] {
		testing.expectf(t, false, "piecewise mixing differs at sample %d", i)
		break
	}
}
