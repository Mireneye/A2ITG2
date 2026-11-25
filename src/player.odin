/*
Playing a song's audio on the phone, for previews on the SONGS page.

	player_play(preview)                        starts (takes the preview; stops whatever was playing)
	player_pause() / player_resume()
	player_set_clicks(on)                       the metronome on or off, any time
	player_set_offset(seconds)                  the #OFFSET the metronome follows, any time
	player_stop()
	player_finished()                           true once a song has played to its end

A thread decodes the song (with the app's own decoders, so it sounds as the cabinet plays it) into a
ring of PLAYER_RING_FRAMES; AAudio's callback takes from the ring on Android's audio thread and plays
silence if the ring runs dry. The thread skips to `from_seconds` by decoding and dropping, so the start
is on the exact sample. Pausing stops AAudio; the thread waits while the ring is full.

The metronome is mixed in by the callback, from the song's own sample count: a click at every beat
of the chart (its time at #OFFSET 0, less the offset), a higher one starting each measure. Music and
clicks leave through the same stream, so the phone's output delay moves both alike: what is heard is
the chart's timing against the music, as the cabinet would play it.
*/
package a2itg2

import "base:intrinsics"
import "core:math"
import "core:thread"
import "core:time"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import aaudio "vendor:android/aaudio"
import "audio"
import "chart"

PLAYER_RING_FRAMES :: 32 * 1024 // 0.74 s at 44.1 kHz: room for the decoder to fall behind now and then
PLAYER_MAX_CHANNELS :: 2
CLICK_FRAMES        :: 1200 // the longest click, 27 ms at 44.1 kHz
CLICK_HZ            :: 1600
DOWNBEAT_HZ         :: 2400
CLICK_LOUDNESS      :: 0.5

@(private = "file")
Player :: struct {
	stream:   ^aaudio.AAudioStream,
	worker:   ^thread.Thread,
	bytes:    []u8,
	ticks:    []chart.Tick,
	format:   audio.Source_Format,
	from:     f64,
	start_frame: i64, // the song's sample frame the ring starts at
	offset_bits: u64, // the #OFFSET the clicks follow, as the f64's bits (set from the app's loop)
	clicks:   bool,
	click:    [2][CLICK_FRAMES]f32, // beat, downbeat
	channels: int,
	rate:     int,
	ring:     []f32, // PLAYER_RING_FRAMES * channels
	written:  u64,   // frames written into the ring (by the decoding thread)
	read:     u64,   // frames taken (by AAudio's callback)
	stop:     bool,  // asks the decoding thread to end
	decoded:  bool,  // the decoding thread reached the song's end
	finished: bool,  // ... and the ring has played out
}

@(private = "file") player: Player

// Starts the preview (its memory becomes the player's) from its preview point. "" or a problem to show.
player_play :: proc(preview: Preview, clicks: bool) -> string {
	player_stop()
	bytes, format, from_seconds := preview.sound, preview.format, preview.start_seconds
	ticks := preview.ticks
	handed_over := false // once the player holds the ticks, player_stop frees them
	defer if !handed_over do delete(ticks)
	probe: audio.Decoder
	if !audio.decoder_open(&probe, format, bytes) {
		audio.decoder_close(&probe)
		delete(bytes)
		return "THE AUDIO COULD NOT BE READ"
	}
	channels, rate := probe.channels, probe.sample_rate
	audio.decoder_close(&probe)
	if channels > PLAYER_MAX_CHANNELS {
		delete(bytes)
		return "ONLY MONO AND STEREO AUDIO CAN BE PLAYED"
	}

	builder: ^aaudio.AAudioStreamBuilder
	if result := aaudio.AAudio_createStreamBuilder(&builder); result != .OK {
		delete(bytes)
		return string(aaudio.AAudio_convertResultToText(result))
	}
	defer aaudio.AAudioStreamBuilder_delete(builder)
	aaudio.AAudioStreamBuilder_setFormat(builder, .PCM_FLOAT)
	aaudio.AAudioStreamBuilder_setChannelCount(builder, i32(channels))
	aaudio.AAudioStreamBuilder_setSampleRate(builder, i32(rate)) // AAudio resamples if the phone runs another rate
	aaudio.AAudioStreamBuilder_setUsage(builder, .USAGE_MEDIA)
	aaudio.AAudioStreamBuilder_setContentType(builder, .MUSIC)
	aaudio.AAudioStreamBuilder_setDataCallback(builder, fill_callback, nil)
	stream: ^aaudio.AAudioStream
	if result := aaudio.AAudioStreamBuilder_openStream(builder, &stream); result != .OK {
		delete(bytes)
		return string(aaudio.AAudio_convertResultToText(result))
	}

	player = Player{stream = stream, bytes = bytes, ticks = ticks, format = format, from = from_seconds, channels = channels, rate = rate, clicks = clicks}
	player.start_frame = i64(max(from_seconds, 0) * f64(rate))
	player.offset_bits = transmute(u64)preview.offset
	for &click, kind in player.click {
		// A short tone that fades out fast: easy to place against a drum hit.
		hz := f64(DOWNBEAT_HZ if kind == 1 else CLICK_HZ)
		for &sample, i in click {
			t := f64(i) / f64(rate)
			sample = f32(CLICK_LOUDNESS * math.sin(2 * math.PI * hz * t) * math.exp(-t / 0.004))
		}
	}
	handed_over = true
	player.ring = make([]f32, PLAYER_RING_FRAMES * channels)
	player.worker = thread.create_and_start(decode_thread)
	if result := aaudio.AAudioStream_requestStart(stream); result != .OK {
		problem := string(aaudio.AAudio_convertResultToText(result))
		player_stop()
		return problem
	}
	return ""
}

