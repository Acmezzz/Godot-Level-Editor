extends Node2D
## EntityPolyView：poly/path 呈现子节点（R-02 几何段）。
## 挂在 EntityNode（Sprite2D）下随实例一起动：继承 position/rotation/scale；
## flip 由本节点自查父节点 data_transform 后手动镜像（Sprite2D 的 flip 只翻贴图不翻子节点）。
##
## 数据：props.points = [[x, y], ...] 像素坐标（相对实例锚点、未翻转变换的局部系）。
## 声明 visual.type = poly（closed 填充）/ path（width 折线）；颜色 alpha 走声明。
## 游戏侧读 objects[].props.points 原样透传；无翻转时局部坐标 = 相对锚点像素。

var node: EntityNode = null   # 宿主 EntityNode（decl/props/flip 从这读）

func _draw() -> void:
	if node == null or not is_instance_valid(node):
		return
	var vis: Dictionary = (node.decl as Dictionary).get("visual", {})
	if str(vis.get("type", "rect")) == "rect":
		return
	var pts := node.points_local()
	if pts.size() < 2:
		return
	# Sprite2D 的 flip 只翻贴图；子节点手动镜像（局部系翻转 = 点位镜像）
	var mh := node.flipped_h()
	var mv := node.flipped_v()
	var arr := PackedVector2Array()
	for p: Vector2 in pts:
		arr.append(Vector2(-p.x if mh else p.x, -p.y if mv else p.y))
	var col := Color(str(vis.get("color", "#4fc3f7")))
	var alpha := float(vis.get("alpha", 0.35))
	var w := float(vis.get("width", 3.0))
	if str(vis.get("type", "rect")) == "path":
		draw_polyline(arr, Color(col, alpha), w, true)
	else:
		# poly 缺省闭合（E16）：未显式声明 closed 时按闭合呈现，
		# 否则「多边形」会画成一条折线、删点下限也随之错位。
		_draw_poly(arr, Color(col, alpha), bool(vis.get("closed", true)))

func _draw_poly(arr: PackedVector2Array, col: Color, closed: bool) -> void:
	if closed and arr.size() >= 3:
		draw_colored_polygon(arr, col)
		draw_polyline(arr + PackedVector2Array([arr[0]]),
			Color(col.r, col.g, col.b, minf(1.0, col.a + 0.5)), 1.5, true)
	elif not closed and arr.size() >= 2:
		draw_polyline(arr, col, 3.0, true)