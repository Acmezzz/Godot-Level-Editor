extends "res://tests/_suite_base.gd"
## 地图 JSON 契约：new_map 模板 + map_data_validation 各道防线 + 变换位互转。

const Store := preload("res://src/map/map_store.gd")
const MV := preload("res://src/map/map_data_validation.gd")
const MapFormat := preload("res://src/map/map_format.gd")

## 最小清单：一张图集场景、一张图片场景、一个实体种类——够覆盖 assets 归属检查
const MANIFEST := {"assets": [
	{"id": "terrain", "kind": "scene", "shape": "tile", "atlas": "t.png", "cell": 16, "palette": []},
	{"id": "bg", "kind": "scene", "shape": "image", "texture": "bg.png", "editorSize": [32, 32]},
	{"id": "door", "kind": "entity", "prefab": "door.tscn"},
]}

func test_new_map_template() -> void:
	var d := Store.new_map("测试图", 60, 40)
	eq(int(d.get("version")), Store.FORMAT_VERSION, "版本 = 当前格式")
	var meta: Dictionary = d.get("meta", {})
	eq((meta.get("layers", []) as Array).size(), 2, "模板两层（资产层+FL）")
	eq(str(meta.get("name")), "测试图", "图名")
	eq((d.get("tiles", {}) as Dictionary).size(), 0, "空 tiles")
	eq((d.get("objects", []) as Array).size(), 0, "空 objects")
	ok(not d.has("entities"), "模板不再产出 entities 段")
	for lm in (meta.get("layers", []) as Array):
		eq(str((lm as Dictionary).get("id", "")).length(), 4, "层 id 4 位")
		eq(bool((lm as Dictionary).get("visible")), true, "层默认可见")

func test_alt_roundtrip() -> void:
	for f in range(8):
		eq(MapFormat.alt_of_godot(MapFormat.alt_to_godot(f)), f, "alt %d 往返幂等" % f)
	eq(MapFormat.alt_to_godot(MapFormat.TILE_ROT90), 16384, "转置 = Godot bit14 (16384)")
	eq(MapFormat.alt_to_godot(MapFormat.TILE_FLIP_H | MapFormat.TILE_FLIP_V | MapFormat.TILE_ROT90), 28672, "H+V+转置全置位")

func _box() -> Dictionary:
	var d := Store.new_map("t", 40, 30)
	var lid: String = str((d.meta.layers[0] as Dictionary).get("id"))
	return {"d": d, "lid": lid}

func test_layers_validation() -> void:
	var d := Store.new_map("t", 40, 30)
	(d.meta.layers as Array).clear()
	ok(_errs(d).size() >= 1, "层栈空报错")
	var d2 := Store.new_map("t", 40, 30)
	(d2.meta.layers as Array).append({"id": str((d2.meta.layers[0] as Dictionary).get("id")), "name": "重", "visible": true})
	ok(_errs(d2).size() >= 1, "层 id 重复报错")
	var d3 := Store.new_map("t", 40, 30)
	(d3.meta.layers[0] as Dictionary)["visible"] = "yes"
	ok(_errs(d3).size() >= 1, "visible 非布尔报错")

func _errs(d: Dictionary, manifest := MANIFEST) -> Array:
	var out := []
	for e in MV.validate(d, manifest):
		if str(e.get("severity")) == "error":
			out.append(str(e.get("path")))
	return out

func test_tiles_key_and_tuple() -> void:
	var box := _box()
	var d: Dictionary = box.d
	var lid: String = box.lid
	(d.tiles as Dictionary)[lid] = [[0, 0, "terrain", 0, 0, 0]]
	eq(_errs(d).size(), 0, "合法瓦片零错误")
	(d.tiles as Dictionary)[lid] = [[0, 0, 0]]
	ok(_errs(d).size() >= 1, "3 元瓦片报错")
	(d.tiles as Dictionary)[lid] = [[0, 0, "terrain", 0, 0, 9]]
	ok(_errs(d).size() >= 1, "alt 越界报错")
	(d.tiles as Dictionary)[lid] = [[0, 0, "terrain", 0, 0]]
	ok(_errs(d).size() >= 1, "5 元瓦片退役报错")
	(d.tiles as Dictionary)["幽灵层"] = [[0, 0, "terrain", 0, 0, 0]]
	ok(_errs(d).size() >= 1, "tiles 键不在层集报错")

