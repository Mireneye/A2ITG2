/*
Ogg Vorbis decoding that outputs the samples StepMania 5 plays for the same file. A port of the read
loop in StepMania's src/RageSoundReader_Vorbisfile.cpp, on the vorbisfile StepMania builds:

	- decoding is libvorbisfile's ov_read_float, from wherever ov_pcm_tell starts;
	- when the decoder's position jumps ahead of what was read (a hole or damage in the file),
	  silence fills the gap, so later audio stays in sync;
	- a jump backwards is ignored; OV_HOLE is skipped; a change of channel count stops decoding.

	d: Ogg_Decoder
	ogg_open(&d, file_bytes) or_return
	for samples in ogg_next(&d) { ... }  // interleaved floats
	ogg_close(&d)
*/
package audio

import "core:c"

OGG_READ_FRAMES :: 1024 // frames asked for per read (StepMania reads in blocks too; the size doesn't change the output)

Ogg_Decoder :: struct {
	file:        ^OggVorbis_File,
	source:      ^Memory_Source,
	channels:    int,
	sample_rate: int,
	read_offset: i64, // frames handed out so far, on the decoder's own timeline
	finished:    bool,
	output:      []f32,
	error:       cstring,
}

// The file in memory, read through vorbisfile's callbacks.
Memory_Source :: struct {
	bytes:    []u8,
	position: int,
}

ogg_open :: proc(d: ^Ogg_Decoder, bytes: []u8) -> bool {
	d.source = new(Memory_Source)
	d.source.bytes = bytes
	d.file = new(OggVorbis_File)
	callbacks := Ov_Callbacks{read_func = memory_read, seek_func = memory_seek, close_func = memory_close, tell_func = memory_tell}
	if ov_open_callbacks(d.source, d.file, nil, 0, callbacks) != 0 {
		free(d.file)
		d.file = nil
		d.error = "not an Ogg Vorbis file"
		return false
	}
	info := ov_info(d.file, -1)
	d.channels, d.sample_rate = int(info.channels), int(info.rate)
	d.read_offset = ov_pcm_tell(d.file)
	d.output = make([]f32, OGG_READ_FRAMES * max(d.channels, 1))
	return d.channels > 0 && d.sample_rate > 0
}

ogg_close :: proc(d: ^Ogg_Decoder) {
	if d.file != nil do ov_clear(d.file)
	free(d.file)
	free(d.source)
	delete(d.output)
	d^ = {}
}

// The next block of samples, interleaved by channel; ok = false at the end (or on an error: d.error).
ogg_next :: proc(d: ^Ogg_Decoder) -> (samples: []f32, ok: bool) {
	for !d.finished {
		position := ov_pcm_tell(d.file)
		if position < d.read_offset {
			d.read_offset = position // the timestamps moved backwards: StepMania ignores it
		} else if position > d.read_offset {
			// A hole: silence up to where the decoder is, so what follows stays in sync.
			gap := int(min(position - d.read_offset, OGG_READ_FRAMES))
			out := d.output[:gap * d.channels]
			for &sample in out do sample = 0
			d.read_offset += i64(gap)
			return out, true
		}

		pcm: [^][^]f32
		bitstream: c.int
		frames := ov_read_float(d.file, &pcm, OGG_READ_FRAMES, &bitstream)
		if info := ov_info(d.file, -1); info == nil || int(info.channels) != d.channels {
			d.error = "the Ogg changes its channel count"
			return nil, false
		}
		switch {
		case frames == OV_HOLE:
			continue
		case frames == OV_EBADLINK:
			d.error = "the Ogg is damaged (bad link)"
			return nil, false
		case frames == 0:
			d.finished = true
		case frames < 0:
			d.error = "the Ogg is damaged"
			return nil, false
		case:
			count := int(frames)
			out := d.output[:count * d.channels]
			for channel in 0..<d.channels {
				source := pcm[channel]
				for i in 0..<count do out[i * d.channels + channel] = source[i]
			}
			d.read_offset += i64(count)
			return out, true
		}
	}
	return nil, false
}

@(private)
memory_read :: proc "c" (destination: rawptr, size, count: c.size_t, data: rawptr) -> c.size_t {
	source := (^Memory_Source)(data)
	if size == 0 do return 0
	available := len(source.bytes) - source.position
	items := min(int(count), available / int(size))
	bytes := items * int(size)
	copy(([^]u8)(destination)[:bytes], source.bytes[source.position:][:bytes])
	source.position += bytes
	return c.size_t(items)
}

@(private)
memory_seek :: proc "c" (data: rawptr, offset: i64, whence: c.int) -> c.int {
	SEEK_SET :: 0
	SEEK_CUR :: 1
	SEEK_END :: 2
	source := (^Memory_Source)(data)
	target: i64
	switch whence {
	case SEEK_SET: target = offset
	case SEEK_CUR: target = i64(source.position) + offset
	case SEEK_END: target = i64(len(source.bytes)) + offset
	case:          return -1
	}
	if target < 0 || target > i64(len(source.bytes)) do return -1
	source.position = int(target)
	return 0
}

@(private)
memory_close :: proc "c" (data: rawptr) -> c.int {
	return 0 // the bytes belong to the caller
}

@(private)
memory_tell :: proc "c" (data: rawptr) -> c.long {
	return c.long((^Memory_Source)(data).position)
}
