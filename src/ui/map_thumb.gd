extends Control
## 跨图落点选择视图：把目标地图完整画出来并支持缩放/平移，用于精确点选落点。
##
## 之前是固定 8px/格的缩略图，格太小又对不准；现在：
##   - 整张地图按 zoom 缩放绘制（滚轮缩放，中键/右键拖拽平移）
##   - 悬停格有黄框；悬停到实体上时该实体高亮并显示名字，避免点错
##   - 点击回传格坐标（空白 = 新建落点）
## 由 app.gd 的跨图落点选择器实例化。

signal hover_info(text: String)

const MIN_ZOOM := 2.0
const MAX_ZOOM := 48.0
const Th := preload("res://src/ui/ui_theme.gd")

var data: Dictionary
var zoom := 8.0                  # 每格像素
var min_zoom := MIN_ZOOM         # U-18：fit 时可随大地图放宽，滚轮下限跟随
var pan := Vector2.ZERO          # 视口左上角对应的地图坐标（格）
var on_pick: Callable            # 兼容旧签名：func(cell, id, scene)
var _hover := Vector2i(-9, -9)
var _hover_ent := {}
var _panning := false
var _pan_from := Vector2.ZERO
var _pan_origin := Vector2.ZERO

## 各实体类型的标记颜色（清单没给就按这个表）
const SCENE_COLORS := {
	"spawn_point": Color(0.30, 1.00, 0.50),
	"portal": Color(0.35, 0.85, 1.00),
	"exit": Color(1.00, 0.62, 0.25),
}

func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP

func _map_size() -> Vector2i:
	var meta: Dictionary = data.get("meta", {})
	return Vector2i(maxi(int(meta.get("w", 1)), 1), maxi(int(meta.get("h", 1)), 1))

## 让整张地图刚好放进当前视口
func fit_view() -> void:
	var ms := _map_size()
	var vp := size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = Vector2(900, 600)
	var ideal := minf(vp.x / float(ms.x), vp.y / float(ms.y))
	# U-18：fit 的承诺优先——大地图允许 zoom 低于全局下限（滚轮下限同步放宽）
	min_zoom = minf(MIN_ZOOM, ideal)
	zoom = clampf(ideal, min_zoom, MAX_ZOOM)
	pan = Vector2.ZERO
	queue_redraw()

## 让某个格居中（打开时把已有落点/当前目标挪到视野中间）
func focus_cell(cell: Vector2i) -> void:
	var half := size * 0.5 / zoom
	pan = Vector2(cell) - half
	_clamp_pan()
	queue_redraw()

## 打开后的首帧初始化：布局尺寸这时才有效。
## 先整图适应窗口；若指定了目标实体，再放大到能看清并居中它——
## 这样打开就是「这张图上你要连的那个点」摆在眼前，不用自己找。
func deferred_open(focus_id: String, map_data: Dictionary) -> void:
	fit_view()
	if focus_id == "":
		return
	for e in map_data.get("entities", []):
		if str(e.get("id", "")) != focus_id:
			continue
		var ms := _map_size()
		# 放大到单格约 14px（能看清邻近格但不必放到最大），再以目标居中
		zoom = clampf(minf(size.x / float(ms.x), size.y / float(ms.y)) * 2.5, 12.0, 26.0)
		focus_cell(Vector2i(int(e.get("x", 0)), int(e.get("y", 0))))
		# 让目标实体自带高亮，一眼看到它
		_hover = Vector2i(int(e.get("x", 0)), int(e.get("y", 0)))
		_hover_ent = e
		hover_info.emit("%s · %s (%d, %d)" % [
			focus_id, str(e.get("scene", "")), _hover.x, _hover.y])
		return

func _clamp_pan() -> void:
	var ms := _map_size()
	var view := size / zoom
	# 地图比视口小时居中，比视口大时限制在边界内
	if view.x >= float(ms.x):
		pan.x = (float(ms.x) - view.x) * 0.5
	else:
		pan.x = clampf(pan.x, 0.0, float(ms.x) - view.x)
	if view.y >= float(ms.y):
		pan.y = (float(ms.y) - view.y) * 0.5
	else:
		pan.y = clampf(pan.y, 0.0, float(ms.y) - view.y)

func _cell_at(local: Vector2) -> Vector2i:
	return Vector2i(((local / zoom) + pan).floor())

func _ent_at(cell: Vector2i) -> Dictionary:
	for e in data.get("entities", []):
		if Vector2i(int(e.get("x", -1)), int(e.get("y", -1))) == cell:
			return e
	return {}

