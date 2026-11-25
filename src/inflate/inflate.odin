// Inflate (RFC 1950/1951: zlib and deflate), written for speed and for streaming: output goes
// into a buffer the caller drains as it fills (a picture's rows), keeping only the last 32 KB
// that later back-references can reach. Nothing the size of the whole output ever exists.
//
// Speed: a 64-bit bit buffer refilled 7-8 bytes at a time with one unaligned load; Huffman
// codes looked up in one table read (codes longer than the table's bits take one more read in
// a subtable); matches copied 16 bytes at a time when they don't overlap that closely. The hot
// loop looks up the next symbol before it refills and before it copies, tests for a literal
// first and for every rare case (subtable, end of block, invalid) in one branch, and is built
// twice, with and without BMI2, the CPU picking at run time. On a Ryzen 2700X that is 1.4-1.5x
// the previous version on text and picture data, and within about 15% of libdeflate.
// Tried and dropped (slower, measured): two literals per table entry, a leaner entry layout,
// deferring the match copy, smaller output chunks. The A/B copy lives in src/experiments/inflate_x.
//
//   z: Inflater
//   inflate_begin(&z, zlib_bytes, has_zlib_header = true)
//   for {
//       status := inflate_run(&z)          // fills z.out[z.drained:z.out_len]
//       ...use the new bytes...; z.drained = z.out_len
//       if status != .Need_Space do break  // .Done, or an error
//       inflate_slide(&z)                  // keeps the last 32 KB, makes room
//   }
package inflate

import "base:intrinsics"
import "core:mem"

INFLATE_WINDOW :: 32 * 1024
// Room for output between drains (the caller sees at most this much new output per run).
INFLATE_CHUNK :: 256 * 1024
INFLATE_MAX_MATCH :: 258
// Slack past the end so a match can be copied 8 bytes at a time without checks.
INFLATE_SLACK :: 16

LITLEN_TABLE_BITS :: 10
DIST_TABLE_BITS :: 8
CODELEN_TABLE_BITS :: 7
MAX_CODE_BITS :: 15
// Big enough for the worst case: every long code its own subtable of 2^(15 - table bits).
LITLEN_TABLE_SIZE :: (1 << LITLEN_TABLE_BITS) + 288 * (1 << (MAX_CODE_BITS - LITLEN_TABLE_BITS))
DIST_TABLE_SIZE :: (1 << DIST_TABLE_BITS) + 32 * (1 << (MAX_CODE_BITS - DIST_TABLE_BITS))

// A table entry, everything the decoder needs in one read:
//   bits 0-7   the code's length in bits (0: no code maps here, a broken stream)
//   bit 8      SUBTABLE: a link instead; bits 16+ the subtable's start, bits 0-7 its index bits
//   bit 9      LITERAL: bits 16-23 are the byte
//   bit 10     END_OF_BLOCK
//   bit 11     INVALID: a symbol that can't appear (286, 287; distances 30, 31)
//   bits 12-15 extra bits after the code (lengths and distances)
//   bits 16-31 the value: a literal byte, a length's base, a distance's base, a code length code
@(private = "file")
SUBTABLE :: 0x100
@(private = "file")
LITERAL :: 0x200
@(private = "file")
END_OF_BLOCK :: 0x400
@(private = "file")
INVALID :: 0x800
@(private = "file")
NO_CODE :: INVALID // an unused slot: no code bits, flagged so the hot loops catch it with the other rare cases

@(private = "file")
Table_Kind :: enum u8 {
	Litlen,
	Dist,
	Codelen,
}

Inflate_Status :: enum u8 {
	Need_Space, // drain z.out, call inflate_slide, run again
	Done,
	Truncated, // the input ended before the stream did
	Broken, // not a valid stream
}

@(private = "file")
Inflate_Stage :: enum u8 {
	Block_Header,
	Stored,
	Huffman,
	Done,
}

