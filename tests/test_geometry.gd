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
	pn.free()
	ptn.free()
	rn.free()

func test_points_write_roundtrip() -> void:
	var pn: EntityNode = _node("poly_e")
	pn.points_write([Vector2(5.556, 1.234), Vector2(-3.0, 0.0)])
	eq((pn.props.get("points", []) as Array).size(), 2, "写入两条")
	eq(pn.props.get("points", [])[0][0], 5.56, "x 两位小数")
	eq(pn.props.get("points", [])[0][1], 1.23, "y 两位小数")
	eq(pn.points_local()[1], Vector2(-3.0, 0.0), "读回 Vector2")
	pn.props["points"] = [[0, 0], ["bad", 1], [8, 8], [1, 2, 3]]
	eq(pn.points_local().size(), 3, "畸形点过滤：非数值对剔除、三元素宽容取前两")
	pn.free()

func test_poly_view_attach() -> void:
	var pn: EntityNode = _node("poly_e")
	ok(pn.get_node_or_null("PolyView") != null, "poly 资产自动挂 PolyView")
	var rn: EntityNode = _node("rect_e")
	ok(rn.get_node_or_null("PolyView") == null, "rect 资产不挂")
	var ptn: EntityNode = _node("path_e")
	ok(ptn.get_node_or_null("PolyView") != null, "path 资产自动挂 PolyView")
	pn.free()
	rn.free()
	ptn.free()

## B2：实例几何（含旋转/缩放）——contains_point/aabb 与视觉一致（E10）
func test_entity_geometry_rotated() -> void:
	var rn: EntityNode = _node("rect_e")
	rn.apply_grid(2, 3)
	rn.refresh_visual()
	# 未旋转未缩放：包含判定走矩形
	ok(rn.contains_point(rn.position), "居中点命中")
	ok(not rn.contains_point(rn.position + Vector2(40, 0)), "远点不命中")
	eq(rn.aabb(), rn.rect(), "无变换时 aabb = rect")
	# 缩放 2 倍：视觉范围围绕锚点放大到 ±16px（16px 贴图）
	rn.data_transform["scale"] = [2.0, 2.0]
	rn.refresh_visual()
	ok(rn.contains_point(rn.position + Vector2(14, 0)), "缩放后 ±16 内仍命中")
	ok(not rn.contains_point(rn.position + Vector2(20, 0)), "缩放后超出 ±16 不命中")
	ok(rn.aabb().size.x >= 31.0, "缩放后 aabb 变大：%s" % str(rn.aabb().size))
	# 旋转 90°：四边形仍是 4 点、中心仍命中、aabb 覆盖旋转后包围盒
	rn.data_transform["scale"] = null
	rn.data_transform.erase("scale")
	rn.data_transform["rotation"] = PI * 0.5
	rn.refresh_visual()
	eq(rn.quad().size(), 4, "旋转后四边形四点")
	ok(rn.contains_point(rn.position), "旋转后中心命中")
	var ab := rn.aabb()
	ok(ab.has_point(rn.position) and ab.size.x >= rn.display_size().x - 0.01, "旋转后 aabb 覆盖视觉")
	# 拖回默认：变换缺省形态
	rn.data_transform.erase("rotation")
	rn.refresh_visual()
	ok(rn.transform_is_default(), "清空后回到缺省变换")
	rn.free()

## B2/E11：排序点偏移——position 含 sortAnchor，视觉矩形反向扣回（贴图不漂移）
func test_sort_anchor() -> void:
	var rn: EntityNode = _node("rect_e")
	rn.apply_grid(2, 3)
	rn.refresh_visual()
	var before := rn.rect()
	rn.set_sort_anchor(Vector2(0, -6))
	ok(rn.sort_anchor() == Vector2(0, -6), "sortAnchor 写入")
	eq(rn.rect(), before, "改排序点不改变视觉矩形")
	var g := rn.grid_of_world(rn.position)
	ok(absf(g.x - 2.0) < 0.001 and absf(g.y - 3.0) < 0.001, "数据格坐标不含排序点偏移：%s" % str(g))
	rn.set_sort_anchor(Vector2.ZERO)
	ok(not rn.raw.has("sortAnchor"), "归零删键（零冗余）")
	rn.free()

## B2/E06：编辑器可见性 setter 同步旗标（未进树时不碰节点）
func test_visible_flag_roundtrip() -> void:
	var rn: EntityNode = _node("rect_e")
	eq(rn.visible_flag, true, "缺省可见")
	rn.visible_flag = false
	eq(rn.visible_flag, false, "写入可见性")
	ok(rn.get_meta("visible") == false, "落盘读取口径（meta）同步")
	rn.free()
