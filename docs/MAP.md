# Map

| Path | What |
|---|---|
| `src/main.odin` | The app: start-up, the loop, status text, drawing the screen, the first-test flow |
| `src/folder.odin` | Folder access: Android's folder picker, keeping access across restarts, writing files into the folder |
| `src/documents.odin` | `android.provider.DocumentsContract` called through JNI by hand (Odin's generated bindings skip `android.provider`) |
| `src/text.odin` | Pixel drawing and a 5x7 bitmap font (ZZ-Replace: stand-in UI) |
| `app/AndroidManifest.xml` | The app's package name, its activity (`OdinActivity`) and library name (`a2itg2`) |
| `app/res/` | Resources: the app's name |
| `build.bat` | Builds the APK; `install` also puts it on the phone |
| `docs/DESIGN.md` | What the app is meant to become, and the findings behind it |

The build writes `app/lib/arm64-v8a/liba2itg2.so` and `build/a2itg2.apk`; both are git-ignored.
