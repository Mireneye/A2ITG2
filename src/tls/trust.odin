// Trust anchors from PEM text (a file of "-----BEGIN CERTIFICATE-----" blocks).
// The OS store is in trust_windows.odin.
package tls

import "core:encoding/base64"
import "core:strings"

PEM_BEGIN :: "-----BEGIN CERTIFICATE-----"
PEM_END   :: "-----END CERTIFICATE-----"

// Returns how many certificates were added.
trust_anchors_add_pem :: proc(anchors: ^Trust_Anchors, text: string) -> (added: int) {
	rest := text
	for {
		start := strings.index(rest, PEM_BEGIN)
		if start < 0 do break
		rest = rest[start + len(PEM_BEGIN):]
		end := strings.index(rest, PEM_END)
		if end < 0 do break
		body := rest[:end]
		rest = rest[end + len(PEM_END):]
		compact := make([]u8, len(body), context.temp_allocator)
		n := 0
		for ch in transmute([]u8)body {
			if ch != '\n' && ch != '\r' && ch != ' ' && ch != '\t' { compact[n] = ch; n += 1 }
		}
		der, err := base64.decode(string(compact[:n]), allocator = context.temp_allocator)
		if err != nil do continue
		if trust_anchors_add_der(anchors, der) do added += 1
	}
	return
}
