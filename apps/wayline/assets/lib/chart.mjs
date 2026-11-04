// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Chart primitives for the Wayline illustrations: palettes, a seeded random source, contour lines from
// a seeded height field, and the plate furniture (neatline, graticule, north arrow, scale bar).
// Deterministic: the same seed string always draws the same lines.

// Colours come from the binding design language in overlay/packages/tailwind-config/brand/tokens.css.
// `neutral` is for an image upstream ships in one variant, which must read on paper and on ink alike.
export const PALETTES = {
  light: {
    paper: "#F4F2EA", surface: "#FBFAF6", ink: "#0F1B2D", route: "#B0186E", hair: "#CFC9B6",
    contour: "#DDD8C8", contourIndex: "#CFC9B6", muted: "#858273", wash: "#F6E2ED", tint: "#EEEBE0",
  },
  dark: {
    paper: "#0B1320", surface: "#111C2E", ink: "#E7E9EE", route: "#E65AA6", hair: "#3C4D6B",
    contour: "#22324C", contourIndex: "#30405C", muted: "#76849C", wash: "#3A1833", tint: "#172438",
  },
  neutral: {
    paper: "none", surface: "#7C8798", surfaceOpacity: 0.1, ink: "#7C8798", route: "#D0378C", hair: "#8D97A6",
    contour: "#8D97A6", contourIndex: "#8D97A6", contourOpacity: 0.3, muted: "#8D97A6", wash: "#D0378C", washOpacity: 0.14,
    tint: "#7C8798", tintOpacity: 0.16,
  },
};

export const n = (v) => {
  const r = Math.round(v * 100) / 100;
  return Object.is(r, -0) ? 0 : r;
};

// mulberry32 over an FNV-1a hash of the seed string.
export function rng(seed) {
  let h = 2166136261;
  for (const ch of String(seed)) {
    h ^= ch.codePointAt(0);
    h = Math.imul(h, 16777619);
  }
  let a = h >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  next.range = (lo, hi) => lo + next() * (hi - lo);
  return next;
}

function heightField(w, h, seed, hills) {
  const r = rng(`field:${seed}`);
  // Sized from the short side, with the hill count following the aspect, so a wide plate gets many hills
  // rather than one enormous one.
  const size = Math.min(w, h);
  const count = Math.round(hills * Math.max(1, Math.sqrt(w / h) * (w > h ? 1.3 : 1)));
  const peaks = Array.from({ length: count }, () => ({
    x: r.range(-0.1, 1.1) * w,
    y: r.range(-0.15, 1.15) * h,
    s: r.range(0.16, 0.4) * size,
    a: r.range(0.5, 1.2) * (r() < 0.18 ? -0.6 : 1),
  }));
  const px = r.range(0, 6.28);
  const py = r.range(0, 6.28);
  return (x, y) => {
    let v = 0.09 * Math.sin((x / size) * 5.1 + px) + 0.09 * Math.sin((y / size) * 6.3 + py);
    for (const p of peaks) {
      const dx = x - p.x;
      const dy = y - p.y;
      v += p.a * Math.exp(-(dx * dx + dy * dy) / (2 * p.s * p.s));
    }
    return v;
  };
}

