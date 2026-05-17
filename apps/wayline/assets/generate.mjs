#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Generates every Wayline image and web manifest into apps/wayline/overlay, at upstream's file names and
// pixel dimensions, so application code needs no edits. The outputs are committed, so a build does not
// need rsvg-convert, cwebp, dwebp or ffmpeg. Only this script does.
//
//   node apps/wayline/assets/generate.mjs              generate everything, verify, write the sheet
//   node apps/wayline/assets/generate.mjs --only cycle generate paths containing "cycle"
//   node apps/wayline/assets/generate.mjs --verify     check sizes and limits of what is in the overlay
//   node apps/wayline/assets/generate.mjs --verify --against <upstream checkout>
//                                                      also compare names and sizes with upstream, and list
//                                                      images shipping code imports that nothing here covers.
//                                                      Run this after bumping UPSTREAM.
//
// The list of what ships, and what was deliberately left alone, is in README.md next to this file.
import { execFile as execFileCb } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { contours, graticule, n, neatline, northArrow, PALETTES, rng, scaleBar, svgDoc } from "./lib/chart.mjs";
import { MOTIFS, pen } from "./lib/motifs.mjs";

const execFile = promisify(execFileCb);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../../..");
const OVERLAY = join(HERE, "../overlay");
const MASTERS = join(HERE, "masters");
const SHEET = join(ROOT, ".local/evidence-raw/wayline-assets-sheet.png");
const MAX_SPINNER_BYTES = 100 * 1024;
const MAX_TOTAL_BYTES = 4 * 1024 * 1024;

const argv = process.argv.slice(2);
const only = argv.includes("--only") ? argv[argv.indexOf("--only") + 1] : null;
const verifyOnly = argv.includes("--verify");
const against = argv.includes("--against") ? resolve(argv[argv.indexOf("--against") + 1]) : null;
const TMP = mkdtempSync(join(tmpdir(), "wayline-assets-"));

// ---------------------------------------------------------------------------------------------------
// Logo masters
// ---------------------------------------------------------------------------------------------------
const master = (name) => readFileSync(join(MASTERS, name), "utf8").replace(/<!--.*?-->\s*/s, "");
const inner = (svg) => svg.replace(/^.*?<svg[^>]*>/s, "").replace(/<\/svg>\s*$/s, "");
const MARK_DARK = inner(master("mark-dark.svg"));
const MARK_LIGHT = inner(master("mark.svg"));
const LOCKUP_DARK = inner(master("lockup-dark.svg"));
const LOCKUP_LIGHT = inner(master("lockup-light.svg"));
const INK = PALETTES.light.ink;

// The logo on an ink tile, the same treatment as the shell. `scale` is the share of the tile the mark
// fills. A tile with no corner radius is for platforms that apply their own mask.
function iconSvg(size, { scale = 0.72, radius = 3 / 32 } = {}) {
  const k = (size * scale) / 32;
  const off = (size - 32 * k) / 2;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">` +
    `<rect width="${size}" height="${size}" rx="${n(size * radius)}" fill="${INK}"/>` +
    `<g transform="translate(${n(off)} ${n(off)}) scale(${n(k)})">${MARK_DARK}</g></svg>\n`
  );
}

// Places a 253x53 lockup inside a box of any size, with no stretching, left aligned.
function lockupSvg(w, h, body) {
  const k = Math.min(w / 253, h / 53);
  return svgDoc(w, h, `<g transform="translate(0 ${n((h - 53 * k) / 2)}) scale(${n(k)})">${body}</g>`);
}
function markSvg(size, body) {
  const k = size / 32;
  return svgDoc(size, size, `<g transform="scale(${n(k)})">${body}</g>`);
}
const whiteLockup = LOCKUP_DARK.replaceAll("#E65AA6", "#FFFFFF").replaceAll("#E7E9EE", "#FFFFFF");

// ---------------------------------------------------------------------------------------------------
// Compositions
// ---------------------------------------------------------------------------------------------------
const strokeBoost = (scale) => Math.min(2.4, Math.max(1, (3 / scale) ** 0.7));

function drawMotif(name, p, cx, cy, scale, opts) {
  const k = strokeBoost(scale);
  return `<g transform="translate(${n(cx)} ${n(cy)}) scale(${n(scale)})">${MOTIFS[name](pen(p, k), opts)}</g>`;
}

// A compass bezel: it clears a circle for the symbol so contours and the route pass behind it.
function bezel(p, cx, cy, r, width) {
  let d = "";
  for (let a = 0; a < 360; a += 5) {
    const rad = (a * Math.PI) / 180;
    const inner = r * (a % 30 === 0 ? 0.93 : a % 15 === 0 ? 0.955 : 0.975);
    d += `M${n(cx + inner * Math.cos(rad))} ${n(cy + inner * Math.sin(rad))}L${n(cx + r * Math.cos(rad))} ${n(cy + r * Math.sin(rad))}`;
  }
  return (
    `<circle cx="${n(cx)}" cy="${n(cy)}" r="${n(r)}" fill="${p.surface}" stroke="${p.hair}" stroke-width="${n(width)}"/>` +
    `<path d="${d}" fill="none" stroke="${p.hair}" stroke-width="${n(width)}"/>`
  );
}

