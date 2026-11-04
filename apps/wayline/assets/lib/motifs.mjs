// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// One chart symbol per topic, drawn in a box from -50 to 50. Each borrows something real from navigation
// charts, so a topic reads differently rather than as a recoloured copy: a cycle is a holding pattern,
// intake is arrivals merging on a fix, "no access" is restricted airspace, "not found" is an
// expanding-square search. No words and no figures, so nothing here claims anything or needs translating.
import { n } from "./chart.mjs";

// Drawing helpers bound to a palette and a stroke multiplier `k`, which thickens lines at small sizes.
export function pen(p, k = 1) {
  const fillAttr = (fill) => {
    if (fill === "surface") return `fill="${p.surface}"${p.surfaceOpacity ? ` fill-opacity="${p.surfaceOpacity}"` : ""}`;
    if (fill === "wash") return `fill="${p.wash}"${p.washOpacity ? ` fill-opacity="${p.washOpacity}"` : ""}`;
    if (fill === "tint") return `fill="${p.tint}"${p.tintOpacity ? ` fill-opacity="${p.tintOpacity}"` : ""}`;
    return `fill="${fill ?? "none"}"`;
  };
  const path = (d, stroke, width, { fill, dash, cap, opacity } = {}) =>
    `<path d="${d}" ${fillAttr(fill)} stroke="${stroke}" stroke-width="${n(width)}"` +
    (dash ? ` stroke-dasharray="${dash}"` : "") +
    (cap ? ` stroke-linecap="${cap}"` : "") +
    (opacity ? ` stroke-opacity="${opacity}"` : "") +
    `/>`;
  const self = {
    p,
    k,
    hair: (d, o) => path(d, p.hair, 0.5 * k, o),
    line: (d, o) => path(d, p.ink, 1 * k, o),
    bold: (d, o) => path(d, p.ink, 2 * k, o),
    route: (d, o) => path(d, p.route, 1.2 * k, { dash: `${n(3.2 * k)} ${n(2.2 * k)}`, ...o }),
    solid: (d, o) => path(d, p.route, 1.4 * k, o),
    muted: (d, o) => path(d, p.muted, 0.8 * k, { dash: `${n(2 * k)} ${n(2 * k)}`, ...o }),
    ring: (x, y, r = 3) =>
      // With a see-through surface (neutral palette) a hollow ring would show the route inside it, so it is solid.
      `<circle cx="${n(x)}" cy="${n(y)}" r="${n(r)}" ${p.surfaceOpacity ? `fill="${p.ink}"` : fillAttr("surface")} stroke="${p.ink}" stroke-width="${n(1 * k)}"/>`,
    hoop: (x, y, r, stroke = p.hair, width = 0.5 * k, extra = "") =>
      `<circle cx="${n(x)}" cy="${n(y)}" r="${n(r)}" fill="none" stroke="${stroke}" stroke-width="${n(width)}"${extra}/>`,
    dia: (x, y, r = 4.5, fill = p.ink) => `<path d="M${n(x)} ${n(y - r)}L${n(x + r)} ${n(y)}L${n(x)} ${n(y + r)}L${n(x - r)} ${n(y)}Z" fill="${fill}"/>`,
    rect: (x, y, w, h, { fill = "surface", stroke = p.hair, width = 0.5 * k, dash } = {}) =>
      `<rect x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" rx="${n(0.7)}" ${fillAttr(fill)} stroke="${stroke}" stroke-width="${n(width)}"${dash ? ` stroke-dasharray="${dash}"` : ""}/>`,
    chevron: (x, y, dir = 0, s = 2.6, color = p.route) =>
      `<path d="M${n(-s)} ${n(-s * 1.1)}L${n(s)} 0L${n(-s)} ${n(s * 1.1)}" transform="translate(${n(x)} ${n(y)}) rotate(${dir})" fill="none" stroke="${color}" stroke-width="${n(1.3 * k)}"/>`,
    rows: (x, y, widths, gap = 6) => widths.map((w, i) => `M${n(x)} ${n(y + i * gap)}h${n(w)}`).join(""),
  };
  return self;
}

