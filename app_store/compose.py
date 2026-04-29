#!/usr/bin/env python3
"""
Compose store-ready screenshots from raw captures.

Takes raw device screenshots and composites them with:
  - A gradient background (brand colors)
  - Localized title and subtitle text
  - A device frame (from PNG assets in frames/, with synthetic fallback)

Usage:
  compose.py --app-store-dir <path> [options]

Options:
  --app-store-dir <path>  Path to app_store/ directory (required).
  --lang <code>           Process single language (default: all from languages.json).
  --device <key>          Process single device (default: all from screens.json).
  --seq <n>               Process single sequence number (default: all found in raw/).
  --frames-dir <path>     Path to device frame PNGs (default: app_store/frames/).
  --force                 Overwrite existing output files.
  --dry-run               Print actions without compositing.
"""

import argparse
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ── Brand colors ────────────────────────────────────────────────────────────

# Named color palettes: (dark_top, bright_bottom) — tasteful, not pure/neon
COLOR_PALETTES = {
    "blue":    ((30, 58, 138),   (59, 130, 246)),   # deep navy → sky blue
    "red":     ((127, 29, 29),   (220, 80, 70)),    # dark crimson → warm red
    "orange":  ((120, 53, 15),   (234, 146, 50)),   # burnt umber → warm amber
    "green":   ((6, 78, 59),     (34, 166, 109)),   # forest → seafoam
    "purple":  ((76, 29, 120),   (147, 85, 210)),   # deep plum → soft violet
    "teal":    ((15, 70, 80),    (45, 170, 180)),   # dark teal → ocean
    "pink":    ((120, 30, 70),   (220, 100, 150)),   # dark rose → blush
    "slate":   ((30, 41, 59),    (100, 116, 139)),   # charcoal → warm slate
}
DEFAULT_COLOR = "blue"

TEXT_COLOR = (255, 255, 255, 255)
TEXT_COLOR_SUB = (255, 255, 255, 200)
SHADOW_COLOR = (0, 0, 0, 100)

BEZEL_COLOR = (26, 26, 26)
BEZEL_HIGHLIGHT = (50, 50, 50)

# ── Font loading ────────────────────────────────────────────────────────────

AVENIR_NEXT = "/System/Library/Fonts/Avenir Next.ttc"
AVENIR_HEAVY_INDEX = 8
AVENIR_DEMIBOLD_INDEX = 2

# Arial Unicode covers Arabic, CJK, Thai, Cyrillic, Ukrainian, etc.
ARIAL_UNICODE = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"

FALLBACK_FONTS = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]

# Languages that need a Unicode font instead of Avenir Next
NON_LATIN_LANGUAGES = {"ar", "ja", "ko", "ru", "th", "uk", "vi", "zh", "zh-hant", "zh-Hant"}


def load_font(size, weight="heavy", lang=None):
    """Load a font at the given size. Weight: 'heavy' or 'demibold'. Uses Arial Unicode for non-Latin scripts."""
    if lang and lang in NON_LATIN_LANGUAGES:
        if os.path.exists(ARIAL_UNICODE):
            return ImageFont.truetype(ARIAL_UNICODE, size)
    index = AVENIR_DEMIBOLD_INDEX if weight == "demibold" else AVENIR_HEAVY_INDEX
    if os.path.exists(AVENIR_NEXT):
        return ImageFont.truetype(AVENIR_NEXT, size, index=index)
    for fb in FALLBACK_FONTS:
        if os.path.exists(fb):
            return ImageFont.truetype(fb, size)
    return ImageFont.load_default()


def prepare_text(text, lang=None):
    """Reshape and reorder text for proper rendering (Arabic RTL, etc.)."""
    if lang == "ar":
        try:
            import arabic_reshaper
            from bidi.algorithm import get_display
            reshaped = arabic_reshaper.reshape(text)
            return get_display(reshaped)
        except ImportError:
            pass
    return text


# ── Device configurations ───────────────────────────────────────────────────

class DeviceConfig:
    def __init__(self, key, canvas_w, canvas_h):
        self.key = key
        self.canvas_w = canvas_w
        self.canvas_h = canvas_h
        self.is_landscape = canvas_w > canvas_h

    @property
    def is_phone(self):
        return "phone" in self.key or "iphone" in self.key

    @property
    def is_desktop(self):
        return "macos" in self.key or "desktop" in self.key

    @property
    def is_tablet(self):
        return "ipad" in self.key or "tablet" in self.key or self.is_desktop


