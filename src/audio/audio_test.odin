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

@(test)
progress_climbs_to_100_in_order :: proc(t: ^testing.T) {
	seen := make([dynamic]int, context.temp_allocator)
	result, problem := mp3_to_ogg(load(t, "busy.mp3"), 1_000_000, proc(data: rawptr, percent, pass: int) {
		append((^[dynamic]int)(data), percent)
	}, &seen)
	defer delete(result.ogg)
	testing.expect_value(t, problem, Convert_Problem.None)
	testing.expect(t, len(seen) > 50) // a 10 s song reports most percents
	testing.expect_value(t, seen[len(seen) - 1], 100)
	for i in 1..<len(seen) do testing.expectf(t, seen[i] > seen[i - 1], "percent went %d then %d", seen[i - 1], seen[i])
}

// Ogg's page checksum written out independently of libogg (CRC-32, polynomial 0x04c11db7, no
// reflection, starting at 0, over the page with its checksum field zeroed).
ogg_crc :: proc(page: []u8) -> u32 {
	crc: u32
	for i in 0..<len(page) {
		b := page[i] if i < 22 || i > 25 else 0
		crc ~= u32(b) << 24
		for _ in 0..<8 do crc = (crc << 1) ~ 0x04c11db7 if crc & 0x80000000 != 0 else crc << 1
	}
	return crc
}

// Every page's stored checksum matches, and the number of pages.
check_all_pages :: proc(t: ^testing.T, ogg: []u8) -> (pages: int) {
	at := 0
	for at < len(ogg) {
		segments := int(ogg[at + 26])
		body := 0
		for size in ogg[at + 27:][:segments] do body += int(size)
		end := at + 27 + segments + body
		stored := u32(ogg[at+22]) | u32(ogg[at+23]) << 8 | u32(ogg[at+24]) << 16 | u32(ogg[at+25]) << 24
		testing.expectf(t, stored == ogg_crc(ogg[at:end]), "page %d: checksum %x, should be %x", pages, stored, ogg_crc(ogg[at:end]))
		pages += 1
		at = end
	}
	return
}

@(test)
length_patch_sets_the_reported_length :: proc(t: ^testing.T) {
	result, problem := mp3_to_ogg(load(t, "busy.mp3"), 1_000_000) // 10 s
	defer delete(result.ogg)
	testing.expect_value(t, problem, Convert_Problem.None)
	original := make([]u8, len(result.ogg), context.temp_allocator)
	copy(original, result.ogg)

	// The real rule (over 1:45) leaves a 10-second song alone, byte for byte.
	untouched := ogg_length_patch(result.ogg)
	testing.expect(t, !untouched.patched)
	testing.expect(t, abs(untouched.reported_seconds - result.seconds) < 0.01)
	testing.expect(t, string(result.ogg) == string(original))

	// Scaled down (over 8 s, patch to 5 s) so a short test file exercises it.
	patch := ogg_length_patch(result.ogg, patched_seconds = 5, if_longer_than = 8)
	testing.expect_value(t, patch.problem, Patch_Problem.None)
	testing.expect(t, patch.patched)

	// Read back by a different Ogg reader: the length a player reads is now 5 s.
	error: stb.Error
	reader := stb.open_memory(raw_data(result.ogg), i32(len(result.ogg)), &error, nil)
	testing.expect(t, reader != nil)
	if reader != nil {
		testing.expect_value(t, int(stb.stream_length_in_samples(reader)), 5 * result.sample_rate)
		stb.close(reader)
	}
	check_all_pages(t, result.ogg)

	// Only the last page's granule and checksum changed: 12 bytes at most.
	changed := 0
	for i in 0..<len(original) do if original[i] != result.ogg[i] do changed += 1
	testing.expectf(t, changed > 0 && changed <= 12, "%d bytes changed", changed)
}

@(test)
length_patch_refuses_what_isnt_ogg_vorbis :: proc(t: ^testing.T) {
	junk := make([]u8, 1000, context.temp_allocator)
	testing.expect_value(t, ogg_length_patch(junk).problem, Patch_Problem.Not_Ogg_Vorbis)
	mp3 := load(t, "busy.mp3")
	testing.expect_value(t, ogg_length_patch(mp3).problem, Patch_Problem.Not_Ogg_Vorbis)
}

