#!/usr/bin/env python3
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Walks every layer blob of an image as a registry serves it, and fails if any of them holds upstream's commercially
licensed file, or a sign of it.

A merged filesystem cannot answer this. A file replaced by a later layer is gone from a container, from `docker
export` and from an image scan, and still handed to everyone who pulls the image. So this reads what a registry serves
and every tar entry in every layer, in order, including files a later layer hides.

    layer-check.py                                 the images we build, from .build/digests.tsv. This is the gate
    layer-check.py <image>...                      the same gate on these images, which must name a digest
    layer-check.py --report-only <image>...        information about images we do not publish: a hit does not fail
    layer-check.py --digests <file>                the gate on another digests file

Each image is read for --platform, or else PLATFORM, or else linux/arm64. An index gives its child for that platform, and
any image whose config says another platform cannot be read, which is exit 2. So production's child is the one walked.

scripts/ci/build-images.sh runs it on each image in a throwaway registry before publishing anything, then again on what
it published, before it records any digest. An image we deploy unmodified can only be changed upstream, so it is
reported with --report-only and never gates a build. checks/layer-check-cases.py tests this file.

A hit is any of these, in a file at any depth:
- The needle, by default the SPDX identifier on upstream's commercially licensed files, written in two pieces so that a
  copy of this file in an image could not match itself. In any case of its letters, and in UTF-16 either way round. It is
  also searched for in entry names, link targets and PAX headers, and in the image's config.
- The sha256 of the original file, ORIGINAL_SHA256 below, under any name.
- An entry at code/**/__pycache__/email*.pyc. Compiling drops comments, so the original's bytecode holds no identifier and
  has its own hash. The backend image has no .pyc under /code at all, so the name alone is enough.

What gets opened is decided by a file's first bytes, never its name: gzip, bzip2, xz, zstd, zip (also after a #! line, as
a zipapp or a .pex has) and tar with a ustar header, nested up to NESTED_DEPTH deep. Python 3.14 reads zstd itself. Older
versions use the zstd binary, and with neither an image holding zstd cannot be read, so the result is exit 2.

Limits, each searched as plain bytes only. A tar with no ustar header (V7, from before 1988) and a raw .lzma have no magic
to detect, and any other format is not looked for. lz4, 7z and rar are recognised, cannot be opened, and leave the image
incomplete. So do an archive that will not open, one above NESTED_LIMIT, and one deeper than NESTED_DEPTH. An incomplete
image names each one and exits 2, as below. Other encodings (base64, UTF-32, a header split across lines) are not looked for.

Exits 0 if clean, 1 if a gated image holds any of these, and 2 if an image could not be read completely, because a
result that is missing must not read as a clean one. --report-only exits 0 or 2, and 2 only if an image could not be read
at all: what it could not open is listed and does not fail.
"""
import argparse
import bz2
import gzip
import hashlib
import io
import lzma
import os
import re
import sys
import tarfile
import zipfile
import zlib

# A __pycache__ beside this file would make the source read as changed, and scripts/ci/build-images.sh would refuse it.
sys.dont_write_bytecode = True

from oci_read import CHUNK, Image, Unreadable, ZstdStream, default_platform

try:
    from compression import zstd  # Python 3.14
except ImportError:
    zstd = None

NEEDLE = "LicenseRef-Plane-" + "Commercial"
# The v1.4.3 apps/api/plane/utils/email.py, as docs/evidence/branding/email-py.txt read it from upstream's image.
ORIGINAL_SHA256 = "5ad017bf6559780a25b0c2a5871e45c5c77673a912b149391db1314202765ccc"
ORIGINAL_BYTECODE = re.compile(r"code/(?:.*/)?__pycache__/email[^/]*\.pyc")
# An archive is read into memory, so one above this is searched as plain bytes and reported as not opened.
NESTED_LIMIT = 512 * 1024 * 1024
NESTED_DEPTH = 3
# Enough for tar's magic, which is at offset 257.
HEAD = 512
OPENS = (
    ("gzip", re.compile(rb"\x1f\x8b\x08[\x00-\x1f]")),  # the flags byte too: two bytes alone turn up in random data
    ("bzip2", re.compile(rb"BZh[1-9](?:1AY&SY|\x17rE8P\x90)")),
    ("xz", re.compile(rb"\xfd7zXZ\x00")),
    ("zstd", re.compile(rb"\x28\xb5\x2f\xfd")),
    ("zip", re.compile(rb"PK\x03\x04|PK\x05\x06")),
    ("tar", re.compile(rb"(?s:.{257})ustar")),
)
CANNOT_OPEN = (
    ("lz4", re.compile(rb"\x04\x22\x4d\x18")),
    ("7z", re.compile(rb"7z\xbc\xaf\x27\x1c")),
    ("rar", re.compile(rb"Rar!\x1a\x07")),
)
# What reading a bad archive raises. Unreadable is not here: with no way to read zstd, the image was not read.
BAD_ARCHIVE = (OSError, EOFError, ValueError, RuntimeError, NotImplementedError, zlib.error, lzma.LZMAError, zipfile.BadZipFile, tarfile.TarError) + ((zstd.ZstdError,) if zstd else ())


def first_match(table, head):
    return next((kind for kind, magic in table if magic.match(head)), None)


def spellings(needle):
    """Searched for in lower-cased bytes, which covers every case, and lower-casing bytes leaves UTF-16's zeros alone."""
    text = needle.lower().decode()
    return (
        ("the identifier", text.encode()),
        ("the identifier in UTF-16", text.encode("utf-16-le")),
        ("the identifier in UTF-16", text.encode("utf-16-be")),
    )


