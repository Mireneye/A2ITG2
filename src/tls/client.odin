// A TLS client, sans-IO: it owns no socket, no thread and no clock of its own.
//
//     client_init(&c, config)          the ClientHello is now in client_output
//     loop:
//         send client_output(&c), then client_output_done(&c, sent)
//         client_receive(&c, bytes_from_the_socket)
//         when c.state == .Connected: client_send(&c, request); read client_data(&c)
//     client_close(&c), client_destroy(&c)
//
// TLS 1.3 (RFC 8446), and a strict TLS 1.2 for servers that never moved on (tls12.odin: ECDHE
// with AEADs only, extended master secret and secure renegotiation required). One hello offers
// both, so a 1.3 server never pays for 1.2. Not here yet: resumption and early data (tickets
// are read and dropped), client certificates (an empty one is sent if asked).
package tls

import "core:crypto"
import "core:crypto/hash"
import "core:time"

MAX_ALPN_PROTOCOLS :: 4

Config :: struct {
	server_name: string,          // checked against the certificate and sent as SNI (unless an IP)
	alpn:        []string,        // e.g. {"http/1.1"}; empty sends no ALPN. Must outlive the client.
	anchors:     ^Trust_Anchors,  // required: there is no "don't check" switch
	now:         time.Time,       // zero: the system clock when the certificate is checked
	classical:   bool,            // no post-quantum share in the hello: the fallback for servers and
	                              // middleboxes that choke on its size (about 1.2 KB more)
}

State :: enum u8 {
	Wait_Server_Hello,
	Handshaking,                 // the server hello chose the version; its message table runs
	Connected,
	Closed,                      // close_notify received (and data before it delivered)
	Failed,
}

Failure :: enum u8 {
	None,
	Decode,                // malformed message or record
	Unexpected_Message,
	Bad_Record_MAC,        // a record failed authentication
	Record_Overflow,
	Needs_Older_Version,   // the server only speaks TLS 1.1 or older
	Legacy_Unsafe,         // a TLS 1.2 server without extended master secret or secure renegotiation
	No_Common_Parameters,  // no shared cipher suite, group or signature scheme
	Illegal_Parameter,
	Unsupported_Extension,
	Certificate,           // see Client.certificate_problem
	Finished_Mismatch,
	Remote_Alert,          // see Client.remote_alert
	Internal,
	Not_Connected,         // client_send before the handshake finished or after it ended
}

// One expected server message: its type, whether it may be absent, and what reads it. Each
// version has its own fixed list (FLIGHT_TLS13, FLIGHT_TLS12), chosen once by the server hello
// and walked in order, so a server can't skip or repeat a message by construction.
Step :: struct {
	type:     Handshake_Type,
	optional: bool,
	receive:  proc(c: ^Client, body, message: []u8),
}

Client :: struct {
	config:  Config,
	state:   State,
	failure: Failure,
	certificate_problem: Certificate_Problem,
	remote_alert:        Alert_Description,

	version: u16, // chosen by the server hello: PROTOCOL_VERSION_TLS13 or LEGACY_VERSION_TLS12
	suite:   Cipher_Suite,
	info:    Suite_Info,
	group:   Named_Group,
	alpn_chosen: int, // index into config.alpn, -1 if none
	flight:  []Step,
	step:    int,

	random:        [RANDOM_SIZE]u8,
	server_random: [RANDOM_SIZE]u8,
	session_id:    [SESSION_ID_SIZE]u8,
	shares:        Key_Shares,
	cookie:        [dynamic]u8,
	retried:       bool, // a HelloRetryRequest came already (a second one is an error)

	first_hello:   [dynamic]u8, // ClientHello bytes kept until the suite (and so the hash) is known
	transcript:    hash.Context,
	transcript_on: bool,

	handshake_secret:  Secret, // TLS 1.3
	client_handshake:  Secret, // TLS 1.3
	server_handshake:  Secret, // TLS 1.3
	tls12: TLS12_State,
	read_keys, write_keys: Traffic_Keys,
	read_epoch: int, // counts read key changes: a message after which it moves must end its record
	early_change_cipher_spec: bool, // one came before the server's hello

	incoming:  Byte_Queue, // raw bytes, not yet a whole record
	handshake: Byte_Queue, // handshake bytes, not yet a whole message
	outgoing:  Byte_Queue, // records to send
	received:  Byte_Queue, // decrypted application data

	certificate_message: [dynamic]u8, // the chain points into this
	chain:               Server_Chain,
	certificate_requested: bool,
	certificate_request_context: [dynamic]u8,
}

