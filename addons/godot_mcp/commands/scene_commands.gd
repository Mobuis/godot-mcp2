@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

const InputBridge = preload("res://addons/godot_mcp/services/mcp_input_bridge.gd")


func get_commands() -> Dictionary:
	return {
		"get_scene_tree": _get_scene_tree,
		"get_scene_file_content": _get_scene_file_content,
		"open_scene": _open_scene,
		"save_scene": _save_scene,
		"create_scene": _create_scene,
		"play_scene": _play_scene,
		"stop_scene": _stop_scene,
		"delete_scene": _delete_scene,
		"add_scene_instance": _add_scene_instance,
		"get_scene_exports": _get_scene_exports,
	}


func _get_scene_tree(_params: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return _ok({"scene": null, "message": "No scene is currently open"})
	return _ok({
		"scene_path": root.scene_file_path,
		"root": _node_to_dict(root),
	})


func _get_scene_file_content(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		var root := _edited_root()
		if root == null:
			return _err("No scene open and no scene_path provided")
		scene_path = root.scene_file_path
	scene_path = _norm_res(scene_path)
	if scene_path.is_empty():
		return _err(_path_error(params, "scene_path"))
	if not FileAccess.file_exists(scene_path):
		return _err("Scene file not found: %s" % scene_path, -32001)
	return _ok({"scene_path": scene_path, "content": FileAccess.get_file_as_string(scene_path)})


func _open_scene(params: Dictionary) -> Dictionary:
	var scene_path := _norm_res(params.get("scene_path", ""))
	if scene_path.is_empty():
		return _err(_path_error(params, "scene_path"))
	if not FileAccess.file_exists(scene_path):
		return _err("Scene file not found: %s" % scene_path, -32001)
	editor_plugin.get_editor_interface().open_scene_from_path(scene_path)
	return _ok({"scene_path": scene_path, "opened": true})


func _save_scene(_params: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return _err("No scene is open")
	var path := root.scene_file_path
	if path.is_empty():
		return _err("Scene has no file path — save manually first or use create_scene")
	# Every command runs from a call_deferred, i.e. inside the message-queue
	# flush, and EditorInterface.save_scene() puts up a progress dialog — which the
	# engine refuses to do from there ("Do not use progress dialog (task) while
	# flushing the message queue"). The save still happened, but it logged an error
	# on every call, and a log that is always red is a log nobody reads. Stepping
	# to the next frame first leaves the flush and the dialog is allowed.
	await editor_plugin.get_tree().process_frame
	# A scene save also writes modified external resources without emitting
	# signals, so they are found by fingerprinting their files before and after.
	# The signals still report the scene; collection ends one frame after the save.
	var written: Array = []
	var on_resource := func(res: Resource) -> void:
		if res != null:
			_note_written(written, res.resource_path)
	var on_scene := func(file_path: String) -> void:
		_note_written(written, file_path)
	var checked := _checkable_files(_external_resource_paths(root))
	var before := _fingerprint_files(checked["files"])
	editor_plugin.resource_saved.connect(on_resource)
	editor_plugin.scene_saved.connect(on_scene)
	var err := editor_plugin.get_editor_interface().save_scene()
	if err == OK:
		await editor_plugin.get_tree().process_frame
	editor_plugin.resource_saved.disconnect(on_resource)
	editor_plugin.scene_saved.disconnect(on_scene)
	if err != OK:
		return _err("Failed to save %s (error %d)" % [path, err])
	# The save returned OK, so the scene was written even if its signal did not arrive.
	if path not in written:
		written.insert(0, path)
	var after := _fingerprint_files(before.keys())
	for file_path in after:
		if after[file_path] != before[file_path]:
			_note_written(written, file_path)
	var result := {"scene_path": path, "saved": true, "files_written": written}
	var notes: Array = []
	var others := written.filter(func(f: String) -> bool: return f != path)
	if not others.is_empty():
		notes.append(
			"Besides the scene, the editor also wrote %d external resource file(s) that were modified in memory: %s. "
			% [others.size(), ", ".join(others)]
			+ "This is standard editor behaviour when a scene is saved."
		)
	if not checked["unchecked"].is_empty():
		notes.append(
			"%d external resource file(s) were not checked for changes (limits: %d files, %d MB each, %d MB in total), so files_written may be incomplete: %s"
			% [checked["unchecked"].size(), MAX_FINGERPRINT_FILES, MAX_FINGERPRINT_BYTES / 1048576, MAX_FINGERPRINT_TOTAL_BYTES / 1048576, ", ".join(checked["unchecked"])]
		)
	if not notes.is_empty():
		result["note"] = " ".join(notes)
	return _ok(result)


## Records a saved file once, in save order. Sub-resources report paths like
## `res://a.tscn::Mesh_1`; they belong to the scene file, so they are skipped.
func _note_written(written: Array, file_path: String) -> void:
	if file_path.is_empty() or "::" in file_path or file_path in written:
		return
	written.append(file_path)


## Only formats the editor writes for in-memory resources. Imported assets (png,
## glb, ogg...) are never rewritten by a scene save, and hashing them is costly.
const SAVABLE_RESOURCE_EXTENSIONS := ["tres", "res", "material", "anim", "mesh", "theme"]
## Bounds on the before/after hashing so a scene with many or huge resource files
## cannot slow every save. Files past the bounds are reported as unchecked.
const MAX_FINGERPRINT_FILES := 256
const MAX_FINGERPRINT_BYTES := 32 * 1048576
const MAX_FINGERPRINT_TOTAL_BYTES := 64 * 1048576
const MAX_CONTAINER_DEPTH := 8


## Splits paths into those worth fingerprinting and those left unchecked.
func _checkable_files(paths: Array) -> Dictionary:
	var files: Array = []
	var unchecked: Array = []
	var total := 0
	for file_path in paths:
		var size := 0
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
		if files.size() >= MAX_FINGERPRINT_FILES or size > MAX_FINGERPRINT_BYTES or total + size > MAX_FINGERPRINT_TOTAL_BYTES:
			unchecked.append(file_path)
		else:
			files.append(file_path)
			total += size
	return {"files": files, "unchecked": unchecked}


## Maps each file to its content hash, "" when missing. Not the modification time:
## its one-second resolution would hide a second save within the same second.
func _fingerprint_files(paths: Array) -> Dictionary:
	var out := {}
	for file_path in paths:
		out[file_path] = FileAccess.get_sha256(file_path) if FileAccess.file_exists(file_path) else ""
	return out


## External resource files (`res://x.tres`, not built-in sub-resources, scripts or
## imported assets) reachable from node's subtree through stored properties.
func _external_resource_paths(node: Node) -> Array:
	var paths: Array = []
	var seen := {}
	_walk_external_resources(node, seen, paths)
	return paths


func _is_savable_external(res_path: String) -> bool:
	if not res_path.begins_with("res://") or "::" in res_path:
		return false
	if res_path.get_extension().to_lower() not in SAVABLE_RESOURCE_EXTENSIONS:
		return false
	# An import sidecar means the file is a source asset, not something the editor saves.
	return not FileAccess.file_exists(res_path + ".import")


func _walk_external_resources(obj: Object, seen: Dictionary, paths: Array) -> void:
	if obj is Resource:
		if seen.has(obj) or obj is Script:
			return
		seen[obj] = true
		var res_path: String = (obj as Resource).resource_path
		if _is_savable_external(res_path) and not res_path in paths:
			paths.append(res_path)
		# Listing the properties of a ShaderMaterial with no shader makes the
		# engine log 'Parameter "shader" is null'; it holds no resources to find.
		if obj is ShaderMaterial and (obj as ShaderMaterial).shader == null:
			return
	for prop in obj.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_STORAGE == 0:
			continue
		# Only values that can hold a resource are read; get() on a mesh's or an
		# image's packed arrays would copy them for nothing.
		var type := int(prop["type"])
		var variant := type == TYPE_NIL and int(prop["usage"]) & PROPERTY_USAGE_NIL_IS_VARIANT != 0
		if type in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY] or variant:
			_walk_external_value(obj.get(str(prop["name"])), seen, paths, 0)
	if obj is Node:
		for child in (obj as Node).get_children():
			_walk_external_resources(child, seen, paths)


## Collects resource files from a property value. `depth` bounds Arrays and
## Dictionaries, which can contain themselves.
func _walk_external_value(value: Variant, seen: Dictionary, paths: Array, depth: int) -> void:
	if value is Resource:
		_walk_external_resources(value, seen, paths)
	elif depth >= MAX_CONTAINER_DEPTH:
		return
	elif value is Array:
		for item in value:
			_walk_external_value(item, seen, paths, depth + 1)
	elif value is Dictionary:
		for key in value:
			_walk_external_value(value[key], seen, paths, depth + 1)


func _create_scene(params: Dictionary) -> Dictionary:
	var scene_path := _norm_res(params.get("scene_path", ""))
	var root_type: String = params.get("root_type", "Node2D")
	if scene_path.is_empty():
		return _err(_path_error(params, "scene_path"))
	if FileAccess.file_exists(scene_path) and not params.get("overwrite", false):
		return _err("Scene already exists: %s" % scene_path, -32002, {"suggestion": "Set overwrite=true to replace"})

	if not ClassDB.class_exists(root_type):
		return _err("Unknown node type: %s" % root_type)

	var root: Node = ClassDB.instantiate(root_type)
	root.name = scene_path.get_file().get_basename()
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, scene_path)
	root.free()
	if err != OK:
		return _err("Failed to create scene: error %d" % err)
	# Overwriting a scene the editor already has open leaves that tab holding the
	# *old* contents. The next save_scene then writes the stale version back over
	# the new file, and in the meantime every node tool operates on a tree the
	# caller believes it just replaced. Force the open tab to re-read from disk.
	var ei := editor_plugin.get_editor_interface()
	var was_open: bool = scene_path in ei.get_open_scenes()
	if was_open:
		ei.reload_scene_from_path(scene_path)

	# Opening is the useful default, but it is also what made every scene the MCP
	# created undeletable: delete_scene refuses while a tab still holds the file.
	# Callers building throwaway scenes can now opt out.
	var opened: bool = params.get("open", true)
	if opened:
		ei.open_scene_from_path(scene_path)
	return _ok({
		"scene_path": scene_path,
		"root_type": root_type,
		"created": true,
		"opened": opened or was_open,
		"reloaded_open_tab": was_open,
	})


func _play_scene(params: Dictionary) -> Dictionary:
	var mode: String = params.get("mode", "current")
	var scene_path := ""
	if mode != "main" and mode != "current":
		scene_path = _norm_res(params.get("scene_path", ""))
		if scene_path.is_empty():
			return _err("Custom play mode: %s" % _path_error(params, "scene_path"))
	# Drop input batches and acks that an earlier run left in user://, so
	# they are not replayed into the new game.
	var user_dir := DirAccess.open(OS.get_user_data_dir())
	if user_dir != null:
		for f in user_dir.get_files():
			if f.begins_with(InputBridge.BATCH_PREFIX) or f.begins_with(InputBridge.TMP_PREFIX) or f.begins_with(InputBridge.ACK_PREFIX):
				DirAccess.remove_absolute(OS.get_user_data_dir().path_join(f))
	match mode:
		"main":
			editor_plugin.get_editor_interface().play_main_scene()
		"current":
			editor_plugin.get_editor_interface().play_current_scene()
		_:
			editor_plugin.get_editor_interface().play_custom_scene(scene_path)
	return _ok({"playing": true, "mode": mode})


func _stop_scene(_params: Dictionary) -> Dictionary:
	editor_plugin.get_editor_interface().stop_playing_scene()
	return _ok({"playing": false})


func _delete_scene(params: Dictionary) -> Dictionary:
	var scene_path := _norm_res(params.get("scene_path", ""))
	if scene_path.is_empty():
		return _err(_path_error(params, "scene_path"))
	if not (scene_path.get_extension().to_lower() in ["tscn", "scn"]):
		return _err("delete_scene only deletes .tscn or .scn files, got: %s" % scene_path)
	if not FileAccess.file_exists(scene_path):
		return _err("Scene not found: %s" % scene_path)
	# T-105: normalize_res() rejects "..", but res:// can still be remapped, so
	# confine the resolved absolute path to the project directory before deleting.
	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not _is_inside_project(abs_path):
		return _err("Refusing to delete outside the project directory: %s" % scene_path)

	# Deleting a scene the editor still has open leaves it holding an in-memory
	# copy that can be written back to disk, so the file reappears and the delete
	# silently does not stick.
	#
	# The original note here said Godot exposes no way to close a scene tab, and
	# refused. `EditorInterface.close_scene()` does exist in 4.7 — it closes the
	# *current* scene — so the tab can be closed properly. Still opt-in: closing a
	# tab out from under someone is not something to do by default.
	var ei := editor_plugin.get_editor_interface()
	if scene_path in ei.get_open_scenes():
		if not params.get("close_if_open", false):
			return _err(
				"Scene is open in the editor: %s. Close its tab first, or pass close_if_open=true — deleting it now would leave the editor holding a copy that can be written back to disk." % scene_path,
				-32003
			)
		if scene_path in ei.get_unsaved_scenes():
			return _err(
				"Scene has unsaved changes: %s. Save or discard them before deleting." % scene_path,
				-32003
			)
		# close_scene() acts on whichever scene is current, so bring the target to
		# the front, close it, then restore whatever was being edited before.
		var previous := ""
		var edited := _edited_root()
		if edited != null:
			previous = edited.scene_file_path
		ei.open_scene_from_path(scene_path)
		ei.close_scene()
		if not previous.is_empty() and previous != scene_path and FileAccess.file_exists(previous):
			ei.open_scene_from_path(previous)
		if scene_path in ei.get_open_scenes():
			return _err("Could not close the scene tab for %s" % scene_path, -32003)

	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		return _err("Failed to delete scene")
	editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	return _ok({"deleted": scene_path})


func _add_scene_instance(params: Dictionary) -> Dictionary:
	var scene_path := _norm_res(params.get("scene_path", ""))
	var parent_path: String = params.get("parent_path", ".")
	var instance_name: String = params.get("name", "")
	if scene_path.is_empty():
		return _err(_path_error(params, "scene_path"))
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return _err("Failed to load scene: %s" % scene_path)
	var parent := _resolve_node(parent_path)
	if parent == null:
		return _err("Parent not found")
	var inst := packed.instantiate()
	if not instance_name.is_empty():
		inst.name = instance_name
	var root := _edited_root()
	editor_plugin.get_undo_redo().create_action("MCP Instance Scene")
	editor_plugin.get_undo_redo().add_do_method(parent, "add_child", inst, true)
	editor_plugin.get_undo_redo().add_do_method(inst, "set_owner", root)
	editor_plugin.get_undo_redo().add_undo_method(parent, "remove_child", inst)
	editor_plugin.get_undo_redo().commit_action()
	return _ok({"path": _scene_path(inst), "scene": scene_path})


func _get_scene_exports(p: Dictionary) -> Dictionary:
	var path := _norm_res(p.get("path", p.get("scene_path", "")))
	if path.is_empty() and _edited_root():
		path = _edited_root().scene_file_path
	if path.is_empty():
		return _err(_path_error(p, "scene_path"))
	if not FileAccess.file_exists(path):
		return _err("Scene not found: %s" % path)
	var packed: PackedScene = load(path)
	if packed == null:
		return _err("Failed to load scene")
	var instance := packed.instantiate()
	var nodes_data: Array = []
	_collect_exports(instance, instance, nodes_data)
	instance.free()
	return _ok({"path": path, "nodes": nodes_data, "count": nodes_data.size()})


func _collect_exports(node: Node, root: Node, out: Array) -> void:
	var script: Script = node.get_script()
	if script:
		var exports := {}
		for info in script.get_script_property_list():
			if (info.usage & PROPERTY_USAGE_EDITOR) and (info.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
				exports[info.name] = _serialize_value(node.get(info.name))
		if not exports.is_empty():
			out.append({
				"node_path": "." if node == root else str(root.get_path_to(node)),
				"node_name": node.name,
				"node_type": node.get_class(),
				"script_path": script.resource_path,
				"exports": exports,
			})
	for child in node.get_children():
		_collect_exports(child, root, out)
