#+build windows
// Trust anchors from Windows' own lists: the machine's and the user's "ROOT" store (what
// Windows itself trusts) and its "AuthRoot" cache (third-party roots Windows has fetched).
//
// ZZ-Attention: Windows fetches some third-party roots only when its own chain builder first
// needs them, so a root a site uses may be missing from these lists on a fresh install. The
// probe (tools/tls_get roots) counts what is readable from where the plugin runs. Those are
// covered by Windows' full trust list (trust_list.odin), read here too.
package tls

import "core:crypto/hash"
import win "core:sys/windows"

// The stores' roots, plus Windows' full trust list (roots it hasn't downloaded, and the
// restrictions it puts on every root) and its blocked certificates.
trust_anchors_add_windows :: proc(anchors: ^Trust_Anchors) -> (added: int) {
	added = add_store_roots(anchors)
	add_blocked(anchors)
	if anchors.list == nil {
		list := new(Trust_List)
		if trust_list_load_windows(list) do anchors.list = list
		else do free(list)
	}
	return
}

// Certificates Windows refuses outright, by thumbprint: its "Disallowed" store.
//
// ZZ-Attention: Windows 10 keeps most of its blocked certificates in the registry instead
// (AutoUpdate\DisallowedCertEncodedCtl, empty store on the user's PC 2026-11-17). That list names
// them by a hash of their signature (16- and 48-byte entries), not by thumbprint; matching it
// needs one known blocked certificate to confirm which bytes are hashed. Not read until then.
@(private)
add_blocked :: proc(anchors: ^Trust_Anchors) {
	store := win.CertOpenSystemStoreW(nil, win.utf8_to_wstring("Disallowed"))
	if store == nil do return
	defer win.CertCloseStore(store, 0)
	cert: ^win.CERT_CONTEXT
	for {
		cert = win.CertEnumCertificatesInStore(store, cert)
		if cert == nil do break
		thumbprint: [THUMBPRINT_SIZE]u8
		hash.hash_bytes_to_buffer(.Insecure_SHA1, cert.pbCertEncoded[:cert.cbCertEncoded], thumbprint[:])
		append(&anchors.disallowed, thumbprint)
	}
}

@(private)
add_store_roots :: proc(anchors: ^Trust_Anchors) -> (added: int) {
	for name in ([?]string{"ROOT", "AuthRoot"}) {
		store := win.CertOpenSystemStoreW(nil, win.utf8_to_wstring(name))
		if store == nil do continue
		defer win.CertCloseStore(store, 0)
		cert: ^win.CERT_CONTEXT
		for {
			cert = win.CertEnumCertificatesInStore(store, cert)
			if cert == nil do break
			der := cert.pbCertEncoded[:cert.cbCertEncoded]
			if trust_anchors_add_der(anchors, der) do added += 1
		}
	}
	return
}

TRUST_LIST_KEY     :: `SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate`
TRUST_LIST_VALUE   :: "EncodedCtl" // every root Windows trusts

// Windows' full trust list from the registry, read-only.
trust_list_load_windows :: proc(list: ^Trust_List) -> bool {
	key := win.utf8_to_wstring(TRUST_LIST_KEY)
	value := win.utf8_to_wstring(TRUST_LIST_VALUE)
	size: win.DWORD
	if win.RegGetValueW(win.HKEY_LOCAL_MACHINE, key, value, win.RRF_RT_REG_BINARY, nil, nil, &size) != 0 || size == 0 do return false
	bytes := make([]u8, size)
	if win.RegGetValueW(win.HKEY_LOCAL_MACHINE, key, value, win.RRF_RT_REG_BINARY, nil, raw_data(bytes), &size) != 0 {
		delete(bytes)
		return false
	}
	if !trust_list_parse(list, bytes[:size]) {
		trust_list_destroy(list)
		return false
	}
	return true
}

// The system's trusted roots (trust_other.odin has the same away from Windows).
trust_anchors_add_os :: proc(anchors: ^Trust_Anchors) -> int {
	return trust_anchors_add_windows(anchors)
}
