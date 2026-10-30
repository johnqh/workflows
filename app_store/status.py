#!/usr/bin/env python3
"""Generate a read-only submission-status dashboard across app_store configs.

Scans one or more app_store/ directories (filesystem only — no network, no
credentials) and emits a self-contained HTML page: for each app, which stores it
targets and how far each release step has progressed (localized text, captured
screenshots, composed screenshots, release build present).

Usage:
  status.py --out <file.html> <app_store_dir> [<app_store_dir> ...]
"""

import argparse
import html
import json
import os
import sys
from datetime import datetime, timezone

STEPS = ["localize", "screenshots", "compose", "build"]
STORE_KEYS = [("apple", "appleAppStore"), ("google", "googlePlay"), ("microsoft", "microsoftStore")]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def has_pngs(d):
    if not os.path.isdir(d):
        return False
    for root, _, files in os.walk(d):
        if any(f.lower().endswith(".png") for f in files):
            return True
    return False


def scan_app(app_store_dir):
    info = load(os.path.join(app_store_dir, "info.json")) or {}
    languages = load(os.path.join(app_store_dir, "languages.json")) or []
    screens = load(os.path.join(app_store_dir, "screens.json")) or {}

    project_dir = os.path.dirname(os.path.abspath(app_store_dir))
    pkg = load(os.path.join(project_dir, "package.json")) or {}
    version = pkg.get("version") or info.get("metadata", {}).get("version", "?")
    name = info.get("app", {}).get("name") or os.path.basename(project_dir)

    stores = [label for label, key in STORE_KEYS if info.get(key) is not None]

    # Devices across platforms.
    devices = []
    for platform, devs in screens.items():
        if isinstance(devs, dict):
            devices += list(devs.keys())

    info_dir = os.path.join(app_store_dir, "screenshots", "info")
    raw_dir = os.path.join(app_store_dir, "screenshots", "raw")
    store_dir = os.path.join(app_store_dir, "screenshots", "store")
    builds_rel = os.path.join(app_store_dir, "builds", "release")

    # localize: fraction of languages with a listing file.
    loc_done = sum(
        1 for lang in languages
        if os.path.isfile(os.path.join(info_dir, lang, "info.json"))
    )
    loc_total = len(languages)

    # screenshots (raw) and compose (store): any PNGs present.
    raw_done = has_pngs(raw_dir)
    store_done = has_pngs(store_dir)

    # build: any release artifact present.
    artifacts = []
    if os.path.isdir(builds_rel):
        for root, _, files in os.walk(builds_rel):
            for f in files:
                if f.endswith((".ipa", ".aab", ".msixupload", ".appxupload")):
                    artifacts.append(f)
    has_archive = os.path.isdir(builds_rel) and any(
        d.endswith(".xcarchive") for d in os.listdir(builds_rel)
    ) if os.path.isdir(builds_rel) else False

    creds = {
        "env": os.path.isfile(os.path.join(app_store_dir, ".env")),
        "apple_key": os.path.isfile(os.path.join(app_store_dir, ".keys", "apple.p8")),
        "google_key": os.path.isfile(os.path.join(app_store_dir, ".keys", "google-play.json")),
    }

    return {
        "name": name,
        "version": version,
        "dir": app_store_dir,
        "stores": stores,
        "languages": loc_total,
        "devices": devices,
        "status": {
            "localize": ("full" if loc_done == loc_total and loc_total else
                         "partial" if loc_done else "none", f"{loc_done}/{loc_total}"),
            "screenshots": ("full" if raw_done else "none", "captured" if raw_done else "—"),
            "compose": ("full" if store_done else "none", "composed" if store_done else "—"),
            "build": ("full" if artifacts else "partial" if has_archive else "none",
                      ", ".join(sorted(set(os.path.splitext(a)[1] for a in artifacts))) or
                      ("archive" if has_archive else "—")),
        },
        "creds": creds,
    }


CELL = {"full": "#1a7f37", "partial": "#9a6700", "none": "#8c959f"}
GLYPH = {"full": "●", "partial": "◐", "none": "○"}


