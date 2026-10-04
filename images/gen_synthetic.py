#!/usr/bin/env python3
"""Generate synthetic cold-pull images (random, incompressible layers), push them, write cold.json."""
import argparse
import concurrent.futures
import json
import os
import subprocess
import sys
import tarfile
import tempfile

from describe import describe_manifest, fetch_manifest

# class: (count, layers per image, bytes per layer)
CLASSES = {
    "c10m": (400, 4, 2_500_000),
    "c100m": (40, 4, 25_000_000),
    "s100m": (16, 4, 25_000_000),
    "s1g": (8, 8, 128_000_000),
}
TAG = "cold"


def plan(classes, only=None):
    out = []
    for cls, (count, layers, layer_bytes) in classes.items():
        if only and cls not in only:
            continue
        for i in range(1, count + 1):
            out.append({"class": cls, "repo": f"cold/{cls}-{i:03d}", "layers": layers, "layer_bytes": layer_bytes})
    return out


class _Random:
    def __init__(self, n):
        self.left = n

    def read(self, size=-1):
        size = self.left if size < 0 else min(size, self.left)
        self.left -= size
        return os.urandom(size)


def write_layer(path, nbytes):
    info = tarfile.TarInfo("data")
    info.size, info.mode = nbytes, 0o644
    with tarfile.open(path, "w") as tf:
        tf.addfile(info, _Random(nbytes))


def exists(ref, insecure):
    cmd = ["crane", "digest", ref] + (["--insecure"] if insecure else [])
    return subprocess.run(cmd, capture_output=True).returncode == 0


def build(entry, registry, insecure):
    ref = f"{registry}/{entry['repo']}:{TAG}"
    if not exists(ref, insecure):
        with tempfile.TemporaryDirectory() as d:
            cmd = ["crane", "append", "-t", ref] + (["--insecure"] if insecure else [])
            for n in range(entry["layers"]):
                path = os.path.join(d, f"l{n}.tar")
                write_layer(path, entry["layer_bytes"])
                cmd += ["-f", path]
            subprocess.run(cmd, check=True, capture_output=True)
    return {"class": entry["class"], "repo": entry["repo"], **describe_manifest(fetch_manifest(ref, insecure))}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--only", default="", help="comma-separated classes")
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args(argv)
    entries = plan(CLASSES, set(filter(None, args.only.split(","))) or None)
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        out = list(ex.map(lambda e: build(e, args.registry, args.insecure), entries))
    json.dump({"images": out}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