Inflater :: struct {
	input:       []u8, // the input piece being read
	more:        [][]u8, // the pieces after it (a PNG's IDAT chunks: read across, never joined)
	position:    int, // next input byte to load into the bit buffer
	bits:        u64,
	count:       u32, // valid bits in `bits`
	padded:      u32, // zero bytes added past the input's end (reading them = truncated)

	out:         []u8, // INFLATE_WINDOW + INFLATE_CHUNK + slack
	out_len:     int,
	drained:     int, // what the caller has taken (inflate_slide keeps the window before it)

	stage:       Inflate_Stage,
	last_block:  bool,
	stored_left: int,
	litlen:      [LITLEN_TABLE_SIZE]u32,
	dist:        [DIST_TABLE_SIZE]u32,
}

// Length and distance codes: base values and extra bits (RFC 1951 3.2.5).
@(private = "file", rodata)
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file", rodata)
LENGTH_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file", rodata)
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file", rodata)
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private = "file", rodata)
CODELEN_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// `out` is allocated here (with the allocator given); the Inflater itself is about 100 KB of
// tables, so keep it off small stacks (new(Inflater) or a worker's own).
// `more`: further pieces of input after `input`, read as if joined (nothing is copied).
inflate_begin :: proc(z: ^Inflater, input: []u8, has_zlib_header: bool, allocator := context.allocator, more: [][]u8 = nil) -> Inflate_Status {
	z.input = input
	z.more = more
	z.position, z.bits, z.count, z.padded = 0, 0, 0, 0
	if len(z.out) == 0 do z.out = make([]u8, INFLATE_WINDOW + INFLATE_CHUNK + INFLATE_SLACK, allocator)
	z.out_len, z.drained = 0, 0
	z.stage, z.last_block = .Block_Header, false
	if has_zlib_header { // read through the bit buffer: the first piece may be shorter than 2 bytes
		refill(z)
		method, flags := u8(take(z, 8)), u8(take(z, 8))
		if z.padded > 0 && z.count < z.padded * 8 do return .Truncated
		if method & 0x0F != 8 || (u16(method) << 8 | u16(flags)) % 31 != 0 || flags & 0x20 != 0 do return .Broken // deflate, checksum, no preset dictionary
	}
	return .Need_Space
}

// Keeps the last 32 KB before what was drained (later matches may reach it); the rest goes.
inflate_slide :: proc(z: ^Inflater) {
	keep_from := max(z.drained - INFLATE_WINDOW, 0)
	if keep_from == 0 do return
	kept := z.out_len - keep_from
	copy(z.out[:kept], z.out[keep_from:z.out_len])
	z.out_len -= keep_from
	z.drained -= keep_from
}

inflate_run :: proc(z: ^Inflater) -> Inflate_Status #no_bounds_check {
	limit := len(z.out) - INFLATE_SLACK - INFLATE_MAX_MATCH // room for one more symbol's output
	for {
		switch z.stage {
		case .Done:
			return .Done
		case .Block_Header:
			if z.last_block {
				z.stage = .Done
				return .Done
			}
			refill(z)
			z.last_block = take(z, 1) == 1
			switch take(z, 2) {
			case 0:
				// Stored: to a byte boundary, then LEN and its complement (from the bit buffer: the
				// input may continue in another piece, so nothing is re-read).
				drop(z, z.count & 7)
				if z.count < 32 do refill(z)
				length := int(take(z, 16))
				complement := int(take(z, 16))
				if z.padded > 0 && z.count < z.padded * 8 do return .Truncated
				if length != ~complement & 0xFFFF do return .Broken
				z.stored_left = length
				z.stage = .Stored
			case 1:
				if !build_fixed_tables(z) do return .Broken
				z.stage = .Huffman
			case 2:
				if status := read_dynamic_tables(z); status != .Need_Space do return status
				z.stage = .Huffman
			case:
				return .Broken
			}
			if z.padded > 0 && z.count < z.padded * 8 do return .Truncated
		case .Stored:
			room := len(z.out) - INFLATE_SLACK - z.out_len
			if room <= 0 do return .Need_Space
			// Whole bytes still in the bit buffer come first (real ones: never the padding).
			for z.stored_left > 0 && room > 0 && z.count >= z.padded * 8 + 8 {
				z.out[z.out_len] = u8(take(z, 8))
				z.out_len += 1
				z.stored_left -= 1
				room -= 1
			}
			if z.count <= z.padded * 8 { // nothing real left in the buffer (padding at most): empty it
				z.bits, z.count, z.padded = 0, 0, 0
			}
			if z.stored_left > 0 && room > 0 && z.count == 0 {
				if z.position >= len(z.input) && !next_piece(z) do return .Truncated
				n := min(z.stored_left, room, len(z.input) - z.position)
				copy(z.out[z.out_len:], z.input[z.position:][:n])
				z.out_len += n
				z.position += n
				z.stored_left -= n
			}
			if z.stored_left == 0 do z.stage = .Block_Header
		case .Huffman:
			status := decode_huffman_block(z, limit)
			if status != .Done do return status
			z.stage = .Block_Header
		}
	}
}

