import tarfile

import gen_synthetic as g


def test_plan_counts_and_names():
    p = g.plan(g.CLASSES)
    assert len(p) == 400 + 40 + 16 + 8
    assert p[0] == {"class": "c10m", "repo": "cold/c10m-001", "layers": 4, "layer_bytes": 2_500_000}
    assert p[-1] == {"class": "s1g", "repo": "cold/s1g-008", "layers": 8, "layer_bytes": 128_000_000}


def test_plan_only_filters_classes():
    p = g.plan(g.CLASSES, only={"s100m"})
    assert [e["repo"] for e in p][:2] == ["cold/s100m-001", "cold/s100m-002"] and len(p) == 16


def test_write_layer_random_payload(tmp_path):
    path = tmp_path / "l.tar"
    g.write_layer(path, 300_000)
    with tarfile.open(path) as tf:
        member = tf.getmember("data")
        data = tf.extractfile(member).read()
    assert member.size == 300_000 and len(data) == 300_000
    assert len(set(data[:4096])) > 200      # random, not zero-filled


def test_write_layer_differs_between_calls(tmp_path):
    a, b = tmp_path / "a.tar", tmp_path / "b.tar"
    g.write_layer(a, 10_000)
    g.write_layer(b, 10_000)
    assert a.read_bytes() != b.read_bytes()
