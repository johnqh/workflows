#!/usr/bin/env node

/**
 * SEO asset generator for multilingual static sites — v2.
 *
 * Successor to generate-seo-assets.mjs. The original script remains in place so
 * existing projects keep their current behavior; adopt this one when you want:
 *
 *   - A sitemap INDEX (sitemap.xml) that points at per-language child sitemaps
 *     (sitemap-<lang>.xml), English listed first. Each child carries only its own
 *     language's <loc> entries plus the full hreflang cluster. This lets you submit
 *     the English sitemap first in Search Console so the English pages are crawled
 *     and indexed ahead of translations (mitigates "Crawled - currently not indexed"
 *     across large multilingual URL sets) while keeping every language discoverable.
 *   - Managed <head> injection (buildManagedMetaBlock / stripManagedHead) instead of
 *     per-tag regex replacement.
 *   - Route-level staticHtml() and structuredData() hooks for crawlable fallback
 *     content and JSON-LD.
 *   - cleanText + unresolved-placeholder assertion on meta fields.
 *   - Trailing-slash control (trailingSlashUrls).
 *   - A richer robots.txt covering standard + AI crawlers.
 *
 * NOTE: consumers that read sitemap.xml as a flat <urlset> (e.g. a prerender step
 * that extracts <loc> page URLs) must be taught to resolve a <sitemapindex> to its
 * child sitemaps — sitemap.xml's <loc>s are now child-sitemap files, not pages.
 *
 * Generates per-route, per-language index.html files with localized meta tags,
 * canonical URLs, hreflang alternates, the sitemap set, and robots.txt.
 *
 * Reads project-specific configuration from ./seo.config.mjs (or --config path).
 *
 * Usage:
 *   node generate-seo-assets-v2.mjs [target-dir]
 *   node generate-seo-assets-v2.mjs --config ./seo.config.mjs public
 *   node generate-seo-assets-v2.mjs dist
 *
 * Config file (seo.config.mjs) must export:
 *   supportedLanguages  - string[] e.g. ['en', 'ar', 'de', ...]
 *   languageHreflangMap - Record<string, string> e.g. { zh: 'zh-Hans' }
 *   primaryDomain       - string e.g. 'example.com'
 *   routes              - Route[] with: key, path, namespace, priority, changefreq,
 *                         indexable, meta(locale) => { title, description, keywords }
 *
 * Optional config fields:
 *   appName             - string (default: VITE_APP_NAME env || primaryDomain)
 *   appDomain           - string (default: VITE_APP_DOMAIN env || primaryDomain)
 *   robotsDisallowPaths - string[] (default: ['/<star>/dashboard/', '/<star>/login'])
 *   localesDir          - string (default: 'public/locales')
 *   interpolationVars   - Record<string, string> extra {{var}} replacements
 *   trailingSlashUrls   - boolean (default: true) append slash to generated canonical URLs
 *   stripPatterns       - RegExp[] extra patterns to strip from base HTML
 *   staticHtml(locale, ctx, route) => string  route-specific crawlable fallback HTML
 *   structuredData(locale, ctx, route) => object[] route-specific JSON-LD
 *
 * Optional per-route fields:
 *   namespaces          - string[] locale namespaces to merge (default: [route.namespace])
 *   canonicalPath       - string  path used for canonical/hreflang instead of route.path
 *   ogType              - string  og:type for this route (default: 'website')
 *   staticHtml          - per-route override of the config-level staticHtml hook
 *   structuredData      - per-route override of the config-level structuredData hook
 */

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs() {
  const args = process.argv.slice(2);
  let configPath = path.resolve('seo.config.mjs');
  const positional = [];

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && i + 1 < args.length) {
      configPath = path.resolve(args[++i]);
    } else if (!args[i].startsWith('--')) {
      positional.push(args[i]);
    }
  }

  return { configPath, targetDir: positional[0] || 'public' };
}

// ---------------------------------------------------------------------------
// Config loading
// ---------------------------------------------------------------------------