// Marching squares, stitched into chains keyed by grid edge, then drawn as quadratic curves through
// segment midpoints so a coarse grid still reads as a hand-drafted line.
function isoChains(f, w, h, cell, level) {
  const nx = Math.ceil(w / cell) + 1;
  const ny = Math.ceil(h / cell) + 1;
  const vals = new Float64Array(nx * ny);
  for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) vals[j * nx + i] = f(i * cell, j * cell);
  const at = (i, j) => vals[j * nx + i];
  const points = new Map();
  const links = new Map();
  const cross = (key, x, y) => {
    if (!points.has(key)) points.set(key, [x, y]);
    return key;
  };
  const connect = (a, b) => {
    if (!links.has(a)) links.set(a, []);
    if (!links.has(b)) links.set(b, []);
    links.get(a).push(b);
    links.get(b).push(a);
  };
  const lerp = (a, b) => (level - a) / (b - a);
  for (let j = 0; j < ny - 1; j++) {
    for (let i = 0; i < nx - 1; i++) {
      const [a, b, c, d] = [at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1)];
      const idx = (a > level ? 8 : 0) | (b > level ? 4 : 0) | (c > level ? 2 : 0) | (d > level ? 1 : 0);
      if (idx === 0 || idx === 15) continue;
      const x = i * cell;
      const y = j * cell;
      const top = () => cross(`h${i},${j}`, x + cell * lerp(a, b), y);
      const right = () => cross(`v${i + 1},${j}`, x + cell, y + cell * lerp(b, c));
      const bottom = () => cross(`h${i},${j + 1}`, x + cell * lerp(d, c), y + cell);
      const left = () => cross(`v${i},${j}`, x, y + cell * lerp(a, d));
      const pairs = {
        1: [[left, bottom]], 2: [[bottom, right]], 3: [[left, right]], 4: [[top, right]],
        5: [[left, top], [bottom, right]], 6: [[top, bottom]], 7: [[left, top]], 8: [[left, top]],
        9: [[top, bottom]], 10: [[top, right], [left, bottom]], 11: [[top, right]], 12: [[left, right]],
        13: [[bottom, right]], 14: [[left, bottom]],
      }[idx];
      for (const [p, q] of pairs) connect(p(), q());
    }
  }
  const seen = new Set();
  const chains = [];
  const walk = (start) => {
    const chain = [start];
    seen.add(start);
    let cur = start;
    for (;;) {
      const nxt = (links.get(cur) ?? []).find((k) => !seen.has(k));
      if (!nxt) break;
      seen.add(nxt);
      chain.push(nxt);
      cur = nxt;
    }
    return chain;
  };
  for (const [k, l] of links) if (l.length === 1 && !seen.has(k)) chains.push(walk(k));
  for (const k of links.keys()) if (!seen.has(k)) chains.push(walk(k));
  return chains.map((c) => c.map((k) => points.get(k)));
}

function chainPath(pts, digits) {
  const f = (v) => (digits === 0 ? Math.round(v) : Math.round(v * 10) / 10);
  if (pts.length < 2) return "";
  const out = [`M${f(pts[0][0])} ${f(pts[0][1])}`];
  for (let i = 1; i < pts.length - 1; i++) {
    const [x, y] = pts[i];
    const mx = (x + pts[i + 1][0]) / 2;
    const my = (y + pts[i + 1][1]) / 2;
    out.push(`Q${f(x)} ${f(y)} ${f(mx)} ${f(my)}`);
  }
  const last = pts[pts.length - 1];
  out.push(`L${f(last[0])} ${f(last[1])}`);
  return out.join("");
}

// Returns <path> elements: `levels` iso-lines, every fifth one heavier, as on a survey chart.
export function contours(w, h, { seed, palette: p, cell, levels = 18, hills = 6, width = 1, minPoints = 8, digits = 1 }) {
  const f = heightField(w, h, seed, hills);
  const size = Math.max(w, h);
  const step = cell ?? size / 72;
  const lo = 0.06;
  const hi = 2;
  const regular = [];
  const index = [];
  for (let l = 0; l < levels; l++) {
    const level = lo + ((hi - lo) * l) / levels;
    for (const chain of isoChains(f, w, h, step, level)) {
      if (chain.length < minPoints) continue;
      (l % 5 === 0 ? index : regular).push(chainPath(chain, digits));
    }
  }
  const op = p.contourOpacity ? ` stroke-opacity="${p.contourOpacity}"` : "";
  return (
    `<path d="${regular.join("")}" fill="none" stroke="${p.contour}" stroke-width="${n(width)}"${op}/>` +
    `<path d="${index.join("")}" fill="none" stroke="${p.contourIndex}" stroke-width="${n(width * 1.7)}"${op}/>`
  );
}