const polar = (r, deg) => [r * Math.cos((deg * Math.PI) / 180), r * Math.sin((deg * Math.PI) / 180)];

// A holding pattern: fly the racetrack, return to the fix, go again.
function holding(g, { partial = false } = {}) {
  const track = "M-24 -16H24A16 16 0 0 1 24 16H-24A16 16 0 0 1 -24 -16Z";
  let s = g.hair("M-24 -26H24A26 26 0 0 1 24 26H-24A26 26 0 0 1 -24 -26Z", { dash: `${n(1.2 * g.k)} ${n(1.8 * g.k)}` });
  s += `<path d="${track}" ${g.p.surfaceOpacity ? 'fill="none"' : `fill="${g.p.surface}"`}/>`;
  s += g.hair("M-24 0H24");
  if (partial) {
    s += g.muted(track);
    s += g.solid("M-24 16A16 16 0 0 1 -24 -16H24");
  } else {
    s += g.route(track);
  }
  s += g.route("M-48 -38L-24 -16");
  s += g.chevron(2, -16, 0);
  s += partial ? "" : g.chevron(2, 16, 180);
  s += g.dia(-24, -16, 4.6);
  s += g.ring(24, -16, 2.6) + g.ring(24, 16, 2.6) + g.ring(-24, 16, 2.6);
  return s;
}

// Sectors of airspace, handed from one to the next along a route.
function sectors(g) {
  const a = "M-42 -30L-6 -38L4 -4L-30 10Z";
  const b = "M-6 -38L40 -30L44 6L4 -4Z";
  const c = "M-30 10L4 -4L44 6L30 36L-18 38Z";
  let s = g.line(a, { fill: "tint" }) + g.line(b, { fill: "surface" }) + g.line(c, { fill: "wash" });
  s += g.hair("M-34 -12L-4 -18M-28 -4L-8 -10M14 -28L34 -22M18 -18L36 -12M-8 18L18 12M-6 28L26 22");
  s += g.route("M-18 -12L18 -14L10 20");
  s += g.dia(-18, -12, 4) + g.ring(18, -14, 2.8) + g.dia(10, 20, 4, g.p.route);
  return s;
}

// A saved window on the same chart: stacked frames and crop marks.
function viewport(g) {
  let s = g.rect(-30, -40, 66, 48, {}) + g.rect(-38, -30, 66, 48, {});
  s += g.rect(-46, -20, 74, 54, { stroke: g.p.ink, width: g.k });
  s += g.hair("M-46 2C-30 -14 -14 -14 0 -6S20 4 28 -6M-46 14C-30 2 -12 2 2 8S20 14 28 8M-46 26C-34 18 -18 18 -4 22S18 28 28 24");
  s += g.route("M-34 24L-14 6L10 12");
  s += g.ring(-34, 24, 2.6) + g.dia(10, 12, 4, g.p.route);
  const c = 7;
  s += g.bold(`M-52 ${-26 + c}V-26H${-52 + c}M34 ${-26 + c}V-26H${34 - c}M-52 ${40 - c}V40H${-52 + c}M34 ${40 - c}V40H${34 - c}`);
  s += g.hoop(42, -38, 6) + g.dia(42, -38, 2.4, g.p.route);
  return s;
}

const sheetShape = (x, y, w, h, f = 10) => `M${x} ${y}H${x + w - f}L${x + w} ${y + f}V${y + h}H${x}Z`;
const sheetFold = (x, y, w, f = 10) => `M${x + w - f} ${y}V${y + f}H${x + w}`;

// A chart sheet with a route ruled across it.
function sheet(g) {
  let s = g.hair(sheetShape(-26, -44, 58, 80), { fill: "tint" });
  s += g.line(sheetShape(-36, -38, 58, 82), { fill: "surface" }) + g.line(sheetFold(-36, -38, 58));
  s += g.hair(g.rows(-28, -24, [26, 36, 30, 34]));
  s += g.route("M-26 34L-10 12L4 24L14 4");
  s += g.ring(-26, 34, 2.6) + g.ring(4, 24, 2.2) + g.dia(14, 4, 4, g.p.route);
  return s;
}

