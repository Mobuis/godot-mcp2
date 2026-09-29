extends Node
## Runtime bridge autoload — handles in-game MCP requests via user:// IPC.

const NodeUtils = preload("res://addons/godot_mcp/utils/node_utils.gd")
const PropertyAccess = preload("res://addons/godot_mcp/utils/property_access.gd")

const REQUEST_FILE := "mcp_runtime_req.json"
const RESPONSE_FILE := "mcp_runtime_res.json"

var _recording: Array = []
var _is_recording := false
var _record_started_ms := 0
var _handling := false
## A handler that hits a script error never returns, so _handling would stay set
## and every later request would time out. Past this time the next request is
## served anyway; the generation stops the stuck handler from clearing the flag.
var _handling_until_msec := 0
var _handling_generation := 0
const DEFAULT_REQUEST_TIMEOUT_MS := 5000

## key -> {node_path, property, started_ms, samples:[{t, value}], max_samples}
var _monitors: Dictionary = {}

const MAX_RECORDED_EVENTS := 4000
const DEFAULT_MAX_SAMPLES := 600


## Captures one node+signal pair for watch_signals.
##
## Deliberately an object rather than a bound Callable. `Callable.bind()` appends
## its arguments *after* the signal's own, so a handler written as
## `(emissions, path, name, ...args)` received the signal's first payload value in
## `emissions`. Godot refused the call — "Cannot convert argument 1 from int to
## Array" — and every signal carrying a value was silently dropped while
## watch_signals still returned success with count 0. Holding the context as
## instance state means the connected method takes only the signal's own
## arguments, however many there are.
class SignalRecorder extends RefCounted:
	var emissions: Array
	var node_path: String
	var signal_name: String

	func _init(p_emissions: Array, p_node_path: String, p_signal_name: String) -> void:
		emissions = p_emissions
		node_path = p_node_path
		signal_name = p_signal_name

	func on_emit(...args) -> void:
		var serialized: Array = []
		for arg in args:
			serialized.append(str(arg))
		emissions.append({
			"node_path": node_path,
			"signal": signal_name,
			"args": serialized,
		})


func _ready() -> void:
	# T-101: this is an autoload injected into project.godot, so it would
	# otherwise ship in exported games. The "editor" feature tag is present when
	# running from the editor, including play-from-editor, and absent in every
	# export — debug or release. A debug-build check would not be enough.
	if not OS.has_feature("editor"):
		queue_free()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_sample_monitors()
	if _handling and Time.get_ticks_msec() < _handling_until_msec:
		return
	var path := _user_path(REQUEST_FILE)
	if not FileAccess.file_exists(path):
		return
	_handling = true
	_handling_generation += 1
	var text := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		_write_response({"error": "bad request json"})
		_handling = false
		return
	var timeout_ms := int(json.data.get("timeout_ms", DEFAULT_REQUEST_TIMEOUT_MS))
	_handling_until_msec = Time.get_ticks_msec() + clampi(timeout_ms, 0, 60000) + 1000
	_handle_request(json.data, _handling_generation)


func _handle_request(req: Dictionary, generation: int) -> void:
	var result: Dictionary = await _dispatch_async(req)
	# T-206: echo the caller's id so it can tell its own response from another's.
	result["id"] = str(req.get("id", ""))
	_write_response(result)
	if generation == _handling_generation:
		_handling = false


