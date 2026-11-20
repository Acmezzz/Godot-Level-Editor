extends Control
class_name TimelineView
## 时间轴视图：步骤 = 横轴时间、纵轴轨道的条块。
## 只负责呈现与拖拽；数据与写盘归 content_editor（视图直接读写同一份 steps 数组）。
##
## 交互：点条块选中（发 picked）；拖条块左右改 at、拖右缘改 duration、上下拖换轨；
## 落定（松手）发一次 changed，由宿主净化回写盘。0.1 秒吸附，0 起步不为负。

const Th := preload("res://src/ui/ui_theme.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")

## 松手后发：宿主据此 from_timeline 净化并写盘 + 刷新。
signal changed
## 点中条块（含拖动起始）后发；-1 = 点到空白处取消选中。
signal picked(index: int)

var steps: Array = []                # 直引用宿主的内容 steps 数组（拖拽就地改）
var name_of: Callable = Callable()   # 步骤码 -> 显示名（Callable 返回 String）
var sel := -1                        # 当前选中步骤下标；-1 = 无

const SNAP := 0.1      # 秒
const MARGIN_L := 10.0
const RULER_H := 16.0
const TRACK_H := 26.0
const EDGE := 7.0      # 右缘拖拽热区宽

var _pps := 64.0              # 像素/秒
var _drag := ""               # "" / "move" / "resize"
var _drag_idx := -1
var _drag_off_x := 0.0
var _drag_orig := {}          # 拖动起点的 at/track/duration 快照（未移动就还原）
var _moved := false

func set_steps(arr: Array, name_of_cb: Callable) -> void:
	steps = arr
	name_of = name_of_cb
	_drag = ""
	_drag_idx = -1
	sync_min_size()
	queue_redraw()

## 按当前数据把 custom_minimum_size 撑到内容尺寸（滚动容器据此出滚动条）。
func sync_min_size() -> void:
	custom_minimum_size = Vector2(fit_width(), fit_height())

## 时间轴总时长（视图宽度口径）：末尾再加 1 秒留白，至少 2 秒。
func _time_max() -> float:
	var t := 2.0
	var tl := StepTimeline.to_timeline(steps)
	for e in tl:
		var end_t := float(e.get("at", 0.0)) + float(e.get("duration", 0.0))
		t = maxf(t, end_t)
	return t

func _track_count() -> int:
	var n := 1
	var tl := StepTimeline.to_timeline(steps)
	for e in tl:
		n = maxi(n, int(e.get("track", 0)) + 1)
	return n

## 最小高度 = 标尺 + 轨道数 × 行高；宿主把它塞进 custom_minimum_size。
func fit_height() -> float:
	return RULER_H + TRACK_H * float(_track_count()) + 4.0

## 宽度 = 内容宽 + 右留白（ScrollContainer 里用）。
func fit_width() -> float:
	return MARGIN_L + _time_max() * _pps + 24.0

func _snap(v: float) -> float:
	return snappedf(maxf(v, 0.0), SNAP)

## 条块矩形（含选中/命中判定用）。
func _block_rect(i: int) -> Rect2:
	var tl := StepTimeline.to_timeline(steps)
	if i < 0 or i >= tl.size():
		return Rect2()
	var e: Dictionary = tl[i]
	var at := float(e.get("at", 0.0))
	var dur := maxf(float(e.get("duration", 0.0)), 0.0)
	var track := int(e.get("track", 0))
	var y := RULER_H + TRACK_H * float(track)
	var w := maxf(dur * _pps, 10.0)
	return Rect2(MARGIN_L + at * _pps, y + 3.0, w, TRACK_H - 6.0)

func _hit(pos: Vector2) -> int:
	for i in steps.size():
		if _block_rect(i).has_point(pos):
			return i
	return -1

func _gui_input(ev: InputEvent) -> void:
	var handled := false
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press(mb.position)
			else:
				_release()
			handled = true
	elif ev is InputEventMouseMotion and _drag != "":
		_motion(ev.position)
		handled = true
	# 滚轮等未处理事件放行给宿主滚动容器
	if handled:
		accept_event()