// A log of waypoints, one to a row.
function log(g) {
  let s = g.rect(-40, -44, 80, 88, { stroke: g.p.ink, width: g.k });
  s += g.rect(-40, -19, 80, 20, { fill: "wash", stroke: "none", width: 0 });
  s += g.route("M-26 -44V44");
  const ys = [-31, -9, 13, 33];
  ys.forEach((y, i) => {
    s += i === 1 ? g.dia(-26, y, 4.4, g.p.route) : g.ring(-26, y, 2.8);
    s += g.hair(`M-16 ${y - 3}H${[26, 30, 18, 24][i]}M-16 ${y + 3}H${[6, 14, -2, 8][i]}`);
  });
  return s;
}

// Arrivals merging on one fix.
function merge(g) {
  let s = g.route("M-34 -36L8 0") + g.route("M-40 0H8") + g.route("M-34 36L8 0");
  s += g.ring(-34, -36, 3) + g.ring(-40, 0, 3) + g.ring(-34, 36, 3);
  s += g.chevron(-14, -18.5, 40) + g.chevron(-16, 0, 0) + g.chevron(-14, 18.5, -40);
  s += g.hoop(8, 0, 11) + g.dia(8, 0, 6);
  s += g.line("M19 0H44") + g.ring(46, 0, 3);
  return s;
}

// Terrain profile with the planned route flown above it.
function profile(g) {
  let s = g.line("M-46 -40V38H48");
  for (let i = 0; i < 10; i++) s += g.hair(`M${-46 + (i + 1) * 9.4} 38v${i % 5 === 4 ? 5 : 3}`);
  for (let i = 0; i < 6; i++) s += g.hair(`M-46 ${38 - (i + 1) * 12}h${i % 5 === 4 ? -5 : -3}`);
  s += g.hair("M-46 38L-36 26L-26 30L-14 12L-6 18L6 2L16 14L26 8L36 22L48 16V38Z", { fill: "tint" });
  s += g.hair("M-36 38L-30 28M-20 38L-10 20M-4 38L6 14M10 38L18 22M26 38L32 24M38 38L44 24");
  s += g.route("M-40 8L-20 -8L4 -24L28 -18L46 -30");
  s += g.ring(-40, 8, 2.8) + g.ring(-20, -8, 2.4) + g.dia(4, -24, 4.2, g.p.route) + g.ring(28, -18, 2.4);
  return s;
}

// Range rings with a bearing to the fix, and a handle, because that is how "search" reads.
function rings(g) {
  let s = `<circle r="34" ${g.p.surfaceOpacity ? 'fill="none"' : `fill="${g.p.surface}"`}/>`;
  s += g.hoop(0, 0, 36, g.p.ink, g.k) + g.hoop(0, 0, 24) + g.hoop(0, 0, 12);
  let t = "";
  for (let a = 0; a < 360; a += 15) {
    const [x1, y1] = polar(a % 45 ? 33 : 30, a);
    const [x2, y2] = polar(36, a);
    t += `M${n(x1)} ${n(y1)}L${n(x2)} ${n(y2)}`;
  }
  s += g.hair(t) + g.hair("M-36 0H36M0 -36V36");
  s += g.route("M0 0L13 -20");
  s += g.ring(0, 0, 2) + g.dia(14, -21, 4.4, g.p.route);
  s += `<path d="M26 26L46 46" stroke="${g.p.ink}" stroke-width="${n(4.4 * g.k)}"/>`;
  return s;
}

const note = (g, x, y, size, rows, fill = "surface") =>
  g.line(sheetShape(x, y, size, size, 8), { fill }) + g.line(sheetFold(x, y, size, 8)) + g.hair(g.rows(x + 6, y + 13, rows));

// Annotations pinned along a route.
function notes(g) {
  let s = note(g, -46, -24, 40, [26, 20, 28]);
  s += note(g, -8, -44, 40, [24, 28, 18], "wash");
  s += note(g, 8, 6, 40, [22, 28, 16]);
  s += g.route("M-26 -24L12 -44L28 6");
  s += g.dia(-26, -24, 3.8) + g.dia(12, -44, 3.8, g.p.route) + g.dia(28, 6, 3.8);
  return s;
}