# ── Frame loading ───────────────────────────────────────────────────────────

def load_frame_config(frames_dir):
    """Load frames.json config mapping device keys to frame files + screen coords."""
    config_path = os.path.join(frames_dir, "frames.json")
    if not os.path.exists(config_path):
        return {}
    with open(config_path) as f:
        data = json.load(f)
    return data.get("frames", {})


def build_framed_device(screenshot, frame_img, screen_origin, screen_size):
    """
    Place screenshot behind a frame PNG.

    The frame has a transparent screen area. We create a canvas the size of the frame,
    paste the screenshot at the screen position, then overlay the frame on top.
    """
    fw, fh = frame_img.size
    sx, sy = screen_origin
    sw, sh = screen_size

    # Scale the screenshot to fill the screen area
    raw_w, raw_h = screenshot.size
    scale = max(sw / raw_w, sh / raw_h)
    scaled_w = int(raw_w * scale)
    scaled_h = int(raw_h * scale)
    scaled_shot = screenshot.resize((scaled_w, scaled_h), Image.LANCZOS)

    # Center the scaled screenshot within the screen area
    offset_x = sx + (sw - scaled_w) // 2
    offset_y = sy + (sh - scaled_h) // 2

    # Build: screenshot layer → frame overlay
    canvas = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    canvas.paste(scaled_shot, (offset_x, offset_y))
    canvas = Image.alpha_composite(canvas, frame_img)

    # Add drop shadow behind the device
    shadow_blur = max(int(min(fw, fh) * 0.01), 6)
    shadow_pad = shadow_blur * 3
    shadow_offset = max(int(min(fw, fh) * 0.004), 3)

    total_w = fw + shadow_pad * 2
    total_h = fh + shadow_pad * 2

    # Create shadow from frame's opaque outline
    shadow = Image.new("RGBA", (total_w, total_h), (0, 0, 0, 0))
    # Use the frame alpha as a shadow mask
    frame_alpha = frame_img.getchannel("A")
    shadow_layer = Image.new("RGBA", (fw, fh), (0, 0, 0, 50))
    shadow_layer.putalpha(frame_alpha)
    shadow.paste(shadow_layer, (shadow_pad + shadow_offset, shadow_pad + shadow_offset))
    shadow = shadow.filter(ImageFilter.GaussianBlur(shadow_blur))

    # Composite: shadow → framed device
    result = shadow.copy()
    result.paste(canvas, (shadow_pad, shadow_pad), canvas)

    return result


# ── Synthetic device frame (fallback) ───────────────────────────────────────

def draw_synthetic_frame(screenshot, config):
    """Draw a simple synthetic device frame when no PNG frame is available."""
    sw, sh = screenshot.size

    if config.is_phone:
        bx, bt, bb = max(int(sw * 0.025), 8), max(int(sh * 0.020), 12), max(int(sh * 0.020), 12)
        corner_r, screen_r = max(int(sw * 0.06), 20), max(int(sw * 0.04), 14)
    else:
        bx, bt, bb = max(int(sw * 0.018), 8), max(int(sh * 0.018), 10), max(int(sh * 0.018), 10)
        corner_r, screen_r = max(int(sw * 0.03), 16), max(int(sw * 0.02), 10)

    dw, dh = sw + 2 * bx, sh + bt + bb
    shadow_offset = max(int(min(dw, dh) * 0.005), 4)
    shadow_blur = max(int(min(dw, dh) * 0.012), 8)
    shadow_pad = shadow_blur * 2 + shadow_offset
    total_w, total_h = dw + shadow_pad * 2, dh + shadow_pad * 2

    # Shadow
    shadow = Image.new("RGBA", (total_w, total_h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [(shadow_pad + shadow_offset, shadow_pad + shadow_offset),
         (shadow_pad + dw - 1 + shadow_offset, shadow_pad + dh - 1 + shadow_offset)],
        corner_r, fill=(0, 0, 0, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(shadow_blur))

    # Device body
    device = Image.new("RGBA", (total_w, total_h), (0, 0, 0, 0))
    dd = ImageDraw.Draw(device)
    dd.rounded_rectangle(
        [(shadow_pad, shadow_pad), (shadow_pad + dw - 1, shadow_pad + dh - 1)],
        corner_r, fill=(*BEZEL_COLOR, 255))
    dd.rounded_rectangle(
        [(shadow_pad + 1, shadow_pad + 1), (shadow_pad + dw - 2, shadow_pad + dh - 2)],
        corner_r - 1, outline=(*BEZEL_HIGHLIGHT, 80), width=1)

    # Screenshot with rounded corners
    rounded_shot = screenshot.copy().convert("RGBA")
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), (sw - 1, sh - 1)], screen_r, fill=255)
    rounded_shot.putalpha(mask)

    result = Image.alpha_composite(shadow, device)
    result.paste(rounded_shot, (shadow_pad + bx, shadow_pad + bt), rounded_shot)
    return result