def render(apps):
    rows = []
    for a in apps:
        store_badges = " ".join(
            f'<span class="badge">{s}</span>' for s in a["stores"]
        ) or '<span class="badge dim">none</span>'
        cells = []
        for step in STEPS:
            state, detail = a["status"][step]
            cells.append(
                f'<td class="cell"><span style="color:{CELL[state]}">{GLYPH[state]}</span>'
                f'<span class="detail">{html.escape(detail)}</span></td>'
            )
        creds = a["creds"]
        cred_txt = []
        if not creds["env"]:
            cred_txt.append("no .env")
        if "apple" in a["stores"] and not creds["apple_key"]:
            cred_txt.append("no apple.p8")
        if "google" in a["stores"] and not creds["google_key"]:
            cred_txt.append("no google key")
        cred_html = (
            f'<span class="warn">{html.escape(", ".join(cred_txt))}</span>'
            if cred_txt else '<span class="ok">ready</span>'
        )
        rows.append(
            f'<tr><td class="app"><b>{html.escape(a["name"])}</b>'
            f'<span class="ver">v{html.escape(str(a["version"]))}</span><br>'
            f'<span class="dim small">{html.escape(a["dir"])}</span></td>'
            f'<td>{store_badges}</td>'
            f'<td class="num">{len(a["devices"])}d · {a["languages"]}lang</td>'
            + "".join(cells)
            + f'<td>{cred_html}</td></tr>'
        )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>App Store Status</title>
<style>
  :root {{ --bg:#fff; --fg:#1f2328; --dim:#656d76; --line:#d0d7de; --card:#f6f8fa; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme=light]) {{
    --bg:#0d1117; --fg:#e6edf3; --dim:#8b949e; --line:#30363d; --card:#161b22; }} }}
  body {{ background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,system-ui,sans-serif;
         margin:0; padding:24px 16px; }}
  h1 {{ font-size:20px; margin:0 0 4px; }}
  .sub {{ color:var(--dim); margin:0 0 20px; }}
  table {{ border-collapse:collapse; width:100%; max-width:1100px; }}
  th,td {{ text-align:left; padding:10px 12px; border-bottom:1px solid var(--line); vertical-align:top; }}
  th {{ font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--dim); }}
  .app .ver {{ color:var(--dim); margin-left:8px; font-weight:400; }}
  .small {{ font-size:11px; }} .dim {{ color:var(--dim); }}
  .num {{ color:var(--dim); white-space:nowrap; }}
  .cell {{ text-align:center; }} .cell span:first-child {{ font-size:16px; }}
  .detail {{ display:block; font-size:11px; color:var(--dim); }}
  .badge {{ display:inline-block; background:var(--card); border:1px solid var(--line);
            border-radius:999px; padding:1px 8px; font-size:12px; margin:1px; }}
  .badge.dim {{ color:var(--dim); }}
  .ok {{ color:#1a7f37; }} .warn {{ color:#9a6700; }}
  .legend {{ margin-top:16px; color:var(--dim); font-size:12px; }}
</style></head>
<body>
  <h1>App Store Submission Status</h1>
  <p class="sub">{len(apps)} app(s) · generated {generated} · filesystem scan (no live store query)</p>
  <table>
    <thead><tr>
      <th>App</th><th>Stores</th><th>Matrix</th>
      <th>Localize</th><th>Screens</th><th>Compose</th><th>Build</th><th>Creds</th>
    </tr></thead>
    <tbody>{"".join(rows)}</tbody>
  </table>
  <p class="legend">● done &nbsp; ◐ partial / archive-only &nbsp; ○ not started.
     Steps map to <code>appstore localize / screenshots / compose / build</code>.</p>
</body></html>"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("dirs", nargs="+")
    args = p.parse_args()

    apps = []
    for d in args.dirs:
        if os.path.isfile(os.path.join(d, "info.json")):
            apps.append(scan_app(d))
        else:
            print(f"  skip {d} (no info.json)", file=sys.stderr)
    apps.sort(key=lambda a: a["name"].lower())

    with open(args.out, "w") as f:
        f.write(render(apps))
    print(f"Wrote {args.out} ({len(apps)} apps).")


if __name__ == "__main__":
    main()
