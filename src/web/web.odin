/*
HTTPS GET of a whole file or a byte range of it, blocking. The one thing the app needs from the web.

	body, info, failure := web.get(&anchors, "https://example.com/file.zip", web.Range{first = 0, last = 99})
	info.total_size // the whole file's size, from the server's Content-Range

TLS is src/tls (Weaving Mirage's). Redirects are followed. Each call is its own connection.
ZZ-Attention: one connection per request costs a TLS handshake each time; keep-alive is a later step
if copying many files feels slow.
*/
package web

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "../tls"

TIMEOUT       :: 20 * time.Second
MAX_REDIRECTS :: 5

// Bytes `first` to `last`, both included (HTTP's own convention).
Range :: struct {
	first, last: i64,
}

Info :: struct {
	status:      int, // 200 for the whole file, 206 for a range
	total_size:  i64, // the whole file's size when the server says (Content-Range or Content-Length), else -1
	range_start: i64, // where the returned bytes start in the file
	final_url:   string, // after redirects (temp allocated)
}

Failure :: enum u8 {
	None,
	Bad_Url,
	Resolve,     // the name didn't resolve
	Connect,
	Tls,         // the handshake failed: see the returned tls.Failure
	Send,
	Receive,     // the connection broke or timed out
	Bad_Response,
	Too_Many_Redirects,
	Http_Error,  // a status other than 200/206 (Info.status says which)
}

// The body is allocated with `allocator`.
get :: proc(anchors: ^tls.Trust_Anchors, url: string, bytes: Maybe(Range) = nil, allocator := context.allocator) -> (body: []u8, info: Info, failure: Failure, tls_failure: tls.Failure) {
	current := url
	for _ in 0..=MAX_REDIRECTS {
		host, port, target, ok := split_url(current)
		if !ok do return nil, info, .Bad_Url, {}

		response: [dynamic]u8
		response, failure, tls_failure = exchange(anchors, host, port, request_text(host, target, bytes))
		if failure != .None {
			delete(response)
			return nil, info, failure, tls_failure
		}
		defer delete(response)

		head, content, parsed := split_response(response[:])
		if !parsed do return nil, info, .Bad_Response, {}
		info.status = status_of(head)
		info.final_url = current

		if info.status >= 300 && info.status < 400 {
			location := header(head, "location")
			if location == "" do return nil, info, .Bad_Response, {}
			current = resolve_location(current, location)
			continue
		}
		if info.status != 200 && info.status != 206 do return nil, info, .Http_Error, {}

		if strings.equal_fold(header(head, "transfer-encoding"), "chunked") {
			unchunked, chunks_ok := unchunk(content, allocator)
			if !chunks_ok do return nil, info, .Bad_Response, {}
			body = unchunked
		} else {
			if length, has_length := strconv.parse_i64(header(head, "content-length")); has_length {
				if i64(len(content)) < length do return nil, info, .Receive, {} // cut short
				content = content[:length]
			}
			body = make([]u8, len(content), allocator)
			copy(body, content)
		}

		info.total_size, info.range_start = -1, 0
		if info.status == 206 {
			info.range_start, info.total_size = parse_content_range(header(head, "content-range"))
		} else {
			info.total_size = i64(len(body))
		}
		return body, info, .None, {}
	}
	return nil, info, .Too_Many_Redirects, {}
}

