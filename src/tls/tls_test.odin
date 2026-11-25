// Tests that need no server: the byte queue, the reader, and the client's answer to hostile or
// broken input (it must fail with the right reason and never crash). The handshake itself is
// checked against OpenSSL by tools/claude/conformance.sh.
package tls

import "core:crypto/x509"
import "core:encoding/base64"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
TEST_ALPN := []string{"http/1.1"}

@(private)
test_client :: proc(c: ^Client, anchors: ^Trust_Anchors) {
	client_init(c, {server_name = "example.test", alpn = TEST_ALPN, anchors = anchors})
	client_output_done(c, len(client_output(c)))
}

@(private)
record :: proc(out: ^[dynamic]u8, type: Content_Type, body: []u8) {
	append(out, u8(type), 3, 3, u8(len(body) >> 8), u8(len(body) & 0xFF))
	append(out, ..body)
}

// A ServerHello as a server would write it, with what can be varied by the tests.
@(private)
server_hello :: proc(c: ^Client, out: ^[dynamic]u8, session_id: []u8, version: u16, suite: Cipher_Suite, legacy_version := LEGACY_VERSION_TLS12) {
	w := Writer{out}
	write_u8(w, u8(Handshake_Type.Server_Hello))
	m := block_begin(w, 3)
	write_u16(w, legacy_version)
	random: [RANDOM_SIZE]u8 = 7
	write_bytes(w, random[:])
	write_block(w, 1, session_id)
	write_u16(w, u16(suite))
	write_u8(w, 0)
	e := block_begin(w, 2)
	if version != 0 {
		write_u16(w, u16(Extension_Type.Supported_Versions))
		write_u16(w, 2)
		write_u16(w, version)
	}
	write_u16(w, u16(Extension_Type.Key_Share))
	ks := block_begin(w, 2)
	write_u16(w, u16(Named_Group.X25519))
	key: [32]u8 = 9 // a valid X25519 point (the base point's u-coordinate)
	write_block(w, 2, key[:])
	block_end(w, ks, 2)
	block_end(w, e, 2)
	block_end(w, m, 3)
}

@(test)
queue_consumes_and_compacts :: proc(t: ^testing.T) {
	q: Byte_Queue
	defer queue_destroy(&q)
	data := [6]u8{1, 2, 3, 4, 5, 6}
	queue_push(&q, data[:])
	queue_consume(&q, 4)
	testing.expect_value(t, queue_len(&q), 2)
	testing.expect_value(t, queue_bytes(&q)[0], 5)
	queue_push(&q, data[:2])
	testing.expect_value(t, queue_len(&q), 4)
	queue_consume(&q, 100)
	testing.expect_value(t, queue_len(&q), 0)
}

@(test)
reader_stops_at_short_input :: proc(t: ^testing.T) {
	data := [3]u8{0, 5, 1}
	r := reader_make(data[:])
	inner := read_block(&r, 2) // says 5 bytes, has 1
	testing.expect(t, !r.ok && !inner.ok)
	testing.expect_value(t, read_u16(&r), 0)
}

@(test)
client_hello_is_well_formed :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	client_init(&c, {server_name = "example.test", alpn = TEST_ALPN, anchors = &anchors})
	out := client_output(&c)
	testing.expect_value(t, Content_Type(out[0]), Content_Type.Handshake)
	r := reader_make(out[RECORD_HEADER_SIZE:])
	testing.expect_value(t, Handshake_Type(read_u8(&r)), Handshake_Type.Client_Hello)
	body := read_block(&r, 3)
	testing.expect(t, reader_done(&r))
	_ = read_bytes(&body, 2 + RANDOM_SIZE)
	_ = read_block(&body, 1)
	_ = read_block(&body, 2)
	_ = read_block(&body, 1)
	extensions := read_block(&body, 2)
	testing.expect(t, reader_done(&body))
	found_hybrid := false
	for reader_left(&extensions) > 0 {
		type := Extension_Type(read_u16(&extensions))
		data := read_block(&extensions, 2)
		if type == .Key_Share {
			shares := read_block(&data, 2)
			group := Named_Group(read_u16(&shares))
			key := read_block(&shares, 2)
			found_hybrid = group == .X25519_MLKEM768 && len(key.data) == MLKEM768_EK_SIZE + X25519_SHARE_SIZE
		}
	}
	testing.expect(t, extensions.ok && found_hybrid)
}

