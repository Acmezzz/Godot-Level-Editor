extends Control
## 内容编辑器中列：只读地图预览（自绘 Control）。
## 为什么独立重绘：同一 TileMapLayer 不能两处上屏，所以不挂 app.canvas，按坐标重画。
## 只读手势：滚轮缩放（鼠标锚点缩放）、中键按住拖动平移、左键点击选中实例（回调宿主）。

const Th := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")
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
var _tiles_rev := {}   # 层栈下标 -> 缓存对应的 tile_rev
var _entity_order_key := []
var _entity_order: Array = []

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
	# 取景范围与主画布共用——层 offset/scale 之后内容可能出根边界，
	# 只按根边界 fit 会把移出去的层裁在画面外。
	_bounds_cache = MapViewData.scene_bounds(host.app.canvas.map_data, host.app.manifest, true)
	if not _bounds_cache.has_area():
		# 退化范围（空图/坏 meta）：退回格空间名义边界，保证 fit 有正尺寸
		var gs: GridSpace = MapViewData.effective_grid(host.app.canvas.map_data, host.app.manifest)
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
	var ents := _ordered_entities()
	for i in range(ents.size() - 1, -1, -1):
		var row: Dictionary = ents[i]
		var n: EntityNode = row.node
		if str(row.code) == "" or n == null or not is_instance_valid(n):
			continue
		if not host.app.canvas.is_entity_shown(n):
			continue
		var xf := MapViewData.layer_transform(host.app.canvas.map_data, n.layer_id)
		var lp := xf.affine_inverse() * world
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
	var gs_lines: GridSpace = MapViewData.effective_grid(host.app.canvas.map_data, host.app.manifest)
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

	var rows := _ordered_entities()
	var by_layer := {}
	for row: Dictionary in rows:
		var n: EntityNode = row.node
		if not by_layer.has(n.layer_id):
			by_layer[n.layer_id] = [[], []]
		var side := 0 if n.z_policy == "below" else 1
		by_layer[n.layer_id][side].append(row)
	var layers: Array = meta.get("layers", [])
	for li in layers.size():
		if not layers[li] is Dictionary or not host.app.canvas.is_layer_visible(li):
			continue
		var lid := str(layers[li].get("id", ""))
		var groups: Array = by_layer.get(lid, [[], []])
		for row: Dictionary in groups[0]:
			_draw_entity(row, origin, s)
		_draw_tiles(li, lid, gs_lines, origin, s, mw, mh)
		for row: Dictionary in groups[1]:
			_draw_entity(row, origin, s)
	_draw_collision(gs_lines, origin, s, mw, mh)
	for row: Dictionary in rows:
		var code := str(row.code)
		if code == "":
			continue
		if code == str(host._selected_ent) or code == hover_ent or code == highlight_ent:
			var rect := _entity_rect(row.node, origin, s)
			var color := Th.WARN if code == str(host._selected_ent) else HOVER_COL
			draw_rect(rect.grow(3.0), color, false, 2.0)

func _ordered_entities() -> Array:
	var cvs = host.app.canvas
	var key := [cvs.get_instance_id(), cvs.ents_rev, cvs.vis_rev]
	if key == _entity_order_key:
		return _entity_order
	var out: Array = []
	for n: EntityNode in cvs.ents_all():
		if cvs.is_entity_shown(n):
			out.append({"node": n, "code": n.code if n.is_entity() else "", "asset": n.asset, "index": out.size()})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var na: EntityNode = a.node
		var nb: EntityNode = b.node
		var li: int = cvs._layer_index_of(na.layer_id)
		var lj: int = cvs._layer_index_of(nb.layer_id)
		if li != lj:
			return li < lj
		var sa := MapViewData.object_segment(na.z_policy)
		var sb := MapViewData.object_segment(nb.z_policy)
		if sa != sb:
			return sa < sb
		if sa == 1 and na.get_parent().y_sort_enabled and na.position.y != nb.position.y:
			return na.position.y < nb.position.y
		return a.index < b.index)
	_entity_order_key = key
	_entity_order = out
	return out

func _entity_rect(n: EntityNode, origin: Vector2, scale_px: float) -> Rect2:
	var xf := MapViewData.layer_transform(host.app.canvas.map_data, n.layer_id)
	var r := MapViewData.xform_rect(xf, n.aabb())
	return Rect2(origin + r.position * scale_px, r.size * scale_px)