client_init :: proc(c: ^Client, config: Config) -> bool {
	c^ = {}
	c.config = config
	c.alpn_chosen = -1
	if config.anchors == nil || len(config.alpn) > MAX_ALPN_PROTOCOLS {
		c.state, c.failure = .Failed, .Internal
		return false
	}
	crypto.rand_bytes(c.random[:])
	crypto.rand_bytes(c.session_id[:])
	if !key_shares_generate(&c.shares, config.classical) {
		c.state, c.failure = .Failed, .Internal
		return false
	}
	write_client_hello(c, &c.first_hello)
	write_record(c, .Handshake, c.first_hello[:], first = true)
	c.state = .Wait_Server_Hello
	return true
}

client_destroy :: proc(c: ^Client) {
	key_shares_clear(&c.shares)
	traffic_keys_clear(&c.read_keys)
	traffic_keys_clear(&c.write_keys)
	tls12_state_clear(&c.tls12)
	crypto.zero_explicit(&c.handshake_secret, size_of(Secret))
	crypto.zero_explicit(&c.client_handshake, size_of(Secret))
	crypto.zero_explicit(&c.server_handshake, size_of(Secret))
	if c.transcript_on do hash.reset(&c.transcript)
	server_chain_destroy(&c.chain)
	delete(c.cookie)
	delete(c.first_hello)
	delete(c.certificate_message)
	delete(c.certificate_request_context)
	queue_destroy(&c.incoming)
	queue_destroy(&c.handshake)
	queue_destroy(&c.outgoing)
	queue_destroy(&c.received)
}

client_output      :: proc(c: ^Client) -> []u8 { return queue_bytes(&c.outgoing) }
client_output_done :: proc(c: ^Client, count: int) { queue_consume(&c.outgoing, count) }
client_data        :: proc(c: ^Client) -> []u8 { return queue_bytes(&c.received) }
client_data_done   :: proc(c: ^Client, count: int) { queue_consume(&c.received, count) }

client_alpn :: proc(c: ^Client) -> string {
	return c.config.alpn[c.alpn_chosen] if c.alpn_chosen >= 0 else ""
}

// Bytes from the socket. Processes every whole record in them; the rest waits for more.
client_receive :: proc(c: ^Client, bytes: []u8) {
	if c.state == .Failed || c.state == .Closed do return
	queue_push(&c.incoming, bytes)
	for c.state != .Failed && c.state != .Closed {
		pending := queue_bytes(&c.incoming)
		if len(pending) < RECORD_HEADER_SIZE do return
		type := Content_Type(pending[0])
		length := int(pending[3]) << 8 | int(pending[4])
		if length > MAX_CIPHERTEXT {
			fail(c, .Record_Overflow, .Record_Overflow)
			return
		}
		if len(pending) < RECORD_HEADER_SIZE + length do return
		header := pending[:RECORD_HEADER_SIZE]
		payload := pending[RECORD_HEADER_SIZE:][:length]
		receive_record(c, type, header, payload)
		queue_consume(&c.incoming, RECORD_HEADER_SIZE + length)
	}
}

// Application data, split into records and encrypted into client_output.
client_send :: proc(c: ^Client, data: []u8) -> bool {
	if c.state != .Connected {
		if c.failure == .None do c.failure = .Not_Connected
		return false
	}
	rest := data
	for len(rest) > 0 {
		count := min(len(rest), MAX_PLAINTEXT)
		write_record(c, .Application_Data, rest[:count])
		rest = rest[count:]
	}
	return true
}

// Says goodbye (close_notify). Data already received stays readable.
client_close :: proc(c: ^Client) {
	if c.state == .Connected || c.state == .Closed {
		send_alert(c, .Warning, .Close_Notify)
	}
	if c.state == .Connected do c.state = .Closed
}

// ---- records ----

