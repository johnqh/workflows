#!/usr/bin/env python3
"""Vectorize a PNG logo using color quantization + per-layer tracing.

Approach:
1. Quantize image to N representative colors (k-means)
2. For each color, create a binary mask of matching pixels
3. Trace each mask into clean SVG paths (bezier curves via contour detection)
4. Layer paths with proper z-ordering (large/dark first)

This produces cleaner SVGs than superpixel-based approaches because each
color layer is a simple binary trace with smooth contours.
"""

import cv2
import numpy as np
from pathlib import Path

INPUT = "/Users/johnhuang/sudojo/sudojo_app/public/logo.png"
OUTPUT = "/Users/johnhuang/sudojo/sudojo_app/public/logo-3.svg"


def load_image(path):
    img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(f"Cannot load {path}")
    if img.shape[2] == 4:
        rgb = cv2.cvtColor(img[:, :, :3], cv2.COLOR_BGR2RGB)
        alpha = img[:, :, 3]
    else:
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        alpha = np.full(img.shape[:2], 255, dtype=np.uint8)
    return rgb, alpha


def quantize_colors(rgb, alpha, n_colors=48):
    """Quantize foreground pixels to n_colors using k-means."""
    fg_mask = alpha > 200
    fg_pixels = rgb[fg_mask].reshape(-1, 3).astype(np.float32)

    # K-means clustering
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1.0)
    _, labels, centers = cv2.kmeans(
        fg_pixels, n_colors, None, criteria, 5, cv2.KMEANS_PP_CENTERS
    )

    centers = centers.astype(np.uint8)
    labels = labels.flatten()

    # Create full label map (-1 for background)
    h, w = rgb.shape[:2]
    label_map = np.full((h, w), -1, dtype=np.int32)
    label_map[fg_mask] = labels

    # Count pixels per color
    counts = np.bincount(labels, minlength=n_colors)

    print(f"  Quantized to {n_colors} colors ({fg_pixels.shape[0]} fg pixels)")
    return label_map, centers, counts


def trace_color_layer(mask, simplify_eps=0.003):
    """Trace a binary mask into compound SVG path data (with holes).

    Uses RETR_CCOMP to get outer contours and holes, combining them
    into compound paths with proper winding for SVG fill-rule="evenodd".
    """
    # Morphological close to fill small gaps, then smooth edges
    kernel = np.ones((3, 3), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)
    blurred = cv2.GaussianBlur(mask, (3, 3), 0.6)
    _, clean = cv2.threshold(blurred, 127, 255, cv2.THRESH_BINARY)

    contours, hierarchy = cv2.findContours(
        clean, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE
    )

    if not contours or hierarchy is None:
        return []

    hierarchy = hierarchy[0]
    paths = []

    # Process outer contours and their holes as compound paths
    i = 0
    while i < len(contours):
        if hierarchy[i][3] >= 0:
            # This is a hole — skip (will be handled by its parent)
            i += 1
            continue

        contour = contours[i]
        area = cv2.contourArea(contour)
        if area < 8:
            i += 1
            continue

        # Simplify outer contour
        perimeter = cv2.arcLength(contour, True)
        epsilon = simplify_eps * perimeter
        simplified = cv2.approxPolyDP(contour, epsilon, True)

        if len(simplified) < 3:
            i += 1
            continue

        # Build path data starting with outer contour
        pts = simplified.reshape(-1, 2)
        d = f"M{pts[0][0]},{pts[0][1]}"
        for p in pts[1:]:
            d += f"L{p[0]},{p[1]}"
        d += "Z"

        # Add any child holes
        child = hierarchy[i][2]  # First child
        while child >= 0:
            hole_contour = contours[child]
            hole_area = cv2.contourArea(hole_contour)
            if hole_area >= 8:
                h_perim = cv2.arcLength(hole_contour, True)
                h_simplified = cv2.approxPolyDP(hole_contour, simplify_eps * h_perim, True)
                if len(h_simplified) >= 3:
                    h_pts = h_simplified.reshape(-1, 2)
                    d += f"M{h_pts[0][0]},{h_pts[0][1]}"
                    for p in h_pts[1:]:
                        d += f"L{p[0]},{p[1]}"
                    d += "Z"
            child = hierarchy[child][0]  # Next sibling

        paths.append({
            "d": d,
            "area": area,
            "is_hole": False,
        })

        i += 1

    return paths


