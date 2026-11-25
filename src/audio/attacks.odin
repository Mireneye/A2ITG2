/*
How strongly the music starts a new sound at each moment ("attack strength"), for measuring a chart's
sync against its audio (match_notes in sync_match.odin).

	attacks, ok := ogg_attacks(ogg_bytes)   // decoded the way StepMania plays it (ogg_decode.odin)
	defer attacks_destroy(&attacks)

The song is mixed to mono and cut into windows of ATTACK_WINDOW samples, one every ATTACK_HOP
samples (1.45 ms at 44.1 kHz; half that spacing measured the same within 0.2 ms, at twice the cost). Each window's spectrum is taken on a log scale; a sound starting
shows as many frequencies getting louder at once, so the strength is the sum of every frequency's
rise since the window before ("spectral flux"). Slow swells in loudness are taken away (the
strength minus its average over ATTACK_LEVEL_SPAN), so only sudden rises are left.

The song streams through: only one window of samples and the strengths (4 bytes per 1.45 ms,
under 0.5 MB for a 2:30 song) are held.
*/
package audio

import "core:math"

ATTACK_WINDOW     :: 512
ATTACK_HOP        :: 64
ATTACK_LEVEL_SPAN :: 151 // strengths averaged to find the slow loudness: 220 ms at 44.1 kHz
ATTACK_LOG_GAIN   :: 100 // spectrum magnitudes go in as log(1 + 100 m): quiet detail still counts

Attacks :: struct {
	strength:      []f32, // heap; one per hop
	first_seconds: f64,   // the time strength[0] stands for
	step_seconds:  f64,   // time between strengths
	song_seconds:  f64,
}

attacks_destroy :: proc(a: ^Attacks) {
	delete(a.strength)
	a^ = {}
}

// The time of strength[i]: the middle between the two windows it compares.
attack_time :: proc(a: Attacks, i: int) -> f64 {
	return a.first_seconds + f64(i) * a.step_seconds
}

ogg_attacks :: proc(ogg: []u8) -> (result: Attacks, ok: bool) {
	d: Ogg_Decoder
	if !ogg_open(&d, ogg) {
		ogg_close(&d)
		return {}, false
	}
	defer ogg_close(&d)
	builder := attack_builder_make(d.sample_rate)
	for samples in ogg_next(&d) do attack_builder_add(&builder, samples, d.channels)
	if d.error != nil {
		attack_builder_destroy(&builder)
		return {}, false
	}
	return attack_builder_finish(&builder), true
}

// Strengths from samples fed in blocks (interleaved by channel), for any source.
Attack_Builder :: struct {
	rate:     int,
	pending:  [dynamic]f32, // mono samples not yet past a window's start
	start:    int,          // where the next window starts in `pending`
	frames:   int,          // samples seen in all
	previous: [ATTACK_WINDOW / 2 + 1]f32,
	have_previous: bool,
	flux:     [dynamic]f32,
	fft:      Fft,
}

attack_builder_make :: proc(rate: int) -> Attack_Builder {
	b := Attack_Builder{rate = rate}
	b.pending = make([dynamic]f32, 0, 4 * ATTACK_WINDOW)
	b.flux = make([dynamic]f32)
	fft_init(&b.fft)
	return b
}

attack_builder_destroy :: proc(b: ^Attack_Builder) {
	delete(b.pending)
	delete(b.flux)
}

attack_builder_add :: proc(b: ^Attack_Builder, samples: []f32, channels: int) {
	count := len(samples) / max(channels, 1)
	scale := 1 / f32(max(channels, 1))
	for i in 0..<count {
		sum: f32
		for channel in 0..<channels do sum += samples[i * channels + channel]
		append(&b.pending, sum * scale)
	}
	b.frames += count
	for len(b.pending) - b.start >= ATTACK_WINDOW {
		take_window(b, b.pending[b.start:][:ATTACK_WINDOW])
		b.start += ATTACK_HOP
	}
	// Keep the buffer short: move what's left to the front now and then.
	if b.start >= 8 * ATTACK_WINDOW {
		left := len(b.pending) - b.start
		copy(b.pending[:left], b.pending[b.start:])
		resize(&b.pending, left)
		b.start = 0
	}
}

@(private = "file")
take_window :: proc(b: ^Attack_Builder, window: []f32) {
	magnitudes: [ATTACK_WINDOW / 2 + 1]f32
	fft_magnitudes(&b.fft, window, magnitudes[:])
	for &m in magnitudes do m = fast_ln(1 + ATTACK_LOG_GAIN * m)
	if b.have_previous {
		rise: f32
		for m, k in magnitudes do rise += max(m - b.previous[k], 0)
		append(&b.flux, rise)
	}
	b.previous = magnitudes
	b.have_previous = true
}

