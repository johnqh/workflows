#!/usr/bin/env python3
"""Rotate NPM_TOKEN in Cloudflare Pages env vars (production + preview) to the
token in ~/.npmrc, safely.

Safety model:
  - Only the single NPM_TOKEN key is PATCHed (Cloudflare merges by key), and it is
    stored as `secret_text` (not plaintext).
  - Each environment is snapshotted before, re-fetched after, and verified that no
    other variable was removed or had its type changed. On any discrepancy the run
    STOPS and prints the original variables.
  - NEVER writes the whole env_vars map back: Cloudflare redacts secret_text values
    on read, so a read-modify-write would blank every secret. Single-key merge avoids that.
  - Environments whose vars are all plaintext (fully recoverable) are processed first
    as canaries, so a replace-bug would be caught before any secret-bearing project.

Auth (read from a key file): CLOUDFLARE_API_TOKEN (preferred), or CLOUDFLARE_API_KEY
(+ CLOUDFLARE_EMAIL for a Global API Key). Key file search order:
  $CF_KEYFILE, ~/.develop/.keys, ~/.keys, ~/.keys.txt, ~/.private_keys
Env: DRY_RUN=1 prints planned changes without writing.
"""
import json, os, re, subprocess, sys, tempfile

API = "https://api.cloudflare.com/client/v4"
DRY = os.environ.get("DRY_RUN", "0") == "1"
SNAP_DIR = os.environ.get("SNAP_DIR") or tempfile.mkdtemp(prefix="pages-rotate-")

KEYFILES = [os.environ.get("CF_KEYFILE", "")] + [
    os.path.expanduser(p) for p in ("~/.develop/.keys", "~/.keys", "~/.keys.txt", "~/.private_keys")
]


def kv(name):
    for f in KEYFILES:
        if f and os.path.isfile(f):
            for line in open(f):
                m = re.match(r'^\s*(?:export\s+)?%s\s*=\s*(.*)$' % re.escape(name), line)
                if m:
                    return m.group(1).strip().strip('"').strip("'")
    return ""


def npm_token():
    for line in open(os.path.expanduser("~/.npmrc")):
        m = re.search(r'_authToken=(.*)$', line.strip())
        if m:
            return m.group(1).strip().strip('"').strip("'")
    sys.exit("No _authToken in ~/.npmrc")


NEW = npm_token()


def api_raw(hdr, method, path, body=None):
    cmd = ["curl", "-s", "-X", method] + hdr
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data", json.dumps(body)]
    cmd += ["%s%s" % (API, path)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {"success": False, "_raw": out[:300]}


def auth_headers():
    for tok in (kv("CLOUDFLARE_API_TOKEN"), kv("CLOUDFLARE_API_KEY")):
        if tok and api_raw(["-H", "Authorization: Bearer %s" % tok], "GET", "/accounts?per_page=1").get("success"):
            return ["-H", "Authorization: Bearer %s" % tok]
    key, email = kv("CLOUDFLARE_API_KEY"), kv("CLOUDFLARE_EMAIL")
    if key and email and api_raw(["-H", "X-Auth-Email: %s" % email, "-H", "X-Auth-Key: %s" % key], "GET", "/user").get("success"):
        return ["-H", "X-Auth-Email: %s" % email, "-H", "X-Auth-Key: %s" % key]
    sys.exit("Cloudflare auth failed: set CLOUDFLARE_API_TOKEN, or CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL, "
             "in a key file (CF_KEYFILE=/path to override).")


HDR = auth_headers()


def api(method, path, body=None):
    return api_raw(HDR, method, path, body)


def accounts():
    return api("GET", "/accounts?per_page=50").get("result") or []


def projects(acct):
    out, page = [], 1
    while True:
        d = api("GET", "/accounts/%s/pages/projects?per_page=10&page=%d" % (acct, page))
        if not d.get("success"):
            sys.exit("list pages failed for %s: %s" % (acct, d.get("errors")))
        r = d.get("result") or []
        out += r
        info = d.get("result_info") or {}
        if len(r) < 10 or len(out) >= (info.get("total_count") or 0):
            break
        page += 1
    return out


def get_project(acct, name):
    d = api("GET", "/accounts/%s/pages/projects/%s" % (acct, name))
    if not d.get("success"):
        sys.exit("get %s failed: %s" % (name, d.get("errors")))
    return d["result"]


def env_vars(proj, env):
    return ((proj.get("deployment_configs") or {}).get(env) or {}).get("env_vars") or {}


def types(ev):
    return {k: ((v or {}).get("type", "plain") if isinstance(v, dict) else "plain") for k, v in ev.items()}


def show_original(name, env, ev):
    print("      !!! ORIGINAL %s/%s env vars (secret values redacted by Cloudflare):" % (name, env))
    for k, v in sorted(ev.items()):
        t = (v or {}).get("type", "plain") if isinstance(v, dict) else "plain"
        val = "<secret-redacted>" if t == "secret_text" else (v or {}).get("value", "")
        print("        %s [%s] = %s" % (k, t, val))


def process(acct, name, env):
    before = env_vars(get_project(acct, name), env)
    json.dump(before, open(os.path.join(SNAP_DIR, "%s.%s.json" % (name, env)), "w"), indent=2)
    if "NPM_TOKEN" not in before:
        return True
    bt = types(before)
    if DRY:
        print("  DRY  %-22s %-10s would set NPM_TOKEN=secret_text (%d other vars kept)" % (name, env, len(bt) - 1))
        return True
    body = {"deployment_configs": {env: {"env_vars": {"NPM_TOKEN": {"type": "secret_text", "value": NEW}}}}}
    r = api("PATCH", "/accounts/%s/pages/projects/%s" % (acct, name), body)
    if not r.get("success"):
        print("  FAIL %-22s %-10s PATCH: %s" % (name, env, r.get("errors") or r.get("_raw")))
        show_original(name, env, before)
        return False
    at = types(env_vars(get_project(acct, name), env))
    missing = [k for k in bt if k not in at]
    changed = [k for k in bt if k in at and k != "NPM_TOKEN" and bt[k] != at[k]]
    if missing or changed:
        print("  *** ERASURE %-18s %-10s missing=%s changed=%s" % (name, env, missing, changed))
        show_original(name, env, before)
        return False
    print("  ok   %-22s %-10s (%d vars kept; NPM_TOKEN %s->%s)" % (name, env, len(bt), bt["NPM_TOKEN"], at.get("NPM_TOKEN")))
    return True


def main():
    print("Snapshots: %s\n" % SNAP_DIR)
    work = []
    for a in accounts():
        for p in projects(a["id"]):
            for env in ("production", "preview"):
                ev = env_vars(p, env)
                if "NPM_TOKEN" in ev:
                    has_secret = any(isinstance(v, dict) and v.get("type") == "secret_text"
                                     for k, v in ev.items() if k != "NPM_TOKEN")
                    work.append((a["id"], p["name"], env, has_secret))
    work.sort(key=lambda w: w[3])  # all-plaintext (recoverable) first
    for acct, name, env, _ in work:
        if not process(acct, name, env):
            print("\n>>> STOPPED. Nothing further touched. Originals shown above; snapshots in %s" % SNAP_DIR)
            sys.exit(2)
    print("\n>>> All NPM_TOKEN-bearing Pages environments rotated and verified. No vars erased.")


main()
