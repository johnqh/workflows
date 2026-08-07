#!/usr/bin/env node
/**
 * Import a package's own entry point the way a consumer would.
 *
 * Every local gate — typecheck, lint, unit tests, build — runs against SOURCE.
 * None of them import the built artifact, so a package can pass all of them and
 * still be unusable the moment someone installs it. That has now shipped three
 * times:
 *
 *   webgraph_client@0.0.1   dist/index.js was `export {}` — the class was never
 *                           packed. Every consumer failed at import.
 *   testomniac_types@0.0.91 published with no changes at all.
 *   testomniac_types@0.0.95 emitted `export * from "./replay-selector"` with no
 *                           extension, which throws under Node ESM.
 *
 * Run under NODE, deliberately. Bun's resolver is more permissive — it resolves
 * extensionless relative imports happily — so a bun-based check passes the
 * 0.0.95 bug and gives false confidence. Consumers run vitest and node.
 *
 * Usage: node check-package-entry.cjs   (from a package root, after build)
 * Exits non-zero when the entry cannot be imported or exports nothing.
 */
const path = require("path");
const { pathToFileURL } = require("url");

const cwd = process.cwd();
const pkg = require(path.join(cwd, "package.json"));

const exportsEntry =
  pkg.exports && pkg.exports["."]
    ? pkg.exports["."].import || pkg.exports["."].default
    : undefined;
const rel = pkg.main || pkg.module || exportsEntry;

if (!rel) {
  console.log("entry check: skipped (no entry point declared)");
  process.exit(0);
}

// A source entry means the package ships TypeScript and is consumed by a
// bundler; importing it under plain node proves nothing.
if (/\.tsx?$/.test(String(rel))) {
  console.log(`entry check: skipped (${rel} is source, not a build artifact)`);
  process.exit(0);
}

const entry = path.resolve(cwd, String(rel));

import(pathToFileURL(entry).href)
  .then(mod => {
    const count = Object.keys(mod).length;
    if (count === 0) {
      console.error(
        `entry check FAILED: ${rel} imports but exports nothing.\n` +
          "The build produced an empty artifact — consumers will import it and get nothing."
      );
      process.exit(1);
    }
    console.log(`entry check: ok (${count} exports from ${rel})`);
  })
  .catch(err => {
    console.error(
      `entry check FAILED: ${String(err && err.message).split("\n")[0]}\n` +
        "The published artifact cannot be imported. Do not publish this."
    );
    process.exit(1);
  });