@(test)
garbage_fails_cleanly :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	for round in 0 ..< 2000 {
		c: Client
		test_client(&c, &anchors)
		junk: [600]u8
		for &b in junk do b = u8(rand.uint32())
		if round % 2 == 0 {
			// Give it a plausible record header so the junk reaches the handshake parser.
			junk[0] = u8(Content_Type.Handshake)
			junk[1], junk[2] = 3, 3
			junk[3], junk[4] = 0x02, 0x00
			junk[5] = u8(Handshake_Type.Server_Hello)
		}
		// Fed whole, then byte by byte: neither may crash.
		client_receive(&c, junk[:])
		d: Client
		test_client(&d, &anchors)
		for i in 0 ..< len(junk) do client_receive(&d, junk[i:i + 1])
		testing.expect(t, c.state == .Failed || c.state == .Wait_Server_Hello)
		testing.expect(t, d.state == .Failed || d.state == .Wait_Server_Hello)
		client_destroy(&c)
		client_destroy(&d)
	}
}

@(test)
oversized_record_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	header := [5]u8{u8(Content_Type.Handshake), 3, 3, 0xFF, 0xFF}
	client_receive(&c, header[:])
	testing.expect_value(t, c.failure, Failure.Record_Overflow)
	testing.expect(t, len(client_output(&c)) > 0) // the alert is ready to send
}

@(test)
tls10_server_is_named :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	server_hello(&c, &hello, c.session_id[:], 0, .ECDHE_RSA_AES_128_GCM_SHA256, legacy_version = LEGACY_VERSION_TLS10)
	record(&records, .Handshake, hello[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.failure, Failure.Needs_Older_Version)
}

// A "TLS 1.2" hello that carries a 1.3 suite and a key share is neither version: refused.
@(test)
mixed_version_hello_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	server_hello(&c, &hello, c.session_id[:], 0, .TLS_AES_128_GCM_SHA256)
	record(&records, .Handshake, hello[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.failure, Failure.Illegal_Parameter)
}

@(test)
wrong_session_id_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	other: [SESSION_ID_SIZE]u8
	server_hello(&c, &hello, other[:], PROTOCOL_VERSION_TLS13, .TLS_AES_128_GCM_SHA256)
	record(&records, .Handshake, hello[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.failure, Failure.Illegal_Parameter)
}

@(test)
unoffered_suite_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	server_hello(&c, &hello, c.session_id[:], PROTOCOL_VERSION_TLS13, Cipher_Suite(0x00FF))
	record(&records, .Handshake, hello[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.failure, Failure.Illegal_Parameter)
}

