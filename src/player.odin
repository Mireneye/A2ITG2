/*
Playing a song's audio on the phone, for previews on the SONGS page.

	player_play(bytes, format, from_seconds)   starts (takes the bytes; stops whatever was playing)
	player_pause() / player_resume()
	player_stop()
	player_finished()                           true once a song has played to its end

A thread decodes the song (with the app's own decoders, so it sounds as the cabinet plays it) into a
ring of PLAYER_RING_FRAMES; AAudio's callback takes from the ring on Android's audio thread and plays
silence if the ring runs dry. The thread skips to `from_seconds` by decoding and dropping, so the start
is on the exact sample. Pausing stops AAudio; the thread waits while the ring is full.
*/
package a2itg2

import "base:intrinsics"
import "core:thread"
import "core:time"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import aaudio "vendor:android/aaudio"
import "audio"

PLAYER_RING_FRAMES :: 32 * 1024 // 0.74 s at 44.1 kHz: room for the decoder to fall behind now and then
PLAYER_MAX_CHANNELS :: 2

@(private = "file")
Player :: struct {
	stream:   ^aaudio.AAudioStream,
	worker:   ^thread.Thread,
	bytes:    []u8,
	format:   audio.Source_Format,
	from:     f64,
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

// Starts `bytes` (heap; the player frees them) from `from_seconds`. "" or a problem to show.
player_play :: proc(bytes: []u8, format: audio.Source_Format, from_seconds: f64) -> string {
	player_stop()
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

	player = Player{stream = stream, bytes = bytes, format = format, from = from_seconds, channels = channels, rate = rate}
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
	intrinsics.atomic_store_explicit(&player.read, read + u64(count), .Seq_Cst)
	if count == 0 && intrinsics.atomic_load_explicit(&player.decoded, .Seq_Cst) && !intrinsics.atomic_load_explicit(&player.finished, .Relaxed) {
		intrinsics.atomic_store_explicit(&player.finished, true, .Release)
		android.ALooper_wake(glue.app().looper) // the app's loop notices and shows the song as stopped
	}
	return .CONTINUE
}
