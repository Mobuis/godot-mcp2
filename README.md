# Godot MCP

**Language:** **English** | [简体中文](README.zh.md)

Open-source Godot MCP server that lets AI assistants (Claude Code, Cursor, Codex, and more) control the Godot 4 editor directly through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/).

```
AI client  ←—stdio/MCP—→  Node.js server  ←—WebSocket:6505—→  Godot editor plugin
```

## Overview

| Component | Role |
|-----------|------|
| **Godot plugin** | WebSocket client that receives JSON-RPC requests and executes commands via editor APIs |
| **Node.js MCP server** | Speaks stdio to AI clients; runs a WebSocket server (default port 6505) to forward tool calls |
| **Command router** | `command_router.gd` aggregates 20 command modules with **156** handlers |
| **Runtime services** | 3 autoloads (`MCPRuntimeBridge` / `MCPInputBridge` / `MCPScreenshotBridge`) use `user://` IPC for in-game inspection, input simulation, and screenshots. They free themselves on `_ready()` unless `OS.has_feature("editor")`, so they do not run in exported builds |

### Core features

- **UndoRedo integration** — node add/remove/edit and property changes go through the editor undo stack
- **Smart type parsing** — strings like `Vector2(100, 200)`, `#ff0000`, `Color(1,0,0)` are converted automatically
- **Reconnect with backoff** — exponential backoff on the plugin side (1s → 60s)
- **Heartbeat** — bidirectional ping/pong to keep the WebSocket alive
- **JSON-RPC 2.0** — standard protocol between the Godot plugin and the Node.js server

## Tool categories

**156 MCP tools** across **20 categories**:

| Category | Tools | Highlights |
|----------|-------|------------|
| Project | 7 | Project info, file search, UID conversion, project settings |
| Scene | 10 | Scene tree, create/delete/instance scenes, play/stop, `@export` variables |
| Node | 14 | CRUD, properties, signals, groups, resource attachment |
| Script | 8 | Script CRUD, attach, validation, full-text search |
| Editor | 11 | Editor/game screenshots, camera control, error log, screenshot diff |
| Input | 7 | Keyboard/mouse/action simulation, input map (incl. deadzone) |
| Runtime | 18 | In-game scene tree, properties, signal watching, record/replay, UI clicks, navigation |
| Animation | 6 | Tracks, keyframes, AnimationPlayer CRUD |
| TileMap | 6 | Cell read/write, rect fill, used-cell queries |
| Theme/UI | 7 | Theme creation, Control layout, color/font/StyleBox overrides |
| Batch/Refactor | 9 | Batch add nodes, batch property updates, cross-scene edits, dependency/cycle detection |
| Shader | 6 | Shader CRUD, material assignment, parameter read/write |
| Resource | 6 | `.tres` read/write, Autoload register/remove |
| Physics | 6 | Collision bodies, physics layers (incl. layer name resolution), RayCast |
| 3D Scene | 6 | Mesh instances, camera, lights, environment, GridMap |
| Particle | 5 | GPU particles, materials, gradients, presets (fire/smoke/spark) |
| Navigation | 6 | Nav regions/agents, mesh baking, pathfinding |
| Audio | 6 | Audio players, buses, effects |
| AnimationTree | 8 | State machines, transitions, blend trees, parameters |
| Analysis | 4 | Scene complexity, signal flow, unused resources, project stats |

Removed from upstream, deliberately: `execute_editor_script` and
`execute_game_script` (arbitrary `Expression` evaluation), `set_auto_dismiss`
(suppressed editor confirmation dialogs), and the Profiling, Export, Testing/QA
and Android categories. See [`SECURITY.md`](SECURITY.md).

<details>
<summary>Expand to see all 156 tool names</summary>

**Project:** `get_project_info` · `get_filesystem_tree` · `search_files` · `get_project_settings` · `set_project_setting` · `uid_to_project_path` · `project_path_to_uid`

**Scene:** `get_scene_tree` · `get_scene_file_content` · `create_scene` · `open_scene` · `delete_scene` · `add_scene_instance` · `play_scene` · `stop_scene` · `save_scene` · `get_scene_exports`

**Node:** `add_node` · `delete_node` · `duplicate_node` · `move_node` · `update_property` · `get_node_properties` · `add_resource` · `set_anchor_preset` · `rename_node` · `connect_signal` · `disconnect_signal` · `get_node_groups` · `set_node_groups` · `find_nodes_in_group`

**Script:** `list_scripts` · `read_script` · `create_script` · `edit_script` · `attach_script` · `get_open_scripts` · `validate_script` · `search_in_files`

**Editor:** `get_editor_errors` · `get_editor_screenshot` · `get_game_screenshot` · `clear_output` · `get_signals` · `reload_plugin` · `reload_project` · `get_output_log` · `get_editor_camera` · `set_editor_camera` · `compare_screenshots`

**Input:** `simulate_key` · `simulate_mouse_click` · `simulate_mouse_move` · `simulate_action` · `simulate_sequence` · `get_input_actions` · `set_input_action`

