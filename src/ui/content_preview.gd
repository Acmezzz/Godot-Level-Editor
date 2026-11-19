extends Control
## 内容编辑器中列：只读地图预览（自绘 Control）。
## 为什么独立重绘：同一 TileMapLayer 不能两处上屏，所以不挂 app.canvas，按坐标重画。
## 只读手势：滚轮缩放（鼠标锚点缩放）、中键按住拖动平移、左键点击选中实例（回调宿主）。

const Th := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")

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
var _tiles_rev := {}   # kind -> 缓存对应的 map_rev

func _init(host) -> void:
	self.host = host
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

## fit 缩放：把整张地图塞进控件（留 24px 边距），不跟随关卡画布的 zoom/相机。
func _fit() -> float:
	if not host._map_ready() or size.x <= 1 or size.y <= 1:
		return 0.0
	var meta: Dictionary = host.app.canvas.map_data.get("meta", {})
	# app.canvas 在宿主上是无类型 var，链式取值是 Variant：必须显式标注，否则推断失败
	var tile_px: float = float(host.app.canvas.tile_px)
	var w: float = float(int(meta.get("w", K.DEFAULT_MAP_W))) * tile_px
	var h: float = float(int(meta.get("h", K.DEFAULT_MAP_H))) * tile_px
	if w <= 0 or h <= 0:
		return 0.0
	return minf((size.x - 48) / w, (size.y - 48) / h)

func _scale() -> float:
	return _fit() * _zoom

## 预览视图原点：居中原点 + 用户 pan 偏移（绘制与命中测试共用同一变换）
func _origin(s: float) -> Vector2:
	var meta: Dictionary = host.app.canvas.map_data.get("meta", {})
	var tile_px: float = float(host.app.canvas.tile_px)
	var map_px := Vector2(float(int(meta.get("w", K.DEFAULT_MAP_W))) * tile_px,
		float(int(meta.get("h", K.DEFAULT_MAP_H))) * tile_px) * s
	return (size - map_px) * 0.5 + _pan

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

## 光标下的实例 id（"" = 空白处）。后画的在上层，命中测试反向遍历
## （同一格叠多个时取最上面那个）。坐标均为预览控件本地坐标。
func _hit_at(pos: Vector2) -> String:
	if not host._map_ready():
		return ""
	var s := _scale()
	if s <= 0.0:
		return ""
	var meta: Dictionary = host.app.canvas.map_data.get("meta", {})
	var map_px := Vector2(float(int(meta.get("w", K.DEFAULT_MAP_W))) * host.app.canvas.tile_px,
		float(int(meta.get("h", K.DEFAULT_MAP_H))) * host.app.canvas.tile_px) * s
	var origin := _origin(s)
	var world := (pos - origin) / s
	var ents: Array = host._entities()
	for i in range(ents.size() - 1, -1, -1):
		var row: Dictionary = ents[i]
		var spr: Sprite2D = row.spr
		if spr == null or not is_instance_valid(spr):
			continue
		var half: Vector2 = host.app.canvas.entity_display_size_of(spr) * 0.5
		if absf(world.x - spr.position.x) <= maxf(half.x, 4.0) \
				and absf(world.y - spr.position.y) <= maxf(half.y, 4.0):
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
	var tile := float(host.app.canvas.tile_px)
	var map_px := Vector2(float(mw) * tile, float(mh) * tile) * s
	var origin := _origin(s)
	draw_rect(Rect2(origin, map_px), Th.BG_BASE)
	var step := tile * s
	# 网格：缩略后逐格线过密就不画（避免一整片灰）
	if step >= 6.0:
		var grid_col := Color(1, 1, 1, 0.05)
		for x in mw + 1:
			var px := origin.x + x * step
			draw_line(Vector2(px, origin.y), Vector2(px, origin.y + map_px.y), grid_col, 1.0)
		for y in mh + 1:
			var py := origin.y + y * step
			draw_line(Vector2(origin.x, py), Vector2(origin.x + map_px.x, py), grid_col, 1.0)
	draw_rect(Rect2(origin, map_px), Color(1, 1, 1, 0.25), false, 1.0)

	# 地形 / 装饰真实瓦片：预览必须看得出实例压在哪块地上，只画网格等于丢了一半信息。
	# 数据优先取画布实时 TileMapLayer（刚涂的立刻可见），退回 map_data 的序列化数组；
	# 两种来源都归一成 [x, y, atlas, ax, ay]。
	var texs: Array = host.app.canvas.atlas_texs
	for kind in ["terrain", "decor"]:
		var fallback: Color = Th.MAP_TERRAIN if str(kind) == "terrain" else Th.MAP_DECOR
		for t in _tiles(str(kind)):
 # 只画地图边界内的格：画布允许在边界外涂，预览出框会显得脏
			var cx := int(t[0])
			var cy := int(t[1])
			if cx < 0 or cy < 0 or cx >= mw or cy >= mh:
				continue
			var ai := int(t[2])
			var src := Rect2(Vector2(float(t[3]), float(t[4])) * tile, Vector2(tile, tile))
			var dst := Rect2(origin + Vector2(float(t[0]), float(t[1])) * step, Vector2(step, step))
			var atex: Texture2D = null
			if ai >= 0 and ai < texs.size():
				atex = texs[ai] as Texture2D
			if atex != null:
				draw_texture_rect_region(atex, dst, src)
			else:
				draw_rect(dst, fallback, true)

	var hover_rect := Rect2()
	var highlight_rect := Rect2()
	var sel: String = str(host._selected_ent)
	for row in host._entities():
		var spr: Sprite2D = row.spr
		if spr == null or not is_instance_valid(spr):
			continue
		var dsz: Vector2 = host.app.canvas.entity_display_size_of(spr) * s
		var center := origin + spr.position * s
		var rect := Rect2(center - dsz * 0.5, dsz)
		var tex: Texture2D = host.app.canvas.thumbs.get(str(row.scene))
		if tex != null:
			draw_texture_rect(tex, rect, false)
		else:
 # 内置种类（触发区等）没有缩略图：画半透明块，尺寸就是它在游戏里的占位
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

## 预览用的瓦片列表，统一为 [x, y, atlas, ax, ay]。
## 首选画布实时 TileMapLayer（编辑中的改动立刻反映），图层不可用时退回 map_data 数组。
func _tiles(kind: String) -> Array:
	if not host._map_ready():
		return []
	var rev: int = int(host.app.canvas.map_rev)
	if _tiles_rev.get(kind, -1) == rev:
		return _tiles_cache.get(kind, [])
	var out: Array = []
	var layer: TileMapLayer = host.app.canvas.terrain if kind == "terrain" else host.app.canvas.decor
	if layer != null and is_instance_valid(layer):
		for c in layer.get_used_cells():
			var ac: Vector2i = layer.get_cell_atlas_coords(c)
			if ac == Vector2i(-1, -1):
				continue
			out.append([c.x, c.y, layer.get_cell_source_id(c), ac.x, ac.y])
	else:
		for raw in host.app.canvas.map_data.get(kind, []):
			if not (raw is Array) or (raw as Array).size() < 5:
				continue
			var a: Array = raw
			out.append([int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4])])
	_tiles_cache[kind] = out
	_tiles_rev[kind] = rev
	return out

