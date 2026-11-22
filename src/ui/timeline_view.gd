extends Control
class_name TimelineView
## 时间轴视图：步骤 = 横轴时间、纵轴轨道的条块。
## 只负责呈现与拖拽；数据与写盘归 content_editor（视图直接读写同一份 steps 数组）。
##
## 交互：点条块选中（发 picked）；拖条块左右改 at、拖右缘改 duration、上下拖换轨；
## 落定（松手）发一次 changed，由宿主净化回写盘。吸附件随功能声明 timebase
## （seconds 0.1 / frames 1 / beats 1/subdivisionsPerBeat），负值夹回 0。

const Th := preload("res://src/ui/ui_theme.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")

## 拖拽落定后发一次：宿主按步骤身份 + 结构版本校验后合并补丁（D1）。
## revision = set_steps 时宿主给的结构版本（拖动起手即固定）；宿主据此丢弃过期请求。
signal step_change_requested(index: int, revision: int, patch: Dictionary)
## 点中条块（含拖动起始）后发；-1 = 点到空白处取消选中。
signal picked(index: int)
## 播放头移动（原始单位）：首版只做定位与对齐，不触发游戏判定（D2）。
signal playhead_changed(value: float)

## 引擎给的数据（只读）：宿主传工作副本；视图不再直接改它——
## 拖动期间只画预览偏移，松手交补丁给宿主统一合并/净化/写盘。
var steps: Array = []
var name_of: Callable = Callable()   # 步骤码 -> 显示名（Callable 返回 String）
var sel := -1                        # 当前选中步骤下标；-1 = 无
var struct_rev := 0                  # 数据源结构版本（宿主增删/排序后变化）

const SNAP := {"seconds": 0.1, "frames": 1.0, "beats": 0.25}   # 吸附粒度按时间基
const MARGIN_L := 10.0
const RULER_H := 16.0
const TRACK_H := 26.0
const EDGE := 7.0      # 右缘拖拽热区宽

var timebase := "seconds"   # R-10：seconds（缺省）/ frames / beats——刻度/吸附单位随声明
var _pps := 64.0              # 像素/单位（set_timebase 按基设）
var clock = null              # TimelineClock（D2）：秒换算/吸附粒度；null = 按时间基缺省
var playhead := 0.0           # 播放头（原始单位）；首版只定位，不调用游戏判定
var _drag := ""               # "" / "move" / "resize"
var _drag_idx := -1
var _drag_off_x := 0.0
var _drag_orig := {}          # 拖动起手的生效区间 {at,track,duration}
var _preview := {}            # 拖动中的预览值 {at,track,duration}（只画，不写数据）
var _moved := false

func set_steps(arr: Array, name_of_cb: Callable, rev := 0) -> void:
	steps = arr
	name_of = name_of_cb
	struct_rev = rev
	_drag = ""
	_drag_idx = -1
	_preview = {}
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

## R-10：按声明时间基设刻度/吸附/像素密度（数据形态 at/duration 不变，游戏侧按声明解释单位）
func set_timebase(tb: String) -> void:
	timebase = tb if SNAP.has(tb) else "seconds"
	_pps = {"seconds": 64.0, "frames": 12.0, "beats": 48.0}.get(timebase, 64.0)
	queue_redraw()

## D2：绑定换算时钟；吸附粒度改由时钟的声明细分决定（拍按 subdivisionsPerBeat）。
func set_clock(c) -> void:
	clock = c
	queue_redraw()

func _snap(v: float) -> float:
	var step := float(SNAP.get(timebase, 0.1))
	if clock != null and (clock as Object).has_method("snap_step"):
		step = float(clock.snap_step())
	return snappedf(maxf(v, 0.0), step)

## 条块矩形（含选中/命中判定用）。拖动中的步骤用预览值（数据不动）。
func _block_rect(i: int) -> Rect2:
	var e: Dictionary = _eff(i)
	if e.is_empty():
		return Rect2()
	if i == _drag_idx and not _preview.is_empty():
		e = {
			"at": float(_preview.get("at", e.get("at", 0.0))),
			"duration": float(_preview.get("duration", e.get("duration", 0.0))),
			"track": int(_preview.get("track", e.get("track", 0))),
		}
	var at := float(e.get("at", 0.0))
	var dur := maxf(float(e.get("duration", 0.0)), 0.0)
	var track := int(e.get("track", 0))
	var y := RULER_H + TRACK_H * float(track)
	var w := maxf(dur * _pps, 10.0)
	return Rect2(MARGIN_L + at * _pps, y + 3.0, w, TRACK_H - 6.0)