// A full chart plate: opaque, so it looks the same on any page behind it. Neatline, contours, graticule,
// north arrow, scale bar, a route across the sheet, and the topic symbol in a compass bezel.
function plate(w, h, motif, theme, { seed = motif, opts, side, levels = 16 } = {}) {
  const p = PALETTES[theme];
  const r = rng(`plate:${seed}`);
  const scale = (h * 0.62) / 100;
  const hairW = Math.max(1, 0.45 * scale);
  const wide = w / h > 1.25;
  const flip = side ?? r() < 0.5;
  const cx = wide ? (flip ? 0.34 : 0.66) * w : w / 2;
  const cy = h * (wide ? r.range(0.47, 0.53) : 0.5);
  const R = 62 * scale;
  const inset = Math.max(6, h * 0.022);
  const spacing = h / 24;
  const routeW = 1.25 * scale;
  const dash = `${n(routeW * 2.8)} ${n(routeW * 1.9)}`;

  let s = `<rect width="${w}" height="${h}" fill="${p.surface}"/>`;
  s += contours(w, h, { seed, palette: p, levels, hills: wide ? 7 : 5, width: hairW * 0.8, cell: Math.max(w, h) / 90 });
  s += graticule(w, h, { palette: p, inset, width: hairW, spacing });

  // The route enters on one side, passes behind the bezel and leaves on the other. Stops are spread over
  // the open chart beside the bezel, so none lands half under it. A narrow gap gets one stop or none.
  const y = (lo, hi) => h * r.range(lo, hi);
  const stops = (from, to) => {
    const room = Math.abs(to - from);
    const count = room > R * 1.5 ? 2 : room > R * 0.55 ? 1 : 0;
    return Array.from({ length: count }, (_, i) => [from + ((to - from) * (i + 0.7)) / (count + 0.2), y(0.22, 0.78)]);
  };
  const left = [[inset, y(0.25, 0.8)], ...stops(inset, cx - R * 1.12), [cx, cy]];
  const right = [[cx, cy], ...stops(cx + R * 1.12, w - inset), [w - inset, y(0.25, 0.8)]];
  const pts = [...left, ...right.slice(1)];
  s += `<path d="M${pts.map((q) => `${n(q[0])} ${n(q[1])}`).join("L")}" fill="none" stroke="${p.route}" stroke-width="${n(routeW)}" stroke-dasharray="${dash}"/>`;
  const wps = pts.slice(1, -1).filter((q) => q[0] !== cx);
  wps.forEach((q, i) => {
    const rr = 3 * scale;
    s += i % 2
      ? `<path d="M${n(q[0])} ${n(q[1] - rr * 1.4)}L${n(q[0] + rr * 1.4)} ${n(q[1])}L${n(q[0])} ${n(q[1] + rr * 1.4)}L${n(q[0] - rr * 1.4)} ${n(q[1])}Z" fill="${p.ink}"/>`
      : `<circle cx="${n(q[0])}" cy="${n(q[1])}" r="${n(rr)}" fill="${p.surface}" stroke="${p.ink}" stroke-width="${n(routeW * 0.85)}"/>`;
  });

  s += bezel(p, cx, cy, R, hairW);
  s += drawMotif(motif, p, cx, cy, scale, opts);

  if (wide) {
    const fx = flip ? w - inset - h * 0.1 : inset + h * 0.1;
    s += northArrow(fx, inset + h * 0.13, h * 0.032, { palette: p, width: hairW });
    const seg = h * 0.05;
    const sx = flip ? w - inset - h * 0.05 - seg * 4 : inset + h * 0.05;
    s += scaleBar(sx, h - inset - h * 0.085, seg, h * 0.012, { palette: p, width: hairW * 0.8 });
  }
  s += neatline(w, h, { palette: p, inset, width: hairW * 1.1, spacing });
  return svgDoc(w, h, s);
}

// A transparent symbol, for small slots and for images that sit on any page colour.
// `ground` adds a patch of contours fading out behind it.
function glyph(w, h, motif, theme, { opts, ground = false, seed = motif, fill = 0.82 } = {}) {
  const p = PALETTES[theme];
  const scale = (Math.min(w, h) * fill) / 100;
  let s = "";
  if (ground) {
    const hairW = Math.max(0.6, 0.35 * scale);
    s += `<defs><radialGradient id="f"><stop offset="0.45" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient><mask id="m"><rect width="${w}" height="${h}" fill="url(#f)"/></mask></defs>`;
    s += `<g mask="url(#m)">${contours(w, h, { seed, palette: p, levels: 12, hills: 4, width: hairW, cell: Math.max(w, h) / 44, minPoints: 6 })}</g>`;
  }
  s += drawMotif(motif, p, w / 2, h / 2, scale, opts);
  return svgDoc(w, h, s);
}

// The same symbol with no ground, the form the SVG outputs use.
const symbol = (w, h, motif, theme, opts, fill) => glyph(w, h, motif, theme, { opts, fill });

// Transparent contours and graticule only, for page backgrounds.
function ground(w, h, theme, { seed, levels = 12, digits = 0, cellDiv = 44 }) {
  const p = PALETTES[theme];
  const hairW = Math.max(1, Math.min(w, h) / 900);
  let s = contours(w, h, { seed, palette: p, levels, hills: 6, width: hairW, cell: Math.max(w, h) / cellDiv, minPoints: 6, digits });
  s += graticule(w, h, { palette: p, inset: 0, width: hairW, spacing: h / 24 });
  return svgDoc(w, h, s);
}

// A strip chart: a straight route with the logo on it, for the very wide "instance" banners.
function banner(w, h, theme) {
  const p = PALETTES[theme];
  const r = rng(`banner:${w}`);
  const hairW = Math.max(1, h / 500);
  const cy = h / 2;
  const routeW = h / 110;
  let s = `<rect width="${w}" height="${h}" fill="${p.surface}"/>`;
  s += contours(w, h, { seed: `banner-${w}`, palette: p, levels: 12, width: hairW, cell: w / 120 });
  s += graticule(w, h, { palette: p, inset: h * 0.03, width: hairW, spacing: h / 12 });
  const stops = Array.from({ length: 7 }, (_, i) => [w * (0.06 + 0.147 * i), cy + (i === 3 ? 0 : r.range(-0.22, 0.22) * h)]);
  s += `<path d="M${stops.map((q) => `${n(q[0])} ${n(q[1])}`).join("L")}" fill="none" stroke="${p.route}" stroke-width="${n(routeW)}" stroke-dasharray="${n(routeW * 2.8)} ${n(routeW * 1.9)}"/>`;
  stops.forEach((q, i) => {
    if (i !== 3) s += `<circle cx="${n(q[0])}" cy="${n(q[1])}" r="${n(routeW * 2.2)}" fill="${p.surface}" stroke="${p.ink}" stroke-width="${n(routeW * 0.8)}"/>`;
  });
  const tile = h * 0.46;
  const tileK = (tile * 0.72) / 32;
  s += `<rect x="${n(stops[3][0] - tile / 2)}" y="${n(cy - tile / 2)}" width="${n(tile)}" height="${n(tile)}" rx="${n(tile * 0.05)}" fill="${INK}"/>`;
  s += `<g transform="translate(${n(stops[3][0] - 16 * tileK)} ${n(cy - 16 * tileK)}) scale(${n(tileK)})">${MARK_DARK}</g>`;
  s += neatline(w, h, { palette: p, inset: h * 0.03, width: hairW, spacing: h / 12 });
  return svgDoc(w, h, s);
}

