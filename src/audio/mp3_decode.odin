/*
MP3 decoding that outputs exactly the samples StepMania 5 plays for the same file, so a converted
song keeps its sync. StepMania reads MP3s with libmad (src/RageSoundReader_MP3.cpp); this decodes
the audio with dr_mp3's frame decoder (minimp3's, public domain or MIT-0) and keeps StepMania's and
libmad's rules around it, here in Odin:

	- nothing is trimmed: the decoder's own delay and the encoder's padding are all played;
	- a "Xing" (VBR) info frame at the start is skipped, but an "Info" (CBR) frame is decoded as a
	  frame of audio (silence), as DWI's decoder (BASS) did, so old charts keep their sync;
	- frames that can't be decoded for missing data (their bit reservoir is before the file, e.g. an
	  MP3 cut without re-encoding) still give a frame of silence, as BASS did;
	- ID3v1/ID3v2 tags in the way are skipped; frames whose channel count differs from the first
	  frame's give no samples;
	- frames are found the way libmad finds them (mad_header_decode): a frame is expected right at the
	  start and right after each frame; where none is, an ID3 tag is skipped or the next sync word is
	  searched for, and a frame found by searching counts only if another sync word follows it. Each
	  frame then goes to dr_mp3 exactly as it is, so dr_mp3's own frame search never decides anything.

Not reproduced (libmad checks them, dr_mp3 doesn't; both rare in real files): a frame with a bad CRC
is silenced by libmad, and a frame whose Huffman data is damaged is dropped by libmad.
Before libmad went, this decoder matched it on 15 files to the sample (docs/DESIGN.md, Conversion as built).

	d: Mp3_Decoder
	mp3_open(&d, file_bytes) or_return       // also decodes the first frame
	for samples in mp3_next(&d) { ... }      // interleaved floats, one frame (usually 1152 per channel) at a time
	mp3_close(&d)
*/
package audio

import "core:c"

MP3_MAX_FRAME_SAMPLES :: 1152

Mp3_Decoder :: struct {
	file:        []u8, // not owned
	position:    int,  // where the next frame is expected
	synced:      bool, // libmad's stream->sync
	first_frame: bool,
	dec:         ^Drmp3_Dec,
	channels:    int,
	sample_rate: int,
	pending:     int,  // samples per channel decoded by mp3_open, not yet handed out (-1: none)
	output:      [2 * MP3_MAX_FRAME_SAMPLES]f32,
	error:       cstring, // set when decoding stopped on an error, not at the end
}

mp3_open :: proc(d: ^Mp3_Decoder, file: []u8) -> bool {
	d^ = {file = file, synced = true, first_frame = true, pending = -1} // mad_stream_buffer starts in sync
	d.dec = new(Drmp3_Dec)
	drmp3dec_init(d.dec)
	count, ok := decode_next_frame(d)
	if !ok {
		if d.error == nil do d.error = "no MP3 audio found"
		return false
	}
	d.pending = count
	return true
}

mp3_close :: proc(d: ^Mp3_Decoder) {
	free(d.dec)
	d^ = {}
}

// The next frame's samples, interleaved by channel. ok = false at the end. A frame may give no
// samples (a channel-count change); the caller just carries on.
mp3_next :: proc(d: ^Mp3_Decoder) -> (samples: []f32, ok: bool) {
	count := d.pending
	d.pending = -1
	if count < 0 do count = decode_next_frame(d) or_return
	return d.output[:count * d.channels], true
}

// Finds and decodes the next frame into d.output; its samples per channel (0 for a frame that gives
// none). ok = false at the end of the file.
@(private = "file")
decode_next_frame :: proc(d: ^Mp3_Decoder) -> (count: int, ok: bool) {
	file := d.file
	for {
		if d.synced {
			if d.position >= len(file) do return 0, false
			if !sync_at(file, d.position) {
				// Lost sync: maybe an ID3 tag (StepMania skips it, and libmad expects a frame right after).
				d.synced = false
				if tag := id3_tag_size(file[d.position:]); tag > 0 {
					d.position += tag
					d.synced = true
					continue
				}
				d.position += 1
				continue
			}
		} else {
			found := find_sync(file, d.position)
			if found < 0 do return 0, false
			d.position = found
		}

		header, valid := parse_frame_header(file[d.position:])
		if !valid {
			d.synced = false // a bad header: libmad goes on looking from the next byte
			d.position += 1
			continue
		}
		if header.free_format do return decode_free_format(d)
		if d.position + header.bytes > len(file) do return 0, false // the last frame is cut short: the end
		if !d.synced {
			// A frame found by searching counts only if another frame's sync word follows it.
			if !sync_at(file, d.position + header.bytes) {
				d.position += 1
				continue
			}
			d.synced = true
		}

		frame := file[d.position:][:header.bytes]
		d.position += header.bytes
		return decode_frame_samples(d, frame, header), true
	}
}

@(private = "file")
decode_frame_samples :: proc(d: ^Mp3_Decoder, frame: []u8, header: Frame_Header) -> int {
	info: Drmp3_Frame_Info
	count := int(drmp3dec_decode_frame(d.dec, raw_data(frame), c.int(len(frame)), &d.output[0], &info))
	if d.first_frame {
		d.first_frame = false
		d.channels, d.sample_rate = header.channels, header.sample_rate
		if header.layer == 3 && xing_kind(frame, header) == .Xing do return 0 // an info frame, not audio
	}
	if header.channels != d.channels do return 0
	if count == 0 {
		// The frame's bit reservoir isn't there (before the start of the file): libmad (BADDATAPTR)
		// still plays the frame, as silence.
		count = header.samples
		for &sample in d.output[:count * d.channels] do sample = 0
	}
	return count
}