func _dispatch_async(req: Dictionary) -> Dictionary:
	var action: String = req.get("action", "")
	var params: Dictionary = req.get("params", {})
	match action:
		"get_scene_tree":
			var root := get_tree().current_scene
			if root == null:
				return {"error": "no current scene"}
			return {"result": NodeUtils.tree_dict(root)}
		"get_node_properties":
			var node := _resolve_node(params.get("node_path", ""))
			if node == null:
				return {"error": "node not found"}
			return {"result": _props(node)}
		"set_node_property":
			var node := _resolve_node(params.get("node_path", ""))
			if node == null:
				return {"error": "node not found"}
			var prop := str(params.get("property", ""))
			if PropertyAccess.touches_script(prop):
				return {"error": (
					"Refusing to set '%s' in the running game: assigning a script runs its code. "
					+ "Attach scripts in the editor with attach_script."
				) % prop}
			var info := PropertyAccess.describe(node, prop)
			if info.has("error"):
				return {"error": info["error"]}
			# Parsed against the declared type, so a Vector2 for a Vector3 is refused.
			var parsed := PropertyAccess.parse(info, str(params.get("value", "")))
			if parsed.has("error"):
				return {"error": "%s.%s: %s" % [node.get_class(), prop, parsed["error"]]}
			var wanted: Variant = parsed["value"]
			var path := NodePath(prop)
			var before: Variant = node.get_indexed(path)
			node.set_indexed(path, wanted)
			# Object.set() fails silently, so judge the write by the value read back.
			var actual: Variant = node.get_indexed(path)
			var check := PropertyAccess.verify(before, wanted, actual)
			if check.has("error"):
				return {"error": "%s.%s: %s" % [node.get_class(), prop, check["error"]]}
			var result := {"ok": true, "property": prop, "value": str(actual)}
			if check.has("note"):
				result["note"] = check["note"]
			return {"result": result}
		"find_by_script":
			var results: Array = []
			var search_root := _search_root()
			if search_root:
				NodeUtils.find_by_script(search_root, params.get("script_path", ""), results)
			return {"result": results}
		"find_ui":
			var results: Array = []
			var search_root := _search_root()
			if search_root:
				_collect_ui(search_root, results)
			return {"result": results}
		"click_button":
			var text: String = params.get("text", "")
			var search_root := _search_root()
			if search_root == null:
				return {"error": "no active scene"}
			var btn := _find_button(search_root, text)
			if btn == null:
				return {"error": "button not found"}
			btn.pressed.emit()
			return {"result": {"clicked": btn.name}}
		"wait_for_node":
			var node := _resolve_node(params.get("node_path", ""))
			return {"result": {"found": node != null}}
		"get_autoload":
			var name: String = params.get("name", "")
			var n := get_node_or_null("/root/%s" % name)
			if n == null:
				return {"error": "autoload not found"}
			return {"result": _props(n)}
		"batch_get_properties":
			var out: Array = []
			var missing: Array = []
			for item in params.get("nodes", []):
				var requested := str(item.get("path", ""))
				var node := _resolve_node(requested)
				if node == null:
					# Previously skipped in silence, so a typo'd path just produced
					# a shorter list the caller had no way to notice.
					missing.append(requested)
					continue
				out.append({"path": str(node.get_path()), "properties": _props(node, item.get("properties", []))})
			return {"result": {"nodes": out, "missing": missing, "count": out.size()}}
		"record_input":
			var enable: bool = params.get("enabled", true)
			if enable:
				_recording.clear()
				_record_started_ms = Time.get_ticks_msec()
				_is_recording = true
				return {"result": {"recording": true}}
			_is_recording = false
			var data := _recording.duplicate()
			_recording.clear()
			return {"result": {"events": data, "count": data.size()}}
		"replay_input":
			var events: Array = params.get("events", [])
			var replayed := _replay_events(events)
			if replayed == -1:
				return {"error": "MCPInputBridge autoload is not present; cannot replay input"}
			if replayed == -2:
				return {"error": "The game has too many input batches waiting; try again once they are applied"}
			return {"result": {"replayed": replayed, "requested": events.size(), "note": "Queued; the events play back over the recorded duration."}}
		"watch_signals":
			return await _watch_signals(params)
		"find_nearby":
			return _find_nearby(params)
		"monitor_properties":
			return _start_monitor(params)
		"get_monitored":
			return _read_monitor(params)
		_:
			return {"error": "unknown action: %s" % action}


