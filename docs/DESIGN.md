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

**Shrinking Oggs, as built.** An Ogg over the audio limit is decoded with libvorbisfile (StepMania's own Ogg
decoder, from the same Vorbis source) through a port of StepMania's read loop (gaps filled with silence so later
audio stays in sync), then encoded again like a converted MP3. Only Oggs over the limit are touched, since
re-encoding lossy audio costs a little quality. Tests: clicks on the same samples and the same length after
shrinking (also read back by stb_vorbis), size limits met, and a length-patched Ogg keeps its whole song (the
sample count comes from decoding, not from the length the file states). For speed, libogg and libvorbis are built
with Xiph's own flags (-O3 -ffast-math), and an Ogg's stated length is trusted unless the file was length patched
(its last page states fewer samples than the page before), which saves decoding it once just to count.

**The length patch, as built.** ITG2 reads a song's length from the Ogg's last page: its granule position, a
sample count. The patch (as github.com/LHCGreg/itgoggpatch does it) sets that to 105 s worth of samples and
recomputes the page's checksum; nothing else in the file changes (12 bytes at most, same file size), and the
start of the song, so its sync, is untouched. Patched: every Ogg longer than 1:45 (itgoggpatch only takes songs
over 2:00, which would leave 1:45-2:00 songs reading their real length on the cabinet). Tests check the new
length with an independent reader (stb_vorbis), every page's checksum with an independent CRC, and that every
decoded sample up to the stated length is unchanged. Found along the way: a player that trusts the last page's
granule may drop that final block of audio (stb_vorbis: 576 samples, 13 ms) at the very end; the cabinet's
behaviour there is to be seen.

**Finding packs.** The site (github.com/concubidated/simfile-pack-search) has a small JSON API: `/api/packs`
lists every pack (id, name, song count, size, type, minimum StepMania version; 10,100 packs, 0.8 MB) and
`/api/search/?type=title|artist|credit&query=...` returns packs with matching songs (about 3 s). The app keeps the
pack list for a day and searches pack names on the phone; song, artist and author searches go to the site, since
there is no list of all songs to keep (and one would be far over a few MB).

**Stock cabinet limits** (from players, to be confirmed on the cabinet): about 50 songs per stick,
audio under 5 MB and in OGG, songs fading out around 105 s. A modded cabinet (Simply Love theme) may lift
the length limit.

**The cabinet wants charts on the music itself (cab offset 0).** Four songs the user finds perfect on their
cabinet (Doki Doki, 1001 Arabian Nights, Turii -Panta Rhei-, Angels Crying) were measured: their notes sit
-3.3, +2.9, +5.4 and +3.0 ms from the music's attacks, 2.0 ms on average, far inside the tightest judgement
window (about 21 ms). So no correction is added for this cabinet; a chart carrying the ~9 ms PC-to-ITG
difference will feel about 9 ms off on it.