// A board of small chart panels.
function panels(g) {
  let s = g.rect(-46, -42, 54, 36, { stroke: g.p.ink, width: g.k }) + g.rect(14, -42, 32, 36, {});
  s += g.rect(-46, 0, 32, 40, {}) + g.rect(-8, 0, 54, 40, { stroke: g.p.ink, width: g.k });
  s += g.route("M-40 -14L-24 -24L-10 -18L2 -34") + g.ring(-40, -14, 2) + g.dia(2, -34, 3, g.p.route);
  s += g.hoop(30, -24, 11) + g.hoop(30, -24, 5) + g.hair("M16 -24H44M30 -38V-10");
  s += g.hair(g.rows(-40, 10, [20, 14, 18, 12], 7));
  s += g.line("M-2 34H40") + [12, 20, 15, 26, 10].map((h, i) => g.rect(2 + i * 8, 34 - h, 5, h, { fill: i === 3 ? "wash" : "tint", stroke: i === 3 ? g.p.route : g.p.hair })).join("");
  return s;
}

// A folded chart, the thing you carry for one journey.
function folio(g) {
  const a = "M-46 -28L-16 -38V30L-46 40Z";
  const b = "M-16 -38L16 -28V40L-16 30Z";
  const c = "M16 -28L46 -38V30L16 40Z";
  let s = g.line(a, { fill: "surface" }) + g.line(b, { fill: "tint" }) + g.line(c, { fill: "surface" });
  s += g.hair("M-40 -14L-22 -20M-40 -2L-22 -8M-40 26L-22 20M-10 -20L10 -14M-10 18L10 24M22 -14L40 -20M22 16L40 10M22 26L40 20");
  s += g.route("M-34 14L-16 -2L4 6L32 -10");
  s += g.ring(-34, 14, 3) + g.ring(4, 6, 2.6) + g.dia(32, -10, 5, g.p.route);
  return s;
}

function tag(g) {
  let s = g.line("M-34 -32H6L40 2L6 36H-34Z", { fill: "surface" });
  s += g.ring(-18, -16, 4);
  s += g.route("M-18 -16L4 4L-4 18");
  s += g.dia(4, 4, 3.6, g.p.route);
  return s;
}

function crew(g) {
  let s = g.hoop(24, -14, 8, g.p.hair, 0.8 * g.k) + g.hair("M8 26C8 10 16 4 24 4S42 10 42 26");
  s += g.line("M-36 36C-36 12 -24 2 -8 2S20 12 20 36", { fill: "surface" });
  s += `<circle cx="-8" cy="-18" r="13" ${g.p.surfaceOpacity ? 'fill="none"' : `fill="${g.p.surface}"`} stroke="${g.p.ink}" stroke-width="${n(g.k)}"/>`;
  s += g.route("M-46 36H46");
  s += g.dia(-8, 36, 4, g.p.route);
  return s;
}

// Flight levels stacked, the top one in route colour.
function altitude(g) {
  let s = g.hair("M-40 40V-40M-40 40h-4M-40 20h-4M-40 0h-4M-40 -20h-4M-40 -40h-4");
  s += `<path d="M-26 34L4 16L34 34" fill="none" stroke="${g.p.muted}" stroke-width="${n(3.2 * g.k)}"/>`;
  s += `<path d="M-26 12L4 -6L34 12" fill="none" stroke="${g.p.ink}" stroke-width="${n(3.2 * g.k)}"/>`;
  s += `<path d="M-26 -10L4 -28L34 -10" fill="none" stroke="${g.p.route}" stroke-width="${n(3.2 * g.k)}"/>`;
  s += g.dia(4, -38, 3.6, g.p.route);
  return s;
}

