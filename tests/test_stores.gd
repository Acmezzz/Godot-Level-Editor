extends "res://tests/_suite_base.gd"
## 两个存储层：MapStore 写读回环 + 复制图重发码 + ContentStore 写读回环（临时目录，跑完清理）。

const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ReferenceUsage := preload("res://src/project/reference_usage.gd")
const Recovery := preload("res://src/map/recovery.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const EventLayers := preload("res://src/project/event_layers.gd")

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

func test_asset_deletion_usage_covers_tiles_nested_refs_and_bad_maps() -> void:
	_wipe()
	var m := _fake_manifest()
	m.assets = [{"id": "owner", "kind": "entity", "fields": [{"id": "rows", "type": "array",
		"of": "record", "fields": [{"id": "target", "type": "asset_ref"}]}]}]
	var live := {"tiles": {"L1": [[0, 0, "used", 0, 0, 0]]},
		"objects": [{"asset": "owner", "props": {"rows": [{"target": "used"}]}}]}
	DirAccess.make_dir_recursive_absolute(m._maps_dir)
	ok(MapStore.write_text(m._maps_dir.path_join("bad.json"), "{"), "写入损坏地图夹具")
	var usage := ReferenceUsage.asset_deletion_usage(m, "used", live, [])
	eq(usage.live, 2, "瓦片和嵌套实例引用均计入")
	eq(usage.bad.size(), 1, "不可读地图使扫描不完整")
	_wipe()

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

func test_shared_drawings_compose_overlapping_map_sets() -> void:
	_wipe()
	var m := _fake_manifest()
	for group in ["X", "Y", "Z", "W", "V"]:
		var data := MapStore.new_map(group, 8, 8)
		data.meta.code = "GRP" + group
		data.collision = [{"x": 1, "y": 2}]
		ok(MapStore.write(m, group, data), "write independent drawing " + group)
	m.eventLayers = {
		"X": {"drawingMap": "GRPX", "maps": ["MAPA", "MAPB", "MAPC"], "drawOrder": -1},
		"Y": {"drawingMap": "GRPY", "maps": ["MAPB", "MAPC", "MAPD", "MAPE", "MAPF"]},
		"Z": {"drawingMap": "GRPZ", "maps": ["MAPA", "MAPC", "MAPF"], "drawOrder": -2},
		"W": {"drawingMap": "GRPW", "maps": ["MAPC"], "drawOrder": 3},
		"V": {"drawingMap": "GRPV", "maps": ["MAPC"], "drawOrder": 1},
	}
	m.eventLayers = JSON.parse_string(JSON.stringify(m.eventLayers))
	eq(EventLayers.issues(m), [], "JSON round trip accepts integer draw orders")
	eq(EventLayers.drawing_stack(m.eventLayers), ["Z", "X", "", "V", "Y", "W"], "base map divides the drawing stack")
	var expected := {"A": ["Z", "X"], "B": ["X", "Y"], "C": ["Z", "X", "V", "Y", "W"],
		"D": ["Y"], "E": ["Y"], "F": ["Z", "Y"]}
	for board in expected:
		var drawings := ReferenceIndex.event_drawings(m, "MAP" + board)
		eq(drawings.map(func(row): return row.layer), expected[board], "matching drawings on map " + board)
		for drawing in drawings:
			var cells: Array = drawing.data.collision
			ok(drawing.data.meta.code == drawing.map and cells.size() == 1 and cells[0].x == 1 and cells[0].y == 2
				and drawing.drawOrder == m.eventLayers[drawing.layer].get("drawOrder", 1),
				"each drawing carries its order, map code and collision data")
	m.eventLayers["Y"].erase("maps")
	eq(ReferenceIndex.event_drawings(m, "MAPG").map(func(row): return row.layer), ["Y"], "an unscoped group applies to new maps")
	eq(ReferenceIndex.event_drawings(m, "GRPX"), [], "a drawing does not recursively load another drawing")
	m.eventLayers["Y"].maps = []
	eq(ReferenceIndex.event_drawings(m, "MAPD"), [], "an explicitly empty group matches no maps")
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

## §7.2：删除前必须由存储层留下历史快照；拿不到快照就不删（删完没有「当前」可备份）。
func test_content_remove_backs_up_history_first() -> void:
	_wipe()
	var m := _fake_manifest()
	ok(ContentStore.write(m, "f1", "D1E2F3", {"name": "keep me", "fields": {}}), "写入内容")
	var path := ContentStore.path_for(m, "f1", "D1E2F3")
	var res := ContentStore.remove_ex(m, "f1", "D1E2F3")
	eq(bool(res.get("ok", false)), true, "删除成功")
	eq(bool(res.get("backed_up", false)), true, "删除前留下了快照")
	ok(not FileAccess.file_exists(path), "正式文件已删")
	var snap := path.get_base_dir().path_join(".history").path_join(path.get_file() + ".1")
	ok(FileAccess.file_exists(snap), "快照在 .history/<名>.json.1")
	ok(FileAccess.get_file_as_string(snap).contains("keep me"), "快照内容 = 删除前的文件")
	# 幂等：再删一次是「已不存在」，不应谎报备份
	var again := ContentStore.remove_ex(m, "f1", "D1E2F3")
	eq(bool(again.get("ok", false)), true, "重复删除幂等")
	eq(bool(again.get("backed_up", false)), false, "无可删文件时不谎报备份")
	_wipe()

## §7.2：快照写不进去时必须**拒绝删除**（宁可留着也不能丢掉可回滚性）。
func test_content_remove_refuses_without_history() -> void:
	_wipe()
	var m := _fake_manifest()
	ok(ContentStore.write(m, "f1", "A9B8C7", {"name": "must survive", "fields": {}}), "写入内容")
	var path := ContentStore.path_for(m, "f1", "A9B8C7")
	# 把 .history 占成一个**文件**，目录建不出来 → 备份必然失败
	var hist := path.get_base_dir().path_join(".history")
	var blocker := FileAccess.open(hist, FileAccess.WRITE)
	blocker.store_string("not a dir")
	blocker.close()
	var res := ContentStore.remove_ex(m, "f1", "A9B8C7")
	eq(bool(res.get("ok", false)), false, "备份失败 → 拒绝删除")
	eq(bool(res.get("backed_up", false)), false, "报告未备份")
	ok(FileAccess.file_exists(path), "原文件仍在（没删）")
	ok(FileAccess.get_file_as_string(path).contains("must survive"), "内容未被破坏")
	DirAccess.remove_absolute(hist)
	_wipe()
func test_content_write_conflict_detects_same_second_same_size_edit() -> void:
	_wipe()
	var m := _fake_manifest()
	ok(ContentStore.write(m, "f1", "C1D2E3", {"name": "aaaa", "fields": {}}), "初始内容写入")
	var path := ContentStore.path_for(m, "f1", "C1D2E3")
	var rd := ContentStore.read_ex(m, "f1", "C1D2E3")
	eq(str(rd.status), "ok", "初始读取成功")
	var base := str(rd.digest)
	ok(base != "", "读取带出磁盘摘要")
	# 外部改写：长度不变、同一秒内完成——mtime+size 校验会当作未改
	var old := FileAccess.get_file_as_string(path)
	var ext := old.replace("aaaa", "bbbb")
	eq(ext.length(), old.length(), "外部改写长度不变")
	var wf := FileAccess.open(path, FileAccess.WRITE)
	wf.store_string(ext)
	wf.close()
	var res := ContentStore.write_ex(m, "f1", "C1D2E3", {"name": "mine"}, base)
	eq(bool(res.get("conflict", false)), true, "同秒同长度的外部修改被摘要检出")
	eq(bool(res.get("ok", false)), false, "冲突时不写盘")
	ok(FileAccess.get_file_as_string(path).contains("bbbb"), "外部内容未被覆盖")
	# 用最新摘要作基线可以正常写入（用户重读后继续编辑）
	var fresh := ContentStore.read_ex(m, "f1", "C1D2E3")
	var res2 := ContentStore.write_ex(m, "f1", "C1D2E3", {"name": "mine"}, str(fresh.digest))
	eq(bool(res2.get("ok", false)), true, "以最新摘要为基线可写入")
	eq(bool(res2.get("conflict", false)), false, "无冲突")
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
	# 注入失败：写盘注入口命中该图路径（唯一临时名之后无法再靠占用 .tmp 路径）
	var blocked := str(m._maps_dir).path_join("w.json")
	MapStore.test_fail_prefix = blocked
	d.meta.name = "w2"
	ok(not MapStore.write(m, "w", d), "写失败被报告（不是静默成功）")
	eq(FileAccess.get_file_as_string(path), before, "失败后原文件内容不变")
	# 解除阻塞后同 ID 重试
	MapStore.test_fail_prefix = ""
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

## F1/P03：code_map 带签名缓存，写盘路径必须显式失效——否则保存后同秒内
## 这张表的角标/引用解析还停在旧码上。
func test_code_map_cache_invalidated_on_write() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("cm", 8, 8)
	d.meta["code"] = "AAA1"
	ok(MapStore.write(m, "cm", d), "首写")
	eq(str(MapStore.code_map(m).get("AAA1", "")), "cm", "码表可查到")
	var cm2 := MapStore.code_map(m)
	ok(cm2.has("AAA1") and not cm2.has("BBB2"), "初次码表")
	# 同秒改码重写：签名里的 mtime 可能不变，靠写路径 invalidate_code_map 兜住
	d.meta["code"] = "BBB2"
	ok(MapStore.write(m, "cm", d), "改码重写")
	var cm3 := MapStore.code_map(m)
	eq(str(cm3.get("BBB2", "")), "cm", "写后码表立刻反映新码")
	ok(not cm3.has("AAA1"), "旧码已被移除（不是叠着两份）")
	# 改名同样换键
	eq(MapStore.rename_map(m, "cm", "cm2"), "", "改名成功")
	var cm4 := MapStore.code_map(m)
	eq(str(cm4.get("BBB2", "")), "cm2", "改名后码表跟到新图名")
	ok(not cm4.has("AAA1"), "旧码不残留")
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
	ok(not MapStore.write(m, "b", b) and not FileAccess.file_exists(MapStore.path_for(m, "b")), "编辑器拒绝写入相同地图码")
	ok(MapStore.write_json(MapStore.path_for(m, "b"), b), "模拟外部工具写入重复地图码")
	ok(not MapStore.write(m, "a", a), "已有歧义也不能持续发布")
	ok(MapStore.rename_map(m, "a", "a2").contains("地图码") and not FileAccess.file_exists(MapStore.path_for(m, "a2")),
		"改名只豁免自己的原路径，拒绝第三方同码")
	var conf := MapStore.code_conflicts(m)
	ok(conf.has("ZZZZ"), "检出重复码")
	eq((conf.get("ZZZZ", []) as Array).size(), 2, "列出两个文件")
	eq(ReferenceIndex.resolve_map(m, "ZZZZ").status, "ambiguous", "拒绝歧义地图引用")
	b.meta.code = MapStore.allocate_code(m)
	ok(MapStore.write(m, "b", b) and MapStore.code_conflicts(m).is_empty(), "显式换码可以恢复唯一性")
	_wipe()

## V4 §4.2-4：地图键解析六态——不合法键 / 图在但读不出，都不能压成 missing
## （压成 missing 会让审计把合法引用当悬空清掉）。
func test_resolve_map_states() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("okmap", 8, 8)
	d.meta["code"] = "GOOD"
	ok(MapStore.write(m, "okmap", d), "正常图写入")
	eq(str(ReferenceIndex.resolve_map(m, "").get("status")), "unset", "空键 = unset")
	eq(str(ReferenceIndex.resolve_map(m, "GOOD").get("status")), "ok", "码命中 = ok")
	eq(ReferenceIndex.resolve_map(m, "okmap").status, "missing", "文件名不参与引用解析")
	var same_name := MapStore.new_map("GOOD", 8, 8)
	same_name.meta["code"] = "OTHR"
	ok(MapStore.write(m, "GOOD", same_name), "写入与地图码同名的另一张地图")
	eq(ReferenceIndex.resolve_map(m, "GOOD").key, "okmap", "只按地图码解析")
	_wipe()

func test_document_guards_invalidate_delayed_actions() -> void:
	var app := preload("res://src/app.gd").new()
	var files := preload("res://src/ui/map_file.gd").new(app)
	app._map_file_ctrl = files
	var snapshot := files.document_guard()
	var identity := files.document_guard(false)
	ok(snapshot.call() and identity.call(), "操作针对当前文档")
	files.note_edit()
	ok(not snapshot.call() and identity.call(), "修改使快照失效但不改变文档身份")
	files._begin_doc_op()
	ok(not identity.call(), "切图使旧操作失效")
	var current := files.document_guard()
	app._map_file_ctrl = null
	ok(not current.call(), "离开项目使旧操作失效")
	app.free()


func test_map_copy_preserves_an_external_content_file() -> void:
	_wipe()
	var m := _fake_manifest()
	var dc := preload("res://src/project/document_commit.gd")
	var data := MapStore.new_map("copy", 8, 8)
	var prep := dc.prepare(m, "copy", data, [
		{"fn_id": "dialog", "cid": "first", "data": {"name": "ours"}},
		{"fn_id": "dialog", "cid": "second", "data": {"name": "ours"}},
	])
	ok(ContentStore.write(m, "dialog", "second", {"name": "external"}), "准备之后创建同名内容")
	var result := dc.apply(prep.plan)
	ok(result.error != "", "拒绝覆盖新增的文件")
	ok(not FileAccess.file_exists(MapStore.path_for(m, "copy")), "内容失败时不发布地图")
	eq(result.written_contents, [], "预检发现冲突，未写入任何内容")
	ok(not FileAccess.file_exists(ContentStore.path_for(m, "dialog", "first")), "没有留下部分写入的内容")
	eq(ContentStore.read(m, "dialog", "second").name, "external", "保留外部数据")
	_wipe()

## A3：草稿写到 editor/drafts/<地图码>.json，记录目标/基线/快照，可读回、可删。
func test_draft_roundtrip_by_map_code() -> void:
	_wipe()
	var m := _fake_manifest()
	var snap := MapStore.new_map("d", 8, 8)
	var target := str(m._maps_dir).path_join("d.json")
	var p := Recovery.write_draft(m, "AB23", "d", target, "digest-1", snap,
		[{"fn_id": "dialog", "id": "X1", "data": {"id": "X1", "fields": {}}}])
	ok(p != "", "草稿写入成功")
	ok(p.contains("editor/drafts") and p.ends_with("AB23.json"), "路径按地图码")
	var d := Recovery.read_draft(m, "AB23", "d")
	eq(str(d.get("targetPath")), target, "记录目标路径")
	eq(str(d.get("baseline")), "digest-1", "记录正式图基线")
	eq((d.get("snapshot", {}) as Dictionary).size() > 0, true, "记录地图快照")
	eq((d.get("pendingContents", []) as Array).size(), 1, "记录待写内容载荷")
	ok(Recovery.list_drafts(m).has("AB23"), "可列出草稿")
	ok(Recovery.remove_draft(m, "AB23", "d"), "可删除草稿")
	ok(Recovery.list_drafts(m).is_empty(), "删除后不再列出")
	_wipe()

## A3：草稿按键（文件名）寻址。带码地图的键是码，用「空码 + 图名」重算会指向另一条路径，
## 这正是「草稿写得进、恢复列表读不到」的旧形态；冲突备份只留档、不算草稿。
func test_draft_key_addressing() -> void:
	_wipe()
	var m := _fake_manifest()
	var snap := MapStore.new_map("d", 8, 8)
	var target := str(m._maps_dir).path_join("d.json")
	ok(Recovery.write_draft(m, "AB23", "d", target, "", snap) != "", "按码写草稿")
	ok(Recovery.read_draft(m, "", "d").is_empty(), "空码 + 图名的旧口径读不到带码草稿")
	eq(str(Recovery.read_draft_key(m, "AB23").get("mapName")), "d", "按键读到同一份草稿")
	var copy := Recovery.draft_path_of_key(m, "AB23") + ".conflict.json"
	Recovery.write_text(copy, "{}")
	eq(Recovery.list_drafts(m), ["AB23"], "冲突备份不列入可恢复草稿")
	ok(Recovery.remove_draft_key(m, "AB23"), "按键删除")
	ok(Recovery.list_drafts(m).is_empty(), "删除后只剩备份文件，不再列出")
	_wipe()

func test_legacy_draft_requires_marker() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var marked := str(m._maps_dir).path_join("a.autosave.json")
	MapStore.write_json(marked, {"_autosave_of": "a", "version": 7})
	var plain := str(m._maps_dir).path_join("foo.autosave.json")
	MapStore.write_json(plain, {"version": 7})
	# 列表口径同一规则：正式图名就叫 foo.autosave 时必须列得出来（否则永远打不开）
	var names := MapStore.list_maps(m)
	ok(names.has("foo.autosave"), "缺标记的 foo.autosave 列为正式图：%s" % str(names))
	ok(not names.has("a.autosave"), "带标记的旧草稿不列入地图：%s" % str(names))
	_wipe()

## A3：提交日志逐条判定——写后结果摘要 == 当前摘要 → 已写；仍等于基线 → 未写；
## 两边都不符（外部改过/写了一半）→ 转人工复核，不自动重放。
func test_pending_log_partial_detection() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var a := str(m._maps_dir).path_join("a.json")
	var b := str(m._maps_dir).path_join("b.json")
	var c := str(m._maps_dir).path_join("c.json")
	MapStore.write_json(a, {"v": 1})
	MapStore.write_json(b, {"v": 1})
	MapStore.write_json(c, {"v": 1})
	var receipt := Recovery.begin_pending(m, "test", [
		{"path": a, "baseline": Recovery.digest(a), "expect": JSON.stringify({"v": 2}, "\t").sha256_text(), "kind": "map"},
		{"path": b, "baseline": Recovery.digest(b), "expect": "", "kind": "content"},
		{"path": c, "baseline": Recovery.digest(c), "expect": "", "kind": "manifest"},
	])
	ok(receipt != "", "登记成功")
	# a 写成登记的版本；b 保持原样；c 被外部改动。
	MapStore.write_json(a, {"v": 2})
	MapStore.write_json(c, {"v": 9})
	var scan := Recovery.scan_pending(m)
	eq(scan.size(), 1, "扫到一条日志")
	var rec: Dictionary = scan[0]
	eq(str(rec.get("status")), "manual", "有对不上的文件 → 人工复核优先于 partial")
	eq(int(rec.get("written")), 1, "一条已写")
	eq(int(rec.get("pending")), 1, "一条未写")
	eq(int(rec.get("manual")), 1, "一条对不上")
	var states: Array = []
	for e in (rec.get("entries", []) as Array):
		states.append(str((e as Dictionary).get("state", "")))
	eq(states, ["written", "pending", "manual"], "逐条状态按摘要判定")
	# §4.4：manual 再分「外部改变」（内容对不上）与「可跳过」（目标不在且无基线）
	eq((rec.get("external", []) as Array).size(), 1, "外部改动一条进 external")
	eq((rec.get("skipped", []) as Array).size(), 0, "目标都在，没有可跳过项")
	ok(Recovery.clear_pending(receipt), "清除日志")
	ok(Recovery.scan_pending(m).is_empty(), "清除后扫不到")
	# 坏日志不能静默隐身：写出坏 JSON 后应扫到 status=corrupt
	var bad := str(m._maps_dir).get_base_dir().path_join("editor/pending/pending-broken.json")
	Recovery.write_text(bad, "{ not json")
	var scan2 := Recovery.scan_pending(m)
	var corrupt := 0
	for r2 in scan2:
		if str((r2 as Dictionary).get("status", "")) == "corrupt":
			corrupt += 1
	eq(corrupt, 1, "坏日志 → status=corrupt（不静默跳过）")
	DirAccess.remove_absolute(bad)
	_wipe()

func test_pending_recovers_from_expected_digest() -> void:
	_wipe()
	var m := _fake_manifest()
	var path := MapStore.path_for(m, "a")
	var text := "{\"v\": 2}"
	var receipt := Recovery.begin_pending(m, "中断", [
		{"path": path, "expect": text.sha256_text(), "expect_absent": true},
	])
	ok(receipt != "", "登记预期摘要")
	eq(Recovery.scan_pending(m)[0].status, "stale", "未写的新文件仍可判为待写")
	ok(Recovery.write_text(path, text), "写入登记的版本")
	eq(Recovery.scan_pending(m)[0].status, "done", "用预期摘要识别已完成写入")
	_wipe()


func test_revised_save_recovers_previously_written_content() -> void:
	_wipe()
	var m := _fake_manifest()
	var dc := preload("res://src/project/document_commit.gd")
	var map := MapStore.new_map("retry", 8, 8)
	var rows := [{"fn_id": "dialog", "cid": "first", "data": {"name": "first version"}}]
	var first := dc.prepare(m, "retry", map, rows)
	MapStore.test_fail_prefix = MapStore.path_for(m, "retry")
	var failed := dc.apply(first.plan)
	MapStore.test_fail_prefix = ""
	ok(failed.error != "", "地图写入失败")
	eq(ContentStore.read(m, "dialog", "first").get("name"), "first version", "内容此前已写")
	map.meta.w = 9
	rows[0].data.name = "edited after failure"
	var retry := dc.prepare(m, "retry", map, rows)
	dc.recover_log(retry.plan)
	eq(dc.apply(retry.plan).error, "", "编辑后可继续本次保存")
	eq(MapStore.read(m, "retry").meta.w, 9, "写入调整后的地图")
	eq(ContentStore.read(m, "dialog", "first").get("name"), "edited after failure", "只覆盖本次发布已写的版本")
	eq(Recovery.scan_pending(m).size(), 0, "提交后清理日志")
	_wipe()


func test_case_only_map_rename_keeps_identity() -> void:
	_wipe()
	var m := _fake_manifest()
	var data := MapStore.new_map("Map", 8, 8)
	data.meta.code = "ABCD"
	ok(MapStore.write(m, "Map", data), "原图已保存")
	eq(MapStore.rename_map(m, "Map", "map"), "", "只改大小写")
	eq(MapStore.list_maps(m), ["map"], "文件名大小写已更新")
	var result := MapStore.read(m, "map")
	eq(result.get("meta", {}).get("name"), "map", "同步图内名称")
	eq(result.get("meta", {}).get("code"), "ABCD", "地图码不变")
	_wipe()


func test_inherited_content_links_protect_removed_port() -> void:
	_wipe()
	var m := _fake_manifest()
	var spatial := preload("res://src/project/spatial_reference_check.gd")
	var inherit_field := {"id": "next", "type": "flow_target", "contentTypes": ["dialog"],
		"contentMapContext": "inherit"}
	m.assets = [{"id": "door", "kind": "entity", "ports": [{"id": "in", "type": "go", "x": 0, "y": 0}],
		"fields": [inherit_field]}]
	m.functions = {"dialog": {"code": "DLOG", "fields": [inherit_field.merged({"code": "NEXT"}),
		{"id": "port", "code": "PORT", "type": "port_ref"}]}}
	var board := MapStore.new_map("board", 8, 8)
	board.meta.code = "ABCD"
	var layer: String = board.meta.layers[0].id
	board.objects = [
		{"asset": "door", "code": "AAAA", "layer": layer, "x": 0, "y": 0,
			"props": {"next": {"function": "dialog", "content": "parent"}}},
		{"asset": "door", "code": "BBBB", "layer": layer, "x": 1, "y": 0},
	]
	ok(MapStore.write(m, "board", board), "保存有目标实例的地图")
	ok(ContentStore.write(m, "dialog", "parent",
		{"fields": {"NEXT": {"function": "dialog", "content": "child"}}}), "继承内容转发上下文")
	var child := {"fields": {"PORT": {"map": "", "inst": "BBBB", "port": "in"}}}
	ok(ContentStore.write(m, "dialog", "child", child), "子内容引用本图端口")
	var cropped := board.duplicate(true)
	cropped.objects.pop_back()
	ok(spatial.blocked_removals(m, board, cropped, []).contains("child"), "阻止经两级继承留下悬空端口")
	ok(spatial.needs_map_save(m, "dialog", child, board, cropped), "新端口尚未存在于正式图时应暂存")
	ok(not spatial.needs_map_save(m, "dialog", child, board, board), "目标在正式图时可即时写")
	_wipe()
