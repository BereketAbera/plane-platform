#!/usr/bin/env python3
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Walks every layer blob of an image as a registry serves it, and fails if any of them holds a byte string.

A merged filesystem cannot answer this. A file replaced by a later layer is gone from a container, from `docker
export` and from an image scan, and still handed to everyone who pulls the image. So this reads what was pushed and
every tar entry in every layer, in order, including files a later layer hides.

    layer-check.py                                 the images we build, from .build/digests.tsv. This is the gate
    layer-check.py <image>...                      the same gate on these images, which must name a digest
    layer-check.py --report-only <image>...        information about images we do not publish: a hit does not fail
    layer-check.py --digests <file>                the gate on another digests file

scripts/ci/build-images.sh runs it on each image right after pushing it, before it records any digest. An image we
deploy unmodified can only be changed upstream, so it is reported with --report-only and never gates a build.

The needle defaults to the SPDX identifier on upstream's commercially licensed files, written in two pieces so that
a copy of this file in an image could not match itself. It is searched for in file contents, in entry names, link
targets and PAX headers, in the image's config, and inside compressed or archived files (.gz, .tgz, .bz2, .xz, .zip,
.whl, .egg, .jar, .tar), because a layer can hold those too.

Exits 0 if clean, 1 if a gated image holds the needle, and 2 if an image could not be read completely, because a
result that is missing must not read as a clean one. --report-only exits 0 or 2.
"""
import argparse
import bz2
import gzip
import io
import lzma
import os
import sys
import tarfile
import zipfile

# A __pycache__ beside this file would make the source read as changed, and scripts/ci/build-images.sh would refuse it.
sys.dont_write_bytecode = True

from oci_read import CHUNK, Image, Unreadable

NEEDLE = "LicenseRef-Plane-" + "Commercial"
# A nested archive is read into memory, so one above this is searched as plain bytes and reported as not opened.
NESTED_LIMIT = 512 * 1024 * 1024
NESTED_DEPTH = 3
NESTED_SUFFIXES = (".gz", ".tgz", ".bz2", ".xz", ".zip", ".whl", ".jar", ".tar", ".egg", ".pex")
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def contains(stream, needle):
    """Searches a stream, keeping an overlap so a match across two reads is still found."""
    tail = b""
    while True:
        chunk = stream.read(CHUNK)
        if not chunk:
            return False
        if needle in tail + chunk:
            return True
        tail = chunk[-(len(needle) - 1) :]


class Walk:
    def __init__(self, needle):
        self.needle = needle
        self.hits = []
        self.unread = []
        self.entries = 0
        self.nested_read = 0

    def nested_bytes(self, label, data, depth):
        """Looks inside something that may be an archive. Its plain bytes have already been searched."""
        if depth > NESTED_DEPTH:
            self.unread.append(f"{label}: nested deeper than {NESTED_DEPTH}")
            return
        try:
            if data[:2] == b"\x1f\x8b":
                self.decompressed(label, "gzip", gzip.decompress(data), depth)
            elif data[:3] == b"BZh":
                self.decompressed(label, "bzip2", bz2.decompress(data), depth)
            elif data[:6] == b"\xfd7zXZ\x00":
                self.decompressed(label, "xz", lzma.decompress(data), depth)
            elif data[:4] == b"PK\x03\x04":
                self.nested_read += 1
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    for info in archive.infolist():
                        if info.is_dir():
                            continue
                        inner = archive.read(info)
                        if self.needle in inner:
                            self.hits.append(f"{label}!{info.filename}: inside zip")
                        if info.filename.endswith(NESTED_SUFFIXES):
                            self.nested_bytes(f"{label}!{info.filename}", inner, depth + 1)
            elif len(data) > 262 and data[257:262] == b"ustar":
                self.nested_read += 1
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
                    for member in archive:
                        if not member.isfile():
                            continue
                        inner = archive.extractfile(member).read()
                        if self.needle in inner:
                            self.hits.append(f"{label}!{member.name}: inside tar")
                        if member.name.endswith(NESTED_SUFFIXES):
                            self.nested_bytes(f"{label}!{member.name}", inner, depth + 1)
        except (OSError, EOFError, zipfile.BadZipFile, tarfile.TarError, lzma.LZMAError, RuntimeError, NotImplementedError) as err:
            # A file named .gz that is not one, or an encrypted member. Its plain bytes were still searched.
            self.unread.append(f"{label}: could not open it as an archive: {err}")

    def decompressed(self, label, kind, inner, depth):
        self.nested_read += 1
        if self.needle in inner:
            self.hits.append(f"{label}: inside {kind}")
        self.nested_bytes(f"{label}!{kind}", inner, depth + 1)

    def layer(self, fileobj):
        with tarfile.open(fileobj=fileobj, mode="r|") as archive:
            for member in archive:
                self.entries += 1
                # A tar entry's own metadata, which no content search sees.
                metadata = " ".join([member.name, member.linkname, *map(str, member.pax_headers.values())])
                if self.needle.decode() in metadata:
                    self.hits.append(f"{member.name}: in its entry metadata")
                if not member.isfile():
                    continue
                source = archive.extractfile(member)
                if member.name.endswith(NESTED_SUFFIXES):
                    if member.size > NESTED_LIMIT:
                        self.unread.append(f"{member.name}: {member.size} bytes, above the limit for opening an archive")
                        if contains(source, self.needle):
                            self.hits.append(member.name)
                        continue
                    data = source.read()
                    if self.needle in data:
                        self.hits.append(member.name)
                    self.nested_bytes(member.name, data, 1)
                elif contains(source, self.needle):
                    self.hits.append(member.name)


def check_image(reference, platform, needle):
    """Prints a line per layer and returns the number of hits."""
    image = Image(reference, platform)
    print(f"\n== {reference}\nread from {image.source}", flush=True)
    if image.platform_manifest:
        print(f"index, {platform} manifest {image.platform_manifest}", flush=True)
    found = 0
    if needle in image.config_bytes:
        found += 1
        print(f"  HIT config {image.config_digest}", flush=True)
    else:
        print(f"config {image.config_digest}: clean", flush=True)
    total = len(image.layers)
    print(f"{total} layers", flush=True)
    for index in range(total):
        walk = Walk(needle)
        try:
            size = image.read_layer(index, walk.layer)
        except tarfile.TarError as err:
            raise Unreadable(f"layer {index + 1}: {err}") from err
        state = f"{len(walk.hits)} HIT(S)" if walk.hits else "clean"
        print(f"layer {index + 1:>2}/{total} {image.layers[index]['digest'][:19]} {size / 1048576:8.1f} MiB {walk.entries:>6} entries, {walk.nested_read} archives opened: {state}", flush=True)
        for hit in walk.hits:
            print(f"  HIT layer {index + 1} of {total}: {hit}", flush=True)
        for item in walk.unread:
            print(f"  note layer {index + 1}: {item}", flush=True)
        found += len(walk.hits)
    return found


def built_images(path):
    images = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 3:
                images.append(f"{fields[1]}@{fields[2]}")
    if not images:
        raise SystemExit(f"layer-check: no images in {path}")
    return images


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("images", nargs="*")
    parser.add_argument("--digests", default=os.path.join(ROOT, ".build", "digests.tsv"))
    parser.add_argument("--platform", default="linux/arm64")
    parser.add_argument("--needle", default=NEEDLE)
    parser.add_argument("--report-only", action="store_true", help="a hit is reported and does not fail: for images we do not publish")
    args = parser.parse_args()
    needle = args.needle.encode()
    images = args.images or built_images(args.digests)

    print(f"searching {len(images)} image(s) for {len(needle)} bytes on {args.platform}: {needle.decode()}", flush=True)
    print("report only: a hit is information, and does not fail" if args.report_only else "gate: a hit fails", flush=True)
    summary = []
    for reference in images:
        try:
            found = check_image(reference, args.platform, needle)
            summary.append((reference, "HIT" if found else "clean", found))
        except (Unreadable, OSError) as err:
            print(f"COULD NOT READ {reference}: {err}", flush=True)
            summary.append((reference, "UNREADABLE", 0))
    print("\n== Summary")
    for reference, state, found in summary:
        print(f"{state:<10} {found:>3} hit(s) {reference}")
    if any(state == "UNREADABLE" for _, state, _ in summary):
        sys.exit(2)
    if not args.report_only and any(state == "HIT" for _, state, _ in summary):
        sys.exit(1)


if __name__ == "__main__":
    main()
