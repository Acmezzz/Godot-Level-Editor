extends SceneTree

## 内容系统数据层回归：ID 规则、原子读写、对话图、事件 schema、商店条目、
## 定义解析与跨资源引用校验。全部使用临时目录，不依赖真实游戏项目。

const Store := preload("res://src/map_store.gd")

var failures: Array[String] = []
var ContentStore
var DialogueModel
var EventModel
var ShopModel
var DefModel
var ContentValidate

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	ContentStore = _module("res://src/content/content_store.gd")
	DialogueModel = _module("res://src/content/dialogue_model.gd")
	EventModel = _module("res://src/content/event_model.gd")
	ShopModel = _module("res://src/content/shop_model.gd")
	DefModel = _module("res://src/content/def_model.gd")
	ContentValidate = _module("res://src/content/content_validate.gd")
	if failures.is_empty():
		_test_ids()
		_test_store_roundtrip()
		_test_dialogue()
		_test_event()
		_test_shop()
		_test_definition()
		_test_validate_all()
	if failures.is_empty():
		print("CONTENT_MODEL_OK")
	else:
		for failure in failures:
			printerr("CONTENT_MODEL_FAIL: ", failure)
	quit(failures.size())

func _module(path: String):
	var script = load(path)
	if script == null:
		failures.append("missing module: " + path)
		return null
	return script

func _test_ids() -> void:
	_check(ContentStore.is_valid_id("dlg.intro"), "dotted content id is valid")
	_check(ContentStore.is_valid_id("town_01"), "underscore content id is valid")
	for bad in ["", "../x", "a/b", "a\\b", "C:evil", ".hidden", "trail."]:
		_check(not ContentStore.is_valid_id(bad), "invalid content id accepted: " + bad)
	_test_layered_ids()

## v2 §5.1：分层 ID（地图-实体-实例-功能-随机码）+ 复用即复制（新 ID）。
## 顺带锁住 content_store 的「白名单已删」——声明与磁盘目录都能列出来。
func _test_layered_ids() -> void:
	var ContentId = _module("res://src/content/content_id.gd")
	if ContentId == null:
		return
	var cid: String = ContentId.make("TEST", "merchant", "e_3", "dialogue")
	_check(cid != "" and cid.begins_with("TEST-merchant-e_3-dialogue-"),
		"layered id carries map/type/instance/function prefix: " + cid)
	var code: String = cid.substr(cid.rfind("-") + 1)
	_check(code.length() == 6, "layered id ends with a 6-char code: " + code)
	_check(not code.contains("I") and not code.contains("O") and not code.contains("0") and not code.contains("1"),
		"random code avoids look-alike chars: " + code)
	# 输入不合法（含路径分隔符）时宁可返回空串，也不产出脏 id
	_check(ContentId.make("TE/ST", "merchant", "e_3", "dialogue") == "",
		"layered id refuses illegal map name")
	# 复用 = 复制出新 ID：同名候选必须被推成另一个合法 id
	var m := _project("layered")
	ContentStore.write(m, "dialogue", cid, {"id": cid, "function": "dialogue", "name": "问好"})
	var dup: String = ContentId.unique(m, "dialogue", cid)
	_check(dup != "" and dup != cid, "unique() never returns an existing id")
	_check(ContentStore.is_valid_id(dup), "unique() output is a valid id: " + dup)
	_check(dup.begins_with("TEST-merchant-e_3-dialogue-"), "unique() keeps the layered prefix")
	_check(ContentId.unique(m, "dialogue", "") == "", "empty candidate yields empty id")

