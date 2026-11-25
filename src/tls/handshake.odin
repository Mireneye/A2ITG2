// The handshake: the ClientHello (one for both versions), the ServerHello that picks the
// version, the per-version message tables, and the TLS 1.3 messages (TLS 1.2's are in tls12.odin).
// The stages both versions share are here too: ALPN, the certificate list, signatures.
package tls

import "core:crypto"
import "core:crypto/hash"
import "core:net"
import "core:time"

// Cipher suites in our order of preference. TLS 1.3's first; then the strict TLS 1.2 set, only
// ever chosen by servers without 1.3 (a 1.3 server picks a 1.3 suite).
CIPHER_SUITES := [?]Cipher_Suite{
	.TLS_AES_128_GCM_SHA256, .TLS_CHACHA20_POLY1305_SHA256, .TLS_AES_256_GCM_SHA384,
	.ECDHE_ECDSA_AES_128_GCM_SHA256, .ECDHE_RSA_AES_128_GCM_SHA256,
	.ECDHE_ECDSA_CHACHA20_POLY1305_SHA256, .ECDHE_RSA_CHACHA20_POLY1305_SHA256,
	.ECDHE_ECDSA_AES_256_GCM_SHA384, .ECDHE_RSA_AES_256_GCM_SHA384,
}

// What the server may sign with, best first. PKCS#1 v1.5 is for certificate signatures and
// TLS 1.2's ServerKeyExchange only, never TLS 1.3's CertificateVerify.
SIGNATURE_SCHEMES := [?]Signature_Scheme{
	.ECDSA_Secp256r1_SHA256, .RSA_PSS_RSAE_SHA256, .Ed25519,
	.ECDSA_Secp384r1_SHA384, .RSA_PSS_RSAE_SHA384, .RSA_PSS_RSAE_SHA512,
	.RSA_PKCS1_SHA256, .RSA_PKCS1_SHA384, .RSA_PKCS1_SHA512,
}

// The server's messages after its hello, in the order each version allows.
FLIGHT_TLS13 := [?]Step{
	{.Encrypted_Extensions, false, receive_encrypted_extensions},
	{.Certificate_Request,  true,  receive_certificate_request},
	{.Certificate,          false, receive_certificate},
	{.Certificate_Verify,   false, receive_certificate_verify},
	{.Finished,             false, receive_finished},
}

PSK_DHE_KE                 :: u8(1)
EC_POINT_FORMAT_UNCOMPRESSED :: u8(0)

@(private)
is_ip_literal :: proc(host: string) -> bool {
	return net.parse_address(host) != nil
}

@(private)
write_extension_header :: proc(w: Writer, type: Extension_Type) -> (mark: int) {
	write_u16(w, u16(type))
	return block_begin(w, 2)
}