**Runtime:** `get_game_scene_tree` · `get_game_node_properties` · `set_game_node_property` · `capture_frames` · `monitor_properties` · `start_recording` · `stop_recording` · `replay_recording` · `find_nodes_by_script` · `get_autoload` · `batch_get_properties` · `find_ui_elements` · `click_button_by_text` · `wait_for_node` · `find_nearby_nodes` · `navigate_to` · `move_to` · `watch_signals`

**Animation:** `list_animations` · `create_animation` · `add_animation_track` · `set_animation_keyframe` · `get_animation_info` · `remove_animation`

**TileMap:** `tilemap_set_cell` · `tilemap_fill_rect` · `tilemap_get_cell` · `tilemap_clear` · `tilemap_get_info` · `tilemap_get_used_cells`

**Theme/UI:** `create_theme` · `set_theme_color` · `set_theme_constant` · `set_theme_font_size` · `set_theme_stylebox` · `get_theme_info` · `setup_control`

**Batch/Refactor:** `find_nodes_by_type` · `find_signal_connections` · `batch_set_property` · `find_node_references` · `get_scene_dependencies` · `cross_scene_set_property` · `find_script_references` · `detect_circular_dependencies` · `batch_add_nodes`

**Shader:** `create_shader` · `read_shader` · `edit_shader` · `assign_shader_material` · `set_shader_param` · `get_shader_params`

**Resource:** `read_resource` · `edit_resource` · `create_resource` · `get_resource_preview` · `add_autoload` · `remove_autoload`

**Physics:** `setup_physics_body` · `setup_collision` · `set_physics_layers` · `get_physics_layers` · `get_collision_info` · `add_raycast`

**3D Scene:** `add_mesh_instance` · `setup_camera_3d` · `setup_lighting` · `setup_environment` · `add_gridmap` · `set_material_3d`

**Particle:** `create_particles` · `set_particle_material` · `set_particle_color_gradient` · `apply_particle_preset` · `get_particle_info`

**Navigation:** `setup_navigation_region` · `setup_navigation_agent` · `bake_navigation_mesh` · `set_navigation_layers` · `get_navigation_info` · `get_navigation_path`

**Audio:** `add_audio_player` · `add_audio_bus` · `add_audio_bus_effect` · `set_audio_bus` · `get_audio_bus_layout` · `get_audio_info`

**AnimationTree:** `create_animation_tree` · `get_animation_tree_structure` · `set_tree_parameter` · `add_state_machine_state` · `remove_state_machine_state` · `add_state_machine_transition` · `remove_state_machine_transition` · `set_blend_tree_node`

**Analysis:** `analyze_scene_complexity` · `analyze_signal_flow` · `find_unused_resources` · `get_project_statistics`

</details>

## Project structure

```
godot-mcp/
├── addons/godot_mcp/              # Godot editor plugin (copy into your project)
│   ├── plugin.gd                  # Plugin entry; injects autoloads
│   ├── plugin.cfg
│   ├── websocket_client.gd        # WebSocket client + JSON-RPC dispatch
│   ├── command_router.gd          # Command router; registers all handlers
│   ├── commands/                  # 20 command modules (156 tool implementations)
│   │   ├── base_commands.gd       # Base class: Undo, runtime IPC, screenshots, etc.
│   │   ├── project_commands.gd
│   │   ├── scene_commands.gd
│   │   ├── node_commands.gd
│   │   ├── script_commands.gd
│   │   ├── editor_commands.gd
│   │   ├── input_commands.gd
│   │   ├── runtime_commands.gd
│   │   ├── animation_commands.gd
│   │   ├── tilemap_commands.gd
│   │   ├── theme_commands.gd
│   │   ├── batch_commands.gd
│   │   ├── shader_commands.gd
│   │   ├── resource_commands.gd
│   │   ├── physics_commands.gd
│   │   ├── scene_3d_commands.gd
│   │   ├── particle_commands.gd
│   │   ├── navigation_commands.gd
│   │   ├── audio_commands.gd
│   │   ├── animation_tree_commands.gd
│   │   └── analysis_commands.gd
│   ├── services/                  # Runtime autoload services
│   │   ├── mcp_runtime_bridge.gd  # In-game scene tree / property inspection
│   │   ├── mcp_input_bridge.gd    # Input event queue
│   │   └── mcp_screenshot_bridge.gd
│   └── utils/
│       ├── type_parser.gd         # Vector2 / Color type parsing
│       ├── node_utils.gd
│       └── resource_utils.gd
├── server/                        # Node.js MCP server
│   ├── src/
│   │   ├── index.ts               # MCP stdio entry
│   │   ├── godot-bridge.ts        # WebSocket server + JSON-RPC
│   │   ├── tools.ts               # Tool registration
│   │   └── tool-manifest.ts       # 156 tool definitions (name / description / params)
│   └── build/index.js             # Build output (MCP entry point)
├── .mcp.json.example              # Sample MCP client config
├── README.md                      # English docs (default)
└── README.zh.md                   # Chinese docs
```

