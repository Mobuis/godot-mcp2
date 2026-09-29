@tool
extends RefCounted
class_name MCPPropertyAccess
## Typed property writes, shared by the editor commands and the runtime bridge.
##
## Values are parsed against the property's declared type, and a write is judged
## by the value read back. Property names may be paths such as `dye:tint` or
## `position:x`, resolved like Object.get_indexed().

const TypeParser = preload("res://addons/godot_mcp/utils/type_parser.gd")
const ResourceUtils = preload("res://addons/godot_mcp/utils/resource_utils.gd")

const NEW_PREFIX := "new:"

## What an untyped property looks like in a property list.
const UNTYPED := {"type": TYPE_NIL, "hint": PROPERTY_HINT_NONE, "hint_string": "", "usage": PROPERTY_USAGE_NIL_IS_VARIANT}

## Property-list entries that are Inspector headings, not properties.
const HEADING_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP


## Properties no value tool may write, with the reason given to the caller.
const REFUSED := {
	"script": "assigning a script runs its code; use attach_script in the editor",
	"resource_path": "it changes which file the resource is saved as",
}


## Why the path may not be written, or "" when it may.
static func refused(property: String) -> String:
	for segment in property.split(":"):
		if REFUSED.has(segment.strip_edges()):
			return "'%s' cannot be set: %s" % [property, REFUSED[segment.strip_edges()]]
	return ""


## True when any segment of the path is `script`. Assigning a script runs its
## code, so every property tool refuses it (see SECURITY.md).
static func touches_script(property: String) -> bool:
	for segment in property.split(":"):
		if segment.strip_edges() == "script":
			return true
	return false


## Resolves `property` on target. Returns the property-list entry of the last
## segment plus "holder", the object that owns it, or {"error": …}. A value-type
## component such as `position:x` takes its type from the current value.
static func describe(target: Object, property: String) -> Dictionary:
	if property.strip_edges().is_empty():
		return {"error": "Missing 'property'"}
	var segments := property.split(":")
	var holder: Object = target
	for i in segments.size():
		var segment := segments[i]
		if segment.is_empty():
			return {"error": "Empty segment in property path '%s'" % property}
		var refusal := refused(property)
		if not refusal.is_empty():
			return {"error": refusal}
		if holder == null:
			var current: Variant = target.get_indexed(NodePath(property))
			if current != null:
				return {"type": typeof(current), "hint": PROPERTY_HINT_NONE, "hint_string": "", "usage": 0, "holder": null}
			# A key the Dictionary does not have yet: set_indexed() adds it.
			var parent: Variant = target.get_indexed(NodePath(":".join(segments.slice(0, i))))
			if typeof(parent) == TYPE_DICTIONARY and i == segments.size() - 1:
				return UNTYPED.merged({"holder": null})
			return {"error": "'%s' cannot be reached: '%s' is not an object property" % [property, ":".join(segments.slice(0, i))]}
		var info := _find_property(holder, segment)
		if info.is_empty() and segment.begins_with("metadata/"):
			# Metadata is created by setting it, as in the Inspector.
			info = UNTYPED
		if info.is_empty():
			return {"error": "%s has no property '%s'%s" % [_label(holder), segment, _placeholder_hint(holder)]}
		if i == segments.size() - 1:
			var out := info.duplicate()
			out["holder"] = holder
			var current_value: Variant = holder.get(segment)
			if current_value is Array and current_value.is_typed():
				out["array_type"] = current_value
			return out
		var next: Variant = holder.get(segment)
		if info.type == TYPE_OBJECT or typeof(next) == TYPE_OBJECT:
			if next == null:
				return {"error": "'%s' is null, so '%s' cannot be reached" % [":".join(segments.slice(0, i + 1)), property]}
			holder = next
		else:
			holder = null
	return {"error": "Invalid property path '%s'" % property}


static func _find_property(holder: Object, name: String) -> Dictionary:
	for info in holder.get_property_list():
		if info.usage & HEADING_USAGE:
			continue
		if info.name == name:
			return info
	return {}


