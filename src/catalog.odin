/*
The site's pack catalog and searches (worker side).

	/api/packs             every pack: "ID, "Name", Song Count, Size, Sync, PackType, Substyle, Min Version"
	                       (about 10,000 lines, 0.8 MB). Kept in the app's private folder for a day.
	/api/search/?type=title|artist|credit&query=...
	                       packs with matching songs, as JSON; joined with the catalog for sizes.

Pack-name searches run on the phone against the catalog, as you type. An empty search lists the
newest packs. Results are capped at MAX_RESULTS.
*/
package a2itg2

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "tls"
import "web"

CATALOG_URL      :: "https://stepmaniaonline.net/api/packs"
SEARCH_URL       :: "https://stepmaniaonline.net/api/search/?type=%s&query=%s"
CATALOG_FILE     :: "packs.csv"
CATALOG_KEEP     :: 24 * time.Hour
MAX_RESULTS      :: 200
MIN_QUERY_LENGTH :: 3 // the site's own minimum for searches it runs

Search_Kind :: enum u8 {
	Pack_Name,
	Song_Title,
	Artist,
	Chart_Author,
}

SEARCH_KIND_LABEL := [Search_Kind]string{
	.Pack_Name    = "PACK NAME",
	.Song_Title   = "SONG TITLE",
	.Artist       = "ARTIST",
	.Chart_Author = "CHART AUTHOR",
}

// The site's names for the searches it runs.
@(private = "file")
SEARCH_KIND_API := [Search_Kind]string{
	.Pack_Name    = "pack",
	.Song_Title   = "title",
	.Artist       = "artist",
	.Chart_Author = "credit",
}

Catalog_Pack :: struct {
	id:          int,
	name:        string, // points into Catalog.text
	songs:       int,
	bytes:       i64,
	kind:        string, // "pad", "itg", "keyboard", ...
	min_version: string, // "Stepmania 3.9", "Stepmania 5", ...
}

Catalog :: struct {
	text:  []u8,
	packs: [dynamic]Catalog_Pack,
	by_id: map[int]int,
}

// What the screen shows for a search hit (heap strings; the screen frees them).
Pack_Row :: struct {
	id:       int,
	name:     string,
	songs:    int,
	bytes:    i64,      // -1 when the catalog doesn't know the pack
	needs_sm5: bool,    // made for StepMania 5: charts may be .ssc only, which ITG2 can't read
	matched:  string,   // for song searches: the first matching song's title, else ""
}

// Fresh from the private folder when it's under a day old, else from the site (and saved).
load_catalog :: proc(anchors: ^tls.Trust_Anchors, catalog: ^Catalog, private_dir: string) -> (from_site: bool, problem: Pack_Problem) {
	path := fmt.tprintf("%s/%s", private_dir, CATALOG_FILE)
	if info, err := os.stat(path, context.temp_allocator); err == nil && time.since(info.modification_time) < CATALOG_KEEP {
		if text, read_err := os.read_entire_file(path, context.allocator); read_err == nil {
			parse_catalog(catalog, text)
			if len(catalog.packs) > 0 do return false, {}
		}
	}

	body, info, failure, tls_failure := web.get(anchors, CATALOG_URL)
	if failure != .None {
		delete(body)
		return true, web_problem("COULD NOT GET THE PACK LIST", failure, tls_failure, info.status)
	}
	parse_catalog(catalog, body)
	if len(catalog.packs) == 0 do return true, {"THE PACK LIST CAME BACK EMPTY", ""}
	_ = os.write_entire_file(path, body) // a failed save only means downloading again next time
	return true, {}
}

catalog_destroy :: proc(catalog: ^Catalog) {
	delete(catalog.text)
	delete(catalog.packs)
	delete(catalog.by_id)
	catalog^ = {}
}

