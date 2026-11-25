// The TLS 1.3 key schedule (RFC 8446 section 7): secrets derived with HKDF from the shared key
// and the transcript. And the stage both versions share: the traffic keys each direction
// encrypts with (TLS 1.2 derives its keys differently, in tls12.odin, then lands here too).
package tls

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"

MAX_HASH_SIZE :: 48 // SHA-384, the largest a TLS 1.3 suite uses

// How a record is sealed: where its nonce comes from and what it authenticates besides the
// content. The AEAD, the counter and the rest of the record path are the same for all three.
Record_Format :: enum u8 {
	TLS13,          // nonce = IV xor counter; the AAD is the record header; the real type is inside
	TLS12_Explicit, // AES-GCM in 1.2: nonce = 4-byte salt + 8 bytes sent at the front of the record
	TLS12_Implicit, // ChaCha20-Poly1305 in 1.2: nonce = IV xor counter, nothing sent
}

// Which certificate key a suite needs: any (TLS 1.3 says it in CertificateVerify) or the one
// a TLS 1.2 suite names.
Suite_Auth :: enum u8 {
	Any,
	ECDSA,
	RSA,
}

Suite_Info :: struct {
	version:  u16,
	hash:     hash.Algorithm, // TLS 1.3's HKDF hash or TLS 1.2's PRF hash
	aead:     aead.Algorithm,
	key_size: int,
	iv_size:  int,            // what the key schedule hands the record layer
	record:   Record_Format,
	auth:     Suite_Auth,
}

suite_info :: proc(suite: Cipher_Suite) -> (info: Suite_Info, ok: bool) {
	V13 :: PROTOCOL_VERSION_TLS13
	V12 :: LEGACY_VERSION_TLS12
	switch suite {
	case .TLS_AES_128_GCM_SHA256:       return {V13, .SHA256, .AES_GCM_128, 16, 12, .TLS13, .Any}, true
	case .TLS_AES_256_GCM_SHA384:       return {V13, .SHA384, .AES_GCM_256, 32, 12, .TLS13, .Any}, true
	case .TLS_CHACHA20_POLY1305_SHA256: return {V13, .SHA256, .CHACHA20POLY1305, 32, 12, .TLS13, .Any}, true
	case .ECDHE_ECDSA_AES_128_GCM_SHA256:       return {V12, .SHA256, .AES_GCM_128, 16, 4, .TLS12_Explicit, .ECDSA}, true
	case .ECDHE_RSA_AES_128_GCM_SHA256:         return {V12, .SHA256, .AES_GCM_128, 16, 4, .TLS12_Explicit, .RSA}, true
	case .ECDHE_ECDSA_AES_256_GCM_SHA384:       return {V12, .SHA384, .AES_GCM_256, 32, 4, .TLS12_Explicit, .ECDSA}, true
	case .ECDHE_RSA_AES_256_GCM_SHA384:         return {V12, .SHA384, .AES_GCM_256, 32, 4, .TLS12_Explicit, .RSA}, true
	case .ECDHE_ECDSA_CHACHA20_POLY1305_SHA256: return {V12, .SHA256, .CHACHA20POLY1305, 32, 12, .TLS12_Implicit, .ECDSA}, true
	case .ECDHE_RSA_CHACHA20_POLY1305_SHA256:   return {V12, .SHA256, .CHACHA20POLY1305, 32, 12, .TLS12_Implicit, .RSA}, true
	case .None:
	}
	return {}, false
}

// A secret sized to the suite's hash; `bytes` is the used part.
Secret :: struct {
	data: [MAX_HASH_SIZE]u8,
	size: int,
}

secret_bytes :: proc(s: ^Secret) -> []u8 {
	return s.data[:s.size]
}

LABEL_PREFIX :: "tls13 "

// HKDF-Expand-Label: the label and context wrapped in the structure the RFC defines.
expand_label :: proc(algorithm: hash.Algorithm, secret: []u8, label: string, ctx: []u8, dst: []u8) {
	info_buffer: [2 + 1 + 255 + 1 + 255]u8
	n := 0
	info_buffer[n] = u8(len(dst) >> 8); n += 1
	info_buffer[n] = u8(len(dst));      n += 1
	info_buffer[n] = u8(len(LABEL_PREFIX) + len(label)); n += 1
	n += copy(info_buffer[n:], LABEL_PREFIX)
	n += copy(info_buffer[n:], label)
	info_buffer[n] = u8(len(ctx)); n += 1
	n += copy(info_buffer[n:], ctx)
	hkdf.expand(algorithm, secret, info_buffer[:n], dst)
}

// Derive-Secret: a secret from a label and a transcript hash.
derive_secret :: proc(algorithm: hash.Algorithm, secret: []u8, label: string, transcript_hash: []u8) -> (out: Secret) {
	out.size = hash.DIGEST_SIZES[algorithm]
	expand_label(algorithm, secret, label, transcript_hash, out.data[:out.size])
	return
}