@(test)
good_server_hello_moves_on :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	test_client(&c, &anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	server_hello(&c, &hello, c.session_id[:], PROTOCOL_VERSION_TLS13, .TLS_AES_128_GCM_SHA256)
	record(&records, .Handshake, hello[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.state, State.Handshaking)
	testing.expect(t, c.read_keys.active)
	// Application data in plaintext now would be an attack: refused.
	plain: [40]u8 = 1 // long enough to hold a tag
	clear(&records)
	record(&records, .Application_Data, plain[:])
	client_receive(&c, records[:])
	testing.expect_value(t, c.failure, Failure.Bad_Record_MAC)
}

// ---- TLS 1.2 ----

@(private)
hex_bytes :: proc(text: string) -> []u8 {
	out := make([]u8, len(text) / 2, context.temp_allocator)
	digit :: proc(c: u8) -> u8 { return c - '0' if c <= '9' else c - 'a' + 10 }
	for i in 0 ..< len(out) do out[i] = digit(text[2 * i]) << 4 | digit(text[2 * i + 1])
	return out
}

// The PRF against the published SHA-256 vector (the same bytes Python's own HMAC gives) and a
// SHA-384 one computed independently with Python's HMAC.
@(test)
tls12_prf_known_answers :: proc(t: ^testing.T) {
	secret := hex_bytes("9bbe436ba940f017b17652849a71db35")
	seed := hex_bytes("a0ba9f936cda311827a6f796ffd5198c")
	got256: [100]u8
	tls12_prf(.SHA256, secret, "test label", got256[:], seed)
	want256 := hex_bytes("e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff70187347b66")
	testing.expect(t, bytes_equal(got256[:], want256))
	got384: [148]u8
	tls12_prf(.SHA384, secret, "test label", got384[:], seed)
	want384 := hex_bytes("dd88775cd827187b67a3f7652b5c13f715791cc46e0274a6d3fb16651103defc544cd8afb68369a219bb918b8b21ddb1764af0a70339e6dec085e574f655851ba692513203536bdfc3675e53768210f0a2389dd324311a440c7c30ef44b391d914c3b0c7c80f1cb5e134cf4253d859fa8a46e978360d095dd2fba0c18a1f4d7b4cf9f24667b5cb0adc5ab65df3a0dc627c9b73cc")
	testing.expect(t, bytes_equal(got384[:], want384))
}

// A TLS 1.2 ServerHello as a server would write it, with what the tests vary.
@(private)
server_hello_tls12 :: proc(c: ^Client, out: ^[dynamic]u8, ems, renegotiation: bool, random_tail: []u8 = nil) {
	w := Writer{out}
	write_u8(w, u8(Handshake_Type.Server_Hello))
	m := block_begin(w, 3)
	write_u16(w, LEGACY_VERSION_TLS12)
	random: [RANDOM_SIZE]u8 = 7
	if random_tail != nil do copy(random[RANDOM_SIZE - len(random_tail):], random_tail)
	write_bytes(w, random[:])
	write_block(w, 1, nil) // 1.2 servers may send any session id; none here
	write_u16(w, u16(Cipher_Suite.ECDHE_ECDSA_AES_128_GCM_SHA256))
	write_u8(w, 0)
	e := block_begin(w, 2)
	if ems { write_u16(w, u16(Extension_Type.Extended_Master_Secret)); write_u16(w, 0) }
	if renegotiation { write_u16(w, u16(Extension_Type.Renegotiation_Info)); write_u16(w, 1); write_u8(w, 0) }
	block_end(w, e, 2)
	block_end(w, m, 3)
}

@(private)
receive_tls12_hello :: proc(c: ^Client, anchors: ^Trust_Anchors, ems, renegotiation: bool, random_tail: []u8 = nil) {
	test_client(c, anchors)
	hello, records: [dynamic]u8
	defer { delete(hello); delete(records) }
	server_hello_tls12(c, &hello, ems, renegotiation, random_tail)
	record(&records, .Handshake, hello[:])
	client_receive(c, records[:])
}

@(test)
tls12_hello_moves_on :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	receive_tls12_hello(&c, &anchors, true, true)
	testing.expect_value(t, c.state, State.Handshaking)
	testing.expect_value(t, c.version, LEGACY_VERSION_TLS12)
}

@(test)
tls12_without_safety_extensions_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	for case_ in 0 ..< 3 {
		c: Client
		receive_tls12_hello(&c, &anchors, ems = case_ != 0, renegotiation = case_ != 1)
		if case_ < 2 do testing.expect_value(t, c.failure, Failure.Legacy_Unsafe)
		client_destroy(&c)
	}
}

