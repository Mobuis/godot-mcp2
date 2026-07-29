@tool
extends EditorPlugin

const AUTOLOADS: Array[Array] = [
	["autoload/MCPRuntimeBridge", "res://addons/godot_mcp/services/mcp_runtime_bridge.gd"],
	["autoload/MCPInputBridge", "res://addons/godot_mcp/services/mcp_input_bridge.gd"],
	["autoload/MCPScreenshotBridge", "res://addons/godot_mcp/services/mcp_screenshot_bridge.gd"],
]

var _websocket_client: Node
var _command_router: Node
var auto_dismiss_dialogs: bool = false


func _enter_tree() -> void:
	_inject_autoloads()
	_command_router = preload("res://addons/godot_mcp/command_router.gd").new()
	_command_router.name = "MCPCommandRouter"
	_command_router.editor_plugin = self
	add_child(_command_router)

	_websocket_client = preload("res://addons/godot_mcp/websocket_client.gd").new()
	_websocket_client.name = "MCPWebSocketClient"
	_websocket_client.command_router = _command_router
	add_child(_websocket_client)
	_websocket_client.start()
	print("[Godot MCP] Plugin started")


func _exit_tree() -> void:
	_remove_autoloads()
	if _websocket_client:
		_websocket_client.stop()
		_websocket_client.queue_free()
	if _command_router:
		_command_router.queue_free()
	print("[Godot MCP] Plugin stopped")


func _process(_delta: float) -> void:
	if not auto_dismiss_dialogs:
		return
	var base_control := get_editor_interface().get_base_control()
	if base_control:
		_dismiss_dialogs(base_control)


func _dismiss_dialogs(node: Node) -> void:
	if node is AcceptDialog and node.visible:
		node.hide()
	for child in node.get_children():
		_dismiss_dialogs(child)


func _inject_autoloads() -> void:
	var changed := false
	for entry in AUTOLOADS:
		var key: String = entry[0]
		var script: String = entry[1]
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, "*" + script)
			changed = true
	if changed:
		ProjectSettings.save()


func _remove_autoloads() -> void:
	# T-102: iterate AUTOLOADS, not an in-memory list of what this session
	# happened to inject. _injected was rebuilt empty on every _enter_tree() and
	# only appended to when the setting did not already exist, so from the second
	# editor session onwards it was always empty and _exit_tree() removed nothing.
	var changed := false
	for entry in AUTOLOADS:
		var key: String = entry[0]
		var script: String = entry[1]
		if not ProjectSettings.has_setting(key):
			continue
		# Ownership check: only remove an entry that still points at this
		# plugin's own script. A user may legitimately have registered their own
		# autoload under the same name, and that is not ours to delete.
		if str(ProjectSettings.get_setting(key)).trim_prefix("*") != script:
			continue
		ProjectSettings.set_setting(key, null)
		changed = true
	if changed:
		ProjectSettings.save()