player_pause :: proc() {
	if player.stream != nil do aaudio.AAudioStream_requestPause(player.stream)
}

player_set_clicks :: proc(on: bool) {
	intrinsics.atomic_store_explicit(&player.clicks, on, .Relaxed)
}

player_set_offset :: proc(offset: f64) {
	intrinsics.atomic_store_explicit(&player.offset_bits, transmute(u64)offset, .Relaxed)
}

player_resume :: proc() {
	if player.stream != nil do aaudio.AAudioStream_requestStart(player.stream)
}

player_stop :: proc() {
	if player.stream == nil do return
	aaudio.AAudioStream_requestStop(player.stream)
	aaudio.AAudioStream_close(player.stream) // after this the callback no longer runs
	intrinsics.atomic_store_explicit(&player.stop, true, .Release)
	thread.join(player.worker)
	thread.destroy(player.worker)
	delete(player.ring)
	delete(player.bytes)
	delete(player.ticks)
	player = {}
}

player_finished :: proc() -> bool {
	return player.stream != nil && intrinsics.atomic_load_explicit(&player.finished, .Acquire)
}

@(private = "file")
decode_thread :: proc() {
	d: audio.Decoder
	defer audio.decoder_close(&d)
	if !audio.decoder_open(&d, player.format, player.bytes) {
		intrinsics.atomic_store_explicit(&player.decoded, true, .Seq_Cst)
		return
	}
	skip := max(int(player.from * f64(player.rate)), 0) // frames to drop before the preview point
	channels := player.channels
	for samples in audio.decoder_next(&d) {
		frames := len(samples) / channels
		offset := 0
		if skip > 0 {
			dropped := min(skip, frames)
			skip -= dropped
			offset = dropped
		}
		for offset < frames {
			if intrinsics.atomic_load_explicit(&player.stop, .Acquire) do return
			written := intrinsics.atomic_load_explicit(&player.written, .Relaxed)
			read := intrinsics.atomic_load_explicit(&player.read, .Seq_Cst)
			room := PLAYER_RING_FRAMES - int(written - read)
			if room == 0 {
				time.sleep(5 * time.Millisecond) // the ring is full: playing, or paused
				continue
			}
			count := min(room, frames - offset)
			for i in 0..<count {
				at := int((written + u64(i)) % PLAYER_RING_FRAMES) * channels
				copy(player.ring[at:at + channels], samples[(offset + i) * channels:][:channels])
			}
			offset += count
			intrinsics.atomic_store_explicit(&player.written, written + u64(count), .Release)
		}
	}
	intrinsics.atomic_store_explicit(&player.decoded, true, .Seq_Cst)
}

// On Android's audio thread: no allocating, no locks, no waiting.
@(private = "file")
fill_callback :: proc "c" (stream: ^aaudio.AAudioStream, user_data: rawptr, audio_data: rawptr, frame_count: i32) -> aaudio.aaudio_data_callback_result_t {
	out := ([^]f32)(audio_data)[:int(frame_count) * player.channels]
	read := intrinsics.atomic_load_explicit(&player.read, .Relaxed)
	written := intrinsics.atomic_load_explicit(&player.written, .Acquire)
	count := min(int(written - read), int(frame_count))
	channels := player.channels
	for i in 0..<count {
		at := int((read + u64(i)) % PLAYER_RING_FRAMES) * channels
		for c in 0..<channels do out[i * channels + c] = player.ring[at + c]
	}
	for i in count * channels..<len(out) do out[i] = 0
	if count > 0 && intrinsics.atomic_load_explicit(&player.clicks, .Relaxed) do mix_clicks(out, i64(read), count)
	intrinsics.atomic_store_explicit(&player.read, read + u64(count), .Seq_Cst)
	if count == 0 && intrinsics.atomic_load_explicit(&player.decoded, .Seq_Cst) && !intrinsics.atomic_load_explicit(&player.finished, .Relaxed) {
		intrinsics.atomic_store_explicit(&player.finished, true, .Release)
		android.ALooper_wake(glue.app().looper) // the app's loop notices and shows the song as stopped
	}
	return .CONTINUE
}

// Adds the clicks that sound during these `count` frames, which start `played` frames into the ring.
@(private = "file")
mix_clicks :: proc "contextless" (out: []f32, played: i64, count: int) {
	if len(player.ticks) == 0 do return
	offset := transmute(f64)intrinsics.atomic_load_explicit(&player.offset_bits, .Relaxed)
	rate := f64(player.rate)
	first := player.start_frame + played // the song's frame at out[0]
	last := first + i64(count)
	click_frame :: proc "contextless" (tick: chart.Tick, offset, rate: f64) -> i64 {
		return i64(math.round((tick.seconds - offset) * rate))
	}
	// The first tick whose click is still sounding at `first`.
	low, high := 0, len(player.ticks)
	for low < high {
		middle := (low + high) / 2
		if click_frame(player.ticks[middle], offset, rate) + CLICK_FRAMES <= first {
			low = middle + 1
		} else {
			high = middle
		}
	}
	channels := player.channels
	for tick in player.ticks[low:] {
		start := click_frame(tick, offset, rate)
		if start >= last do break
		click := &player.click[1 if tick.downbeat else 0]
		for frame in max(start, first)..<min(start + CLICK_FRAMES, last) {
			value := click[frame - start]
			at := int(frame - first) * channels
			for c in 0..<channels do out[at + c] = clamp(out[at + c] + value, -1, 1)
		}
	}
}