// Social card: ink chart, logo, a route running through it. The only words are the wordmark.
function ogImage(w, h) {
  const p = PALETTES.dark;
  const hairW = 1.2;
  let s = `<rect width="${w}" height="${h}" fill="${p.paper}"/>`;
  s += contours(w, h, { seed: "og", palette: p, levels: 18, width: hairW, cell: w / 110 });
  s += graticule(w, h, { palette: p, inset: 18, width: hairW, spacing: 26 });
  s += `<path d="M18 ${h - 150}L180 ${h - 210}L330 ${h - 150}" fill="none" stroke="${p.route}" stroke-width="5" stroke-dasharray="15 10"/>`;
  s += `<path d="M880 210L1010 150L${w - 18} 215" fill="none" stroke="${p.route}" stroke-width="5" stroke-dasharray="15 10"/>`;
  for (const [x, y] of [[180, h - 210], [1010, 150]]) s += `<circle cx="${x}" cy="${y}" r="10" fill="${p.paper}" stroke="${p.ink}" stroke-width="4"/>`;
  const k = 2.1;
  const lw = 253 * k;
  const lh = 53 * k;
  const pad = 46;
  s += `<rect x="${n((w - lw) / 2 - pad)}" y="${n((h - lh) / 2 - pad)}" width="${n(lw + 2 * pad)}" height="${n(lh + 2 * pad)}" rx="3" fill="${p.surface}" stroke="${p.hair}" stroke-width="1.5"/>`;
  s += `<g transform="translate(${n((w - lw) / 2)} ${n((h - lh) / 2)}) scale(${k})">${LOCKUP_DARK}</g>`;
  s += `<path d="M330 ${h - 150}L${n((w - lw) / 2 - pad)} ${n(h / 2 + 40)}M${n((w + lw) / 2 + pad)} ${n(h / 2 - 40)}L880 210" fill="none" stroke="${p.route}" stroke-width="5" stroke-dasharray="15 10"/>`;
  s += neatline(w, h, { palette: p, inset: 18, width: 1.5, spacing: 26 });
  return svgDoc(w, h, s);
}

// The welcome image: the logo tile on a short route. Reads on either theme.
function welcomeLogo(w, h) {
  const p = PALETTES.neutral;
  const tile = h * 0.72;
  const k = (tile * 0.72) / 32;
  const cx = w / 2;
  const cy = h / 2;
  const lw = h / 60;
  let s = `<path d="M${n(w * 0.06)} ${n(cy + h * 0.2)}L${n(cx)} ${n(cy)}L${n(w * 0.94)} ${n(cy - h * 0.2)}" fill="none" stroke="${p.route}" stroke-width="${n(lw)}" stroke-dasharray="${n(lw * 3)} ${n(lw * 2)}"/>`;
  s += `<circle cx="${n(w * 0.06)}" cy="${n(cy + h * 0.2)}" r="${n(lw * 2.6)}" stroke="${p.ink}" stroke-width="${n(lw)}"/>`;
  s += `<path d="M${n(w * 0.94)} ${n(cy - h * 0.2 - lw * 3.6)}l${n(lw * 3.6)} ${n(lw * 3.6)}l${n(-lw * 3.6)} ${n(lw * 3.6)}l${n(-lw * 3.6)} ${n(-lw * 3.6)}Z" fill="${p.ink}"/>`;
  s += `<rect x="${n(cx - tile / 2)}" y="${n(cy - tile / 2)}" width="${n(tile)}" height="${n(tile)}" rx="${n(tile * 0.04)}" fill="${INK}" stroke="#3C4D6B" stroke-width="${n(lw * 0.5)}"/>`;
  s += `<g transform="translate(${n(cx - 16 * k)} ${n(cy - 16 * k)}) scale(${n(k)})">${MARK_DARK}</g>`;
  return svgDoc(w, h, s);
}

function bgLogo(w, h) {
  const p = PALETTES.neutral;
  const k = (h * 0.7) / 32;
  const body = contours(w, h, { seed: "welcome-bg", palette: { ...p, contourOpacity: 0.55 }, levels: 14, width: 1.4, cell: w / 80 });
  return svgDoc(w, h, `${body}<g transform="translate(${n(w / 2 - 16 * k)} ${n(h / 2 - 16 * k)}) scale(${n(k)})">${MARK_LIGHT.replaceAll(INK, "#7C8798").replaceAll("#B0186E", "#D0378C")}</g>`);
}

// The icon shown in the admin's new-user popup: the logo inside a graduated ring.
function takeoffIcon(theme) {
  const p = PALETTES[theme];
  const mark = theme === "dark" ? MARK_DARK : MARK_LIGHT;
  const w = 91;
  const h = 90;
  let d = "";
  for (let a = 0; a < 360; a += 15) {
    const t = (a * Math.PI) / 180;
    const r0 = a % 45 ? 41 : 39;
    d += `M${n(45.5 + r0 * Math.cos(t))} ${n(45 + r0 * Math.sin(t))}L${n(45.5 + 44 * Math.cos(t))} ${n(45 + 44 * Math.sin(t))}`;
  }
  const s = `<circle cx="45.5" cy="45" r="44" stroke="${p.hair}"/><path d="${d}" stroke="${p.hair}"/><g transform="translate(25 24.5) scale(1.28)">${mark}</g>`;
  return svgDoc(w, h, s);
}

// ---------------------------------------------------------------------------------------------------
// The image list: path, [width, height], how to draw it. Dimensions are upstream's, odd ones included.
// ---------------------------------------------------------------------------------------------------
const WEB = "apps/web/app/assets";
const ADMIN = "apps/admin/app/assets";
const SPACE = "apps/space/app/assets";
const APPS = ["web", "admin", "space"];
const ES = `${WEB}/empty-state`;

const jobs = [];
const add = (path, build) => jobs.push({ path, build });
const raster = (path, w, h, svg, encode = {}) => add(path, { kind: "raster", w, h, svg, encode });
const opaque = { opaque: true };
const vector = (path, svg) => add(path, { kind: "svg", svg });