def hex_color(r, g, b):
    return f"#{r:02x}{g:02x}{b:02x}"


def build_svg(layers, width, height):
    """Build SVG from traced color layers."""
    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" '
                 f'viewBox="0 0 {width} {height}" '
                 f'width="{width}" height="{height}">')

    total_paths = 0
    for layer in layers:
        color = layer["color"]
        fill = hex_color(*color)

        for path_info in layer["paths"]:
            lines.append(
                f'  <path d="{path_info["d"]}" '
                f'fill="{fill}" fill-rule="evenodd" '
                f'stroke="{fill}" stroke-width="0.3" '
                f'stroke-linejoin="round"/>'
            )
            total_paths += 1

    lines.append("</svg>")
    print(f"  {total_paths} paths in SVG")
    return "\n".join(lines) + "\n"


def compute_quality(rgb, alpha, svg_path, width, height):
    """Render SVG and compute quality metrics."""
    import subprocess, tempfile, os

    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    tmp.close()
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(width), "-h", str(height),
             "-o", tmp.name, svg_path],
            check=True, capture_output=True,
        )
        img = cv2.imread(tmp.name, cv2.IMREAD_UNCHANGED)
        if img is None:
            return
        rendered = cv2.cvtColor(img[:, :, :3], cv2.COLOR_BGR2RGB)

        fg_mask = alpha > 200
        orig_fg = rgb[fg_mask].astype(float)
        rend_fg = rendered[fg_mask].astype(float)

        mse = np.mean((orig_fg - rend_fg) ** 2)
        psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-10))

        diff = np.abs(orig_fg - rend_fg)
        max_ch = diff.max(axis=1)
        mean_err = diff.mean()

        print(f"\n  Quality:")
        print(f"    PSNR: {psnr:.2f} dB")
        print(f"    Mean error: {mean_err:.1f} RGB")
        for t in [5, 10, 20, 40]:
            pct = (max_ch <= t).mean() * 100
            print(f"    Within {t:2d} RGB: {pct:.1f}%")
    finally:
        os.unlink(tmp.name)


def main():
    print(f"Loading {INPUT}...")
    rgb, alpha = load_image(INPUT)
    h, w = rgb.shape[:2]
    print(f"  Size: {w}x{h}")

    print("Quantizing colors...")
    label_map, centers, counts = quantize_colors(rgb, alpha, n_colors=96)

    print("Tracing color layers...")
    layers = []

    for color_idx in range(len(centers)):
        if counts[color_idx] < 10:
            continue

        color = tuple(int(c) for c in centers[color_idx])
        mask = (label_map == color_idx).astype(np.uint8) * 255

        paths = trace_color_layer(mask)
        if not paths:
            continue

        # Compute brightness for z-ordering
        lab = cv2.cvtColor(np.array([[list(color)]], dtype=np.uint8), cv2.COLOR_RGB2LAB)
        brightness = float(lab[0, 0, 0])

        total_area = sum(p["area"] for p in paths if not p["is_hole"])

        layers.append({
            "color": color,
            "paths": paths,
            "brightness": brightness,
            "total_area": total_area,
            "pixel_count": int(counts[color_idx]),
        })

    # Z-order: large bright regions first (background fill),
    # then small/dark regions on top (details and outlines should be visible)
    layers.sort(key=lambda l: (-l["total_area"], -l["brightness"]))

    print(f"  {len(layers)} color layers")

    print("Building SVG...")
    svg = build_svg(layers, w, h)

    with open(OUTPUT, "w") as f:
        f.write(svg)

    import os
    size_kb = os.path.getsize(OUTPUT) / 1024
    png_kb = os.path.getsize(INPUT) / 1024
    print(f"\nResult: {OUTPUT}")
    print(f"  SVG: {size_kb:.1f} KB")
    print(f"  PNG: {png_kb:.1f} KB (original)")
    print(f"  Ratio: {size_kb/png_kb:.1%}")

    compute_quality(rgb, alpha, OUTPUT, w, h)


if __name__ == "__main__":
    main()
