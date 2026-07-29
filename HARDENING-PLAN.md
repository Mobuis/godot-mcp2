# godot-mcp — Fork Hardening & Readiness Plan

**Base:** fork of `mkdevkit/godot-mcp` @ `328e15f` (4 commits, MIT)
**Goal:** make this safe and reliable enough for daily Godot 4.4+ development driven by an AI agent.
**Audience:** an AI coding agent executing tasks, with a human reviewing between phases.

---

## 0. Rules for the executing agent

Read this section before doing anything.

1. **Do not run the MCP server or enable the Godot plugin until Phase 1 is complete and human-verified.** The unpatched code has an unauthenticated local WebSocket and no path-traversal guards.
2. **Disable the `godot-mcp` MCP server in your own client while working on this repo.** You are editing the tool that would be calling you. Circular. Turn it off.
3. **Work one phase at a time. Stop at each `HUMAN CHECKPOINT` and wait.** Do not batch phases.
4. **One commit per task ID**, message format: `[T-ID] short description`. This keeps `git bisect` useful, because there is no test suite to catch you.
5. **You cannot verify GDScript changes.** You have no Godot editor. For any task marked `VERIFY: human`, make the change, state precisely what you changed, and stop. Do not claim it works.
6. **Do not refactor opportunistically.** No renaming, no reformatting, no "while I was here." Every unrequested diff line is unreviewable noise in a codebase with zero tests.
7. **If a task's premise looks wrong when you open the file, stop and report.** Line numbers below are from commit `328e15f` and may have drifted.

---

## Phase 1 — Security (BLOCKING: complete before first run)

### T-101 — Stop the runtime bridges from shipping in exported games
**Files:** `addons/godot_mcp/services/mcp_runtime_bridge.gd`, `mcp_input_bridge.gd`, `mcp_screenshot_bridge.gd`
**Severity:** Critical — affects end users of any game built with the plugin enabled.

**Problem.** All three are autoloads injected into `project.godot`. `mcp_runtime_bridge.gd` polls `user://mcp_runtime_req.json` every frame and executes its contents via `Expression`. `mcp_input_bridge.gd` injects synthetic `InputEventKey`/`InputEventMouseButton` from a file and has no environment guard at all. The existing `if Engine.is_editor_hint(): return` is inverted for this purpose — it disables the bridge in the editor and *enables* it in the running game, including exported builds.

**Fix.** Add to each of the three files:

```gdscript
func _ready() -> void:
	if not OS.has_feature("editor"):
		queue_free()
```

Use `has_feature("editor")`, **not** `OS.is_debug_build()`. The `editor` feature tag is present when running from the editor including play-from-editor (so runtime tools keep working) and absent in every export, debug or release. `is_debug_build()` would leave the bridge active in debug exports.

Leave the existing `Engine.is_editor_hint()` checks alone — they serve a different purpose (editor vs game process).

**VERIFY: human** — export a debug build, confirm the `[autoload]` entries either do not run or are absent, and confirm runtime tools still work when playing from the editor.

---

### T-102 — Fix the autoload cleanup bug
**File:** `addons/godot_mcp/plugin.gd`
**Severity:** Critical — this is what makes T-101 happen by default rather than by accident.

**Problem.** `_inject_autoloads()` only appends to `_injected` when the setting did *not* already exist:

```gdscript
if not ProjectSettings.has_setting(key):
    ProjectSettings.set_setting(key, "*" + script)
    _injected.append(key)
```

`_injected` is in-memory and rebuilt each `_enter_tree()`. On the second and every subsequent editor session the settings already exist in `project.godot`, so nothing is appended, and `_exit_tree()` removes nothing. Disabling the plugin after an editor restart silently leaves all three autoloads permanently in the project file. The README's claim that they are removed on disable is only true for the first session.

**Fix.** Track ownership persistently rather than by in-memory session state. Either:
- (preferred) always remove the three known `AUTOLOADS` keys in `_exit_tree()` if their value matches the plugin's own script path, or
- write a marker setting (e.g. `mcp/injected_autoloads`) to `project.godot` and read it back on `_enter_tree()`.

Do not simply always-remove without checking the value — a user may legitimately have their own autoload at that name.

**VERIFY: human** — enable plugin, restart editor, disable plugin, inspect `project.godot` for `[autoload]` entries.

---

### T-103 — Reject browser-originated WebSocket connections
**File:** `server/src/godot-bridge.ts`
**Severity:** High — this is the only finding that grants a *remote* party a foothold.

