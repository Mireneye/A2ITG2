/*
Playing a song's audio on the phone, for previews on the SONGS page.

	player_play(preview)                        starts (takes the preview; stops whatever was playing)
	player_pause() / player_resume()
	player_set_clicks(on)                       the metronome on or off, any time
	player_set_offset(seconds)                  the #OFFSET the metronome follows, any time
	player_set_click_volume(volume)             how loud the clicks are (1 = the metronome's default)
	player_stop()
	player_finished()                           true once a song has played to its end

A thread decodes the song (with the app's own decoders, so it sounds as the cabinet plays it) into a
ring of PLAYER_RING_FRAMES; AAudio's callback takes from the ring on Android's audio thread and plays
silence if the ring runs dry. The thread skips to `from_seconds` by decoding and dropping, so the start
is on the exact sample. Pausing stops AAudio; the thread waits while the ring is full.

The metronome (src/metronome) is mixed in by the callback, from the song's own sample count: a click
at every beat of the chart (its time at #OFFSET 0, less the offset), a higher one starting each
measure, the music dipping under each click so it can be heard over a loud mix. Music and
clicks leave through the same stream, so the phone's output delay moves both alike: what is heard is
the chart's timing against the music, as the cabinet would play it.
*/
package a2itg2

import "base:intrinsics"
import "core:thread"
import "core:time"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import aaudio "vendor:android/aaudio"
import "audio"
import "chart"
import "metronome"

PLAYER_RING_FRAMES :: 32 * 1024 // 0.74 s at 44.1 kHz: room for the decoder to fall behind now and then
PLAYER_MAX_CHANNELS :: 2

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
	volume_bits: u32, // the clicks' volume, as the f32's bits
	metronome: metronome.Metronome,
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
player_play :: proc(preview: Preview, clicks: bool, click_volume: f32) -> string {
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
	player.metronome = metronome.metronome_make(ticks, rate)
	player.volume_bits = transmute(u32)click_volume
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

player_set_click_volume :: proc(volume: f32) {
	intrinsics.atomic_store_explicit(&player.volume_bits, transmute(u32)volume, .Relaxed)
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
	if count > 0 && intrinsics.atomic_load_explicit(&player.clicks, .Relaxed) {
		offset := transmute(f64)intrinsics.atomic_load_explicit(&player.offset_bits, .Relaxed)
		volume := transmute(f32)intrinsics.atomic_load_explicit(&player.volume_bits, .Relaxed)
		metronome.mix(&player.metronome, out[:count * channels], channels, player.start_frame + i64(read), offset, volume)
	}
	intrinsics.atomic_store_explicit(&player.read, read + u64(count), .Seq_Cst)
	if count == 0 && intrinsics.atomic_load_explicit(&player.decoded, .Seq_Cst) && !intrinsics.atomic_load_explicit(&player.finished, .Relaxed) {
		intrinsics.atomic_store_explicit(&player.finished, true, .Release)
		android.ALooper_wake(glue.app().looper) // the app's loop notices and shows the song as stopped
	}
	return .CONTINUE
}

