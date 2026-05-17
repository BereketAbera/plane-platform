#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Scripted brand-text replacement, run by apply.sh after patches. Its output is never committed.
//
//   node apps/wayline/codemod/rebrand.mjs <tree>
//
// Scope: TS and TSX of the three frontends and shared packages, i18n JSON, web manifests. apps/api
// and apps/live are out of scope: the backend owner handles apps/api, and live stays unmodified.
//
// Never touched: SPDX and copyright lines, import lines, and functional identifiers (@plane/* packages,
// X-Plane-* headers, PlaneLogo-style component names, JSON keys). Other comments are rewritten too,
// because the SSR server bundle keeps them.
//
// Domain policy. Marketing and legal links go to /source, which the web image redirects to this
// build's source (AGPL section 13). The exceptions, each with a reason, are KEPT below and mirrored
// in checks/leak-allowlist.txt. Placeholder addresses in forms become RFC 2606 example.com. No
// support address is invented: SUPPORT_EMAIL falls back to empty, which takes upstream's existing
// "contact your administrator" branch. leak-scan.sh on the build output is the check that nothing
// slipped through; this file only has to get close.
import { readFileSync, readdirSync, writeFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const tree = process.argv[2];
if (!tree) {
  console.error("usage: rebrand.mjs <tree>");
  process.exit(2);
}

const SOURCE = "/source";

// Left exactly as they are. Each sentinel swaps out and back around the rewrite.
const KEPT = [
  // Compared against a backend bot address in inbox-list-item.tsx. Functional, not branding.
  "intake@plane.so",
  // The only credit line allowed in the UI. Honest attribution, see NOTICE.md.
  "Built on Plane Community Edition",
  // Upstream's documentation for this exact software: there is no other manual, and saying so is honest.
  "https://docs.plane.so/core-concepts/projects/run-project#estimate",
  "https://docs.plane.so/",
  // Explains the telemetry the code can send, next to the setting that controls it.
  "https://developers.plane.so/self-hosting/telemetry",
];

// Literal rewrites, longest first where one is a prefix of another. Applied in order.
const LINKS = [
  ["https://go.plane.so/p-docs", "https://docs.plane.so/"],
  ["https://go.plane.so/p-changelog", SOURCE],
  ["https://plane.so/legals/terms-and-conditions", SOURCE],
  ["https://plane.so/legals/privacy-policy", SOURCE],
  ["https://plane.so/changelog?category=self-hosted", SOURCE],
  ["https://plane.so/changelog?category=cloud", SOURCE],
  ["https://plane.so/changelog", SOURCE],
  ["https://plane.so/talk-to-sales", SOURCE],
  ["https://plane.so/pricing", SOURCE],
  ["https://plane.so/contact", SOURCE],
  ["https://plane.so/pages", SOURCE],
  ["https://plane.so/business", SOURCE],
  ["https://plane.so/pro", SOURCE],
  ["https://plane.so/one", SOURCE],
  ["https://forum.plane.so", SOURCE],
  ["https://status.plane.so/", SOURCE],
  ["https://x.com/planepowers", SOURCE],
  ["https://github.com/makeplane/plane/issues/new/choose", SOURCE],
  ["https://github.com/makeplane/plane", SOURCE],
  ["https://github.com/makeplane", SOURCE],
  ["https://app.plane.so/og-image.png", "/og-image.png"],
  ["mailto:support@plane.so", SOURCE],
  ["mailto:sales@plane.so", SOURCE],
  ['process.env.VITE_SUPPORT_EMAIL || "support@plane.so"', 'process.env.VITE_SUPPORT_EMAIL || ""'],
  ['process.env.VITE_WEBSITE_URL || "https://plane.so"', `process.env.VITE_WEBSITE_URL || "${SOURCE}"`],
  // Form placeholders.
  ["@projectplane.so", "@example.com"],
  ["help@plane.so", "help@example.com"],
  ["example@plane.so", "example@example.com"],
  // Upstream's own account handle.
  ['"@planepowers"', '"Source code"'],
  ['"planepowers"', '""'],
];
const LINK_PATTERNS = [
  [/https:\/\/app\.plane\.so\/upgrade\/[^"'`\s]*/g, SOURCE],
  [/https:\/\/(app|sites)\.plane\.so\/?/g, SOURCE],
  [/https:\/\/plane\.so\/?/g, SOURCE],
];
// Whole lines that only make sense on upstream's own domain.
const DROP_LINE = [
  /^\s*\{ property: "og:url", content: "https:\/\/[a-z.]*plane\.so\/" \},\s*$/,
  /^\s*\{ name: "twitter:site", content: "@planepowers" \},\s*$/,
];
// Sentences that would read wrong after a word swap.
const PHRASES = [
  ["That crashed Plane, pun intended. No worries", "That crashed Wayline. No worries"],
  ["is a customer feedback management tool built on top of plane.so", "is a customer feedback management tool"],
  ["Work in plane happens best", "Work in Wayline happens best"],
  ["Get Galileo, Plane's AI assistant, to help you get started", "Get AI help to start"],
  ["use Galileo to help you start", "use AI to help you start"],
  ["your plane account", "your account"],
  ["sign up to plane with", "sign up to Wayline with"],
  // Doc comments and one developer-facing error, which the SSR server bundle keeps.
  ["plane sites", "public sites"],
  ["plane applications", "applications"],
  // Mail text.
  ['"support@plane.so"', '""'],
  ["support@plane.so", "the source repository"],
];
// The research's lookaround form, so text beside CJK is caught (\b misses it). Tightened on the left
// so X-Plane-* headers survive and on both sides so identifiers such as PlaneLogo or EPlane survive.
const WORD = /(?<![A-Za-z0-9_$]|X-)Plane(?![A-Za-z0-9_$])/g;
const GALILEO = /(?<![A-Za-z0-9_$])Galileo(?![A-Za-z0-9_$])/g;
const JSON_ONLY = [
  [/https:\/\/plane\.so/g, "https://example.com"],
  [/(?<![a-z.-])plane\.so/g, "example.com"],
  [/[a-z]+\.plane\.town/g, "git.example.com"],
  [/plane-github-enterprise/g, "wayline-github-enterprise"],
  // Upstream's own typo of its domain, in form placeholders.
  [/(?<![a-z.-])planes\.so/g, "example.com"],
  // Six locales lower-case the name in one sentence. Keys are never rewritten, so "plane": stays.
  [/(?<![-_.\/@A-Za-z])plane(?![-_\/@A-Za-z0-9]|\.[A-Za-z0-9])/g, "Wayline"],
];

const stats = { files: 0, changed: 0, dropped: 0 };

function shield(text) {
  KEPT.forEach((k, i) => (text = text.split(k).join(`\u0000K${i}\u0000`)));
  return text;
}
function unshield(text) {
  KEPT.forEach((k, i) => (text = text.split(`\u0000K${i}\u0000`).join(k)));
  return text;
}
function rewrite(text) {
  let out = shield(text);
  for (const [from, to] of PHRASES) out = out.split(from).join(to);
  for (const [from, to] of LINKS) out = out.split(from).join(to);
  for (const [re, to] of LINK_PATTERNS) out = out.replace(re, to);
  // A literal \\n in a string puts a letter right before the word, which the lookbehind would skip.
  out = out.replace(/\\nPlane(?![A-Za-z0-9_$])/g, "\\nWayline");
  out = out.replace(WORD, "Wayline").replace(GALILEO, "AI");
  return unshield(out);
}

const PROTECTED_LINE = /SPDX|Copyright|\(c\) 20/;
const IMPORT_LINE = /^\s*(import\s|export\s.*\sfrom\s|}\s*from\s)/;

function processSource(path) {
  const before = readFileSync(path, "utf8");
  const out = [];
  for (const line of before.split("\n")) {
    if (PROTECTED_LINE.test(line) || IMPORT_LINE.test(line)) {
      out.push(line);
    } else if (DROP_LINE.some((re) => re.test(line))) {
      stats.dropped++;
    } else {
      out.push(rewrite(line));
    }
  }
  const after = out.join("\n");
  stats.files++;
  if (after !== before) {
    writeFileSync(path, after);
    stats.changed++;
  }
}

// Values only, so keys and structure cannot change. Reformatting is harmless: nothing is committed.
function walkValues(node, locale) {
  if (typeof node === "string") {
    let v = rewrite(node);
    // German genitive of the name. In Spanish, "Planes" means plans and must stay.
    if (locale === "de") v = v.replace(/(?<![A-Za-z])Planes(?![A-Za-z])/g, "Waylines");
    for (const [re, to] of JSON_ONLY) v = v.replace(re, to);
    return v;
  }
  if (Array.isArray(node)) return node.map((v) => walkValues(v, locale));
  if (node && typeof node === "object") {
    return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, walkValues(v, locale)]));
  }
  return node;
}

