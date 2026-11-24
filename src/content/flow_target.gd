extends RefCounted
## A published destination with one address format shared by layouts and declarative fields.

static func kind(value: Variant) -> String:
	if not value is Dictionary:
		return ""
	if value.size() == 1:
		if value.get("view") is String and value.view != "":
			return "view"
		if value.get("map") is String and value.map != "":
			return "map"
	if value.size() == 2 and value.get("function") is String and value.get("content") is String \
			and value.function != "" and value.content != "":
		return "content"
	return ""

static func allows(decl: Dictionary, target: Variant) -> bool:
	match kind(target):
		"view": return decl.get("screens") == true
		"map": return decl.get("maps") == true
		"content": return target.function in decl.get("contentTypes", [])
	return false

static func declaration_valid(decl: Dictionary) -> bool:
	var types = decl.get("contentTypes", [])
	return decl.get("maps", false) is bool and decl.get("screens", false) is bool and types is Array \
		and types.all(func(id): return id is String and id != "") \
		and (decl.get("maps") == true or decl.get("screens") == true or not types.is_empty())
