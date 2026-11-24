extends "res://tests/_suite_base.gd"

func test_extend_tile_graph_only_updates_generated_seam() -> void:
	var builder := preload("res://src/map/cell_graph_tiles.gd")
	var grid := GridSpace.new()
	var graph := {"spaces": {"floor": {"layer": "tiles"}}, "cells": []}
	var initial := builder.plan(graph, grid, "tiles", "floor", [Vector2i(1, 1), Vector2i(1, 2)])
	graph.cells = initial.rows
	graph.cells[0].neighbors.clear()
	graph.cells[0].polygon[0] = [15, 15]
	var before := graph.duplicate(true)
	var next := builder.plan(graph, grid, "tiles", "floor", [Vector2i(2, 1)], true,
		func(cell): return cell == Vector2i(1, 1))
	eq(next.rows[0].neighbors, ["floor:1,1"], "new cell can join an occupied generated neighbor")
	eq(next.joins, {0: ["floor:2,1"]}, "only propose the new seam, without restoring the removed old edge")
	eq(graph, before, "planning does not modify existing polygon or graph")
	var removed := builder.plan(graph, grid, "tiles", "floor", [Vector2i(2, 1)], true, func(_cell): return false)
	ok(removed.joins.is_empty(), "tile removed from the source does not become a seam")
	var changed := builder.plan(graph, GridSpace.new(Vector2i(32, 16)), "tiles", "floor",
		[Vector2i(2, 1)], true, func(_cell): return true)
	ok(changed.joins.is_empty(), "different source geometry does not become an implicit seam")
	graph.cells[0].erase(builder.GENERATED_KEY)
	var collision := builder.plan(graph, grid, "tiles", "floor", [Vector2i(1, 1)])
	ok(collision.has("error"), "a hand-authored same-ID cell blocks the batch")
## C4（§7.4）：有限格图——声明校验（重复 id/多边形/邻接）、多边形命中、写盘拦截。
## 首个样例：棋盘含一条回绕边（A4↔A1 显式邻接）与两处非矩形格（宽格 + L 形格）。

const CellGraph := preload("res://src/map/cell_graph.gd")
const MapValidator := preload("res://src/map/map_data_validation.gd")
const MapStore := preload("res://src/map/map_store.gd")

func _graph() -> Dictionary:
	return {"cells": [
		{"id": "A1", "polygon": [[0, 0], [40, 0], [40, 40], [0, 40]], "neighbors": ["A2", "A4"]},
		{"id": "A2", "polygon": [[40, 0], [90, 0], [90, 40], [40, 40]], "neighbors": ["A1", "A3"]},
		{"id": "A3", "polygon": [[90, 0], [120, 0], [120, 40], [130, 40], [130, 50], [90, 50]], "neighbors": ["A2", "A4"]},
		{"id": "A4", "polygon": [[0, 40], [40, 40], [40, 80], [0, 80]], "neighbors": ["A3", "A1"]},
	]}

func test_validate_and_pick() -> void:
	eq(CellGraph.validate_graph(_graph()).size(), 0, "valid wraparound board has no issues")
	var bad := {"cells": [
		{"id": "A1", "polygon": [[0, 0], [40, 0], [40, 40]], "neighbors": ["X"]},
		{"id": "A1", "polygon": [[0, 0], [10, 0], [10, 10]]}]}
	var errs := CellGraph.validate_graph(bad)
	ok(errs.size() >= 2, "dup id + missing neighbor reported: " + str(errs))
	# 非矩形命中：L 形格 A3 的凹点内部；回绕边 = 显式邻接查表
	var g := _graph()
	eq(CellGraph.pick_cell(g, Vector2(125, 45)), "A3", "L-shaped cell hit")
	eq(CellGraph.pick_cell(g, Vector2(20, 20)), "A1", "regular cell hit")
	eq(CellGraph.pick_cell(g, Vector2(35, 40)), "A1", "boundary point hits first declared cell")
	var nbs := CellGraph.neighbors(g, "A4")
	ok(nbs.has("A1"), "wraparound edge A4->A1 explicit")
