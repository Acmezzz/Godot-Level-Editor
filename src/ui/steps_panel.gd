extends RefCounted
## 演出子面板：从 content_editor.gd 拆出的控制器。宿主 = content_editor 实例（host 引用）。
## 搬迁约定：函数体逐字节原样迁入；跨边界引用经 host 转发——
## 同名 const 重声明 + 同名转发属性 + 同名包装方法，搬动文本零改动。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const TimelineClock := preload("res://src/content/timeline_clock.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const EntityNodeRef := preload("res://src/canvas/entity_node.gd")

var host   # content_editor 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
var _pending_commits: Array:
	get: return host._pending_commits

## 同名包装方法（真实实现经 host 转发）
func commit() -> bool:
	return host.commit()
func _current_fns() -> Array:
	return host._current_fns()
func _ensure_content(i: int) -> String:
	return host._ensure_content(i)
func _ensure_failed() -> void:
	host._ensure_failed()
func _refresh_status_only() -> void:
	host._refresh_status_only()
func _resolve_fn(f: Dictionary) -> Dictionary:
	return host._resolve_fn(f)
func _resolve_options(decl: Dictionary) -> Array:
	return host._resolve_options(decl)
func _rebuild_right() -> void:
	host._rebuild_right()

var _steps_pop: PopupPanel = null
var _steps_i := -1            # 正在编辑的绑定行下标
var _steps_fn_id := ""        # 该绑定的功能 id
var _steps_cid := ""          # 该绑定的内容 ID（身份校验：绑定换内容 = 数据源失效）
var _steps_rev := 0           # 结构版本：增删/排序后递增，过期控件回调据此丢弃（D1）
var _steps_sel := -1          # 当前选中步骤下标；-1 = 无
var _steps_list: VBoxContainer = null
var _steps_form: VBoxContainer = null
var _steps_warn_box: VBoxContainer = null
# 时间轴视图页签（第 4 批）：同一份 steps，两种呈现。
var _steps_view := "list"     # "list" / "timeline"
var _steps_tabs: HBoxContainer = null
var _steps_tl_box: VBoxContainer = null
var _steps_scroll: ScrollContainer = null
var _steps_tl: TimelineView = null
var _steps_tl_rev := -1       # 时间轴视图绑定的结构版本
var _steps_clock = null       # TimelineClock（D2）：秒换算/吸附粒度
var _steps_clock_missing: Array = []   # 声明了但解析不到的参考项（表单显示，不阻断编辑）
var _steps_preview_asset := ""         # frameAssetField 解析出的资产码（帧基预览用）
var _steps_preview_frames: Array = []   # 该资产的帧序列（相对路径）
var _steps_preview_idx := -1            # 当前预览帧（播放头所在帧）
var _steps_audio := ""                  # audioField 解析出的音频码（只显示，不播放）
var _steps_frame_holder: Control = null  # 参考帧预览行（播放头移动时只刷这一行）
var _steps_playhead_label: Label = null  # 播放头读数（原始单位 → 秒；负秒 = 音频起点前）

## 打开演出子面板：绑定已有内容就地编辑；空绑定**首次实际改动才预留内容 ID**（D1/A2）。
func _open_steps_editor(i: int) -> void:
	host.commit_fields()   # 主表单待提交值先落盘：子面板写盘不该挤掉未提交值
	var fns := _current_fns()
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	if fn_id == "":
		return
	_steps_i = i
	_steps_fn_id = fn_id
	_steps_cid = str(f.get("content", ""))
	_steps_rev = 0
	_steps_sel = -1
	_steps_view = "list"
	_steps_clock = null
	_steps_clock_missing = []
	_steps_preview_asset = ""
	_steps_preview_frames = []
	_steps_preview_idx = -1
	_steps_audio = ""
	var shell: Dictionary = app._popup_body("演出编辑：%s" % FunctionDecls.function_name(manifest, fn_id),
		"步骤按 at/duration/track 排布；列表保序、时间轴可拖")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	_steps_pop = pop
	_steps_list = Kit.vbox(4)
	_steps_tl_box = Kit.vbox(4)
	_steps_form = Kit.vbox(6)
	_build_steps_tabs(body)
	body.add_child(_steps_list)
	body.add_child(_steps_tl_box)
	body.add_child(Kit.divider())
	body.add_child(_steps_form)
	# 时间轴视图建一次、反复复用（set_steps 换数据源）；滚动容器兜住超宽/超高的排布
	_steps_tl = TimelineView.new()
	_steps_tl.set_steps([], _step_name_of)
	_steps_tl.picked.connect(func(idx: int): _steps_pick_tl(idx))
	# 视图按起手时的结构版本发请求：宿主据此丢弃过期拖拽（D1）
	_steps_tl.step_change_requested.connect(func(idx: int, revision: int, patch: Dictionary):
		_on_step_change_requested(idx, revision, patch))
	_steps_tl.playhead_changed.connect(func(v: float): _on_playhead_changed(v))
	_steps_scroll = ScrollContainer.new()
	_steps_scroll.custom_minimum_size = Vector2(0, 120)
	_steps_scroll.add_child(_steps_tl)
	_steps_tl_box.add_child(_steps_scroll)
	pop.popup_hide.connect(func(): _rebuild_right())
	_rebuild_steps_all()
	app._open_popup(pop)