func _watch_signals(params: Dictionary) -> Dictionary:
	var node_paths: Array = params.get("node_paths", [])
	var duration_ms: int = int(params.get("duration_ms", 5000))
	var signal_filter: Array = params.get("signal_filter", [])
	var emissions: Array = []
	var connections: Array = []
	for path_str in node_paths:
		var node := _resolve_node(str(path_str))
		if node == null:
			continue
		for sig_info in node.get_signal_list():
			var sig_name: String = sig_info.name
			if not signal_filter.is_empty() and sig_name not in signal_filter:
				continue
			var recorder := SignalRecorder.new(emissions, str(path_str), sig_name)
			var callable := Callable(recorder, "on_emit")
			if node.connect(sig_name, callable) != OK:
				continue
			# The recorder is RefCounted; the connection alone does not keep it
			# alive, so hold it here for the duration of the watch.
			connections.append({"node": node, "signal": sig_name, "callable": callable, "recorder": recorder})
	if connections.is_empty():
		return {"error": "no signals matched (nodes: %s, filter: %s)" % [node_paths, signal_filter]}
	await get_tree().create_timer(maxf(duration_ms / 1000.0, 0.1)).timeout
	for conn in connections:
		var n: Node = conn.node
		if is_instance_valid(n) and n.is_connected(conn.signal, conn.callable):
			n.disconnect(conn.signal, conn.callable)
	return {"result": {
		"emissions": emissions,
		"count": emissions.size(),
		"duration_ms": duration_ms,
		"watched": connections.size(),
	}}


func _search_root() -> Node:
	var scene := get_tree().current_scene
	if scene != null:
		return scene
	var tree := get_tree()
	for i in tree.root.get_child_count():
		var child: Node = tree.root.get_child(i)
		if child != null:
			return child
	return null


## Resolves any shape of node path a caller could reasonably hold: the absolute
## form printed by get_scene_tree ("/root/my_scene/Sprite2D"), the same without
## the leading slash, an absolute path with the root segment omitted
## ("/my_scene/Sprite2D"), or a path relative to the current scene ("Sprite2D").
##
## The absolute forms used to be handled by stripping only the leading "/",
## which left "root/my_scene/Sprite2D" — and get_tree().root IS the node named
## "root", so the lookup went hunting for a child of root also called "root" and
## could never match. get_scene_tree emits exactly that form, so its own output
## was not valid input to get_game_node_properties.
func _resolve_node(path: String) -> Node:
	var path_text := str(path).strip_edges()
	if path_text.is_empty() or path_text == ".":
		return get_tree().current_scene

	var root := get_tree().root
	if root == null:
		return null

	# An absolute NodePath resolves from any node, so these can go straight to
	# get_node_or_null() without being rewritten relative to anything.
	var absolute: Array[String] = []
	if path_text == "/root" or path_text.begins_with("/root/"):
		absolute.append(path_text)
	elif path_text == "root" or path_text.begins_with("root/"):
		absolute.append("/" + path_text)
	elif path_text.begins_with("/"):
		absolute.append("/root" + path_text)
		absolute.append(path_text.substr(1))

	for candidate in absolute:
		var hit := root.get_node_or_null(NodePath(candidate))
		if hit != null:
			return hit
	if not absolute.is_empty():
		return null

	var scene := get_tree().current_scene
	if scene == null:
		return null
	return NodeUtils.resolve_in_tree(scene, path_text)


func _props(node: Node, keys: Array = []) -> Dictionary:
	var out := {}
	if keys.is_empty():
		for info in node.get_property_list():
			if info.usage & PROPERTY_USAGE_EDITOR:
				out[info.name] = str(node.get(info.name))
	else:
		for k in keys:
			out[str(k)] = str(node.get(str(k)))
	return out


func _collect_ui(node: Node, results: Array) -> void:
	if node is Control:
		results.append({
			"path": str(node.get_path()),
			"type": node.get_class(),
			"text": node.text if "text" in node else "",
		})
	for child in node.get_children():
		_collect_ui(child, results)


func _find_button(node: Node, text: String) -> BaseButton:
	if node is BaseButton and (text.is_empty() or node.text == text):
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found:
			return found
	return null