async function loadConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    console.error(`Config file not found: ${configPath}`);
    console.error('Create seo.config.mjs in your project root or use --config <path>');
    process.exit(1);
  }
  const mod = await import(pathToFileURL(configPath).href);
  return mod.default || mod;
}

function buildContext(config) {
  const appName = config.appName || process.env.VITE_APP_NAME || config.primaryDomain;
  const appDomain = config.appDomain || process.env.VITE_APP_DOMAIN || config.primaryDomain;
  const today = new Date().toISOString().slice(0, 10);
  const baseUrl = `https://${appDomain}`;
  const productionBaseUrl = `https://${config.primaryDomain}`;
  const isNonProductionHost =
    appDomain !== config.primaryDomain ||
    appDomain.startsWith('dev.') ||
    appDomain.includes('staging') ||
    appDomain.includes('preview');

  const vars = {
    appName,
    VITE_APP_NAME: appName,
    date: today,
    TODAY: today,
    ...(config.interpolationVars || {}),
  };

  return {
    supportedLanguages: config.supportedLanguages,
    languageHreflangMap: config.languageHreflangMap,
    primaryDomain: config.primaryDomain,
    routes: config.routes,
    appName,
    appDomain,
    today,
    baseUrl,
    productionBaseUrl,
    isNonProductionHost,
    trailingSlashUrls: config.trailingSlashUrls !== false,
    localesDir: config.localesDir || 'public/locales',
    robotsDisallowPaths: config.robotsDisallowPaths || ['/*/dashboard/', '/*/login'],
    stripPatterns: config.stripPatterns || [],
    vars,
  };
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function escapeJsonForHtml(value) {
  return JSON.stringify(value).replaceAll('</script', '<\\/script');
}

function stripHtml(value) {
  return String(value).replace(/<[^>]*>/g, '');
}

function normalizeWhitespace(value) {
  return String(value).replace(/\s+/g, ' ').trim();
}

function cleanText(value) {
  return normalizeWhitespace(
    stripHtml(String(value || '').replace(/\{\{\s*([^{}\s]+)\s*\}\}/g, '$1'))
  );
}

function defaultStaticHtml({ title, description }) {
  if (!title && !description) {
    return '';
  }

  return [
    '      <main class="seo-static-content" data-static-seo="true">',
    '        <article>',
    title ? `          <h1>${escapeHtml(title)}</h1>` : '',
    description ? `          <p>${escapeHtml(description)}</p>` : '',
    '        </article>',
    '      </main>',
  ]
    .filter(Boolean)
    .join('\n');
}

function assertNoUnresolvedPlaceholders(route, language, fields) {
  const issues = [];
  for (const [field, value] of Object.entries(fields)) {
    const text = Array.isArray(value) ? value.join(', ') : String(value || '');
    if (/\{\{[^}]*\}\}?/.test(text)) {
      issues.push(`${field}: ${text}`);
    }
  }

  if (issues.length > 0) {
    throw new Error(
      `Unresolved SEO placeholders for ${language}${route.path || '/'}:\n${issues.join('\n')}`
    );
  }
}

function deepMerge(baseValue, overrideValue) {
  if (Array.isArray(baseValue) || Array.isArray(overrideValue)) {
    if (Array.isArray(overrideValue) && overrideValue.length > 0) {
      return overrideValue;
    }
    return baseValue ?? overrideValue;
  }

  if (
    baseValue &&
    overrideValue &&
    typeof baseValue === 'object' &&
    typeof overrideValue === 'object'
  ) {
    const merged = { ...baseValue };
    for (const [key, value] of Object.entries(overrideValue)) {
      merged[key] = key in merged ? deepMerge(merged[key], value) : value;
    }
    return merged;
  }

  return overrideValue ?? baseValue;
}