@(private)
request_text :: proc(host, target: string, bytes: Maybe(Range)) -> string {
	// Explicit ranges only: "the last N bytes" (bytes=-N) is refused by some servers and proxies.
	range_line := ""
	if r, ok := bytes.?; ok do range_line = fmt.tprintf("Range: bytes=%d-%d\r\n", r.first, r.last)
	return fmt.tprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: A2ITG2\r\nAccept: */*\r\nAccept-Encoding: identity\r\n%sConnection: close\r\n\r\n", target, host, range_line)
}

// One request over a fresh TLS connection; returns everything the server sent until it closed.
@(private)
exchange :: proc(anchors: ^tls.Trust_Anchors, host: string, port: int, request: string) -> (response: [dynamic]u8, failure: Failure, tls_failure: tls.Failure) {
	found, resolve_err := net.resolve_ip4(host)
	if resolve_err != nil do return nil, .Resolve, {}
	endpoint := found
	endpoint.port = port
	socket, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do return nil, .Connect, {}
	defer net.close(socket)
	net.set_option(socket, .Receive_Timeout, TIMEOUT)
	net.set_option(socket, .Send_Timeout, TIMEOUT)

	@(static) protocols := [1]string{"http/1.1"}
	client := new(tls.Client) // keys, transcript and buffers: not on the stack
	defer {
		tls.client_destroy(client)
		free(client)
	}
	tls.client_init(client, {server_name = host, alpn = protocols[:], anchors = anchors})

	response = make([dynamic]u8)
	buffer := make([]u8, 64 * 1024, context.temp_allocator)
	sent := false
	for {
		if !flush(client, socket) do return response, .Send, {}
		if client.state == .Connected && !sent {
			tls.client_send(client, transmute([]u8)request)
			sent = true
			continue
		}
		if client.state == .Failed do return response, .Tls, client.failure
		if client.state == .Closed do break
		n, err := net.recv_tcp(socket, buffer)
		if err != nil || n == 0 do break // the server closed (Connection: close) or timed out
		tls.client_receive(client, buffer[:n])
		data := tls.client_data(client)
		append(&response, ..data)
		tls.client_data_done(client, len(data))
	}
	if !sent do return response, .Tls, client.failure
	return response, .None, {}
}

@(private)
flush :: proc(client: ^tls.Client, socket: net.TCP_Socket) -> bool {
	for {
		out := tls.client_output(client)
		if len(out) == 0 do return true
		n, err := net.send_tcp(socket, out)
		if err != nil do return false
		tls.client_output_done(client, n)
	}
}

// "https://host[:port]/path?query" into its parts. Only https.
@(private)
split_url :: proc(url: string) -> (host: string, port: int, target: string, ok: bool) {
	PREFIX :: "https://"
	if !strings.has_prefix(url, PREFIX) do return
	rest := url[len(PREFIX):]
	slash := strings.index_byte(rest, '/')
	authority := rest if slash < 0 else rest[:slash]
	target = "/" if slash < 0 else rest[slash:]
	host, port = authority, 443
	if colon := strings.index_byte(authority, ':'); colon >= 0 {
		host = authority[:colon]
		port = strconv.parse_int(authority[colon + 1:]) or_return
	}
	return host, port, target, host != ""
}

@(private)
resolve_location :: proc(current, location: string) -> string {
	if strings.has_prefix(location, "https://") || strings.has_prefix(location, "http://") do return location
	host, port, _, _ := split_url(current)
	if port == 443 do return fmt.tprintf("https://%s%s", host, location)
	return fmt.tprintf("https://%s:%d%s", host, port, location)
}

@(private)
split_response :: proc(response: []u8) -> (head: string, body: []u8, ok: bool) {
	text := string(response)
	end := strings.index(text, "\r\n\r\n")
	if end < 0 do return
	return text[:end], response[end + 4:], true
}

@(private)
status_of :: proc(head: string) -> int {
	// "HTTP/1.1 206 Partial Content"
	first_line := head
	if end := strings.index(head, "\r\n"); end >= 0 do first_line = head[:end]
	parts := strings.fields(first_line, context.temp_allocator)
	if len(parts) < 2 do return 0
	status, _ := strconv.parse_int(parts[1])
	return status
}

// The value of the first header called `name` (any case), trimmed; "" if absent.
header :: proc(head: string, name: string) -> string {
	lines := head
	for line in strings.split_lines_iterator(&lines) {
		colon := strings.index_byte(line, ':')
		if colon > 0 && strings.equal_fold(strings.trim_space(line[:colon]), name) {
			return strings.trim_space(line[colon + 1:])
		}
	}
	return ""
}

// "bytes 0-63/57701893" -> start 0, total 57701893 (total -1 when the server writes "*").
@(private)
parse_content_range :: proc(value: string) -> (start: i64, total: i64) {
	total = -1
	rest := strings.trim_prefix(value, "bytes ")
	dash, slash := strings.index_byte(rest, '-'), strings.index_byte(rest, '/')
	if dash < 0 || slash < 0 do return
	start, _ = strconv.parse_i64(rest[:dash])
	if parsed, ok := strconv.parse_i64(rest[slash + 1:]); ok do total = parsed
	return
}

@(private)
unchunk :: proc(content: []u8, allocator := context.allocator) -> (body: []u8, ok: bool) {
	out := make([dynamic]u8, allocator)
	rest := content
	for {
		line_end := strings.index(string(rest), "\r\n")
		if line_end < 0 do break
		size_text := string(rest[:line_end])
		if semicolon := strings.index_byte(size_text, ';'); semicolon >= 0 do size_text = size_text[:semicolon]
		size, size_ok := strconv.parse_int(strings.trim_space(size_text), 16)
		if !size_ok do break
		rest = rest[line_end + 2:]
		if size == 0 do return out[:], true
		if size > len(rest) do break
		append(&out, ..rest[:size])
		rest = rest[min(size + 2, len(rest)):]
	}
	delete(out)
	return nil, false
}