class Search:
    """One file's bytes, as they pass: what it holds and its hash, keeping an overlap so a match across two reads is found."""

    def __init__(self, needle):
        self.spellings = spellings(needle)
        self.keep = max(len(spelled) for _, spelled in self.spellings) - 1
        self.tail = b""
        self.sha = hashlib.sha256()
        self.found = []

    def feed(self, data):
        self.sha.update(data)
        window = self.tail + data.lower()
        for label, spelled in self.spellings:
            if label not in self.found and spelled in window:
                self.found.append(label)
        self.tail = window[-self.keep :]

    def reasons(self):
        return [*self.found, *(["the sha256 of the original"] if self.sha.hexdigest() == ORIGINAL_SHA256 else [])]


def decompressing(kind, data):
    """A readable stream of what is inside, bounded by whoever reads it, so a small bomb cannot fill the memory."""
    source = io.BytesIO(data)
    if kind == "gzip":
        return gzip.GzipFile(fileobj=source)
    if kind == "bzip2":
        return bz2.BZ2File(source)
    if kind == "xz":
        return lzma.LZMAFile(source)
    if zstd:
        return zstd.ZstdFile(source)
    return io.BufferedReader(ZstdStream(source), CHUNK)


class Walk:
    def __init__(self, needle):
        self.needle = needle
        self.hits = []
        self.unread = []
        self.entries = 0
        self.nested_read = 0

    def record(self, label, reasons):
        if reasons:
            self.hits.append(f"{label}: {', '.join(reasons)}")

    def entry(self, label, *names, extras=()):
        """A tar or zip entry's own metadata, which no content search sees."""
        search = Search(self.needle)
        search.feed(" ".join([*names, *extras]).encode("utf-8", "surrogateescape"))
        reasons = list(search.found)
        if ORIGINAL_BYTECODE.fullmatch(re.sub(r"^(?:\./|/)+", "", names[0])):
            reasons.append("bytecode at the original's path")
        self.record(label, reasons)

    def file(self, label, source, depth):
        """One file's contents, at any depth, whatever its name. Everything in it passes through one Search."""
        search = Search(self.needle)
        head = source.read(HEAD)
        kind = first_match(OPENS, head)
        may_be_zipapp = kind is None and head[:2] == b"#!"
        cannot_open = first_match(CANNOT_OPEN, head)
        if cannot_open:
            self.unread.append(f"{label}: {cannot_open}, which this cannot open")
        body = head
        if kind or may_be_zipapp:
            body += source.read(NESTED_LIMIT + 1 - len(head))
        search.feed(body)
        too_big = len(body) > NESTED_LIMIT
        for chunk in iter(lambda: source.read(CHUNK), b""):
            search.feed(chunk)
        self.record(label, search.reasons())
        if too_big:
            self.unread.append(f"{label}: {kind or 'a script'}, above the limit for opening an archive")
        elif may_be_zipapp and zipfile.is_zipfile(io.BytesIO(body)):
            self.nested(label, "zip", body, depth)
        elif kind:
            self.nested(label, kind, body, depth)

    def nested(self, label, kind, data, depth):
        """Looks inside an archive. Its plain bytes have already been searched."""
        if depth >= NESTED_DEPTH:
            self.unread.append(f"{label}: nested deeper than {NESTED_DEPTH}")
            return
        try:
            self.nested_read += 1
            if kind == "zip":
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    for info in archive.infolist():
                        self.entry(f"{label}!{info.filename}", info.filename)
                        if not info.is_dir():
                            with archive.open(info) as inner:
                                self.file(f"{label}!{info.filename}", inner, depth + 1)
            elif kind == "tar":
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
                    for member in archive:
                        self.entry(f"{label}!{member.name}", member.name, member.linkname, extras=map(str, member.pax_headers.values()))
                        if member.isfile():
                            self.file(f"{label}!{member.name}", archive.extractfile(member), depth + 1)
            else:
                self.file(f"{label}!{kind}", decompressing(kind, data), depth + 1)
        except BAD_ARCHIVE as err:
            # A file that only looks like one, or an encrypted member. Its plain bytes were still searched.
            self.unread.append(f"{label}: could not open it as {kind}: {err}")

    def layer(self, fileobj):
        with tarfile.open(fileobj=fileobj, mode="r|") as archive:
            for member in archive:
                self.entries += 1
                self.entry(member.name, member.name, member.linkname, extras=map(str, member.pax_headers.values()))
                if member.isfile():
                    self.file(member.name, archive.extractfile(member), 0)