## 页签：列表 / 时间轴。同一份数据，两种呈现。
func _build_steps_tabs(parent: Control) -> void:
	_steps_tabs = Kit.hbox(6)
	var grp := ButtonGroup.new()
	for pair in [["列表", "list"], ["时间轴", "timeline"]]:
		var b := Kit.button(str(pair[0]), func(): _set_steps_view(str(pair[1])), "ghost")
		b.toggle_mode = true
		b.button_group = grp
		b.set_meta("view", str(pair[1]))
		_steps_tabs.add_child(b)
	parent.add_child(_steps_tabs)

func _set_steps_view(mode: String) -> void:
	if mode != "list" and mode != "timeline":
		return
	# 切页签前先提交当前控件（D1）：待提交值属于旧下标，切完再落到新表单上会串步
	host.commit_fields()
	_steps_view = mode
	_rebuild_steps_all()

func _sync_steps_tabs() -> void:
	if _steps_tabs == null:
		return
	for c in _steps_tabs.get_children():
		var b := c as Button
		if b != null:
			b.button_pressed = str(b.get_meta("view", "")) == _steps_view

## 时间轴名称回调：未知码原样返回（视图据此画 ⚠）。
func _step_name_of(sc: String) -> String:
	var d: Dictionary = StepDecls.step_by_code(manifest, sc)
	return str(d.get("name", sc)) if not d.is_empty() else sc

## 功能声明 timebase（R-10 帧级时间轴）：seconds（缺省）/ frames / beats
func _steps_timebase() -> String:
	var fns: Dictionary = FunctionDecls.functions(manifest)
	var d = fns.get(_steps_fn_id, null)
	if not (d is Dictionary):
		return "seconds"
	return str((d as Dictionary).get("timebase", "seconds"))

## 时间轴点选：只换选中与表单，不重建视图（拖拽进行中 picked 会被发多次）。
func _steps_pick_tl(idx: int) -> void:
	# 换选中前提交旧步骤的待提交控件值（同 _steps_pick）
	host.commit_fields()
	_pending_commits.clear()
	_steps_sel = idx
	if _steps_tl != null and is_instance_valid(_steps_tl):
		_steps_tl.sel = idx
		_steps_tl.queue_redraw()
	_rebuild_steps_form_from_data()

## 身份校验：绑定行还在、功能 id 与内容 ID 都还是开面板时的那个（换内容 = 数据源失效）。
func _steps_identity_ok() -> bool:
	var fns := _current_fns()
	if _steps_i < 0 or _steps_i >= fns.size() or not (fns[_steps_i] is Dictionary):
		return false
	var f: Dictionary = fns[_steps_i]
	if str(_resolve_fn(f).get("id", "")) != _steps_fn_id:
		return false
	# 空绑定：会话内还没预留内容 ID，仍可写（首次实际改动才预留）
	return _steps_cid == "" or str(f.get("content", "")) == _steps_cid

## 工作副本读取：已绑定内容读磁盘/暂存；空绑定返回内存空壳（不落盘、不建 ID）。
func _steps_data() -> Dictionary:
	if not _steps_identity_ok():
		return {}
	if _steps_cid == "":
		return {"id": "", "function": FunctionDecls.fn_code(manifest, _steps_fn_id),
			"name": _steps_fn_id, "fields": {}, "steps": []}
	return host.read_content_staged(_steps_fn_id, _steps_cid)

## 工作副本写回：**首次实际改动时才预留内容 ID**（D1）；内容写盘失败给可见反馈。
func _steps_write(data: Dictionary) -> void:
	if not _steps_identity_ok():
		return
	if _steps_cid == "":
		# 空绑定：先预留（绑定行加 content、生成 staged 新 ID），再走同一写路径
		var cid := _ensure_content(_steps_i)
		if cid == "":
			_ensure_failed()
			return
		_steps_cid = cid
		if str(data.get("id", "")) == "":
			data["id"] = cid
	if not host.write_content_staged(_steps_fn_id, _steps_cid, data):
		_ensure_failed()

