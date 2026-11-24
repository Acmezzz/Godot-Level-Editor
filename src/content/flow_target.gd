extends RefCounted
## A published destination with one address format shared by layouts and declarative fields.

static func kind(value: Variant) -> String:
	if not value is Dictionary:
		return ""
	if value.size() == 3 and _has_id(value, "map") and _has_id(value, "inst") and _has_id(value, "port"):
		return "map"
	if value.size() == 1:
		if _has_id(value, "view"):
			return "view"
		if _has_id(value, "map"):
			return "map"
	if value.size() == 2 and _has_id(value, "function") and _has_id(value, "content"):
		return "content"
	return ""

static func _has_id(value: Dictionary, key: String) -> bool:
	return value.get(key) is String and not value[key].is_empty()

static func allows(decl: Dictionary, target: Variant) -> bool:
	match kind(target):
		"view": return decl.get("screens") == true
		"map": return not decl.get("arrivalPorts", []).is_empty() if target.has("port") else decl.get("maps") == true
		"content": return target.function in decl.get("contentTypes", [])
	return false

static func declaration_valid(decl: Dictionary) -> bool:
	var types = decl.get("contentTypes", [])
	var ports = decl.get("arrivalPorts", [])
	return decl.get("maps", false) is bool and decl.get("screens", false) is bool and types is Array \
		and types.all(func(id): return id is String and id != "") \
		and ports is Array and ports.all(func(id): return id is String and id != "") \
		and (decl.get("maps") == true or decl.get("screens") == true or not types.is_empty() or not ports.is_empty())
