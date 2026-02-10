#!/usr/bin/env node
/**
 * Batch Localization Script (Translation API)
 *
 * Translates all missing locale strings using a batch translation API.
 * Groups strings together and translates to all target languages in one pass,
 * limiting total translations (strings × languages) to a configurable batch size.
 *
 * Usage:
 *   node localize_batch.cjs <locales-dir> <endpoint-url> [options]
 *
 * Arguments:
 *   locales-dir    Path to the locales directory (e.g., ./public/locales)
 *   endpoint-url   Translation API endpoint URL
 *
 * Options:
 *   --api-key <key>    API key for Bearer token auth (or set WHISPERLY_API_KEY env var)
 *   --env <file>       Path to .env file
 *   --batch-limit <n>  Max total translations per API call (strings × languages, default: 400)
 *
 * Example:
 *   node localize_batch.cjs ./public/locales https://api.whisperly.dev/api/v1/translate/xxx/yyy
 *   node localize_batch.cjs ./public/locales https://api.whisperly.dev/api/v1/translate/xxx/yyy --api-key wh_xxx
 *   node localize_batch.cjs ./public/locales https://api.whisperly.dev/api/v1/translate/xxx/yyy --env ./.env.local
 */

const fs = require('fs');
const path = require('path');

// --- CLI Argument Parsing ---

const args = process.argv.slice(2);

function printUsage() {
  console.error('Usage: node localize_batch.cjs <locales-dir> <endpoint-url> [options]');
  console.error('');
  console.error('Arguments:');
  console.error('  locales-dir        Path to the locales directory (e.g., ./public/locales)');
  console.error('  endpoint-url       Translation API endpoint URL');
  console.error('');
  console.error('Options:');
  console.error('  --api-key <key>    API key for Bearer auth (or set WHISPERLY_API_KEY env var)');
  console.error('  --env <file>       Path to .env file');
  console.error('  --batch-limit <n>  Max translations per API call (strings × languages, default: 100)');
}

let localesDir = null;
let endpointUrl = null;
let apiKey = null;
let envFile = null;
let batchLimit = 100;

for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === '--api-key' && args[i + 1]) {
    apiKey = args[++i];
  } else if (arg === '--env' && args[i + 1]) {
    envFile = path.resolve(process.cwd(), args[++i]);
  } else if (arg === '--batch-limit' && args[i + 1]) {
    batchLimit = parseInt(args[++i], 10);
  } else if (arg === '--help' || arg === '-h') {
    printUsage();
    process.exit(0);
  } else if (arg.startsWith('--')) {
    console.error(`Unknown option: ${arg}`);
    printUsage();
    process.exit(1);
  } else if (!localesDir) {
    localesDir = path.resolve(process.cwd(), arg);
  } else if (!endpointUrl) {
    endpointUrl = arg;
  }
}

if (!localesDir || !endpointUrl) {
  printUsage();
  process.exit(1);
}

if (!fs.existsSync(localesDir)) {
  console.error(`Error: Locales directory not found: ${localesDir}`);
  process.exit(1);
}

// --- Environment Setup ---

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  const content = fs.readFileSync(filePath, 'utf8');
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    let val = trimmed.slice(eqIdx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    process.env[key] = val;
  }
}

loadEnvFile(path.join(process.cwd(), '.env'));
loadEnvFile(path.join(process.cwd(), '.env.local'));
if (envFile) loadEnvFile(envFile);

if (!apiKey) apiKey = process.env.WHISPERLY_API_KEY;
if (!apiKey) {
  console.error('Error: API key not provided. Use --api-key or set WHISPERLY_API_KEY env var.');
  process.exit(1);
}

// --- Source / Target Setup ---

const sourceDir = path.join(localesDir, 'en');

if (!fs.existsSync(sourceDir)) {
  console.error(`Error: Source directory not found: ${sourceDir}`);
  console.error('Expected English locale files in: <locales-dir>/en/');
  process.exit(1);
}

const targetLanguages = [
  'ar', 'de', 'es', 'fr', 'it', 'ja', 'ko',
  'pt', 'ru', 'sv', 'th', 'uk', 'vi', 'zh', 'zh-hant',
];

console.log('='.repeat(60));
console.log('Batch Localization Script');
console.log('='.repeat(60));
console.log(`Source: ${sourceDir}`);
console.log(`Endpoint: ${endpointUrl}`);
console.log(`Batch limit: ${batchLimit} (strings × languages)`);
console.log(`Languages: ${targetLanguages.join(', ')}`);
console.log('='.repeat(60));