// The ClientHello (also the second one after a HelloRetryRequest: same random, same session
// id, only the key share and cookie change).
write_client_hello :: proc(c: ^Client, out: ^[dynamic]u8) {
	clear(out)
	w := Writer{out}
	write_u8(w, u8(Handshake_Type.Client_Hello))
	message := block_begin(w, 3)
	write_u16(w, LEGACY_VERSION_TLS12)
	write_bytes(w, c.random[:])
	write_block(w, 1, c.session_id[:])
	suites := block_begin(w, 2)
	for suite in CIPHER_SUITES do write_u16(w, u16(suite))
	block_end(w, suites, 2)
	write_u8(w, 1); write_u8(w, 0) // legacy compression: null only

	extensions := block_begin(w, 2)
	if len(c.config.server_name) > 0 && !is_ip_literal(c.config.server_name) {
		ext := write_extension_header(w, .Server_Name)
		list := block_begin(w, 2)
		write_u8(w, 0) // host_name
		write_block(w, 2, transmute([]u8)c.config.server_name)
		block_end(w, list, 2)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Supported_Versions)
		write_u8(w, 4)
		write_u16(w, PROTOCOL_VERSION_TLS13)
		write_u16(w, LEGACY_VERSION_TLS12)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Supported_Groups)
		list := block_begin(w, 2)
		for group in supported_groups(&c.shares) do write_u16(w, u16(group))
		block_end(w, list, 2)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Signature_Algorithms)
		list := block_begin(w, 2)
		for scheme in SIGNATURE_SCHEMES do write_u16(w, u16(scheme))
		block_end(w, list, 2)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Key_Share)
		list := block_begin(w, 2)
		write_key_shares(w, &c.shares)
		block_end(w, list, 2)
		block_end(w, ext, 2)
	}
	{
		// Needed for servers to issue tickets later; harmless until resumption exists.
		ext := write_extension_header(w, .PSK_Key_Exchange_Modes)
		write_u8(w, 1)
		write_u8(w, PSK_DHE_KE)
		block_end(w, ext, 2)
	}
	// For TLS 1.2 servers: uncompressed points, extended master secret, secure renegotiation
	// (an empty renegotiated_connection: this is a first handshake). TLS 1.3 servers ignore them.
	{
		ext := write_extension_header(w, .EC_Point_Formats)
		write_u8(w, 1)
		write_u8(w, EC_POINT_FORMAT_UNCOMPRESSED)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Extended_Master_Secret)
		block_end(w, ext, 2)
	}
	{
		ext := write_extension_header(w, .Renegotiation_Info)
		write_u8(w, 0)
		block_end(w, ext, 2)
	}
	if len(c.config.alpn) > 0 {
		ext := write_extension_header(w, .ALPN)
		list := block_begin(w, 2)
		for protocol in c.config.alpn do write_block(w, 1, transmute([]u8)protocol)
		block_end(w, list, 2)
		block_end(w, ext, 2)
	}
	if len(c.cookie) > 0 {
		ext := write_extension_header(w, .Cookie)
		write_block(w, 2, c.cookie[:])
		block_end(w, ext, 2)
	}
	block_end(w, extensions, 2)
	block_end(w, message, 3)
}

// Takes every whole handshake message out of the handshake queue.
receive_handshake_messages :: proc(c: ^Client) {
	for c.state != .Failed {
		pending := queue_bytes(&c.handshake)
		if len(pending) < HANDSHAKE_HEADER_SIZE do return
		length := int(pending[1]) << 16 | int(pending[2]) << 8 | int(pending[3])
		if length > MAX_HANDSHAKE_MESSAGE {
			fail(c, .Decode, .Decode_Error)
			return
		}
		if len(pending) < HANDSHAKE_HEADER_SIZE + length do return
		message := pending[:HANDSHAKE_HEADER_SIZE + length]
		epoch := c.read_epoch
		receive_handshake(c, Handshake_Type(message[0]), message[HANDSHAKE_HEADER_SIZE:], message)
		queue_consume(&c.handshake, len(message))
		// A message after which the read keys changed must end its record (RFC 8446 5.1).
		if c.state != .Failed && c.read_epoch != epoch && queue_len(&c.handshake) > 0 {
			fail(c, .Unexpected_Message, .Unexpected_Message)
		}
	}
}

@(private)
receive_handshake :: proc(c: ^Client, type: Handshake_Type, body: []u8, message: []u8) {
	switch c.state {
	case .Wait_Server_Hello:
		if type == .Server_Hello {
			receive_server_hello(c, body, message)
			return
		}
	case .Handshaking:
		// TLS 1.2 servers may ask to renegotiate at any time; it is never accepted (and never in the transcript).
		if c.version == LEGACY_VERSION_TLS12 && type == .Hello_Request && len(body) == 0 do return
		for c.step < len(c.flight) {
			step := c.flight[c.step]
			c.step += 1
			if step.type == type {
				step.receive(c, body, message)
				return
			}
			if !step.optional do break
		}
	case .Connected, .Closed:
		if c.version == LEGACY_VERSION_TLS12 {
			if type == .Hello_Request && len(body) == 0 {
				send_alert(c, .Warning, .No_Renegotiation)
				return
			}
			break
		}
		#partial switch type {
		case .New_Session_Ticket:
			return // ZZ-Replace: kept for resumption once it exists; dropped for now
		case .Key_Update:
			receive_key_update(c, body)
			return
		}
	case .Failed:
		return
	}
	fail(c, .Unexpected_Message, .Unexpected_Message)
}

// What a ServerHello says, read once; the version it picks then decides which rules apply.
@(private)
Server_Hello :: struct {
	random:      []u8,
	session:     []u8,
	suite:       Cipher_Suite,
	version:     u16, // from supported_versions; 0 if absent (TLS 1.2 and older)
	share_group: Named_Group,
	share_key:   []u8,
	cookie:      []u8,
	alpn:        []u8,
	is_retry:    bool,
	extended_master_secret, renegotiation_ok, sent_tls13_only, sent_tls12_only: bool,
	point_formats_ok: bool,
}

