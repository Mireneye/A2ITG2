"""Test zips for src/zip (python: a quick, independent zip writer; only a test helper).

Writes tests/fixtures/pack.zip (classic) and tests/fixtures/pack64.zip (ZIP64 records throughout,
forced by lowering Python's ZIP64 threshold). Both hold the same pack-like tree:
  Test Pack/Song A/song a.sm   (deflate)
  Test Pack/Song A/song a.mp3  (stored, as audio usually is)
  Test Pack/Song A/video.avi   (deflate)
  Test Pack/Song B/b.ssc       (deflate)
File contents follow fixture_bytes(); src/zip/zip_test.odin computes the same bytes to compare.
"""
import os, zipfile

FILES = [  # name, size, method
    ("Test Pack/Song A/song a.sm", 20000, zipfile.ZIP_DEFLATED),
    ("Test Pack/Song A/song a.mp3", 70000, zipfile.ZIP_STORED),
    ("Test Pack/Song A/video.avi", 150000, zipfile.ZIP_DEFLATED),
    ("Test Pack/Song B/b.ssc", 3000, zipfile.ZIP_DEFLATED),
]

def fixture_bytes(size, seed):
    # Text-like and repetitive enough to compress, but not trivially.
    return bytes(((i * 7 + seed * 13) % 251) % 64 + 32 for i in range(size))

def write(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("Test Pack/"), b"")
        for seed, (name, size, method) in enumerate(FILES):
            z.writestr(zipfile.ZipInfo(name), fixture_bytes(size, seed), compress_type=method)

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "tests", "fixtures")
os.makedirs(out, exist_ok=True)
write(os.path.join(out, "pack.zip"))
zipfile.ZIP64_LIMIT = 1000  # every size and offset past 1000 bytes goes into ZIP64 records
write(os.path.join(out, "pack64.zip"))
print("wrote", out)