function interpolate(ctx, value) {
  if (typeof value === 'string') {
    return value.replace(/\{\{(\w+)\}\}?/g, (match, key) => ctx.vars[key] ?? match);
  }

  if (Array.isArray(value)) {
    return value.map(item => interpolate(ctx, item));
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, interpolate(ctx, nested)])
    );
  }

  return value;
}

function buildManagedMetaBlock({
  title,
  description,
  keywords,
  robots,
  canonicalUrl,
  currentUrl,
  imageUrl,
  ogType,
  appName,
  locale,
}) {
  return [
    '    <!-- Route-specific primary meta -->',
    `    <meta name="title" content="${escapeHtml(title)}" />`,
    `    <meta name="description" content="${escapeHtml(description)}" />`,
    keywords ? `    <meta name="keywords" content="${escapeHtml(keywords)}" />` : '',
    `    <meta name="robots" content="${robots}" />`,
    `    <link rel="canonical" href="${canonicalUrl}" />`,
    '',
    '    <!-- Route-specific Open Graph -->',
    `    <meta property="og:type" content="${ogType}" />`,
    `    <meta property="og:site_name" content="${escapeHtml(appName)}" />`,
    `    <meta property="og:title" content="${escapeHtml(title)}" />`,
    `    <meta property="og:description" content="${escapeHtml(description)}" />`,
    `    <meta property="og:url" content="${currentUrl}" />`,
    `    <meta property="og:image" content="${imageUrl}" />`,
    `    <meta property="og:locale" content="${locale}" />`,
    '',
    '    <!-- Route-specific Twitter Card -->',
    '    <meta name="twitter:card" content="summary_large_image" />',
    `    <meta name="twitter:title" content="${escapeHtml(title)}" />`,
    `    <meta name="twitter:description" content="${escapeHtml(description)}" />`,
    `    <meta name="twitter:url" content="${currentUrl}" />`,
    `    <meta name="twitter:image" content="${imageUrl}" />`,
  ]
    .filter(Boolean)
    .join('\n');
}

function stripManagedHead(html) {
  let next = html;
  next = next.replace(/\n\s*<meta\s+name="title"[^>]*>/gi, '');
  next = next.replace(/\n\s*<meta\s+name="description"[^>]*>/gi, '');
  next = next.replace(/\n\s*<meta\s+name="keywords"[^>]*>/gi, '');
  next = next.replace(/\n\s*<meta\s+name="robots"[^>]*>/gi, '');
  next = next.replace(/\n\s*<meta\s+property="og:[^"]+"[^>]*>/gi, '');
  next = next.replace(/\n\s*<meta\s+(?:name|property)="twitter:[^"]+"[^>]*>/gi, '');
  next = next.replace(/\n\s*<link rel="canonical"[^>]*>/gi, '');
  next = next.replace(/\n\s*<!-- Hreflang:[^>]*-->/gi, '');
  next = next.replace(/\n\s*<link rel="alternate" hreflang="[^"]*"[^>]*>/gi, '');
  next = next.replace(
    /\n\s*<!-- Structured Data: WebSite -->\s*<script type="application\/ld\+json">[\s\S]*?<\/script>/gi,
    ''
  );
  return next;
}

// ---------------------------------------------------------------------------
// Locale loading
// ---------------------------------------------------------------------------

function readLocale(ctx, language, namespace) {
  const localePath = path.join(ctx.localesDir, language, `${namespace}.json`);
  return JSON.parse(fs.readFileSync(localePath, 'utf8'));
}

