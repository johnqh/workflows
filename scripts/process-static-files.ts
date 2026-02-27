#!/usr/bin/env tsx

/**
 * Generic static file template processor.
 *
 * Auto-discovers template files in the project and replaces {{...}} placeholders
 * with values from process.env (loaded from .env / .env.local).
 *
 * Template conventions:
 *   index_template.html        → index.html
 *   public/foo.template.bar    → public/foo.bar
 *
 * Built-in variables:
 *   {{TODAY}} → current date in YYYY-MM-DD format
 *
 * Usage:
 *   tsx process-static-files.ts                  # uses cwd
 *   tsx process-static-files.ts /path/to/project # uses specified dir
 */

import * as fs from 'fs';
import * as path from 'path';

// Project root: first CLI arg or cwd
const projectRoot = path.resolve(process.argv[2] || process.cwd());

/**
 * Parse a .env file and load variables into process.env.
 * Supports KEY=VALUE, KEY="VALUE", KEY='VALUE', comments (#), and blank lines.
 */
function loadEnvFile(filePath: string, override = false): void {
  if (!fs.existsSync(filePath)) return;

  const content = fs.readFileSync(filePath, 'utf8');
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) continue;

    const key = trimmed.slice(0, eqIndex).trim();
    let value = trimmed.slice(eqIndex + 1).trim();

    // Strip surrounding quotes
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }

    if (override || process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

// Load environment variables: .env first (defaults), then .env.local (overrides)
loadEnvFile(path.join(projectRoot, '.env'));
loadEnvFile(path.join(projectRoot, '.env.local'), true);

// Built-in variables
const TODAY = new Date().toISOString().split('T')[0];

interface TemplateFile {
  template: string; // absolute path to template
  output: string; // absolute path to output
  label: string; // display label
}

/**
 * Discover template files in the project.
 *
 * Looks for:
 *   - index_template.html at project root
 *   - *.template.* files in public/ (including subdirectories like .well-known/)
 */
function discoverTemplates(): TemplateFile[] {
  const templates: TemplateFile[] = [];

  // Check for index_template.html at project root
  const indexTemplate = path.join(projectRoot, 'index_template.html');
  if (fs.existsSync(indexTemplate)) {
    templates.push({
      template: indexTemplate,
      output: path.join(projectRoot, 'index.html'),
      label: 'index.html',
    });
  }

  // Scan public/ for *.template.* files (recursive)
  const publicDir = path.join(projectRoot, 'public');
  if (fs.existsSync(publicDir)) {
    scanForTemplates(publicDir, templates);
  }

  return templates;
}

/**
 * Recursively scan a directory for *.template.* files.
 */
function scanForTemplates(dir: string, templates: TemplateFile[]): void {
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);

    if (entry.isDirectory() && entry.name !== 'locales' && entry.name !== 'node_modules') {
      scanForTemplates(fullPath, templates);
    } else if (entry.isFile() && entry.name.includes('.template')) {
      let outputName: string;
      if (entry.name.includes('.template.')) {
        // foo.template.bar → foo.bar
        outputName = entry.name.replace('.template.', '.');
      } else if (entry.name.endsWith('.template')) {
        // foo.template → foo
        outputName = entry.name.replace('.template', '');
      } else {
        continue;
      }

      const outputPath = path.join(dir, outputName);
      const label = path.relative(projectRoot, outputPath);

      templates.push({
        template: fullPath,
        output: outputPath,
        label,
      });
    }
  }
}

/**
 * Replace all {{...}} placeholders in content.
 *
 * Resolution order:
 *   1. Built-in variables (TODAY)
 *   2. process.env
 */
function replaceVariables(content: string, filePath: string): string {
  const builtins: Record<string, string> = { TODAY };
  const warned = new Set<string>();

  return content.replace(/\{\{(\w+)\}\}/g, (match, varName) => {
    // Check built-ins first
    if (varName in builtins) {
      return builtins[varName];
    }

    // Check environment
    const envValue = process.env[varName];
    if (envValue !== undefined) {
      return envValue;
    }

    // Warn once per variable per file
    if (!warned.has(varName)) {
      warned.add(varName);
      const relPath = path.relative(projectRoot, filePath);
      console.warn(`  ⚠️  Unresolved: {{${varName}}} in ${relPath}`);
    }
    return match;
  });
}

/**
 * Process a single template file.
 */
function processFile(file: TemplateFile): boolean {
  try {
    const template = fs.readFileSync(file.template, 'utf8');
    const processed = replaceVariables(template, file.template);

    // Ensure output directory exists
    const outputDir = path.dirname(file.output);
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(file.output, processed, 'utf8');
    console.log(`  ✅ ${file.label}`);
    return true;
  } catch (error) {
    console.error(`  ❌ ${file.label}:`, error);
    return false;
  }
}

function main() {
  console.log('🔧 Processing static files...');
  console.log(`   Project: ${projectRoot}`);
  console.log('');

  const templates = discoverTemplates();

  if (templates.length === 0) {
    console.log('   No template files found.');
    return;
  }

  let succeeded = 0;
  let failed = 0;

  for (const file of templates) {
    if (processFile(file)) {
      succeeded++;
    } else {
      failed++;
    }
  }

  console.log('');
  console.log(`✨ Done! ${succeeded} processed${failed > 0 ? `, ${failed} failed` : ''}`);

  if (failed > 0) {
    process.exit(1);
  }
}

main();
