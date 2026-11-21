extends "res://tests/_suite_base.gd"
## 两个存储层：MapStore 写读回环 + 复制图重发码 + ContentStore 写读回环（临时目录，跑完清理）。

const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ProjectAudit := preload("res://src/project/project_audit.gd")

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