// A 1.3 server pushed down to 1.2 marks its random; whoever stripped 1.3 from our hello is caught.
@(test)
tls12_downgrade_is_caught :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	receive_tls12_hello(&c, &anchors, true, true, DOWNGRADE_TO_TLS12[:])
	testing.expect_value(t, c.failure, Failure.Illegal_Parameter)
}

// The server's ChangeCipherSpec before it has sent anything we can key from: refused.
@(test)
tls12_early_change_cipher_spec_is_refused :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	c: Client
	defer client_destroy(&c)
	receive_tls12_hello(&c, &anchors, true, true)
	ccs := [6]u8{u8(Content_Type.Change_Cipher_Spec), 3, 3, 0, 1, 1}
	client_receive(&c, ccs[:])
	testing.expect_value(t, c.failure, Failure.Unexpected_Message)
}

// Junk into a client that already chose 1.2 reaches the 1.2 message table: never a crash.
@(test)
tls12_garbage_fails_cleanly :: proc(t: ^testing.T) {
	anchors: Trust_Anchors
	types := [?]Handshake_Type{.Certificate, .Server_Key_Exchange, .Certificate_Request, .Server_Hello_Done, .Finished, .Hello_Request, .Client_Hello}
	for round in 0 ..< 2000 {
		c: Client
		receive_tls12_hello(&c, &anchors, true, true)
		junk: [600]u8
		for &b in junk do b = u8(rand.uint32())
		junk[0] = u8(Content_Type.Handshake)
		junk[1], junk[2] = 3, 3
		junk[3], junk[4] = 0x02, 0x00
		junk[5] = u8(types[round % len(types)])
		if round % 3 == 0 { junk[6], junk[7], junk[8] = 0, 0, u8(rand.uint32() % 200) } // plausible lengths
		if round % 2 == 0 do client_receive(&c, junk[:])
		else do for i in 0 ..< len(junk) do client_receive(&c, junk[i:i + 1])
		testing.expect(t, c.state == .Failed || c.state == .Handshaking)
		client_destroy(&c)
	}
}

// ---- the OS's trust list and blocked certificates ----
//
// Our own test root and leaf (P-256, valid 2020-2120 and 2025-06-01 to 2119), made for these
// tests: a chain where the server sends its root, as JobTech's does.

@(private) TEST_ROOT_PEM :: `-----BEGIN CERTIFICATE-----
MIIBnzCCAUWgAwIBAgIUFOjZjvoiWNEYvI8yP4jSrpm1k6AwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRV2VhdmluZyBUZXN0IFJvb3QwIBcNMjAwMTAxMDAwMDAwWhgP
MjEyMDAxMDEwMDAwMDBaMBwxGjAYBgNVBAMMEVdlYXZpbmcgVGVzdCBSb290MFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEPqI7JN+E32sxhrJbdo+gkr7+9YQXXHrV
BnDiGBnUTlahB/USv3/FWYXv8q5kQtSJWZhZp1IyK+3gwfMLfo4ew6NjMGEwHQYD
VR0OBBYEFJdZRwODiqGyXmQaGIGHfmqO80o3MB8GA1UdIwQYMBaAFJdZRwODiqGy
XmQaGIGHfmqO80o3MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoG
CCqGSM49BAMCA0gAMEUCIGrg+AMgaOkFwC1Ovfp+yM/BQF7wGu//cgM8v9d5PS8v
AiEA/b4hLDWlpMSEiP5/SbTdnaaEC5umq5rVmu3ziuonmB8=
-----END CERTIFICATE-----`
@(private) TEST_LEAF_PEM :: `-----BEGIN CERTIFICATE-----
MIIBmzCCAUGgAwIBAgIBBzAKBggqhkjOPQQDAjAcMRowGAYDVQQDDBFXZWF2aW5n
IFRlc3QgUm9vdDAgFw0yNTA2MDEwMDAwMDBaGA8yMTE5MDEwMTAwMDAwMFowFTET
MBEGA1UEAwwKdGVzdC5sb2NhbDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABGTg
zT27thhlGJcX7aBunBQQkRMQ5rFFrt9I6r66Wo8h70YfEUMOeAvC/Xk9orJgtbbz
aZTN3mvA/ye8UMK7Ec2jeTB3MBUGA1UdEQQOMAyCCnRlc3QubG9jYWwwEwYDVR0l
BAwwCgYIKwYBBQUHAwEwCQYDVR0TBAIwADAdBgNVHQ4EFgQULJg42L4JIu0C1HON
XxPWf1jfHEowHwYDVR0jBBgwFoAUl1lHA4OKobJeZBoYgYd+ao7zSjcwCgYIKoZI
zj0EAwIDSAAwRQIgQXr2yuBMS92Ap8HCsPArOGiEoo16NR9/w89hgyyAy3ICIQD4
5VayVV2bPOCdAFAQgHE49Jz7++zW/HtPw045BsztDA==
-----END CERTIFICATE-----`

