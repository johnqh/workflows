#!/usr/bin/env python3
"""Vectorize a PNG logo to SVG using vtracer (bitmap trace).

Produces clean, compact SVGs with good color fidelity.
Requires: vtracer (cargo install vtracer)

Usage:
    python3 vectorize_vtracer.py [input.png] [output.svg]
"""

import subprocess
import sys
import os


def vectorize(input_path, output_path,
              filter_speckle=4, color_precision=8,
              corner_threshold=60, segment_length=4,
              splice_threshold=45):
    """Convert PNG to SVG using vtracer."""
    cmd = [
        "vtracer",
        "--input", input_path,
        "--output", output_path,
        "--colormode", "color",
        "--hierarchical", "stacked",
        "--mode", "polygon",
        "--filter_speckle", str(filter_speckle),
        "--color_precision", str(color_precision),
        "--corner_threshold", str(corner_threshold),
        "--segment_length", str(segment_length),
        "--splice_threshold", str(splice_threshold),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    size_kb = os.path.getsize(output_path) / 1024
    png_kb = os.path.getsize(input_path) / 1024
    print(f"Converted: {input_path} -> {output_path}")
    print(f"  PNG: {png_kb:.1f} KB")
    print(f"  SVG: {size_kb:.1f} KB ({size_kb/png_kb:.0%} of original)")


def compute_quality(input_path, output_path):
    """Compute quality metrics by rendering SVG and comparing to original."""
    try:
        import cv2
        import numpy as np
        import tempfile
    except ImportError:
        print("  (Install opencv-python and numpy for quality metrics)")
        return

    img = cv2.imread(input_path, cv2.IMREAD_UNCHANGED)
    if img is None:
        return
    rgb = cv2.cvtColor(img[:, :, :3], cv2.COLOR_BGR2RGB)
    alpha = img[:, :, 3] if img.shape[2] == 4 else np.full(img.shape[:2], 255, np.uint8)
    fg = alpha > 200
    h, w = rgb.shape[:2]

    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    tmp.close()
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(w), "-h", str(h), "-o", tmp.name, output_path],
            capture_output=True, check=True,
        )
        rimg = cv2.imread(tmp.name, cv2.IMREAD_UNCHANGED)
        rendered = cv2.cvtColor(rimg[:, :, :3], cv2.COLOR_BGR2RGB)

        orig_fg = rgb[fg].astype(float)
        rend_fg = rendered[fg].astype(float)
        mse = np.mean((orig_fg - rend_fg) ** 2)
        psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-10))
        diff = np.abs(orig_fg - rend_fg).max(axis=1)

        print(f"\n  Quality:")
        print(f"    PSNR: {psnr:.2f} dB")
        for t in [5, 10, 20, 40]:
            print(f"    Within {t:2d} RGB: {100 * (diff <= t).mean():.1f}%")
    except (subprocess.CalledProcessError, Exception) as e:
        print(f"  (Could not compute quality: {e})")
    finally:
        os.unlink(tmp.name)


if __name__ == "__main__":
    input_path = sys.argv[1] if len(sys.argv) > 1 else "/Users/johnhuang/sudojo/sudojo_app/public/logo.png"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "/Users/johnhuang/sudojo/sudojo_app/public/logo-3.svg"

    vectorize(input_path, output_path)
    compute_quality(input_path, output_path)
