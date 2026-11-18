extends SceneTree

## 内容系统数据层回归：ID 规则、原子读写、数值三层合并。
## 全部使用临时目录，不依赖真实游戏项目。

const Store := preload("res://src/map_store.gd")

var failures: Array[String] = []
var ContentStore
var DefModel

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	ContentStore = _module("res://src/content/content_store.gd")
	DefModel = _module("res://src/content/def_model.gd")
	if failures.is_empty():
		_test_ids()
		_test_store_roundtrip()
		_test_effective_stats()
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

## 分层身份码：地图/实体/实例段为 4 位稳定码，内容段 6 位；名字不进 ID。
func _test_layered_ids() -> void:
	var ContentId = _module("res://src/content/content_id.gd")
	if ContentId == null:
		return
	var cid: String = ContentId.content_id("A3F9", "K2XP", "B7QM", "dialogue")
	_check(cid != "" and cid.begins_with("A3F9-K2XP-B7QM-dialogue-"),
		"layered id carries map/type/instance/function prefix: " + cid)
	var code: String = cid.substr(cid.rfind("-") + 1)
	_check(code.length() == 6, "layered id ends with a 6-char code: " + code)
	_check(not code.contains("I") and not code.contains("O") and not code.contains("0") and not code.contains("1"),
		"random code avoids look-alike chars: " + code)
	# 缺任何一段身份码都不产出脏 ID
	_check(ContentId.content_id("", "K2XP", "B7QM", "dialogue") == "",
		"layered id refuses missing map code")
	# 复用 = 复制出新 ID：冲突时只换内容段，身份前缀不动
	var m := _project("layered")
	ContentStore.write(m, "dialogue", cid, {"id": cid, "function": "dialogue", "name": "问好"})
	var dup: String = ContentId.unique(m, "dialogue", cid)
	_check(dup != "" and dup != cid, "unique() never returns an existing id")
	_check(ContentStore.is_valid_id(dup), "unique() output is a valid id: " + dup)
	_check(dup.begins_with("A3F9-K2XP-B7QM-dialogue-"), "unique() keeps the layered prefix")
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

## 实例 stats 覆盖定义 stats，定义 stats 覆盖清单默认值
func _test_effective_stats() -> void:
	var stats: Dictionary = DefModel.effective_stats(
		{"stats": {"hp": 20, "speed": 0}},
		{"stats": [{"id": "hp", "default": 1}, {"id": "speed", "default": 30}, {"id": "range", "default": 10}]},
		{"stats": {"hp": 5}})
	_check(int(stats.get("hp", 0)) == 5, "instance stat override wins")
	_check(int(stats.get("speed", -1)) == 0, "definition stat beats manifest default")
	_check(int(stats.get("range", 0)) == 10, "manifest default fills missing stats")

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