function buildLocaleBundle(ctx, language, namespaces) {
  return Object.fromEntries(
    namespaces.map(namespace => {
      const fallback = readLocale(ctx, 'en', namespace);
      const localized = language === 'en' ? fallback : readLocale(ctx, language, namespace);
      return [namespace, deepMerge(fallback, localized)];
    })
  );
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function getRoutePath(language, routePath) {
  const localizedPath = routePath ? `/${language}${routePath}` : `/${language}`;
  return localizedPath;
}

function withTrailingSlash(ctx, routePath) {
  if (!ctx.trailingSlashUrls || routePath.endsWith('/')) {
    return routePath;
  }
  return `${routePath}/`;
}

function getCanonicalUrl(ctx, language, route) {
  const effectivePath = route.canonicalPath || route.path;
  const routePath = withTrailingSlash(ctx, getRoutePath(language, effectivePath));
  const baseUrl = ctx.isNonProductionHost ? ctx.productionBaseUrl : ctx.baseUrl;
  return `${baseUrl}${routePath}`;
}

function getSelfUrl(ctx, language, route) {
  return `${ctx.baseUrl}${withTrailingSlash(ctx, getRoutePath(language, route.path))}`;
}

// ---------------------------------------------------------------------------
// Alternate links (hreflang)
// ---------------------------------------------------------------------------

function buildAlternateLinks(ctx, route) {
  if (!route.indexable || ctx.isNonProductionHost) {
    return '';
  }

  const links = ctx.supportedLanguages.map(language => {
    const href = getCanonicalUrl(ctx, language, route);
    const hrefLang = ctx.languageHreflangMap[language] || language;
    return `    <link rel="alternate" hreflang="${hrefLang}" href="${href}" />`;
  });

  links.push(
    `    <link rel="alternate" hreflang="x-default" href="${getCanonicalUrl(ctx, 'en', route)}" />`
  );

  return links.join('\n');
}

// ---------------------------------------------------------------------------
// Sitemap (index + per-language children)
// ---------------------------------------------------------------------------

function sitemapFileName(language) {
  return `sitemap-${language}.xml`;
}

// Languages ordered so English leads: a sitemap index lists `en` first, which
// lets us submit/prioritize the English sitemap ahead of the translations in
// Search Console while keeping every language discoverable.
function orderedSitemapLanguages(ctx) {
  if (!ctx.supportedLanguages.includes('en')) {
    return ctx.supportedLanguages;
  }
  return ['en', ...ctx.supportedLanguages.filter(language => language !== 'en')];
}

// One <urlset> per language. Each entry still carries the full hreflang cluster
// (all languages + x-default), so bidirectional hreflang confirmation holds even
// when only a subset of the per-language sitemaps has been submitted.
function buildLanguageSitemap(ctx, language) {
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"',
    '        xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    '',
  ];

  for (const route of ctx.routes.filter(r => r.indexable && !ctx.isNonProductionHost)) {
    lines.push('  <url>');
    lines.push(`    <loc>${getCanonicalUrl(ctx, language, route)}</loc>`);
    lines.push(`    <lastmod>${ctx.today}</lastmod>`);
    lines.push(`    <changefreq>${route.changefreq}</changefreq>`);
    lines.push(`    <priority>${route.priority}</priority>`);

    for (const altLang of ctx.supportedLanguages) {
      lines.push(
        `    <xhtml:link rel="alternate" hreflang="${ctx.languageHreflangMap[altLang]}" href="${getCanonicalUrl(ctx, altLang, route)}" />`
      );
    }

    lines.push(
      `    <xhtml:link rel="alternate" hreflang="x-default" href="${getCanonicalUrl(ctx, 'en', route)}" />`
    );
    lines.push('  </url>');
  }

  lines.push('</urlset>', '');
  return lines.join('\n');
}

// The top-level sitemap.xml is a sitemap index pointing at the per-language
// sitemaps (English first). On non-production hosts it stays empty, matching the
// behavior of emitting no indexable URLs.
function buildSitemapIndex(ctx) {
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    '',
  ];

  if (!ctx.isNonProductionHost) {
    for (const language of orderedSitemapLanguages(ctx)) {
      lines.push('  <sitemap>');
      lines.push(`    <loc>${ctx.baseUrl}/${sitemapFileName(language)}</loc>`);
      lines.push(`    <lastmod>${ctx.today}</lastmod>`);
      lines.push('  </sitemap>');
    }
  }

  lines.push('</sitemapindex>', '');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Robots.txt