## In the editor, properties a non-@tool script builds in code do not exist.
static func _placeholder_hint(obj: Object) -> String:
	var script: Script = obj.get_script()
	if Engine.is_editor_hint() and script != null and not script.is_tool():
		return " (its script is not @tool, so properties it defines in code only exist in the running game)"
	return ""


static func _label(obj: Object) -> String:
	var script: Script = obj.get_script()
	if script != null and not script.get_global_name().is_empty():
		return script.get_global_name()
	return obj.get_class()


## Parses text as the type `info` declares. Returns {"value": …} or {"error": …}.
## Text that does not parse is refused, never converted: type_convert() turns
## "abc" into 0 without complaint.
static func parse(info: Dictionary, text: String) -> Dictionary:
	var type: int = info.get("type", TYPE_NIL)
	var trimmed := text.strip_edges()
	match type:
		TYPE_NIL:
			# Untyped `var`: nothing to parse against.
			return {"value": TypeParser.parse(text)}
		TYPE_STRING:
			return {"value": text}
		TYPE_STRING_NAME:
			return {"value": StringName(text)}
		TYPE_NODE_PATH:
			return {"value": NodePath(trimmed)}
		TYPE_BOOL:
			match trimmed.to_lower():
				"true", "1":
					return {"value": true}
				"false", "0":
					return {"value": false}
			return {"error": "expected a bool (true or false), got '%s'" % text}
		TYPE_INT:
			return _parse_int(info, trimmed)
		TYPE_FLOAT:
			if trimmed.is_valid_float() and is_finite(float(trimmed)):
				return {"value": float(trimmed)}
			return {"error": "expected a finite number, got '%s'" % text}
		TYPE_OBJECT:
			return _parse_object(info, trimmed)
		TYPE_COLOR:
			if trimmed.begins_with("Color("):
				# Three components are accepted as well as four.
				var numbers: Variant = _number_list(trimmed, "Color(")
				if numbers is Array and numbers.size() == 3:
					return {"value": Color(numbers[0], numbers[1], numbers[2])}
				if numbers is Array and numbers.size() == 4:
					return {"value": Color(numbers[0], numbers[1], numbers[2], numbers[3])}
				return {"error": "expected Color(r, g, b) or Color(r, g, b, a) with numbers, got '%s'" % text}
			# from_string() only signals failure by returning the default, so try two.
			var a := Color.from_string(trimmed, Color(0, 0, 0, 0))
			if a == Color.from_string(trimmed, Color(1, 1, 1, 1)):
				return {"value": a}
			return {"error": "expected a Color: #rrggbb, a name such as red, or Color(r, g, b[, a]); got '%s'" % text}
		TYPE_ARRAY, TYPE_DICTIONARY:
			# JSON, not str_to_var(), which instantiates Object(...) entries.
			var json: Variant = _json(trimmed)
			if typeof(json) != type:
				return {"error": "expected a JSON %s, got '%s'" % ["array" if type == TYPE_ARRAY else "object", text]}
			if info.has("array_type"):
				return _typed_array(info["array_type"], json)
			return {"value": json}
	return _parse_constructor(type, trimmed, text)


## Parsed JSON, or null. JSON.parse_string() would log an engine error for every
## bad value, which then shows up in get_editor_errors.
static func _json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


## Builds an array typed like `typed_like`: Object.set() silently refuses an
## untyped array for an Array[T] property. Each element is parsed as a T.
static func _typed_array(typed_like: Array, items: Array) -> Dictionary:
	var element_type := typed_like.get_typed_builtin()
	var element_script: Script = typed_like.get_typed_script()
	var element_info := {"type": element_type, "hint": PROPERTY_HINT_NONE, "hint_string": ""}
	if element_type == TYPE_OBJECT:
		var class_id := str(typed_like.get_typed_class_name())
		if element_script != null and not element_script.get_global_name().is_empty():
			class_id = element_script.get_global_name()
		element_info = {"type": TYPE_OBJECT, "hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": class_id}
	var values: Array = []
	for i in items.size():
		var item: Variant = items[i]
		var parsed := parse(element_info, item if item is String else str(item))
		if parsed.has("error"):
			return {"error": "element %d: %s" % [i, parsed["error"]]}
		values.append(parsed["value"])
	return {"value": Array(values, element_type, typed_like.get_typed_class_name(), element_script)}


