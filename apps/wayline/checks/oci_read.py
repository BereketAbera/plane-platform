# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Reads an image as a registry serves it: the manifest, the config and each layer blob, each checked against its
digest. Blobs are streamed, so nothing is stored, and nothing is loaded into Docker. Used by layer-check.py,
flatten-compare.py and flatten-config.py.

A reference must name a digest. Docker Hub images are read through mirror.gcr.io first, as scripts/ci/scan-images.sh
does, then Docker Hub. The digest makes any mirror safe.

An image is read for one platform: each command's --platform, or else PLATFORM, with the default scripts/ci/build-images.sh
has. An index gives its child for that platform. A plain manifest is one architecture, which only its config says, and a
registry serves any digest it holds. So an image whose config says another platform is refused. Read anyway, it would pass
every check and say nothing about the image that runs.
"""
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request

MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
# The laptop's kind node. images.yml sets PLATFORM=linux/amd64, for the VPS.
DEFAULT_PLATFORM = "linux/arm64"
CHUNK = 1024 * 1024
# The gzip of an empty tar. BuildKit adds it for an instruction that changes nothing, and it holds no entries.
EMPTY_LAYER = "sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1"


def default_platform():
    return os.environ.get("PLATFORM") or DEFAULT_PLATFORM


class Unreadable(Exception):
    """An image could not be read completely. Callers must not treat this as a clean result."""


class NoCrossHostAuth(urllib.request.HTTPRedirectHandler):
    """A blob redirects to a CDN or an object store, which must not receive the registry's token."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            new.remove_header("Authorization")
        return new


OPENER = urllib.request.build_opener(NoCrossHostAuth())


def docker_auth(host):
    """The login `docker login` stored for this host, if it is in config.json rather than a credential helper."""
    path = os.path.join(os.environ.get("DOCKER_CONFIG", os.path.expanduser("~/.docker")), "config.json")
    try:
        with open(path, encoding="utf-8") as handle:
            auths = json.load(handle).get("auths", {})
    except (OSError, ValueError):
        return None
    entry = auths.get(host) or auths.get(f"https://{host}") or {}
    return entry.get("auth")


class Registry:
    def __init__(self, host, repository):
        self.host = host
        self.repository = repository
        plain_http = host.startswith(("localhost:", "127.0.0.1:"))
        self.base = f"{'http' if plain_http else 'https'}://{host}/v2/{repository}"
        self.token = None

    def _authenticate(self, challenge):
        fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        if not challenge.lower().startswith("bearer") or "realm" not in fields:
            raise Unreadable(f"{self.host} asks for authentication this does not speak: {challenge}")
        query = {"service": fields.get("service", ""), "scope": fields.get("scope") or f"repository:{self.repository}:pull"}
        request = urllib.request.Request(f"{fields['realm']}?{urllib.parse.urlencode(query)}")
        auth = docker_auth(self.host)
        if auth:
            request.add_header("Authorization", f"Basic {auth}")
        with OPENER.open(request, timeout=60) as reply:
            body = json.load(reply)
        self.token = body.get("token") or body.get("access_token")
        if not self.token:
            raise Unreadable(f"{self.host} gave no token")

    def open(self, path, accept=None):
        for attempt in range(2):
            request = urllib.request.Request(f"{self.base}/{path}")
            if accept:
                request.add_header("Accept", accept)
            if self.token:
                request.add_header("Authorization", f"Bearer {self.token}")
            try:
                return OPENER.open(request, timeout=300)
            except urllib.error.HTTPError as err:
                if err.code == 401 and attempt == 0:
                    self._authenticate(err.headers.get("WWW-Authenticate", ""))
                    continue
                raise Unreadable(f"{self.base}/{path}: HTTP {err.code}") from err
            except urllib.error.URLError as err:
                raise Unreadable(f"{self.base}/{path}: {err.reason}") from err
        raise Unreadable(f"{self.base}/{path}: not authorized")

    def verified_bytes(self, path, digest, accept=None):
        with self.open(path, accept) as reply:
            data = reply.read()
        if f"sha256:{hashlib.sha256(data).hexdigest()}" != digest:
            raise Unreadable(f"{self.base}/{path} does not match {digest}")
        return data


def candidates(reference):
    """The (host, repository) pairs to try in order, and the digest."""
    name, _, digest = reference.partition("@")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise Unreadable(f"{reference} does not name a digest")
    first = name.split("/", 1)[0]
    if "." in first or ":" in first or first == "localhost":
        host, path = name.split("/", 1)
    else:
        host, path = "docker.io", name
    path = re.sub(r":[^/]*$", "", path)
    if host != "docker.io":
        return [(host, path)], digest
    if "/" not in path:
        path = f"library/{path}"
    return [("mirror.gcr.io", path), ("registry-1.docker.io", path)], digest


