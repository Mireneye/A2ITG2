/*
Bindings for the C audio libraries (built by tools/build_audio_libs.sh into libs/<target>/libaudio.a):
libmad 0.15.1b for MP3 decoding, libogg and libvorbis for Ogg Vorbis encoding.

Only what the converter calls. Structs the converter reads into are written out field by field;
structs it only hands back to the libraries are opaque blocks of the right size. layout_test.odin
checks every size and offset used here against what the C compiler says (Linux x86-64 and Android
arm64 lay these out the same: both are LP64 with natural alignment).
*/
package audio

import "core:c"

// libmad, libogg and libvorbis in one archive (see the build script).
when ODIN_PLATFORM_SUBTARGET == .Android {
	foreign import libaudio "../../libs/android_arm64/libaudio.a"
} else {
	foreign import libaudio "../../libs/linux_amd64/libaudio.a"
}

// ---- libmad ----

MAD_BUFFER_GUARD :: 8   // zero bytes after the last frame so the decoder can finish it
MAD_F_FRACBITS   :: 28  // mad_fixed_t is 4.28 fixed point
MAD_FLAG_LSF_EXT :: 0x1000

Mad_Error :: enum c.int {
	NONE           = 0x0000,
	BUFLEN         = 0x0001,
	BUFPTR         = 0x0002,
	NOMEM          = 0x0031,
	LOSTSYNC       = 0x0101,
	BADLAYER       = 0x0102,
	BADBITRATE     = 0x0103,
	BADSAMPLERATE  = 0x0104,
	BADEMPHASIS    = 0x0105,
	BADCRC         = 0x0201,
	BADBITALLOC    = 0x0211,
	BADSCALEFACTOR = 0x0221,
	BADMODE        = 0x0222,
	BADFRAMELEN    = 0x0231,
	BADBIGVALUES   = 0x0232,
	BADBLOCKTYPE   = 0x0233,
	BADSCFSI       = 0x0234,
	BADDATAPTR     = 0x0235,
	BADPART3LEN    = 0x0236,
	BADHUFFTABLE   = 0x0237,
	BADHUFFDATA    = 0x0238,
	BADSTEREO      = 0x0239,
}

// MAD_RECOVERABLE: errors in one frame that decoding can step past.
mad_recoverable :: proc(error: Mad_Error) -> bool {
	return u32(error) & 0xff00 != 0
}

Mad_Mode :: enum c.int {
	SINGLE_CHANNEL = 0,
	DUAL_CHANNEL   = 1,
	JOINT_STEREO   = 2,
	STEREO         = 3,
}

Mad_Bitptr :: struct {
	byte:  [^]u8,
	cache: c.ushort,
	left:  c.ushort,
}

Mad_Timer :: struct {
	seconds:  c.long,
	fraction: c.ulong,
}

Mad_Stream :: struct {
	buffer:     [^]u8,
	bufend:     [^]u8,
	skiplen:    c.ulong,
	sync:       c.int,
	freerate:   c.ulong,
	this_frame: [^]u8,
	next_frame: [^]u8,
	ptr:        Mad_Bitptr,
	anc_ptr:    Mad_Bitptr,
	anc_bitlen: c.uint,
	main_data:  rawptr,
	md_len:     c.uint,
	options:    c.int,
	error:      Mad_Error,
}

Mad_Header :: struct {
	layer:          c.int,
	mode:           Mad_Mode,
	mode_extension: c.int,
	emphasis:       c.int,
	bitrate:        c.ulong,
	samplerate:     c.uint,
	crc_check:      c.ushort,
	crc_target:     c.ushort,
	flags:          c.int,
	private_bits:   c.int,
	duration:       Mad_Timer,
}

Mad_Frame :: struct {
	header:   Mad_Header,
	options:  c.int,
	sbsample: [2][36][32]i32,
	overlap:  rawptr,
}

Mad_Pcm :: struct {
	samplerate: c.uint,
	channels:   c.ushort,
	length:     c.ushort,
	samples:    [2][1152]i32,
}

Mad_Synth :: struct {
	filter: [2][2][2][16][8]i32,
	phase:  c.uint,
	pcm:    Mad_Pcm,
}

// MAD_NCHANNELS
mad_channels :: proc(header: ^Mad_Header) -> int {
	return 1 if header.mode == .SINGLE_CHANNEL else 2
}

@(default_calling_convention = "c")
foreign libaudio {
	mad_stream_init     :: proc(stream: ^Mad_Stream) ---
	mad_stream_finish   :: proc(stream: ^Mad_Stream) ---
	mad_stream_buffer   :: proc(stream: ^Mad_Stream, buffer: [^]u8, length: c.ulong) ---
	mad_stream_skip     :: proc(stream: ^Mad_Stream, length: c.ulong) ---
	mad_stream_errorstr :: proc(stream: ^Mad_Stream) -> cstring ---
	mad_frame_init      :: proc(frame: ^Mad_Frame) ---
	mad_frame_finish    :: proc(frame: ^Mad_Frame) ---
	mad_frame_decode    :: proc(frame: ^Mad_Frame, stream: ^Mad_Stream) -> c.int ---
	mad_frame_mute      :: proc(frame: ^Mad_Frame) ---
	mad_synth_init      :: proc(synth: ^Mad_Synth) ---
	mad_synth_frame     :: proc(synth: ^Mad_Synth, frame: ^Mad_Frame) ---
	mad_synth_mute      :: proc(synth: ^Mad_Synth) ---
	mad_bit_read        :: proc(ptr: ^Mad_Bitptr, length: c.uint) -> c.ulong ---
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