@(private)
receive_server_hello :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	legacy_version := read_u16(&r)
	hello: Server_Hello
	hello.random = read_bytes(&r, RANDOM_SIZE)
	hello.session = read_block(&r, 1).data
	hello.suite = Cipher_Suite(read_u16(&r))
	compression := read_u8(&r)
	extensions := read_block(&r, 2)
	if !reader_done(&r) {
		fail(c, .Decode, .Decode_Error)
		return
	}
	if compression != 0 {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	hello.is_retry = bytes_equal(hello.random, HELLO_RETRY_REQUEST_RANDOM[:])
	hello.point_formats_ok = true

	seen: bit_set[0 ..< 64]
	renegotiation_seen := false
	for reader_left(&extensions) > 0 && extensions.ok {
		ext_type := Extension_Type(read_u16(&extensions))
		data := read_block(&extensions, 2)
		if int(ext_type) < 64 {
			if int(ext_type) in seen { fail(c, .Illegal_Parameter, .Illegal_Parameter); return }
			seen += {int(ext_type)}
		}
		#partial switch ext_type {
		case .Supported_Versions:
			hello.version = read_u16(&data)
			hello.sent_tls13_only = true
		case .Key_Share:
			hello.share_group = Named_Group(read_u16(&data))
			if !hello.is_retry do hello.share_key = read_block(&data, 2).data
			hello.sent_tls13_only = true
		case .Cookie:
			if !hello.is_retry { fail(c, .Unsupported_Extension, .Unsupported_Extension); return }
			hello.cookie = read_block(&data, 2).data
		case .Extended_Master_Secret:
			hello.extended_master_secret = true
			hello.sent_tls12_only = true
		case .Renegotiation_Info:
			if renegotiation_seen { fail(c, .Illegal_Parameter, .Illegal_Parameter); return }
			renegotiation_seen = true
			hello.renegotiation_ok = len(read_block(&data, 1).data) == 0 // first handshake: must be empty
			hello.sent_tls12_only = true
		case .EC_Point_Formats:
			formats := read_block(&data, 1)
			hello.point_formats_ok = false
			for b in formats.data do if b == EC_POINT_FORMAT_UNCOMPRESSED do hello.point_formats_ok = true
			hello.sent_tls12_only = true
		case .Server_Name:
			hello.sent_tls12_only = true // an empty acknowledgement, TLS 1.2 style
		case .ALPN:
			hello.alpn = data.data
			data.at = len(data.data)
			hello.sent_tls12_only = true // TLS 1.3 puts ALPN in EncryptedExtensions
		case:
			fail(c, .Unsupported_Extension, .Unsupported_Extension) // includes pre_shared_key: none offered
			return
		}
		if !reader_done(&data) { fail(c, .Decode, .Decode_Error); return }
	}
	if !extensions.ok { fail(c, .Decode, .Decode_Error); return }

	info, known := suite_info(hello.suite)
	offered_suite := false
	for s in CIPHER_SUITES do if s == hello.suite do offered_suite = true
	if !known || !offered_suite {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}

	switch {
	case hello.version == PROTOCOL_VERSION_TLS13:
		if legacy_version != LEGACY_VERSION_TLS12 || info.version != PROTOCOL_VERSION_TLS13 || hello.sent_tls12_only ||
		   len(hello.session) != SESSION_ID_SIZE || !bytes_equal(hello.session, c.session_id[:]) {
			fail(c, .Illegal_Parameter, .Illegal_Parameter)
			return
		}
		receive_server_hello_tls13(c, &hello, info, message)
	case hello.version == 0 && legacy_version == LEGACY_VERSION_TLS12:
		if hello.is_retry || c.retried || info.version != LEGACY_VERSION_TLS12 || hello.sent_tls13_only {
			fail(c, .Illegal_Parameter, .Illegal_Parameter) // a retry is TLS 1.3 only, and so is what follows one
			return
		}
		receive_server_hello_tls12(c, &hello, info, message)
	case hello.version == 0 && legacy_version < LEGACY_VERSION_TLS12:
		fail(c, .Needs_Older_Version, .Protocol_Version)
	case:
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
	}
}

