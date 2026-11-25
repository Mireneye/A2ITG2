/*
Either decoder (MP3 or Ogg) behind one face, for code outside this package (the preview player).

	d: Decoder
	decoder_open(&d, .Ogg, bytes) or_return
	for samples in decoder_next(&d) { ... }   // interleaved floats, d.channels per frame
	decoder_close(&d)
*/
package audio

Decoder :: struct {
	source:      Sample_Source,
	channels:    int,
	sample_rate: int,
}

decoder_open :: proc(d: ^Decoder, format: Source_Format, bytes: []u8) -> bool {
	ok: bool
	d.channels, d.sample_rate, ok = source_open(&d.source, format, bytes)
	return ok && d.channels > 0 && d.sample_rate > 0
}

decoder_next :: proc(d: ^Decoder) -> (samples: []f32, ok: bool) {
	return source_next(&d.source)
}

decoder_close :: proc(d: ^Decoder) {
	source_close(&d.source)
	d^ = {}
}
