class_name TriTileView
extends Node2D
## B3：瓦片自绘层。TileMapLayer 只有方形/等距/六角三种 tile_shape，表现不了
## 半格三角形，也表达不了任意斜基（gridBasis）的平行四边形。这两种拓扑下瓦片数据仍住在
## TileMapLayer（六元组原样读写），由本节点按真实格多边形自绘（以图集切片为源，按格形做 UV 裁切）。
##
## 显隐与层参数由层控制器同步到本节点（图层接口只碰 TileMapLayer，本节点跟它走）；
## refresh() 只是请求重绘（queue_redraw），真正的遍历在 _draw() 里——只扫**可见世界矩形**内的格。
## §4.3-3：图元按块缓存。格空间按 BLOCK×BLOCK 分块，数据变化（refresh）时整表作废，
## 下次绘制一次性把全部块算好；此后平移/缩放只遍历与视口相交的块，重算量与「数据变化」挂钩、
## 与「相机移动」脱钩。块包围盒取块内实际多边形的并集，任何斜基/三角都不越界。
const BLOCK := 16

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")
const MapFormat := preload("res://src/map/map_format.gd")

var layer: TileMapLayer
var grid: GridSpace
var cvs   # 宿主画布（manifest / atlas_texs / asset_of_source / asset_cell）

## §4.3-3 块缓存：块坐标 (bx,by) → {bbox, items:[{poly, uvs, tex}]}。
## refresh() 整表作废，下次绘制重建一次（O(该层瓦片数)），此后平移/缩放只遍历可见块。
var _blocks := {}
var _built := false
var _dirty_blocks := {}
var _atlas_rev := -1   # 图集重建（外改图集 / 资产增删）后，缓存里的纹理引用会过期

func setup(p_layer: TileMapLayer, p_grid: GridSpace, p_cvs) -> Node2D:
	layer = p_layer
	grid = p_grid
	cvs = p_cvs
	return self

func refresh() -> void:
	_blocks.clear()   # 数据变了：全部块作废，下次绘制重算（按可见块惰性重扫）
	_built = false
	queue_redraw()

func dirty_cell(cell: Vector2i) -> void:
	_dirty_blocks[_block_key(cell)] = true
	queue_redraw()

func _draw() -> void:
	if layer == null or not is_instance_valid(layer) or grid == null or cvs == null:
		return
	if not _built or _atlas_rev != int(cvs.atlas_rev):
		_atlas_rev = int(cvs.atlas_rev)
		_blocks.clear()
		_build_blocks(layer.get_used_cells())
		_dirty_blocks.clear()
		_built = true
	# §5：按可见世界矩形裁剪——只遍历与视口相交的块，块内图元已算好。
	var vis := Rect2()
	var has_vis := false
	var vp := get_viewport()
	if vp != null:
		var world: Rect2 = vp.get_canvas_transform().affine_inverse() * Rect2(Vector2.ZERO, vp.get_visible_rect().size)
		vis = get_global_transform().affine_inverse() * world
		has_vis = true
	var keys: Array = _blocks.keys()
	for key: Vector2i in _dirty_blocks:
		_blocks.erase(key)
		var start := key * BLOCK
		var cells: Array[Vector2i] = []
		for y in range(start.y, start.y + BLOCK):
			for x in range(start.x, start.x + BLOCK):
				var cell := Vector2i(x, y)
				if layer.get_cell_source_id(cell) >= 0:
					cells.append(cell)
		_build_blocks(cells)
	if not _dirty_blocks.is_empty():
		keys = _blocks.keys()
		_dirty_blocks.clear()
	if has_vis:
		var range_cells := grid.cell_window(vis)
		var lo := _block_key(range_cells.position)
		var hi := _block_key(range_cells.end - Vector2i.ONE)
		if float(hi.x - lo.x + 1) * float(hi.y - lo.y + 1) < keys.size():
			keys = []
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var key := Vector2i(x, y)
					if _blocks.has(key):
						keys.append(key)
	for k in keys:
		var blk: Dictionary = _blocks[k]
		if has_vis and not vis.intersects(blk.bbox as Rect2):
			continue
		for it in (blk.items as Array):
			var item: Dictionary = it
			draw_polygon(item.poly as PackedVector2Array, _white_cols((item.poly as PackedVector2Array).size()),
				item.uvs as PackedVector2Array, item.tex as Texture2D)

## 块号：格空间按 BLOCK 均分。三角拓扑的格号 x 是半格列，块也就按半格列分，
## 块包围盒由块内实际多边形合并得到（不依赖拓扑公式，任何斜基/三角都不越界）。
static func _block_key(c: Vector2i) -> Vector2i:
	return Vector2i(floori(float(c.x) / BLOCK), floori(float(c.y) / BLOCK))

## 重建块表：遍历一次该层瓦片，把多边形/UV/纹理算好按块归堆。
func _build_blocks(cells: Array[Vector2i]) -> void:
	for c in cells:
		if layer.get_cell_tile_data(c) == null:
			continue
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
		var poly := tile_polygon(grid, c, cs)
		if poly.size() < 3:
			continue
		var tex := texs[src] as Texture2D
		if tex == null or tex.get_size().x <= 0.0 or tex.get_size().y <= 0.0:
			continue
		# R18：alt（编辑器变换位）参与自绘——翻转/转置不再被三角自绘吞掉
		var alt := MapFormat.alt_of_godot(layer.get_cell_alternative_tile(c))
		var uvs := tri_uvs(poly, atl, cs, tex.get_size(), alt)
		if uvs.size() != poly.size():
			continue
		var k := _block_key(c)
		var bb := _bbox_of_poly(poly)
		if not _blocks.has(k):
			_blocks[k] = {"bbox": bb, "items": []}
		var blk: Dictionary = _blocks[k]
		blk.bbox = (blk.bbox as Rect2).merge(bb)
		(blk.items as Array).append({"poly": poly, "uvs": uvs, "tex": tex})

static func tile_polygon(grid_space: GridSpace, cell: Vector2i, size: Vector2i) -> PackedVector2Array:
	if grid_space.is_tri() or grid_space.has_basis:
		return grid_space.cell_polygon(cell)
	var rect := grid_space.cell_tex_rect(cell, size)
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)])

static func _white_cols(n: int) -> PackedColorArray:
	var cols := PackedColorArray()
	for i in n:
		cols.append(Color.WHITE)
	return cols

## 多边形包围盒（可见区裁剪用）。
static func _bbox_of_poly(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p: Vector2 in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)

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
		var uv := tile_uv(Vector2(lx, ly), alt)
		out.append(Vector2(lerpf(u0, u1, uv.x), lerpf(v0, v1, uv.y)))
	return out

## 图集格内的 D4 变换，实时预览和 PNG 采样共用。
static func tile_uv(local: Vector2, alt: int) -> Vector2:
	var lx := local.x
	var ly := local.y
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
	return Vector2(ux, uy)