# ── Gradient background ────────────────────────────────────────────────────

def make_gradient(width, height, color_name=None):
    """Create a vertical gradient background using a named color palette."""
    top, bottom = COLOR_PALETTES.get(color_name or DEFAULT_COLOR, COLOR_PALETTES[DEFAULT_COLOR])
    img = Image.new("RGBA", (width, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        t = y / max(height - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        draw.line([(0, y), (width, y)], fill=(r, g, b, 255))
    return img


# ── Background textures ───────────────────────────────────────────────────

def _texture_diagonal_lines(width, height, opacity=18):
    """Subtle diagonal lines pattern."""
    tex = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tex)
    spacing = max(int(min(width, height) * 0.04), 40)
    line_w = max(int(spacing * 0.15), 2)
    color = (255, 255, 255, opacity)
    for offset in range(-max(width, height), max(width, height) * 2, spacing):
        draw.line([(offset, 0), (offset + height, height)], fill=color, width=line_w)
    return tex


def _texture_dots(width, height, opacity=20):
    """Grid of soft dots."""
    tex = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tex)
    spacing = max(int(min(width, height) * 0.06), 60)
    radius = max(int(spacing * 0.08), 3)
    color = (255, 255, 255, opacity)
    for y in range(spacing // 2, height, spacing):
        for x in range(spacing // 2, width, spacing):
            draw.ellipse([(x - radius, y - radius), (x + radius, y + radius)], fill=color)
    return tex


def _texture_circles(width, height, opacity=14):
    """Concentric circles radiating from bottom-right."""
    tex = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tex)
    cx, cy = int(width * 0.85), int(height * 0.85)
    max_r = int(math.hypot(width, height) * 0.9)
    spacing = max(int(min(width, height) * 0.06), 60)
    line_w = max(int(spacing * 0.1), 2)
    color = (255, 255, 255, opacity)
    for r in range(spacing, max_r, spacing):
        draw.ellipse([(cx - r, cy - r), (cx + r, cy + r)], outline=color, width=line_w)
    return tex


def _texture_waves(width, height, opacity=16):
    """Horizontal wavy lines."""
    tex = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tex)
    spacing = max(int(min(width, height) * 0.07), 70)
    amplitude = spacing * 0.3
    line_w = max(int(spacing * 0.1), 2)
    color = (255, 255, 255, opacity)
    for base_y in range(spacing // 2, height + spacing, spacing):
        points = []
        for x in range(0, width + 4, 4):
            y = base_y + amplitude * math.sin(x * 2 * math.pi / (spacing * 4))
            points.append((x, y))
        if len(points) >= 2:
            draw.line(points, fill=color, width=line_w)
    return tex


TEXTURE_FUNCTIONS = [
    _texture_diagonal_lines,
    _texture_dots,
    _texture_circles,
    _texture_waves,
]


def make_background(width, height, seq=1, color_name=None):
    """Create gradient background with a per-screenshot texture overlay."""
    bg = make_gradient(width, height, color_name)
    texture_fn = TEXTURE_FUNCTIONS[(seq - 1) % len(TEXTURE_FUNCTIONS)]
    texture = texture_fn(width, height)
    return Image.alpha_composite(bg, texture)


# ── Text rendering ──────────────────────────────────────────────────────────

def wrap_text(text, font, max_width, draw):
    """Wrap text to fit within max_width. Returns list of lines."""
    words = text.split()
    if not words:
        return [""]
    lines = []
    current = words[0]
    for word in words[1:]:
        test = current + " " + word
        bbox = draw.textbbox((0, 0), test, font=font)
        if bbox[2] - bbox[0] <= max_width:
            current = test
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def draw_text_block(canvas, title, subtitle, area, config, lang=None):
    """Draw title and subtitle text within the given area (x, y, w, h) with word wrapping."""
    ax, ay, aw, ah = area

    title = prepare_text(title, lang)
    subtitle = prepare_text(subtitle, lang)

    title_size = int(config.canvas_h * 0.065) if config.is_landscape else int(config.canvas_h * 0.048)
    sub_size = int(config.canvas_h * 0.038) if config.is_landscape else int(config.canvas_h * 0.028)

    title_font = load_font(title_size, "heavy", lang)
    sub_font = load_font(sub_size, "demibold", lang)

    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Wrap text to fit area width (with some padding)
    text_max_w = int(aw * 0.9)
    title_lines = wrap_text(title, title_font, text_max_w, draw)
    sub_lines = wrap_text(subtitle, sub_font, text_max_w, draw)

    # Measure line heights
    title_line_h = draw.textbbox((0, 0), "Ag", font=title_font)[3]
    sub_line_h = draw.textbbox((0, 0), "Ag", font=sub_font)[3]
    title_spacing = int(title_line_h * 0.15)
    sub_spacing = int(sub_line_h * 0.1)

    total_title_h = len(title_lines) * title_line_h + (len(title_lines) - 1) * title_spacing
    total_sub_h = len(sub_lines) * sub_line_h + (len(sub_lines) - 1) * sub_spacing
    gap = int(title_line_h * 0.35)
    total_h = total_title_h + gap + total_sub_h

    # Vertical start position
    if config.is_landscape:
        start_y = ay  # top-aligned for tablets
    else:
        start_y = ay + int(ah * 0.15)

    shadow_off = max(int(title_size * 0.02), 2)
    cur_y = start_y

    # Draw title lines
    for line in title_lines:
        line_bbox = draw.textbbox((0, 0), line, font=title_font)
        line_w = line_bbox[2] - line_bbox[0]
        if config.is_landscape:
            lx = ax
        else:
            lx = ax + (aw - line_w) // 2
        draw.text((lx + shadow_off, cur_y + shadow_off), line, font=title_font, fill=SHADOW_COLOR)
        draw.text((lx, cur_y), line, font=title_font, fill=TEXT_COLOR)
        cur_y += title_line_h + title_spacing

    cur_y = start_y + total_title_h + gap

    # Draw subtitle lines
    for line in sub_lines:
        line_bbox = draw.textbbox((0, 0), line, font=sub_font)
        line_w = line_bbox[2] - line_bbox[0]
        if config.is_landscape:
            lx = ax
        else:
            lx = ax + (aw - line_w) // 2
        draw.text((lx + shadow_off, cur_y + shadow_off), line, font=sub_font, fill=SHADOW_COLOR)
        draw.text((lx, cur_y), line, font=sub_font, fill=TEXT_COLOR_SUB)
        cur_y += sub_line_h + sub_spacing

    return Image.alpha_composite(canvas, overlay)


# ── Main composition ────────────────────────────────────────────────────────

def round_screenshot(screenshot, radius):
    """Apply rounded corners to a screenshot."""
    shot = screenshot.copy().convert("RGBA")
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (shot.size[0] - 1, shot.size[1] - 1)], radius, fill=255)
    shot.putalpha(mask)
    return shot