**Problem.** `WebSocketServer` is correctly bound to `127.0.0.1`, but there is no authentication and no `Origin` check, and the connection handler unconditionally promotes any new socket to the active client:

```typescript
this.wss.on("connection", (ws) => {
  this.client = ws;   // last connection wins
```

Browsers do not apply CORS to WebSocket handshakes. Any web page open in a browser can connect to `ws://127.0.0.1:6505`, reconnect in a loop until it wins the race against the Godot plugin's reconnect backoff, and then receive every subsequent tool call and return **forged results to the AI agent** — an indirect prompt-injection channel into an agent holding 173 tools.

**Fix (minimum).**

```typescript
this.wss = new WebSocketServer({
  port: this.port,
  host: "127.0.0.1",
  verifyClient: (info) => !info.origin,
});
```

Browsers are required to send `Origin` on WebSocket handshakes; Godot's `WebSocketPeer` does not add one by default.

**Fix (preferred, if T-401 is in scope).** Shared token: read `GODOT_MCP_TOKEN` from env, require it as a query param, reject on mismatch. Godot side appends `?token=...` in `websocket_client.gd::_try_connect()`. Keep the `!info.origin` check as well.

**VERIFY: agent** — start the server, confirm a Node `ws` client with an `Origin` header is rejected and one without is accepted.
**VERIFY: human** — confirm the Godot plugin still connects. If it does not, Godot is sending an `Origin` header on your version; switch to the token approach.

---

### T-104 — Reject path traversal
**Files:** `addons/godot_mcp/utils/resource_utils.gd`, `addons/godot_mcp/commands/script_commands.gd`
**Severity:** High

**Problem.** `normalize_res()` is the only path guard in the codebase and it does exactly one thing — prepend `res://` if absent. It never rejects `..`. Several call sites then globalize the result, which escapes any `res://` sandbox:

- `resource_utils.gd:22` — `DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(p.get_base_dir()))`
- `script_commands.gd:69` — same pattern
- `scene_commands.gd:120` — `DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))`

**Fix.** In `resource_utils.gd`:

```gdscript
static func normalize_res(path: String) -> String:
	if path.is_empty() or ".." in path:
		return ""
	if path.begins_with("res://"):
		return path
	return "res://" + path.trim_prefix("/")
```

`_create_script` (lines ~63-64) and `_edit_script` (lines ~86-87) in `script_commands.gd` **do not call `normalize_res`** — they inline their own `res://` prepending. Add the same `".." in path` rejection there, or better, replace the inline logic with a call to `normalize_res`.

Then audit every caller for empty-string handling: several currently assume a non-empty return.

**VERIFY: agent** — grep to confirm no remaining code path builds a `res://` string without the guard.

---

### T-105 — Confine `delete_scene`
**File:** `addons/godot_mcp/commands/scene_commands.gd:114-121`
**Severity:** High

**Problem.** No extension check and no project confinement. Combined with T-104 this is an arbitrary-file-delete primitive.

**Fix.** After normalization, require the resolved absolute path to start with `ProjectSettings.globalize_path("res://")`, and require a `.tscn` or `.scn` extension. Reject otherwise with a clear error.

Apply the same confinement check to any other handler that calls `remove_absolute` on a user-supplied path.

**VERIFY: agent** — code review; **human** — try deleting a file outside the project and confirm rejection.

---

### T-106 — Decide the policy on `execute_editor_script`
**File:** `addons/godot_mcp/commands/editor_commands.gd:55-69`
**Severity:** Medium-High — **decision required, do not implement unilaterally**

`Expression` in Godot 4 can reach global singletons, so `OS.execute(...)` and `DirAccess` are plausibly in range. Treat this as host command execution regardless of the "just an expression" framing.

Options, in order of preference:
1. Delete the tool entirely (also remove from `TOOL_DEFINITIONS`). You almost certainly do not need it.
2. Keep it behind an opt-in env var, default off.
3. Keep it, and deny it at the MCP client's tool-permission layer.

**Agent: stop and ask the human which option.** Do not pick one.

---

### 🛑 HUMAN CHECKPOINT 1
Review all Phase 1 diffs. Only after this may the plugin be enabled and the server run for the first time. Do this against a **throwaway Godot project**, not real work.

---

## Phase 2 — Correctness & robustness

### T-201 — `rejectAll` fires for any closing socket
**File:** `server/src/godot-bridge.ts`

`rejectAll()` sits outside the `if (this.client === ws)` guard, so a stale or hijacked socket closing kills all in-flight requests on the live connection. Move it inside the guard.

