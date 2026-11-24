#!/usr/bin/env python3
"""Write musicless.json, the in-app update manifest of the Musicless fork build (same format as
tools/update_manifest.py's newtube.json; the fork's feed is -PforkUpdateUrl, normally
https://github.com/<repo>/releases/latest/download/musicless.json).
Usage: tools/musicless_manifest.py --repo yshalsager/newtube-musicless --tag v1.17.1-musicless.1 \\
           --code 1170101 --dist dist --out dist/musicless.json --note "Removes music" --note-ar "يزيل الموسيقى" ...
The app shows changelog_<its language> when present (changelog_ar), else changelog.
"""
import argparse
import json
import pathlib
import sys

ABIS = ["arm64-v8a", "armeabi-v7a", "x86"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True, help="e.g. v1.17.1-musicless.1")
    ap.add_argument("--code", type=int, required=True, help="the APKs' versionCode")
    ap.add_argument("--dist", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--note", action="append", default=[], help="changelog line (repeatable)")
    ap.add_argument("--note-ar", action="append", default=[], help="Arabic changelog line (repeatable)")
    args = ap.parse_args()

    name = args.tag[1:] if args.tag.startswith("v") else args.tag
    dist = pathlib.Path(args.dist)
    base = f"https://github.com/{args.repo}/releases/download/{args.tag}"
    package = {}
    for abi in ABIS:
        apk = dist / f"NewTube_{name}_{abi}.apk"
        if apk.is_file():
            package[f"downloadUrlList_{abi}"] = [f"{base}/{apk.name}"]
            package[f"downloadSize_{abi}"] = apk.stat().st_size
    universal = dist / f"NewTube_{name}_universal.apk"
    if not universal.is_file():
        sys.exit(f"{universal.name} is missing from {dist}")
    package["downloadUrlList"] = [f"{base}/{universal.name}"]
    package["downloadSize"] = universal.stat().st_size

    entry = {"versionCode": args.code, "changelog": args.note}
    if args.note_ar:
        entry["changelog_ar"] = args.note_ar
    manifest = {"package": package, name: entry}
    pathlib.Path(args.out).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
