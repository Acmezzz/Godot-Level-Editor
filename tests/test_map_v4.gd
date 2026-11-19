extends "res://tests/_suite_base.gd"
## 地图 JSON v4：new_map 模板 + map_data_validation 各道防线。

const Store := preload("res://src/map_store.gd")
const MV := preload("res://src/map_data_validation.gd")

func test_new_map_template() -> void:
	var d := Store.new_map("测试图", 60, 40)
	eq(int(d.get("version")), 4, "版本 4")
	var meta: Dictionary = d.get("meta", {})
	eq((meta.get("layers", []) as Array).size(), 2, "模板两层（资产层+FL）")
	eq(str(meta.get("name")), "测试图", "图名")
	eq((d.get("tiles", {}) as Dictionary).size(), 0, "空 tiles")
	eq((d.get("entities", []) as Array).size(), 0, "空实体")
	for lm in (meta.get("layers", []) as Array):
		eq(str((lm as Dictionary).get("id", "")).length(), 4, "层 id 4 位")
		eq(bool((lm as Dictionary).get("visible")), true, "层默认可见")

func _v4() -> Dictionary:
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

func _errs(d: Dictionary) -> Array:
	var out := []
	for e in MV.validate(d):
		if str(e.get("severity")) == "error":
			out.append(str(e.get("path")))
	return out

func test_tiles_key_and_tuple() -> void:
	var box := _v4()
	var d: Dictionary = box.d
	var lid: String = box.lid
	(d.tiles as Dictionary)[lid] = [[0, 0, 0, 0, 0]]
	eq(_errs(d).size(), 0, "合法瓦片零错误")
	(d.tiles as Dictionary)[lid] = [[0, 0, 0]]
	ok(_errs(d).size() >= 1, "3 元瓦片报错")
	(d.tiles as Dictionary)[lid] = [[0, 0, 0, 0, 0, 9]]
	ok(_errs(d).size() >= 1, "6 元瓦片报错")
	(d.tiles as Dictionary)["幽灵层"] = [[0, 0, 0, 0, 0]]
	ok(_errs(d).size() >= 1, "tiles 键不在层集报错")

func test_entities_and_spawn() -> void:
	var box := _v4()
	var d: Dictionary = box.d
	var lid: String = box.lid
	(d.entities as Array).append({"scene": "door", "code": "QK3T", "layer": lid, "x": 1, "y": 1})
	eq(_errs(d).size(), 0, "合法实体零错误")
	(d.entities as Array).append({"scene": "door", "code": "QK3T", "layer": lid, "x": 2, "y": 2})
	ok(_errs(d).size() >= 1, "实体码重复报错")
	var d2 := Store.new_map("t", 40, 30)
	var lid2: String = str((d2.meta.layers[0] as Dictionary).get("id"))
	(d2.entities as Array).append({"scene": "door", "code": "QQQQ", "layer": "幽灵层", "x": 0, "y": 0})
	ok(_errs(d2).size() >= 1, "实体 layer 不在层集报错")
	(d2.entities as Array).append({"scene": "door", "code": "QQQ1", "layer": lid2, "x": 0, "y": 0})
	d2["spawn"] = [1]
	ok(_errs(d2).size() >= 1, "spawn 非 2 元报错")

func test_decode_text_gate() -> void:
	var good := Store.new_map("t", 40, 30)
	var r1 := Store.decode_text(JSON.stringify(good), "t.json")
	eq(bool(r1.get("ok")), true, "合法 v4 图通过")
	ok((r1.get("data", {}) as Dictionary).size() > 0, "通过时返回数据")
	var r2 := Store.decode_text("not json", "t.json")
	eq(bool(r2.get("ok")), false, "非 JSON 拒收")
	var bad := Store.new_map("t", 40, 30)
	(bad.meta.layers as Array).clear()
	var r3 := Store.decode_text(JSON.stringify(bad), "t.json")
	eq(bool(r3.get("ok")), false, "坏图拒收")
	eq((r3.get("data", {}) as Dictionary).size(), 0, "拒收时数据为空")
	ok((r3.get("errors", []) as Array).size() >= 1, "给出错误列表")

