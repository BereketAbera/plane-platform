#!/usr/bin/env node
// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Draws the sign-in chart: a fictional sheet of terrain with a magenta course line over it, built the
// way a VFR sectional is. The output is static path data, so nothing here runs in the browser.
//
//   node apps/wayline/assets/generate-contours.mjs                 # writes the overlay component
//   node apps/wayline/assets/generate-contours.mjs --preview <dir> # also writes chart-{light,dark}.svg
//   rsvg-convert -w 1400 <dir>/chart-light.svg -o <dir>/chart-light.png
//
// The terrain is eroded, not just noise: a small stream-power landscape model cuts drainage into it, so
// contours crenulate up the valleys and the rivers really run downhill to the lake. The seed is fixed, so
// the same script always writes the same file.
//
// Colours are not decided here. Every mark gets a wl-c-* class, styled in
// overlay/packages/tailwind-config/brand/auth.css. --preview reads the rules between the chart:start and
// chart:end markers there and resolves their tokens per theme, so the picture you check uses the rules
// that ship.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// One sheet for every sign-in. Each app gets its own copy, because the apps cannot import from one another.
const OUTS = [
  "../overlay/apps/web/core/components/auth-screens/wayline-chart.tsx",
  "../overlay/apps/admin/app/(all)/(home)/wayline-chart.tsx",
  "../overlay/apps/space/components/views/wayline-chart.tsx",
].map((p) => join(here, p));
const AUTH_CSS = join(here, "../overlay/packages/tailwind-config/brand/auth.css");

// ---------- Sheet geometry ----------
// Square. The panel crops it with "slice", so everything that matters stays inside the middle.
const SIZE = 1000;
const CELL = 6;
const MARGIN = 26; // Grid cells simulated beyond the sheet, so the model's base-level edge never shows.
const SEED = 20261104;
// The sheet is 60 NM tall (one degree of latitude). Longitude is scaled by cos(latitude).
const NM = SIZE / 60;
const LAT_TOP = 47 + 50 / 60;
const LON_LEFT = 11 + 2 / 60;
const LON_SCALE = Math.cos((47.33 * Math.PI) / 180);
const yAtLat = (lat) => (LAT_TOP - lat) * SIZE;
const xAtLon = (lon) => (lon - LON_LEFT) * SIZE * LON_SCALE;
const r1 = (n) => Math.round(n * 10) / 10;
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

// ---------- Noise ----------
function mulberry32(seed) {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(SEED);
const PERM = Array.from({ length: 256 }, (_, i) => i);
for (let i = 255; i > 0; i--) {
  const j = Math.floor(rand() * (i + 1));
  [PERM[i], PERM[j]] = [PERM[j], PERM[i]];
}
const GRAD = Array.from({ length: 256 }, () => {
  const a = rand() * Math.PI * 2;
  return [Math.cos(a), Math.sin(a)];
});
const fade = (t) => t * t * t * (t * (t * 6 - 15) + 10);
function perlin(x, y) {
  const xi = Math.floor(x);
  const yi = Math.floor(y);
  const dot = (ix, iy) => {
    const g = GRAD[PERM[(PERM[(xi + ix) & 255] + yi + iy) & 255]];
    return g[0] * (x - xi - ix) + g[1] * (y - yi - iy);
  };
  const u = fade(x - xi);
  const a = dot(0, 0) + u * (dot(1, 0) - dot(0, 0));
  const b = dot(0, 1) + u * (dot(1, 1) - dot(0, 1));
  return (a + fade(y - yi) * (b - a)) * 1.5;
}
function fbm(x, y, octaves) {
  let [sum, amp, freq, norm] = [0, 1, 1, 0];
  for (let i = 0; i < octaves; i++) {
    sum += amp * perlin(x * freq + i * 19.7, y * freq - i * 7.3);
    norm += amp;
    amp *= 0.5;
    freq *= 2.03;
  }
  return sum / norm;
}

// ---------- Terrain ----------
const gauss = (x, y, cx, cy, sx, sy) => Math.exp(-(((x - cx) / sx) ** 2 + ((y - cy) / sy) ** 2));
const LAKE = [742, 792];
const inBasin = (x, y) => gauss(x, y, LAKE[0], LAKE[1], 150, 104) > 0.62;
// Rock uplift: a range running NW-SE across the upper sheet, a lower spur south-west, a trough for the lake.
function uplift(x, y) {
  const c = Math.cos(0.62);
  const s = Math.sin(0.62);
  const wx = x + 90 * fbm(x / 520 + 3.1, y / 520, 2);
  const wy = y + 90 * fbm(x / 520 - 5.7, y / 520 + 9.2, 2);
  const along = (wx - 330) * c + (wy - 300) * s;
  const across = -(wx - 330) * s + (wy - 300) * c;
  const range = Math.exp(-((across / 165) ** 2) - (along / 620) ** 2);
  const spur = gauss(wx, wy, 90, 700, 260, 190);
  const east = gauss(wx, wy, 930, 330, 240, 300);
  const trough = gauss(x, y, LAKE[0], LAKE[1], 250, 170);
  return Math.max(0.03, 0.26 + 1.0 * range + 0.42 * spur + 0.34 * east - 0.42 * trough);
}

const COLS = Math.ceil(SIZE / CELL) + 3;
const BIG = COLS + MARGIN * 2;
const bigX = (i) => (i - MARGIN - 1) * CELL;
const idx = (i, j) => j * BIG + i;
const NB = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]];

