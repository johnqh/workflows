#!/usr/bin/env node
/**
 * Shared Localization Script
 *
 * Usage:
 *   node localize.cjs <locales-dir> [options]
 *
 * Arguments:
 *   locales-dir  Path to the locales directory (e.g., ./public/locales)
 *
 * Options:
 *   --llm-host <host>  LLM server host/IP (default: localhost)
 *   --llm-port <port>  LLM server port (default: 1234)
 *   --env <file>       Path to .env file
 *
 * Example:
 *   node ../workflows/scripts/localize.cjs ./public/locales
 *   node ../workflows/scripts/localize.cjs ./public/locales --llm-host 192.168.1.100
 *   node ../workflows/scripts/localize.cjs ./public/locales --llm-host 192.168.1.100 --llm-port 8080
 *   node ../workflows/scripts/localize.cjs ./public/locales --env ./.env.local
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');
const dotenv = require('dotenv');

// Parse CLI arguments
const args = process.argv.slice(2);

function printUsage() {
  console.error('Usage: node localize.cjs <locales-dir> [options]');
  console.error('');
  console.error('Arguments:');
  console.error('  locales-dir        Path to the locales directory (e.g., ./public/locales)');
  console.error('');
  console.error('Options:');
  console.error('  --llm-host <host>  LLM server host/IP (default: localhost)');
  console.error('  --llm-port <port>  LLM server port (default: 1234)');
  console.error('  --env <file>       Path to .env file');
  console.error('');
  console.error('Example:');
  console.error('  node ../workflows/scripts/localize.cjs ./public/locales');
  console.error('  node ../workflows/scripts/localize.cjs ./public/locales --llm-host 192.168.1.100');
}

// Parse options
let localesDir = null;
let envFile = null;
let llmHost = 'localhost';
let llmPort = '1234';

for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === '--llm-host' && args[i + 1]) {
    llmHost = args[++i];
  } else if (arg === '--llm-port' && args[i + 1]) {
    llmPort = args[++i];
  } else if (arg === '--env' && args[i + 1]) {
    envFile = path.resolve(process.cwd(), args[++i]);
  } else if (arg.startsWith('--')) {
    console.error(`Unknown option: ${arg}`);
    printUsage();
    process.exit(1);
  } else if (!localesDir) {
    localesDir = path.resolve(process.cwd(), arg);
  }
}

if (!localesDir) {
  printUsage();
  process.exit(1);
}

// Validate locales directory exists
if (!fs.existsSync(localesDir)) {
  console.error(`Error: Locales directory not found: ${localesDir}`);
  process.exit(1);
}

// Load environment variables from caller's directory
const callerEnvPath = path.join(process.cwd(), '.env');
const callerEnvLocalPath = path.join(process.cwd(), '.env.local');

if (fs.existsSync(callerEnvPath)) {
  dotenv.config({ path: callerEnvPath });
}
if (fs.existsSync(callerEnvLocalPath)) {
  dotenv.config({ path: callerEnvLocalPath, override: true });
}
// Override with specific env file if provided
if (envFile && fs.existsSync(envFile)) {
  dotenv.config({ path: envFile, override: true });
}

// Paths based on CLI argument
const sourceDir = path.join(localesDir, 'en');
const targetBaseDir = localesDir;

// Validate source directory exists
if (!fs.existsSync(sourceDir)) {
  console.error(`Error: Source directory not found: ${sourceDir}`);
  console.error('Expected English locale files in: <locales-dir>/en/');
  process.exit(1);
}

console.log('='.repeat(60));
console.log('Localization Script');
console.log('='.repeat(60));
console.log(`Source directory: ${sourceDir}`);
console.log(`Target base directory: ${targetBaseDir}`);
console.log(`LLM server: ${llmHost}:${llmPort}`);
console.log('='.repeat(60));

// List of target languages and their directory names
// Maps our i18n language codes to DeepL API language codes
const languages = {
  ar: 'AR', // Arabic
  de: 'DE', // German
  es: 'ES', // Spanish
  fr: 'FR', // French
  it: 'IT', // Italian
  ja: 'JA', // Japanese
  ko: 'KO', // Korean
  pt: 'PT', // Portuguese
  ru: 'RU', // Russian
  sv: 'SV', // Swedish
  th: 'TH', // Thai (DeepL supports this)
  uk: 'UK', // Ukrainian
  vi: 'VI', // Vietnamese (DeepL supports this)
  zh: 'ZH', // Chinese (Simplified)
  'zh-hant': 'ZH-HANT', // Chinese (Traditional)
};

// Helper function to add a delay
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Your DeepL API key
const DEEPL_API_KEY = process.env.VITE_APP_DEEPL_API_KEY;

if (!DEEPL_API_KEY) {
  console.error('Error: DEEPL_API_KEY environment variable not set.');
  console.error('Please set VITE_APP_DEEPL_API_KEY in your .env file.');
  process.exit(1);
}

// LM Studio Server configuration
const LM_STUDIO_URL = `http://${llmHost}:${llmPort}/v1`;

// Language name mapping for LM Studio
const languageNames = {
  AR: 'Arabic',
  DE: 'German',
  ES: 'Spanish',
  FR: 'French',
  IT: 'Italian',
  JA: 'Japanese',
  KO: 'Korean',
  PT: 'Portuguese',
  RU: 'Russian',
  SV: 'Swedish',
  TH: 'Thai',
  UK: 'Ukrainian',
  VI: 'Vietnamese',
  ZH: 'Chinese (Simplified)',
  'ZH-HANT': 'Chinese (Traditional)',
};

// Function to translate using LM Studio - handles both simple and complex strings
async function translateWithLMStudio(text, langCode, retryCount = 0) {
  const maxRetries = 3;
  const targetLanguage = languageNames[langCode] || langCode;

  console.log(`\n  LM Studio Translation to ${targetLanguage}:`);
  console.log(`     Original: "${text}"`);

  try {
    const requestPayload = {
      model: 'local-model',
      messages: [
        {
          role: 'system',
          content: `You are a professional translator. Translate the input text to ${targetLanguage}.

RULES:
1. Translate ONLY the exact meaning of the input - do not add, expand, or explain
2. Text inside <xx>...</xx> tags must be kept EXACTLY as-is (do not translate)
3. Output only the translation - no notes, no explanations, no additional content
4. If the input is short (a word or phrase), keep the output short
5. Do not extend beyond the meaning of the input

Examples:
Input: "Email"
Output: The word "Email" in ${targetLanguage}

Input: "Connect your <xx>MetaMask</xx> wallet"
Output: The phrase translated to ${targetLanguage}, keeping <xx>MetaMask</xx> unchanged`,
        },
        {
          role: 'user',
          content: text,
        },
      ],
      temperature: 0.1,
      max_tokens: 500, // Reduced from 2000 to prevent hallucinations
    };

    const response = await axios.post(`${LM_STUDIO_URL}/chat/completions`, requestPayload, {
      headers: { 'Content-Type': 'application/json' },
    });

    const translated = response.data.choices[0].message.content.trim();
    console.log(`     Translated: "${translated}"`);

    // ANTI-HALLUCINATION CHECK: Validate translation length
    const originalLength = text.length;
    const translatedLength = translated.length;
    const lengthRatio = translatedLength / originalLength;

    // If translation is more than 3x the original length, it's likely hallucinated
    const MAX_LENGTH_RATIO = 3.0;
    if (lengthRatio > MAX_LENGTH_RATIO) {
      console.warn(
        `     WARNING: Translation is ${lengthRatio.toFixed(1)}x longer than original!`
      );
      console.warn(`     Original: ${originalLength} chars, Translated: ${translatedLength} chars`);
      console.warn(`     This is likely a hallucination. Falling back to original text.`);
      return text; // Return original text instead of hallucinated translation
    }

    return translated;
  } catch (error) {
    // Enhanced error logging
    console.error(`\n     LM Studio Error Details:`);
    console.error(`        Status: ${error.response?.status || 'No response'}`);
    console.error(`        Message: ${error.message}`);
    if (error.response?.data) {
      console.error(`        Response Data:`, JSON.stringify(error.response.data, null, 2));
    }
    if (error.code) {
      console.error(`        Error Code: ${error.code}`);
    }

    if (retryCount < maxRetries) {
      console.warn(
        `     Retrying (attempt ${retryCount + 1}/${maxRetries}) in ${
          (retryCount + 1) * 2
        } seconds...`
      );
      await delay((retryCount + 1) * 2000);
      return translateWithLMStudio(text, langCode, retryCount + 1);
    }

    console.error(`     Max retries reached. Throwing error to trigger DeepL fallback.`);
    throw error; // Throw error to trigger fallback to DeepL
  }
}

// Function to translate text while preserving placeholders inside {}
async function translateWithPlaceholders(text, langCode, retryCount = 0) {
  const maxRetries = 5;
  const singleQuoteRegex = /{[^}]+}/g;
  const singleQuoteRegexPlaceholders = text.match(singleQuoteRegex) || [];

  const doubleQuoteRegex = /{{[^}]+}}/g;
  const doubleQuoteRegexRegexPlaceholders = text.match(doubleQuoteRegex) || [];

  let translatedText = text;

  // Replace placeholders with temporary markers
  singleQuoteRegexPlaceholders.forEach(placeholder => {
    translatedText = translatedText.replace(placeholder, `<xx>${placeholder}</xx>`);
  });

  // Replace placeholders with double {{}} with temporary markers
  doubleQuoteRegexRegexPlaceholders.forEach(placeholder => {
    translatedText = translatedText.replace(placeholder, `<xx>${placeholder}</xx>`);
  });

  // Get email domain and app name from environment variables
  const emailDomain = process.env.VITE_EMAIL_DOMAIN || 'example.com';
  const appName = process.env.VITE_APP_NAME || 'App';

  // Replace brand names and technical terms with temporary markers
  translatedText = translatedText.replace('.box', '<xx>.box</xx>');

  // Replace domain-specific terms (if emailDomain contains them, preserve them)
  if (emailDomain) {
    const domainRegex = new RegExp(emailDomain.replace('.', '\\.'), 'g');
    translatedText = translatedText.replace(domainRegex, `<xx>${emailDomain}</xx>`);
  }

  // Replace app name (preserve it)
  if (appName) {
    const appNameRegex = new RegExp(`\\b${appName}\\b`, 'g');
    translatedText = translatedText.replace(appNameRegex, `<xx>${appName}</xx>`);
  }

  // Preserve ISO 8601 duration codes (PT15M, PT2M, PT5M, etc.)
  translatedText = translatedText.replace(/PT\d+[SMHD]/g, match => `<xx>${match}</xx>`);

  // Preserve ISO 8601 datetime strings (2025-08-24T00:00:00Z, etc.)
  translatedText = translatedText.replace(
    /\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?/g,
    match => `<xx>${match}</xx>`
  );

  // Preserve technical blockchain/crypto terms
  const technicalTerms = ['Web3', 'DApp', 'dApp', 'NFT', 'DAO', 'DeFi', 'ENS', 'SNS'];
  technicalTerms.forEach(term => {
    const regex = new RegExp(`\\b${term}\\b`, 'g');
    translatedText = translatedText.replace(regex, match => `<xx>${match}</xx>`);
  });

  // Preserve wallet names
  const walletNames = [
    'MetaMask',
    'Phantom',
    'WalletConnect',
    'Coinbase Wallet',
    'Trust Wallet',
    'Ledger',
    'Trezor',
    'Rabby',
    'Rainbow',
    'Brave Wallet',
    'Frame',
    'Zerion',
  ];

  walletNames.forEach(walletName => {
    const regex = new RegExp(walletName, 'gi');
    translatedText = translatedText.replace(regex, match => `<xx>${match}</xx>`);
  });

  // Always try LM Studio first for all strings
  try {
    translatedText = await translateWithLMStudio(translatedText, langCode);
  } catch (lmError) {
    console.warn(
      `  LM Studio failed, falling back to DeepL for: "${text.substring(0, 50)}..."`
    );
    // Fallback to DeepL if LM Studio fails
    const hasPlaceholders = translatedText.includes('<xx>');

    if (hasPlaceholders) {
      // Use DeepL with XML tag handling for strings with placeholders
      const response = await axios.post(
        'https://api-free.deepl.com/v2/translate',
        new URLSearchParams({
          auth_key: DEEPL_API_KEY,
          text: translatedText,
          source_lang: 'EN',
          target_lang: langCode,
          tag_handling: 'xml',
          ignore_tags: 'xx',
        }),
        {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        }
      );
      translatedText = response.data.translations[0].text;
    } else {
      // Use DeepL without tag handling for simple strings
      const response = await axios.post(
        'https://api-free.deepl.com/v2/translate',
        new URLSearchParams({
          auth_key: DEEPL_API_KEY,
          text: translatedText,
          source_lang: 'EN',
          target_lang: langCode,
        }),
        {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        }
      );
      translatedText = response.data.translations[0].text;
    }
  }

  // Restore placeholders in the translated text
  translatedText = translatedText.replaceAll('<xx>', '').replaceAll('</xx>', '');

  // Clean RTL text to ensure no control characters that could affect JSON structure
  if (langCode === 'AR') {
    translatedText = cleanRTLText(translatedText);
  }

  return translatedText;
}

// Function to clean RTL text and remove problematic characters for JSON
function cleanRTLText(text) {
  // Remove any RTL/LTR control characters that could interfere with JSON parsing
  return text
    .replace(/[\u200E\u200F\u202A-\u202E]/g, '') // Remove directional control characters
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, '') // Remove control characters
    .replace(/[\u061C]/g, '') // Remove Arabic Letter Mark
    .replace(/[\uFEFF]/g, '') // Remove Byte Order Mark
    .trim();
}

// Function to sanitize entire object for RTL languages
function sanitizeObjectForRTL(obj, langCode) {
  if (langCode !== 'AR') return obj;

  function sanitizeValue(value) {
    if (typeof value === 'string') {
      return cleanRTLText(value);
    } else if (Array.isArray(value)) {
      return value.map(sanitizeValue);
    } else if (typeof value === 'object' && value !== null) {
      const sanitizedObj = {};
      for (const [key, val] of Object.entries(value)) {
        sanitizedObj[key] = sanitizeValue(val);
      }
      return sanitizedObj;
    }
    return value;
  }

  return sanitizeValue(obj);
}

// Recursive function to translate all string values in a JSON object
async function translateObject(obj, langCode, existingTranslations = {}, path = '') {
  const translatedObj = {};
  let translationCount = 0;
  let skippedCount = 0;

  for (const [key, value] of Object.entries(obj)) {
    const currentPath = path ? `${path}.${key}` : key;

    if (typeof value === 'string') {
      // Empty strings should stay empty - no translation needed
      if (value === '') {
        translatedObj[key] = '';
        skippedCount++;
        console.log(`  Skipped "${currentPath}" (empty string)`);
        continue;
      }

      // Check if the key already has a valid translation (non-empty string)
      const hasValidTranslation =
        existingTranslations[key] &&
        typeof existingTranslations[key] === 'string' &&
        existingTranslations[key].trim() !== '';

      if (hasValidTranslation) {
        translatedObj[key] = existingTranslations[key];
        skippedCount++;
        console.log(`  Skipped "${currentPath}" (already translated)`);
      } else {
        try {
          translatedObj[key] = await translateWithPlaceholders(value, langCode);
          translationCount++;
          console.log(`  Translated "${currentPath}"`);
          await delay(200); // Add a delay of 200ms between requests to avoid rate limiting
        } catch (error) {
          console.error(`    Error translating "${currentPath}":`, error.message);
          // If it's a rate limit error after max retries, fail the entire process
          if (error.message.includes('Rate limit exceeded')) {
            throw error;
          }
          translatedObj[key] = value; // Fallback to original for other errors
        }
      }
    } else if (Array.isArray(value)) {
      // Handle arrays - translate each string element
      const hasValidArrayTranslation =
        existingTranslations[key] &&
        Array.isArray(existingTranslations[key]) &&
        existingTranslations[key].length === value.length;

      if (hasValidArrayTranslation) {
        // Check if all string array elements are valid (non-empty)
        // For non-string elements (objects, etc.), we consider them valid if they exist
        const allElementsValid = existingTranslations[key].every((item, idx) => {
          if (typeof item === 'string') {
            return item.trim() !== '';
          } else if (typeof item === 'object' && item !== null) {
            // Objects are valid if they exist and match the source structure
            return typeof value[idx] === 'object';
          } else {
            // Other types (numbers, booleans) are valid if they match
            return true;
          }
        });

        if (allElementsValid) {
          translatedObj[key] = existingTranslations[key];
          skippedCount++;
          console.log(`  Skipped array "${currentPath}" (already translated)`);
        } else {
          // Re-translate if any element is invalid
          translatedObj[key] = [];
          for (let i = 0; i < value.length; i++) {
            const item = value[i];
            if (typeof item === 'string') {
              try {
                translatedObj[key][i] = await translateWithPlaceholders(item, langCode);
                translationCount++;
                console.log(`  Translated array "${currentPath}[${i}]"`);
                await delay(200);
              } catch (error) {
                console.error(
                  `    Error translating array "${currentPath}[${i}]":`,
                  error.message
                );
                if (error.message.includes('Rate limit exceeded')) {
                  throw error;
                }
                translatedObj[key][i] = item;
              }
            } else if (typeof item === 'object' && item !== null) {
              const result = await translateObject(item, langCode, {}, `${currentPath}[${i}]`);
              translatedObj[key][i] = result.obj;
              translationCount += result.count;
              skippedCount += result.skipped;
            } else {
              translatedObj[key][i] = item;
            }
          }
        }
      } else {
        translatedObj[key] = [];
        for (let i = 0; i < value.length; i++) {
          const item = value[i];
          if (typeof item === 'string') {
            try {
              translatedObj[key][i] = await translateWithPlaceholders(item, langCode);
              translationCount++;
              console.log(`  Translated array "${currentPath}[${i}]"`);
              await delay(200); // Add a delay of 200ms between requests to avoid rate limiting
            } catch (error) {
              console.error(
                `    Error translating array "${currentPath}[${i}]":`,
                error.message
              );
              // If it's a rate limit error after max retries, fail the entire process
              if (error.message.includes('Rate limit exceeded')) {
                throw error;
              }
              translatedObj[key][i] = item; // Fallback to original for other errors
            }
          } else if (typeof item === 'object' && item !== null) {
            // Handle objects within arrays
            const result = await translateObject(item, langCode, {}, `${currentPath}[${i}]`);
            translatedObj[key][i] = result.obj;
            translationCount += result.count;
            skippedCount += result.skipped;
          } else {
            // Preserve non-string, non-object values as-is
            translatedObj[key][i] = item;
          }
        }
      }
    } else if (typeof value === 'object' && value !== null) {
      // Recursively translate nested objects
      const result = await translateObject(
        value,
        langCode,
        existingTranslations[key] || {},
        currentPath
      );
      translatedObj[key] = result.obj;
      translationCount += result.count;
      skippedCount += result.skipped;
    } else {
      // Preserve non-string values as-is
      translatedObj[key] = value;
    }
  }

  return { obj: translatedObj, count: translationCount, skipped: skippedCount };
}

async function translateFiles() {
  try {
    // Read all files in the source directory
    const files = fs.readdirSync(sourceDir);
    const jsonFiles = files.filter(file => path.extname(file) === '.json');

    console.log(`Found ${jsonFiles.length} JSON files to translate`);
    console.log(`Target languages: ${Object.keys(languages).join(', ')}`);
    console.log('='.repeat(60));

    for (const file of jsonFiles) {
      const sourceFile = path.join(sourceDir, file);

      console.log(`\nProcessing file: ${file}`);
      console.log('-'.repeat(40));

      const content = JSON.parse(fs.readFileSync(sourceFile, 'utf8'));

      // Process each language sequentially for this file
      for (const [langDir, langCode] of Object.entries(languages)) {
        console.log(`\nTranslating to ${langDir.toUpperCase()} (${langCode})...`);

        const targetDir = path.join(targetBaseDir, langDir);
        const targetFile = path.join(targetDir, file);

        // Ensure the target directory exists
        fs.mkdirSync(targetDir, { recursive: true });

        // Load existing translations if the target file exists
        let existingTranslations = {};
        if (fs.existsSync(targetFile)) {
          existingTranslations = JSON.parse(fs.readFileSync(targetFile, 'utf8'));
          console.log(`  Loaded existing translations for ${langDir}`);
        } else {
          console.log(`  Creating new translation file for ${langDir}`);
        }

        try {
          // Translate the entire JSON object
          const result = await translateObject(content, langCode, existingTranslations);
          let translatedContent = result.obj;
          const newTranslations = result.count;
          const skippedTranslations = result.skipped;

          // Sanitize RTL languages to prevent JSON corruption
          translatedContent = sanitizeObjectForRTL(translatedContent, langCode);

          // Write the translated content to the target file
          const jsonString = JSON.stringify(translatedContent, null, 2);

          // For RTL languages, validate JSON integrity before writing
          if (langCode === 'AR') {
            try {
              JSON.parse(jsonString); // Validate JSON can be parsed
              console.log(`  JSON validation passed for Arabic`);
            } catch (jsonError) {
              console.error(`  JSON validation failed for Arabic: ${jsonError.message}`);
              throw new Error(
                `Invalid JSON structure for Arabic translation: ${jsonError.message}`
              );
            }
          }

          fs.writeFileSync(targetFile, jsonString, 'utf8');
          console.log(
            `  Successfully saved: ${targetFile} (${newTranslations} new, ${skippedTranslations} skipped)`
          );
        } catch (error) {
          console.error(`  Error translating ${file} to ${langDir}:`, error.message);
          // Continue with next language instead of stopping completely
        }
      }

      console.log(`\nCompleted processing ${file}`);
      console.log('='.repeat(60));
    }

    console.log('\nAll files translation process completed!');
  } catch (error) {
    console.error('Error processing files:', error);
    process.exit(1);
  }
}

translateFiles();