// Position on the route: flown solid, still to fly dashed.
function position(g) {
  let s = g.hair("M-46 34H46");
  for (let i = 0; i <= 10; i++) s += g.hair(`M${-46 + i * 9.2} 34v${i % 5 === 0 ? 6 : 3}`);
  s += g.solid("M-44 22L-22 16L-2 -2L8 -8");
  s += g.muted("M8 -8L28 -18L44 -36");
  s += g.ring(-44, 22, 3) + g.dia(8, -8, 5.4, g.p.route) + g.ring(44, -36, 3);
  s += g.hair("M8 -2V34", { dash: `${n(1.2 * g.k)} ${n(1.6 * g.k)}` });
  return s;
}

function trend(g) {
  let s = g.line("M-44 -40V38H46");
  for (let i = 1; i <= 4; i++) s += g.hair(`M-44 ${38 - i * 16}H46`);
  s += g.muted("M-44 -34L46 34");
  s += g.solid("M-44 -34L-22 -22L-6 -2L14 4L30 22");
  s += g.ring(-22, -22, 2.4) + g.ring(-6, -2, 2.4) + g.ring(14, 4, 2.4) + g.dia(30, 22, 4.4, g.p.route);
  return s;
}

// Restricted airspace: a boundary hatched on its inside, and a route that goes around it.
function restricted(g, { shape = "circle", center = "dia" } = {}) {
  const R = 30;
  let edge = "";
  const ticks = [];
  if (shape === "circle") {
    edge = g.hoop(0, 0, R, g.p.route, 1.5 * g.k);
    for (let a = 0; a < 360; a += 10) {
      const [x1, y1] = polar(R, a);
      const [x2, y2] = polar(R - 6, a + 9);
      ticks.push(`M${n(x1)} ${n(y1)}L${n(x2)} ${n(y2)}`);
    }
  } else {
    const sides = shape === "hex" ? 6 : 4;
    const off = shape === "hex" ? 0 : 45;
    const rr = shape === "hex" ? R + 2 : R + 8;
    const v = Array.from({ length: sides }, (_, i) => polar(rr, off + (i * 360) / sides));
    edge = g.solid(`M${v.map((q) => `${n(q[0])} ${n(q[1])}`).join("L")}Z`);
    v.forEach((q, i) => {
      const t = v[(i + 1) % sides];
      const m = shape === "hex" ? 7 : 10;
      for (let j = 0; j < m; j++) {
        const f = (j + 0.5) / m;
        const f2 = f + 0.5 / m;
        const x = q[0] + (t[0] - q[0]) * f;
        const y = q[1] + (t[1] - q[1]) * f;
        const x2 = (q[0] + (t[0] - q[0]) * f2) * 0.82;
        const y2 = (q[1] + (t[1] - q[1]) * f2) * 0.82;
        ticks.push(`M${n(x)} ${n(y)}L${n(x2)} ${n(y2)}`);
      }
    });
  }
  let s = g.p.surfaceOpacity ? "" : `<circle r="${R + 2}" fill="${g.p.surface}"/>`;
  s += edge + `<path d="${ticks.join("")}" fill="none" stroke="${g.p.route}" stroke-width="${n(0.8 * g.k)}"/>`;
  s += g.line("M-50 22L-40 20A44 44 0 0 1 40 18L50 20", { dash: `${n(3 * g.k)} ${n(2 * g.k)}` });
  s += g.ring(-40, 20, 2.8) + g.ring(40, 18, 2.8);
  if (center === "dia") s += g.dia(0, 0, 7);
  if (center === "bar") s += `<path d="M-11 0H11" stroke="${g.p.ink}" stroke-width="${n(4 * g.k)}"/>`;
  if (center === "plus") s += `<path d="M-10 0H10M0 -10V10" stroke="${g.p.ink}" stroke-width="${n(3.4 * g.k)}"/>`;
  if (center === "grid") s += [[-9, -9], [1, -9], [-9, 1], [1, 1]].map(([x, y]) => g.rect(x, y, 8, 8, { fill: "none", stroke: g.p.ink, width: g.k })).join("");
  if (center === "sheet") s += g.line(sheetShape(-8, -11, 16, 22, 5)) + g.line(sheetFold(-8, -11, 16, 5));
  return s;
}

