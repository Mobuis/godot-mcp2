@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

func get_commands() -> Dictionary:
	return {
		"setup_navigation_region": _setup_navigation_region,
		"setup_navigation_agent": _setup_navigation_agent,
		"bake_navigation_mesh": _bake_navigation_mesh,
		"set_navigation_layers": _set_navigation_layers,
		"get_navigation_info": _get_navigation_info,
		"get_navigation_path": _get_navigation_path,
	}


func _setup_navigation_region(p: Dictionary) -> Dictionary:
	var parent := _resolve_node(p.get("parent_path", "."))
	if parent == null:
		return _err("Parent not found")
	var is_3d: bool = p.get("is_3d", true)
	var region := NavigationRegion3D.new() if is_3d else NavigationRegion2D.new()
	region.name = p.get("name", "NavigationRegion")
	# A region with no mesh resource cannot be baked. The engine logged "Baking the
	# navigation mesh requires a valid NavigationMesh resource" while
	# bake_navigation_mesh still answered {"baked": true}, so give the region
	# something to bake into.
	if is_3d:
		region.navigation_mesh = NavigationMesh.new()
	else:
		region.navigation_polygon = NavigationPolygon.new()
	parent.add_child(region, true)
	region.owner = _edited_root()
	_mark_unsaved()
	return _ok({"path": _scene_path(region), "has_mesh": true})


func _setup_navigation_agent(p: Dictionary) -> Dictionary:
	var parent := _resolve_node(p.get("parent_path", "."))
	if parent == null:
		return _err("Parent not found")
	var agent := NavigationAgent3D.new() if p.get("is_3d", true) else NavigationAgent2D.new()
	agent.name = p.get("name", "NavigationAgent")
	if "max_speed" in agent:
		agent.max_speed = float(p.get("max_speed", 5.0))
	parent.add_child(agent, true)
	agent.owner = _edited_root()
	_mark_unsaved()
	return _ok({"path": _scene_path(agent)})


func _bake_navigation_mesh(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	# Baking without a mesh resource is an engine-level error the caller never saw:
	# the region logged a complaint and this returned {"baked": true} regardless.
	if node is NavigationRegion3D:
		if node.navigation_mesh == null:
			return _err("%s has no NavigationMesh to bake into. Assign one, or create the region with setup_navigation_region." % node.name)
		node.bake_navigation_mesh()
	elif node is NavigationRegion2D:
		if node.navigation_polygon == null:
			return _err("%s has no NavigationPolygon to bake into." % node.name)
		node.bake_navigation_polygon()
	else:
		return _err("NavigationRegion node required, got %s" % node.get_class())
	_mark_unsaved()
	return _ok({"baked": true, "node_path": _scene_path(node)})


func _set_navigation_layers(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	if "navigation_layers" in node:
		node.navigation_layers = int(p.get("layers", 1))
	_mark_unsaved()
	return _ok({"layers": p.get("layers", 1)})


func _get_navigation_info(p: Dictionary) -> Dictionary:
	var node := _resolve_node(p.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	return _ok({
		"type": node.get_class(),
		"layers": node.navigation_layers if "navigation_layers" in node else 0,
	})


func _get_navigation_path(p: Dictionary) -> Dictionary:
	var map := NavigationServer2D.get_maps()
	if map.is_empty():
		return _ok({"path": [], "note": "No navigation map"})
	var from := Vector2(float(p.get("from_x", 0)), float(p.get("from_y", 0)))
	var to := Vector2(float(p.get("to_x", 0)), float(p.get("to_y", 0)))
	var path := NavigationServer2D.map_get_path(map[0], from, to, true)
	var points: Array = []
	for pt in path:
		points.append({"x": pt.x, "y": pt.y})
	return _ok({"path": points})
