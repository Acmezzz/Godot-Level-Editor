extends "res://tests/_suite_base.gd"
## E2：批量改值计划与瓦片替换计划（纯数据层）。

const BatchOps := preload("res://src/content/batch_ops.gd")
const TileReplace := preload("res://src/canvas/tile_replace.gd")
const ContentStore := preload("res://src/content/content_store.gd")

const TMP := "user://test_batch_e2_tmp"

func _manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content",
		"projectName": "p", "tileSize": 16,
		"functions": {"card": {"name": "卡牌", "code": "F111", "fields": [
			{"id": "cost", "code": "N111", "name": "费用", "kind": "input", "type": "int", "min": 0, "max": 99},
			{"id": "note", "code": "N222", "name": "备注", "kind": "input", "type": "string"},
			{"id": "tags", "code": "N333", "name": "标签", "kind": "choice", "source": "content:card", "multiple": true},
			{"id": "steps", "code": "N444", "name": "步骤", "kind": "unknown_type"},
		]}},
		"assets": [
			{"id": "grass", "kind": "scene", "shape": "tile", "atlas": "a.png",
				"palette": [{"cell": [0, 0], "name": "草"}, {"cell": [1, 0], "name": "草2"}]},
			{"id": "stone", "kind": "scene", "shape": "tile", "atlas": "b.png",
				"palette": [{"cell": [0, 0], "name": "石"}]},
			{"id": "tree", "kind": "entity", "prefab": "res://t.tscn"},
		]}

func _nuke(p: String) -> void:
	if DirAccess.dir_exists_absolute(p):
		for f in DirAccess.get_files_at(p):
			DirAccess.remove_absolute(p.path_join(str(f)))
		for d in DirAccess.get_directories_at(p):
			_nuke(p.path_join(str(d)))
		DirAccess.remove_absolute(p)

func _cleanup() -> void:
	_nuke(TMP)

func _write_content(m: Dictionary, cid: String, fields: Dictionary) -> void:
	ContentStore.write(m, "card", cid, {"id": cid, "function": "F111", "name": cid, "fields": fields})

## —— E2-2：批量改值计划：只收同功能可写字段、类型不符进冲突、缺内容进跳过 ——
func test_batch_plan_field() -> void:
	_cleanup()
	var m := _manifest()
	_write_content(m, "c1", {"N111": 1})
	_write_content(m, "c2", {"N111": 2})
	_write_content(m, "c3", {"N111": "不是数字"})
	var rows := [
		{"node": null, "code": "AAAA", "cid": "c1"},
		{"node": null, "code": "BBBB", "cid": "c2"},
		{"node": null, "code": "CCCC", "cid": "c3"},
		{"node": null, "code": "DDDD", "cid": ""},       # 还没有内容 → 跳过
		{"node": null, "code": "EEEE", "cid": "missing"},  # 文件缺失 → 冲突
	]
	var plan := BatchOps.plan_field(m, "card", rows, "N111", 7)
	eq(str(plan.get("status", "")), "ok", "计划生成成功")
	eq((plan.get("targets", []) as Array).size(), 2, "两条可写（c1/c2）")
	eq((plan.get("skipped", []) as Array).size(), 1, "无内容的实例进跳过")
	eq((plan.get("conflicts", []) as Array).size(), 2, "类型不符与文件缺失各一条冲突")
	eq(int((plan.get("old_values", {}) as Dictionary).get("c1", -1)), 1, "带出旧值供预览")
	# 认不出的字段种类不参与批量（不给能写坏数据的入口）
	var bad := BatchOps.plan_field(m, "card", rows, "N444", "x")
	eq(str(bad.get("status", "")), "error", "非可写种类拒绝批量")
	var bad2 := BatchOps.plan_field(m, "card", rows, "N999", "x")
	eq(str(bad2.get("status", "")), "error", "未声明字段拒绝批量")
	# 应用：只写命中的两条，c3 原值保留
	var res := BatchOps.apply_field(m, "card", plan)
	eq(int(res.get("written", 0)), 2, "写两条")
	eq(int((res.get("failed", []) as Array).size()), 0, "无失败")
	eq(int(ContentStore.read(m, "card", "c1").get("fields", {}).get("N111", -1)), 7, "c1 已改")
	eq(int(ContentStore.read(m, "card", "c2").get("fields", {}).get("N111", -1)), 7, "c2 已改")
	eq(str(ContentStore.read(m, "card", "c3").get("fields", {}).get("N111", "")), "不是数字",
		"类型不符的 c3 原值保留（不被批量写坏）")
	_cleanup()

