#!/usr/bin/env node
/**
 * check-invariants.mjs — security & robustness regression locks.
 *
 * Each invariant corresponds to a task ID in HARDENING-PLAN.md and encodes the
 * *property* that task establishes, so it cannot silently regress later.
 *
 * IMPORTANT — these are greps, not proofs. They are cheap regression locks that
 * catch "someone deleted the guard", not formal verification. Do not mistake a
 * green run for a security audit. If you change how a fix is implemented, update
 * the corresponding invariant rather than deleting it.
 *
 * Expected state on the UNPATCHED upstream commit: most of these FAIL. That is
 * correct — that is the red state the hardening work turns green.
 *
 * Usage:
 *   node server/scripts/check-invariants.mjs           # enforce
 *   node server/scripts/check-invariants.mjs --report   # list status, exit 0
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const REPORT_ONLY = process.argv.includes("--report");

const read = (p) => (existsSync(join(REPO, p)) ? readFileSync(join(REPO, p), "utf8") : null);
const exists = (p) => existsSync(join(REPO, p));

const SERVICES = ["mcp_runtime_bridge.gd", "mcp_input_bridge.gd", "mcp_screenshot_bridge.gd"];
const CMD_DIR = "addons/godot_mcp/commands";

/**
 * Each check returns:
 *   true            -> pass
 *   string          -> fail, with reason
 *   null            -> not applicable (e.g. file intentionally deleted)
 */