### T-202 — Unhandled server error crashes the process
**File:** `server/src/godot-bridge.ts`

There is no `this.wss.on("error", ...)` handler. `EADDRINUSE` (a second Godot project, or a stale server) produces an unhandled error and the MCP server dies at startup. Add a handler that logs to `console.error` and reports a clear "port 6505 already in use" message.

### T-203 — Request timeout is too short and not configurable
**File:** `server/src/godot-bridge.ts`

`REQUEST_TIMEOUT_MS = 30_000` is global. `deploy_to_android` runs a full headless export *plus* `adb install` and will essentially always time out; `bake_navigation_mesh` and `run_stress_test` are also at risk. Make it configurable via `GODOT_MCP_TIMEOUT_MS`, raise the default, and allow a per-tool override in `TOOL_DEFINITIONS` for the known-slow tools.

Note that on timeout the request is dropped client-side but Godot keeps executing it. There is no cancellation. Document this; do not attempt to fix it here.

### T-204 — Heartbeat does not detect dead peers
**File:** `server/src/godot-bridge.ts`

The interval sends `ping` and `onMessage` ignores `pong` (`if (msg.method === "pong") return;`). There is no liveness tracking. Add an `isAlive` flag set on `pong`, cleared before each `ping`, and terminate the socket if a cycle passes without a response.

### T-205 — `pending.set` happens after `send`
**File:** `server/src/godot-bridge.ts`

In `call()`, `this.client.send(message)` runs before the `Promise` executor registers the pending entry. Safe in practice because Node cannot deliver the response within the same synchronous block, but it is fragile. Register the pending entry first, then send.

### T-206 — File IPC has no request correlation
**Files:** `addons/godot_mcp/commands/base_commands.gd`, `services/mcp_runtime_bridge.gd`, `services/mcp_screenshot_bridge.gd`

`_runtime_call()` and `_request_screenshot()` both write to a single fixed filename (`mcp_runtime_req.json`, `mcp_screenshot_req.json`). MCP clients routinely issue tool calls in parallel — two concurrent runtime calls overwrite each other's request file and can read each other's response. This surfaces as Godot returning *wrong data*, not as a clean error, which is the worst failure mode to debug.

**Minimum fix here:** add a `request_id` to the request/response payloads and have the caller discard responses whose id does not match.
**Proper fix:** T-401. If T-401 is in scope, skip this task.

### T-207 — Tool description does not match implementation
**File:** `server/src/tool-manifest.ts`

`execute_editor_script` is described as "Run arbitrary GDScript in editor". It uses `Expression`, which is single-expression only — no `var`, no multi-line, no loops. An agent will waste turns on failed calls. Correct the description. (Skip if T-106 resolves to deletion.)

### T-208 — Manifest drift
**File:** `server/src/tool-manifest.ts`

`_deploy_to_android` reads `device_id` and `launch` from params but neither is declared in the manifest, so no agent can reach them. Add them.

### T-209 — `set_auto_dismiss` is a footgun
**File:** `addons/godot_mcp/plugin.gd`

When enabled, `_process` walks the *entire* editor control tree every frame hiding every visible `AcceptDialog`. Two problems: per-frame full-tree recursion, and it suppresses exactly the confirmation prompts that would otherwise catch a destructive agent action.

Recommend removing the tool. If kept, add an auto-expiry (e.g. disables itself after N seconds) and throttle the tree walk to a timer rather than `_process`.

**Agent: propose, do not decide.**

### 🛑 HUMAN CHECKPOINT 2

---

## Phase 3 — Scope reduction

### T-301 — Cut unused tool categories
173 tools is a large attack surface and maintenance burden for features you will never call. Cutting to the 40–60 you actually use makes the codebase auditable in an afternoon.

Removal is mechanical:
1. Delete the module from `addons/godot_mcp/commands/`
2. Remove its path from `COMMAND_MODULES` in `command_router.gd`
3. Remove its block from `TOOL_DEFINITIONS` in `server/src/tool-manifest.ts`
4. Rebuild

**Recommended first cuts** (thinnest code, least likely to be needed): `android_commands.gd`, `test_commands.gd`, `export_commands.gd`, `profiling_commands.gd`. Removing `android_commands.gd` also eliminates the only `OS.execute` call site in the plugin.

**Agent: produce the list of candidate cuts with tool names and wait for human selection. Do not delete anything unprompted.**

---

## Phase 4 — Runtime transport redesign (optional, highest value)

