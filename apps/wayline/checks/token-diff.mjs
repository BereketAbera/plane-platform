#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Fails when brand CSS names a token upstream does not have, which catches an upstream design
// system rewrite loudly instead of as a silently unstyled app. Also fails when tokens.css sets a
// token in its light block but not in its dark block: the light block comes after upstream's dark
// block at equal specificity, so it would overwrite the dark value.
//
//   node apps/wayline/checks/token-diff.mjs <upstream tree>
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { parseCss, tokenNames } from "./css-parse.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const tree = process.argv[2];
if (!tree) {
  console.error("usage: token-diff.mjs <upstream tree>");
  process.exit(2);
}
if (!existsSync(join(tree, "packages/tailwind-config/variables.css"))) {
  console.error(
    `token-diff: ${tree} has no packages/tailwind-config/variables.css. Upstream's design system has moved, so brand/tokens.css needs reworking before anything else.`
  );
  process.exit(1);
}

// From tailwindcss/theme.css, which is not on disk before pnpm install. Each is a name Tailwind 4
// itself defines and variables.css does not redeclare.
const TAILWIND_DEFAULTS = new Set([
  "--radius-xs", "--radius-sm", "--radius-md", "--radius-lg", "--radius-xl", "--radius-2xl", "--radius-3xl", "--spacing",
]);
const OURS = /^--(wl|tw)-/;

function walkCss(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === "dist" || e.name === "build" || e.name === ".git") continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) walkCss(p, out);
    else if (e.name.endsWith(".css")) out.push(p);
  }
  return out;
}

const brandDir = join(here, "../overlay/packages/tailwind-config");
const brandFiles = [join(brandDir, "brand.css"), ...walkCss(join(brandDir, "brand"))];

const upstream = new Set();
for (const base of ["packages/tailwind-config", "packages/editor/src", "packages/propel/src", "apps/web/styles", "apps/admin/styles", "apps/space/styles"]) {
  if (!existsSync(join(tree, base))) continue;
  for (const f of walkCss(join(tree, base))) {
    const rel = relative(tree, f);
    if (rel === "packages/tailwind-config/brand.css" || rel.startsWith("packages/tailwind-config/brand/")) continue;
    for (const d of parseCss(readFileSync(f, "utf8"))) if (d.name.startsWith("--")) upstream.add(d.name);
  }
}
if (upstream.size < 500) {
  console.error(`token-diff: only ${upstream.size} upstream tokens found under ${tree}, the tree looks wrong`);
  process.exit(2);
}

let bad = 0;
let names = 0;
for (const f of brandFiles) {
  for (const name of tokenNames(readFileSync(f, "utf8"))) {
    names++;
    if (OURS.test(name) || upstream.has(name) || TAILWIND_DEFAULTS.has(name)) continue;
    console.error(`missing upstream: ${name} (${relative(brandDir, f)})`);
    bad++;
  }
}

const tokens = parseCss(readFileSync(join(brandDir, "brand/tokens.css"), "utf8"));
const inPalette = (d) => d.name.startsWith("--") && d.path[0] === "@layer base";
const light = tokens.filter((d) => inPalette(d) && d.path.length === 2).map((d) => d.name);
const dark = new Set(tokens.filter((d) => inPalette(d) && d.path.at(-1) === "@variant dark").map((d) => d.name));
for (const name of light) {
  if (!dark.has(name)) {
    console.error(`set in light but not dark: ${name}, which would overwrite upstream's dark value`);
    bad++;
  }
}

console.log(`token-diff: ${names} names across ${brandFiles.length} brand files, ${upstream.size} upstream tokens, ${bad} problems`);
process.exit(bad ? 1 : 0);
