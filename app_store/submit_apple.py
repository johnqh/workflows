#!/usr/bin/env python3
"""
Apple App Store Connect API client for submission automation.

Handles: JWT auth, version checking, metadata upload, screenshot upload.
Uses only Python stdlib + openssl for ES256 signing.

Usage:
  submit_apple.py --action check-version --key-id X --issuer-id X --key-file X --bundle-id X --package-version X
  submit_apple.py --action submit --key-id X --issuer-id X --key-file X --bundle-id X --package-version X --app-store-dir X [--screenshots]
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
import hashlib

API_BASE = "https://api.appstoreconnect.apple.com/v1"

# ── Locale mapping ─────────────────────────────────────────────────────────

LOCALE_MAP = {
    "en": "en-US",
    "ar": "ar-SA",
    "de": "de-DE",
    "es": "es-ES",
    "fr": "fr-FR",
    "it": "it",
    "ja": "ja",
    "ko": "ko",
    "pt": "pt-BR",
    "ru": "ru",
    "sv": "sv",
    "th": "th",
    "uk": "uk",
    "vi": "vi",
    "zh": "zh-Hans",
    "zh-hant": "zh-Hant",
    "zh-Hant": "zh-Hant",
}

# Screenshot display type mapping
SCREENSHOT_DISPLAY_TYPES = {
    "iphone_6_9": "APP_IPHONE_67",
    "ipad_13": "APP_IPAD_PRO_3GEN_129",
    "macos_desktop": "APP_DESKTOP",
}


# ── JWT Token Generation ───────────────────────────────────────────────────

def base64url_encode(data):
    """Base64url encode without padding."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("utf-8")


def generate_jwt(key_id, issuer_id, key_file):
    """Generate a signed JWT for App Store Connect API using openssl."""
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1200,  # 20 minutes
        "aud": "appstoreconnect-v1",
    }

    header_b64 = base64url_encode(json.dumps(header))
    payload_b64 = base64url_encode(json.dumps(payload))
    signing_input = f"{header_b64}.{payload_b64}"

    # Sign with openssl
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_file],
        input=signing_input.encode("utf-8"),
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"Error signing JWT: {result.stderr.decode()}", file=sys.stderr)
        sys.exit(1)

    # openssl outputs DER-encoded signature; convert to raw r||s for ES256
    der_sig = result.stdout
    signature = der_to_raw_es256(der_sig)
    sig_b64 = base64url_encode(signature)

    return f"{header_b64}.{payload_b64}.{sig_b64}"


def der_to_raw_es256(der_sig):
    """Convert DER-encoded ECDSA signature to raw 64-byte r||s format."""
    idx = 2  # skip 0x30 and total length
    if der_sig[0] != 0x30:
        raise ValueError("Invalid DER signature")

    # Handle multi-byte length
    total_len = der_sig[1]
    if total_len & 0x80:
        num_bytes = total_len & 0x7F
        idx = 2 + num_bytes

    # Read r
    if der_sig[idx] != 0x02:
        raise ValueError("Invalid DER signature (r)")
    r_len = der_sig[idx + 1]
    r = der_sig[idx + 2 : idx + 2 + r_len]
    idx += 2 + r_len

    # Read s
    if der_sig[idx] != 0x02:
        raise ValueError("Invalid DER signature (s)")
    s_len = der_sig[idx + 1]
    s = der_sig[idx + 2 : idx + 2 + s_len]

    # Pad/trim to 32 bytes each
    r = r[-32:].rjust(32, b"\x00")
    s = s[-32:].rjust(32, b"\x00")

    return r + s


# ── API helpers ────────────────────────────────────────────────────────────

def api_request(method, path, token, data=None):
    """Make an App Store Connect API request."""
    url = f"{API_BASE}{path}" if path.startswith("/") else path
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status == 204:
                return None
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"API Error {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)


def get_app_id(token, bundle_id):
    """Find the App Store Connect app ID by bundle ID."""
    resp = api_request("GET", f"/apps?filter[bundleId]={bundle_id}", token)
    apps = resp.get("data", [])
    if not apps:
        print(f"Error: No app found with bundle ID {bundle_id}", file=sys.stderr)
        sys.exit(1)
    return apps[0]["id"]


def get_live_version(token, app_id):
    """Get the current live version string, or None if no live version."""
    resp = api_request(
        "GET",
        f"/apps/{app_id}/appStoreVersions"
        f"?filter[appStoreState]=READY_FOR_SALE"
        f"&limit=1",
        token,
    )
    versions = resp.get("data", [])
    if not versions:
        return None
    return versions[0]["attributes"]["versionString"]


