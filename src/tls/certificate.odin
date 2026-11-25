// Checking the server: its certificate chain against the trust anchors (core:crypto/x509 does
// the path building, hostname and usage rules) and its signature (TLS 1.3's CertificateVerify,
// TLS 1.2's ServerKeyExchange), which proves it holds the leaf's private key.
package tls

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:time"

MAX_CHAIN_CERTIFICATES :: 10 // real chains are 2 to 4; more is refused rather than searched

Certificate_Problem :: enum u8 {
	None,
	Malformed,
	Empty_Chain,
	Too_Long,
	Untrusted,        // no path to a trust anchor
	Expired,
	Not_Yet_Valid,
	Wrong_Host,
	Wrong_Usage,
	Unsupported,      // a signature or key algorithm we can't check
	Bad_Signature,    // CertificateVerify didn't verify
	Scheme_Mismatch,  // signature scheme doesn't fit the leaf's key
	Distrusted,       // the path's root (or a certificate in it) is blocked or restricted by the OS's own lists
}

Trust_Anchors :: struct {
	certificates: [dynamic]x509.Certificate,
	pointers:     [dynamic]^x509.Certificate,
	// Windows: its full trust list (roots it trusts but may not have downloaded, with their
	// restrictions) and its blocked certificates, by SHA-1 thumbprint. Empty elsewhere.
	list:         ^Trust_List,
	disallowed:   [dynamic][THUMBPRINT_SIZE]u8,
	learned:      int, // roots taken from servers' chains because the list names them
}

// Adds one DER certificate; unparseable ones are skipped (an OS store holds odd entries).
trust_anchors_add_der :: proc(anchors: ^Trust_Anchors, der: []u8) -> bool {
	owned := make([]u8, len(der))
	copy(owned, der)
	cert, err := x509.parse(owned)
	if err != .None {
		delete(owned)
		return false
	}
	append(&anchors.certificates, cert)
	return true
}

// The pointer list x509 wants; built once after the last add (the array may have moved).
trust_anchors_seal :: proc(anchors: ^Trust_Anchors) {
	clear(&anchors.pointers)
	for &cert in anchors.certificates do append(&anchors.pointers, &cert)
}

trust_anchors_destroy :: proc(anchors: ^Trust_Anchors) {
	for &cert in anchors.certificates {
		delete(cert.raw)
		x509.destroy(&cert)
	}
	delete(anchors.certificates)
	delete(anchors.pointers)
	delete(anchors.disallowed)
	if anchors.list != nil {
		trust_list_destroy(anchors.list)
		free(anchors.list)
	}
	anchors^ = {}
}

Server_Chain :: struct {
	certificates: [MAX_CHAIN_CERTIFICATES]x509.Certificate,
	count:        int,
}

server_chain_destroy :: proc(chain: ^Server_Chain) {
	for i in 0 ..< chain.count do x509.destroy(&chain.certificates[i])
	chain.count = 0
}

// Parses the Certificate message's entries (they point into the handshake message, which must
// outlive the chain) and checks the path for `host` at `now`.
check_chain :: proc(chain: ^Server_Chain, entries: [][]u8, anchors: ^Trust_Anchors, host: string, now: time.Time) -> Certificate_Problem {
	if len(entries) == 0 do return .Empty_Chain
	if len(entries) > MAX_CHAIN_CERTIFICATES do return .Too_Long
	for der in entries {
		cert, err := x509.parse(der)
		if err != .None do return .Malformed
		chain.certificates[chain.count] = cert
		chain.count += 1
	}
	problem, root := find_path(chain, anchors, host, now)
	// No path, but the server sent a root the OS's full list trusts (Windows: one it hasn't
	// downloaded yet): learn it, the way Windows would, and look again.
	if problem == .Untrusted && learn_listed_root(chain, anchors, now) {
		problem, root = find_path(chain, anchors, host, now)
	}
	if problem != .None do return problem
	return check_os_restrictions(chain, root, anchors, now)
}

