# A2ITG2

An Android app that takes songs from StepMania pack sites onto an ITG2 arcade cabinet's USB stick,
through the phone's USB OTG port. Written in Odin; a functional app, not a pretty one.

**Status: first test.** The app can pick a folder through Android's folder picker, keep access to it
across restarts, and write files into it. That proves every phone-side piece the real app needs
before the pack work starts. See [docs/DESIGN.md](docs/DESIGN.md) for the plan and [docs/MAP.md](docs/MAP.md)
for where things live.

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

## The first test

1. Plug the USB stick into the phone and open A2ITG2. The top strip is blue; the text says no folder is picked.
2. Tap the screen. Android's folder picker opens. Choose the USB stick (or a folder on it) and allow access.
3. Expected: the strip turns green and the text says `WROTE A2ITG2_PICK.TXT`.
4. Close the app fully (swipe it away from recent apps) and open it again.
5. Expected, without any picker: green again, with `REOPENED: ACCESS KEPT WITHOUT ASKING.` and `WROTE A2ITG2_REOPEN.TXT`.
6. On a PC, the stick holds `a2itg2_pick.txt` and `a2itg2_reopen.txt`.

A red strip means a step failed; the text under it says which and why.