// ---------------------------------------------------------------------------

function buildRobots(ctx) {
  if (ctx.isNonProductionHost) {
    return [
      `# robots.txt for non-production ${ctx.appName} deployment`,
      `# ${ctx.baseUrl}`,
      '',
      'User-agent: *',
      'Disallow: /',
      '',
      '# Keep preview hosts out of search results',
      `Sitemap: ${ctx.baseUrl}/sitemap.xml`,
      '',
    ].join('\n');
  }

  const disallowLines = ctx.robotsDisallowPaths.map(p => `Disallow: ${p}`).join('\n');
  const aiCrawlerAgents = [
    ['# OpenAI GPT', 'GPTBot'],
    ['', 'ChatGPT-User'],
    ['# Anthropic Claude', 'Claude-Web'],
    ['', 'ClaudeBot'],
    ['', 'anthropic-ai'],
    ['# Google Gemini/Bard', 'Google-Extended'],
    ['# Perplexity', 'PerplexityBot'],
    ['# You.com', 'YouBot'],
    ['# Cohere', 'CohereBot'],
    ['# Common Crawl', 'CCBot'],
    ['# Meta AI', 'Meta-ExternalAgent'],
    ['', 'FacebookBot'],
  ];
  const aiCrawlerLines = aiCrawlerAgents
    .map(([comment, agent]) =>
      [
        comment,
        `User-agent: ${agent}`,
        'Allow: /',
        'Allow: /llms.txt',
        disallowLines,
        'Crawl-delay: 5',
      ]
        .filter(Boolean)
        .join('\n')
    )
    .join('\n\n');

  return [
    `# robots.txt for ${ctx.appName}`,
    `# ${ctx.baseUrl}`,
    '',
    '# ===========================================',
    '# Standard Search Engine Crawlers',
    '# ===========================================',
    '',
    'User-agent: *',
    'Allow: /',
    disallowLines,
    'Crawl-delay: 2',
    '',
    '# ===========================================',
    '# Google',
    '# ===========================================',
    '',
    'User-agent: Googlebot',
    'Allow: /',
    disallowLines,
    'Crawl-delay: 1',
    '',
    'User-agent: Googlebot-Image',
    'Allow: /',
    '',
    '# ===========================================',
    '# Bing',
    '# ===========================================',
    '',
    'User-agent: Bingbot',
    'Allow: /',
    disallowLines,
    'Crawl-delay: 2',
    '',
    '# ===========================================',
    '# AI Search Engine Crawlers',
    '# ===========================================',
    '',
    aiCrawlerLines,
    '',
    '# ===========================================',
    '# Sitemaps',
    '# ===========================================',
    '',
    `Sitemap: ${ctx.baseUrl}/sitemap.xml`,
    '',
    '# ===========================================',
    '# AI Content Files',
    '# ===========================================',
    '',
    '# LLMs.txt - AI crawler guidance',
    `# Available at: ${ctx.baseUrl}/llms.txt`,
    '',
  ].join('\n');
}

// ---------------------------------------------------------------------------
// HTML generation
// ---------------------------------------------------------------------------