const channelRand = mulberry32(SEED + 1);
// Priority flood: drains every cell to the edge or the lake, in ascending order. The neighbour that first
// reaches a cell is its lowest one, so that neighbour is where the cell flows.
function floodRouting(surface, outlet, jitter) {
  const n = BIG * BIG;
  // A little per-step roughness stops flow locking onto the grid's 8 directions.
  const h = surface.map((v) => v + (jitter ? jitter * channelRand() : 0));
  const receiver = new Int32Array(n).fill(-1);
  const seen = new Uint8Array(n);
  const order = new Int32Array(n);
  const heapCell = new Int32Array(n + 1);
  const heapKey = new Float64Array(n + 1);
  let size = 0;
  const push = (c, key) => {
    let at = size++;
    while (at > 0) {
      const up = (at - 1) >> 1;
      if (heapKey[up] <= key) break;
      heapKey[at] = heapKey[up];
      heapCell[at] = heapCell[up];
      at = up;
    }
    heapKey[at] = key;
    heapCell[at] = c;
  };
  const pop = () => {
    const top = heapCell[0];
    const key = heapKey[--size];
    const cell = heapCell[size];
    let at = 0;
    for (;;) {
      let child = at * 2 + 1;
      if (child >= size) break;
      if (child + 1 < size && heapKey[child + 1] < heapKey[child]) child++;
      if (heapKey[child] >= key) break;
      heapKey[at] = heapKey[child];
      heapCell[at] = heapCell[child];
      at = child;
    }
    heapKey[at] = key;
    heapCell[at] = cell;
    return top;
  };
  const filled = new Float64Array(n);
  for (let j = 0; j < BIG; j++) {
    for (let i = 0; i < BIG; i++) {
      const c = idx(i, j);
      if (i === 0 || j === 0 || i === BIG - 1 || j === BIG - 1 || outlet[c]) {
        seen[c] = 1;
        filled[c] = h[c];
        push(c, h[c]);
      }
    }
  }
  let count = 0;
  while (size > 0) {
    const c = pop();
    order[count++] = c;
    const j = Math.floor(c / BIG);
    const i = c - j * BIG;
    for (const [di, dj] of NB) {
      const ni = i + di;
      const nj = j + dj;
      if (ni < 0 || nj < 0 || ni >= BIG || nj >= BIG) continue;
      const nc = idx(ni, nj);
      if (seen[nc]) continue;
      seen[nc] = 1;
      receiver[nc] = c;
      filled[nc] = Math.max(h[nc], filled[c] + 1e-7);
      push(nc, filled[nc]);
    }
  }
  return { order, receiver };
}
function blur(a, passes) {
  let cur = a;
  for (let p = 0; p < passes; p++) {
    const out = cur.slice();
    for (let j = 1; j < BIG - 1; j++) {
      for (let i = 1; i < BIG - 1; i++) {
        const c = idx(i, j);
        out[c] = 0.5 * cur[c] + 0.125 * (cur[c - 1] + cur[c + 1] + cur[c - BIG] + cur[c + BIG]);
      }
    }
    cur = out;
  }
  return cur;
}
// FastScape-style stream power (implicit, n = 1), with hillslope diffusion and uplift.
function evolve() {
  const n = BIG * BIG;
  const h = new Float64Array(n);
  const rock = new Float64Array(n);
  const outlet = new Uint8Array(n);
  for (let j = 0; j < BIG; j++) {
    for (let i = 0; i < BIG; i++) {
      const [x, y] = [bigX(i), bigX(j)];
      const c = idx(i, j);
      rock[c] = uplift(x, y);
      outlet[c] = inBasin(x, y) ? 1 : 0;
      h[c] = rock[c] * (0.5 + 0.22 * fbm(x / 300, y / 300, 5)) + 0.05 * fbm(x / 70, y / 70, 3);
      if (outlet[c]) h[c] = 0;
    }
  }
  const STEPS = 150;
  const K = 0.05;
  const M = 0.5;
  const U = 0.02;
  const D = 0.05;
  let routing;
  let area = new Float64Array(n);
  for (let step = 0; step < STEPS; step++) {
    routing = floodRouting(h, outlet, 0.012);
    area.fill(1);
    for (let k = n - 1; k >= 0; k--) {
      const c = routing.order[k];
      const r = routing.receiver[c];
      if (r >= 0) area[r] += area[c];
    }
    for (let k = 0; k < n; k++) {
      const c = routing.order[k];
      const r = routing.receiver[c];
      if (r < 0 || outlet[c]) continue;
      h[c] += U * rock[c];
      if (h[c] > h[r]) {
        const diag = Math.abs(c - r) === 1 || Math.abs(c - r) === BIG ? 1 : 1.41;
        const f = (K * area[c] ** M) / diag;
        h[c] = (h[c] + f * h[r]) / (1 + f);
      }
    }
    const next = h.slice();
    for (let j = 1; j < BIG - 1; j++) {
      for (let i = 1; i < BIG - 1; i++) {
        const c = idx(i, j);
        if (!outlet[c]) next[c] = h[c] + D * (h[c - 1] + h[c + 1] + h[c - BIG] + h[c + BIG] - 4 * h[c]);
      }
    }
    h.set(next);
  }
  // Final routing for the rivers. The light blur only takes the 8-direction grain out of the contours.
  routing = floodRouting(h, outlet);
  area.fill(1);
  for (let k = n - 1; k >= 0; k--) {
    const c = routing.order[k];
    const r = routing.receiver[c];
    if (r >= 0) area[r] += area[c];
  }
  return { h: blur(h, 3), area, receiver: routing.receiver };
}
const land = evolve();

