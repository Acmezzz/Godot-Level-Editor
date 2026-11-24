extends "res://tests/_suite_base.gd"
## §7.4 格边引用：规范代表边（无向去重）、解析、字段值自洽、拓扑判定、
## 引用字段描述、清单合法、复制重映射、审计悬空。

const EdgeRef := preload("res://src/map/edge_ref.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")
const GridSpace := preload("res://src/canvas/grid_space.gd")

## 无向边：两端点顺序无关，同一格对只得到一条 ID
func test_canonical_edge_is_undirected() -> void:
	var a := Vector2i(3, 2)
	var b := Vector2i(4, 2)
	eq(EdgeRef.canonical_edge(a, b), EdgeRef.canonical_edge(b, a), "正反方向同一 ID")
	eq(EdgeRef.canonical_edge(a, b), "3,2|4,2", "按 (y,x) 排序：较小端点在前")
	# y 不同的边：先比 y
	eq(EdgeRef.canonical_edge(Vector2i(9, 5), Vector2i(0, 1)), "0,1|9,5", "先比 y 再比 x")
	eq(EdgeRef.canonical_edge(Vector2i(-1, 0), Vector2i(0, 0)), "-1,0|0,0", "负坐标照样排序")

## 解析：合法串往返一致，坏串返回空数组（不抛错）
func test_parse_edge() -> void:
	var e := EdgeRef.canonical_edge(Vector2i(1, 0), Vector2i(-2, 4))
	var ends := EdgeRef.parse_edge(e)
	eq(ends.size(), 2, "两段")
	eq(ends[0], [1, 0], "第一端点")
	eq(ends[1], [-2, 4], "第二端点")
	eq(EdgeRef.parse_edge("1,0"), [], "缺分隔符 = 非法")
	eq(EdgeRef.parse_edge("1,0|2"), [], "端点缺 y = 非法")
	eq(EdgeRef.parse_edge("a,b|1,2"), [], "非整数 = 非法")
	eq(EdgeRef.parse_edge("1,2|3,4|5,6"), [], "三段 = 非法")

## 字段值：cell 恒等于规范边首端点（与 edge 自洽，不存两套口径）
func test_value_of_self_consistent() -> void:
	var v := EdgeRef.value_of("MAP1", Vector2i(5, 3), Vector2i(4, 3))
	eq(str(v.map), "MAP1", "地图码透传")
	eq(str(v.edge), EdgeRef.canonical_edge(Vector2i(4, 3), Vector2i(5, 3)), "代表边")
	eq(v.cell, [4, 3], "cell = 规范首端点")
	var v2 := EdgeRef.value_of("", Vector2i(2, 2), Vector2i(2, 3))
	eq(v2.cell, [2, 2], "y 小的在前")
	eq(EdgeRef.edge_of(v2), str(v2.edge), "edge_of 读回")
	eq(EdgeRef.edge_of("x"), "", "非字典 = 空")
	eq(EdgeRef.edge_of({}), "", "无 edge 键 = 空")

## 拓扑判定：四邻/三角格各自的共边才算真边
func test_is_real_edge_by_topology() -> void:
	var quads := GridSpace.new(Vector2i(16, 16), "orthogonal")
	var c := Vector2i(2, 2)
	var nbs := quads.neighbors_any(c)
	ok(EdgeRef.is_real_edge(EdgeRef.canonical_edge(c, Vector2i(3, 2)), c, nbs), "四邻右 = 真边")
	ok(EdgeRef.is_real_edge(EdgeRef.canonical_edge(Vector2i(3, 2), c), c, nbs), "反方向写法也认")
	ok(not EdgeRef.is_real_edge(EdgeRef.canonical_edge(c, Vector2i(3, 3)), c, nbs), "对角 = 不是共边")
	ok(not EdgeRef.is_real_edge(canonical_bad(), c, nbs), "坏 ID = false")
	var tris := GridSpace.new(Vector2i(16, 16), "orthogonal")
	tris.set_topology("triangles")
	var t := Vector2i(4, 2)
	var tnbs := tris.neighbors_any(t)
	ok(tnbs.size() == 3, "三角格 3 个共边邻格")
	ok(EdgeRef.is_real_edge(EdgeRef.canonical_edge(t, tnbs[0]), t, tnbs), "三角格共边成立")

func canonical_bad() -> String:
	return "0,0"

