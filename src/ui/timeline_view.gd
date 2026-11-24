extends Control
class_name TimelineView
## 时间轴视图：步骤 = 横轴时间、纵轴轨道的条块。
## 只负责呈现与拖拽；数据与写盘归 content_editor。视图读同一份步骤数组，
## 但改动只走「松手发补丁 → 宿主合并回写」，自己从不直接改数据（见下方 steps 注释）。
##
## 交互：点条块选中（发 picked）；拖条块左右改 at、拖右缘改 duration、上下拖换轨；
## 落定（松手）发一次 changed，由宿主净化回写盘。吸附件随功能声明 timebase
## （seconds 0.1 / frames 1 / beats 1/subdivisionsPerBeat），负值夹回 0。

const Th := preload("res://src/ui/ui_theme.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")
const StepIntervalIndex := preload("res://src/content/step_interval_index.gd")

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
var playhead := 0.0           # 播放头（原始单位）
var _audio_length := 0.0
var _waveform := PackedVector2Array()
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
	_tl_cache_key = ""
	sync_min_size()
	queue_redraw()

## 按当前数据把 custom_minimum_size 撑到内容尺寸（滚动容器据此出滚动条）。
func sync_min_size() -> void:
	custom_minimum_size = Vector2(fit_width(), fit_height())

## P02：生效区间表一帧/一次改动只算一遍。拖动中只画预览偏移、数据不动，
## 所以按「数据引用 + 结构版本」缓存就够：宿主换数据或增删步骤必换引用/版本。
var _tl_cache: Array = []
var _tl_cache_key := ""
var _max_time := 2.0
var _tracks := 1
var _intervals := StepIntervalIndex.new()
var _step_names := {}
## 冲突集合按生效区间缓存，仅在数据改变后重算。
var _hot_cache := {}
var _hot_cache_key := ""

func _timeline() -> Array:
	var key := "%d:%d" % [steps.size(), struct_rev]
	if key == _tl_cache_key:
		return _tl_cache
	_tl_cache = StepTimeline.to_timeline(steps)
	_max_time = 2.0
	_tracks = 1
	_step_names.clear()
	for i in _tl_cache.size():
		var e: Dictionary = _tl_cache[i]
		if e.is_empty():
			continue
		var track := int(e.track)
		_max_time = maxf(_max_time, float(e.at) + float(e.duration))
		_tracks = maxi(_tracks, track + 1)
	_intervals.rebuild(_tl_cache, _pps, MARGIN_L)
	_tl_cache_key = key
	_hot_cache_key = ""   # 区间表换了，冲突集合必然重算
	return _tl_cache

## 冲突步骤集合 {下标: true}：按区间表版本缓存（P02）。
func _hot_blocks() -> Dictionary:
	if _hot_cache_key == _tl_cache_key and not _tl_cache_key.is_empty():
		return _hot_cache
	_hot_cache = StepTimeline.overlap_summary(_timeline()).hot
	_hot_cache_key = _tl_cache_key
	return _hot_cache

## 时间轴总时长（视图宽度口径）：末尾再加 1 秒留白，至少 2 秒。
func _time_max() -> float:
	_timeline()
	return maxf(_max_time, float(clock.value_at(_audio_length))) if _audio_length > 0.0 and clock != null else _max_time

func _track_count() -> int:
	_timeline()
	return _tracks

## 最小高度 = 标尺 + 轨道数 × 行高；宿主把它塞进 custom_minimum_size。
func fit_height() -> float:
	return RULER_H + TRACK_H * float(_track_count()) + 4.0

## 宽度 = 内容宽 + 右留白（ScrollContainer 里用）。
func fit_width() -> float:
	return MARGIN_L + _time_max() * _pps + 24.0

## R-10：按声明时间基设刻度/吸附/像素密度（数据形态 at/duration 不变，游戏侧按声明解释单位）
func set_timebase(tb: String) -> void:
	timebase = tb if SNAP.has(tb) else "seconds"
	var scale := float({"seconds": 64.0, "frames": 12.0, "beats": 48.0}[timebase])
	if scale != _pps:
		_pps = scale
		_tl_cache_key = ""
	queue_redraw()

