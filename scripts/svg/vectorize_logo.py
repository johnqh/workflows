#!/usr/bin/env python3
"""Vectorize a low-poly style PNG logo into clean SVG polygons.

v3 — Full quality pipeline:
1. Edge-aware SLIC superpixel segmentation (high resolution)
2. LAB color space for perceptual color merging
3. Dark outline preservation (thin dark regions kept separate)
4. Union-find merge with adaptive thresholds
5. Per-polygon color sampling from original pixels
6. Gradient fitting with R² quality gate
7. Adaptive polygon simplification
8. Morphological cleanup for clean contours
9. Proper z-ordering and SVG optimization
"""

import cv2
import numpy as np
from collections import defaultdict

INPUT = "/Users/johnhuang/sudojo/sudojo_app/public/logo.png"
OUTPUT = "/Users/johnhuang/sudojo/sudojo_app/public/logo-2.svg"


# ── Image loading ──────────────────────────────────────────────

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


# ── Edge detection ─────────────────────────────────────────────

def detect_edges(rgb):
    """Multi-channel Canny edge detection for facet boundaries."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)

    # Multi-scale on grayscale
    e1 = cv2.Canny(gray, 30, 80)
    e2 = cv2.Canny(gray, 60, 160)

    # Per-channel edges (catches color-only boundaries)
    er = cv2.Canny(rgb[:, :, 0], 35, 100)
    eg = cv2.Canny(rgb[:, :, 1], 35, 100)
    eb = cv2.Canny(rgb[:, :, 2], 35, 100)

    # LAB edges (perceptually uniform)
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)
    el = cv2.Canny(lab[:, :, 0], 30, 90)
    ea = cv2.Canny(lab[:, :, 1], 25, 75)
    ebl = cv2.Canny(lab[:, :, 2], 25, 75)

    edges = np.maximum(e1, e2)
    for e in [er, eg, eb, el, ea, ebl]:
        edges = np.maximum(edges, e)

    return edges


# ── Superpixel segmentation ───────────────────────────────────

def slic_segmentation(rgb, alpha, edges, n_segments=1200):
    """Edge-aware SLIC segmentation at high resolution."""
    from skimage.segmentation import slic as sk_slic

    fg_mask = alpha > 200

    # Boost edge pixels in the image to discourage SLIC from crossing them.
    # Overlay dark lines on a copy of the image at edge locations.
    rgb_edged = rgb.copy()
    edge_dilated = cv2.dilate(edges, np.ones((2, 2), np.uint8), iterations=1)
    edge_mask = edge_dilated > 0
    # Darken edge pixels to create barriers
    rgb_edged[edge_mask] = (rgb_edged[edge_mask].astype(float) * 0.5).astype(np.uint8)

    labels = sk_slic(rgb_edged, n_segments=n_segments, compactness=12,
                     start_label=0, mask=fg_mask, enforce_connectivity=True,
                     min_size_factor=0.2, sigma=0.5)

    # Remap: background = -1, foreground = 0..N-1
    labels[~fg_mask] = -1
    unique = sorted(set(labels.flat) - {-1})
    remap = {old: new for new, old in enumerate(unique)}
    remap[-1] = -1
    out = np.vectorize(lambda x: remap.get(x, -1))(labels)
    n_labels = len(unique)

    print(f"  SLIC: {n_labels} superpixels")
    return out, n_labels


# ── Adjacency computation ─────────────────────────────────────

def compute_adjacency(labels, n_labels):
    """Vectorized adjacency detection."""
    adj = defaultdict(set)

    # Horizontal neighbors
    diff_h = labels[:, :-1] != labels[:, 1:]
    ys, xs = np.where(diff_h)
    for y, x in zip(ys, xs):
        a, b = int(labels[y, x]), int(labels[y, x + 1])
        if a >= 0 and b >= 0:
            adj[a].add(b)
            adj[b].add(a)

    # Vertical neighbors
    diff_v = labels[:-1, :] != labels[1:, :]
    ys, xs = np.where(diff_v)
    for y, x in zip(ys, xs):
        a, b = int(labels[y, x]), int(labels[y + 1, x])
        if a >= 0 and b >= 0:
            adj[a].add(b)
            adj[b].add(a)

    return adj


# ── Region statistics ──────────────────────────────────────────

def compute_region_stats(labels, n_labels, rgb, alpha):
    """Compute per-superpixel color stats in both RGB and LAB."""
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(float)

    mean_rgb = np.zeros((n_labels, 3), dtype=float)
    mean_lab = np.zeros((n_labels, 3), dtype=float)
    mean_alpha = np.zeros(n_labels, dtype=float)
    counts = np.zeros(n_labels, dtype=int)
    brightness = np.zeros(n_labels, dtype=float)  # L channel

    for lid in range(n_labels):
        mask = labels == lid
        count = mask.sum()
        if count == 0:
            continue
        counts[lid] = count
        mean_rgb[lid] = rgb[mask].mean(axis=0)
        mean_lab[lid] = lab[mask].mean(axis=0)
        mean_alpha[lid] = alpha[mask].mean()
        brightness[lid] = mean_lab[lid, 0]

    return mean_rgb, mean_lab, mean_alpha, counts, brightness


# ── Merging ────────────────────────────────────────────────────

def merge_regions(labels, n_labels, rgb, alpha, adj,
                  mean_rgb, mean_lab, mean_alpha, counts, brightness,
                  color_threshold=18.0, dark_threshold=40.0):
    """
    Merge adjacent superpixels with similar colors using LAB distance.
    Dark/outline regions (low brightness) are merged more conservatively
    to preserve the dark stroke lines between facets.
    """
    h, w = labels.shape

    parent = list(range(n_labels))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if counts[ra] < counts[rb]:
            ra, rb = rb, ra
        parent[rb] = ra
        total = counts[ra] + counts[rb]
        if total > 0:
            w_a, w_b = counts[ra] / total, counts[rb] / total
            mean_rgb[ra] = mean_rgb[ra] * w_a + mean_rgb[rb] * w_b
            mean_lab[ra] = mean_lab[ra] * w_a + mean_lab[rb] * w_b
            mean_alpha[ra] = mean_alpha[ra] * w_a + mean_alpha[rb] * w_b
            brightness[ra] = mean_lab[ra, 0]
        counts[ra] = total

    # Multiple passes until convergence
    changed = True
    passes = 0
    while changed:
        changed = False
        passes += 1
        for a in range(n_labels):
            ra = find(a)
            if mean_alpha[ra] < 200 or counts[ra] == 0:
                continue
            for b in adj[a]:
                rb = find(b)
                if ra == rb:
                    continue
                if mean_alpha[rb] < 200 or counts[rb] == 0:
                    continue

                # LAB distance (perceptually uniform)
                lab_dist = np.linalg.norm(mean_lab[ra] - mean_lab[rb])

                # Are both dark? (potential outline strokes)
                both_dark = brightness[ra] < dark_threshold and brightness[rb] < dark_threshold
                # Is one dark and one bright? (outline vs facet boundary - don't merge)
                one_dark = (brightness[ra] < dark_threshold) != (brightness[rb] < dark_threshold)

                if one_dark:
                    # Very strict threshold for dark-to-bright boundaries
                    threshold = color_threshold * 0.5
                elif both_dark:
                    # Dark regions merge with each other more easily
                    threshold = color_threshold * 1.3
                else:
                    threshold = color_threshold

                if lab_dist < threshold:
                    union(ra, rb)
                    changed = True

    # Relabel
    new_labels = np.full_like(labels, -1)
    label_map = {}
    next_id = 0
    for y in range(h):
        for x in range(w):
            lbl = labels[y, x]
            if lbl < 0:
                continue
            root = find(lbl)
            if counts[root] == 0 or mean_alpha[root] < 200:
                continue
            if root not in label_map:
                label_map[root] = next_id
                next_id += 1
            new_labels[y, x] = label_map[root]

    # Build color maps
    new_colors = {}
    new_alphas = {}
    new_lab_colors = {}
    for root, nid in label_map.items():
        new_colors[nid] = tuple(int(v) for v in mean_rgb[root])
        new_alphas[nid] = float(mean_alpha[root]) / 255.0
        new_lab_colors[nid] = mean_lab[root].copy()

    print(f"  Merged: {n_labels} → {next_id} regions ({passes} passes)")
    return new_labels, next_id, new_colors, new_alphas, new_lab_colors


# ── Stroke/outline detection ───────────────────────────────────

def detect_strokes(rgb, alpha, labels, dark_threshold=65):
    """
    Detect dark outline strokes between polygon facets.

    Instead of skeletonizing (which fails on complex branching networks),
    we detect dark boundary lines between adjacent polygon regions and
    render them as polygon outlines with measured width/color.

    Returns per-polygon stroke info (width and color for the outline).
    """
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    fg = alpha > 200
    h, w = gray.shape

    # Real dark strokes: very dark pixels (not just color transitions)
    # Use a stricter threshold — real outlines are near-black
    strict_dark = (gray < 45) & fg
    strict_u8 = strict_dark.astype(np.uint8) * 255
    kernel = np.ones((3, 3), np.uint8)
    strict_u8 = cv2.morphologyEx(strict_u8, cv2.MORPH_CLOSE, kernel, iterations=1)

    # Width of real dark bands via distance transform
    dist = cv2.distanceTransform(strict_u8, cv2.DIST_L2, 5)

    # For each polygon, check if its boundary has a REAL dark outline
    n_regions = labels.max() + 1
    stroke_info = {}

    for rid in range(n_regions):
        mask = (labels == rid).astype(np.uint8) * 255
        if cv2.countNonZero(mask) < 10:
            continue

        # Boundary ring (2px wide to catch the outline band)
        dilated = cv2.dilate(mask, np.ones((5, 5), np.uint8), iterations=1)
        boundary = dilated - mask

        bdy_ys, bdy_xs = np.where(boundary > 0)
        if len(bdy_ys) == 0:
            continue

        # The boundary must be significantly darker than the polygon itself
        # (otherwise it's just a dark block's edge, not a drawn outline)
        region_ys, region_xs = np.where(mask > 0)
        region_brightness = float(np.median(gray[region_ys, region_xs]))

        bdy_very_dark = (boundary > 0) & strict_dark
        dark_ys, dark_xs = np.where(bdy_very_dark)

        if len(dark_ys) < 5:
            continue

        # Boundary must be much darker than the polygon (real outline contrast)
        bdy_brightness = float(np.median(gray[dark_ys, dark_xs]))
        if region_brightness - bdy_brightness < 40:
            continue  # Not enough contrast — just color transition, not outline

        dark_fraction = len(dark_ys) / len(bdy_ys)
        if dark_fraction < 0.25:
            continue

        # Must have coherent width > 2px
        widths = dist[dark_ys, dark_xs] * 2
        median_width = float(np.median(widths))
        if median_width < 2.5:
            continue  # Too thin — likely AA, not a drawn stroke

        # Sample color from the dark band
        bdy_colors = rgb[dark_ys, dark_xs]
        stroke_color = tuple(int(v) for v in np.median(bdy_colors, axis=0))

        # Stroke width: use half the measured dark band width
        stroke_width = np.clip(median_width * 0.45, 1.0, 3.0)

        stroke_info[rid] = {
            "width": round(stroke_width, 1),
            "color": stroke_color,
            "dark_fraction": dark_fraction,
        }

    print(f"  {len(stroke_info)} polygons with dark outlines")
    return stroke_info


# ── Contour smoothing ──────────────────────────────────────────

def gaussian_smooth_contour(contour, sigma=1.5):
    """
    Smooth a closed contour using 1D Gaussian filtering on coordinates.
    Unlike Chaikin corner-cutting, this is approximately area-preserving
    and doesn't systematically shrink the polygon.
    """
    from scipy.ndimage import gaussian_filter1d

    pts = contour.reshape(-1, 2).astype(float)
    n = len(pts)
    if n < 6:
        return contour

    # Wrap-pad for periodic boundary (closed contour)
    pad = min(n, max(3, int(3 * sigma)))
    x = np.concatenate([pts[-pad:, 0], pts[:, 0], pts[:pad, 0]])
    y = np.concatenate([pts[-pad:, 1], pts[:, 1], pts[:pad, 1]])

    x_smooth = gaussian_filter1d(x, sigma=sigma)
    y_smooth = gaussian_filter1d(y, sigma=sigma)

    # Extract the non-padded portion
    result = np.column_stack([
        x_smooth[pad:pad + n],
        y_smooth[pad:pad + n],
    ])

    return result.reshape(-1, 1, 2).astype(np.int32)


# ── Polygon extraction ─────────────────────────────────────────

def extract_polygons(labels, n_regions, colors, alphas, lab_colors,
                     rgb, alpha, min_area=12):
    """Extract clean polygon contours with adaptive simplification."""
    polygons = []

    for rid in range(n_regions):
        mask = (labels == rid).astype(np.uint8) * 255
        area = cv2.countNonZero(mask)
        if area < min_area:
            continue

        a = alphas.get(rid, 1.0)
        if a < 0.8:
            continue

        # Close to fill tiny holes, dilate 1px for slight overlap
        kernel = np.ones((3, 3), np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)
        mask = cv2.dilate(mask, np.ones((2, 2), np.uint8), iterations=1)

        # Find contours
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_TC89_L1)
        if not contours:
            continue

        contour = max(contours, key=cv2.contourArea)
        carea = cv2.contourArea(contour)
        if carea < min_area:
            continue

        # Step 1: simplify to remove pixel-level noise
        perimeter = cv2.arcLength(contour, True)
        if carea < 60:
            epsilon = 0.018 * perimeter
        elif carea < 200:
            epsilon = 0.010 * perimeter
        elif carea < 800:
            epsilon = 0.006 * perimeter
        else:
            epsilon = 0.004 * perimeter

        approx = cv2.approxPolyDP(contour, epsilon, True)
        if len(approx) < 3:
            continue

        # Step 2: Get full contour for smooth filtering, then Gaussian smooth
        full_contour, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        if full_contour:
            full_c = max(full_contour, key=cv2.contourArea)
            # Adaptive sigma: more smoothing for larger regions
            sigma = 1.0 if carea < 100 else (1.5 if carea < 500 else 2.5)
            smoothed = gaussian_smooth_contour(full_c, sigma=sigma)

            # Re-simplify the smoothed contour
            smooth_perim = cv2.arcLength(smoothed, True)
            approx = cv2.approxPolyDP(smoothed, 0.005 * smooth_perim, True)
            if len(approx) < 3:
                continue

        # Sample actual color from original pixels inside the polygon
        color, sampled_alpha = sample_color_from_original(rgb, alpha, mask)

        # Check for gradient — only use if it improves over solid fill
        gradient = None
        if carea > 50:
            grad_candidate = fit_gradient(rgb, mask)
            if grad_candidate:
                # Verify gradient improves MSE vs solid fill
                gradient = verify_gradient_improvement(rgb, mask, color, grad_candidate)

        points = approx.reshape(-1, 2).tolist()

        # Compute centroid for z-ordering
        M = cv2.moments(contour)
        if M["m00"] > 0:
            cx = M["m10"] / M["m00"]
            cy = M["m01"] / M["m00"]
        else:
            cx, cy = np.mean(points, axis=0)

        polygons.append({
            "points": points,
            "color": color,
            "opacity": round(min(sampled_alpha, 1.0), 3),
            "area": carea,
            "gradient": gradient,
            "centroid": (cx, cy),
            "brightness": lab_colors.get(rid, np.array([50, 0, 0]))[0],
            "region_id": rid,
        })

    return polygons


def sample_color_from_original(rgb, alpha, mask):
    """Sample color from original image pixels (not SLIC average)."""
    # Erode mask slightly to avoid edge contamination
    kernel = np.ones((2, 2), np.uint8)
    inner_mask = cv2.erode(mask, kernel, iterations=1)
    if cv2.countNonZero(inner_mask) < 5:
        inner_mask = mask  # Fall back if too small

    ys, xs = np.where(inner_mask > 0)
    if len(ys) == 0:
        return (128, 128, 128), 1.0

    colors = rgb[ys, xs]
    alphas = alpha[ys, xs]

    # Use trimmed mean (exclude top/bottom 10%) for robustness
    n = len(colors)
    if n > 20:
        trim = max(1, n // 10)
        means = []
        for ch in range(3):
            sorted_ch = np.sort(colors[:, ch])
            means.append(int(np.mean(sorted_ch[trim:-trim])))
        color = tuple(means)
    else:
        color = tuple(int(v) for v in np.median(colors, axis=0))

    a = float(np.median(alphas)) / 255.0
    return color, a


# ── Gradient fitting and validation ─────────────────────────────

def verify_gradient_improvement(rgb, mask, solid_color, gradient):
    """Only use gradient if it reduces mean color error vs solid fill."""
    ys, xs = np.where(mask > 0)
    if len(ys) < 10:
        return None

    actual = rgb[ys, xs].astype(float)

    # MSE with solid fill
    solid = np.array(solid_color, dtype=float)
    mse_solid = np.mean(np.sum((actual - solid) ** 2, axis=1))

    # MSE with gradient fill: interpolate gradient color per pixel
    g = gradient
    gx1, gy1 = g["x1"], g["y1"]
    gx2, gy2 = g["x2"], g["y2"]
    c_start = np.array(g["color_start"], dtype=float)
    c_end = np.array(g["color_end"], dtype=float)

    # Project each pixel onto the gradient axis
    dx, dy = gx2 - gx1, gy2 - gy1
    length_sq = dx * dx + dy * dy
    if length_sq < 1:
        return None

    t = ((xs - gx1) * dx + (ys - gy1) * dy) / length_sq
    t = np.clip(t, 0, 1)

    # Interpolated gradient colors
    grad_colors = c_start[None, :] + t[:, None] * (c_end - c_start)[None, :]
    mse_gradient = np.mean(np.sum((actual - grad_colors) ** 2, axis=1))

    # Only use gradient if it's meaningfully better (>15% MSE reduction)
    if mse_gradient < mse_solid * 0.85:
        return gradient
    return None

def fit_gradient(rgb, mask):
    """
    Fit a linear gradient to a region.
    Returns gradient params only if R² is high enough (good fit).
    """
    ys, xs = np.where(mask > 0)
    if len(ys) < 20:
        return None

    colors = rgb[ys, xs].astype(float)
    std = np.std(colors, axis=0)
    if np.max(std) < 5:
        return None  # Truly solid color

    coords = np.column_stack([xs, ys]).astype(float)
    mean_coord = coords.mean(axis=0)
    dc = coords - mean_coord

    best = None
    best_r2 = 0

    for angle_deg in range(0, 180, 5):  # Fine angle search
        angle = np.radians(angle_deg)
        direction = np.array([np.cos(angle), np.sin(angle)])
        proj = dc @ direction

        span = proj.max() - proj.min()
        if span < 6:
            continue

        t = (proj - proj.min()) / span  # 0..1 along gradient axis

        # Fit linear model: color = a + b*t for each channel
        # Compute R² to check fit quality
        total_var = 0
        residual_var = 0
        c_start = np.zeros(3)
        c_end = np.zeros(3)

        for ch in range(3):
            y = colors[:, ch]
            y_mean = y.mean()
            ss_tot = np.sum((y - y_mean) ** 2)
            if ss_tot < 1:
                continue

            # Linear regression: y = a + b*t
            t_mean = t.mean()
            b = np.sum((t - t_mean) * (y - y_mean)) / (np.sum((t - t_mean) ** 2) + 1e-10)
            a = y_mean - b * t_mean

            predicted = a + b * t
            ss_res = np.sum((y - predicted) ** 2)

            total_var += ss_tot
            residual_var += ss_res
            c_start[ch] = np.clip(a, 0, 255)
            c_end[ch] = np.clip(a + b, 0, 255)

        if total_var < 1:
            continue

        r2 = 1 - (residual_var / total_var)
        color_range = np.linalg.norm(c_end - c_start)

        # Accept if gradient explains meaningful variance and is visually noticeable
        if r2 > best_r2 and r2 > 0.20 and color_range > 15:
            p_start = mean_coord - direction * span / 2
            p_end = mean_coord + direction * span / 2
            best_r2 = r2
            best = {
                "color_start": tuple(int(v) for v in c_start),
                "color_end": tuple(int(v) for v in c_end),
                "x1": float(p_start[0]),
                "y1": float(p_start[1]),
                "x2": float(p_end[0]),
                "y2": float(p_end[1]),
                "r2": r2,
            }

    return best


# ── SVG rendering & quality metrics ────────────────────────────

def render_svg_to_array(svg_path, width, height):
    """Render SVG to numpy RGBA array via rsvg-convert."""
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
            raise RuntimeError(f"Failed to read rendered PNG {tmp.name}")
        # Convert BGR(A) to RGB(A)
        if img.shape[2] == 4:
            rendered_rgb = cv2.cvtColor(img[:, :, :3], cv2.COLOR_BGR2RGB)
            rendered_alpha = img[:, :, 3]
        else:
            rendered_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            rendered_alpha = np.full(img.shape[:2], 255, dtype=np.uint8)
        return rendered_rgb, rendered_alpha
    finally:
        os.unlink(tmp.name)


def compute_psnr(orig, rendered, fg_mask):
    """Compute PSNR over foreground pixels."""
    orig_fg = orig[fg_mask].astype(float)
    rend_fg = rendered[fg_mask].astype(float)
    mse = np.mean((orig_fg - rend_fg) ** 2)
    if mse < 1e-10:
        return 100.0
    return 10 * np.log10(255.0 ** 2 / mse)


def compute_per_polygon_error(orig, rendered, labels, polygons):
    """Compute per-polygon MSE and mean color difference using interior pixels only.

    Interior pixels (eroded mask) avoid contamination from overlapping polygon
    boundaries, giving more accurate per-polygon error signals.
    """
    h, w = labels.shape

    # Build region_id → polygon index map
    rid_to_idx = {}
    for i, poly in enumerate(polygons):
        rid = poly.get("region_id")
        if rid is not None:
            rid_to_idx[rid] = i

    errors = [None] * len(polygons)
    kernel = np.ones((3, 3), np.uint8)

    for rid, idx in rid_to_idx.items():
        full_mask = (labels == rid)
        # Erode by 2px to get interior-only pixels (avoid overlap zone)
        mask_u8 = full_mask.astype(np.uint8) * 255
        eroded = cv2.erode(mask_u8, kernel, iterations=2)
        interior = eroded > 0

        # Fall back to full mask if erosion leaves too few pixels
        if interior.sum() < 10:
            interior = full_mask

        n_pixels = int(interior.sum())
        if n_pixels < 5:
            errors[idx] = {"mse": 0, "orig_mean": np.zeros(3), "rend_mean": np.zeros(3), "n_pixels": 0}
            continue

        orig_px = orig[interior].astype(float)
        rend_px = rendered[interior].astype(float)
        diff = orig_px - rend_px
        mse = float(np.mean(np.sum(diff ** 2, axis=1)))

        errors[idx] = {
            "mse": mse,
            "orig_mean": orig_px.mean(axis=0),
            "rend_mean": rend_px.mean(axis=0),
            "n_pixels": n_pixels,
        }

    return errors


def adjust_solid_color(poly, error_stats, damping):
    """Shift fill color toward the original mean color.

    For solid fills, adjusts the solid color directly.
    For gradient fills, shifts both gradient endpoint colors by the same correction.
    """
    if error_stats is None or error_stats["n_pixels"] < 5:
        return False

    # Correct directly toward original pixel mean (avoids rendered-overlap artifacts)
    current = np.array(poly["color"], dtype=float)
    target = error_stats["orig_mean"]
    correction = damping * (target - current)

    # Check if correction is meaningful (at least 1 unit in some channel)
    if np.max(np.abs(correction)) < 0.5:
        return False

    changed = False

    # Adjust solid fill color
    r, g, b = poly["color"]
    new_color = (
        int(np.clip(r + correction[0], 0, 255)),
        int(np.clip(g + correction[1], 0, 255)),
        int(np.clip(b + correction[2], 0, 255)),
    )
    if new_color != poly["color"]:
        poly["color"] = new_color
        changed = True

    # Also shift gradient endpoints if present
    grad = poly.get("gradient")
    if grad:
        cs = grad["color_start"]
        ce = grad["color_end"]
        new_cs = tuple(int(np.clip(cs[i] + correction[i], 0, 255)) for i in range(3))
        new_ce = tuple(int(np.clip(ce[i] + correction[i], 0, 255)) for i in range(3))
        if new_cs != cs or new_ce != ce:
            grad["color_start"] = new_cs
            grad["color_end"] = new_ce
            changed = True

    return changed


def try_upgrade_to_gradient(poly, error_stats, rgb, labels):
    """For solid polygons with high MSE, try upgrading to gradient."""
    if poly.get("gradient") is not None:
        return False
    if error_stats is None or error_stats["mse"] < 400:
        return False

    rid = poly.get("region_id")
    if rid is None:
        return False

    mask = (labels == rid).astype(np.uint8) * 255
    if cv2.countNonZero(mask) < 50:
        return False

    grad = fit_gradient(rgb, mask)
    if grad is None:
        return False

    grad = verify_gradient_improvement(rgb, mask, poly["color"], grad)
    if grad is not None:
        poly["gradient"] = grad
        return True
    return False


def refit_gradient(poly, error_stats, rgb, labels):
    """For gradient polygons with high MSE, re-fit the gradient."""
    if poly.get("gradient") is None:
        return False
    if error_stats is None or error_stats["mse"] < 200:
        return False

    rid = poly.get("region_id")
    if rid is None:
        return False

    mask = (labels == rid).astype(np.uint8) * 255
    if cv2.countNonZero(mask) < 50:
        return False

    new_grad = fit_gradient(rgb, mask)
    if new_grad is None:
        return False

    # Blend old and new gradient (0.5 factor) for stability
    old = poly["gradient"]
    blended = {
        "color_start": tuple(int((a + b) / 2) for a, b in zip(old["color_start"], new_grad["color_start"])),
        "color_end": tuple(int((a + b) / 2) for a, b in zip(old["color_end"], new_grad["color_end"])),
        "x1": (old["x1"] + new_grad["x1"]) / 2,
        "y1": (old["y1"] + new_grad["y1"]) / 2,
        "x2": (old["x2"] + new_grad["x2"]) / 2,
        "y2": (old["y2"] + new_grad["y2"]) / 2,
        "r2": new_grad["r2"],
    }

    verified = verify_gradient_improvement(rgb, mask, poly["color"], blended)
    if verified is not None:
        poly["gradient"] = verified
        return True
    return False


def split_high_error_polygon(poly, rgb, alpha, labels):
    """Split a high-error polygon into sub-polygons using k-means color clustering.

    Returns a list of new polygon dicts, or None if splitting doesn't help.
    """
    rid = poly.get("region_id")
    if rid is None:
        return None

    mask = (labels == rid)
    ys, xs = np.where(mask)
    n_pixels = len(ys)
    if n_pixels < 100:  # Too small to split
        return None

    # Get colors at these pixels
    colors = rgb[ys, xs].astype(np.float32)

    # K-means with k=2 (split into 2 sub-regions)
    from sklearn.cluster import KMeans
    kmeans = KMeans(n_clusters=2, n_init=3, max_iter=50, random_state=42)
    cluster_labels = kmeans.fit_predict(colors)

    # Check if the two clusters are actually different
    c0_mean = kmeans.cluster_centers_[0]
    c1_mean = kmeans.cluster_centers_[1]
    color_dist = np.linalg.norm(c0_mean - c1_mean)
    if color_dist < 15:  # Clusters too similar — don't split
        return None

    h, w = labels.shape
    new_polys = []

    for k in range(2):
        sub_mask = np.zeros((h, w), dtype=np.uint8)
        sub_idx = cluster_labels == k
        sub_ys, sub_xs = ys[sub_idx], xs[sub_idx]
        sub_mask[sub_ys, sub_xs] = 255

        area = cv2.countNonZero(sub_mask)
        if area < 30:
            continue

        # Morphological cleanup
        kernel = np.ones((3, 3), np.uint8)
        sub_mask = cv2.morphologyEx(sub_mask, cv2.MORPH_CLOSE, kernel, iterations=2)
        sub_mask = cv2.dilate(sub_mask, np.ones((2, 2), np.uint8), iterations=1)

        # Find contours
        contours, _ = cv2.findContours(sub_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        if not contours:
            continue

        contour = max(contours, key=cv2.contourArea)
        carea = cv2.contourArea(contour)
        if carea < 30:
            continue

        # Smooth + simplify
        sigma = 1.0 if carea < 200 else 1.5
        smoothed = gaussian_smooth_contour(contour, sigma=sigma)
        perim = cv2.arcLength(smoothed, True)
        approx = cv2.approxPolyDP(smoothed, 0.005 * perim, True)
        if len(approx) < 3:
            continue

        # Sample color
        color, sampled_alpha = sample_color_from_original(rgb, alpha, sub_mask)

        # Try gradient
        gradient = None
        if carea > 50:
            grad = fit_gradient(rgb, sub_mask)
            if grad:
                gradient = verify_gradient_improvement(rgb, sub_mask, color, grad)

        points = approx.reshape(-1, 2).tolist()
        M = cv2.moments(contour)
        cx = M["m10"] / M["m00"] if M["m00"] > 0 else np.mean([p[0] for p in points])
        cy = M["m01"] / M["m00"] if M["m00"] > 0 else np.mean([p[1] for p in points])

        # Compute LAB brightness
        lab_pixel = cv2.cvtColor(
            np.array([[list(color)]], dtype=np.uint8), cv2.COLOR_RGB2LAB
        )[0, 0]

        new_polys.append({
            "points": points,
            "color": color,
            "opacity": round(min(sampled_alpha, 1.0), 3),
            "area": carea,
            "gradient": gradient,
            "centroid": (cx, cy),
            "brightness": float(lab_pixel[0]),
            "region_id": rid,  # Keep same region_id (both sub-polys share it)
        })

    if len(new_polys) >= 2:
        return new_polys
    return None


def direct_optimize_colors(polygons, rgb, labels):
    """One-shot color optimization: set each polygon's fill to the mean of
    original pixels in its interior (using labels, not contour mask).
    No render needed — purely analytical. No oscillation.
    """
    kernel = np.ones((3, 3), np.uint8)
    n_adjusted = 0

    for poly in polygons:
        rid = poly.get("region_id")
        if rid is None:
            continue

        # Use labels mask, erode to get interior pixels
        full_mask = (labels == rid).astype(np.uint8) * 255
        eroded = cv2.erode(full_mask, kernel, iterations=3)
        if cv2.countNonZero(eroded) < 10:
            eroded = cv2.erode(full_mask, kernel, iterations=1)
        if cv2.countNonZero(eroded) < 5:
            eroded = full_mask

        ys, xs = np.where(eroded > 0)
        if len(ys) < 5:
            continue

        # Optimal solid color = trimmed mean of original interior pixels
        colors = rgb[ys, xs]
        n = len(colors)
        if n > 20:
            trim = max(1, n // 10)
            optimal = tuple(
                int(np.mean(np.sort(colors[:, ch])[trim:-trim]))
                for ch in range(3)
            )
        else:
            optimal = tuple(int(v) for v in np.median(colors, axis=0))

        if optimal != poly["color"]:
            poly["color"] = optimal
            n_adjusted += 1

        # For gradient polygons, also re-fit gradient from interior pixels
        if poly.get("gradient") and n > 50:
            inner_mask = np.zeros_like(full_mask)
            inner_mask[ys, xs] = 255
            new_grad = fit_gradient(rgb, inner_mask)
            if new_grad:
                verified = verify_gradient_improvement(rgb, inner_mask, optimal, new_grad)
                if verified:
                    poly["gradient"] = verified

    return n_adjusted


def adjust_stroke_widths(stroke_info, polygons, labels, orig_rgb, rendered_rgb, fg_mask):
    """Nudge stroke widths based on boundary brightness comparison."""
    gray_orig = cv2.cvtColor(orig_rgb, cv2.COLOR_RGB2GRAY).astype(float)
    gray_rend = cv2.cvtColor(rendered_rgb, cv2.COLOR_RGB2GRAY).astype(float)
    adjusted = 0

    for poly in polygons:
        rid = poly.get("region_id")
        if rid is None or rid not in stroke_info:
            continue

        mask = (labels == rid).astype(np.uint8) * 255
        dilated = cv2.dilate(mask, np.ones((5, 5), np.uint8), iterations=1)
        boundary = (dilated - mask) > 0

        bdy_pixels = boundary & fg_mask
        n = bdy_pixels.sum()
        if n < 10:
            continue

        orig_bdy_brightness = gray_orig[bdy_pixels].mean()
        rend_bdy_brightness = gray_rend[bdy_pixels].mean()

        # If rendered boundary is brighter than original → stroke too thin
        # If rendered boundary is darker than original → stroke too thick
        diff = orig_bdy_brightness - rend_bdy_brightness
        si = stroke_info[rid]
        if abs(diff) > 3:
            nudge = np.clip(diff * 0.02, -0.15, 0.15)
            new_width = np.clip(si["width"] + nudge, 0.5, 4.0)
            if abs(new_width - si["width"]) > 0.05:
                si["width"] = round(float(new_width), 1)
                adjusted += 1

    return adjusted


def _snapshot_state(polygons, stroke_info):
    """Deep copy polygon colors/gradients and stroke widths for rollback."""
    import copy
    poly_state = []
    for p in polygons:
        poly_state.append({
            "color": p["color"],
            "gradient": copy.deepcopy(p.get("gradient")),
        })
    stroke_state = {rid: {"width": si["width"]} for rid, si in stroke_info.items()}
    return poly_state, stroke_state


def _restore_state(polygons, stroke_info, poly_state, stroke_state):
    """Restore polygon colors/gradients and stroke widths from snapshot."""
    for p, s in zip(polygons, poly_state):
        p["color"] = s["color"]
        p["gradient"] = s["gradient"]
    for rid, ss in stroke_state.items():
        if rid in stroke_info:
            stroke_info[rid]["width"] = ss["width"]


def iterative_refine(polygons, stroke_info, rgb, alpha, labels,
                     width, height, output_path, max_iterations=15):
    """Iteratively refine polygon colors/gradients by comparing rendered SVG to original.

    Phase 1: Split high-error polygons (structural improvement)
    Phase 2: Color/gradient correction iterations (color refinement)
    """
    fg_mask = alpha > 200

    print(f"\n{'='*60}")
    print("Starting iterative refinement...")
    print(f"{'='*60}")

    # ── Phase 0: Direct color optimization (analytical, no render needed) ──
    n_optimized = direct_optimize_colors(polygons, rgb, labels)
    print(f"\n  Direct optimization: {n_optimized} polygon colors updated")

    # ── Phase 1: Polygon splitting (one-time structural improvement) ──
    svg = polygons_to_svg(polygons, width, height, stroke_info=stroke_info)
    with open(output_path, "w") as f:
        f.write(svg)
    rendered_rgb, _ = render_svg_to_array(output_path, width, height)

    psnr = compute_psnr(rgb, rendered_rgb, fg_mask)
    diff = np.abs(rgb[fg_mask].astype(float) - rendered_rgb[fg_mask].astype(float))
    within_20 = (diff.max(axis=1) <= 20).mean() * 100
    print(f"\n  Baseline: PSNR={psnr:.2f} dB, {within_20:.1f}% within 20 RGB")

    errors = compute_per_polygon_error(rgb, rendered_rgb, labels, polygons)
    indexed_errors = [(i, e) for i, e in enumerate(errors) if e is not None and e["n_pixels"] > 0]
    indexed_errors.sort(key=lambda x: -x[1]["mse"])

    to_remove = []
    to_add = []
    for idx, err in indexed_errors:
        if err["mse"] < 500 or err["n_pixels"] < 80:
            continue
        new_polys = split_high_error_polygon(polygons[idx], rgb, alpha, labels)
        if new_polys:
            to_remove.append(idx)
            to_add.extend(new_polys)

    for idx in sorted(to_remove, reverse=True):
        polygons.pop(idx)
    polygons.extend(to_add)

    if to_remove:
        print(f"  Split {len(to_remove)} polygons → {len(to_add)} sub-polygons "
              f"(total: {len(polygons)} polygons)")

    # ── Phase 2: Color/gradient correction iterations ───────────
    best_psnr = 0
    best_poly_state = None
    best_stroke_state = None
    stale_count = 0

    for iteration in range(max_iterations):
        # 1. Write SVG
        svg = polygons_to_svg(polygons, width, height, stroke_info=stroke_info)
        with open(output_path, "w") as f:
            f.write(svg)

        # 2. Render to PNG
        rendered_rgb, _ = render_svg_to_array(output_path, width, height)

        # 3. Compute PSNR
        psnr = compute_psnr(rgb, rendered_rgb, fg_mask)
        diff = np.abs(rgb[fg_mask].astype(float) - rendered_rgb[fg_mask].astype(float))
        within_20 = (diff.max(axis=1) <= 20).mean() * 100

        improvement = psnr - best_psnr if best_psnr > 0 else psnr
        print(f"\n  Iteration {iteration}: PSNR={psnr:.2f} dB "
              f"(delta={improvement:+.2f}), {within_20:.1f}% within 20 RGB")

        if psnr > best_psnr:
            best_psnr = psnr
            best_poly_state, best_stroke_state = _snapshot_state(polygons, stroke_info)
            stale_count = 0
        else:
            _restore_state(polygons, stroke_info, best_poly_state, best_stroke_state)
            stale_count += 1
            print(f"  Reverted to best state (PSNR={best_psnr:.2f})")

        if stale_count >= 3:
            print(f"  No improvement for {stale_count} iterations — stopping")
            break

        # 4. Per-polygon error (re-render from best if reverted)
        if stale_count > 0:
            svg = polygons_to_svg(polygons, width, height, stroke_info=stroke_info)
            with open(output_path, "w") as f:
                f.write(svg)
            rendered_rgb, _ = render_svg_to_array(output_path, width, height)

        errors = compute_per_polygon_error(rgb, rendered_rgb, labels, polygons)

        # 5. Sort by MSE, process top candidates
        indexed_errors = [(i, e) for i, e in enumerate(errors) if e is not None and e["n_pixels"] > 0]
        indexed_errors.sort(key=lambda x: -x[1]["mse"])
        frac = 0.5 if iteration < 3 else 0.25
        n_candidates = max(1, int(len(indexed_errors) * frac))
        candidates = indexed_errors[:n_candidates]

        # 6. Adjustments — focused on gradient upgrades (highest-value operation)
        # Direct optimization already set optimal solid colors, so skip color nudges.
        # Gradient refits cause oscillation, so skip those too.
        n_grad_upgrade = 0

        for idx, err in candidates:
            poly = polygons[idx]
            if try_upgrade_to_gradient(poly, err, rgb, labels):
                n_grad_upgrade += 1

        print(f"  Adjustments: {n_grad_upgrade} grad upgrades")

        if n_grad_upgrade == 0:
            print("  No more gradient upgrades possible — stopping")
            break

    # Restore best state and do final write
    if best_poly_state:
        _restore_state(polygons, stroke_info, best_poly_state, best_stroke_state)

    svg = polygons_to_svg(polygons, width, height, stroke_info=stroke_info)
    with open(output_path, "w") as f:
        f.write(svg)

    # Final quality report
    rendered_rgb, _ = render_svg_to_array(output_path, width, height)
    final_psnr = compute_psnr(rgb, rendered_rgb, fg_mask)
    diff = np.abs(rgb[fg_mask].astype(float) - rendered_rgb[fg_mask].astype(float))
    max_ch_diff = diff.max(axis=1)
    mean_diff = diff.mean()

    print(f"\n  Final quality:")
    print(f"    PSNR: {final_psnr:.2f} dB")
    print(f"    Mean pixel error: {mean_diff:.1f} RGB")
    for threshold in [5, 10, 20, 40]:
        pct = (max_ch_diff <= threshold).mean() * 100
        print(f"    Within {threshold:2d} RGB: {pct:.1f}%")
    print(f"{'='*60}\n")


# ── SVG generation ─────────────────────────────────────────────

def hex_color(r, g, b):
    return f"#{r:02x}{g:02x}{b:02x}"


def polygons_to_svg(polygons, width, height, stroke_info=None):
    """Generate compact SVG with sharp polygon edges (matches low-poly style)."""
    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
                 f' width="{width}" height="{height}">')

    # Z-order: larger & darker first (background), smaller & brighter on top
    polygons_sorted = sorted(polygons, key=lambda p: (
        -p["area"],
        p["brightness"],
    ))

    # First pass: collect gradient defs using userSpaceOnUse (absolute pixel coords)
    grad_defs = []
    grad_id = 0
    for poly in polygons_sorted:
        g = poly.get("gradient")
        if not g:
            continue
        poly["_grad_id"] = f"g{grad_id}"

        # Absolute pixel coordinates — avoids bounding-box rounding issues
        c1 = hex_color(*g["color_start"])
        c2 = hex_color(*g["color_end"])

        grad_defs.append(
            f'    <linearGradient id="g{grad_id}" gradientUnits="userSpaceOnUse" '
            f'x1="{g["x1"]:.1f}" y1="{g["y1"]:.1f}" '
            f'x2="{g["x2"]:.1f}" y2="{g["y2"]:.1f}">'
            f'<stop offset="0%" stop-color="{c1}"/>'
            f'<stop offset="100%" stop-color="{c2}"/>'
            f'</linearGradient>'
        )
        grad_id += 1

    if grad_defs:
        lines.append("  <defs>")
        lines.extend(grad_defs)
        lines.append("  </defs>")

    # Second pass: emit polygons with integer coordinates for compactness
    for poly in polygons_sorted:
        pts = poly["points"]
        opacity = poly["opacity"]
        if opacity < 0.01:
            continue

        # Integer coords — no precision loss at 1024x1024
        points_str = " ".join(f"{int(round(x))},{int(round(y))}" for x, y in pts)
        r, g, b = poly["color"]
        fill_hex = hex_color(r, g, b)

        has_grad = poly.get("_grad_id")
        if has_grad:
            fill_attr = f'url(#{poly["_grad_id"]})'
        else:
            fill_attr = fill_hex

        opacity_attr = f' fill-opacity="{opacity}"' if opacity < 0.99 else ""

        # For gradient fills, use the gradient for stroke too (no color mismatch at edges)
        # For solid fills, use matching solid stroke
        stroke_attr = fill_attr if has_grad else fill_hex

        # Gap-prevention stroke (thin, same color as fill)
        lines.append(
            f'  <polygon points="{points_str}" fill="{fill_attr}" '
            f'stroke="{stroke_attr}" stroke-width="0.8" '
            f'stroke-linejoin="round"{opacity_attr}/>'
        )

    # Second layer: dark outline strokes on top (drawn as polygon outlines)
    if stroke_info:
        for poly in polygons_sorted:
            rid = poly.get("region_id")
            if rid is None or rid not in stroke_info:
                continue

            pts = poly["points"]
            si = stroke_info[rid]
            points_str = " ".join(f"{int(round(x))},{int(round(y))}" for x, y in pts)
            sr, sg, sb = si["color"]
            s_hex = hex_color(sr, sg, sb)
            sw = si["width"]

            lines.append(
                f'  <polygon points="{points_str}" fill="none" '
                f'stroke="{s_hex}" stroke-width="{sw}" '
                f'stroke-linejoin="round"/>'
            )

    lines.append("</svg>")
    return "\n".join(lines) + "\n"


# ── Main pipeline ──────────────────────────────────────────────

def main():
    print(f"Loading {INPUT}...")
    rgb, alpha = load_image(INPUT)
    h, w = rgb.shape[:2]
    print(f"  Size: {w}x{h}")

    print("Detecting edges...")
    edges = detect_edges(rgb)
    edge_count = cv2.countNonZero(edges)
    print(f"  {edge_count} edge pixels")

    print("Running edge-aware SLIC segmentation...")
    labels, n_labels = slic_segmentation(rgb, alpha, edges, n_segments=3000)

    print("Computing region statistics...")
    mean_rgb, mean_lab, mean_alpha, counts, brightness = \
        compute_region_stats(labels, n_labels, rgb, alpha)

    print("Computing adjacency...")
    adj = compute_adjacency(labels, n_labels)

    print("Merging similar regions (LAB color space)...")
    labels, n_regions, colors, alphas, lab_colors = merge_regions(
        labels, n_labels, rgb, alpha, adj,
        mean_rgb, mean_lab, mean_alpha, counts, brightness,
        color_threshold=13.0, dark_threshold=45.0,
    )

    print("Extracting polygons...")
    polygons = extract_polygons(labels, n_regions, colors, alphas, lab_colors,
                                rgb, alpha)
    n_grad = sum(1 for p in polygons if p.get("gradient"))
    print(f"  {len(polygons)} polygons ({n_grad} gradients, "
          f"{len(polygons) - n_grad} solid)")

    print("Detecting outline strokes...")
    stroke_info = detect_strokes(rgb, alpha, labels, dark_threshold=65)

    print("Generating initial SVG...")
    svg = polygons_to_svg(polygons, w, h, stroke_info=stroke_info)

    with open(OUTPUT, "w") as f:
        f.write(svg)

    import os
    size_kb = os.path.getsize(OUTPUT) / 1024
    png_kb = os.path.getsize(INPUT) / 1024
    print(f"\nInitial result: {OUTPUT}")
    print(f"  SVG: {size_kb:.1f} KB ({len(polygons)} polygons, "
          f"{len(stroke_info)} with outlines)")
    print(f"  PNG: {png_kb:.1f} KB (original)")
    print(f"  Ratio: {size_kb/png_kb:.1%}")

    # Iterative refinement: render → compare → adjust → repeat
    iterative_refine(polygons, stroke_info, rgb, alpha, labels,
                     w, h, OUTPUT, max_iterations=10)

    size_kb = os.path.getsize(OUTPUT) / 1024
    n_grad = sum(1 for p in polygons if p.get("gradient"))
    print(f"Final SVG: {size_kb:.1f} KB ({len(polygons)} polygons, "
          f"{n_grad} gradients, {len(stroke_info)} outlines)")


if __name__ == "__main__":
    main()