function processJson(path) {
  const before = readFileSync(path, "utf8");
  const parsed = JSON.parse(before);
  stats.files++;
  const locale = relative(tree, path).match(/^packages\/i18n\/src\/locales\/([^/]+)\//)?.[1];
  const walked = walkValues(parsed, locale);
  if (JSON.stringify(walked) !== JSON.stringify(parsed)) {
    writeFileSync(path, `${JSON.stringify(walked, null, 2)}\n`);
    stats.changed++;
  }
}

const SKIP_DIR = new Set(["node_modules", "dist", "build", ".git", ".turbo", ".react-router", ".storybook", "storybook-static"]);

function walk(dir, visit) {
  for (const name of readdirSync(dir).sort()) {
    if (SKIP_DIR.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, visit);
    else visit(p, name);
  }
}

const isSource = (name) => /\.tsx?$/.test(name) && !/\.(stories|test|spec)\.tsx?$/.test(name) && !name.endsWith(".d.ts");
const isManifest = (rel, name) =>
  /^apps\/(web|admin|space)\//.test(rel) && (/webmanifest(\.json)?$/.test(name) || name === "manifest.json");

for (const app of ["apps/web", "apps/admin", "apps/space", "packages"]) {
  walk(join(tree, app), (path, name) => {
    const rel = relative(tree, path);
    if (isSource(name)) processSource(path);
    else if (isManifest(rel, name)) processJson(path);
    else if (/^packages\/i18n\/src\/locales\/.*\.json$/.test(rel)) processJson(path);
  });
}

console.log(`rebrand: ${stats.files} files read, ${stats.changed} changed, ${stats.dropped} lines dropped`);
