extends RefCounted
## 事件资源校验：按游戏工程声明的动作 schema 检查步骤类型、必填参数与参数类型。
## schema 缺失时只做结构性检查（步骤是对象、type 非空），不猜测游戏能力。

const MODEL := "event"
const ContentStore := preload("res://src/content/content_store.gd")

## A3.3：全工程已声明 flag 清单（扫事件 set_flag 步骤）；flag 参数选择器共用。
## flag 也可能由游戏代码写——清单不全时 UI 只提示不强制。
static func declared_flags(m: Dictionary) -> Array:
	var out := {}
	for eid in ContentStore.list_ids(m, "events"):
		var data := ContentStore.read(m, "events", str(eid))
		if data.is_empty():
			continue
		var steps = data.get("steps", [])
		if not (steps is Array):
			continue
		for st in steps:
			if st is Dictionary and str(st.get("type", "")) == "set_flag":
				var f := str(st.get("flag", ""))
				if f != "":
					out[f] = true
	return out.keys()

static func validate(event: Dictionary, schema: Dictionary = {}) -> Array:
	var issues: Array = []
	var steps = event.get("steps", [])
	if not (steps is Array) or (steps as Array).is_empty():
		issues.append(_issue("error", "steps", "事件至少需要一个步骤"))
		return issues
	var actions: Dictionary = schema.get("actions", {}) if schema.get("actions", {}) is Dictionary else {}
	for i in (steps as Array).size():
		var step = (steps as Array)[i]
		var field := "steps[%d]" % i
		if not (step is Dictionary):
			issues.append(_issue("error", field, "步骤必须是对象"))
			continue
		var type := str((step as Dictionary).get("type", ""))
		if type == "":
			issues.append(_issue("error", field + ".type", "步骤缺少 type"))
			continue
		if actions.is_empty():
			continue
		if not actions.has(type):
			issues.append(_issue("error", field + ".type", "游戏工程未声明该动作: " + type))
			continue
		var def: Dictionary = actions[type] if actions[type] is Dictionary else {}
		var params: Dictionary = def.get("params", {}) if def.get("params", {}) is Dictionary else {}
		for pid in params:
			var pdef: Dictionary = params[pid] if params[pid] is Dictionary else {}
			var value = (step as Dictionary).get(pid, null)
			if value == null:
				if bool(pdef.get("required", false)):
					issues.append(_issue("error", "%s.%s" % [field, pid], "缺少必填参数: " + pid))
				continue
			if not _type_matches(value, str(pdef.get("type", ""))):
				issues.append(_issue("error", "%s.%s" % [field, pid],
					"参数类型不符: %s 需要 %s" % [pid, str(pdef.get("type", ""))]))
	return issues

## schema 参数类型 → 值类型检查。未知类型按通过处理，由游戏侧自行解释。
static func _type_matches(value, type_name: String) -> bool:
	match type_name:
		"bool":
			return value is bool
		"int":
			return value is int or (value is float and float(value) == float(int(value)))
		"float":
			return value is int or value is float
		"string", "dialogue_ref", "event_ref", "shop_ref", "def_ref", "entity_ref":
			return value is String
		"array":
			return value is Array
		"dict":
			return value is Dictionary
		_:
			return true

## 取出 schema 声明，供编辑器生成动作菜单与参数控件。
static func actions_of(schema: Dictionary) -> Dictionary:
	return schema.get("actions", {}) if schema.get("actions", {}) is Dictionary else {}

## 单个动作的参数声明；未声明返回空字典。
static func params_of(schema: Dictionary, action: String) -> Dictionary:
	var def: Dictionary = actions_of(schema).get(action, {})
	var params = def.get("params", {})
	return params if params is Dictionary else {}

static func _issue(level: String, field: String, message: String) -> Dictionary:
	return {"level": level, "model": MODEL, "field": field, "message": message}