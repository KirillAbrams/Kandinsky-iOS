#!/usr/bin/env python3
from pathlib import Path
from collections import Counter
import hashlib, json, sys

root = Path(__file__).resolve().parents[1] / "fixtures"
assert (root / "manifest.json").is_file(), "Native offline corpus is missing"
m = json.loads((root / "manifest.json").read_text())
seed = (root / "seed-v1.json").read_bytes()
assert hashlib.sha256(seed).hexdigest() == m["seedSha256"]
s = json.loads(seed)
heavy = [r for r in s["messages"] if r["chatID"] == 4]
expected = {"text": 6500, "photo": 2000, "voice": 700, "video": 400, "round": 200, "gif": 200}
assert Counter(r["kind"] for r in heavy) == expected
assert len({r["id"] for r in s["messages"]}) == len(s["messages"])
assert len({r["kind"] for r in heavy[:1000]}) == 6
files = {f["id"]: f for f in m["files"]}
assert {p.name for p in (root / "media").iterdir()} == {f["fileName"] for f in m["files"]}, (
    "Unexpected files in corpus"
)
assert len(files) == 329
for f in files.values():
    p = root / "media" / f["fileName"]
    data = p.read_bytes()
    assert len(data) == f["byteSize"] and hashlib.sha256(data).hexdigest() == f["sha256"]
    if f["mime"] == "image/jpeg":
        assert data[:2] == b"\xff\xd8"
    elif f["mime"] == "image/png":
        assert data.startswith(b"\x89PNG\r\n\x1a\n")
    elif f["mime"] == "image/gif":
        assert (
            data.startswith((b"GIF89a", b"GIF87a"))
            and f["frameCount"] == 8
            and [f["width"], f["height"]] == [128, 128]
        )
    elif f["mime"] in ["video/mp4", "audio/mp4"]:
        assert data[4:8] == b"ftyp"
    else:
        raise AssertionError(f["mime"])
for r in s["messages"]:
    assert all(i in files for i in r["attachmentFileIDs"])
photos = [f for f in files.values() if f["mime"] == "image/jpeg"]
assert len(photos) == 256 and len({f["sha256"] for f in photos}) == 256
decoded = sum(f["width"] * f["height"] * 4 for f in photos)
assert decoded > 48 * 1024 * 1024
assert sum(f["mime"] == "video/mp4" for f in files.values()) == 32
assert sum(f["mime"] == "audio/mp4" for f in files.values()) == 32
assert sum(f["mime"] == "image/gif" for f in files.values()) == 8
print(
    json.dumps(
        {
            "heavy_messages": len(heavy),
            "counts": dict(Counter(r["kind"] for r in heavy)),
            "files": len(files),
            "unique_photo_decoded_bytes": decoded,
            "seed_sha256": m["seedSha256"],
        },
        indent=2,
    )
)

for name, sha in m.get("oracleFiles", {}).items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == sha
