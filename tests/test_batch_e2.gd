extends "res://tests/_suite_base.gd"
## 瓦片替换计划。

const TileReplace := preload("res://src/canvas/tile_replace.gd")

func _manifest() -> Dictionary:
	return {"assets": [
			{"id": "grass", "kind": "scene", "shape": "tile", "atlas": "a.png",
				"palette": [{"cell": [0, 0], "name": "草"}, {"cell": [1, 0], "name": "草2"}]},
			{"id": "stone", "kind": "scene", "shape": "tile", "atlas": "b.png",
				"palette": [{"cell": [0, 0], "name": "石"}]},
			{"id": "tree", "kind": "entity", "prefab": "res://t.tscn"},
		]}

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