// An expanding-square search, flown from the last known position.
function lost(g) {
  const a = 13;
  let x = 0;
  let y = 0;
  const pts = [[0, 0]];
  const dirs = [[1, 0], [0, -1], [-1, 0], [0, 1]];
  let leg = 1;
  for (let i = 0; i < 10; i++) {
    x += dirs[i % 4][0] * leg * a;
    y += dirs[i % 4][1] * leg * a;
    pts.push([x, y]);
    if (i % 2 === 1) leg++;
  }
  let s = g.hair("M-46 -46H-40M-46 -46V-40M46 -46H40M46 -46V-40M-46 46H-40M-46 46V40M46 46H40M46 46V40");
  s += g.route(`M${pts.map((q) => `${q[0]} ${q[1]}`).join("L")}`);
  s += g.dia(0, 0, 4.6);
  const end = pts[pts.length - 1];
  s += g.ring(end[0], end[1], 3);
  s += g.chevron(a / 2 + 1, 0, 0) + g.chevron(0, -a, 180) + g.chevron(0, 2 * a, 0);
  return s;
}

// An obstruction, as charted: an inverted V on a base dot, with its light, and the route taken around it.
function obstacle(g) {
  let s = g.line("M-48 36H48");
  for (let i = 0; i < 12; i++) s += g.hair(`M${-45 + i * 8.6} 36l-4 6`);
  s += g.bold("M-13 36L0 -10L13 36");
  s += g.dia(0, 36, 4.2);
  s += g.hoop(0, -14, 3.6, g.p.route, 1.4 * g.k);
  s += g.solid("M-13 -22L-8 -18M13 -22L8 -18M0 -30V-24");
  s += g.route("M-48 8L-24 -36H24L48 8");
  s += g.ring(-24, -36, 2.8) + g.ring(24, -36, 2.8);
  s += g.chevron(-37, -13, -62) + g.chevron(37, -13, 62);
  return s;
}

// A leg that stops: two break marks and a failed waypoint.
function broken(g) {
  let s = g.solid("M-46 16L-22 6") + g.muted("M22 -8L46 -18");
  s += g.ring(-46, 16, 3) + g.ring(46, -18, 3);
  s += g.line("M-24 -2L-18 14M18 -16L24 0");
  s += g.hoop(0, -1, 14, g.p.route, 1.4 * g.k);
  s += `<path d="M-6 -7L6 5M6 -7L-6 5" stroke="${g.p.route}" stroke-width="${n(2.2 * g.k)}"/>`;
  s += g.hair("M-46 34H46M-46 -36H46", { dash: `${n(1.2 * g.k)} ${n(2 * g.k)}` });
  return s;
}

function invite(g) {
  let s = g.line("M-40 -18H32V30H-40Z", { fill: "surface" });
  s += g.solid("M-40 -18L-4 10L32 -18");
  s += g.hair("M-40 30L-14 2M32 30L6 2");
  s += g.route("M46 -40L14 -28");
  s += g.ring(46, -40, 3) + g.dia(-4, 10, 4.4, g.p.route);
  return s;
}

// A key whose bow is the logo's ring and whose shaft is the route.
function keyMotif(g) {
  let s = g.hoop(-26, 0, 18, g.p.hair) + g.hoop(-26, 0, 11, g.p.ink, 3.2 * g.k);
  s += `<path d="M-15 0H42M28 0V12M38 0V9" fill="none" stroke="${g.p.route}" stroke-width="${n(3 * g.k)}"/>`;
  s += g.hair("M-46 -32H46M-46 32H46", { dash: `${n(1.2 * g.k)} ${n(2 * g.k)}` });
  return s;
}