@(private)
find_path :: proc(chain: ^Server_Chain, anchors: ^Trust_Anchors, host: string, now: time.Time) -> (Certificate_Problem, ^x509.Certificate) {
	intermediates: [MAX_CHAIN_CERTIFICATES]^x509.Certificate
	for i in 1 ..< chain.count do intermediates[i - 1] = &chain.certificates[i]
	options := x509.Verify_Options {
		roots         = anchors.pointers[:],
		intermediates = intermediates[:chain.count - 1],
		current_time  = now,
		dns_name      = host,
		required_eku  = .Server_Auth,
	}
	path, err := x509.verify_chain(&chain.certificates[0], options, context.temp_allocator)
	root := path[len(path) - 1] if len(path) > 0 else nil
	delete(path, context.temp_allocator)
	#partial switch err {
	case .None:                  return .None, root
	case .Expired:               return .Expired, nil
	case .Not_Yet_Valid:         return .Not_Yet_Valid, nil
	case .Hostname_Mismatch, .No_SAN: return .Wrong_Host, nil
	case .Incompatible_Usage:    return .Wrong_Usage, nil
	case .Unsupported_Algorithm: return .Unsupported, nil
	case .Malformed, .Invalid_Validity, .Invalid_Extension, .Duplicate_Extension, .Unsupported_Version:
		return .Malformed, nil
	}
	return .Untrusted, nil
}

@(private)
thumbprint_of :: proc(cert: ^x509.Certificate) -> (out: [THUMBPRINT_SIZE]u8) {
	hash.hash_bytes_to_buffer(.Insecure_SHA1, cert.raw, out[:]) // the OS's identifier, not a security hash here
	return
}

// A self-signed certificate in the server's chain that the full list names for server auth
// becomes an anchor (kept for the rest of the run). Its restrictions still apply after.
@(private)
learn_listed_root :: proc(chain: ^Server_Chain, anchors: ^Trust_Anchors, now: time.Time) -> bool {
	if anchors.list == nil do return false
	learned := false
	for i in 0 ..< chain.count {
		cert := &chain.certificates[i]
		if !bytes_equal(cert.raw_subject, cert.raw_issuer) do continue
		thumbprint := thumbprint_of(cert)
		entry := trust_list_find(anchors.list, thumbprint[:])
		if entry == nil || !trust_entry_allows_server_auth(entry, now) do continue
		if trust_anchors_add_der(anchors, cert.raw) {
			anchors.learned += 1
			learned = true
		}
	}
	if learned do trust_anchors_seal(anchors)
	return learned
}

// The OS's own say over a path it would otherwise accept: its blocked certificates, and the
// restrictions its full list puts on the path's root (whichever store that root came from).
@(private)
check_os_restrictions :: proc(chain: ^Server_Chain, root: ^x509.Certificate, anchors: ^Trust_Anchors, now: time.Time) -> Certificate_Problem {
	if len(anchors.disallowed) > 0 {
		for i in 0 ..< chain.count {
			thumbprint := thumbprint_of(&chain.certificates[i])
			for blocked in anchors.disallowed do if blocked == thumbprint do return .Distrusted
		}
		if root != nil {
			thumbprint := thumbprint_of(root)
			for blocked in anchors.disallowed do if blocked == thumbprint do return .Distrusted
		}
	}
	if root == nil || anchors.list == nil do return .None
	thumbprint := thumbprint_of(root)
	entry := trust_list_find(anchors.list, thumbprint[:])
	if entry == nil do return .None // a root the user added themselves: theirs to trust
	if !trust_entry_allows_server_auth(entry, now) do return .Distrusted
	if limit, restricted := trust_entry_not_before(entry); restricted && time.diff(limit, chain.certificates[0].not_before) >= 0 {
		return .Distrusted // issued on or after the date the OS stopped trusting this root's new certificates
	}
	return .None
}

CERTIFICATE_VERIFY_PAD     :: 64 // bytes of 0x20 before the context string
CERTIFICATE_VERIFY_CONTEXT :: "TLS 1.3, server CertificateVerify"
CERTIFICATE_VERIFY_CONTENT_MAX :: CERTIFICATE_VERIFY_PAD + len(CERTIFICATE_VERIFY_CONTEXT) + 1 + MAX_HASH_SIZE

// What a TLS 1.3 server signs: the padded context string and the transcript hash.
certificate_verify_content :: proc(content: ^[CERTIFICATE_VERIFY_CONTENT_MAX]u8, transcript_hash: []u8) -> []u8 {
	n := 0
	for _ in 0 ..< CERTIFICATE_VERIFY_PAD { content[n] = ' '; n += 1 }
	n += copy(content[n:], CERTIFICATE_VERIFY_CONTEXT)
	content[n] = 0; n += 1
	n += copy(content[n:], transcript_hash)
	return content[:n]
}