// Light and dark variants of one idea. `dims` is [w, h], or { light: [w, h], dark: [w, h] }.
function pair(base, ext, dims, draw, encode) {
  for (const theme of ["light", "dark"]) {
    const [w, h] = Array.isArray(dims) ? dims : dims[theme];
    const path = `${base}-${theme}.${ext}`;
    if (ext === "svg") vector(path, () => draw(w, h, theme));
    else raster(path, w, h, () => draw(w, h, theme), encode);
  }
}
const platePair = (base, ext, dims, motif, o = {}) => pair(base, ext, dims, (w, h, t) => plate(w, h, motif, t, { seed: base, ...o }), opaque);
const glyphPair = (base, ext, dims, motif, o = {}) => pair(base, ext, dims, (w, h, t) => glyph(w, h, motif, t, { seed: base, ...o }));

// --- 1. Favicons and app icons ---
for (const app of APPS) {
  const fav = `apps/${app}/app/assets/favicon`;
  raster(`${fav}/apple-touch-icon.png`, 180, 180, () => iconSvg(180, { radius: 0 }));
  raster(`${fav}/favicon-16x16.png`, 16, 16, () => iconSvg(16, { scale: 0.86, radius: 2 / 16 }));
  raster(`${fav}/favicon-32x32.png`, 32, 32, () => iconSvg(32, { scale: 0.8 }));
  add(`${fav}/favicon.ico`, { kind: "ico", sizes: [16, 32, 48] });
  for (const size of [192, 512]) raster(`apps/${app}/public/favicon/android-chrome-${size}x${size}.png`, size, size, () => iconSvg(size, { radius: 0, scale: 0.62 }));
}
// icon-192x192 is declared "any maskable" in the manifest, so the mark stays in the 80% safe zone.
for (const size of [192, 348, 512]) raster(`apps/web/public/icons/icon-${size}x${size}.png`, size, size, () => iconSvg(size, { radius: 0, scale: 0.6 }));
raster("apps/web/public/plane-logos/plane-mobile-pwa.png", 1024, 1024, () => iconSvg(1024, { radius: 0, scale: 0.6 }));
raster(`${WEB}/icons/icon-180x180.png`, 180, 180, () => iconSvg(180, { radius: 0 }));
raster(`${WEB}/icons/icon-512x512.png`, 512, 512, () => iconSvg(512, { radius: 0, scale: 0.6 }));

// --- 2. Spinners ---
for (const app of APPS) {
  add(`apps/${app}/app/assets/images/logo-spinner-light.gif`, { kind: "gif", dark: false });
  add(`apps/${app}/app/assets/images/logo-spinner-dark.gif`, { kind: "gif", dark: true });
}

// --- 3. Marks ---
raster(`${WEB}/auth/gradient-logo.webp`, 561, 312, () => welcomeLogo(561, 312));
raster(`${WEB}/auth/gradient-bg-logo.webp`, 1080, 672, () => bgLogo(1080, 672));
for (const path of [`${WEB}/plane-takeoff.png`, `${ADMIN}/images/plane-takeoff.png`, `${SPACE}/instance/plane-takeoff.png`]) {
  raster(path, 470, 276, () => glyph(470, 276, "takeoff", "neutral", { fill: 0.86 }));
}
vector(`${ADMIN}/logos/takeoff-icon-light.svg`, () => takeoffIcon("light"));
vector(`${ADMIN}/logos/takeoff-icon-dark.svg`, () => takeoffIcon("dark"));
for (const dir of [`${WEB}/plane-logos`, `${SPACE}/plane-logos`]) {
  raster(`${dir}/black-horizontal-with-blue-logo.png`, 269, 60, () => lockupSvg(269, 60, LOCKUP_LIGHT));
  raster(`${dir}/white-horizontal-with-blue-logo.png`, 269, 60, () => lockupSvg(269, 60, LOCKUP_DARK));
  raster(`${dir}/blue-without-text.png`, 276, 276, () => markSvg(276, MARK_LIGHT));
  vector(`${dir}/white-horizontal.svg`, () => lockupSvg(178, 40, whiteLockup));
}
raster(`${SPACE}/plane-logos/blue-without-text-new.png`, 276, 276, () => markSvg(276, MARK_LIGHT));
vector(`${SPACE}/plane-logo.svg`, () => markSvg(155, MARK_LIGHT));
raster(`${WEB}/instance-not-ready.webp`, 2160, 548, () => banner(2160, 548, "dark"), opaque);
raster(`${SPACE}/instance/plane-instance-not-ready.webp`, 3600, 536, () => banner(3600, 536, "dark"), opaque);
raster(`${WEB}/instance-setup-done.webp`, 2798, 1776, () => plate(2798, 1776, "takeoff", "dark", { seed: "setup-done" }), opaque);
raster(`${WEB}/og-image.png`, 1201, 631, () => ogImage(1201, 631));
vector("packages/propel/public/plane-lockup-light.svg", () => lockupSvg(253, 53, LOCKUP_DARK));
raster(`${WEB}/workspace/workspace-not-available.png`, 617, 651, () => glyph(617, 651, "lost", "neutral", { ground: true, seed: "ws-gone", fill: 0.78 }));
raster(`${WEB}/workspace/workspace-creation-disabled.png`, 617, 651, () => glyph(617, 651, "restricted", "neutral", { ground: true, seed: "ws-off", fill: 0.78, opts: { center: "plus" } }));

// --- 4. Empty states and other illustrations imported by shipping code ---
const FEATURE = [2631, 1200];
platePair(`${ES}/cycle/active`, "webp", FEATURE, "holding", { opts: { partial: true } });
platePair(`${ES}/disabled-feature/cycles`, "webp", FEATURE, "holding");
platePair(`${ES}/disabled-feature/intake`, "webp", FEATURE, "merge");
platePair(`${ES}/disabled-feature/modules`, "webp", { light: [2632, 1201], dark: FEATURE }, "sectors");
platePair(`${ES}/disabled-feature/pages`, "webp", { light: [2632, 1201], dark: FEATURE }, "sheet");
platePair(`${ES}/disabled-feature/views`, "webp", FEATURE, "viewport");
platePair(`${ES}/stickies/stickies`, "webp", FEATURE, "notes");
platePair(`${ES}/project-settings/no-projects`, "png", [1440, 840], "folio");
platePair(`${ES}/dashboard/widgets`, "webp", [617, 615], "panels");
platePair(`${ES}/search/project`, "webp", { light: [615, 651], dark: [615, 615] }, "folio");
platePair(`${ES}/stickies/stickies-search`, "webp", [615, 735], "rings");