## Replays events through MCPInputBridge rather than reimplementing them.
##
## The old version handled only `type: "action"` and ignored keys and clicks
## outright, while still answering {"replayed": true} — so replaying a recorded
## key sequence did nothing and said it had worked. Delegating also guarantees a
## replayed event is built identically to a simulated one.
##
## Returns the number of events dispatched, or -1 if the input bridge is missing.
func _replay_events(events: Array) -> int:
	var bridge := get_node_or_null("/root/MCPInputBridge")
	if bridge == null or not bridge.has_method("enqueue"):
		return -1
	# Replayed through the sequencer with the recorded gaps: applied in one frame,
	# a press and its release are invisible to a game that polls input.
	var timed: Array = []
	var previous_t := -1.0
	for ev in events:
		if not ev is Dictionary:
			continue
		var entry: Dictionary = ev.duplicate()
		var t := float(ev.get("t", previous_t if previous_t >= 0.0 else 0.0))
		if previous_t >= 0.0 and is_finite(t):
			entry["delay_ms"] = maxf(t - previous_t, 0.0)
		previous_t = t
		timed.append(entry)
	var accepted: int = bridge.enqueue(timed)
	return accepted if accepted >= 0 else -2


## Records real input while `start_recording` is active.
##
## `_recording` was declared and never appended to — there was no input hook at
## all — so `stop_recording` always returned an empty list and reported success.
func _input(event: InputEvent) -> void:
	if not _is_recording:
		return
	var serialized := _serialize_input_event(event)
	if serialized.is_empty():
		return
	if _recording.size() >= MAX_RECORDED_EVENTS:
		return
	serialized["t"] = Time.get_ticks_msec() - _record_started_ms
	_recording.append(serialized)


## Serialised in exactly the shape MCPInputBridge.apply_event() consumes, so a
## recording can be handed straight back to replay_recording.
func _serialize_input_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {
			"type": "key",
			"keycode": event.keycode,
			"physical_keycode": event.physical_keycode,
			"pressed": event.pressed,
		}
	if event is InputEventMouseButton:
		# apply_event's "mouse_click" always emits press+release, so only record
		# the press half; recording both would double every click on replay.
		if not event.pressed:
			return {}
		return {
			"type": "mouse_click",
			"x": event.position.x,
			"y": event.position.y,
			"button": event.button_index,
		}
	if event is InputEventMouseMotion:
		return {"type": "mouse_move", "x": event.position.x, "y": event.position.y}
	if event is InputEventAction:
		return {"type": "action", "action": str(event.action), "pressed": event.pressed}
	return {}


## Nodes within `radius` of a point, or of another node.
##
## Was a stub returning {"note": "Use get_game_scene_tree and filter by position"}
## — success-shaped, no data. Mob density is the loop this project is built
## around, so "what is near the player right now" needs a real answer.
##
## 3D and 2D nodes are measured in their own space: a Node3D against
## Vector3(x, y, z), a Node2D or Control against Vector2(x, y). Pass `node_path`
## to centre on a node instead of raw coordinates.
func _find_nearby(params: Dictionary) -> Dictionary:
	var root := _search_root()
	if root == null:
		return {"error": "no active scene"}

	var origin_3d := Vector3(float(params.get("x", 0.0)), float(params.get("y", 0.0)), float(params.get("z", 0.0)))
	var origin_2d := Vector2(float(params.get("x", 0.0)), float(params.get("y", 0.0)))
	var centre_path := str(params.get("node_path", ""))
	var centre_name := ""
	if not centre_path.is_empty():
		var centre := _resolve_node(centre_path)
		if centre == null:
			return {"error": "centre node not found: %s" % centre_path}
		centre_name = str(centre.get_path())
		if centre is Node3D:
			origin_3d = centre.global_position
		elif centre is Node2D:
			origin_2d = centre.global_position
		elif centre is Control:
			origin_2d = centre.global_position

	var radius: float = float(params.get("radius", 100.0))
	var type_filter := str(params.get("type", ""))
	var found: Array = []
	_collect_nearby(root, origin_3d, origin_2d, radius, type_filter, found, centre_name)
	found.sort_custom(func(a, b): return a["distance"] < b["distance"])
	var limit: int = int(params.get("max_results", 50))
	if found.size() > limit:
		found = found.slice(0, limit)
	return {"result": {
		"nodes": found,
		"count": found.size(),
		"radius": radius,
		"origin_3d": str(origin_3d),
		"origin_2d": str(origin_2d),
		"centred_on": centre_name,
	}}


