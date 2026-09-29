@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

const InputBridge = preload("res://addons/godot_mcp/services/mcp_input_bridge.gd")

const KNOWN_EVENT_TYPES := ["key", "mouse_click", "mouse_move", "action"]
## Real-time ceiling for a waiting simulate_* call. The bridge caps allow
## about 25 s; this stays under the server's 45 s timeout.
const ACK_DEADLINE_SEC := 30.0


func get_commands() -> Dictionary:
	return {
		"simulate_key": _simulate_key,
		"simulate_mouse_click": _simulate_mouse_click,
		"simulate_mouse_move": _simulate_mouse_move,
		"simulate_action": _simulate_action,
		"simulate_sequence": _simulate_sequence,
		"get_input_actions": _get_input_actions,
		"set_input_action": _set_input_action,
	}


func _simulate_key(params: Dictionary) -> Dictionary:
	var event := {
		"type": "key",
		"keycode": int(params.get("keycode", KEY_SPACE)),
		"pressed": params.get("pressed", true),
	}
	# Optional: forward a physical keycode when the caller distinguishes it.
	# Left absent, the bridge mirrors `keycode` into it so bindings made against
	# physical keys -- which is Godot's own default -- still match.
	if params.has("physical_keycode"):
		event["physical_keycode"] = int(params.get("physical_keycode"))
	return await _send_input([event], params, true)


func _simulate_mouse_click(params: Dictionary) -> Dictionary:
	return await _send_input([{
		"type": "mouse_click",
		"x": float(params.get("x", 0)),
		"y": float(params.get("y", 0)),
		"button": int(params.get("button", MOUSE_BUTTON_LEFT)),
	}], params, true)


func _simulate_mouse_move(params: Dictionary) -> Dictionary:
	return await _send_input([{
		"type": "mouse_move",
		"x": float(params.get("x", 0)),
		"y": float(params.get("y", 0)),
	}], params, true)


func _simulate_action(params: Dictionary) -> Dictionary:
	return await _send_input([{
		"type": "action",
		"action": str(params.get("action", "")),
		"pressed": params.get("pressed", true),
	}], params, true)


func _simulate_sequence(params: Dictionary) -> Dictionary:
	var events = params.get("events", [])
	if not events is Array:
		return _err("events must be an array")
	return await _send_input(events, params, false)


## Validates, queues and by default waits for the game to apply the events.
## `single` marks the one-event tools, whose result reports `"queued": true`.
func _send_input(events: Array, params: Dictionary, single: bool) -> Dictionary:
	if not editor_plugin.get_editor_interface().is_playing_scene():
		# Nothing consumes batches while stopped, so clear leftovers that would
		# otherwise fire at the next game start.
		_clear_input_files()
		return _err("Game is not running. Use play_scene first.", -32010)
	var wait: bool = bool(params.get("wait", true))
	var wait_frames_raw = params.get("wait_frames", 0)
	var bad := _check_count(wait_frames_raw, InputBridge.MAX_FRAMES, "wait_frames")
	if not bad.is_empty():
		return _err(bad)
	var wait_frames := int(wait_frames_raw)
	var problem := _validate_events(events, wait_frames)
	if not problem.is_empty():
		return _err(problem)
	if events.is_empty():
		return _ok({"queued": 0, "applied": 0})
	_purge_stale_input_files()
	if _pending_batch_files() >= InputBridge.MAX_PENDING_BATCHES:
		return _err("The game has %d input batches waiting to be applied; wait for them to finish before sending more." % InputBridge.MAX_PENDING_BATCHES, -32013)
	# Every batch needs an id for its file name; only a waiting call gets an ack.
	var request_id := _new_request_id()
	var batch := {
		"id": request_id,
		"ack": wait,
		"created": Time.get_unix_time_from_system(),
		"wait_frames": wait_frames if wait else 0,
		"events": events,
	}
	if not _queue_batch(request_id, batch):
		return _err("Could not write the input batch")
	var queued: Variant = true if single else events.size()
	if not wait:
		return _ok({"queued": queued, "waited": false})
	var ack := await _await_ack(request_id)
	if ack.has("_error"):
		return _err(str(ack["_error"]), -32011)
	return _ok({
		"queued": queued,
		"applied": int(ack.get("applied", 0)),
		"frames": int(ack.get("frames", 0)),
		"elapsed_ms": int(ack.get("elapsed_ms", 0)),
	})


