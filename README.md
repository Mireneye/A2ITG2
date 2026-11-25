# A2ITG2

An Android app that takes songs from StepMania pack sites onto an ITG2 arcade cabinet's USB stick,
through the phone's USB OTG port. Written in Odin; a functional app, not a pretty one.

**Status: copying single songs.** The app reads a pack's table of contents over HTTPS (a few small byte
ranges, not the whole pack), lists its songs, and copies a tapped song onto the stick: its `.sm` chart and
the files the chart names, without videos. No audio conversion yet, so MP3 songs won't play on the cabinet.
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
`ndk;30...` installed through `sdkmanager`, with `ODIN_ANDROID_NDK` pointing at the NDK. Then:

    build.bat            builds build\a2itg2.apk
    build.bat install    also installs and starts it on a phone plugged in with USB debugging

## Using it

1. Plug the stick into the phone and open A2ITG2.
2. Tap the **STICK** row and pick the folder songs should go in: on a stick the cabinet has used, its
   "In The Groove 2" folder's Songs folder. The app remembers it.
3. The pack (for now always #10850, a small test pack) is read on start; its songs appear below.
   Tap **PACK** to read it again.
4. Tap a song. Its row shows the files as they copy; the top strip turns green with `SAFE TO UNPLUG`.

Blue strip: working. Green: done. Red: a step failed, and the text says which and why.