// ALPN, in TLS 1.3's EncryptedExtensions or TLS 1.2's ServerHello: one name, one we offered.
@(private)
accept_alpn :: proc(c: ^Client, data: []u8) -> bool {
	if len(c.config.alpn) == 0 {
		fail(c, .Unsupported_Extension, .Unsupported_Extension)
		return false
	}
	r := reader_make(data)
	list := read_block(&r, 2)
	name := read_block(&list, 1)
	if !reader_done(&r) || !reader_done(&list) || len(name.data) == 0 {
		fail(c, .Decode, .Decode_Error)
		return false
	}
	for protocol, i in c.config.alpn {
		if bytes_equal(transmute([]u8)protocol, name.data) do c.alpn_chosen = i
	}
	if c.alpn_chosen < 0 {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return false
	}
	return true
}

// ---- TLS 1.3 ----

@(private)
receive_server_hello_tls13 :: proc(c: ^Client, hello: ^Server_Hello, info: Suite_Info, message: []u8) {
	if c.retried && hello.suite != c.suite {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	c.version, c.suite, c.info = PROTOCOL_VERSION_TLS13, hello.suite, info

	if hello.is_retry {
		supported := false
		for g in supported_groups(&c.shares) do if g == hello.share_group do supported = true
		// A retry must change something: a group we didn't already send, or a cookie.
		if c.retried || !supported || (key_share_offered(&c.shares, hello.share_group) && hello.cookie == nil) {
			fail(c, .Illegal_Parameter, .Illegal_Parameter)
			return
		}
		c.retried = true
		if !key_shares_retry(&c.shares, hello.share_group) {
			fail(c, .Internal, .Internal_Error)
			return
		}
		clear(&c.cookie)
		append(&c.cookie, ..hello.cookie)
		transcript_start(c)
		transcript_restart_after_retry(c)
		transcript_add(c, message)
		write_client_hello(c, &c.first_hello)
		transcript_add(c, c.first_hello[:])
		write_record(c, .Handshake, c.first_hello[:])
		return
	}

	if hello.share_group == .None || !key_share_offered(&c.shares, hello.share_group) {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	shared: [MAX_SHARED_KEY_SIZE]u8
	shared_size, agreed := key_share_finish(&c.shares, hello.share_group, hello.share_key, &shared)
	if !agreed {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	c.group = hello.share_group
	key_shares_clear(&c.shares)

	if !c.retried do transcript_start(c)
	transcript_add(c, message)
	delete(c.first_hello)
	c.first_hello = nil

	c.handshake_secret = handshake_secret(info.hash, shared[:shared_size])
	crypto.zero_explicit(&shared, size_of(shared))
	hello_hash := transcript_hash(c)
	c.client_handshake = derive_secret(info.hash, secret_bytes(&c.handshake_secret), "c hs traffic", secret_bytes(&hello_hash))
	c.server_handshake = derive_secret(info.hash, secret_bytes(&c.handshake_secret), "s hs traffic", secret_bytes(&hello_hash))
	set_read_keys(c, c.server_handshake)
	c.flight, c.step = FLIGHT_TLS13[:], 0
	c.state = .Handshaking
}

@(private)
receive_encrypted_extensions :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	extensions := read_block(&r, 2)
	if !reader_done(&r) { fail(c, .Decode, .Decode_Error); return }
	seen: bit_set[0 ..< 64]
	for reader_left(&extensions) > 0 && extensions.ok {
		ext_type := Extension_Type(read_u16(&extensions))
		data := read_block(&extensions, 2)
		if int(ext_type) < 64 {
			if int(ext_type) in seen { fail(c, .Illegal_Parameter, .Illegal_Parameter); return }
			seen += {int(ext_type)}
		}
		#partial switch ext_type {
		case .Server_Name:
			if len(data.data) != 0 { fail(c, .Decode, .Decode_Error); return } // only an empty acknowledgement
		case .Supported_Groups:
			data.at = len(data.data) // the server's preferences, for next time
		case .ALPN:
			if !accept_alpn(c, data.data) do return
			data.at = len(data.data)
		case:
			fail(c, .Unsupported_Extension, .Unsupported_Extension)
			return
		}
		if !reader_done(&data) { fail(c, .Decode, .Decode_Error); return }
	}
	if !extensions.ok { fail(c, .Decode, .Decode_Error); return }
	transcript_add(c, message)
}

@(private)
receive_certificate_request :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	request_context := read_block(&r, 1)
	_ = read_block(&r, 2) // extensions: we answer with no certificate whatever they ask
	if !reader_done(&r) { fail(c, .Decode, .Decode_Error); return }
	append(&c.certificate_request_context, ..request_context.data)
	c.certificate_requested = true
	transcript_add(c, message)
}

