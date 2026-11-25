extends SceneTree
## §7.5 性能采样（headless）：两份夹具（1 万 / 10 万瓦片，含实体、引用、多层、碰撞），
## 逐场景多次采样后打印中位数 / P95 / 最长。数据侧全覆盖；**编辑帧**依赖视口，
## 本工具只能给「保存一次」「整图快照序列化」这类可计时的代理值，真实帧时间靠 GUI 采样。
## 用法：godot --headless --path . --script res://tools/perf_sample.gd
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")

const TMP := "user://perf_sample_project"
const MAPS := [["小图", 10000], ["大图", 100000]]
const REPS_IO := 11
const REPS_HEAVY := 5

var _samples := {}   # 场景名 -> [us]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_clean(TMP)
	DirAccess.make_dir_recursive_absolute(TMP.path_join("maps"))
	var assets: Array = []
	for i in 20:
		assets.append({"id": "A%04d" % i, "kind": "entity", "prefab": "p%d.tscn" % i,
			"name": "资产 %d" % i, "fields": [{"id": "f1", "kind": "input", "type": "int"}]})
	var m := {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "assets": assets,
		"functions": {"刷怪": {"code": "S0001"}}}
	for pair in MAPS:
		_build_map(m, str(pair[0]), int(pair[1]))
	# 项目里另有 18 张小图：全项目自检的规模近似真实工程
	for i in 18:
		var d := MapStore.new_map("背景图%d" % i, 32, 32)
		d["tiles"] = _tiles(d, 64, 0)
		MapStore.write(m, "背景图%d" % i, d)
	for pair2 in MAPS:
		_measure_reads(m, str(pair2[0]))
	_measure_write(m, "大图")
	_measure_serialize(m, "大图")
	_measure_lookups(m)
	_report()
	_clean(TMP)
	quit(0)

func _build_map(m: Dictionary, name: String, tile_count: int) -> void:
	var w := 256
	var h: int = maxi(256, floori(float(tile_count) / w) + 64)
	var d := MapStore.new_map(name, w, h)
	d["tiles"] = _tiles(d, tile_count, 40)
	d["collision"] = []
	for i in 40:
		d["collision"].append({"x": i, "y": 1, "type": "solid"})
	d["objects"] = []
	for i in 40:
		d["objects"].append({"asset": "A%04d" % (i % 20), "code": "E%03d" % i,
			"x": float(i), "y": float(i + 2), "layer": str(d.meta.layers[0].id),
			"props": {"f1": 1}})
	MapStore.write(m, name, d)

func _tiles(d: Dictionary, count: int, skip_rows: int) -> Dictionary:
	var lid := str(d.meta.layers[0].id)
	var out: Array = []
	var w := int(d.meta.w)
	var start := skip_rows * w
	for i in count:
		var idx := start + i
		out.append([idx % w, floori(float(idx) / w), "A%04d" % (i % 20), 0, 0, 0])
	return {lid: out}

## 冷开 = 清缓存后读盘并校验；热开 = MapStore.read 命中 mtime 缓存（画布切图走这条）
func _measure_reads(m: Dictionary, name: String) -> void:
	var path := MapStore.path_for(m, name)
	for i in REPS_IO:
		MapStore.invalidate_read_cache()
		var t0 := Time.get_ticks_usec()
		MapStore.read_path(path, m)
		_add("冷开 " + name, Time.get_ticks_usec() - t0)
		var t1 := Time.get_ticks_usec()
		MapStore.read(m, name)
		_add("热开 " + name, Time.get_ticks_usec() - t1)

## 保存一次 = 校验整图 + 序列化 + 原子替换 + 历史快照（不含 UI 确认框）
func _measure_write(m: Dictionary, name: String) -> void:
	var d: Dictionary = MapStore.read(m, name)
	var lid := str(d.meta.layers[0].id)
	var cells: Array = d.tiles[lid]
	for i in REPS_HEAVY:
		# 单格改动（短涂刷一笔的真实落盘成本）：改一格再写
		cells[0] = [int(cells[0][0]), int(cells[0][1]), "A%04d" % (i % 20), 0, 0, 0]
		var t0 := Time.get_ticks_usec()
		MapStore.write(m, name, d)
		_add("单格改+保存 " + name, Time.get_ticks_usec() - t0)

## 整图快照（撤销堆栈里全局操作的条目成本）
func _measure_serialize(m: Dictionary, name: String) -> void:
	var d: Dictionary = MapStore.read(m, name)
	for i in REPS_HEAVY:
		var t0 := Time.get_ticks_usec()
		JSON.stringify(d)
		_add("整图快照序列化 " + name, Time.get_ticks_usec() - t0)

## 切换实例/查资产：绘制出口每帧都要做的查表。
## 地图码表分冷/热两次采样：首次（目录列举 + 20 个 mtime）与命中缓存是两种成本。
func _measure_lookups(m: Dictionary) -> void:
	for i in REPS_IO:
		var t0 := Time.get_ticks_usec()
		for k in 2000:
			AssetDecl.by_id(m, "A%04d" % (k % 20))
		_add("切实例查表×2000", Time.get_ticks_usec() - t0)
		MapStore.invalidate_code_map()
		var t1 := Time.get_ticks_usec()
		MapStore.code_map(m)
		_add("地图码表重建(冷)", Time.get_ticks_usec() - t1)
		var t2 := Time.get_ticks_usec()
		MapStore.code_map(m)
		_add("地图码表重建(热)", Time.get_ticks_usec() - t2)

func _add(key: String, us: int) -> void:
	if not _samples.has(key):
		_samples[key] = []
	(_samples[key] as Array).append(us)

func _report() -> void:
	print("PERF_SAMPLE machine=%s cpus=%d os=%s" % [OS.get_processor_name(), OS.get_processor_count(), OS.get_version()])
	var keys: Array = _samples.keys()
	keys.sort()
	for k in keys:
		var arr: Array = _samples[k]
		arr.sort()
		var n := arr.size()
		var med := float(arr[n >> 1]) / 1000.0
		var p95 := float(arr[max(0, int(ceil(n * 0.95)) - 1)]) / 1000.0
		var mx := float(arr[n - 1]) / 1000.0
		print("PERF_SAMPLE %s n=%d median=%.2fms p95=%.2fms max=%.2fms"
			% [k, n, med, p95, mx])

func _clean(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_clean(dir.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
