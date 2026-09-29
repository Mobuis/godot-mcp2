extends Node
## Queues synthetic input events for the running game/editor.

## One file per batch, named by request id. The editor writes a temp name and
## renames it into place, and the game deletes each batch after reading it, so
## neither side rewrites a shared file. Shared with input_commands.gd.
const BATCH_PREFIX := "mcp_input_batch_"
## One ack file per request id, so concurrent callers do not overwrite each other.
const ACK_PREFIX := "mcp_input_ack_"
## Files are written under this prefix, then renamed, so no reader sees half a file.
const TMP_PREFIX := "mcp_input_tmp_"
## While idle, user:// is listed only every this many frames, to keep it cheap.
const IDLE_POLL_FRAMES := 3

## Input caps. The editor rejects over-cap requests and the bridge clamps again,
## since it acts on a file it did not write. A server timeout does not cancel
## Godot-side work, so an uncapped sequence would keep the game busy.
const MAX_EVENTS := 500
const MAX_FRAMES := 600
const MAX_DELAY_MS := 5000
const MAX_TOTAL_DELAY_MS := 10000
const MAX_TOTAL_FRAMES := 900
## Batches allowed to wait behind the running one. The rest stay on disk, where
## the editor counts them and refuses new requests.
const MAX_PENDING_BATCHES := 8
## A batch created before process start minus this margin is left over from an
## earlier run. The margin covers a batch queued while the engine was starting.
const STALE_MARGIN_SEC := 5.0

## Batches read from disk and not finished yet, oldest first.
var _batches: Array = []
## The batch being applied: {id, steps, idx, wait_frames, applied, start_frame,
## start_msec, last_frame, last_msec, done_frame}.
var _current: Dictionary = {}


func _ready() -> void:
	# T-101: this is an autoload injected into project.godot, so it would
	# otherwise ship in exported games. The "editor" feature tag is present when
	# running from the editor, including play-from-editor, and absent in every
	# export — debug or release. A debug-build check would not be enough.
	if not OS.has_feature("editor"):
		queue_free()
		return
	_discard_stale_files()


## Removes acks that an earlier run left in user://. Stale batches are
## dropped in _read_batches().
func _discard_stale_files() -> void:
	var dir := DirAccess.open(OS.get_user_data_dir())
	if dir != null:
		for f in dir.get_files():
			if f.begins_with(ACK_PREFIX):
				DirAccess.remove_absolute(OS.get_user_data_dir().path_join(f))


func _process_start_unix() -> float:
	return Time.get_unix_time_from_system() - float(Time.get_ticks_msec()) / 1000.0


## Queues events from inside the game, such as a replayed recording. Returns how
## many were accepted, or -1 when too many batches are already waiting.
func enqueue(events: Array) -> int:
	if _batches.size() >= MAX_PENDING_BATCHES:
		return -1
	var accepted: Array = events.filter(func(ev): return not sanitize(ev).is_empty())
	_batches.append({"id": "", "ack": false, "wait_frames": 0, "events": accepted})
	return accepted.size()


func _process(_delta: float) -> void:
	var idle := _current.is_empty() and _batches.is_empty()
	if not idle or Engine.get_process_frames() % IDLE_POLL_FRAMES == 0:
		_read_batches()
	if _current.is_empty() and not _batches.is_empty():
		_current = _start_batch(_batches.pop_front())
	if _current.is_empty():
		return
	_advance()


## Sort key from the id "<ticks_usec>-<seq>-<random>", compared numerically:
## a string sort puts "999999" after "1000000".
func _batch_order(id: String) -> Array:
	var parts := id.split("-")
	if parts.size() != 3:
		return []
	return [int(parts[0]), int(parts[1])]


