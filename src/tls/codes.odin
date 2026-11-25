// The numbers TLS 1.3 puts on the wire (RFC 8446 and its registries), as named enums so no
// magic number appears in the protocol code.
package tls

PROTOCOL_VERSION_TLS13 :: u16(0x0304)
LEGACY_VERSION_TLS12   :: u16(0x0303) // what every record and hello still says outside supported_versions
LEGACY_VERSION_TLS10   :: u16(0x0301) // allowed (and most compatible) on the very first record

RANDOM_SIZE              :: 32
SESSION_ID_SIZE          :: 32 // a random legacy session id puts servers in middlebox compatibility mode
RECORD_HEADER_SIZE       :: 5
HANDSHAKE_HEADER_SIZE    :: 4
MAX_PLAINTEXT            :: 1 << 14       // 16 KB: the largest record payload
MAX_CIPHERTEXT           :: MAX_PLAINTEXT + 256 // what a peer may send at most (RFC 8446 5.2)
MAX_HANDSHAKE_MESSAGE    :: 1 << 17       // 128 KB: far above any real certificate chain; refuses memory blow-ups
AEAD_TAG_SIZE            :: 16
AEAD_NONCE_SIZE          :: 12

Content_Type :: enum u8 {
	Invalid            = 0,
	Change_Cipher_Spec = 20, // only the compatibility byte in TLS 1.3, ignored
	Alert              = 21,
	Handshake          = 22,
	Application_Data   = 23,
}

Handshake_Type :: enum u8 {
	Hello_Request        = 0,  // TLS 1.2: the server asking to renegotiate (always declined)
	Client_Hello         = 1,
	Server_Hello         = 2,
	New_Session_Ticket   = 4,
	End_Of_Early_Data    = 5,
	Encrypted_Extensions = 8,
	Certificate          = 11,
	Server_Key_Exchange  = 12, // TLS 1.2: the server's signed ECDHE share
	Certificate_Request  = 13,
	Server_Hello_Done    = 14, // TLS 1.2
	Client_Key_Exchange  = 16, // TLS 1.2: our ECDHE share
	Certificate_Verify   = 15,
	Finished             = 20,
	Key_Update           = 24,
	Message_Hash         = 254, // stands in for the first ClientHello after a HelloRetryRequest
}

Extension_Type :: enum u16 {
	Server_Name            = 0,
	Supported_Groups       = 10,
	EC_Point_Formats       = 11,     // TLS 1.2: uncompressed points only
	Extended_Master_Secret = 23,     // TLS 1.2: keys bound to the whole handshake (RFC 7627), required
	Signature_Algorithms   = 13,
	ALPN                   = 16,
	Pre_Shared_Key         = 41,
	Early_Data             = 42,
	Supported_Versions     = 43,
	Cookie                 = 44,
	PSK_Key_Exchange_Modes = 45,
	Signature_Algorithms_Cert = 50,
	Key_Share              = 51,
	Renegotiation_Info     = 0xFF01, // TLS 1.2: proof of secure renegotiation (RFC 5746), required
}

Named_Group :: enum u16 {
	None            = 0,
	Secp256r1       = 0x0017,
	Secp384r1       = 0x0018,
	X25519          = 0x001D,
	X25519_MLKEM768 = 0x11EC, // hybrid post-quantum: ML-KEM-768 + X25519 (what Chrome and Firefox send first)
}

Signature_Scheme :: enum u16 {
	RSA_PKCS1_SHA256       = 0x0401, // certificates only, never CertificateVerify in TLS 1.3
	RSA_PKCS1_SHA384       = 0x0501,
	RSA_PKCS1_SHA512       = 0x0601,
	ECDSA_Secp256r1_SHA256 = 0x0403,
	ECDSA_Secp384r1_SHA384 = 0x0503,
	RSA_PSS_RSAE_SHA256    = 0x0804,
	RSA_PSS_RSAE_SHA384    = 0x0805,
	RSA_PSS_RSAE_SHA512    = 0x0806,
	Ed25519                = 0x0807,
	RSA_PSS_PSS_SHA256     = 0x0809,
	RSA_PSS_PSS_SHA384     = 0x080A,
	RSA_PSS_PSS_SHA512     = 0x080B,
}

Cipher_Suite :: enum u16 {
	None                         = 0,
	TLS_AES_128_GCM_SHA256       = 0x1301,
	TLS_AES_256_GCM_SHA384       = 0x1302,
	TLS_CHACHA20_POLY1305_SHA256 = 0x1303,
	// TLS 1.2, the strict set: ECDHE (forward secrecy) with AEADs only (no CBC, no RSA key exchange).
	ECDHE_ECDSA_AES_128_GCM_SHA256       = 0xC02B,
	ECDHE_RSA_AES_128_GCM_SHA256         = 0xC02F,
	ECDHE_ECDSA_AES_256_GCM_SHA384       = 0xC02C,
	ECDHE_RSA_AES_256_GCM_SHA384         = 0xC030,
	ECDHE_ECDSA_CHACHA20_POLY1305_SHA256 = 0xCCA9,
	ECDHE_RSA_CHACHA20_POLY1305_SHA256   = 0xCCA8,
}

Alert_Level :: enum u8 {
	Warning = 1,
	Fatal   = 2,
}

Alert_Description :: enum u8 {
	Close_Notify                    = 0,
	Unexpected_Message              = 10,
	Bad_Record_MAC                  = 20,
	Record_Overflow                 = 22,
	Handshake_Failure               = 40,
	Bad_Certificate                 = 42,
	Unsupported_Certificate         = 43,
	Certificate_Revoked             = 44,
	Certificate_Expired             = 45,
	Certificate_Unknown             = 46,
	Illegal_Parameter               = 47,
	Unknown_CA                      = 48,
	Access_Denied                   = 49,
	Decode_Error                    = 50,
	Decrypt_Error                   = 51,
	Protocol_Version                = 70,
	Insufficient_Security           = 71,
	Internal_Error                  = 80,
	Inappropriate_Fallback          = 86,
	User_Canceled                   = 90,
	Missing_Extension               = 109,
	Unsupported_Extension           = 110,
	Unrecognized_Name               = 112,
	Bad_Certificate_Status_Response = 113,
	Unknown_PSK_Identity            = 115,
	No_Renegotiation                = 100,
	Certificate_Required            = 116,
	No_Application_Protocol         = 120,
}

// The last 8 bytes of ServerHello.random from a TLS 1.3 server that is answering in TLS 1.2:
// seeing it means someone in between stripped 1.3 from our hello (RFC 8446 4.1.3).
DOWNGRADE_TO_TLS12 := [8]u8{'D', 'O', 'W', 'N', 'G', 'R', 'D', 1}

// The fixed ServerHello.random that marks a HelloRetryRequest (SHA-256 of "HelloRetryRequest").
HELLO_RETRY_REQUEST_RANDOM := [RANDOM_SIZE]u8 {
	0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
	0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
}
