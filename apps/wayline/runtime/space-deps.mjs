// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// The space image keeps upstream's node_modules, which arrive through its FROM line with CRITICAL findings in
// three packages. storybook and tinypool are development tools nothing at runtime can reach, so they go.
// proxy-addr is reached by express on every request, so it is replaced with 2.0.8 from an integrity-checked
// tarball. Every expectation is exact, so a new base image stops the build here and this gets read again.
//
//   node --experimental-vm-modules space-deps.mjs apply     Dockerfile.space, as root, with network
//   node --experimental-vm-modules space-deps.mjs check     Dockerfile.space and checks/smoke-images.sh
//   node --experimental-vm-modules space-deps.mjs closure   prints what the server can reach, for evidence
//
// The flag gives this file V8's own parser for the bundle's import statements, in place of a pattern.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import http from "node:http";
import { builtinModules, createRequire } from "node:module";
import { basename, dirname, join, relative, resolve } from "node:path";
import vm from "node:vm";

const APP = "/app/apps/space";
const STORE = "/app/node_modules/.pnpm";
const SERVER = `${APP}/build/server`;
const SERVE = "@react-router/serve"; // Upstream's CMD runs its bin, so it is a root alongside the bundle.

// What goes: the package's store directory, and the name it is imported by.
const REMOVED = [
  { name: "storybook", dir: /^storybook@10\.4\.6(_|$)/ },
  { name: "tinypool", dir: /^tinypool@2\.1\.0$/ },
];
const PROXY_ADDR = {
  old: "proxy-addr@2.0.7",
  new: "proxy-addr@2.0.8",
  url: "https://registry.npmjs.org/proxy-addr/-/proxy-addr-2.0.8.tgz",
  // dist.integrity from https://registry.npmjs.org/proxy-addr/2.0.8, the same dependencies as 2.0.7.
  integrity: "sha512-5nnx0yGyVUcY6t9RnWcARWtwT9F1D8O9rt08htPvnd49W1IgZtmLkhu9WfMzQj1cFxjHIO6connUNVW5k7AVyQ==",
  deps: { forwarded: "forwarded@0.2.0", "ipaddr.js": "ipaddr.js@1.9.1" },
  // The only two places that link to it. A third would be something this did not look at.
  links: ["express@4.22.0/node_modules/proxy-addr", "node_modules/proxy-addr"],
};

let failures = 0;
function report(ok, label, detail = "") {
  failures += ok ? 0 : 1;
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? ` ${detail}` : ""}`);
}
function die(message) {
  console.error(`space-deps: ${message}`);
  process.exit(1);
}

const builtin = (spec) => spec.startsWith("node:") || builtinModules.includes(spec.split("/")[0]);
const isBare = (spec) => !spec.startsWith(".") && !spec.startsWith("/") && !spec.startsWith("data:");
const packageName = (spec) => spec.split("/").slice(0, spec.startsWith("@") ? 2 : 1).join("/");

function bundleFiles() {
  const assets = join(SERVER, "assets");
  return [join(SERVER, "index.js"), ...readdirSync(assets).filter((f) => f.endsWith(".js")).map((f) => join(assets, f))];
}

// Static imports as V8 parses them. import() and require() with a literal are not part of a module's static
// requests, so those are read with a pattern. A hit there that resolves to nothing is reported and not failed:
// bundled code can hold a guarded require() of something optional.
function bundleImports() {
  const required = new Set();
  const dynamic = new Set();
  let mentions = 0;
  for (const file of bundleFiles()) {
    const code = readFileSync(file, "utf8");
    for (const spec of new vm.SourceTextModule(code, { identifier: file }).dependencySpecifiers) {
      if (isBare(spec) && !builtin(spec)) required.add(spec);
    }
    for (const match of code.matchAll(/\b(?:import|require)\(\s*["'`]([^"'`]+)["'`]\s*\)/g)) {
      if (isBare(match[1]) && !builtin(match[1])) dynamic.add(match[1]);
    }
    if (REMOVED.some(({ name }) => code.includes(name))) mentions += 1;
  }
  return { required, dynamic, mentions };
}

