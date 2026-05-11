#!/usr/bin/env python3
"""
Google Play Developer API client for submission automation.

Handles: Service account auth, AAB upload, listing updates, screenshot upload.
Uses only Python stdlib + openssl for RS256 signing.

Usage:
  submit_google.py --action submit --service-account-key X --package-name X --package-version X --app-store-dir X [--screenshots] [--metadata-only] [--track production]
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import urllib.parse

API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
TOKEN_URL = "https://oauth2.googleapis.com/token"

# ── Locale mapping ─────────────────────────────────────────────────────────

LOCALE_MAP = {
    "en": "en-US",
    "ar": "ar",
    "de": "de-DE",
    "es": "es-ES",
    "fr": "fr-FR",
    "it": "it-IT",
    "ja": "ja-JP",
    "ko": "ko-KR",
    "pt": "pt-BR",
    "ru": "ru-RU",
    "sv": "sv-SE",
    "th": "th",
    "uk": "uk",
    "vi": "vi",
    "zh": "zh-CN",
    "zh-hant": "zh-TW",
    "zh-Hant": "zh-TW",
}

# Screenshot type mapping (device directory → Google Play image type)
SCREENSHOT_TYPES = {
    "android_phone": "phoneScreenshots",
    "android_10_inch_tablet": "tenInchScreenshots",
}


# ── JWT / Auth ────────────────────────────────────────────────────────────

def base64url_encode(data):
    """Base64url encode without padding."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("utf-8")


def get_access_token(service_account_key):
    """Get an OAuth2 access token using service account credentials."""
    with open(service_account_key) as f:
        sa = json.load(f)

    # Build JWT
    header = {"alg": "RS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": sa["client_email"],
        "scope": "https://www.googleapis.com/auth/androidpublisher",
        "aud": sa.get("token_uri", TOKEN_URL),
        "iat": now,
        "exp": now + 3600,
    }

    header_b64 = base64url_encode(json.dumps(header))
    payload_b64 = base64url_encode(json.dumps(payload))
    signing_input = f"{header_b64}.{payload_b64}"

    # Write private key to temp file for openssl
    fd, key_file = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(sa["private_key"])

        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_file],
            input=signing_input.encode("utf-8"),
            capture_output=True,
        )
    finally:
        os.unlink(key_file)

    if result.returncode != 0:
        print(f"Error signing JWT: {result.stderr.decode()}", file=sys.stderr)
        sys.exit(1)

    sig_b64 = base64url_encode(result.stdout)
    jwt_token = f"{header_b64}.{payload_b64}.{sig_b64}"

    # Exchange JWT for access token
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt_token,
    }).encode("utf-8")

    req = urllib.request.Request(TOKEN_URL, data=data)
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        return result["access_token"]
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"Auth error: {error_body}", file=sys.stderr)
        sys.exit(1)


# ── API helpers ───────────────────────────────────────────────────────────

def api_request(method, url, token, data=None, content_type="application/json"):
    """Make a Google Play Developer API request."""
    headers = {"Authorization": f"Bearer {token}"}

    if data is not None and content_type == "application/json":
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")
    elif data is not None:
        headers["Content-Type"] = content_type
        body = data if isinstance(data, bytes) else data.encode("utf-8")
    else:
        body = None

    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            resp_body = resp.read().decode("utf-8")
            if not resp_body:
                return None
            return json.loads(resp_body)
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"API Error {e.code}: {error_body}", file=sys.stderr)
        raise


# ── Edit management ───────────────────────────────────────────────────────

def create_edit(token, package_name):
    """Create a new edit."""
    resp = api_request("POST", f"{API_BASE}/{package_name}/edits", token, {})
    return resp["id"]


def commit_edit(token, package_name, edit_id):
    """Commit an edit to apply changes."""
    api_request("POST", f"{API_BASE}/{package_name}/edits/{edit_id}:commit", token)


def delete_edit(token, package_name, edit_id):
    """Delete an edit without committing."""
    try:
        api_request("DELETE", f"{API_BASE}/{package_name}/edits/{edit_id}", token)
    except urllib.error.HTTPError:
        pass


# ── Bundle upload ─────────────────────────────────────────────────────────

def upload_bundle(token, package_name, edit_id, aab_path):
    """Upload an AAB to the edit."""
    with open(aab_path, "rb") as f:
        aab_data = f.read()

    url = (
        f"{UPLOAD_BASE}/{package_name}/edits/{edit_id}/bundles"
        f"?uploadType=media"
    )
    resp = api_request("POST", url, token, aab_data, "application/octet-stream")
    return resp["versionCode"]


