/*
Ogg Vorbis at the best quality that fits a size limit, from an MP3 or from an Ogg that is too big.

	result, problem := mp3_to_ogg(mp3_bytes, target_bytes)
	result, problem := ogg_shrink(ogg_bytes, target_bytes)
	result, problem := mp3_to_ogg(mp3_bytes, target_bytes, on_progress, data) // told how far it got

The source is decoded the way StepMania plays it (mp3_decode.odin, ogg_decode.odin) and every sample
goes into the new Ogg, so the song lines up with the source sample for sample and the chart's #OFFSET
stays right. Vorbis adds no delay of its own: the new Ogg's first sample is the source's first sample.
Shrinking re-encodes lossy audio, so it is only for Oggs over the limit.

The bitrate comes from the limit: bits available over the song's length, minus a margin for Ogg's
own framing. If the file still comes out over the limit, the bitrate is lowered by the overshoot and
the song encoded again (at most MAX_PASSES times). Bitrates are clamped to what libvorbis accepts
for the song's channels and sample rate.
*/
package audio

import "core:c"

MAX_PASSES       :: 4
FRAMING_MARGIN   :: 0.97   // Ogg pages and headers take ~1-2%
HIGHEST_BITRATE  :: 480_000 // libvorbis' top for 44.1/48 kHz stereo; tried downwards until accepted
LOWEST_BITRATE   :: 32_000
RETRY_SHRINK     :: 0.98   // a little under the measured overshoot, so the retry lands inside
REFUSED_MEANS_TOO_LONG :: 64_000 // a refusal below this is libvorbis' floor, not its ceiling

Conversion :: struct {
	ogg:         []u8, // heap; the caller deletes it
	seconds:     f64,
	bitrate:     int,  // the bitrate of the pass that fit
	passes:      int,
	channels:    int,
	sample_rate: int,
}

// Called as encoding goes: `percent` of the current pass (0-100, each value once), `pass` from 1.
// Runs on the converting thread.
Progress_Proc :: #type proc(data: rawptr, percent: int, pass: int)

Convert_Problem :: enum u8 {
	None,
	Not_Mp3,      // no MP3 audio found (or, shrinking, no Ogg Vorbis audio)
	Decode_Error, // decoding stopped on an error part-way
	Too_Long,     // even the lowest bitrate is over the size limit
	Encoder_Refused,
}

Source_Format :: enum u8 {
	Mp3,
	Ogg,
}

mp3_to_ogg :: proc(mp3: []u8, target_bytes: int, on_progress: Progress_Proc = nil, data: rawptr = nil) -> (result: Conversion, problem: Convert_Problem) {
	return to_ogg(.Mp3, mp3, target_bytes, on_progress, data)
}

ogg_shrink :: proc(ogg: []u8, target_bytes: int, on_progress: Progress_Proc = nil, data: rawptr = nil) -> (result: Conversion, problem: Convert_Problem) {
	return to_ogg(.Ogg, ogg, target_bytes, on_progress, data)
}

@(private)
to_ogg :: proc(format: Source_Format, source: []u8, target_bytes: int, on_progress: Progress_Proc, data: rawptr) -> (result: Conversion, problem: Convert_Problem) {
	// Count the samples first: decoding is far faster than encoding, and the bitrate needs the length.
	// (For an Ogg this is also its real length: a length-patched Ogg states a shorter one.)
	frames, channels, rate := count_samples(format, source) or_return
	result.channels, result.sample_rate = channels, rate
	result.seconds = f64(frames) / f64(rate)
	if frames == 0 do return result, .Not_Mp3

	bitrate := clamp(int(f64(target_bytes) * 8 * FRAMING_MARGIN / result.seconds), LOWEST_BITRATE, HIGHEST_BITRATE)
	for pass in 1..=MAX_PASSES {
		report := Progress_Report{on_progress = on_progress, data = data, pass = pass, total_frames = frames, last_percent = -1}
		ogg, used_bitrate, encode_problem := encode_pass(format, source, channels, rate, bitrate, &report)
		if encode_problem != .None do return result, encode_problem
		result.passes = pass
		if len(ogg) <= target_bytes {
			result.ogg, result.bitrate = ogg, used_bitrate
			return result, .None
		}
		delete(ogg)
		if used_bitrate <= LOWEST_BITRATE do return result, .Too_Long
		bitrate = max(int(f64(used_bitrate) * f64(target_bytes) / f64(len(ogg)) * RETRY_SHRINK), LOWEST_BITRATE)
	}
	return result, .Too_Long
}

// Either decoder behind one face.
@(private)
Sample_Source :: struct {
	format: Source_Format,
	mp3:    Mp3_Decoder,
	ogg:    Ogg_Decoder,
}

@(private)
source_open :: proc(s: ^Sample_Source, format: Source_Format, bytes: []u8) -> (channels, rate: int, ok: bool) {
	s.format = format
	switch format {
	case .Mp3:
		ok = mp3_open(&s.mp3, bytes)
		return s.mp3.channels, s.mp3.sample_rate, ok
	case .Ogg:
		ok = ogg_open(&s.ogg, bytes)
		return s.ogg.channels, s.ogg.sample_rate, ok
	}
	return
}

@(private)
source_next :: proc(s: ^Sample_Source) -> ([]f32, bool) {
	switch s.format {
	case .Mp3: return mp3_next(&s.mp3)
	case .Ogg: return ogg_next(&s.ogg)
	}
	return nil, false
}