def compare_versions(package_version, live_version):
    """Compare semver-style versions. Returns 1 if package > live, 0 if equal, -1 if less."""
    def parse(v):
        return tuple(int(p) for p in v.split("."))
    try:
        pv = parse(package_version)
        lv = parse(live_version)
        if pv > lv:
            return 1
        elif pv == lv:
            return 0
        return -1
    except (ValueError, IndexError):
        if package_version > live_version:
            return 1
        elif package_version == live_version:
            return 0
        return -1


# ── Version check action ──────────────────────────────────────────────────

def action_check_version(args):
    """Check if package version can be submitted."""
    token = generate_jwt(args.key_id, args.issuer_id, args.key_file)
    app_id = get_app_id(token, args.bundle_id)
    live_version = get_live_version(token, app_id)

    if live_version is None:
        print("NEW_APP")
        return

    cmp = compare_versions(args.package_version, live_version)
    if cmp == 0:
        print("VERSION_EXISTS")
    elif cmp < 0:
        print("VERSION_OLDER")
    else:
        print(f"OK:{live_version}")


# ── Submit action ─────────────────────────────────────────────────────────

def action_submit(args):
    """Create version, upload metadata, and optionally screenshots."""
    token = generate_jwt(args.key_id, args.issuer_id, args.key_file)
    app_id = get_app_id(token, args.bundle_id)

    # Create new version (or find existing editable version)
    print(f"Creating App Store version {args.package_version}...")
    version_id = create_or_get_editable_version(token, app_id, args.package_version)
    print(f"Version ID: {version_id}")

    # Upload metadata for each language
    print("Uploading metadata...")
    info_dir = os.path.join(args.app_store_dir, "screenshots", "info")
    for lang_dir in sorted(os.listdir(info_dir)):
        info_path = os.path.join(info_dir, lang_dir, "info.json")
        if not os.path.exists(info_path):
            continue

        locale = LOCALE_MAP.get(lang_dir, lang_dir)
        with open(info_path) as f:
            info = json.load(f)

        listing = info.get("listing", {})
        if not listing:
            continue

        print(f"  [{locale}] updating metadata...")
        update_localization(token, version_id, locale, listing)

    # Upload screenshots if requested
    if args.screenshots:
        print("Uploading screenshots...")
        upload_all_screenshots(token, version_id, args.app_store_dir)

    print(f"Version {args.package_version} is ready as draft on App Store Connect.")


def create_or_get_editable_version(token, app_id, version_string):
    """Create a new version or return existing editable version."""
    # Check for existing editable version
    resp = api_request(
        "GET",
        f"/apps/{app_id}/appStoreVersions"
        f"?filter[appStoreState]=PREPARE_FOR_SUBMISSION"
        f"&limit=5",
        token,
    )
    for v in resp.get("data", []):
        if v["attributes"]["versionString"] == version_string:
            return v["id"]

    # Create new version
    data = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "versionString": version_string,
                "platform": "IOS",
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            },
        }
    }
    resp = api_request("POST", "/appStoreVersions", token, data)
    return resp["data"]["id"]


def update_localization(token, version_id, locale, listing):
    """Create or update localization for a version."""
    resp = api_request(
        "GET",
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        token,
    )

    loc_id = None
    for loc in resp.get("data", []):
        if loc["attributes"]["locale"] == locale:
            loc_id = loc["id"]
            break

    attrs = {}
    if listing.get("description"):
        attrs["description"] = listing["description"]
    if listing.get("keywords"):
        attrs["keywords"] = listing["keywords"]
    if listing.get("promotionalText"):
        attrs["promotionalText"] = listing["promotionalText"]
    if listing.get("whatsNew"):
        attrs["whatsNewText"] = listing["whatsNew"]
    if listing.get("marketingUrl"):
        attrs["marketingUrl"] = listing["marketingUrl"]
    if listing.get("supportUrl"):
        attrs["supportUrl"] = listing["supportUrl"]

    if loc_id:
        data = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc_id,
                "attributes": attrs,
            }
        }
        api_request("PATCH", f"/appStoreVersionLocalizations/{loc_id}", token, data)
    else:
        attrs["locale"] = locale
        data = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "attributes": attrs,
                "relationships": {
                    "appStoreVersion": {
                        "data": {
                            "type": "appStoreVersions",
                            "id": version_id,
                        }
                    }
                },
            }
        }
        api_request("POST", "/appStoreVersionLocalizations", token, data)