const INVARIANTS = [
  {
    id: "INV-101",
    task: "T-101",
    desc: "runtime service autoloads refuse to run outside the editor",
    check() {
      const missing = [];
      for (const f of SERVICES) {
        const src = read(`addons/godot_mcp/services/${f}`);
        if (src === null) continue; // deleted is also safe
        if (!/OS\.has_feature\(\s*["']editor["']\s*\)/.test(src)) missing.push(f);
        if (/OS\.is_debug_build\(\)/.test(src)) {
          return `${f} uses OS.is_debug_build() — wrong guard, still active in debug exports`;
        }
      }
      return missing.length === 0
        ? true
        : `missing OS.has_feature("editor") guard in: ${missing.join(", ")}`;
    },
  },
  {
    id: "INV-102",
    task: "T-102",
    desc: "autoload removal does not rely on in-memory session state alone",
    check() {
      const src = read("addons/godot_mcp/plugin.gd");
      if (src === null) return "plugin.gd not found";
      const fn = src.slice(src.indexOf("func _remove_autoloads"));
      if (!fn) return "_remove_autoloads() not found";
      const body = fn.slice(0, fn.indexOf("\n\n\nfunc ") === -1 ? fn.length : fn.indexOf("\n\n\nfunc "));
      if (/for\s+\w+\s+in\s+_injected/.test(body) && !/AUTOLOADS/.test(body)) {
        return "_remove_autoloads() iterates only _injected (in-memory); autoloads persist after editor restart";
      }
      return true;
    },
  },
  {
    id: "INV-103",
    task: "T-103",
    desc: "WebSocket server rejects browser-originated connections",
    check() {
      const src = read("server/src/godot-bridge.ts");
      if (src === null) return "godot-bridge.ts not found";
      if (!/host:\s*["']127\.0\.0\.1["']/.test(src)) return "server is not bound to 127.0.0.1";
      if (!/verifyClient/.test(src)) return "no verifyClient — any web page can connect to the loopback port";
      return true;
    },
  },
  {
    id: "INV-104",
    task: "T-104",
    desc: "path normalisation rejects parent-directory traversal",
    check() {
      const util = read("addons/godot_mcp/utils/resource_utils.gd");
      if (util === null) return "resource_utils.gd not found";
      const fn = util.slice(util.indexOf("static func normalize_res"));
      const body = fn.slice(0, fn.indexOf("\n\n"));
      if (!/\.\./.test(body)) return 'normalize_res() does not reject ".."';

      // script_commands.gd builds res:// paths inline without calling normalize_res
      const sc = read(`${CMD_DIR}/script_commands.gd`);
      if (sc !== null) {
        const inlineBuilds = (sc.match(/"res:\/\/"\s*\+\s*\w+\.trim_prefix/g) || []).length;
        const guards = (sc.match(/\.\.\s*(?:in|not in)\s|contains\(\s*["']\.\.["']\s*\)/g) || []).length;
        if (inlineBuilds > 0 && guards === 0) {
          return `script_commands.gd builds res:// paths inline (${inlineBuilds}x) with no ".." guard`;
        }
      }
      return true;
    },
  },
  {
    id: "INV-105",
    task: "T-105",
    desc: "every remove_absolute() call site is confined to the project directory",
    check() {
      if (!exists(CMD_DIR)) return "commands dir not found";
      const offenders = [];
      for (const f of readdirSync(join(REPO, CMD_DIR)).filter((x) => x.endsWith(".gd"))) {
        const src = readFileSync(join(REPO, CMD_DIR, f), "utf8");
        const lines = src.split("\n");
        lines.forEach((line, i) => {
          if (!/DirAccess\.remove_absolute\(/.test(line)) return;
          // Only user-supplied paths are dangerous. A remove_absolute() whose
          // argument is derived from globalize_path() is by definition operating
          // on a caller-controlled path. Removals of fixed user:// IPC filenames
          // (base_commands.gd, the service bridges) are not user-controlled and
          // are deliberately not flagged.
          if (!/globalize_path/.test(line)) return;
          const window = lines.slice(Math.max(0, i - 15), i).join("\n");
          const confined =
            /begins_with\(\s*ProjectSettings\.globalize_path/.test(window) ||
            /_is_inside_project|_assert_in_project|_confine/.test(window);
          if (!confined) offenders.push(`${f}:${i + 1}`);
        });
      }
      return offenders.length === 0
        ? true
        : `unconfined remove_absolute() at: ${offenders.join(", ")}`;
    },
  },
  {
    id: "INV-106",
    task: "T-106",
    desc: "execute_editor_script is not exposed (DECISIONS.md: delete)",
    check() {
      const manifest = read("server/src/tool-manifest.ts");
      if (manifest && /"execute_editor_script"/.test(manifest)) {
        return "execute_editor_script still present in tool-manifest.ts";
      }
      const ed = read(`${CMD_DIR}/editor_commands.gd`);
      if (ed && /"execute_editor_script"\s*:/.test(ed)) {
        return "execute_editor_script still registered in editor_commands.gd";
      }
      return true;
    },
  },
  {
    id: "INV-107",
    task: "T-106",
    desc: "no Expression-based code execution remains in the plugin",
    check() {
      const hits = [];
      for (const dir of [CMD_DIR, "addons/godot_mcp/services"]) {
        if (!exists(dir)) continue;
        for (const f of readdirSync(join(REPO, dir)).filter((x) => x.endsWith(".gd"))) {
          const src = readFileSync(join(REPO, dir, f), "utf8");
          if (/Expression\.new\(\)/.test(src)) hits.push(`${dir}/${f}`);
        }
      }
      return hits.length === 0 ? true : `Expression.new() still present in: ${hits.join(", ")}`;
    },
  },
  {
    id: "INV-201",
    task: "T-201",
    desc: "a closing stale socket does not reject the live connection's pending requests",
    check() {
      const src = read("server/src/godot-bridge.ts");
      if (src === null) return "godot-bridge.ts not found";
      const closeIdx = src.indexOf('ws.on("close"');
      if (closeIdx === -1) return 'no ws.on("close") handler found';
      const handler = src.slice(closeIdx, closeIdx + 500);
      const guardIdx = handler.indexOf("this.client === ws");
      const rejectIdx = handler.indexOf("this.rejectAll");
      if (guardIdx === -1) return "close handler has no `this.client === ws` guard";
      if (rejectIdx === -1) return true; // rejectAll removed entirely is acceptable
      // crude brace-depth test: rejectAll must sit inside the guard block
      const between = handler.slice(guardIdx, rejectIdx);
      const opens = (between.match(/\{/g) || []).length;
      const closes = (between.match(/\}/g) || []).length;
      return opens > closes ? true : "rejectAll() is outside the `this.client === ws` guard";
    },
  },
  {
    id: "INV-202",
    task: "T-202",
    desc: "WebSocket server error (e.g. EADDRINUSE) is handled, not fatal",
    check() {
      const src = read("server/src/godot-bridge.ts");
      if (src === null) return "godot-bridge.ts not found";
      return /wss\??\.on\(\s*["']error["']/.test(src)
        ? true
        : "no wss.on('error') handler — port already in use crashes the MCP server at startup";
    },
  },
  {
    id: "INV-203",
    task: "T-203",
    desc: "request timeout is configurable via environment",
    check() {
      const src = read("server/src/godot-bridge.ts");
      if (src === null) return "godot-bridge.ts not found";
      return /GODOT_MCP_TIMEOUT_MS/.test(src)
        ? true
        : "timeout is hardcoded; slow tools (deploy_to_android, bake_navigation_mesh) will always time out";
    },
  },
  {
    id: "INV-204",
    task: "T-204",
    desc: "heartbeat detects dead peers rather than only keeping alive",
    check() {
      const src = read("server/src/godot-bridge.ts");
      if (src === null) return "godot-bridge.ts not found";
      const hasLiveness = /isAlive|lastPong|missedPong/.test(src);
      const terminates = /\.terminate\(\)/.test(src);
      if (!hasLiveness) return "no liveness flag — pong is received but never acted upon";
      if (!terminates) return "liveness tracked but socket is never terminated";
      return true;
    },
  },
  {
    id: "INV-209",
    task: "T-209",
    desc: "set_auto_dismiss (suppresses editor confirmation dialogs) is not exposed",
    check() {
      const manifest = read("server/src/tool-manifest.ts");
      if (manifest && /"set_auto_dismiss"/.test(manifest)) {
        return "set_auto_dismiss still present in tool-manifest.ts";
      }
      const plugin = read("addons/godot_mcp/plugin.gd");
      if (plugin && /_dismiss_dialogs/.test(plugin)) {
        return "plugin.gd still contains the per-frame dialog-dismissal tree walk";
      }
      return true;
    },
  },
  {
    id: "INV-501",
    task: "T-506",
    desc: "commit.bat (blanket `git add .` + fixed message) is removed",
    check() {
      return exists("commit.bat") ? "commit.bat still present" : true;
    },
  },
  {
    id: "INV-502",
    task: "T-502",
    desc: "upstream's compare-tools.mjs (hardcoded commercial 'pro' tool list) is removed",
    check() {
      return exists("server/scripts/compare-tools.mjs") ? "compare-tools.mjs still present" : true;
    },
  },
];

// ------------------------------------------------------------------ run -----
let failed = 0;
let passed = 0;

console.log("security & robustness invariants\n");
for (const inv of INVARIANTS) {
  let result;
  try {
    result = inv.check();
  } catch (e) {
    result = `check threw: ${e.message}`;
  }
  if (result === true) {
    passed++;
    console.log(`  ✓ ${inv.id} [${inv.task}] ${inv.desc}`);
  } else if (result === null) {
    console.log(`  – ${inv.id} [${inv.task}] n/a`);
  } else {
    failed++;
    console.log(`  ✗ ${inv.id} [${inv.task}] ${inv.desc}`);
    console.log(`      ${result}`);
  }
}

console.log(`\n${passed} passed, ${failed} failed, ${INVARIANTS.length} total`);

if (failed > 0 && !REPORT_ONLY) {
  console.error("\ninvariant check FAILED");
  process.exit(1);
}