## D2：绑定换算时钟；吸附粒度改由时钟的声明细分决定（拍按 subdivisionsPerBeat）。
func set_clock(c) -> void:
	clock = c
	queue_redraw()

func set_reference_audio(seconds: float, envelope: PackedVector2Array) -> void:
	if _audio_length == seconds and is_same(_waveform, envelope):
		return
	_audio_length = seconds
	_waveform = envelope
	sync_min_size()
	queue_redraw()

func follow_playhead() -> void:
	var scroll := _scroll_container()
	if scroll == null:
		return
	var x := MARGIN_L + playhead * _pps
	if x < scroll.scroll_horizontal or x > scroll.scroll_horizontal + scroll.size.x - 8:
		scroll.scroll_horizontal = maxi(0, roundi(x - scroll.size.x * 0.2))

func reveal_step(index: int) -> void:
	var scroll := _scroll_container()
	var block := _block_rect(index)
	if scroll == null or block.size == Vector2.ZERO:
		return
	var view := _visible_rect()
	if block.position.x < view.position.x or block.position.x + StepIntervalIndex.MIN_BLOCK_WIDTH > view.end.x:
		scroll.scroll_horizontal = maxi(0, roundi(block.position.x - view.size.x * 0.2))
	if block.position.y < view.position.y or block.end.y > view.end.y:
		scroll.scroll_vertical = maxi(0, roundi(block.position.y - TRACK_H))

func _draw_reference_audio(lo: float, hi: float) -> void:
	if _waveform.is_empty() or clock == null or _audio_length <= 0.0:
		return
	var x0 := floori(MARGIN_L + lo * _pps)
	var x1 := ceili(MARGIN_L + hi * _pps)
	for px in range(x0, x1, 2):
		var raw := maxf(0.0, (float(px) - MARGIN_L) / _pps)
		var sec := float(clock.seconds_at(raw))
		if sec < 0.0 or sec >= _audio_length:
			continue
		var bucket := mini(_waveform.size() - 1, int(sec / _audio_length * _waveform.size()))
		var peak := _waveform[bucket]
		var mid := RULER_H * 0.58
		draw_line(Vector2(px, mid - peak.y * 6.0), Vector2(px, mid - peak.x * 6.0), Color(Th.ACCENT, 0.45))

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
	var w := maxf(dur * _pps, StepIntervalIndex.MIN_BLOCK_WIDTH)
	return Rect2(MARGIN_L + at * _pps, y + 3.0, w, TRACK_H - 6.0)

## 生效条目（含缺省展开）；越界/非对象返回 {}。走缓存表（P02：不再每块重算整份）。
func _eff(i: int) -> Dictionary:
	var tl := _timeline()
	if i < 0 or i >= tl.size():
		return {}
	return tl[i]

func _hit(pos: Vector2) -> int:
	_timeline()
	var track := int(floorf((pos.y - RULER_H) / TRACK_H))
	var candidates: Array[int] = []
	_intervals.query(track, pos.x, pos.x, candidates)
	if _drag_idx >= 0:
		candidates.append(_drag_idx)
	var hit := -1
	for i in candidates:
		if (hit < 0 or i < hit) and _block_rect(i).has_point(pos):
			hit = i
	return hit

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

func reject_pick(previous: int) -> void:
	sel = previous
	_drag = ""
	_drag_idx = -1
	_preview = {}
	_moved = false
	queue_redraw()

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

## P02：可视时间区间（原始单位）[lo, hi]。视图在 ScrollContainer 里滚动，
## 自身坐标原点是内容原点，所以可视段 = (滚动偏移, 滚动偏移 + 视宽)。
## 取不到父滚动容器（单测/未进树）时退化为整条轴。
func _scroll_container() -> ScrollContainer:
	var p := get_parent()
	while p != null:
		if p is ScrollContainer:
			return p
		p = p.get_parent()
	return null

func _ready() -> void:
	var scroll := _scroll_container()
	if scroll != null:
		scroll.get_h_scroll_bar().value_changed.connect(func(_x: float): queue_redraw())
		scroll.get_v_scroll_bar().value_changed.connect(func(_y: float): queue_redraw())
		scroll.resized.connect(queue_redraw)