// Symbols until the end of the block (.Done), a full buffer (.Need_Space) or an error.
// The bit buffer and positions live in locals here (registers), written back on the way out.
@(private = "file")
decode_huffman_block_body :: #force_inline proc(z: ^Inflater, limit: int) -> Inflate_Status #no_bounds_check {
	out := raw_data(z.out)
	n := z.out_len
	input := raw_data(z.input)
	input_len := len(z.input)
	position := z.position
	bits, count := z.bits, z.count
	litlen, dist := raw_data(z.litlen[:]), raw_data(z.dist[:])
	LITLEN_MASK :: (1 << LITLEN_TABLE_BITS) - 1
	DIST_MASK :: (1 << DIST_TABLE_BITS) - 1
	defer {
		z.out_len, z.position, z.bits, z.count = n, position, bits, count
	}
	RARE :: SUBTABLE | INVALID | END_OF_BLOCK // everything the hot path does not handle, tested once

	// The fast region: while at least 8 input bytes are left, every refill is one 8-byte load and the
	// bit buffer then holds 64 true stream bits, so the next table lookup can be issued straight after the
	// last code is consumed (16+ bits remain), before the refill and before the match copy; neither
	// waits for the other. The slow loop below finishes near the ends of the input and the output.
	if n < limit && position + 16 <= input_len { // 16: this refill, and the next one at the end of the first round
		bits |= u64(intrinsics.unaligned_load((^u64le)(&input[position]))) << (count & 63)
		position += int(63 - count) >> 3
		count |= 56
		last_position := input_len - 8 // the last position a refill can start from
		entry := litlen[bits & LITLEN_MASK]
		for {
			if entry & LITERAL != 0 { // the common case first: one test for a literal, none of the rare ones
				out[n] = u8(entry >> 16)
				n += 1
				bits >>= entry & 63
				count -= entry & 0xFF
				entry = litlen[bits & LITLEN_MASK]
				if entry & (LITERAL | SUBTABLE) == LITERAL {
					bits >>= entry & 63
					count -= entry & 0xFF
					out[n] = u8(entry >> 16)
					n += 1
					entry = litlen[bits & LITLEN_MASK]
					if entry & (LITERAL | SUBTABLE) == LITERAL {
						bits >>= entry & 63
						count -= entry & 0xFF
						out[n] = u8(entry >> 16)
						n += 1
						entry = litlen[bits & LITLEN_MASK]
					}
				}
				bits |= u64(intrinsics.unaligned_load((^u64le)(&input[position]))) << (count & 63)
				position += int(63 - count) >> 3
				count |= 56
				if u8(n >= limit) | u8(position > last_position) != 0 do break // one branch for both
				continue
			}
			if entry & RARE != 0 {
				if entry & SUBTABLE != 0 {
					entry = litlen[(entry >> 16) + u32((bits >> (LITLEN_TABLE_BITS & 63)) & ((u64(1) << (entry & 63)) - 1))]
				}
				if entry & INVALID != 0 do return .Broken
				if entry & END_OF_BLOCK != 0 {
					bits >>= entry & 63
					count -= entry & 0xFF
					if z.padded > 0 && count < z.padded * 8 do return .Truncated
					return .Done
				}
				if entry & LITERAL != 0 { // a literal behind a subtable: rare, one at a time
					out[n] = u8(entry >> 16)
					n += 1
					bits >>= entry & 63
					count -= entry & 0xFF
					entry = litlen[bits & LITLEN_MASK]
					bits |= u64(intrinsics.unaligned_load((^u64le)(&input[position]))) << (count & 63)
					position += int(63 - count) >> 3
					count |= 56
					if u8(n >= limit) | u8(position > last_position) != 0 do break
					continue
				}
			}
			code_bits := entry & 0xFF
			saved := bits
			bits >>= code_bits & 63
			count -= code_bits
			extra := (entry >> 12) & 0xF
			length := int(entry >> 16) + int((saved >> ((code_bits - extra) & 63)) & ((u64(1) << (extra & 63)) - 1))
			entry = dist[bits & DIST_MASK]
			if entry & (SUBTABLE | INVALID) != 0 {
				if entry & SUBTABLE != 0 {
					entry = dist[(entry >> 16) + u32((bits >> (DIST_TABLE_BITS & 63)) & ((u64(1) << (entry & 63)) - 1))]
				}
				if entry & INVALID != 0 do return .Broken
			}
			code_bits = entry & 0xFF // the code and its extra bits together
			extra = (entry >> 12) & 0xF
			saved = bits
			bits >>= code_bits & 63
			count -= code_bits
			distance := int(entry >> 16) + int((saved >> ((code_bits - extra) & 63)) & ((u64(1) << (extra & 63)) - 1))
			if distance > n do return .Broken
			entry = litlen[bits & LITLEN_MASK] // the next symbol, before the refill and the copy
			bits |= u64(intrinsics.unaligned_load((^u64le)(&input[position]))) << (count & 63)
			position += int(63 - count) >> 3
			count |= 56
			copy_match(out, n, n - distance, length)
			n += length
			if u8(n >= limit) | u8(position > last_position) != 0 do break
		}
	}
	for {
		// Refill to 56+ bits: enough for a length (15 + 5) and a distance (15 + 13).
		if n >= limit || position + 8 > input_len {
			if n >= limit do return .Need_Space
			z.position, z.bits, z.count = position, bits, count
			refill(z) // may move on to the next input piece
			position, bits, count = z.position, z.bits, z.count
			input, input_len = raw_data(z.input), len(z.input)
			if z.padded > 0 && count < z.padded * 8 do return .Truncated
		} else {
			bits |= u64(intrinsics.unaligned_load((^u64le)(&input[position]))) << (count & 63)
			position += int(63 - count) >> 3
			count |= 56
		}
		entry := litlen[bits & LITLEN_MASK]
		if entry & RARE != 0 {
			if entry & SUBTABLE != 0 {
				entry = litlen[(entry >> 16) + u32((bits >> (LITLEN_TABLE_BITS & 63)) & ((u64(1) << (entry & 63)) - 1))]
			}
			if entry & INVALID != 0 do return .Broken
			if entry & END_OF_BLOCK != 0 {
				bits >>= entry & 63
				count -= entry & 0xFF
				if z.padded > 0 && count < z.padded * 8 do return .Truncated
				return .Done
			}
		}
		code_bits := entry & 0xFF // the code and, for a length, its extra bits
		saved := bits // the extra bits of a length are read from here, in parallel with the shift
		bits >>= code_bits & 63
		count -= code_bits
		if entry & LITERAL != 0 {
			out[n] = u8(entry >> 16)
			n += 1
			// Up to two more literals on the same refill (each code is at most 15 bits).
			entry = litlen[bits & LITLEN_MASK]
			if entry & (LITERAL | SUBTABLE) != LITERAL do continue
			bits >>= entry & 63
			count -= entry & 0xFF
			out[n] = u8(entry >> 16)
			n += 1
			entry = litlen[bits & LITLEN_MASK]
			if entry & (LITERAL | SUBTABLE) != LITERAL do continue
			bits >>= entry & 63
			count -= entry & 0xFF
			out[n] = u8(entry >> 16)
			n += 1
			continue
		}
		extra := (entry >> 12) & 0xF
		length := int(entry >> 16) + int((saved >> ((code_bits - extra) & 63)) & ((u64(1) << (extra & 63)) - 1))
		entry = dist[bits & DIST_MASK]
		if entry & (SUBTABLE | INVALID) != 0 {
			if entry & SUBTABLE != 0 {
				entry = dist[(entry >> 16) + u32((bits >> (DIST_TABLE_BITS & 63)) & ((u64(1) << (entry & 63)) - 1))]
			}
			if entry & INVALID != 0 do return .Broken
		}
		code_bits = entry & 0xFF // the code and its extra bits together
		if count < code_bits { // near the end of the input piece: top up
			z.position, z.bits, z.count = position, bits, count
			refill(z)
			position, bits, count = z.position, z.bits, z.count
			input, input_len = raw_data(z.input), len(z.input)
		}
		extra = (entry >> 12) & 0xF
		saved = bits
		bits >>= code_bits & 63
		count -= code_bits
		distance := int(entry >> 16) + int((saved >> ((code_bits - extra) & 63)) & ((u64(1) << (extra & 63)) - 1))
		if distance > n do return .Broken
		copy_match(out, n, n - distance, length)
		n += length
	}
}

