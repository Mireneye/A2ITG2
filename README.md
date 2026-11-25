# A2ITG2

An Android app that takes songs from StepMania pack sites onto an ITG2 arcade cabinet's USB stick,
through the phone's USB OTG port. Written in Odin; a functional app, not a pretty one.

**Status: first test.** The app can pick a folder through Android's folder picker, keep access to it
across restarts, and write files into it. That proves every phone-side piece the real app needs
before the pack work starts. See [docs/DESIGN.md](docs/DESIGN.md) for the plan and [docs/MAP.md](docs/MAP.md)
for where things live.

## Setting up (once)

1. **Odin** dev-2026-11a or newer, on `PATH`. Use 11a, not dev-2026-11 (that one has a type-check bug).
2. **A JDK** (17 or newer, e.g. Temurin), through `JAVA_HOME` or `PATH`.
3. **Android's command-line tools** (no Android Studio needed): download "Command line tools only"
   for Windows from developer.android.com/studio (bottom of the page), and unzip it so this file exists:
   `%LocalAppData%\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat`
4. In a terminal, install the rest (the NDK version: pick the newest `ndk;30...` that
   `sdkmanager --list | findstr ndk` shows; Odin's bindings come from NDK r30):

       cd %LocalAppData%\Android\Sdk\cmdline-tools\latest\bin
       sdkmanager "platform-tools" "build-tools;37.0.0" "platforms;android-36" "ndk;30.0.XXXXXXX"

5. Point Odin at the NDK, then open a new terminal:

       setx ODIN_ANDROID_NDK "%LocalAppData%\Android\Sdk\ndk\30.0.XXXXXXX"

`build.bat` makes Android's debug signing key on first use if the PC has none.

## Building

    build.bat            builds build\a2itg2.apk
    build.bat install    also installs and starts it on a phone plugged in by USB

`install` needs USB debugging on the phone (Settings, About phone: tap "OS version" 7 times;
then Additional settings, Developer options, USB debugging; Xiaomi phones also need "Install via USB"
on in the same list). Without it, copy `build\a2itg2.apk`
to the phone and open it there (allow installing from that app when asked).

## The first test

1. Plug the USB stick into the phone and open A2ITG2. The top strip is blue; the text says no folder is picked.
2. Tap the screen. Android's folder picker opens. Choose the USB stick (or a folder on it) and allow access.
3. Expected: the strip turns green and the text says `WROTE A2ITG2_PICK.TXT`.
4. Close the app fully (swipe it away from recent apps) and open it again.
5. Expected, without any picker: green again, with `REOPENED: ACCESS KEPT WITHOUT ASKING.` and `WROTE A2ITG2_REOPEN.TXT`.
6. On a PC, the stick holds `a2itg2_pick.txt` and `a2itg2_reopen.txt`.

A red strip means a step failed; the text under it says which and why.
