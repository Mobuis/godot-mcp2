@tool
extends Node
class_name MCPBaseCommands

const NodeUtils = preload("res://addons/godot_mcp/utils/node_utils.gd")
const ResourceUtils = preload("res://addons/godot_mcp/utils/resource_utils.gd")
const TypeParser = preload("res://addons/godot_mcp/utils/type_parser.gd")

var editor_plugin: EditorPlugin

var _request_seq: int = 0

const RUNTIME_REQ := "mcp_runtime_req.json"
const RUNTIME_RES := "mcp_runtime_res.json"
const SCREENSHOT_REQ := "mcp_screenshot_req.json"
const SCREENSHOT_RES := "mcp_screenshot_res.png"
const SCREENSHOT_META := "mcp_screenshot_meta.json"


func get_commands() -> Dictionary:
	return {}


func _ok(result: Variant = {}) -> Dictionary:
	return {"result": result}


func _err(message: String, code: int = -32000, data: Dictionary = {}) -> Dictionary:
	return {"error": {"code": code, "message": message, "data": data}}


func _edited_root() -> Node:
	return editor_plugin.get_editor_interface().get_edited_scene_root()


func _resolve_node(path: String) -> Node:
	return NodeUtils.resolve_in_tree(_edited_root(), path)


func _norm_res(path: String) -> String:
	return ResourceUtils.normalize_res(path)


## Longest-edge default for returned screenshots.
##
## A raw HiDPI editor capture is ~3024x1898, which base64-encodes to ~1.3M
## characters and is rejected outright by the MCP client for exceeding its token
## limit — the tool "worked" and was unusable. 1568 is the longest edge that
## still reads clearly while keeping the payload manageable.
const SCREENSHOT_MAX_EDGE := 1568


## Shrinks an image so its longest edge is at most max_edge. Never upscales.
func _downscale_image(img: Image, max_edge: int) -> Image:
	if max_edge <= 0:
		return img
	var longest := maxi(img.get_width(), img.get_height())
	if longest <= max_edge:
		return img
	var scale := float(max_edge) / float(longest)
	var out := img.duplicate() as Image
	out.resize(
		maxi(1, int(round(img.get_width() * scale))),
		maxi(1, int(round(img.get_height() * scale))),
		Image.INTERPOLATE_BILINEAR
	)
	return out


