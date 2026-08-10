@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

var _output_label: RichTextLabel = null

func get_commands() -> Dictionary:
	return {
		"get_editor_errors": _get_editor_errors,
		"get_output_log": _get_output_log,
		"clear_output": _clear_output,
		"get_open_scripts": _get_open_scripts,
		"get_editor_screenshot": _get_editor_screenshot,
		"get_game_screenshot": _get_game_screenshot,
		"reload_commands": _reload_commands,
		"reload_project": _reload_project,
		"get_editor_camera": _get_editor_camera,
		"set_editor_camera": _set_editor_camera,
		"set_main_screen": _set_main_screen,
		"compare_screenshots": _compare_screenshots,
	}


const MAIN_SCREENS := ["2D", "3D", "Script", "Game", "AssetLib"]


## Switches the editor's main screen tab.
##
## get_editor_screenshot captures whatever the main screen is currently showing,
## so an editor capture silently depends on which tab happened to be selected —
## the same script, run twice, produced identical screenshots one time and a
## script-editor view the next. Anything that wants repeatable editor captures has
## to be able to state which screen it means.
func _set_main_screen(p: Dictionary) -> Dictionary:
	var screen := str(p.get("screen", "3D"))
	if screen not in MAIN_SCREENS:
		return _err("Unknown main screen '%s'. Expected one of: %s" % [screen, ", ".join(MAIN_SCREENS)])
	editor_plugin.get_editor_interface().set_main_screen_editor(screen)
	return _ok({"screen": screen})


## Finds the editor's Output dock (class `EditorLog`) and the RichTextLabel it
## renders into.
##
## There is no scripting API for the Output dock, and the previous approach — an
## in-plugin buffer with an `append_output()` that nothing ever called — meant
## `get_output_log` returned [] and `get_editor_errors` reported a clean bill of
## health forever, no matter what the engine had printed. Walking for the control
## is a hack, but it reads the real thing, and if the editor's internals move it
## returns an error saying so instead of quietly reporting success.
func _find_output_label() -> RichTextLabel:
	if is_instance_valid(_output_label):
		return _output_label
	var base: Control = editor_plugin.get_editor_interface().get_base_control()
	if base == null:
		return null
	var log_node := _find_by_class(base, "EditorLog", 0)
	if log_node == null:
		return null
	var label := _find_by_class(log_node, "RichTextLabel", 0)
	_output_label = label as RichTextLabel
	return _output_label


func _find_by_class(node: Node, target: String, depth: int) -> Node:
	if depth > 24:
		return null
	if node.get_class() == target:
		return node
	for child in node.get_children(true):
		var hit := _find_by_class(child, target, depth + 1)
		if hit != null:
			return hit
	return null


## Every line currently in the Output dock, oldest first.
## Play-from-editor pipes the game's stdout into this same dock, so a print()
## from the running game shows up here too.
func _output_lines() -> Variant:
	var label := _find_output_label()
	if label == null:
		return null
	var text: String = label.get_parsed_text()
	var lines: Array = []
	for line in text.split("\n"):
		var trimmed := str(line).strip_edges()
		if not trimmed.is_empty():
			lines.append(trimmed)
	return lines


const OUTPUT_DOCK_MISSING := (
	"Could not find the editor Output dock (EditorLog). The editor's internal "
	+ "control tree has changed; this tool needs updating for this Godot version."
)


func _get_editor_errors(_params: Dictionary) -> Dictionary:
	var lines: Variant = _output_lines()
	if lines == null:
		return _err(OUTPUT_DOCK_MISSING)
	var errors: Array = []
	var warnings: Array = []
	for line in lines:
		var upper := str(line).to_upper()
		if upper.begins_with("ERROR:") or "SCRIPT ERROR" in upper or "PARSE ERROR" in upper or upper.begins_with("ERROR "):
			errors.append(line)
		elif upper.begins_with("WARNING:") or upper.begins_with("WARNING "):
			warnings.append(line)
	return _ok({
		"errors": errors,
		"warnings": warnings,
		"error_count": errors.size(),
		"warning_count": warnings.size(),
	})


func _get_output_log(params: Dictionary) -> Dictionary:
	var lines: Variant = _output_lines()
	if lines == null:
		return _err(OUTPUT_DOCK_MISSING)
	var all: Array = lines
	var max_lines: int = int(params.get("max_lines", 200))
	var start := maxi(0, all.size() - max_lines)
	return _ok({"lines": all.slice(start), "count": all.size() - start, "total": all.size()})


func _clear_output(_params: Dictionary) -> Dictionary:
	var label := _find_output_label()
	if label == null:
		return _err(OUTPUT_DOCK_MISSING)
	# EditorLog owns a "clear" button; calling the log's own clear keeps its
	# internal message counters in step with what is on screen.
	var log_node := label.get_parent()
	while log_node != null and log_node.get_class() != "EditorLog":
		log_node = log_node.get_parent()
	if log_node != null and log_node.has_method("clear"):
		log_node.call("clear")
	else:
		label.clear()
	return _ok({"cleared": true})


