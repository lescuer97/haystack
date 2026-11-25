"""Check standalone build inputs or create synthetic assets for CI (never publish them)."""
import argparse
from pathlib import Path
import struct
import subprocess
import zlib


# Minimal sheets with the production dimensions, independent of the licensed art.
ATLAS_FIXTURES = {
    "Tiles/Grass_Middle.png": (16, 16),
    "Tiles/Path_Tile.png": (48, 96),
    "Tiles/Water_Tile.png": (48, 96),
    "Outdoor decoration/Oak_Tree.png": (64, 80),
    "Outdoor decoration/Outdoor_Decor_Free.png": (112, 192),
    "Player/Player.png": (192, 320),
    "Player/Player_Actions.png": (96, 576),
}


def create_fixture(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as output:
        output.write(data)


def png(width, height, color):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\x00" + color * width) * height))
        + chunk(b"IEND", b"")
    )


def create_fixtures(assets):
    ogg = subprocess.check_output([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "anullsrc=r=44100:cl=mono", "-t", "0.25", "-c:a", "libvorbis", "-f", "ogg", "pipe:1",
    ])
    for index, (name, (width, height)) in enumerate(ATLAS_FIXTURES.items()):
        create_fixture(assets / name, png(width, height, bytes((64 + index * 20, 130, 80))))
    for index in range(1, 5):
        create_fixture(assets / f"music/media/cozy-{index}.ogg", ogg)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("paths", nargs="+", type=Path)
    fixture = commands.add_parser("fixtures")
    fixture.add_argument("assets", type=Path)
    args = parser.parse_args()
    if args.command == "fixtures":
        create_fixtures(args.assets)
        return
    missing = [path for path in args.paths if not path.is_file() or path.stat().st_size == 0]
    if missing:
        listing = "\n".join(f"  {path}" for path in missing)
        parser.exit(1, f"Standalone assets missing or empty:\n{listing}\nSee docs/build.md for asset sources and licensing.\n")


if __name__ == "__main__":
    main()