// The chart border: a hairline with graduation ticks on the inside, longer every fifth tick.
export function neatline(w, h, { palette: p, inset, width, spacing }) {
  const parts = [`<rect x="${n(inset)}" y="${n(inset)}" width="${n(w - 2 * inset)}" height="${n(h - 2 * inset)}" rx="${n(width * 2)}" fill="none" stroke="${p.hair}" stroke-width="${n(width)}"/>`];
  const short = spacing * 0.22;
  const long = spacing * 0.48;
  let d = "";
  const nx = Math.floor((w - 2 * inset) / spacing);
  const ny = Math.floor((h - 2 * inset) / spacing);
  const ox = (w - nx * spacing) / 2;
  const oy = (h - ny * spacing) / 2;
  for (let i = 0; i <= nx; i++) {
    const x = n(ox + i * spacing);
    const t = i % 5 === 0 ? long : short;
    d += `M${x} ${n(inset)}v${n(t)}M${x} ${n(h - inset)}v${n(-t)}`;
  }
  for (let j = 0; j <= ny; j++) {
    const y = n(oy + j * spacing);
    const t = j % 5 === 0 ? long : short;
    d += `M${n(inset)} ${y}h${n(t)}M${n(w - inset)} ${y}h${n(-t)}`;
  }
  parts.push(`<path d="${d}" fill="none" stroke="${p.hair}" stroke-width="${n(width)}"/>`);
  return parts.join("");
}

// Small crosses at every fifth graduation, where a chart's graticule lines would meet.
export function graticule(w, h, { palette: p, inset, width, spacing }) {
  const step = spacing * 5;
  const arm = spacing * 0.3;
  const nx = Math.floor((w - 2 * inset) / spacing);
  const ny = Math.floor((h - 2 * inset) / spacing);
  const ox = (w - nx * spacing) / 2;
  const oy = (h - ny * spacing) / 2;
  let d = "";
  for (let x = ox + step; x < w - inset - spacing; x += step) {
    for (let y = oy + step; y < h - inset - spacing; y += step) {
      d += `M${n(x - arm)} ${n(y)}h${n(2 * arm)}M${n(x)} ${n(y - arm)}v${n(2 * arm)}`;
    }
  }
  return `<path d="${d}" fill="none" stroke="${p.hair}" stroke-width="${n(width)}"/>`;
}

export function northArrow(x, y, r, { palette: p, width }) {
  return (
    `<circle cx="${n(x)}" cy="${n(y)}" r="${n(r)}" fill="none" stroke="${p.hair}" stroke-width="${n(width)}"/>` +
    `<path d="M${n(x)} ${n(y - r * 1.5)}L${n(x + r * 0.34)} ${n(y)}H${n(x - r * 0.34)}Z" fill="${p.ink}"/>` +
    `<path d="M${n(x)} ${n(y + r * 1.5)}L${n(x + r * 0.34)} ${n(y)}H${n(x - r * 0.34)}Z" fill="none" stroke="${p.ink}" stroke-width="${n(width)}"/>`
  );
}

// An unnumbered scale bar: alternating filled and open segments.
export function scaleBar(x, y, seg, height, { palette: p, width, count = 4 }) {
  let out = "";
  for (let i = 0; i < count; i++) {
    out += `<rect x="${n(x + i * seg)}" y="${n(y)}" width="${n(seg)}" height="${n(height)}" fill="${i % 2 ? "none" : p.ink}" stroke="${p.ink}" stroke-width="${n(width)}"/>`;
  }
  return out;
}

export const svgDoc = (w, h, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" fill="none">` +
  `<!-- Wayline illustration. Copyright (c) 2026 Bereket Abera. SPDX-License-Identifier: AGPL-3.0-only. Generated by apps/wayline/assets/generate.mjs. -->` +
  `${body}</svg>\n`;