// The same loop built twice: for any x86-64, and for CPUs with BMI2 (bzhi/shrx make the bit
// extraction a third shorter); the CPU decides at run time which one is used.
@(private = "file")
decode_huffman_block_generic :: proc(z: ^Inflater, limit: int) -> Inflate_Status {
	return decode_huffman_block_body(z, limit)
}

@(private = "file", enable_target_feature = "bmi2")
decode_huffman_block_bmi2 :: proc(z: ^Inflater, limit: int) -> Inflate_Status {
	return decode_huffman_block_body(z, limit)
}

@(private = "file")
decode_huffman_block :: proc(z: ^Inflater, limit: int) -> Inflate_Status {
	when ODIN_ARCH == .amd64 {
		if cpu_has_bmi2() do return decode_huffman_block_bmi2(z, limit)
	}
	return decode_huffman_block_generic(z, limit)
}

@(private = "file")
cpu_has_bmi2 :: proc() -> bool {
	@(static) known, has: bool
	if !known {
		// A2ITG2 change: BMI2 is an x86 feature; ARM phones take the generic path.
		when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 {
			_, ebx, _, _ := intrinsics.x86_cpuid(7, 0)
			has = ebx & (1 << 8) != 0
		}
		known = true
	}
	return has
}

// The match copy: `length` bytes from `from` to `n`, overlapping like deflate says (the slack after the
// output covers the overshoot).
@(private = "file")
copy_match :: #force_inline proc(out: [^]u8, n, from, length: int) #no_bounds_check {
	distance := n - from
	switch {
	case distance >= 16:
		// 16 at a time: a copy never overlaps what it writes (slack covers the overshoot).
		Wide :: #simd[16]u8
		// The first 32 bytes without a loop test (most matches are shorter), then the rest.
		intrinsics.unaligned_store((^Wide)(&out[n]), intrinsics.unaligned_load((^Wide)(&out[from])))
		intrinsics.unaligned_store((^Wide)(&out[n + 16]), intrinsics.unaligned_load((^Wide)(&out[from + 16])))
		for copied := 32; copied < length; copied += 16 {
			intrinsics.unaligned_store((^Wide)(&out[n + copied]), intrinsics.unaligned_load((^Wide)(&out[from + copied])))
		}
	case distance >= 8:
		for copied := 0; copied < length; copied += 8 {
			intrinsics.unaligned_store((^u64)(&out[n + copied]), intrinsics.unaligned_load((^u64)(&out[from + copied])))
		}
	case distance == 1:
		mem.set(&out[n], out[from], length) // a run of one byte
	case:
		// A short pattern (2 to 7 bytes: a repeated pixel): copied by doubling, each copy a
		// whole number of patterns, from the pattern's start, never overlapping itself.
		for copied := 0; copied < length; {
			chunk := min(copied + distance, length - copied)
			intrinsics.mem_copy_non_overlapping(&out[n + copied], &out[from], chunk)
			copied += chunk
		}
	}
}

