// ZZ-Deprecate: TLS 1.2, only for servers that never moved to 1.3 (1 of 30 sites in the first
// run, 2026-11-16). Deleting this file, FLIGHT_TLS12's users and the six 1.2 suites in
// CIPHER_SUITES / suite_info takes it out; TLS 1.3 doesn't depend on any of it.
//
// Strict by refusal: ECDHE only (forward secrecy; no RSA key exchange), AEADs only (no CBC),
// no compression, no renegotiation, and extended master secret plus secure renegotiation
// required (RFC 7627, RFC 5746). What is here is 1.2's own: its PRF and key block, its message
// order, ServerKeyExchange and our ClientKeyExchange. Records, certificates, signatures, key
// exchange and Finished go through the stages both versions share.
package tls

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"

TLS12_MASTER_SECRET_SIZE :: 48
TLS12_VERIFY_DATA_SIZE   :: 12
CURVE_TYPE_NAMED         :: u8(3)

// The server's messages after its hello. The server's ChangeCipherSpec (a record, not a
// message) comes between ServerHelloDone and Finished, and Finished is refused without it.
FLIGHT_TLS12 := [?]Step{
	{.Certificate,         false, receive_certificate_tls12},
	{.Server_Key_Exchange, false, receive_server_key_exchange},
	{.Certificate_Request, true,  receive_certificate_request_tls12},
	{.Server_Hello_Done,   false, receive_server_hello_done},
	{.Finished,            false, receive_finished_tls12},
}

TLS12_State :: struct {
	pre_master: Secret,
	master:     [TLS12_MASTER_SECRET_SIZE]u8,
	read_pending: bool, // the server's keys are in read_keys, switched off until its ChangeCipherSpec
	client_public: [1 + 2 * 48]u8, // our ECDHE share for ClientKeyExchange
	client_public_size: int,
}

tls12_state_clear :: proc(s: ^TLS12_State) {
	crypto.zero_explicit(s, size_of(s^))
}

// P_hash (RFC 5246 5): HMAC chained over label + seed until dst is full.
tls12_prf :: proc(algorithm: hash.Algorithm, secret: []u8, label: string, dst: []u8, seed_parts: ..[]u8) {
	size := hash.DIGEST_SIZES[algorithm]
	a, block: [MAX_HASH_SIZE]u8
	ctx: hmac.Context
	feed_seed :: proc(ctx: ^hmac.Context, label: string, seed_parts: [][]u8) {
		hmac.update(ctx, transmute([]u8)label)
		for part in seed_parts do hmac.update(ctx, part)
	}
	hmac.init(&ctx, algorithm, secret) // A(1) = HMAC(secret, label + seed)
	feed_seed(&ctx, label, seed_parts)
	hmac.final(&ctx, a[:size])
	for filled := 0; filled < len(dst); filled += size {
		hmac.init(&ctx, algorithm, secret)
		hmac.update(&ctx, a[:size])
		feed_seed(&ctx, label, seed_parts)
		hmac.final(&ctx, block[:size])
		copy(dst[filled:], block[:size])
		hmac.init(&ctx, algorithm, secret) // A(i+1) = HMAC(secret, A(i))
		hmac.update(&ctx, a[:size])
		hmac.final(&ctx, a[:size])
	}
	crypto.zero_explicit(&a, size_of(a))
	crypto.zero_explicit(&block, size_of(block))
}

