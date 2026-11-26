// The bindings' struct layouts against the C compiler's (numbers from sizeof/offsetof on the
// libraries' own headers, see libraries.odin). A wrong offset here would corrupt memory silently.
package audio

import "core:testing"

@(test)
struct_layouts_match_c :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Drmp3_Dec), 22928)
	testing.expect_value(t, size_of(Drmp3_Frame_Info), 20)
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
