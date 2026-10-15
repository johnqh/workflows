#!/usr/bin/env tsx

/**
 * Generate a committed `.env.production` from a project's local `.env`.
 *
 * Goal: bake the PUBLIC, non-secret build-time config into the repo so a
 * Cloudflare Pages project only needs a handful of real keys configured in its
 * build settings, instead of dozens of variables.
 *
 * Model: ALLOWLIST then DENY. A key is written only if it (a) matches a public
 * prefix (default `VITE_`) or is named in CF_ENV_INCLUDE, AND (b) does NOT look
 * like a credential. Anything whose name matches API_KEY / SECRET / TOKEN /
 * PASSWORD / PRIVATE / CREDENTIAL is EXCLUDED even when it is `VITE_`-prefixed --
 * so no API key of any kind ends up in the committed file. Everything else in
 * `.env` (local-only tooling, etc.) is ignored entirely.
 *
 * Why `.env.production` (not a wrangler file): `VITE_*` vars are consumed at
 * BUILD time. A wrangler `[vars]` block is runtime-only and never reaches
 * `vite build`, so it cannot replace these. Vite auto-loads `.env.production`
 * during a production build -- no build-command change needed for VITE_* vars.
 *
 * Usage:
 *   tsx generate-cloudflare-env.ts                 # .env -> .env.production
 *   tsx generate-cloudflare-env.ts <src> <out>     # custom paths
 *
 * Config (env vars):
 *   CF_ENV_PREFIX    Comma-separated key prefixes to include. Default: VITE_
 *   CF_ENV_INCLUDE   Comma-separated extra, non-prefixed keys to also include
 *                    (for NON-secret build vars a build script needs, e.g.
 *                    CF_ENV_INCLUDE=GENERATE_ORIGIN). Still subject to the
 *                    credential filter below.
 *   CF_ENV_EXCLUDE   Comma-separated exact key names to always exclude, on top
 *                    of the built-in credential name filter.
 *   CF_ENV_ALLOW     Comma-separated extra patterns (case-insensitive substring)
 *                    for credential-looking keys that ARE safe to commit, on top
 *                    of the built-in `FIREBASE` allowance (its client apiKey is
 *                    public by design). e.g. CF_ENV_ALLOW=PUBLISHABLE
 *   CF_ENV_OVERRIDES Path to a shared values file. Default: ~/.keys, then
 *                    ~/.keys.txt. For any key also present in the source .env,
 *                    this file's value wins -- so common cross-project values
 *                    can be centralized and left blank in each project's .env.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';

const sourcePath = resolve(process.cwd(), process.argv[2] ?? '.env');
const outPath = resolve(process.cwd(), process.argv[3] ?? '.env.production');

const prefixes = (process.env.CF_ENV_PREFIX ?? 'VITE_')
  .split(',')
  .map((p) => p.trim())
  .filter(Boolean);
const extraIncludes = new Set(
  (process.env.CF_ENV_INCLUDE ?? '')
    .split(',')
    .map((k) => k.trim())
    .filter(Boolean),
);
const extraExcludes = new Set(
  (process.env.CF_ENV_EXCLUDE ?? '')
    .split(',')
    .map((k) => k.trim())
    .filter(Boolean),
);

/**
 * Overrides file (default ~/.keys, then ~/.keys.txt): shared cross-project
 * values. When a key in the source .env also has a value here, the value from
 * here wins -- so common vars can be centralized and left blank in each .env.
 * Only keys already declared in .env are considered, so secrets that live only
 * in this file (e.g. CLOUDFLARE_API_KEY) are never pulled into the output.
 */
const overridePath =
  (process.env.CF_ENV_OVERRIDES ? resolve(process.env.CF_ENV_OVERRIDES) : undefined) ??
  [join(homedir(), '.keys'), join(homedir(), '.keys.txt')].find((p) => existsSync(p));

function parseEnvMap(file: string | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (!file || !existsSync(file)) return map;
  for (const raw of readFileSync(file, 'utf8').split('\n')) {
    let line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.slice(7).trim();
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    const val = line.slice(eq + 1).trim();
    if (key && hasValue(val)) map.set(key, val);
  }
  return map;
}

const overrides = parseEnvMap(overridePath);
let overridesApplied = 0;

/** Credential-looking names are NEVER written -- keep them in the dashboard. */
const CREDENTIAL = /(SECRET|TOKEN|PASSWORD|PRIVATE|CREDENTIAL|API_KEY|APIKEY|ACCESS_KEY)/i;
/** ...except these, which are public by design (Firebase client config + opt-ins). */
const allowPatterns = [
  'FIREBASE',
  ...(process.env.CF_ENV_ALLOW ?? '').split(',').map((p) => p.trim()).filter(Boolean),
];
const isAllowedCredential = (key: string) =>
  allowPatterns.some((p) => key.toUpperCase().includes(p.toUpperCase()));

