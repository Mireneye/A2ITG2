// The bindings' struct layouts against the C compiler's (numbers from sizeof/offsetof on the
// libraries' own headers, see libraries.odin). A wrong offset here would corrupt memory silently.
package audio

import "core:testing"

@(test)
struct_layouts_match_c :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Mad_Stream), 120)
	testing.expect_value(t, offset_of(Mad_Stream, this_frame), 40)
	testing.expect_value(t, offset_of(Mad_Stream, next_frame), 48)
	testing.expect_value(t, offset_of(Mad_Stream, anc_ptr), 72)
	testing.expect_value(t, offset_of(Mad_Stream, anc_bitlen), 88)
	testing.expect_value(t, offset_of(Mad_Stream, error), 112)
	testing.expect_value(t, size_of(Mad_Header), 56)
	testing.expect_value(t, offset_of(Mad_Header, bitrate), 16)
	testing.expect_value(t, offset_of(Mad_Header, samplerate), 24)
	testing.expect_value(t, offset_of(Mad_Header, flags), 32)
	testing.expect_value(t, offset_of(Mad_Header, duration), 40)
	testing.expect_value(t, size_of(Mad_Frame), 9288)
	testing.expect_value(t, offset_of(Mad_Frame, sbsample), 60)
	testing.expect_value(t, offset_of(Mad_Frame, overlap), 9280)
	testing.expect_value(t, size_of(Mad_Synth), 13324)
	testing.expect_value(t, offset_of(Mad_Synth, phase), 4096)
	testing.expect_value(t, offset_of(Mad_Synth, pcm), 4100)
	testing.expect_value(t, size_of(Mad_Pcm), 9224)
	testing.expect_value(t, offset_of(Mad_Pcm, length), 6)
	testing.expect_value(t, offset_of(Mad_Pcm, samples), 8)
	testing.expect_value(t, size_of(Mad_Bitptr), 16)
	testing.expect_value(t, size_of(Ogg_Stream_State), 408)
	testing.expect_value(t, size_of(Ogg_Page), 32)
	testing.expect_value(t, offset_of(Ogg_Page, body), 16)
	testing.expect_value(t, offset_of(Ogg_Page, body_len), 24)
	testing.expect_value(t, size_of(Ogg_Packet), 48)
	testing.expect_value(t, size_of(Vorbis_Info), 56)
	testing.expect_value(t, size_of(Vorbis_Comment), 32)
	testing.expect_value(t, size_of(Vorbis_Dsp_State), 144)
	testing.expect_value(t, size_of(Vorbis_Block), 192)
	testing.expect_value(t, size_of(OggVorbis_File), 944)
	testing.expect_value(t, size_of(Ov_Callbacks), 32)
	testing.expect_value(t, offset_of(Vorbis_Info_Fields, channels), 4)
	testing.expect_value(t, offset_of(Vorbis_Info_Fields, rate), 8)
}
