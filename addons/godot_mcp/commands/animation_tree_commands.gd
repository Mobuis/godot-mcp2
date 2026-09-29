@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

func get_commands() -> Dictionary:
	return {
		"create_animation_tree": _create_animation_tree,
		"get_animation_tree_structure": _get_animation_tree_structure,
		"set_tree_parameter": _set_tree_parameter,
		"add_state_machine_state": _add_state_machine_state,
		"remove_state_machine_state": _remove_state_machine_state,
		"add_state_machine_transition": _add_state_machine_transition,
		"remove_state_machine_transition": _remove_state_machine_transition,
		"set_blend_tree_node": _set_blend_tree_node,
		"set_state_machine_root": _set_state_machine_root,
	}


func _get_tree(path: String) -> AnimationTree:
	var node := _resolve_node(path)
	return node if node is AnimationTree else null


## The four state-machine tools need `tree_root` to be an AnimationNodeStateMachine.
## Nothing could produce one — `set_blend_tree_node` installs a *BlendTree* — so all
## four were unreachable through the MCP. Worse, once a BlendTree root existed they
## stopped erroring cleanly and started aborting on the cast instead, which the
## server then reported as success. Returns the state machine or a real error
## naming the root that is actually installed.
func _state_machine(p: Dictionary) -> Variant:
	var tree := _get_tree(p.get("node_path", ""))
	if tree == null:
		return _err("AnimationTree not found at '%s'" % p.get("node_path", ""))
	if tree.tree_root == null:
		return _err("AnimationTree has no tree_root. Call set_state_machine_root first.")
	if not tree.tree_root is AnimationNodeStateMachine:
		return _err(
			"tree_root is a %s, not an AnimationNodeStateMachine. Call set_state_machine_root to replace it."
			% tree.tree_root.get_class()
		)
	return tree.tree_root


func _set_state_machine_root(p: Dictionary) -> Dictionary:
	var tree := _get_tree(p.get("node_path", ""))
	if tree == null:
		return _err("AnimationTree not found at '%s'" % p.get("node_path", ""))
	tree.tree_root = AnimationNodeStateMachine.new()
	_mark_unsaved()
	return _ok({"tree_root": "AnimationNodeStateMachine", "node_path": p.get("node_path", "")})


func _create_animation_tree(p: Dictionary) -> Dictionary:
	var parent := _resolve_node(p.get("parent_path", "."))
	if parent == null:
		return _err("Parent not found")
	var tree := AnimationTree.new()
	tree.name = p.get("name", "AnimationTree")
	var player_path: String = p.get("anim_player_path", "")
	if not player_path.is_empty():
		tree.anim_player = NodePath(player_path)
	parent.add_child(tree, true)
	tree.owner = _edited_root()
	_mark_unsaved()
	return _ok({"path": _scene_path(tree)})


func _get_animation_tree_structure(p: Dictionary) -> Dictionary:
	var tree := _get_tree(p.get("node_path", ""))
	if tree == null:
		return _err("AnimationTree not found")
	# `AnimationTree.get_parameter_list()` does not exist in Godot 4.7 — there are no
	# parameter methods at all. Blend parameters are plain properties under the
	# `parameters/` prefix, so enumerate them from the property list.
	var params := {}
	for prop in tree.get_property_list():
		var pname: String = prop.get("name", "")
		if pname.begins_with("parameters/"):
			params[pname] = _serialize_value(tree.get(pname))
	return _ok({
		"active": tree.active,
		"tree_root": tree.tree_root.get_class() if tree.tree_root else "",
		"anim_player": str(tree.anim_player),
		"parameters": params,
		"parameter_count": params.size(),
	})


func _set_tree_parameter(p: Dictionary) -> Dictionary:
	var tree := _get_tree(p.get("node_path", ""))
	if tree == null:
		return _err("AnimationTree not found")
	var param: String = p.get("parameter", "")
	tree.set(param, _parse_value(str(p.get("value", "0"))))
	_mark_unsaved()
	return _ok({"parameter": param})


func _add_state_machine_state(p: Dictionary) -> Dictionary:
	var found: Variant = _state_machine(p)
	if found is Dictionary:
		return found
	var sm: AnimationNodeStateMachine = found
	var state_name: String = p.get("state_name", "NewState")
	var anim_node := AnimationNodeAnimation.new()
	var anim_name: String = p.get("animation", "")
	if not anim_name.is_empty():
		anim_node.animation = anim_name
	sm.add_node(state_name, anim_node)
	_mark_unsaved()
	return _ok({"state": state_name, "states": sm.get_node_list()})


func _remove_state_machine_state(p: Dictionary) -> Dictionary:
	var found: Variant = _state_machine(p)
	if found is Dictionary:
		return found
	var sm: AnimationNodeStateMachine = found
	var state_name: String = p.get("state_name", "")
	if not sm.has_node(state_name):
		return _err("No such state: '%s'. States: %s" % [state_name, sm.get_node_list()])
	sm.remove_node(state_name)
	_mark_unsaved()
	return _ok({"removed": state_name, "states": sm.get_node_list()})


func _add_state_machine_transition(p: Dictionary) -> Dictionary:
	var found: Variant = _state_machine(p)
	if found is Dictionary:
		return found
	var sm: AnimationNodeStateMachine = found
	var from_state: String = p.get("from", "")
	var to_state: String = p.get("to", "")
	for state in [from_state, to_state]:
		if not sm.has_node(state):
			return _err("No such state: '%s'. States: %s" % [state, sm.get_node_list()])
	sm.add_transition(from_state, to_state, AnimationNodeStateMachineTransition.new())
	_mark_unsaved()
	return _ok({"from": from_state, "to": to_state, "transition_count": sm.get_transition_count()})


func _remove_state_machine_transition(p: Dictionary) -> Dictionary:
	var found: Variant = _state_machine(p)
	if found is Dictionary:
		return found
	var sm: AnimationNodeStateMachine = found
	var from_state: String = p.get("from", "")
	var to_state: String = p.get("to", "")
	if not sm.has_transition(from_state, to_state):
		return _err("No transition '%s' -> '%s'" % [from_state, to_state])
	sm.remove_transition(from_state, to_state)
	_mark_unsaved()
	return _ok({"removed": true, "transition_count": sm.get_transition_count()})


func _set_blend_tree_node(p: Dictionary) -> Dictionary:
	var tree := _get_tree(p.get("node_path", ""))
	if tree == null:
		return _err("AnimationTree not found")
	var blend := AnimationNodeBlendTree.new()
	tree.tree_root = blend
	_mark_unsaved()
	return _ok({"blend_tree": true, "note": "Created new BlendTree root"})
