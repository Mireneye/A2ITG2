/*
Reading a zip file a few byte ranges at a time, without having the whole file: the table of
contents first, then only the files wanted. ZIP64 (archives or files past 4 GB, or more than
65535 entries) is read wherever it appears.

	tail := <the last TAIL_SIZE bytes of the file>
	where, need := directory_location(tail)
	if need.size > 0 { where = zip64_directory_location(<bytes at need.offset, need.size>) }
	entries := read_directory(<bytes at where.offset, where.size>)
	span := entry_span(entry)                        // a range that holds the local header and data
	data := extract(entry, <bytes at span.offset, span.size>)

Nothing here touches the network or files: the caller fetches the ranges.
*/
package zip

import "core:hash"
import "core:strings"
import "core:unicode/utf8"
import "../inflate"

// The end record is 22 bytes plus a comment of up to 65535; the ZIP64 locator sits just before it.
TAIL_SIZE :: 22 + 65535 + 20

// A slice of the zip file.
Span :: struct {
	offset: i64,
	size:   i64,
}

Method :: enum u16 {
	Stored  = 0,
	Deflate = 8,
}

Entry :: struct {
	name:              string, // full path inside the zip, '/' separated; a folder ends in '/'; UTF-8
	name_owned:        bool,   // decoded into its own memory (free it with the entries); else points into the directory
	stored_name_bytes: int,    // the name's length as stored (the local header's is about the same)
	method:            Method, // other methods show up as their raw number
	compressed_size:   i64,
	uncompressed_size: i64,
	local_offset:      i64,    // where the entry's local header starts
	crc32:             u32,
}

Failure :: enum u8 {
	None,
	Not_A_Zip,          // no end record in the tail
	Spanned,            // a multi-disk archive (never seen on pack sites)
	Damaged,            // a record is cut short or its signature is wrong
	Unsupported_Method, // neither stored nor deflate
	Bad_Data,           // the compressed data does not inflate, or comes out the wrong size or checksum
}

@(private) SIG_END          :: 0x06054b50
@(private) SIG_ZIP64_END    :: 0x06064b50
@(private) SIG_ZIP64_LOCATE :: 0x07064b50
@(private) SIG_CENTRAL      :: 0x02014b50
@(private) SIG_LOCAL        :: 0x04034b50
@(private) ZIP64_EXTRA_ID   :: 0x0001
@(private) UNICODE_PATH_ID  :: 0x7075 // Info-ZIP's UTF-8 copy of the name
@(private) FLAG_UTF8        :: 0x0800 // general purpose bit 11: the name is UTF-8
@(private) ZIP64_END_SIZE   :: 56
@(private) LOCAL_HEADER_SIZE :: 30
@(private) MAX_U16 :: 0xFFFF
@(private) MAX_U32 :: 0xFFFFFFFF

// Where the central directory is, from the file's last bytes. When the archive is ZIP64, `need` is
// the ZIP64 end record to fetch next (pass it to zip64_directory_location).
directory_location :: proc(tail: []u8) -> (directory: Span, need: Span, failure: Failure) {
	at := -1
	for i := len(tail) - 22; i >= 0; i -= 1 {
		if read_u32(tail, i) == SIG_END {
			at = i
			break
		}
	}
	if at < 0 do return {}, {}, .Not_A_Zip
	disk, directory_disk := read_u16(tail, at + 4), read_u16(tail, at + 6)
	count := read_u16(tail, at + 10)
	size, offset := read_u32(tail, at + 12), read_u32(tail, at + 16)

	// A locator right before the end record means ZIP64, whatever the classic fields say.
	locator := at - 20
	if locator >= 0 && read_u32(tail, locator) == SIG_ZIP64_LOCATE {
		record := i64(read_u64(tail, locator + 8))
		return {}, {offset = record, size = ZIP64_END_SIZE}, .None
	}
	if count == MAX_U16 || size == MAX_U32 || offset == MAX_U32 do return {}, {}, .Damaged // ZIP64 values without a locator
	if disk != 0 || directory_disk != 0 do return {}, {}, .Spanned
	return {offset = i64(offset), size = i64(size)}, {}, .None
}

zip64_directory_location :: proc(record: []u8) -> (directory: Span, failure: Failure) {
	if len(record) < ZIP64_END_SIZE || read_u32(record, 0) != SIG_ZIP64_END do return {}, .Damaged
	if read_u32(record, 16) != 0 || read_u32(record, 20) != 0 do return {}, .Spanned
	return {offset = i64(read_u64(record, 48)), size = i64(read_u64(record, 40))}, .None
}