def assign_track(token, package_name, edit_id, track, version_code, status="draft"):
    """Assign a bundle to a release track."""
    data = {
        "track": track,
        "releases": [{
            "versionCodes": [str(version_code)],
            "status": status,
        }],
    }
    api_request(
        "PUT",
        f"{API_BASE}/{package_name}/edits/{edit_id}/tracks/{track}",
        token,
        data,
    )


# ── Listings ──────────────────────────────────────────────────────────────

def update_listing(token, package_name, edit_id, locale, listing_data):
    """Create or update a store listing for a locale."""
    listing_data["language"] = locale
    api_request(
        "PUT",
        f"{API_BASE}/{package_name}/edits/{edit_id}/listings/{locale}",
        token,
        listing_data,
    )


# ── Screenshots ───────────────────────────────────────────────────────────

def delete_all_images(token, package_name, edit_id, locale, image_type):
    """Delete all images of a given type for a locale."""
    api_request(
        "DELETE",
        f"{API_BASE}/{package_name}/edits/{edit_id}/listings/{locale}/{image_type}",
        token,
    )


def upload_image(token, package_name, edit_id, locale, image_type, image_path):
    """Upload a single image."""
    with open(image_path, "rb") as f:
        img_data = f.read()

    url = (
        f"{UPLOAD_BASE}/{package_name}/edits/{edit_id}/listings/{locale}"
        f"/{image_type}"
    )
    api_request("POST", url, token, img_data, "image/png")


def upload_all_screenshots(token, package_name, edit_id, app_store_dir):
    """Upload all screenshots for all languages and device types."""
    store_dir = os.path.join(app_store_dir, "screenshots", "store")
    if not os.path.isdir(store_dir):
        print("  Warning: No store screenshots directory found, skipping.")
        return

    for device_key, image_type in SCREENSHOT_TYPES.items():
        device_dir = os.path.join(store_dir, device_key)
        if not os.path.isdir(device_dir):
            continue

        for lang_dir in sorted(os.listdir(device_dir)):
            lang_path = os.path.join(device_dir, lang_dir)
            if not os.path.isdir(lang_path):
                continue

            locale = LOCALE_MAP.get(lang_dir, lang_dir)
            screenshots = sorted(
                [f for f in os.listdir(lang_path) if f.endswith(".png")]
            )
            if not screenshots:
                continue

            print(f"  [{locale}] {device_key}: {len(screenshots)} screenshots")

            try:
                # Delete existing screenshots of this type
                delete_all_images(token, package_name, edit_id, locale, image_type)

                # Upload new screenshots
                for ss_file in screenshots:
                    ss_path = os.path.join(lang_path, ss_file)
                    upload_image(
                        token, package_name, edit_id, locale, image_type, ss_path
                    )
            except urllib.error.HTTPError:
                print(f"  [{locale}] {device_key}: FAILED — skipping.")


# ── Subscription listings ────────────────────────────────────────────

def update_subscription_listings(token, package_name, app_store_dir):
    """Upload per-store subscription name/description localizations.

    Uses the inappproducts API to update subscription listings.
    Reads product definitions from info.json and localized text from each
    language's info.json (the "subscriptions" object with "apple"/"google" keys).

    This runs outside the edit workflow — in-app product updates are direct.
    """
    info_json = os.path.join(app_store_dir, "info.json")
    with open(info_json) as f:
        root_info = json.load(f)

    products = root_info.get("subscriptions", {}).get("products", [])
    if not products:
        print("  No subscription products defined in info.json.")
        return

    # Collect all localized listings per product
    # product_listings[googleSku][locale] = {title, description}
    product_listings = {}
    info_dir = os.path.join(app_store_dir, "screenshots", "info")
    for lang_dir in sorted(os.listdir(info_dir)):
        lang_info_path = os.path.join(info_dir, lang_dir, "info.json")
        if not os.path.exists(lang_info_path):
            continue

        with open(lang_info_path) as f:
            lang_info = json.load(f)

        subs_data = lang_info.get("subscriptions", {})
        if not subs_data:
            continue

        locale = LOCALE_MAP.get(lang_dir, lang_dir)

        for product in products:
            key = product["key"]
            sku = product["googleSku"]
            sub_text = subs_data.get(key, {}).get("google", {})
            if not sub_text:
                continue

            if sku not in product_listings:
                product_listings[sku] = {}

            listing = {}
            if sub_text.get("name"):
                listing["title"] = sub_text["name"]
            if sub_text.get("description"):
                listing["description"] = sub_text["description"]
            if listing:
                product_listings[sku][locale] = listing

    # Update each product's listings
    for sku, new_listings in product_listings.items():
        print(f"  {sku}: updating {len(new_listings)} locale(s)...")
        try:
            # GET existing product to merge listings
            existing = api_request(
                "GET",
                f"{API_BASE}/{package_name}/inappproducts/{sku}",
                token,
            )
            current_listings = existing.get("listings", {})
            current_listings.update(new_listings)

            api_request(
                "PATCH",
                f"{API_BASE}/{package_name}/inappproducts/{sku}",
                token,
                {"listings": current_listings},
            )
            print(f"  {sku}: done.")
        except urllib.error.HTTPError:
            print(f"  {sku}: FAILED — skipping (see error above).")


