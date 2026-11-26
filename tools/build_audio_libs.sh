#!/bin/sh
# Builds the audio libraries into one static library, libaudio.a: dr_mp3 (MP3 decoding, its frame decoder;
# the rules StepMania decodes MP3s by are in src/audio/mp3_decode.odin), libogg and libvorbis (Ogg Vorbis
# encoding, and decoding through vorbisfile as StepMania does). libogg and libvorbis are the commits
# StepMania 5 uses, so decoding matches what chart authors heard.
# (A shell script: build tooling, run by GitHub's build and in Claude's sandbox for the tests.)
#
#   tools/build_audio_libs.sh <output folder> <C compiler> [archiver]
#   tools/build_audio_libs.sh libs/linux_amd64 clang                                   # for `odin test`
#   tools/build_audio_libs.sh libs/android_arm64 "$NDK_CLANG --target=aarch64-linux-android29" "$NDK_AR"
#
# Sources are fetched once into third_party/ (git-ignored), at pinned commits:
#   dr_mp3  mackron/dr_libs (public domain or MIT-0)
#   libogg, libvorbis  the commits StepMania pins as submodules (xiph/ogg, xiph/vorbis; BSD)
set -e
OUT=$1
CC=$2
AR=${3:-ar}
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/third_party

DR_LIBS_COMMIT=dfbebc36e7a17a0f9511798c1bd77d96f0e74413
OGG_COMMIT=be05b13e98b048f0b5a0f5fa8ce514d56db5f822
VORBIS_COMMIT=0657aee69dec8508a0011f47f3b69d7538e9d262

fetch() { # <folder> <repository> <commit> [sparse path]
	if [ -f "$SRC/$1/.fetched-$3" ]; then return; fi
	rm -rf "$SRC/$1"
	git init -q "$SRC/$1"
	git -C "$SRC/$1" remote add origin "$2"
	if [ -n "$4" ]; then
		git -C "$SRC/$1" config core.sparseCheckout true
		echo "$4" > "$SRC/$1/.git/info/sparse-checkout"
	fi
	git -C "$SRC/$1" fetch -q --depth 1 --filter=blob:none origin "$3"
	git -C "$SRC/$1" checkout -q FETCH_HEAD
	touch "$SRC/$1/.fetched-$3"
}
fetch ogg https://github.com/xiph/ogg.git $OGG_COMMIT
fetch vorbis https://github.com/xiph/vorbis.git $VORBIS_COMMIT
fetch dr_libs https://github.com/mackron/dr_libs.git $DR_LIBS_COMMIT "/dr_mp3.h"

GEN=$SRC/generated
mkdir -p "$GEN/ogg" "$OUT"

# libogg's generated type header, for a 64-bit Linux-like target (Android and Linux are both LP64).
cat > "$GEN/ogg/config_types.h" <<'H'
#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__
#include <stdint.h>
typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;
#endif
H

BUILD=$OUT/.objects
rm -rf "$BUILD"
mkdir -p "$BUILD/ogg" "$BUILD/vorbis" "$BUILD/mp3"
FLAGS="-O2 -fPIC -w"
# libogg and libvorbis get the flags Xiph's own build uses for them: the encoder is where the time goes,
# and fast floating-point maths speeds it up a good deal. (dr_mp3 keeps plain -O2: MP3 decoding is quick, and
# exact floating-point maths keeps it the same on every machine.)
VORBIS_FLAGS="-O3 -ffast-math -fsigned-char -fPIC -w"

for f in bitwise framing; do
	$CC $VORBIS_FLAGS -I"$GEN" -I"$SRC/ogg/include" -c "$SRC/ogg/src/$f.c" -o "$BUILD/ogg/$f.o"
done
for f in analysis bitrate block codebook envelope floor0 floor1 info lookup lpc lsp mapping0 mdct psy registry res0 sharedbook smallft synthesis vorbisenc vorbisfile window; do
	$CC $VORBIS_FLAGS -I"$GEN" -I"$SRC/ogg/include" -I"$SRC/vorbis/include" -I"$SRC/vorbis/lib" -c "$SRC/vorbis/lib/$f.c" -o "$BUILD/vorbis/$f.o"
done

# dr_mp3 (public domain or MIT-0), only its frame decoder is used: float output, no file access.
cat > "$GEN/dr_mp3.c" <<'C'
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_FLOAT_OUTPUT
#define DR_MP3_NO_STDIO
#include "dr_mp3.h"
C
$CC $FLAGS -I"$SRC/dr_libs" -c "$GEN/dr_mp3.c" -o "$BUILD/mp3/dr_mp3.o"

# One archive for all three: libvorbis needs libogg, and a single archive makes link order moot.
rm -f "$OUT/libaudio.a"
$AR rcs "$OUT/libaudio.a" "$BUILD"/mp3/*.o "$BUILD"/ogg/*.o "$BUILD"/vorbis/*.o
rm -rf "$BUILD"
echo "built $OUT/libaudio.a (dr_mp3, libogg, libvorbis)"
