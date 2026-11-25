/*
The Ogg length patch for ITG2: makes the cabinet read a long song as 1:45 so it plays all of it,
instead of cutting custom songs off. Only r21 cabinets honour it; r23 cuts every custom song at
2:00 regardless.

What it changes, as itgoggpatch (github.com/LHCGreg/itgoggpatch, ogglength.cpp) does: the granule
position (the sample count) of the stream's last page is set to PATCHED_SECONDS worth of samples,
and that page's checksum is recomputed. Nothing else moves; the audio is untouched.

Which songs: every song the cabinet would read as longer than 1:45 (itgoggpatch only patches songs
over 2:00, which leaves songs between 1:45 and 2:00 reading their real length on the cabinet).

	patch := ogg_length_patch(ogg_bytes)    // edits ogg_bytes in place when it patches
*/
package audio

import "core:c"

PATCHED_SECONDS      :: 105 // 1:45, the length the cabinet is made to read
PATCH_IF_LONGER_THAN :: PATCHED_SECONDS // anything the cabinet would read as over 1:45

Length_Patch :: struct {
	patched:          bool,
	reported_seconds: f64, // the length the file stated before (its last granule position)
	problem:          Patch_Problem,
}

Patch_Problem :: enum u8 {
	None,
	Not_Ogg_Vorbis,
	Damaged,
	Several_Streams, // more than one logical stream: not a plain song file
}

@(private) PAGE_HEADER_SIZE  :: 27
@(private) HEADER_TYPE_EOS   :: 0x04
@(private) GRANULE_AT        :: 6
@(private) SERIAL_AT         :: 14
@(private) CHECKSUM_AT       :: 22
@(private) SEGMENT_COUNT_AT  :: 26

ogg_length_patch :: proc(ogg: []u8, patched_seconds := PATCHED_SECONDS, if_longer_than := PATCH_IF_LONGER_THAN) -> (result: Length_Patch) {
	sample_rate := 0
	serial := u32(0)
	at := 0
	for {
		if at + PAGE_HEADER_SIZE > len(ogg) do return {problem = .Damaged}
		page := ogg[at:]
		if page[0] != 'O' || page[1] != 'g' || page[2] != 'g' || page[3] != 'S' || page[4] != 0 {
			return {problem = .Not_Ogg_Vorbis if at == 0 else .Damaged}
		}
		segments := int(page[SEGMENT_COUNT_AT])
		header_length := PAGE_HEADER_SIZE + segments
		if header_length > len(page) do return {problem = .Damaged}
		body_length := 0
		for size in page[PAGE_HEADER_SIZE:header_length] do body_length += int(size)
		if header_length + body_length > len(page) do return {problem = .Damaged}
		body := page[header_length:][:body_length]

		page_serial := read_u32_le(page, SERIAL_AT)
		if at == 0 {
			// The first page holds the identification header: 0x01 "vorbis", version, channels, rate.
			if len(body) < 16 || body[0] != 1 || string(body[1:7]) != "vorbis" do return {problem = .Not_Ogg_Vorbis}
			sample_rate = int(read_u32_le(body, 12))
			if sample_rate == 0 do return {problem = .Damaged}
			serial = page_serial
		} else if page_serial != serial {
			return {problem = .Several_Streams}
		}

		if page[5] & HEADER_TYPE_EOS != 0 {
			granule := i64(read_u64_le(page, GRANULE_AT))
			result.reported_seconds = f64(granule) / f64(sample_rate)
			if result.reported_seconds <= f64(if_longer_than) do return result

			write_u64_le(page, GRANULE_AT, u64(i64(patched_seconds) * i64(sample_rate)))
			header := page[:header_length]
			write_u32_le(header, CHECKSUM_AT, 0)
			ogg_page := Ogg_Page{header = raw_data(header), header_len = c.long(len(header)), body = raw_data(body), body_len = c.long(len(body))}
			ogg_page_checksum_set(&ogg_page) // libogg writes the page's CRC into the header
			result.patched = true
			return result
		}
		at += header_length + body_length
	}
}

// The length an Ogg states (its last page's granule position), without changing anything.
ogg_reported_seconds :: proc(ogg: []u8) -> (seconds: f64, ok: bool) {
	copy_of := make([]u8, len(ogg), context.temp_allocator)
	copy(copy_of, ogg)
	result := ogg_length_patch(copy_of, if_longer_than = max(int))
	return result.reported_seconds, result.problem == .None
}

@(private) read_u32_le :: proc(b: []u8, at: int) -> u32 { return u32(b[at]) | u32(b[at+1]) << 8 | u32(b[at+2]) << 16 | u32(b[at+3]) << 24 }
@(private) read_u64_le :: proc(b: []u8, at: int) -> u64 { return u64(read_u32_le(b, at)) | u64(read_u32_le(b, at + 4)) << 32 }
@(private) write_u32_le :: proc(b: []u8, at: int, v: u32) { for i in 0..<4 do b[at + i] = u8(v >> (8 * uint(i))) }
@(private) write_u64_le :: proc(b: []u8, at: int, v: u64) { for i in 0..<8 do b[at + i] = u8(v >> (8 * uint(i))) }
