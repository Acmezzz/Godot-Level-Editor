extends SceneTree
## F1 基线/对照采集（headless）：在临时工程里造大样例，分段计时后打印。
## 用法：godot --headless --path . --script res://tools/f1_bench.gd
## 覆盖：资产池逐项访问、地图码表、时间轴区间与冲突、整图读取。
## 画布级（绘制/碰撞重建）需要视口，不在本工具内；那部分用 GUI 目测 + 计数器。
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")

const TMP := "user://f1_bench_project"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_clean(TMP)
	DirAccess.make_dir_recursive_absolute(TMP.path_join("maps"))
	# 1000 个资产声明（项目样例口径）
	var assets: Array = []
	for i in 1000:
		assets.append({"id": "A%04d" % i, "kind": "entity", "prefab": "p%d.tscn" % i,
			"name": "资产 %d" % i, "fields": [{"id": "f1", "kind": "input", "type": "int"}]})
	var m := {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "assets": assets}
	# 20 张图（每张带码）——code_map 的样例
	for i in 20:
		var doc := MapStore.new_map("图%d" % i, 32, 32)
		MapStore.write(m, "图%d" % i, doc)
	# 1000 步 / 8 轨的演出
	var steps: Array = []
	for i in 1000:
		steps.append({"step": "S0001", "at": float(i) * 0.25, "duration": 0.2, "track": i % 8})
	# 10000 瓦片的抽取口径（纯数组构造 + JSON 序列化，代理 extract 的序列化成本）
	var tiles: Array = []
	for i in 10000:
		tiles.append([i % 128, floori(i / 128.0), "A0001", 0, 0, 0])

	var t0 := Time.get_ticks_usec()
	for i in 5000:
		AssetDecl.by_id(m, "A%04d" % (i % 1000))
	var t_byid := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for i in 50:
		MapStore.code_map(m)
	var t_codemap := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var conflicts := 0
	for i in 100:
		var tl := StepTimeline.to_timeline(steps)
		conflicts += StepTimeline.conflicts_of(tl).size()
	var t_timeline := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for i in 20:
		JSON.stringify({"tiles": tiles, "objects": []})
	var t_json := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var all := MapStore.read_all(m)
	var t_readall := Time.get_ticks_usec() - t0

	# A2 保存前冲突检查：读整份地图文本算 sha256（与 map_file._file_digest 同算法）。
	# 1 万瓦片的地图 JSON 约 0.4 MB，这个数就是每次保存多付的一次读盘+哈希。
	var big_path := MapStore.path_for(m, "图0")
	var big_text := JSON.stringify({"tiles": tiles, "objects": []}, "", true)
	var wf := FileAccess.open(big_path, FileAccess.WRITE)
	wf.store_string(big_text)
	wf.close()
	t0 = Time.get_ticks_usec()
	for i in 20:
		var f2 := FileAccess.open(big_path, FileAccess.READ)
		var _d := f2.get_as_text().sha256_text()
		f2.close()
	var t_digest := Time.get_ticks_usec() - t0

	# P05：区域遍历口径——满图矩形 × 3 层的「面积扫描」vs「used_cells 过滤」。
	# 用稀疏占位（每 5 格 1 个 ≈ 20%）模拟真实地图；两个数直接对比数量级。
	var sel := Rect2i(0, 0, 256, 256)
	var used := {}
	for i in 10000:
		used[Vector2i(i % 256, floori(i / 256.0))] = true
	t0 = Time.get_ticks_usec()
	var hits_old := 0
	for li in 3:
		for y in range(sel.position.y, sel.end.y):
			for x in range(sel.position.x, sel.end.x):
				if used.has(Vector2i(x, y)):
					hits_old += 1
	var t_rect := Time.get_ticks_usec() - t0
	var sorted_cells: Array = used.keys()
	sorted_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	t0 = Time.get_ticks_usec()
	var hits_new := 0
	for li in 3:
		for c in sorted_cells:
			if sel.has_point(c):
				hits_new += 1
	var t_sparse := Time.get_ticks_usec() - t0
	print("F1_BENCH rect_3x256x256=%dus used_cells_3x=%dus hits=%d/%d"
		% [t_rect, t_sparse, hits_old, hits_new])

	print("F1_BENCH byid_5000=%dus codemap_50=%dus timeline_100=%dus json_20=%dus readall_20=%dus"
		% [t_byid, t_codemap, t_timeline, t_json, t_readall])
	print("F1_BENCH digest_20=%dus bytes=%d" % [t_digest, big_text.length()])
	print("F1_BENCH detail conflicts=%d maps=%d mem=%d" % [conflicts, all.size(), OS.get_static_memory_usage()])
	_clean(TMP)
	quit(0)

func _clean(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_clean(dir.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)