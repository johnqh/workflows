#!/usr/bin/env node

/**
 * SEO asset generator for multilingual static sites.
 *
 * Generates per-route, per-language index.html files with localized meta tags,
 * canonical URLs, hreflang alternates, sitemap.xml, and robots.txt.
 *
 * Reads project-specific configuration from ./seo.config.mjs (or --config path).
 *
 * Usage:
 *   node generate-seo-assets.mjs [target-dir]
 *   node generate-seo-assets.mjs --config ./seo.config.mjs public
 *   node generate-seo-assets.mjs dist
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
 *   stripPatterns       - RegExp[] extra patterns to strip from base HTML
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
  return routePath ? `/${language}${routePath}` : `/${language}`;
}

function getCanonicalUrl(ctx, language, route) {
  const effectivePath = route.canonicalPath || route.path;
  const routePath = getRoutePath(language, effectivePath);
  const baseUrl = ctx.isNonProductionHost ? ctx.productionBaseUrl : ctx.baseUrl;
  return `${baseUrl}${routePath}`;
}

function getSelfUrl(ctx, language, route) {
  return `${ctx.baseUrl}${getRoutePath(language, route.path)}`;
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
// Sitemap
// ---------------------------------------------------------------------------

function buildSitemap(ctx) {
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"',
    '        xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    '',
  ];

  for (const route of ctx.routes.filter(r => r.indexable && !ctx.isNonProductionHost)) {
    for (const language of ctx.supportedLanguages) {
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
  }

  lines.push('</urlset>', '');
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

  return [
    `# robots.txt for ${ctx.appName}`,
    `# ${ctx.baseUrl}`,
    '',
    'User-agent: *',
    'Allow: /',
    disallowLines,
    '',
    'User-agent: Googlebot',
    'Allow: /',
    disallowLines,
    '',
    `Sitemap: ${ctx.baseUrl}/sitemap.xml`,
    '',
  ].join('\n');
}

// ---------------------------------------------------------------------------
// HTML generation
// ---------------------------------------------------------------------------

function updateTag(html, pattern, replacement, fallback) {
  if (pattern.test(html)) {
    return html.replace(pattern, replacement);
  }
  return html.replace('</head>', `${fallback}\n  </head>`);
}

function generateRouteHtml(ctx, baseHtml, language, route) {
  const locale = interpolate(ctx, buildLocaleBundle(ctx, language, [route.namespace]));
  const meta = route.meta(locale);
  const title = `${meta.title}`;
  const description = meta.description || '';
  const keywords = Array.isArray(meta.keywords) ? meta.keywords.join(', ') : '';
  const noindex = ctx.isNonProductionHost || !route.indexable;
  const robots = noindex ? 'noindex, nofollow' : 'index, follow';
  const canonicalUrl = getCanonicalUrl(ctx, language, route);
  const currentUrl = getSelfUrl(ctx, language, route);
  const alternateLinks = buildAlternateLinks(ctx, route);

  let html = baseHtml;

  // Language
  html = html.replace(/<html lang="[^"]*">/, `<html lang="${language}">`);

  // Title
  html = html.replace(/<title>[\s\S]*?<\/title>/, `<title>${escapeHtml(title)}</title>`);

  // Meta tags — replacement has no leading whitespace (preserves original indent)
  html = updateTag(
    html,
    /<meta name="title" content="[^"]*" \/>/,
    `<meta name="title" content="${escapeHtml(title)}" />`,
    `    <meta name="title" content="${escapeHtml(title)}" />`
  );
  html = updateTag(
    html,
    /<meta\s+name="description"\s+content="[\s\S]*?"\s*\/>/,
    `<meta name="description" content="${escapeHtml(description)}" />`,
    `    <meta name="description" content="${escapeHtml(description)}" />`
  );
  html = updateTag(
    html,
    /<meta\s+name="keywords"\s+content="[\s\S]*?"\s*\/>/,
    `<meta name="keywords" content="${escapeHtml(keywords)}" />`,
    `    <meta name="keywords" content="${escapeHtml(keywords)}" />`
  );
  html = updateTag(
    html,
    /<meta name="robots" content="[^"]*" \/>/,
    `<meta name="robots" content="${robots}" />`,
    `    <meta name="robots" content="${robots}" />`
  );

  // Open Graph
  html = updateTag(
    html,
    /<meta property="og:url" content="[^"]*" \/>/,
    `<meta property="og:url" content="${currentUrl}" />`,
    `    <meta property="og:url" content="${currentUrl}" />`
  );
  html = updateTag(
    html,
    /<meta property="og:title" content="[\s\S]*?" \/>/,
    `<meta property="og:title" content="${escapeHtml(title)}" />`,
    `    <meta property="og:title" content="${escapeHtml(title)}" />`
  );
  html = updateTag(
    html,
    /<meta property="og:description" content="[\s\S]*?" \/>/,
    `<meta property="og:description" content="${escapeHtml(description)}" />`,
    `    <meta property="og:description" content="${escapeHtml(description)}" />`
  );
  html = updateTag(
    html,
    /<meta property="og:locale" content="[^"]*" \/>/,
    `<meta property="og:locale" content="${ctx.languageHreflangMap[language] || language}" />`,
    `    <meta property="og:locale" content="${ctx.languageHreflangMap[language] || language}" />`
  );

  // Twitter
  html = updateTag(
    html,
    /<meta property="twitter:url" content="[^"]*" \/>/,
    `<meta property="twitter:url" content="${currentUrl}" />`,
    `    <meta property="twitter:url" content="${currentUrl}" />`
  );
  html = updateTag(
    html,
    /<meta property="twitter:title" content="[\s\S]*?" \/>/,
    `<meta property="twitter:title" content="${escapeHtml(title)}" />`,
    `    <meta property="twitter:title" content="${escapeHtml(title)}" />`
  );
  html = updateTag(
    html,
    /<meta property="twitter:description" content="[\s\S]*?" \/>/,
    `<meta property="twitter:description" content="${escapeHtml(description)}" />`,
    `    <meta property="twitter:description" content="${escapeHtml(description)}" />`
  );

  // Strip old canonical and hreflang
  html = html.replace(/\n\s*<link rel="canonical"[^>]*>/g, '');
  html = html.replace(/\n\s*<!-- Hreflang:[^>]*-->/g, '');
  html = html.replace(/\n\s*<link rel="alternate" hreflang="[^"]*"[^>]*>/g, '');

  // Apply project-specific strip patterns
  for (const pattern of ctx.stripPatterns) {
    html = html.replace(pattern, '');
  }

  // Inject route-specific SEO before </head>
  const headInjection = [
    '    <!-- Route-specific SEO -->',
    `    <link rel="canonical" href="${canonicalUrl}" />`,
    alternateLinks,
  ]
    .filter(Boolean)
    .join('\n');

  html = html.replace('  </head>', `${headInjection}\n  </head>`);

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
  fs.writeFileSync(path.join(targetDir, 'sitemap.xml'), buildSitemap(ctx));
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
  `Generated SEO assets in ${targetDir} for ${ctx.isNonProductionHost ? 'non-production' : 'production'} domain ${ctx.appDomain}`
);