const field = new Float64Array(COLS * COLS);
const gx = (i) => (i - 1) * CELL;
let lo = Infinity;
let hi = -Infinity;
for (let j = 0; j < COLS; j++) {
  for (let i = 0; i < COLS; i++) {
    const v = land.h[idx(i + MARGIN, j + MARGIN)];
    field[j * COLS + i] = v;
    lo = Math.min(lo, v);
    hi = Math.max(hi, v);
  }
}
const FT_LOW = 1800;
const FT_HIGH = 9400;
const feet = (v) => FT_LOW + ((v - lo) / (hi - lo)) * (FT_HIGH - FT_LOW);
const valueAtFeet = (ft) => lo + ((ft - FT_LOW) / (FT_HIGH - FT_LOW)) * (hi - lo);
function sample(x, y) {
  const fx = Math.min(COLS - 1.001, Math.max(0, x / CELL + 1));
  const fy = Math.min(COLS - 1.001, Math.max(0, y / CELL + 1));
  const i = Math.floor(fx);
  const j = Math.floor(fy);
  const [a, b, c, d] = [field[j * COLS + i], field[j * COLS + i + 1], field[(j + 1) * COLS + i], field[(j + 1) * COLS + i + 1]];
  const [u, v] = [fx - i, fy - j];
  return a + u * (b - a) + v * (c - a) + u * v * (a - b - c + d);
}

// ---------- Marching squares. With ring, the sheet's outside counts as below level so tint bands can close ----------
function contour(level, ring = false) {
  const pad = ring ? 1 : 0;
  const v = (i, j) => (i < 0 || j < 0 || i >= COLS || j >= COLS ? -Infinity : field[j * COLS + i]);
  const W = COLS + 3;
  const edge = (i, j, dir) => ((j + 1) * W + i + 1) * 2 + dir; // dir 0: edge to the right, 1: edge downward
  const pointOn = (id) => {
    const dir = id & 1;
    const m = id >> 1;
    const j = Math.floor(m / W) - 1;
    const i = m - (j + 1) * W - 1;
    const a = v(i, j);
    const b = dir ? v(i, j + 1) : v(i + 1, j);
    let t = 0.5;
    if (a === -Infinity) t = 1;
    else if (b === -Infinity) t = 0;
    else if (a !== b) t = Math.min(1, Math.max(0, (level - a) / (b - a)));
    return dir ? [gx(i), gx(j + t)] : [gx(i + t), gx(j)];
  };
  const next = new Map();
  const heads = new Set();
  const add = (p, q) => {
    next.set(p, q);
    heads.add(p);
  };
  // Oriented so that "above level" is always on the same side, which lets segments chain up.
  const CASES = {
    1: [["L", "B"]], 2: [["B", "R"]], 3: [["L", "R"]], 4: [["R", "T"]], 5: [["L", "T"], ["R", "B"]],
    6: [["B", "T"]], 7: [["L", "T"]], 8: [["T", "L"]], 9: [["T", "B"]], 10: [["T", "R"], ["B", "L"]],
    11: [["T", "R"]], 12: [["R", "L"]], 13: [["R", "B"]], 14: [["B", "L"]],
  };
  for (let j = -pad; j < COLS - 1 + pad; j++) {
    for (let i = -pad; i < COLS - 1 + pad; i++) {
      const code =
        (v(i, j) >= level ? 8 : 0) | (v(i + 1, j) >= level ? 4 : 0) | (v(i + 1, j + 1) >= level ? 2 : 0) | (v(i, j + 1) >= level ? 1 : 0);
      const e = { T: edge(i, j, 0), R: edge(i + 1, j, 1), B: edge(i, j + 1, 0), L: edge(i, j, 1) };
      for (const [p, q] of CASES[code] ?? []) add(e[p], e[q]);
    }
  }
  // Open lines must start at a real end, so begin from edges nothing flows into.
  const targets = new Set(next.values());
  const starts = [...heads].filter((h) => !targets.has(h)).concat([...heads]);
  const loops = [];
  const seen = new Set();
  for (const start of starts) {
    if (seen.has(start)) continue;
    const ids = [];
    let cur = start;
    while (cur !== undefined && !seen.has(cur)) {
      seen.add(cur);
      ids.push(cur);
      cur = next.get(cur);
    }
    const closed = cur === start;
    if (cur !== undefined && !closed) ids.push(cur);
    loops.push({ pts: ids.map(pointOn), closed });
  }
  return loops;
}