if (!existsSync(sourcePath)) {
  console.error(`✗ Source env file not found: ${sourcePath}`);
  process.exit(1);
}

interface Entry {
  key: string;
  value: string;
}

/** A value counts as "set" only if it is non-empty after stripping quotes. */
function hasValue(rawValue: string): boolean {
  let v = rawValue.trim();
  if (
    (v.startsWith('"') && v.endsWith('"') && v.length >= 2) ||
    (v.startsWith("'") && v.endsWith("'") && v.length >= 2)
  ) {
    v = v.slice(1, -1).trim();
  }
  return v.length > 0;
}

const included: Entry[] = [];
const notWritten: string[] = []; // have a value in .env but intentionally left out

for (const rawLine of readFileSync(sourcePath, 'utf8').split('\n')) {
  const line = rawLine.trim();
  if (!line || line.startsWith('#')) continue;

  const eq = line.indexOf('=');
  if (eq === -1) continue; // not a KEY=VALUE line

  const key = line.slice(0, eq).trim();
  const envValue = line.slice(eq + 1); // keep value verbatim (may contain '=')
  if (!key) continue;

  // Prefer the shared overrides file (~/.keys) when it has a value for this key.
  const override = overrides.get(key);
  if (override !== undefined) overridesApplied++;
  const value = override ?? envValue;

  // Skip keys with no value (in .env or overrides) -- don't emit empty `KEY=''`.
  if (!hasValue(value)) continue;

  const isCandidate = prefixes.some((p) => key.startsWith(p)) || extraIncludes.has(key);
  const isBlocked =
    extraExcludes.has(key) || (CREDENTIAL.test(key) && !isAllowedCredential(key));

  if (isCandidate && !isBlocked) {
    included.push({ key, value });
  } else {
    // Has a value in .env but not written here (wrong prefix, or a credential).
    notWritten.push(key);
  }
}

/**
 * Quote a value so the file is safe both for Vite's dotenv parser (which strips
 * surrounding quotes) and for `set -a && . ./.env.production` in bash. Values
 * already wrapped in matching quotes are left as-is.
 */
function quote(value: string): string {
  const v = value.trim();
  if (
    (v.startsWith('"') && v.endsWith('"') && v.length >= 2) ||
    (v.startsWith("'") && v.endsWith("'") && v.length >= 2)
  ) {
    return v; // already quoted in the source -- leave as-is
  }
  // Leave simple values bare (matches hand-written .env style). Only values
  // with whitespace or shell-special chars are quoted, so the file stays safe
  // for Vite's parser and for `set -a && . ./.env.production`.
  if (/^[A-Za-z0-9_.:/@%+,-]+$/.test(v)) return v;
  // Single quotes = literal in both bash and dotenv; escape embedded quotes.
  return `'${v.replace(/'/g, `'\\''`)}'`;
}

const header = [
  '# ---------------------------------------------------------------------------',
  '# Public build-time config for production. Vite auto-loads this on `vite build`.',
  '# Generated by `bun run generate:cf-env`; you can also edit it by hand.',
];

if (notWritten.length) {
  header.push(
    '#',
    '# Set in .env with a value, but NOT written here (configure these in the',
    '# Cloudflare build variables if the build needs them):',
    ...notWritten.map((k) => `#   ${k}`),
  );
}

header.push('# ---------------------------------------------------------------------------', '');

const body = included.map(({ key, value }) => `${key}=${quote(value)}`).join('\n');
writeFileSync(outPath, `${header.join('\n')}${body}\n`, 'utf8');

console.log(
  `✓ Wrote ${included.length} public vars to ${outPath} ` +
    `(prefix: ${prefixes.join(', ')}; ${notWritten.length} other keys noted in the header)\n`,
);

if (overridePath && overridesApplied) {
  console.log(`Applied ${overridesApplied} value override(s) from ${overridePath}\n`);
}

if (notWritten.length) {
  console.log('Have a value in .env but NOT written (kept for Cloudflare / local only):');
  for (const k of notWritten) console.log(`  • ${k}`);
  console.log('');
}

console.log('Review .env.production, then commit it. Vite picks up VITE_* automatically.');
console.log('If a build SCRIPT needs a non-VITE var, add it via CF_ENV_INCLUDE and set the');
console.log('build command to:  set -a && . ./.env.production && set +a && bun run build');