@(private)
source_failed :: proc(s: ^Sample_Source) -> bool {
	switch s.format {
	case .Mp3: return s.mp3.error != nil
	case .Ogg: return s.ogg.error != nil
	}
	return false
}

@(private)
source_close :: proc(s: ^Sample_Source) {
	switch s.format {
	case .Mp3: mp3_close(&s.mp3)
	case .Ogg: ogg_close(&s.ogg)
	}
}

@(private)
count_samples :: proc(format: Source_Format, bytes: []u8) -> (frames: int, channels: int, rate: int, problem: Convert_Problem) {
	s: Sample_Source
	defer source_close(&s)
	ok: bool
	channels, rate, ok = source_open(&s, format, bytes)
	if !ok do return 0, 0, 0, .Not_Mp3
	for samples in source_next(&s) do frames += len(samples) / channels
	if source_failed(&s) do return 0, 0, 0, .Decode_Error
	return frames, channels, rate, .None
}

@(private)
Progress_Report :: struct {
	on_progress:  Progress_Proc,
	data:         rawptr,
	pass:         int,
	total_frames: int,
	done_frames:  int,
	last_percent: int,
}

@(private)
report_progress :: proc(report: ^Progress_Report, frames: int) {
	report.done_frames += frames
	if report.on_progress == nil || report.total_frames <= 0 do return
	percent := min(report.done_frames * 100 / report.total_frames, 100)
	if percent == report.last_percent do return
	report.last_percent = percent
	report.on_progress(report.data, percent, report.pass)
}

@(private)
encode_pass :: proc(format: Source_Format, source: []u8, channels, rate, wanted_bitrate: int, report: ^Progress_Report) -> (ogg: []u8, bitrate: int, problem: Convert_Problem) {
	info: Vorbis_Info
	vorbis_info_init(&info)
	defer vorbis_info_clear(&info)

	// libvorbis accepts a range of bitrates that depends on channels and rate. Over its top, step
	// down until it accepts. Under its floor (about 45 kbps for 44.1 kHz stereo) the song is simply
	// too long for the limit: going lower isn't possible.
	bitrate = wanted_bitrate
	for vorbis_encode_init(&info, c.long(channels), c.long(rate), -1, c.long(bitrate), -1) != 0 {
		if bitrate < REFUSED_MEANS_TOO_LONG do return nil, bitrate, .Too_Long
		if bitrate <= LOWEST_BITRATE do return nil, bitrate, .Encoder_Refused
		vorbis_info_clear(&info)
		vorbis_info_init(&info)
		bitrate = max(int(f64(bitrate) * 0.9), LOWEST_BITRATE)
	}

	comment: Vorbis_Comment
	vorbis_comment_init(&comment)
	defer vorbis_comment_clear(&comment)
	vorbis_comment_add_tag(&comment, "ENCODER", "A2ITG2")

	dsp: Vorbis_Dsp_State
	block: Vorbis_Block
	vorbis_analysis_init(&dsp, &info)
	defer vorbis_dsp_clear(&dsp)
	vorbis_block_init(&dsp, &block)
	defer vorbis_block_clear(&block)

	stream: Ogg_Stream_State
	ogg_stream_init(&stream, 0x4132_4954) // a fixed serial ("A2IT"): same input, same file
	defer ogg_stream_clear(&stream)

	out := make([dynamic]u8)
	header, comment_header, code_header: Ogg_Packet
	vorbis_analysis_headerout(&dsp, &comment, &header, &comment_header, &code_header)
	ogg_stream_packetin(&stream, &header)
	ogg_stream_packetin(&stream, &comment_header)
	ogg_stream_packetin(&stream, &code_header)
	page: Ogg_Page
	for ogg_stream_flush(&stream, &page) != 0 do append_page(&out, &page) // audio starts on a fresh page

	s: Sample_Source
	defer source_close(&s)
	if _, _, ok := source_open(&s, format, source); !ok {
		delete(out)
		return nil, bitrate, .Not_Mp3
	}
	for samples in source_next(&s) {
		count := len(samples) / channels
		if count == 0 do continue
		buffer := vorbis_analysis_buffer(&dsp, c.int(count))
		for channel in 0..<channels {
			destination := buffer[channel]
			for i in 0..<count do destination[i] = samples[i * channels + channel]
		}
		vorbis_analysis_wrote(&dsp, c.int(count))
		drain(&dsp, &block, &stream, &out)
		report_progress(report, count)
	}
	vorbis_analysis_wrote(&dsp, 0) // the end of the song
	drain(&dsp, &block, &stream, &out)
	for ogg_stream_flush(&stream, &page) != 0 do append_page(&out, &page)
	return out[:], bitrate, .None
}

// Everything libvorbis has ready, into Ogg pages.
@(private)
drain :: proc(dsp: ^Vorbis_Dsp_State, block: ^Vorbis_Block, stream: ^Ogg_Stream_State, out: ^[dynamic]u8) {
	packet: Ogg_Packet
	page: Ogg_Page
	for vorbis_analysis_blockout(dsp, block) == 1 {
		vorbis_analysis(block, nil)
		vorbis_bitrate_addblock(block)
		for vorbis_bitrate_flushpacket(dsp, &packet) == 1 {
			ogg_stream_packetin(stream, &packet)
			for ogg_stream_pageout(stream, &page) != 0 do append_page(out, &page)
		}
	}
}

@(private)
append_page :: proc(out: ^[dynamic]u8, page: ^Ogg_Page) {
	append(out, ..page.header[:page.header_len])
	append(out, ..page.body[:page.body_len])
}

