/*
A metronome mixed into a song as it plays: a click on every beat of the chart, a higher one on each
measure's first beat. Allocation-free and lock-free once made, so it can run in an audio callback.

	m := metronome_make(ticks, sample_rate)      // ticks from chart.metronome_ticks (at #OFFSET 0)
	mix(&m, out, channels, first_frame, offset, volume)  // out: interleaved; first_frame: the song's frame
	                                                      // at out[0]; volume 1 = CLICK_LOUDNESS

A tick's click starts on frame round((tick.seconds - offset) * rate) exactly. While clicks sound the
music is lowered by DUCK_GAIN, so the clicks cut through a loud mix; the dip follows the click's own
envelope, so between beats the music plays at full level.
*/
package metronome

import "core:math"
import "../chart"

CLICK_FRAMES   :: 2048  // 46 ms at 44.1 kHz: longer than the click's audible tail
CLICK_HZ       :: 1000
DOWNBEAT_HZ    :: 1500
CLICK_DECAY    :: 0.012 // seconds for the click to fall to 1/e
CLICK_LOUDNESS :: 0.9
DUCK_GAIN      :: 0.35  // the music's level at the click's start

Metronome :: struct {
	ticks:    []chart.Tick, // not owned
	rate:     f64,
	envelope: [CLICK_FRAMES]f32, // 1 at the start, fading
	tone:     [2][CLICK_FRAMES]f32, // beat, downbeat; envelope included
}

metronome_make :: proc(ticks: []chart.Tick, rate: int) -> (m: Metronome) {
	m.ticks, m.rate = ticks, f64(max(rate, 1))
	for i in 0..<CLICK_FRAMES {
		t := f64(i) / m.rate
		m.envelope[i] = f32(math.exp(-t / CLICK_DECAY))
		for kind in 0..<2 {
			hz := f64(DOWNBEAT_HZ if kind == 1 else CLICK_HZ)
			m.tone[kind][i] = f32(CLICK_LOUDNESS * math.sin(2 * math.PI * hz * t)) * m.envelope[i]
		}
	}
	return
}

click_frame :: proc "contextless" (m: ^Metronome, tick: chart.Tick, offset: f64) -> i64 {
	return i64(math.round((tick.seconds - offset) * m.rate))
}

// Adds the clicks that sound in `out` (len(out)/channels frames from the song's `first_frame`).
mix :: proc "contextless" (m: ^Metronome, out: []f32, channels: int, first_frame: i64, offset: f64, volume: f32 = 1) {
	if len(m.ticks) == 0 || channels <= 0 do return
	last := first_frame + i64(len(out) / channels)
	// The first tick whose click still sounds at first_frame.
	low, high := 0, len(m.ticks)
	for low < high {
		middle := (low + high) / 2
		if click_frame(m, m.ticks[middle], offset) + CLICK_FRAMES <= first_frame {
			low = middle + 1
		} else {
			high = middle
		}
	}
	for tick in m.ticks[low:] {
		start := click_frame(m, tick, offset)
		if start >= last do break
		tone := &m.tone[1 if tick.downbeat else 0]
		for frame in max(start, first_frame)..<min(start + CLICK_FRAMES, last) {
			k := frame - start
			duck := 1 - (1 - DUCK_GAIN) * m.envelope[k]
			at := int(frame - first_frame) * channels
			click := tone[k] * volume
			for c in 0..<channels do out[at + c] = clamp(out[at + c] * duck + click, -1, 1)
		}
	}
}