// ---------- Path output ----------
function perimeter(pts, closed) {
  let s = 0;
  for (let i = 1; i < pts.length; i++) s += dist(pts[i - 1], pts[i]);
  return closed ? s + dist(pts[pts.length - 1], pts[0]) : s;
}
function simplify(pts, tol) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length);
  keep[0] = 1;
  keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [dx, dy] = [pts[b][0] - pts[a][0], pts[b][1] - pts[a][1]];
    const len = Math.hypot(dx, dy) || 1;
    let [worst, at] = [0, -1];
    for (let i = a + 1; i < b; i++) {
      const d = Math.abs((pts[i][0] - pts[a][0]) * dy - (pts[i][1] - pts[a][1]) * dx) / len;
      if (d > worst) [worst, at] = [d, i];
    }
    if (worst > tol) {
      keep[at] = 1;
      stack.push([a, at], [at, b]);
    }
  }
  return pts.filter((_, i) => keep[i]);
}
const num = (n) => String(r1(n)).replace(/^(-?)0\./, "$1.");
const numbers = (list) => list.map(num).join(" ").replace(/ -/g, "-");
// A pen line through segment midpoints. Each midpoint is exactly halfway between two control points, so SVG's
// smooth-quadratic "t" can carry the whole line at one coordinate pair per point. The endpoint rounding is
// fed back so the reflected control point cannot drift.
function penPath(pts, closed) {
  const n = pts.length;
  if (n < 3) return `M${numbers(pts[0])}L${numbers(pts[n - 1])}`;
  const mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
  const controls = closed ? pts : pts.slice(1, -1);
  const start = closed ? mid(pts[n - 1], pts[0]) : pts[0];
  const round = (p) => [r1(p[0]), r1(p[1])];
  let pen = round(start);
  let ctrl = round(controls[0]);
  const m = controls.length;
  const firstEnd = round(m > 1 ? mid(ctrl, controls[1]) : closed ? start : pts[n - 1]);
  let out = `M${numbers(pen)}q${numbers([ctrl[0] - pen[0], ctrl[1] - pen[1], firstEnd[0] - pen[0], firstEnd[1] - pen[1]])}`;
  pen = firstEnd;
  ctrl = [2 * pen[0] - ctrl[0], 2 * pen[1] - ctrl[1]];
  const ends = [];
  for (let i = 1; i < m; i++) {
    const after = controls[i + 1];
    const target = after ? mid(ctrl, after) : closed ? start : pts[n - 1];
    const end = round(target);
    ends.push(end[0] - pen[0], end[1] - pen[1]);
    pen = end;
    ctrl = [2 * pen[0] - ctrl[0], 2 * pen[1] - ctrl[1]];
  }
  if (ends.length) out += `t${numbers(ends)}`;
  return out + (closed ? "z" : "");
}

// ---------- Contours and hypsometric tints ----------
const INTERVAL = 200; // feet
const INDEX_EVERY = 5; // a heavier line every 1000 ft
const TINT_LEVELS = [3000, 4000, 5000, 6000, 7000, 8000];
const encloses = (pts, x, y) => {
  let inside = false;
  for (let i = 0, k = pts.length - 1; i < pts.length; k = i++) {
    if (pts[i][1] > y !== pts[k][1] > y && x < ((pts[k][0] - pts[i][0]) * (y - pts[i][1])) / (pts[k][1] - pts[i][1]) + pts[i][0]) inside = !inside;
  }
  return inside;
};
// The lake is as full as the basin allows: the highest closed shoreline of a sensible size around its centre.
function fillLake() {
  let best = null;
  for (let ft = FT_LOW + 10; ft < FT_LOW + 1600; ft += 10) {
    const shore = contour(valueAtFeet(ft)).find(({ pts, closed }) => closed && encloses(pts, LAKE[0], LAKE[1]));
    if (!shore || perimeter(shore.pts, true) > 900) break;
    best = { ft, pts: shore.pts };
  }
  if (!best) throw new Error("no closed shoreline around the lake centre");
  return best;
}
const lake = fillLake();
const WATER_FT = lake.ft;
const minor = [];
const index = [];
const indexLines = [];
for (let ft = (Math.floor(WATER_FT / INTERVAL) + 1) * INTERVAL; ft < FT_HIGH; ft += INTERVAL) {
  const isIndex = ft % (INTERVAL * INDEX_EVERY) === 0;
  for (const { pts, closed } of contour(valueAtFeet(ft))) {
    if (perimeter(pts, closed) < 60) continue;
    const line = simplify(pts, 1.6);
    if (line.length < 3) continue;
    (isIndex ? index : minor).push(penPath(line, closed));
    if (isIndex) indexLines.push({ ft, pts: line });
  }
}
const tints = TINT_LEVELS.map((ft) =>
  contour(valueAtFeet(ft), true)
    .filter(({ pts }) => perimeter(pts, true) > 110)
    .map(({ pts }) => penPath(simplify(pts, 3), true))
    .join("")
);

