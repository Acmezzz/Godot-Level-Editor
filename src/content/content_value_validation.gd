extends RefCounted
## Checks stored values against declared fields; extension keys remain game-owned.

const Usage := preload("res://src/project/reference_usage.gd")
const Fields := preload("res://src/content/ref_fields.gd")
const Steps := preload("res://src/content/step_decl.gd")
const Conditions := preload("res://src/content/condition_decl.gd")
const Curves := preload("res://src/content/keyframe_curve.gd")
const Flow := preload("res://src/content/flow_target.gd")

static func check(m: Dictionary, fn: String, data: Dictionary) -> Array:
	var issues := []
	var values = data.get("fields", {})
	if values is Dictionary:
		_fields(m, Usage.content_sections(m, fn, {"fields": values})[0].decls, values, "fields", issues)
	else:
		_issue(issues, "fields", "须为对象。")
	var steps = data.get("steps", [])
	if not steps is Array:
		_issue(issues, "steps", "须为数组。")
		return issues
	if steps.is_empty():
		return issues
	var step_codes := Steps.by_code(m)
	for i in steps.size():
		var row = steps[i]
		var path := "steps[%d]" % i
		if not row is Dictionary:
			_issue(issues, path, "步骤须为对象。")
			continue
		var code = row.get("step")
		if not code is String or code == "" or not step_codes.has(code):
			_issue(issues, path + ".step", "未声明的步骤码：" + str(code))
		var fields = row.get("fields", {})
		if not fields is Dictionary:
			_issue(issues, path + ".fields", "须为对象。")
		elif code is String and step_codes.has(code):
			_fields(m, step_codes[code].fields, fields, path + ".fields", issues)
		for key in ["at", "duration", "track"]:
			if row.has(key):
				var value = row[key]
				if not Curves.number(value) or value < 0 or (key == "track" and value != floor(value)):
					_issue(issues, path + "." + key, "轨道须为非负整数。" if key == "track" else "时间须为非负有限数值。")
		if row.has("blocking") and not row.blocking is bool:
			_issue(issues, path + ".blocking", "须为布尔值。")
	return issues

static func _fields(m: Dictionary, decls: Array, values: Dictionary, path: String, issues: Array) -> void:
	for decl in decls:
		if not decl is Dictionary:
			continue
		var key: String = decl.get("code", "")
		if key == "":
			key = decl.get("id", "")
		if values.has(key):
			_value(m, decl, values[key], path + "." + key, issues)

static func _value(m: Dictionary, decl: Dictionary, value: Variant, path: String, issues: Array) -> void:
	var type: String = decl.get("type", "")
	var kind: String = decl.get("kind", "")
	if value == null or (value is String and value == "" and kind != "choice"):
		return # The existing editors treat these stored values as unset.
	if type == "array" or (kind == "choice" and decl.get("multiple", false)):
		if not value is Array:
			_issue(issues, path, "须为数组。")
			return
		var item := Fields.array_element_decl(decl) if type == "array" else decl.merged({"multiple": false}, true)
		for i in value.size():
			_value(m, item, value[i], "%s[%d]" % [path, i], issues)
		return
	var ok := true
	var expected := type
	var ref: String = Fields.describe(decl).kind
	if ref == "flow_target":
		ok = value is Dictionary and (value.is_empty() or Flow.kind(value) != "")
		expected = "流程目标对象"
	elif kind == "choice":
		ok = value is String
		expected = "选项值（字符串）"
		if ok and decl.get("options") is Array and (value != "" or not Fields.wants_empty_option(decl)):
			ok = decl.options.any(func(option):
				return str(option.get("v", "")) == value if option is Dictionary else str(option) == value)
			expected = "已声明选项"
	else:
		match type:
			"string", "asset_ref", "entity_ref", "viewport_ref":
				ok = value is String
			"int", "float", "range":
				ok = Curves.number(value) and (type != "int" or value == floor(value))
				if ok and Curves.number(decl.get("min")):
					ok = value >= decl.min
				if ok and Curves.number(decl.get("max")):
					ok = value <= decl.max
			"bool":
				ok = value is bool
			"color":
				ok = value is String and value.begins_with("#") and Color.html_is_valid(value)
			"vector2":
				ok = value is Array and value.size() == Fields.vector_dims(decl) and value.all(Curves.number)
			"curve":
				ok = Curves.valid(value)
			"port_ref", "edge_ref":
				ok = value is Dictionary
			"record":
				ok = value is Dictionary
				if ok:
					_fields(m, decl.get("fields", []), value, path, issues)
			"condition":
				ok = value is Dictionary
				if ok:
					var schema := Conditions.row_schema(m, decl, value)
					ok = not schema.is_empty() and value.get("fields", {}) is Dictionary
					if ok:
						_fields(m, schema.fields, value.get("fields", {}), path + ".fields", issues)
	if not ok:
		_issue(issues, path, "不符合字段声明（%s）。" % expected)

static func _issue(issues: Array, path: String, message: String) -> void:
	issues.append({"path": path, "message": message})
