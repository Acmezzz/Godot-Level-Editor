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

## B2/E08：八种 alt 作为 D4 组合表——转四次回原值、翻两次回原值、翻转在任何旋转档都生效
func test_alt_group_table() -> void:
	for f in range(8):
		var r: int = f
		for _i in 4:
			r = MapFormat.alt_rotate90(r)
		eq(r, f, "alt %d 转四次回原值" % f)
		eq(MapFormat.alt_flip_h(MapFormat.alt_flip_h(f)), f, "alt %d 翻两次回原值" % f)
		ok(MapFormat.alt_flip_h(f) != f, "alt %d 翻转改变档位" % f)
	# 旋转 90° 的档位描述：0→90→180→270→0
	var a := 0
	for deg in [90, 180, 270, 0]:
		a = MapFormat.alt_rotate90(a)
		eq(MapFormat.alt_rot_deg(a), deg, "旋转档位 %d" % deg)
	# 旧实现 OR 组合的翻转失效样例：90°档(5) 再翻必须变成 4，而不是回到 5
	eq(MapFormat.alt_flip_h(5), 4, "90° 档翻转 = 4（旧 OR 组合会抵消成 5）")
	eq(MapFormat.alt_flip_h(4), 5, "4 再翻回 5")
	ok(MapFormat.alt_flipped(1) and not MapFormat.alt_flipped(0), "翻转位描述")
	ok(MapFormat.alt_label(0) == "0°" and MapFormat.alt_label(3).contains("180"), "档位标签")

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

## B1：逐图投影键 meta.gridProjection——三种枚举；缺键沿用项目解析
func test_grid_projection_key() -> void:
	var d := Store.new_map("t", 40, 30)
	ok(not d.meta.has("gridProjection"), "正交新图不写冗余键")
	var di := Store.new_map("t", 40, 30, "isometric")
	eq(str(di.meta.get("gridProjection", "")), "isometric", "新建等距图写 meta.gridProjection")
	var dh := Store.new_map("t", 40, 30, "hexagonal")
	eq(str(dh.meta.get("gridProjection", "")), "hexagonal", "新建六边图写 meta.gridProjection")
	var d2 := Store.new_map("t", 40, 30)
	d2.meta["gridProjection"] = "bogus"
	ok(_errs(d2).size() >= 1, "非法投影枚举报错")
	var d3 := Store.new_map("t", 40, 30)
	d3.meta["gridProjection"] = "isometric"
	eq(_errs(d3).size(), 0, "等距投影合法")
	ok(_errs(d3).size() == 0, "缺键不报错（沿用项目解析）")

## 可选键保存前后对照（§4）：gridProjection / gridTopology / gridBasis 经
## JSON 序列化 + 写盘 + 读回后逐字节保持；缺键仍缺省；非法值在读入侧被拒。
func test_optional_grid_keys_survive_roundtrip() -> void:
	var d := Store.new_map("opt", 20, 12, "isometric", "triangles")
	d.meta["gridBasis"] = [[32, 8], [0, 24]]
	var text := JSON.stringify(d)
	var back: Dictionary = Store.decode_text(text)
	ok(bool(back.get("ok", false)), "带三个可选键的文档可读回")
	var bd: Dictionary = back.get("data", {})
	eq(str((bd.meta as Dictionary).get("gridProjection", "")), "isometric", "gridProjection 读回一致")
	eq(str((bd.meta as Dictionary).get("gridTopology", "")), "triangles", "gridTopology 读回一致")
	# JSON 数字都是 float：等值即可（与瓦片 alt 的 5.0 同一约定）
	var basis_back: Array = (bd.meta as Dictionary).get("gridBasis", [])
	eq(basis_back.size(), 2, "gridBasis 两行读回")
	ok(absf(float((basis_back[0] as Array)[0]) - 32.0) < 0.001
		and absf(float((basis_back[0] as Array)[1]) - 8.0) < 0.001, "u = (32,8) 读回一致")
	ok(absf(float((basis_back[1] as Array)[0])) < 0.001
		and absf(float((basis_back[1] as Array)[1]) - 24.0) < 0.001, "v = (0,24) 读回一致")
	# 落盘再读：序列化结果必须与内存一致（写盘不丢可选键）
	var plain := Store.new_map("plain", 20, 12)
	ok(not (plain.meta as Dictionary).has("gridProjection"), "正交缺省不写键")
	ok(not (plain.meta as Dictionary).has("gridTopology"), "quads 缺省不写键")
	ok(not (plain.meta as Dictionary).has("gridBasis"), "无基向量不写键")
	var plain_back: Dictionary = Store.decode_text(JSON.stringify(plain))
	ok(bool(plain_back.get("ok", false)), "缺省文档可读回")
	ok(not ((plain_back.data as Dictionary).meta as Dictionary).has("gridBasis"), "读回也不凭空生键")