## 生效条目（含缺省展开）；越界/非对象返回 {}。
func _eff(i: int) -> Dictionary:
	return StepTimeline.effective(steps, i)

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
	# 标尺区（顶部 RULER_H 内）= 播放头定位：首版只读时间，不调用游戏判定（D2）
	if p.y < RULER_H:
		playhead = _snap((p.x - MARGIN_L) / _pps)
		_drag = "scrub"
		_drag_idx = -1
		_moved = false
		playhead_changed.emit(playhead)
		queue_redraw()
		return
	var i := _hit(p)
	if i < 0:
		if sel != -1:
			sel = -1
			picked.emit(-1)
			queue_redraw()
		return
	sel = i
	_drag_idx = i
	# 起手快照 = 生效区间（缺省展开后的值）；拖拽增量基于它算，松手交补丁
	_drag_orig = _eff(i).duplicate(true)
	_preview = {}
	if p.x > _block_rect(i).end.x - EDGE:
		_drag = "resize"
	else:
		_drag = "move"
		_drag_off_x = p.x - _block_rect(i).position.x
	_moved = false
	picked.emit(i)
	queue_redraw()

## 当前步骤的工作副本数据（步骤不是对象时返回 {}）。
func _step(i: int) -> Dictionary:
	return steps[i] if i >= 0 and i < steps.size() and steps[i] is Dictionary else {}

func _motion(p: Vector2) -> void:
	if _drag == "scrub":
		playhead = _snap((p.x - MARGIN_L) / _pps)
		playhead_changed.emit(playhead)
		queue_redraw()
		return
	if _drag_idx < 0 or _drag_idx >= steps.size():
		return
	var orig := _drag_orig
	if orig.is_empty():
		return
	if _drag == "move":
		var at := _snap((p.x - MARGIN_L - _drag_off_x) / _pps)
		var track := clampi(int(floorf((p.y - RULER_H) / TRACK_H)), 0, maxi(_track_count(), 1) - 1)
		_preview = {"at": at, "track": track, "duration": float(orig.get("duration", 0.0))}
		_moved = true
	elif _drag == "resize":
		var at0 := float(orig.get("at", 0.0))
		# 右缘拖拽：先求绝对终点再减起点——终点被吸附到格，时长随之为合成值
		var end := _snap((p.x - MARGIN_L) / _pps)
		var dur := maxf(end - at0, _snap(0.0))
		_preview = {"at": at0, "track": int(orig.get("track", 0)), "duration": dur}
		_moved = true
	queue_redraw()

## 松手：有位移就把预览差值作为补丁发给宿主（只含真正变了的键）。
func _release() -> void:
	if _drag == "":
		return
	var idx := _drag_idx
	var moved := _moved
	var patch := {}
	if moved and not _preview.is_empty():
		for k in ["at", "duration", "track"]:
			if _preview.has(k) and not is_equal_approx(float(_preview[k]), float(_drag_orig.get(k, 0.0))):
				patch[k] = _preview[k]
	_drag = ""
	_drag_idx = -1
	_preview = {}
	_moved = false
	if moved and not patch.is_empty():
		step_change_requested.emit(idx, struct_rev, patch)
	queue_redraw()

func _draw() -> void:
	var fnt: Font = ThemeDB.fallback_font
	# 滚动容器按内容宽撑开：视图自身尺寸 = max(容器给宽, 内容宽)
	var w := maxf(size.x, fit_width())
	var tracks := _track_count()
	# 主刻度：每单位一格 + 单位标签（frames 每 5 帧一档防挤）
	var tstep := 5 if timebase == "frames" else 1
	var suffix: String = {"seconds": "s", "frames": "f", "beats": "拍"}.get(timebase, "s")
	# 拍基细分（subdivisionsPerBeat）：每拍内画 n−1 条浅线，主刻度仍是「拍」
	if timebase == "beats" and clock != null and (clock as Object).has_method("snap_step"):
		var sub := float(clock.snap_step())
		var per := int(roundf(1.0 / sub)) if sub > 0.0 else 1
		if per > 1:
			var k := 1
			while float(k) * sub <= _time_max():
				if k % per != 0:   # 整拍处由主刻度画
					var xs := MARGIN_L + float(k) * sub * _pps
					draw_line(Vector2(xs, RULER_H * 0.55), Vector2(xs, fit_height()), Th.BORDER, 1.0)
				k += 1
	for t in range(0, int(_time_max()) + 1, tstep):
		var x := MARGIN_L + float(t) * _pps
		draw_line(Vector2(x, 0), Vector2(x, fit_height()), Th.BORDER, 1.0)
		draw_string(fnt, Vector2(x + 2, RULER_H - 4), "%s%s" % [t, suffix],
			HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_META, Th.TEXT_MUTE)
	# 轨道分隔线
	for k in tracks + 1:
		var y := RULER_H + TRACK_H * float(k)
		draw_line(Vector2(0, y), Vector2(w, y), Th.BORDER, 1.0)
	# 播放头（D2）：标尺上点/拖定位；只画线+读数，不做游戏判定
	var phx := MARGIN_L + playhead * _pps
	# 先记下位置，条块画完再叠播放头（否则会被条块盖住）
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
	# 播放头叠在条块之上（否则会被填充盖住）：竖线 + 秒读数（D2）
	draw_line(Vector2(phx, 0), Vector2(phx, fit_height()), Th.ERR, 1.5)
	if clock != null and (clock as Object).has_method("seconds_at"):
		var sec := float(clock.seconds_at(playhead))
		draw_string(fnt, Vector2(phx + 3, RULER_H + 12), "%.2fs" % sec,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_META, Th.ERR)