// ---------- Water ----------
const isWet = (x, y) => sample(x, y) < valueAtFeet(WATER_FT);
const lakes = [simplify(lake.pts, 0.8)];
function drainage(threshold) {
  // Channels are cells above an upstream-area threshold. Each is walked from its head to a confluence or the lake.
  const channel = (c) => land.area[c] >= threshold;
  const fed = new Set();
  const inSheet = (c) => {
    const j = Math.floor(c / BIG);
    const i = c - j * BIG;
    return i >= MARGIN && j >= MARGIN && i < MARGIN + COLS && j < MARGIN + COLS;
  };
  for (let c = 0; c < BIG * BIG; c++) {
    if (channel(c) && land.receiver[c] >= 0) fed.add(land.receiver[c]);
  }
  const done = new Set();
  const lines = [];
  for (let c = 0; c < BIG * BIG; c++) {
    if (!channel(c) || fed.has(c) || !inSheet(c)) continue;
    const pts = [];
    let cur = c;
    while (cur >= 0 && inSheet(cur)) {
      const j = Math.floor(cur / BIG);
      const p = [bigX(cur - j * BIG), bigX(j)];
      pts.push(p);
      if (done.has(cur) || isWet(p[0], p[1])) break;
      done.add(cur);
      cur = land.receiver[cur];
    }
    if (perimeter(pts, false) > 46) lines.push(pts);
  }
  // Grid steps read as stairs, so ease them before the pen pass.
  return lines.map((pts) => {
    let out = pts;
    for (let p = 0; p < 3; p++) {
      out = out.map((q, i) =>
        i === 0 || i === out.length - 1
          ? q
          : [(out[i - 1][0] + 2 * q[0] + out[i + 1][0]) / 4, (out[i - 1][1] + 2 * q[1] + out[i + 1][1]) / 4]
      );
    }
    return simplify(out, 0.9);
  });
}
const rivers = drainage(240);

// ---------- Route ----------
const WAYPOINTS = [
  { id: "ORIGN", x: 196, y: 792, kind: "start", dx: 17, dy: 11, anchor: "start" },
  { id: "KNOLL", x: 352, y: 590, kind: "fix", dx: -15, dy: -12, anchor: "end" },
  { id: "SADLE", x: 610, y: 514, kind: "vor", dx: 16, dy: 19, anchor: "start" },
  { id: "HAVEN", x: 822, y: 214, kind: "end", dx: 18, dy: 4, anchor: "start" },
];
const VARIATION = 3; // Degrees east. The isogonic line and the rose carry the same value.
const CLEAR = { start: 12, fix: 12, vor: 13, end: 13 };
const legs = WAYPOINTS.slice(1).map((b, i) => {
  const a = WAYPOINTS[i];
  const [dx, dy] = [b.x - a.x, b.y - a.y];
  const len = Math.hypot(dx, dy);
  return { a, b, dx, dy, len, ux: dx / len, uy: dy / len, nm: len / NM, mag: ((Math.atan2(dx, -dy) * 180) / Math.PI - VARIATION + 360) % 360 };
});
const nearRoute = (x, y) =>
  Math.min(
    ...legs.map(({ a, dx, dy, len }) => {
      const t = Math.max(0, Math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / (len * len)));
      return dist([x, y], [a.x + dx * t, a.y + dy * t]);
    })
  );
const vor = WAYPOINTS.find((w) => w.kind === "vor");
const ROSE_R = 92;
const AIRSPACE = { x: 822, y: 214, r: 84 };

