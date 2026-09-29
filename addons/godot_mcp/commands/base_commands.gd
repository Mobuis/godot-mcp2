@tool
extends Node
class_name MCPBaseCommands

const NodeUtils = preload("res://addons/godot_mcp/utils/node_utils.gd")
const ResourceUtils = preload("res://addons/godot_mcp/utils/resource_utils.gd")
const TypeParser = preload("res://addons/godot_mcp/utils/type_parser.gd")
const PropertyAccess = preload("res://addons/godot_mcp/utils/property_access.gd")

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


## A node's path relative to the edited scene root — the form every tool here
## accepts as `node_path`.
##
## `node.get_path()` on a node in the open scene returns a path rooted in the
## *editor's* control tree, e.g.
## `/root/@EditorNode@19513/…/@SubViewportContainer@…/Sandbox/Particles`. The
## create-style tools returned that, and then every sibling get_*/set_* tool
## rejected it, because they resolve relative to the scene root. Callers were left
## having to guess the node's default name.
func _scene_path(node: Node) -> String:
	if node == null:
		return ""
	var root := _edited_root()
	if root == null:
		return str(node.get_path())
	if node == root:
		return "."
	if not root.is_ancestor_of(node):
		return str(node.get_path())
	return str(root.get_path_to(node))


## Starting longest-edge cap for returned screenshots. Only a starting point —
## SCREENSHOT_MAX_BASE64 is the constraint that actually decides the size.
const SCREENSHOT_MAX_EDGE := 1024

## Hard ceiling on the base64 payload, in characters.
##
## Capping the longest edge alone does not work: PNG size depends on content, so
## the same edge produces wildly different payloads. Measured on a 3024x1898
## Retina editor capture, edge caps of 1568 and even 400 still produced 821k and
## 73k characters respectively, both refused by the client; only ~45k got
## through. So the budget is the real limit and the edge is derived from it.
const SCREENSHOT_MAX_BASE64 := 40_000


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


## Encodes img as base64 PNG, shrinking until it fits within budget.
##
## Always re-scales from the original, so repeated passes do not compound
## resampling loss. base64 length tracks pixel count closely enough to jump most
## of the way in one step instead of creeping down.
func _encode_within_budget(img: Image, max_edge: int, budget: int) -> Dictionary:
	var candidate := _downscale_image(img, max_edge)
	var b64 := Marshalls.raw_to_base64(candidate.save_png_to_buffer())
	var attempts := 0
	while b64.length() > budget and attempts < 6:
		var longest := maxi(candidate.get_width(), candidate.get_height())
		var ratio := sqrt(float(budget) / float(b64.length())) * 0.9
		var next_edge := maxi(96, int(longest * ratio))
		if next_edge >= longest:
			break
		candidate = _downscale_image(img, next_edge)
		b64 = Marshalls.raw_to_base64(candidate.save_png_to_buffer())
		attempts += 1
	return {"image": candidate, "base64": b64}


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
		result["base64_omitted"] = "include_base64 was false; read the PNG at 'path'"
		return _ok(result)

	var budget := int(p.get("max_base64_chars", SCREENSHOT_MAX_BASE64))
	var encoded := _encode_within_budget(img, int(p.get("max_edge", SCREENSHOT_MAX_EDGE)), budget)
	var image: Image = encoded["image"]
	var b64: String = encoded["base64"]

	# Never return a payload known to be over budget — the client rejects the
	# whole result, so the caller loses the path as well as the image.
	if b64.length() > budget:
		result["base64_omitted"] = (
			"image does not fit in %d base64 chars even at %dpx; read the PNG at 'path'"
			% [budget, maxi(image.get_width(), image.get_height())]
		)
		return _ok(result)

	result["base64"] = b64
	result["base64_chars"] = b64.length()
	if image.get_width() != img.get_width():
		result["base64_width"] = image.get_width()
		result["base64_height"] = image.get_height()
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
	file.store_string(JSON.stringify({"id": request_id, "action": action, "params": params, "timeout_ms": int(timeout_sec * 1000.0)}))
	file.close()
	# Measure real time, not iterations. `elapsed += 0.05` assumed each poll took
	# exactly its nominal 50ms, but the editor throttles its frame rate when idle
	# and a SceneTreeTimer cannot fire faster than a frame — so a nominal 5s
	# budget was observed taking ~10s of wall clock. The advertised timeout has
	# to be the real one.
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await editor_plugin.get_tree().create_timer(0.05).timeout
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
	return _err("Runtime request timed out after %.1fs: %s" % [timeout_sec, action], -32011)


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
		var captured := _capture_editor_area(p)
		if captured.has("error"):
			return _err(str(captured["error"]))
		if captured.has("image"):
			var img: Image = captured["image"]
			# The file on disk is the requested crop.
			img.save_png(res_path)
			return _screenshot_result(img, res_path, p, captured["extra"])
	# Same real-time deadline as _runtime_call, for the same reason.
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await editor_plugin.get_tree().create_timer(0.1).timeout
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
			var extra := {"meta": meta}
			if _has_region(p):
				var cropped := _crop_to_region(img, p)
				if cropped.has("error"):
					return _err(str(cropped["error"]))
				img = cropped["image"]
				img.save_png(res_path)
				extra["region"] = cropped["region"]
			return _screenshot_result(img, res_path, p, extra)
	return _err("Screenshot capture failed")


