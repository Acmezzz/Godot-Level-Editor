extends "res://tests/_suite_base.gd"
## 全项目审计：条目包装（kind/map/jump）+ 引用悬空检查（entity_ref/map_ref）。

const ProjectAudit := preload("res://src/project/project_audit.gd")
const MapStore := preload("res://src/map/map_store.gd")

const TMP := "user://test_audit_tmp"

func _fake_manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "projectName": "p"}

func _wipe() -> void:
	var maps := TMP.path_join("maps")
	if DirAccess.dir_exists_absolute(maps):
		for f in DirAccess.get_files_at(maps):
			DirAccess.remove_absolute(f)
		DirAccess.remove_absolute(maps)
	if DirAccess.dir_exists_absolute(TMP):
		DirAccess.remove_absolute(TMP)

func test_manifest_wrap() -> void:
	# 清单级问题 → kind=manifest，map 空、不可跳转（功能 id 数组写法重复 = 错误）
	var m := _fake_manifest()
	m["functions"] = [{"id": "f", "name": "f", "fields": []}, {"id": "f", "name": "g", "fields": []}]
	var out := ProjectAudit.audit(m)
	var man := out.filter(func(e): return str(e.get("kind")) == "manifest")
	ok(man.size() > 0, "manifest 条目被收集")
	if man.size() > 0:
		var e0: Dictionary = man[0]
		eq(str(e0.get("map")), "", "manifest 条目 map 为空")
		eq(str((e0.get("jump", {}) as Dictionary).get("type", "")), "", "manifest 条目不可跳转")
	_wipe()

func test_ref_checks() -> void:
	# entity_ref 悬空 = 警告（jump 指回实例）；未填 = 合法状态不报
	var m := _fake_manifest()
	m["assets"] = [{"id": "door", "kind": "entity", "fields": [{"id": "TGT", "type": "entity_ref"}]}]
	var data := {"objects": [
		{"code": "A1", "asset": "door", "props": {"TGT": "B9"}},
		{"code": "B1", "asset": "door", "props": {}},
	]}
	var out := ProjectAudit._ref_checks(data, m, "m1")
	eq(out.size(), 1, "悬空 entity_ref → 1 条警告")
	if out.size() == 1:
		var e0: Dictionary = out[0]
		eq(str(e0.get("severity")), "warning", "severity=warning")
		eq(str(e0.get("map")), "m1", "map 带图名")
		var j: Dictionary = e0.get("jump", {}) as Dictionary
		eq(str(j.get("type")), "entity", "jump.type=entity")
		eq(str(j.get("code")), "A1", "jump.code 指回实例")
	_wipe()

func test_ref_checks_map_ref() -> void:
	# map_ref：目标图文件不存在 = 警告；存在 = 不报
	var m := _fake_manifest()
	m["assets"] = [{"id": "warp", "kind": "entity", "fields": [{"id": "MAP", "type": "map_ref"}]}]
	var data := {"objects": [{"code": "W1", "asset": "warp", "props": {"MAP": "nope"}}]}
	var out := ProjectAudit._ref_checks(data, m, "m1")
	eq(out.size(), 1, "目标图不存在 → 1 条警告")
	_wipe()

func test_audit_map_issues() -> void:
	# 地图校验条目：kind=map，map=图名，jump 可跳转开图
	_wipe()
	var m := _fake_manifest()
	var bad := MapStore.new_map("t", 8, 8)
	(bad.get("collision", []) as Array).append({"x": 1, "y": 1, "type": 123})
	(bad.get("collision", []) as Array).append([2, 2])
	MapStore.write(m, "t", bad)
	var out := ProjectAudit.audit(m)
	var mp := out.filter(func(e): return str(e.get("kind")) == "map")
	ok(mp.size() > 0, "map 条目被收集")
	if mp.size() > 0:
		var e0: Dictionary = mp[0]
		eq(str(e0.get("map")), "t", "map=图名")
		eq(str((e0.get("jump", {}) as Dictionary).get("type")), "map", "jump.type=map")
	_wipe()