// `5299, "0  OmegaSteps 1", 22, 102035436, n/a, pad, None, Stepmania 3.9`. Names may hold commas, so
// the name is what sits between the first `"` and the last `", `.
@(private = "file")
parse_catalog :: proc(catalog: ^Catalog, text: []u8) {
	catalog_destroy(catalog)
	catalog.text = text
	catalog.by_id = make(map[int]int)
	rest := string(text)
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if first { first = false; continue } // the header
		open := strings.index_byte(line, '"')
		close := strings.last_index(line, "\", ")
		if open < 0 || close <= open do continue
		id, id_ok := strconv.parse_int(strings.trim_space(line[:strings.index_byte(line, ',')]))
		if !id_ok do continue
		fields := strings.split(line[close + 3:], ", ", context.temp_allocator)
		if len(fields) < 6 do continue
		pack := Catalog_Pack{id = id, name = line[open + 1:close], kind = fields[3], min_version = fields[5]}
		pack.songs, _ = strconv.parse_int(fields[0])
		pack.bytes, _ = strconv.parse_i64(fields[1])
		catalog.by_id[id] = len(catalog.packs)
		append(&catalog.packs, pack)
	}
}

// Runs a search. Pack names and the empty search are answered from the catalog; the others ask the site.
search_packs :: proc(anchors: ^tls.Trust_Anchors, catalog: ^Catalog, kind: Search_Kind, typed: string) -> (rows: []Pack_Row, problem: Pack_Problem) {
	query := strings.trim_space(typed)
	found := make([dynamic]Pack_Row)

	if query == "" {
		// The newest packs first: the file is sorted by name, and ids rise as packs are added.
		sorted := slice.clone(catalog.packs[:], context.temp_allocator)
		slice.sort_by(sorted, proc(a, b: Catalog_Pack) -> bool { return a.id > b.id })
		for pack in sorted[:min(len(sorted), MAX_RESULTS)] do append(&found, row_of(pack, ""))
		return found[:], {}
	}

	if kind == .Pack_Name {
		// Every word of the query, anywhere in the name, any letter case.
		words := strings.fields(strings.to_lower(query, context.temp_allocator), context.temp_allocator)
		for pack in catalog.packs {
			name := strings.to_lower(pack.name, context.temp_allocator)
			all := true
			for word in words do if !strings.contains(name, word) { all = false; break }
			if all do append(&found, row_of(pack, ""))
			if len(found) == MAX_RESULTS do break
		}
		return found[:], {}
	}

	if len(query) < MIN_QUERY_LENGTH do return found[:], {fmt.tprintf("TYPE AT LEAST %d LETTERS", MIN_QUERY_LENGTH), ""}
	url := fmt.tprintf(SEARCH_URL, SEARCH_KIND_API[kind], net.percent_encode(query, context.temp_allocator))
	body, info, failure, tls_failure := web.get(anchors, url)
	defer delete(body)
	if failure != .None do return found[:], web_problem("THE SEARCH FAILED", failure, tls_failure, info.status)

	Answer :: struct {
		results: []struct {
			id:             int,
			name:           string,
			songs_count:    int,
			matching_songs: []string,
		},
	}
	answer: Answer
	if json.unmarshal(body, &answer, allocator = context.temp_allocator) != nil do return found[:], {"THE SITE'S ANSWER WAS UNREADABLE", ""}
	for result in answer.results[:min(len(answer.results), MAX_RESULTS)] {
		matched := result.matching_songs[0] if len(result.matching_songs) > 0 else ""
		if at, known := catalog.by_id[result.id]; known {
			append(&found, row_of(catalog.packs[at], matched))
		} else {
			append(&found, Pack_Row{id = result.id, name = strings.clone(result.name), songs = result.songs_count, bytes = -1, matched = strings.clone(matched)})
		}
	}
	return found[:], {}
}

@(private = "file")
row_of :: proc(pack: Catalog_Pack, matched: string) -> Pack_Row {
	return {
		id        = pack.id,
		name      = strings.clone(pack.name),
		songs     = pack.songs,
		bytes     = pack.bytes,
		needs_sm5 = strings.contains(pack.min_version, "5"),
		matched   = strings.clone(matched),
	}
}

web_problem :: proc(what: string, failure: web.Failure, tls_failure: tls.Failure, status: int) -> Pack_Problem {
	#partial switch failure {
	case .Tls:              return {what, fmt.tprint(tls_failure)}
	case .Http_Error:       return {what, fmt.tprintf("HTTP %d", status)}
	case .Resolve, .Connect: return {what, "IS THE PHONE ONLINE?"}
	}
	return {what, fmt.tprint(failure)}
}