func _read_batches() -> void:
	if _batches.size() >= MAX_PENDING_BATCHES:
		return
	var dir_path := OS.get_user_data_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var found: Array = []
	for f in dir.get_files():
		if not (f.begins_with(BATCH_PREFIX) and f.ends_with(".json")):
			continue
		var id := f.trim_prefix(BATCH_PREFIX).trim_suffix(".json")
		var order := _batch_order(id) if _is_safe_id(id) and id.length() <= 64 else []
		if order.is_empty():
			DirAccess.remove_absolute(dir_path.path_join(f))
			continue
		found.append({"id": id, "file": f, "order": order})
	if found.is_empty():
		return
	found.sort_custom(func(x, y): return x["order"] < y["order"])
	var stale_before := _process_start_unix() - STALE_MARGIN_SEC
	for entry in found:
		if _batches.size() >= MAX_PENDING_BATCHES:
			break
		var path: String = dir_path.path_join(entry["file"])
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		DirAccess.remove_absolute(path)
		# Skip non-batches and batches without a creation time (cannot be proven fresh).
		if not parsed is Dictionary or not parsed.get("events") is Array:
			continue
		if _num(parsed.get("created"), 0.0) < stale_before:
			continue
		parsed["id"] = entry["id"]
		_batches.append(parsed)


## `v` as a finite float, else `fallback`. int(1e30) is INT64_MIN in GDScript.
func _num(v: Variant, fallback: float) -> float:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return fallback
	var f := float(v)
	return f if is_finite(f) else fallback


func _clamp_int(v: Variant, fallback: float, lo: int, hi: int) -> int:
	return int(clampf(_num(v, fallback), float(lo), float(hi)))


## Turns a queue entry into steps. A mouse_click becomes a press step and a
## release step so they land in different frames.
func _start_batch(batch: Dictionary) -> Dictionary:
	var steps: Array = []
	var total_delay := 0
	var total_frames := 0
	var events: Array = batch["events"]
	for i in mini(events.size(), MAX_EVENTS):
		var raw = events[i]
		var ev := sanitize(raw)
		# A file this bridge did not write can hold anything; a bad event is
		# skipped rather than left to abort the sequencer on every frame.
		if ev.is_empty():
			continue
		ev["frames"] = raw.get("frames")
		ev["delay_ms"] = raw.get("delay_ms")
		# Default gap is the next frame; the first event only waits if asked.
		var frames := _clamp_int(ev.get("frames"), 1.0 if i > 0 else 0.0, 0, MAX_FRAMES)
		var delay := _clamp_int(ev.get("delay_ms"), 0.0, 0, MAX_DELAY_MS)
		delay = clampi(MAX_TOTAL_DELAY_MS - total_delay, 0, delay)
		frames = clampi(MAX_TOTAL_FRAMES - total_frames, 0, frames)
		total_delay += delay
		total_frames += frames
		if str(ev.get("type", "")) == "mouse_click":
			steps.append({"ev": ev, "phase": "press", "frames": frames, "delay": delay})
			steps.append({"ev": ev, "phase": "release", "frames": 1, "delay": 0})
			total_frames += 1
		else:
			steps.append({"ev": ev, "phase": "", "frames": frames, "delay": delay})
	var now_frame := Engine.get_process_frames()
	var now_msec := Time.get_ticks_msec()
	return {
		"id": str(batch.get("id", "")),
		"ack": bool(batch.get("ack", false)),
		"steps": steps,
		"idx": 0,
		"applied": 0,
		"wait_frames": _clamp_int(batch.get("wait_frames"), 0.0, 0, MAX_FRAMES),
		"start_frame": now_frame,
		"start_msec": now_msec,
		"last_frame": now_frame,
		"last_msec": now_msec,
		"done_frame": -1,
	}


func _advance() -> void:
	var frame := Engine.get_process_frames()
	var now := Time.get_ticks_msec()
	var applied_any := false
	var steps: Array = _current["steps"]
	while _current["idx"] < steps.size():
		var step: Dictionary = steps[_current["idx"]]
		if frame - int(_current["last_frame"]) < int(step["frames"]):
			break
		if now - int(_current["last_msec"]) < int(step["delay"]):
			break
		_apply_step(step)
		applied_any = true
		_current["idx"] += 1
		if step["phase"] != "press":
			_current["applied"] += 1
		_current["last_frame"] = frame
		_current["last_msec"] = now
	# parse_input_event only *queues*; the queue is drained at the start of the
	# next engine iteration. Without this, a caller that acts and then
	# immediately inspects or screenshots reads pre-event state and concludes
	# the input did nothing.
	if applied_any:
		Input.flush_buffered_events()
	if _current["idx"] >= steps.size():
		if int(_current["done_frame"]) < 0:
			_current["done_frame"] = frame
		if frame - int(_current["done_frame"]) >= int(_current["wait_frames"]):
			_finish_batch(frame, now)


