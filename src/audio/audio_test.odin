/*
Sync and size tests on the click tracks from tools/make_audio_fixtures.py (run it once first).

Where a click lands after decoding is the whole question. The source clicks are at samples 44100
and 88200. StepMania plays an MP3 with nothing trimmed, so a click comes out later by:
	529    libmad's synthesis delay (fixed by the MP3 format)
	+ 576  LAME's encoder delay
	+ 1152 when the file starts with an "Info" frame, which StepMania plays as a frame of silence
	       (a "Xing" frame is skipped, so it adds nothing)
The converted Ogg must put each click on exactly the same sample as the MP3 decoding does.

Needs Odin's stb_vorbis (vendor/stb/src/build_stb.sh) to play the Ogg back.
*/
package audio

import "core:fmt"
import "core:os"
import "core:testing"
import stb "vendor:stb/vorbis"

FIXTURES :: #directory + "/../../tests/fixtures/"
SOURCE_CLICKS :: [2]int{44100, 88200}
DECODER_DELAY :: 529
LAME_DELAY    :: 576
INFO_FRAME    :: 1152
// One-sample clicks come back as a short ripple after lossy coding; its peak can sit a sample or
// two off the click. 1105 and 2257 samples apart are what is being told apart here.
PEAK_TOLERANCE :: 2

Click_Case :: struct {
	file:  string,
	delay: int,
}

CASES := [?]Click_Case{
	{"click_cbr_info.mp3", DECODER_DELAY + LAME_DELAY + INFO_FRAME},
	{"click_vbr_xing.mp3", DECODER_DELAY + LAME_DELAY},
	{"click_cbr_none.mp3", DECODER_DELAY + LAME_DELAY},
}

load :: proc(t: ^testing.T, name: string) -> []u8 {
	data, err := os.read_entire_file(fmt.tprint(FIXTURES, name, sep = ""), context.temp_allocator)
	testing.expectf(t, err == nil, "missing %s: run tools/make_audio_fixtures.py first", name)
	return data
}

// The loudest sample (first channel) within `window` samples of `around`.
peak_near :: proc(samples: []f32, channels, around, window: int) -> int {
	best, best_value := -1, f32(0)
	for i in max(around - window, 0)..<min(around + window, len(samples) / channels) {
		value := abs(samples[i * channels])
		if value > best_value do best, best_value = i, value
	}
	return best
}

decode_mp3_all :: proc(t: ^testing.T, mp3: []u8) -> (samples: [dynamic]f32, channels: int) {
	d: Mp3_Decoder
	defer mp3_close(&d)
	testing.expect(t, mp3_open(&d, mp3))
	samples = make([dynamic]f32, context.temp_allocator)
	for frame in mp3_next(&d) do append(&samples, ..frame)
	testing.expect(t, d.error == nil)
	return samples, d.channels
}

decode_ogg_all :: proc(t: ^testing.T, ogg: []u8) -> (samples: []f32, channels: int) {
	rate: i32
	pcm: [^]i16
	ch: i32
	frames := stb.decode_memory(raw_data(ogg), i32(len(ogg)), &ch, &rate, &pcm)
	testing.expectf(t, frames > 0, "the Ogg didn't play back (%d)", frames)
	if frames <= 0 do return nil, 0
	samples = make([]f32, int(frames) * int(ch), context.temp_allocator)
	for i in 0..<len(samples) do samples[i] = f32(pcm[i]) / 32768
	return samples, int(ch)
}

@(test)
mp3_clicks_land_where_stepmania_plays_them :: proc(t: ^testing.T) {
	for case_ in CASES {
		samples, channels := decode_mp3_all(t, load(t, case_.file))
		for click in SOURCE_CLICKS {
			expected := click + case_.delay
			found := peak_near(samples[:], channels, expected, 4000)
			testing.expectf(t, abs(found - expected) <= PEAK_TOLERANCE, "%s: click at %d expected near %d, found %d (off by %d)", case_.file, click, expected, found, found - expected)
		}
	}
}

@(test)
ogg_keeps_every_sample_where_the_mp3_had_it :: proc(t: ^testing.T) {
	for case_ in CASES {
		mp3 := load(t, case_.file)
		mp3_samples, mp3_channels := decode_mp3_all(t, mp3)

		result, problem := mp3_to_ogg(mp3, 1_000_000)
		testing.expect_value(t, problem, Convert_Problem.None)
		defer delete(result.ogg)
		ogg_samples, ogg_channels := decode_ogg_all(t, result.ogg)
		testing.expect_value(t, ogg_channels, mp3_channels)

		// Same length to the sample: nothing added at the start or the end.
		testing.expectf(t, len(ogg_samples) == len(mp3_samples), "%s: %d samples in the Ogg, %d from the MP3", case_.file, len(ogg_samples) / ogg_channels, len(mp3_samples) / mp3_channels)
		for click in SOURCE_CLICKS {
			in_mp3 := peak_near(mp3_samples[:], mp3_channels, click + case_.delay, 4000)
			in_ogg := peak_near(ogg_samples, ogg_channels, in_mp3, 4000)
			testing.expectf(t, abs(in_ogg - in_mp3) <= 1, "%s: click on sample %d in the MP3, %d in the Ogg", case_.file, in_mp3, in_ogg)
		}
	}
}

@(test)
ogg_fits_the_size_limit :: proc(t: ^testing.T) {
	mp3 := load(t, "busy.mp3") // 10 s, dense like music
	for target in ([?]int{80_000, 120_000, 240_000}) { // about 64, 96 and 192 kbps
		result, problem := mp3_to_ogg(mp3, target)
		testing.expect_value(t, problem, Convert_Problem.None)
		testing.expectf(t, len(result.ogg) <= target, "limit %d: the Ogg is %d bytes", target, len(result.ogg))
		testing.expectf(t, len(result.ogg) >= target * 7 / 10, "limit %d: the Ogg is only %d bytes (%d bps, %d passes): quality left unused", target, len(result.ogg), result.bitrate, result.passes)
		delete(result.ogg)
	}
}

@(test)
too_long_for_the_limit_says_so :: proc(t: ^testing.T) {
	_, problem := mp3_to_ogg(load(t, "busy.mp3"), 20_000) // 16 kbps: below what Vorbis can do
	testing.expect_value(t, problem, Convert_Problem.Too_Long)
}

@(test)
not_an_mp3_is_refused :: proc(t: ^testing.T) {
	junk := make([]u8, 5000, context.temp_allocator)
	_, problem := mp3_to_ogg(junk, 1_000_000)
	testing.expect_value(t, problem, Convert_Problem.Not_Mp3)
}