glyphPair(`${ES}/active-cycle/assignee`, "webp", { light: [156, 157], dark: [157, 156] }, "crew");
glyphPair(`${ES}/active-cycle/chart`, "webp", { light: [156, 156], dark: [157, 157] }, "trend");
glyphPair(`${ES}/active-cycle/label`, "webp", { light: [156, 157], dark: [157, 156] }, "tag");
glyphPair(`${ES}/active-cycle/priority`, "webp", { light: [156, 156], dark: [157, 156] }, "altitude");
glyphPair(`${ES}/active-cycle/progress`, "webp", { light: [156, 156], dark: [157, 157] }, "position");
glyphPair(`${ES}/search/issues`, "webp", [294, 294], "log");
glyphPair(`${ES}/search/search`, "webp", [294, 294], "rings");
glyphPair(`${ES}/wiki/navigation-pane/assets`, "webp", [260, 327], "gallery");
glyphPair(`${ES}/wiki/navigation-pane/outline`, "webp", [260, 307], "outline");
pair(`${ES}/analytics/empty-grid-background`, "webp", { light: [440, 437], dark: [438, 438] }, (w, h, t) => {
  const p = PALETTES[t];
  const stepX = w / 12;
  let d = "";
  for (let i = 1; i < 12; i++) d += `M${n(i * stepX)} 0V${h}M0 ${n((i * h) / 12)}H${w}`;
  const mask = `<defs><radialGradient id="f"><stop offset="0.3" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient><mask id="m"><rect width="${w}" height="${h}" fill="url(#f)"/></mask></defs>`;
  return svgDoc(w, h, `${mask}<g mask="url(#m)"><path d="${d}" stroke="${p.hair}" stroke-width="1"/>${graticule(w, h, { palette: p, inset: 0, width: 1.5, spacing: stepX / 5 })}</g>`);
});

// Upstream ships these in one variant, so they use the neutral palette and read on both themes.
const neutralSymbol = (path, w, h, motif, opts, fill) => vector(path, () => symbol(w, h, motif, "neutral", opts, fill));
neutralSymbol(`${ES}/api-token.svg`, 128, 130, "key");
neutralSymbol(`${ES}/web-hook.svg`, 128, 130, "beacon");
neutralSymbol(`${ES}/cycle.svg`, 182, 160, "holding");
neutralSymbol(`${ES}/module.svg`, 128, 120, "sectors");
neutralSymbol(`${ES}/view.svg`, 135, 120, "viewport");
neutralSymbol(`${ES}/issue.svg`, 97, 110, "log");
neutralSymbol(`${ES}/invitation.svg`, 225, 172, "invite");
neutralSymbol(`${ES}/empty_label.svg`, 40, 40, "tag", undefined, 0.9);
neutralSymbol(`${ES}/empty_members.svg`, 48, 48, "crew", undefined, 0.9);
neutralSymbol(`${ES}/cycle/all-filters.svg`, 205, 217, "funnel", { top: "oval" });
neutralSymbol(`${ES}/cycle/name-filter.svg`, 205, 217, "field", { top: "oval" });
neutralSymbol(`${ES}/module/all-filters.svg`, 205, 217, "funnel", { top: "hex" });
neutralSymbol(`${ES}/module/name-filter.svg`, 206, 217, "field", { top: "hex" });

// The tour shows one image in both themes, so it uses Night Ops, the same ink as the shell.
for (const [name, motif] of [["cycles", "holding"], ["issues", "log"], ["modules", "sectors"], ["pages", "sheet"], ["views", "viewport"]]) {
  raster(`${WEB}/onboarding/${name}.webp`, 1920, 1080, () => plate(1920, 1080, motif, "dark", { seed: `tour-${name}` }), opaque);
}
raster(`${WEB}/onboarding/onboarding-pages.webp`, 900, 507, () => plate(900, 507, "sheet", "dark", { seed: "feature-pages" }), opaque);

// Upgrade prompt panels. Imported, so they ship, even though no CE route is expected to show them.
const CTA = `${WEB}/workspace-active-cycles`;
glyphPair(`${CTA}/cta-l-1`, "webp", { light: [390, 390], dark: [450, 330] }, "holding", { ground: true });
platePair(`${CTA}/cta-r-1`, "webp", [1641, 1134], "position");
platePair(`${CTA}/cta-r-2`, "webp", { light: [989, 799], dark: [989, 798] }, "profile");

// Sign-in and access
const AUTH = `${WEB}/auth`;
vector(`${AUTH}/unauthorized.svg`, () => symbol(264.935, 151.935, "restricted", "neutral", { center: "bar" }));
neutralSymbol(`${AUTH}/project-not-authorized.svg`, 283, 174, "restricted", { shape: "hex", center: "sheet" });
neutralSymbol(`${AUTH}/workspace-not-authorized.svg`, 283, 174, "restricted", { shape: "square", center: "grid" });
neutralSymbol(`${AUTH}/access-denied.svg`, 632, 269, "restricted", { center: "bar" });
for (const app of [WEB, SPACE]) {
  vector(`${app}/auth/background-pattern.svg`, () => ground(1512, 900, "light", { seed: "auth-pattern" }));
  vector(`${app}/auth/background-pattern-dark.svg`, () => ground(1512, 900, "dark", { seed: "auth-pattern" }));
}