**Measuring a chart's sync** (`src/audio/attacks.odin`, `src/audio/sync_match.odin`, `src/chart/`). The Ogg
that goes onto the stick is decoded as StepMania plays it, mixed to mono, and cut into 512-sample windows
every 64 samples (1.45 ms); the attack strength is each window's rise in log spectrum (spectral flux), less
its 220 ms average. Every shift of the notes within +-100 ms is scored by the average strength under the
notes; the best shift, refined between steps, is the measurement. The method reads attacks 2.9 ms early on a
known click track, which is added back. It is Unsure when the best shift barely stands out (best / average
under 2.5: the four songs score 6-23, a chart against another song's audio 1.4 at most) or a rival shift
20+ ms away comes within 85% of it. Every chart's notes in the .sm are used (taps, hold and roll heads).
On a PC it takes 0.6 s per song, decoding included; spacing windows half as far apart measured within
0.2 ms of this at twice the cost. The app only shows the result (a mark on the song, and the #OFFSET that
would fit): the sync is the user's to change. Tests: the click track measures 0 and +9 ms when moved; the
four songs (the user's own files in the git-ignored `tests/fixtures/sync/`, skipped when missing) measure
under 6 ms, and each chart against another song's audio comes out Unsure.

**Changing a song's sync (SYNC page).** Only the chart's `#OFFSET` changes; the audio is never touched, so
tempo changes and stops in the chart stay where they are. The page lists the song folders in the stick
folder; an opened song shows its `#OFFSET` and how far the notes have moved from the original. NOTES
EARLIER raises `#OFFSET` by the chosen step (0.1, 1, 10 or 100 ms), NOTES LATER lowers it; each change is
written to the stick at once (only the newest of quick taps, since the stick is slow) and fsynced. Four
decimals are written only when a tenth of a millisecond is used. Before a chart is first changed the whole
original `.sm` is kept in the app's private folder (`sync_backups/`, named by a hash of the stick folder and
the chart's document id); RESET writes it back and drops it. MEASURE reads the song's Ogg from the stick (a
few seconds over USB 1.1) and measures it as on copying; after nudges, the page shows what is left of the
measured difference. No cabinet-wide offset setting: the cab-perfect songs say this cabinet wants 0.

**Previews.** The button at a song's right on SONGS downloads its chart and audio and plays the audio from
the chart's `#SAMPLESTART`, the point the song wheel plays, until paused or the song ends. Decoding is the
app's own (as the cabinet plays it), reaching the preview point by decoding and dropping, so it starts on the
exact sample; a thread fills a 0.74 s ring that AAudio's callback plays from. The downloaded files stay in the
app's `preview_cache/` (60 MB at most, oldest dropped first), and copying a song takes them from there: the
preview is the download, the copy is the commit. The song pauses when the app leaves the screen.
SYNC rows have the same button: the song is read straight from the stick into memory and played; nothing is
copied anywhere.

**Metronome.** While a song plays on SYNC (SONGS previews are for listening), the app can click on every beat of its chart: the beats'
times come from `#BPMS` and `#STOPS` at `#OFFSET` 0 (`chart.metronome_ticks`, through the measure after the
last note), and the player subtracts the offset as it mixes, so on SYNC the clicks move with each nudge as it
is made, before the stick has it. Clicks are short tones (1 kHz, 1.5 kHz on each measure's first beat,
fading to 1/e in 12 ms, loudness set by SYNC's CLICKS row, 10-200%; the first version, 4 ms at half level, was lost under a loud mix), with the music
dipping to 35% under each click and back within its tail, placed by the song's own sample count in AAudio's
callback (`src/metronome`); music and clicks share one
stream, so the phone's output delay can't pull them apart. Clicks on the drums mean the chart is on the music.

**When #MUSIC names a file that isn't there.** StepMania and OpenITG (the open rebuild of the ITG2 engine,
`Song::TidyUpData`) then use the folder's audio: they list `.mp3`, `.ogg` and `.wav` files and take the first,
or the second when there are several and the first's name starts with "intro" (a KSF intro). So a song whose
chart names its audio wrongly still plays on the cabinet. The app does the same for copying, previews and the
SYNC page, with `.ogg` before `.mp3` (the cabinet plays only Ogg), and the copied chart's `#MUSIC` names the
file chosen, so the cabinet never has to guess.

**Zip file names.** A name is UTF-8 when its entry's UTF-8 flag (bit 11) is set, or when Info-ZIP's Unicode
path field (0x7075) carries a UTF-8 copy matching the stored name's CRC. Otherwise the zip format says CP437,
which old Windows zippers wrote (`²` is the byte 0xFD); such names are decoded to UTF-8, unless they already
read as valid UTF-8 (many tools write UTF-8 without the flag). Raw CP437 bytes would otherwise reach Android as
broken names, failing folder and file creation and comparisons with the chart's tags.

**Finding tags in a chart.** Charts are often not valid UTF-8 (a Latin-1 `²` is the single byte 0xB2).
Tags are found byte by byte in the chart itself, comparing only the ASCII tag letters without regard to case
(`chart.tag_value`, `chart.replace_tag_value`). An earlier version searched an upper-cased copy and used that
position in the original; upper-casing turns an invalid byte into the 3-byte U+FFFD, so every tag after such a
byte landed 2 bytes off: `#MUSIC` names were misread (songs reported as missing their audio) and rewritten
values were put in the wrong place (`#OFFSET:-0-0.201;`). Every chart change on the stick is now also read back
and compared with what was written.

**Assist tick (CLICKS: NOTES).** Besides BEATS, the metronome can click on every note (every chart's,
a jump once), StepMania's "assist tick". It tells a chart's own timing against the music even when the
chart's BPM is wrong, as in hand-placed charts (a made-up high BPM with notes on a 64th grid, like the
Chobits chart: 50% 64ths, 24% 32nds, just as notes dropped at random would fall), where beat clicks can
never sit on the music. Row text fits the 30-letter-wide screen: CLICKS label at most 11 letters, slim
- and +, a switch a fifth of the width for "NOTES".
