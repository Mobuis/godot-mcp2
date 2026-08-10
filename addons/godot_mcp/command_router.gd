@tool
extends Node

var editor_plugin: EditorPlugin
var _handlers: Dictionary = {}
var _reload_pending := false

const COMMAND_MODULES := [
	"res://addons/godot_mcp/commands/project_commands.gd",
	"res://addons/godot_mcp/commands/scene_commands.gd",
	"res://addons/godot_mcp/commands/node_commands.gd",
	"res://addons/godot_mcp/commands/script_commands.gd",
	"res://addons/godot_mcp/commands/editor_commands.gd",
	"res://addons/godot_mcp/commands/input_commands.gd",
	"res://addons/godot_mcp/commands/runtime_commands.gd",
	"res://addons/godot_mcp/commands/animation_commands.gd",
	"res://addons/godot_mcp/commands/tilemap_commands.gd",
	"res://addons/godot_mcp/commands/theme_commands.gd",
	"res://addons/godot_mcp/commands/batch_commands.gd",
	"res://addons/godot_mcp/commands/shader_commands.gd",
	"res://addons/godot_mcp/commands/resource_commands.gd",
	"res://addons/godot_mcp/commands/physics_commands.gd",
	"res://addons/godot_mcp/commands/scene_3d_commands.gd",
	"res://addons/godot_mcp/commands/particle_commands.gd",
	"res://addons/godot_mcp/commands/navigation_commands.gd",
	"res://addons/godot_mcp/commands/audio_commands.gd",
	"res://addons/godot_mcp/commands/animation_tree_commands.gd",
	"res://addons/godot_mcp/commands/analysis_commands.gd",
]

func _ready() -> void:
	_register_commands()

func _register_commands() -> void:
	for script_path in COMMAND_MODULES:
		# CACHE_MODE_REPLACE so reload_commands() actually picks up edits on disk.
		# A plain load() returns whatever the editor cached at startup, which made
		# a "reload" a no-op that reported success.
		var script: GDScript = ResourceLoader.load(script_path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)
		if script == null:
			push_error("[Godot MCP] Command module failed to load: %s" % script_path)
			continue
		var cmd: Node = script.new()
		cmd.editor_plugin = editor_plugin
		add_child(cmd)
		var commands: Dictionary = cmd.get_commands()
		for method_name: String in commands:
			_handlers[method_name] = commands[method_name]
	print("[Godot MCP] Registered %d commands" % _handlers.size())

## Rebuilds every command module from disk.
##
## Deferred on purpose. The caller is itself a handler living inside one of the
## modules this frees, so tearing them down inside the call would free the frame
## that is still executing. The response goes out first; the swap happens after.
func request_reload() -> void:
	if _reload_pending:
		return
	_reload_pending = true
	_do_reload.call_deferred()

func _do_reload() -> void:
	await get_tree().process_frame
	_handlers.clear()
	for child in get_children():
		remove_child(child)
		child.free()
	_register_commands()
	_reload_pending = false

func module_count() -> int:
	return COMMAND_MODULES.size()

func execute(method: String, params: Dictionary) -> Dictionary:
	if not _handlers.has(method):
		return {
			"error": {
				"code": -32601,
				"message": "Method not found: %s" % method,
			},
		}
	var result: Variant = await _handlers[method].call(params)

	# A GDScript runtime error aborts the handler and hands back the declared
	# return type's default — {} for `-> Dictionary`. That has no "error" key, so
	# it used to travel out as a successful empty result and the caller was told
	# the call worked. Every silent failure found in Milestone 0a arrived this
	# way: a dead API, a property that does not exist on the node, a bad cast.
	# Anything not shaped like a handler result is a handler that died.
	if result is Dictionary and (result.has("result") or result.has("error")):
		return result
	return {
		"error": {
			"code": -32001,
			"message": (
				"Handler for '%s' returned no result — it aborted on a runtime error. "
				+ "The reason is in the editor Output dock; get_editor_errors will show it."
			) % method,
			"data": {"method": method, "returned": str(result)},
		},
	}

func get_available_methods() -> Array:
	return _handlers.keys()