// Errors and instance states
vector(`${WEB}/404.svg`, () => symbol(596, 568, "lost", "neutral", undefined, 0.8));
vector(`${SPACE}/404.svg`, () => symbol(596, 568, "lost", "neutral", undefined, 0.8));
vector(`${ADMIN}/images/404.svg`, () => symbol(596, 568, "lost", "neutral", undefined, 0.8));
pair(`${WEB}/instance/maintenance-mode`, "svg", [595, 300], (w, h, t) => symbol(w, h, "obstacle", t));
for (const dir of [`${ADMIN}/instance`, `${SPACE}/instance`]) {
  vector(`${dir}/instance-failure.svg`, () => symbol(210, 206, "broken", "light"));
  vector(`${dir}/instance-failure-dark.svg`, () => symbol(210, 206, "broken", "dark"));
}
neutralSymbol(`${SPACE}/something-went-wrong.svg`, 104, 104, "broken");
neutralSymbol(`${SPACE}/project-not-published.svg`, 219, 219, "restricted", { shape: "square", center: "sheet" });
neutralSymbol(`${SPACE}/user-logged-in.svg`, 125, 125, "signedIn");
raster(`${SPACE}/instance/intake-sent-light.png`, 616, 616, () => glyph(616, 616, "merge", "light", { ground: true, seed: "intake-sent", fill: 0.62 }));
raster(`${SPACE}/instance/intake-sent-dark.png`, 616, 615, () => glyph(616, 615, "merge", "dark", { ground: true, seed: "intake-sent", fill: 0.62 }));

// ---------------------------------------------------------------------------------------------------
// Web manifests
// ---------------------------------------------------------------------------------------------------
const THEME_COLOR = INK;
const BACKGROUND = "#F4F2EA";
const DESCRIPTION = "Wayline: issues, cycles and modules for your projects. Built on Plane Community Edition.";
const chrome = [
  { src: "/favicon/android-chrome-192x192.png", sizes: "192x192", type: "image/png" },
  { src: "/favicon/android-chrome-512x512.png", sizes: "512x512", type: "image/png" },
];
const pwa = (name) => ({ name, short_name: name, description: DESCRIPTION, start_url: ".", display: "standalone", background_color: BACKGROUND, theme_color: THEME_COLOR, icons: chrome });
const favManifest = { name: "Wayline", short_name: "Wayline", icons: chrome, theme_color: THEME_COLOR, background_color: BACKGROUND, display: "standalone" };
const MANIFESTS = {
  "apps/web/manifest.json": {
    theme_color: THEME_COLOR, background_color: BACKGROUND, display: "standalone", scope: "/", start_url: "/",
    name: "Wayline", short_name: "Wayline", description: DESCRIPTION,
    // Upstream lists these files though it ships none at the web root, and this file is outside public/. Left as is.
    icons: [192, 256, 384, 512].map((s) => ({ src: `/icon-${s}x${s}.png`, sizes: `${s}x${s}`, type: "image/png" })),
  },
  "apps/web/public/manifest.json": {
    name: "Wayline", short_name: "Wayline",
    icons: [
      { src: "/icons/icon-192x192.png", sizes: "192x192", type: "image/png", purpose: "any maskable" },
      { src: "/icons/icon-348x348.png", sizes: "348x348", type: "image/png" },
      { src: "/icons/icon-512x512.png", sizes: "512x512", type: "image/png" },
    ],
    theme_color: THEME_COLOR, background_color: BACKGROUND, start_url: "/", display: "standalone", orientation: "portrait",
  },
  "apps/web/public/site.webmanifest.json": {
    ...pwa("Wayline"),
    icons: [
      { src: "/plane-logos/plane-mobile-pwa.png", sizes: "192x192", type: "image/png" },
      { src: "/plane-logos/plane-mobile-pwa.png", sizes: "512x512", type: "image/png" },
    ],
  },
  "apps/web/public/favicon/site.webmanifest": favManifest,
  "apps/admin/public/site.webmanifest.json": pwa("Wayline God Mode"),
  "apps/space/public/site.webmanifest.json": pwa("Wayline Space"),
  "apps/space/app/assets/favicon/site.webmanifest": favManifest,
};

// ---------------------------------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------------------------------
const run = async (cmd, args) => (await execFile(cmd, args, { maxBuffer: 64 * 1024 * 1024 })).stdout;
let tmpId = 0;
const tmp = (name) => join(TMP, `${tmpId++}-${name}`);

async function renderPng(svg, out) {
  const src = tmp("in.svg");
  writeFileSync(src, svg);
  await run("rsvg-convert", ["-o", out, src]);
}

function outPath(rel) {
  const p = join(OVERLAY, rel);
  mkdirSync(dirname(p), { recursive: true });
  return p;
}

async function buildRaster(rel, job) {
  const out = outPath(rel);
  const svg = job.svg();
  if (rel.endsWith(".png")) return renderPng(svg, out);
  const png = tmp("r.png");
  await renderPng(svg, png);
  await run("cwebp", ["-quiet", "-m", "6", "-q", "78", ...(job.encode.opaque ? ["-noalpha"] : ["-alpha_q", "90"]), png, "-o", out]);
}

// Frames from the master spinner. Colour is composited over the theme's canvas before keying, so edge
// pixels blend into that canvas instead of showing a fringe, and the outside stays transparent.
const spinnerCache = new Map();
async function buildSpinner(dark) {
  const key = dark ? "dark" : "light";
  if (spinnerCache.has(key)) return spinnerCache.get(key);
  const task = (async () => {
    const bg = dark ? PALETTES.dark.paper : PALETTES.light.paper;
    const dir = tmp(`spin-${key}`);
    const SIZE = 88;
    const flags = dark ? ["--dark"] : [];
    await run("node", [join(MASTERS, "spinner.mjs"), join(dir, "c"), ...flags, "--frames", "20", "--bg", bg]);
    await run("node", [join(MASTERS, "spinner.mjs"), join(dir, "a"), ...flags, "--frames", "20"]);
    for (const part of ["c", "a"]) {
      await Promise.all(Array.from({ length: 20 }, (_, i) => {
        const base = join(dir, part, `frame-${String(i).padStart(3, "0")}`);
        return run("rsvg-convert", ["-w", String(SIZE), "-h", String(SIZE), "-o", `${base}.png`, `${base}.svg`]);
      }));
    }
    const out = join(dir, "spinner.gif");
    await run("ffmpeg", [
      "-y", "-loglevel", "error",
      "-framerate", "18", "-i", join(dir, "c", "frame-%03d.png"),
      "-framerate", "18", "-i", join(dir, "a", "frame-%03d.png"),
      "-filter_complex",
      "[0:v]format=rgb24[c];[1:v]format=rgba,alphaextract,lut=y='if(gt(val,10),255,0)'[a];[c][a]alphamerge,split[x][y];" +
        "[x]palettegen=max_colors=24:reserve_transparent=1:stats_mode=full[p];[y][p]paletteuse=dither=none:alpha_threshold=128",
      "-loop", "0", "-gifflags", "-offsetting", out,
    ]);
    return readFileSync(out);
  })();
  spinnerCache.set(key, task);
  return task;
}