// Node's own lookup: node_modules of each directory on the way up.
function lookup(from, name) {
  for (let dir = from; ; dir = dirname(dir)) {
    const candidate = join(dir, "node_modules", name);
    if (existsSync(join(candidate, "package.json"))) return realpathSync(candidate);
    if (dir === dirname(dir)) return null;
  }
}

// pnpm links a package's declared dependencies and peers beside it, so that is where to look. Walking up would
// reach .pnpm/node_modules, which holds every package hoisted, and would pull in peers nothing installed for it.
function neighbour(packageDir, name) {
  const pathParts = packageDir.split("/node_modules/");
  const home = `${pathParts.slice(0, -1).join("/node_modules/")}/node_modules`;
  const candidate = join(home, name);
  return existsSync(join(candidate, "package.json")) ? realpathSync(candidate) : null;
}

function closure() {
  const { required, dynamic, mentions } = bundleImports();
  const seen = new Map();
  const missing = [];
  const queue = [];
  const visit = (dir, via) => {
    if (seen.has(dir)) return;
    const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    seen.set(dir, { name: pkg.name, version: pkg.version, via });
    queue.push({ dir, pkg });
  };
  for (const spec of [...required, SERVE]) {
    const name = packageName(spec);
    const dir = lookup(APP, name);
    if (dir) visit(dir, spec === SERVE ? "CMD" : "server bundle");
    else missing.push(`${name} (imported by the server bundle)`);
  }
  const unresolved = [];
  for (const spec of dynamic) {
    const dir = lookup(APP, packageName(spec));
    if (dir) visit(dir, "server bundle, import() or require()");
    else unresolved.push(spec);
  }
  while (queue.length) {
    const { dir, pkg } = queue.pop();
    for (const name of Object.keys(pkg.dependencies ?? {})) {
      const found = neighbour(dir, name);
      if (found) visit(found, pkg.name);
      else if (!(name in (pkg.optionalDependencies ?? {}))) missing.push(`${name} (dependency of ${pkg.name}@${pkg.version})`);
    }
    for (const name of [...Object.keys(pkg.optionalDependencies ?? {}), ...Object.keys(pkg.peerDependencies ?? {})]) {
      const found = neighbour(dir, name);
      if (found) visit(found, pkg.name);
    }
  }
  return { required, dynamic, mentions, packages: [...seen.values()], missing, unresolved };
}

function reachesRemoved(found) {
  return found.packages.filter(({ name }) => REMOVED.some((r) => r.name === name));
}

// Every symlink and .bin shim under /app, without following any.
function walk(dir, visit) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isSymbolicLink()) visit(path, "link");
    else if (entry.isDirectory()) walk(path, visit);
    else if (basename(dir) === ".bin") visit(path, "shim");
  }
}

function storeDirs(pattern) {
  return readdirSync(STORE).filter((name) => pattern.test(name)).map((name) => join(STORE, name));
}

