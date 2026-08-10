extends Node
## Queues synthetic input events for the running game/editor.

const QUEUE_FILE := "mcp_input_queue.json"


func _ready() -> void:
	# T-101: this is an autoload injected into project.godot, so it would
	# otherwise ship in exported games. The "editor" feature tag is present when
	# running from the editor, including play-from-editor, and absent in every
	# export — debug or release. A debug-build check would not be enough.
	if not OS.has_feature("editor"):
		queue_free()


func queue_events(events: Array) -> void:
	var path := OS.get_user_data_dir().path_join(QUEUE_FILE)
	var existing: Array = []
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Array:
			existing = parsed
	existing.append_array(events)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(existing))
		file.close()


func _process(_delta: float) -> void:
	var path := OS.get_user_data_dir().path_join(QUEUE_FILE)
	if not FileAccess.file_exists(path):
		return
	var events = JSON.parse_string(FileAccess.get_file_as_string(path))
	DirAccess.remove_absolute(path)
	if not events is Array:
		return
	for ev in events:
		apply_event(ev)
	# parse_input_event only *queues*; the queue is drained at the start of the
	# next engine iteration. Without this, a caller that acts and then
	# immediately inspects or screenshots reads pre-event state and concludes
	# the input did nothing.
	Input.flush_buffered_events()


## Public so MCPRuntimeBridge's replay path can reuse it. Replaying a recorded
## event and simulating a fresh one have to build the event the same way, or
## replay quietly behaves differently from the tool that produced the recording.
func apply_event(ev: Dictionary) -> void:
	match ev.get("type", ""):
		"key":
			var e := InputEventKey.new()
			e.keycode = int(ev.get("keycode", 0))
			# Both, deliberately. An InputMap action binds either the layout
			# keycode or the physical one, and Godot matches on whichever the
			# *binding* uses. Godot's own editor writes physical bindings by
			# default, so sending only `keycode` silently fails to trigger most
			# real projects' actions.
			e.physical_keycode = int(ev.get("physical_keycode", e.keycode))
			e.pressed = ev.get("pressed", true)
			Input.parse_input_event(e)
		"mouse_click":
			var point := Vector2(ev.get("x", 0), ev.get("y", 0))
			# Move the real pointer first. Games that pick from the cursor read
			# get_viewport().get_mouse_position() rather than the event's
			# position -- that is the standard click-to-move raycast in 3D -- so
			# an event alone lands at wherever the pointer physically happens to
			# be, usually outside the window, and the click appears to do
			# nothing at all.
			Input.warp_mouse(point)
			var e := InputEventMouseButton.new()
			e.position = point
			e.global_position = point
			e.button_index = int(ev.get("button", MOUSE_BUTTON_LEFT))
			e.button_mask = _mask_for(e.button_index)
			e.pressed = true
			Input.parse_input_event(e)
			var release := InputEventMouseButton.new()
			release.position = point
			release.global_position = point
			release.button_index = e.button_index
			release.pressed = false
			Input.parse_input_event(release)
		"mouse_move":
			var point := Vector2(ev.get("x", 0), ev.get("y", 0))
			var previous := _viewport_mouse_position()
			Input.warp_mouse(point)
			var e := InputEventMouseMotion.new()
			e.position = point
			e.global_position = point
			e.relative = point - previous
			Input.parse_input_event(e)
		"action":
			var e := InputEventAction.new()
			e.action = StringName(str(ev.get("action", "")))
			e.pressed = ev.get("pressed", true)
			# An InputEventAction, not Input.action_press(). action_press flips
			# the action's internal state without dispatching anything, so
			# _input/_unhandled_input handlers -- where almost every game reads
			# actions -- never see it and nothing happens.
			Input.parse_input_event(e)


func _mask_for(button_index: int) -> int:
	match button_index:
		MOUSE_BUTTON_LEFT:
			return MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT:
			return MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE:
			return MOUSE_BUTTON_MASK_MIDDLE
		_:
			return 0


func _viewport_mouse_position() -> Vector2:
	var viewport := get_viewport()
	return viewport.get_mouse_position() if viewport != null else Vector2.ZERO