// --- RTL Cleaning ---

function cleanRTLText(text) {
  return text
    .replace(/[\u200E\u200F\u202A-\u202E]/g, '')
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, '')
    .replace(/[\u061C]/g, '')
    .replace(/[\uFEFF]/g, '')
    .trim();
}

// --- JSON Traversal Helpers ---

function flattenStrings(obj, prefix = '') {
  const result = [];
  for (const [key, value] of Object.entries(obj)) {
    const p = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'string') {
      result.push({ path: p, value });
    } else if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        if (typeof value[i] === 'string') {
          result.push({ path: `${p}[${i}]`, value: value[i] });
        } else if (typeof value[i] === 'object' && value[i] !== null) {
          result.push(...flattenStrings(value[i], `${p}[${i}]`));
        }
      }
    } else if (typeof value === 'object' && value !== null) {
      result.push(...flattenStrings(value, p));
    }
  }
  return result;
}

function getNestedValue(obj, dotPath) {
  const parts = dotPath.replace(/\[(\d+)\]/g, '.$1').split('.');
  let current = obj;
  for (const part of parts) {
    if (current == null) return undefined;
    current = current[part];
  }
  return current;
}

/**
 * Build a target translation object by walking the source structure.
 * For each leaf string: use existing translation if valid, else use new translation, else fallback to source.
 */
function buildTargetObject(source, existing, newTranslations, lang, prefix = '') {
  if (typeof source === 'string') {
    if (source === '') return '';
    // Use existing valid translation
    if (existing && typeof existing === 'string' && existing.trim() !== '') {
      return existing;
    }
    // Use new translation
    if (newTranslations[prefix] != null) {
      let translated = newTranslations[prefix];
      if (lang === 'ar') translated = cleanRTLText(translated);
      return translated;
    }
    // Fallback to source
    return source;
  }

  if (Array.isArray(source)) {
    return source.map((item, i) => {
      const itemPath = `${prefix}[${i}]`;
      if (typeof item === 'string') {
        return buildTargetObject(item, existing?.[i], newTranslations, lang, itemPath);
      }
      if (typeof item === 'object' && item !== null) {
        return buildTargetObject(item, existing?.[i], newTranslations, lang, itemPath);
      }
      return item;
    });
  }

  if (typeof source === 'object' && source !== null) {
    const result = {};
    for (const [key, value] of Object.entries(source)) {
      const p = prefix ? `${prefix}.${key}` : key;
      result[key] = buildTargetObject(value, existing?.[key], newTranslations, lang, p);
    }
    return result;
  }

  return source;
}