func test_region_mapper_requires_both_centers_and_a_real_destination_edge() -> void:
	var grid := GridSpace.new(Vector2i(16, 16), "orthogonal")
	var stretched := GridSpace.new(Vector2i(32, 32), "orthogonal")
	var size := Vector2i(8, 8)
	var frame := Transform2D.IDENTITY
	var area := Rect2(4, 4, 24, 10)
	var mapper := EdgeRef.region_mapper(grid, size, frame, area, grid, size, frame, Vector2(36, 20))
	eq(mapper.call(EdgeRef.value_of("SRC1", Vector2i.ZERO, Vector2i.RIGHT), "DST1"),
		EdgeRef.value_of("DST1", Vector2i(2, 1), Vector2i(3, 1)), "translates both endpoints and rebuilds the canonical edge")
	eq(mapper.call(EdgeRef.value_of("SRC1", Vector2i.RIGHT, Vector2i(2, 0)), "DST1"), {},
		"a boundary edge has only one endpoint inside the selection")
	mapper = EdgeRef.region_mapper(grid, size, frame, area, stretched, size, frame, Vector2(4, 4))
	eq(mapper.call(EdgeRef.value_of("SRC1", Vector2i.ZERO, Vector2i.RIGHT), "DST1"), {},
		"both endpoints landing on one destination cell cannot form an edge")

## 引用字段描述与清单校验：edge_ref 是合法 input 类型
func test_decl_and_validation() -> void:
	var d := RefFields.describe({"type": "edge_ref"})
	eq(str(d.kind), "edge", "kind=edge")
	eq(str(d.scope), "same_map", "无 mapField = 本图")
	ok(bool(d.is_ref), "标记为引用")
	var d2 := RefFields.describe({"type": "edge_ref", "mapField": "target_map"})
	eq(str(d2.scope), "map_ref", "有 mapField = 目标图域")
	var m := {"functions": [{"id": "f", "name": "F", "code": "FN01", "fields": [
		{"id": "E", "kind": "input", "type": "edge_ref", "code": "F001"}]}]}
	var errs := []
	for it in ManifestValidation.validate(m):
		if str(it.get("severity", "")) == "error":
			errs.append(str(it.get("message", "")))
	eq(errs.size(), 0, "清单接受 edge_ref：%s" % str(errs))

## 复制：边身份不变，只把「本图」分量钉成源图码（跨图），同图复制原样
func test_clone_keeps_edge_pins_source_map() -> void:
	var m := {"assets": [{"id": "gate", "kind": "entity", "visual": {"type": "rect"},
		"fields": [{"id": "E", "type": "edge_ref"}]}]}
	var row := {"code": "AAAA", "asset": "gate", "x": 0, "y": 0,
		"props": {"E": EdgeRef.value_of("", Vector2i(1, 1), Vector2i(2, 1))}}
	var same: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": "MAP1"}, "objects": [row]}, "manifest": m, "map": "m"},
		{"data": {"meta": {"code": "MAP1"}, "objects": []}, "manifest": m, "map": "m"})
	eq(str((same.map_patch.objects as Array)[0].props.E.map), "", "同图复制不改地图分量")
	var cross: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": "MAP1"}, "objects": [row]}, "manifest": m, "map": "m"},
		{"data": {"meta": {"code": "MAP2"}, "objects": []}, "manifest": m, "map": "m2"})
	var got: Dictionary = (cross.map_patch.objects as Array)[0].props.E
	eq(str(got.map), "MAP1", "跨图复制钉源图码")
	eq(str(got.edge), str(row.props.E.edge), "边身份不动")

## §4.2-3：整图复制（副本 = 源图的新身份）时，map:"" 随副本解释，不钉回源图；
## 显式指向第三图的引用原样保留。
func test_whole_map_copy_keeps_edge_local() -> void:
	var m := {"assets": [{"id": "gate", "kind": "entity", "visual": {"type": "rect"},
		"fields": [{"id": "E", "type": "edge_ref"}]}]}
	var local_row := {"code": "AAAA", "asset": "gate", "x": 0, "y": 0,
		"props": {"E": EdgeRef.value_of("", Vector2i(1, 1), Vector2i(2, 1))}}
	var third_row := {"code": "BBBB", "asset": "gate", "x": 1, "y": 0,
		"props": {"E": EdgeRef.value_of("MAP9", Vector2i(0, 0), Vector2i(1, 0))}}
	var plan: Dictionary = ClonePlan.whole_map_document(
		{"data": {"meta": {"name": "m1", "code": "MAP1"}, "objects": [local_row, third_row]},
			"manifest": m, "map": "m1"}, "m2", "MAP2")
	eq(str(plan.status), "ok", "整图计划成功：%s" % ClonePlan.conflicts_text(plan.conflicts))
	var rows: Array = plan.document.objects
	var e_local: Dictionary = (rows[0] as Dictionary).props.E
	eq(str(e_local.get("map")), "", "整图复制保留「本图」分量（随副本解释）")
	var e_third: Dictionary = (rows[1] as Dictionary).props.E
	eq(str(e_third.get("map")), "MAP9", "显式第三图原样保留")

