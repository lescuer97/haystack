#!/usr/bin/env python3
"""Install the pinned Zig toolchain used by CI.

The version, supported platforms, URLs and SHA-256 digests are pinned here. The
script never consults the live download index and never falls back to another
platform or version: a missing mapping is an error. Downloads and extraction use
a fresh, narrowly scoped temporary directory; caller-provided paths are never
recursively deleted.
"""
import argparse
import hashlib
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import NamedTuple

VERSION = "0.17.0"
BASE_URL = "https://ziglang.org/download/{version}/zig-{key}-{version}.tar.xz"


class InstallError(RuntimeError):
    pass


class Artifact(NamedTuple):
    key: str
    sha256: str

    def url(self, version: str) -> str:
        return BASE_URL.format(version=version, key=self.key)


# Reviewed official Zig 0.17.0 artifacts. Update these together with VERSION and
# re-verify against the official release before changing the pins.
ARTIFACTS = {
    ("Linux", "x86_64"): Artifact(
        "x86_64-linux",
        "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    ),
    ("Linux", "amd64"): Artifact(
        "x86_64-linux",
        "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    ),
    ("Darwin", "arm64"): Artifact(
        "aarch64-macos",
        "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    ),
    ("Darwin", "aarch64"): Artifact(
        "aarch64-macos",
        "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    ),
}


def select_artifact(version, system, machine):
    """Return the pinned artifact for an exact version/platform, or fail."""
    if version != VERSION:
        raise InstallError(
            f"unsupported Zig version {version!r}; this project pins {VERSION}"
        )
    try:
        return ARTIFACTS[(system, machine)]
    except KeyError as error:
        raise InstallError(
            f"no pinned Zig {VERSION} artifact for {system}/{machine}; "
            "refusing to use a different platform or version"
        ) from error


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, dest):
    """Download a URL to `dest` using a streaming read."""
    with urllib.request.urlopen(url, timeout=120) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out)


def _inside(root, path):
    try:
        return os.path.commonpath((str(root), str(path))) == str(root)
    except ValueError:
        return False


def safe_extract(archive_path, dest):
    """Extract an xz tar archive without allowing members outside `dest`."""
    root = Path(dest).resolve()
    with tarfile.open(archive_path, "r:xz") as archive:
        for member in archive.getmembers():
            target = (root / member.name).resolve()
            if not _inside(root, target):
                raise InstallError(f"archive member escapes destination: {member.name}")
            if member.issym() or member.islnk():
                link = (target.parent / member.linkname).resolve()
                if not _inside(root, link):
                    raise InstallError(
                        f"archive link escapes destination: {member.name}"
                    )
        if hasattr(tarfile, "data_filter"):
            archive.extractall(root, filter="data")
        else:  # pragma: no cover - current CI Python always has data_filter
            archive.extractall(root)


def find_zig(extract_dir):
    entries = [entry for entry in Path(extract_dir).iterdir() if entry.is_dir()]
    if len(entries) != 1:
        raise InstallError(
            f"expected one top-level directory in the Zig archive, found {len(entries)}"
        )
    zig = entries[0] / "zig"
    if not zig.is_file():
        raise InstallError(f"Zig archive has no executable at {zig}")
    return zig


def install_artifact(
    artifact,
    version=VERSION,
    *,
    downloader=download,
    github_path=None,
    work_dir=None,
):
    """Download, verify, extract and locate a pinned Zig artifact.

    Returns the path to the `zig` executable. A temporary work directory is kept
    on success (so the toolchain remains available for the rest of the job) and
    removed on failure. If the caller supplies `work_dir`, it is never deleted
    by this function.
    """
    managed = work_dir is None
    work = Path(tempfile.mkdtemp(prefix="cdk-zig-")) if managed else Path(work_dir)
    work.mkdir(parents=True, exist_ok=True)
    try:
        archive = work / "zig.tar.xz"
        downloader(artifact.url(version), archive)
        actual = sha256_file(archive)
        if actual != artifact.sha256:
            raise InstallError(
                f"Zig {version} checksum mismatch: expected {artifact.sha256}, got {actual}"
            )

        extract = work / "extract"
        extract.mkdir()
        safe_extract(archive, extract)
        zig = find_zig(extract)
        if not os.access(zig, os.X_OK):
            raise InstallError(f"Zig executable is not executable: {zig}")

        if github_path:
            with open(github_path, "a", encoding="utf-8") as path_file:
                path_file.write(f"{zig.parent}\n")
        return zig
    except Exception:
        if managed:
            shutil.rmtree(work, ignore_errors=True)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=VERSION)
    parser.add_argument("--system", default=platform.system())
    parser.add_argument("--machine", default=platform.machine())
    args = parser.parse_args(argv)

    try:
        artifact = select_artifact(args.version, args.system, args.machine)
        zig = install_artifact(
            artifact,
            args.version,
            github_path=os.environ.get("GITHUB_PATH"),
        )
    except (InstallError, OSError) as error:
        sys.exit(f"Zig install failed: {error}")
    print(f"Zig {args.version} installed at {zig}")


if __name__ == "__main__":
    main()
