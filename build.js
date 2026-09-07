#!/usr/bin/env node
/* Prerender: one static HTML file per route, built from src/index.html.

   Every route used to be served the same document, so a crawler saw the
   home title, description and canonical on every URL and fourteen H1s in
   the markup. Each output file now carries only its own page block, visible
   without JavaScript, with its own title, description, canonical, Open
   Graph tags and structured data. The client router still runs for
   in-page behaviour; links to other pages are ordinary navigations.

   Run after any edit to src/index.html:   node build.js
   Writes: index.html, <route>.html for each inner page, sitemap.xml      */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const SRC = path.join(ROOT, 'src', 'index.html');
const ORIGIN = 'https://dj-website-roan.vercel.app';
const OG_IMAGE = 'https://img1.wsimg.com/isteam/ip/e9b2f055-9f75-45f0-af87-5650a1143928/Hand%20plane%20(Backgrond%20photo).JPG';
const TODAY = new Date().toISOString().slice(0, 10);
const FIRST_PUBLISHED = '2026-08-20';

const src = fs.readFileSync(SRC, 'utf8');

/* ---- route tables, read from the source so they cannot drift ---- */
function extract(name) {
  const m = src.match(new RegExp('\\nvar ' + name + '=\\{([\\s\\S]*?)\\n\\};'));
  if (!m) throw new Error(name + ' map not found in source');
  return new Function('return {' + m[1] + '\n};')();
}
const TITLES = extract('TITLES');
const DESCS = extract('DESCS');
const routes = Object.keys(TITLES);

const LABELS = {
  '/windows': 'Timber windows', '/doors': 'Timber doors', '/materials': 'Materials',
  '/guidance': 'Guidance', '/guide-repair': 'Repair or replace?',
  '/guide-conservation': 'Conservation area windows', '/accreditation': 'Accreditation',
  '/projects': 'Projects', '/heritage': 'Listed and heritage', '/about': 'About us',
  '/fitting-on-site': 'Fitting on site', '/sustainability': 'Sustainability', '/contact': 'Get a quote'
};
const PRIORITY = {
  '/': '1.0', '/windows': '0.9', '/doors': '0.9', '/materials': '0.8', '/heritage': '0.8',
  '/contact': '0.8', '/guidance': '0.8', '/accreditation': '0.8', '/projects': '0.7',
  '/about': '0.7', '/fitting-on-site': '0.7', '/sustainability': '0.7',
  '/guide-repair': '0.7', '/guide-conservation': '0.7'
};
for (const r of routes) {
  if (r !== '/' && !LABELS[r]) throw new Error('no breadcrumb label for ' + r);
  if (!PRIORITY[r]) throw new Error('no sitemap priority for ' + r);
}

/* ---- page blocks: top-level <div class="page" data-page="..."> ... </div> ---- */
const blockRe = /<div class="page" data-page="([^"]+)">[\s\S]*?\n<\/div>\n/g;
const blocks = {};
let m;
while ((m = blockRe.exec(src))) blocks[m[1]] = m[0];
for (const r of routes) if (!blocks[r]) throw new Error('no page block for route ' + r);
for (const b of Object.keys(blocks)) if (!TITLES[b]) throw new Error('page block without a title: ' + b);

const esc = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const text = s => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&mdash;/g, '—')
  .replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
function h1Of(route) {
  const mm = blocks[route].match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  if (!mm) throw new Error('no h1 in ' + route);
  return text(mm[1]);
}
function setTag(html, re, replacement, label) {
  if (!re.test(html)) throw new Error('head tag missing: ' + label);
  return html.replace(re, () => replacement);
}

/* ---- per-page structured data: WebPage, BreadcrumbList, Article on guides ---- */
function jsonld(route) {
  const url = ORIGIN + (route === '/' ? '/' : route);
  const graph = [];
  const page = {
    '@type': 'WebPage', '@id': url + '#webpage', 'url': url, 'name': TITLES[route],
    'description': DESCS[route], 'inLanguage': 'en-GB',
    'isPartOf': { '@id': ORIGIN + '/#website' }, 'about': { '@id': ORIGIN + '/#business' },
    'primaryImageOfPage': { '@type': 'ImageObject', 'url': OG_IMAGE }
  };
  if (route !== '/') {
    const crumbs = [{ '@type': 'ListItem', 'position': 1, 'name': 'Home', 'item': ORIGIN + '/' }];
    if (route.startsWith('/guide-')) crumbs.push({ '@type': 'ListItem', 'position': 2, 'name': 'Guidance', 'item': ORIGIN + '/guidance' });
    crumbs.push({ '@type': 'ListItem', 'position': crumbs.length + 1, 'name': LABELS[route], 'item': url });
    graph.push({ '@type': 'BreadcrumbList', '@id': url + '#breadcrumb', 'itemListElement': crumbs });
    page.breadcrumb = { '@id': url + '#breadcrumb' };
  }
  graph.push(page);
  if (route.startsWith('/guide-')) {
    graph.push({
      '@type': 'Article', '@id': url + '#article', 'headline': h1Of(route), 'description': DESCS[route],
      'mainEntityOfPage': { '@id': url + '#webpage' }, 'image': OG_IMAGE, 'inLanguage': 'en-GB',
      'author': { '@type': 'Person', 'name': 'Harry Jackson', 'jobTitle': 'Joiner', 'worksFor': { '@id': ORIGIN + '/#business' } },
      'publisher': { '@id': ORIGIN + '/#business' },
      'datePublished': FIRST_PUBLISHED, 'dateModified': TODAY
    });
  }
  return '<script type="application/ld+json">\n' + JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }) + '\n</script>\n';
}

