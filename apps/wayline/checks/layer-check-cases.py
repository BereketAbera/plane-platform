#!/usr/bin/env python3
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Tests checks/layer-check.py on layers made here, in memory, so no copy of the original file is needed.

    layer-check-cases.py                       each case through the Walk, in this process. Needs nothing but Python
    layer-check-cases.py --registry <host:port>  also pushes each case as a real image and runs the command on it

The second needs an empty registry on loopback that nobody else uses, with plain HTTP. Exits 1 if any case is wrong.
"""
import argparse
import bz2
import gzip
import hashlib
import importlib.util
import io
import json
import lzma
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SPEC = importlib.util.spec_from_file_location("layer_check", os.path.join(HERE, "layer-check.py"))
layer_check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(layer_check)

NEEDLE = layer_check.NEEDLE
TEXT = f"# SPDX-License-Identifier: {NEEDLE}\nprint('hello')\n"
# Stands in for the original in-process, because this repository does not hold it.
STAND_IN = b"def generate_plain_text_from_html(html):\n    return html\n"


def tar_of(files, **options):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", **options) as archive:
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


def zip_of(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return buffer.getvalue()


def zstd_of(data):
    if layer_check.zstd:
        return layer_check.zstd.compress(data)
    binary = shutil.which("zstd")
    if not binary:
        return None
    return subprocess.run([binary, "-q", "-c"], input=data, stdout=subprocess.PIPE, check=True).stdout


def nest(data, times):
    for _ in range(times):
        data = gzip.compress(data)
    return data


def pax_tar():
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        info = tarfile.TarInfo("clean/name.txt")
        info.pax_headers = {"comment": NEEDLE}
        archive.addfile(info, io.BytesIO())
    return buffer.getvalue()


def cases():
    """(name, the layer's uncompressed tar, what is expected: hit, clean or incomplete)."""
    plain = TEXT.encode()
    inner_tar = tar_of({"email.py": plain})
    rows = [
        ("a clean file", {"x/hello.txt": b"nothing here\n"}, "clean"),
        ("the replacement's bytes", {"code/plane/utils/email.py": b"# SPDX-License-Identifier: AGPL-3.0-only\n"}, "clean"),
        ("a pyc at another path", {"usr/local/lib/python3.12/email/__pycache__/message.cpython-312.pyc": b"\xcb\r\r\n"}, "clean"),
        ("a pyc of another name under code/", {"code/plane/utils/__pycache__/html_processor.cpython-312.pyc": b"\xcb\r\r\n"}, "clean"),
        ("the identifier in a plain file", {"x/y.py": plain}, "hit"),
        ("lower case", {"x/y.py": plain.lower()}, "hit"),
        ("upper case", {"x/y.py": plain.upper()}, "hit"),
        ("UTF-16-LE", {"x/y.txt": TEXT.encode("utf-16-le")}, "hit"),
        ("UTF-16-BE", {"x/y.txt": TEXT.encode("utf-16-be")}, "hit"),
        ("UTF-16 with a BOM, lower case", {"x/y.txt": TEXT.lower().encode("utf-16")}, "hit"),
        ("across two reads", {"x/big.bin": b"\0" * (layer_check.CHUNK - 5) + plain}, "hit"),
        ("in UTF-16 across two reads", {"x/big.bin": b"\0" * (layer_check.CHUNK - 9) + TEXT.encode("utf-16-le")}, "hit"),
        ("gz named x.body", {"x.body": gzip.compress(plain)}, "hit"),
        ("gz named .gz", {"x.gz": gzip.compress(plain)}, "hit"),
        ("bz2 with no suffix", {"x": bz2.compress(plain)}, "hit"),
        ("xz named .txt", {"x.txt": lzma.compress(plain)}, "hit"),
        ("tar named .dat", {"x.dat": inner_tar}, "hit"),
        ("zip named .dat", {"x.dat": zip_of({"y.py": plain})}, "hit"),
        ("tar.gz named .png", {"x.png": gzip.compress(inner_tar)}, "hit"),
        ("zipapp after a #! line", {"app": b"#!/usr/bin/env python3\n" + zip_of({"__main__.py": plain})}, "hit"),
        ("nested to the limit", {"x": nest(plain, layer_check.NESTED_DEPTH)}, "hit"),
        ("in an entry's name", {f"x/{NEEDLE}.txt": b"clean\n"}, "hit"),
        ("in a PAX header", pax_tar(), "hit"),
        ("email pyc under code/", {"code/plane/utils/__pycache__/email.cpython-312.pyc": b"\xcb\r\r\n"}, "hit"),
        ("email_x pyc under code/, with ./", {"./code/plane/__pycache__/email_x.cpython-312.pyc": b"\xcb\r\r\n"}, "hit"),
        ("email pyc under code/, in a tar", {"x.dat": tar_of({"code/plane/utils/__pycache__/email.cpython-312.pyc": b"\xcb\r\r\n"})}, "hit"),
        ("nested past the limit", {"x": nest(plain, layer_check.NESTED_DEPTH + 1)}, "incomplete"),
        ("lz4, which this cannot open", {"x": b"\x04\x22\x4d\x18" + b"\0" * 32}, "incomplete"),
        ("gzip magic and nothing after", {"x.gz": b"\x1f\x8b\x08\x00" + b"\0" * 6}, "incomplete"),
    ]
    compressed = zstd_of(inner_tar)
    if compressed is not None:
        rows.append(("x.tar.zst", {"x.tar.zst": compressed}, "hit"))
        rows.append(("zstd named .bin", {"x.bin": zstd_of(plain)}, "hit"))
        rows.append(("zstd cut short", {"x.bin": compressed[: len(compressed) // 2]}, "incomplete"))
    else:
        print("NOTE no zstd reader or binary here, so the zstd cases do not run")
    return [(name, content if isinstance(content, bytes) else tar_of(content), expect) for name, content, expect in rows]


def walk_case(layer):
    walk = layer_check.Walk(NEEDLE.encode())
    walk.layer(io.BytesIO(layer))
    return walk


def outcome(walk):
    return "hit" if walk.hits else "incomplete" if walk.unread else "clean"


def in_process():
    """Prints a line per case and returns how many are wrong."""
    wrong = 0
    for name, layer, expect in cases():
        walk = walk_case(layer)
        got = outcome(walk)
        wrong += got != expect
        detail = "; ".join(walk.hits + walk.unread)
        print(f"{'PASS' if got == expect else 'FAIL'} {name}: {got}, expected {expect}{'. ' + detail if detail else ''}")
    # The sha256 of the original, under another name and inside an archive, with a stand-in for it, because the point of
    # the hash is bytes that hold no identifier.
    original = layer_check.ORIGINAL_SHA256
    layer_check.ORIGINAL_SHA256 = hashlib.sha256(STAND_IN).hexdigest()
    try:
        for name, files in (("the original's sha256 under another name", {"x/renamed.txt": STAND_IN}), ("the original's sha256 in a gz named x.body", {"x.body": gzip.compress(STAND_IN)})):
            walk = walk_case(tar_of(files))
            wrong += outcome(walk) != "hit"
            print(f"{'PASS' if outcome(walk) == 'hit' else 'FAIL'} {name}: {outcome(walk)}, expected hit. {'; '.join(walk.hits)}")
    finally:
        layer_check.ORIGINAL_SHA256 = original
    # With no way to read zstd, the image has not been read, and that must not read as clean.
    compressed = zstd_of(TEXT.encode())
    if compressed is not None:
        reader, path = layer_check.zstd, os.environ.get("PATH", "")
        layer_check.zstd, os.environ["PATH"] = None, ""
        try:
            walk_case(tar_of({"x.bin": compressed}))
            wrong += 1
            print("FAIL zstd with nothing to read it: the walk finished")
        except layer_check.Unreadable as err:
            print(f"PASS zstd with nothing to read it: {err}")
        finally:
            layer_check.zstd, os.environ["PATH"] = reader, path
    return wrong


def push_blob(registry, repository, data):
    digest = f"sha256:{hashlib.sha256(data).hexdigest()}"
    start = urllib.request.Request(f"http://{registry}/v2/{repository}/blobs/uploads/", method="POST")
    with urllib.request.urlopen(start, timeout=60) as reply:
        location = reply.headers["Location"]
    if location.startswith("/"):
        location = f"http://{registry}{location}"
    joined = "&" if "?" in location else "?"
    put = urllib.request.Request(f"{location}{joined}digest={digest}", data=data, method="PUT", headers={"Content-Type": "application/octet-stream"})
    urllib.request.urlopen(put, timeout=60).close()
    return digest, len(data)


def push_image(registry, repository, layer):
    """One layer and a config, by hand, so this leaves nothing in Docker or its build cache."""
    compressed = gzip.compress(layer)
    config = json.dumps({"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": [f"sha256:{hashlib.sha256(layer).hexdigest()}"]}}).encode()
    config_digest, config_size = push_blob(registry, repository, config)
    layer_digest, layer_size = push_blob(registry, repository, compressed)
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": config_size},
            "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": layer_digest, "size": layer_size}],
        }
    ).encode()
    digest = f"sha256:{hashlib.sha256(manifest).hexdigest()}"
    put = urllib.request.Request(f"http://{registry}/v2/{repository}/manifests/{digest}", data=manifest, method="PUT", headers={"Content-Type": "application/vnd.oci.image.manifest.v1+json"})
    urllib.request.urlopen(put, timeout=60).close()
    return f"{registry}/{repository}@{digest}"