func _get_open_scripts(_params: Dictionary) -> Dictionary:
	var scripts: Array = []
	var script_editor := editor_plugin.get_editor_interface().get_script_editor()
	if script_editor:
		for script in script_editor.get_open_scripts():
			if script and script.resource_path:
				scripts.append(script.resource_path)
	return _ok({"scripts": scripts})


func _get_editor_screenshot(params: Dictionary) -> Dictionary:
	return await _request_screenshot("editor", params)


func _get_game_screenshot(params: Dictionary) -> Dictionary:
	return await _request_screenshot("game", params)


## Rebuilds the command modules from disk so edits to them take effect without
## restarting the editor.
##
## This replaces `reload_plugin`, which toggled the plugin off and on. That is the
## operation Godot answers by firing `_disable_plugin()` — which strips the three
## autoload entries and `enabled=` out of project.godot — and it freed the
## WebSocket client mid-call, so the tool crashed, the connection died, and the
## tracked config was left edited. Rebuilding only the router touches no files and
## keeps the socket up.
func _reload_commands(_params: Dictionary) -> Dictionary:
	var router := get_parent()
	if router == null or not router.has_method("request_reload"):
		return _err("Command router not reachable")
	router.request_reload()
	return _ok({
		"reloading": true,
		"modules": router.module_count(),
		"note": "Modules rebuild on the next frame. The new command count is printed to the Output dock; get_output_log will show it.",
	})


func _reload_project(_params: Dictionary) -> Dictionary:
	editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	editor_plugin.get_editor_interface().reload_scene_from_path(
		_edited_root().scene_file_path if _edited_root() else ""
	)
	return _ok({"reloaded": true})


## The editor 3D viewport's camera.
##
## `SubViewport.get_camera_transform()` / `set_camera_transform()` do not exist in
## Godot 4.7 — both calls aborted the handler, which then returned an empty result
## the server reported as success. The viewport's actual Camera3D is reachable via
## `get_camera_3d()`, and writing its `global_transform` does take effect (measured:
## the write survives with no user input; the viewport reclaims the camera as soon
## as you navigate it by hand).
func _editor_camera(idx: int) -> Camera3D:
	var ei := editor_plugin.get_editor_interface()
	if not ei.has_method("get_editor_viewport_3d"):
		return null
	var vp: SubViewport = ei.get_editor_viewport_3d(idx)
	if vp == null:
		return null
	return vp.get_camera_3d()


func _camera_info(idx: int, cam: Camera3D) -> Dictionary:
	var xform := cam.global_transform
	var euler := xform.basis.get_euler()
	return {
		"viewport_index": idx,
		"position": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z},
		"rotation": {"x": euler.x, "y": euler.y, "z": euler.z},
		"fov": cam.fov,
	}


func _get_editor_camera(_params: Dictionary) -> Dictionary:
	var cameras: Array = []
	for i in 4:
		var cam := _editor_camera(i)
		if cam == null:
			continue
		cameras.append(_camera_info(i, cam))
	if cameras.is_empty():
		return _err("No 3D editor viewport camera. Open a 3D scene and switch to the 3D view.")
	return _ok({"cameras": cameras, "count": cameras.size()})


func _set_editor_camera(params: Dictionary) -> Dictionary:
	var idx: int = int(params.get("viewport_index", 0))
	var cam := _editor_camera(idx)
	if cam == null:
		return _err("No 3D editor viewport camera at index %d. Open a 3D scene and switch to the 3D view." % idx)
	var current := cam.global_transform
	var current_euler := current.basis.get_euler()
	# Every component is optional and defaults to whatever the camera already has,
	# so a caller can nudge one axis without having to restate the whole transform.
	var pos := Vector3(
		float(params.get("x", current.origin.x)),
		float(params.get("y", current.origin.y)),
		float(params.get("z", current.origin.z))
	)
	var rot := Vector3(
		float(params.get("rotation_x", current_euler.x)),
		float(params.get("rotation_y", current_euler.y)),
		float(params.get("rotation_z", current_euler.z))
	)
	cam.global_transform = Transform3D(Basis.from_euler(rot), pos)
	if params.has("fov"):
		cam.fov = float(params.get("fov"))
	# Report what the camera actually holds afterwards, not what we asked for.
	return _ok(_camera_info(idx, cam))


func _compare_screenshots(p: Dictionary) -> Dictionary:
	var path_a: String = p.get("path_a", "")
	var path_b: String = p.get("path_b", "")
	var img_a := Image.load_from_file(path_a)
	var img_b := Image.load_from_file(path_b)
	if img_a == null or img_b == null:
		return _err("Failed to load images")
	if img_a.get_size() != img_b.get_size():
		return _ok({"match": false, "reason": "size_mismatch", "size_a": str(img_a.get_size()), "size_b": str(img_b.get_size())})
	var diff := 0
	var pixels := img_a.get_width() * img_a.get_height()
	for y in img_a.get_height():
		for x in img_a.get_width():
			if img_a.get_pixel(x, y) != img_b.get_pixel(x, y):
				diff += 1
	var ratio := float(diff) / float(maxi(pixels, 1))
	return _ok({"match": diff == 0, "diff_pixels": diff, "total_pixels": pixels, "diff_ratio": ratio})