@(private)
receive_certificate :: proc(c: ^Client, body: []u8, message: []u8) {
	receive_certificate_list(c, body, message, tls13_layout = true)
}

// The server's certificate list, both versions: TLS 1.3 wraps it in a request context and gives
// every entry its own extensions; TLS 1.2 has neither. The check after is the same.
@(private)
receive_certificate_list :: proc(c: ^Client, body: []u8, message: []u8, tls13_layout: bool) {
	// The chain's parsed certificates point into the message, so it is kept.
	append(&c.certificate_message, ..body)
	r := reader_make(c.certificate_message[:])
	if tls13_layout {
		request_context := read_block(&r, 1)
		if len(request_context.data) != 0 { fail(c, .Decode, .Decode_Error); return }
	}
	list := read_block(&r, 3)
	if !reader_done(&r) {
		fail(c, .Decode, .Decode_Error)
		return
	}
	entries: [MAX_CHAIN_CERTIFICATES + 1][]u8
	count := 0
	for reader_left(&list) > 0 && list.ok {
		der := read_block(&list, 3)
		if tls13_layout do _ = read_block(&list, 2) // per-certificate extensions (OCSP, SCT): not checked yet
		if len(der.data) == 0 { fail(c, .Decode, .Decode_Error); return }
		if count == len(entries) { count += 1; break }
		entries[count] = der.data
		count += 1
	}
	if !list.ok { fail(c, .Decode, .Decode_Error); return }
	if count > MAX_CHAIN_CERTIFICATES {
		c.certificate_problem = .Too_Long
		fail(c, .Certificate, .Bad_Certificate)
		return
	}
	now := c.config.now
	if now == {} do now = time.now()
	problem := check_chain(&c.chain, entries[:count], c.config.anchors, c.config.server_name, now)
	if problem == .None do problem = check_suite_key(&c.chain.certificates[0], c.info.auth)
	if problem != .None {
		c.certificate_problem = problem
		fail(c, .Certificate, alert_for_problem(problem))
		return
	}
	transcript_add(c, message)
}

// Reads a signature scheme and signature, checks the scheme was offered, and the signature
// over `content` with the leaf's key. Both versions' proof of the private key go through here.
@(private)
receive_signature :: proc(c: ^Client, r: ^Reader, content: []u8, tls12: bool) -> bool {
	scheme := Signature_Scheme(read_u16(r))
	signature := read_block(r, 2)
	if !reader_done(r) { fail(c, .Decode, .Decode_Error); return false }
	offered := false
	for s in SIGNATURE_SCHEMES do if s == scheme do offered = true
	if !offered { fail(c, .Illegal_Parameter, .Illegal_Parameter); return false }
	problem := check_signature(&c.chain.certificates[0], scheme, content, signature.data, tls12)
	if problem != .None {
		c.certificate_problem = problem
		fail(c, .Certificate, alert_for_problem(problem))
		return false
	}
	return true
}

@(private)
receive_certificate_verify :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	signed := transcript_hash(c)
	content: [CERTIFICATE_VERIFY_CONTENT_MAX]u8
	if !receive_signature(c, &r, certificate_verify_content(&content, secret_bytes(&signed)), tls12 = false) do return
	transcript_add(c, message)
}

// The two Finished checks are the same stage: the server's value against ours, constant time.
@(private)
finished_matches :: proc(c: ^Client, body: []u8, expected: []u8) -> bool {
	if len(body) != len(expected) || crypto.compare_constant_time(body, expected) != 1 {
		fail(c, .Finished_Mismatch, .Decrypt_Error)
		return false
	}
	return true
}

