// A byte queue: appended at the back, consumed from the front without moving the rest every
// time (the unread part is moved down only once more than half the buffer is read).
package tls

Byte_Queue :: struct {
	data: [dynamic]u8,
	head: int,
}

queue_bytes :: proc(q: ^Byte_Queue) -> []u8 {
	return q.data[q.head:]
}

queue_len :: proc(q: ^Byte_Queue) -> int {
	return len(q.data) - q.head
}

queue_push :: proc(q: ^Byte_Queue, b: []u8) {
	append(&q.data, ..b)
}

queue_consume :: proc(q: ^Byte_Queue, count: int) {
	q.head += min(count, queue_len(q))
	if q.head == len(q.data) {
		clear(&q.data)
		q.head = 0
	} else if q.head > len(q.data) / 2 {
		left := len(q.data) - q.head
		copy(q.data[:left], q.data[q.head:])
		resize(&q.data, left)
		q.head = 0
	}
}

queue_destroy :: proc(q: ^Byte_Queue) {
	delete(q.data)
	q^ = {}
}