// ---------------------------------------------------------------------------------------
// Bits

@(private = "file")
refill :: #force_inline proc(z: ^Inflater) #no_bounds_check {
	if z.position + 8 <= len(z.input) {
		word := intrinsics.unaligned_load((^u64le)(&z.input[z.position]))
		z.bits |= u64(word) << z.count
		z.position += int(63 - z.count) >> 3
		z.count |= 56
		return
	}
	for z.count <= 56 {
		if z.position >= len(z.input) do next_piece(z)
		if z.position < len(z.input) {
			z.bits |= u64(z.input[z.position]) << z.count
			z.position += 1
		} else {
			z.padded += 1 // zeros past the end: fine unless they are actually used
		}
		z.count += 8
	}
}

// On to the next input piece, if any (empty pieces are skipped).
@(private = "file")
next_piece :: proc(z: ^Inflater) -> bool {
	for len(z.more) > 0 {
		z.input, z.more = z.more[0], z.more[1:]
		z.position = 0
		if len(z.input) > 0 do return true
	}
	return false
}

@(private = "file")
take :: #force_inline proc(z: ^Inflater, n: u32) -> u32 {
	value := u32(z.bits & ((u64(1) << n) - 1))
	z.bits >>= n
	z.count -= n
	return value
}

@(private = "file")
drop :: #force_inline proc(z: ^Inflater, n: u32) {
	z.bits >>= n
	z.count -= n
}