@(private)
receive_finished :: proc(c: ^Client, body: []u8, message: []u8) {
	info := c.info
	before := transcript_hash(c)
	expected := finished_verify_data(info.hash, secret_bytes(&c.server_handshake), secret_bytes(&before))
	if !finished_matches(c, body, secret_bytes(&expected)) do return
	transcript_add(c, message)

	// Application secrets cover the transcript up to the server's Finished.
	master := master_secret(info.hash, &c.handshake_secret)
	through_server := transcript_hash(c)
	client_application := derive_secret(info.hash, secret_bytes(&master), "c ap traffic", secret_bytes(&through_server))
	server_application := derive_secret(info.hash, secret_bytes(&master), "s ap traffic", secret_bytes(&through_server))
	crypto.zero_explicit(&master, size_of(master))

	// Our flight: the compatibility ChangeCipherSpec, an empty Certificate if one was asked
	// for, then Finished, all but the first under the client handshake keys.
	write_change_cipher_spec(c)
	traffic_keys_set(&c.write_keys, info, c.client_handshake)
	if c.certificate_requested do write_empty_certificate(c, tls13_layout = true)
	through_client := transcript_hash(c)
	verify := finished_verify_data(info.hash, secret_bytes(&c.client_handshake), secret_bytes(&through_client))
	write_finished(c, secret_bytes(&verify))

	traffic_keys_set(&c.write_keys, info, client_application)
	set_read_keys(c, server_application)
	crypto.zero_explicit(&client_application, size_of(Secret))
	crypto.zero_explicit(&server_application, size_of(Secret))
	crypto.zero_explicit(&c.handshake_secret, size_of(Secret))
	crypto.zero_explicit(&c.client_handshake, size_of(Secret))
	crypto.zero_explicit(&c.server_handshake, size_of(Secret))
	handshake_done(c)
}

// ---- our messages, both versions ----

@(private)
write_change_cipher_spec :: proc(c: ^Client) {
	header := [RECORD_HEADER_SIZE]u8{u8(Content_Type.Change_Cipher_Spec), 3, 3, 0, 1}
	body := [1]u8{1}
	queue_push(&c.outgoing, header[:])
	queue_push(&c.outgoing, body[:])
}

// We have no client certificates: an empty list when asked (TLS 1.3 echoes the request context).
@(private)
write_empty_certificate :: proc(c: ^Client, tls13_layout: bool) {
	empty: [dynamic]u8
	defer delete(empty)
	w := Writer{&empty}
	write_u8(w, u8(Handshake_Type.Certificate))
	m := block_begin(w, 3)
	if tls13_layout do write_block(w, 1, c.certificate_request_context[:])
	write_u24(w, 0)
	block_end(w, m, 3)
	transcript_add(c, empty[:])
	write_record(c, .Handshake, empty[:])
}

@(private)
write_finished :: proc(c: ^Client, verify_data: []u8) {
	finished: [HANDSHAKE_HEADER_SIZE + MAX_HASH_SIZE]u8
	finished[0] = u8(Handshake_Type.Finished)
	finished[3] = u8(len(verify_data))
	copy(finished[HANDSHAKE_HEADER_SIZE:], verify_data)
	message := finished[:HANDSHAKE_HEADER_SIZE + len(verify_data)]
	transcript_add(c, message) // TLS 1.2's server Finished covers ours (1.3's application keys are already derived)
	write_record(c, .Handshake, message)
}

@(private)
handshake_done :: proc(c: ^Client) {
	key_shares_clear(&c.shares)
	hash.reset(&c.transcript)
	c.transcript_on = false
	c.flight, c.step = nil, 0
	c.state = .Connected
}

KEY_UPDATE_NOT_REQUESTED :: u8(0)
KEY_UPDATE_REQUESTED     :: u8(1)

@(private)
receive_key_update :: proc(c: ^Client, body: []u8) {
	if len(body) != 1 || body[0] > KEY_UPDATE_REQUESTED {
		fail(c, .Decode, .Decode_Error)
		return
	}
	traffic_keys_update(&c.read_keys, c.info)
	c.read_epoch += 1
	if body[0] == KEY_UPDATE_REQUESTED && c.state == .Connected {
		answer := [HANDSHAKE_HEADER_SIZE + 1]u8{u8(Handshake_Type.Key_Update), 0, 0, 1, KEY_UPDATE_NOT_REQUESTED}
		write_record(c, .Handshake, answer[:])
		traffic_keys_update(&c.write_keys, c.info)
	}
}

bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) do if a[i] != b[i] do return false
	return true
}