/* ---- build one route ---- */
function build(route) {
  const url = ORIGIN + (route === '/' ? '/' : route);
  const title = TITLES[route], desc = DESCS[route];
  const isGuide = route.startsWith('/guide-');
  let out = src;

  out = setTag(out, /<title>[^<]*<\/title>/, '<title>' + esc(title) + '</title>', 'title');
  out = setTag(out, /<meta name="description" content="[^"]*">/, '<meta name="description" content="' + esc(desc) + '">', 'description');
  out = setTag(out, /<link rel="canonical" href="[^"]*">/, '<link rel="canonical" href="' + url + '">', 'canonical');
  out = setTag(out, /<meta property="og:type" content="[^"]*">/, '<meta property="og:type" content="' + (isGuide ? 'article' : 'website') + '">', 'og:type');
  out = setTag(out, /<meta property="og:url" content="[^"]*">/, '<meta property="og:url" content="' + url + '">', 'og:url');
  out = setTag(out, /<meta property="og:title" content="[^"]*">/, '<meta property="og:title" content="' + esc(title) + '">', 'og:title');
  out = setTag(out, /<meta property="og:description" content="[^"]*">/, '<meta property="og:description" content="' + esc(desc) + '">', 'og:description');
  out = setTag(out, /<meta name="twitter:title" content="[^"]*">/, '<meta name="twitter:title" content="' + esc(title) + '">', 'twitter:title');
  out = setTag(out, /<meta name="twitter:description" content="[^"]*">/, '<meta name="twitter:description" content="' + esc(desc) + '">', 'twitter:description');

  /* per-page structured data goes straight after the site-wide block */
  const styleAt = out.indexOf('</script>\n<style>');
  if (styleAt < 0) throw new Error('could not place structured data');
  out = out.slice(0, styleAt + '</script>\n'.length) + jsonld(route) + out.slice(styleAt + '</script>\n'.length);

  /* keep only this route's page block, visible without JavaScript */
  for (const b of Object.keys(blocks)) if (b !== route) out = out.replace(blocks[b], () => '');
  const own = blocks[route].replace('<div class="page" data-page="' + route + '">', '<div class="page on" data-page="' + route + '">');
  out = out.replace(blocks[route], () => own);
  out = out.replace(/\n<!-- =+ [^\n]*=+ -->\n/g, '\n');   /* section markers of removed pages */

  const banner = '<!-- Generated from src/index.html by build.js on ' + TODAY + '. Edit the source and rebuild; do not edit this file. -->\n';
  out = out.replace('<!DOCTYPE html>\n', '<!DOCTYPE html>\n' + banner);

  const h1s = (out.match(/<h1[\s>]/g) || []).length;
  if (h1s !== 1) throw new Error(route + ' has ' + h1s + ' h1 elements');
  const file = route === '/' ? 'index.html' : route.slice(1) + '.html';
  fs.writeFileSync(path.join(ROOT, file), out, 'utf8');
  return file;
}

/* ---- sitemap ---- */
function sitemap() {
  const rows = routes.map(r => '  <url><loc>' + ORIGIN + (r === '/' ? '/' : r) + '</loc><lastmod>' + TODAY +
    '</lastmod><changefreq>' + (r === '/about' ? 'yearly' : 'monthly') + '</changefreq><priority>' + PRIORITY[r] + '</priority></url>');
  fs.writeFileSync(path.join(ROOT, 'sitemap.xml'),
    '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + rows.join('\n') + '\n</urlset>\n', 'utf8');
}

const written = routes.map(build);
sitemap();
console.log('built ' + written.length + ' pages: ' + written.join(', ') + '\nsitemap.xml: ' + routes.length + ' urls, lastmod ' + TODAY);
