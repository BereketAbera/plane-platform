#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// /source is answered by nginx, not by the app. A router link adds a trailing slash and navigates inside the
// app, so it lands on the :workspaceSlug route instead of the source offer. The codemod rewrites strings
// without knowing which component holds them, so this reads its output and fails on any router link
// that ends up pointing there, and on any mailto: left in front of something that is not an address.
//
//   node apps/wayline/checks/source-links.mjs <tree after the codemod>
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const tree = process.argv[2];
if (!tree) {
  console.error("usage: source-links.mjs <tree>");
  process.exit(2);
}
const SKIP = new Set(["node_modules", "dist", "build", ".git", ".turbo", ".react-router"]);
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (/\.tsx$/.test(name)) files.push(p);
  }
})(join(tree, "apps"));

const SOURCE = String.raw`(?:"/source"|'/source'|\{"/source"\}|\{'/source'\}|\{\`/source\`\})`;
// Components that navigate through the router. EmptySpaceItem wraps next/link.
const ROUTER_LINK = new RegExp(String.raw`<(Link|NavLink|EmptySpaceItem|ControlLink)\b[^>]*?\b(?:href|to)=${SOURCE}`, "gs");
const BAD_MAILTO = /mailto:[A-Za-z][A-Za-z ]*["'`]/g;

// Upstream code that nothing imports, so its link cannot render. It stays allowed only while that holds.
const UNUSED = ["apps/web/core/components/common/latest-feature-block.tsx"];
const sources = new Map(files.map((file) => [relative(tree, file), readFileSync(file, "utf8")]));

let bad = 0;
for (const unused of UNUSED) {
  const stem = unused.replace(/^.*\//, "").replace(/\.tsx$/, "");
  for (const [rel, text] of sources) {
    if (rel !== unused && text.includes(`/${stem}"`)) {
      console.error(`FAIL ${rel} imports ${unused}, which holds a router link to /source`);
      bad++;
    }
  }
}
for (const [rel, text] of sources) {
  if (UNUSED.includes(rel)) continue;
  for (const [re, what] of [[ROUTER_LINK, "router link to /source"], [BAD_MAILTO, "mailto: without an address"]]) {
    for (const m of text.matchAll(re)) {
      const line = text.slice(0, m.index).split("\n").length;
      console.error(`FAIL ${rel}:${line}: ${what}: ${m[0].replace(/\s+/g, " ").slice(0, 100)}`);
      bad++;
    }
  }
}
console.log(`source-links: ${files.length} files read, ${bad} problems`);
process.exit(bad ? 1 : 0);
