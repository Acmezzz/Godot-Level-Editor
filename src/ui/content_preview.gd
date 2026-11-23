extends Control
## 内容编辑器中列：只读地图预览（自绘 Control）。
## 为什么独立重绘：同一 TileMapLayer 不能两处上屏，所以不挂 app.canvas，按坐标重画。
## 只读手势：滚轮缩放（鼠标锚点缩放）、中键按住拖动平移、左键点击选中实例（回调宿主）。

const Th := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapExport := preload("res://src/map/map_export.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const MapFormat := preload("res://src/map/map_format.gd")

## 悬停高亮色：青色，和选中框的黄（Th.WARN）区分开
const HOVER_COL := Color(0.35, 0.95, 0.95, 0.95)

var host  # content_editor 宿主（_map_ready / _entities / select_inst / app 都在宿主）

## 青框悬停的实例 id（宿主在悬停目标失效时清它）
var hover_ent := ""
## 指向预览：引用字段选中的实例（亮青粗框；编辑引用时由宿主设置）
var highlight_ent := ""

var _zoom := 1.0
var _pan := Vector2.ZERO
var _panning := false   # 中键按住拖动平移（手势同关卡画布）
# 瓦片缓存（整图满涂时每次重绘重建上万条临时数组——按 canvas.map_rev 缓存）
var _tiles_cache := {}
var _tiles_rev := {}   # 层栈下标 -> 缓存对应的 map_rev

func _init(h) -> void:
	self.host = h
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 缩放/平移后地图不能画出控件边界（曾盖到左列）——同关卡画布的裁剪语义
	clip_contents = true
	tooltip_text = "只读预览 · 滚轮缩放 · 中键拖动 · 点击实例选中"

## 宿主刷新入口：任何数据变化后调它重绘。
func refresh() -> void:
	queue_redraw()

## 悬停实例变更（含清空）。
func set_hover(id: String) -> void:
	hover_ent = id
	queue_redraw()

## 指向预览：高亮引用字段选中的实例（含清空）。
func set_highlight(id: String) -> void:
	highlight_ent = id
	queue_redraw()

## 切图/缩放复位：zoom 归 1（整图塞进控件）、pan 归零。
func reset_view() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	_panning = false
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# 中键拖动平移：pan 是屏幕偏移，手势语义与画布 cam_pos 相同（跟手走）
		if _panning:
			_pan += mm.relative
			refresh()
			return
		_update_hover(mm.position)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP
			or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_zoom_at(mb.position, 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
		return
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = mb.pressed
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if not host._map_ready():
		return
	var hit := _hit_at(mb.position)
	if hit != "":
		host.select_inst(hit)

## 鼠标离开预览区：清掉悬停高亮，避免光标移出后框还停在原处；拖出即复位中键
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		set_hover("")
		_panning = false
	elif what == NOTIFICATION_MOUSE_ENTER:
		_update_hover(get_local_mouse_position())

## 更新悬停实体并重绘（悬停框是最上层信息，每次移动都请求重绘）。
func _update_hover(pos: Vector2) -> void:
	set_hover(_hit_at(pos))

## 地图的世界像素包围盒（取景/原点/背景共用）：等距/六边/斜基/三角的地图不是
## w×tile、h×tile 的矩形，按正交宽高取景会把整图裁掉（V4 P1）。几何统一走 GridSpace。
## 每帧多次调用（fit/origin/绘制），按 map_rev 缓存——切图或有改动才重算。
var _bounds_cache := Rect2()
var _bounds_rev := -1

func _map_bounds_px() -> Rect2:
	var rev: int = int(host.app.canvas.map_rev)
	if rev == _bounds_rev:
		return _bounds_cache
	var meta: Dictionary = host.app.canvas.map_data.get("meta", {})
	var mw := int(meta.get("w", K.DEFAULT_MAP_W))
	var mh := int(meta.get("h", K.DEFAULT_MAP_H))
	# §4.3-1：取景范围与导出一份口径——层 offset/scale 之后内容可能出根边界，
	# 只按根边界 fit 会把移出去的层裁在画面外。
	_bounds_cache = MapViewData.scene_bounds(host.app.canvas.map_data, host.app.manifest, true)
	if not _bounds_cache.has_area():
		# 退化范围（空图/坏 meta）：退回格空间名义边界，保证 fit 有正尺寸
		var gs: GridSpace = MapExport.grid_of(host.app.canvas.map_data, host.app.manifest)
		_bounds_cache = gs.map_bounds(Rect2i(0, 0, mw, mh))
	_bounds_rev = rev
	return _bounds_cache
## fit 缩放：把整张地图塞进控件（留 24px 边距），不跟随关卡画布的 zoom/相机。
func _fit() -> float:
	if not host._map_ready() or size.x <= 1 or size.y <= 1:
		return 0.0
	var bb := _map_bounds_px()
	if bb.size.x <= 0.0 or bb.size.y <= 0.0:
		return 0.0
	return minf((size.x - 48) / bb.size.x, (size.y - 48) / bb.size.y)

func _scale() -> float:
	return _fit() * _zoom

## 预览视图原点：世界 (0,0) 在控件里的位置 = 居中 + 用户 pan 偏移
## （地图包围盒起点不一定在 0,0——等距图的左上角为负，必须扣掉 bounds.position）。
func _origin(s: float) -> Vector2:
	var bb := _map_bounds_px()
	return (size - bb.size * s) * 0.5 - bb.position * s + _pan

## 滚轮缩放预览：缩放前后鼠标指着的地图点不动。pan 屏幕偏移 = 新原点 − 新居中原点。
func _zoom_at(pos: Vector2, factor: float) -> void:
	if not host._map_ready():
		return
	var s_old := _scale()
	if s_old <= 0.0:
		return
	var origin_old := _origin(s_old)
	_zoom = clampf(_zoom * factor, 0.2, 8.0)
	var s_new := _scale()
	if is_equal_approx(s_new, s_old):
		return
	_pan = Vector2.ZERO
	var center_new := _origin(s_new)
	_pan = pos - (pos - origin_old) * (s_new / s_old) - center_new
	refresh()

## 光标下的实例码（"" = 空白处）。后画的在上层，命中测试反向遍历
## （同一格叠多个时取最上面那个）。坐标均为预览控件本地坐标。
## 命中口径复用主画布（E14）：世界坐标先经主画布层变换反算，再用实例真实几何
## （含旋转/缩放/翻转）判定；隐藏层与隐藏实例不命中，与主画布一致。
func _hit_at(pos: Vector2) -> String:
	if not host._map_ready():
		return ""
	var s := _scale()
	if s <= 0.0:
		return ""
	var origin := _origin(s)
	var world := (pos - origin) / s
	var ents: Array = host._entities()
	for i in range(ents.size() - 1, -1, -1):
		var row: Dictionary = ents[i]
		var n: EntityNode = row.node
		if n == null or not is_instance_valid(n):
			continue
		if not host.app.canvas.is_entity_shown(n):
			continue
		var li: int = host.app.canvas._layer_index_of(n.layer_id)
		var lp: Vector2 = world if li < 0 else host.app.canvas.to_layer_local(li, world)
		if n.contains_point(lp):
			return str(row.code)
	return ""

func _draw() -> void:
	_draw_map()

## 预览绘制：网格 + 真实地形/装饰瓦片 + 实例缩略图/色块 + 选中/悬停框。
## 地形必须画出来：只画实体点时，用户看不出实例压在什么地形上。
func _draw_map() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Th.BG_VOID)
	if not host._map_ready():
		draw_string(ThemeDB.fallback_font, Vector2(24, size.y * 0.5),
			"没有正在编辑的地图", HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_SMALL, Th.TEXT_MUTE)
		return
	var s := _scale()
	if s <= 0.0:
		return
	var meta: Dictionary = host.app.canvas.map_data.get("meta", {})
	var mw := int(meta.get("w", K.DEFAULT_MAP_W))
	var mh := int(meta.get("h", K.DEFAULT_MAP_H))
	var tile_w := float(host.app.canvas.tile_w)
	var tile_h := float(host.app.canvas.tile_h)
	var mbb := _map_bounds_px()
	var map_px := mbb.size * s
	var origin := _origin(s)
	# 背景/边框 = 地图真实包围盒（等距/六边/斜基/三角都不是 w×tile 的矩形）
	draw_rect(Rect2(origin + mbb.position * s, map_px), Th.BG_BASE)
	# 网格：缩略后逐格线过密就不画（避免一整片灰）；矩形格两轴步长分开。
	# 只有正交（无斜基）才铺规则方格——其余投影的格线走 GridSpace，不在这里硬画。
	var step_x := tile_w * s
	var step_y := tile_h * s
	var gs_lines: GridSpace = MapExport.grid_of(host.app.canvas.map_data, host.app.manifest)
	var plain_ortho := not (gs_lines.has_basis or gs_lines.is_iso() or gs_lines.is_hex() or gs_lines.is_tri())
	if plain_ortho and minf(step_x, step_y) >= 6.0:
		var grid_col := Color(1, 1, 1, 0.05)
		for x in mw + 1:
			var px := origin.x + x * step_x
			draw_line(Vector2(px, origin.y), Vector2(px, origin.y + map_px.y), grid_col, 1.0)
		for y in mh + 1:
			var py := origin.y + y * step_y
			draw_line(Vector2(origin.x, py), Vector2(origin.x + map_px.x, py), grid_col, 1.0)
	draw_rect(Rect2(origin + mbb.position * s, map_px), Color(1, 1, 1, 0.25), false, 1.0)

	# 各用户层真实瓦片：预览必须看得出实例压在哪块地上，只画网格等于丢了一半信息。
	# 数据优先取画布实时 TileMapLayer（刚涂的与主画布一致），退回 map_data 的序列化数组；
	# 两种来源都归一成 [x, y, 资产id, ax, ay]；预览不分层配色，统一用地形色。
	# R19：非正交图（等距/六边/斜基/三角）的地形按 GridSpace 格多边形落位与着色
	# （与主画布/导出同一口径），实体走世界坐标——同一 GridSpace 下地形与实例对齐。
	# 正交图保持原纹理块绘制；参考图允许色块简化，但格形、落点与范围必须保真。
	var gs: GridSpace = MapExport.grid_of(host.app.canvas.map_data, host.app.manifest)
	var use_poly: bool = gs.has_basis or gs.is_iso() or gs.is_hex() or gs.is_tri()
	var layers: Array = meta.get("layers", [])
	if not use_poly:
		for li in layers.size():
			var ldef = layers[li]
			if not (ldef is Dictionary):
				continue
			var fallback: Color = Th.MAP_TERRAIN
			var lid := str(ldef.get("id", ""))
			# 层 offset/scale 同样作用在正交瓦片上（否则瓦片不动、实例动，预览会错位）。
			# 层变换统一取 MapViewData.layer_transform（与画布/导出同一份规则），每层只算一次。
			var lxf := MapViewData.layer_transform(host.app.canvas.map_data, lid)
			for t in _tiles(li, lid):
				# 只画地图边界内的格：画布允许在边界外涂，预览出框会显得脏。
				# 三角拓扑的 x 是三角列（0..2w-1），边界判定交 GridSpace（V4 P1）
				if not gs_lines.cell_in_map(Vector2i(int(t[0]), int(t[1])), mw, mh):
					continue
				var cx := int(t[0])
				var cy := int(t[1])
				var aid := str(t[2])
				var texs: Array = host.app.canvas.atlas_texs
				var ai: int = host.app.canvas.source_of_asset(aid)
				var cs := Vector2(host.app.canvas.asset_cell(aid))
				var src := Rect2(Vector2(float(t[3]), float(t[4])) * cs, cs)
				var alt := int(t[5]) if t.size() >= 6 else 0
				var atex: Texture2D = null
				if ai >= 0 and ai < texs.size():
					atex = texs[ai] as Texture2D
				# 正交格形本来就是方形：无层变换时直接量出目标矩形（不每格走 cell_polygon）；
				# 有层变换才取格多边形过变换再取包围盒（与实例同一条规则）。
				var quad: PackedVector2Array
				var dst: Rect2
				if lxf == Transform2D.IDENTITY:
					dst = Rect2(origin + Vector2(float(cx) * tile_w * s, float(cy) * tile_h * s),
						Vector2(tile_w, tile_h) * s)
					quad = PackedVector2Array([dst.position, Vector2(dst.end.x, dst.position.y),
						dst.end, Vector2(dst.position.x, dst.end.y)])
				else:
					var poly := _xformed(lxf, gs.cell_polygon(Vector2i(cx, cy)))
					var bb := _poly_bbox(poly)
					dst = Rect2(origin + bb.position * s, bb.size * s)
					quad = PackedVector2Array()
					for p1 in poly:
						quad.append(origin + (p1 as Vector2) * s)
				if atex == null:
					draw_rect(dst, fallback, true)
				elif alt == 0:
					# 无变换：直接按纹理块贴（最快路径）
					draw_texture_rect_region(atex, dst, src)
				elif cs != Vector2.ZERO:
					# alt ≠ 0：翻转/转置编在切片内，纹理块贴图会丢掉它们——
					# 改走与多边形分支同一个 tri_uvs（切片内施加变换），格形仍是方形。
					var uvs: PackedVector2Array = TriTileView.tri_uvs(quad,
						Vector2i(int(t[3]), int(t[4])), cs, atex.get_size(), alt)
					if uvs.size() == quad.size():
						var cols := PackedColorArray()
						for _i in quad.size():
							cols.append(Color.WHITE)
						draw_polygon(quad, cols, uvs, atex)
					else:
						draw_texture_rect_region(atex, dst, src)
				else:
					draw_texture_rect_region(atex, dst, src)
	else:
		for li2 in layers.size():
			var ldef2 = layers[li2]
			if not (ldef2 is Dictionary):
				continue
			# R19/B3：层变换（偏移/缩放）参与瓦片落位（与实体同一变换路径）；格多边形 + 真实图集切片：
			# UV 经 tri_uvs（通用多边形口径）贴到格形上，alt 变换位同样生效；坏资产退回色块。
			# 几何统一走 GridSpace 格多边形 + MapViewData 层变换（与画布/导出同口径），每层变换只算一次。
			var lid2 := str(ldef2.get("id", ""))
			var lxf2 := MapViewData.layer_transform(host.app.canvas.map_data, lid2)
			for t2 in _tiles(li2, lid2):
				var cx2 := int(t2[0])
				var cy2 := int(t2[1])
				if not gs.cell_in_map(Vector2i(cx2, cy2), mw, mh):
					continue
				var poly := _xformed(lxf2, gs.cell_polygon(Vector2i(cx2, cy2)))
				var pts := PackedVector2Array()
				for p0 in poly:
					pts.append(origin + (p0 as Vector2) * s)
				var aid2 := str(t2[2])
				var texs: Array = host.app.canvas.atlas_texs
				var ai: int = host.app.canvas.source_of_asset(aid2)
				var cs := Vector2(host.app.canvas.asset_cell(aid2))
				var atex: Texture2D = null
				if ai >= 0 and ai < texs.size():
					atex = texs[ai] as Texture2D
				if atex != null and cs != Vector2.ZERO:
					# R19：切片 → 格多边形 UV（与三角自绘同一纯函数），alt 在切片内生效
					var uvs: PackedVector2Array = TriTileView.tri_uvs(pts,
						Vector2i(int(t2[3]), int(t2[4])), cs, atex.get_size(),
						int(t2[5]) if t2.size() >= 6 else 0)
					if uvs.size() == pts.size():
						var cols := PackedColorArray()
						for _i in pts.size():
							cols.append(Color.WHITE)
						draw_polygon(pts, cols, uvs, atex)
				else:
					draw_colored_polygon(pts, Th.MAP_TERRAIN)
				var outline: PackedVector2Array = pts.duplicate()
				outline.append(pts[0])
				draw_polyline(outline, Color(1, 1, 1, 0.06), 1.0)

	var hover_rect := Rect2()
	var highlight_rect := Rect2()
	var sel: String = str(host._selected_ent)
	for row in host._entities():
		var n: EntityNode = row.node
		if n == null or not is_instance_valid(n):
			continue
		# 与主画布同一可见性口径（E06）：隐藏层/隐藏实例在预览里也不显示
		if not host.app.canvas.is_entity_shown(n):
			continue
		# 层局部 → 世界 → 预览屏幕（E02）：层偏移/缩放/排序点在预览里同样生效
		var li: int = host.app.canvas._layer_index_of(n.layer_id)
		var wrect: Rect2 = n.aabb() if li < 0 else host.app.canvas.layer_xform(li) * n.aabb()
		var rect := Rect2(origin + wrect.position * s, wrect.size * s)
		var tex: Texture2D = host.app.canvas.thumbs.get(str(row.asset))
		if tex != null:
			draw_texture_rect(tex, rect, false)
		else:
			# 内置种类（事件区等）没有缩略图：画半透明块，尺寸就是它在游戏里的占位
			draw_rect(rect, Color(Th.ACCENT, 0.35), true)
			draw_rect(rect, Color(Th.ACCENT_HI, 0.8), false, 1.0)
		# 悬停框记下来，循环结束后再画：否则被后画的实体盖住，悬停看起来像没生效
		if str(row.code) == hover_ent and str(row.code) != sel:
			hover_rect = rect
		if str(row.code) == highlight_ent:
			highlight_rect = rect
		if str(row.code) == sel:
			var pad := 3.0
			draw_rect(rect.grow(pad), Th.WARN, false, 2.0)
	# 悬停高亮：青色淡框 + 细十字，最后画保证在最上层
	if hover_rect.size.x > 0.0:
		var hr := hover_rect.grow(2.0)
		var hc := hr.get_center()
		draw_rect(hr, HOVER_COL, false, 1.5)
		draw_line(Vector2(hr.position.x, hc.y), Vector2(hr.end.x, hc.y), Color(HOVER_COL, 0.35), 1.0)
		draw_line(Vector2(hc.x, hr.position.y), Vector2(hc.x, hr.end.y), Color(HOVER_COL, 0.35), 1.0)
	# 指向预览：引用字段选中的实例（亮青粗框，最后画保证可见）
	if highlight_rect.size.x > 0.0:
		draw_rect(highlight_rect.grow(3.0), Color(0.2, 1.0, 0.9, 0.95), false, 2.0)

## 预览用的瓦片列表，统一为 [x, y, 资产id, ax, ay, alt]（按层栈下标取）。
## 首选画布实时 TileMapLayer（编辑中的改动立刻反映），图层不可用时退回 map_data 数组。
## alt 必须一起带出来：多边形分支要把它贴在切片 UV 里，丢了就等于预览里看不见翻转/转置。
func _tiles(li: int, layer_id: String) -> Array:
	if not host._map_ready():
		return []
	var rev: int = int(host.app.canvas.map_rev)
	if _tiles_rev.get(li, -1) == rev:
		return _tiles_cache.get(li, [])
	var out: Array = []
	var stack: Array = host.app.canvas.layer_tiles
	var layer: TileMapLayer = stack[li] if li >= 0 and li < stack.size() else null
	if layer != null and is_instance_valid(layer):
		for c in layer.get_used_cells():
			var ac: Vector2i = layer.get_cell_atlas_coords(c)
			if ac == Vector2i(-1, -1):
				continue
			var aid: String = host.app.canvas.asset_of_source(layer.get_cell_source_id(c))
			if aid == "":
				continue
			out.append([c.x, c.y, aid, ac.x, ac.y,
				MapFormat.alt_of_godot(layer.get_cell_alternative_tile(c))])
	else:
		var tiles: Dictionary = host.app.canvas.map_data.get("tiles", {})
		for raw in tiles.get(layer_id, []):
			if not (raw is Array) or (raw as Array).size() < 5:
				continue
			var a: Array = raw
			out.append([int(a[0]), int(a[1]), str(a[2]), int(a[3]), int(a[4]),
				int(a[5]) if a.size() >= 6 else 0])
	_tiles_cache[li] = out
	_tiles_rev[li] = rev
	return out

## 多边形轴对齐包围盒（预览贴纹理块用）。
static func _poly_bbox(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)

## 多边形过层变换（Transform2D 乘点为仿射，含 offset/scale）。
static func _xformed(xf: Transform2D, poly: PackedVector2Array) -> PackedVector2Array:
	if xf == Transform2D.IDENTITY:
		return poly
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = xf * (poly[i] as Vector2)
	return out
