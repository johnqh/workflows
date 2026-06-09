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
 *   --batch-limit <n>  Max total translations per API call (strings × languages, default: 50)
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
  console.error('  --batch-limit <n>  Max translations per API call (strings × languages, default: 50)');
  console.error('  --lang-batch <n>   Max languages per API call (default: all at once)');
  console.error('  --word-limit <n>   Target words × languages per API call (default: 40).')
  console.error('                     Controls batching only — all strings are always translated.');
}

let localesDir = null;
let endpointUrl = null;
let apiKey = null;
let envFile = null;
let batchLimit = 50;
let langBatch = 0; // 0 = all languages at once
let wordLimit = 40; // max words × languages per API call

for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === '--api-key' && args[i + 1]) {
    apiKey = args[++i];
  } else if (arg === '--env' && args[i + 1]) {
    envFile = path.resolve(process.cwd(), args[++i]);
  } else if (arg === '--batch-limit' && args[i + 1]) {
    batchLimit = parseInt(args[++i], 10);
  } else if (arg === '--lang-batch' && args[i + 1]) {
    langBatch = parseInt(args[++i], 10);
  } else if (arg === '--word-limit' && args[i + 1]) {
    wordLimit = parseInt(args[++i], 10);
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
  'de', 'es', 'fr', 'it', 'ja', 'ko',
  'pt', 'ru', 'sv', 'th', 'uk', 'vi', 'zh', 'zh-hant',
];

console.log('='.repeat(60));
console.log('Batch Localization Script');
console.log('='.repeat(60));
console.log(`Source: ${sourceDir}`);
console.log(`Endpoint: ${endpointUrl}`);
console.log(`Batch limit: ${batchLimit} (strings × languages)`);
console.log(`Lang batch: ${langBatch || 'all'} languages per API call`);
console.log(`Word limit: ${wordLimit} (words × languages per API call)`);
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
  // Handle top-level arrays with bracket notation to match buildTargetObject
  if (Array.isArray(obj)) {
    const result = [];
    for (let i = 0; i < obj.length; i++) {
      const p = `${prefix}[${i}]`;
      if (typeof obj[i] === 'string') {
        result.push({ path: p, value: obj[i] });
      } else if (typeof obj[i] === 'object' && obj[i] !== null) {
        result.push(...flattenStrings(obj[i], p));
      }
    }
    return result;
  }
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
    // No translation available — omit from output so the key stays
    // "missing" for the next run. i18next will fall back to the source
    // language at runtime.
    return undefined;
  }

  if (Array.isArray(source)) {
    return source.map((item, i) => {
      const itemPath = `${prefix}[${i}]`;
      if (typeof item === 'string') {
        const built = buildTargetObject(item, existing?.[i], newTranslations, lang, itemPath);
        // In arrays, fall back to source string to preserve array shape
        return built !== undefined ? built : item;
      }
      if (typeof item === 'object' && item !== null) {
        const built = buildTargetObject(item, existing?.[i], newTranslations, lang, itemPath);
        // In arrays, fall back to source object to preserve array shape
        return built !== undefined ? built : item;
      }
      return item;
    });
  }

  if (typeof source === 'object' && source !== null) {
    const result = {};
    for (const [key, value] of Object.entries(source)) {
      const p = prefix ? `${prefix}.${key}` : key;
      const built = buildTargetObject(value, existing?.[key], newTranslations, lang, p);
      if (built !== undefined) {
        result[key] = built;
      }
    }
    return Object.keys(result).length > 0 ? result : undefined;
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

    const startTime = Date.now();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 300000);

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
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log(`  Response: success=${data.success}, languages=[${Object.keys(data.data?.translations || {}).join(', ')}] (${elapsed}s)`);

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

    // Word count helper
    const countWords = (s) => s.split(/\s+/).filter(Boolean).length;

    console.log(`  Will batch dynamically based on word limit (${wordLimit} words × languages)`);

    // Store translations: translationsByLang[lang][path] = translated string
    const translationsByLang = {};
    for (const lang of langsWithMissing) {
      translationsByLang[lang] = {};
    }

    // Helper: save all translated files for this source file
    function saveTranslatedFiles() {
      for (const lang of targetLanguages) {
        const targetDir = path.join(localesDir, lang);
        fs.mkdirSync(targetDir, { recursive: true });

        const targetObj = buildTargetObject(
          sourceContent,
          existingByLang[lang],
          translationsByLang[lang] || {},
          lang
        );

        if (targetObj === undefined) continue;

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
      }
    }

    // Translate one string at a time, splitting languages based on word count.
    // For each string: langsPerCall = max(floor(wordLimit / wordCount), 1)
    // So a 5-word string gets all 15 langs at once, a 40-word string gets 2 at a time.
    for (let i = 0; i < missingEntries.length; i++) {
      const entry = missingEntries[i];
      const words = countWords(entry.value);
      const langsPerCall = Math.max(Math.floor(wordLimit / Math.max(words, 1)), 1);

      // Split languages into chunks
      const langChunks = [];
      for (let l = 0; l < langsWithMissing.length; l += langsPerCall) {
        langChunks.push(langsWithMissing.slice(l, l + langsPerCall));
      }

      for (let lc = 0; lc < langChunks.length; lc++) {
        const langChunk = langChunks[lc];
        const langLabel = langChunks.length > 1 ? ` [langs ${lc + 1}/${langChunks.length}]` : '';

        console.log(`  ${i + 1}/${missingEntries.length}${langLabel}: ~${words} words × ${langChunk.length} lang(s)`);

        try {
          const translations = await translateBatch([entry.value], langChunk);

          for (const lang of langChunk) {
            const translated = translations[lang];
            if (!translated || !translated[0]) {
              console.warn(`  Warning: no translation returned for ${lang}`);
              continue;
            }
            translationsByLang[lang][entry.path] = translated[0];
          }
        } catch (error) {
          console.error(`  FATAL: API failed at string ${i + 1}${langLabel}: ${error.message}`);
          console.error('  Saving translations from completed strings before stopping...');
          saveTranslatedFiles();
          process.exit(1);
        }

        // Save after each API call so progress is preserved
        saveTranslatedFiles();
      }
    }

    // Final stats
    for (const lang of targetLanguages) {
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