## 结构版本递增：增删/排序/复制后旧控件与旧拖拽请求一律失效（D1）。
func _bump_steps_rev() -> void:
	_steps_rev += 1
	_steps_tl_rev = -1

## 重建子面板：页签同步 + 列表/时间轴互斥重建 + 当前步骤表单。
func _rebuild_steps_all() -> void:
	if _steps_list == null or _steps_form == null:
		return
	_sync_steps_tabs()
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	_sync_steps_clock(data)
	if _steps_view == "timeline":
		_steps_list.visible = false
		_steps_tl_box.visible = true
		_rebuild_steps_tl(arr)
	else:
		_steps_tl_box.visible = false
		_steps_list.visible = true
		_rebuild_steps_list(arr)
	_rebuild_steps_form(arr)

## 步骤列表（列表视图）：空态 + 逐行渲染。
func _rebuild_steps_list(arr: Array) -> void:
	if _steps_list == null:
		return
	for c in _steps_list.get_children():
		_steps_list.remove_child(c)
		c.queue_free()
	if arr.is_empty():
		_steps_list.add_child(Kit.hint_label("（空演出：添加步骤开始排）", 320))
	var pool := StepDecls.steps(manifest)
	for si in arr.size():
		var st = arr[si]
		if not (st is Dictionary):
			continue
		_steps_list.add_child(_steps_row(si, st, pool))

## D2：按 timePreview 声明建换算时钟，并把参考素材（帧序列 / 音频）解析成界面可用的值。
## 缺项只记录在 _steps_clock_missing 里（表单显示），不阻断原单位编辑。
func _sync_steps_clock(data: Dictionary) -> void:
	if data.is_empty():
		# 数据源已失效（绑定换了）：不拿空内容解析缺项，免得报假警告
		_steps_clock = null
		_steps_clock_missing = []
		_steps_preview_asset = ""
		_steps_preview_frames = []
		_steps_audio = ""
		return
	var r: Dictionary = TimelineClock.from_decl(manifest, _steps_fn_id, data)
	_steps_clock = TimelineClock.new(str(r.get("timebase", "seconds")), r.get("cfg", {}))
	_steps_clock_missing = r.get("missing", [])
	var refs: Dictionary = r.get("refs", {})
	var fields: Dictionary = data.get("fields", {}) if data.get("fields", null) is Dictionary else {}
	# 参考帧序列：资产码 → 声明 frames[]（相对路径）；只在帧基下用得到
	_steps_preview_asset = str(fields.get(str(refs.get("frameAssetField", "")), ""))
	_steps_preview_frames = []
	if _steps_preview_asset != "":
		var ad: Dictionary = AssetDecl.by_id(manifest, _steps_preview_asset)
		var fr = ad.get("frames", null)
		if fr is Array:
			_steps_preview_frames = fr
	# 音频：只显示已选音频名，不加载不播放（D2 只做对齐参考）
	_steps_audio = str(fields.get(str(refs.get("audioField", "")), ""))
	if _steps_tl != null and is_instance_valid(_steps_tl):
		_steps_tl.set_clock(_steps_clock)

## 播放头移动：帧基下换算成整数帧号给表单预览；秒/拍基只显示时间换算。
## 只刷参考帧行与读数——整表重建会清掉用户正在输入的控件。
func _on_playhead_changed(v: float) -> void:
	_steps_preview_idx = int(floorf(v)) if _steps_clock != null and _steps_clock.timebase == "frames" else -1
	_fill_frame_preview()
	_fill_playhead_label(v)

## 播放头读数：原始单位 + 换算秒数。负秒（拍基首拍偏移前）标「音频起点前」。
func _fill_playhead_label(v: float) -> void:
	if _steps_playhead_label == null:
		return
	var tb: String = str(_steps_clock.timebase) if _steps_clock != null else "seconds"
	var unit: String = {"seconds": "s", "frames": "帧", "beats": "拍"}.get(tb, "s")
	var sec: float = float(_steps_clock.seconds_at(v)) if _steps_clock != null else v
	var tail := "（音频起点前，静音）" if sec < 0.0 else ""
	_steps_playhead_label.text = "播放头 %s %s → %.3f s%s" % [
		_num_text(v), unit, sec, tail]

