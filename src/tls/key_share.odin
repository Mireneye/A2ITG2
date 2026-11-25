// Key exchange: the client's key shares and the shared key from the server's answer.
//
// The first ClientHello offers the hybrid post-quantum group (ML-KEM-768 + X25519) and plain
// X25519, reusing ONE X25519 key for both shares (the hybrid draft allows it, and it saves a
// key generation and 32 bytes of state). P-256 and P-384 are only listed as supported, so a
// server that wants them asks with a HelloRetryRequest and pays the round trip, not everyone.
package tls

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/mlkem"

X25519_SHARE_SIZE   :: 32
MLKEM768_EK_SIZE    :: 1184
MLKEM768_CT_SIZE    :: 1088
MAX_SHARED_KEY_SIZE :: 64 // hybrid: 32 from ML-KEM + 32 from X25519

// Groups in the order we prefer them; the first two get shares in the first ClientHello.
SUPPORTED_GROUPS := [?]Named_Group{.X25519_MLKEM768, .X25519, .Secp256r1, .Secp384r1}

Key_Shares :: struct {
	x25519: ecdh.Private_Key,
	mlkem:  mlkem.Decapsulation_Key,
	retry:  ecdh.Private_Key, // the one group a HelloRetryRequest asked for (if not one of the above)
	retry_group: Named_Group,
	has_x25519, has_mlkem, has_retry: bool,
	classical: bool, // no post-quantum share (Config.classical)
}

key_shares_generate :: proc(shares: ^Key_Shares, classical: bool) -> bool {
	shares.classical = classical
	shares.has_x25519 = ecdh.private_key_generate(&shares.x25519, .X25519)
	if classical do return shares.has_x25519
	shares.has_mlkem = mlkem.decapsulation_key_generate(&shares.mlkem, .ML_KEM_768)
	return shares.has_x25519 && shares.has_mlkem
}

// The groups a hello lists as supported: all of them, or all but the hybrid when classical.
supported_groups :: proc(shares: ^Key_Shares) -> []Named_Group {
	return SUPPORTED_GROUPS[1:] if shares.classical else SUPPORTED_GROUPS[:]
}

key_shares_clear :: proc(shares: ^Key_Shares) {
	ecdh.private_key_clear(&shares.x25519)
	ecdh.private_key_clear(&shares.retry)
	if shares.has_mlkem do mlkem.decapsulation_key_clear(&shares.mlkem)
	shares^ = {}
}

ecdh_curve :: proc(group: Named_Group) -> ecdh.Curve {
	#partial switch group {
	case .X25519:    return .X25519
	case .Secp256r1: return .SECP256R1
	case .Secp384r1: return .SECP384R1
	}
	return .Invalid
}

// After a HelloRetryRequest: a fresh share for exactly the group the server named.
key_shares_retry :: proc(shares: ^Key_Shares, group: Named_Group) -> bool {
	shares.retry_group = group
	switch group {
	case .X25519, .X25519_MLKEM768:
		return true // already have keys for these; they are offered again alone
	case .Secp256r1, .Secp384r1:
		shares.has_retry = ecdh.private_key_generate(&shares.retry, ecdh_curve(group))
		return shares.has_retry
	case .None:
	}
	return false
}

// The KeyShareEntry list for a ClientHello: both first shares, or the single retry share.
write_key_shares :: proc(w: Writer, shares: ^Key_Shares) {
	x25519_public: [X25519_SHARE_SIZE]u8
	ecdh.private_key_public_bytes(&shares.x25519, x25519_public[:])
	write_hybrid :: proc(w: Writer, shares: ^Key_Shares, x25519_public: []u8) {
		write_u16(w, u16(Named_Group.X25519_MLKEM768))
		mark := block_begin(w, 2)
		ek: [MLKEM768_EK_SIZE]u8
		mlkem.decapsulation_key_encaps_bytes(&shares.mlkem, ek[:])
		write_bytes(w, ek[:]) // ML-KEM first, then X25519 (the order the hybrid group defines)
		write_bytes(w, x25519_public)
		block_end(w, mark, 2)
	}
	switch shares.retry_group {
	case .None:
		if !shares.classical do write_hybrid(w, shares, x25519_public[:])
		write_u16(w, u16(Named_Group.X25519))
		write_block(w, 2, x25519_public[:])
	case .X25519_MLKEM768:
		write_hybrid(w, shares, x25519_public[:])
	case .X25519:
		write_u16(w, u16(Named_Group.X25519))
		write_block(w, 2, x25519_public[:])
	case .Secp256r1, .Secp384r1:
		public: [1 + 2 * 48]u8 // an uncompressed point (0x04, x, y); P-384's is the largest
		size := 1 + 2 * ecdh.key_size(&shares.retry)
		ecdh.private_key_public_bytes(&shares.retry, public[:size])
		write_u16(w, u16(shares.retry_group))
		write_block(w, 2, public[:size])
	}
}

// Was this group offered with a share in the hello just sent?
key_share_offered :: proc(shares: ^Key_Shares, group: Named_Group) -> bool {
	if shares.retry_group != .None do return group == shares.retry_group
	return group == .X25519 || (group == .X25519_MLKEM768 && !shares.classical)
}

// Our public share for `group` (TLS 1.2's ClientKeyExchange): the hello's X25519 key, or the
// P-256 / P-384 key key_shares_retry made.
key_share_public :: proc(shares: ^Key_Shares, group: Named_Group, dst: []u8) -> int {
	if group == .X25519 {
		ecdh.private_key_public_bytes(&shares.x25519, dst[:X25519_SHARE_SIZE])
		return X25519_SHARE_SIZE
	}
	size := 1 + 2 * ecdh.key_size(&shares.retry)
	ecdh.private_key_public_bytes(&shares.retry, dst[:size])
	return size
}

// The shared key from the server's KeyShareEntry (or TLS 1.2's ServerKeyExchange).
key_share_finish :: proc(shares: ^Key_Shares, group: Named_Group, server_share: []u8, out: ^[MAX_SHARED_KEY_SIZE]u8) -> (size: int, ok: bool) {
	agree :: proc(private: ^ecdh.Private_Key, curve: ecdh.Curve, public_bytes: []u8, dst: []u8) -> bool {
		public: ecdh.Public_Key
		if !ecdh.public_key_set_bytes(&public, curve, public_bytes) do return false
		defer ecdh.public_key_clear(&public)
		return ecdh.ecdh(private, &public, dst) // refuses the all-zero result (small-order points)
	}
	#partial switch group {
	case .X25519:
		if len(server_share) != X25519_SHARE_SIZE do return 0, false
		return 32, agree(&shares.x25519, .X25519, server_share, out[:32])
	case .X25519_MLKEM768:
		if !shares.has_mlkem do return 0, false
		if len(server_share) != MLKEM768_CT_SIZE + X25519_SHARE_SIZE do return 0, false
		if !mlkem.decaps(&shares.mlkem, server_share[:MLKEM768_CT_SIZE], out[:32]) do return 0, false
		return 64, agree(&shares.x25519, .X25519, server_share[MLKEM768_CT_SIZE:], out[32:64])
	case .Secp256r1, .Secp384r1:
		if !shares.has_retry || group != shares.retry_group do return 0, false
		size = ecdh.shared_secret_size(&shares.retry)
		return size, agree(&shares.retry, ecdh_curve(group), server_share, out[:size])
	}
	crypto.zero_explicit(out, size_of(out^))
	return 0, false
}
