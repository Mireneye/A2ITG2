# Map

| Path | What |
|---|---|
| `src/main.odin` | The app: start-up, the loop, status text, touches, what each tap does |
| `src/screen.odin` | Drawing the screen (status, stick row, pack row, song list) and where the tap targets are |
| `src/worker.odin` | The worker thread: downloads and copies run here so the screen keeps answering |
| `src/pack.odin` | A pack on stepmaniaonline.net: reading its table of contents, finding its songs, copying one song (its `.sm` and the files the `.sm` names) |
| `src/folder.odin` | The stick: Android's folder picker, keeping access across restarts, making folders and files (fsynced) |
| `src/documents.odin` | `android.provider.DocumentsContract` called through JNI by hand (Odin's generated bindings skip `android.provider`) |
| `src/text.odin` | Pixel drawing and a 5x7 bitmap font (ZZ-Replace: stand-in UI) |
| `src/web/` | HTTPS GET of a byte range, over `src/tls` |
| `src/zip/` | Reading a zip a few byte ranges at a time, ZIP64 included; `zip_test.odin` tests it |
| `src/tls/` | TLS 1.3/1.2 client, copied from Weaving Mirage (see `docs/VENDORED.md`) |
| `src/inflate/` | Deflate decoder, copied from Folding Mirage (see `docs/VENDORED.md`) |
| `app/AndroidManifest.xml` | The app's package name, its activity (`OdinActivity`), library name (`a2itg2`), internet permission |
| `app/res/` | Resources: the app's name |
| `.github/workflows/build.yml` | GitHub runs the tests, builds the APK on every push and publishes it as the "latest" release |
| `build.bat` | Building on a PC instead (optional); `install` also puts it on the phone |
| `tools/make_zip_fixtures.py` | Makes the test zips for `src/zip` (into the git-ignored `tests/fixtures/`) |
| `docs/DESIGN.md` | What the app is meant to become, and the findings behind it |
| `docs/VENDORED.md` | Where the copied code came from, and the changes made to it |

The build writes `app/lib/arm64-v8a/liba2itg2.so` and `build/a2itg2.apk`; both are git-ignored.