### T-401 — Replace file-polling IPC with a second WebSocket client
**Scope:** ~150 lines. This is a design change, not a patch. **Requires human design sign-off before implementation.**

The file-based IPC is the weakest part of the codebase and the part you will spend the most debugging time in. Current design: fixed filenames, no request ids, per-frame `FileAccess.file_exists` polling in both the editor and the running game.

**Proposed replacement.** The game process opens its own `WebSocketPeer` to the same Node server on startup, identifying itself with a role tag (`editor` vs `game`). `GodotBridge` tracks two clients instead of one and routes by role. Runtime tools then travel over real JSON-RPC with proper ids.

Gains: request correlation for free, no polling, no fixed-filename races, no per-frame syscall, and the three `user://` bridge files disappear entirely. It also makes `this.client = ws` (T-103) into a proper registry rather than last-write-wins.

Still requires T-101 — the game-side client must not exist in exported builds.

---

## Phase 5 — Project hygiene

### T-501 — Manifest/handler parity check (do this one first in Phase 5)
There are zero tests. This is the single highest-value automatable check, because the manifest and the GDScript handlers are maintained by hand in two places and will drift.

Write `server/scripts/check-parity.mjs` that:
1. Imports `TOOL_DEFINITIONS`
2. Scans `addons/godot_mcp/commands/*.gd` for handler registrations of the form `"tool_name": _handler_fn`
3. Confirms every manifest tool has a registration, every registration has a manifest entry, and every referenced `_handler_fn` has a matching `func _handler_fn(` definition
4. Exits non-zero on any mismatch

At the base commit this passes cleanly (173/173, no orphans either direction) — so any failure is a regression you introduced.

Wire it into `npm run build` as a prebuild step.

### T-502 — Delete `server/scripts/compare-tools.mjs`
It contains a hardcoded list of 173 tool names labelled `pro`, diffing this repo against a commercial product's feature list. It has no function in your fork.

### T-503 — CI
`.github/` currently contains only `FUNDING.yml`. Add a workflow running `npm ci`, `tsc --noEmit`, and `check-parity.mjs` on push and PR. Also add a GDScript syntax check if `godot --headless --check-only` is available in CI.

### T-504 — Fix the README
Known false or stale claims to correct:
- The "Example project" section references an `example/` directory that **does not exist** — it is listed in `.gitignore`. Usage step 5 is broken. Either remove the section or actually add the demo project.
- The autoload claim ("they are removed when the plugin is disabled") is false until T-102 lands.
- Category counts are wrong in both the README table and the `tool-manifest.ts` section comments: Scene says 9 / has 10, Editor says 9 / has 13, Testing-QA says 6 / has 5, Android says 3 / has 4.
- Document the new `GODOT_MCP_TOKEN` / `GODOT_MCP_TIMEOUT_MS` env vars.

### T-505 — Add `SECURITY.md` and a threat-model note
Record explicitly, for your future self: the WebSocket is loopback-only and token-gated; the plugin must never ship in exported builds; `execute_editor_script` policy per T-106.

### T-506 — Delete `commit.bat`
`git add . && git commit -m "#0 godot-mcp change" && git push origin master`. Blanket-add with a fixed message is how credentials and local paths leak into public history. Nothing leaked in the 4 upstream commits, but do not inherit the practice.

---

## Task summary

| Phase | Tasks | Verifiable by agent? | Est. |
|---|---|---|---|
| 1 — Security (blocking) | T-101 … T-106 | Partly — GDScript needs human | ~2h + testing |
| 2 — Correctness | T-201 … T-209 | Mostly yes (TypeScript) | ~3h |
| 3 — Scope reduction | T-301 | Mechanical, human selects | ~1h |
| 4 — Runtime redesign | T-401 | No — design sign-off first | ~1 day |
| 5 — Hygiene | T-501 … T-506 | Yes | ~2h |

**Minimum viable for daily dev:** Phase 1 + T-201, T-202, T-203, T-501.
**Do not skip:** T-101 and T-102. They are the only ones whose failure mode reaches people other than you.

---

## What the agent must NOT do

- Do not run the Godot editor or the MCP server before HUMAN CHECKPOINT 1.
- Do not enable the `godot-mcp` MCP connector in its own client while editing this repo.
- Do not decide T-106, T-209, or T-301 — surface options and wait.
- Do not "improve" `websocket_client.gd`'s reconnect/backoff logic. It is correct and it is the only thing keeping the editor connection alive during your edits.
- Do not claim any GDScript change is tested. You cannot run Godot.
- Do not squash the phases into one commit.