@(private) USAGE_SERVER_AUTH := []u8{0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01}
@(private) USAGE_CLIENT_AUTH := []u8{0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02}
@(private) USAGE_OCSP_SIGNING := []u8{0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x09}

@(private)
pem_der :: proc(text: string) -> []u8 {
	body := text[len(PEM_BEGIN):strings.index(text, PEM_END)]
	compact := make([dynamic]u8, context.temp_allocator)
	for ch in transmute([]u8)body do if ch != '\n' && ch != '\r' do append(&compact, ch)
	der, _ := base64.decode(string(compact[:]), allocator = context.temp_allocator)
	return der
}

@(private)
filetime_bytes :: proc(year: int, month: time.Month, day: int) -> []u8 {
	moment, _ := time.datetime_to_time(year, int(month), day, 0, 0, 0)
	ticks := u64(time.to_unix_seconds(moment) + 11644473600) * 10_000_000
	out := make([]u8, 8, context.temp_allocator)
	for i in 0 ..< 8 do out[i] = u8(ticks >> uint(8 * i))
	return out
}

// The root's list entry, with the properties a case sets.
@(private)
test_entry :: proc(usage: []u8) -> Trust_List_Entry {
	root_cert, _ := x509.parse(pem_der(TEST_ROOT_PEM))
	defer x509.destroy(&root_cert)
	entry: Trust_List_Entry
	entry.thumbprint = thumbprint_of(&root_cert)
	if usage != nil { entry.properties[.Usage] = usage; entry.present += {.Usage} }
	return entry
}

@(private)
TEST_NOW :: proc() -> time.Time { t, _ := time.datetime_to_time(2026, 11, 17, 0, 0, 0); return t }

// The server sends leaf + root; `local_root` puts the root in the stores first.
@(private)
check_test_chain :: proc(entry: Maybe(Trust_List_Entry), local_root := false, blocked: []u8 = nil) -> (problem: Certificate_Problem, learned: int) {
	anchors: Trust_Anchors
	defer trust_anchors_destroy(&anchors)
	if local_root do trust_anchors_add_pem(&anchors, TEST_ROOT_PEM)
	trust_anchors_seal(&anchors)
	if e, ok := entry.?; ok {
		anchors.list = new(Trust_List)
		append(&anchors.list.entries, e)
	}
	if blocked != nil {
		thumbprint: [THUMBPRINT_SIZE]u8
		copy(thumbprint[:], blocked)
		append(&anchors.disallowed, thumbprint)
	}
	chain: Server_Chain
	defer server_chain_destroy(&chain)
	entries := [][]u8{pem_der(TEST_LEAF_PEM), pem_der(TEST_ROOT_PEM)}
	problem = check_chain(&chain, entries, &anchors, "test.local", TEST_NOW())
	return problem, anchors.learned
}

@(test)
listed_root_sent_by_the_server_is_learned :: proc(t: ^testing.T) {
	problem, learned := check_test_chain(test_entry(USAGE_SERVER_AUTH))
	testing.expect_value(t, problem, Certificate_Problem.None)
	testing.expect_value(t, learned, 1)
}

