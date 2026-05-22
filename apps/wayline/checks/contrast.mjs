#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Computes WCAG contrast for the main token pairs in all four themes, the ink shell scope and the paper
// page scope, from upstream's variables.css and brand/tokens.css cascaded in source order. Covers resting
// colours, every hover, active and selected layer, and accent tints composited over the surfaces they sit on.
// Exits non-zero below AA: 4.5:1 for text, 3:1 for icons and focus indicators. Disabled text is exempt under
// WCAG 1.4.3, so it is printed but does not fail.
//
//   node apps/wayline/checks/contrast.mjs [path/to/upstream/variables.css] [-v]
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseCss } from "./css-parse.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const args = process.argv.slice(2);
const verbose = args.includes("-v");
const variablesPath = args.find((a) => a !== "-v") ?? [
  join(root, ".build/plane-patchwork/packages/tailwind-config/variables.css"),
  join(root, ".build/plane-src/packages/tailwind-config/variables.css"),
].find(existsSync);
if (!variablesPath) {
  console.error("contrast: upstream variables.css not found, run apps/wayline/scripts/fetch.sh first");
  process.exit(2);
}
if (!existsSync(variablesPath)) {
  console.error(`contrast: ${variablesPath} does not exist. Upstream's design system has moved, so brand/tokens.css needs reworking first.`);
  process.exit(1);
}

const decls = [
  ...parseCss(readFileSync(variablesPath, "utf8")),
  ...parseCss(readFileSync(join(here, "../overlay/packages/tailwind-config/brand/tokens.css"), "utf8")),
];

const THEMES = ["light", "dark", "light-contrast", "dark-contrast"];

function applies(path, theme) {
  const variants = path.filter((p) => p.startsWith("@variant ")).map((p) => p.slice(9));
  return variants.every(
    (v) =>
      (v === "dark" && theme.includes("dark")) ||
      (v === "dark-high-contrast" && theme === "dark-contrast") ||
      (v === "light-high-contrast" && theme === "light-contrast")
  );
}

function themeVars(theme, withShell) {
  const vars = new Map();
  for (const d of decls) {
    if (!d.name.startsWith("--")) continue;
    if (d.path.some((p) => p.startsWith("@theme"))) continue;
    if (d.path.includes("[data-shell]")) continue;
    if (!d.path.some((p) => p === ":root" || p === ":root,\n  :host" || /^:root,\s*:host$/.test(p))) continue;
    if (applies(d.path, theme)) vars.set(d.name, d.value);
  }
  if (withShell) {
    for (const d of decls) if (d.path.includes("[data-shell]") && d.name.startsWith("--")) vars.set(d.name, d.value);
  }
  return vars;
}

function oklchToRgb(L, C, h) {
  const a = C * Math.cos((h * Math.PI) / 180);
  const b = C * Math.sin((h * Math.PI) / 180);
  const l = L + 0.3963377774 * a + 0.2158037573 * b;
  const m = L - 0.1055613458 * a - 0.0638541728 * b;
  const s = L - 0.0894841775 * a - 1.291485548 * b;
  const [l3, m3, s3] = [l ** 3, m ** 3, s ** 3];
  return [
    4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
    -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
    -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3,
  ].map((v) => Math.min(1, Math.max(0, v))); // linear sRGB, gamut-clipped
}

const toLinear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);

