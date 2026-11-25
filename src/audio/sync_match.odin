/*
How far a chart's notes sit from the music's attacks (attacks.odin).

	result := match_notes(attacks, note_seconds)

Every shift from -MATCH_SPAN to +MATCH_SPAN is tried: the notes are moved by it and the attack
strength at each note averaged. The shift with the most strength is where the music's attacks are,
seen from the notes. A positive shift means the music comes later than the notes: the notes are
early.

The measurement reads attacks MATCH_BIAS too early (a known click track measures that much off; see
the tests), which is added back.

It is not always trustworthy: soft or ambient music has few clear attacks, and a chart can follow
something other than the beat. The result is Unsure when
	- there are too few notes (MATCH_MIN_NOTES),
	- the best shift barely stands out from the average shift (MATCH_MIN_CONTRAST), or
	- another shift, at least MATCH_RIVAL_DISTANCE away, comes close to the best (MATCH_RIVAL_RATIO).
*/
package audio

import "core:math"
import "core:slice"

MATCH_SPAN           :: 0.100  // seconds each way
MATCH_STEP           :: 0.0005
MATCH_EDGE           :: 0.2    // notes this close to either end of the song are left out
MATCH_BIAS           :: 0.0029 // seconds the attacks read early (measured on a known click track)
MATCH_MIN_NOTES      :: 32
MATCH_MIN_CONTRAST   :: 2.5    // best / average over all shifts (in sync: 5.7+; wrong audio: 1.4 at most)
MATCH_RIVAL_DISTANCE :: 0.020
MATCH_RIVAL_RATIO    :: 0.85   // a rival at this share of the best makes it unsure

Match_State :: enum u8 {
	Unmeasured,
	Measured,
	Unsure,
}

Match :: struct {
	state:    Match_State,
	shift:    f64, // seconds the music sits after the notes (+: notes early)
	notes:    int, // notes used
	contrast: f64, // best / average strength (what MATCH_MIN_CONTRAST checks)
	rival:    f64, // the best rival's share of the best (what MATCH_RIVAL_RATIO checks)
}

match_notes :: proc(attacks: Attacks, note_seconds: []f64) -> Match {
	used := make([dynamic]f64, 0, len(note_seconds), context.temp_allocator)
	for t in note_seconds {
		if t > MATCH_EDGE && t < attacks.song_seconds - MATCH_EDGE do append(&used, t)
	}
	result := Match{state = .Unsure, notes = len(used)}
	if len(used) < MATCH_MIN_NOTES || len(attacks.strength) == 0 do return result

	steps := int(math.round(MATCH_SPAN / MATCH_STEP))
	scores := make([]f64, 2 * steps + 1, context.temp_allocator)
	for &score, i in scores {
		shift := f64(i - steps) * MATCH_STEP
		sum: f64
		for t in used do sum += strength_at(attacks, t + shift)
		score = sum / f64(len(used))
	}

	best := 0
	for score, i in scores do if score > scores[best] do best = i
	average := math.sum(scores) / f64(len(scores))
	if scores[best] <= 0 || average <= 0 do return result

	// The best local peak at least MATCH_RIVAL_DISTANCE away.
	rival: f64
	apart := int(math.round(MATCH_RIVAL_DISTANCE / MATCH_STEP))
	for i in 1..<len(scores) - 1 {
		if abs(i - best) < apart do continue
		if scores[i] >= scores[i - 1] && scores[i] >= scores[i + 1] do rival = max(rival, scores[i])
	}

	// Between steps: the top of a parabola through the best and its neighbours.
	refine: f64
	if best > 0 && best < len(scores) - 1 {
		a, b, c := scores[best - 1], scores[best], scores[best + 1]
		curve := a - 2 * b + c
		if curve != 0 do refine = 0.5 * (a - c) / curve
	}
	result.shift = (f64(best - steps) + refine) * MATCH_STEP + MATCH_BIAS
	result.contrast = scores[best] / average
	result.rival = rival / scores[best]
	at_edge := best == 0 || best == len(scores) - 1
	if result.contrast >= MATCH_MIN_CONTRAST && result.rival < MATCH_RIVAL_RATIO && !at_edge do result.state = .Measured
	return result
}

// The strength at a time, between its two nearest samples.
@(private = "file")
strength_at :: proc(a: Attacks, seconds: f64) -> f64 {
	position := (seconds - a.first_seconds) / a.step_seconds
	if position <= 0 do return f64(a.strength[0])
	i := int(position)
	if i >= len(a.strength) - 1 do return f64(slice.last(a.strength))
	fraction := position - f64(i)
	return f64(a.strength[i]) * (1 - fraction) + f64(a.strength[i + 1]) * fraction
}
