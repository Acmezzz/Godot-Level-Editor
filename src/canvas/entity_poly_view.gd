extends Node2D
## EntityPolyView：poly/path 呈现子节点（R-02 几何段）。
## 子节点由 EntityNode 设置变换，直接绘制未变换的锚点局部坐标。
##
## 数据：props.points = [[x, y], ...] 像素坐标（相对实例锚点、未翻转变换的局部系）。
## 声明 visual.type = poly（closed 填充）/ path（width 折线）；颜色 alpha 走声明。
## 游戏侧读 objects[].props.points 原样透传；无翻转时局部坐标 = 相对锚点像素。

var node: EntityNode = null
const Geometry := preload("res://src/map/object_geometry.gd")
var _rings: Array[PackedVector2Array] = []
var _fill: Array[PackedVector2Array] = []

func _draw() -> void:
	if node == null or not is_instance_valid(node):
		return
	var vis: Dictionary = (node.decl as Dictionary).get("visual", {})
	if str(vis.get("type", "rect")) == "rect":
		return
	var pts := node.points_local()
	if pts.size() < 2:
		return
	var arr := PackedVector2Array(pts)
	var col := Color(str(vis.get("color", "#4fc3f7")))
	var alpha := float(vis.get("alpha", 0.35))
	var w := float(vis.get("width", 3.0))
	if str(vis.get("type", "rect")) == "path":
		draw_polyline(arr, Color(col, alpha), w, true)
	else:
		# poly 缺省闭合（E16）：未显式声明 closed 时按闭合呈现，
		# 否则「多边形」会画成一条折线、删点下限也随之错位。
		if bool(vis.get("closed", true)):
			_draw_parts(Color(col, alpha))
		else:
			draw_polyline(arr, Color(col, alpha), 3.0, true)

func _draw_parts(col: Color) -> void:
	var rings: Array[PackedVector2Array] = []
	var parts := node.geometry_parts()
	for part in parts:
		var contours := [part.points]
		contours.append_array(part.holes)
		for contour in contours:
			if contour.size() < 3:
				continue
			rings.append(PackedVector2Array(contour))
	if rings.size() == 1:
		if not Geometry2D.triangulate_polygon(rings[0]).is_empty():
			draw_colored_polygon(rings[0], col)
	else:
		if rings != _rings:
			_rings = rings
			_fill = Geometry.fill_strips(rings) if Geometry.parts_problem(parts).is_empty() else []
		for shape in _fill:
			draw_colored_polygon(shape, col)
	for ring in rings:
		draw_polyline(ring + PackedVector2Array([ring[0]]),
			Color(col.r, col.g, col.b, minf(1.0, col.a + 0.5)), 1.5, true)