// ---------------------------------------------------------------------------------------
// Tables

// Canonical Huffman codes from code lengths (RFC 1951 3.2.2) into a lookup table. Codes come
// least significant bit first in the stream, so table indexes are the bit-reversed codes.
// False for an over-subscribed set of lengths; incomplete sets are allowed (a single distance
// code is legal), their unused slots stay NO_CODE.
@(private = "file")
build_table :: proc(table: []u32, table_bits: u32, lengths: []u8, kind: Table_Kind) -> bool #no_bounds_check {
	length_count: [MAX_CODE_BITS + 1]u32
	longest: u32
	for length in lengths {
		length_count[length] += 1
		longest = max(longest, u32(length))
	}
	length_count[0] = 0
	// Over-subscribed?
	left: i32 = 1
	for bits in 1 ..= MAX_CODE_BITS {
		left = left * 2 - i32(length_count[bits])
		if left < 0 do return false
	}
	next_code: [MAX_CODE_BITS + 2]u32
	for bits in 1 ..= MAX_CODE_BITS do next_code[bits + 1] = (next_code[bits] + length_count[bits]) << 1
	main_size := u32(1) << table_bits
	for i in 0 ..< main_size do table[i] = NO_CODE
	sub_bits := longest - table_bits if longest > table_bits else 0
	sub_size := u32(1) << sub_bits
	next_sub := main_size // subtables follow the main table
	for length, symbol in lengths {
		if length == 0 do continue
		bits := u32(length)
		code := next_code[bits]
		next_code[bits] += 1
		reversed := reverse_bits(code, bits)
		baked := payload(kind, symbol)
		entry := baked | (bits + (baked >> 12) & 0xF) // a length or distance: the code and its extra bits together
		if bits <= table_bits {
			for index := reversed; index < main_size; index += 1 << bits do table[index] = entry
			continue
		}
		// A long code: its first table_bits pick a subtable, the rest index into it.
		prefix := reversed & (main_size - 1)
		link := table[prefix]
		if link & SUBTABLE == 0 {
			if int(next_sub + sub_size) > len(table) do return false
			link = next_sub << 16 | SUBTABLE | sub_bits
			table[prefix] = link
			for i in 0 ..< sub_size do table[next_sub + i] = NO_CODE
			next_sub += sub_size
		}
		start := link >> 16
		rest := reversed >> table_bits
		rest_bits := bits - table_bits
		for index := rest; index < sub_size; index += 1 << rest_bits do table[start + index] = entry
	}
	return true
}

