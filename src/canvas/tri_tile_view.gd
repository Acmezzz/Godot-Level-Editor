class_name TriTileView
extends Node2D
## B3：瓦片自绘层。TileMapLayer 只有方形/等距/六角三种 tile_shape，表现不了
## 半格三角形，也表达不了任意斜基（gridBasis）的平行四边形。这两种拓扑下瓦片数据仍住在
## TileMapLayer（六元组原样读写），由本节点按真实格多边形自绘（以图集切片为源，按格形做 UV 裁切）。
##
## 显隐与层参数由层控制器同步到本节点（图层接口只碰 TileMapLayer，本节点跟它走）；
## refresh() 只是请求重绘（queue_redraw），真正的遍历在 _draw() 里——每次重绘都扫该层全部瓦片，
## 不做逐格缓存。所以大图重绘是 O(瓦片数)，别在每帧调用 refresh()。

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")
const MapFormat := preload("res://src/map/map_format.gd")

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
	# 三角拓扑与斜基拓扑都走自绘（斜基的平行四边形没有原生 tile_shape）
	if not grid.is_tri() and not grid.has_basis:
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
		var poly: PackedVector2Array = grid.cell_polygon(c)
		if poly.size() < 3:
			continue
		# R18：alt（编辑器变换位）参与自绘——翻转/转置不再被三角自绘吞掉
		var alt := MapFormat.alt_of_godot(layer.get_cell_alternative_tile(c))
		draw_tri_texture(texs[src] as Texture2D, poly, atl, cs, alt)

## 把一个图集切片贴到三角形内：UV 取切片在整张图集里的归一化矩形，
## 按三角形包围盒做仿射（切片左上对齐包围盒；等距/斜平面下三角形是旋转的，
## 包围盒映射会把贴图略微拉伸——与导出预览的 _blit_tile 同口径）。
func draw_tri_texture(tex: Texture2D, poly: PackedVector2Array, atl: Vector2i, cs: Vector2i, alt := 0) -> void:
	var tsz := tex.get_size()
	if tsz.x <= 0.0 or tsz.y <= 0.0:
		return
	var uvs := tri_uvs(poly, atl, cs, tsz, alt)
	if uvs.size() != poly.size():
		return
	var cols := PackedColorArray()
	for i in poly.size():
		cols.append(Color.WHITE)
	draw_polygon(poly, cols, uvs, tex)

## 三角形三点 → 图集 UV（纯函数，绘制的几何口径；tests/test_tri_render.gd 直接验证）。
## R18：alt（编辑器变换位 0-7，D4 口径见 map_format）在切片内部施加变换，
## 与按键/吸管的旋转翻转动作同一套编号；alt=0 与旧口径逐点相同。
static func tri_uvs(poly: PackedVector2Array, atl: Vector2i, cs: Vector2i, tex_size: Vector2, alt := 0) -> PackedVector2Array:
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
		# R18：按编辑器变换位在切片内部施加变换（D4 作用，见 map_format ALT_* 表）：
		# 0 恒等 / 1 水平翻转 / 2 垂直翻转 / 3 180° / 4 转置 / 5 90° / 6 270° / 7 270°·翻转
		var ux := lx
		var uy := ly
		var a := alt & 7
		if a == 1:
			ux = 1.0 - lx
		elif a == 2:
			uy = 1.0 - ly
		elif a == 3:
			ux = 1.0 - lx
			uy = 1.0 - ly
		elif a == 4:
			ux = ly
			uy = lx
		elif a == 5:
			ux = 1.0 - ly
			uy = lx
		elif a == 6:
			ux = ly
			uy = 1.0 - lx
		elif a == 7:
			ux = 1.0 - ly
			uy = 1.0 - lx
		out.append(Vector2(lerpf(u0, u1, ux), lerpf(v0, v1, uy)))
	return out
