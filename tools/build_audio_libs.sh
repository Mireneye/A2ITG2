#!/bin/sh
# Builds the audio libraries into one static library, libaudio.a: libmad (MP3 decoding), libogg and libvorbis (Ogg Vorbis
# encoding). Same sources and settings as StepMania 5, so decoding matches what chart authors heard.
# (A shell script: build tooling, run by GitHub's build and in Claude's sandbox for the tests.)
#
#   tools/build_audio_libs.sh <output folder> <C compiler> [archiver]
#   tools/build_audio_libs.sh libs/linux_amd64 clang                                   # for `odin test`
#   tools/build_audio_libs.sh libs/android_arm64 "$NDK_CLANG --target=aarch64-linux-android29" "$NDK_AR"
#
# Sources are fetched once into third_party/ (git-ignored), at pinned commits:
#   libmad 0.15.1b  as bundled in StepMania (stepmania/stepmania extern/libmad)
#   libogg, libvorbis  the commits StepMania pins as submodules (xiph/ogg, xiph/vorbis)
set -e
OUT=$1
CC=$2
AR=${3:-ar}
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/third_party

STEPMANIA_COMMIT=7cbaff8ce2dcbede32dd3d6f3f2d8fafeafd674e
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
fetch stepmania https://github.com/stepmania/stepmania.git $STEPMANIA_COMMIT "/extern/libmad/"
fetch ogg https://github.com/xiph/ogg.git $OGG_COMMIT
fetch vorbis https://github.com/xiph/vorbis.git $VORBIS_COMMIT

MAD=$SRC/stepmania/extern/libmad
GEN=$SRC/generated
mkdir -p "$GEN/ogg" "$OUT"

# What CMake would generate for a 64-bit Linux-like target (Android and Linux are both LP64).
cat > "$GEN/config.h" <<'H'
#define HAVE_ASSERT_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
H
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
mkdir -p "$BUILD/mad" "$BUILD/ogg" "$BUILD/vorbis"
FLAGS="-O2 -fPIC -w"

for f in bit decoder fixed frame huffman layer12 layer3 stream synth timer version; do
	$CC $FLAGS -DHAVE_CONFIG_H -DFPM_64BIT=1 -I"$GEN" -I"$MAD" -c "$MAD/$f.c" -o "$BUILD/mad/$f.o"
done
for f in bitwise framing; do
	$CC $FLAGS -I"$GEN" -I"$SRC/ogg/include" -c "$SRC/ogg/src/$f.c" -o "$BUILD/ogg/$f.o"
done
for f in analysis bitrate block codebook envelope floor0 floor1 info lookup lpc lsp mapping0 mdct psy registry res0 sharedbook smallft synthesis vorbisenc window; do
	$CC $FLAGS -I"$GEN" -I"$SRC/ogg/include" -I"$SRC/vorbis/include" -I"$SRC/vorbis/lib" -c "$SRC/vorbis/lib/$f.c" -o "$BUILD/vorbis/$f.o"
done

# One archive for all three: libvorbis needs libogg, and a single archive makes link order moot.
rm -f "$OUT/libaudio.a"
$AR rcs "$OUT/libaudio.a" "$BUILD"/mad/*.o "$BUILD"/ogg/*.o "$BUILD"/vorbis/*.o
rm -rf "$BUILD"
echo "built $OUT/libaudio.a (libmad, libogg, libvorbis)"
