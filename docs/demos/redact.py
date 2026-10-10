#!/usr/bin/env python3
"""Reproduce this demo's privacy edit from the owner's private source recording."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile


def interpolate(frame, points):
    for (first, a), (last, b) in zip(points, points[1:]):
        if first <= frame <= last:
            return a + (b - a) * (frame - first) / (last - first)
    return points[-1][1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    if source == output:
        parser.error("The output must differ from the source.")
    if output.exists():
        parser.error("The output exists. Choose a new path.")
    spec = json.loads(Path(__file__).with_name("redaction.json").read_text())
    if hashlib.sha256(source.read_bytes()).hexdigest() != spec["source_sha256"]:
        parser.error("The source does not match this recording's redaction map.")
    width, height = spec["width"], spec["height"]

    with tempfile.TemporaryDirectory(prefix="macoma-demo-mask-") as temporary:
        mask = Path(temporary) / "mask.mkv"
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
            "-pixel_format", "gray", "-video_size", f"{width}x{height}",
            "-framerate", str(spec["fps"]), "-i", "pipe:0", "-c:v", "ffv1", str(mask),
        ]
        process = subprocess.Popen(command, stdin=subprocess.PIPE)
        try:
            for frame in range(spec["frames"]):
                pixels = bytearray(width * height)
                for track in spec["tracks"]:
                    if not track["start"] <= frame <= track["end"]:
                        continue
                    if "rectangle" in track:
                        left, top, right, bottom = track["rectangle"]
                    else:
                        edge = interpolate(frame, track["edge"])
                        top, bottom = 0, height
                        left, right = (
                            (math.floor(edge), width) if track["side"] == "right"
                            else (0, math.ceil(edge))
                        )
                    left, right = max(0, left), min(width, right)
                    top, bottom = max(0, top), min(height, bottom)
                    white = b"\xff" * (right - left)
                    for row in range(top, bottom):
                        pixels[row * width + left:row * width + right] = white
                process.stdin.write(pixels)
        finally:
            process.stdin.close()
        if process.wait() != 0:
            raise SystemExit("FFmpeg could not create the privacy mask.")

        filters = (
            "[0:v]split[base][b];"
            f"[b]scale=24:16:flags=area,scale={width}:{height}:flags=bilinear,"
            "gblur=sigma=24[blur];[blur][1:v]alphamerge[redact];"
            "[base][redact]overlay=format=auto,format=yuv420p[out]"
        )
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
            "-i", str(source), "-i", str(mask), "-filter_complex", filters,
            "-map", "[out]", "-an", "-sn", "-dn", "-map_metadata", "-1",
            "-c:v", "libx264", "-preset", "medium", "-crf", "20",
            "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709",
            "-color_trc", "bt709", "-movflags", "+faststart", str(output),
        ], check=True)


if __name__ == "__main__":
    main()