func test_validator_hook_and_write_block() -> void:
	var m := {"_dir": "user://test_c4_tmp", "_maps_dir": "user://test_c4_tmp/maps"}
	var d := MapStore.new_map("m1", 40, 30)
	(d.get("meta", {}) as Dictionary)["cellGraph"] = {"cells": [{"id": "A1", "polygon": [[0, 0], [40, 0]]}]}
	var errs := MapValidator.validate(d, m)
	ok((errs as Array).any(func(x): return str((x as Dictionary).get("path", "")).contains("cellGraph")), "validator reports cellGraph issue")
	(d.get("meta", {}) as Dictionary)["cellGraph"] = _graph()
	var errs2 := MapValidator.validate(d, m)
	ok(not (errs2 as Array).any(func(x): return str((x as Dictionary).get("path", "")).contains("cellGraph")), "valid graph passes validator")
	ok(MapStore.write(m, "m1", d), "write ok with valid graph")

## C4 画布接入：多边形/重心查询是画布高亮与「确认后对准这一格」的数据源。
func test_polygon_and_centroid() -> void:
	var g := _graph()
	eq(CellGraph.polygon_of(g, "A1").size(), 4, "regular cell polygon")
	eq(CellGraph.polygon_of(g, "A3").size(), 6, "L-shaped cell polygon")
	eq(CellGraph.polygon_of(g, "NOPE").size(), 0, "unknown id has no polygon")
	# 矩形格重心 = 中心；L 形格重心必在自身多边形内（非外接框中心）
	var c1 := CellGraph.centroid_of(g, "A1")
	ok(c1.is_equal_approx(Vector2(20, 20)), "rect centroid at center: " + str(c1))
	var c3 := CellGraph.centroid_of(g, "A3")
	ok(Geometry2D.is_point_in_polygon(c3, CellGraph.polygon_of(g, "A3")), "L centroid inside polygon")
	eq(CellGraph.centroid_of(g, "NOPE"), Vector2.ZERO, "unknown id centroid is zero")

## 画布命中口径与纯函数一致：命中候选必须是 pick_cell 的返回值（同一真相）。
func test_pick_matches_centroid_hit() -> void:
	var g := _graph()
	for id in CellGraph.cell_ids(g):
		var c := CellGraph.centroid_of(g, str(id))
		eq(CellGraph.pick_cell(g, c), str(id), "centroid picks its own cell: " + str(id))

func test_explicit_edges_block_dangling_endpoints_but_preserve_schema_drift() -> void:
	var manifest := {"cellGraphEdgeTypes": {"route": {"fields": [
		{"id": "cost", "kind": "input", "type": "int", "min": 1, "default": 3}
	]}}}
	var level := MapStore.new_map("map", 8, 8)
	var graph := _graph()
	level.meta["cellGraph"] = graph
	graph["edges"] = [
		{"id": "one", "from": "A1", "to": "A2", "type": "route", "props": {"cost": 3}},
		{"id": "two", "from": "A1", "to": "A2", "type": "route", "props": {"cost": 0}},
	]
	var json := JSON.stringify(level)
	var result := MapStore.decode_text(json, "", manifest)
	ok(result.ok, "并行边合法；游戏声明调整不应锁住地图")
	ok(result.warnings.any(func(w): return w.path == "meta.cellGraph.edges[1].props.cost"),
		"值漂移定位到具体属性")
	if result.ok:
		eq(result.data.meta.cellGraph.edges[1].props.cost, 0, "原值保留便于修复")
	graph.edges[1].to = "missing"
	var reason := MapStore.write_error(manifest, level)
	ok(reason.begins_with("meta.cellGraph.edges[1].to:"), "结构上悬空的端点阻止保存")

func test_overlapping_spaces_use_same_coordinates_for_options_and_hits() -> void:
	var graph := _graph()
	graph["spaces"] = {"upper": {"name": "楼上", "origin": [-40, 0], "axisX": [1, 0], "axisY": [0, 1]}}
	graph.cells[1]["space"] = "upper"
	eq(CellGraph.validate_graph(graph).size(), 0, "重叠空间仍可使用相同地图像素")
	eq(CellGraph.pick_cell(graph, Vector2(20, 20)), "A1", "不指定空间时历史命中顺序不变")
	eq(CellGraph.pick_cell(graph, Vector2(20, 20), "upper"), "A2", "限定空间可以选中上层重叠格")
	eq(CellGraph.cell_options(graph, "upper"), [{"v": "A2", "t": "A2 · 楼上"}], "下拉使用同一身份和作用域")
	graph.spaces.upper.axisY = [2, 0]
	ok(CellGraph.validate_graph(graph).any(func(issue): return issue.path == "meta.cellGraph.spaces.upper"),
		"不能逆映射的空间不可保存")