static func _parse_int(info: Dictionary, trimmed: String) -> Dictionary:
	# Past 64 bits, is_valid_int() still passes and int() wraps.
	if trimmed.is_valid_float() and absf(float(trimmed)) >= 9.2e18:
		return {"error": "%s does not fit in a 64-bit integer" % trimmed}
	if trimmed.is_valid_int():
		return {"value": int(trimmed)}
	# A whole number sent as JSON may arrive as "5.0".
	if trimmed.is_valid_float() and float(trimmed) == floorf(float(trimmed)):
		return {"value": int(float(trimmed))}
	if info.get("hint", PROPERTY_HINT_NONE) == PROPERTY_HINT_ENUM:
		var next_value := 0
		var names: Array = []
		for option in str(info.get("hint_string", "")).split(","):
			var parts := option.split(":")
			var name := parts[0].strip_edges()
			var value := int(parts[1]) if parts.size() > 1 else next_value
			next_value = value + 1
			names.append(name)
			# The Inspector shows WALK_FAST as "Walk Fast"; accept both spellings.
			if _enum_key(name) == _enum_key(trimmed):
				return {"value": value}
		return {"error": "expected an integer or one of %s, got '%s'" % [", ".join(names), trimmed]}
	return {"error": "expected an integer, got '%s'" % trimmed}


static func _enum_key(name: String) -> String:
	return name.to_lower().replace(" ", "").replace("_", "")


## Vector3(1, 2, 3), Transform3D(…) and the other built-in types. Arguments must
## be numbers; they are printed back for str_to_var(), which checks their count.
## str_to_var() never sees caller text, because it instantiates Object(...).
static func _parse_constructor(type: int, trimmed: String, text: String) -> Dictionary:
	var constructor := type_string(type) + "("
	if type == TYPE_PACKED_STRING_ARRAY:
		return _parse_string_array(trimmed, constructor, text)
	var numbers: Variant = _number_list(trimmed, constructor)
	if numbers is Array:
		# str_to_var() turns a packed array with a wrong count into an empty one.
		var per_element: int = PACKED_ELEMENT_SIZE.get(type, 1)
		if numbers.size() % per_element != 0:
			return {"error": "%s takes numbers in groups of %d, got '%s'" % [type_string(type), per_element, text]}
		var parts: Array = []
		for n in numbers:
			# Otherwise Vector2i(1.5, 2) is silently truncated.
			if type in INTEGER_TYPES and n != floorf(n):
				return {"error": "%s takes whole numbers, got '%s'" % [type_string(type), text]}
			if INTEGER_RANGES.has(type) and (n < INTEGER_RANGES[type][0] or n > INTEGER_RANGES[type][1]):
				return {"error": "%s takes values from %d to %d, got '%s'" % [type_string(type), INTEGER_RANGES[type][0], INTEGER_RANGES[type][1], text]}
			parts.append(var_to_str(n))
		var value: Variant = str_to_var(constructor + ", ".join(parts) + ")")
		if typeof(value) == type:
			return {"value": value}
	return {"error": "expected %s with the right number of numeric arguments, for example %s…), got '%s'" % [type_string(type), constructor, text]}


## Numbers per element of the packed arrays of vectors and colors.
const PACKED_ELEMENT_SIZE := {
	TYPE_PACKED_VECTOR2_ARRAY: 2, TYPE_PACKED_VECTOR3_ARRAY: 3,
	TYPE_PACKED_VECTOR4_ARRAY: 4, TYPE_PACKED_COLOR_ARRAY: 4,
}

## Packed arrays that wrap out-of-range values instead of refusing them.
const INTEGER_RANGES := {
	TYPE_PACKED_BYTE_ARRAY: [0, 255],
	TYPE_PACKED_INT32_ARRAY: [-2147483648, 2147483647],
}

## Types whose components are integers.
const INTEGER_TYPES := [
	TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I, TYPE_RECT2I,
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
]