class Tee(io.RawIOBase):
    """Reads a blob once, hashing what passes through, so the bytes read are the bytes the digest names."""

    def __init__(self, source):
        super().__init__()
        self.source = source
        self.sha = hashlib.sha256()
        self.count = 0

    def readable(self):
        return True

    def readinto(self, buffer):
        data = self.source.read(len(buffer))
        self.sha.update(data)
        self.count += len(data)
        buffer[: len(data)] = data
        return len(data)


class ZstdStream(io.RawIOBase):
    """The zstd binary, fed from a thread, because the standard library gains zstd only in Python 3.14."""

    def __init__(self, source):
        super().__init__()
        binary = shutil.which("zstd")
        if not binary:
            raise Unreadable("a layer is zstd and there is no zstd binary to read it with")
        self.process = subprocess.Popen([binary, "-dc"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.thread = threading.Thread(target=self._feed, args=(source,), daemon=True)
        self.thread.start()

    def _feed(self, source):
        try:
            for chunk in iter(lambda: source.read(CHUNK), b""):
                self.process.stdin.write(chunk)
        except BrokenPipeError:
            pass
        finally:
            self.process.stdin.close()

    def readable(self):
        return True

    def readinto(self, buffer):
        data = self.process.stdout.read(len(buffer))
        buffer[: len(data)] = data
        # Without this, a stream zstd could not read would end early and look like a short, clean one.
        if not data and self.process.wait() != 0:
            raise OSError(f"zstd exited {self.process.returncode}")
        return len(data)


def tar_stream(media_type, blob):
    if "gzip" in media_type:
        return io.BufferedReader(gzip.GzipFile(fileobj=blob, mode="rb"), CHUNK)
    if "zstd" in media_type:
        return io.BufferedReader(ZstdStream(blob), CHUNK)
    if media_type.endswith("tar"):
        return blob
    raise Unreadable(f"a layer has a media type this cannot read: {media_type}")


class Image:
    """One platform's manifest and config, from the first place that serves the digest. Fails if that is not what it is."""

    def __init__(self, reference, platform=None):
        self.reference = reference
        self.platform = platform or default_platform()
        if not re.fullmatch(r"[a-z0-9]+/[a-z0-9]+", self.platform):
            raise Unreadable(f"{self.platform} is not <os>/<architecture>, such as linux/amd64")
        hosts, digest = candidates(reference)
        data = None
        errors = []
        for host, repository in hosts:
            registry = Registry(host, repository)
            try:
                data = registry.verified_bytes(f"manifests/{digest}", digest, MANIFEST_TYPES)
                self.registry = registry
                break
            except (Unreadable, OSError) as err:
                errors.append(str(err))
        if data is None:
            raise Unreadable("; ".join(errors))
        self.source = f"{self.registry.host}/{self.registry.repository}"
        manifest = json.loads(data)
        self.platform_manifest = None
        if "manifests" in manifest:
            os_name, arch = self.platform.split("/")
            matches = [m for m in manifest["manifests"] if m.get("platform", {}).get("os") == os_name and m.get("platform", {}).get("architecture") == arch]
            if len(matches) != 1:
                raise Unreadable(f"{reference} has {len(matches)} manifests for {self.platform}")
            self.platform_manifest = matches[0]["digest"]
            manifest = json.loads(self.registry.verified_bytes(f"manifests/{self.platform_manifest}", self.platform_manifest, MANIFEST_TYPES))
        self.manifest = manifest
        self.layers = manifest["layers"]
        self.config_digest = manifest["config"]["digest"]
        self.config_bytes = self.registry.verified_bytes(f"blobs/{self.config_digest}", self.config_digest)
        self.config = json.loads(self.config_bytes)
        found = f"{self.config.get('os')}/{self.config.get('architecture')}"
        if found != self.platform:
            raise Unreadable(f"{reference} is {found}, and this read is for {self.platform}. --platform or PLATFORM says which it should be")

    def read_layer(self, index, handler):
        """Calls handler(tar stream) on layer <index>, counted from 0, and returns the compressed size. Everything the
        handler leaves unread still passes through the hash, and a blob that does not match its digest raises."""
        layer = self.layers[index]
        with self.registry.open(f"blobs/{layer['digest']}") as reply:
            tee = Tee(reply)
            blob = io.BufferedReader(tee, CHUNK)
            try:
                handler(tar_stream(layer["mediaType"], blob))
                for _ in iter(lambda: blob.read(CHUNK), b""):
                    pass
            except (OSError, EOFError) as err:
                raise Unreadable(f"layer {index + 1} {layer['digest']}: {err}") from err
        got = f"sha256:{tee.sha.hexdigest()}"
        if got != layer["digest"]:
            raise Unreadable(f"layer {index + 1}: read {got}, the manifest says {layer['digest']}")
        return tee.count
