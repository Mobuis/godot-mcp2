@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

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
	return _queued(_queue_input([event]))


func _simulate_mouse_click(params: Dictionary) -> Dictionary:
	return _queued(_queue_input([{
		"type": "mouse_click",
		"x": float(params.get("x", 0)),
		"y": float(params.get("y", 0)),
		"button": int(params.get("button", MOUSE_BUTTON_LEFT)),
	}]))


func _simulate_mouse_move(params: Dictionary) -> Dictionary:
	return _queued(_queue_input([{
		"type": "mouse_move",
		"x": float(params.get("x", 0)),
		"y": float(params.get("y", 0)),
	}]))


func _simulate_action(params: Dictionary) -> Dictionary:
	return _queued(_queue_input([{
		"type": "action",
		"action": str(params.get("action", "")),
		"pressed": params.get("pressed", true),
	}]))


func _simulate_sequence(params: Dictionary) -> Dictionary:
	var events: Array = params.get("events", [])
	if not _queue_input(events):
		return _err("Could not write the input queue")
	return _ok({"queued": events.size()})


## Reports whether the events actually reached the queue, rather than always
## claiming success.
func _queued(ok: bool) -> Dictionary:
	if not ok:
		return _err("Could not write the input queue")
	return _ok({"queued": true})


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
