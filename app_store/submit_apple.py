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

# Map device keys to App Store Connect platform
DEVICE_PLATFORM_MAP = {
    "iphone_6_9": "IOS",
    "ipad_13": "IOS",
    "macos_desktop": "MAC_OS",
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
        raise


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


# ── Subscription localizations ───────────────────────────────────────────

def update_subscription_localizations(token, app_id, app_store_dir):
    """Upload per-store subscription name/description localizations.

    Reads product definitions from info.json and localized text from each
    language's info.json (the "subscriptions" object with "apple"/"google" keys).
    """
    info_json = os.path.join(app_store_dir, "info.json")
    with open(info_json) as f:
        root_info = json.load(f)

    products = root_info.get("subscriptions", {}).get("products", [])
    if not products:
        print("  No subscription products defined in info.json.")
        return

    # Build map: appleProductId -> subscription resource ID
    print("  Fetching subscription groups...")
    resp = api_request("GET", f"/apps/{app_id}/subscriptionGroups?limit=50", token)
    groups = resp.get("data", [])

    product_map = {}  # appleProductId -> subscription resource ID
    for group in groups:
        group_id = group["id"]
        subs_resp = api_request(
            "GET", f"/subscriptionGroups/{group_id}/subscriptions?limit=50", token
        )
        for sub in subs_resp.get("data", []):
            pid = sub["attributes"]["productID"]
            product_map[pid] = sub["id"]

    if not product_map:
        print("  Warning: No subscriptions found on App Store Connect.")
        return

    # Process each language
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
            apple_pid = product["appleProductId"]
            sub_id = product_map.get(apple_pid)
            if not sub_id:
                print(f"  Warning: Subscription '{apple_pid}' not found on App Store Connect, skipping.")
                continue

            sub_text = subs_data.get(key, {}).get("apple", {})
            if not sub_text:
                continue

            print(f"  [{locale}] {key}: updating subscription localization...")
            try:
                _upsert_subscription_localization(token, sub_id, locale, sub_text)
            except urllib.error.HTTPError:
                print(f"  [{locale}] {key}: FAILED — skipping (see error above).")


def _upsert_subscription_localization(token, subscription_id, locale, text):
    """Create or update a subscription localization."""
    # Find existing localization for this locale
    resp = api_request(
        "GET",
        f"/subscriptions/{subscription_id}/subscriptionLocalizations",
        token,
    )

    loc_id = None
    for loc in resp.get("data", []):
        if loc["attributes"]["locale"] == locale:
            loc_id = loc["id"]
            break

    attrs = {}
    if text.get("name"):
        attrs["name"] = text["name"]
    if text.get("description"):
        attrs["description"] = text["description"]

    if not attrs:
        return

    if loc_id:
        data = {
            "data": {
                "type": "subscriptionLocalizations",
                "id": loc_id,
                "attributes": attrs,
            }
        }
        api_request("PATCH", f"/subscriptionLocalizations/{loc_id}", token, data)
    else:
        attrs["locale"] = locale
        data = {
            "data": {
                "type": "subscriptionLocalizations",
                "attributes": attrs,
                "relationships": {
                    "subscription": {
                        "data": {
                            "type": "subscriptions",
                            "id": subscription_id,
                        }
                    }
                },
            }
        }
        api_request("POST", "/subscriptionLocalizations", token, data)


# ── Submit action ─────────────────────────────────────────────────────────

def action_submit(args):
    """Create version, upload metadata, and optionally screenshots."""
    token = generate_jwt(args.key_id, args.issuer_id, args.key_file)
    app_id = get_app_id(token, args.bundle_id)

    # Determine which platforms are needed from info.json
    info_path = os.path.join(args.app_store_dir, "info.json")
    needed_platforms = {"IOS"}  # Always create iOS version
    if os.path.isfile(info_path):
        with open(info_path) as f:
            info = json.load(f)
        configured_platforms = info.get("appleAppStore", {}).get("platforms", {})
        PLATFORM_MAP = {"ios": "IOS", "ipados": "IOS", "macos": "MAC_OS"}
        for key in configured_platforms:
            if key in PLATFORM_MAP:
                needed_platforms.add(PLATFORM_MAP[key])

    # Create versions for each platform
    version_ids = {}
    for platform in sorted(needed_platforms):
        print(f"Creating App Store version {args.package_version} ({platform})...")
        version_id = create_or_get_editable_version(token, app_id, args.package_version, platform)
        version_ids[platform] = version_id
        print(f"  Version ID ({platform}): {version_id}")

    # Upload metadata for each language to each platform version
    print("Uploading metadata...")
    info_dir = os.path.join(args.app_store_dir, "screenshots", "info")
    for lang_dir in sorted(os.listdir(info_dir)):
        info_path = os.path.join(info_dir, lang_dir, "info.json")
        if not os.path.exists(info_path):
            continue

        locale = LOCALE_MAP.get(lang_dir, lang_dir)
        with open(info_path) as f:
            info = json.load(f)

        listing = info.get("appleAppStore", {})
        if not listing:
            continue

        # Update app-level info (subtitle) — only once per locale, not per platform
        print(f"  [{locale}] updating app info (subtitle)...")
        try:
            update_app_info_localization(token, app_id, locale, listing)
        except urllib.error.HTTPError:
            print(f"  [{locale}] app info FAILED — skipping (see error above).")

        for platform, version_id in version_ids.items():
            print(f"  [{locale}] updating metadata ({platform})...")
            try:
                update_localization(token, version_id, locale, listing)
            except urllib.error.HTTPError:
                print(f"  [{locale}] {platform} FAILED — skipping (see error above).")

    # Upload screenshots if requested
    if args.screenshots:
        print("Uploading screenshots...")
        upload_all_screenshots(token, version_ids, args.app_store_dir)

    # Upload subscription localizations if requested
    if args.subscriptions:
        print("Uploading subscription localizations...")
        update_subscription_localizations(token, app_id, args.app_store_dir)

    platforms_str = ", ".join(sorted(needed_platforms))
    print(f"Version {args.package_version} ({platforms_str}) is ready as draft on App Store Connect.")


def create_or_get_editable_version(token, app_id, version_string, platform="IOS"):
    """Create a new version or return existing editable version."""
    # Check for existing editable version — fetch recent versions and filter locally
    resp = api_request(
        "GET",
        f"/apps/{app_id}/appStoreVersions"
        f"?filter[platform]={platform}"
        f"&limit=10",
        token,
    )
    live_states = {"READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE"}
    editable_versions = [
        v for v in resp.get("data", [])
        if v["attributes"]["appStoreState"] not in live_states
    ]

    # Exact match
    for v in editable_versions:
        if v["attributes"]["versionString"] == version_string:
            return v["id"]

    # If there's an editable version with a different version string, update it
    if editable_versions:
        v = editable_versions[0]
        old_ver = v["attributes"]["versionString"]
        print(f"  Updating existing editable version {old_ver} → {version_string} ({platform})")
        data = {
            "data": {
                "type": "appStoreVersions",
                "id": v["id"],
                "attributes": {
                    "versionString": version_string,
                },
            }
        }
        api_request("PATCH", f"/appStoreVersions/{v['id']}", token, data)
        return v["id"]

    # Create new version
    data = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "versionString": version_string,
                "platform": platform,
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


def update_app_info_localization(token, app_id, locale, listing):
    """Update app-level localization (subtitle, name) via appInfoLocalizations."""
    # Get the app's appInfo
    resp = api_request("GET", f"/apps/{app_id}/appInfos?limit=1", token)
    app_infos = resp.get("data", [])
    if not app_infos:
        print(f"  Warning: No appInfo found for app, skipping subtitle.", file=sys.stderr)
        return

    app_info_id = app_infos[0]["id"]

    # Get existing localizations
    resp = api_request(
        "GET",
        f"/appInfos/{app_info_id}/appInfoLocalizations",
        token,
    )

    loc_id = None
    for loc in resp.get("data", []):
        if loc["attributes"]["locale"] == locale:
            loc_id = loc["id"]
            break

    attrs = {}
    if listing.get("subtitle"):
        attrs["subtitle"] = listing["subtitle"]

    if not attrs:
        return

    if loc_id:
        data = {
            "data": {
                "type": "appInfoLocalizations",
                "id": loc_id,
                "attributes": attrs,
            }
        }
        api_request("PATCH", f"/appInfoLocalizations/{loc_id}", token, data)
    else:
        attrs["locale"] = locale
        data = {
            "data": {
                "type": "appInfoLocalizations",
                "attributes": attrs,
                "relationships": {
                    "appInfo": {
                        "data": {
                            "type": "appInfos",
                            "id": app_info_id,
                        }
                    }
                },
            }
        }
        api_request("POST", "/appInfoLocalizations", token, data)


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
        # App Store keywords must be ≤100 characters
        kw = listing["keywords"]
        if len(kw) > 100:
            # Trim to last complete keyword within 100 chars
            kw = kw[:100].rsplit(",", 1)[0]
        attrs["keywords"] = kw
    if listing.get("promotionalText"):
        attrs["promotionalText"] = listing["promotionalText"]
    if listing.get("whatsNew"):
        attrs["whatsNew"] = listing["whatsNew"]
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


def upload_all_screenshots(token, version_ids, app_store_dir):
    """Upload all composed screenshots for all languages and devices.

    version_ids: dict mapping platform (e.g. "IOS", "MAC_OS") to version ID.
    """
    store_dir = os.path.join(app_store_dir, "screenshots", "store")
    if not os.path.isdir(store_dir):
        print("  Warning: No store screenshots directory found, skipping.")
        return

    # Cache localizations per version to avoid redundant API calls
    loc_cache = {}  # version_id -> {locale: loc_id}

    def get_localizations(version_id):
        if version_id not in loc_cache:
            resp = api_request(
                "GET",
                f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
                token,
            )
            loc_cache[version_id] = {
                loc["attributes"]["locale"]: loc["id"]
                for loc in resp.get("data", [])
            }
        return loc_cache[version_id]

    for device_key, display_type in SCREENSHOT_DISPLAY_TYPES.items():
        device_dir = os.path.join(store_dir, device_key)
        if not os.path.isdir(device_dir):
            continue

        # Determine which platform version this device belongs to
        platform = DEVICE_PLATFORM_MAP.get(device_key, "IOS")
        version_id = version_ids.get(platform)
        if not version_id:
            print(f"  Warning: No {platform} version for {device_key}, skipping.")
            continue

        loc_by_locale = get_localizations(version_id)

        for lang_dir in sorted(os.listdir(device_dir)):
            lang_path = os.path.join(device_dir, lang_dir)
            if not os.path.isdir(lang_path):
                continue

            locale = LOCALE_MAP.get(lang_dir, lang_dir)
            loc_id = loc_by_locale.get(locale)
            if not loc_id:
                print(f"  Warning: No localization for {locale} ({platform}), skipping screenshots.")
                continue

            screenshots = sorted(
                [f for f in os.listdir(lang_path) if f.endswith(".png")]
            )
            if not screenshots:
                continue

            print(f"  [{locale}] {device_key}: {len(screenshots)} screenshots")

            try:
                # Get or create screenshot set
                set_id = get_or_create_screenshot_set(token, loc_id, display_type)

                # Delete existing screenshots in set
                delete_existing_screenshots(token, set_id)

                # Upload each screenshot
                for ss_file in screenshots:
                    ss_path = os.path.join(lang_path, ss_file)
                    upload_screenshot(token, set_id, ss_path, ss_file)
            except urllib.error.HTTPError:
                print(f"  [{locale}] {device_key}: FAILED — skipping.")


def _device_family(display_type):
    """Return device family prefix (e.g. 'APP_IPHONE' from 'APP_IPHONE_67')."""
    for prefix in ("APP_IPHONE", "APP_IPAD", "APP_DESKTOP", "APP_APPLE_TV", "APP_WATCH"):
        if display_type.startswith(prefix):
            return prefix
    return display_type


def get_or_create_screenshot_set(token, localization_id, display_type):
    """Get existing screenshot set or create one.

    If a set with a different display type in the same device family exists
    (e.g. APP_IPHONE_65 when we want APP_IPHONE_67), delete it first so we
    can create the correct one.
    """
    resp = api_request(
        "GET",
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        token,
    )

    target_family = _device_family(display_type)
    family_match = None

    for ss_set in resp.get("data", []):
        existing_type = ss_set["attributes"]["screenshotDisplayType"]
        if existing_type == display_type:
            return ss_set["id"]
        if _device_family(existing_type) == target_family:
            family_match = ss_set

    # If a set exists for the same device family but wrong display type, replace it
    if family_match:
        old_type = family_match["attributes"]["screenshotDisplayType"]
        print(f"    Replacing display type {old_type} → {display_type}")
        delete_existing_screenshots(token, family_match["id"])
        api_request("DELETE", f"/appScreenshotSets/{family_match['id']}", token)

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
    parser.add_argument("--subscriptions", action="store_true")
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
