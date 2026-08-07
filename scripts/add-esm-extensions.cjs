#!/usr/bin/env node
/**
 * Add explicit `.js` extensions to relative import/export specifiers.
 *
 * TypeScript emits relative specifiers exactly as written. Under
 * `moduleResolution: bundler` you may omit extensions in source, and the emitted
 * ESM then contains extensionless imports that Node cannot resolve. Bun and
 * bundlers resolve them, so the breakage is invisible until a consumer runs
 * node or vitest — which is how testomniac_types@0.0.95 shipped unusable.
 *
 * Writing `.js` in TypeScript source is the documented way to emit ESM that
 * Node can load: the specifier refers to the OUTPUT file, and tsc leaves it be.
 *
 * Handles the two shapes that break:
 *   './thing'      -> './thing.js'        (sibling module)
 *   './dir'        -> './dir/index.js'    (directory import, unsupported in ESM)
 *
 * Leaves alone: bare specifiers, aliases, and anything already carrying an
 * extension.
 *
 * Usage: node add-esm-extensions.cjs <srcDir>   (defaults to ./src)
 */
const fs = require("fs");
const path = require("path");

const root = path.resolve(process.cwd(), process.argv[2] || "src");

/** Files whose specifiers we rewrite. */
const SOURCE = /\.(ts|tsx)$/;
/** A specifier already carrying any extension is left untouched. */
const HAS_EXTENSION = /\.[a-zA-Z0-9]+$/;

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (SOURCE.test(entry.name)) out.push(full);
  }
  return out;
}

/** What should this specifier become, or null to leave it alone? */
function resolveSpecifier(fromFile, spec) {
  if (!spec.startsWith(".")) return null;
  if (HAS_EXTENSION.test(spec)) return null;

  const base = path.resolve(path.dirname(fromFile), spec);
  for (const ext of [".ts", ".tsx", ".d.ts"]) {
    if (fs.existsSync(base + ext)) return `${spec}.js`;
  }
  for (const ext of [".ts", ".tsx"]) {
    if (fs.existsSync(path.join(base, `index${ext}`))) {
      return `${spec}/index.js`;
    }
  }
  return null;
}

const files = walk(root);
let changedFiles = 0;
let changedSpecifiers = 0;

for (const file of files) {
  const original = fs.readFileSync(file, "utf8");
  // from '...' | import('...') — covers import, export-from and dynamic import.
  const updated = original.replace(
    /(from\s+|import\(\s*)(['"])(\.[^'"]*)\2/g,
    (match, lead, quote, spec) => {
      const next = resolveSpecifier(file, spec);
      if (!next) return match;
      changedSpecifiers += 1;
      return `${lead}${quote}${next}${quote}`;
    }
  );
  if (updated !== original) {
    fs.writeFileSync(file, updated);
    changedFiles += 1;
  }
}

console.log(
  `rewrote ${changedSpecifiers} specifiers across ${changedFiles} files (${files.length} scanned)`
);