func _draw() -> void:
	var ms := _map_size()
	var origin := -pan * zoom
	var map_rect := Rect2(origin, Vector2(ms) * zoom)

	# 画布底 + 地图底色（地图外区域压暗，边界一眼可辨）
	draw_rect(Rect2(Vector2.ZERO, size), Th.MAP_BG)
	draw_rect(map_rect, Th.MAP_FIELD)

	# 网格：缩放够大才画细格线，否则只画每 8 格的粗线
	var step := 1 if zoom >= 7.0 else 8
	var gx := 0
	while gx <= ms.x:
		var x := origin.x + gx * zoom
		if x >= -2.0 and x <= size.x + 2.0:
			var major := gx % 8 == 0
			draw_line(Vector2(x, maxf(origin.y, 0.0)),
				Vector2(x, minf(map_rect.end.y, size.y)),
				Color(1, 1, 1, 0.10 if major else 0.045), 1.0)
		gx += step
	var gy := 0
	while gy <= ms.y:
		var y := origin.y + gy * zoom
		if y >= -2.0 and y <= size.y + 2.0:
			var major2 := gy % 8 == 0
			draw_line(Vector2(maxf(origin.x, 0.0), y),
				Vector2(minf(map_rect.end.x, size.x), y),
				Color(1, 1, 1, 0.10 if major2 else 0.045), 1.0)
		gy += step

	# 地形 / 装饰（U-19：按可见格范围裁剪，大地图缩放平移不再逐格画到屏幕外）
	var vis := Rect2(-pan, size / zoom).grow(1.0)
	for c in data.get("terrain", []):
		var cell := Vector2i(int(c[0]), int(c[1]))
		if not vis.has_point(Vector2(cell)):
			continue
		var p := origin + Vector2(cell) * zoom
		draw_rect(Rect2(p, Vector2(zoom, zoom)), Th.MAP_TERRAIN)
	for c in data.get("decor", []):
		var cell2 := Vector2i(int(c[0]), int(c[1]))
		if not vis.has_point(Vector2(cell2)):
			continue
		var p := origin + Vector2(cell2) * zoom
		draw_rect(Rect2(p, Vector2(zoom, zoom)), Th.MAP_DECOR)

	# 实体标记：按格大小自适应，太小就画个实心块
	for e in data.get("entities", []):
		var cell := Vector2i(int(e.get("x", 0)), int(e.get("y", 0)))
		var p := origin + Vector2(cell) * zoom
		var sc := str(e.get("scene", ""))
		var col: Color = SCENE_COLORS.get(sc, Th.MAP_ENT_FALLBACK)
		var is_hover: bool = str(_hover_ent.get("id", "")) == str(e.get("id", "")) \
			and str(_hover_ent.get("scene", "")) == sc
		var sz := maxf(zoom * 0.9, 5.0)
		var r := Rect2(p + (Vector2(zoom, zoom) - Vector2(sz, sz)) * 0.5, Vector2(sz, sz))
		draw_rect(r, col)
		if is_hover:
			# 悬停高亮：外扩一圈亮框，比改颜色更容易在密集处辨认
			var o := maxf(zoom * 0.35, 3.0)
			draw_rect(r.grow(o), Color(1, 1, 1, 0.95), false, 2.0)
		# U-19：小 zoom 下 id 标签互相压字——放大到可读才画
		if zoom >= 8.0:
			draw_string(ThemeDB.fallback_font, r.position + Vector2(0, -6),
				str(e.get("id", "")), HORIZONTAL_ALIGNMENT_LEFT, -1,
				Th.FS_META, Color(1, 1, 1, 0.95))

	# 出生点：白框
	var sp: Array = data.get("spawn", [2, 2])
	var sp_rect := Rect2(origin + Vector2(int(sp[0]), int(sp[1])) * zoom, Vector2(zoom, zoom))
	draw_rect(sp_rect, Color(1, 1, 1, 0.75), false, 1.5)

	# 地图边界
	draw_rect(map_rect, Th.MAP_BORDER, false, 2.0)

	# 悬停格：黄框（缩放小时也至少 6px，保证看得见）
	if _hover.x >= 0 and _hover.x < ms.x and _hover.y >= 0 and _hover.y < ms.y:
		var hr := Rect2(origin + Vector2(_hover) * zoom, Vector2(zoom, zoom))
		draw_rect(hr, Th.MAP_HOVER_FILL, true)
		draw_rect(hr, Th.MAP_HOVER, false, 2.0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _cell_at(event.position)
		var e2 := _ent_at(_hover)
		_hover_ent = e2
		if e2.is_empty():
			hover_info.emit("(%d, %d)" % [_hover.x, _hover.y])
		else:
			hover_info.emit("%s · %s (%d, %d)" % [
				str(e2.get("id", "")), str(e2.get("scene", "")), _hover.x, _hover.y])
		if _panning:
			pan = _pan_origin - (event.position - _pan_from) / zoom
			_clamp_pan()
		queue_redraw()
		return

	if event is InputEventMouseButton:
		# 滚轮缩放：浮点锚点——缩放前后保持光标下的地图点不动（BUG-13）。
		# 旧实现 pan += after − before 用了取整格坐标且符号反了：地图超出视口后
		# 缩放会被钉死在边界。cell = pan + local/zoom，要 cell 不变 ⇒ pan += local/z0 − local/z1。
		if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP
				or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var local: Vector2 = event.position
			var z0 := zoom
			var k := 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
			zoom = clampf(zoom * k, min_zoom, MAX_ZOOM)
			if not is_equal_approx(zoom, z0):
				pan += local / z0 - local / zoom
				_clamp_pan()
			_hover = _cell_at(event.position)
			queue_redraw()
			return
		# 中键 / 右键拖拽平移
		if event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_panning = true
				_pan_from = event.position
				_pan_origin = pan
			else:
				_panning = false
			return
		# 左键点选
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var cell := _cell_at(event.position)
			var ms := _map_size()
			if cell.x < 0 or cell.y < 0 or cell.x >= ms.x or cell.y >= ms.y:
				return   # 点在地图外：忽略，避免误建落点
			var e3 := _ent_at(cell)
			if on_pick.is_valid():
				on_pick.call(cell, str(e3.get("id", "")), str(e3.get("scene", "")))