func _visible_rect() -> Rect2:
	var scroll := _scroll_container()
	if scroll == null:
		return Rect2(Vector2.ZERO, size)
	return Rect2(Vector2(scroll.scroll_horizontal, scroll.scroll_vertical), scroll.size)

func _visible_blocks(view: Rect2, first_track: int, last_track: int) -> Array[int]:
	var visible: Array[int] = []
	for track in range(first_track, last_track + 1):
		_intervals.query(track, view.position.x, view.end.x, visible)
	if _drag_idx >= 0 and not visible.has(_drag_idx):
		visible.append(_drag_idx)
	visible.sort()
	return visible

func _draw() -> void:
	var fnt: Font = ThemeDB.fallback_font
	var tmax := _time_max()
	var tracks := _track_count()
	var view := _visible_rect()
	var vis_lo := maxf(0.0, (view.position.x - MARGIN_L) / _pps)
	var vis_hi := maxf(vis_lo, (view.end.x - MARGIN_L) / _pps)
	var first_track := maxi(0, floori((view.position.y - RULER_H) / TRACK_H))
	var last_track := mini(tracks - 1, floori((view.end.y - RULER_H) / TRACK_H))
	if view.position.y < RULER_H:
		_draw_reference_audio(vis_lo, minf(vis_hi, tmax))
	# 主刻度：每单位一格 + 单位标签（frames 每 5 帧一档防挤）
	var tstep := 5 if timebase == "frames" else 1
	var suffix: String = {"seconds": "s", "frames": "f", "beats": "拍"}.get(timebase, "s")
	# 拍基细分（subdivisionsPerBeat）：每拍内画 n−1 条浅线，主刻度仍是「拍」
	if timebase == "beats" and clock != null and (clock as Object).has_method("snap_step"):
		var sub := float(clock.snap_step())
		var per := int(roundf(1.0 / sub)) if sub > 0.0 else 1
		if per > 1:
			var k := maxi(1, int(floorf(vis_lo / sub)))
			while float(k) * sub <= minf(tmax, vis_hi + sub):
				if k % per != 0:   # 整拍处由主刻度画
					var xs := MARGIN_L + float(k) * sub * _pps
					draw_line(Vector2(xs, maxf(RULER_H * 0.55, view.position.y)), Vector2(xs, view.end.y), Th.BORDER, 1.0)
				k += 1
	var t0 := int(floorf(vis_lo / float(tstep))) * tstep
	for t in range(maxi(0, t0), int(minf(tmax, vis_hi)) + 1, tstep):
		var x := MARGIN_L + float(t) * _pps
		draw_line(Vector2(x, view.position.y), Vector2(x, view.end.y), Th.BORDER, 1.0)
		if view.position.y < RULER_H:
			draw_string(fnt, Vector2(x + 2, RULER_H - 4), "%s%s" % [t, suffix],
				HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_META, Th.TEXT_MUTE)
	# 轨道分隔线
	for k in range(first_track, last_track + 2):
		var y := RULER_H + TRACK_H * float(k)
		draw_line(Vector2(view.position.x, y), Vector2(view.end.x, y), Th.BORDER, 1.0)
	# 播放头（D2）：标尺上点/拖定位；只画线+读数，不做游戏判定
	var phx := MARGIN_L + playhead * _pps
	# 先记下位置，条块画完再叠播放头（否则会被条块盖住）
	# 条块：选中高亮、冲突描红、瞬发画细条（P02：冲突基于同一份缓存区间表）
	var hot := _hot_blocks()
	for i in _visible_blocks(view, first_track, last_track):
		var r := _block_rect(i)
		var sc := str((steps[i] as Dictionary).get("step", ""))
		if not _step_names.has(sc):
			_step_names[sc] = str(name_of.call(sc)) if name_of.is_valid() else sc
		var nm: String = _step_names[sc]
		var known := nm != sc
		var base := Th.ACCENT_BG if known else Th.BG_HOVER
		var fill := base
		var border := Th.ACCENT if known else Th.WARN
		if hot.has(i):
			border = Th.ERR
		if i == sel:
			border = Th.ACCENT_HI
		draw_rect(r, fill, true)
		draw_rect(r, border, false, 1.5)
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