func test_batch_rejects_changed_old_value() -> void:
	_cleanup()
	var m := _manifest()
	_write_content(m, "c1", {"N111": 1})
	_write_content(m, "c2", {"N111": 2})
	var plan := BatchOps.plan_field(m, "card", [{"cid": "c1"}, {"cid": "c2"}], "N111", 7)
	_write_content(m, "c1", {"N111": 9})
	var result := BatchOps.apply_field(m, "card", plan)
	eq(result.written, 1, "只写旧值未变的目标")
	eq(result.failed[0].cid, "c1", "过期目标有失败收据")
	eq(int(ContentStore.read(m, "card", "c1").fields.N111), 9, "保留预览后的编辑")
	_cleanup()

## 批量可写字段清单：只列 input/choice（与控件可写集合一致）
func test_batchable_fields() -> void:
	var m := _manifest()
	var rows := BatchOps.batchable_fields(m, "card")
	eq(rows.size(), 3, "三个可写字段（int/string/choice），未知种类不列")
	var names := []
	for r in rows:
		names.append(str((r as Dictionary).get("code", "")))
	ok(names.has("N111") and names.has("N222") and names.has("N333"), "按声明码列出")
	ok(not names.has("N444"), "未知种类不列")

## 同码判定：字段键优先码、无码退回 id（内容文件里的键口径）
func test_field_key_prefers_code() -> void:
	eq(BatchOps.field_key({"id": "cost", "code": "N111"}), "N111", "有码用码")
	eq(BatchOps.field_key({"id": "cost"}), "cost", "无码退回 id")

## —— E2-2：瓦片替换计划：幻灯片边界冲突先列，不越界写入 ——
func test_tile_replace_plan() -> void:
	var m := _manifest()
	var cells := [
		{"c": Vector2i(1, 1), "layer": "L1", "atlas": Vector2i(0, 0), "alt": 1},
		{"c": Vector2i(2, 1), "layer": "L1", "atlas": Vector2i(1, 0), "alt": 0},
		{"c": Vector2i(3, 1), "layer": "L1", "atlas": Vector2i(5, 5), "alt": 0},
	]
	# 目标 stone 只有 1×1 切片：后两格（(1,0) 与 (5,5)）超界 → 冲突；首格保留 alt
	var plan := TileReplace.plan(m, cells, "stone")
	eq((plan.get("conflicts", []) as Array).size(), 2, "超界切片各列一条冲突")
	eq((plan.get("cells", []) as Array).size(), 1, "一格可替换")
	eq(int((plan.get("cells", []) as Array)[0].get("alt", -1)), 1, "变换位随格保留")
	# 指定目标切片：所有格都写到 (0,0)，无边界冲突
	var plan2 := TileReplace.plan(m, cells, "stone", Vector2i(0, 0))
	eq((plan2.get("conflicts", []) as Array).size(), 0, "指定合法切片后无冲突")
	eq((plan2.get("cells", []) as Array).size(), 3, "三格全可替换")
	# 目标不是瓦片类：直接拒绝
	var plan3 := TileReplace.plan(m, cells, "tree")
	eq((plan3.get("cells", []) as Array).size(), 0, "非图集资产不产替换计划")
	ok((plan3.get("conflicts", []) as Array).size() > 0, "非图集资产报冲突")
	# 未知资产同样拒绝
	var plan4 := TileReplace.plan(m, cells, "ghost")
	ok((plan4.get("conflicts", []) as Array).size() > 0, "未知资产报冲突")

## 图集边界：palette 声明优先（grass 2×1）
func test_tile_atlas_bounds() -> void:
	var m := _manifest()
	eq(TileReplace.atlas_bounds(m, "grass"), Vector2i(2, 1), "palette 声明的切片边界")
	eq(TileReplace.atlas_bounds(m, "stone"), Vector2i(1, 1), "单切片边界")
	eq(TileReplace.atlas_bounds(m, "tree"), Vector2i.ZERO, "非瓦片返回 ZERO")
