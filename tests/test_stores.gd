extends "res://tests/_suite_base.gd"
## 两个存储层：MapStore 写读回环 + 复制图重发码 + ContentStore 写读回环（临时目录，跑完清理）。

const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ProjectAudit := preload("res://src/project/project_audit.gd")
const Recovery := preload("res://src/map/recovery.gd")

const TMP := "user://test_stores_tmp"

func _fake_manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content"}

func _wipe() -> void:
	_nuke(TMP)

## 递归清临时目录（remove_absolute 不递归；写死文件清单每加一个测试就要补一次，改为一劳永逸）
func _nuke(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_nuke(p.path_join(str(d)))
	DirAccess.remove_absolute(p)

func test_map_write_read_roundtrip() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("t", 40, 30)
	ok(MapStore.write(m, "t", d), "写入成功")
	var data: Dictionary = MapStore.read(m, "t")
	ok(data.size() > 0, "读回非空")
	eq(int(data.get("version")), MapStore.FORMAT_VERSION, "版本保真")
	eq(str((data.get("meta", {}) as Dictionary).get("name")), "t", "图名保真")
	eq((data.get("meta", {}) as Dictionary).get("layers", []).size(), 2, "层栈保真")
	_wipe()

func test_duplicate_map_reissue_code() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("t", 40, 30)
	ok(MapStore.write(m, "t", d), "原图写入")
	eq(MapStore.duplicate_map(m, "t", "t2"), "", "复制成功")
	var d2 := MapStore.read(m, "t2")
	ok(d2.size() > 0, "复制图可读")
	var c1 := str((d.get("meta", {}) as Dictionary).get("code", ""))
	var c2 := str((d2.get("meta", {}) as Dictionary).get("code", ""))
	ok(c2 != "", "复制图有码")
	ok(c2 != c1, "复制图重发码（项目内唯一）")
	_wipe()

func test_content_drift_audit() -> void:
	_wipe()
	var m := _fake_manifest()
	m["functions"] = [{"id": "f1", "name": "F", "code": "CURCOD", "fields": []}]
	ok(ContentStore.write(m, "f1", "A1B2", {"name": "ok", "function": "CURCOD", "fields": {}}), "一致内容写入")
	ok(ContentStore.write(m, "f1", "C3D4", {"name": "drift", "function": "OLDCODE", "fields": {}}), "漂移内容写入")
	var all := ProjectAudit._content_checks(m, {"A1B2": true})
	var drift := 0
	var orphan := 0
	for e in all:
		var msg := str(e.get("message", ""))
		if str(e.get("path", "")) == "f1/C3D4" and msg.contains("码漂移"):
			drift += 1
		if str(e.get("path", "")) == "f1/C3D4" and msg.contains("孤立"):
			orphan += 1
	eq(drift, 1, "码漂移警告")
	eq(orphan, 1, "孤立内容警告")
	eq(all.size(), 2, "一致且被引用的 A1B2 零警告（全部警告只来自 C3D4）")
	_wipe()

func test_content_write_read_roundtrip() -> void:
	_wipe()
	var m := _fake_manifest()
	ok(ContentStore.write(m, "f1", "X1Y2Z3", {"name": "n", "fields": {"A111": 1}}), "内容写入")
	var c := ContentStore.read(m, "f1", "X1Y2Z3")
	eq(str(c.get("name")), "n", "内容读回")
	eq(int((c.get("fields", {}) as Dictionary).get("A111", 0)), 1, "字段保真")
	var ids := ContentStore.list_ids(m, "f1")
	eq(ids.size(), 1, "列出一个内容")
	ok(ids.has("X1Y2Z3"), "id 正确")
	_wipe()

func test_v7_tile_alt_roundtrip() -> void:
	var data := MapStore.new_map("alt", 8, 8)
	var layer_id := str((data.meta.layers[0] as Dictionary).get("id"))
	data.tiles[layer_id] = [[1, 2, "AB23", 0, 0, 5]]
	var decoded := MapStore.decode_text(JSON.stringify(data))
	ok(decoded.ok, "合法的 v7 瓦片变换可读回")
	if decoded.ok:
		eq(int(decoded.data.tiles[layer_id][0][5]), 5, "变换位保真")

## JSON 数字都是 float：5.0 合法；5.5 / -1 / 8 拒绝（D01）
func test_v7_tile_alt_float_rejected() -> void:
	var mk := func(alt):
		var d := MapStore.new_map("alt", 8, 8)
		var lid := str((d.meta.layers[0] as Dictionary).get("id"))
		d.tiles[lid] = [[1, 2, "AB23", 0, 0, alt]]
		return MapStore.decode_text(JSON.stringify(d))
	ok(bool((mk.call(5.0) as Dictionary).ok), "整数值 5.0 接受")
	ok(not bool((mk.call(5.5) as Dictionary).ok), "5.5 拒绝")
	ok(not bool((mk.call(8) as Dictionary).ok), "8 拒绝")

## A2 写失败注入：地图写不过时文件保持原内容，修好目标后同 ID 可重试成功。
func test_map_write_failure_keeps_old_and_retries() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var d := MapStore.new_map("w", 8, 8)
	ok(MapStore.write(m, "w", d), "首次写入成功")
	var path := str(m._maps_dir).path_join("w.json")
	var before := FileAccess.get_file_as_string(path)
	# 注入失败：目标路径变成目录 → .tmp 换名必失败
	var blocked := str(m._maps_dir).path_join("w.json.tmp")
	DirAccess.make_dir_recursive_absolute(blocked)
	d.meta.name = "w2"
	ok(not MapStore.write(m, "w", d), "写失败被报告（不是静默成功）")
	eq(FileAccess.get_file_as_string(path), before, "失败后原文件内容不变")
	# 解除阻塞后同 ID 重试
	_nuke(blocked)
	d.meta.name = "w"
	ok(MapStore.write(m, "w", d), "解除阻塞后同 ID 重试成功")
	_wipe()

## A2：写前校验失败以错误码拒绝，且不产生/不覆盖目标文件。
func test_map_write_rejects_bad_data() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var d := MapStore.new_map("v", 8, 8)
	# 重复层 id = 结构性错误（校验器必拒）
	var layers: Array = d.meta.layers
	d.meta.layers = [layers[0], (layers[1] as Dictionary).duplicate(true)]
	(d.meta.layers[1] as Dictionary)["id"] = str((layers[0] as Dictionary).get("id"))
	var path := str(m._maps_dir).path_join("v.json")
	ok(not MapStore.write(m, "v", d), "非法数据拒绝写入")
	ok(not FileAccess.file_exists(path), "拒绝时不生成目标文件")
	ok(MapStore.write_error(m, d) != "", "给出首个错误原因")
	_wipe()

## A2/D08：撞码时列出全部路径（引用解析不能靠 code_map 的最后写入者猜）
func test_map_code_conflict_lists_all_paths() -> void:
	_wipe()
	var m := _fake_manifest()
	var a := MapStore.new_map("a", 8, 8)
	var b := MapStore.new_map("b", 8, 8)
	a.meta["code"] = "ZZZZ"
	b.meta["code"] = "ZZZZ"
	ok(MapStore.write(m, "a", a), "a 写入")
	ok(MapStore.write(m, "b", b), "b 写入")
	var conf := MapStore.code_conflicts(m)
	ok(conf.has("ZZZZ"), "检出重复码")
	eq((conf.get("ZZZZ", []) as Array).size(), 2, "列出两个文件")
	var all := ProjectAudit.audit(m)
	var found := 0
	for e in all:
		if str(e.get("message", "")).contains("地图码重复") and str(e.get("message", "")).contains("a.json") \
				and str(e.get("message", "")).contains("b.json"):
			found += 1
	eq(found, 1, "审计报告给出两条路径")
	_wipe()

## A3：草稿写到 editor/drafts/<地图码>.json，记录目标/基线/快照，可读回、可删。
func test_draft_roundtrip_by_map_code() -> void:
	_wipe()
	var m := _fake_manifest()
	var snap := MapStore.new_map("d", 8, 8)
	var target := str(m._maps_dir).path_join("d.json")
	var p := Recovery.write_draft(m, "AB23", "d", target, "digest-1", snap, [{"id": "X1"}], ["X1"])
	ok(p != "", "草稿写入成功")
	ok(p.contains("editor/drafts") and p.ends_with("AB23.json"), "路径按地图码")
	var d := Recovery.read_draft(m, "AB23", "d")
	eq(str(d.get("targetPath")), target, "记录目标路径")
	eq(str(d.get("baseline")), "digest-1", "记录正式图基线")
	eq((d.get("snapshot", {}) as Dictionary).size() > 0, true, "记录地图快照")
	eq((d.get("pendingIds", []) as Array).size(), 1, "记录待写 ID")
	ok(Recovery.list_drafts(m).has("AB23"), "可列出草稿")
	ok(Recovery.remove_draft(m, "AB23", "d"), "可删除草稿")
	ok(Recovery.list_drafts(m).is_empty(), "删除后不再列出")
	_wipe()

## A3：旧式 .autosave.json 只认带 _autosave_of 的作为草稿来源
func test_legacy_draft_requires_marker() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var marked := str(m._maps_dir).path_join("a.autosave.json")
	MapStore.write_json(marked, {"_autosave_of": "a", "version": 7})
	eq(Recovery.legacy_draft_owner(m, marked), "a", "带标记的识别为草稿")
	var plain := str(m._maps_dir).path_join("foo.autosave.json")
	MapStore.write_json(plain, {"version": 7})
	eq(Recovery.legacy_draft_owner(m, plain), "", "无标记的按普通地图处理")
	_wipe()

## A3：地图历史按码分目录；替换失败时快照不入历史（旧条目不减少）
func test_map_history_by_code_and_write_failure() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("h", 8, 8)
	d.meta["code"] = "HHHH"
	ok(MapStore.write(m, "h", d), "首次写入")
	ok(MapStore.write(m, "h", d), "二次写入 → 产生一份历史")
	eq(Recovery.list_history(m, "HHHH", "h").size(), 1, "历史按地图码分目录")
	# 注入替换失败：目标变成目录 → 写入必失败
	var path := str(m._maps_dir).path_join("h.json")
	var before_hist := Recovery.list_history(m, "HHHH", "h").size()
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	ok(not MapStore.write(m, "h", d), "替换失败被报告")
	eq(Recovery.list_history(m, "HHHH", "h").size(), before_hist, "失败不增加历史")
	_nuke(path + ".tmp")
	_wipe()

## A3：提交日志登记 → 部分写入的判定 → 清除
func test_pending_log_partial_detection() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var a := str(m._maps_dir).path_join("a.json")
	var b := str(m._maps_dir).path_join("b.json")
	MapStore.write_json(a, {"v": 1})
	MapStore.write_json(b, {"v": 1})
	var log := Recovery.begin_pending(m, "test", [
		{"path": a, "baseline": "", "expect": Recovery.digest(a), "kind": "map"},
		{"path": b, "baseline": "", "expect": "not-yet", "kind": "content"},
	])
	ok(log != "", "登记成功")
	var scan := Recovery.scan_pending(m)
	eq(scan.size(), 1, "扫到一条日志")
	eq(str((scan[0] as Dictionary).get("status")), "partial", "判定为部分写入")
	ok(Recovery.clear_pending(m, log), "清除日志")
	ok(Recovery.scan_pending(m).is_empty(), "清除后扫不到")
	_wipe()