/*
MP3 decoding that outputs exactly the samples StepMania 5 plays for the same file, so a converted
song keeps its sync. A port of the decoding loop in StepMania's src/RageSoundReader_MP3.cpp
(do_mad_frame_decode, handle_first_frame, synth_output, xing_parse, id3_tag_query), on libmad 0.15.1b
built as StepMania builds it:

	- nothing is trimmed: the decoder's own delay and the encoder's padding are all played;
	- a "Xing" (VBR) info frame at the start is skipped, but an "Info" (CBR) frame is decoded as a
	  frame of audio (silence), as DWI's decoder (BASS) did, so old charts keep their sync;
	- frames that can't be decoded for missing data (BADDATAPTR, e.g. an MP3 cut without
	  re-encoding) still give their samples, as BASS did;
	- ID3v1/ID3v2 tags in the way are skipped; frames whose channel count differs from the first
	  frame's give no samples.

	d: Mp3_Decoder
	mp3_open(&d, file_bytes) or_return       // also decodes the first frame
	for samples in mp3_next(&d) { ... }      // interleaved floats, one frame (usually 1152 per channel) at a time
	mp3_close(&d)
*/
package audio

import "core:c"

Mp3_Decoder :: struct {
	input:       []u8, // the file plus MAD_BUFFER_GUARD zero bytes
	stream:      ^Mad_Stream,
	frame:       ^Mad_Frame,
	synth:       ^Mad_Synth,
	first_frame: bool,
	pending:     bool, // a decoded frame not yet synthesized
	channels:    int,
	sample_rate: int,
	output:      [2 * 1152]f32,
	error:       cstring, // set when decoding stopped on an error, not at the end
}

Decode_Result :: enum {
	Frame,
	End,
	Error,
}

mp3_open :: proc(d: ^Mp3_Decoder, file: []u8) -> bool {
	d.input = make([]u8, len(file) + MAD_BUFFER_GUARD)
	copy(d.input, file)
	d.stream = new(Mad_Stream)
	d.frame = new(Mad_Frame)
	d.synth = new(Mad_Synth)
	mad_stream_init(d.stream)
	mad_frame_init(d.frame)
	mad_synth_init(d.synth)
	mad_frame_mute(d.frame)
	mad_stream_buffer(d.stream, raw_data(d.input), c.ulong(len(d.input)))
	d.first_frame = true

	if decode_frame(d) != .Frame {
		if d.error == nil do d.error = "no MP3 audio found"
		return false
	}
	d.sample_rate = int(d.frame.header.samplerate)
	d.channels = mad_channels(&d.frame.header)
	d.pending = true
	return true
}

mp3_close :: proc(d: ^Mp3_Decoder) {
	if d.stream != nil {
		mad_frame_finish(d.frame)
		mad_stream_finish(d.stream)
	}
	free(d.stream)
	free(d.frame)
	free(d.synth)
	delete(d.input)
	d^ = {}
}

// The next frame's samples, interleaved by channel. ok = false at the end (or on an error: see
// d.error). A frame may give no samples (a channel-count change); the caller just carries on.
mp3_next :: proc(d: ^Mp3_Decoder) -> (samples: []f32, ok: bool) {
	if !d.pending {
		if decode_frame(d) != .Frame do return nil, false
	}
	d.pending = false
	return synth_output(d), true
}

// do_mad_frame_decode, for a decoder that has the whole file: running out of input is the end.
@(private)
decode_frame :: proc(d: ^Mp3_Decoder) -> Decode_Result {
	stream := d.stream
	for {
		result := mad_frame_decode(d.frame, stream)

		if result == -1 && (stream.error == .BUFLEN || stream.error == .BUFPTR) {
			return .End
		}

		if result == -1 && stream.error == .LOSTSYNC {
			// This might be an ID3 tag.
			if tag_size := id3_tag_size(stream.this_frame, stream.bufend); tag_size > 0 {
				mad_stream_skip(stream, c.ulong(tag_size))
				continue
			}
		}

		if result == -1 && stream.error == .BADDATAPTR {
			// The frame refers to data that isn't there; BASS plays it as silence. Pretend success.
			result = 0
		}

		if result == 0 {
			if d.first_frame {
				if handle_first_frame(d) do continue // a Xing tag: not audio
				d.first_frame = false
			}
			return .Frame
		}

		if stream.error == .BADCRC {
			mad_frame_mute(d.frame)
			mad_synth_mute(d.synth)
			continue
		}

		if !mad_recoverable(stream.error) {
			d.error = mad_stream_errorstr(stream)
			return .Error
		}
		// Recoverable (lost sync, a damaged frame): libmad moves on to the next frame.
	}
}

