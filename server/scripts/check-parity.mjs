#!/usr/bin/env node
/**
 * check-parity.mjs — manifest <-> GDScript handler parity.
 *
 * The TypeScript tool manifest and the GDScript handler registrations are
 * maintained by hand in two separate places. They WILL drift. This is the
 * cheapest high-value regression lock in the repo.
 *
 * Verifies, in both directions:
 *   1. every tool in TOOL_DEFINITIONS has a GDScript handler registration
 *   2. every GDScript registration is exposed in TOOL_DEFINITIONS
 *   3. every registered handler function actually has a `func _name(` body
 *   4. every command module referenced by command_router.gd exists on disk
 *   5. every command module on disk is referenced by command_router.gd
 *   6. no duplicate tool names
 *
 * Reads the manifest by parsing the .ts source directly, so it runs without a
 * build step. Exits non-zero on any mismatch.
 *
 * Usage: node server/scripts/check-parity.mjs
 */
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MANIFEST = join(REPO, "server", "src", "tool-manifest.ts");
const CMD_DIR = join(REPO, "addons", "godot_mcp", "commands");
const ROUTER = join(REPO, "addons", "godot_mcp", "command_router.gd");

const problems = [];
const fail = (m) => problems.push(m);

// ---------------------------------------------------------------- manifest --
const manifestSrc = readFileSync(MANIFEST, "utf8");

// Tool entries look like:  { name: "add_node", description: "...", method: "add_node", ... }
// Param entries look like: { name: "type", type: "string" }
// Only the former is followed by `, description:`.
const tsTools = [];
const toolRe = /\{\s*name:\s*"([a-z_0-9]+)"\s*,\s*description:/g;
let m;
while ((m = toolRe.exec(manifestSrc)) !== null) tsTools.push(m[1]);

if (tsTools.length === 0) fail("parsed 0 tools from tool-manifest.ts — parser is broken or file moved");

const tsDupes = tsTools.filter((t, i) => tsTools.indexOf(t) !== i);
if (tsDupes.length) fail(`duplicate tool names in manifest: ${[...new Set(tsDupes)].join(", ")}`);

// Also collect the `method:` field — the router dispatches on this, not on name.
const tsMethods = new Map();
const methodRe = /\{\s*name:\s*"([a-z_0-9]+)"\s*,\s*description:\s*"(?:[^"\\]|\\.)*"\s*,\s*method:\s*"([a-z_0-9]+)"/g;
while ((m = methodRe.exec(manifestSrc)) !== null) tsMethods.set(m[1], m[2]);
for (const t of tsTools) {
  if (!tsMethods.has(t)) fail(`tool "${t}": could not parse its method field`);
}

// -------------------------------------------------------------- gdscript ----
if (!existsSync(CMD_DIR)) {
  fail(`command directory not found: ${CMD_DIR}`);
} 

const gdFiles = existsSync(CMD_DIR)
  ? readdirSync(CMD_DIR).filter((f) => f.endsWith(".gd"))
  : [];

/** tool name -> { fn, file } */
const gdHandlers = new Map();

for (const file of gdFiles) {
  const src = readFileSync(join(CMD_DIR, file), "utf8");

  // Only look inside the get_commands() dictionary literal. Registrations
  // elsewhere (e.g. `"results": _test_results` inside a payload dict) are not
  // command registrations and must not be counted.
  const block = extractGetCommands(src);
  if (block === null) {
    if (file !== "base_commands.gd") fail(`${file}: no get_commands() found`);
    continue;
  }

  const regRe = /"([a-z_0-9]+)"\s*:\s*(_[A-Za-z_0-9]+)/g;
  let r;
  while ((r = regRe.exec(block)) !== null) {
    const [, tool, fn] = r;
    if (gdHandlers.has(tool)) {
      fail(`tool "${tool}" registered twice (${gdHandlers.get(tool).file} and ${file})`);
    }
    gdHandlers.set(tool, { fn, file });

    // the handler body must exist in the same file
    if (!new RegExp(`^func\\s+${fn}\\s*\\(`, "m").test(src)) {
      fail(`${file}: "${tool}" -> ${fn}() is registered but has no function body`);
    }
  }
}

/** Return the text of the get_commands() return dict, or null. */
function extractGetCommands(src) {
  const start = src.indexOf("func get_commands()");
  if (start === -1) return null;
  const open = src.indexOf("{", start);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  return null;
}

// ------------------------------------------------------------------ diff ----
const tsSet = new Set(tsTools);
const gdSet = new Set(gdHandlers.keys());

for (const t of [...tsSet].sort()) {
  if (!gdSet.has(t)) fail(`tool "${t}" is in the manifest but has NO GDScript handler (dead tool)`);
}
for (const t of [...gdSet].sort()) {
  if (!tsSet.has(t)) fail(`handler "${t}" exists in GDScript but is NOT exposed in the manifest (unreachable)`);
}

// the manifest's `method` must be what the router will look up
for (const [name, method] of tsMethods) {
  if (gdSet.has(method) === false && tsSet.has(name)) {
    fail(`tool "${name}" dispatches to method "${method}" which has no GDScript handler`);
  }
}

// ---------------------------------------------------------------- router ----
if (existsSync(ROUTER)) {
  const routerSrc = readFileSync(ROUTER, "utf8");
  const referenced = new Set();
  const modRe = /"res:\/\/addons\/godot_mcp\/commands\/([a-z_0-9]+\.gd)"/g;
  while ((m = modRe.exec(routerSrc)) !== null) referenced.add(m[1]);

  for (const f of referenced) {
    if (!gdFiles.includes(f)) fail(`command_router.gd references ${f} which does not exist on disk`);
  }
  for (const f of gdFiles) {
    if (f === "base_commands.gd") continue;
    if (!referenced.has(f)) fail(`${f} exists on disk but is NOT registered in command_router.gd (its tools will 404)`);
  }
} else {
  fail(`command_router.gd not found at ${ROUTER}`);
}

// ----------------------------------------------------------------- report ---
console.log(`manifest tools : ${tsTools.length}`);
console.log(`gd handlers    : ${gdHandlers.size}`);
console.log(`command modules: ${gdFiles.length - (gdFiles.includes("base_commands.gd") ? 1 : 0)}`);

if (problems.length) {
  console.error(`\n✗ parity check FAILED (${problems.length} problem${problems.length === 1 ? "" : "s"}):\n`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}

console.log("\n✓ parity check passed");
