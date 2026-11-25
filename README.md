# A2ITG2

An Android app that takes songs from StepMania pack sites onto an ITG2 arcade cabinet's USB stick,
through the phone's USB OTG port. Written in Odin; a functional app, not a pretty one.

**Status: finding packs, copying songs, MP3s converted, length patch.** The PACKS page searches the site by pack
name (on the phone, as you type), song title, artist or chart author. The SONGS page reads the chosen pack's table of
contents over HTTPS (a few small byte ranges, not the whole pack), lists its songs, and copies a tapped song onto the stick: its `.sm` chart and
the files the chart names, without videos. MP3 audio is converted to Ogg Vorbis within the audio limit, with
the sync kept to the sample, and the chart's `#MUSIC` is pointed at the new file. With the length patch on,
Oggs over 1:45 are patched so the cabinet reads them as 1:45 (r21 cabinets then play them through).
See [docs/DESIGN.md](docs/DESIGN.md) for the plan and [docs/MAP.md](docs/MAP.md) for where things live.

## Getting the app

GitHub builds the app on every push to `main` and publishes it here. Open this link on the phone:

**https://github.com/Mireneye/A2ITG2/releases/download/latest/a2itg2.apk**

Open the downloaded file to install it (allow installing from the browser when Android asks).
Later builds install over it as updates, because every build is signed with the same key.

That key lives in the repository's secret `ANDROID_DEBUG_KEYSTORE`. Without it GitHub still builds
(as a compile check) but publishes nothing.

## Building on a PC (optional)

Only needed to build without GitHub. Needs Odin dev-2026-11a or newer on `PATH`, a JDK, and Android's
command-line tools with `"platform-tools" "build-tools;37.0.0" "platforms;android-36"` and the newest
`ndk;30...` installed through `sdkmanager`, with `ODIN_ANDROID_NDK` pointing at the NDK. Build the audio
libraries once, in Git Bash (`TOOLS` being the NDK's `toolchains/llvm/prebuilt/windows-x86_64/bin`):

    tools/build_audio_libs.sh libs/android_arm64 "$TOOLS/clang --target=aarch64-linux-android29" "$TOOLS/llvm-ar"

Then:

    build.bat            builds build\a2itg2.apk
    build.bat install    also installs and starts it on a phone plugged in with USB debugging

## Using it

**PACKS page**: find a pack.
1. With nothing typed, the newest packs on the site are listed.
2. Pick what to search by: **PACK**, **TITLE**, **ARTIST** or **AUTHOR**. Tap the search text to type: Android's
   own keyboard comes up in a small dialog. Pack names are searched as you type; the others ask the site when you
   tap **Search** (about 3 seconds).
3. Pack results show each pack's size and song count; `SM5` marks packs made for StepMania 5, whose charts may be
   `.ssc` only (ITG2 reads `.sm`). Song results show one song per row, under the name of its pack.
4. Tap a result to open its pack on the SONGS page (a picked song is highlighted there). The app remembers the pack.

**SONGS page**: copy songs.
1. Plug the stick into the phone. Tap **STICK** and pick the folder songs should go in: on a stick the cabinet has
   used, its "In The Groove 2" folder's Songs folder. The app remembers it.
2. **MAX AUDIO** is the most a song's Ogg may take; tap - or + (0.1 MB steps). MP3s are converted to the best
   quality that fits; an Ogg over the limit is re-encoded smaller (Oggs that fit are copied untouched).
3. **LENGTH PATCH** ON/OFF (on by default): songs over 1:45 get the Ogg length patch, so an r21 cabinet reads them
   as 1:45 and plays all of them. (r23 cabinets cut custom songs at 2:00 regardless.)
4. Tap a song. Its row fills as it copies: by files, then by percent while an MP3 becomes an Ogg (`CONVERTING TO OGG
   37%`) or a big Ogg is made smaller (`SHRINKING THE OGG 37%`; `SMALLER .. (TRY 2)` if the first try came out over
   the limit). The top strip turns green with `SAFE TO UNPLUG`.

Blue strip: working. Green: done. Red: a step failed, and the text says which and why.
