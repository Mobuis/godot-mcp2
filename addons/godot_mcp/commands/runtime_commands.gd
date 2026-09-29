@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

func get_commands() -> Dictionary:
	return {
		"get_game_scene_tree": _get_game_scene_tree,
		"get_game_node_properties": _get_game_node_properties,
		"set_game_node_property": _set_game_node_property,
		"capture_frames": _capture_frames,
		"monitor_properties": _monitor_properties,
		"get_monitored_properties": _get_monitored_properties,
		"start_recording": _start_recording,
		"stop_recording": _stop_recording,
		"replay_recording": _replay_recording,
		"find_nodes_by_script": _find_nodes_by_script,
		"get_autoload": _get_autoload,
		"batch_get_properties": _batch_get_properties,
		"find_ui_elements": _find_ui_elements,
		"click_button_by_text": _click_button_by_text,
		"wait_for_node": _wait_for_node,
		"find_nearby_nodes": _find_nearby_nodes,
		"navigate_to": _navigate_to,
		"move_to": _move_to,
		"watch_signals": _watch_signals,
	}


func _get_game_scene_tree(_p: Dictionary) -> Dictionary:
	return await _runtime_call("get_scene_tree")


func _get_game_node_properties(p: Dictionary) -> Dictionary:
	return await _runtime_call("get_node_properties", {"node_path": p.get("node_path", "")})


func _set_game_node_property(p: Dictionary) -> Dictionary:
	return await _runtime_call("set_node_property", p)


func _capture_frames(p: Dictionary) -> Dictionary:
	var count: int = int(p.get("count", 3))
	# N inline images blow the client's token limit even downscaled, so this tool
	# returns paths only unless the caller explicitly asks for image data.
	var shot_params := p.duplicate()
	if not shot_params.has("include_base64"):
		shot_params["include_base64"] = false
	var frames: Array = []
	for i in count:
		var shot := await _request_screenshot("game", shot_params)
		if shot.has("error"):
			return _err("Frame %d: %s" % [i, shot["error"].get("message", "capture failed")])
		var data: Variant = shot.get("result", shot)
		# _request_screenshot always writes the same fixed user:// filename, so
		# each frame overwrites the last. Copy it aside under a per-frame name —
		# without this the caller gets N identical paths and one file on disk,
		# which is unusable given this tool returns paths rather than image data.
		if data is Dictionary and data.has("path"):
			var src_path := str(data["path"])
			var dst_path := _user_file("mcp_frame_%d.png" % i)
			if FileAccess.file_exists(src_path) and DirAccess.copy_absolute(src_path, dst_path) == OK:
				data["path"] = dst_path
			else:
				data["path_warning"] = "could not copy this frame aside; the file at 'path' is overwritten by later frames"
		frames.append(data)
		await editor_plugin.get_tree().create_timer(0.1).timeout
	return _ok({"frames": frames, "count": frames.size()})


func _monitor_properties(p: Dictionary) -> Dictionary:
	return await _runtime_call("monitor_properties", p)


func _get_monitored_properties(p: Dictionary) -> Dictionary:
	return await _runtime_call("get_monitored", p)


func _start_recording(_p: Dictionary) -> Dictionary:
	return await _runtime_call("record_input", {"enabled": true})


func _stop_recording(_p: Dictionary) -> Dictionary:
	return await _runtime_call("record_input", {"enabled": false})


func _replay_recording(p: Dictionary) -> Dictionary:
	return await _runtime_call("replay_input", {"events": p.get("events", [])})


func _find_nodes_by_script(p: Dictionary) -> Dictionary:
	return await _runtime_call("find_by_script", {"script_path": _norm_res(p.get("script_path", ""))})


func _get_autoload(p: Dictionary) -> Dictionary:
	return await _runtime_call("get_autoload", {"name": p.get("name", "")})


func _batch_get_properties(p: Dictionary) -> Dictionary:
	return await _runtime_call("batch_get_properties", {"nodes": p.get("nodes", [])})


func _find_ui_elements(_p: Dictionary) -> Dictionary:
	return await _runtime_call("find_ui")


func _click_button_by_text(p: Dictionary) -> Dictionary:
	return await _runtime_call("click_button", {"text": p.get("text", "")})


func _wait_for_node(p: Dictionary) -> Dictionary:
	var timeout: float = float(p.get("timeout", 5.0))
	var elapsed := 0.0
	while elapsed < timeout:
		var res := await _runtime_call("wait_for_node", {"node_path": p.get("node_path", "")}, 1.0)
		if res.has("result") and res["result"].get("found", false):
			return res
		elapsed += 1.0
	return _err("Node did not appear in time")


func _find_nearby_nodes(p: Dictionary) -> Dictionary:
	return await _runtime_call("find_nearby", p)


## Points a NavigationAgent at a destination.
##
## T-106: this used to build a GDScript string and hand it to the runtime
## bridge's Expression evaluator, which DECISIONS.md D-1 removes. The typed
## set_node_property action does the same job without an evaluator.
##
## The replacement then hardcoded `Vector2(x, y)`, and NavigationAgent3D's
## target_position is a Vector3 — so on a 3D agent the write was discarded and the
## tool still answered {"ok": true}. A 3D destination also could not be expressed:
## there was no z. Now the vector matches the agent's dimension, and the bridge
## rejects a mismatch rather than swallowing it.
func _navigate_to(p: Dictionary) -> Dictionary:
	var agent_path: String = p.get("agent_path", ".")
	var is_3d: bool = p.get("is_3d", p.has("z"))
	var value := (
		"Vector3(%s, %s, %s)" % [p.get("x", 0), p.get("y", 0), p.get("z", 0)]
		if is_3d
		else "Vector2(%s, %s)" % [p.get("x", 0), p.get("y", 0)]
	)
	var res := await _runtime_call("set_node_property", {
		"node_path": agent_path,
		"property": "target_position",
		"value": value,
	})
	# A 2D vector on a 3D agent (or the reverse) now comes back as a real error.
	# Retry once in the other dimension so callers that omit `z` on a 3D agent get
	# the obvious behaviour instead of a lecture.
	if res.has("error") and not p.has("is_3d"):
		var flipped := (
			"Vector2(%s, %s)" % [p.get("x", 0), p.get("y", 0)]
			if is_3d
			else "Vector3(%s, %s, %s)" % [p.get("x", 0), p.get("y", 0), p.get("z", 0)]
		)
		var retry := await _runtime_call("set_node_property", {
			"node_path": agent_path,
			"property": "target_position",
			"value": flipped,
		})
		if not retry.has("error"):
			return retry
	return res


func _move_to(p: Dictionary) -> Dictionary:
	return await _navigate_to(p)


func _watch_signals(p: Dictionary) -> Dictionary:
	var duration_ms: int = int(p.get("duration_ms", 5000))
	var timeout_sec: float = duration_ms / 1000.0 + 3.0
	return await _runtime_call("watch_signals", p, timeout_sec)
