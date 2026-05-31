// Copyright (c) 2026 Bereket Abera
// SPDX-License-Identifier: AGPL-3.0-only
//
// Lists the packages inlined into the space server bundle, from the //#region comments the bundler leaves. Code inlined
// this way is not a package in node_modules: runtime/space-deps.mjs's closure and its load trace cannot see it, because
// nothing imports it, while an image scan reports the copy in node_modules, if there is one, and not the bundle.
// With a trivy JSON for the space image, each inlined package also shows that package's findings at the same version.
//
//   node apps/wayline/checks/space-regions.mjs <build/server directory> [trivy json]
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [server, scan] = process.argv.slice(2);
if (!server) {
  console.error("usage: space-regions.mjs <build/server directory> [trivy json]");
  process.exit(2);
}

const files = [join(server, "index.js"), ...readdirSync(join(server, "assets")).filter((f) => f.endsWith(".js")).map((f) => join(server, "assets", f))];
// node_modules/.pnpm/<store directory>/node_modules/<package>/..., and the last package on the path is what was inlined.
const STORE = /node_modules\/\.pnpm\/([^/]+)\/node_modules\/((?:@[^/]+\/)?[^/]+)\//;

const packages = new Map();
let otherRegions = 0;
let totalRegions = 0;
const perFile = new Map();
for (const file of files) {
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.startsWith("//#region ")) continue;
    totalRegions += 1;
    const match = line.match(STORE);
    if (!match) {
      otherRegions += 1;
      continue;
    }
    const [, store, name] = match;
    const prefix = `${name.replace("/", "+")}@`;
    const version = store.startsWith(prefix) ? store.slice(prefix.length).split("_")[0] : `unknown, store ${store}`;
    const key = `${name}@${version}`;
    packages.set(key, (packages.get(key) ?? 0) + 1);
    const inFile = file.endsWith("index.js") ? "index.js" : "assets/*.js";
    perFile.set(`${key} ${inFile}`, (perFile.get(`${key} ${inFile}`) ?? 0) + 1);
  }
}

const findings = new Map();
if (scan) {
  for (const result of JSON.parse(readFileSync(scan, "utf8")).Results ?? []) {
    for (const v of result.Vulnerabilities ?? []) {
      const key = `${v.PkgName}@${v.InstalledVersion}`;
      if (!findings.has(key)) findings.set(key, {});
      const counts = findings.get(key);
      counts[v.Severity] = (counts[v.Severity] ?? 0) + 1;
    }
  }
}

console.log(`# ${files.length} bundle files, ${totalRegions} //#region comments: ${totalRegions - otherRegions} from ${packages.size} packages in node_modules, ${otherRegions} from the app and workspace packages`);
console.log("# regions\tpackage\twhere\tfindings at this version in the scan given" + (scan ? "" : " (none given)"));
for (const key of [...packages.keys()].sort()) {
  const where = ["index.js", "assets/*.js"].filter((f) => perFile.has(`${key} ${f}`)).join(", ");
  const found = findings.get(key);
  console.log(`${packages.get(key)}\t${key}\t${where}\t${found ? JSON.stringify(found) : "-"}`);
}
if (scan) {
  const inlined = [...packages.keys()].filter((k) => findings.has(k)).sort();
  console.log(`# inlined at a version with a finding: ${inlined.length}`);
  for (const key of inlined) console.log(`${key}\t${JSON.stringify(findings.get(key))}`);
}