// ---------- Figures: summits and contour heights ----------
function summits() {
  const found = [];
  for (let j = 8; j < COLS - 8; j++) {
    for (let i = 8; i < COLS - 8; i++) {
      const v = field[j * COLS + i];
      let top = true;
      for (let dj = -5; dj <= 5 && top; dj++) {
        for (let di = -5; di <= 5 && top; di++) {
          if (field[(j + dj) * COLS + i + di] > v) top = false;
        }
      }
      if (top) found.push({ x: gx(i), y: gx(j), v });
    }
  }
  found.sort((a, b) => b.v - a.v);
  const chosen = [];
  for (const p of found) {
    const open =
      WAYPOINTS.every((w) => dist([p.x, p.y], [w.x, w.y]) > 70) &&
      nearRoute(p.x, p.y) > 44 &&
      dist([p.x, p.y], [vor.x, vor.y]) > ROSE_R + 30 &&
      p.x > 50 && p.x < SIZE - 90 && p.y > 50 && p.y < SIZE - 50 && feet(p.v) > 3200;
    if (open && chosen.every((c) => dist([c.x, c.y], [p.x, p.y]) > 135)) chosen.push(p);
    if (chosen.length === 8) break;
  }
  return chosen.map((p, i) => ({ x: p.x, y: p.y, ft: Math.round(feet(p.v)), top: i === 0 }));
}
const spots = summits();
function contourFigures() {
  // Long index lines only, on a straight run, the way a cartographer breaks a line for its height.
  const placed = [];
  const open = (x, y) =>
    placed.every((p) => dist([p.x, p.y], [x, y]) > 92) &&
    spots.every((s) => dist([s.x, s.y], [x, y]) > 40) &&
    WAYPOINTS.every((w) => dist([w.x, w.y], [x, y]) > 62) &&
    dist([x, y], [vor.x, vor.y]) > ROSE_R + 22 &&
    nearRoute(x, y) > 28 &&
    !isWet(x, y);
  for (const { ft, pts } of indexLines.slice().sort((a, b) => perimeter(b.pts) - perimeter(a.pts))) {
    let walked = 0;
    for (let i = 1; i < pts.length - 1; i++) {
      walked += dist(pts[i - 1], pts[i]);
      if (walked < 90) continue;
      const [x, y] = pts[i];
      if (x < 70 || x > SIZE - 70 || y < 70 || y > SIZE - 70 || !open(x, y)) continue;
      const [a, b] = [pts[i - 1], pts[i + 1]];
      if (dist(a, b) < 16) continue;
      let turn = Math.abs(Math.atan2(b[1] - y, b[0] - x) - Math.atan2(y - a[1], x - a[0]));
      turn = Math.min(turn, Math.PI * 2 - turn);
      if (turn > 0.3) continue;
      let angle = (Math.atan2(b[1] - a[1], b[0] - a[0]) * 180) / Math.PI;
      if (angle > 90) angle -= 180;
      if (angle < -90) angle += 180;
      placed.push({ x: r1(x), y: r1(y), angle: r1(angle), text: String(ft) });
      walked = -300;
      if (placed.length >= 22) return placed;
    }
  }
  return placed;
}

// ---------- Marks: [tag, React props, text]. One list renders both the component and the preview ----------
const marks = [];
const path = (className, d, extra = {}) => d && marks.push(["path", { className, d, ...extra }]);
const label = (className, x, y, text, extra = {}) => marks.push(["text", { className: `wl-c-text ${className}`.trim(), x, y, ...extra }, String(text)]);
const along = (x, y, angle) => ({ textAnchor: "middle", dominantBaseline: "central", transform: `rotate(${angle} ${x} ${y})` });

marks.push(["rect", { className: "wl-c-paper", width: SIZE, height: SIZE }]);
tints.forEach((d) => path("wl-c-tint", d, { fillRule: "evenodd" }));

