// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Just enough of a CSS parser for token files: ordered declarations with their block path. No
// dependency, because checks run before pnpm install.

export function parseCss(source) {
  const text = source.replace(/\/\*[\s\S]*?\*\//g, "");
  const out = [];
  const stack = [];
  let buf = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "{") {
      stack.push(buf.trim());
      buf = "";
    } else if (c === "}") {
      pushDecl(buf, stack, out);
      buf = "";
      stack.pop();
    } else if (c === ";") {
      pushDecl(buf, stack, out);
      buf = "";
    } else {
      buf += c;
    }
  }
  return out;
}

function pushDecl(raw, stack, out) {
  const m = raw.trim().match(/^(-{0,2}[\w-]+)\s*:\s*([\s\S]*)$/);
  if (m) out.push({ name: m[1], value: m[2].trim().replace(/\s+/g, " "), path: [...stack] });
}

// Every custom property name mentioned, declared or read, in a source string.
export function tokenNames(source) {
  const text = source.replace(/\/\*[\s\S]*?\*\//g, "");
  const names = new Set();
  for (const m of text.matchAll(/(?<![\w-])--[A-Za-z][\w-]*/g)) names.add(m[0]);
  return names;
}