// A Windows icon with PNG payloads: 6-byte header, 16 bytes per image, then the images.
async function buildIco(rel, sizes) {
  const pngs = await Promise.all(sizes.map(async (size) => {
    const f = tmp(`ico${size}.png`);
    await renderPng(iconSvg(size, { scale: size < 32 ? 0.86 : 0.8, radius: size < 32 ? 2 / 16 : 3 / 32 }), f);
    return readFileSync(f);
  }));
  const header = Buffer.alloc(6 + 16 * sizes.length);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  sizes.forEach((size, i) => {
    const e = 6 + 16 * i;
    header.writeUInt8(size, e);
    header.writeUInt8(size, e + 1);
    header.writeUInt16LE(1, e + 4);
    header.writeUInt16LE(32, e + 6);
    header.writeUInt32LE(pngs[i].length, e + 8);
    header.writeUInt32LE(offset, e + 12);
    offset += pngs[i].length;
  });
  writeFileSync(outPath(rel), Buffer.concat([header, ...pngs]));
}

async function buildJob({ path, build }) {
  if (build.kind === "raster") return buildRaster(path, build);
  if (build.kind === "svg") return writeFileSync(outPath(path), build.svg());
  if (build.kind === "gif") return writeFileSync(outPath(path), await buildSpinner(build.dark));
  if (build.kind === "ico") return buildIco(path, build.sizes);
  throw new Error(`unknown kind for ${path}`);
}

async function pool(items, limit, fn) {
  let next = 0;
  await Promise.all(Array.from({ length: limit }, async () => {
    while (next < items.length) await fn(items[next++]);
  }));
}

