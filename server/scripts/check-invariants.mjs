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
    id: "INV-301",
    task: "0001",
    desc: "a handler that dies on a runtime error is reported as an error, not as success",
    check() {
      const src = read("addons/godot_mcp/command_router.gd");
      if (src === null) return "command_router.gd not found";
      // GDScript aborts a handler on a runtime error and hands back the return
      // type's default — {} for `-> Dictionary`. Without this guard that travels
      // out as a successful empty result, which is how every silent failure found
      // in Milestone 0a reached the caller.
      if (!/result\.has\("result"\)\s*or\s*result\.has\("error"\)/.test(src)) {
        return "execute() does not check that the handler returned a result/error shape";
      }
      if (!/-32001/.test(src)) return "no distinct error code for an aborted handler";
      return true;
    },
  },
  {
    id: "INV-302",
    task: "0001",
    desc: "reload_plugin (strips autoloads from project.godot, kills the connection) is not exposed",
    check() {
      const manifest = read("server/src/tool-manifest.ts");
      if (manifest && /"reload_plugin"/.test(manifest)) {
        return "reload_plugin still present in tool-manifest.ts";
      }
      const editor = read("addons/godot_mcp/commands/editor_commands.gd");
      if (editor && /set_plugin_enabled/.test(editor)) {
        return "editor_commands.gd still toggles the plugin, which rewrites project.godot";
      }
      return true;
    },
  },
  {
    id: "INV-303",
    task: "0001",
    desc: "watch_signals does not bind context arguments ahead of a signal's own payload",
    check() {
      const src = read("addons/godot_mcp/services/mcp_runtime_bridge.gd");
      if (src === null) return "mcp_runtime_bridge.gd not found";
      // Callable.bind() appends, so binding the emissions array placed it after
      // the signal's payload; every signal carrying a value was dropped while the
      // tool still reported success with count 0.
      if (/_on_signal_emitted\.bind\(/.test(src)) {
        return "signal capture still uses bind(), which puts the payload into the context parameters";
      }
      if (!/class SignalRecorder/.test(src)) {
        return "no SignalRecorder — signal context must be instance state, not bound arguments";
      }
      return true;
    },
  },
  {
    id: "INV-304",
    task: "0001",
    desc: "the editor log tools read the real Output dock rather than a buffer nothing writes",
    check() {
      const src = read("addons/godot_mcp/commands/editor_commands.gd");
      if (src === null) return "editor_commands.gd not found";
      if (/var _output_buffer/.test(src) && !/EditorLog/.test(src)) {
        return "still backed by _output_buffer, which had no writer — both tools always reported 'no errors'";
      }
      if (!/EditorLog/.test(src)) return "no EditorLog lookup — there is no other source for editor output";
      if (!/get_parsed_text/.test(src)) return "dock located but its text is never read";
      return true;
    },
  },
  {
    id: "INV-305",
    task: "property-tools",
    desc: "resource values load only project paths and create only Resource types",
    check() {
      const src = read("addons/godot_mcp/utils/property_access.gd");
      if (src === null) return "property_access.gd not found";
      // ResourceLoader.load() also accepts user:// and absolute paths.
      if (!/ResourceUtils\.normalize_res\(/.test(src)) {
        return "resource paths are loaded without normalize_res() — user:// and absolute paths escape the project";
      }
      if (!/is_parent_class\(class_id, "Resource"\)/.test(src)) {
        return "new:<ClassName> is not restricted to Resource types — any ClassDB class could be instantiated";
      }
      // str_to_var() can instantiate Objects and load Resources, so it may only
      // see text rebuilt from validated numbers.
      if (/str_to_var\(/.test(src) && !/_number_list\(/.test(src)) {
        return "str_to_var() is fed caller text instead of a type name and validated numbers";
      }
      return true;
    },
  },
  {
    id: "INV-306",
    task: "property-tools",
    desc: "no property tool can assign a script, in the editor or the running game",
    check() {
      const access = read("addons/godot_mcp/utils/property_access.gd");
      const bridge = read("addons/godot_mcp/services/mcp_runtime_bridge.gd");
      if (access === null) return "property_access.gd not found";
      // Assigning a script runs its code, like the removed execute_game_script.
      if (!/const REFUSED := \{[^}]*"script":/.test(access)) {
        return "property_access.gd REFUSED no longer lists `script`";
      }
      if (!/var refusal := refused\(property\)/.test(access)) {
        return "describe() no longer checks refused(), so property tools can write `script`";
      }
      if (bridge !== null && !/PropertyAccess\.touches_script\(/.test(bridge)) {
        return "set_node_property does not refuse the `script` property";
      }
      return true;
    },
  },
  {
    id: "INV-307",
    task: "input-waits",
    desc: "waiting input/reload tools are capped and stay under the server timeout",
    check() {
      const bridge = read("addons/godot_mcp/services/mcp_input_bridge.gd");
      const cmds = read(`${CMD_DIR}/input_commands.gd`);
      const editor = read(`${CMD_DIR}/editor_commands.gd`);
      if (bridge === null || cmds === null || editor === null) return null;
      for (const c of ["MAX_EVENTS", "MAX_FRAMES", "MAX_DELAY_MS", "MAX_TOTAL_DELAY_MS", "MAX_TOTAL_FRAMES"]) {
        if (!new RegExp(`const ${c} :=`).test(bridge)) return `mcp_input_bridge.gd lost the ${c} cap`;
        if (!new RegExp(`InputBridge\\.${c}`).test(cmds)) return `input_commands.gd does not enforce ${c}`;
      }
      // The wait deadlines must be real-time and below the server's 45 s default.
      for (const [src, name, re] of [
        [cmds, "input_commands.gd ACK_DEADLINE_SEC", /const ACK_DEADLINE_SEC := (\d+(?:\.\d+)?)/],
        [editor, "editor_commands.gd RELOAD_DEADLINE_SEC", /const RELOAD_DEADLINE_SEC := (\d+(?:\.\d+)?)/],
      ]) {
        const m = src.match(re);
        if (!m) return `${name} not found`;
        if (Number(m[1]) >= 45) return `${name} is ${m[1]} s, not below the server's 45 s timeout`;
      }
      if (!/is_playing_scene\(\)/.test(cmds)) return "simulate_* no longer refuse to queue when the game is not running";
      if (!/_is_safe_id\(/.test(bridge)) return "the input ack/batch file names are built from an unchecked id";
      if (!/const MAX_PENDING_BATCHES :=/.test(bridge) || !/MAX_PENDING_BATCHES/.test(cmds)) {
        return "the number of pending input batches is no longer limited";
      }
      // One file per batch, published by rename: a shared read-modify-write
      // queue file loses or duplicates batches.
      if (!/rename_absolute\(/.test(cmds)) return "input batches are not published atomically (temp file + rename)";
      if (/mcp_input_queue\.json/.test(bridge) || /mcp_input_queue\.json/.test(cmds)) return "a shared input queue file is back";
      if (!/is_finite\(/.test(cmds) || !/is_finite\(/.test(bridge)) return "input caps are checked without rejecting non-finite/huge numbers first";
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
