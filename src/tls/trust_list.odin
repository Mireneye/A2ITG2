// Windows' full list of trusted roots (the AuthRoot certificate trust list): every root Windows
// trusts, by SHA-1 thumbprint, including the many it only downloads on first use. Parsing is
// platform-neutral (the bytes come from trust_windows.odin), so tests can run anywhere.
//
// The list is a PKCS#7 SignedData whose content is a CTL: one TrustedSubject per root, each a
// thumbprint and a set of properties (OID 1.3.6.1.4.1.311.10.11.<property id>).
package tls

import "core:encoding/asn1"
import "core:time"

THUMBPRINT_SIZE :: 20 // SHA-1 of the certificate's DER: how the list names a root

// The properties we read; the rest are counted (Trust_List.property_counts) and ignored.
Trust_Property :: enum u8 {
	Usage,            // CERT_ENHKEY_USAGE: the purposes the root is trusted for (absent: all)
	Friendly_Name,
	Subject_Name_MD5, // MD5 of the subject Name: finds a root by an issuer's name
	Disallowed_Time,  // CERT_DISALLOWED_FILETIME: disabled (from that time, or at once if empty)
	Disallowed_Usage, // the purposes the disabling applies to (absent: all)
	Not_Before_Time,  // CERT_NOT_BEFORE_FILETIME: certificates issued after this aren't trusted
	Not_Before_Usage, // the purposes that applies to (absent: all)
}

// Each property's id: the last arc of its OID.
TRUST_PROPERTY_IDS := [Trust_Property]int{
	.Usage = 9, .Friendly_Name = 11, .Subject_Name_MD5 = 29,
	.Disallowed_Time = 104, .Disallowed_Usage = 122, .Not_Before_Time = 126, .Not_Before_Usage = 127,
}

Trust_List_Entry :: struct {
	thumbprint: [THUMBPRINT_SIZE]u8,
	properties: [Trust_Property][]u8, // each one's raw value (points into the list's bytes); nil if absent
	present:    bit_set[Trust_Property],
}

MAX_PROPERTY_ID :: 160

Trust_List :: struct {
	bytes:   []u8, // owned
	entries: [dynamic]Trust_List_Entry,
	property_counts: [MAX_PROPERTY_ID]int, // how many entries carry each property id (for the probe)
}

// OID prefixes, DER-encoded: 1.2.840.113549.1.7.2 (signedData), 1.3.6.1.4.1.311.10.1 (CTL),
// 1.3.6.1.4.1.311.10.11 (certificate properties).
@(private) OID_SIGNED_DATA     := []u8{0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02}
@(private) OID_CTL             := []u8{0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x0A, 0x01}
@(private) OID_PROPERTY_PREFIX := []u8{0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x0A, 0x0B}

// Parses the list; `bytes` becomes the list's own (freed by trust_list_destroy).
trust_list_parse :: proc(list: ^Trust_List, bytes: []u8) -> bool {
	list.bytes = bytes
	r: asn1.Cursor
	asn1.cursor_init(&r, bytes)
	content_info, e1 := asn1.read_sequence(&r)
	oid, e2 := asn1.read_oid(&content_info)
	if e1 != .None || e2 != .None || !bytes_equal(oid, OID_SIGNED_DATA) do return false
	explicit, present, e3 := asn1.read_explicit(&content_info, 0)
	if e3 != .None || !present do return false
	signed_data, e4 := asn1.read_sequence(&explicit)
	if e4 != .None do return false
	_, _ = asn1.read_integer_bytes(&signed_data) // version
	if asn1.skip(&signed_data) != .None do return false // digest algorithms
	encapsulated, e5 := asn1.read_sequence(&signed_data)
	content_type, e6 := asn1.read_oid(&encapsulated)
	if e5 != .None || e6 != .None || !bytes_equal(content_type, OID_CTL) do return false
	content, has_content, e7 := asn1.read_explicit(&encapsulated, 0)
	if e7 != .None || !has_content do return false
	ctl, e8 := asn1.read_sequence(&content)
	if e8 != .None do return false

	// CTL: subjectUsage, [listIdentifier], [sequenceNumber], thisUpdate, [nextUpdate],
	// subjectAlgorithm, trustedSubjects, [extensions]. The subjects are the one SEQUENCE OF
	// SEQUENCEs that starts with an OCTET STRING; everything before it is skipped by shape.
	for !asn1.is_empty(&ctl) {
		item, err := asn1.read_sequence(&ctl)
		if err != .None {
			if asn1.skip(&ctl) != .None do return false
			continue
		}
		probe := item
		first, first_err := asn1.read_sequence(&probe)
		if first_err != .None do continue
		if _, not_subject := asn1.read_octet_string(&first); not_subject != .None do continue
		return read_trusted_subjects(list, &item)
	}
	return false
}