async function fetchProxyAddr() {
  const response = await fetch(PROXY_ADDR.url);
  if (!response.ok) die(`${PROXY_ADDR.url} answered ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  const integrity = `sha512-${createHash("sha512").update(bytes).digest("base64")}`;
  if (integrity !== PROXY_ADDR.integrity) die(`${PROXY_ADDR.url} is ${integrity}, expected ${PROXY_ADDR.integrity}`);
  console.log(`proxy-addr tarball: ${bytes.length} bytes, integrity ${integrity}`);
  return bytes;
}

function installProxyAddr(bytes) {
  const oldDir = join(STORE, PROXY_ADDR.old);
  const newDir = join(STORE, PROXY_ADDR.new);
  if (!existsSync(oldDir) || existsSync(newDir)) die(`expected ${PROXY_ADDR.old} and no ${PROXY_ADDR.new} in the store`);
  const packageDir = join(newDir, "node_modules/proxy-addr");
  mkdirSync(packageDir, { recursive: true });
  const tarball = "/tmp/proxy-addr.tgz";
  writeFileSync(tarball, bytes);
  execFileSync("tar", ["-xzf", tarball, "-C", packageDir, "--strip-components=1"], { stdio: "inherit" });
  rmSync(tarball);
  for (const [name, storeDir] of Object.entries(PROXY_ADDR.deps)) {
    if (!existsSync(join(STORE, storeDir, "node_modules", name))) die(`${storeDir} is not in the store`);
    symlinkSync(`../../${storeDir}/node_modules/${name}`, join(newDir, "node_modules", name));
  }
  const links = [];
  walk("/app", (path, kind) => {
    if (kind === "link" && resolve(dirname(path), readlinkSync(path)).startsWith(`${oldDir}/`)) links.push(path);
  });
  const expected = PROXY_ADDR.links.map((link) => join(STORE, link)).sort();
  if (JSON.stringify(links.sort()) !== JSON.stringify(expected)) die(`links to ${PROXY_ADDR.old} are ${links}, expected ${expected}`);
  for (const link of links) {
    unlinkSync(link);
    symlinkSync(relative(dirname(link), join(packageDir)), link);
  }
  rmSync(oldDir, { recursive: true });
  console.log(`replaced ${PROXY_ADDR.old} with ${PROXY_ADDR.new}, ${links.length} links repointed`);
}

function removeDevTools() {
  const reached = reachesRemoved(closure());
  if (reached.length) die(`the server can reach what this would remove: ${JSON.stringify(reached)}`);
  const dirs = REMOVED.map(({ name, dir }) => {
    const matches = storeDirs(dir);
    if (matches.length !== 1) die(`expected one ${name} in the store matching ${dir}, found ${matches.length}`);
    return matches[0];
  });
  let links = 0;
  let shims = 0;
  walk("/app", (path, kind) => {
    if (kind === "link" && dirs.some((dir) => resolve(dirname(path), readlinkSync(path)).startsWith(`${dir}/`))) {
      unlinkSync(path);
      links += 1;
    } else if (kind === "shim" && basename(path) === "storybook") {
      unlinkSync(path);
      shims += 1;
    }
  });
  for (const dir of dirs) rmSync(dir, { recursive: true });
  console.log(`removed ${dirs.map((dir) => basename(dir).split("_")[0]).join(" and ")}, ${links} links to them and ${shims} .bin shims`);
}

// A request through the same express the server runs, with a spoofed header. Returns what express concluded.
async function askExpress(express, trust) {
  const app = express();
  if (trust !== undefined) app.set("trust proxy", trust);
  app.get("/", (req, res) => res.json({ ip: req.ip, ips: req.ips }));
  const server = await new Promise((done) => {
    const listening = app.listen(0, "127.0.0.1", () => done(listening));
  });
  try {
    return await new Promise((done, failed) => {
      const headers = { "X-Forwarded-For": "203.0.113.9, 198.51.100.7" };
      http.get({ host: "127.0.0.1", port: server.address().port, headers }, (res) => {
        let body = "";
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => done(JSON.parse(body)));
      }).on("error", failed);
    });
  } finally {
    server.close();
  }
}

async function check() {
  console.log("\n== What the server bundle imports");
  const found = closure();
  console.log(`${found.required.size} static imports and ${found.dynamic.size} import() or require() of a package, across ${bundleFiles().length} bundle files`);
  console.log(`${found.packages.length} packages reachable from them and from ${SERVE}`);
  report(found.missing.length === 0, "every import and required dependency resolves", found.missing.join(", "));
  report(reachesRemoved(found).length === 0, "storybook and tinypool are not reachable");
  report(found.mentions === 0, "no bundle file mentions storybook or tinypool", found.mentions ? `${found.mentions} files` : "");
  if (found.unresolved.length) console.log(`note: these names follow import( or require( in comments or bundled code, and no package is installed under them, so nothing loads them: ${found.unresolved.join(", ")}`);

  console.log("\n== What is gone from the store");
  for (const { name, dir } of REMOVED) report(storeDirs(dir).length === 0, `${name} is gone`);
  report(!existsSync(join(STORE, PROXY_ADDR.old)), `${PROXY_ADDR.old} is gone`);
  const dangling = [];
  walk("/app", (path, kind) => {
    if (kind === "link" && /\/(storybook|tinypool|proxy-addr)$/.test(path) && !path.includes("/@chromatic-com/") && !existsSync(path)) dangling.push(path);
  });
  report(dangling.length === 0, "nothing links to them", dangling.join(", "));

  console.log("\n== proxy-addr, as express resolves it");
  const expressMain = createRequire(join(lookup(APP, SERVE), "package.json")).resolve("express");
  const express = createRequire(expressMain)(expressMain);
  const fromExpress = createRequire(expressMain);
  const version = fromExpress("proxy-addr/package.json").version;
  report(version === "2.0.8", `express resolves proxy-addr ${version}`, realpathSync(fromExpress.resolve("proxy-addr")));
  const proxyaddr = fromExpress("proxy-addr");
  report(proxyaddr.compile("::ffff:10.0.0.0/8")("203.0.113.9", 0) === false, "the CVE-2026-90711 subnet does not trust an arbitrary IPv4 address");
  report(proxyaddr.compile("10.0.0.0/8")("10.1.2.3", 0) === true, "a plain IPv4 subnet still trusts its own addresses");

  console.log("\n== X-Forwarded-For: 203.0.113.9, 198.51.100.7 from 127.0.0.1, through this express");
  const untrusted = await askExpress(express);
  report(untrusted.ip === "127.0.0.1" && untrusted.ips.length === 0, "with no trust proxy, which is how react-router-serve runs, the header is ignored", JSON.stringify(untrusted));
  const loopback = await askExpress(express, "loopback");
  report(loopback.ip === "198.51.100.7", "trust proxy loopback takes the nearest untrusted address", JSON.stringify(loopback));
  const mapped = await askExpress(express, "::ffff:10.0.0.0/8");
  report(mapped.ip === "127.0.0.1", "trust proxy ::ffff:10.0.0.0/8 does not let the client choose its address", JSON.stringify(mapped));

  console.log(`\nspace-deps: ${failures} failed`);
  process.exit(failures ? 1 : 0);
}

const command = process.argv[2];
if (command === "apply") {
  // Fetch first: a failed download leaves the tree alone, and the layer fails as a whole anyway.
  const bytes = await fetchProxyAddr();
  removeDevTools();
  installProxyAddr(bytes);
} else if (command === "check") {
  await check();
} else if (command === "closure") {
  const found = closure();
  console.log(`# ${found.required.size} static imports of a package in the server bundle:`);
  console.log([...found.required].map(packageName).filter((v, i, a) => a.indexOf(v) === i).sort().join("\n"));
  console.log(`# import() or require() of a package with a literal name:`);
  console.log([...found.dynamic].sort().join("\n"));
  console.log(`# of those, not resolvable here: ${found.unresolved.join(", ") || "none"}`);
  console.log(`# ${found.packages.length} packages reachable, with what first pulled each in:`);
  for (const { name, version, via } of found.packages.sort((a, b) => a.name.localeCompare(b.name))) console.log(`${name}@${version}\t${via}`);
  console.log(`# storybook or tinypool among them: ${reachesRemoved(found).length}`);
  console.log(`# bundle files that mention either name: ${found.mentions}`);
  console.log(`# missing: ${found.missing.join(", ") || "none"}`);
} else {
  die("usage: space-deps.mjs apply|check|closure");
}
