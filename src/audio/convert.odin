/*
MP3 to Ogg Vorbis at the best quality that fits a size limit.

	result, problem := mp3_to_ogg(mp3_bytes, target_bytes)

The MP3 is decoded the way StepMania plays it (mp3_decode.odin) and every sample goes into the Ogg,
so the song lines up with the MP3 sample for sample and the chart's #OFFSET stays right. Vorbis adds
no delay of its own: the Ogg's first sample is the MP3's first sample.

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

Convert_Problem :: enum u8 {
	None,
	Not_Mp3,      // no MP3 audio found
	Decode_Error, // decoding stopped on an error part-way
	Too_Long,     // even the lowest bitrate is over the size limit
	Encoder_Refused,
}

mp3_to_ogg :: proc(mp3: []u8, target_bytes: int) -> (result: Conversion, problem: Convert_Problem) {
	// Count the samples first: decoding is far faster than encoding, and the bitrate needs the length.
	frames, channels, rate := count_samples(mp3) or_return
	result.channels, result.sample_rate = channels, rate
	result.seconds = f64(frames) / f64(rate)
	if frames == 0 do return result, .Not_Mp3

	bitrate := clamp(int(f64(target_bytes) * 8 * FRAMING_MARGIN / result.seconds), LOWEST_BITRATE, HIGHEST_BITRATE)
	for pass in 1..=MAX_PASSES {
		ogg, used_bitrate, encode_problem := encode_pass(mp3, channels, rate, bitrate)
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

@(private)
count_samples :: proc(mp3: []u8) -> (frames: int, channels: int, rate: int, problem: Convert_Problem) {
	d: Mp3_Decoder
	defer mp3_close(&d)
	if !mp3_open(&d, mp3) do return 0, 0, 0, .Not_Mp3
	for samples in mp3_next(&d) do frames += len(samples) / d.channels
	if d.error != nil do return 0, 0, 0, .Decode_Error
	return frames, d.channels, d.sample_rate, .None
}

@(private)
encode_pass :: proc(mp3: []u8, channels, rate, wanted_bitrate: int) -> (ogg: []u8, bitrate: int, problem: Convert_Problem) {
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

	d: Mp3_Decoder
	defer mp3_close(&d)
	if !mp3_open(&d, mp3) {
		delete(out)
		return nil, bitrate, .Not_Mp3
	}
	for samples in mp3_next(&d) {
		count := len(samples) / channels
		if count == 0 do continue
		buffer := vorbis_analysis_buffer(&dsp, c.int(count))
		for channel in 0..<channels {
			destination := buffer[channel]
			for i in 0..<count do destination[i] = samples[i * channels + channel]
		}
		vorbis_analysis_wrote(&dsp, c.int(count))
		drain(&dsp, &block, &stream, &out)
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