const SCREENSHOT_AREAS := ["editor", "main_screen", "viewport_3d", "viewport_2d"]
const REGION_KEYS := ["region_x", "region_y", "region_width", "region_height"]


func _has_region(p: Dictionary) -> bool:
	for key in REGION_KEYS:
		if p.has(key):
			return true
	return false


## Crops img to p's region_x/y/width/height, clamped to the image. x and y
## default to 0, sizes to the far edge. Returns {"image", "region"} or {"error"}.
func _crop_to_region(img: Image, p: Dictionary) -> Dictionary:
	for key in REGION_KEYS:
		if p.has(key) and not (typeof(p[key]) in [TYPE_INT, TYPE_FLOAT]):
			return {"error": "%s must be a number of pixels" % key}
	var iw := img.get_width()
	var ih := img.get_height()
	var wf := float(p.get("region_width", iw))
	var hf := float(p.get("region_height", ih))
	if not (wf > 0.0 and hf > 0.0):
		return {"error": "region_width and region_height must be positive (got %s x %s)" % [wf, hf]}
	# Clamped as floats first: Rect2i is 32-bit, so a huge value would wrap.
	var x := int(clampf(float(p.get("region_x", 0)), -iw, iw))
	var y := int(clampf(float(p.get("region_y", 0)), -ih, ih))
	var w := int(minf(wf, 2.0 * iw))
	var h := int(minf(hf, 2.0 * ih))
	var rect := Rect2i(0, 0, iw, ih).intersection(Rect2i(x, y, w, h))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return {"error": "Region x=%s y=%s lies outside the %dx%d image" % [p.get("region_x", 0), p.get("region_y", 0), iw, ih]}
	return {
		"image": img.get_region(rect),
		"region": {"x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y},
	}


## True when vp is on screen. A hidden editor SubViewport keeps its last,
## stale texture.
func _viewport_is_shown(vp: Viewport) -> bool:
	var node: Node = vp.get_parent()
	while node != null:
		if node is CanvasItem:
			return (node as CanvasItem).is_visible_in_tree()
		node = node.get_parent()
	return false


## Captures p["area"] and applies p's region. Returns {"image", "extra"},
## {"error"}, or {} when the editor has no viewport, so the caller falls back.
## Control rects are in canvas units, so "main_screen" scales its rect to pixels.
func _capture_editor_area(p: Dictionary) -> Dictionary:
	var area := str(p.get("area", "editor"))
	if area not in SCREENSHOT_AREAS:
		return {"error": "Unknown area '%s'. Expected one of: %s" % [area, ", ".join(SCREENSHOT_AREAS)]}
	var ei := editor_plugin.get_editor_interface()
	var img: Image = null
	var extra := {"area": area}
	if area in ["editor", "main_screen"]:
		var screen := ei.get_editor_main_screen()
		var root_vp := screen.get_viewport()
		if root_vp == null:
			return {}
		img = root_vp.get_texture().get_image()
		if img == null:
			return {}
		if area == "main_screen":
			var canvas := root_vp.get_visible_rect().size
			var sx := float(img.get_width()) / maxf(canvas.x, 1.0)
			var sy := float(img.get_height()) / maxf(canvas.y, 1.0)
			var r := screen.get_global_rect()
			var crop := Rect2i(
				Vector2i(roundi(r.position.x * sx), roundi(r.position.y * sy)),
				Vector2i(roundi(r.size.x * sx), roundi(r.size.y * sy))
			).intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
			if crop.size.x <= 0 or crop.size.y <= 0:
				return {"error": "The editor main screen has no visible area to capture"}
			img = img.get_region(crop)
	else:
		var index := int(p.get("viewport_index", 0))
		var vp: SubViewport = null
		if area == "viewport_3d":
			if index < 0 or index > 3:
				return {"error": "viewport_index must be 0-3, got %d" % index}
			if ei.has_method("get_editor_viewport_3d"):
				vp = ei.get_editor_viewport_3d(index)
			extra["viewport_index"] = index
		elif ei.has_method("get_editor_viewport_2d"):
			vp = ei.get_editor_viewport_2d()
		var screen_name := "3D" if area == "viewport_3d" else "2D"
		if vp == null:
			return {"error": "The editor's %s viewport is not available (%s)" % [screen_name, area]}
		if not _viewport_is_shown(vp):
			var hint := "Call set_main_screen with screen '%s' (and open a %s scene) first" % [screen_name, screen_name]
			if area == "viewport_3d" and index > 0:
				hint = "Viewport %d is only shown when the 3D view uses a split layout. %s" % [index, hint]
			return {"error": "The %s viewport is not on screen, so its texture would be stale or blank. %s" % [screen_name, hint]}
		img = vp.get_texture().get_image()
		if img == null or img.is_empty():
			return {"error": "The %s viewport has no image yet. Try again in a moment" % screen_name}
	if _has_region(p):
		extra["area_width"] = img.get_width()
		extra["area_height"] = img.get_height()
		var cropped := _crop_to_region(img, p)
		if cropped.has("error"):
			return cropped
		img = cropped["image"]
		extra["region"] = cropped["region"]
	return {"image": img, "extra": extra}


## Marks the edited scene unsaved after a change made without UndoRedo.
## Otherwise the editor does not know it changed: reload_project would discard it
## and closing the editor would not prompt to save.
func _mark_unsaved() -> void:
	var ei := editor_plugin.get_editor_interface()
	if ei.has_method("mark_scene_as_unsaved"):
		ei.mark_scene_as_unsaved()


func _undo_property(node: Object, property: String, new_value: Variant) -> void:
	var undo_redo := editor_plugin.get_undo_redo()
	undo_redo.create_action("MCP Set %s" % property)
	if ":" in property:
		# add_do_property() takes a plain name; a path needs set_indexed().
		var path := NodePath(property)
		undo_redo.add_do_method(node, "set_indexed", path, new_value)
		undo_redo.add_undo_method(node, "set_indexed", path, node.get_indexed(path))
	else:
		undo_redo.add_do_property(node, property, new_value)
		undo_redo.add_undo_property(node, property, node.get(property))
	undo_redo.commit_action()


## Parses value_text for the property, writes it and checks the value read back
## (see MCPPropertyAccess). Returns {"value"} plus an optional "note", or {"error"}.
## use_undo is false for objects outside the scene's undo history. refuse_external
## is for callers that save a single file: a write into another file would stay
## in memory only.
func _set_property_typed(target: Object, property: String, value_text: String, use_undo: bool = true, refuse_external: bool = false) -> Dictionary:
	var info := PropertyAccess.describe(target, property)
	if info.has("error"):
		return info
	if refuse_external:
		var external := PropertyAccess.external_file(info, target)
		if not external.is_empty():
			return {"error": "%s: this writes into %s, which is saved in its own file. Edit that file with edit_resource instead." % [property, external]}
	var parsed := PropertyAccess.parse(info, value_text)
	if parsed.has("error"):
		return {"error": "%s: %s" % [property, parsed["error"]]}
	var wanted: Variant = parsed["value"]
	var path := NodePath(property)
	var before: Variant = target.get_indexed(path)
	if use_undo:
		_undo_property(target, property, wanted)
	else:
		target.set_indexed(path, wanted)
	var after: Variant = target.get_indexed(path)
	var check := PropertyAccess.verify(before, wanted, after)
	if check.has("error"):
		return {"error": "%s: %s" % [property, check["error"]]}
	var out := {"value": after}
	var notes: Array = []
	if check.has("note"):
		notes.append(check["note"])
	var shared := PropertyAccess.shared_resource_note(info, target)
	if not shared.is_empty():
		notes.append(shared)
	if not notes.is_empty():
		out["note"] = " ".join(notes)
	return out


func _parse_value(text: String) -> Variant:
	return TypeParser.parse(text)


func _node_to_dict(node: Node, depth: int = 0, max_depth: int = 8) -> Dictionary:
	var info := {
		"name": node.name,
		"type": node.get_class(),
		"path": _scene_path(node),
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
