# A2ITG2

An Android app that takes songs from StepMania pack sites onto an ITG2 arcade cabinet's USB stick,
through the phone's USB OTG port. Written in Odin; a functional app, not a pretty one.

**Status: copying songs, MP3s converted.** The app reads a pack's table of contents over HTTPS (a few small
byte ranges, not the whole pack), lists its songs, and copies a tapped song onto the stick: its `.sm` chart and
the files the chart names, without videos. MP3 audio is converted to Ogg Vorbis within the audio limit, with
the sync kept to the sample, and the chart's `#MUSIC` is pointed at the new file.
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

1. Plug the stick into the phone and open A2ITG2.
2. Tap the **STICK** row and pick the folder songs should go in: on a stick the cabinet has used, its
   "In The Groove 2" folder's Songs folder. The app remembers it.
3. **AUDIO LIMIT** is the most a song's Ogg may take; tap - or + to change it (0.1 MB steps). MP3s are
   converted to the best quality that fits.
4. The pack (for now always #10850, a small test pack) is read on start; its songs appear below.
   Tap **PACK** to read it again.
5. Tap a song. Its row shows the files as they copy (and `CONVERTING` while an MP3 becomes an Ogg); the
   top strip turns green with `SAFE TO UNPLUG`.

Blue strip: working. Green: done. Red: a step failed, and the text says which and why.