## 时间轴视图：换数据源 + 选中态 + 滚动容器高度。
## 结构版本变了才 set_steps（换数据源并清拖拽）；版本没变只同步选中，不打断进行中的拖拽。
func _rebuild_steps_tl(arr: Array) -> void:
	if _steps_tl == null or not is_instance_valid(_steps_tl):
		return
	_steps_tl.set_timebase(_steps_timebase())
	if _steps_tl_rev != _steps_rev:
		_steps_tl.set_steps(arr, _step_name_of, _steps_rev)
		_steps_tl_rev = _steps_rev
	_steps_tl.sel = _steps_sel
	_steps_tl.sync_min_size()
	if _steps_scroll != null:
		_steps_scroll.custom_minimum_size = Vector2(0, minf(_steps_tl.fit_height() + 8.0, 220.0))

## 时间轴拖拽落定：**一次拖动 = 一次编辑**（D1）。补丁按步骤身份 + 结构版本校验后合并，
## 过期请求（期间增删/换序/换页签/换绑定）直接丢弃；合并只净化被编辑的键。
func _on_step_change_requested(idx: int, revision: int, patch: Dictionary) -> void:
	if revision != _steps_rev or not _steps_identity_ok():
		return   # 过期拖拽：结构已变，按下标写回会落到别的步骤上
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var res: Dictionary = StepTimeline.apply_patch(arr, idx, patch)
	if not bool(res.get("ok", false)):
		return
	data["steps"] = res.get("steps", arr)
	_steps_write(data)
	_steps_sel = idx
	_bump_steps_rev()
	_rebuild_steps_all()

## 表单重建（数据自取）：时间轴点选后只换表单、不动视图。
func _rebuild_steps_form_from_data() -> void:
	if _steps_form == null:
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	_sync_steps_clock(data)   # fps/偏移等参考值可能刚在别处改过，读数跟着更新
	_rebuild_steps_form(arr)

## 子面板里的一个步骤行：序号+名称（选中高亮）+ 上移/下移/复制/删除。
func _steps_row(si: int, st: Dictionary, _pool: Dictionary) -> Control:
	var sc := str(st.get("step", ""))
	var decl: Dictionary = StepDecls.step_by_code(manifest, sc)
	var known := not decl.is_empty()
	var nm := str(decl.get("name", sc)) if known else "（未声明的步骤 %s）" % sc
	var sel := _steps_sel == si
	var row := Kit.hbox(4)
	var mark := Kit.text_label("%d. %s" % [si + 1, nm],
		Th.TEXT if sel else Th.TEXT_DIM, Th.FS_SMALL)
	mark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 行可点：点步骤名选中该步，右侧表单跟着换（不必先按 ↑↓ 才能选）
	mark.mouse_filter = Control.MOUSE_FILTER_STOP
	mark.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_steps_pick(si))
	row.add_child(mark)
	if not known:
		row.add_child(Kit.hint_label("⚠", 20))
	row.add_child(Kit.button("↑", func(): _steps_move(si, -1), "ghost"))
	row.add_child(Kit.button("↓", func(): _steps_move(si, 1), "ghost"))
	row.add_child(Kit.button("复制", func(): _steps_dup(si), "ghost"))
	row.add_child(Kit.del_button(func(): _steps_del(si)))
	return row

## 点步骤名选中该步：右侧表单换到这一步（重建保持 _steps_sel 选中态）。
func _steps_pick(si: int) -> void:
	# 换选中前先提交当前表单控件：SpinBox 之类的待提交值属于旧步骤下标
	host.commit_fields()
	_pending_commits.clear()
	_steps_sel = si
	_rebuild_steps_all()

