# app_store toolkit

Shared, config-driven tooling to take any app in this ecosystem through the
whole store pipeline — screenshots, store-text localization, builds, and
submission to the **Apple App Store, Google Play, and Microsoft Store** — from
one set of scripts and one data model.

Each app keeps only its **config + credentials** under `<project>/app_store/`.
All logic lives here (`~/projects/workflows/app_store/`). Apps invoke it through
the `appstore` CLI.

## How apps invoke it

No global install. Each project has one repo-local wrapper, `scripts/store.sh`,
which exports `APP_STORE_DIR` (this project's `app_store/`) and `WORKFLOWS_DIR`
(the toolkit) and execs the shared `store` orchestrator. The toolkit path lives
only in that wrapper, so nothing else hardcodes it.

- **RN apps** — `package.json` points at the wrapper:
  ```json
  "scripts": { "store": "bash scripts/store.sh" }
  ```
  ```bash
  bun run store                              # whole flow: doctor → localize → screenshots → submit
  bun run store -- --screenshots             # one step (pass options after --)
  ```
- **Native / Gradle apps** (no package manager) — run the wrapper directly:
  ```bash
  ./scripts/store.sh --submit:appstore
  ```
  A second product keeps its own wrapper (e.g. dimensions'
  `scripts/store-gimbal.sh`, which points `APP_STORE_DIR` at `app_store_gimbal/`).

`scripts/store.sh` is identical across projects — copy it when onboarding a new
app (`appstore init` leaves a reminder).

### `store` flag grammar

One or more `--<step>[:<narrow>[:<narrow>]]` options; `:` narrows a step. A lone
`--dry-run` (or `-n`) applies to every step. Steps run in the order given.

| Option | Does |
|---|---|
| (none) | whole flow: doctor → localize → screenshots → submit (all configured stores, with screenshots) |
| `--screenshots` | capture + frame all devices × languages |
| `--screenshots:iphone` | one device/platform (`iphone`→ios, `ipad`→ipados, `mac`→macos, `android`, or a raw `screens.json` device key) |
| `--screenshots:iphone:en` | that device, one language |
| `--build:android:release` | build one platform; optional `debug`/`release` |
| `--submit:appstore` | submit to one store (`appstore`/`apple`, `play`/`google`, `microsoft`/`windows`) |
| `--submit:appstore:screenshots` | …also upload screenshots (or `:metadata` for metadata-only) |
| `--localize` / `--compose` / `--doctor` / `--status` / `--cleanup` | that single step |

```bash
bun run store -- --localize --screenshots:iphone --submit:appstore:screenshots
bun run store -- --dry-run --submit:play           # preview, no upload
```

### Lower-level CLI

`store` is a front-end over `appstore <subcommand>` (the subcommand CLI:
`doctor localize screenshots build submit status init cleanup …`). Call
`appstore` directly by full path when you want the raw subcommand interface, or
symlink it onto PATH if you prefer a global command — neither is required.

## The pipeline (maps to the 4 release steps)

| Step | Command | Apple (iOS/macOS) | Google (Android) | Microsoft (Windows) |
|---|---|---|---|---|
| 1. Screenshots | `appstore screenshots` | simulator capture + frame | emulator capture + frame | capture on Windows host |
| 2. Localize store text | `appstore localize` | ✓ | ✓ | ✓ |
| 3. Build binary | `appstore build` | Xcode Cloud (or local) | ✓ (`--platform android`) | `build_windows.ps1` (Windows host) |
| 4. Submit | `appstore submit` | `submit_apple.py` | `submit_google.py` | `submit_microsoft.py` |

iOS/macOS binaries are normally built by **Xcode Cloud** (`ci_post_clone.sh`),
so `submit --platforms apple` can run `--metadata-only` once the Xcode Cloud
build lands. Windows must be built on a Windows PC or `windows-latest` runner.

## Data model

Per app, under `app_store/`:

| File | Purpose |
|---|---|
| `info.json` | Identity, build config, and **non-localized** store declarations (categories, age ratings, data-safety, platforms, subscription id map). `appleAppStore` / `googlePlay` / `microsoftStore` keys decide which stores the app targets. |
| `screens.json` | Devices → simulator/emulator names + resolutions, per platform. |
| `paths.json` | One deep-link path per screenshot. |
| `languages.json` | Languages to capture + localize. |
| `frames/frames.json` + PNGs | Device frames (geometry for compose). |
| `screenshots/info/<lang>/info.json` | **Localized** listing text: `appleAppStore`, `googlePlay`, `microsoftStore` (+ `subscriptions`). `en/` is hand-authored; the rest are produced by `appstore localize`. |
| `screenshots/info/<lang>/screens.json` | Per-screenshot captions (`title` + `text`), one per `paths.json` entry. |
| `.env` + `.keys/` | Credentials (gitignored). |
| `ExportOptions*.plist` | iOS / macOS archive export. |

### info.json build block

```jsonc
"build": {
  "metroPort": 8082,                       // RN apps
  "projectType": "native",                 // optional: force native (skips RN env-merge/version sync)
  "ios":     { "appName": "X", "workspace": "X.xcworkspace", "scheme": "X" },
  "macos":   { "workspace": "X.xcworkspace", "scheme": "X-macOS" },
  "android": { "dir": "android", "module": "app" },  // dir "." for a standalone Gradle app
  "windows": { "appName": "X" }
}
"localize": { "slug": "x", "apiBase": "https://api.whisperly.dev/api/v1/translate/jie9cytr" }
```

`projectType` is auto-detected (RN if `package.json`, native if an `.xcodeproj`),
so RN apps need nothing. A standalone Android app (no `package.json`, Gradle at
the repo root) sets `projectType: "native"` and `android.dir: "."`.

## Credentials (`app_store/.env`)

| Store | Needed |
|---|---|
| Apple | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `.keys/apple.p8` |
| Google | `GOOGLE_PLAY_SERVICE_ACCOUNT_KEY=.keys/google-play.json` |
| Microsoft | `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET`, `MS_SELLER_APP_ID` (Azure AD app registration linked in Partner Center) |

## doctor — validate before you run

`appstore doctor` checks config validity, credential presence, frame files, and
the store length limits that otherwise fail *during* submission:

- Apple subtitle ≤ 30, promotionalText ≤ 170, keywords ≤ 100 (auto-trimmed → warning), description ≤ 4000
- Google Play title ≤ 30, **shortDescription ≤ 80** (over → 403 on submit), fullDescription ≤ 4000
- Microsoft shortDescription ≤ 1000, description ≤ 10000
- caption count per language == number of screenshots

Errors exit non-zero; warnings don't. Run it in CI before submitting.

## status — fleet dashboard

`appstore status` auto-discovers every `*/app_store/info.json` under
`~/projects` and writes a self-contained HTML page showing, per app, which
stores it targets and how far each step (localize / screenshots / compose /
build) has progressed, plus credential readiness. Filesystem-only; no network.

```bash
appstore status                         # whole fleet, opens in browser
appstore status --no-out --out out.html app_store   # single app
```

## CI (GitHub Actions)

`.github/workflows/app-store.yml` is a reusable workflow for the CI-able steps
(screenshots stay local — they need simulators). It runs, gated by inputs +
secrets: metadata/localization submit (ubuntu), Android build+submit (ubuntu),
Windows build+submit (windows). See the header of that file for a caller
example.

## Xcode Cloud

Each RN app's `ios/ci_scripts/ci_post_clone.sh` (and `macos/…`) should be a thin
fetch of the shared `ci_post_clone.sh` here, so the setup logic lives in one
place:

```bash
#!/bin/bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/johnqh/workflows/main/app_store/ci_post_clone.sh -o /tmp/ci_post_clone.sh
exec bash /tmp/ci_post_clone.sh ios     # or: macos
```

(Switch per-app scripts to this only after the shared file is on `main`.)

## Adopters

RN: `sudojo_app_rn`, `svgr_app_rn`, `music_app_rn`, `music_player_app_rn`,
`raidr_agent_app_rn`, `mail_box_rn` (Signic). Native iOS/macOS: `dimensions`
(+ `app_store_gimbal`). Standalone Android: `dimensions_android`.

New apps: `appstore init`.