// What a symbol means, baked into its entry (see the entry layout at the top).
@(private = "file")
payload :: proc(kind: Table_Kind, symbol: int) -> u32 {
	switch kind {
	case .Litlen:
		switch {
		case symbol < 256:  return u32(symbol) << 16 | LITERAL
		case symbol == 256: return END_OF_BLOCK
		case symbol < 286:  return u32(LENGTH_BASE[symbol - 257]) << 16 | u32(LENGTH_EXTRA[symbol - 257]) << 12
		}
		return INVALID
	case .Dist:
		if symbol < 30 do return u32(DIST_BASE[symbol]) << 16 | u32(DIST_EXTRA[symbol]) << 12
		return INVALID
	case .Codelen:
		return u32(symbol) << 16
	}
	return INVALID
}

@(private = "file")
reverse_bits :: #force_inline proc(code, bits: u32) -> u32 {
	return intrinsics.reverse_bits(code) >> (32 - bits)
}

@(private = "file")
build_fixed_tables :: proc(z: ^Inflater) -> bool {
	lengths: [288]u8
	for i in 0 ..< 144 do lengths[i] = 8
	for i in 144 ..< 256 do lengths[i] = 9
	for i in 256 ..< 280 do lengths[i] = 7
	for i in 280 ..< 288 do lengths[i] = 8
	distances: [30]u8
	for &length in distances do length = 5
	return build_table(z.litlen[:], LITLEN_TABLE_BITS, lengths[:], .Litlen) && build_table(z.dist[:], DIST_TABLE_BITS, distances[:], .Dist)
}

@(private = "file")
read_dynamic_tables :: proc(z: ^Inflater) -> Inflate_Status {
	refill(z)
	literal_count := int(take(z, 5)) + 257
	distance_count := int(take(z, 5)) + 1
	codelen_count := int(take(z, 4)) + 4
	codelen_lengths: [19]u8
	for i in 0 ..< codelen_count {
		if z.count < 3 do refill(z)
		codelen_lengths[CODELEN_ORDER[i]] = u8(take(z, 3))
	}
	codelen_table: [1 << CODELEN_TABLE_BITS]u32
	if !build_table(codelen_table[:], CODELEN_TABLE_BITS, codelen_lengths[:], .Codelen) do return .Broken
	lengths: [288 + 32]u8
	total := literal_count + distance_count
	for i := 0; i < total; {
		refill(z)
		entry := codelen_table[z.bits & ((1 << CODELEN_TABLE_BITS) - 1)]
		if entry & 0xFF == 0 do return .Broken
		drop(z, entry & 0xFF)
		symbol := entry >> 16
		repeat, value := 1, u8(0)
		switch symbol {
		case 0 ..= 15: value = u8(symbol)
		case 16:
			if i == 0 do return .Broken
			value, repeat = lengths[i - 1], 3 + int(take(z, 2))
		case 17: repeat = 3 + int(take(z, 3))
		case 18: repeat = 11 + int(take(z, 7))
		case: return .Broken
		}
		if i + repeat > total do return .Broken
		for _ in 0 ..< repeat {
			lengths[i] = value
			i += 1
		}
	}
	if z.padded > 0 && z.count < z.padded * 8 do return .Truncated
	if lengths[256] == 0 do return .Broken // no end-of-block code
	if !build_table(z.litlen[:], LITLEN_TABLE_BITS, lengths[:literal_count], .Litlen) do return .Broken
	if !build_table(z.dist[:], DIST_TABLE_BITS, lengths[literal_count:total], .Dist) do return .Broken
	return .Need_Space
}
