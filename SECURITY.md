# SECURITY.md

Threat model and standing security decisions for this fork of
[`mkdevkit/godot-mcp`](https://github.com/mkdevkit/godot-mcp).

This is a note to my future self, not a policy for third parties. It records
what is defended, what is not, and why — so that a later change that quietly
removes a guard is recognisable as a regression rather than a cleanup.

---

## What this thing is

An MCP server that hands an AI agent 156 tools for driving the Godot 4 editor.
Two processes, two channels:

```
AI client  ←—stdio—→  Node.js server  ←—WebSocket 127.0.0.1:6505—→  Godot editor plugin
                                                                          ↕
                                                          user:// file IPC to the game process
```

The agent on the other end of stdio is the thing being trusted. Everything else
is treated as reachable by something that is not.

---

## Standing decisions

### The WebSocket is loopback-only and origin-gated

`GodotBridge` binds to `127.0.0.1` and rejects any handshake that carries an
`Origin` header. Browsers are required to send `Origin` on a WebSocket
handshake; Godot's `WebSocketPeer` does not. This is what keeps an arbitrary
web page you have open from connecting to the port.

A second connection cannot displace a healthy existing client. The upstream
`this.client = ws` was last-write-wins, which meant anything that could complete
a handshake could win the reconnect race and start returning **forged tool
results to the agent** — a prompt-injection channel into a process holding 156
tools.

**Not defended:** any local process that can open a socket without an `Origin`
header and win the race while no client is attached. There is no token, so
loopback access is authorisation. If you need more than that, the fix is a
shared secret in `GODOT_MCP_TOKEN` checked as a query parameter, with the Godot
side appending it in `websocket_client.gd::_try_connect()`. Keep the `Origin`
check as well; do not replace it.

### The plugin must never ship in an exported build

All three runtime services are autoloads written into `project.godot`, so a
build made while the plugin is enabled would carry them into the shipped game.
`mcp_runtime_bridge.gd` polls a `user://` file every frame and acts on its
contents; `mcp_input_bridge.gd` injects synthetic input events from a file.
In an exported game, that is a remote-ish control channel for anyone who can
write to the user data directory.

Each of the three frees itself in `_ready()` unless `OS.has_feature("editor")`.

Use `has_feature("editor")`, **not** `OS.is_debug_build()`. The `editor` tag is
present for play-from-editor (so runtime tools keep working) and absent in every
export. `is_debug_build()` would leave the bridges live in debug exports.

Disabling the plugin also removes the autoload entries again — but only entries
whose value still points at this plugin's own script, so an autoload you
registered yourself under the same name survives.

### No arbitrary code execution — `execute_editor_script` is gone

Deleted, along with `execute_game_script` and the `Expression`-based
`execute_script` branch in the runtime bridge.

`Expression` in Godot 4 reaches global singletons, so `OS.execute(...)` and
`DirAccess` are plausibly in range. That is host command execution wearing a
smaller hat. The agent driving this MCP already has shell access through its own
client, so the tool granted no new capability; what it did add was a path that
bypasses the client's tool-permission layer entirely.

If a scripting escape hatch is ever genuinely needed, reintroduce it as a
narrowly-typed tool with an explicit allowlist of callable methods. Not a
general evaluator.

### Paths are confined to the project

`normalize_res()` returns `""` for any path that is empty or contains `..`, and
callers treat `""` as rejected. This matters because several call sites
globalize the result, which would otherwise escape `res://` entirely.

`delete_scene` additionally requires a `.tscn`/`.scn` extension and requires the
resolved absolute path to sit inside `globalize_path("res://")`. It is the only
`remove_absolute()` call site that takes a caller-supplied path; the rest operate
on fixed `user://` IPC filenames.

**Not defended:** symlinks inside the project pointing out of it. The check is
prefix-based on the globalized path.

### Property values cannot load or run code from outside the project

Property tools (`update_property`, `set_game_node_property`, `edit_resource`,
the batch tools) parse values against the property's declared type in
`utils/property_access.gd`. Three rules keep that from widening the surface:

- A resource value is a `res://` path, a `uid://` id or `new:<ClassName>`.
  Paths go through `normalize_res()`, and any other scheme (`user://`, `file://`)
  is refused, because `ResourceLoader.load()` accepts absolute and `user://`
  paths too.
- `new:<ClassName>` creates only `Resource` types, engine or script classes.
  Anything else in `ClassDB` could otherwise be instantiated by name.
- Built-in types are never parsed with `str_to_var()` unless the text names that
  exact type and contains no `Object(`/`Resource(`: `str_to_var()` instantiates
  objects and loads resources. Arrays and dictionaries are parsed as JSON.

Every property tool, in the editor and in the running game, refuses a path with
a `script` segment. Assigning a script runs its code, which is the path D-1
closed by deleting `execute_game_script`. The editor attaches scripts only
through `attach_script`, where the client's permission layer sees it. A
`resource_path` segment is refused too: rewriting it makes the editor save the
resource over another file.

INV-305 and INV-306 lock these.

### Waiting tools are capped

`simulate_*` and `reload_project` wait for their effect. A server-side timeout
does not cancel work in Godot, so every wait has a cap: per-event and total
delays and frames in `mcp_input_bridge.gd`, checked before anything is queued,
and real-time deadlines below the server's 45 s timeout. The input ack file name
is built only from an id the bridge has validated. INV-307 locks this.

The caps bound one call, not the queue. Up to about 17 batches can be accepted
(8 on disk, 8 read by the game, 1 running), so `wait: false` calls can keep a
game busy for a few minutes; `stop_scene` ends it. A frame cap is not a time
cap either: at 30 fps a batch within the caps can outlast the 30 s wait, and
the caller then gets an error while the events still play.

### Confirmation dialogs are not suppressed

`set_auto_dismiss` is gone. It walked the entire editor control tree every frame
hiding every visible `AcceptDialog` — which meant it suppressed exactly the
confirmation prompts that are the last line of defence when an agent is driving
the editor. `plugin.gd` has no `_process()` at all now.

### Tool surface is deliberately small

156 tools, down from 173. Android, export, profiling and test modules are gone;
removing `android_commands.gd` also removed the plugin's only `OS.execute` call
site. Every tool is attack surface and maintenance burden. This is a starting
cut, not a final one.

---

## Known-weak areas

Documented rather than fixed. Do not mistake their absence from the guard list
for their absence as a problem.

- **The `user://` file IPC is not concurrent.** One fixed filename per direction.
  Requests carry an id and callers reject responses that are not theirs, so the
  failure mode is a clean timeout rather than silently returning another call's
  data — but two concurrent runtime calls still cannot both succeed. The real fix
  is to give the game process its own WebSocket client (T-401 in the hardening
  plan); it is a design change and has not been done. Simulated input is the
  exception: it uses one file per batch, written under a temporary name and
  renamed into place, so input calls no longer overwrite each other.
- **No request cancellation.** When a call times out server-side, Godot keeps
  executing it. The result is discarded on arrival.
- **No authentication on the WebSocket.** See above.
- **The Godot plugin trusts the server completely.** It executes any method the
  router knows about. The `Origin` check and the single-client rule are what
  stand between that and an untrusted peer.
- **The plugin does not check which server it reaches.** Those two guards live in
  the MCP server, so they only apply when that server holds the port. Any local
  process that listens on 6505 first (or on `GODOT_MCP_PORT`) receives the
  plugin's connection and can drive the editor, which means running code through
  a `@tool` script. Nothing distinguishes it from the real server. The
  `GODOT_MCP_TOKEN` fix above closes this too, provided the plugin also refuses
  a server that does not prove it knows the token.

Supporting several MCP sessions at once, for example through a registry file of
ports the plugin connects to, is not built. If it ever is, the plugin must accept
only `127.0.0.1` entries and require the token above: otherwise anything that can
write the registry gets the editor.

---

## Verifying the guards

`scripts/verify.sh` runs the syntax check, the manifest/handler parity check,
the invariant checks, `tsc` and the unit tests.

`server/scripts/check-invariants.mjs` encodes each guard above as a regression
lock. **They are greps, not proofs** — they catch "someone deleted the guard",
not "the guard is correct". A green run is not a security audit.

If you change how one of these is implemented, update the corresponding
invariant. Do not delete it.
