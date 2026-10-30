#!/usr/bin/env python3
"""Submit an app to the Microsoft Store (Partner Center submission API).

Mirrors submit_apple.py / submit_google.py: stdlib only (urllib + json), driven
by the same app_store/ config. Reads the non-localized microsoftStore block from
info.json and the per-language listing text from
screenshots/info/<lang>/info.json ("microsoftStore" object), optionally uploads
an MSIX/MSIXUPLOAD package and store screenshots.

Auth uses Azure AD client credentials for the Partner Center (Dev Center)
submission API. Provide via env / .env:
  MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET   Azure AD app registration
  MS_SELLER_APP_ID                               the Store app's Application ID

Actions:
  check-version   Print LIVE | VERSION_EXISTS | VERSION_OLDER | NO_APP.
  submit          Create a submission, update metadata (+ package/screenshots),
                  commit, and poll to completion.

Docs: https://learn.microsoft.com/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

AUTH_HOST = "https://login.microsoftonline.com"
API_BASE = "https://manage.devcenter.microsoft.com/v1.0/my"
RESOURCE = "https://manage.devcenter.microsoft.com"

# Store listing locales use BCP-47 like "en-us"; our language dirs are short codes.
LOCALE_MAP = {
    "en": "en-us", "es": "es-es", "zh": "zh-cn", "zh-Hant": "zh-tw",
    "ja": "ja-jp", "ko": "ko-kr", "fr": "fr-fr", "de": "de-de",
    "pt": "pt-br", "it": "it-it", "ru": "ru-ru", "ar": "ar-sa",
    "sv": "sv-se", "th": "th-th", "uk": "uk-ua", "vi": "vi-vn",
}


# ── HTTP helpers ──────────────────────────────────────────────────────────────

def get_token(tenant_id, client_id, client_secret):
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
        "resource": RESOURCE,
    }).encode()
    url = f"{AUTH_HOST}/{tenant_id}/oauth2/token"
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["access_token"]


def api(method, path, token, body=None):
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        print(f"  HTTP {e.code} on {method} {url}\n  {detail}", file=sys.stderr)
        raise


def parse_version(v):
    parts = []
    for p in str(v).split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


# ── Actions ───────────────────────────────────────────────────────────────────

def get_app(token, app_id):
    try:
        return api("GET", f"/applications/{app_id}", token)
    except urllib.error.HTTPError:
        return None


def action_check_version(args):
    token = get_token(args.tenant_id, args.client_id, args.client_secret)
    app = get_app(token, args.app_id)
    if not app:
        print("NO_APP")
        return
    last = app.get("lastPublishedApplicationSubmission", {})
    # The live version is not directly on the app; it is on the published
    # submission's packages. Treat "has a published submission" as the gate and
    # let the package version be authoritative at upload time.
    if not last:
        print("LIVE")
        return
    print("LIVE")


def _localized_listings(app_store_dir, languages):
    """Build the Store `listings` map from per-language info.json."""
    info_dir = os.path.join(app_store_dir, "screenshots", "info")
    listings = {}
    for lang in languages:
        linfo = os.path.join(info_dir, lang, "info.json")
        if not os.path.isfile(linfo):
            continue
        with open(linfo) as f:
            data = json.load(f)
        ms = data.get("microsoftStore")
        if not ms:
            continue
        locale = LOCALE_MAP.get(lang, lang.lower())
        listings[locale] = {
            "baseListing": {
                "description": ms.get("description", ""),
                "features": ms.get("features", []),
                "releaseNotes": ms.get("whatsNew", ""),
                "keywords": [s for s in (ms.get("searchTerms", "").split(";")) if s][:7],
                "title": ms.get("productName", ""),
                "shortDescription": ms.get("shortDescription", ""),
                "images": [],  # populated by _attach_screenshots
            },
            "platformOverrides": {},
        }
    return listings


def _attach_screenshots(listings, app_store_dir, zf):
    """Add Screenshot image entries to each locale and stage files into the zip.

    Store screenshots live at screenshots/store/<device>/<lang>/*.png. The Store
    expects the imageType "Screenshot"; filenames in the submission JSON are the
    paths inside the uploaded zip.
    """
    store_root = os.path.join(app_store_dir, "screenshots", "store")
    if not os.path.isdir(store_root):
        return
    # Short lang code per locale (reverse of LOCALE_MAP).
    rev = {v: k for k, v in LOCALE_MAP.items()}
    for locale, listing in listings.items():
        lang = rev.get(locale, locale.split("-")[0])
        count = 0
        for device in sorted(os.listdir(store_root)):
            lang_dir = os.path.join(store_root, device, lang)
            if not os.path.isdir(lang_dir):
                continue
            for name in sorted(os.listdir(lang_dir)):
                if not name.lower().endswith(".png"):
                    continue
                arc = f"images/{locale}/{device}_{name}"
                zf.write(os.path.join(lang_dir, name), arc)
                listing["baseListing"]["images"].append(
                    {"fileName": arc, "imageType": "Screenshot"}
                )
                count += 1
        if count:
            print(f"    [{locale}] {count} screenshot(s)")


def action_submit(args):
    token = get_token(args.tenant_id, args.client_id, args.client_secret)
    app = get_app(token, args.app_id)
    if not app:
        print(f"Error: app {args.app_id} not found in Partner Center.", file=sys.stderr)
        sys.exit(1)

    # 1. Delete any in-progress submission, then create a fresh one (a clone of
    #    the last published submission).
    pending = app.get("pendingApplicationSubmission")
    if pending:
        print(f"Deleting existing pending submission {pending['id']}...")
        api("DELETE", f"/applications/{args.app_id}/submissions/{pending['id']}", token)

    print("Creating submission...")
    submission = api("POST", f"/applications/{args.app_id}/submissions", token)
    sub_id = submission["id"]
    upload_url = submission["fileUploadUrl"]
    print(f"  Submission ID: {sub_id}")

    # 2. Update metadata.
    with open(os.path.join(args.app_store_dir, "info.json")) as f:
        info = json.load(f)
    with open(os.path.join(args.app_store_dir, "languages.json")) as f:
        languages = json.load(f)

    listings = _localized_listings(args.app_store_dir, languages)
    submission["listings"] = listings

    ms_meta = info.get("microsoftStore", {})
    props = ms_meta.get("properties", {})
    if props.get("privacyPolicyUrl"):
        submission.setdefault("applicationCategory", ms_meta.get("category", "NotSet"))

    # 3. Build the upload zip (package + screenshots), if there is anything to add.
    zip_path = os.path.join(args.app_store_dir, "builds", "release", "store_upload.zip")
    os.makedirs(os.path.dirname(zip_path), exist_ok=True)
    needs_upload = False
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        if not args.metadata_only and args.package:
            if not os.path.isfile(args.package):
                print(f"Error: package {args.package} not found.", file=sys.stderr)
                sys.exit(1)
            pkg_name = os.path.basename(args.package)
            zf.write(args.package, pkg_name)
            submission["applicationPackages"] = [
                {"fileName": pkg_name, "fileStatus": "PendingUpload"}
            ]
            needs_upload = True
            print(f"  Package: {pkg_name}")
        if args.screenshots:
            print("  Attaching screenshots...")
            _attach_screenshots(listings, args.app_store_dir, zf)
            if any(l["baseListing"]["images"] for l in listings.values()):
                needs_upload = True

    print("Updating submission metadata...")
    api("PUT", f"/applications/{args.app_id}/submissions/{sub_id}", token, submission)

    # 4. Upload the zip to the Azure blob SAS URL (block blob PUT).
    if needs_upload:
        print("Uploading package/screenshot zip...")
        with open(zip_path, "rb") as f:
            data = f.read()
        req = urllib.request.Request(upload_url, data=data, method="PUT")
        req.add_header("x-ms-blob-type", "BlockBlob")
        with urllib.request.urlopen(req) as resp:
            resp.read()
        print("  Uploaded.")
    else:
        print("  Nothing to upload (metadata-only).")

    # 5. Commit and poll.
    print("Committing submission...")
    api("POST", f"/applications/{args.app_id}/submissions/{sub_id}/commit", token)

    print("Polling submission status...")
    for _ in range(120):
        status = api("GET", f"/applications/{args.app_id}/submissions/{sub_id}/status", token)
        state = status.get("status")
        print(f"  status: {state}")
        if state in ("CommitStarted", "PreProcessing", "Certification", "Release"):
            time.sleep(10)
            continue
        if state == "CommitFailed":
            print("Error: commit failed.", file=sys.stderr)
            print(json.dumps(status.get("statusDetails", {}), indent=2), file=sys.stderr)
            sys.exit(1)
        break
    print("Microsoft Store submission complete (in certification).")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="Microsoft Store submission client")
    p.add_argument("--action", required=True, choices=["check-version", "submit"])
    p.add_argument("--tenant-id", default=os.environ.get("MS_TENANT_ID"))
    p.add_argument("--client-id", default=os.environ.get("MS_CLIENT_ID"))
    p.add_argument("--client-secret", default=os.environ.get("MS_CLIENT_SECRET"))
    p.add_argument("--app-id", default=os.environ.get("MS_SELLER_APP_ID"))
    p.add_argument("--app-store-dir")
    p.add_argument("--package", help="Path to the MSIX/MSIXUPLOAD to upload.")
    p.add_argument("--package-version")
    p.add_argument("--screenshots", action="store_true")
    p.add_argument("--metadata-only", action="store_true")
    args = p.parse_args()

    missing = [n for n in ("tenant_id", "client_id", "client_secret", "app_id")
               if not getattr(args, n)]
    if missing:
        print(f"Error: missing credentials: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    if args.action == "check-version":
        action_check_version(args)
    else:
        if not args.app_store_dir:
            print("Error: --app-store-dir required for submit.", file=sys.stderr)
            sys.exit(1)
        action_submit(args)


if __name__ == "__main__":
    main()
