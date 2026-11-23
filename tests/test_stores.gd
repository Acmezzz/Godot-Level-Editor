extends "res://tests/_suite_base.gd"
## 两个存储层：MapStore 写读回环 + 复制图重发码 + ContentStore 写读回环（临时目录，跑完清理）。

const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ProjectAudit := preload("res://src/project/project_audit.gd")
const Recovery := preload("res://src/map/recovery.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")

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
	var all := ProjectAudit._content_checks(m, {ProjectAudit._content_key("f1", "A1B2"): true})
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
	eq(str(ReferenceIndex.resolve_map(m, "okmap").get("status")), "ok", "图名命中 = ok")
	eq(str(ReferenceIndex.resolve_map(m, "nosuch").get("status")), "missing", "普通未知键 = missing")
	eq(str(ReferenceIndex.resolve_map(m, "bad/name").get("status")), "invalid",
		"不能当地图名的键 = invalid（永远解析不成文件）")
	# 图名在目录里、内容读不出 = unreadable（不是 missing）
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var bad_path := str(m._maps_dir).path_join("broken.json")
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	eq(str(ReferenceIndex.resolve_map(m, "broken").get("status")), "unreadable",
		"文件在但读不出 = unreadable")
	# 引用解析的消费侧：读不出的目标不参与悬空判定
	var tgt := MapStore.new_map("tgt", 8, 8)
	tgt.meta["code"] = "TGTT"
	ok(MapStore.write(m, "tgt", tgt), "目标图写入")
	var audit := ProjectAudit.audit(m)
	var cleared := 0
	for e in audit:
		var fx = (e as Dictionary).get("fix", null)
		if fx is Dictionary and str((fx as Dictionary).get("map", "")) == "broken":
			cleared += 1
	eq(cleared, 0, "读不出的目标图不产出清空项")
	DirAccess.remove_absolute(bad_path)
	_wipe()

## §4.4-3：提交收据逐目标列出——提前返回时未轮到的目标一律记 pending，
## 调用方不必猜「哪些落盘了」。
func test_document_commit_receipts() -> void:
	var DC := preload("res://src/project/document_commit.gd")
	# apply() 是协程（钩子是保存协程），测试里只验证收据辅助函数；空计划分支见 prepare/app 调用侧
	var plan_targets: Array = [
		{"path": "a", "kind": "manifest", "id": ""},
		{"path": "b", "kind": "content", "id": "C1"},
		{"path": "c", "kind": "map", "id": "m"},
	]
	var rest: Array = DC._receipts_pending(plan_targets, "b")
	eq(rest.size(), 1, "停在 b 之后只剩 c")
	eq(str((rest[0] as Dictionary).get("status", "")), "pending", "未轮到 = pending")
	eq(str((rest[0] as Dictionary).get("kind", "")), "map", "收据带 kind")
	eq(DC._receipts_pending(plan_targets, "").size(), 3, "还没开始 = 全部 pending")
	var rc: Dictionary = DC._receipt_of(plan_targets[1], "written", "DIG")
	eq(str(rc.get("id", "")), "C1", "收据带目标身份")
	eq(str(rc.get("digest", "")), "DIG", "写到盘上的目标带摘要")

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
	eq(Recovery.legacy_draft_owner(m, marked), "a", "带标记的识别为草稿")
	var plain := str(m._maps_dir).path_join("foo.autosave.json")
	MapStore.write_json(plain, {"version": 7})
	eq(Recovery.legacy_draft_owner(m, plain), "", "无标记的按普通地图处理")
	# 列表口径同一规则：正式图名就叫 foo.autosave 时必须列得出来（否则永远打不开）
	var names := MapStore.list_maps(m)
	ok(names.has("foo.autosave"), "缺标记的 foo.autosave 列为正式图：%s" % str(names))
	ok(not names.has("a.autosave"), "带标记的旧草稿不列入地图：%s" % str(names))
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
	# 注入替换失败：写盘注入口（连续三次，旧历史条目不减少）
	var path := str(m._maps_dir).path_join("h.json")
	var before_hist := Recovery.list_history(m, "HHHH", "h").size()
	MapStore.test_fail_prefix = path
	for i in 3:
		ok(not MapStore.write(m, "h", d), "替换失败被报告 #%d" % i)
		eq(Recovery.list_history(m, "HHHH", "h").size(), before_hist, "失败不减少历史 #%d" % i)
	MapStore.test_fail_prefix = ""
	# 改名后按码查历史仍在（码不变 → 目录不变）
	eq(MapStore.rename_map(m, "h", "h2"), "", "改名成功")
	eq(Recovery.list_history(m, "HHHH", "h2").size(), before_hist, "改名后同码历史仍可查")
	eq(str((MapStore.read(m, "h2").meta as Dictionary).get("name", "")), "h2", "文件内 meta.name 同步")
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
	var log := Recovery.begin_pending(m, "test", [
		{"path": a, "baseline": Recovery.digest(a), "expect": "", "kind": "map"},
		{"path": b, "baseline": Recovery.digest(b), "expect": "", "kind": "content"},
		{"path": c, "baseline": Recovery.digest(c), "expect": "", "kind": "manifest"},
	])
	ok(log != "", "登记成功")
	# a 写成功 → 回填结果摘要；b 保持原样（未写）；c 被外部改动
	MapStore.write_json(a, {"v": 2})
	Recovery.mark_pending_written(m, log, 0, Recovery.digest(a))
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
	ok(Recovery.clear_pending(m, log), "清除日志")
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

## §7.1 阶段一：替换已成功但进度标记失败时必须停手，不能报成功也不能继续写。
## 这里直接验证底层判据：日志不在了，回填就返回 false（调用方据此停）。
func test_pending_mark_fails_when_log_gone() -> void:
	_wipe()
	var m := _fake_manifest()
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	var a := str(m._maps_dir).path_join("a.json")
	MapStore.write_json(a, {"v": 1})
	var log := Recovery.begin_pending(m, "t", [
		{"path": a, "baseline": Recovery.digest(a), "expect": "", "kind": "map"}])
	ok(log != "", "登记成功")
	ok(Recovery.mark_pending_written(m, log, 0, Recovery.digest(a)), "正常情况下回填成功")
	DirAccess.remove_absolute(log)
	ok(not Recovery.mark_pending_written(m, log, 0, Recovery.digest(a)), "日志被删 → 回填失败（调用方必须停手）")
	ok(not Recovery.mark_pending_written(m, log, 5, "x"), "越界索引也返回失败，不静默跳过")
	_wipe()