@(private)
receive_record :: proc(c: ^Client, type: Content_Type, header: []u8, payload: []u8) {
	// TLS 1.2 authenticates the negotiated version, not the header's bytes, so the header must
	// carry it (TLS 1.3 authenticates the header itself and ignores its version otherwise).
	if c.version == LEGACY_VERSION_TLS12 && (u16(header[1]) << 8 | u16(header[2])) != LEGACY_VERSION_TLS12 {
		fail(c, .Decode, .Protocol_Version)
		return
	}
	if type == .Change_Cipher_Spec {
		if len(payload) != 1 || payload[0] != 1 {
			fail(c, .Unexpected_Message, .Unexpected_Message)
		} else if c.version == LEGACY_VERSION_TLS12 {
			tls12_receive_change_cipher_spec(c) // TLS 1.2: the server's keys start here
		} else if c.state >= .Connected {
			fail(c, .Unexpected_Message, .Unexpected_Message) // TLS 1.3: only the compatibility byte, only in the handshake
		} else if c.state == .Wait_Server_Hello {
			c.early_change_cipher_spec = true // fine for 1.3 (dropped); a 1.2 server is then refused
		}
		return
	}
	content := payload
	inner_type := type
	plaintext: [MAX_CIPHERTEXT]u8 = ---
	used := 0
	defer crypto.zero_explicit(&plaintext, used) // only what was decrypted into it
	if c.read_keys.active {
		failure: Failure
		used = len(payload)
		inner_type, content, failure = open_record(&c.read_keys, type, header, payload, plaintext[:])
		if failure != .None {
			fail(c, failure, .Bad_Record_MAC if failure == .Bad_Record_MAC else .Unexpected_Message)
			return
		}
	}
	if len(content) > MAX_PLAINTEXT {
		fail(c, .Record_Overflow, .Record_Overflow)
		return
	}
	#partial switch inner_type {
	case .Handshake:
		if len(content) == 0 {
			fail(c, .Unexpected_Message, .Unexpected_Message)
			return
		}
		queue_push(&c.handshake, content)
		receive_handshake_messages(c)
	case .Alert:
		receive_alert(c, content)
	case .Application_Data:
		if c.state != .Connected || !c.read_keys.active {
			fail(c, .Unexpected_Message, .Unexpected_Message)
			return
		}
		queue_push(&c.received, content)
	case:
		fail(c, .Unexpected_Message, .Unexpected_Message)
	}
}

@(private)
receive_alert :: proc(c: ^Client, content: []u8) {
	if len(content) != 2 {
		fail(c, .Decode, .Decode_Error)
		return
	}
	level := Alert_Level(content[0])
	description := Alert_Description(content[1])
	if description == .Close_Notify {
		c.state = .Closed
		return
	}
	// TLS 1.3: every alert but close_notify ends it (user_canceled precedes one). TLS 1.2 also
	// has warnings that don't, e.g. a server declining renegotiation.
	if description == .User_Canceled do return
	if level == .Warning && c.version == LEGACY_VERSION_TLS12 do return
	c.remote_alert = description
	c.failure = .Remote_Alert
	c.state = .Failed
}

@(private)
send_alert :: proc(c: ^Client, level: Alert_Level, description: Alert_Description) {
	alert := [2]u8{u8(level), u8(description)}
	write_record(c, .Alert, alert[:])
}

// Ends the connection on our side, with the alert written out for the caller to send.
@(private)
fail :: proc(c: ^Client, failure: Failure, alert: Alert_Description) {
	if c.state == .Failed do return
	c.failure = failure
	send_alert(c, .Fatal, alert)
	c.state = .Failed
}

// New read keys, counted so a message after which they changed can't share its record.
@(private)
set_read_keys :: proc(c: ^Client, secret: Secret) {
	traffic_keys_set(&c.read_keys, c.info, secret)
	c.read_epoch += 1
}

// ---- the transcript ----

@(private)
transcript_add :: proc(c: ^Client, message: []u8) {
	hash.update(&c.transcript, message)
}

@(private)
transcript_hash :: proc(c: ^Client) -> (out: Secret) {
	out.size = hash.DIGEST_SIZES[c.info.hash]
	hash.final(&c.transcript, out.data[:out.size], finalize_clone = true)
	return
}

// Starts the running hash once the server picked the suite; the ClientHello kept so far goes in first.
@(private)
transcript_start :: proc(c: ^Client) {
	hash.init(&c.transcript, c.info.hash)
	c.transcript_on = true
	transcript_add(c, c.first_hello[:])
}

// After a HelloRetryRequest the first ClientHello is replaced by a message_hash of it.
@(private)
transcript_restart_after_retry :: proc(c: ^Client) {
	first := transcript_hash(c)
	hash.reset(&c.transcript)
	hash.init(&c.transcript, c.info.hash)
	stand_in := [HANDSHAKE_HEADER_SIZE]u8{u8(Handshake_Type.Message_Hash), 0, 0, u8(first.size)}
	transcript_add(c, stand_in[:])
	transcript_add(c, secret_bytes(&first))
}
