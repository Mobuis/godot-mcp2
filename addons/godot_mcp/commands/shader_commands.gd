@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

func get_commands() -> Dictionary:
	return {
		"create_shader": _create_shader,
		"read_shader": _read_shader,
		"edit_shader": _edit_shader,
		"assign_shader_material": _assign_shader_material,
		"set_shader_param": _set_shader_param,
		"get_shader_params": _get_shader_params,
	}


func _create_shader(p: Dictionary) -> Dictionary:
	var path := _norm_res(p.get("shader_path", "res://shader.gdshader"))
	if path.is_empty():
		return _err(_path_error(p, "shader_path"))
	var shader_type: String = p.get("type", "spatial")
	var template := "shader_type %s;\n\nvoid fragment() {\n\tCOLOR = vec4(1.0);\n}\n" % shader_type
	if ResourceUtils.write_text(path, p.get("content", template)) != OK:
		return _err("Failed to write shader")
	return _ok({"shader_path": path})


func _read_shader(p: Dictionary) -> Dictionary:
	var path := _norm_res(p.get("shader_path", ""))
	if path.is_empty():
		return _err(_path_error(p, "shader_path"))
	return _ok({"content": ResourceUtils.read_text(path)})


func _edit_shader(p: Dictionary) -> Dictionary:
	var path := _norm_res(p.get("shader_path", ""))
	if path.is_empty():
		return _err(_path_error(p, "shader_path"))
	var content: String = p.get("content", "")
	if content.is_empty():
		var existing := ResourceUtils.read_text(path)
		content = existing.replace(p.get("search", ""), p.get("replace", ""))
	ResourceUtils.write_text(path, content)
	editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	return _ok({"updated": path})


## Where a ShaderMaterial lives depends on the node.
##
## `CanvasItem` has a `material` property. `GeometryInstance3D` does **not** — it
## has `material_override`. The old code assigned `node.material` for both, which
## on a MeshInstance3D threw "Invalid assignment of property 'material'", aborted
## the handler, and returned an empty result the server reported as success. So
## every 3D shader assignment silently did nothing, and the two parameter tools
## then correctly reported there was no material — the one visible symptom.
func _material_slot(node: Node) -> String:
	if node is CanvasItem:
		return "material"
	if node is GeometryInstance3D:
		return "material_override"
	return ""


func _shader_material_on(node: Node) -> ShaderMaterial:
	var slot := _material_slot(node)
	if slot.is_empty():
		return null
	var mat: Variant = node.get(slot)
	return mat as ShaderMaterial


func _assign_shader_material(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	var shader_path := _norm_res(p.get("shader_path", ""))
	if shader_path.is_empty():
		return _err(_path_error(p, "shader_path"))
	var shader: Shader = load(shader_path)
	if shader == null:
		return _err("Shader not found: %s" % shader_path)
	var slot := _material_slot(node)
	if slot.is_empty():
		return _err(
			"%s takes no material. Shader materials go on CanvasItem (2D) or GeometryInstance3D (3D)."
			% node.get_class()
		)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	node.set(slot, mat)
	# Confirm the assignment landed rather than assuming it did.
	if _shader_material_on(node) != mat:
		return _err("Assignment to %s.%s did not take" % [node.get_class(), slot])
	return _ok({"node_path": _scene_path(node), "slot": slot, "shader_path": shader_path})


func _set_shader_param(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	var mat := _shader_material_on(node)
	if mat == null:
		return _err("No ShaderMaterial on %s (checked '%s'). Call assign_shader_material first." % [node.get_class(), _material_slot(node)])
	var param := str(p.get("param", ""))
	mat.set_shader_parameter(param, _parse_value(str(p.get("value", ""))))
	return _ok({"param": param, "value": str(mat.get_shader_parameter(param))})


func _get_shader_params(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	var mat := _shader_material_on(node)
	if mat == null or mat.shader == null:
		return _err("No shader material on %s (checked '%s')" % [node.get_class(), _material_slot(node)])
	var params := {}
	for uniform in mat.shader.get_shader_uniform_list():
		params[uniform.name] = str(mat.get_shader_parameter(uniform.name))
	return _ok({"params": params, "slot": _material_slot(node)})
