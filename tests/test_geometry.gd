extends "res://tests/_suite_base.gd"
## R-02 几何段用例：EntityNode 的 visual_type / points_local / points_write 与
## PolyView 子节点装配（不进树，纯数据口径）。

const EntityNodeScript := preload("res://src/canvas/entity_node.gd")

const TMP_M := {
	"assets": [
		{"id": "rect_e", "kind": "entity", "name": "矩形实体", "visual": {"type": "rect", "color": "#4fc3f7"}},
		{"id": "poly_e", "kind": "entity", "name": "多边形", "visual": {"type": "poly", "color": "#81c784", "closed": true,
			"points": [[0, 0], [32, 0], [0, 32]]}},
		{"id": "path_e", "kind": "entity", "name": "折线", "visual": {"type": "path", "color": "#ffb74d", "width": 3}},
	]
}

func _node(aid: String) -> EntityNode:
	return EntityNodeScript.create(TMP_M, aid, Vector2(16, 16), 16, {}, null)

func test_visual_type_and_points() -> void:
	var pn: EntityNode = _node("poly_e")
	eq(pn.visual_type(), "poly", "visual.type 解析 poly")
	eq(pn.points_local().size(), 3, "缺省点集退回声明 visual.points")
	var ptn: EntityNode = _node("path_e")
	eq(ptn.visual_type(), "path", "visual.type 解析 path")
	eq(ptn.points_local().size(), 0, "声明无 points → 空集（落笔时给缺省形状）")
	var rn: EntityNode = _node("rect_e")
	eq(rn.visual_type(), "rect", "缺省 rect")
	eq(rn.points_local().size(), 0, "rect 资产无点集")

func test_points_write_roundtrip() -> void:
	var pn: EntityNode = _node("poly_e")
	pn.points_write([Vector2(5.556, 1.234), Vector2(-3.0, 0.0)])
	eq((pn.props.get("points", []) as Array).size(), 2, "写入两条")
	eq(pn.props.get("points", [])[0][0], 5.56, "x 两位小数")
	eq(pn.props.get("points", [])[0][1], 1.23, "y 两位小数")
	eq(pn.points_local()[1], Vector2(-3.0, 0.0), "读回 Vector2")
	pn.props["points"] = [[0, 0], ["bad", 1], [8, 8], [1, 2, 3]]
	eq(pn.points_local().size(), 3, "畸形点过滤：非数值对剔除、三元素宽容取前两")

func test_poly_view_attach() -> void:
	var pn: EntityNode = _node("poly_e")
	ok(pn.get_node_or_null("PolyView") != null, "poly 资产自动挂 PolyView")
	var rn: EntityNode = _node("rect_e")
	ok(rn.get_node_or_null("PolyView") == null, "rect 资产不挂")
	var ptn: EntityNode = _node("path_e")
	ok(ptn.get_node_or_null("PolyView") != null, "path 资产自动挂 PolyView")
