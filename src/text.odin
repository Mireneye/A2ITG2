/*
Drawing into the window's pixel buffer: filled rectangles and text in a 5x7 bitmap font.

ZZ-Replace: a stand-in for a real UI (proper font, layout, touch targets). The test only needs
readable status lines.
*/
package a2itg2

import "core:slice"
import "core:strings"

Canvas :: struct {
	pixels: [^]u32,
	width:  int,
	height: int,
	stride: int, // pixels per row in memory, at least `width`
}

GLYPH_WIDTH  :: 5
GLYPH_HEIGHT :: 7
CELL_WIDTH   :: GLYPH_WIDTH + 1  // one column of space between letters
CELL_HEIGHT  :: GLYPH_HEIGHT + 3 // three rows between lines
MARGIN_CELLS :: 2

fill :: proc(canvas: Canvas, color: u32) {
	fill_rect(canvas, 0, 0, canvas.width, canvas.height, color)
}

fill_rect :: proc(canvas: Canvas, x, y, width, height: int, color: u32) {
	x0, y0 := max(x, 0), max(y, 0)
	x1, y1 := min(x + width, canvas.width), min(y + height, canvas.height)
	if x1 <= x0 do return
	for row in y0..<y1 {
		slice.fill(canvas.pixels[row*canvas.stride + x0:row*canvas.stride + x1], color) // vectorised stores
	}
}

// Draws the newest of `lines` in `max_rows` text rows from `top` down, wrapping at word boundaries.
// Older rows scroll off the top; the area itself never changes size.
draw_lines :: proc(canvas: Canvas, lines: []string, scale, top, max_rows: int) {
	columns := canvas.width / (CELL_WIDTH * scale) - 2 * MARGIN_CELLS
	if columns < 8 {
		return
	}
	wrapped := make([dynamic]string, context.temp_allocator)
	for line in lines {
		wrap(&wrapped, line, columns)
	}

	first := max(len(wrapped) - max_rows, 0)
	left := MARGIN_CELLS * CELL_WIDTH * scale
	for row, i in wrapped[first:] {
		// The newest message is bright, older ones dimmed.
		color := u32(COLOR_TEXT) if first + i >= len(wrapped) - newest_rows(lines[len(lines) - 1:], columns) else u32(COLOR_DIM)
		draw_text(canvas, row, left, top + i * CELL_HEIGHT * scale, scale, color)
	}
}

// How many rows the last message takes once wrapped.
@(private = "file")
newest_rows :: proc(last: []string, columns: int) -> int {
	if len(last) == 0 do return 0
	rows := make([dynamic]string, context.temp_allocator)
	wrap(&rows, last[0], columns)
	return len(rows)
}

@(private = "file")
wrap :: proc(out: ^[dynamic]string, line: string, columns: int) {
	rest := line
	for len(rest) > columns {
		cut := strings.last_index_byte(rest[:columns + 1], ' ')
		if cut <= 0 {
			cut = columns // a single long word (like a URI) is cut anywhere
		}
		append(out, rest[:cut])
		rest = strings.trim_left_space(rest[cut:])
	}
	append(out, rest)
}

draw_text :: proc(canvas: Canvas, text: string, x, y, scale: int, color: u32 = COLOR_TEXT) {
	for i in 0..<len(text) {
		c := text[i]
		has_glyph := c < len(FONT) && (c == ' ' || FONT[c] != {})
		glyph := &FONT[c] if has_glyph else &FONT[0]
		left := x + i * CELL_WIDTH * scale
		for row in 0..<GLYPH_HEIGHT {
			bits := glyph[row]
			for column in 0..<GLYPH_WIDTH {
				if bits & (0b10000 >> uint(column)) != 0 {
					fill_rect(canvas, left + column*scale, y + row*scale, scale, scale, color)
				}
			}
		}
	}
}

// Control characters drawn as symbols.
GLYPH_PLAY  :: 1
GLYPH_PAUSE :: 2

// Each glyph is 7 rows of 5 bits, leftmost pixel in the highest bit. Characters without a
// glyph (lowercase is drawn upper-cased before it gets here) show as a hollow box, index 0.
@(rodata)
FONT := [128][GLYPH_HEIGHT]u8{
	0   = {0b11111, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11111},
	'A' = {0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001},
	'B' = {0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110},
	'C' = {0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110},
	'D' = {0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110},
	'E' = {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111},
	'F' = {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000},
	'G' = {0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111},
	'H' = {0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001},
	'I' = {0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},
	'J' = {0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100},
	'K' = {0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001},
	'L' = {0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111},
	'M' = {0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001},
	'N' = {0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001},
	'O' = {0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110},
	'P' = {0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000},
	'Q' = {0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101},
	'R' = {0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001},
	'S' = {0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110},
	'T' = {0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100},
	'U' = {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110},
	'V' = {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100},
	'W' = {0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010},
	'X' = {0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001},
	'Y' = {0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100},
	'Z' = {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111},
	'0' = {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110},
	'1' = {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},
	'2' = {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111},
	'3' = {0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110},
	'4' = {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010},
	'5' = {0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110},
	'6' = {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110},
	'7' = {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000},
	'8' = {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110},
	'9' = {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100},
	' ' = {},
	'.' = {0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100},
	',' = {0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b00100, 0b01000},
	GLYPH_PLAY  = {0b10000, 0b11000, 0b11100, 0b11110, 0b11100, 0b11000, 0b10000},
	GLYPH_PAUSE = {0b11011, 0b11011, 0b11011, 0b11011, 0b11011, 0b11011, 0b11011},
	':' = {0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000},
	';' = {0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b00100, 0b01000},
	'-' = {0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000},
	'_' = {0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111},
	'/' = {0b00000, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000},
	'(' = {0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010},
	')' = {0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000},
	'!' = {0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100},
	'?' = {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100},
	'\''= {0b00100, 0b00100, 0b01000, 0b00000, 0b00000, 0b00000, 0b00000},
	'"' = {0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000},
	'=' = {0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000},
	'+' = {0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000},
	'%' = {0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011},
	'#' = {0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010},
	'@' = {0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110},
	'&' = {0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101},
	'<' = {0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010},
	'>' = {0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000},
}