// The entries of a central directory. Names point into `directory`, so keep it alive; names that had to
// be decoded (name_owned) are allocated with `allocator`.
//
// Names are UTF-8 when the entry's UTF-8 flag is set or Info-ZIP's Unicode path field carries them.
// Otherwise the zip format says CP437 (the DOS character set), which old Windows zippers wrote: "²" is the
// byte 0xFD there. A name that already reads as UTF-8 is kept as it is: many tools write UTF-8 without
// setting the flag, and CP437 text almost never happens to be valid UTF-8.
read_directory :: proc(directory: []u8, allocator := context.allocator) -> (entries: [dynamic]Entry, failure: Failure) {
	entries = make([dynamic]Entry, allocator)
	at := 0
	for at + 46 <= len(directory) && read_u32(directory, at) == SIG_CENTRAL {
		name_length  := int(read_u16(directory, at + 28))
		extra_length := int(read_u16(directory, at + 30))
		note_length  := int(read_u16(directory, at + 32))
		end := at + 46 + name_length + extra_length + note_length
		if end > len(directory) do return entries, .Damaged

		stored := directory[at + 46:][:name_length]
		flags := read_u16(directory, at + 8)
		entry := Entry{
			name              = string(stored),
			stored_name_bytes = name_length,
			method            = Method(read_u16(directory, at + 10)),
			crc32             = read_u32(directory, at + 16),
			compressed_size   = i64(read_u32(directory, at + 20)),
			uncompressed_size = i64(read_u32(directory, at + 24)),
			local_offset      = i64(read_u32(directory, at + 42)),
		}
		extra := directory[at + 46 + name_length:][:extra_length]
		apply_zip64_extra(&entry, extra) or_return
		if unicode, found := unicode_path(extra, stored); found {
			entry.name = unicode
		} else if flags & FLAG_UTF8 == 0 && !utf8.valid_string(entry.name) {
			entry.name, entry.name_owned = cp437_to_utf8(stored, allocator), true
		}
		append(&entries, entry)
		at = end
	}
	return entries, .None
}

// The ZIP64 extra field holds, in this order, only the fields whose classic value is all ones.
@(private)
apply_zip64_extra :: proc(entry: ^Entry, extra: []u8) -> Failure {
	at := 0
	for at + 4 <= len(extra) {
		id, size := read_u16(extra, at), int(read_u16(extra, at + 2))
		field := extra[at + 4:]
		if size > len(field) do return .Damaged
		field = field[:size]
		at += 4 + size
		if id != ZIP64_EXTRA_ID do continue

		next := 0
		take :: proc(field: []u8, next: ^int, value: ^i64) -> Failure {
			if next^ + 8 > len(field) do return .Damaged
			value^ = i64(read_u64(field, next^))
			next^ += 8
			return .None
		}
		if entry.uncompressed_size == MAX_U32 do take(field, &next, &entry.uncompressed_size) or_return
		if entry.compressed_size   == MAX_U32 do take(field, &next, &entry.compressed_size) or_return
		if entry.local_offset      == MAX_U32 do take(field, &next, &entry.local_offset) or_return
	}
	return .None
}

// Info-ZIP's Unicode path field: a version byte, the CRC-32 of the stored name (so a renamed entry's
// stale copy is ignored), then the name in UTF-8.
@(private)
unicode_path :: proc(extra, stored: []u8) -> (name: string, found: bool) {
	at := 0
	for at + 4 <= len(extra) {
		id, size := read_u16(extra, at), int(read_u16(extra, at + 2))
		if at + 4 + size > len(extra) do return
		field := extra[at + 4:][:size]
		at += 4 + size
		if id != UNICODE_PATH_ID || size < 5 || field[0] != 1 do continue
		if read_u32(field, 1) != hash.crc32(stored) do continue
		text := string(field[5:])
		if utf8.valid_string(text) do return text, true
	}
	return
}

