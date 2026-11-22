class_name TriTileView
extends Node2D
## B3：三角格的瓦片可视层。TileMapLayer 只有方形/等距/六角三种 tile_shape，表现不了
## 半格三角形；因此三角拓扑下瓦片数据仍住在 TileMapLayer（六元组原样读写），
## 由本节点按三角形轮廓自绘（以图集切片为源，按三角形做 UV 裁切）。
##
## 显隐随所属层的 TileMapLayer 同步（图层接口只碰 TileMapLayer，本节点跟它走）；
## 改动数据后由画布 refresh() 触发重绘。

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")

var layer: TileMapLayer
var grid: GridSpace
var cvs   # 宿主画布（manifest / atlas_texs / asset_of_source / asset_cell）

## 每帧重建得太贵：数据变化时画布调 refresh() 抬代数，_draw 只在代数变时重算图元。
var _rev := -1
var _dirty := true

func setup(p_layer: TileMapLayer, p_grid: GridSpace, p_cvs) -> Node2D:
	layer = p_layer
	grid = p_grid
	cvs = p_cvs
	return self

func refresh() -> void:
	_dirty = true
	queue_redraw()

func _process(_dt: float) -> void:
	# 图层显隐由 layer_ops._apply_layer_shown 直接设置（数据节点常隐，这里不反向跟随）
	pass

func _draw() -> void:
	if layer == null or not is_instance_valid(layer) or grid == null or cvs == null:
		return
	if not grid.is_tri():
		return
	_dirty = false
	for c in layer.get_used_cells():
		var td: TileData = layer.get_cell_tile_data(c)
		if td == null:
			continue
		# 图集切片：source → 资产 id → 纹理与格尺寸；atlas 坐标从 TileSet 的 source 拿
		var src := layer.get_cell_source_id(c)
		if src < 0:
			continue
		var aid: String = str(cvs.asset_of_source(src))
		if aid == "":
			continue
		var texs: Array = cvs.atlas_texs
		if src >= texs.size() or texs[src] == null:
			continue
		var atl := layer.get_cell_atlas_coords(c)
		var cs: Vector2i = cvs.asset_cell(aid)
		if cs == Vector2i.ZERO:
			continue
		var poly: PackedVector2Array = grid.tri_polygon(c.x, c.y)
		if poly.size() < 3:
			continue
		draw_tri_texture(texs[src] as Texture2D, poly, atl, cs)

## 把一个图集切片贴到三角形内：UV 取切片在整张图集里的归一化矩形，
## 按三角形包围盒做仿射（切片左上对齐包围盒；等距/斜平面下三角形是旋转的，
## 包围盒映射会把贴图略微拉伸——与导出预览的 _blit_tile 同口径）。
func draw_tri_texture(tex: Texture2D, poly: PackedVector2Array, atl: Vector2i, cs: Vector2i) -> void:
	var tsz := tex.get_size()
	if tsz.x <= 0.0 or tsz.y <= 0.0:
		return
	var uvs := tri_uvs(poly, atl, cs, tsz)
	if uvs.size() != poly.size():
		return
	var cols := PackedColorArray()
	for i in poly.size():
		cols.append(Color.WHITE)
	draw_polygon(poly, cols, uvs, tex)

## 三角形三点 → 图集 UV（纯函数，绘制的几何口径；tests/test_tri_render.gd 直接验证）。
static func tri_uvs(poly: PackedVector2Array, atl: Vector2i, cs: Vector2i, tex_size: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if poly.is_empty() or tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return out
	var u0 := float(atl.x * cs.x) / tex_size.x
	var v0 := float(atl.y * cs.y) / tex_size.y
	var u1 := float((atl.x + 1) * cs.x) / tex_size.x
	var v1 := float((atl.y + 1) * cs.y) / tex_size.y
	var mn := poly[0]
	var mx := poly[0]
	for p: Vector2 in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	var sx := maxf(mx.x - mn.x, 0.0001)
	var sy := maxf(mx.y - mn.y, 0.0001)
	for p2: Vector2 in poly:
		var lx := (p2.x - mn.x) / sx
		var ly := (p2.y - mn.y) / sy
		out.append(Vector2(lerpf(u0, u1, lx), lerpf(v0, v1, ly)))
	return out
