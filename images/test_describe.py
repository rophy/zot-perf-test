import hashlib
import json

import pytest

from describe import describe_manifest, parse_images_txt


def test_parse_images_txt_skips_comments_and_blanks():
    text = "# c s r\n\n10MB  docker.io/library/registry:2  bench/registry\n1GB a/b:c bench/b\n"
    assert parse_images_txt(text) == [
        {"class": "10MB", "src": "docker.io/library/registry:2", "repo": "bench/registry"},
        {"class": "1GB", "src": "a/b:c", "repo": "bench/b"},
    ]


def test_parse_images_txt_rejects_bad_class():
    with pytest.raises(ValueError, match="class"):
        parse_images_txt("5MB a/b:c bench/b\n")


def test_parse_images_txt_rejects_wrong_field_count():
    with pytest.raises(ValueError, match="3 fields"):
        parse_images_txt("10MB a/b:c\n")


def test_describe_manifest():
    manifest = {
        "schemaVersion": 2,
        "config": {"digest": "sha256:c", "size": 100},
        "layers": [{"digest": "sha256:l1", "size": 1000}, {"digest": "sha256:l2", "size": 2000}],
    }
    raw = json.dumps(manifest).encode()
    got = describe_manifest(raw)
    assert got == {"digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "size": 3100, "layers": 2}


def test_describe_manifest_rejects_index():
    raw = json.dumps({"schemaVersion": 2, "manifests": []}).encode()
    with pytest.raises(ValueError, match="index"):
        describe_manifest(raw)
