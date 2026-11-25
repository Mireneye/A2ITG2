# Design

## Goal

Browse StepMania packs, pick single songs, make them fit an ITG2 cabinet, and write them to the
cabinet's USB stick from the phone. Planned features beyond a plain copy:

1. Re-sync a song by an offset.
2. Optionally apply an .ogg patch so the cabinet plays songs longer than its stock limit.
3. Convert audio to fit the cabinet's file-size limit, with one slider for the target size in MB;
   the encoder finds the best quality that fits.

## Stack

- **Odin** for all app code, built with Odin's Android target (`-subtarget:android`, `odin bundle android`).
- **libmad** (MP3 decoding) and **libvorbis** (Ogg Vorbis encoding), C libraries called with `foreign import`.
  libmad is GPL: fine for personal use; sharing the app means releasing its source under the GPL.
- **TLS** copied from Weaving Mirage (`src/tls`, see `docs/VENDORED.md`); on Android the trusted roots come from
  `/apex/com.android.conscrypt/cacerts` or `/system/etc/security/cacerts`.
- **Deflate** copied from Folding Mirage (`src/inflate`), for unpacking songs from the zips.
- **Android's folder picker** for the USB stick, through `vendor:android/java`.

## Findings

**Single-song downloads work.** stepmaniaonline.net serves packs at `/download/pack/{id}/` and answers
HTTP range requests (206). Reading the zip's table of contents from the end and then only the bytes of
the wanted files works: one chart file from a 57.7 MB pack cost 73 KB of downloads. No Drive or
full-pack download needed.

**ZIP64 is required from the start.** Packs of 4 GB are common and the largest reach 12-15 GB. All sizes
and offsets are 64-bit; packs around 4 GB, where tools mix classic and ZIP64 records, are the case to test.

**Packs carry things to skip.** Background videos can dwarf the audio (21.9 MB `.avi` beside a 1.6 MB `.mp3`);
fetching single files means skipping them.

**MP3 to OGG must keep sync exactly as StepMania plays it.** StepMania 5 decodes MP3 with libmad
(`src/RageSoundReader_MP3.cpp`) and:

- trims nothing at the start: the decoder's 529-sample delay and the encoder's delay are all played;
- skips a "Xing" (VBR) info frame, but deliberately plays an "Info" (CBR) frame as 1152 samples of
  silence, to match DWI's decoder (BASS);
- plays frames it cannot decode at the start (e.g. after an MP3 was cut) as silence.

So the converter decodes with libmad, follows those three rules, and encodes every sample it outputs.
The OGG then lines up with the MP3 sample for sample and the chart's offset stays right without knowing
the encoder's delay. Vorbis adds no delay of its own. What remains is the known ~9 ms difference between
charts synced for PC and for ITG machines, which the offset feature covers.

**A song is its .sm chart and the files the chart names.** A song folder holds the chart (`.sm`;
StepMania 5 packs may also or only have `.ssc`, old ones `.dwi`), the audio (`.ogg`, or `.mp3` that the
cabinet can't play), and optionally a banner, background and CD title picture, a lyrics file (`.lrc`),
background or banner videos, and leftovers like `.old` backups. File names need not match the folder or
each other: the chart's `#MUSIC`, `#BANNER`, `#BACKGROUND`, `#CDTITLE` and `#LYRICSPATH` tags name them.
So copying a song means: read its `.sm`, copy it and the files it names that sit in the song folder,
leave out videos. ITG2 reads `.sm` only, so a song without one can't be copied as is.

**Where songs go on the stick.** The cabinet makes an "In The Groove 2" folder on a stick the first time
it reads it; song folders go into its Songs folder. The app copies into whatever folder is picked, so
picking that Songs folder puts songs where the cabinet looks.

**Revisions matter for long songs.** Custom songs from the stick came with the r21 update; r23 cuts
every custom song at 120 seconds whether or not the .ogg is patched, so the .ogg length patch only helps
on r21 cabinets.

**Conversion as built.** libmad 0.15.1b from StepMania's own tree, built with FPM_64BIT as StepMania does on
Linux/macOS (plain C arithmetic, so the phone and the test machine decode alike). The decoding loop is a port
of StepMania's, rules above included. Every decoded sample goes to libvorbis (StepMania's pinned commit) at an
average bitrate worked out from the limit and the song's length; if the file comes out over, the bitrate drops by
the overshoot and it is encoded again. Tests on click tracks (CBR with an Info frame, VBR with a Xing frame, no
frame) check the clicks land 1105 or 2257 samples late as StepMania plays them, and on the same sample in the Ogg,
with the same sample count. Below about 45 kbps libvorbis can't go: at the 4.8 MB default that is a 14-minute song.

**The length patch, as built.** ITG2 reads a song's length from the Ogg's last page: its granule position, a
sample count. The patch (as github.com/LHCGreg/itgoggpatch does it) sets that to 105 s worth of samples and
recomputes the page's checksum; nothing else in the file changes (12 bytes at most, same file size), and the
start of the song, so its sync, is untouched. Patched: every Ogg longer than 1:45 (itgoggpatch only takes songs
over 2:00, which would leave 1:45-2:00 songs reading their real length on the cabinet). Tests check the new
length with an independent reader (stb_vorbis), every page's checksum with an independent CRC, and that every
decoded sample up to the stated length is unchanged. Found along the way: a player that trusts the last page's
granule may drop that final block of audio (stb_vorbis: 576 samples, 13 ms) at the very end; the cabinet's
behaviour there is to be seen.

**Stock cabinet limits** (from players, to be confirmed on the cabinet): about 50 songs per stick,
audio under 5 MB and in OGG, songs fading out around 105 s. A modded cabinet (Simply Love theme) may lift
the length limit.
