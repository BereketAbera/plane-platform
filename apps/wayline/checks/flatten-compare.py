#!/usr/bin/env python3
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Compares the filesystem and config of two images, read layer by layer from their registries. Whiteouts, opaque
directories and hard links are applied as a container runtime applies them, so this compares what a container sees,
however many layers each image has.

For every path: type, mode including setuid, setgid and sticky, uid, gid, size, link target, device numbers, xattrs,
sha256 and modification time. Python decides whether a .pyc is stale from its source's time and size, so a moved time
is a real difference. Also hard links, reported as groups of paths that share one inode. Empty directories are paths
like any other, and are counted in the totals.

    flatten-compare.py [--platform <os/architecture>] [--list file] <image a> <image b>

Each image must name a digest, and is read for --platform, or else PLATFORM, or else linux/arm64. --list writes the whole of
image b's merged filesystem as a TSV. Exits 0 if the two match on all of that and on their config, 1 if not, listing every
difference, and 2 if an image cannot be read, which includes an image of another platform.
"""
import argparse
import hashlib
import json
import posixpath
import stat
import sys
import tarfile

# A __pycache__ beside this file would make the source read as changed, and scripts/ci/build-images.sh would refuse it.
sys.dont_write_bytecode = True

from oci_read import CHUNK, EMPTY_LAYER, Image, Unreadable, default_platform

ATTRIBUTES = ("type", "mode", "uid", "gid", "size", "target", "device", "xattrs", "sha256", "mtime")
CONFIG_KEYS = ("Env", "Cmd", "Entrypoint", "WorkingDir", "User", "ExposedPorts", "Labels", "Volumes", "StopSignal", "Healthcheck", "Shell", "OnBuild", "ArgsEscaped")


def entry_type(member):
    if member.isdir():
        return "dir"
    if member.issym():
        return "symlink"
    if member.ischr():
        return "char"
    if member.isblk():
        return "block"
    if member.isfifo():
        return "fifo"
    if member.isfile() or member.islnk():
        return "file"
    return f"unknown:{member.type!r}"


def normal(name):
    name = posixpath.normpath(name)
    return name[2:] if name.startswith("./") else name


class Merged:
    """The filesystem a stack of layers adds up to."""

    def __init__(self):
        self.paths = {}
        self.next_group = 0

    def remove_under(self, path, include_self):
        prefix = path + "/"
        for key in [k for k in self.paths if k.startswith(prefix) or (include_self and k == path)]:
            del self.paths[key]

    def read_layer(self, stream):
        entries, whiteouts, opaques, links = {}, [], [], []
        with tarfile.open(fileobj=stream, mode="r|") as archive:
            for member in archive:
                path = normal(member.name)
                if path == ".":
                    continue
                parent, base = posixpath.split(path)
                if base == ".wh..wh..opq":
                    opaques.append(parent)
                    continue
                if base.startswith(".wh."):
                    whiteouts.append(posixpath.join(parent, base[4:]))
                    continue
                record = {
                    "type": entry_type(member),
                    "mode": stat.S_IMODE(member.mode),
                    "uid": member.uid,
                    "gid": member.gid,
                    "size": 0,
                    "target": "",
                    "device": "",
                    "xattrs": ";".join(sorted(f"{k[13:]}={v}" for k, v in member.pax_headers.items() if k.startswith("SCHILY.xattr."))),
                    "sha256": "",
                    "mtime": int(member.mtime),
                    "group": None,
                }
                if member.issym():
                    record["target"] = member.linkname
                elif member.ischr() or member.isblk():
                    record["device"] = f"{member.devmajor}:{member.devminor}"
                elif member.isfile():
                    record["size"] = member.size
                    digest = hashlib.sha256()
                    source = archive.extractfile(member)
                    for chunk in iter(lambda: source.read(CHUNK), b""):
                        digest.update(chunk)
                    record["sha256"] = digest.hexdigest()
                elif member.islnk():
                    links.append((path, normal(member.linkname), record))
                    continue
                entries[path] = record
        for parent in opaques:
            self.remove_under(parent, include_self=False)
        for path in whiteouts:
            self.remove_under(path, include_self=True)
        # A hard link names a path in this layer, or one already below it.
        for path, target, _ in links:
            origin = entries.get(target) or self.paths.get(target)
            if origin is None:
                raise Unreadable(f"{path} is a hard link to {target}, which does not exist")
            if origin["group"] is None:
                origin["group"] = self.next_group
                self.next_group += 1
            entries[path] = dict(origin)
        for path, record in entries.items():
            lower = self.paths.get(path)
            if lower is not None and lower["type"] == "dir" and record["type"] != "dir":
                self.remove_under(path, include_self=False)
            self.paths[path] = record

    def hard_link_groups(self):
        groups = {}
        for path, record in self.paths.items():
            if record["group"] is not None:
                groups.setdefault(record["group"], []).append(path)
        return {tuple(sorted(paths)) for paths in groups.values() if len(paths) > 1}


def read_image(reference, platform):
    image = Image(reference, platform)
    print(f"\n== {reference}\nread from {image.source}", flush=True)
    empty = sum(1 for layer in image.layers if layer["digest"] == EMPTY_LAYER)
    print(f"{len(image.layers)} layers, {empty} of them empty, {sum(layer['size'] for layer in image.layers) / 1048576:.1f} MiB compressed", flush=True)
    merged = Merged()
    for index in range(len(image.layers)):
        try:
            image.read_layer(index, merged.read_layer)
        except tarfile.TarError as err:
            raise Unreadable(f"layer {index + 1}: {err}") from err
    return image, merged


def totals(merged):
    paths = merged.paths
    children = {posixpath.dirname(p) for p in paths}
    counts = {}
    for record in paths.values():
        counts[record["type"]] = counts.get(record["type"], 0) + 1
    print(f"paths {len(paths)}: {json.dumps(counts, sort_keys=True)}")
    print(f"bytes in regular files {sum(r['size'] for r in paths.values())}")
    print(f"empty directories {sum(1 for p, r in paths.items() if r['type'] == 'dir' and p not in children)}")
    print(f"setuid or setgid or sticky {sum(1 for r in paths.values() if r['mode'] & 0o7000)}: {sorted(p for p, r in paths.items() if r['mode'] & 0o7000)}")
    print(f"hard link groups {len(merged.hard_link_groups())}, holding {sum(len(g) for g in merged.hard_link_groups())} paths")
    print(f"with xattrs {sum(1 for r in paths.values() if r['xattrs'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image_a")
    parser.add_argument("image_b")
    parser.add_argument("--platform", default=default_platform(), help="default: PLATFORM, or else linux/arm64")
    parser.add_argument("--list", help="write image b's merged filesystem to this file, as TSV")
    args = parser.parse_args()

    try:
        image_a, merged_a = read_image(args.image_a, args.platform)
        print(f"-- totals of a, {args.image_a}")
        totals(merged_a)
        image_b, merged_b = read_image(args.image_b, args.platform)
        print(f"-- totals of b, {args.image_b}")
        totals(merged_b)
    except (Unreadable, OSError) as err:
        print(f"COULD NOT READ: {err}")
        sys.exit(2)

    if args.list:
        with open(args.list, "w", encoding="utf-8") as out:
            out.write("path\t" + "\t".join(ATTRIBUTES) + "\n")
            for path in sorted(merged_b.paths):
                record = merged_b.paths[path]
                out.write(path + "\t" + "\t".join(str(record[a]) for a in ATTRIBUTES) + "\n")

    print("\n== Filesystem: b against a")
    a, b = merged_a.paths, merged_b.paths
    only_a, only_b = sorted(a.keys() - b.keys()), sorted(b.keys() - a.keys())
    for path in only_a:
        print(f"ONLY IN A {path} {a[path]['type']}")
    for path in only_b:
        print(f"ONLY IN B {path} {b[path]['type']}")
    counts = dict.fromkeys(ATTRIBUTES, 0)
    differing = 0
    for path in sorted(a.keys() & b.keys()):
        changed = [attr for attr in ATTRIBUTES if a[path][attr] != b[path][attr]]
        if changed:
            differing += 1
            for attr in changed:
                counts[attr] += 1
            print(f"DIFFERS {path}: " + ", ".join(f"{attr} {a[path][attr]} to {b[path][attr]}" for attr in changed))
    links_a, links_b = merged_a.hard_link_groups(), merged_b.hard_link_groups()
    link_changes = sorted(links_a ^ links_b)
    for group in link_changes:
        print(f"HARD LINKS {'only in a' if group in links_a else 'only in b'}: {group}")
    print(f"{len(a.keys() & b.keys())} paths in both, {len(only_a)} only in a, {len(only_b)} only in b, {differing} differ, {len(link_changes)} hard link groups differ")
    print("differences by attribute: " + json.dumps(counts))

    print("\n== Config: b against a")
    config_a, config_b = image_a.config.get("config", {}), image_b.config.get("config", {})
    config_differs = 0
    for key in sorted(set(CONFIG_KEYS) | config_a.keys() | config_b.keys()):
        left, right = config_a.get(key), config_b.get(key)
        if left == right:
            print(f"same {key}: {json.dumps(left, sort_keys=True)}")
        else:
            config_differs += 1
            print(f"DIFFERS {key}:\n  a {json.dumps(left, sort_keys=True)}\n  b {json.dumps(right, sort_keys=True)}")
    for key in ("architecture", "os"):
        if image_a.config.get(key) != image_b.config.get(key):
            config_differs += 1
            print(f"DIFFERS {key}: {image_a.config.get(key)} to {image_b.config.get(key)}")

    same = not (only_a or only_b or differing or link_changes or config_differs)
    print(f"\nRESULT {'the same' if same else 'different'}: {len(only_a) + len(only_b)} paths on one side only, {differing} paths differ, {len(link_changes)} hard link groups differ, {config_differs} config fields differ")
    sys.exit(0 if same else 1)


if __name__ == "__main__":
    main()