## Builds a screenshot result. The PNG on disk is always full resolution; only
## the returned base64 is downscaled, so compare_screenshots and anything else
## reading the file still sees the real capture.
func _screenshot_result(img: Image, path: String, p: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var result := {
		"path": path,
		"width": img.get_width(),
		"height": img.get_height(),
	}
	for k in extra:
		result[k] = extra[k]

	if not bool(p.get("include_base64", true)):
		result["base64_omitted"] = "include_base64 was false; read the file at 'path'"
		return _ok(result)

	var max_edge := int(p.get("max_edge", SCREENSHOT_MAX_EDGE))
	var encoded := _downscale_image(img, max_edge)
	result["base64"] = Marshalls.raw_to_base64(encoded.save_png_to_buffer())
	if encoded.get_width() != img.get_width():
		result["base64_width"] = encoded.get_width()
		result["base64_height"] = encoded.get_height()
		result["downscaled"] = true
	return _ok(result)


## Builds the error for a path parameter that _norm_res() refused.
##
## "you did not supply this" and "you supplied something the guard rejected" are
## different problems with different fixes, and collapsing them into one string
## made the guards undebuggable — a caller could not tell a typo from a blocked
## traversal. Says which rule refused, and echoes the offending path.
func _path_error(params: Dictionary, key: String) -> String:
	var raw := str(params.get(key, "")).strip_edges()
	if raw.is_empty():
		return "Missing '%s'" % key
	if ".." in raw:
		return "Rejected '%s': %s — parent-directory segments are not allowed, paths must stay inside the project" % [key, raw]
	return "Rejected '%s': %s" % [key, raw]


## T-105: true only if an absolute filesystem path resolves inside the project
## directory. Any destructive handler acting on a caller-supplied path must gate
## on this, not on normalize_res() alone.
func _is_inside_project(abs_path: String) -> bool:
	if abs_path.is_empty():
		return false
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	if root.is_empty():
		return false
	if not root.ends_with("/"):
		root += "/"
	return abs_path.simplify_path().begins_with(root)


func _user_file(name: String) -> String:
	return OS.get_user_data_dir().path_join(name)


## T-206: the file IPC uses one fixed filename per channel, so two concurrent
## tool calls overwrite each other's request and can read each other's response.
## Tagging every request lets a caller recognise a response that is not its own.
## This turns "silently wrong data" into "clean timeout"; it does not make the
## channel concurrent. The real fix is T-401.
func _new_request_id() -> String:
	_request_seq += 1
	return "%d-%d-%d" % [Time.get_ticks_usec(), _request_seq, randi()]


func _runtime_call(action: String, params: Dictionary = {}, timeout_sec: float = 5.0) -> Dictionary:
	if not editor_plugin.get_editor_interface().is_playing_scene():
		return _err("Game is not running. Use play_scene first.", -32010)
	var request_id := _new_request_id()
	var req_path := _user_file(RUNTIME_REQ)
	var res_path := _user_file(RUNTIME_RES)
	if FileAccess.file_exists(res_path):
		DirAccess.remove_absolute(res_path)
	var file := FileAccess.open(req_path, FileAccess.WRITE)
	if file == null:
		return _err("Failed to write runtime request file", -32012)
	file.store_string(JSON.stringify({"id": request_id, "action": action, "params": params}))
	file.close()
	var elapsed := 0.0
	while elapsed < timeout_sec:
		await editor_plugin.get_tree().create_timer(0.05).timeout
		elapsed += 0.05
		if FileAccess.file_exists(res_path):
			var text := FileAccess.get_file_as_string(res_path)
			var data = JSON.parse_string(text)
			if not (data is Dictionary):
				# unparseable — drop it so it cannot block the poll loop
				DirAccess.remove_absolute(res_path)
				continue
			if str(data.get("id", "")) != request_id:
				# Another call's response. Leave it for its owner and keep
				# waiting; this request was overwritten and will time out.
				continue
			DirAccess.remove_absolute(res_path)
			if data.has("error"):
				return _err(str(data["error"]))
			return _ok(data.get("result", data))
	return _err("Runtime request timed out", -32011)


func _queue_input(events: Array) -> void:
	var bridge = _get_input_bridge()
	if bridge:
		bridge.queue_events(events)


func _get_input_bridge() -> Node:
	return get_node_or_null("/root/MCPInputBridge")


func _request_screenshot(target: String = "editor", p: Dictionary = {}) -> Dictionary:
	var request_id := _new_request_id()
	var req_path := _user_file(SCREENSHOT_REQ)
	var res_path := _user_file(SCREENSHOT_RES)
	var meta_path := _user_file(SCREENSHOT_META)
	if FileAccess.file_exists(res_path):
		DirAccess.remove_absolute(res_path)
	var file := FileAccess.open(req_path, FileAccess.WRITE)
	if file == null:
		return _err("Failed to write screenshot request file")
	file.store_string(JSON.stringify({"id": request_id, "target": target}))
	file.close()
	if target == "editor":
		var vp := editor_plugin.get_editor_interface().get_editor_main_screen().get_viewport()
		if vp:
			var img := vp.get_texture().get_image()
			if img:
				img.save_png(res_path)
				return _screenshot_result(img, res_path, p)
	var elapsed := 0.0
	while elapsed < 5.0:
		await editor_plugin.get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		if FileAccess.file_exists(res_path):
			var meta = {}
			if FileAccess.file_exists(meta_path):
				meta = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
			# T-206: only accept the capture produced for this request.
			if not (meta is Dictionary) or str(meta.get("id", "")) != request_id:
				continue
			var img := Image.load_from_file(res_path)
			if img == null:
				return _err("Screenshot file could not be read: %s" % res_path)
			return _screenshot_result(img, res_path, p, {"meta": meta})
	return _err("Screenshot capture failed")


func _undo_property(node: Object, property: String, new_value: Variant) -> void:
	var old_value = node.get(property)
	editor_plugin.get_undo_redo().create_action("MCP Set %s" % property)
	editor_plugin.get_undo_redo().add_do_property(node, property, new_value)
	editor_plugin.get_undo_redo().add_undo_property(node, property, old_value)
	editor_plugin.get_undo_redo().commit_action()


func _parse_value(text: String) -> Variant:
	return TypeParser.parse(text)


func _node_to_dict(node: Node, depth: int = 0, max_depth: int = 8) -> Dictionary:
	var info := {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()),
	}
	if depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(_node_to_dict(child, depth + 1, max_depth))
		info["children"] = children
	return info


func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return "Vector2(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "Vector3(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_VECTOR2I:
			return "Vector2i(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3I:
			return "Vector3i(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_RECT2:
			return "Rect2(%s, %s, %s, %s)" % [value.position.x, value.position.y, value.size.x, value.size.y]
		TYPE_COLOR:
			return "Color(%s, %s, %s, %s)" % [value.r, value.g, value.b, value.a]
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return str(value.get_path())
			if value is Resource:
				return value.resource_path if value.resource_path else str(value)
			return str(value)
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(_serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var dict := {}
			for key in value:
				dict[str(key)] = _serialize_value(value[key])
			return dict
		_:
			return str(value)
