"""Verify preserved upstream source against the pinned Git ancestor."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "85868386f1d4c105b8baa666c5a6c273756fa8e5"


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def main() -> int:
    paths = git("ls-tree", "-r", "--name-only", SOURCE_COMMIT).decode().splitlines()
    entries = []
    for old in paths:
        new = "docs/UPSTREAM_README.md" if old == "README.md" else "upstream/" + old
        original = git("show", f"{SOURCE_COMMIT}:{old}")
        if git("diff", "--", new) or git("diff", "--cached", "--", new):
            raise RuntimeError(f"Uncommitted archived-source edit: {new}")
        current = git("show", f"HEAD:{new}")
        if current != original:
            raise RuntimeError(f"Changed archived source: {new}")
        entries.append(
            {
                "source_path": old,
                "destination_path": new,
                "sha256": hashlib.sha256(original).hexdigest(),
            }
        )
    record = {
        "source_repository": "https://github.com/sha1kh-talib/DMA-PROTOCOL",
        "source_commit": SOURCE_COMMIT,
        "joint_project_permission": "User-confirmed; M. Roohan Khan and Talib",
        "licence_text": "Preserved in docs/UPSTREAM_README.md (MIT, DMA RTL Team, 2026)",
        "files": entries,
    }
    record_path = ROOT / "SOURCE_PROVENANCE.json"
    if "--write" in sys.argv:
        record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    elif json.loads(record_path.read_text(encoding="utf-8")) != record:
        raise RuntimeError("Provenance map differs from pinned source")
    print(f"PROVENANCE_PASS files={len(entries)} commit={SOURCE_COMMIT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
