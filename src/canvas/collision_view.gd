class_name CollisionView
extends Node2D
## 碰撞图层的可视表达：把 grid 层的隐形碰撞格画成半透明色块。
##
## 为什么单独一个节点：碰撞层在数据上是 TileMapLayer，但它用的瓦片是「隐形格」，
## 直接显示 TileMapLayer 会画出图集里那格灰白分块（看起来像一层脏网格）。
## 所以碰撞层有一个专属的可视节点，和地形/装饰/实体层一样挂在图层节点上——
## 可见性、锁定、 SubViewport 显示都由统一的图层接口控制。
##
## 按类型分色分形——solid 红块、one_way 琥珀色、ladder 青色、hazard 品红；
## 斜坡画三角形（r45 右高 / l45 左高），一眼区分斜坡朝向。颜色刻意饱和。

var layer: TileMapLayer
var tile_px := 16
var canvas_ref   # 宿主编码画布：读 _collision_meta（批次 9 类型化碰撞）
var fill := Color(0.95, 0.22, 0.30, 0.28)
var outline := Color(1.0, 0.35, 0.42, 0.5)
## 类型 → [填充色, 描边色]；solid/无 meta 用默认红
const TYPE_COLORS := {
	"solid": [Color(0.95, 0.22, 0.30, 0.28), Color(1.0, 0.35, 0.42, 0.5)],
	"one_way": [Color(0.95, 0.72, 0.20, 0.30), Color(1.0, 0.82, 0.35, 0.55)],
	"ladder": [Color(0.30, 0.62, 0.95, 0.30), Color(0.42, 0.72, 1.0, 0.55)],
	"hazard": [Color(0.85, 0.30, 0.95, 0.30), Color(0.92, 0.45, 1.0, 0.55)],
}

func setup(p_layer: TileMapLayer, p_tile_px: int) -> Node2D:
	layer = p_layer
	tile_px = p_tile_px
	return self

## 数据变了就重画（碰撞格增删、撤销、区域粘贴都走这里）
func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	if layer == null:
		return
	for c in layer.get_used_cells():
		var cm = null
		if canvas_ref != null and is_instance_valid(canvas_ref):
			cm = canvas_ref._collision_meta.get(c, null)
		var ctype := "solid"
		var cshape := ""
		if cm is Dictionary:
			ctype = str(cm.get("type", "solid"))
			cshape = str(cm.get("shape", ""))
		var cols: Array = TYPE_COLORS.get(ctype, TYPE_COLORS["solid"])
		var r := Rect2(Vector2(c) * tile_px, Vector2(tile_px, tile_px))
 # 斜坡画三角形：r45 = 右高（实心在斜线下方），l45 = 左高
		if cshape == "r45":
			var pts := PackedVector2Array([r.position + Vector2(0, tile_px), r.position + Vector2(tile_px, 0), r.position + Vector2(tile_px, tile_px)])
			draw_colored_polygon(pts, cols[0])
			draw_polyline(pts + PackedVector2Array([pts[0]]), cols[1], 1.0)
			continue
		if cshape == "l45":
			var pts2 := PackedVector2Array([r.position + Vector2(0, 0), r.position + Vector2(tile_px, tile_px), r.position + Vector2(0, tile_px)])
			draw_colored_polygon(pts2, cols[0])
			draw_polyline(pts2 + PackedVector2Array([pts2[0]]), cols[1], 1.0)
			continue
		draw_rect(r, cols[0], true)
		draw_rect(r, cols[1], false, 1.0)
