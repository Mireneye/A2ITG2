# Map

| Path | What |
|---|---|
| `src/main.odin` | The app: start-up, the loop, status text, touches, what each tap does (PACKS, SONGS, SYNC pages) |
| `src/screen.odin` | Drawing the screen (status, PACKS and SONGS pages) and where the tap targets are |
| `src/text_input.odin` | Typing with Android's keyboard: a dialog with a real text field, through `vendor:android/java` |
| `src/catalog.odin` | The site's pack list (cached a day, 0.8 MB) and the searches: pack names on the phone, songs/artists/authors on the site |
| `src/worker.odin` | The worker thread: downloads and copies run here so the screen keeps answering |
| `src/pack.odin` | A pack on stepmaniaonline.net: reading its table of contents, finding its songs, copying one song (its `.sm` and the files the `.sm` names), fetching a song's audio for a preview (kept in the preview cache) |
| `src/folder.odin` | The stick: Android's folder picker, keeping access across restarts, making folders and files (fsynced), listing a folder, reading and overwriting a file |
| `src/player.odin` | Playing a song on the phone (previews): the app's decoders into a ring, AAudio plays it |
| `src/stick.odin` | The SYNC page's work on songs already on the stick: listing them, reading and changing `#OFFSET`, backups of the original charts, RESET, MEASURE |
| `src/documents.odin` | `android.provider.DocumentsContract` and `android.database.Cursor` called through JNI by hand (Odin's generated bindings skip those packages) |
| `src/text.odin` | Pixel drawing and a 5x7 bitmap font (ZZ-Replace: stand-in UI) |
| `src/web/` | HTTPS GET of a byte range, over `src/tls` |
| `src/zip/` | Reading a zip a few byte ranges at a time, ZIP64 included; `zip_test.odin` tests it |
| `src/audio/` | MP3 to Ogg and shrinking Oggs: `mp3_decode.odin` and `ogg_decode.odin` (StepMania's MP3 and Ogg reading, ported), `convert.odin` (Vorbis encoding to a size limit), `length_patch.odin` (the ITG Ogg length patch), `decoder.odin` (either decoder behind one face), `attacks.odin` and `sync_match.odin` (measuring where the music's beats are against a chart's notes), `libraries.odin` (C bindings); tests check sync to the sample |
| `src/chart/` | A `.sm` chart's timing: `#OFFSET`, `#BPMS`, `#STOPS`, when each note is; `sync_test.odin` tests the sync measurement |
| `src/metronome/` | Clicks on a chart's beats mixed into a playing song (the music dips under each click); tested on PC |
| `src/insets.odin` | How much of the window the phone's status and navigation bars cover |
| `src/tls/` | TLS 1.3/1.2 client, copied from Weaving Mirage (see `docs/VENDORED.md`) |
| `src/inflate/` | Deflate decoder, copied from Folding Mirage (see `docs/VENDORED.md`) |
| `app/AndroidManifest.xml` | The app's package name, its activity (`OdinActivity`), library name (`a2itg2`), internet permission |
| `app/res/` | Resources: the app's name |
| `.github/workflows/build.yml` | GitHub runs the tests, builds the APK on every push and publishes it as the "latest" release |
| `build.bat` | Building on a PC instead (optional); `install` also puts it on the phone |
| `tools/build_audio_libs.sh` | Fetches libmad (StepMania's copy), libogg and libvorbis at pinned commits and builds `libs/<target>/libaudio.a` |
| `tools/make_audio_fixtures.py` | Makes the click-track and dense test MP3s for `src/audio` (needs `lame`) |
| `tests/fixtures/sync/` | Git-ignored: the user's cab-perfect songs (`.sm` + `.ogg`) for the sync tests |
| `tools/make_zip_fixtures.py` | Makes the test zips for `src/zip` (into the git-ignored `tests/fixtures/`) |
| `docs/DESIGN.md` | What the app is meant to become, and the findings behind it |
| `docs/VENDORED.md` | Where the copied code came from, and the changes made to it |

The build writes `app/lib/arm64-v8a/liba2itg2.so`, `build/a2itg2.apk`, `libs/` and `third_party/`; all git-ignored.