attack_builder_finish :: proc(b: ^Attack_Builder) -> Attacks {
	defer delete(b.pending)
	flux := b.flux[:]
	strength := make([]f32, len(flux))
	// The strength over its moving average (a running sum), kept above zero.
	half := ATTACK_LEVEL_SPAN / 2
	running: f64
	for i in 0..<min(half, len(flux)) do running += f64(flux[i])
	for i in 0..<len(flux) {
		if i + half < len(flux) do running += f64(flux[i + half])
		if i - half - 1 >= 0 do running -= f64(flux[i - half - 1])
		level := f32(running / ATTACK_LEVEL_SPAN) // edges: zeros beyond the song, as numpy's "same"
		strength[i] = max(flux[i] - level, 0)
	}
	delete(b.flux)
	rate := f64(max(b.rate, 1))
	return Attacks{
		strength      = strength,
		first_seconds = (ATTACK_WINDOW / 2 + ATTACK_HOP / 2) / rate,
		step_seconds  = ATTACK_HOP / rate,
		song_seconds  = f64(b.frames) / rate,
	}
}

// ln(x) for x >= 1, to about 1e-4: the exponent from the float's bits, a polynomial for the rest.
// The strengths only need to rise and fall like the true ones, and this is several times faster than
// math.ln, which runs 257 times per window.
@(private = "file")
fast_ln :: #force_inline proc "contextless" (x: f32) -> f32 {
	bits := transmute(u32)x
	exponent := f32(i32(bits >> 23) - 127)
	m := transmute(f32)((bits & 0x007f_ffff) | 0x3f80_0000) - 1 // mantissa - 1, in [0, 1)
	// log2(1 + m), a fit on [0, 1)
	log2 := m * (1.4425449 + m * (-0.7181452 + m * (0.4575485 + m * (-0.2779042 + m * (0.121797 + m * -0.0258411)))))
	return (exponent + log2) * 0.6931472
}

// A real FFT of ATTACK_WINDOW samples through a complex one of half the size, with a Hann window.
@(private = "file")
FFT_HALF :: ATTACK_WINDOW / 2

Fft :: struct {
	hann:      [ATTACK_WINDOW]f32,
	twiddle:   [FFT_HALF]complex64,      // e^(-2 pi i k / FFT_HALF), first half used by the butterflies
	untangle:  [FFT_HALF]complex64,      // e^(-2 pi i k / ATTACK_WINDOW), for splitting the halves
	reversed:  [FFT_HALF]u16,            // bit-reversed order
}

@(private = "file")
fft_init :: proc(f: ^Fft) {
	for i in 0..<ATTACK_WINDOW {
		// numpy's np.hanning: symmetric, zero at both ends
		f.hann[i] = f32(0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / f64(ATTACK_WINDOW - 1)))
	}
	for k in 0..<FFT_HALF {
		a := -2 * math.PI * f64(k) / f64(FFT_HALF)
		f.twiddle[k] = complex(f32(math.cos(a)), f32(math.sin(a)))
		u := -2 * math.PI * f64(k) / f64(ATTACK_WINDOW)
		f.untangle[k] = complex(f32(math.cos(u)), f32(math.sin(u)))
	}
	bits := 0
	for (1 << uint(bits)) < FFT_HALF do bits += 1
	for i in 0..<FFT_HALF {
		r := 0
		for bit in 0..<bits do if i & (1 << uint(bit)) != 0 do r |= 1 << uint(bits - 1 - bit)
		f.reversed[i] = u16(r)
	}
}

// |X[k]| for k = 0 ..= ATTACK_WINDOW/2 of the windowed samples.
@(private = "file")
fft_magnitudes :: proc(f: ^Fft, samples: []f32, out: []f32) {
	z: [FFT_HALF]complex64
	// Even samples as real parts, odd as imaginary, in bit-reversed order.
	for i in 0..<FFT_HALF {
		j := int(f.reversed[i])
		z[i] = complex(samples[2 * j] * f.hann[2 * j], samples[2 * j + 1] * f.hann[2 * j + 1])
	}
	for size := 2; size <= FFT_HALF; size *= 2 {
		half := size / 2
		stride := FFT_HALF / size
		for start := 0; start < FFT_HALF; start += size {
			for k in 0..<half {
				t := f.twiddle[k * stride] * z[start + k + half]
				z[start + k + half] = z[start + k] - t
				z[start + k] += t
			}
		}
	}
	// Split into the spectra of the even and odd samples, then combine.
	for k in 0..=FFT_HALF {
		a := z[k % FFT_HALF]
		b := conj(z[(FFT_HALF - k) % FFT_HALF])
		even := (a + b) * 0.5
		odd := (a - b) * complex64(complex(0, -0.5))
		w := f.untangle[k] if k < FFT_HALF else complex64(-1)
		x := even + w * odd
		out[k] = abs(x)
	}
}
