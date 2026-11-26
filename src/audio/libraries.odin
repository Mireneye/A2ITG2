/*
Bindings for the C audio libraries (built by tools/build_audio_libs.sh into libs/<target>/libaudio.a):
dr_mp3's frame decoder for MP3 decoding, libogg and libvorbis for Ogg Vorbis encoding, and libvorbis'
vorbisfile for Ogg Vorbis decoding (as StepMania reads Oggs).

Only what the converter calls. Structs the converter reads into are written out field by field;
structs it only hands back to the libraries are opaque blocks of the right size. layout_test.odin
checks every size and offset used here against what the C compiler says (Linux x86-64 and Android
arm64 lay these out the same: both are LP64 with natural alignment).
*/
package audio

import "core:c"

// dr_mp3, libogg and libvorbis in one archive (see the build script).
when ODIN_PLATFORM_SUBTARGET == .Android {
	foreign import libaudio "../../libs/android_arm64/libaudio.a"
} else {
	foreign import libaudio "../../libs/linux_amd64/libaudio.a"
}

// ---- dr_mp3 ----

// dr_mp3's frame decoder (minimp3's). drmp3dec's contents are dr_mp3's own: only its size matters here
// (sizeof(drmp3dec), checked in layout_test.odin).
Drmp3_Dec :: struct #align(8) {
	_: [22928]u8,
}

Drmp3_Frame_Info :: struct {
	frame_bytes:  c.int,
	channels:     c.int,
	sample_rate:  c.int,
	layer:        c.int, // 0 when no complete frame was found
	bitrate_kbps: c.int,
}

@(default_calling_convention = "c")
foreign libaudio {
	drmp3dec_init         :: proc(dec: ^Drmp3_Dec) ---
	// One frame into `pcm` (floats, interleaved): its samples per channel, 0 when it gave none.
	drmp3dec_decode_frame :: proc(dec: ^Drmp3_Dec, mp3: [^]u8, mp3_bytes: c.int, pcm: [^]f32, info: ^Drmp3_Frame_Info) -> c.int ---
}

// ---- libogg ----

Ogg_Stream_State :: struct #align(8) { _: [408]u8 } // opaque
Ogg_Packet       :: struct #align(8) { _: [48]u8 }  // opaque

Ogg_Page :: struct {
	header:     [^]u8,
	header_len: c.long,
	body:       [^]u8,
	body_len:   c.long,
}

@(default_calling_convention = "c")
foreign libaudio {
	ogg_stream_init     :: proc(stream: ^Ogg_Stream_State, serial: c.int) -> c.int ---
	ogg_stream_clear    :: proc(stream: ^Ogg_Stream_State) -> c.int ---
	ogg_stream_packetin :: proc(stream: ^Ogg_Stream_State, packet: ^Ogg_Packet) -> c.int ---
	ogg_stream_pageout  :: proc(stream: ^Ogg_Stream_State, page: ^Ogg_Page) -> c.int ---
	ogg_stream_flush    :: proc(stream: ^Ogg_Stream_State, page: ^Ogg_Page) -> c.int ---
	ogg_page_eos        :: proc(page: ^Ogg_Page) -> c.int ---
	ogg_page_checksum_set :: proc(page: ^Ogg_Page) ---
}

// ---- libvorbis (with vorbisenc) ----

Vorbis_Info      :: struct #align(8) { _: [56]u8 }  // opaque
Vorbis_Comment   :: struct #align(8) { _: [32]u8 }  // opaque
Vorbis_Dsp_State :: struct #align(8) { _: [144]u8 } // opaque
Vorbis_Block     :: struct #align(8) { _: [192]u8 } // opaque

@(default_calling_convention = "c")
foreign libaudio {
	vorbis_info_init            :: proc(info: ^Vorbis_Info) ---
	vorbis_info_clear           :: proc(info: ^Vorbis_Info) ---
	vorbis_comment_init         :: proc(comment: ^Vorbis_Comment) ---
	vorbis_comment_add_tag      :: proc(comment: ^Vorbis_Comment, tag, contents: cstring) ---
	vorbis_comment_clear        :: proc(comment: ^Vorbis_Comment) ---
	vorbis_encode_init          :: proc(info: ^Vorbis_Info, channels, rate, max_bitrate, nominal_bitrate, min_bitrate: c.long) -> c.int ---
	vorbis_analysis_init        :: proc(dsp: ^Vorbis_Dsp_State, info: ^Vorbis_Info) -> c.int ---
	vorbis_block_init           :: proc(dsp: ^Vorbis_Dsp_State, block: ^Vorbis_Block) -> c.int ---
	vorbis_block_clear          :: proc(block: ^Vorbis_Block) -> c.int ---
	vorbis_dsp_clear            :: proc(dsp: ^Vorbis_Dsp_State) ---
	vorbis_analysis_headerout   :: proc(dsp: ^Vorbis_Dsp_State, comment: ^Vorbis_Comment, header, comment_header, code_header: ^Ogg_Packet) -> c.int ---
	vorbis_analysis_buffer      :: proc(dsp: ^Vorbis_Dsp_State, samples: c.int) -> [^][^]f32 ---
	vorbis_analysis_wrote       :: proc(dsp: ^Vorbis_Dsp_State, samples: c.int) -> c.int ---
	vorbis_analysis_blockout    :: proc(dsp: ^Vorbis_Dsp_State, block: ^Vorbis_Block) -> c.int ---
	vorbis_analysis             :: proc(block: ^Vorbis_Block, packet: ^Ogg_Packet) -> c.int ---
	vorbis_bitrate_addblock     :: proc(block: ^Vorbis_Block) -> c.int ---
	vorbis_bitrate_flushpacket  :: proc(dsp: ^Vorbis_Dsp_State, packet: ^Ogg_Packet) -> c.int ---
}

// ---- vorbisfile (decoding) ----

OggVorbis_File :: struct #align(8) { _: [944]u8 } // opaque

// The start of vorbis_info: what the decoder reads from ov_info.
Vorbis_Info_Fields :: struct {
	version:  c.int,
	channels: c.int,
	rate:     c.long,
}

Ov_Callbacks :: struct {
	read_func:  proc "c" (destination: rawptr, size, count: c.size_t, source: rawptr) -> c.size_t,
	seek_func:  proc "c" (source: rawptr, offset: i64, whence: c.int) -> c.int,
	close_func: proc "c" (source: rawptr) -> c.int,
	tell_func:  proc "c" (source: rawptr) -> c.long,
}

OV_HOLE      :: -3
OV_EBADLINK  :: -137

@(default_calling_convention = "c")
foreign libaudio {
	ov_open_callbacks :: proc(source: rawptr, file: ^OggVorbis_File, initial: [^]u8, initial_bytes: c.long, callbacks: Ov_Callbacks) -> c.int ---
	ov_clear          :: proc(file: ^OggVorbis_File) -> c.int ---
	ov_info           :: proc(file: ^OggVorbis_File, link: c.int) -> ^Vorbis_Info_Fields ---
	ov_pcm_tell       :: proc(file: ^OggVorbis_File) -> i64 ---
	ov_pcm_total      :: proc(file: ^OggVorbis_File, link: c.int) -> i64 ---
	ov_read_float     :: proc(file: ^OggVorbis_File, pcm: ^[^][^]f32, samples: c.int, bitstream: ^c.int) -> c.long ---
}