func _test_store_roundtrip() -> void:
	var m := _project("roundtrip")
	ContentStore.write(m, "dialogues", "dlg.one", {"version": 1, "id": "dlg.one", "nodes": []})
	_check(FileAccess.file_exists(ContentStore.path_for(m, "dialogues", "dlg.one")),
		"content write creates a json file")
	var back: Dictionary = ContentStore.read(m, "dialogues", "dlg.one")
	_check(str(back.get("id", "")) == "dlg.one", "content read returns the stored id")
	_check(ContentStore.list_ids(m, "dialogues").has("dlg.one"), "list_ids sees the new resource")
	_check(ContentStore.path_for(m, "dialogues", "../evil") == "", "content path refuses traversal")
	# 坏文件单独报告，不污染其他资源
	var bad_path: String = ContentStore.dir_for(m, "dialogues").path_join("dlg.bad.json")
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("{oops")
	f.close()
	var bad: Array = []
	var all: Dictionary = ContentStore.read_all(m, "dialogues", bad)
	_check(all.has("dlg.one") and not all.has("dlg.bad"), "read_all skips corrupt resources")
	_check(bad.size() == 1 and str(bad[0].get("name", "")) == "dlg.bad", "read_all reports corrupt resource")
	# 改名与删除
	_check(ContentStore.rename(m, "dialogues", "dlg.one", "dlg.two"), "content rename succeeds")
	_check(not ContentStore.read(m, "dialogues", "dlg.one").size() and ContentStore.read(m, "dialogues", "dlg.two").size() > 0,
		"rename moves the file")
	ContentStore.remove(m, "dialogues", "dlg.two")
	ContentStore.remove(m, "dialogues", "dlg.bad")
	_check(ContentStore.read(m, "dialogues", "dlg.two").is_empty(), "remove deletes the resource")

func _test_dialogue() -> void:
	var good := {
		"version": 1, "id": "dlg.good", "start": "n1",
		"nodes": [
			{"id": "n1", "speaker": "self", "text": "你好。", "next": "n2"},
			{"id": "n2", "speaker": "", "text": "远处传来风声。", "choices": [
				{"text": "继续", "next": "n3"},
				{"text": "离开", "next": "end"},
			]},
			{"id": "n3", "speaker": "self", "text": "再见。", "next": "end"},
			{"id": "end", "end": true},
		],
	}
	_check(DialogueModel.validate(good).is_empty(), "valid dialogue passes validation")
	var dangling := good.duplicate(true)
	dangling.nodes[0].next = "n99"
	_check(_has_msg(DialogueModel.validate(dangling), "不存在的节点"), "dangling next is reported")
	var orphan := good.duplicate(true)
	orphan.nodes.append({"id": "lonely", "text": "无人到达。", "next": "end"})
	_check(_has_msg(DialogueModel.validate(orphan), "不可到达"), "unreachable node is a warning")
	var no_end := good.duplicate(true)
	for node in no_end.nodes:
		node.erase("end")
		(node as Dictionary)["next"] = "n1"
	_check(_has_msg(DialogueModel.validate(no_end), "终止"), "dialogue without a terminal node warns")
	var dup := good.duplicate(true)
	dup.nodes.append({"id": "n1", "text": "重复。"})
	_check(_has_msg(DialogueModel.validate(dup), "重复"), "duplicate node id is reported")
	var missing_start := good.duplicate(true)
	missing_start.start = "ghost"
	_check(_has_msg(DialogueModel.validate(missing_start), "起始"), "missing start node is reported")

func _test_event() -> void:
	var schema := {"version": 1, "actions": {
		"dialogue": {"params": {"dialogue": {"type": "dialogue_ref", "required": true}}},
		"wait": {"params": {"seconds": {"type": "float", "default": 0.5}}},
		"set_flag": {"params": {"flag": {"type": "string", "required": true}}},
	}}
	var good := {"version": 1, "id": "evt.good", "steps": [
		{"type": "dialogue", "dialogue": "dlg.good"},
		{"type": "wait", "seconds": 0.3},
		{"type": "set_flag", "flag": "met"},
	]}
	_check(EventModel.validate(good, schema).is_empty(), "valid event passes schema validation")
	var unknown := good.duplicate(true)
	unknown.steps.append({"type": "not_declared"})
	_check(_has_msg(EventModel.validate(unknown, schema), "未声明"), "undeclared action is reported")
	var missing_param := good.duplicate(true)
	missing_param.steps.append({"type": "set_flag"})
	_check(_has_msg(EventModel.validate(missing_param, schema), "缺少"), "missing required param is reported")
	var empty_steps := {"version": 1, "id": "evt.empty", "steps": []}
	_check(_has_msg(EventModel.validate(empty_steps, schema), "至少"), "empty event is reported")

