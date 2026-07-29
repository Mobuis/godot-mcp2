# DECISIONS.md

Pre-made decisions for the hardening run. **A checkpoint is just a decision that
hasn't been made yet.** These were the three tasks that previously required the
agent to stop and ask. They are answered here so it never blocks.

The agent must treat these as binding and must not relitigate them.

---

## D-1 — `execute_editor_script`: **DELETE**

**Task:** T-106 · **Invariants:** INV-106, INV-107

Remove the tool entirely:
- delete `_execute_editor_script` and its registration from `addons/godot_mcp/commands/editor_commands.gd`
- delete the `execute_editor_script` entry from `server/src/tool-manifest.ts`
- remove the `Expression`-based `execute_script` branch from `addons/godot_mcp/services/mcp_runtime_bridge.gd`
- remove the `execute_game_script` tool that depends on it

**Rationale.** `Expression` in Godot 4 reaches global singletons, so `OS.execute(...)`
and `DirAccess` are plausibly in range — this is host command execution wearing a
smaller hat. The agent driving this MCP already has shell access through its own
client, so the tool adds no capability; what it *does* add is a path that bypasses
the client's tool-permission layer entirely. Net negative.

**Also note** the upstream description ("Run arbitrary GDScript in editor") was
already wrong — `Expression` is single-expression only, no `var`, no loops, no
multi-line. Deleting it removes a tool that would have burned agent turns anyway.

If a scripting escape hatch is ever needed, reintroduce it as a narrowly-typed
tool with an explicit allowlist of callable methods — not a general evaluator.

---

## D-2 — `set_auto_dismiss`: **DELETE**

**Task:** T-209 · **Invariant:** INV-209

Remove:
- the `set_auto_dismiss` tool from the manifest and `editor_commands.gd`
- `auto_dismiss_dialogs`, `_process()` and `_dismiss_dialogs()` from `addons/godot_mcp/plugin.gd`

**Rationale.** Two independent problems. It recurses the *entire* editor control
tree every frame while enabled, and — more importantly — it suppresses exactly the
confirmation dialogs that are the last line of defence when an agent is driving the
editor. Auto-dismissing safety prompts on behalf of an automated caller is the wrong
default in every scenario I can construct.

`plugin.gd` should have no `_process()` at all after this change.

---

## D-3 — Scope reduction: **CUT FOUR MODULES**

**Task:** T-301

Delete these command modules, their `COMMAND_MODULES` entries in
`command_router.gd`, and their `TOOL_DEFINITIONS` blocks:

| Module | Tools | Why |
|---|---|---|
| `android_commands.gd` | 4 | Removes the plugin's only `OS.execute` call site |
| `test_commands.gd` | 5 | Thin, unreliable, duplicates what a real test runner does |
| `export_commands.gd` | 3 | Only generates a command string; do exports from the CLI |
| `profiling_commands.gd` | 2 | Use Godot's own profiler |

Expected result: **173 → 159 tools**, and `check-parity.mjs` must still pass with
zero orphans in either direction.

Combined with D-1 (which removes `execute_editor_script` and `execute_game_script`)
and D-2 (`set_auto_dismiss`), the final count should be **156**.

**Rationale.** Every tool is attack surface and maintenance burden. These four are
the thinnest code in the repo and the least likely to be used in day-to-day Godot
work. This is a starting cut, not a final one — revisit after real use.

---

## Standing decisions

- **Do not add new features during this run.** Hardening only.
- **Do not reformat or rename anything** that a task does not require. With no
  pre-existing test coverage, every unrequested diff line is unreviewable noise.
- **T-401 (runtime IPC redesign) is OUT OF SCOPE** for the autonomous run. It is a
  design change requiring human sign-off, not an implementation task. Leave
  `T-206` (add request ids to the existing file IPC) as the interim fix.
- **If a task's premise looks wrong when the file is opened, stop and report.**
  Do not improvise a different fix.