## 当前步骤表单：步骤类型选择 + 该步骤声明的字段 + 未声明键只读保留。
## 字段改动即时写盘，不重建表单（保持输入焦点，与主表单同一纪律）。
func _rebuild_steps_form(arr: Array) -> void:
	var box := _steps_form
	if box == null:
		return
	# 表单整片重建：待提交项绑定的是旧控件（旧步骤下标），重建后一律失效
	_pending_commits.clear()
	_steps_frame_holder = null   # 参考帧行随旧表单一起释放
	_steps_playhead_label = null
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	# 添加步骤：下拉选步骤池条目 → 追加到末尾
	var add_row := Kit.hbox(6)
	var pick := OptionButton.new()
	for sid in StepDecls.steps(manifest):
		var d: Dictionary = StepDecls.steps(manifest)[sid]
		pick.add_item(str(d.get("name", sid)))
		pick.set_item_metadata(pick.item_count - 1, str(d.get("code", "")))
	add_row.add_child(pick)
	var add_btn := Kit.button("添加步骤", func():
		if pick.selected < 0:
			return
		_steps_add(str(pick.get_item_metadata(pick.selected))))
	add_row.add_child(add_btn)
	box.add_child(add_row)
	# 时间轴警告（负 at/duration、同轨重叠）：只提示不阻断
	for wtext in StepTimeline.warnings(arr):
		box.add_child(Kit.hint_label("⚠ " + str(wtext), 320))
	# D2：参考时钟（缺项 / 小数帧待修 / 参考帧与音频）
	box.add_child(_steps_clock_box(arr))
	if _steps_sel < 0 or _steps_sel >= arr.size() or not (arr[_steps_sel] is Dictionary):
		if not arr.is_empty():
			box.add_child(Kit.hint_label("点上方一个步骤进行编辑", 320))
		return
	var st: Dictionary = arr[_steps_sel]
	var sc := str(st.get("step", ""))
	var decl: Dictionary = StepDecls.step_by_code(manifest, sc)
	if decl.is_empty():
		box.add_child(Kit.hint_label(
			"⚠ 步骤码 %s 不在清单声明里（声明被删/换码）。只读保留。" % sc, 320))
		return
	box.add_child(Kit.divider())
	box.add_child(Kit.section_header("第 %d 步：%s" % [_steps_sel + 1, str(decl.get("name", sc))]))
	# 时间与轨道（D1）：与时间轴同一份数据、同一补丁入口；缺 at 显示「随前序」
	box.add_child(_steps_time_row(arr, _steps_sel))
	var sfields: Array = decl.get("fields", [])
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	for fd in sfields:
		if not (fd is Dictionary):
			continue
		box.add_child(_step_field_row(fd, sfd))
	# 该步骤里有声明已删的键：只读保留
	var known := {}
	for fd2 in sfields:
		if fd2 is Dictionary:
			known[str((fd2 as Dictionary).get("code", ""))] = true
	var extra := []
	for k in sfd:
		if str(k) == "" or known.has(str(k)):
			continue
		extra.append(k)
	if not extra.is_empty():
		extra.sort()
		box.add_child(Kit.hint_label("⚠ %d 个参数未在声明里（只读保留）" % extra.size(), 320))
		for k2 in extra:
			var v = sfd[k2]
			var row := LineEdit.new()
			row.text = "%s = %s" % [str(k2), str(v) if (v is String or v is StringName) else JSON.stringify(v)]
			row.editable = false
			box.add_child(row)

## 步骤字段行：复用 field_widgets，值取自步骤自己的 fields（键=字段码）。
## 回调捕获**步骤下标 + 结构版本 + 绑定身份**（D1）：换序/切页签后迟到的回调按版本丢弃。
func _step_field_row(fd: Dictionary, sfd: Dictionary) -> Control:
	var key := str(fd.get("code", ""))
	var val = sfd.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", str(fd.get("id", ""))))
	var si := _steps_sel
	var rev := _steps_rev
	var built := FieldWidgets.build(fd, val, func(v):
		_set_step_field(si, key, v, rev), _resolve_options)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	return Kit.field_row(label, built.ctl, 96)

## 时间换算读数（D2）：非秒基下显示「= 起 .. 止 s」，秒基返回空串。
## 只做对齐参考；缺项（时钟不可用）时不显示，避免给出假秒数。
func _step_seconds_hint(eff: Dictionary) -> String:
	if _steps_clock == null or str(_steps_clock.timebase) == "seconds":
		return ""
	if not _steps_clock.is_ready():
		return ""
	var at := float(_steps_clock.seconds_at(float(eff.get("at", 0.0))))
	var end := float(_steps_clock.seconds_at(float(eff.get("at", 0.0)) + float(eff.get("duration", 0.0))))
	return "  = %ss → %ss" % [String.num(at, 3), String.num(end, 3)]