func _collect_nearby(
	node: Node,
	origin_3d: Vector3,
	origin_2d: Vector2,
	radius: float,
	type_filter: String,
	out: Array,
	exclude_path: String
) -> void:
	var path := str(node.get_path())
	if path != exclude_path and (type_filter.is_empty() or node.is_class(type_filter)):
		var distance := -1.0
		var position := ""
		if node is Node3D:
			distance = node.global_position.distance_to(origin_3d)
			position = str(node.global_position)
		elif node is Node2D:
			distance = node.global_position.distance_to(origin_2d)
			position = str(node.global_position)
		elif node is Control:
			distance = node.global_position.distance_to(origin_2d)
			position = str(node.global_position)
		if distance >= 0.0 and distance <= radius:
			out.append({
				"path": path,
				"name": node.name,
				"type": node.get_class(),
				"position": position,
				"distance": distance,
			})
	for child in node.get_children():
		_collect_nearby(child, origin_3d, origin_2d, radius, type_filter, out, exclude_path)


## Starts sampling a property every frame. Read the samples with get_monitored.
##
## The editor-side handler used to file the request in a dictionary that nothing
## ever read, and no tool existed to retrieve anything, so the whole feature was
## inert while reporting success.
func _start_monitor(params: Dictionary) -> Dictionary:
	var key := str(params.get("key", "default"))
	var node_path := str(params.get("node_path", ""))
	var property := str(params.get("property", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return {"error": "node not found: %s" % node_path}
	if not (property in node):
		return {"error": "%s has no property '%s'" % [node.get_class(), property]}
	_monitors[key] = {
		"node_path": node_path,
		"property": property,
		"started_ms": Time.get_ticks_msec(),
		"max_samples": int(params.get("max_samples", DEFAULT_MAX_SAMPLES)),
		"samples": [],
		"last": null,
	}
	return {"result": {"monitoring": key, "node_path": node_path, "property": property}}


func _read_monitor(params: Dictionary) -> Dictionary:
	var key := str(params.get("key", "default"))
	if not _monitors.has(key):
		return {"error": "no monitor named '%s'. Active: %s" % [key, _monitors.keys()]}
	var monitor: Dictionary = _monitors[key]
	var samples: Array = (monitor["samples"] as Array).duplicate()
	if bool(params.get("stop", false)):
		_monitors.erase(key)
	elif bool(params.get("clear", false)):
		monitor["samples"] = []
	return {"result": {
		"key": key,
		"node_path": monitor["node_path"],
		"property": monitor["property"],
		"samples": samples,
		"count": samples.size(),
		"stopped": bool(params.get("stop", false)),
	}}


## Samples every active monitor once per frame, storing a point only when the
## value changes. A property that never moves costs one sample, not one per frame.
func _sample_monitors() -> void:
	if _monitors.is_empty():
		return
	for key in _monitors:
		var monitor: Dictionary = _monitors[key]
		var node := _resolve_node(str(monitor["node_path"]))
		if node == null:
			continue
		var value: Variant = node.get(str(monitor["property"]))
		var text := str(value)
		if monitor["last"] != null and str(monitor["last"]) == text:
			continue
		var samples: Array = monitor["samples"]
		if samples.size() >= int(monitor["max_samples"]):
			continue
		monitor["last"] = text
		samples.append({"t": Time.get_ticks_msec() - int(monitor["started_ms"]), "value": text})


func _user_path(file: String) -> String:
	return OS.get_user_data_dir().path_join(file)


func _write_response(data: Dictionary) -> void:
	var file := FileAccess.open(_user_path(RESPONSE_FILE), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()
