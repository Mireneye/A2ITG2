// Reads the fixtures from tools/make_zip_fixtures.py the way the app reads a pack over the network:
// only the byte ranges the reader asks for. Run the script once, then `odin test src/zip`.
package zip

import "core:fmt"
import "core:os"
import "core:testing"

FIXTURE_FOLDER :: #directory + "/../../tests/fixtures/"

Expected_File :: struct {
	name:   string,
	size:   int,
	seed:   int,
	method: Method,
}

EXPECTED := [?]Expected_File{
	{"Test Pack/Song A/song a.sm",  20000,  0, .Deflate},
	{"Test Pack/Song A/song a.mp3", 70000,  1, .Stored},
	{"Test Pack/Song A/video.avi",  150000, 2, .Deflate},
	{"Test Pack/Song B/b.ssc",      3000,   3, .Deflate},
}

// The script's fixture_bytes().
fixture_bytes :: proc(size, seed: int, allocator := context.temp_allocator) -> []u8 {
	data := make([]u8, size, allocator)
	for i in 0..<size do data[i] = u8(((i * 7 + seed * 13) % 251) % 64 + 32)
	return data
}

// A fake "fetch": the bytes of `file` at `span`, cut short at the end of the file like a server would.
fetch :: proc(file: []u8, span: Span) -> []u8 {
	start := clamp(int(span.offset), 0, len(file))
	end := clamp(int(span.offset + span.size), start, len(file))
	return file[start:end]
}

read_fixture :: proc(t: ^testing.T, name: string) -> (entries: [dynamic]Entry, file: []u8, ok: bool) {
	data, err := os.read_entire_file(fmt.tprint(FIXTURE_FOLDER, name, sep = ""), context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "missing %s: run tools/make_zip_fixtures.py first", name)
		return
	}
	tail := fetch(data, {offset = i64(len(data)) - TAIL_SIZE, size = TAIL_SIZE})
	directory, need, failure := directory_location(tail)
	testing.expect_value(t, failure, Failure.None)
	if need.size > 0 {
		directory, failure = zip64_directory_location(fetch(data, need))
		testing.expect_value(t, failure, Failure.None)
	}
	entries, failure = read_directory(fetch(data, directory), context.temp_allocator)
	testing.expect_value(t, failure, Failure.None)
	return entries, data, failure == .None
}

check_pack :: proc(t: ^testing.T, name: string, expect_zip64: bool) {
	data, _ := os.read_entire_file(fmt.tprint(FIXTURE_FOLDER, name, sep = ""), context.temp_allocator)
	_, need, _ := directory_location(fetch(data, {offset = i64(len(data)) - TAIL_SIZE, size = TAIL_SIZE}))
	testing.expect_value(t, need.size > 0, expect_zip64)

	entries, file, ok := read_fixture(t, name)
	if !ok do return
	testing.expect_value(t, len(entries), 1 + len(EXPECTED)) // the pack folder, then the files
	testing.expect(t, is_folder(entries[0]))
	for want, i in EXPECTED {
		entry := entries[i + 1]
		testing.expect_value(t, entry.name, want.name)
		testing.expect_value(t, entry.method, want.method)
		testing.expect_value(t, entry.uncompressed_size, i64(want.size))
		contents, failure := extract(entry, fetch(file, entry_span(entry)), context.temp_allocator)
		testing.expect_value(t, failure, Failure.None)
		testing.expectf(t, string(contents) == string(fixture_bytes(want.size, want.seed)), "%s: contents differ", want.name)
	}
}

@(test)
classic_pack :: proc(t: ^testing.T) {
	check_pack(t, "pack.zip", expect_zip64 = false)
}

@(test)
zip64_pack :: proc(t: ^testing.T) {
	check_pack(t, "pack64.zip", expect_zip64 = true)
}

@(test)
damage_is_reported :: proc(t: ^testing.T) {
	entries, file, ok := read_fixture(t, "pack.zip")
	if !ok do return
	entry := entries[1]
	span := fetch(file, entry_span(entry))

	broken := make([]u8, len(span), context.temp_allocator)
	copy(broken, span)
	broken[30 + len(entry.name) + int(entry.compressed_size) / 2] ~= 0xFF // a flipped byte in the middle of the data
	_, failure := extract(entry, broken, context.temp_allocator)
	testing.expect_value(t, failure, Failure.Bad_Data)

	_, failure = extract(entry, span[:40], context.temp_allocator) // cut short
	testing.expect_value(t, failure, Failure.Damaged)

	_, _, failure = directory_location(make([]u8, 100, context.temp_allocator)) // no zip at all
	testing.expect_value(t, failure, Failure.Not_A_Zip)
}