## 时间与轨道行（D1）：默认收起，展开后可输入起点 / 时长 / 轨号 / 阻塞。
## 起点留空 = 「随前序」（缺 at）；显式 0 = 从零开始。时长接受 0。
func _steps_time_row(arr: Array, si: int) -> Control:
	var box := Kit.vbox(2)
	var eff: Dictionary = StepTimeline.effective(arr, si)
	var st: Dictionary = arr[si] if si < len(arr) and arr[si] is Dictionary else {}
	var has_at := st.has("at")
	var body := Kit.vbox(2)
	body.visible = false
	var head := Kit.button("▸ 时间与轨道（%s 起，时长 %s，轨 %d）%s" % [
		_num_text(eff.get("at", 0.0)), _num_text(eff.get("duration", 0.0)),
		int(eff.get("track", 0)), _step_seconds_hint(eff)], Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.pressed.connect(func():
		body.visible = not body.visible
		head.text = ("▾" if body.visible else "▸") + head.text.substr(1))
	box.add_child(head)
	box.add_child(body)
	var row := Kit.hbox(6)
	# 起点
	var at_edit := LineEdit.new()
	at_edit.custom_minimum_size = Vector2(74, 0)
	at_edit.placeholder_text = "随前序"
	at_edit.text = _num_text(st.get("at", null)) if has_at else ""
	at_edit.tooltip_text = "留空 = 随前序（接着上一阻塞步骤结束）；填 0 = 从零开始"
	var rev_at := _steps_rev
	at_edit.text_submitted.connect(func(t: String):
		if rev_at != _steps_rev:
			return
		if t.strip_edges() == "":
			_apply_time_patch(si, {}, ["at"])   # 清起点 = 恢复「随前序」
		else:
			_apply_time_patch(si, {"at": maxf(t.to_float(), 0.0)}, []))
	at_edit.focus_exited.connect(func():
		if rev_at == _steps_rev and at_edit.text.strip_edges() != "":
			_apply_time_patch(si, {"at": maxf(at_edit.text.to_float(), 0.0)}, []))
	row.add_child(Kit.text_label("起点", Th.TEXT_DIM, Th.FS_META))
	row.add_child(at_edit)
	# 时长
	var dur_edit := LineEdit.new()
	dur_edit.custom_minimum_size = Vector2(64, 0)
	dur_edit.text = _num_text(eff.get("duration", 0.0))
	dur_edit.tooltip_text = "持续时长；0 = 瞬发（不占时）"
	var rev_dur := _steps_rev
	dur_edit.text_submitted.connect(func(t: String):
		if rev_dur != _steps_rev:
			return
		_apply_time_patch(si, {"duration": maxf(t.to_float(), 0.0)}, []))
	row.add_child(Kit.text_label("时长", Th.TEXT_DIM, Th.FS_META))
	row.add_child(dur_edit)
	# 轨号
	var trk := SpinBox.new()
	trk.min_value = 0
	trk.max_value = 99
	trk.step = 1
	trk.value = int(eff.get("track", 0))
	trk.custom_minimum_size = Vector2(60, 0)
	trk.tooltip_text = "轨道号；同轨按起点排序，重叠只警告"
	var rev_trk := _steps_rev
	trk.value_changed.connect(func(v: float):
		if rev_trk == _steps_rev:
			_apply_time_patch(si, {"track": int(v)}, []))
	row.add_child(Kit.text_label("轨", Th.TEXT_DIM, Th.FS_META))
	row.add_child(trk)
	# 阻塞
	var blk := CheckBox.new()
	blk.text = "阻塞"
	blk.button_pressed = bool(eff.get("blocking", true))
	blk.tooltip_text = "阻塞 = 后续步骤等这一步结束；关掉则同刻继续"
	var rev_blk := _steps_rev
	blk.toggled.connect(func(v: bool):
		if rev_blk == _steps_rev:
			_apply_time_patch(si, {"blocking": v}, []))
	row.add_child(blk)
	var rev_new := _steps_rev
	var new_trk := Kit.button("移至新轨", func():
		if rev_new == _steps_rev:
			_apply_time_patch(si, {"track": _next_track()}, []), "ghost")
	new_trk.tooltip_text = "轨号取当前最大值 + 1（新轨在时间轴底部）"
	row.add_child(new_trk)
	# 拍基：显式对齐到声明细分格（既有拍数精度不自动改，D2）
	if _steps_clock != null and str(_steps_clock.timebase) == "beats" and _steps_clock.is_ready():
		var grid := float(_steps_clock.snap_step())
		var rev_align := _steps_rev
		var align := Kit.button("对齐 1/%d 拍" % int(roundf(1.0 / grid)), func():
			if rev_align == _steps_rev:
				_quantize_step(si, grid), "ghost")
		align.tooltip_text = "把这一步的 at/duration 对齐到声明的每拍格数"
		row.add_child(align)
	body.add_child(row)
	return box

## D2 参考时钟块：声明缺项提示、小数帧待修（含一键量化）、参考帧缩略与音频名。
## 只服务于「按秒对齐」，不做游戏判定；缺项时时间仍按原单位编辑。
func _steps_clock_box(arr: Array) -> Control:
	var box := Kit.vbox(2)
	if _steps_clock == null:
		return box
	var tb := str(_steps_clock.timebase)
	var unit: String = {"seconds": "秒", "frames": "帧", "beats": "拍"}.get(tb, "秒")
	# 播放头读数：原始单位 → 秒（负秒 = 音频起点前，保持静音；这里只标注）
	_steps_playhead_label = Kit.text_label("", Th.TEXT_MUTE, Th.FS_META)
	var ph: float = _steps_tl.playhead if _steps_tl != null and is_instance_valid(_steps_tl) else 0.0
	_fill_playhead_label(ph)
	box.add_child(_steps_playhead_label)
	for m in _steps_clock_missing:
		box.add_child(Kit.hint_label("⚠ 参考参数缺项：%s（时间仍按%s编辑）" % [str(m), unit], 320))
	# 小数帧待修：已存值不求整，只标记；逐条提供显式量化（新输入由吸附取整）
	if tb == "frames":
		var frac: Array = TimelineClock.fractional_frames(arr)
		if not frac.is_empty():
			box.add_child(Kit.hint_label("⚠ %d 处小数帧待修（at/duration 应为整数帧）" % frac.size(), 320))
			for f in frac:
				var fi := int(f.index)
				var nm := _step_name_of(str((arr[fi] as Dictionary).get("step", ""))) \
					if fi >= 0 and fi < arr.size() and arr[fi] is Dictionary else ""
				var frow := Kit.hbox(6)
				var flabel := Kit.hint_label("  · 第 %d 步%s %s = %s 帧" % [
					fi + 1, ("（%s）" % nm) if nm != "" else "",
					str(f.key), _num_text(f.value)], 320)
				flabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				frow.add_child(flabel)
				var fix := Kit.button("取整", func(): _quantize_step(fi, 1.0), "ghost")
				fix.tooltip_text = "只把这一步的 at/duration 四舍五入到整帧"
				frow.add_child(fix)
				box.add_child(frow)
	# 拍基：既有拍数精度不动（底层保留），只有显式「对齐格」才量化选中步骤——
	# 见时间与轨道行里的对齐按钮，这里不逐条列「不在格上」免得老内容满屏提示
	# 参考帧预览（帧基专有）：播放头帧号取整，越界显式提示（从第 0 帧计数）
	if tb == "frames" and not _steps_preview_frames.is_empty():
		box.add_child(_steps_frame_preview())
	if _steps_audio != "":
		var an := AudioDecls.audio_decl(manifest, _steps_audio)
		var sec0: float = float(_steps_clock.seconds_at(0.0))
		box.add_child(Kit.hint_label("♪ 参考音频：%s（只对齐，不播放；0 %s 对应 %.3f s）" % [
			str(an.get("name", _steps_audio)), "秒" if tb == "seconds" else ("帧" if tb == "frames" else "拍"), sec0], 320))
	return box

## 参考帧预览：帧基下按播放头帧索引显示该资产声明的一帧；无播放头时显示第 0 帧。
## 播放头拖动期间只重建这一行（不动整张表单，免得清掉正在输入的焦点）。
func _steps_frame_preview() -> Control:
	_steps_frame_holder = Kit.hbox(6)
	_fill_frame_preview()
	return _steps_frame_holder

func _fill_frame_preview() -> void:
	if _steps_frame_holder == null:
		return
	for c in _steps_frame_holder.get_children():
		_steps_frame_holder.remove_child(c)
		c.queue_free()
	var n := _steps_preview_frames.size()
	if n <= 0:
		return
	var idx := _steps_preview_idx
	var label := "参考帧："
	if idx < 0:
		idx = 0
		label = "参考帧（第 0 帧）："
	elif idx >= n:
		_steps_frame_holder.add_child(Kit.hint_label("⚠ 播放头帧 %d 超出帧序列（0..%d）" % [idx, n - 1], 320))
		idx = n - 1
	_steps_frame_holder.add_child(Kit.text_label(label, Th.TEXT_DIM, Th.FS_META))
	var rel := str(_steps_preview_frames[idx])
	var tex: Texture2D = EntityNodeRef.texture_of(manifest, rel)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = Vector2(48, 48)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_steps_frame_holder.add_child(tr)
	_steps_frame_holder.add_child(Kit.text_label("%d / %d  %s" % [idx, n - 1, rel], Th.TEXT_MUTE, Th.FS_META))

## 显式量化单步（D2：吸附只作用于新输入或显式量化选中项）：
## 只把该步 at/duration 按粒度四舍五入（帧 = 1 帧；拍 = 1/subdivisions），
## 经同一补丁入口写回，已有精度不被自动改写。
func _quantize_step(si: int, grid: float) -> void:
	if grid <= 0.0:
		return
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return
	var step: Dictionary = arr[si]
	var patch := {}
	for key in ["at", "duration"]:
		if step.has(key):
			patch[key] = snappedf(maxf(float(step.get(key, 0.0)), 0.0), grid)
	if patch.is_empty():
		return
	_apply_time_patch(si, patch, [])

## 新轨号 = 当前所有步骤的最大轨号 + 1。
func _next_track() -> int:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var mx := 0
	var tl := StepTimeline.to_timeline(arr)
	for e in tl:
		mx = maxi(mx, int((e as Dictionary).get("track", 0)))
	return mx + 1

static func _num_text(v) -> String:
	if v == null:
		return ""
	if v is int:
		return str(v)
	var f := float(v)
	return str(int(f)) if is_equal_approx(f, floorf(f)) else ("%.2f" % f)

## 表单的时间编辑：与时间轴同一个补丁入口（StepTimeline.apply_patch + 同一写回）。
func _apply_time_patch(si: int, patch: Dictionary, erase_keys: Array) -> void:
	var data := _steps_data()
	if data.is_empty():
		return
	# D2：新输入的 at/duration 按声明粒度吸附（帧取整、拍按 subdivisionsPerBeat）；
	# 秒基不吸附——手输的秒精度就是用户意图，不该被改
	if _steps_clock != null and str(_steps_clock.timebase) != "seconds":
		var snapv := float(_steps_clock.snap_step())
		patch = patch.duplicate()
		for k in ["at", "duration"]:
			if patch.has(k):
				patch[k] = snappedf(maxf(float(patch[k]), 0.0), snapv)
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var res: Dictionary = StepTimeline.apply_patch(arr, si, patch, erase_keys)
	if not bool(res.get("ok", false)):
		return
	data["steps"] = res.get("steps", arr)
	_steps_write(data)
	_bump_steps_rev()
	_rebuild_steps_all()

## 写步骤字段：即时写盘，不重建表单（保焦点）。版本过期/下标越界直接丢弃。
func _set_step_field(si: int, key: String, value, rev := -1) -> void:
	if si < 0 or key == "":
		return
	if rev >= 0 and rev != _steps_rev:
		return   # 过期控件回调：期间增删/换序过，按下标写回会落到别的步骤上
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si >= arr.size() or not (arr[si] is Dictionary):
		return
	var st: Dictionary = arr[si]
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	if sfd.get(key, null) == value:
		return   # 值没变不写盘（重建触发的同值回调幂等跳过）
	sfd[key] = value
	st["fields"] = sfd
	data["steps"] = arr
	_steps_write(data)

## 添加步骤：追加到末尾并选中。
func _steps_add(code: String) -> void:
	if code == "":
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	arr.append({"step": code, "fields": {}})
	data["steps"] = arr
	_steps_sel = arr.size() - 1
	_steps_write(data)
	_bump_steps_rev()
	_rebuild_steps_all()

## 删除步骤；删的是选中的步骤时清除选中。
func _steps_del(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size():
		return
	arr.remove_at(si)
	data["steps"] = arr
	if _steps_sel >= arr.size():
		_steps_sel = arr.size() - 1
	if _steps_sel > si:
		_steps_sel -= 1
	_steps_write(data)
	_bump_steps_rev()
	_rebuild_steps_all()

## 上移/下移一格。
func _steps_move(si: int, dir: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var nj := si + dir
	if si < 0 or si >= arr.size() or nj < 0 or nj >= arr.size():
		return
	var tmp = arr[si]
	arr[si] = arr[nj]
	arr[nj] = tmp
	data["steps"] = arr
	_steps_sel = nj
	_steps_write(data)
	_bump_steps_rev()
	_rebuild_steps_all()

## 复制步骤：浅拷贝 fields 并插到下一步；步骤码引用清单声明、跨内容共享，无需重映射。
func _steps_dup(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return
	var cp: Dictionary = (arr[si] as Dictionary).duplicate(true)
	cp["fields"] = (cp.get("fields", {}) as Dictionary).duplicate(true) if cp.get("fields", {}) is Dictionary else {}
	arr.insert(si + 1, cp)
	data["steps"] = arr
	_steps_sel = si + 1
	_steps_write(data)
	_bump_steps_rev()
	_rebuild_steps_all()