func _apply_step(step: Dictionary) -> void:
	var ev: Dictionary = step["ev"]
	match step["phase"]:
		"press":
			_apply_mouse_button(ev, true)
		"release":
			_apply_mouse_button(ev, false)
		_:
			apply_event(ev)


func _finish_batch(frame: int, now: int) -> void:
	var id: String = _current["id"]
	# Only digits and dashes are accepted because the id becomes a file name.
	if _current["ack"] and not id.is_empty() and id.length() <= 64 and _is_safe_id(id):
		# Temp name then rename, so the editor never reads a half-written file.
		var tmp := OS.get_user_data_dir().path_join(TMP_PREFIX + "ack_" + id + ".json")
		var file := FileAccess.open(tmp, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify({
				"id": id,
				"applied": _current["applied"],
				"frames": frame - int(_current["start_frame"]),
				"elapsed_ms": now - int(_current["start_msec"]),
			}))
			file.close()
			DirAccess.rename_absolute(tmp, OS.get_user_data_dir().path_join(ACK_PREFIX + id + ".json"))
	_current = {}


func _is_safe_id(id: String) -> bool:
	for i in id.length():
		var c := id.unicode_at(i)
		if not ((c >= 48 and c <= 57) or c == 45):
			return false
	return true


## Public so MCPRuntimeBridge's replay path can reuse it. Replaying a recorded
## event and simulating a fresh one have to build the event the same way, or
## replay quietly behaves differently from the tool that produced the recording.
## The event with its fields checked and converted, or {} when it cannot be
## applied. Batch files and replayed recordings arrive as untyped JSON.
static func sanitize(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var type := str(raw.get("type", ""))
	var ev := {"type": type, "pressed": raw.get("pressed", true)}
	if typeof(ev["pressed"]) != TYPE_BOOL:
		return {}
	for key in ["keycode", "physical_keycode", "x", "y", "button"]:
		if raw.has(key):
			var v: Variant = raw[key]
			if not (typeof(v) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(float(v)):
				return {}
			ev[key] = v
	match type:
		"key":
			if not ev.has("keycode"):
				return {}
		"mouse_click":
			var button := int(ev.get("button", MOUSE_BUTTON_LEFT))
			if button < MOUSE_BUTTON_LEFT or button > MOUSE_BUTTON_XBUTTON2:
				return {}
		"mouse_move":
			pass
		"action":
			ev["action"] = str(raw.get("action", ""))
			if ev["action"].is_empty():
				return {}
		_:
			return {}
	return ev


## Applies one event at once. Returns false when the event is invalid.
func apply_event(raw: Dictionary) -> bool:
	var ev := sanitize(raw)
	if ev.is_empty():
		return false
	match ev["type"]:
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
			_apply_mouse_button(ev, true)
			_apply_mouse_button(ev, false)
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
	return true


## One half of a click. apply_event() emits both halves together; the sequencer
## uses separate frames.
func _apply_mouse_button(ev: Dictionary, pressed: bool) -> void:
	var point := Vector2(ev.get("x", 0), ev.get("y", 0))
	var e := InputEventMouseButton.new()
	e.position = point
	e.global_position = point
	e.button_index = int(ev.get("button", MOUSE_BUTTON_LEFT))
	e.pressed = pressed
	if pressed:
		# Move the real pointer first: games that pick from the cursor read
		# get_viewport().get_mouse_position(), not the event position.
		Input.warp_mouse(point)
		e.button_mask = _mask_for(e.button_index)
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