// A TLS 1.2 suite names the key its certificate must carry; TLS 1.3 suites take any.
check_suite_key :: proc(leaf: ^x509.Certificate, auth: Suite_Auth) -> Certificate_Problem {
	switch auth {
	case .Any:
	case .ECDSA: if leaf.public_key_algorithm != .ECDSA_P256 && leaf.public_key_algorithm != .ECDSA_P384 do return .Scheme_Mismatch
	case .RSA:   if leaf.public_key_algorithm != .RSA do return .Scheme_Mismatch
	}
	return .None
}

// The server's proof that it holds the leaf's private key, both versions: `signature` over
// `content` (TLS 1.3: certificate_verify_content; TLS 1.2: both randoms and the key share).
// The differences are two: TLS 1.2 also allows PKCS#1 v1.5, and in TLS 1.2 an ECDSA scheme
// names only the hash (the curve is the key's), where TLS 1.3 binds the curve too.
check_signature :: proc(leaf: ^x509.Certificate, scheme: Signature_Scheme, content, signature: []u8, tls12: bool) -> Certificate_Problem {
	#partial switch scheme {
	case .ECDSA_Secp256r1_SHA256, .ECDSA_Secp384r1_SHA384:
		algorithm := hash.Algorithm.SHA256 if scheme == .ECDSA_Secp256r1_SHA256 else .SHA384
		curve: ecdsa.Curve
		#partial switch leaf.public_key_algorithm {
		case .ECDSA_P256: curve = .SECP256R1
		case .ECDSA_P384: curve = .SECP384R1
		case:             return .Scheme_Mismatch
		}
		if !tls12 && ((curve == .SECP256R1) != (scheme == .ECDSA_Secp256r1_SHA256)) do return .Scheme_Mismatch
		key: ecdsa.Public_Key
		if !ecdsa.public_key_set_bytes(&key, curve, leaf.ec_point) do return .Malformed
		defer ecdsa.public_key_clear(&key)
		return .None if ecdsa.verify_asn1(&key, algorithm, content, signature) else .Bad_Signature

	case .RSA_PSS_RSAE_SHA256, .RSA_PSS_RSAE_SHA384, .RSA_PSS_RSAE_SHA512,
	     .RSA_PKCS1_SHA256, .RSA_PKCS1_SHA384, .RSA_PKCS1_SHA512:
		// rsaEncryption keys (nearly all RSA certificates). RSASSA-PSS keys (the PSS_PSS schemes)
		// are vanishingly rare on the web and are not offered.
		if leaf.public_key_algorithm != .RSA do return .Scheme_Mismatch
		pkcs1 := scheme == .RSA_PKCS1_SHA256 || scheme == .RSA_PKCS1_SHA384 || scheme == .RSA_PKCS1_SHA512
		if pkcs1 && !tls12 do return .Scheme_Mismatch // never in TLS 1.3's CertificateVerify
		algorithm := hash.Algorithm.SHA256
		if scheme == .RSA_PSS_RSAE_SHA384 || scheme == .RSA_PKCS1_SHA384 do algorithm = .SHA384
		if scheme == .RSA_PSS_RSAE_SHA512 || scheme == .RSA_PKCS1_SHA512 do algorithm = .SHA512
		key: rsa.Public_Key
		if !rsa.public_key_set_bytes(&key, leaf.rsa_n, leaf.rsa_e) do return .Malformed
		defer rsa.public_key_clear(&key)
		if pkcs1 do return .None if rsa.verify_pkcs1(&key, algorithm, content, signature) else .Bad_Signature
		salt := hash.DIGEST_SIZES[algorithm] // fixed to the hash length
		return .None if rsa.verify_pss(&key, algorithm, salt, content, signature) else .Bad_Signature

	case .Ed25519:
		if leaf.public_key_algorithm != .Ed25519 do return .Scheme_Mismatch
		key: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&key, leaf.ec_point) do return .Malformed
		return .None if ed25519.verify(&key, content, signature) else .Bad_Signature
	}
	return .Scheme_Mismatch
}

alert_for_problem :: proc(problem: Certificate_Problem) -> Alert_Description {
	switch problem {
	case .None:                     return .Close_Notify
	case .Malformed, .Empty_Chain, .Too_Long: return .Bad_Certificate
	case .Untrusted:                return .Unknown_CA
	case .Expired, .Not_Yet_Valid:  return .Certificate_Expired
	case .Wrong_Host, .Wrong_Usage: return .Bad_Certificate
	case .Unsupported:              return .Unsupported_Certificate
	case .Bad_Signature:            return .Decrypt_Error
	case .Scheme_Mismatch:          return .Illegal_Parameter
	case .Distrusted:               return .Bad_Certificate
	}
	return .Internal_Error
}