// A free-format frame (no bitrate in its header) has no length to read: dr_mp3 finds it by
// searching for the next frame, so here it frames the file itself.
@(private = "file")
decode_free_format :: proc(d: ^Mp3_Decoder) -> (count: int, ok: bool) {
	info: Drmp3_Frame_Info
	rest := d.file[d.position:]
	count = int(drmp3dec_decode_frame(d.dec, raw_data(rest), c.int(len(rest)), &d.output[0], &info))
	if info.frame_bytes <= 0 || info.layer == 0 do return 0, false
	d.position += int(info.frame_bytes)
	if d.first_frame {
		d.first_frame = false
		d.channels, d.sample_rate = int(info.channels), int(info.sample_rate)
	}
	if int(info.channels) != d.channels do return 0, true
	return count, true
}

@(private = "file")
sync_at :: proc(file: []u8, at: int) -> bool {
	return at + 1 < len(file) && file[at] == 0xff && file[at + 1] & 0xe0 == 0xe0
}

// mad_stream_sync: the next sync word from `from`, or -1.
@(private = "file")
find_sync :: proc(file: []u8, from: int) -> int {
	for at in from..<len(file) - 1 {
		if file[at] == 0xff && file[at + 1] & 0xe0 == 0xe0 do return at
	}
	return -1
}

Frame_Header :: struct {
	layer:       int, // 1, 2 or 3
	mpeg1:       bool,
	crc:         bool,
	channels:    int,
	sample_rate: int,
	bytes:       int, // the whole frame, header and padding included
	samples:     int, // per channel
	free_format: bool,
}

// An MPEG audio frame header, checked as libmad's decode_header checks it.
parse_frame_header :: proc(b: []u8) -> (h: Frame_Header, ok: bool) {
	if len(b) < 4 do return
	version := (b[1] >> 3) & 3   // 0 MPEG 2.5, 1 reserved, 2 MPEG 2, 3 MPEG 1
	layer_bits := (b[1] >> 1) & 3 // 1 layer III, 2 layer II, 3 layer I
	if version == 1 || layer_bits == 0 do return
	bitrate_index := int(b[2] >> 4)
	rate_index := int(b[2] >> 2) & 3
	if bitrate_index == 15 || rate_index == 3 do return
	if b[3] & 3 == 2 do return // reserved emphasis
	h.layer = 4 - int(layer_bits)
	h.mpeg1 = version == 3
	h.crc = b[1] & 1 == 0
	h.channels = 1 if b[3] >> 6 == 3 else 2
	RATES := [3]int{44100, 48000, 32000}
	h.sample_rate = RATES[rate_index] >> (0 if version == 3 else 1 if version == 2 else uint(2)) // MPEG 2 halves, 2.5 quarters
	switch {
	case h.layer == 1:                h.samples = 384
	case h.layer == 3 && !h.mpeg1:    h.samples = 576
	case:                             h.samples = 1152
	}
	if bitrate_index == 0 {
		h.free_format = true
		return h, true
	}
	BITRATES := [5][15]int{
		{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448}, // MPEG 1 layer I
		{0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384},    // MPEG 1 layer II
		{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320},     // MPEG 1 layer III
		{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256},    // MPEG 2/2.5 layer I
		{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},         // MPEG 2/2.5 layers II, III
	}
	table := h.layer - 1 if h.mpeg1 else (3 if h.layer == 1 else 4)
	bitrate := BITRATES[table][bitrate_index] * 1000
	padding := int(b[2] >> 1) & 1
	if h.layer == 1 {
		h.bytes = (12 * bitrate / h.sample_rate + padding) * 4
	} else {
		h.bytes = h.samples / 8 * bitrate / h.sample_rate + padding // 144 or 72 times bitrate over rate
	}
	return h, h.bytes > 4
}

Xing_Kind :: enum {
	None,
	Xing,
	Info,
}

// Whether a layer III frame holds a complete Xing or Info tag, right after its side information,
// as libmad's ancillary data and StepMania's xing_parse see it.
xing_kind :: proc(frame: []u8, h: Frame_Header) -> Xing_Kind {
	side_info := (17 if h.channels == 1 else 32) if h.mpeg1 else (9 if h.channels == 1 else 17)
	at := 4 + (2 if h.crc else 0) + side_info
	read32 :: proc(b: []u8, at: int) -> u32 { return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]) }
	if at + 8 > len(frame) do return .None
	kind: Xing_Kind
	switch string(frame[at:][:4]) {
	case "Xing": kind = .Xing
	case "Info": kind = .Info
	case:        return .None
	}
	flags := read32(frame, at + 4)
	size := 8
	if flags & 0x1 != 0 do size += 4   // frames
	if flags & 0x2 != 0 do size += 4   // bytes
	if flags & 0x4 != 0 do size += 100 // table of contents
	if flags & 0x8 != 0 do size += 4   // quality
	if at + size > len(frame) do return .None // incomplete: libmad's check fails, so not a tag
	return kind
}

// id3_tag_query: the size of an ID3 tag starting at b[0], or 0.
// ZZ-Attention: StepMania also answers a negative size for an ID3v2 footer and then skips by it,
// which can't do anything sensible; here a footer is simply not skipped.
id3_tag_size :: proc(b: []u8) -> int {
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