func _test_shop() -> void:
	var good := {"version": 1, "id": "shop.good", "entries": [
		{"item": "item.ore", "price": 12, "stock": 5},
		{"item": "item.sword", "price": 80, "stock": -1},
	]}
	_check(ShopModel.validate(good).is_empty(), "valid shop passes validation")
	var dup := good.duplicate(true)
	dup.entries.append({"item": "item.ore", "price": 1})
	_check(_has_msg(ShopModel.validate(dup), "重复"), "duplicate shop item is reported")
	var negative := good.duplicate(true)
	negative.entries[0].price = -3
	_check(_has_msg(ShopModel.validate(negative), "价格"), "negative price is reported")

func _test_definition() -> void:
	var manifest := {"entities": [{"id": "npc", "name": "NPC"}, {"id": "enemy"}]}
	var good := {"version": 1, "id": "town.smith", "kind": "npc",
		"components": {"dialogue": {"id": "dlg.good"}, "shop": {"id": "shop.good"}}}
	_check(DefModel.validate(good, manifest).is_empty(), "valid definition passes validation")
	var bad_kind := good.duplicate(true)
	bad_kind.kind = "ghost"
	_check(_has_msg(DefModel.validate(bad_kind, manifest), "种类"), "unknown kind is reported")
	var bad_comp := good.duplicate(true)
	bad_comp.components = {"script": {"id": "x"}}
	_check(_has_msg(DefModel.validate(bad_comp, manifest), "组件"), "unknown component is reported")
	# 实例 stats 覆盖定义 stats，定义 stats 覆盖清单默认值
	var stats: Dictionary = DefModel.effective_stats(
		{"stats": {"hp": 20, "speed": 0}},
		{"stats": [{"id": "hp", "default": 1}, {"id": "speed", "default": 30}, {"id": "range", "default": 10}]},
		{"stats": {"hp": 5}})
	_check(int(stats.get("hp", 0)) == 5, "instance stat override wins")
	_check(int(stats.get("speed", -1)) == 0, "definition stat beats manifest default")
	_check(int(stats.get("range", 0)) == 10, "manifest default fills missing stats")
	_test_multi_slot(manifest)

## 多段内容：一个槽位可挂多份，顺序即匹配优先级；旧单对象写法必须继续可用。
func _test_multi_slot(manifest: Dictionary) -> void:
	# 旧写法（单对象）归一化成单元素数组
	var single := {"version": 1, "kind": "npc", "components": {"dialogue": {"id": "dlg.solo", "once": true}}}
	var items: Array = DefModel.items_of(single, "dialogue")
	_check(items.size() == 1, "legacy single-object component normalises to one entry")
	_check(bool((items[0] as Dictionary).get("once", false)), "legacy once flag survives normalisation")
	var refs: Dictionary = DefModel.references(single)
	_check((refs.get("dialogue", []) as Array).size() == 1, "references reports legacy form as one entry")
	_check(str(((refs.get("dialogue", []) as Array)[0] as Dictionary).get("kind", "")) == "dialogues",
		"references annotates the content kind")

	# 多条目：每条的 once/when 独立
	var multi := {"version": 1, "kind": "npc", "components": {"dialogue": [
		{"id": "dlg.first", "once": true},
		{"id": "dlg.idle", "when": "met_smith"},
		{"id": "dlg.default"},
	]}}
	_check(DefModel.validate(multi, manifest).is_empty(), "multi-entry slot passes validation")
	var multi_refs: Array = DefModel.references(multi)["dialogue"]
	_check(multi_refs.size() == 3, "all entries are reported in order")
	_check(str((multi_refs[0] as Dictionary).get("id", "")) == "dlg.first", "order is preserved")
	_check(bool((multi_refs[0] as Dictionary).get("once", false)), "per-entry once is read")
	_check(str((multi_refs[1] as Dictionary).get("when", "")) == "met_smith", "per-entry condition is read")
	_check(not (multi_refs[2] as Dictionary).get("once", false), "entries without once default to repeatable")

	# 同一槽位重复引用同一份资源 → error
	var dup := {"version": 1, "kind": "npc", "components": {"dialogue": [
		{"id": "dlg.a"}, {"id": "dlg.a"}]}}
	_check(_has_msg(DefModel.validate(dup, manifest), "重复"), "duplicate entries in one slot are rejected")
	# 空槽位 → error（写了键就要有内容）
	var empty_slot := {"version": 1, "kind": "npc", "components": {"dialogue": []}}
	_check(_has_msg(DefModel.validate(empty_slot, manifest), "没有任何条目"),
		"an empty slot is reported instead of silently ignored")