// True when the first frame is a Xing tag (skipped). An Info tag is false on purpose: StepMania
// decodes it as audio to match DWI's sync.
@(private)
handle_first_frame :: proc(d: ^Mp3_Decoder) -> bool {
	kind, found := xing_parse(d.stream.anc_ptr, d.stream.anc_bitlen)
	return found && kind == .Xing
}

@(private)
synth_output :: proc(d: ^Mp3_Decoder) -> []f32 {
	if mad_channels(&d.frame.header) != d.channels do return nil
	mad_synth_frame(d.synth, d.frame)
	pcm := &d.synth.pcm
	count := int(pcm.length)
	for i in 0..<count {
		for channel in 0..<d.channels {
			d.output[i * d.channels + channel] = f32(f64(pcm.samples[channel][i]) / (1 << MAD_F_FRACBITS))
		}
	}
	return d.output[:count * d.channels]
}

Xing_Kind :: enum {
	Xing,
	Info,
}

// xing_parse: whether the frame's ancillary bits hold a complete Xing or Info tag.
@(private)
xing_parse :: proc(ptr: Mad_Bitptr, bit_length: c.uint) -> (kind: Xing_Kind, ok: bool) {
	XING_MAGIC :: u32('X') << 24 | u32('i') << 16 | u32('n') << 8 | u32('g')
	INFO_MAGIC :: u32('I') << 24 | u32('n') << 16 | u32('f') << 8 | u32('o')
	XING_FRAMES :: 0x1
	XING_BYTES  :: 0x2
	XING_TOC    :: 0x4
	XING_SCALE  :: 0x8

	ptr := ptr
	bits := bit_length
	if bits < 64 do return
	switch u32(mad_bit_read(&ptr, 32)) {
	case XING_MAGIC: kind = .Xing
	case INFO_MAGIC: kind = .Info
	case:            return
	}
	flags := u32(mad_bit_read(&ptr, 32))
	bits -= 64
	if flags & XING_FRAMES != 0 {
		if bits < 32 do return
		mad_bit_read(&ptr, 32)
		bits -= 32
	}
	if flags & XING_BYTES != 0 {
		if bits < 32 do return
		mad_bit_read(&ptr, 32)
		bits -= 32
	}
	if flags & XING_TOC != 0 {
		if bits < 800 do return
		for _ in 0..<100 do mad_bit_read(&ptr, 8)
		bits -= 800
	}
	if flags & XING_SCALE != 0 {
		if bits < 32 do return
		mad_bit_read(&ptr, 32)
		bits -= 32
	}
	return kind, true
}

// id3_tag_query: the size of an ID3 tag starting at `data`, or 0.
// ZZ-Attention: StepMania also answers a negative size for an ID3v2 footer and then skips by it,
// which can't do anything sensible; here a footer is simply not skipped.
@(private)
id3_tag_size :: proc(data, end: [^]u8) -> int {
	if data == nil do return 0
	length := int(uintptr(end) - uintptr(data))
	b := data[:max(length, 0)]
	if len(b) >= 3 && b[0] == 'T' && b[1] == 'A' && b[2] == 'G' do return 128
	if len(b) >= 10 && b[0] == 'I' && b[1] == 'D' && b[2] == '3' &&
	   b[3] < 0xff && b[4] < 0xff && b[6] < 0x80 && b[7] < 0x80 && b[8] < 0x80 && b[9] < 0x80 {
		FOOTER_PRESENT :: 0x10
		size := int(b[6]) << 21 | int(b[7]) << 14 | int(b[8]) << 7 | int(b[9])
		if b[5] & FOOTER_PRESENT != 0 do size += 10
		return 10 + size
	}
	return 0
}