@(private)
receive_server_hello_tls12 :: proc(c: ^Client, hello: ^Server_Hello, info: Suite_Info, message: []u8) {
	// A 1.3 server forced down to 1.2 says so in its random: someone stripped 1.3 from our hello.
	if bytes_equal(hello.random[RANDOM_SIZE - len(DOWNGRADE_TO_TLS12):], DOWNGRADE_TO_TLS12[:]) {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	if c.early_change_cipher_spec { // TLS 1.2 has no compatibility byte: one before the hello is an injection
		fail(c, .Unexpected_Message, .Unexpected_Message)
		return
	}
	if !hello.extended_master_secret || !hello.renegotiation_ok || !hello.point_formats_ok {
		fail(c, .Legacy_Unsafe, .Handshake_Failure)
		return
	}
	if len(hello.session) > SESSION_ID_SIZE {
		fail(c, .Decode, .Decode_Error)
		return
	}
	if hello.alpn != nil && !accept_alpn(c, hello.alpn) do return
	c.version, c.suite, c.info = LEGACY_VERSION_TLS12, hello.suite, info
	copy(c.server_random[:], hello.random)
	transcript_start(c)
	transcript_add(c, message)
	delete(c.first_hello)
	c.first_hello = nil
	c.flight, c.step = FLIGHT_TLS12[:], 0
	c.state = .Handshaking
}

@(private)
receive_certificate_tls12 :: proc(c: ^Client, body: []u8, message: []u8) {
	receive_certificate_list(c, body, message, tls13_layout = false)
}

// The server's ECDHE share, signed over both randoms and the share itself.
@(private)
receive_server_key_exchange :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	curve_type := read_u8(&r)
	group := Named_Group(read_u16(&r))
	server_public := read_block(&r, 1)
	params := body[:r.at]
	if !r.ok || curve_type != CURVE_TYPE_NAMED {
		fail(c, .Decode, .Decode_Error)
		return
	}
	usable := false
	for g in supported_groups(&c.shares) do if g == group && g != .X25519_MLKEM768 do usable = true
	if !usable {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	signed: [2 * RANDOM_SIZE + 4 + 255]u8
	n := copy(signed[:], c.random[:])
	n += copy(signed[n:], c.server_random[:])
	n += copy(signed[n:], params)
	if !receive_signature(c, &r, signed[:n], tls12 = true) do return

	// The X25519 key from our hello serves here too; P-256 / P-384 get a fresh one now.
	if group != .X25519 && !key_shares_retry(&c.shares, group) {
		fail(c, .Internal, .Internal_Error)
		return
	}
	shared: [MAX_SHARED_KEY_SIZE]u8
	shared_size, agreed := key_share_finish(&c.shares, group, server_public.data, &shared)
	if !agreed {
		fail(c, .Illegal_Parameter, .Illegal_Parameter)
		return
	}
	c.tls12.pre_master.size = shared_size
	copy(c.tls12.pre_master.data[:], shared[:shared_size])
	crypto.zero_explicit(&shared, size_of(shared))
	c.tls12.client_public_size = key_share_public(&c.shares, group, c.tls12.client_public[:])
	c.group = group
	transcript_add(c, message)
}

@(private)
receive_certificate_request_tls12 :: proc(c: ^Client, body: []u8, message: []u8) {
	r := reader_make(body)
	_ = read_block(&r, 1) // certificate types
	_ = read_block(&r, 2) // signature schemes
	_ = read_block(&r, 2) // acceptable authorities: we answer with no certificate whatever they ask
	if !reader_done(&r) { fail(c, .Decode, .Decode_Error); return }
	c.certificate_requested = true
	transcript_add(c, message)
}

// The server is done: our flight (an empty Certificate if asked, ClientKeyExchange,
// ChangeCipherSpec, Finished), then we wait for the server's ChangeCipherSpec and Finished.
@(private)
receive_server_hello_done :: proc(c: ^Client, body: []u8, message: []u8) {
	if len(body) != 0 { fail(c, .Decode, .Decode_Error); return }
	transcript_add(c, message)
	if c.certificate_requested do write_empty_certificate(c, tls13_layout = false)

	exchange: [dynamic]u8
	defer delete(exchange)
	w := Writer{&exchange}
	write_u8(w, u8(Handshake_Type.Client_Key_Exchange))
	m := block_begin(w, 3)
	write_block(w, 1, c.tls12.client_public[:c.tls12.client_public_size])
	block_end(w, m, 3)
	transcript_add(c, exchange[:])
	write_record(c, .Handshake, exchange[:])

	// Extended master secret: the master secret covers the whole handshake so far.
	info := c.info
	session_hash := transcript_hash(c)
	tls12_prf(info.hash, secret_bytes(&c.tls12.pre_master), "extended master secret", c.tls12.master[:], secret_bytes(&session_hash))
	crypto.zero_explicit(&c.tls12.pre_master, size_of(Secret))
	key_block: [2 * 32 + 2 * AEAD_NONCE_SIZE]u8
	block := key_block[:2 * info.key_size + 2 * info.iv_size]
	tls12_prf(info.hash, c.tls12.master[:], "key expansion", block, c.server_random[:], c.random[:])
	client_key := block[:info.key_size]
	server_key := block[info.key_size:][:info.key_size]
	client_iv := block[2 * info.key_size:][:info.iv_size]
	server_iv := block[2 * info.key_size + info.iv_size:][:info.iv_size]
	traffic_keys_set_material(&c.read_keys, info, server_key, server_iv)
	c.read_keys.active = false // the server's ChangeCipherSpec turns them on
	c.tls12.read_pending = true

	write_change_cipher_spec(c)
	traffic_keys_set_material(&c.write_keys, info, client_key, client_iv)
	crypto.zero_explicit(&key_block, size_of(key_block))
	through_client := transcript_hash(c)
	verify: [TLS12_VERIFY_DATA_SIZE]u8
	tls12_prf(info.hash, c.tls12.master[:], "client finished", verify[:], secret_bytes(&through_client))
	write_finished(c, verify[:])
}

// The server's ChangeCipherSpec: allowed exactly once, right before its Finished, with no
// handshake bytes left half-read; its keys start here.
tls12_receive_change_cipher_spec :: proc(c: ^Client) {
	expecting_finished := c.state == .Handshaking && c.step < len(c.flight) && c.flight[c.step].type == .Finished
	if !expecting_finished || c.read_keys.active || !c.tls12.read_pending || queue_len(&c.handshake) > 0 {
		fail(c, .Unexpected_Message, .Unexpected_Message)
		return
	}
	c.read_keys.active = true
	c.tls12.read_pending = false
	c.read_epoch += 1
}

@(private)
receive_finished_tls12 :: proc(c: ^Client, body: []u8, message: []u8) {
	if !c.read_keys.active { fail(c, .Unexpected_Message, .Unexpected_Message); return } // no ChangeCipherSpec first
	before := transcript_hash(c)
	expected: [TLS12_VERIFY_DATA_SIZE]u8
	tls12_prf(c.info.hash, c.tls12.master[:], "server finished", expected[:], secret_bytes(&before))
	if !finished_matches(c, body, expected[:]) do return
	tls12_state_clear(&c.tls12)
	handshake_done(c)
}