// --- API Call ---

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function translateBatch(strings, targetLangs, retryCount = 0) {
  const maxRetries = 3;
  try {
    const payload = { strings, target_languages: targetLangs };
    const payloadJson = JSON.stringify(payload);
    const curlCmd = `curl -X POST '${endpointUrl}' \\\n` +
      `  -H 'Authorization: Bearer ${apiKey}' \\\n` +
      `  -H 'Content-Type: application/json' \\\n` +
      `  -d '${payloadJson.replace(/'/g, "'\\''")}'`;
    console.log(`  cURL:\n${curlCmd}`);

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 120000);

    const response = await fetch(endpointUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    clearTimeout(timeout);

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${await response.text()}`);
    }

    const data = await response.json();
    console.log(`  Response: success=${data.success}, languages=[${Object.keys(data.data?.translations || {}).join(', ')}]`);

    if (!data.success) {
      throw new Error(`API returned success=false: ${JSON.stringify(data)}`);
    }

    return data.data.translations;
  } catch (error) {
    if (retryCount < maxRetries) {
      const waitSec = (retryCount + 1) * 3;
      console.warn(
        `  API error: ${error.message}. Retrying in ${waitSec}s (${retryCount + 1}/${maxRetries})...`
      );
      await delay(waitSec * 1000);
      return translateBatch(strings, targetLangs, retryCount + 1);
    }
    throw error;
  }
}

// --- Main ---

async function main() {
  const files = fs.readdirSync(sourceDir).filter(f => f.endsWith('.json'));
  console.log(`\nFound ${files.length} JSON file(s) to process\n`);

  let totalNew = 0;
  let totalSkipped = 0;

  for (const file of files) {
    console.log(`Processing: ${file}`);
    console.log('-'.repeat(40));

    const sourceContent = JSON.parse(fs.readFileSync(path.join(sourceDir, file), 'utf8'));
    const allStrings = flattenStrings(sourceContent);

    // Load existing translations for each language
    const existingByLang = {};
    for (const lang of targetLanguages) {
      const targetFile = path.join(localesDir, lang, file);
      if (fs.existsSync(targetFile)) {
        existingByLang[lang] = JSON.parse(fs.readFileSync(targetFile, 'utf8'));
      } else {
        existingByLang[lang] = {};
      }
    }

    // Find which paths are missing per language
    const missingPathsByLang = {};
    const allMissingPaths = new Set();

    for (const lang of targetLanguages) {
      missingPathsByLang[lang] = new Set();
      for (const { path: p, value } of allStrings) {
        if (value === '') continue;
        const existing = getNestedValue(existingByLang[lang], p);
        if (!existing || (typeof existing === 'string' && existing.trim() === '')) {
          missingPathsByLang[lang].add(p);
          allMissingPaths.add(p);
        }
      }
    }

    // Collect entries that need translation (source order, unique by path)
    const missingEntries = allStrings.filter(e => allMissingPaths.has(e.path) && e.value !== '');

    if (missingEntries.length === 0) {
      console.log('  No missing translations, skipping.\n');
      totalSkipped += allStrings.filter(e => e.value !== '').length * targetLanguages.length;
      continue;
    }

    // Only translate to languages that actually have gaps
    const langsWithMissing = targetLanguages.filter(lang => missingPathsByLang[lang].size > 0);

    console.log(
      `  ${missingEntries.length} string(s) to translate across ${langsWithMissing.length} language(s)`
    );

    // Calculate batch size: strings per API call = floor(limit / num_languages)
    const batchSize = Math.max(1, Math.floor(batchLimit / langsWithMissing.length));
    const totalBatches = Math.ceil(missingEntries.length / batchSize);
    console.log(`  Batch size: ${batchSize} strings, ${totalBatches} batch(es)`);

    // Store translations: translationsByLang[lang][path] = translated string
    const translationsByLang = {};
    for (const lang of langsWithMissing) {
      translationsByLang[lang] = {};
    }

    for (let i = 0; i < missingEntries.length; i += batchSize) {
      const batch = missingEntries.slice(i, i + batchSize);
      const batchNum = Math.floor(i / batchSize) + 1;

      const stringsToSend = batch.map(e => e.value);

      console.log(`  Batch ${batchNum}/${totalBatches}: translating ${batch.length} string(s)...`);

      try {
        const translations = await translateBatch(stringsToSend, langsWithMissing);

        for (const lang of langsWithMissing) {
          const translated = translations[lang];
          if (!translated) {
            console.warn(`  Warning: no translations returned for ${lang}`);
            continue;
          }
          for (let j = 0; j < batch.length; j++) {
            translationsByLang[lang][batch[j].path] = translated[j];
          }
        }
      } catch (error) {
        console.error(`  Error in batch ${batchNum}: ${error.message}`);
      }
    }

    // Write translated files
    for (const lang of targetLanguages) {
      const targetDir = path.join(localesDir, lang);
      fs.mkdirSync(targetDir, { recursive: true });

      const targetObj = buildTargetObject(
        sourceContent,
        existingByLang[lang],
        translationsByLang[lang] || {},
        lang
      );

      const targetFile = path.join(targetDir, file);
      const jsonString = JSON.stringify(targetObj, null, 2);

      // Validate JSON for Arabic (RTL)
      if (lang === 'ar') {
        try {
          JSON.parse(jsonString);
        } catch (jsonError) {
          console.error(`  JSON validation failed for Arabic: ${jsonError.message}`);
          continue;
        }
      }

      fs.writeFileSync(targetFile, jsonString, 'utf8');

      const newCount = missingPathsByLang[lang].size;
      const skippedCount = allStrings.filter(e => e.value !== '').length - newCount;
      totalNew += newCount;
      totalSkipped += skippedCount;

      if (newCount > 0) {
        console.log(`  ${lang}: ${newCount} new, ${skippedCount} existing`);
      }
    }

    console.log(`  Done: ${file}\n`);
  }

  console.log('='.repeat(60));
  console.log(`Completed! ${totalNew} new translations, ${totalSkipped} existing.`);
  console.log('='.repeat(60));
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