// ---------------------------------------------------------------------------------------------------
// Verification, from the bytes on disk
// ---------------------------------------------------------------------------------------------------
function imageSize(file) {
  const b = readFileSync(file);
  if (b.subarray(1, 4).toString() === "PNG") return [b.readUInt32BE(16), b.readUInt32BE(20)];
  if (b.subarray(0, 3).toString() === "GIF") return [b.readUInt16LE(6), b.readUInt16LE(8)];
  if (b.subarray(0, 4).toString() === "RIFF") {
    const c = b.subarray(12, 16).toString();
    if (c === "VP8 ") return [b.readUInt16LE(26) & 0x3fff, b.readUInt16LE(28) & 0x3fff];
    if (c === "VP8L") {
      const bits = b.readUInt32LE(21);
      return [(bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1];
    }
    if (c === "VP8X") return [b.readUIntLE(24, 3) + 1, b.readUIntLE(27, 3) + 1];
  }
  return null;
}

function verify() {
  const problems = [];
  let total = 0;
  for (const { path, build } of jobs) {
    const file = join(OVERLAY, path);
    if (!existsSync(file)) {
      problems.push(`missing ${path}`);
      continue;
    }
    total += statSync(file).size;
    if (build.kind === "raster") {
      const got = imageSize(file);
      if (!got || got[0] !== build.w || got[1] !== build.h) problems.push(`${path}: ${got} is not ${build.w}x${build.h}`);
    }
    if (build.kind === "gif" && statSync(file).size > MAX_SPINNER_BYTES) problems.push(`${path}: over 100 KB`);
  }
  for (const rel of Object.keys(MANIFESTS)) {
    const file = join(OVERLAY, rel);
    if (!existsSync(file)) problems.push(`missing ${rel}`);
    else if (/Plane(?! Community Edition)/.test(readFileSync(file, "utf8"))) problems.push(`${rel}: upstream name`);
  }
  if (total > MAX_TOTAL_BYTES) problems.push(`total ${total} bytes is over the 4 MiB target`);
  console.log(`${jobs.length} images, ${Object.keys(MANIFESTS).length} manifests, ${(total / 1048576).toFixed(2)} MiB in the overlay`);
  for (const p of problems) console.error(`FAIL ${p}`);
  return problems.length === 0;
}

function svgSize(file) {
  const head = readFileSync(file, "utf8").match(/<svg[^>]*>/)?.[0] ?? "";
  const w = head.match(/\swidth="([\d.]+)/)?.[1];
  const h = head.match(/\sheight="([\d.]+)/)?.[1];
  return w && h ? [Number(w), Number(h)] : null;
}

// Rows of the "left alone" table in README.md: | `path or prefix, * for one directory` | reason |
function keptPatterns() {
  return [...readFileSync(join(HERE, "README.md"), "utf8").matchAll(/^\| `((?:apps|packages)\/[^`]+)` \|/gm)].map(
    (m) => new RegExp(`^${m[1].replace(/[.+?^$()[\]{}|\\]/g, "\\$&").replaceAll("*", "[^/]+")}`)
  );
}

function sourceFiles(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (["node_modules", "build", "dist", ".turbo", ".react-router", ".git"].includes(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) sourceFiles(p, out);
    else if (/\.(tsx?|jsx?|mjs|css|html)$|manifest(\.json)?$|^manifest\.json$/.test(name) && !/^(sw|workbox-)/.test(name)) out.push(p);
  }
  return out;
}

// Same dimensions under the same name, and nothing imported by shipping code left uncovered.
function verifyAgainst(tree) {
  const problems = [];
  for (const { path, build } of jobs) {
    const up = join(tree, path);
    if (!existsSync(up)) {
      problems.push(`upstream has no ${path}`);
      continue;
    }
    if (build.kind === "gif" || build.kind === "ico") continue; // The spinner's size is ours on purpose: its slot is height-driven.
    const a = path.endsWith(".svg") ? svgSize(up) : imageSize(up);
    const b = path.endsWith(".svg") ? svgSize(join(OVERLAY, path)) : imageSize(join(OVERLAY, path));
    if (a && (!b || Math.abs(a[0] - b[0]) > 0.01 || Math.abs(a[1] - b[1]) > 0.01)) problems.push(`${path}: upstream ${a}, ours ${b}`);
  }
  const covered = new Set(jobs.map((j) => j.path));
  const kept = keptPatterns();
  const ref = /["'`(]((?:@\/|\.\.?\/|\/)[^"'`()\s]*?\.(?:png|webp|svg|gif|jpe?g|ico))(?:\?[a-z]*)?["'`)]/g;
  const seen = new Set();
  for (const root of ["apps/web", "apps/admin", "apps/space", "packages"]) {
    for (const file of sourceFiles(join(tree, root))) {
      const rel = file.slice(tree.length + 1);
      const app = rel.match(/^apps\/(web|admin|space)\//)?.[0];
      for (const m of readFileSync(file, "utf8").matchAll(ref)) {
        const r = m[1];
        const candidates = r.startsWith("@/") && app ? [app + r.slice(2)]
          : r.startsWith(".") ? [join(dirname(rel), r)]
          : r.startsWith("/") && app ? [`${app}public${r}`, app + r.slice(1)]
          : [];
        for (const c of candidates) if (existsSync(join(tree, c))) seen.add(c);
      }
    }
  }
  const uncovered = [...seen].filter((c) => !covered.has(c) && !kept.some((k) => k.test(c))).sort();
  for (const c of uncovered) problems.push(`imported by shipping code and not covered: ${c}`);
  console.log(`against ${tree}: ${jobs.length} outputs compared, ${seen.size} images referenced by source, ${uncovered.length} uncovered`);
  for (const p of problems) console.error(`FAIL ${p}`);
  return problems.length === 0;
}

// ---------------------------------------------------------------------------------------------------
// Contact sheet, built from the encoded outputs rather than the sources
// ---------------------------------------------------------------------------------------------------
async function thumbnail(path, build, box) {
  const file = join(OVERLAY, path);
  const png = tmp("thumb.png");
  if (path.endsWith(".svg")) await run("rsvg-convert", ["-a", "-w", String(box), "-h", String(box), "-o", png, file]);
  else if (path.endsWith(".webp")) {
    const [w, h] = imageSize(file);
    const k = box / Math.max(w, h);
    await run("dwebp", ["-quiet", "-scale", String(Math.max(1, Math.round(w * k))), String(Math.max(1, Math.round(h * k))), file, "-o", png]);
  } else if (path.endsWith(".gif")) {
    await run("ffmpeg", ["-y", "-loglevel", "error", "-i", file, "-vf", `select=eq(n\\,9),scale=${box}:-1:flags=neighbor`, "-frames:v", "1", png]);
  } else if (path.endsWith(".ico")) {
    const b = readFileSync(file);
    const i = b.readUInt16LE(4) - 1;
    writeFileSync(png, b.subarray(b.readUInt32LE(6 + 16 * i + 12), b.readUInt32LE(6 + 16 * i + 12) + b.readUInt32LE(6 + 16 * i + 8)));
  } else {
    await run("ffmpeg", ["-y", "-loglevel", "error", "-i", file, "-vf", `scale=w=${box}:h=${box}:force_original_aspect_ratio=decrease:flags=${(imageSize(file)?.[0] ?? box) < box ? "neighbor" : "area"}`, png]);
  }
  return readFileSync(png).toString("base64");
}

async function contactSheet() {
  const CELL_W = 196;
  const CELL_H = 170;
  const BOX = 164;
  const COLS = 13;
  const seen = new Set();
  const list = jobs.filter((j) => {
    const b = readFileSync(join(OVERLAY, j.path)).toString("base64");
    if (seen.has(b)) return false;
    seen.add(b);
    return true;
  });
  const dupes = jobs.length - list.length;
  const cells = [];
  await pool(list.map((j, i) => [j, i]), 6, async ([j, i]) => {
    const dark = /-dark\.|white-|plane-lockup-light|onboarding|instance-(not-ready|setup)|og-image/.test(j.path);
    const light = /-light\.|black-|background-pattern\.|instance-failure\.|favicon|icon/.test(j.path);
    const both = !dark && !light && /\.svg$|\.png$/.test(j.path);
    cells[i] = { j, dark, both, data: await thumbnail(j.path, j.build, BOX) };
  });
  const rows = Math.ceil(cells.length / COLS);
  const W = COLS * CELL_W;
  const H = rows * CELL_H + 34;
  let s = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><rect width="${W}" height="${H}" fill="#6B7280"/>`;
  s += `<text x="10" y="23" font-family="Menlo, monospace" font-size="15" fill="#fff">Wayline images: ${jobs.length} files, ${list.length} distinct, ${dupes} byte-identical copies not repeated. Decoded from the overlay outputs.</text>`;
  cells.forEach(({ j, dark, both, data }, i) => {
    const x = (i % COLS) * CELL_W + 3;
    const y = Math.floor(i / COLS) * CELL_H + 34;
    const w = CELL_W - 6;
    const h = CELL_H - 6;
    const bg = dark ? PALETTES.dark.paper : PALETTES.light.paper;
    s += `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${bg}"/>`;
    if (both) s += `<path d="M${x + w} ${y}V${y + h}H${x}Z" fill="${PALETTES.dark.paper}"/>`;
    s += `<image x="${x + (w - BOX) / 2}" y="${y}" width="${BOX}" height="${BOX - 8}" preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,${data}"/>`;
    const label = j.path.replace(/^apps\/|app\/assets\/|empty-state\//g, "").slice(-30);
    s += `<rect x="${x}" y="${y + h - 13}" width="${w}" height="13" fill="#000" fill-opacity="0.65"/><text x="${x + 3}" y="${y + h - 3}" font-family="Menlo, monospace" font-size="9.5" fill="#fff">${label}</text>`;
  });
  s += "</svg>\n";
  const src = tmp("sheet.svg");
  writeFileSync(src, s);
  mkdirSync(dirname(SHEET), { recursive: true });
  await run("rsvg-convert", ["-o", SHEET, src]);
  console.log(`sheet: ${SHEET}`);
}

// ---------------------------------------------------------------------------------------------------
try {
  if (!verifyOnly) {
    const todo = only ? jobs.filter((j) => j.path.includes(only)) : jobs;
    await pool(todo, 6, buildJob);
    for (const [rel, body] of Object.entries(MANIFESTS)) writeFileSync(outPath(rel), `${JSON.stringify(body, null, 2)}\n`);
    console.log(`built ${todo.length} images`);
  }
  const ok = verify() && (!against || verifyAgainst(against));
  if (!verifyOnly && !only) await contactSheet();
  if (!ok) process.exitCode = 1;
} finally {
  rmSync(TMP, { recursive: true, force: true });
}