def upload_all_screenshots(token, version_id, app_store_dir):
    """Upload all composed screenshots for all languages and devices."""
    store_dir = os.path.join(app_store_dir, "screenshots", "store")
    if not os.path.isdir(store_dir):
        print("  Warning: No store screenshots directory found, skipping.")
        return

    # Get localizations for this version
    resp = api_request(
        "GET",
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        token,
    )
    loc_by_locale = {}
    for loc in resp.get("data", []):
        loc_by_locale[loc["attributes"]["locale"]] = loc["id"]

    for device_key, display_type in SCREENSHOT_DISPLAY_TYPES.items():
        device_dir = os.path.join(store_dir, device_key)
        if not os.path.isdir(device_dir):
            continue

        for lang_dir in sorted(os.listdir(device_dir)):
            lang_path = os.path.join(device_dir, lang_dir)
            if not os.path.isdir(lang_path):
                continue

            locale = LOCALE_MAP.get(lang_dir, lang_dir)
            loc_id = loc_by_locale.get(locale)
            if not loc_id:
                print(f"  Warning: No localization for {locale}, skipping screenshots.")
                continue

            screenshots = sorted(
                [f for f in os.listdir(lang_path) if f.endswith(".png")]
            )
            if not screenshots:
                continue

            print(f"  [{locale}] {device_key}: {len(screenshots)} screenshots")

            # Get or create screenshot set
            set_id = get_or_create_screenshot_set(token, loc_id, display_type)

            # Delete existing screenshots in set
            delete_existing_screenshots(token, set_id)

            # Upload each screenshot
            for ss_file in screenshots:
                ss_path = os.path.join(lang_path, ss_file)
                upload_screenshot(token, set_id, ss_path, ss_file)


def get_or_create_screenshot_set(token, localization_id, display_type):
    """Get existing screenshot set or create one."""
    resp = api_request(
        "GET",
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        token,
    )
    for ss_set in resp.get("data", []):
        if ss_set["attributes"]["screenshotDisplayType"] == display_type:
            return ss_set["id"]

    # Create new set
    data = {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {
                "appStoreVersionLocalization": {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization_id,
                    }
                }
            },
        }
    }
    resp = api_request("POST", "/appScreenshotSets", token, data)
    return resp["data"]["id"]


def delete_existing_screenshots(token, set_id):
    """Delete all screenshots in a set."""
    resp = api_request(
        "GET", f"/appScreenshotSets/{set_id}/appScreenshots", token
    )
    for ss in resp.get("data", []):
        api_request("DELETE", f"/appScreenshots/{ss['id']}", token)


def upload_screenshot(token, set_id, file_path, file_name):
    """Upload a single screenshot to a screenshot set."""
    file_size = os.path.getsize(file_path)

    # Step 1: Reserve the screenshot
    data = {
        "data": {
            "type": "appScreenshots",
            "attributes": {
                "fileSize": file_size,
                "fileName": file_name,
            },
            "relationships": {
                "appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id}
                }
            },
        }
    }
    resp = api_request("POST", "/appScreenshots", token, data)
    screenshot_id = resp["data"]["id"]

    # Step 2: Upload the binary to the provided URL
    upload_ops = resp["data"]["attributes"].get("uploadOperations", [])
    with open(file_path, "rb") as f:
        file_data = f.read()

    for op in upload_ops:
        url = op["url"]
        offset = op.get("offset", 0)
        length = op.get("length", len(file_data))
        chunk = file_data[offset : offset + length]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}

        req = urllib.request.Request(url, data=chunk, headers=headers, method="PUT")
        urllib.request.urlopen(req)

    # Step 3: Commit the upload
    checksum = hashlib.md5(file_data).hexdigest()
    data = {
        "data": {
            "type": "appScreenshots",
            "id": screenshot_id,
            "attributes": {
                "uploaded": True,
                "sourceFileChecksum": checksum,
            },
        }
    }
    api_request("PATCH", f"/appScreenshots/{screenshot_id}", token, data)


# ── CLI ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Apple App Store Connect API client")
    parser.add_argument("--action", required=True, choices=["check-version", "submit"])
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--app-store-dir", default=None)
    parser.add_argument("--screenshots", action="store_true")
    args = parser.parse_args()

    if args.action == "check-version":
        action_check_version(args)
    elif args.action == "submit":
        if not args.app_store_dir:
            print("Error: --app-store-dir required for submit action", file=sys.stderr)
            sys.exit(1)
        action_submit(args)


if __name__ == "__main__":
    main()