function parseColor(value) {
  const hex = value.match(/^#([0-9a-f]{6})$/i);
  if (hex) {
    const n = parseInt(hex[1], 16);
    return { rgb: [n >> 16, (n >> 8) & 255, n & 255].map((v) => toLinear(v / 255)), a: 1 };
  }
  const ok = value.match(/^oklch\(([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+)%)?\)$/);
  if (ok) return { rgb: oklchToRgb(+ok[1], +ok[2], +ok[3]), a: ok[4] === undefined ? 1 : +ok[4] / 100 };
  if (value === "transparent") return { rgb: [0, 0, 0], a: 0 };
  throw new Error(`cannot parse colour: ${value}`);
}

function resolve(vars, name) {
  let value = vars.get(name);
  for (let i = 0; i < 12 && value?.startsWith("var("); i++) value = vars.get(value.slice(4, -1).trim());
  if (value === undefined) throw new Error(`undefined token ${name}`);
  return parseColor(value);
}

const luminance = ([r, g, b]) => 0.2126 * r + 0.7152 * g + 0.0722 * b;
const ratio = (a, b) => {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
// Browsers composite in gamma-encoded sRGB, not linear light, and the stored values are linear.
const toGamma = (c) => (c <= 0.0031308 ? c * 12.92 : 1.055 * c ** (1 / 2.4) - 0.055);
const over = (fg, bg) => fg.rgb.map((v, i) => toLinear(toGamma(v) * fg.a + toGamma(bg.rgb[i]) * (1 - fg.a)));

// An alpha background counts as what it composites to. Transparent state layers sit on surface-1, and a
// tint such as bg-accent-primary/20 names its base: { tint, alpha, over }.
function backgroundOf(vars, bg) {
  if (typeof bg === "object") {
    const base = backgroundOf(vars, bg.over);
    return { rgb: over({ rgb: resolve(vars, bg.tint).rgb, a: bg.alpha }, base), a: 1 };
  }
  const c = resolve(vars, bg);
  if (c.a === 1 || bg === "--bg-surface-1") return c;
  return { rgb: over(c, resolve(vars, "--bg-surface-1")), a: 1 };
}
const nameOf = (bg) => (typeof bg === "object" ? `${bg.tint}/${Math.round(bg.alpha * 100)} over ${bg.over}` : bg);

const BG = ["--bg-canvas", "--bg-surface-1", "--bg-surface-2", "--bg-layer-1", "--bg-layer-2"];
const STATE_LAYERS = ["1", "2", "3"].flatMap((n) => ["hover", "active", "selected"].map((s) => `--bg-layer-${n}-${s}`));
const TRANSPARENT_LAYERS = ["hover", "active", "selected"].map((s) => `--bg-layer-transparent-${s}`);
// The tints upstream actually pairs with accent text, over the surfaces they appear on. /30 is only a hover
// state, and tokens.css moves the text to accent-secondary there. /80 and /90 under on-color text are made
// solid in tokens.css, so they are not listed.
const ACCENT_TINTS = [0.05, 0.1, 0.2].flatMap((alpha) =>
  ["--bg-canvas", "--bg-surface-1", "--bg-surface-2", "--bg-layer-1"].map((base) => ({ tint: "--bg-accent-primary", alpha, over: base }))
);
const HOVER_TINTS = ["--bg-canvas", "--bg-surface-1", "--bg-layer-1"].map((base) => ({ tint: "--bg-accent-primary", alpha: 0.3, over: base }));
const cross = (fgs, bgs, min) => fgs.flatMap((fg) => bgs.map((bg) => [fg, bg, min]));
const PAGE_PAIRS = [
  ...cross(["--txt-primary", "--txt-secondary", "--txt-tertiary"], [...BG, "--bg-layer-3", "--bg-layer-1-hover"], 4.5),
  ...cross(
    [
      "--txt-placeholder", "--txt-accent-primary", "--txt-accent-secondary", "--txt-link-primary",
      "--txt-link-primary-hover", "--txt-link-secondary", "--txt-success-primary", "--txt-success-secondary",
      "--txt-warning-primary", "--txt-warning-secondary", "--txt-danger-primary", "--txt-danger-secondary",
    ],
    BG,
    4.5
  ),
  ...cross(
    ["--txt-on-color"],
    [
      "--bg-accent-primary", "--bg-accent-primary-hover", "--bg-accent-primary-active", "--bg-danger-primary",
      "--bg-danger-primary-hover", "--bg-success-primary", "--bg-warning-primary",
    ],
    4.5
  ),
  ...cross(["--txt-primary", "--txt-secondary", "--txt-tertiary", "--txt-accent-primary"], [...STATE_LAYERS, ...TRANSPARENT_LAYERS], 4.5),
  ...cross(["--txt-accent-primary", "--txt-accent-secondary"], ACCENT_TINTS, 4.5),
  ...cross(["--txt-accent-secondary"], HOVER_TINTS, 4.5),
  ...cross(["--txt-accent-primary"], ["--bg-accent-subtle", "--bg-accent-subtle-hover", "--bg-accent-subtle-active"], 4.5),
  ...cross(["--txt-danger-primary", "--txt-danger-secondary"], ["--bg-danger-subtle", "--bg-danger-subtle-hover", "--bg-danger-subtle-active"], 4.5),
  ...cross(["--txt-success-primary"], ["--bg-success-subtle"], 4.5),
  ...cross(["--txt-warning-primary"], ["--bg-warning-subtle"], 4.5),
  ...cross(["--txt-icon-primary", "--txt-icon-secondary", "--txt-icon-tertiary"], BG, 3),
  ["--txt-icon-on-color", "--bg-accent-primary", 3],
  ...cross(["--bg-accent-primary", "--border-accent-strong"], ["--bg-canvas", "--bg-surface-1"], 3),
];
const SHELL_PAIRS = [
  ...cross(
    ["--txt-primary", "--txt-secondary", "--txt-tertiary", "--txt-placeholder", "--txt-accent-primary"],
    ["--bg-canvas", "--bg-surface-1", "--bg-surface-2", "--bg-layer-1", "--bg-layer-1-hover", "--bg-layer-transparent-hover"],
    4.5
  ),
  ...cross(["--txt-on-color"], ["--bg-accent-primary", "--bg-accent-primary-hover"], 4.5),
  ...cross(["--txt-icon-primary", "--txt-icon-secondary", "--txt-icon-tertiary"], ["--bg-surface-1", "--bg-layer-1"], 3),
  ...cross(["--bg-accent-primary", "--border-accent-strong"], ["--bg-surface-1"], 3),
];

let failures = 0;
let checked = 0;
function run(label, vars, pairs) {
  let lowest = Infinity;
  for (const [fg, bg, min] of pairs) {
    const b = backgroundOf(vars, bg);
    const r = ratio(over(resolve(vars, fg), b), b.rgb);
    checked++;
    lowest = Math.min(lowest, r);
    const failed = r < min;
    if (failed) failures++;
    if (failed || verbose) console.log(`${failed ? "FAIL" : "ok  "} ${label}: ${fg} on ${nameOf(bg)} = ${r.toFixed(2)} (min ${min})`);
  }
  console.log(`${label}: ${pairs.length} pairs, lowest ${lowest.toFixed(2)}`);
}

for (const theme of THEMES) {
  run(theme, themeVars(theme, false), PAGE_PAIRS);
  run(`${theme} [data-shell]`, themeVars(theme, true), SHELL_PAIRS);
  // shell.css: in the light themes the page under the top band is paper, with cards and fields raised on it.
  if (theme.startsWith("light")) {
    const page = themeVars(theme, false);
    page.set("--bg-surface-1", "var(--neutral-200)");
    page.set("--bg-surface-2", "var(--neutral-300)");
    page.set("--bg-layer-1", "var(--neutral-white)");
    page.set("--bg-layer-1-hover", "var(--neutral-100)");
    run(`${theme} page main`, page, PAGE_PAIRS);
  }
  const vars = themeVars(theme, false);
  const disabled = ratio(resolve(vars, "--txt-disabled").rgb, resolve(vars, "--bg-surface-1").rgb);
  console.log(`${theme}: disabled text on surface-1 = ${disabled.toFixed(2)} (exempt, informational)`);
}
// ---------- Shell scope (owner: shell agent, brand/shell.css) ----------
// Effective tokens inside data-shell="nav" and data-shell="top": tokens.css, then shell.css in order of
// specificity. Requires 4.5:1 for text and 3:1 for the route line, waypoint and unread dot. In both
// high-contrast themes shell text must reach 7:1 and hairlines 3:1, which is why those themes can keep
// the ink shell instead of skipping it.
{
  const shellDecls = parseCss(readFileSync(join(here, "../overlay/packages/tailwind-config/brand/shell.css"), "utf8"));
  const CONTRAST_SELECTOR = '[data-theme$="-contrast"] [data-shell]';
  const scoped = (theme, scope) => {
    const vars = themeVars(theme, true);
    const selectors = [
      "[data-shell]",
      `[data-shell="${scope}"]`,
      ...(theme.includes("dark") ? [`[data-theme*="dark"] [data-shell="${scope}"]`] : []),
      ...(theme.endsWith("-contrast") ? [CONTRAST_SELECTOR] : []),
    ];
    for (const selector of selectors) {
      for (const d of shellDecls) {
        if (d.name.startsWith("--") && d.path.length === 1 && d.path[0] === selector) vars.set(d.name, d.value);
      }
    }
    return vars;
  };
  const TEXT = [
    "--txt-primary", "--txt-secondary", "--txt-tertiary", "--txt-placeholder", "--txt-accent-primary",
    "--txt-accent-secondary", "--txt-link-primary", "--txt-danger-primary", "--txt-danger-secondary",
    "--txt-success-primary", "--txt-warning-primary",
  ];
  const ICONS = [
    "--txt-icon-primary", "--txt-icon-secondary", "--txt-icon-tertiary", "--txt-icon-placeholder",
    "--txt-icon-accent-primary", "--txt-icon-danger", "--txt-icon-danger-primary",
  ];
  const NAV_BG = [
    "--bg-surface-1", "--bg-surface-2", "--bg-layer-1", "--bg-layer-1-hover", "--bg-layer-1-active", "--bg-layer-2",
    "--bg-layer-2-hover", "--bg-layer-2-active", "--bg-layer-3", "--bg-layer-3-hover", "--bg-layer-3-active",
    "--bg-layer-transparent-hover", "--bg-layer-transparent-active", "--bg-layer-transparent-selected",
    "--bg-accent-subtle", "--bg-accent-subtle-hover",
  ];
  const TOP_BG = ["--bg-canvas", ...NAV_BG];
  const LINES = ["--border-subtle", "--border-subtle-1", "--border-strong"];
  const shellPairs = (bgs, marks, theme) => {
    const high = theme.endsWith("-contrast");
    return [
      ...cross(TEXT, bgs, high ? 7 : 4.5),
      ...cross(ICONS, bgs, 3),
      ...cross(["--txt-on-color", "--txt-icon-on-color"], ["--bg-accent-primary", "--bg-accent-primary-hover", "--bg-danger-primary"], 4.5),
      ...cross(["--bg-accent-primary", "--bg-danger-primary"], marks, 3),
      ...(high ? cross(LINES, marks, 3) : []),
      ...cross(["--txt-primary", "--txt-danger-primary"], ["--bg-danger-subtle", "--bg-danger-subtle-hover"], high ? 7 : 4.5),
      ...cross(["--txt-primary", "--txt-success-primary"], ["--bg-success-subtle"], high ? 7 : 4.5),
      ...cross(["--txt-primary", "--txt-warning-primary"], ["--bg-warning-subtle"], high ? 7 : 4.5),
    ];
  };
  for (const theme of THEMES) {
    run(`${theme} shell nav`, scoped(theme, "nav"), shellPairs(NAV_BG, ["--bg-surface-1"], theme));
    run(`${theme} shell top`, scoped(theme, "top"), shellPairs(TOP_BG, ["--bg-canvas", "--bg-surface-1"], theme));
    const vars = scoped(theme, "nav");
    const line = ratio(resolve(vars, "--border-subtle").rgb, resolve(vars, "--bg-surface-1").rgb);
    const disabled = ratio(resolve(vars, "--txt-disabled").rgb, resolve(vars, "--bg-surface-1").rgb);
    console.log(`${theme} shell: hairline ${line.toFixed(2)}, disabled text ${disabled.toFixed(2)} (informational, 7:1 and 3:1 rules above apply to high contrast only)`);
  }
}
// ---------- End of shell scope ----------

console.log(`${checked} pairs checked, ${failures} below AA`);
process.exit(failures ? 1 : 0);