// CP437's upper half, 0x80 to 0xFF.
@(private, rodata)
CP437_HIGH := [128]rune{
	'Ç', 'ü', 'é', 'â', 'ä', 'à', 'å', 'ç', 'ê', 'ë', 'è', 'ï', 'î', 'ì', 'Ä', 'Å',
	'É', 'æ', 'Æ', 'ô', 'ö', 'ò', 'û', 'ù', 'ÿ', 'Ö', 'Ü', '¢', '£', '¥', '₧', 'ƒ',
	'á', 'í', 'ó', 'ú', 'ñ', 'Ñ', 'ª', 'º', '¿', '⌐', '¬', '½', '¼', '¡', '«', '»',
	'░', '▒', '▓', '│', '┤', '╡', '╢', '╖', '╕', '╣', '║', '╗', '╝', '╜', '╛', '┐',
	'└', '┴', '┬', '├', '─', '┼', '╞', '╟', '╚', '╔', '╩', '╦', '╠', '═', '╬', '╧',
	'╨', '╤', '╥', '╙', '╘', '╒', '╓', '╫', '╪', '┘', '┌', '█', '▄', '▌', '▐', '▀',
	'α', 'ß', 'Γ', 'π', 'Σ', 'σ', 'µ', 'τ', 'Φ', 'Θ', 'Ω', 'δ', '∞', 'φ', 'ε', '∩',
	'≡', '±', '≥', '≤', '⌠', '⌡', '÷', '≈', '°', '∙', '·', '√', 'ⁿ', '²', '■', '\u00A0',
}

cp437_to_utf8 :: proc(stored: []u8, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(stored) * 2, allocator)
	for c in stored {
		if c < 0x80 do strings.write_byte(&b, c)
		else do strings.write_rune(&b, CP437_HIGH[c - 0x80])
	}
	return strings.to_string(b)
}

is_folder :: proc(entry: Entry) -> bool {
	return strings.has_suffix(entry.name, "/")
}

// A range that surely holds the entry's local header and its data. The local header's own name and
// extra field may differ in length from the central directory's, so a little slack is added.
LOCAL_SLACK :: 1024
entry_span :: proc(entry: Entry) -> Span {
	return {offset = entry.local_offset, size = LOCAL_HEADER_SIZE + i64(entry.stored_name_bytes) + LOCAL_SLACK + entry.compressed_size}
}

// The entry's contents, from bytes fetched at entry_span(entry).
extract :: proc(entry: Entry, span_bytes: []u8, allocator := context.allocator) -> (data: []u8, failure: Failure) {
	if len(span_bytes) < LOCAL_HEADER_SIZE || read_u32(span_bytes, 0) != SIG_LOCAL do return nil, .Damaged
	start := LOCAL_HEADER_SIZE + int(read_u16(span_bytes, 26)) + int(read_u16(span_bytes, 28))
	if i64(start) + entry.compressed_size > i64(len(span_bytes)) do return nil, .Damaged
	compressed := span_bytes[start:][:entry.compressed_size]

	switch entry.method {
	case .Stored:
		if entry.compressed_size != entry.uncompressed_size do return nil, .Damaged
		data = make([]u8, len(compressed), allocator)
		copy(data, compressed)
	case .Deflate:
		data = inflate_all(compressed, int(entry.uncompressed_size), allocator) or_return
	case:
		return nil, .Unsupported_Method
	}
	if hash.crc32(data) != entry.crc32 {
		delete(data, allocator)
		return nil, .Bad_Data
	}
	return data, .None
}

@(private)
inflate_all :: proc(compressed: []u8, expected: int, allocator := context.allocator) -> (data: []u8, failure: Failure) {
	z := new(inflate.Inflater, context.temp_allocator) // about 100 KB of tables: not on the stack
	if inflate.inflate_begin(z, compressed, has_zlib_header = false, allocator = context.temp_allocator) != .Need_Space do return nil, .Bad_Data
	data = make([]u8, expected, allocator)
	written := 0
	for {
		status := inflate.inflate_run(z)
		fresh := z.out[z.drained:z.out_len]
		if written + len(fresh) > expected {
			delete(data, allocator)
			return nil, .Bad_Data
		}
		copy(data[written:], fresh)
		written += len(fresh)
		z.drained = z.out_len
		if status == .Need_Space {
			inflate.inflate_slide(z)
			continue
		}
		if status != .Done || written != expected {
			delete(data, allocator)
			return nil, .Bad_Data
		}
		return data, .None
	}
}

@(private) read_u16 :: proc(b: []u8, at: int) -> u16 { return u16(b[at]) | u16(b[at+1]) << 8 }
@(private) read_u32 :: proc(b: []u8, at: int) -> u32 { return u32(read_u16(b, at)) | u32(read_u16(b, at + 2)) << 16 }
@(private) read_u64 :: proc(b: []u8, at: int) -> u64 { return u64(read_u32(b, at)) | u64(read_u32(b, at + 4)) << 32 }