## A finite number. 1e30 is valid JSON and int(1e30) is INT64_MIN in GDScript,
## which would slip under a `> cap` check.
func _is_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and is_finite(float(v))


## Returns an error message, or "" when `v` is a number in 0..cap. Checks the
## float, not int(v).
func _check_count(v: Variant, cap: int, label: String) -> String:
	if not _is_number(v) or float(v) < 0.0:
		return "%s must be a non-negative number" % label
	if float(v) > float(cap):
		return "%s %s exceeds the cap of %d" % [label, str(int(v)) if float(v) < 1e9 else "(huge value)", cap]
	return ""


## Returns an error message, or "" when every event is valid and within the caps.
func _validate_events(events: Array, wait_frames: int) -> String:
	if events.size() > InputBridge.MAX_EVENTS:
		return "Too many events: %d (cap %d)" % [events.size(), InputBridge.MAX_EVENTS]
	var total_delay := 0
	var total_frames := wait_frames
	for i in events.size():
		var ev = events[i]
		if not ev is Dictionary:
			return "Event %d is not an object" % i
		var type := str(ev.get("type", ""))
		if not KNOWN_EVENT_TYPES.has(type):
			return "Event %d has unknown type '%s' (expected one of: %s)" % [i, type, ", ".join(KNOWN_EVENT_TYPES)]
		for key in ["keycode", "physical_keycode", "x", "y", "button"]:
			if ev.has(key) and not _is_number(ev[key]):
				return "Event %d: %s must be a number" % [i, key]
		if ev.has("pressed") and typeof(ev["pressed"]) != TYPE_BOOL:
			return "Event %d: pressed must be a boolean" % i
		if type == "action" and str(ev.get("action", "")).is_empty():
			return "Event %d: action requires a non-empty action name" % i
		if type == "key" and not ev.has("keycode"):
			return "Event %d: key requires keycode" % i
		if ev.has("button") and (float(ev["button"]) < MOUSE_BUTTON_LEFT or float(ev["button"]) > MOUSE_BUTTON_XBUTTON2):
			return "Event %d: button must be %d to %d" % [i, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_XBUTTON2]
		var frames := 1 if i > 0 else 0
		if ev.has("frames"):
			var bad := _check_count(ev["frames"], InputBridge.MAX_FRAMES, "Event %d: frames" % i)
			if not bad.is_empty():
				return bad
			frames = int(ev["frames"])
		if ev.has("delay_ms"):
			var bad := _check_count(ev["delay_ms"], InputBridge.MAX_DELAY_MS, "Event %d: delay_ms" % i)
			if not bad.is_empty():
				return bad
			total_delay += int(ev["delay_ms"])
		total_frames += frames
		if type == "mouse_click":
			total_frames += 1 # press and release are applied in separate frames
	if total_delay > InputBridge.MAX_TOTAL_DELAY_MS:
		return "Total delay_ms %d exceeds the cap of %d" % [total_delay, InputBridge.MAX_TOTAL_DELAY_MS]
	if total_frames > InputBridge.MAX_TOTAL_FRAMES:
		return "The sequence needs %d frames (including wait_frames), above the cap of %d" % [total_frames, InputBridge.MAX_TOTAL_FRAMES]
	return ""


