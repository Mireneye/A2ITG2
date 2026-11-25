// Records, both versions: one path that seals and opens them, with the three layouts of
// Record_Format as the only difference (where the nonce comes from, what the AAD holds, where
// the content type lives).
package tls

import "core:crypto/aead"

EXPLICIT_NONCE_SIZE :: 8 // TLS 1.2 AES-GCM: the per-record part of the nonce, sent in front

// A record into client_output, sealed if the write keys are on.
@(private)
write_record :: proc(c: ^Client, type: Content_Type, content: []u8, first := false) {
	out := &c.outgoing.data
	keys := &c.write_keys
	if !keys.active {
		version := LEGACY_VERSION_TLS10 if first else LEGACY_VERSION_TLS12
		append(out, u8(type), u8(version >> 8), u8(version & 0xFF), u8(len(content) >> 8), u8(len(content)))
		append(out, ..content)
		return
	}
	inner := 1 if keys.format == .TLS13 else 0 // TLS 1.3 hides the real type inside
	explicit := EXPLICIT_NONCE_SIZE if keys.format == .TLS12_Explicit else 0
	outer_type := Content_Type.Application_Data if keys.format == .TLS13 else type
	sealed_size := explicit + len(content) + inner + AEAD_TAG_SIZE

	start := len(out)
	append(out, u8(outer_type), u8(LEGACY_VERSION_TLS12 >> 8), u8(LEGACY_VERSION_TLS12 & 0xFF),
		u8(sealed_size >> 8), u8(sealed_size))
	// Our explicit nonce is the record counter: unique under one key, which is all GCM needs.
	// With the salt in iv[:4] and zeros after, traffic_nonce then gives exactly salt + counter.
	for i in 0 ..< explicit do append(out, u8(keys.sequence >> uint(8 * (EXPLICIT_NONCE_SIZE - 1 - i))))
	append(out, ..content)
	if inner == 1 do append(out, u8(type))
	resize(out, start + RECORD_HEADER_SIZE + sealed_size)

	body_start := start + RECORD_HEADER_SIZE + explicit
	body := out[body_start:][:len(content) + inner]
	tag := out[body_start + len(body):][:AEAD_TAG_SIZE]
	nonce := traffic_nonce(keys)
	aad: [TLS12_AAD_SIZE]u8
	aad_bytes := out[start:][:RECORD_HEADER_SIZE] if keys.format == .TLS13 else tls12_aad(&aad, keys.sequence, type, len(content))
	aead.seal_ctx(&keys.cipher, body, tag, nonce[:], aad_bytes, body)
	keys.sequence += 1
}

TLS12_AAD_SIZE :: 13 // counter (8), type, version (2), plaintext length (2)

@(private)
tls12_aad :: proc(aad: ^[TLS12_AAD_SIZE]u8, sequence: u64, type: Content_Type, length: int) -> []u8 {
	for i in 0 ..< 8 do aad[i] = u8(sequence >> uint(8 * (7 - i)))
	aad[8] = u8(type)
	aad[9], aad[10] = u8(LEGACY_VERSION_TLS12 >> 8), u8(LEGACY_VERSION_TLS12 & 0xFF)
	aad[11], aad[12] = u8(length >> 8), u8(length)
	return aad[:]
}

// Opens a sealed record into `plaintext`: its real type and content, or ok = false (and the
// caller fails the connection) if it was malformed or did not authenticate.
@(private)
open_record :: proc(keys: ^Traffic_Keys, type: Content_Type, header, payload: []u8, plaintext: []u8) -> (inner_type: Content_Type, content: []u8, failure: Failure) {
	explicit := EXPLICIT_NONCE_SIZE if keys.format == .TLS12_Explicit else 0
	minimum := explicit + AEAD_TAG_SIZE + (1 if keys.format == .TLS13 else 0)
	if len(payload) < minimum do return .Invalid, nil, .Unexpected_Message
	if keys.format == .TLS13 {
		if type != .Application_Data do return .Invalid, nil, .Unexpected_Message
	} else if type != .Handshake && type != .Alert && type != .Application_Data {
		return .Invalid, nil, .Unexpected_Message
	}
	sealed := payload[explicit:len(payload) - AEAD_TAG_SIZE]
	tag := payload[len(payload) - AEAD_TAG_SIZE:]
	nonce := traffic_nonce(keys)
	if explicit > 0 do copy(nonce[AEAD_NONCE_SIZE - EXPLICIT_NONCE_SIZE:], payload[:EXPLICIT_NONCE_SIZE])
	aad: [TLS12_AAD_SIZE]u8
	aad_bytes := header if keys.format == .TLS13 else tls12_aad(&aad, keys.sequence, type, len(sealed))
	out := plaintext[:len(sealed)]
	copy(out, sealed)
	if !aead.open_ctx(&keys.cipher, out, nonce[:], aad_bytes, out, tag) do return .Invalid, nil, .Bad_Record_MAC
	keys.sequence += 1
	if keys.format != .TLS13 do return type, out, .None
	// TLSInnerPlaintext: content, the real type, then zero padding.
	end := len(out)
	for end > 0 && out[end - 1] == 0 do end -= 1
	if end == 0 do return .Invalid, nil, .Unexpected_Message
	return Content_Type(out[end - 1]), out[:end - 1], .None
}