def add_shadow(img, blur=12, offset=6, opacity=50):
    """Add a drop shadow behind an RGBA image."""
    pad = blur * 3 + offset
    w, h = img.size
    total_w, total_h = w + pad * 2, h + pad * 2

    shadow = Image.new("RGBA", (total_w, total_h), (0, 0, 0, 0))
    shadow_shape = Image.new("RGBA", (w, h), (0, 0, 0, opacity))
    shadow_shape.putalpha(img.getchannel("A"))
    shadow.paste(shadow_shape, (pad + offset, pad + offset))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))

    result = shadow.copy()
    result.paste(img, (pad, pad), img)
    return result


def compose_screenshot(raw_path, title, subtitle, config, frames_dir, frame_configs, seq=1, color_name=None, lang=None):
    """Compose a single store-ready screenshot."""
    raw = Image.open(raw_path).convert("RGBA")
    cw, ch = config.canvas_w, config.canvas_h
    rw, rh = raw.size

    # 1. Background gradient with per-screenshot texture
    bg = make_background(cw, ch, seq, color_name)

    # 2. Round the raw screenshot corners and add shadow
    #    Desktop raw screenshots already have window chrome with transparency —
    #    skip rounding/shadow and let the alpha composite onto the gradient.
    if config.is_desktop:
        shadowed = raw
    else:
        radius_pct = 0.08 if config.is_phone else 0.04
        corner_r = max(int(min(rw, rh) * radius_pct), 16)
        shadow_blur = max(int(min(rw, rh) * 0.01), 8)
        rounded = round_screenshot(raw, corner_r)
        shadowed = add_shadow(rounded, blur=shadow_blur, offset=shadow_blur // 2, opacity=50)

    # 3. Layout
    sw, sh = shadowed.size

    if config.is_landscape:
        # Tablets/desktop: text at top-left, large tilted screenshot toward bottom-right
        text_area = (int(cw * 0.04), int(ch * 0.06), int(cw * 0.40), int(ch * 0.40))

        shot_max_h = int(ch * 1.0) if config.is_desktop else int(ch * 0.95)
        scale = shot_max_h / sh
        scaled = shadowed.resize((int(sw * scale), int(sh * scale)), Image.LANCZOS)

        # Rotate 15 degrees counter-clockwise for a lively look
        rotated = scaled.rotate(15, resample=Image.BICUBIC, expand=True)
        rw, rh = rotated.size

        # Position toward bottom-right, allow bleed off edges
        dx = cw - int(rw * 0.82)
        dy = ch - int(rh * 0.78)
    else:
        # Phones: screenshot bleeds off bottom
        shot_max_w = int(cw * 0.88)
        scale = shot_max_w / sw
        scaled = shadowed.resize((int(sw * scale), int(sh * scale)), Image.LANCZOS)
        nsw, nsh = scaled.size

        text_area = (0, int(ch * 0.02), cw, int(ch * 0.20))

        dx = (cw - nsw) // 2
        dy = int(ch * 0.24)

    # 4. Paste screenshot onto background
    shot_img = rotated if config.is_landscape else scaled
    bg.paste(shot_img, (dx, dy), shot_img)

    # 5. Draw text
    bg = draw_text_block(bg, title, subtitle, text_area, config, lang=lang)

    return bg


# ── Processing loop ─────────────────────────────────────────────────────────

def process_all(app_store_dir, languages, device_keys, seq_filter, frames_dir, force, dry_run, color_name=None):
    screens_json = os.path.join(app_store_dir, "screens.json")
    with open(screens_json) as f:
        screens_config = json.load(f)

    all_devices = {}
    for platform, devices in screens_config.items():
        for key, info in devices.items():
            # Prefer store_resolution (composed output size) over resolution (raw capture size)
            res = info.get("store_resolution", info.get("resolution", ""))
            if "x" in res:
                w, h = res.split("x")
                all_devices[key] = (int(w), int(h))

    frame_configs = load_frame_config(frames_dir)

    total = 0
    composed = 0

    for lang in languages:
        # Try multiple locations for per-language screen text
        lang_screens_path = os.path.join(app_store_dir, "screenshots", "info", lang, "screens.json")
        if not os.path.exists(lang_screens_path):
            lang_screens_path = os.path.join(app_store_dir, lang, "screens.json")
        if not os.path.exists(lang_screens_path):
            # Try case-insensitive match (e.g. zh-Hant vs zh-hant)
            info_dir = os.path.join(app_store_dir, "screenshots", "info")
            if os.path.isdir(info_dir):
                for d in os.listdir(info_dir):
                    if d.lower() == lang.lower():
                        candidate = os.path.join(info_dir, d, "screens.json")
                        if os.path.exists(candidate):
                            lang_screens_path = candidate
                            break
        if not os.path.exists(lang_screens_path):
            print(f"  Warning: screens.json not found for '{lang}', skipping.")
            continue
        with open(lang_screens_path) as f:
            screens_text = json.load(f)

        for device_key in device_keys:
            if device_key not in all_devices:
                print(f"  Warning: device '{device_key}' not in screens.json, skipping.")
                continue

            # Try multiple raw directory layouts
            raw_dir = os.path.join(app_store_dir, "screenshots", "raw", device_key, lang)
            if not os.path.isdir(raw_dir):
                raw_dir = os.path.join(app_store_dir, lang, "screenshots", "raw", device_key)
            out_dir = os.path.join(app_store_dir, "screenshots", "store", device_key, lang)

            if not os.path.isdir(raw_dir):
                print(f"  Warning: raw dir not found: {raw_dir}, skipping.")
                continue

            raw_files = sorted(
                [f for f in os.listdir(raw_dir) if f.endswith(".png")],
                key=lambda x: int(x.replace(".png", "")) if x.replace(".png", "").isdigit() else 0,
            )
            if not raw_files:
                print(f"  Warning: no raw PNGs in {raw_dir}, skipping.")
                continue

            canvas_w, canvas_h = all_devices[device_key]
            config = DeviceConfig(device_key, canvas_w, canvas_h)

            for raw_file in raw_files:
                seq = int(raw_file.replace(".png", ""))
                if seq_filter is not None and seq != seq_filter:
                    continue

                total += 1

                if seq - 1 >= len(screens_text):
                    print(f"  Warning: no text for seq {seq} in {lang}/screens.json, skipping.")
                    continue

                text_entry = screens_text[seq - 1]
                if text_entry is None:
                    # Fall back to English text if translation is missing
                    en_path = os.path.join(app_store_dir, "screenshots", "info", "en", "screens.json")
                    if not os.path.exists(en_path):
                        en_path = os.path.join(app_store_dir, "en", "screens.json")
                    if os.path.exists(en_path) and seq - 1 < len(json.load(open(en_path))):
                        text_entry = json.load(open(en_path))[seq - 1]
                    if text_entry is None:
                        text_entry = {}
                title = text_entry.get("title", "")
                subtitle = text_entry.get("text", "")
                raw_path = os.path.join(raw_dir, raw_file)
                out_path = os.path.join(out_dir, raw_file)

                if not force and os.path.exists(out_path):
                    print(f"  [{lang}] {device_key}/{raw_file} — exists, skipping (use --force).")
                    continue

                if dry_run:
                    print(f"  [{lang}] {device_key}/{raw_file} — would compose: \"{title}\" / \"{subtitle}\"")
                    composed += 1
                    continue

                print(f"  [{lang}] {device_key}/{raw_file} — composing...")
                os.makedirs(out_dir, exist_ok=True)
                result = compose_screenshot(raw_path, title, subtitle, config, frames_dir, frame_configs, seq=seq, color_name=color_name, lang=lang)
                result.convert("RGB").save(out_path, "PNG", optimize=True)
                composed += 1

    print(f"\nDone. {composed}/{total} screenshots composed.")


# ── CLI ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Compose store-ready screenshots.")
    parser.add_argument("--app-store-dir", required=True, help="Path to app_store/ directory.")
    parser.add_argument("--lang", default=None, help="Single language code to process.")
    parser.add_argument("--device", default=None, help="Single device key to process.")
    parser.add_argument("--seq", type=int, default=None, help="Single sequence number to process.")
    parser.add_argument("--frames-dir", default=None, help="Path to device frame PNGs.")
    parser.add_argument("--color", default=None,
                        choices=list(COLOR_PALETTES.keys()),
                        help="Background color theme (default: blue).")
    parser.add_argument("--force", action="store_true", help="Overwrite existing output files.")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without compositing.")
    args = parser.parse_args()

    app_store_dir = args.app_store_dir
    with open(os.path.join(app_store_dir, "languages.json")) as f:
        all_languages = json.load(f)
    languages = [args.lang] if args.lang else all_languages

    with open(os.path.join(app_store_dir, "screens.json")) as f:
        screens_config = json.load(f)
    all_device_keys = [k for p in screens_config.values() for k in p]
    device_keys = [args.device] if args.device else all_device_keys

    frames_dir = args.frames_dir or os.path.join(app_store_dir, "frames")

    color_name = args.color or DEFAULT_COLOR

    print(f"Languages: {', '.join(languages)}")
    print(f"Devices:   {', '.join(device_keys)}")
    print(f"Color:     {color_name}")
    print(f"Frames:    {frames_dir}")
    print()

    process_all(app_store_dir, languages, device_keys, args.seq, frames_dir, args.force, args.dry_run, color_name)


if __name__ == "__main__":
    main()
