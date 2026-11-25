// Reading and writing TLS's big-endian, length-prefixed structures. A reader never panics on
// short input: it turns `ok` off and every later read returns zeros, so a parser checks once
// at the end instead of after every field.
package tls

Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

reader_make :: proc(data: []u8) -> Reader {
	return Reader{data = data, ok = true}
}

reader_left :: proc(r: ^Reader) -> int {
	return len(r.data) - r.at
}

reader_done :: proc(r: ^Reader) -> bool {
	return r.ok && r.at == len(r.data)
}

read_bytes :: proc(r: ^Reader, count: int) -> []u8 {
	if !r.ok || count < 0 || count > reader_left(r) {
		r.ok = false
		return nil
	}
	b := r.data[r.at:][:count]
	r.at += count
	return b
}

read_u8 :: proc(r: ^Reader) -> u8 {
	b := read_bytes(r, 1)
	return b[0] if b != nil else 0
}

read_u16 :: proc(r: ^Reader) -> u16 {
	b := read_bytes(r, 2)
	return u16(b[0]) << 8 | u16(b[1]) if b != nil else 0
}

read_u24 :: proc(r: ^Reader) -> int {
	b := read_bytes(r, 3)
	return int(b[0]) << 16 | int(b[1]) << 8 | int(b[2]) if b != nil else 0
}

// A block whose length is given by a 1-, 2- or 3-byte prefix.
read_block :: proc(r: ^Reader, prefix_size: int) -> Reader {
	count: int
	switch prefix_size {
	case 1: count = int(read_u8(r))
	case 2: count = int(read_u16(r))
	case 3: count = read_u24(r)
	}
	b := read_bytes(r, count)
	inner := reader_make(b)
	inner.ok = r.ok
	return inner
}

Writer :: struct {
	out: ^[dynamic]u8,
}

write_u8 :: proc(w: Writer, v: u8) {
	append(w.out, v)
}

write_u16 :: proc(w: Writer, v: u16) {
	append(w.out, u8(v >> 8), u8(v))
}

write_u24 :: proc(w: Writer, v: int) {
	append(w.out, u8(v >> 16), u8(v >> 8), u8(v))
}

write_bytes :: proc(w: Writer, b: []u8) {
	append(w.out, ..b)
}

// Opens a length-prefixed block; block_end writes its length once the contents are in.
block_begin :: proc(w: Writer, prefix_size: int) -> (mark: int) {
	mark = len(w.out)
	for _ in 0 ..< prefix_size do append(w.out, 0)
	return mark
}

block_end :: proc(w: Writer, mark: int, prefix_size: int) {
	count := len(w.out) - mark - prefix_size
	for i in 0 ..< prefix_size {
		w.out[mark + i] = u8(count >> uint(8 * (prefix_size - 1 - i)))
	}
}

write_block :: proc(w: Writer, prefix_size: int, b: []u8) {
	mark := block_begin(w, prefix_size)
	write_bytes(w, b)
	block_end(w, mark, prefix_size)
}