## The arguments of `Name(a, b, …)` as floats: [] for `Name()`, null when the
## text is not that shape or any argument is not a number.
static func _number_list(trimmed: String, constructor: String) -> Variant:
	if not (trimmed.begins_with(constructor) and trimmed.ends_with(")")):
		return null
	var inner := trimmed.trim_prefix(constructor).trim_suffix(")").strip_edges()
	var numbers: Array = []
	if inner.is_empty():
		return numbers
	for part in inner.split(","):
		var p := part.strip_edges()
		if not p.is_valid_float():
			return null
		numbers.append(float(p))
	return numbers


## PackedStringArray("a", "b"), read as JSON rather than through str_to_var().
static func _parse_string_array(trimmed: String, constructor: String, text: String) -> Dictionary:
	if trimmed.begins_with(constructor) and trimmed.ends_with(")"):
		var items: Variant = _json("[" + trimmed.trim_prefix(constructor).trim_suffix(")") + "]")
		if items is Array and items.all(func(item): return item is String):
			return {"value": PackedStringArray(items)}
	return {"error": "expected PackedStringArray(\"a\", \"b\") with quoted strings, got '%s'" % text}


static func _parse_object(info: Dictionary, trimmed: String) -> Dictionary:
	if trimmed.is_empty() or trimmed == "null":
		return {"value": null}
	var hint: int = info.get("hint", PROPERTY_HINT_NONE)
	if hint == PROPERTY_HINT_NODE_TYPE:
		return {"error": "this property holds a node; node references cannot be assigned by value"}
	var allowed: Array = ["Resource"]
	var hint_string := str(info.get("hint_string", ""))
	if hint == PROPERTY_HINT_RESOURCE_TYPE and not hint_string.is_empty():
		allowed = []
		for t in hint_string.split(","):
			allowed.append(t.strip_edges())

	var res: Resource
	if trimmed.begins_with(NEW_PREFIX):
		var made := _new_resource(trimmed.substr(NEW_PREFIX.length()).strip_edges())
		if made.has("error"):
			return made
		res = made["value"]
	else:
		var loaded := _load_resource(trimmed)
		if loaded.has("error"):
			return loaded
		res = loaded["value"]

	for t in allowed:
		if not t.is_empty() and is_instance_of_type(res, t):
			return {"value": res}
	return {"error": "%s is a %s; this property takes %s" % [trimmed, _label(res), " or ".join(allowed)]}


## Loads a project resource. Paths go through normalize_res() because
## ResourceLoader also accepts user:// and absolute paths.
static func _load_resource(text: String) -> Dictionary:
	var path := text
	if "://" in text and not (text.begins_with("res://") or text.begins_with("uid://")):
		return {"error": "Rejected resource path '%s': only res:// paths and uid:// ids are accepted" % text}
	if text.begins_with("uid://"):
		path = ResourceUtils.path_for_uid(text)
		if path.is_empty():
			return {"error": "Unknown uid: %s" % text}
	path = ResourceUtils.normalize_res(path)
	if path.is_empty():
		return {"error": "Rejected resource path '%s': paths must stay inside the project" % text}
	if not ResourceLoader.exists(path):
		return {"error": "No resource at %s. Give a res:// path, a uid:// id, or new:<ClassName>" % path}
	var res := ResourceLoader.load(path)
	if res == null:
		return {"error": "Could not load %s" % path}
	return {"value": res}