@(test)
length_patch_leaves_the_audio_and_sync_alone :: proc(t: ^testing.T) {
	mp3 := load(t, "click_cbr_info.mp3") // 3 s, clicks at known samples
	result, problem := mp3_to_ogg(mp3, 1_000_000)
	defer delete(result.ogg)
	testing.expect_value(t, problem, Convert_Problem.None)
	before, channels := decode_ogg_all(t, result.ogg)

	// Patched to read as 2 s: an end-of-song change on a song that lasts longer.
	patch := ogg_length_patch(result.ogg, patched_seconds = 2, if_longer_than = 1)
	testing.expect(t, patch.patched)
	after, _ := decode_ogg_all(t, result.ogg)

	// Every sample a player decodes up to the stated length is the same, so the clicks (and the
	// chart's sync) sit exactly where they were.
	compared := min(len(before), len(after), 2 * result.sample_rate * channels)
	same := true
	for i in 0..<compared do if before[i] != after[i] {
		same = false
		testing.expectf(t, false, "sample %d differs after patching", i / channels)
		break
	}
	testing.expect(t, same)
	click := peak_near(after, channels, 44100 + DECODER_DELAY + LAME_DELAY + INFO_FRAME, 4000)
	testing.expectf(t, abs(click - (44100 + DECODER_DELAY + LAME_DELAY + INFO_FRAME)) <= PEAK_TOLERANCE, "first click moved to %d", click)
	// Past the stated length a player may keep going: stb_vorbis plays on and drops only the last
	// block (576 samples here), since it takes the last page's granule as "trim this page".
	fmt.printfln("length patch: %d samples decoded before patching, %d after (patched to %d)", len(before) / channels, len(after) / channels, 2 * result.sample_rate)
}

decode_with_our_ogg_decoder :: proc(t: ^testing.T, ogg: []u8) -> (samples: [dynamic]f32, channels: int) {
	d: Ogg_Decoder
	defer ogg_close(&d)
	testing.expect(t, ogg_open(&d, ogg))
	samples = make([dynamic]f32, context.temp_allocator)
	for block in ogg_next(&d) do append(&samples, ..block)
	testing.expect(t, d.error == nil)
	return samples, d.channels
}

// A big Ogg to shrink: the click track converted at the encoder's top bitrate.
big_ogg :: proc(t: ^testing.T, mp3_name: string) -> []u8 {
	result, problem := mp3_to_ogg(load(t, mp3_name), 10_000_000)
	testing.expect_value(t, problem, Convert_Problem.None)
	return result.ogg
}

@(test)
shrinking_an_ogg_keeps_every_sample_in_place :: proc(t: ^testing.T) {
	source := big_ogg(t, "click_cbr_info.mp3")
	defer delete(source)
	before, channels := decode_with_our_ogg_decoder(t, source)

	// About 96 kbps for 3 s. (A click track is almost all silence, so its Ogg is small at any bitrate;
	// this test is about timing, shrinking_meets_the_size_limit about size.)
	result, problem := ogg_shrink(source, 36_000)
	defer delete(result.ogg)
	testing.expect_value(t, problem, Convert_Problem.None)

	ours, _ := decode_with_our_ogg_decoder(t, result.ogg)
	theirs, _ := decode_ogg_all(t, result.ogg) // stb_vorbis: an independent decoder
	testing.expectf(t, len(ours) == len(before), "%d samples after shrinking, %d before", len(ours) / channels, len(before) / channels)
	testing.expectf(t, len(theirs) == len(before), "stb_vorbis reads %d samples, %d before", len(theirs) / channels, len(before) / channels)
	for click in SOURCE_CLICKS {
		at := click + DECODER_DELAY + LAME_DELAY + INFO_FRAME
		in_source := peak_near(before[:], channels, at, 4000)
		in_shrunk := peak_near(theirs, channels, in_source, 4000)
		testing.expectf(t, abs(in_source - at) <= PEAK_TOLERANCE, "click at %d in the source Ogg, expected %d", in_source, at)
		testing.expectf(t, abs(in_shrunk - in_source) <= 1, "click on sample %d before shrinking, %d after", in_source, in_shrunk)
	}
}

@(test)
shrinking_meets_the_size_limit :: proc(t: ^testing.T) {
	source := big_ogg(t, "busy.mp3")
	defer delete(source)
	for target in ([?]int{80_000, 120_000, 240_000}) {
		result, problem := ogg_shrink(source, target)
		testing.expect_value(t, problem, Convert_Problem.None)
		testing.expectf(t, len(result.ogg) <= target && len(result.ogg) >= target * 7 / 10, "limit %d: %d bytes", target, len(result.ogg))
		delete(result.ogg)
	}
}

@(test)
shrinking_a_length_patched_ogg_keeps_the_whole_song :: proc(t: ^testing.T) {
	source := big_ogg(t, "busy.mp3") // 10 s
	defer delete(source)
	ogg_length_patch(source, patched_seconds = 5, if_longer_than = 8) // now states 5 s
	result, problem := ogg_shrink(source, 120_000)
	defer delete(result.ogg)
	testing.expect_value(t, problem, Convert_Problem.None)
	// The real length, not the stated one: the patch doesn't cut the song short.
	testing.expectf(t, result.seconds > 9.9, "shrunk song lasts %.2f s", result.seconds)
	stated, ok := ogg_reported_seconds(result.ogg)
	testing.expect(t, ok)
	testing.expectf(t, stated > 9.9, "the shrunk Ogg states %.2f s (it is unpatched until the copy patches it)", stated)
}

@(test)
patched_oggs_are_recognised :: proc(t: ^testing.T) {
	ogg := big_ogg(t, "busy.mp3")
	defer delete(ogg)
	testing.expect(t, ogg_stated_length_is_real(ogg))
	ogg_length_patch(ogg, patched_seconds = 5, if_longer_than = 8)
	testing.expect(t, !ogg_stated_length_is_real(ogg))
}