## Lists the user-data files whose names start with `prefix`.
func _input_files(prefix: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(OS.get_user_data_dir())
	if dir != null:
		for f in dir.get_files():
			if f.begins_with(prefix):
				out.append(f)
	return out


func _pending_batch_files() -> int:
	return _input_files(InputBridge.BATCH_PREFIX).size()


## Removes every batch, temp and acknowledgement file.
func _clear_input_files() -> void:
	for prefix in [InputBridge.BATCH_PREFIX, InputBridge.TMP_PREFIX, InputBridge.ACK_PREFIX]:
		for f in _input_files(prefix):
			DirAccess.remove_absolute(_user_file(f))


## Removes files nobody waits for any more, such as an ack written after its
## caller gave up. Anything older than the ack deadline plus slack is stale.
func _purge_stale_input_files() -> void:
	var limit := ACK_DEADLINE_SEC + 5.0
	var now := Time.get_unix_time_from_system()
	# Not batch files: an accepted wait:false batch can wait its turn longer than
	# this, and deleting it would drop events the caller was told were queued.
	for prefix in [InputBridge.TMP_PREFIX, InputBridge.ACK_PREFIX]:
		for f in _input_files(prefix):
			var path := _user_file(f)
			if now - float(FileAccess.get_modified_time(path)) > limit:
				DirAccess.remove_absolute(path)


## Writes a batch to its own file, temp name then rename, so the game never reads
## a half-written file. Goes through disk because the MCPInputBridge autoload does
## not exist in the editor, where these commands run.
func _queue_batch(request_id: String, batch: Dictionary) -> bool:
	var tmp := _user_file(InputBridge.TMP_PREFIX + request_id + ".json")
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(batch))
	file.close()
	if DirAccess.rename_absolute(tmp, _batch_path(request_id)) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true


func _batch_path(request_id: String) -> String:
	return _user_file(InputBridge.BATCH_PREFIX + request_id + ".json")


## Polls for this request's ack until ACK_DEADLINE_SEC. On failure, withdraws the
## batch if the game has not picked it up and returns {"_error": message}.
func _await_ack(request_id: String) -> Dictionary:
	var ack_path := _user_file(InputBridge.ACK_PREFIX + request_id + ".json")
	var deadline := Time.get_ticks_msec() + int(ACK_DEADLINE_SEC * 1000.0)
	var editor_interface := editor_plugin.get_editor_interface()
	while Time.get_ticks_msec() < deadline:
		await editor_plugin.get_tree().create_timer(0.05).timeout
		# Ack first: a game that finished and then stopped still answered.
		if FileAccess.file_exists(ack_path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(ack_path))
			# Leave an unparsable ack for the next poll, so a read racing the write
			# cannot lose it.
			if data is Dictionary and str(data.get("id", "")) == request_id:
				DirAccess.remove_absolute(ack_path)
				return data
		elif not editor_interface.is_playing_scene():
			_abandon(request_id, ack_path)
			return {"_error": "The game stopped before applying the events."}
	_abandon(request_id, ack_path)
	return {"_error": "The game did not confirm the input within %d s (it may be paused or still applying the sequence). Events it had already started may still be applied." % int(ACK_DEADLINE_SEC)}


func _abandon(request_id: String, ack_path: String) -> void:
	var batch_path := _batch_path(request_id)
	if FileAccess.file_exists(batch_path):
		DirAccess.remove_absolute(batch_path)
	if FileAccess.file_exists(ack_path):
		DirAccess.remove_absolute(ack_path)


func _get_input_actions(_params: Dictionary) -> Dictionary:
	var actions: Array = []
	for action in InputMap.get_actions():
		var events: Array = []
		for ev in InputMap.action_get_events(action):
			var entry := {"as_text": ev.as_text(), "class": ev.get_class()}
			if ev is InputEventKey:
				entry["keycode"] = ev.keycode
				entry["physical_keycode"] = ev.physical_keycode
			elif ev is InputEventJoypadButton:
				entry["button_index"] = ev.button_index
			events.append(entry)
		actions.append({
			"name": action,
			"deadzone": InputMap.action_get_deadzone(action),
			"events": events,
		})
	return _ok({"actions": actions, "count": actions.size()})


func _set_input_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return _err("Missing action name")
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if params.has("deadzone"):
		InputMap.action_set_deadzone(action, float(params.get("deadzone")))
	if params.has("keycode"):
		var ev := InputEventKey.new()
		ev.keycode = int(params.get("keycode"))
		if params.has("physical_keycode"):
			ev.physical_keycode = int(params.get("physical_keycode"))
		InputMap.action_add_event(action, ev)
	elif params.has("button_index"):
		var joy := InputEventJoypadButton.new()
		joy.button_index = int(params.get("button_index"))
		InputMap.action_add_event(action, joy)
	return _ok({"action": action})
