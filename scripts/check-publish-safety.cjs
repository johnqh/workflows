#!/usr/bin/env node
/**
 * Refuse to publish work that is not finished.
 *
 * `testomniac_runner_service@0.1.188` shipped an interface without the code
 * that called it. Everything passed: the build was fresh, the entry point
 * imported, the tests were green — because the half that existed was correct.
 * The consumer installed it, called nothing, and captured no traffic for a day
 * before anyone noticed.
 *
 * No check can know what a change was meant to include. But that publish
 * happened from a DIRTY tree, mid-edit, and so did the risk. Requiring a clean
 * tree does not verify intent; it forces the publish to correspond to a commit
 * — something reviewable, revertable, and deliberate enough to notice you are
 * halfway through.
 *
 * Also refuses to republish a version that already exists, which silently
 * fails or, worse, quietly succeeds against a different registry.
 *
 * Set ALLOW_DIRTY_PUBLISH=1 to override, deliberately and visibly.
 */
const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

/**
 * No shell. The package name comes from package.json rather than a person, but
 * a name is still data and this file's whole purpose is to be a guard.
 */
function run(command, args) {
  return execFileSync(command, args, {
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
  }).trim();
}

function fail(message, hint) {
  console.error(`\n✖ refusing to publish: ${message}`);
  if (hint) console.error(`  ${hint}`);
  console.error("");
  process.exit(1);
}

const pkg = JSON.parse(readFileSync(join(process.cwd(), "package.json"), "utf8"));
const { name, version } = pkg;

// 1. A publish must correspond to a commit.
if (process.env.ALLOW_DIRTY_PUBLISH !== "1") {
  let status = "";
  try {
    status = run("git", ["status", "--porcelain"]);
  } catch {
    fail("not a git repository", "publish from the package's repo");
  }
  if (status) {
    const files = status.split("\n").slice(0, 10).join("\n    ");
    fail(
      `the working tree has uncommitted changes`,
      `Commit them first — a published artifact should match a commit.\n` +
        `  Shipping an interface without its caller is exactly what this catches.\n` +
        `    ${files}\n` +
        `  Override with ALLOW_DIRTY_PUBLISH=1 if you mean it.`
    );
  }
}

// 2. Never republish a version that already exists.
let published = "";
try {
  published = run("npm", ["view", name, "versions", "--json"]);
} catch {
  // A package that has never been published has no versions. That is fine.
  published = "";
}
if (published.includes(`"${version}"`)) {
  fail(
    `${name}@${version} is already published`,
    "Bump the version — republishing either fails or silently diverges."
  );
}

console.log(`✔ publish safety: ${name}@${version}, tree clean, version new`);
