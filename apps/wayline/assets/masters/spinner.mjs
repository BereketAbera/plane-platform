#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Spinner source: a pulse travelling the route from the ring to the diamond. rsvg-convert does not
// run SMIL, so this writes numbered SVG frames for the assets step to rasterise and join.
//
//   node spinner.mjs <out-dir> [--dark] [--frames 24] [--bg '#F4F2EA']
//   for f in out/*.svg; do rsvg-convert -w 64 -h 64 "$f" -o "${f%.svg}.png"; done
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const out = args[0];
if (!out) {
  console.error("usage: spinner.mjs <out-dir> [--dark] [--frames N] [--bg color]");
  process.exit(2);
}
const flag = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const dark = args.includes("--dark");
const frames = Number(flag("--frames", 24));
const bg = flag("--bg", null);
const ink = dark ? "#E7E9EE" : "#0F1B2D";
const route = dark ? "#E65AA6" : "#B0186E";
const ROUTE = "M11 25.5H15.5L22.2 12.4";
const LENGTH = 19.21; // 4.5 + hypot(6.7, 13.1)
const PULSE = 7;

mkdirSync(out, { recursive: true });
for (let i = 0; i < frames; i++) {
  const t = i / frames;
  // The pulse enters at the ring and leaves through the diamond, so one cycle is length + pulse.
  const offset = PULSE - t * (LENGTH + PULSE);
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">` +
    (bg ? `<rect width="32" height="32" fill="${bg}"/>` : "") +
    `<path d="${ROUTE}" fill="none" stroke="${route}" stroke-opacity="0.28" stroke-width="3"/>` +
    `<path d="${ROUTE}" fill="none" stroke="${route}" stroke-width="3" stroke-dasharray="${PULSE} ${LENGTH + PULSE}" stroke-dashoffset="${offset.toFixed(3)}"/>` +
    `<circle cx="6.5" cy="25.5" r="3.75" fill="none" stroke="${ink}" stroke-width="3"/>` +
    `<path d="M24.5 2L31 8.5L24.5 15L18 8.5Z" fill="${ink}"/></svg>\n`;
  writeFileSync(join(out, `frame-${String(i).padStart(3, "0")}.svg`), svg);
}
console.log(`${frames} frames in ${out}`);
