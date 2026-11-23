class_name CollisionView
extends Node2D
## 碰撞图层的可视表达：把 grid 层的隐形碰撞格画成半透明色块。
##
## 为什么单独一个节点：碰撞层在数据上是 TileMapLayer，但它用的瓦片是「隐形格」，
## 直接显示 TileMapLayer 会画出图集里那格灰白分块（看起来像一层脏网格）。
## 所以碰撞层有一个专属的可视节点，和地形/装饰/实体层一样挂在图层节点上——
## 可见性/锁定由统一的图层接口控制；画布整体包在 SubViewport 里（editor_layout.gd）。
##
## 颜色/形状按清单 `collisionTypes` 声明（缺省池 = 内置四类）；斜坡画三角形
## （r45 右高 / l45 左高），一眼区分朝向。形状画法只认 rect/斜坡，其余声明形状暂按矩形画。

const CollisionTypes := preload("res://src/assets/collision_types.gd")

var layer: TileMapLayer
var grid_ref: GridSpace = null   # GridSpace 引用：cell 多边形随投影（等距 = 菱形）
var canvas_ref   # 宿主编码画布：读 _collision_meta 做类型化分色分形
var manifest := {}   # 清单（declared pool 的颜色来源）

## 声明 color → [填充, 描边]；未声明颜色的类型按 id 稳定取一个柔和色相。
static func _colors_of(d: Dictionary) -> Array:
	var base := Color("#f0605c")
	var cs := str(d.get("color", ""))
	if cs != "":
		base = Color(cs)
	else:
		var h := float(int(str(d.get("id", "x")).hash()) % 360) / 360.0
		base = Color.from_hsv(h * 0.28, 0.55, 0.9)   # 限制在暖红~黄区间的柔和色
	return [Color(base, 0.28), Color(base.lightened(0.2), 0.55)]

## 兼容转发（tile_px 参数退役：格尺寸随 grid_ref.tile，兜底 16×16）
func setup(p_layer: TileMapLayer, p_tile_px: int, p_grid: GridSpace = null) -> Node2D:
	layer = p_layer
	grid_ref = p_grid
	return self

## 数据变了就重画（碰撞格增删、撤销、区域粘贴都走这里）
func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	if layer == null:
		return
	# §5：按可见世界矩形裁剪（原先每次重画都遍历整层；120×56 满图拖动时每帧上千格）。
	# 可见矩形反算到本节点空间（本节点挂在层容器下，层 offset/scale 已计入变换）。
	var vis := Rect2()
	var has_vis := false
	var vp := get_viewport()
	if vp != null:
		var world: Rect2 = vp.get_canvas_transform().affine_inverse() * Rect2(Vector2.ZERO, vp.get_visible_rect().size)
		vis = get_global_transform().affine_inverse() * world
		has_vis = true
	for c in layer.get_used_cells():
		if has_vis:
			var bb := _bbox_of(_cell_poly(c))
			if not vis.intersects(bb):
				continue
		var cm = null
		if canvas_ref != null and is_instance_valid(canvas_ref):
			cm = canvas_ref._collision_meta.get(c, null)
		var ctype := "solid"
		var cshape := ""
		if cm is Dictionary:
			ctype = str(cm.get("type", "solid"))
			cshape = str(cm.get("shape", ""))
		var d: Dictionary = CollisionTypes.decl_of(manifest, ctype)
		if d.is_empty():
			d = {"id": ctype, "name": ctype, "shape": cshape}
		var cols: Array = _colors_of(d)
		var poly := _cell_poly(c)
		var r := _bbox_of(poly)
		# 斜坡按包围盒近似：r45 = 右高（实心在斜线下方），l45 = 左高
		if cshape == "r45":
			var pts := PackedVector2Array([r.position + Vector2(0, r.size.y), r.position + Vector2(r.size.x, 0), r.position + Vector2(r.size.x, r.size.y)])
			draw_colored_polygon(pts, cols[0])
			draw_polyline(pts + PackedVector2Array([pts[0]]), cols[1], 1.0)
			continue
		if cshape == "l45":
			var pts2 := PackedVector2Array([r.position + Vector2(0, 0), r.position + Vector2(r.size.x, r.size.y), r.position + Vector2(0, r.size.y)])
			draw_colored_polygon(pts2, cols[0])
			draw_polyline(pts2 + PackedVector2Array([pts2[0]]), cols[1], 1.0)
			continue
		draw_colored_polygon(poly, cols[0])
		draw_polyline(poly + PackedVector2Array([poly[0]]), cols[1], 1.0)

## cell 覆盖多边形：有 grid_ref = 格多边形（等距 = 菱形/六边 = 六角）；无 = 正交方形（兜底）
func _cell_poly(c: Vector2i) -> PackedVector2Array:
	if grid_ref != null:
		return grid_ref.cell_polygon(c)
	var cs := Vector2(16, 16)
	var o := Vector2(c) * cs
	return PackedVector2Array([o, o + Vector2(cs.x, 0), o + cs, o + Vector2(0, cs.y)])

## 多边形包围盒（斜坡三角形底座）
func _bbox_of(poly: PackedVector2Array) -> Rect2:
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)