def through_registry(registry):
    """The real command on real images: its exit code, and whether it names what it should."""
    wrong = 0
    expected_exit = {"clean": 0, "hit": 1, "incomplete": 2}
    for index, (name, layer, expect) in enumerate(cases()):
        reference = push_image(registry, f"layer-check-cases/{index}", layer)
        done = subprocess.run([sys.executable, "-B", os.path.join(HERE, "layer-check.py"), reference], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        marks = [line.strip() for line in done.stdout.splitlines() if line.startswith("  ")]
        good = done.returncode == expected_exit[expect]
        wrong += not good
        print(f"{'PASS' if good else 'FAIL'} {name}: exit {done.returncode}, expected {expected_exit[expect]} {reference}")
        for mark in marks:
            print(f"     {mark}")
    return wrong


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", help="host:port of an empty registry on loopback, with plain HTTP")
    args = parser.parse_args()
    print(f"python {sys.version.split()[0]}, zstd read by {'compression.zstd' if layer_check.zstd else 'the zstd binary, if there is one'}")
    print("\n== Each case through the Walk, in this process")
    wrong = in_process()
    if args.registry:
        print(f"\n== Each case as a real image in {args.registry}, through the command")
        wrong += through_registry(args.registry)
    print(f"\nlayer-check-cases: {wrong} wrong")
    sys.exit(1 if wrong else 0)


if __name__ == "__main__":
    main()