@(private)
read_trusted_subjects :: proc(list: ^Trust_List, subjects: ^asn1.Cursor) -> bool {
	for !asn1.is_empty(subjects) {
		subject, e1 := asn1.read_sequence(subjects)
		thumbprint, e2 := asn1.read_octet_string(&subject)
		if e1 != .None || e2 != .None || len(thumbprint) != THUMBPRINT_SIZE do return false
		entry: Trust_List_Entry
		copy(entry.thumbprint[:], thumbprint)
		if !asn1.is_empty(&subject) {
			attributes, e3 := asn1.read_set(&subject)
			if e3 != .None do return false
			for !asn1.is_empty(&attributes) {
				attribute, e4 := asn1.read_sequence(&attributes)
				type, e5 := asn1.read_oid(&attribute)
				values, e6 := asn1.read_set(&attribute)
				value, e7 := asn1.read_octet_string(&values)
				if e4 != .None || e5 != .None || e6 != .None || e7 != .None do return false
				if len(type) != len(OID_PROPERTY_PREFIX) + 1 && len(type) != len(OID_PROPERTY_PREFIX) + 2 do continue
				if !bytes_equal(type[:len(OID_PROPERTY_PREFIX)], OID_PROPERTY_PREFIX) do continue
				id := property_id(type[len(OID_PROPERTY_PREFIX):])
				if id < MAX_PROPERTY_ID do list.property_counts[id] += 1
				for property_id_known, property in TRUST_PROPERTY_IDS {
					if property_id_known != id do continue
					entry.properties[property] = value
					entry.present += {property}
				}
			}
		}
		append(&list.entries, entry)
	}
	return true
}

// The last OID arc (one byte, or two in base-128 for ids from 128).
@(private)
property_id :: proc(arc: []u8) -> int {
	if len(arc) == 1 do return int(arc[0])
	return int(arc[0] & 0x7F) << 7 | int(arc[1])
}

trust_list_find :: proc(list: ^Trust_List, thumbprint: []u8) -> ^Trust_List_Entry {
	if list == nil do return nil
	for &entry in list.entries do if bytes_equal(entry.thumbprint[:], thumbprint) do return &entry
	return nil
}

trust_list_destroy :: proc(list: ^Trust_List) {
	delete(list.entries)
	delete(list.bytes)
	list^ = {}
}

// ---- what an entry allows (read from the real list, 2026-11-17: disabled roots carry a
// disallowed time, the Symantec and Trustwave distrusts a not-before time) ----

OID_SERVER_AUTH := []u8{0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01} // 1.3.6.1.5.5.7.3.1

// Does a DER SEQUENCE OF OID name server auth? (An absent list means "every purpose".)
@(private)
usage_names_server_auth :: proc(value: []u8) -> bool {
	r: asn1.Cursor
	asn1.cursor_init(&r, value)
	list, err := asn1.read_sequence(&r)
	if err != .None do return false
	for !asn1.is_empty(&list) {
		oid, oid_err := asn1.read_oid(&list)
		if oid_err != .None do return false
		if bytes_equal(oid, OID_SERVER_AUTH) do return true
	}
	return false
}

// A FILETIME property as a time; empty means "from the start of time".
@(private)
filetime_to_time :: proc(value: []u8) -> time.Time {
	if len(value) != 8 do return {}
	ticks: u64
	for i in 0 ..< 8 do ticks |= u64(value[i]) << uint(8 * i)
	FILETIME_TO_UNIX_SECONDS :: 11644473600
	return time.unix(i64(ticks / 10_000_000) - FILETIME_TO_UNIX_SECONDS, 0)
}

// Trusted for server auth, and not switched off for it.
trust_entry_allows_server_auth :: proc(entry: ^Trust_List_Entry, now: time.Time) -> bool {
	if .Usage not_in entry.present || !usage_names_server_auth(entry.properties[.Usage]) do return false
	if .Disallowed_Time in entry.present || .Disallowed_Usage in entry.present {
		// With no purpose list the whole root is off; with one, only the purposes it names.
		applies := .Disallowed_Usage not_in entry.present || usage_names_server_auth(entry.properties[.Disallowed_Usage])
		if applies && .Disallowed_Time in entry.present {
			off_from := filetime_to_time(entry.properties[.Disallowed_Time])
			if time.diff(off_from, now) >= 0 do return false
		} else if applies do return false
	}
	return true
}

// The date after which the root's new server certificates aren't trusted, if it has one.
trust_entry_not_before :: proc(entry: ^Trust_List_Entry) -> (limit: time.Time, restricted: bool) {
	if .Not_Before_Time not_in entry.present do return {}, false
	if .Not_Before_Usage in entry.present && !usage_names_server_auth(entry.properties[.Not_Before_Usage]) do return {}, false
	return filetime_to_time(entry.properties[.Not_Before_Time]), true
}