func test_objects() -> void:
	var box := _box()
	var d: Dictionary = box.d
	var lid: String = box.lid
	# 实体：code 合法
	(d.objects as Array).append({"asset": "door", "code": "QK3T", "layer": lid, "x": 1.5, "y": 2})
	eq(_errs(d).size(), 0, "合法实体零错误")
	# 场景图片实例：不带 code 合法
	(d.objects as Array).append({"asset": "bg", "layer": lid, "x": 0, "y": 0})
	eq(_errs(d).size(), 0, "场景图片实例零错误")
	# 重复码
	(d.objects as Array).append({"asset": "door", "code": "QK3T", "layer": lid, "x": 2, "y": 2})
	ok(_errs(d).size() >= 1, "实例码重复报错")
	# 场景实例发码 = 数据模型用错
	var d2 := Store.new_map("t", 40, 30)
	(d2.objects as Array).append({"asset": "bg", "code": "ZZZZ", "layer": box.lid, "x": 0, "y": 0})
	ok(_errs(d2).size() >= 1, "场景实例带 code 报错")
	# 图集场景不能当摆放物
	var d3 := Store.new_map("t", 40, 30)
	(d3.objects as Array).append({"asset": "terrain", "layer": box.lid, "x": 0, "y": 0})
	ok(_errs(d3).size() >= 1, "图集场景当摆放物报错")
	# 未知层
	var d4 := Store.new_map("t", 40, 30)
	(d4.objects as Array).append({"asset": "door", "code": "QQQQ", "layer": "幽灵层", "x": 0, "y": 0})
	ok(_errs(d4).size() >= 1, "摆放物 layer 不在层集报错")
	# transform / visible / zPolicy 类型
	var d5 := Store.new_map("t", 40, 30)
	(d5.objects as Array).append({"asset": "bg", "layer": box.lid, "x": 0, "y": 0,
		"transform": "big", "visible": "no", "zPolicy": "middle"})
	ok(_errs(d5).size() >= 3, "transform/visible/zPolicy 三项各报错")
	# 退役的 entities 段
	var d6 := Store.new_map("t", 40, 30)
	d6["entities"] = []
	ok(_errs(d6).size() >= 1, "entities 段报退役")

func test_spawn() -> void:
	var d := Store.new_map("t", 40, 30)
	d["spawn"] = [1]
	ok(_errs(d).size() >= 1, "spawn 非 2 元报错")

func test_collision_objects() -> void:
	var d := Store.new_map("t", 40, 30)
	(d.collision as Array).append({"x": 3, "y": 4})
	eq(_errs(d).size(), 0, "缺省碰撞条目零错误")
	(d.collision as Array).append({"x": 1, "y": 2, "type": "one_way", "shape": "r45"})
	eq(_errs(d).size(), 0, "带类型形状零错误")
	(d.collision as Array).append([5, 6])
	ok(_errs(d).size() >= 1, "v5 数组条目报退役（跑迁移）")
	(d.collision as Array).append({"y": 7})
	ok(_errs(d).size() >= 1, "缺 x 报错")
	(d.collision as Array).append({"x": 1, "y": 2, "type": 3})
	ok(_errs(d).size() >= 1, "type 非字符串报错")

func test_layer_params() -> void:
	var d := Store.new_map("t", 40, 30)
	var lm: Dictionary = d.meta.layers[0]
	lm["parallax"] = 0.5
	lm["ySort"] = true
	lm["offset"] = [0, -8]
	lm["scale"] = 1.0
	eq(_errs(d).size(), 0, "层参数全合法")
	var d2 := Store.new_map("t", 40, 30)
	var lm2: Dictionary = d2.meta.layers[0]
	lm2["parallax"] = "half"
	lm2["ySort"] = 1
	lm2["offset"] = [0]
	lm2["scale"] = "2"
	ok(_errs(d2).size() >= 4, "层参数类型错各报一条：%s" % str(_errs(d2)))

func test_decode_text_gate() -> void:
	var good := Store.new_map("t", 40, 30)
	var r1 := Store.decode_text(JSON.stringify(good), "t.json")
	eq(bool(r1.get("ok")), true, "合法图通过")
	ok((r1.get("data", {}) as Dictionary).size() > 0, "通过时返回数据")
	var r2 := Store.decode_text("not json", "t.json")
	eq(bool(r2.get("ok")), false, "非 JSON 拒收")
	var bad := Store.new_map("t", 40, 30)
	(bad.meta.layers as Array).clear()
	var r3 := Store.decode_text(JSON.stringify(bad), "t.json")
	eq(bool(r3.get("ok")), false, "坏图拒收")
	eq((r3.get("data", {}) as Dictionary).size(), 0, "拒收时数据为空")
	ok((r3.get("errors", []) as Array).size() >= 1, "给出错误列表")