function generateRouteHtml(ctx, baseHtml, language, route) {
  const namespaces = route.namespaces || [route.namespace];
  const locale = interpolate(ctx, buildLocaleBundle(ctx, language, namespaces));
  const meta = route.meta(locale);
  const title = cleanText(meta.title);
  const description = cleanText(meta.description || '');
  const keywordList = Array.isArray(meta.keywords) ? meta.keywords.map(cleanText) : [];
  const keywords = keywordList.filter(Boolean).join(', ');
  assertNoUnresolvedPlaceholders(route, language, { title, description, keywords });
  const noindex = ctx.isNonProductionHost || !route.indexable;
  const robots = noindex ? 'noindex, nofollow' : 'index, follow';
  const canonicalUrl = getCanonicalUrl(ctx, language, route);
  const currentUrl = getSelfUrl(ctx, language, route);
  const alternateLinks = buildAlternateLinks(ctx, route);
  const localeCode = ctx.languageHreflangMap[language] || language;
  const imageUrl = `${ctx.baseUrl}/og-image.png`;
  const ogType = route.ogType || 'website';

  let html = baseHtml;

  // Language
  html = html.replace(/<html lang="[^"]*">/, `<html lang="${language}">`);

  // Title
  html = html.replace(/<title>[\s\S]*?<\/title>/, `<title>${escapeHtml(title)}</title>`);

  html = stripManagedHead(html);

  // Apply project-specific strip patterns
  for (const pattern of ctx.stripPatterns) {
    html = html.replace(pattern, '');
  }

  // Inject route-specific SEO before </head>
  const staticStructuredData =
    typeof route.structuredData === 'function'
      ? route.structuredData(locale, ctx, { ...route, language, canonicalUrl, currentUrl, meta })
      : [];
  const structuredDataScripts = (
    Array.isArray(staticStructuredData) ? staticStructuredData : [staticStructuredData]
  )
    .filter(Boolean)
    .map(
      schema =>
        `    <script type="application/ld+json" data-static-seo="true">${escapeJsonForHtml(
          schema
        )}</script>`
    )
    .join('\n');

  const headInjection = [
    buildManagedMetaBlock({
      title,
      description,
      keywords,
      robots,
      canonicalUrl,
      currentUrl,
      imageUrl,
      ogType,
      appName: ctx.appName,
      locale: localeCode,
    }),
    '    <!-- Route-specific SEO -->',
    alternateLinks,
    structuredDataScripts,
  ]
    .filter(Boolean)
    .join('\n');

  html = html.replace('  </head>', `${headInjection}\n  </head>`);

  if (route.indexable || typeof route.staticHtml === 'function') {
    const staticHtml =
      typeof route.staticHtml === 'function'
        ? route.staticHtml(locale, ctx, {
            ...route,
            language,
            canonicalUrl,
            currentUrl,
            meta,
          })
        : defaultStaticHtml({ title, description });
    if (staticHtml) {
      html = html.replace('<div id="root"></div>', `<div id="root">\n${staticHtml}\n    </div>`);
    }
  }

  return html;
}

// ---------------------------------------------------------------------------
// File writing
// ---------------------------------------------------------------------------

function writeRouteHtml(ctx, targetDir) {
  const indexPath = path.join(targetDir, 'index.html');
  if (!fs.existsSync(indexPath)) {
    return;
  }

  const baseHtml = fs.readFileSync(indexPath, 'utf8');

  for (const route of ctx.routes) {
    for (const language of ctx.supportedLanguages) {
      const routeFile = path.join(targetDir, language, route.path.replace(/^\//, ''), 'index.html');
      fs.mkdirSync(path.dirname(routeFile), { recursive: true });
      fs.writeFileSync(routeFile, generateRouteHtml(ctx, baseHtml, language, route));
    }
  }
}

function writeStaticAssets(ctx, targetDir) {
  fs.mkdirSync(targetDir, { recursive: true });
  fs.writeFileSync(path.join(targetDir, 'sitemap.xml'), buildSitemapIndex(ctx));
  if (!ctx.isNonProductionHost) {
    for (const language of ctx.supportedLanguages) {
      fs.writeFileSync(
        path.join(targetDir, sitemapFileName(language)),
        buildLanguageSitemap(ctx, language)
      );
    }
  }
  fs.writeFileSync(path.join(targetDir, 'robots.txt'), buildRobots(ctx));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const { configPath, targetDir } = parseArgs();
const rawConfig = await loadConfig(configPath);
const ctx = buildContext(rawConfig);

writeStaticAssets(ctx, targetDir);
writeRouteHtml(ctx, targetDir);

console.log(
  `Generated SEO assets (v2: sitemap index) in ${targetDir} for ${ctx.isNonProductionHost ? 'non-production' : 'production'} domain ${ctx.appDomain}`
);
