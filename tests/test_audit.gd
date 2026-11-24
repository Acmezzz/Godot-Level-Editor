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

func test_layer_ref_checks_nested_rows_and_target_scope() -> void:
	var m := _fake_manifest()
	m.assets = [{"id": "moving", "kind": "entity", "fields": [
		{"id": "routes", "kind": "input", "type": "array", "of": "record", "fields": [
			{"id": "scope", "code": "SCOP", "kind": "choice", "source": "map"},
			{"id": "layer", "kind": "choice", "source": "layer:", "mapField": "scope"}]}]}]
	var target := {"meta": {"code": "DEST", "layers": [{"id": "upper"}]}}
	var data := {"meta": {"code": "HOME", "layers": [{"id": "upper"}]}, "objects": [
		{"code": "MOVE", "asset": "moving", "props": {"routes": [{"scope": "DEST", "layer": "upper"}]}}]}
	eq(ProjectAudit._ref_checks(data, m, "home", {"DEST": target}).size(), 0, "paired map owns the layer")
	target.meta.layers.clear()
	var out := ProjectAudit._ref_checks(data, m, "home", {"DEST": target})
	eq(out.size(), 1, "same layer ID in the source map does not hide the missing target")
	if out.size() == 1:
		ok(out[0].path.ends_with("routes#0.layer") and out[0].jump.prop == "routes", "the issue identifies the row and jumps to its form")
		ok(not out[0].has("fix"), "the editor preserves the authored reference for repair")

## C1：配对地图引用按目标图码集判定（同码在本图不存在但目标图存在 = 不报）
func test_ref_checks_paired_map() -> void:
	_wipe()
	var m := _fake_manifest()
	m["assets"] = [{"id": "switch", "kind": "entity", "fields": [
		{"id": "target_map", "type": "map_ref"},
		{"id": "target", "type": "entity_ref", "mapField": "target_map"},
	]}]
	# 目标图 b 有实例 T1，本图 m1 没有 T1
	var bmap := MapStore.new_map("b", 8, 8)
	(bmap.meta as Dictionary)["code"] = "BBBB"
	(bmap.objects as Array).append({"asset": "switch", "code": "T1", "layer": str(bmap.meta.layers[0].id), "x": 0, "y": 0})
	MapStore.write(m, "b", bmap)
	var data := {"meta": {"code": "AAAA"}, "objects": [
		{"code": "S1", "asset": "switch", "props": {"target_map": "BBBB", "target": "T1"}},
	]}
	var out := ProjectAudit._ref_checks(data, m, "m1")
	eq(out.size(), 0, "目标图里存在的实例码不报悬空：%s" % str(out))
	# 目标码在目标图里也不存在 → 报，且消息指名目标图
	var data2 := {"meta": {"code": "AAAA"}, "objects": [
		{"code": "S1", "asset": "switch", "props": {"target_map": "BBBB", "target": "ZZZZ"}},
	]}
	var out2 := ProjectAudit._ref_checks(data2, m, "m1")
	eq(out2.size(), 1, "目标图里的悬空引用报一条")
	if out2.size() == 1:
		ok(str((out2[0] as Dictionary).get("message")).contains("BBBB"), "消息指明目标图")
	# 配对地图未填 = 本图域：本图有码即可
	var data3 := {"meta": {"code": "AAAA"}, "objects": [
		{"code": "S1", "asset": "switch", "props": {"target": "S1"}},
	]}
	eq(ProjectAudit._ref_checks(data3, m, "m1").size(), 0, "未填地图 = 本图域，本图码合法")
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

## A4：停用/改名待确认的资产进审计，jump 指资产页
func test_audit_scan_states() -> void:
	var m := _fake_manifest()
	m["assets"] = [
		{"id": "A1", "kind": "entity", "visual": {"type": "rect"}, "retired": true, "retiredPath": "assets/entities/a.tscn"},
		{"id": "B2", "kind": "entity", "visual": {"type": "rect"}, "retired": true,
			"retiredPath": "assets/entities/b.tscn", "relinkCandidates": ["assets/entities/x.tscn", "assets/entities/y.tscn"]},
	]
	m["_scan_report"] = {
		"retired": ["A1"], "ambiguous": [{"id": "B2", "candidates": ["assets/entities/x.tscn", "assets/entities/y.tscn"]}],
	}
	var out := ProjectAudit.audit(m)
	var ast := out.filter(func(e): return str(e.get("kind")) == "asset")
	eq(ast.size(), 2, "停用 + 歧义各报一条")
	for e in ast:
		eq(str((e as Dictionary).get("severity")), "warning", "资产问题 warning 级")
		eq(str(((e as Dictionary).get("jump", {}) as Dictionary).get("type")), "asset", "jump.type=asset")
	var amb := ast.filter(func(e): return str(e.get("path")) == "assets/B2")
	ok(amb.size() == 1 and str((amb[0] as Dictionary).get("message")).contains("待确认"), "歧义条目指名待确认")
