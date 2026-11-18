extends RefCounted
## 跨资源引用总校验：内容资源之间、地图实体与内容之间的一致性。
## 输出与 map_validate 同构的 issue（level/map/ent_id/scene/field/message），
## 可直接 append 到现有问题面板，不需要 UI 改动。

const Store := preload("res://src/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const DialogueModel := preload("res://src/content/dialogue_model.gd")
const EventModel := preload("res://src/content/event_model.gd")
const ShopModel := preload("res://src/content/shop_model.gd")
const DefModel := preload("res://src/content/def_model.gd")

## 触发区支持的触发模式。
const TRIGGER_MODES := ["enter", "interact", "auto"]

## 全量校验。manifest 可选；缺省时种类/物品检查退化为宽松模式。
static func validate_all(m: Dictionary, manifest: Dictionary = {}) -> Array:
	var issues: Array = []
	var bad := {}
	var dialogues := ContentStore.read_all(m, "dialogues", bad.get("dialogues", []))
	_collect_bad(bad, issues)
	var events := ContentStore.read_all(m, "events", bad.get("events", []))
	_collect_bad(bad, issues)
	var shops := ContentStore.read_all(m, "shops", bad.get("shops", []))
	_collect_bad(bad, issues)
	var defs := ContentStore.read_all(m, "defs", bad.get("defs", []))
	_collect_bad(bad, issues)
	var schema := ContentStore.read(m, "schema", ContentStore.SCHEMA_ID)
	var known_items := ShopModel.item_index(manifest)

	for id in dialogues:
		_append(issues, DialogueModel.validate(dialogues[id]), "dialogues", id)
	for id in events:
		_append(issues, EventModel.validate(events[id], schema), "events", id)
	for id in shops:
		_append(issues, ShopModel.validate(shops[id], known_items), "shops", id)
	for id in defs:
		_append(issues, DefModel.validate(defs[id], manifest), "defs", id)
		_check_component_refs(defs[id], manifest, dialogues, events, shops, issues, id)

	var all := Store.read_all(m)
	for map_name in all:
		_validate_map_entities(all[map_name], str(map_name), manifest, defs, events, issues, known_items)
	# K13：孤儿内容资源——没有任何引用源（defs 槽位/触发区/事件步骤）指向的资源，
	# 游戏里永远不会出现。反向引用扫描，warn 级（引用可能由游戏代码写）。
	var referenced := {}
	for id in defs:
		var refs := DefModel.references(defs[id], manifest)
		for comp_name in refs:
			for entry in refs[comp_name]:
				var rid := str((entry as Dictionary).get("id", ""))
				if rid != "":
					referenced[rid] = true
	for map_name in all:
		for ent in (all[map_name] as Dictionary).get("entities", []):
			if ent is Dictionary and str(ent.get("scene", "")) == "trigger_zone":
				var tev := str((ent.get("props", {}) as Dictionary).get("event", ""))
				if tev != "":
					referenced[tev] = true
	for id in events:
		for st in (events[id] as Dictionary).get("steps", []):
			if st is Dictionary:
				for k in st:
					var v = st[k]
					if v is String and (v.begins_with("dlg.") or v.begins_with("evt.") or v.begins_with("shop.") or v.begins_with("grp.")):
						referenced[v] = true
	for pair in [["dialogues", dialogues], ["events", events], ["shops", shops]]:
		for id in (pair[1] as Dictionary):
			if not referenced.has(str(id)):
				issues.append({
					"level": "warn", "map": "", "ent_id": "", "scene": "",
					"field": "content/%s/%s" % [str(pair[0]), str(id)],
					"message": "未被任何地方引用（游戏里不会出现）——可删除，或挂到 def 槽位/触发区",
				}
				)
	return issues

static func _collect_bad(bad: Dictionary, issues: Array) -> void:
	for kind in bad:
		for entry in bad[kind]:
			issues.append({
				"level": "error", "map": "", "ent_id": "", "scene": "",
				"field": "content/" + str(kind),
				"message": "内容文件损坏无法参与校验：%s/%s（%s）" % [
					str(kind), str((entry as Dictionary).get("name", "")),
					str((entry as Dictionary).get("reason", ""))],
			})

static func _append(issues: Array, local: Array, kind: String, id: String) -> void:
	for issue in local:
		var it: Dictionary = issue
		issues.append({
			"level": str(it.get("level", "warn")), "map": "", "ent_id": "", "scene": "",
			"field": "%s/%s/%s" % [kind, id, str(it.get("field", ""))],
			"message": str(it.get("message", "")),
		})

## 定义里的组件引用必须指向存在的资源。一个槽位可挂多份，逐条校验。
static func _check_component_refs(definition: Dictionary, manifest: Dictionary, dialogues: Dictionary, events: Dictionary,
		shops: Dictionary, issues: Array, def_id: String) -> void:
	var refs := DefModel.references(definition, manifest)
	for comp_name in refs:
		var entries: Array = refs[comp_name]
		for i in entries.size():
			var ref: Dictionary = entries[i]
			var kind := str(ref.get("kind", ""))
			var ref_id := str(ref.get("id", ""))
			var found := false
			match kind:
				"dialogues": found = dialogues.has(ref_id)
				"events": found = events.has(ref_id)
				"shops": found = shops.has(ref_id)
			if found:
				continue
			issues.append({
				"level": "error", "map": "", "ent_id": "", "scene": "",
				"field": "defs/%s/components.%s[%d]" % [def_id, comp_name, i],
				"message": "定义 %s 引用的%s不存在: %s" % [def_id, _kind_name(kind), ref_id],
			})

static func _validate_map_entities(data: Dictionary, map_name: String, manifest: Dictionary,
		defs: Dictionary, events: Dictionary, issues: Array, _known_items: Dictionary) -> void:
	for ent in data.get("entities", []):
		if not (ent is Dictionary):
			continue
		var e: Dictionary = ent
		var sid := str(e.get("scene", ""))
		var eid := str(e.get("id", ""))
		var def_id := str(e.get("def", ""))
		if def_id != "":
			if not defs.has(def_id):
				issues.append(_entity_issue("error", map_name, e, "def", "定义不存在: " + def_id))
			else:
				var def_kind := str((defs[def_id] as Dictionary).get("kind", ""))
				if def_kind != "" and def_kind != sid:
					issues.append(_entity_issue("error", map_name, e, "def",
						"定义 %s 的种类是 %s，与实体种类 %s 不一致" % [def_id, def_kind, sid]))
		if sid == "trigger_zone":
			_validate_trigger(e, map_name, events, issues, data)

static func _validate_trigger(e: Dictionary, map_name: String, events: Dictionary, issues: Array, data: Dictionary) -> void:
	var eid := str(e.get("id", ""))
	var props: Dictionary = e.get("props", {}) if e.get("props", {}) is Dictionary else {}
	var mode := str(props.get("mode", "enter"))
	if not TRIGGER_MODES.has(mode):
		issues.append(_entity_issue("error", map_name, e, "mode", "触发方式不存在: " + mode))
	var event_id := str(props.get("event", ""))
	if event_id == "":
		issues.append(_entity_issue("error", map_name, e, "event", "触发区没有绑定事件"))
	elif not events.has(event_id):
		issues.append(_entity_issue("error", map_name, e, "event", "事件不存在: " + event_id))
	var w := int(props.get("w", 0))
	var h := int(props.get("h", 0))
	if w <= 0 or h <= 0:
		issues.append(_entity_issue("error", map_name, e, "w/h", "触发区尺寸必须为正"))
		return
	var meta: Dictionary = data.get("meta", {})
	var mx := int(meta.get("w", 0))
	var my := int(meta.get("h", 0))
	var ex := int(e.get("x", 0)) + w
	var ey := int(e.get("y", 0)) + h
	if (mx > 0 and ex > mx) or (my > 0 and ey > my):
		issues.append(_entity_issue("warn", map_name, e, "w/h", "触发区超出地图边界"))
	# 触发区必须有唯一 id 才能被事件/调试引用
	if eid == "":
		issues.append(_entity_issue("error", map_name, e, "id", "触发区缺少 id"))

static func _kind_name(kind: String) -> String:
	match kind:
		"dialogues": return "对话"
		"events": return "事件"
		"shops": return "商店"
		_: return kind

static func _entity_issue(level: String, map_name: String, ent: Dictionary, field: String, message: String) -> Dictionary:
	return {
		"level": level, "map": map_name,
		"ent_id": str(ent.get("id", "")), "scene": str(ent.get("scene", "")),
		"field": field, "message": message,
	}