func test_nested_paired_port_and_edge_keep_their_resolved_map() -> void:
	var m := {"assets": [{"id": "gate", "kind": "entity", "fields": [
		{"id": "links", "type": "array", "of": "record", "fields": [
			{"id": "target_map", "type": "map_ref"},
			{"id": "instance", "type": "entity_ref", "mapField": "target_map"},
			{"id": "port", "type": "port_ref", "mapField": "target_map"},
			{"id": "edge", "type": "edge_ref", "mapField": "target_map"}]}]}]}
	var row := {"asset": "gate", "code": "SELF", "props": {"links": [
		{"target_map": "MAP9", "instance": "SELF", "port": {"map": "", "inst": "SELF", "port": "in"},
			"edge": EdgeRef.value_of("", Vector2i(1, 1), Vector2i(2, 1))},
		{"target_map": "", "instance": "SELF", "port": {"map": "", "inst": "SELF", "port": "in"},
			"edge": EdgeRef.value_of("", Vector2i(1, 1), Vector2i(2, 1))}]}}
	var copy := ClonePlan.remap_row(row, {"SELF": "NEW1"}, {}, m, "MAP1", {"SELF": true},
		[], "MAP2", "MAP1")
	var foreign: Dictionary = copy.props.links[0]
	var local: Dictionary = copy.props.links[1]
	eq([foreign.port.map, foreign.port.inst, foreign.edge.map], ["MAP9", "SELF", "MAP9"],
		"跨图配对优先：即使实例同码也不重映射")
	eq([local.target_map, local.port.map, local.port.inst, local.edge.map], ["MAP2", "MAP2", "NEW1", "MAP1"],
		"端口随复制对象走，格边留在源图，避免与配对地图冲突")

## 候选：只列「两侧都有瓦片」的相邻格对，按规范边去重（两条相反方向的边只出一项）
func test_edge_candidates_of_occupied_cells() -> void:
	# 3 个格连成一条横线：两条边；再放对角格（不相邻）不产生边
	var data := {
		"meta": {"code": "MAP1", "gridProjection": "orthogonal"},
		"tiles": {"L1": [[0, 0, "t0", 0, 0, 0], [1, 0, "t0", 0, 0, 0], [2, 0, "t0", 0, 0, 0],
			[2, 2, "t0", 0, 0, 0]]},
	}
	var m := {"tileSize": 16}
	var out := RefFields.edge_candidates_of(data, m)
	eq(out.size(), 2, "横排三格 = 两条边：%s" % str(out))
	var vs: Array = []
	for it in out:
		var v = JSON.parse_string(str((it as Dictionary).get("v", "")))
		vs.append(str((v as Dictionary).get("edge", "")))
	eq(vs, ["0,0|1,0", "1,0|2,0"], "边按字典序，端点规范排序")
	# 三角拓扑：邻接口径换成三角邻接
	var tri := data.duplicate(true)
	tri.meta["gridTopology"] = "triangles"
	var out2 := RefFields.edge_candidates_of(tri, m)
	ok(out2.size() > 0, "三角拓扑也能出边")
	for it2 in out2:
		var v2 = JSON.parse_string(str((it2 as Dictionary).get("v", "")))
		ok(str((v2 as Dictionary).get("edge", "")) != "", "三角边 ID 非空")
	eq(RefFields.edge_candidates_of({}, m), [], "空文档返回空")

## 边几何：相邻两格的多边形恰有 2 个公共顶点（画布高亮/命中共用的「真实分界线」判据）。
## 六边/三角同一条口径：公共顶点数 = 2 才是共边。
func test_shared_vertices_define_edge() -> void:
	for proj in ["orthogonal", "isometric", "hexagonal"]:
		var g := GridSpace.new(Vector2i(16, 16), proj)
		var c := Vector2i(3, 3)
		var nb: Vector2i = g.neighbors_any(c)[0]
		var shared := 0
		for p in g.cell_polygon(c):
			for q in g.cell_polygon(nb):
				if p.distance_squared_to(q) < 0.01:
					shared += 1
					break
		eq(shared, 2, "%s：共边格恰有 2 个公共顶点" % proj)
		# 双向不变式：公共顶点恰 2 个 ⟺ 拓扑上是邻格（对角/隔格都不会误判成一条边）
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				if dx == 0 and dy == 0:
					continue
				var other := c + Vector2i(dx, dy)
				var s2 := 0
				for p2 in g.cell_polygon(c):
					for q2 in g.cell_polygon(other):
						if p2.distance_squared_to(q2) < 0.01:
							s2 += 1
							break
				var adj: bool = g.neighbors_any(c).has(other)
				ok((s2 == 2) == adj, "%s：(%d,%d) 公共顶点数 %d 与邻接 %s 不符" % [
					proj, dx, dy, s2, str(adj)])
	var tri := GridSpace.new(Vector2i(16, 16), "orthogonal")
	tri.set_topology("triangles")
	var tc := Vector2i(2, 1)
	var tnb: Vector2i = tri.neighbors_any(tc)[0]
	var s3 := 0
	for p3 in tri.cell_polygon(tc):
		for q3 in tri.cell_polygon(tnb):
			if p3.distance_squared_to(q3) < 0.01:
				s3 += 1
				break
	eq(s3, 2, "三角格共边也是 2 个公共顶点")