## Requirements

- **Godot** 4.4+
- **Node.js** 18+
- Any MCP-capable client: Claude Code, Cursor, Codex CLI, Cline, Windsurf, etc.

## Usage

### 1. Install the Godot plugin

Copy `addons/godot_mcp/` into your Godot project's `addons/` directory:

```bash
cp -r addons/godot_mcp /path/to/your-game/addons/
```

Enable it in Godot: **Project → Project Settings → Plugins → Godot MCP → Enable**

> Enabling the plugin injects 3 autoloads (`MCPRuntimeBridge`, etc.) into `project.godot`. Disabling it removes each of those entries, but only if the entry still points at this plugin's own script — an autoload you registered yourself under the same name is left alone.
>
> The three services free themselves on `_ready()` unless `OS.has_feature("editor")` is true. That tag is set when running from the editor, including play-from-editor, and is absent in every export, so the bridges cannot run in a shipped build.

### 2. Build the MCP server

```bash
cd server
npm install
npm run build
```

The entry point after build is `server/build/index.js`.

### 3. Configure your AI client

Add the following to your MCP config file (**replace paths with your actual paths**):

| Client | Config location |
|--------|-----------------|
| Claude Code | `.mcp.json` in the project root |
| Cursor | Settings → MCP, or `~/.cursor/mcp.json` |
| Codex CLI | MCP section in `~/.codex/config.toml` |
| Cline / Roo Code | MCP settings in the extension |

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "node",
      "args": ["D:/godot-mcp/server/build/index.js"],
      "env": {
        "GODOT_MCP_PORT": "6505"
      }
    }
  }
}
```

See also [`.mcp.json.example`](.mcp.json.example) in the repo.

#### Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `GODOT_MCP_PORT` | `6505` | Port for the loopback WebSocket server |
| `GODOT_MCP_TIMEOUT_MS` | `120000` | Per-request timeout. A few known-slow tools (e.g. `bake_navigation_mesh`) declare a higher floor in `tool-manifest.ts`; the effective timeout is the larger of the two, so raising this never shortens them |
| `GODOT_MCP_HEARTBEAT_MS` | `10000` | Ping interval. A peer that answers nothing for a full interval is terminated |

Non-positive or non-numeric values fall back to the default.

The WebSocket server binds to `127.0.0.1` and rejects any handshake carrying an
`Origin` header, which is what keeps a web page in your browser from connecting
to it. There is no token authentication — see [`SECURITY.md`](SECURITY.md).

### 4. Get started

1. **First**, open your project in Godot (with the plugin enabled)
2. Start your AI client and confirm the `godot-mcp` MCP server is connected
3. Ask the AI to operate the editor, for example:
   - "Get the current scene tree"
   - "Add a CharacterBody2D named Player under the root"
   - "Create a GDScript and attach it to Player"
   - "Play the current scene, then capture a game screenshot"
   - "Fill a grass area on the TileMap"

## How it works

1. The AI client calls an MCP tool (e.g. `add_node`) over **stdio**
2. The Node.js server converts the request to **JSON-RPC** and sends it over **WebSocket** to the Godot plugin
3. The plugin's `command_router` dispatches to the matching handler, which calls **EditorInterface** and related APIs
4. The result travels back to the AI client along the same path

**Runtime tools** (e.g. `get_game_scene_tree`) additionally require:

- The editor to be in **Play** mode
- The `MCPRuntimeBridge` autoload polling `user://mcp_runtime_req.json` in the game process and writing responses

Each request carries an id which the bridge echoes back, so a caller discards a
response that is not its own. The channel is still one fixed filename per
direction, so two concurrent runtime calls will not both succeed — the loser is
overwritten and times out rather than returning the other's data.

## Adding a tool

To add a new MCP tool:

1. Create or edit a command class under `addons/godot_mcp/commands/` and register the handler in `get_commands()`
2. Add the script path to the `COMMAND_MODULES` array in `command_router.gd`
3. Add the tool name, description, and parameter schema to `TOOL_DEFINITIONS` in `server/src/tool-manifest.ts`

Then rebuild the server:

```bash
cd server && npm run build
```

## Known limitations

- **Runtime tools**: call `play_scene` first; the game process must load the `MCPRuntimeBridge` autoload; `watch_signals` listens for signal emissions on specified nodes while the game is running
- **No parallel runtime calls**: the game-process IPC is a single fixed file per direction, so concurrent runtime or screenshot tool calls do not both succeed
- **No request cancellation**: when a call times out on the server side, Godot keeps executing it
- **Exports and Android deploys** are not exposed as tools; run them from the Godot CLI
- **Cross-scene batch edits** (`cross_scene_set_property`): modifies scene instances in memory — save the affected scene files manually
- Some editor APIs may differ across Godot minor versions; **4.4+** is recommended

## License

MIT