# ── Actions ───────────────────────────────────────────────────────────────

def action_check_version(args):
    """Check the current production version on Google Play."""
    token = get_access_token(args.service_account_key)
    pkg = args.package_name

    edit_id = None
    try:
        edit_id = create_edit(token, pkg)
        track = api_request(
            "GET",
            f"{API_BASE}/{pkg}/edits/{edit_id}/tracks/production",
            token,
        )

        releases = track.get("releases", [])
        for release in releases:
            if release.get("status") in ("completed", "inProgress"):
                version_name = release.get("name", "unknown")
                print(f"OK:{version_name}")
                return

        print("NEW_APP")
    except urllib.error.HTTPError:
        print("NEW_APP")
    finally:
        if edit_id:
            delete_edit(token, pkg, edit_id)


def action_submit(args):
    """Create edit, upload AAB/metadata/screenshots, and commit."""
    token = get_access_token(args.service_account_key)
    pkg = args.package_name

    # Create edit
    print("Creating edit...")
    edit_id = create_edit(token, pkg)
    print(f"  Edit ID: {edit_id}")

    try:
        # Upload AAB and assign to track
        if not args.metadata_only:
            aab_path = os.path.join(
                args.app_store_dir, "builds", "release", "app-release.aab"
            )
            if not os.path.exists(aab_path):
                print(f"Error: AAB not found at {aab_path}", file=sys.stderr)
                sys.exit(1)

            size_mb = os.path.getsize(aab_path) / 1024 / 1024
            print(f"Uploading AAB ({size_mb:.1f} MB)...")
            version_code = upload_bundle(token, pkg, edit_id, aab_path)
            print(f"  Version code: {version_code}")

            print(f"Assigning to {args.track} track (draft)...")
            assign_track(token, pkg, edit_id, args.track, version_code)
        else:
            print("Skipping AAB upload (--metadata-only).")

        # Update listings
        print("Updating listings...")
        info_dir = os.path.join(args.app_store_dir, "screenshots", "info")
        for lang_dir in sorted(os.listdir(info_dir)):
            info_path = os.path.join(info_dir, lang_dir, "info.json")
            if not os.path.exists(info_path):
                continue

            locale = LOCALE_MAP.get(lang_dir, lang_dir)
            with open(info_path) as f:
                info = json.load(f)

            gp = info.get("googlePlay", {})
            if not gp:
                continue

            listing = {}
            if gp.get("title"):
                listing["title"] = gp["title"]
            if gp.get("shortDescription"):
                listing["shortDescription"] = gp["shortDescription"]
            if gp.get("fullDescription"):
                listing["fullDescription"] = gp["fullDescription"]

            if not listing:
                continue

            print(f"  [{locale}] updating listing...")
            try:
                update_listing(token, pkg, edit_id, locale, listing)
            except urllib.error.HTTPError:
                print(f"  [{locale}] FAILED — skipping.")

        # Upload screenshots
        if args.screenshots:
            print("Uploading screenshots...")
            upload_all_screenshots(token, pkg, edit_id, args.app_store_dir)

        # Commit
        print("Committing edit...")
        commit_edit(token, pkg, edit_id)
        print(
            f"Done. Version {args.package_version} is ready as draft "
            f"on Google Play Console ({args.track} track)."
        )

    except Exception:
        print("Error during submission. Deleting edit...", file=sys.stderr)
        delete_edit(token, pkg, edit_id)
        raise

    # Update subscription listings (outside the edit workflow)
    if args.subscriptions:
        print("Updating subscription listings...")
        update_subscription_listings(token, pkg, args.app_store_dir)


# ── CLI ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Google Play Developer API client"
    )
    parser.add_argument(
        "--action", required=True, choices=["check-version", "submit"]
    )
    parser.add_argument("--service-account-key", required=True)
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--app-store-dir", default=None)
    parser.add_argument("--track", default="production")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--subscriptions", action="store_true")
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()

    if args.action == "check-version":
        action_check_version(args)
    elif args.action == "submit":
        if not args.app_store_dir:
            print(
                "Error: --app-store-dir required for submit action",
                file=sys.stderr,
            )
            sys.exit(1)
        action_submit(args)


if __name__ == "__main__":
    main()