func _test_validate_all() -> void:
	var m := _project("validate")
	var manifest := {
		"entities": [{"id": "npc", "name": "NPC"}, {"id": "trigger_zone", "name": "触发区"}],
	}
	m["_dir"] = str(m["_dir"])
	var base := str(m["_dir"])
	ContentStore.write(m, "dialogues", "dlg.one", {"version": 1, "id": "dlg.one",
		"start": "n1", "nodes": [{"id": "n1", "text": "嗨。", "next": "end"}, {"id": "end", "end": true}]})
	ContentStore.write(m, "shops", "shop.one", {"version": 1, "id": "shop.one",
		"entries": [{"item": "item.ghost", "price": 3}]})
	ContentStore.write(m, "defs", "town.one", {"version": 1, "id": "town.one", "kind": "npc",
		"components": {"dialogue": {"id": "dlg.missing"}, "shop": {"id": "shop.one"}}})
	ContentStore.write(m, "events", "evt.one", {"version": 1, "id": "evt.one",
		"steps": [{"type": "dialogue", "dialogue": "dlg.one"}]})
	var schema := {"actions": {"dialogue": {"params": {"dialogue": {"type": "dialogue_ref", "required": true}}}}}
	ContentStore.write(m, "schema", "actions", schema)

	# 地图：一个错误种类定义 + 一个缺事件触发区 + 一个合法定义
	Store.write(m, "m1", _map([
		{"scene": "npc", "id": "e_1", "x": 1, "y": 1, "def": "town.one", "props": {}},
		{"scene": "npc", "id": "e_2", "x": 2, "y": 2, "def": "town.missing", "props": {}},
		{"scene": "trigger_zone", "id": "e_3", "x": 3, "y": 3,
			"props": {"w": 2, "h": 1, "mode": "enter", "event": "evt.missing"}},
	]))
	var issues: Array = ContentValidate.validate_all(m, manifest)
	_check(_has(issues, "dlg.missing", "不存在"), "missing dialogue reference is reported")
	_check(_has(issues, "town.missing", "不存在"), "missing definition reference is reported")
	_check(_has(issues, "evt.missing", "不存在"), "missing trigger event is reported")
	_check(_has(issues, "town.one", "种类") == false, "matching kind produces no kind error")
	_cleanup(m, ["m1"])

func _has_msg(issues: Array, needle: String) -> bool:
	for issue in issues:
		if str(issue.get("message", "")).contains(needle):
			return true
	return false

func _has(issues: Array, resource: String, needle: String) -> bool:
	for issue in issues:
		var hay := str(issue.get("field", "")) + " " + str(issue.get("message", ""))
		if hay.contains(resource) and hay.contains(needle):
			return true
	return false

func _project(name: String) -> Dictionary:
	var base := "user://content_model_" + name
	var dir := base.path_join("content")
	DirAccess.make_dir_recursive_absolute(dir)
	var maps_dir := base.path_join("maps")
	DirAccess.make_dir_recursive_absolute(maps_dir)
	return {"_dir": base, "_maps_dir": maps_dir, "_content_dir": dir}

func _map(entities: Array) -> Dictionary:
	return {"meta": {"name": "test", "w": 10, "h": 10}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [], "entities": entities}

func _cleanup(m: Dictionary, maps: Array) -> void:
	for map_name in maps:
		var p := Store.path_for(m, map_name)
		if p != "" and FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("CONTENT_MODEL_FAIL: ", message)