empty_hash :: proc(algorithm: hash.Algorithm) -> (out: Secret) {
	out.size = hash.DIGEST_SIZES[algorithm]
	hash.hash_bytes_to_buffer(algorithm, nil, out.data[:out.size])
	return
}

hkdf_extract :: proc(algorithm: hash.Algorithm, salt, ikm: []u8) -> (out: Secret) {
	out.size = hash.DIGEST_SIZES[algorithm]
	hkdf.extract(algorithm, salt, ikm, out.data[:out.size])
	return
}

// The early secret with no pre-shared key, then the handshake secret from the shared key.
handshake_secret :: proc(algorithm: hash.Algorithm, shared_key: []u8) -> Secret {
	zeros: [MAX_HASH_SIZE]u8
	size := hash.DIGEST_SIZES[algorithm]
	early := hkdf_extract(algorithm, zeros[:size], zeros[:size])
	empty := empty_hash(algorithm)
	derived := derive_secret(algorithm, secret_bytes(&early), "derived", secret_bytes(&empty))
	result := hkdf_extract(algorithm, secret_bytes(&derived), shared_key)
	crypto.zero_explicit(&early, size_of(early))
	crypto.zero_explicit(&derived, size_of(derived))
	return result
}

master_secret :: proc(algorithm: hash.Algorithm, handshake: ^Secret) -> Secret {
	zeros: [MAX_HASH_SIZE]u8
	empty := empty_hash(algorithm)
	derived := derive_secret(algorithm, secret_bytes(handshake), "derived", secret_bytes(&empty))
	result := hkdf_extract(algorithm, secret_bytes(&derived), zeros[:handshake.size])
	crypto.zero_explicit(&derived, size_of(derived))
	return result
}

// verify_data for a Finished message: HMAC of the transcript with the finished key.
finished_verify_data :: proc(algorithm: hash.Algorithm, base_secret: []u8, transcript_hash: []u8) -> (out: Secret) {
	finished_key: Secret
	finished_key.size = hash.DIGEST_SIZES[algorithm]
	expand_label(algorithm, base_secret, "finished", nil, finished_key.data[:finished_key.size])
	out.size = finished_key.size
	hmac.sum(algorithm, out.data[:out.size], transcript_hash, secret_bytes(&finished_key))
	crypto.zero_explicit(&finished_key, size_of(finished_key))
	return
}

// One direction of record protection: the AEAD and its key, the IV, the record counter, and
// how the nonce and AAD are laid out (Record_Format).
Traffic_Keys :: struct {
	cipher:   aead.Context,
	iv:       [AEAD_NONCE_SIZE]u8,
	sequence: u64,
	format:   Record_Format,
	secret:   Secret, // TLS 1.3: kept for KeyUpdate
	active:   bool,
}

// TLS 1.3: keys from a traffic secret.
traffic_keys_set :: proc(keys: ^Traffic_Keys, info: Suite_Info, secret: Secret) {
	secret := secret
	key: [32]u8
	iv: [AEAD_NONCE_SIZE]u8
	expand_label(info.hash, secret.data[:secret.size], "key", nil, key[:info.key_size])
	expand_label(info.hash, secret.data[:secret.size], "iv", nil, iv[:])
	traffic_keys_set_material(keys, info, key[:info.key_size], iv[:])
	keys.secret = secret
	crypto.zero_explicit(&key, size_of(key))
	crypto.zero_explicit(&iv, size_of(iv))
}

// The stage both versions end in: a key and an IV, however they were derived.
traffic_keys_set_material :: proc(keys: ^Traffic_Keys, info: Suite_Info, key, iv: []u8) {
	traffic_keys_clear(keys)
	copy(keys.iv[:], iv)
	aead.init(&keys.cipher, info.aead, key)
	keys.format = info.record
	keys.sequence = 0
	keys.active = true
}

// KeyUpdate: the next traffic secret from this one, and new keys from it.
traffic_keys_update :: proc(keys: ^Traffic_Keys, info: Suite_Info) {
	next: Secret
	next.size = keys.secret.size
	expand_label(info.hash, secret_bytes(&keys.secret), "traffic upd", nil, next.data[:next.size])
	traffic_keys_set(keys, info, next)
	crypto.zero_explicit(&next, size_of(next))
}

traffic_keys_clear :: proc(keys: ^Traffic_Keys) {
	aead.reset(&keys.cipher) // also when keyed but not yet switched on (TLS 1.2 before the server's ChangeCipherSpec)
	crypto.zero_explicit(keys, size_of(keys^))
}

traffic_nonce :: proc(keys: ^Traffic_Keys) -> (nonce: [AEAD_NONCE_SIZE]u8) {
	nonce = keys.iv
	for i in 0 ..< 8 {
		nonce[AEAD_NONCE_SIZE - 1 - i] ~= u8(keys.sequence >> uint(8 * i))
	}
	return
}