func _press(p: Vector2) -> void:
	var i := _hit(p)
	if i < 0:
		if sel != -1:
			sel = -1
			picked.emit(-1)
			queue_redraw()
		return
	sel = i
	_drag_idx = i
	var r := _block_rect(i)
	if p.x > r.end.x - EDGE:
		_drag = "resize"
		_drag_orig = {"at": _cur_at(i), "track": _cur_track(i), "duration": _cur_dur(i)}
	else:
		_drag = "move"
		_drag_off_x = p.x - r.position.x
		_drag_orig = {"at": _cur_at(i), "track": _cur_track(i), "duration": _cur_dur(i)}
	_moved = false
	picked.emit(i)
	queue_redraw()

## 就地读写当前步骤的时间轴键（视图直改宿主数组；写盘由宿主在 changed 后统一做）。
func _cur_at(i: int) -> float:
	return float(_step(i).get("at", 0.0))

func _cur_track(i: int) -> int:
	return int(_step(i).get("track", 0))

func _cur_dur(i: int) -> float:
	return float(_step(i).get("duration", 0.0))

func _step(i: int) -> Dictionary:
	return steps[i] if i >= 0 and i < steps.size() and steps[i] is Dictionary else {}

func _motion(p: Vector2) -> void:
	if _drag_idx < 0 or _drag_idx >= steps.size():
		return
	var st: Dictionary = steps[_drag_idx]
	if not (st is Dictionary):
		return
	if _drag == "move":
		var at := _snap((p.x - MARGIN_L - _drag_off_x) / _pps)
		if not is_equal_approx(_cur_at(_drag_idx), at):
			st["at"] = at
			_moved = true
		var track := clampi(int(floorf((p.y - RULER_H) / TRACK_H)), 0, _track_count() - 1)
		if _cur_track(_drag_idx) != track:
			st["track"] = track
			_moved = true
	elif _drag == "resize":
		var at0 := _snap(float(_drag_orig.get("at", 0.0)))
		var dur := _snap((p.x - MARGIN_L) / _pps - at0)
		if dur > 0.0 and not is_equal_approx(_cur_dur(_drag_idx), dur):
			st["duration"] = dur
			_moved = true
	queue_redraw()

func _release() -> void:
	if _drag == "":
		return
	var moved := _moved
	_drag = ""
	_drag_idx = -1
	if moved:
		changed.emit()

func _draw() -> void:
	var fnt: Font = ThemeDB.fallback_font
	# 滚动容器按内容宽撑开：视图自身尺寸 = max(容器给宽, 内容宽)
	var w := maxf(size.x, fit_width())
	var tracks := _track_count()
	# 顶标尺：每秒一格 + 秒数标签
	for t in int(_time_max()) + 1:
		var x := MARGIN_L + float(t) * _pps
		draw_line(Vector2(x, 0), Vector2(x, fit_height()), Th.BORDER, 1.0)
		draw_string(fnt, Vector2(x + 2, RULER_H - 4), "%ds" % t,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_META, Th.TEXT_MUTE)
	# 轨道分隔线
	for k in tracks + 1:
		var y := RULER_H + TRACK_H * float(k)
		draw_line(Vector2(0, y), Vector2(w, y), Th.BORDER, 1.0)
	# 条块：选中高亮、冲突描红、瞬发画细条
	var cf := StepTimeline.conflicts(steps)
	var hot := {}
	for pair in cf:
		hot[int((pair as Dictionary).get("a", -1))] = true
		hot[int((pair as Dictionary).get("b", -1))] = true
	for i in steps.size():
		if not (steps[i] is Dictionary):
			continue
		var r := _block_rect(i)
		var sc := str((steps[i] as Dictionary).get("step", ""))
		var known: bool = name_of.is_valid() and str(name_of.call(sc)) != sc
		var base := Th.ACCENT_BG if known else Th.BG_HOVER
		var fill := base
		var border := Th.ACCENT if known else Th.WARN
		if hot.has(i):
			border = Th.ERR
		if i == sel:
			border = Th.ACCENT_HI
		draw_rect(r, fill, true)
		draw_rect(r, border, false, 1.5)
		var nm := str(name_of.call(sc)) if name_of.is_valid() else sc
		var lbl := ("⚠ " + sc) if not known else nm
		var pad := 4.0
		if r.size.x > 26.0:
			draw_string(fnt, r.position + Vector2(pad, r.size.y - pad),
				lbl, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - pad * 2.0, Th.FS_META, Th.TEXT)