def check_image(reference, platform, needle):
    """Prints a line per layer and returns the number of hits, and the number of things it could not open."""
    image = Image(reference, platform)
    print(f"\n== {reference}\nread from {image.source}", flush=True)
    if image.platform_manifest:
        print(f"index, {platform} manifest {image.platform_manifest}", flush=True)
    else:
        print(f"plain manifest, {platform}", flush=True)
    found = 0
    incomplete = 0
    config = Search(needle)
    config.feed(image.config_bytes)
    if config.found:
        found += 1
        print(f"  HIT config {image.config_digest}: {', '.join(config.found)}", flush=True)
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
            print(f"  NOT OPENED layer {index + 1} of {total}: {item}", flush=True)
        found += len(walk.hits)
        incomplete += len(walk.unread)
    return found, incomplete


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
    parser.add_argument("--digests", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".build", "digests.tsv"))
    parser.add_argument("--platform", default=default_platform(), help="default: PLATFORM, or else linux/arm64")
    parser.add_argument("--needle", default=NEEDLE)
    parser.add_argument("--report-only", action="store_true", help="a hit is reported and does not fail: for images we do not publish")
    args = parser.parse_args()
    needle = args.needle.encode()
    images = args.images or built_images(args.digests)

    print(f"searching {len(images)} image(s) on {args.platform} for {len(needle)} bytes in any case, also as UTF-16: {needle.decode()}", flush=True)
    print(f"and for sha256 {ORIGINAL_SHA256} and entries at code/**/__pycache__/email*.pyc", flush=True)
    print("report only: a hit is information, and does not fail" if args.report_only else "gate: a hit fails", flush=True)
    summary = []
    for reference in images:
        try:
            found, incomplete = check_image(reference, args.platform, needle)
            state = "HIT" if found else "INCOMPLETE" if incomplete else "clean"
            summary.append((reference, state, found, incomplete))
        except (Unreadable, OSError) as err:
            print(f"COULD NOT READ {reference}: {err}", flush=True)
            summary.append((reference, "UNREADABLE", 0, 0))
    print("\n== Summary")
    for reference, state, found, incomplete in summary:
        print(f"{state:<10} {found:>3} hit(s) {incomplete:>3} not opened {reference}")
    if any(state == "UNREADABLE" for _, state, _, _ in summary):
        sys.exit(2)
    if args.report_only:
        return
    if any(state == "HIT" for _, state, _, _ in summary):
        sys.exit(1)
    if any(state == "INCOMPLETE" for _, state, _, _ in summary):
        sys.exit(2)


if __name__ == "__main__":
    main()
