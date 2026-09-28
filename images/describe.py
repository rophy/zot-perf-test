#!/usr/bin/env python3
"""Build images.json from images.txt by reading manifests from a registry via crane."""
import argparse
import hashlib
import json
import subprocess
import sys

CLASSES = ("10MB", "100MB", "1GB")


def parse_images_txt(text):
    entries = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f"line {lineno}: expected 3 fields, got {len(fields)}")
        cls, src, repo = fields
        if cls not in CLASSES:
            raise ValueError(f"line {lineno}: unknown class {cls!r}")
        entries.append({"class": cls, "src": src, "repo": repo})
    return entries


def describe_manifest(raw):
    manifest = json.loads(raw)
    if "manifests" in manifest:
        raise ValueError("got an image index; expected a single-platform manifest")
    layers = manifest["layers"]
    size = manifest["config"]["size"] + sum(layer["size"] for layer in layers)
    return {"digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "size": size, "layers": len(layers)}


def fetch_manifest(ref, insecure):
    cmd = ["crane", "manifest", ref]
    if insecure:
        cmd.insert(1, "--insecure")
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--tag", default="bench")
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("images_txt")
    args = ap.parse_args(argv)

    with open(args.images_txt) as f:
        entries = parse_images_txt(f.read())
    out = []
    for e in entries:
        raw = fetch_manifest(f"{args.registry}/{e['repo']}:{args.tag}", args.insecure)
        out.append({"class": e["class"], "repo": e["repo"], **describe_manifest(raw)})
    json.dump({"images": out}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