## new:<ClassName>, like "New …" in the Inspector. Only Resource types may be
## created.
static func _new_resource(class_id: String) -> Dictionary:
	if class_id.is_empty():
		return {"error": "Missing class name after '%s'" % NEW_PREFIX}
	if ClassDB.class_exists(class_id):
		if not ClassDB.is_parent_class(class_id, "Resource"):
			return {"error": "%s is not a Resource type" % class_id}
		if not ClassDB.can_instantiate(class_id):
			return {"error": "%s cannot be instantiated (it is abstract)" % class_id}
		return {"value": ClassDB.instantiate(class_id)}
	for entry in ProjectSettings.get_global_class_list():
		if str(entry["class"]) != class_id:
			continue
		if not _global_class_inherits(class_id, "Resource"):
			return {"error": "%s is not a Resource type" % class_id}
		var script := load(entry["path"]) as Script
		if script == null:
			return {"error": "Could not load the script of %s" % class_id}
		# new() cannot pass arguments; calling it on an _init that needs some
		# aborts the handler, and in the game leaves the bridge stuck.
		for method in script.get_script_method_list():
			if method["name"] == "_init" and method["args"].size() > method["default_args"].size():
				return {"error": "%s cannot be created with new: its _init() needs arguments" % class_id}
		if script.can_instantiate():
			return {"value": script.new()}
		# A non-@tool script cannot be instantiated in the editor. Like the
		# Inspector, build the engine base and attach the script.
		var base := script.get_instance_base_type()
		if not ClassDB.can_instantiate(base):
			return {"error": "%s cannot be instantiated" % class_id}
		var res: Object = ClassDB.instantiate(base)
		res.set_script(script)
		return {"value": res}
	return {"error": "Unknown class: %s" % class_id}


static func _global_class_inherits(class_id: String, base: String) -> bool:
	var bases := {}
	for entry in ProjectSettings.get_global_class_list():
		bases[str(entry["class"])] = str(entry["base"])
	var current := class_id
	# Bounded in case the class list has a cycle.
	for i in 64:
		if current == base:
			return true
		if not bases.has(current):
			return ClassDB.class_exists(current) and ClassDB.is_parent_class(current, base)
		current = bases[current]
	return false


## is_class() only knows engine classes, so script classes such as `Dye` are
## matched on the script chain.
static func is_instance_of_type(obj: Object, type_name: String) -> bool:
	if ClassDB.class_exists(type_name):
		return obj.is_class(type_name)
	var script: Script = obj.get_script()
	while script != null:
		if script.get_global_name() == type_name:
			return true
		script = script.get_base_script()
	return false


## Judges a write by the value read back: {} when it took, {"note": …} when a
## setter adjusted a value, {"error": …} otherwise. An object is never "adjusted":
## if the property does not hold the object given, the write failed.
static func verify(before: Variant, wanted: Variant, after: Variant) -> Dictionary:
	if same(after, wanted):
		return {}
	if typeof(wanted) == TYPE_OBJECT and wanted != null:
		return {"error": "the property did not accept %s: it holds %s" % [str(wanted), str(after)]}
	if same(after, before):
		return {"error": "the property still holds %s: the write was ignored, or a setter kept the old value" % str(after)}
	return {"note": "the property's setter changed the value: asked for %s, it holds %s" % [str(wanted), str(after)]}


## Equality that accepts int against float and 32-bit float storage (0.1 reads
## back as 0.10000000149). == between unrelated types errors in GDScript.
static func same(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta == tb:
		if ta == TYPE_FLOAT:
			return is_equal_approx(a, b)
		if ta in APPROX_TYPES:
			return a.is_equal_approx(b)
		return a == b
	var numeric := [TYPE_INT, TYPE_FLOAT]
	if ta in numeric and tb in numeric:
		return is_equal_approx(float(a), float(b))
	var textual := [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]
	if ta in textual and tb in textual:
		return str(a) == str(b)
	return false


const APPROX_TYPES := [
	TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_QUATERNION, TYPE_BASIS,
	TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_RECT2, TYPE_AABB, TYPE_PLANE,
]


## The file of the resource a path writes into, when that resource has its own
## file and is not `target`; otherwise "". `dye:tint` writes into the dye's file.
static func external_file(info: Dictionary, target: Object) -> String:
	var holder: Variant = info.get("holder")
	if not (holder is Resource) or holder == target:
		return ""
	var path: String = holder.resource_path
	if path.is_empty() or "::" in path:
		return ""
	return path


## A note for a write into a resource that has its own file.
static func shared_resource_note(info: Dictionary, target: Object) -> String:
	var path := external_file(info, target)
	if path.is_empty():
		return ""
	return "This changed %s, which every scene using it shares. The editor writes it to disk on the next save." % path