// Graticule: 30' lines with a tick every minute, the sectional's signature.
{
  const dms = (mins, hemi) => `${Math.floor(mins / 60)}°${String(mins % 60).padStart(2, "0")}′${hemi}`;
  const tick = (m) => (m % 10 === 0 ? 8 : m % 5 === 0 ? 5.5 : 3);
  let lines = "";
  let ticks = "";
  for (let lat = 47 * 60; lat <= 48 * 60; lat += 30) {
    const y = r1(yAtLat(lat / 60));
    if (y < 20 || y > SIZE - 20) continue;
    lines += `M0 ${y}H${SIZE}`;
    for (let m = 11 * 60; m <= 13 * 60; m++) {
      const x = r1(xAtLon(m / 60));
      if (x >= 0 && x <= SIZE) ticks += `M${x} ${y}v${tick(m)}`;
    }
    label("wl-c-text-faint", 146, y - 5, dms(lat, "N"));
  }
  for (let lon = 11 * 60; lon <= 13 * 60; lon += 30) {
    const x = r1(xAtLon(lon / 60));
    if (x < 20 || x > SIZE - 20) continue;
    lines += `M${x} 0V${SIZE}`;
    for (let m = 47 * 60; m <= 48 * 60; m++) {
      const y = r1(yAtLat(m / 60));
      if (y >= 0 && y <= SIZE) ticks += `M${x} ${y}h${tick(m)}`;
    }
    label("wl-c-text-faint", r1(x + 5), 130, dms(lon, "E"), { transform: `rotate(90 ${r1(x + 5)} 130)` });
  }
  marks.splice(1 + tints.length, marks.length - 1 - tints.length, ["path", { className: "wl-c-grid", d: lines }], ["path", { className: "wl-c-tick", d: ticks }], ...marks.slice(1 + tints.length));
}
path("wl-c-minor", minor.join(""));
path("wl-c-index", index.join(""));
path("wl-c-river", rivers.map((p) => penPath(p, false)).join(""));
path("wl-c-lake", lakes.map((p) => penPath(p, true)).join(""));
// An isogonic line, and a controlled-airspace ring around the destination.
path("wl-c-isogonic", "M92 1000C210 760 300 470 330 0");
label("wl-c-text-iso", 266, 472, `${VARIATION}°E`, along(266, 472, -80));
marks.push(["circle", { className: "wl-c-airspace", cx: AIRSPACE.x, cy: AIRSPACE.y, r: AIRSPACE.r }]);
label("wl-c-text-air", AIRSPACE.x, AIRSPACE.y - AIRSPACE.r - 7, "CTR 4500", { textAnchor: "middle" });
for (const t of contourFigures()) label("wl-c-figure", t.x, t.y, t.text, along(t.x, t.y, t.angle));
for (const s of spots) {
  marks.push(["circle", { className: "wl-c-spot", cx: s.x, cy: s.y, r: s.top ? 2.4 : 1.7 }]);
  label(s.top ? "wl-c-summit" : "", s.x + 6, s.y + 3.5, s.ft);
}
// VOR rose, tilted by the variation like the real thing.
{
  let ticks = `M${vor.x - ROSE_R} ${vor.y}a${ROSE_R} ${ROSE_R} 0 1 0 ${ROSE_R * 2} 0a${ROSE_R} ${ROSE_R} 0 1 0-${ROSE_R * 2} 0`;
  for (let deg = 0; deg < 360; deg += 5) {
    const a = ((deg + VARIATION - 90) * Math.PI) / 180;
    const [cx, cy] = [Math.cos(a), Math.sin(a)];
    const long = deg % 30 === 0 ? 11 : deg % 10 === 0 ? 7 : 3.5;
    ticks += `M${r1(vor.x + cx * ROSE_R)} ${r1(vor.y + cy * ROSE_R)}L${r1(vor.x + cx * (ROSE_R - long))} ${r1(vor.y + cy * (ROSE_R - long))}`;
  }
  path("wl-c-rose", ticks);
  for (let deg = 0; deg < 360; deg += 30) {
    const a = ((deg + VARIATION - 90) * Math.PI) / 180;
    const [x, y] = [r1(vor.x + Math.cos(a) * (ROSE_R + 9)), r1(vor.y + Math.sin(a) * (ROSE_R + 9))];
    if (nearRoute(x, y) < 9) continue;
    label("wl-c-text-rose", x, y, deg === 0 ? "N" : String(deg / 10).padStart(2, "0"), along(x, y, deg + VARIATION));
  }
}
// The course line, trimmed at each symbol, with a tick every 5 NM and its leg data alongside.
path("wl-c-halo", `M${WAYPOINTS.map((w) => `${w.x} ${w.y}`).join("L")}`);
path(
  "wl-c-route",
  legs.map((l) => `M${r1(l.a.x + l.ux * CLEAR[l.a.kind])} ${r1(l.a.y + l.uy * CLEAR[l.a.kind])}L${r1(l.b.x - l.ux * CLEAR[l.b.kind])} ${r1(l.b.y - l.uy * CLEAR[l.b.kind])}`).join("")
);
path(
  "wl-c-route-tick",
  legs
    .map((l) => {
      let d = "";
      for (let nm = 5; nm < l.nm - 1; nm += 5) {
        const [px, py] = [l.a.x + l.ux * nm * NM, l.a.y + l.uy * nm * NM];
        d += `M${r1(px - l.uy * 5)} ${r1(py + l.ux * 5)}L${r1(px + l.uy * 5)} ${r1(py - l.ux * 5)}`;
      }
      return d;
    })
    .join("")
);
const diamond = (x, y, r) => `M${x} ${y - r}L${x + r} ${y}L${x} ${y + r}L${x - r} ${y}Z`;
for (const w of WAYPOINTS) {
  if (w.kind === "start") marks.push(["circle", { className: "wl-c-ring", cx: w.x, cy: w.y, r: 8 }]);
  if (w.kind === "fix" || w.kind === "vor") path("wl-c-wpt", diamond(w.x, w.y, 9.5));
  if (w.kind === "end") path("wl-c-wpt-end", diamond(w.x, w.y, 12));
}
legs.forEach((l, i) => {
  const t = [0.5, 0.36, 0.56][i];
  const side = [-1, -1, -1][i];
  let angle = (Math.atan2(l.dy, l.dx) * 180) / Math.PI;
  if (angle > 90 || angle < -90) angle += 180;
  const [x, y] = [r1(l.a.x + l.dx * t + l.uy * side * 13), r1(l.a.y + l.dy * t - l.ux * side * 13)];
  label("wl-c-text-route", x, y, `${String(Math.round(l.mag)).padStart(3, "0")}°  ${l.nm.toFixed(1)} NM`, along(x, y, r1(angle)));
});
for (const w of WAYPOINTS) label("wl-c-text-wpt", w.x + w.dx, w.y + w.dy, w.id, { textAnchor: w.anchor });
// Scale bar.
{
  const [x, y] = [650, 926];
  const at = (nm) => r1(x + nm * NM);
  path("wl-c-scale", `M${x} ${y}H${at(10)}${[0, 5, 10].map((n) => `M${at(n)} ${y - 5}v10`).join("")}${[1, 2, 3, 4].map((n) => `M${at(n)} ${y - 3}v3`).join("")}`);
  [[0, "0"], [5, "5"], [10, "10 NM"]].forEach(([n, t]) => label("wl-c-text-faint", at(n), y - 10, t, { textAnchor: "middle" }));
}