// A radio beacon: arcs on both sides, one bearing out to a waypoint.
function beacon(g) {
  let s = "";
  for (const r of [14, 24, 34]) {
    const [x1, y1] = polar(r, -40);
    const [x2, y2] = polar(r, 40);
    const arc = `M${n(x1)} ${n(y1)}A${r} ${r} 0 0 1 ${n(x2)} ${n(y2)}`;
    s += r === 34 ? g.hair(arc) : g.line(arc);
    s += r === 34 ? g.hair(`M${n(-x1)} ${n(y1)}A${r} ${r} 0 0 0 ${n(-x2)} ${n(y2)}`) : g.line(`M${n(-x1)} ${n(y1)}A${r} ${r} 0 0 0 ${n(-x2)} ${n(y2)}`);
  }
  s += g.line("M0 0V40") + g.hair("M-14 40H14");
  s += g.route("M0 0L28 -40") + g.ring(29, -41, 3);
  s += g.dia(0, 0, 5.4, g.p.route);
  return s;
}

function funnel(g, { top = "oval" } = {}) {
  let s = g.line("M-42 -18H42L10 14V38L-10 44V14Z", { fill: "surface" });
  s += g.hair("M-28 -8H28M-16 2H16");
  s += top === "oval" ? g.route("M-18 -38H18A7 7 0 0 1 18 -24H-18A7 7 0 0 1 -18 -38Z") : g.route("M-18 -40H18L24 -32L18 -24H-18L-24 -32Z");
  s += g.dia(0, -24, 3.8, g.p.route);
  return s;
}

function field(g, { top = "oval" } = {}) {
  let s = g.rect(-44, -10, 88, 22, { stroke: g.p.ink, width: g.k });
  s += g.hair("M-34 1H-4");
  s += `<path d="M2 -5V7" stroke="${g.p.route}" stroke-width="${n(2 * g.k)}"/>`;
  s += g.hoop(32, 1, 4.4, g.p.ink, g.k) + g.line("M35 4L39 8");
  s += top === "oval" ? g.route("M-18 -38H18A7 7 0 0 1 18 -24H-18A7 7 0 0 1 -18 -38Z") : g.route("M-18 -40H18L24 -32L18 -24H-18L-24 -32Z");
  s += g.hair(g.rows(-28, 24, [56, 40, 48], 7));
  return s;
}

function outline(g) {
  let s = g.line(sheetShape(-38, -44, 76, 88), { fill: "surface" }) + g.line(sheetFold(-38, -44, 76));
  s += g.route("M-24 -30V34");
  const rows = [[-30, 0, 34], [-16, 10, 28], [-2, 10, 22], [12, 0, 38], [26, 10, 24]];
  for (const [y, ind, w] of rows) {
    s += ind ? g.ring(-24, y, 2) : g.dia(-24, y, 3.4, g.p.route);
    s += g.hair(`M${-16 + ind} ${y}h${w}`);
  }
  return s;
}

function gallery(g) {
  let s = g.rect(-30, -40, 72, 58, {});
  s += g.rect(-42, -26, 76, 62, { stroke: g.p.ink, width: g.k });
  s += g.hair("M-42 16L-22 -2L-8 10L8 -8L34 18V36H-42Z", { fill: "tint" });
  s += g.hair("M-36 24L-22 8L-10 18L8 0L28 22");
  s += g.hoop(18, -12, 5, g.p.route, 1.2 * g.k);
  return s;
}

// A climb out from a runway.
function takeoff(g) {
  let s = g.bold("M-48 34H10");
  s += g.hair("M-44 40H6M-48 28H10");
  s += g.solid("M-20 34C2 34 12 26 22 8");
  s += g.route("M22 8L44 -34");
  s += g.ring(22, 8, 2.8) + g.dia(44, -36, 5.4, g.p.route);
  return s;
}

function signedIn(g) {
  let s = g.hoop(-6, -14, 14, g.p.ink, g.k);
  s += g.line("M-34 36C-34 14 -22 6 -6 6S22 14 22 36");
  s += g.solid("M20 -10L28 -2L44 -22");
  s += g.hair("M-46 36H46");
  return s;
}

export const MOTIFS = {
  holding, sectors, viewport, sheet, log, merge, profile, rings, notes, panels, folio, tag, crew, altitude,
  position, trend, restricted, lost, obstacle, broken, invite, key: keyMotif, beacon, funnel, field, outline,
  gallery, takeoff, signedIn,
};
