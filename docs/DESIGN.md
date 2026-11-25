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

**Stock cabinet limits** (from players, to be confirmed on the cabinet): about 50 songs per stick,
audio under 5 MB and in OGG, songs fading out around 105 s. A modded cabinet (Simply Love theme) may lift
the length limit.