func _draw_entity(row: Dictionary, origin: Vector2, scale_px: float) -> void:
	var n: EntityNode = row.node
	var xf := MapViewData.layer_transform(host.app.canvas.map_data, n.layer_id)
	var pts := n.quad()
	for i in pts.size():
		pts[i] = origin + (xf * pts[i]) * scale_px
	var tex: Texture2D = host.app.canvas.thumbs.get(str(row.asset))
	if is_zero_approx((pts[1] - pts[0]).cross(pts[3] - pts[0])):
		return
	if tex != null:
		var uv := PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN])
		for i in uv.size():
			uv[i] = Vector2(1.0 - uv[i].x if n.flipped_h() else uv[i].x,
				1.0 - uv[i].y if n.flipped_v() else uv[i].y)
		draw_colored_polygon(pts, Color.WHITE, uv, tex)
	else:
		draw_colored_polygon(pts, Color(Th.ACCENT, 0.35))
		pts.append(pts[0])
		draw_polyline(pts, Color(Th.ACCENT_HI, 0.8), 1.0)

func _draw_collision(gs: GridSpace, origin: Vector2, scale_px: float, mw: int, mh: int) -> void:
	var cvs = host.app.canvas
	if cvs.collision == null or not cvs.is_layer_visible(cvs.collision_index()):
		return
	var colors := {}
	for cell: Vector2i in cvs.collision.get_used_cells():
		if not gs.cell_in_map(cell, mw, mh):
			continue
		var info: Dictionary = cvs._collision_meta.get(cell, {})
		var type := str(info.get("type", "solid"))
		if not colors.has(type):
			var decl := CollisionTypes.decl_of(host.app.manifest, type)
			colors[type] = CollisionView._colors_of(decl if not decl.is_empty() else {"id": type})
		var pts := MapViewData.collision_polygon(gs.cell_polygon(cell), str(info.get("shape", "")))
		for i in pts.size():
			pts[i] = origin + pts[i] * scale_px
		draw_colored_polygon(pts, colors[type][0])
		draw_polyline(pts + PackedVector2Array([pts[0]]), colors[type][1], 1.0)

func _draw_tiles(li: int, lid: String, gs: GridSpace, origin: Vector2, s: float, mw: int, mh: int) -> void:
	var cvs = host.app.canvas
	gs = cvs.tile_grid_for_layer(li)
	var xf := MapViewData.layer_transform(cvs.map_data, lid)
	var texs: Array = cvs.atlas_texs
	for row: Array in _tiles(li, lid):
		var cell := Vector2i(int(row[0]), int(row[1]))
		if not gs.cell_in_map(cell, mw, mh):
			continue
		var pts := gs.cell_polygon(cell)
		for i in pts.size():
			pts[i] = origin + (xf * pts[i]) * s
		var aid := str(row[2])
		var source: int = cvs.source_of_asset(aid)
		var tex: Texture2D = texs[source] if source >= 0 and source < texs.size() else null
		var cell_size := Vector2(cvs.asset_cell(aid))
		if tex == null or cell_size.x <= 0.0 or cell_size.y <= 0.0:
			draw_colored_polygon(pts, Th.MAP_TERRAIN)
			continue
		var atlas := Vector2i(int(row[3]), int(row[4]))
		var alt := int(row[5]) if row.size() >= 6 else 0
		var uv := TriTileView.tri_uvs(pts, atlas, cell_size, tex.get_size(), alt)
		if uv.size() == pts.size():
			var colors := PackedColorArray()
			colors.resize(pts.size())
			colors.fill(Color.WHITE)
			draw_polygon(pts, colors, uv, tex)

## 预览用的瓦片列表，统一为 [x, y, 资产id, ax, ay, alt]（按层栈下标取）。
## 首选画布实时 TileMapLayer（编辑中的改动立刻反映），图层不可用时退回 map_data 数组。
## alt 必须一起带出来：多边形分支要把它贴在切片 UV 里，丢了就等于预览里看不见翻转/转置。
func _tiles(li: int, layer_id: String) -> Array:
	if not host._map_ready():
		return []
	var rev := [host.app.canvas.get_instance_id(), host.app.canvas.tile_rev]
	if _tiles_rev.get(li, []) == rev:
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