@(test)
unlisted_root_stays_untrusted :: proc(t: ^testing.T) {
	problem, learned := check_test_chain(nil)
	testing.expect_value(t, problem, Certificate_Problem.Untrusted)
	testing.expect_value(t, learned, 0)
}

@(test)
listed_root_not_for_server_auth_is_not_learned :: proc(t: ^testing.T) {
	problem, _ := check_test_chain(test_entry(USAGE_CLIENT_AUTH))
	testing.expect_value(t, problem, Certificate_Problem.Untrusted)
	problem, _ = check_test_chain(test_entry(nil)) // no purposes listed: not trusted for this
	testing.expect_value(t, problem, Certificate_Problem.Untrusted)
}

@(test)
root_switched_off_is_distrusted_even_from_the_store :: proc(t: ^testing.T) {
	entry := test_entry(USAGE_SERVER_AUTH)
	entry.properties[.Disallowed_Time] = filetime_bytes(2024, .February, 1)
	entry.present += {.Disallowed_Time}
	problem, _ := check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.Distrusted)
	problem, _ = check_test_chain(entry) // and never learned
	testing.expect_value(t, problem, Certificate_Problem.Untrusted)
}

@(test)
root_switched_off_later_still_works_now :: proc(t: ^testing.T) {
	entry := test_entry(USAGE_SERVER_AUTH)
	entry.properties[.Disallowed_Time] = filetime_bytes(2030, .January, 1)
	entry.present += {.Disallowed_Time}
	problem, _ := check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.None)
}

@(test)
root_switched_off_for_another_purpose_still_serves :: proc(t: ^testing.T) {
	entry := test_entry(USAGE_SERVER_AUTH)
	entry.properties[.Disallowed_Time] = filetime_bytes(2024, .February, 1)
	entry.properties[.Disallowed_Usage] = USAGE_OCSP_SIGNING
	entry.present += {.Disallowed_Time, .Disallowed_Usage}
	problem, _ := check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.None)
}

// The Symantec / Trustwave kind of distrust: certificates issued from a date on aren't trusted.
@(test)
not_before_cuts_off_newer_certificates :: proc(t: ^testing.T) {
	entry := test_entry(USAGE_SERVER_AUTH)
	entry.properties[.Not_Before_Time] = filetime_bytes(2025, .January, 1) // the leaf is from 2025-06-01
	entry.present += {.Not_Before_Time}
	problem, _ := check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.Distrusted)
	entry.properties[.Not_Before_Time] = filetime_bytes(2026, .January, 1) // the leaf is older: fine
	problem, _ = check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.None)
	entry.properties[.Not_Before_Time] = filetime_bytes(2025, .January, 1)
	entry.properties[.Not_Before_Usage] = USAGE_OCSP_SIGNING // only for another purpose
	entry.present += {.Not_Before_Usage}
	problem, _ = check_test_chain(entry, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.None)
}

@(test)
blocked_certificate_is_distrusted :: proc(t: ^testing.T) {
	leaf_cert, _ := x509.parse(pem_der(TEST_LEAF_PEM))
	leaf_thumbprint := thumbprint_of(&leaf_cert)
	x509.destroy(&leaf_cert)
	problem, _ := check_test_chain(nil, local_root = true, blocked = leaf_thumbprint[:])
	testing.expect_value(t, problem, Certificate_Problem.Distrusted)
	entry := test_entry(USAGE_SERVER_AUTH)
	problem, _ = check_test_chain(nil, local_root = true, blocked = entry.thumbprint[:]) // the root itself
	testing.expect_value(t, problem, Certificate_Problem.Distrusted)
}

// A root the user added themselves isn't on the OS list: it is theirs to trust.
@(test)
own_root_needs_no_list :: proc(t: ^testing.T) {
	problem, _ := check_test_chain(nil, local_root = true)
	testing.expect_value(t, problem, Certificate_Problem.None)
}