// ---------- Caption, from the same numbers the chart is drawn with ----------
function coord({ x, y }) {
  const dm = (v, width) => {
    const deg = Math.floor(v);
    return `${String(deg).padStart(width, "0")}°${((v - deg) * 60).toFixed(1).padStart(4, "0")}′`;
  };
  return `N${dm(LAT_TOP - y / SIZE, 2)} E${dm(LON_LEFT + x / SIZE / LON_SCALE, 3)}`;
}
const CAPTION = {
  from: coord(WAYPOINTS[0]),
  to: coord(WAYPOINTS[WAYPOINTS.length - 1]),
  route: WAYPOINTS.map((w) => w.id).join(" – "),
  distance: `${legs.reduce((s, l) => s + l.nm, 0).toFixed(1)} NM`,
};

// ---------- Output ----------
function component() {
  const list = marks.map((m) => JSON.stringify(m)).join(",\n  ");
  return `/**
 * Copyright (c) 2026 Bereket Abera
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 *
 * GENERATED by apps/wayline/assets/generate-contours.mjs. Regenerate rather than edit. A fictional sheet of
 * terrain with a course line; the caption comes from the numbers it is drawn with. Styled by the wl-c-*
 * rules in packages/tailwind-config/brand/auth.css.
 */

import { createElement } from "react";

type TChartMark = [string, Record<string, string | number>, string?];

const MARKS: TChartMark[] = [
  ${list},
];

export const WAYLINE_CHART_CAPTION = ${JSON.stringify(CAPTION)};

export function WaylineChart() {
  return (
    <svg
      data-wl-chart=""
      viewBox="0 0 ${SIZE} ${SIZE}"
      preserveAspectRatio="xMidYMid slice"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      focusable="false"
    >
      {MARKS.map(([tag, props, text], i) => createElement(tag, { key: i, ...props }, text))}
    </svg>
  );
}
`;
}

const THEMES = {
  light: {
    "--wl-chart-paper": "#f4f2ea",
    "--wl-chart-tint": "#a39a78",
    "--wl-chart-contour": "#c9c3ae",
    "--wl-chart-index": "#a29c86",
    "--wl-chart-figure": "#5b616c",
    "--wl-chart-grid": "#465162",
    "--wl-chart-label": "#465162",
    "--wl-chart-label-strong": "#0f1b2d",
    "--wl-chart-water": "#cfe0e2",
    "--wl-chart-water-line": "#5f8ea3",
    "--wl-chart-route": "#b0186e",
    "--font-code": "JetBrains Mono, Menlo, monospace",
  },
  dark: {
    "--wl-chart-paper": "#0b1320",
    "--wl-chart-tint": "#7f93b5",
    "--wl-chart-contour": "#26354e",
    "--wl-chart-index": "#4e6080",
    "--wl-chart-figure": "#76849c",
    "--wl-chart-grid": "#a0aabb",
    "--wl-chart-label": "#a0aabb",
    "--wl-chart-label-strong": "#e7e9ee",
    "--wl-chart-water": "#16304a",
    "--wl-chart-water-line": "#4a7ea3",
    "--wl-chart-route": "#e65aa6",
    "--font-code": "JetBrains Mono, Menlo, monospace",
  },
};
function preview(theme) {
  const css = readFileSync(AUTH_CSS, "utf8");
  const found = css.match(/chart:start[\s\S]*?\*\/([\s\S]*?)\/\* chart:end/);
  if (!found) throw new Error("no chart:start/chart:end markers in auth.css");
  const rules = found[1].replace(/var\((--[a-z0-9-]+)\)/g, (_, name) => {
    if (!THEMES[theme][name]) throw new Error(`preview has no value for ${name}`);
    return THEMES[theme][name];
  });
  const attr = (name) => (name === "className" ? "class" : name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`));
  const body = marks
    .map(([tag, props, text]) => {
      const attrs = Object.entries(props).map(([k, v]) => `${attr(k)}="${v}"`).join(" ");
      return text === undefined ? `<${tag} ${attrs}/>` : `<${tag} ${attrs}>${text}</${tag}>`;
    })
    .join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}"><style>${rules}</style>${body}</svg>\n`;
}

const source = component();
for (const out of OUTS) {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, source);
}
const previewAt = process.argv.indexOf("--preview");
if (previewAt >= 0) {
  const dir = process.argv[previewAt + 1];
  mkdirSync(dir, { recursive: true });
  for (const theme of Object.keys(THEMES)) writeFileSync(join(dir, `chart-${theme}.svg`), preview(theme));
}
console.log(
  JSON.stringify({
    bytes: source.length,
    minorPaths: minor.length,
    indexPaths: index.length,
    feetRange: [Math.round(feet(lo)), Math.round(feet(hi))],
    waterFt: WATER_FT,
    rivers: rivers.length,
    summits: spots.map((s) => s.ft),
    caption: CAPTION,
  })
);
